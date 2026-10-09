import DeeCore
import DeeFace
import DeeLLM
import DeeMemory
import DeeMind
import DeeSelf
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

/// The app's I/O shell around Dee's one mind.
///
/// v0.5 ("Someone"): DeeModel no longer decides how Dee looks or sounds. Every
/// stimulus — speech, pauses, touch, gestures, sights, sounds, who's there, her own
/// sentences — becomes a `Percept` for the Cortex (DeeSelf), which keeps one shared
/// interpretation of the moment (`Stance`). The face, the voice style, the gaze,
/// the little performances and the language model's `<dee_state>` cue are all
/// projected from that one Stance, so they can never disagree. DeeModel runs the
/// devices, the language model and the stores, and executes the Cortex's effects.
@Observable @MainActor
final class DeeModel {
    enum LoadState: Equatable {
        case idle
        case loading(Double)
        case ready
        case failed(String)
    }

    /// Something that makes Dee take a conversational turn.
    enum Stimulus {
        /// Said out loud (or typed in Debug); appraised for what and how.
        case spoken(String, prosody: Prosody?)
        /// A non-verbal event already turned into an appraisal, plus the stage
        /// direction the language model sees ("(The user waves at you.)").
        case event(Appraisal, line: String)
        /// Dee's own initiative from the curiosity director: a stage direction.
        case initiative(String)
        /// Dee's own initiative from the Cortex: a complete `<dee_state>` cue.
        case cortexInitiative(cue: String)
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

    // Body state the Cortex doesn't own
    /// Sleeping is a body state (driven by presence); everything else the face
    /// shows comes from the Stance.
    private(set) var sleeping = false {
        didSet {
            guard oldValue != sleeping else { return }
            camera.isDozing = sleeping
            updateListening()
            sense(.asleep(sleeping))
        }
    }
    private(set) var lookAt: SIMD2<Double>?
    private(set) var touchPoint: SIMD2<Double>?
    private(set) var performance: PerformanceRequest?
    private var performanceCounter = 0
    private(set) var speechLevel = 0.0
    private(set) var micLevel = 0.0

    // Mind and self
    /// Dee's inner state (26 parameters → one code).
    private(set) var mindSnapshot: MindSnapshot?
    /// Bumped whenever the Stance changes, so the face re-renders.
    private(set) var stanceVersion = 0
    private var selfDriver: SelfDriver?

    // Senses
    private(set) var cameraActive = false
    private(set) var someoneHere = false
    private(set) var isSpeaking = false
    private(set) var voiceReady = false
    private(set) var microphoneAllowed = true
    private var lastHeardPartialAt = Date.distantPast
    private var lastPartialForwarded = Date.distantPast
    private var absentSince: Date? = Date()
    private var asleepSince: Date?
    private var touch = TouchInterpreter()
    private var curiosity = CuriosityDirector()
    private var lastInitiativeAt = Date.distantPast

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

    /// How long nobody may be in view before Dee falls asleep, and how long she
    /// must sleep before the next visit counts as a new conversation.
    static let sleepAfter: TimeInterval = 180
    static let newConversationAfterSleeping: TimeInterval = 300

    // MARK: - Projection (face / voice from the one Stance)

    var faceInputs: FaceInputs {
        _ = stanceVersion
        var inputs: FaceInputs
        if let s = selfDriver?.stance {
            inputs = Projector.face(s, faceAt: lookAt, touchPoint: touchPoint)
            if let m = mindSnapshot?.mood, Projection.expression(s).idleDirector {
                inputs.mood = FaceMood(curiosity: m.curiosity, boredom: m.boredom, playfulness: m.playfulness,
                                       energy: m.energy, affection: m.affection, arousal: m.arousal)
            }
        } else {
            // Before the self store opens (first frames of launch).
            let tint = mindSnapshot.map { FaceColor($0.eyeColor.r, $0.eyeColor.g, $0.eyeColor.b) }
            inputs = FaceInputs(emotion: mindSnapshot?.emotion ?? .content, activity: .idle, lookAt: lookAt, tint: tint)
        }
        if sleeping { inputs.activity = .sleeping }
        if loadState != .ready, !sleeping { inputs.activity = .thinking }
        inputs.speechLevel = speechLevel
        inputs.micLevel = micLevel
        inputs.performance = performance
        return inputs
    }

    private var voiceStyle: VoiceStyle {
        if let s = selfDriver?.stance { return Projector.voice(s) }
        return VoiceStyle.forMood(emotion: mindSnapshot?.emotion ?? .content, age: mindSnapshot?.age, energy: mindSnapshot?.mood.energy ?? 0.8)
    }

    /// A physical reflex the body makes directly (a tapped eye blinks). Everything
    /// expressive goes through the Stance instead.
    private func perform(_ p: Performance) {
        performanceCounter += 1
        performance = PerformanceRequest(id: performanceCounter, performance: p)
    }

    /// Seconds since boot — the same clock as `UITouch.timestamp`.
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    // MARK: - The one entry point into the Cortex

    /// Steps the Cortex with a percept, re-projects the face, executes effects.
    private func sense(_ percept: Percept) {
        guard let driver = selfDriver, let snap = mindSnapshot else { return }
        let effects = driver.step(percept, mind: snap)
        afterStep()
        for e in effects { execute(e) }
    }

    private func afterStep() {
        guard let driver = selfDriver else { return }
        stanceVersion &+= 1
        performanceCounter += 1
        if let p = Projector.performance(driver.stance, id: performanceCounter) { performance = p }
    }

    private func execute(_ effect: Effect) {
        switch effect {
        case .reply(let userText, let cue):
            if let userText { perceive(.spoken(userText, prosody: nil)) } else { perceive(.cortexInitiative(cue: cue)) }
        case .initiative(let cue):
            perceive(.cortexInitiative(cue: cue))
        case .say(let line):
            voice.say(line, style: voiceStyle)
        case .stopSpeaking:
            stop()
        case .setPauseScale(let scale):
            voice.pauseScale = scale
        case .glanceNow(let side):
            if let s = DeeSense.CameraSide(rawValue: side.rawValue) { camera.glanceNow(s) }
        case .lookAround(let on):
            camera.lookAround = on
        case .appraise(let a):
            Task { await self.react(a, then: nil) }
        case .curiosity(let stimulus):
            curiosity.note(stimulus, at: Date())
        case .persist:
            break // batched inside SelfDriver
        case .remember(let fact, let person):
            guard let people else { break }
            Task { await people.store.remember(fact.text, category: fact.category, about: person, at: Date()) }
        case .reflect:
            Task { [weak self] in
                guard let self, let driver = self.selfDriver else { return }
                for e in await driver.flush() { self.execute(e) }
            }
        }
    }

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
        if let snap = mindSnapshot {
            selfDriver = await SelfDriver.open(memory: people?.store, snapshot: snap)
        }
        wirePeople()
        startMoodClock()
        startVoice()
        await startCamera()
        await loadIfNeeded()
    }

    func loadIfNeeded() async {
        guard loadState == .idle || { if case .failed = loadState { true } else { false } }() else { return }
        guard let url = ModelLocator.locate() else {
            loadState = .failed(ModelLocator.Problem.notFound.localizedDescription)
            return
        }
        do {
            try ModelLocator.checkMemory()
            loadState = .loading(0)
            let engine = try await LlamaEngine.load(.init(modelPath: url.path(percentEncoded: false))) { [weak self] p in
                Task { @MainActor in
                    if case .loading = self?.loadState { self?.loadState = .loading(p) }
                }
            }
            let agent = ConversationAgent(generator: engine, tools: memoryTools(), persona: persona)
            self.engine = engine
            self.agent = agent
            await startConversation(agent)
            loadState = .ready
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
        } catch {
            // A corrupt database must never brick Dee: move it aside (kept for
            // diagnosis, never deleted) and start a fresh one; in-memory as a last resort.
            let stamp = Int(Date().timeIntervalSince1970)
            for suffix in ["", "-wal", "-shm"] {
                let file = URL(fileURLWithPath: url.path(percentEncoded: false) + suffix)
                try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("corrupt-\(stamp)"))
            }
            mind = (try? Mind(databaseURL: url)) ?? (try? Mind(databaseURL: nil))
            if let mind { accept(await mind.tick(userPresent: someoneHere, asleep: false)) }
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
    @discardableResult
    private func accept(_ snap: MindSnapshot) -> Bool {
        if let current = mindSnapshot, snap.sequence < current.sequence { return false }
        mindSnapshot = snap
        return true
    }

    /// Mind first (feelings), then the Cortex (interpretation), per SELF.md §4.3.
    @discardableResult
    private func react(_ appraisal: Appraisal, then percept: Percept? = .tick) async -> MindSnapshot? {
        guard let mind else { return nil }
        let snap = await mind.react(appraisal)
        accept(snap)
        if let percept { sense(percept) }
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
            sense(.tick)
            updateListening()
        } else if backgroundedAt == nil {
            backgroundedAt = Date()
            voice.listeningEnabled = false
            voice.stopSpeaking()
            touch.cancelAll()
            touchPoint = nil
            accept(await mind.tick(userPresent: someoneHere, asleep: sleeping))
            // Tick writes are throttled; make sure nothing is lost if iOS ends the app.
            await mind.flush()
            if let driver = selfDriver { for e in await driver.flush() where !isPersist(e) { execute(e) } }
        }
    }

    private func isPersist(_ e: Effect) -> Bool { if case .persist = e { true } else { false } }

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
        voice.listeningEnabled = loadState == .ready && someoneHere && !sleeping && backgroundedAt == nil
    }

    private func handle(_ event: VoiceEvent) {
        switch event {
        case .permission(let mic, _):
            microphoneAllowed = mic
            if !mic {
                transcript.append(TranscriptItem(kind: .note, text: "Microphone access is off — Dee can't hear you. Turn it on in Settings › Dee."))
            }
        case .ready:
            voiceReady = true
            updateListening()
        case .listening:
            break
        case .partial(let text):
            heard = text
            lastHeardPartialAt = Date()
            if sleeping { sleeping = false; asleepSince = nil }
            // Forward partials at ≤ 2 Hz: the listening face previews her reaction.
            if Date().timeIntervalSince(lastPartialForwarded) >= 0.5 {
                lastPartialForwarded = Date()
                sense(.partial(text))
            }
        case .pause(let turnEnd, let hesitation):
            sense(.pause(turnEnd: turnEnd, hesitation: hesitation))
        case .heard(let utterance):
            lastHeardPartialAt = .distantPast
            let p = utterance.prosody
            let prosody = Prosody(loudnessDB: p.loudnessDB, peakDB: p.peakDB, speechRate: p.speechRate, pitchVariability: p.pitchVariability)
            pendingHeardDuration = utterance.duration
            perceive(.spoken(utterance.text, prosody: prosody))
        case .sound(let sound):
            heardSound(sound)
        case .micLevel(let level):
            micLevel = level
        case .speakingStarted:
            isSpeaking = true
            sense(.speakingStarted)
        case .speechLevel(let level):
            speechLevel = level
        case .speakingFinished:
            isSpeaking = false
            speechLevel = 0
            curiosity.note(.deeSpoke, at: Date())
            sense(.speakingFinished)
        case .bargeIn:
            // The user talked over Dee: stop and listen.
            stop()
            sense(.bargeIn)
        case .error(let message):
            transcript.append(TranscriptItem(kind: .note, text: "Voice: \(message)"))
        }
    }

    private var pendingHeardDuration = 0.0

    private func heardSound(_ sound: HeardSound) {
        let loudness = max(0, min(1, (sound.loudnessDB + 50) / 40))
        // Social sounds are never "unexpected", but they matter most: laughter is
        // contagious, crying gets concern, applause delights.
        if sound.kind.isSocial {
            let quietMoment = !isSpeaking && !isResponding && !voice.userIsSpeaking
            if sound.kind == .laughter, quietMoment, !sleeping {
                voice.laugh(intensity: 0.5, age: mindSnapshot?.age, energy: mindSnapshot?.mood.energy ?? 0.7)
            }
            Task { await react(.sound(label: sound.label, unexpected: false, loudness: loudness), then: .sound(label: sound.label, unexpected: false)) }
            return
        }
        guard sound.isUnexpected else { return }
        curiosity.noteSound(sound.label, unexpected: true, loudness: loudness, at: Date())
        if sleeping {
            // Only an alarming or loud noise wakes a sleeping Dee (not every creak).
            let asleepFor = asleepSince.map { Date().timeIntervalSince($0) }
            guard loudness > 0.6 || CuriosityDirector.callsOutUnattended(sound: sound.label, loudness: loudness, asleepFor: asleepFor) else {
                Task { await react(.sound(label: sound.label, unexpected: true, loudness: loudness * 0.5), then: nil) }
                return
            }
            sleeping = false
            asleepSince = nil
        }
        Task { await react(.sound(label: sound.label, unexpected: true, loudness: loudness), then: .sound(label: sound.label, unexpected: true)) }
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
        if sleeping, case .tap = gesture {} else if sleeping {
            sleeping = false
            asleepSince = nil
        }
        let kind: Touch
        let line: String?
        var at: SIMD2<Double>? = touchPoint
        switch gesture {
        case .tap(let p):
            kind = .tap
            line = nil
            at = p
            // A tapped eye blinks — a physical reflex, not an expression.
            if abs(p.y - 0.47) < 0.12, abs(abs(p.x - 0.5) - 0.19) < 0.12 {
                perform(p.x < 0.5 ? .blinkLeft : .blinkRight)
            }
        case .doubleTap(let p):
            kind = .doubleTap
            line = nil
            at = p
        case .pet(let duration, let gentleness):
            kind = .pet(gentleness: gentleness, seconds: duration)
            line = duration > 3 && gentleness > 0.5 ? "(Your human is gently stroking you.)" : nil
        case .hold(let duration):
            kind = .hold(seconds: duration)
            line = duration > 2 ? "(Your human is holding you gently, like a little hug.)" : nil
        case .pokes(_, _, let total):
            kind = .pokes(count: total)
            line = total >= 6 ? "(Your human keeps poking you.)" : nil
        case .slap(let force):
            kind = .slap(force: force)
            line = force > 0.5 ? "(Your human just smacked your screen.)" : nil
        case .tickle(let duration):
            kind = .tickle(seconds: duration)
            line = duration > 1.5 ? "(Your human is tickling you!)" : nil
            if duration > 0.6, !isSpeaking { voice.laugh(intensity: 0.7, age: mindSnapshot?.age, energy: mindSnapshot?.mood.energy ?? 0.7) }
        }
        let gentle: Bool = switch gesture {
        case .pet, .hold, .tap, .doubleTap, .tickle: true
        default: false
        }
        let appraisal = Appraisal.touch(kind)
        let percept = Percept.touch(kind: kind.word, gentle: gentle, at: at)
        if let line, !isResponding, !isSpeaking, loadState == .ready {
            // Answered right now — don't also let curiosity bring it up again.
            Task { await react(appraisal, then: percept) }
            perceive(.event(appraisal, line: line), alreadyAppraised: true)
        } else {
            curiosity.note(.touched(kind.word), at: Date())
            Task { await react(appraisal, then: percept) }
        }
    }

    // MARK: - People (DeeMemory)

    private func wirePeople() {
        guard let people else { return }
        people.onMerged = { [weak self] from, into in
            guard let self, let driver = self.selfDriver, let memory = self.people?.store else { return }
            Task { await driver.merge(from: from, into: into, memory: memory) }
        }
        people.onDiscarded = { [weak self] id in
            guard let self, let memory = self.people?.store else { return }
            if let driver = self.selfDriver {
                Task { await driver.forgetPerson(id, memory: memory, placeholder: true) }
            } else {
                Task { await memory.discardPlaceholder(id) }
            }
        }
        people.onCurrentChanged = { [weak self] person in
            guard let self else { return }
            let id = person.flatMap { $0.isPlaceholder ? nil : $0.id }
            Task {
                // Shared memories first, so the very next turn can recall them.
                if let id, let driver = self.selfDriver { await driver.prefetch(person: id) }
                // The People layer has already matched the face: a confirmed identity.
                self.sense(.identified(id, distance: 0))
            }
        }
    }

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
        case .nameConflict(let heard, let thought):
            pendingNotes.append("(You thought this was \(thought), but they said they're \(heard). Gently check who you're talking to.)")
        case .askSamePerson(let name):
            pendingNotes.append("(You've met someone called \(name) before. Ask if it was them.)")
        case .introduced(let names):
            pendingNotes.append("(They're introducing \(names.joined(separator: " and ")) to you. Say hello to them.)")
        case .wellbeingConcern:
            pendingNotes.append("(They may be going through something painful. Be warm and gentle; encourage them to reach out to someone they trust or a local crisis line.)")
        case .askWhich(let facts):
            pendingNotes.append("(Ask gently which one they mean: \(facts.prefix(3).joined(separator: "; ")).)")
        }
    }

    /// The persona for a new conversation: who Dee is talking to, what she
    /// remembers about them, and her self block (frozen for the conversation).
    private func currentPersona() async -> Persona {
        var p = persona
        p.userName = people?.currentName
        p.memories = Array((await people?.memories() ?? []).prefix(6))
        if let driver = selfDriver {
            p = driver.persona(p, person: people?.currentName == nil ? nil : people?.currentID)
        }
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
            sense(.presence(arrived: true))
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
            if sleeping {
                sleeping = false
                asleepSince = nil
                if sleptLongEnough { newConversation() }
            }
            curiosity.note(.userArrived, at: Date())
            updateListening()
            sense(.presence(arrived: true))
        case .presence(.left):
            someoneHere = false
            absentSince = Date()
            updateListening()
            sense(.faceLost)
            sense(.presence(arrived: false))
        case .look(let point):
            lookAt = point
        case .gesture(let gesture):
            handle(gesture)
        case .head(let yaw, let pitch):
            sense(.head(yaw: yaw, pitch: pitch))
        case .faces(let crops):
            recognize(crops)
        case .sight(let report):
            let camera: DeeSelf.CameraSide = report.camera == .back ? .back : .front
            let percept = Percept.sight(camera: camera, things: report.things.map(\.label), novel: report.novel.map(\.label))
            guard !report.novel.isEmpty else { sense(percept); return }
            let novelty = min(1, (report.novel.map(\.confidence).max() ?? 0.5) * 0.6 + Double(report.novel.count) * 0.15)
            curiosity.noteSight(report.novel.map(\.label), camera: report.camera.rawValue, novelty: novelty, at: Date())
            Task { await react(.sight(novelty: min(1, Double(report.novel.count) * 0.4)), then: percept) }
        }
    }

    private func handle(_ gesture: Gesture) {
        switch gesture {
        case .wave:
            if sleeping { sleeping = false; asleepSince = nil }
            if !isResponding, !isSpeaking, loadState == .ready {
                Task { await react(.wave, then: .gesture("wave")) }
                perceive(.event(.wave, line: "(The user waves at you.)"), alreadyAppraised: true)
            } else {
                Task { await react(.wave, then: .gesture("wave")) }
            }
        case .palm:
            // "Hush": stop talking now.
            stop()
            sense(.gesture("palm"))
        case .thumbsUp:
            Task { await react(.thumbsUp, then: .gesture("thumbsUp")) }
        }
    }

    /// 2 Hz heartbeat: Cortex ticks, mind ticks, sleep, curiosity.
    private func startMoodClock() {
        moodClock?.cancel()
        moodClock = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self else { return }
                ticks += 1
                guard self.backgroundedAt == nil else { continue }
                if ticks % 6 == 0, let mind = self.mind {
                    self.accept(await mind.tick(userPresent: self.someoneHere, asleep: self.sleeping))
                }
                self.sense(.tick)
                self.curiosity.asleepSince = self.asleepSince
                if ticks % 4 == 0 { self.considerInitiative() }
                guard !self.isResponding, !self.isSpeaking, let since = self.absentSince else { continue }
                if Date().timeIntervalSince(since) >= Self.sleepAfter, !self.sleeping {
                    self.people?.newSession()
                    self.sleeping = true
                    self.asleepSince = Date()
                }
            }
        }
    }

    /// The curiosity director covers novel sights, odd noises and greetings; the
    /// Cortex's IntentionBoard covers follow-ups and her own intentions. They share
    /// one pacing clock so Dee never double-books a moment.
    private func considerInitiative() {
        guard loadState == .ready, backgroundedAt == nil, !sleeping, let snap = mindSnapshot else { return }
        guard Date().timeIntervalSince(lastInitiativeAt) > 20 else { return }
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
            voice.say("Okay! Fresh start.", style: voiceStyle)
            return true
        }
        if has(["stop", "stop talking", "be quiet", "shush", "shh", "hush", "quiet"]) {
            stop()
            return true
        }
        if has(["go to sleep", "goodnight dee", "good night dee", "time to sleep", "nap time"]) {
            stop()
            voice.say("Okay. Goodnight!", style: VoiceStyle.forMood(emotion: .sleepy, age: mindSnapshot?.age, energy: 0.2))
            perform(.yawn)
            Task {
                try? await Task.sleep(for: .seconds(2))
                self.sleeping = true
                self.asleepSince = Date()
            }
            return true
        }
        return false
    }

    func perceive(_ stimulus: Stimulus, alreadyAppraised: Bool = false) {
        let text: String
        var appraisal: Appraisal?
        var prosody: Prosody?
        var shouldAppraise = false
        var isInitiative = false
        var readyCue: String?
        switch stimulus {
        case .spoken(let raw, let p):
            text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            heard = text
            transcript.append(TranscriptItem(kind: .user, text: text))
            curiosity.note(.userSpoke, at: Date())
            if sleeping { sleeping = false; asleepSince = nil }
            if command(in: text) { return }
            prosody = p
            shouldAppraise = true
        case .event(let a, let line):
            text = line
            appraisal = alreadyAppraised ? nil : a
        case .initiative(let line):
            text = line
            isInitiative = true
        case .cortexInitiative(let cue):
            text = ""
            readyCue = cue
            isInitiative = true
        }
        guard let agent, loadState == .ready else {
            if shouldAppraise { Task { await self.hear(text, prosody: prosody) } }
            return
        }
        if isResponding || isSpeaking {
            // Busy: still let the words land emotionally, but don't start a new turn
            // (barge-in handles interruptions).
            if shouldAppraise { Task { await self.hear(text, prosody: prosody) } }
            else if let appraisal { Task { await self.react(appraisal) } }
            return
        }
        if isInitiative, voice.userIsSpeaking { return }
        if isInitiative { lastInitiativeAt = Date() }
        isResponding = true
        caption = ""
        if asleepSince != nil { asleepSince = nil }

        responseTask = Task {
            if shouldAppraise, let people, let event = await people.heard(text) { handle(event) }
            if shouldAppraise {
                await hear(text, prosody: prosody)
            } else if let appraisal {
                await react(appraisal)
            }
            // The cue: the Cortex's <dee_state> (mood sentence + its notes), plus any
            // identity/care notes from the people layer.
            var cue: String?
            if let readyCue {
                cue = readyCue
            } else if let driver = selfDriver {
                sense(.promptSubmitted)
                let (state, fx) = driver.cue()
                for e in fx { execute(e) }
                cue = state
            } else {
                cue = mindSnapshot?.cue
            }
            if readyCue != nil { sense(.promptSubmitted) }
            if !pendingNotes.isEmpty {
                cue = ([cue].compactMap { $0 } + pendingNotes.prefix(2)).joined(separator: "\n")
                pendingNotes.removeAll()
            }
            await run(agent: agent, text: text, cue: cue, initiative: isInitiative)
        }
    }

    /// The user's words: appraised by the mind (what + how), then interpreted by
    /// the Cortex. The face starts reacting before the model has said a word.
    private func hear(_ text: String, prosody: Prosody?) async {
        guard let mind else { return }
        let (appraisal, snap) = await mind.hear(text, prosody: prosody)
        accept(snap)
        let loudness = prosody.map { ($0.loudnessDB + 32) / 12 } ?? 0
        sense(.heard(text: text, durationS: pendingHeardDuration, loudnessVsBaseline: loudness, appraisal: appraisal))
        pendingHeardDuration = 0
    }

    /// - Parameter initiative: Dee spoke up on her own — her words wait politely if
    ///   the user starts talking meanwhile (a reply to the user never waits).
    private func run(agent: ConversationAgent, text: String, cue: String?, initiative: Bool) async {
        var deeIndex: Int?
        var sentence = ""
        var pendingTag: Emotion?
        var full = ""
        func deeItem() -> Int {
            if let deeIndex { return deeIndex }
            transcript.append(TranscriptItem(kind: .dee, text: "", isStreaming: true))
            deeIndex = transcript.count - 1
            return deeIndex!
        }
        /// Each finished sentence goes to the Cortex (tag reconciliation, floor).
        func flushSentence(force: Bool) {
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty || pendingTag != nil else { return }
            guard force || trimmed.last.map({ ".!?…".contains($0) }) == true else { return }
            sense(.deeSaid(tag: pendingTag, sentence: trimmed))
            pendingTag = nil
            sentence = ""
        }
        do {
            for try await event in agent.respond(to: text, state: cue) {
                switch event {
                case .thinkingModeChanged(let on):
                    thinkingMode = on
                    transcript.append(TranscriptItem(kind: .note, text: on ? "Thinking mode on for this conversation" : "Thinking mode off"))
                case .generationStarted:
                    deeIndex = nil
                case .reasoning(let s):
                    transcript[deeItem()].reasoning += s
                case .content(let s):
                    let i = deeItem()
                    if transcript[i].text.isEmpty { caption = "" }
                    transcript[i].text += s
                    caption += s
                    full += s
                    sentence += s
                    flushSentence(force: false)
                    voice.stream(s, style: voiceStyle, deferWhileUserSpeaks: initiative)
                case .emotion(let e):
                    // The model's tag goes through the Cortex, which may reconcile it
                    // with how Dee actually feels (she can't beam love while hurt —
                    // unless a joke just made her laugh).
                    flushSentence(force: true)
                    pendingTag = e
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
        }
        flushSentence(force: true)
        sense(.deeTurnFinished(text: full))
        voice.endStream()
        for i in transcript.indices where transcript[i].isStreaming { transcript[i].isStreaming = false }
        isResponding = false
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
        Task { await self.startConversation(agent) }
    }

    private func startConversation(_ agent: ConversationAgent) async {
        sense(.conversationStarted(Date()))
        await agent.newConversation(persona: await currentPersona())
    }

    func toggleThinking() {
        guard let agent else { return }
        thinkingMode.toggle()
        let on = thinkingMode
        Task { await agent.setThinking(on) }
    }
}
