import DeeCore
import DeeFace
import DeeLLM
import DeeMind
import DeeSense
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

/// The app's single source of truth: model lifecycle, the conversation, what Dee
/// sees through the camera, and what its face should be doing.
@Observable @MainActor
final class DeeModel {
    enum LoadState: Equatable {
        case idle
        case loading(Double)
        case ready
        case failed(String)
    }

    // Brain
    private(set) var loadState: LoadState = .idle
    private(set) var transcript: [TranscriptItem] = []
    private(set) var thinkingMode = false
    private(set) var isResponding = false
    private(set) var statusLine = ""
    /// What Dee is saying right now (shown as a caption).
    private(set) var caption = ""
    /// What Dee last heard (shown small, above the caption).
    private(set) var heard = ""

    // Face
    private(set) var emotion: Emotion = .neutral
    private(set) var activity: FaceActivity = .idle {
        // A sleeping Dee only needs to notice someone arriving: let the camera idle.
        didSet { if (oldValue == .sleeping) != (activity == .sleeping) { camera.isDozing = activity == .sleeping } }
    }
    private(set) var lookAt: SIMD2<Double>?

    // Mind
    /// Dee's inner state (26 parameters → one code); drives eye colour and mood.
    private(set) var mindSnapshot: MindSnapshot?
    /// Expression chosen by the language model while it talks; falls back to the
    /// mind's dominant emotion a few seconds after Dee finishes.
    private var spokenEmotion: Emotion?
    private var spokenEmotionUntil = Date.distantPast

    // Senses
    private(set) var cameraActive = false
    private(set) var someoneHere = false
    private var absentSince: Date? = Date()
    private var asleepSince: Date?

    private var engine: LlamaEngine?
    private var agent: ConversationAgent?
    private var responseTask: Task<Void, Never>?
    private var persona = Persona()
    private let camera = CameraSense()
    private var moodClock: Task<Void, Never>?
    private var mind: Mind?

    /// How long nobody may be in view before Dee gets drowsy / falls asleep, and how
    /// long it must sleep before the next visit counts as a new conversation.
    static let drowsyAfter: TimeInterval = 30
    static let sleepAfter: TimeInterval = 120
    static let newConversationAfterSleeping: TimeInterval = 300

    var faceInputs: FaceInputs {
        let tint = mindSnapshot.map { FaceColor($0.eyeColor.r, $0.eyeColor.g, $0.eyeColor.b) }
        return FaceInputs(emotion: emotion, activity: activity, lookAt: lookAt, tint: tint)
    }

    /// The face shows the model's chosen expression while speaking (and briefly
    /// after), otherwise whatever the mind feels most.
    private func refreshEmotion() {
        if let spoken = spokenEmotion, isResponding || Date() < spokenEmotionUntil {
            emotion = spoken
        } else if let snap = mindSnapshot, activity != .sleeping {
            spokenEmotion = nil
            emotion = snap.emotion
        }
    }

    // MARK: - Lifecycle

    private var started = false
    private var senseTask: Task<Void, Never>?
    /// When the app went to the background (time away counts as the user being absent).
    private var backgroundedAt: Date?

    func start() async {
        // `.task` can re-run (scene reconnects); everything here must happen once.
        guard !started else { return }
        started = true
        await openMind()
        startMoodClock()
        await startCamera()
        await loadIfNeeded()
    }

    func loadIfNeeded() async {
        guard loadState == .idle || { if case .failed = loadState { true } else { false } }() else { return }
        guard let url = ModelLocator.locate() else {
            loadState = .failed(ModelLocator.Problem.notFound.localizedDescription)
            emotion = .confused
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
            let agent = ConversationAgent(generator: engine, tools: ToolRegistry(), persona: persona)
            await agent.newConversation(persona: persona)
            self.engine = engine
            self.agent = agent
            loadState = .ready
            activity = .idle
            emotion = .happy
            statusLine = engine.modelDescription
            #if DEBUG
            // `-DeeAutoPrompt "text"`: send a message on launch (screenshots, UI tests).
            if let auto = UserDefaults.standard.string(forKey: "DeeAutoPrompt"), !auto.isEmpty {
                send(auto)
            }
            #endif
        } catch {
            loadState = .failed(error.localizedDescription)
            activity = .idle
            emotion = .sad
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
        // age — otherwise turning ageing off would snap an aged Dee back to its
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

    private func appraise(_ text: String) async -> String? {
        guard let mind else { return nil }
        let (_, snap) = await mind.hear(text, prosody: nil)
        accept(snap)
        // React on the face immediately, before the model has said a word.
        if !isResponding || activity == .thinking { emotion = snap.emotion }
        return snap.cue
    }

    /// Keeps only the newest snapshot: a slow tick finishing after a newer `hear`
    /// must not paint the eyes with stale feelings.
    private func accept(_ snap: MindSnapshot) {
        if let current = mindSnapshot, snap.sequence < current.sequence { return }
        mindSnapshot = snap
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
        accept(snap)
        return snap
    }

    // MARK: - App lifecycle

    /// Called on scene-phase changes. Time spent in the background counts as the
    /// user being away (not as them sitting silently in front of Dee).
    func sceneBecame(active: Bool) async {
        guard let mind else { return }
        if active {
            // Time in the background was time without the user.
            let away = backgroundedAt
            backgroundedAt = nil
            accept(await mind.catchUp(lastSeenUserAt: someoneHere ? away : nil))
            await applyAgeSettings()
            refreshEmotion()
        } else if backgroundedAt == nil {
            backgroundedAt = Date()
            accept(await mind.tick(userPresent: someoneHere, asleep: activity == .sleeping))
            // Tick writes are throttled; make sure nothing is lost if iOS ends the app.
            await mind.flush()
        }
    }

    // MARK: - Camera: presence, gaze, gestures

    private func startCamera() async {
        guard CameraSense.isAvailable else {
            // Simulator / no camera: behave as if someone is always there.
            someoneHere = true
            absentSince = nil
            return
        }
        do {
            try await camera.start()
            cameraActive = true
        } catch {
            someoneHere = true
            absentSince = nil
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
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    if self.emotion == .surprised { self.flash(.happy) }
                }
                if sleptLongEnough { newConversation() }
            } else if emotion == .sleepy {
                flash(.happy)
            }
        case .presence(.left):
            someoneHere = false
            absentSince = Date()
        case .look(let point):
            lookAt = point
        case .gesture(let gesture):
            handle(gesture)
        }
    }

    private func handle(_ gesture: Gesture) {
        switch gesture {
        case .wave:
            if activity == .sleeping { activity = .idle; asleepSince = nil }
            flash(.joy)
            if !isResponding, loadState == .ready {
                respond(to: "(The user waves at you.)", show: false, gesture: .wave)
            } else {
                Task { await react(.wave) }
            }
        case .palm:
            // "Hush": stop talking now.
            if isResponding { stop() }
            flash(.neutral)
        case .thumbsUp:
            flash(.happy)
            Task { await react(.thumbsUp) }
        }
    }

    /// Drowsiness and sleep when nobody's around.
    private func startMoodClock() {
        moodClock?.cancel()
        moodClock = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                ticks += 1
                if ticks % 3 == 0, self.backgroundedAt == nil, let mind = self.mind {
                    self.accept(await mind.tick(userPresent: self.someoneHere, asleep: self.activity == .sleeping))
                    if !self.isResponding { self.refreshEmotion() }
                }
                guard !self.isResponding, let since = self.absentSince else { continue }
                let away = Date().timeIntervalSince(since)
                if away >= Self.sleepAfter, self.activity != .sleeping {
                    self.activity = .sleeping
                    self.asleepSince = Date()
                } else if away >= Self.drowsyAfter, self.activity == .idle, self.emotion != .sleepy {
                    self.emotion = .sleepy
                }
            }
        }
    }

    // MARK: - Conversation

    /// Debug-only text entry (the shipping app is voice and camera only).
    func send(_ raw: String) {
        respond(to: raw, show: true)
    }

    private func respond(to raw: String, show: Bool, gesture: Appraisal? = nil) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let agent, !isResponding else { return }
        if show {
            transcript.append(TranscriptItem(kind: .user, text: text))
            heard = text
        }
        isResponding = true
        activity = .thinking
        caption = ""
        if asleepSince != nil { asleepSince = nil }

        responseTask = Task {
            // Gestures arrive pre-appraised; only real utterances go through the
            // appraiser. Either way the cue reflects the reaction just applied.
            let cue: String?
            if let gesture {
                cue = await react(gesture)?.cue
            } else {
                cue = await appraise(text)
            }
            var deeIndex: Int?
            @MainActor func deeItem() -> Int {
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
                    case .generationStarted:
                        deeIndex = nil
                        activity = .thinking
                    case .reasoning(let s):
                        transcript[deeItem()].reasoning += s
                    case .content(let s):
                        let i = deeItem()
                        if transcript[i].text.isEmpty {
                            activity = .speaking
                            caption = ""
                        }
                        transcript[i].text += s
                        caption += s
                    case .emotion(let e):
                        spokenEmotion = e
                        emotion = e
                    case .toolCall(let call):
                        transcript.append(TranscriptItem(kind: .tool, text: "⚙︎ \(call.name)"))
                    case .toolResult, .reasoningBudgetExhausted, .turnCompleted:
                        break
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
                emotion = .confused
            }
            for i in transcript.indices where transcript[i].isStreaming { transcript[i].isStreaming = false }
            isResponding = false
            activity = .idle
            spokenEmotionUntil = Date().addingTimeInterval(4)
            if let engine {
                statusLine = String(format: "%@ · %.0f tok/s", engine.modelDescription, engine.stats.generateTokensPerSecond)
            }
        }
    }

    func stop() {
        guard let agent else { return }
        Task { await agent.cancel() }
    }

    func newConversation() {
        guard let agent, !isResponding else { return }
        transcript.removeAll()
        thinkingMode = false
        caption = ""
        heard = ""
        Task { await agent.newConversation(persona: persona) }
    }

    func toggleThinking() {
        guard let agent else { return }
        thinkingMode.toggle()
        let on = thinkingMode
        Task { await agent.setThinking(on) }
    }
}
