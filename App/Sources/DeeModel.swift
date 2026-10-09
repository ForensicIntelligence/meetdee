import DeeCore
import DeeFace
import DeeLLM
import DeeMemory
import DeeMind
import DeeSense
import DeeVoice
import Foundation
import Observation

/// One line in the (debug) transcript.
struct TranscriptItem: Identifiable, Equatable {
    enum Kind: Equatable { case user, dee, tool, note }
    let id = UUID()
    var kind: Kind
    var text: String
    var reasoning: String = ""
    var isStreaming = false
}

/// The app's single source of truth: model lifecycle, the conversation, Dee's voice,
/// what she sees, hears and feels, and what her eyes should be doing.
///
/// Every way of reaching Dee funnels into `perceive(_:)`: speech, touch, gestures,
/// things she sees or hears, and her own curiosity.
@Observable @MainActor
final class DeeModel {
    enum LoadState: Equatable {
        case idle
        case loading(Double)
        case ready
        case failed(String)
    }

    /// Something that reaches Dee and may make her respond.
    enum Stimulus {
        /// Said out loud (or typed in Debug); appraised for what and how.
        case spoken(String, prosody: Prosody?)
        /// A non-verbal event already turned into an appraisal, plus the stage
        /// direction the language model sees ("(The user waves at you.)").
        case event(Appraisal, line: String)
        /// Dee's own initiative (curiosity): a stage direction, no appraisal.
        case initiative(String)
    }

    // Brain
    private(set) var loadState: LoadState = .idle
    private(set) var transcript: [TranscriptItem] = []
    private(set) var thinkingMode = false
    private(set) var isResponding = false
    private(set) var statusLine = ""
    /// What Dee is saying right now (shown as a caption).
    private(set) var caption = ""
    /// What Dee is hearing / last heard (shown small, above the caption).
    private(set) var heard = ""

    // Face
    private(set) var emotion: Emotion = .neutral
    private(set) var activity: FaceActivity = .idle {
        // A sleeping Dee only needs to notice someone arriving: let the camera idle.
        didSet { if (oldValue == .sleeping) != (activity == .sleeping) { camera.isDozing = activity == .sleeping; updateListening() } }
    }
    private(set) var lookAt: SIMD2<Double>?
    private(set) var touchPoint: SIMD2<Double>?
    private(set) var performance: PerformanceRequest?
    private var performanceCounter = 0
    private(set) var speechLevel = 0.0
    private(set) var micLevel = 0.0

    // Mind
    /// Dee's inner state (26 parameters → one code); drives eye colour and mood.
    private(set) var mindSnapshot: MindSnapshot?
    /// A short-lived expression (the model's tag while she talks, or a reflex /
    /// reaction) that wins over the mind's mood until `spokenEmotionUntil`.
    private var spokenEmotion: Emotion?
    private var spokenEmotionUntil = Date.distantPast

    // Senses
    private(set) var cameraActive = false
    private(set) var someoneHere = false
    private(set) var isSpeaking = false
    private(set) var voiceReady = false
    private(set) var microphoneAllowed = true
    private var lastHeardPartialAt = Date.distantPast
    private var absentSince: Date? = Date()
    private var asleepSince: Date?
    private var touch = TouchInterpreter()
    private var curiosity = CuriosityDirector()

    private var engine: LlamaEngine?
    private var agent: ConversationAgent?
    private var responseTask: Task<Void, Never>?
    private var persona = Persona()
    private let camera = CameraSense()
    private let voice = VoiceService()
    private var moodClock: Task<Void, Never>?
    private var touchClock: Task<Void, Never>?
    private var mind: Mind?
    private var people: People?
    /// Extra stage-direction notes for the next turn's cue (identity checks, care).
    private var pendingNotes: [String] = []

    /// How long nobody may be in view before Dee gets drowsy / falls asleep, and how
    /// long she must sleep before the next visit counts as a new conversation.
    static let drowsyAfter: TimeInterval = 45
    static let sleepAfter: TimeInterval = 180
    static let newConversationAfterSleeping: TimeInterval = 300

    var faceInputs: FaceInputs {
        let tint = mindSnapshot.map { FaceColor($0.eyeColor.r, $0.eyeColor.g, $0.eyeColor.b) }
        var inputs = FaceInputs(emotion: emotion, activity: activity, lookAt: touchPoint.map(Self.gaze(fromTouch:)) ?? lookAt,
                                speechLevel: speechLevel, micLevel: micLevel, tint: tint)
        if let m = mindSnapshot?.mood {
            inputs.mood = FaceMood(curiosity: m.curiosity, boredom: m.boredom, playfulness: m.playfulness,
                                   energy: m.energy, affection: m.affection, arousal: m.arousal)
        }
        inputs.touchPoint = touchPoint
        inputs.performance = performance
        return inputs
    }

    /// Touch location (0…1, y down) → gaze space (−1…1).
    static func gaze(fromTouch p: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2((p.x - 0.5) * 2, (p.y - 0.47) * 2)
    }

    /// The face shows a short-lived expression (the model's tag while talking, a
    /// reflex) when there is one, otherwise whatever the mind feels most.
    private func refreshEmotion() {
        if let spoken = spokenEmotion, isResponding || isSpeaking || Date() < spokenEmotionUntil {
            emotion = spoken
        } else if let snap = mindSnapshot, activity != .sleeping {
            spokenEmotion = nil
            emotion = snap.emotion
        }
    }

    private func perform(_ p: Performance) {
        performanceCounter += 1
        performance = PerformanceRequest(id: performanceCounter, performance: p)
    }

    /// Seconds since boot — the same clock as `UITouch.timestamp`.
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    // MARK: - Lifecycle

    private var started = false
    private var senseTask: Task<Void, Never>?
    private var voiceTask: Task<Void, Never>?
    /// When the app went to the background (time away counts as the user being absent).
    private var backgroundedAt: Date?

    func start() async {
        // `.task` can re-run (scene reconnects); everything here must happen once.
        guard !started else { return }
        started = true
        await openMind()
        people = People()
        startMoodClock()
        startVoice()
        await startCamera()
        await loadIfNeeded()
    }

    func loadIfNeeded() async {
        guard loadState == .idle || { if case .failed = loadState { true } else { false } }() else { return }
        guard let url = ModelLocator.locate() else {
            loadState = .failed(ModelLocator.Problem.notFound.localizedDescription)
            flash(.confused, seconds: 5)
            return
        }
        do {
            try ModelLocator.checkMemory()
            loadState = .loading(0)
            activity = .thinking
            let engine = try await LlamaEngine.load(.init(modelPath: url.path(percentEncoded: false))) { [weak self] p in
                Task { @MainActor in
                    if case .loading = self?.loadState { self?.loadState = .loading(p) }
                }
            }
            let agent = ConversationAgent(generator: engine, tools: memoryTools(), persona: persona)
            await agent.newConversation(persona: await currentPersona())
            self.engine = engine
            self.agent = agent
            loadState = .ready
            activity = .idle
            flash(.happy)
            statusLine = engine.modelDescription
            updateListening()
            #if DEBUG
            // `-DeeAutoPrompt "text"`: send a message on launch (screenshots, UI tests).
            if let auto = UserDefaults.standard.string(forKey: "DeeAutoPrompt"), !auto.isEmpty {
                send(auto)
            }
            #endif
        } catch {
            loadState = .failed(error.localizedDescription)
            activity = .idle
            flash(.sad, seconds: 5)
        }
    }

    // MARK: - Mind

    private func openMind() async {
        let defaults = UserDefaults.standard
        let url = Mind.defaultURL()
        do {
            let mind = try Mind(databaseURL: url)
            if defaults.bool(forKey: "resetMind") {
                await mind.reset()
                defaults.set(false, forKey: "resetMind")
            }
            self.mind = mind
            await applyAgeSettings()
            accept(await mind.tick(userPresent: someoneHere, asleep: false))
            refreshEmotion()
        } catch {
            // A corrupt database must never brick Dee: move it aside (kept for
            // diagnosis, never deleted) and start a fresh one; in-memory as a last resort.
            let stamp = Int(Date().timeIntervalSince1970)
            for suffix in ["", "-wal", "-shm"] {
                let file = URL(fileURLWithPath: url.path(percentEncoded: false) + suffix)
                try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("corrupt-\(stamp)"))
            }
            mind = (try? Mind(databaseURL: url)) ?? (try? Mind(databaseURL: nil))
            if let mind {
                accept(await mind.tick(userPresent: someoneHere, asleep: false))
                refreshEmotion()
            }
        }
    }

    /// Reads the age options from the Settings app.
    func applyAgeSettings() async {
        guard let mind else { return }
        let d = UserDefaults.standard
        var settings = await mind.state.age
        let original = settings
        let enabled = d.bool(forKey: "ageEnabled")
        let aging = d.bool(forKey: "agingEnabled")
        let start = max(0, min(120, Double(d.string(forKey: "startAge") ?? "") ?? 6))
        let rate = Double(d.string(forKey: "yearsPerDay") ?? "") ?? 0.1
        // Compare with what was last *applied from Settings*, not with Dee's live
        // age — otherwise turning ageing off would snap an aged Dee back to her
        // starting age on the next launch.
        let appliedStart = d.object(forKey: "appliedStartAge") as? Double
        if enabled != settings.enabled || start != appliedStart {
            settings.enabled = enabled
            settings.startAge = start
            settings.since = Date()
            d.set(start, forKey: "appliedStartAge")
        }
        if aging != settings.agingEnabled {
            if let now = settings.age(at: Date()) { settings.startAge = now }
            settings.agingEnabled = aging
            settings.since = Date()
        }
        if settings != original { await mind.setAge(settings) }
        if aging, abs(rate - settings.yearsPerDay) > 1e-9 { await mind.setAgingRate(rate) }
    }

    /// Keeps only the newest snapshot: a slow tick finishing after a newer `hear`
    /// must not paint the eyes with stale feelings.
    private func accept(_ snap: MindSnapshot) {
        if let current = mindSnapshot, snap.sequence < current.sequence { return }
        mindSnapshot = snap
    }

    /// Applies a fresh snapshot from something that just happened: the reflex (a
    /// laugh at a joke, a flinch at a slap) shows immediately, whatever the mood.
    private func took(_ snap: MindSnapshot, laughable: Bool = false) {
        accept(snap)
        if let reflex = snap.reflex {
            // Hold the reflex through the first words of a reply, so a joke is
            // answered in a laughing voice even when her mood is low.
            flash(reflex, seconds: isResponding ? 6 : 2.5)
            switch reflex {
            case .giddy, .joy:
                perform(.giggle)
                if laughable, !isSpeaking {
                    voice.laugh(intensity: reflex == .giddy ? 0.8 : 0.5, age: snap.age, energy: snap.mood.energy)
                }
            case .surprised, .scared: perform(.startle)
            case .shy: perform(.contentSquint)
            case .relieved: perform(.sigh)
            default: break
            }
        } else if !isResponding {
            refreshEmotion()
        }
    }

    /// Shows a reaction for a few seconds before the mind's mood takes over again.
    private func flash(_ e: Emotion, seconds: TimeInterval = 3) {
        spokenEmotion = e
        spokenEmotionUntil = Date().addingTimeInterval(seconds)
        emotion = e
    }

    @discardableResult
    private func react(_ appraisal: Appraisal) async -> MindSnapshot? {
        guard let mind else { return nil }
        let snap = await mind.react(appraisal)
        took(snap)
        return snap
    }

    // MARK: - App lifecycle

    /// Called on scene-phase changes. Time spent in the background counts as the
    /// user being away (not as them sitting silently in front of Dee).
    func sceneBecame(active: Bool) async {
        guard let mind else { return }
        if active {
            let away = backgroundedAt
            backgroundedAt = nil
            accept(await mind.catchUp(lastSeenUserAt: someoneHere ? away : nil))
            await applyAgeSettings()
            refreshEmotion()
            updateListening()
        } else if backgroundedAt == nil {
            backgroundedAt = Date()
            voice.listeningEnabled = false
            voice.stopSpeaking()
            touch.cancelAll()
            touchPoint = nil
            accept(await mind.tick(userPresent: someoneHere, asleep: activity == .sleeping))
            // Tick writes are throttled; make sure nothing is lost if iOS ends the app.
            await mind.flush()
        }
    }

    // MARK: - Voice

    private func startVoice() {
        voiceTask?.cancel()
        voiceTask = Task { [weak self, voice] in
            for await event in voice.events {
                guard let self else { return }
                self.handle(event)
            }
        }
        Task { await voice.start() }
    }

    /// Listen whenever someone could be talking to Dee and she's awake. The voice
    /// service pauses recognition by itself while Dee is speaking.
    private func updateListening() {
        voice.listeningEnabled = loadState == .ready && someoneHere && activity != .sleeping && backgroundedAt == nil
    }

    private var voiceStyle: VoiceStyle {
        VoiceStyle.forMood(emotion: emotion, age: mindSnapshot?.age, energy: mindSnapshot?.mood.energy ?? 0.8)
    }

    private func handle(_ event: VoiceEvent) {
        switch event {
        case .permission(let mic, _):
            microphoneAllowed = mic
            if !mic {
                transcript.append(TranscriptItem(kind: .note, text: "Microphone access is off — Dee can't hear you. Turn it on in Settings › Dee."))
                flash(.sad, seconds: 4)
            }
        case .ready:
            voiceReady = true
            updateListening()
        case .listening(let on):
            if on, !isResponding, !isSpeaking, activity == .idle { micLevel = 0 }
        case .partial(let text):
            heard = text
            lastHeardPartialAt = Date()
            if !isResponding, !isSpeaking, activity != .sleeping { activity = .listening }
        case .heard(let utterance):
            lastHeardPartialAt = .distantPast
            if activity == .listening { activity = .idle }
            let p = utterance.prosody
            let prosody = Prosody(loudnessDB: p.loudnessDB, peakDB: p.peakDB, speechRate: p.speechRate, pitchVariability: p.pitchVariability)
            perceive(.spoken(utterance.text, prosody: prosody))
        case .sound(let sound):
            heardSound(sound)
        case .micLevel(let level):
            micLevel = level
        case .speakingStarted:
            isSpeaking = true
            activity = .speaking
        case .speechLevel(let level):
            speechLevel = level
        case .speakingFinished:
            isSpeaking = false
            speechLevel = 0
            curiosity.note(.deeSpoke, at: Date())
            if !isResponding { activity = .idle; spokenEmotionUntil = Date().addingTimeInterval(3) }
        case .bargeIn:
            // The user talked over Dee: stop and listen.
            stop()
            flash(.listening, seconds: 2)
        case .pause:
            // v0.5: routed to the Cortex (turn prediction); v0.4 ignores it.
            break
        case .error(let message):
            transcript.append(TranscriptItem(kind: .note, text: "Voice: \(message)"))
        }
    }

    private func heardSound(_ sound: HeardSound) {
        let loudness = max(0, min(1, (sound.loudnessDB + 50) / 40))
        // Social sounds are never "unexpected", but they matter most: laughter is
        // contagious, crying gets concern, applause delights.
        if sound.kind.isSocial {
            let quietMoment = !isSpeaking && !isResponding && !voice.userIsSpeaking
            if sound.kind == .laughter, quietMoment, activity != .sleeping {
                voice.laugh(intensity: 0.5, age: mindSnapshot?.age, energy: mindSnapshot?.mood.energy ?? 0.7)
                perform(.giggle)
            }
            Task { await react(.sound(label: sound.label, unexpected: false, loudness: loudness)) }
            return
        }
        guard sound.isUnexpected else { return }
        curiosity.noteSound(sound.label, unexpected: true, loudness: loudness, at: Date())
        if activity == .sleeping {
            // Only an alarming or loud noise wakes a sleeping Dee (not every creak).
            let asleepFor = asleepSince.map { Date().timeIntervalSince($0) }
            guard loudness > 0.6 || CuriosityDirector.callsOutUnattended(sound: sound.label, loudness: loudness, asleepFor: asleepFor) else {
                Task { await react(.sound(label: sound.label, unexpected: true, loudness: loudness * 0.5)) }
                return
            }
            activity = .idle
            asleepSince = nil
        }
        perform(sound.loudnessDB > -20 ? .startle : .doubleTake)
        Task {
            await react(.sound(label: sound.label, unexpected: true, loudness: loudness))
        }
    }

    // MARK: - Touch

    /// Raw touches from the face view (location 0…1, y down).
    func touched(_ sample: TouchSample) {
        touchPoint = sample.phase == .ended || sample.phase == .cancelled ? nil : sample.location
        for gesture in touch.add(sample) { handle(gesture) }
        startTouchClockIfNeeded()
    }

    /// The interpreter needs ~30 Hz ticks while fingers are down or taps are
    /// pending (holds, tap timeouts, end of a poke burst); none otherwise.
    private func startTouchClockIfNeeded() {
        guard touchClock == nil, touch.needsFastTicks else { return }
        touchClock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self else { return }
                for g in self.touch.tick(at: self.now) { self.handle(g) }
                if !self.touch.needsFastTicks { break }
            }
            self?.touchClock = nil
        }
    }

    private func handle(_ gesture: TouchGesture) {
        guard loadState != .idle else { return }
        if activity == .sleeping, case .tap = gesture {} else if activity == .sleeping {
            activity = .idle
            asleepSince = nil
            perform(.startle)
        }
        let kind: Touch
        let line: String?
        switch gesture {
        case .tap(let at):
            kind = .tap
            line = nil
            // A tap on an eye makes that eye blink; anywhere else she looks.
            if abs(at.y - 0.47) < 0.12, abs(abs(at.x - 0.5) - 0.19) < 0.12 {
                perform(at.x < 0.5 ? .blinkLeft : .blinkRight)
            } else {
                perform(.doubleTake)
            }
        case .doubleTap:
            kind = .doubleTap
            line = nil
            perform(.bounce)
        case .pet(let duration, let gentleness):
            kind = .pet(gentleness: gentleness, seconds: duration)
            line = duration > 3 && gentleness > 0.5 ? "(Your human is gently stroking you.)" : nil
            perform(.contentSquint)
        case .hold(let duration):
            kind = .hold(seconds: duration)
            line = duration > 2 ? "(Your human is holding you gently, like a little hug.)" : nil
            perform(.contentSquint)
        case .pokes(_, _, let total):
            kind = .pokes(count: total)
            line = total >= 6 ? "(Your human keeps poking you.)" : nil
            perform(.squint)
        case .slap(let force):
            kind = .slap(force: force)
            line = force > 0.5 ? "(Your human just smacked your screen.)" : nil
            perform(.startle)
        case .tickle(let duration):
            kind = .tickle(seconds: duration)
            line = duration > 1.5 ? "(Your human is tickling you!)" : nil
            perform(.giggle)
            if duration > 0.6, !isSpeaking { voice.laugh(intensity: 0.7, age: mindSnapshot?.age, energy: mindSnapshot?.mood.energy ?? 0.7) }
        }
        let appraisal = Appraisal.touch(kind)
        if let line, !isResponding, !isSpeaking, loadState == .ready {
            // Answered right now — don't also let curiosity bring it up again.
            perceive(.event(appraisal, line: line))
        } else {
            curiosity.note(.touched(kind.word), at: Date())
            Task { await react(appraisal) }
        }
    }

    // MARK: - People (DeeMemory)

    /// Face crops from the camera → who is here.
    private func recognize(_ crops: [FaceCrop]) {
        guard let people else { return }
        Task {
            if let event = await people.process(crops) { self.handle(event) }
        }
    }

    private func handle(_ event: People.Event) {
        switch event {
        case .recognised(let person):
            // A friend she knows: start a conversation that remembers them, and say hi.
            guard loadState == .ready, !isResponding, !isSpeaking else { return }
            newConversation()
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                self.perceive(.initiative("(You recognise \(person.name) — you know them. Greet them warmly by name.)"))
            }
        case .learnedName(let name):
            pendingNotes.append("(Their name is \(name). You will remember it.)")
            perform(.nod)
        case .nameConflict(let heard, let thought):
            pendingNotes.append("(You thought this was \(thought), but they said they're \(heard). Gently check who you're talking to.)")
            perform(.doubleTake)
        }
    }

    /// The persona for a new conversation: who Dee is talking to and what she
    /// remembers about them (frozen for the conversation).
    private func currentPersona() async -> Persona {
        var p = persona
        p.userName = people?.currentName
        p.memories = await people?.memories() ?? []
        return p
    }

    private func memoryTools() -> ToolRegistry {
        guard let people else { return ToolRegistry() }
        let current: @Sendable () async -> UUID? = { await MainActor.run { people.currentID } }
        return ToolRegistry([
            RememberTool(store: people.store, currentPerson: current),
            RecallTool(store: people.store, currentPerson: current),
            ForgetTool(store: people.store, currentPerson: current),
        ])
    }

    // MARK: - Camera: presence, gaze, gestures, sight

    private func startCamera() async {
        guard CameraSense.isAvailable else {
            // Simulator / no camera: behave as if someone is always there.
            someoneHere = true
            absentSince = nil
            updateListening()
            return
        }
        camera.lookAround = true
        do {
            try await camera.start()
            cameraActive = true
        } catch {
            someoneHere = true
            absentSince = nil
            updateListening()
            return
        }
        senseTask?.cancel()
        senseTask = Task { [weak self, camera] in
            for await update in camera.updates {
                guard let self else { return }
                self.handle(update)
            }
        }
    }

    private func handle(_ update: SenseUpdate) {
        switch update {
        case .presence(.arrived):
            someoneHere = true
            let sleptLongEnough = asleepSince.map { Date().timeIntervalSince($0) >= Self.newConversationAfterSleeping } ?? false
            absentSince = nil
            if activity == .sleeping {
                // Waking up: a surprised pop, then a happy hello.
                asleepSince = nil
                activity = .idle
                flash(.surprised, seconds: 0.7)
                perform(.startle)
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    if self.emotion == .surprised { self.flash(.happy) }
                }
                if sleptLongEnough { newConversation() }
            } else if emotion == .sleepy {
                flash(.happy)
            }
            curiosity.note(.userArrived, at: Date())
            updateListening()
        case .presence(.left):
            someoneHere = false
            absentSince = Date()
            updateListening()
        case .look(let point):
            lookAt = point
        case .gesture(let gesture):
            handle(gesture)
        case .head:
            break // v0.5: Cortex attention
        case .faces(let crops):
            recognize(crops)
        case .sight(let report):
            guard !report.novel.isEmpty else { return }
            let novelty = min(1, (report.novel.map(\.confidence).max() ?? 0.5) * 0.6 + Double(report.novel.count) * 0.15)
            curiosity.noteSight(report.novel.map(\.label), camera: report.camera.rawValue, novelty: novelty, at: Date())
            perform(report.camera == .back ? .lookAround : .doubleTake)
            Task { await react(.sight(novelty: min(1, Double(report.novel.count) * 0.4))) }
        }
    }

    private func handle(_ gesture: Gesture) {
        switch gesture {
        case .wave:
            if activity == .sleeping { activity = .idle; asleepSince = nil }
            flash(.joy)
            perform(.bounce)
            if !isResponding, !isSpeaking, loadState == .ready {
                perceive(.event(.wave, line: "(The user waves at you.)"))
            } else {
                Task { await react(.wave) }
            }
        case .palm:
            // "Hush": stop talking now.
            stop()
            flash(.neutral)
        case .thumbsUp:
            flash(.happy)
            perform(.nod)
            Task { await react(.thumbsUp) }
        }
    }

    /// Drowsiness and sleep when nobody's around; mind ticks; curiosity.
    private func startMoodClock() {
        moodClock?.cancel()
        moodClock = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                ticks += 1
                if ticks % 3 == 0, self.backgroundedAt == nil, let mind = self.mind {
                    self.accept(await mind.tick(userPresent: self.someoneHere, asleep: self.activity == .sleeping))
                    if !self.isResponding, !self.isSpeaking { self.refreshEmotion() }
                }
                self.curiosity.asleepSince = self.asleepSince
                if ticks % 2 == 0 { self.considerInitiative() }
                guard !self.isResponding, !self.isSpeaking, let since = self.absentSince else { continue }
                let away = Date().timeIntervalSince(since)
                if away >= Self.sleepAfter, self.activity != .sleeping {
                    self.people?.newSession()
                    self.activity = .sleeping
                    self.asleepSince = Date()
                } else if away >= Self.drowsyAfter, self.activity == .idle, self.emotion != .sleepy {
                    self.flash(.sleepy, seconds: 10)
                }
            }
        }
    }

    /// Dee is very interactive: when the curiosity director has something to say
    /// (a novel sight, an odd noise, a question about you), she says it.
    private func considerInitiative() {
        guard loadState == .ready, backgroundedAt == nil, activity != .sleeping, let snap = mindSnapshot else { return }
        let userTalking = voice.userIsSpeaking || Date().timeIntervalSince(lastHeardPartialAt) < 2.5
        let busy = isResponding || isSpeaking || userTalking
        guard let prompt = curiosity.nextPrompt(at: Date(), snapshot: snap, userPresent: someoneHere, busy: busy) else { return }
        perceive(.initiative(prompt))
    }

    // MARK: - Conversation

    /// Debug-only text entry (the shipping app is voice and camera only).
    func send(_ raw: String) {
        perceive(.spoken(raw, prosody: nil))
    }

    /// Spoken commands handled without the language model.
    private func command(in text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        func has(_ phrases: [String]) -> Bool { phrases.contains { t == $0 || t.hasPrefix($0 + " ") || t.hasSuffix(" " + $0) } }
        if has(["start over", "let's start over", "new conversation", "start a new conversation", "fresh start", "let's start fresh"]) {
            newConversation()
            flash(.happy)
            perform(.bounce)
            voice.say("Okay! Fresh start.", style: voiceStyle)
            return true
        }
        if has(["stop", "stop talking", "be quiet", "shush", "shh", "hush", "quiet"]) {
            stop()
            flash(.neutral)
            return true
        }
        if has(["go to sleep", "goodnight dee", "good night dee", "time to sleep", "nap time"]) {
            stop()
            voice.say("Okay. Goodnight!", style: VoiceStyle.forMood(emotion: .sleepy, age: mindSnapshot?.age, energy: 0.2))
            perform(.yawn)
            Task {
                try? await Task.sleep(for: .seconds(2))
                self.activity = .sleeping
                self.asleepSince = Date()
            }
            return true
        }
        return false
    }

    func perceive(_ stimulus: Stimulus) {
        let text: String
        var appraisal: Appraisal?
        var prosody: Prosody?
        var shouldAppraise = false
        var isInitiative = false
        switch stimulus {
        case .spoken(let raw, let p):
            text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            heard = text
            transcript.append(TranscriptItem(kind: .user, text: text))
            curiosity.note(.userSpoke, at: Date())
            if activity == .sleeping { activity = .idle; asleepSince = nil }
            if command(in: text) { return }
            prosody = p
            shouldAppraise = true
            if FactExtractor.selfHarmSignal(in: text) {
                pendingNotes.append("(They may be going through something painful. Be warm and gentle; encourage them to reach out to someone they trust or a local crisis line.)")
            }
        case .event(let a, let line):
            text = line
            appraisal = a
        case .initiative(let line):
            text = line
            isInitiative = true
        }
        guard let agent, loadState == .ready else {
            if shouldAppraise { Task { await self.appraiseOnly(text, prosody: prosody) } }
            return
        }
        if isResponding || isSpeaking {
            // Busy: still let the words land emotionally, but don't start a new turn
            // (barge-in handles interruptions).
            if shouldAppraise { Task { await self.appraiseOnly(text, prosody: prosody) } }
            else if let appraisal { Task { await self.react(appraisal) } }
            return
        }
        if isInitiative, voice.userIsSpeaking { return }
        isResponding = true
        activity = .thinking
        caption = ""
        if asleepSince != nil { asleepSince = nil }

        responseTask = Task {
            if shouldAppraise, let people, let event = await people.heard(text) { handle(event) }
            var cue: String?
            if shouldAppraise {
                cue = await appraiseOnly(text, prosody: prosody)
            } else if let appraisal {
                cue = await react(appraisal)?.cue
            } else {
                cue = mindSnapshot?.cue
            }
            if !pendingNotes.isEmpty {
                cue = ([cue].compactMap { $0 } + pendingNotes.prefix(2)).joined(separator: "\n")
                pendingNotes.removeAll()
            }
            await run(agent: agent, text: text, cue: cue, initiative: isInitiative)
        }
    }

    @discardableResult
    private func appraiseOnly(_ text: String, prosody: Prosody?) async -> String? {
        guard let mind else { return nil }
        let (_, snap) = await mind.hear(text, prosody: prosody)
        took(snap, laughable: true)
        // React on the face immediately, before the model has said a word.
        if snap.reflex == nil, !isSpeaking { emotion = snap.emotion }
        return snap.cue
    }

    /// - Parameter initiative: Dee spoke up on her own — her words wait politely if
    ///   the user starts talking meanwhile (a reply to the user never waits).
    private func run(agent: ConversationAgent, text: String, cue: String?, initiative: Bool) async {
        var deeIndex: Int?
        func deeItem() -> Int {
            if let deeIndex { return deeIndex }
            transcript.append(TranscriptItem(kind: .dee, text: "", isStreaming: true))
            deeIndex = transcript.count - 1
            return deeIndex!
        }
        do {
            for try await event in agent.respond(to: text, state: cue) {
                switch event {
                case .thinkingModeChanged(let on):
                    thinkingMode = on
                    transcript.append(TranscriptItem(kind: .note, text: on ? "Thinking mode on for this conversation" : "Thinking mode off"))
                    if on { perform(.lookAround) }
                case .generationStarted:
                    deeIndex = nil
                    if !isSpeaking { activity = .thinking }
                case .reasoning(let s):
                    transcript[deeItem()].reasoning += s
                case .content(let s):
                    let i = deeItem()
                    if transcript[i].text.isEmpty { caption = "" }
                    transcript[i].text += s
                    caption += s
                    voice.stream(s, style: voiceStyle, deferWhileUserSpeaks: initiative)
                case .emotion(let e):
                    spokenEmotion = e
                    emotion = e
                case .toolCall(let call):
                    transcript.append(TranscriptItem(kind: .tool, text: "⚙︎ \(call.name)"))
                case .toolResult, .reasoningBudgetExhausted:
                    break
                case .turnCompleted:
                    voice.endStream()
                case .compacted(let n):
                    transcript.append(TranscriptItem(kind: .note, text: "Forgot \(n) older messages to make room"))
                case .messageCompleted(let message):
                    if let i = deeIndex {
                        transcript[i].isStreaming = false
                        transcript[i].text = message.content
                        if transcript[i].text.isEmpty, transcript[i].reasoning.isEmpty { transcript.remove(at: i) }
                    }
                    deeIndex = nil
                }
            }
        } catch is CancellationError {
        } catch {
            transcript.append(TranscriptItem(kind: .note, text: error.localizedDescription))
            flash(.confused)
        }
        voice.endStream()
        for i in transcript.indices where transcript[i].isStreaming { transcript[i].isStreaming = false }
        isResponding = false
        if !isSpeaking { activity = .idle }
        spokenEmotionUntil = Date().addingTimeInterval(4)
        if let engine {
            statusLine = String(format: "%@ · %.0f tok/s", engine.modelDescription, engine.stats.generateTokensPerSecond)
        }
    }

    func stop() {
        voice.stopSpeaking()
        guard let agent else { return }
        Task { await agent.cancel() }
    }

    func newConversation() {
        guard let agent, !isResponding else { return }
        transcript.removeAll()
        thinkingMode = false
        caption = ""
        heard = ""
        Task { await agent.newConversation(persona: await self.currentPersona()) }
    }

    func toggleThinking() {
        guard let agent else { return }
        thinkingMode.toggle()
        let on = thinkingMode
        Task { await agent.setThinking(on) }
    }
}
