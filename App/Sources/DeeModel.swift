import DeeBrain
import DeeCore
import DeeFace
import DeeLocal
import DeeMemory
import DeeMind
import DeeRealtime
import DeeSelf
import DeeSense
import DeeVoice
import DeeWake
import Foundation
import Observation
import UIKit

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
/// Every stimulus — speech, pauses, touch, gestures, sights, sounds, who's there,
/// her own sentences — becomes a `Percept` for the Cortex (DeeSelf), which keeps one
/// shared interpretation of the moment (`Stance`). The face, the voice style, the
/// gaze, the little performances and the Dee DNA sent with every response are all
/// projected from that one state, so they can never disagree.
///
/// v0.6: her ears, thinking and voice are one realtime session (`CloudVoice`) — OpenAI
/// gpt-realtime (mode 1) or the in-process cascade of a LAN brain with OpenAI or LAN /
/// on-device speech (modes 2/3, `DeeLocal`) — driven by `RealtimeBrain` (DeeBrain).
/// She is DORMANT until her wake phrase is heard ON THIS iPHONE (`WakeController` +
/// the on-device ear; never a server transcript), a tap, or the opt-in greeting: no
/// socket, no request, no audio leaves the phone before that (W1/W2). The brain decides when she answers spoken
/// turns and calls back here (`BrainHost`) for the words' normal path (commands,
/// "is this for me?", people, Mind, Cortex) and for the DNA inputs. Initiatives,
/// event lines and typed text still start here (`startTurn` → `brain.respond`).
/// Offline she stays alive — eyes, touch, camera — with a visible "no connection".
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
    /// What is wrong with her cloud voice, in words for the status chip (Release too).
    var cloudStatus: CloudStatus? { CloudStatus(voiceProblem) }
    /// Why her provider can't be built (no key, no server…), in words for the chip.
    private(set) var providerProblem: String?
    /// The wake ear's problem (permission, assets, too warm) — she stays dormant; a tap still wakes her.
    private(set) var earProblem: String?
    /// A short notice next to the chip (a pasted key was refused, a setting needs a relaunch).
    private(set) var notice: String?
    /// The one-time AI-voice disclosure, shown while she says it.
    private(set) var disclosure: String?
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
            if !sleeping { lastWokeAt = Date() }
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
    /// What is wrong with her ears or voice, for the screen (audit C11): permission
    /// off, the speech model still downloading, recognition or audio failing.
    private(set) var voiceProblem: VoiceProblem?
    /// Her ears are the cloud voice: no on-device speech recognition to wait for.
    private var voiceHealth: VoiceHealth = {
        var health = VoiceHealth()
        health.onDeviceSpeech = false
        return health
    }()
    /// The user's turn as her ears saw it (who holds the floor, audit C3).
    private var userFloor = UserFloor()
    private var lastPartialForwarded = Date.distantPast
    private var absentSince: Date? = Date()
    private var asleepSince: Date?
    private var touch = TouchInterpreter()
    private var curiosity = CuriosityDirector()
    private var lastInitiativeAt = Date.distantPast

    /// Whatever writes her replies: the cloud realtime brain (`makeReplyEngine`).
    /// Without a key or a connection Dee is silent but alive: she sees, hears sounds,
    /// feels and reacts with her face.
    private var brain: (any ReplyEngine)?
    private var realtime: RealtimeBrain?
    private var responseTask: Task<Void, Never>?
    private var persona = Persona()
    private let camera = CameraSense()
    /// Her voice, model and "share memories" (from the provider config and prefs).
    private var settings: CloudSettings
    /// In-app preferences (no secrets) and the Keychain.
    let prefs = DeePrefs()
    let secrets = KeychainSecrets()
    /// Her ears and voice for the current provider: rebuilt only while DORMANT
    /// (`applyProvider`). It never answers by itself; the brain asks it to.
    private var stack: VoiceStack
    private var voice: CloudVoice { stack.voice }
    /// The conversation window (DORMANT ⇄ CONVERSATION) and the on-device wake ear.
    let wake: WakeController
    private var wakeEar: (any WakeEar)?
    private var awakeTask: Task<Void, Never>?
    private var problemTask: Task<Void, Never>?
    /// "Change your wake phrase to X" waiting for her confirmation.
    private var phraseChange = WakePhraseChange()
    /// Speak-first: one greeting per arrival.
    private var greetedThisArrival = false
    private var pendingGreeting: String?
    /// The eyes' "not listening" look (every → dormant) and the brief perk-up.
    private(set) var listeningOff = true
    private var perkedAt: Date?
    private var lastActivityAt = Date()
    /// The settings sheet was asked for (two-finger hold, the chip).
    private(set) var settingsRequested = false
    /// The session's current speech speed (mood), so it is only updated on a change.
    private var sessionSpeed = 1.0
    /// For the DNA (§1.8): the last touch and when she last woke.
    private var lastTouch: TouchInput?
    private var lastWokeAt: Date?
    /// The Mind's voice baseline, refreshed after each heard turn.
    private var baseline = Appraiser.VoiceBaseline()
    private var dailyCache: (at: Date, days: [DNADay])?
    /// The notes a Cortex initiative issued (its aim), for that initiative's DNA.
    private var initiativeNotes: [Note]?
    /// The spoken AI-voice disclosure is being tried right now.
    private var disclosing = false
    private var moodClock: Task<Void, Never>?
    private var touchClock: Task<Void, Never>?
    private var mind: Mind?
    private var people: People?
    /// Extra stage-direction notes for the next turn's cue (identity checks, care).
    private var pendingNotes: [String] = []

    // Turns (audit C1–C3, C8, C9)
    /// When someone last engaged Dee: in view, or spoke to her by name. She answers
    /// whatever she hears until `engagedGrace` after that; later only speech that
    /// addresses her ("Dee, …", "wake up"), so a TV or people talking to each other
    /// get no answers. Listening itself never depends on the face (C1).
    private var lastEngagedAt = Date()
    /// Dee's current (or last) reply — how much of it was heard, whether it gives
    /// way to the user — and the user's words carried over from a withdrawn turn
    /// (C2: "Hi Dee." … "How was your day?" are answered together).
    private var ledger = TurnLedger()
    /// The brain is being brought in line with a stopped reply, or is starting a new
    /// conversation; the next turn waits.
    private var settling: Task<Void, Never>?
    /// Words that arrived while a reply was still being prepared or cut short; they
    /// start the next turn as soon as that one has wound down (C2: never dropped).
    private var queuedUtterance: QueuedUtterance?
    /// "Start over" arrived mid-reply: do it once the turn has wound down.
    private var freshStartPending = false
    /// When Dee was last stopped (barge-in, hush): "stop" right after is a command.
    private var lastStoppedAt = Date.distantPast

    init() {
        let prefs = DeePrefs()
        let config = prefs.providerConfig
        settings = CloudSettings(voice: config?.voice ?? "marin", model: config?.openAIModel ?? "gpt-realtime-2.1-mini",
                                 shareMemories: prefs.shareMemories)
        // Building the stack makes no request: everything waits for a window.
        stack = VoiceStack.make(config, secrets: KeychainSecrets())
        wake = WakeController(phrase: prefs.wakePhrase, ear: nil, mode: config?.mode.rawValue ?? "none",
                              usage: prefs.usage)
        providerProblem = stack.issue?.message
        wake.persistUsage = { [prefs] u in prefs.usage = u }
    }

    /// How long nobody may be in view before Dee falls asleep, and how long she
    /// must sleep before the next visit counts as a new conversation.
    static let sleepAfter: TimeInterval = 180
    static let newConversationAfterSleeping: TimeInterval = 300
    /// How long after the last face (or her name) Dee still answers anything she hears.
    static let engagedGrace: TimeInterval = 60

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
        // DORMANT: a distinct "not listening" look (soft, a little lower lids), dimmer
        // after two minutes without anything happening; the perk-up for a candidate.
        if listeningOff, !sleeping, loadState == .ready {
            inputs.lidSoften = max(inputs.lidSoften, dimmed ? 0.45 : 0.18)
            if dimmed { inputs.tint = (inputs.tint ?? FaceColor(0.5, 0.9, 1)).scaled(0.6) }
        }
        if let perkedAt, Date().timeIntervalSince(perkedAt) < 0.8 { inputs.readyFace = max(inputs.readyFace, 0.7) }
        if let status = cloudStatus, status.cloudOff, !sleeping {
            // No cloud voice: a quieter, slightly puzzled look (her eyes, touch and
            // camera stay alive; only her words are away).
            inputs.lidSoften = max(inputs.lidSoften, 0.3)
            inputs.tilt = inputs.tilt == 0 ? 0.18 : inputs.tilt
            inputs.tint = FaceColor(0.55, 0.62, 0.72)
        }
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
        // Her speaking speed follows her mood (the session applies it between turns).
        let speed = voiceStyle.sessionSpeed
        if abs(speed - sessionSpeed) >= 0.04 {
            sessionSpeed = speed
            Task { [voice] in await voice.session.updateSession(speed: speed) }
        }
    }

    private func execute(_ effect: Effect) {
        switch effect {
        case .reply(let userText, let cue):
            if let userText { perceive(.spoken(userText, prosody: nil)) } else { perceive(.cortexInitiative(cue: cue)) }
        case .initiative(let cue):
            // The aim was issued into the Stance on this very step; the next steps
            // reset `stance.notes`, so the DNA gets these.
            initiativeNotes = selfDriver?.stance.notes
            perceive(.cortexInitiative(cue: cue))
        case .say(let line):
            // Canned lines (the sorry line, …) never start over the user: speaking
            // would close their turn mid-thought (audit C3).
            guard !userHoldsFloor else {
                transcript.append(TranscriptItem(kind: .note, text: "Held back (the user has the floor): \(line)"))
                break
            }
            sayAside(line, style: voiceStyle)
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
        wake.host = self
        // The brain configures the session (instructions, tools) before it connects —
        // which happens only when a window opens.
        await startStack()
        await startWakeEar()
        await startCamera()
        await loadIfNeeded()
        UIApplication.shared.isIdleTimerDisabled = true
    }

    /// The brain and voice of the current stack (dormant: mic + graph only).
    private func startStack() async {
        let realtime = makeReplyEngine()
        self.realtime = realtime
        self.brain = realtime
        await realtime.start()
        startVoice()
        watchAwakeStates()
        watchProviderProblems()
        if let ear = wakeEar { attach(ear) }
    }

    /// A cascaded part failing (hearing, chat, voice): said in words, never a fallback.
    private func watchProviderProblems() {
        problemTask?.cancel()
        guard let problems = stack.problems else { return }
        problemTask = Task { [weak self] in
            for await issue in problems {
                guard let self else { return }
                self.show(notice: issue.message)
            }
        }
    }

    /// Apple on-device recognition on the existing mic tap (VPIO stays on). The only
    /// thing that may wake her by voice (W1).
    private func startWakeEar() async {
        let ear = OnDeviceWakeEar()
        wakeEar = ear
        attach(ear)
        wake.ear = ear
        await wake.start()
    }

    private func attach(_ ear: any WakeEar) {
        voice.addMicSink { pcm, frame in ear.consume(pcm, captureFrame24k: frame) }
    }

    /// The voice's connection state → the window (connected / failed).
    private func watchAwakeStates() {
        awakeTask?.cancel()
        let states = voice.awakeStates
        awakeTask = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                switch state {
                case .awake:
                    self.realtime?.windowOpened()
                    self.wake.connected()
                    self.windowConnected()
                case .failed(let problem):
                    self.wake.connectFailed(problem.message)
                case .dormant, .waking:
                    break
                }
            }
        }
    }

    /// Her body is ready at once (there is no model to load); the brain starts its
    /// first conversation.
    func loadIfNeeded() async {
        guard loadState == .idle else { return }
        await startConversation(brain)
        loadState = .ready
        statusLine = stack.statusLine
        updateListening()
        #if DEBUG
        // `-DeeAutoPrompt "text"`: send a message on launch (screenshots, UI tests).
        if let auto = UserDefaults.standard.string(forKey: "DeeAutoPrompt"), !auto.isEmpty {
            send(auto)
        }
        #endif
    }

    /// The brain: RealtimeBrain on `voice`, with the memory tools (unless memories
    /// are private) and the device tools.
    private func makeReplyEngine() -> RealtimeBrain {
        RealtimeBrain(voice: voice, host: self, toolbox: toolbox(), options: RealtimeBrain.Options(timing: stack.timing))
    }

    private func toolbox() -> BrainToolbox {
        var tools: [any AgentTool] = []
        if let people {
            let current: @Sendable () async -> UUID? = { await MainActor.run { people.currentID } }
            tools += BrainToolbox.memoryTools(store: people.store, currentPerson: current, share: settings.shareMemories)
        }
        tools += DeviceTools.all()
        return BrainToolbox(tools: tools)
    }

    // MARK: - Provider and settings (in-app; v0.6)

    /// The in-app settings or onboarding saved: wake phrase, speak-first, share
    /// memories, age — and a new provider, applied only while DORMANT (an open window
    /// closes first). Never touches the network (W2).
    func settingsChanged() async {
        let config = prefs.providerConfig
        let fresh = CloudSettings(voice: config?.voice ?? "marin", model: config?.openAIModel ?? "gpt-realtime-2.1-mini",
                                  shareMemories: prefs.shareMemories)
        let shareChanged = fresh.shareMemories != settings.shareMemories
        settings = fresh
        if prefs.wakePhrase != wake.phrase { await wake.setPhrase(prefs.wakePhrase) }
        // A new provider — or the same one that couldn't work before (a key just added).
        if config != stack.config || stack.issue != nil { await applyProvider(config) }
        else if shareChanged { await realtime?.setToolbox(toolbox()) }
        await applyAgeSettings()
        if started, backgroundedAt == nil {
            UIApplication.shared.isIdleTimerDisabled = true
            updateListening()
        }
    }

    /// Rebuilds her voice and brain for `config` (closing a window first).
    func applyProvider(_ config: ProviderConfig?) async {
        if !wake.isDormant { wake.providerChanged() }
        guard started else {
            stack = VoiceStack.make(config, secrets: secrets)
            providerProblem = stack.issue?.message
            wake.mode = config?.mode.rawValue ?? "none"
            return
        }
        stop(hush: true)
        voice.shutdown()
        stack = VoiceStack.make(config, secrets: secrets)
        providerProblem = stack.issue?.message
        wake.mode = config?.mode.rawValue ?? "none"
        voiceReady = false
        await startStack()
        updateListening()
        statusLine = stack.statusLine
    }

    /// Onboarding again: she goes dormant and stops listening until it is done.
    func leaveForOnboarding() async {
        if !wake.isDormant { wake.providerChanged() }
        voice.listeningEnabled = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    var usageToday: UsageDay { wake.usage.today(at: Date()) }

    func settingsOpened() {
        settingsRequested = false
        touch.cancelAll()
        touchPoint = nil
    }

    func settingsClosed() { settingsRequested = false }

    /// The chip asks for the sheet.
    func requestSettings() { settingsRequested = true }

    // MARK: - Wake (DORMANT ⇄ CONVERSATION)

    /// What the wake chip shows.
    struct WakeStatus: Equatable {
        var text: String
        var symbol: String
        var open: Bool
        var accessibility: String
    }

    var wakeStatus: WakeStatus {
        let phrase = wake.phrase.text
        switch wake.window.state {
        case .open:
            return WakeStatus(text: "Listening", symbol: "waveform", open: true,
                              accessibility: "Listening. Say “go to sleep” or “that's all” to end the conversation.")
        case .waking:
            return WakeStatus(text: "Waking up…", symbol: "ellipsis", open: true, accessibility: "Waking up")
        case .dormant:
            if earProblem != nil {
                return WakeStatus(text: "Tap me to talk", symbol: "hand.tap", open: false,
                                  accessibility: "She can't hear her wake phrase. Tap to talk.")
            }
            return WakeStatus(text: "Say “\(phrase)” or tap", symbol: "ear", open: false,
                              accessibility: "Not listening. Say \(phrase), or tap to talk.")
        }
    }

    /// A working provider and her body ready.
    var canWake: Bool { loadState == .ready && stack.issue == nil }

    /// A tap outside her eyes, or the chip.
    func tapToTalk() {
        guard canWake, wake.isDormant else {
            if stack.issue != nil { requestSettings() }
            return
        }
        wake.tapToTalk(captureFrame: voice.captureFrame)
    }

    /// The window just connected: a speak-first greeting goes now.
    private func windowConnected() {
        lastActivityAt = Date()
        if wake.greetingInitiativeOpen, let name = pendingGreeting {
            pendingGreeting = nil
            wake.usedGreetingInitiative()
            newConversation()
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                self.perceive(.initiative("(You recognise \(name) — you know them. Greet them warmly by name.)"))
            }
        }
    }

    private var dimmed: Bool { listeningOff && Date().timeIntervalSince(lastActivityAt) > 120 }

    /// Busy for the window's idle close (TurnPolicy.initiativeAllowed inputs): never
    /// raw speech energy — EarCore's bed-proof voice only.
    private var windowBusy: Busy {
        Busy(replyOutstanding: isResponding || (realtime?.isBusy ?? false), toolRunning: false,
             awaitingWords: ledger.awaitingVoice, holdActive: voice.floorHold != nil,
             someoneTalking: voice.userVoiceActive)
    }

    private func show(notice text: String) {
        notice = text
        transcript.append(TranscriptItem(kind: .note, text: text))
        Task {
            try? await Task.sleep(for: .seconds(8))
            if self.notice == text { self.notice = nil }
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
            baseline = await mind.voiceBaseline
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
        let before = mindSnapshot?.code
        let snap = await mind.react(appraisal)
        accept(snap)
        if let before { realtime?.noteMind(appraisal, before: before, after: snap.code) }
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
            let before = mindSnapshot?.code
            let snap = await mind.catchUp(lastSeenUserAt: someoneHere ? away : nil)
            accept(snap)
            if let before { realtime?.noteCause(sleeping ? .rest : .timeAlone, before: before, after: snap.code) }
            await applyAgeSettings()
            await wake.recheckEar()
            UIApplication.shared.isIdleTimerDisabled = true
            lastActivityAt = Date()
            sense(.tick)
            updateListening()
        } else if backgroundedAt == nil {
            backgroundedAt = Date()
            // No background wake (no background mic): the window closes, she goes dormant.
            wake.backgrounded()
            voice.listeningEnabled = false
            UIApplication.shared.isIdleTimerDisabled = false
            stop(hush: true)
            // The guard corpus and prosody frames are RAM for this session only.
            realtime?.backgrounded()
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

    /// The microphone runs whenever Dee is loaded and in the foreground: DORMANT it
    /// feeds only the on-device wake ear (nothing is sent: CloudVoice has no socket and
    /// no uplink until a window opens); in a window it also feeds the uplink. *Whether*
    /// she answers is the window's rule (`Engagement.answers`).
    private func updateListening() {
        let on = loadState == .ready && backgroundedAt == nil
        voice.listeningEnabled = on
        voiceHealth.listeningWanted(since: on && voiceReady ? (voiceHealth.waitingForEarsSince ?? Date()) : nil)
        refreshVoiceProblem()
    }

    /// Someone is with Dee: in view, or was (or said her name) within `engagedGrace`.
    var isEngaged: Bool { someoneHere || Date().timeIntervalSince(lastEngagedAt) < Self.engagedGrace }

    /// The user has the floor: talking, mid-pause with words not yet delivered, or
    /// Dee has just yielded to them. Her own sounds — initiatives, events, laughs,
    /// canned lines — wait (audit C3: any speech she starts closes the user's turn).
    /// Raw voice activity counts only while someone is engaged (a TV in an empty
    /// room must not keep her awake), and a Cortex floor left at "user speaking" by
    /// words that never reached it as `.heard` (a command) does not (`UserFloor`).
    private var userHoldsFloor: Bool {
        let floor = selfDriver?.stance.floor
        let yielding: Bool = if case .yielding? = floor { true } else { false }
        return userFloor.holds(at: Date(), voiceActive: voice.userIsSpeaking, engaged: wake.answers,
                               cortexUserTurn: floor?.isUserTurn ?? false, cortexYielding: yielding)
    }

    /// The window woke her (her phrase heard on the device, a tap, a greeting).
    func wokenByVoice() {
        lastEngagedAt = Date()
        guard sleeping else { return }
        let sleptLongEnough = asleepSince.map { Date().timeIntervalSince($0) >= Self.newConversationAfterSleeping } ?? false
        sleeping = false
        asleepSince = nil
        if sleptLongEnough { newConversation() }
    }


    private func refreshVoiceProblem() {
        // No connection (no key, refused key, network down) is shown like any
        // other problem with her ears or voice.
        voiceHealth.cloudVoice(voice.problem)
        var problem = voiceHealth.problem(at: Date())
        // Her ears close while she talks: not a reason to start saying they aren't ready.
        if problem == .preparingEars, isSpeaking, voiceProblem != .preparingEars { problem = nil }
        guard problem != voiceProblem else { return }
        voiceProblem = problem
        if let problem { transcript.append(TranscriptItem(kind: .note, text: problem.message)) }
    }

    private func handle(_ event: VoiceEvent) {
        switch event {
        case .permission(let mic, let speech):
            microphoneAllowed = mic
            voiceHealth.permission(microphone: mic, speech: speech)
            refreshVoiceProblem()
        case .ready:
            voiceReady = true
            updateListening()
        case .listening(let open):
            if open, !voiceHealth.earsOpened || voiceProblem != nil {
                voiceHealth.earsWorking()
                refreshVoiceProblem()
            }
        case .partial(let text):
            if !voiceHealth.earsOpened || voiceProblem != nil { voiceHealth.earsWorking(); refreshVoiceProblem() }
            // Outside a window nothing is for her — not even her name in a server
            // transcript (W1: only the on-device ear wakes her).
            guard wake.answers else { return }
            lastActivityAt = Date()
            heard = text
            userFloor.partial(at: Date())
            // The user started talking: an initiative or event line she has not started
            // saying gives way.
            yieldToUser()
            // Forward partials at ≤ 2 Hz: the listening face previews her reaction.
            if Date().timeIntervalSince(lastPartialForwarded) >= 0.5 {
                lastPartialForwarded = Date()
                sense(.partial(text))
            }
        case .pause(let turnEnd, let hesitation):
            guard wake.answers else { return }
            userFloor.paused(at: Date())
            sense(.pause(turnEnd: turnEnd, hesitation: hesitation))
        case .heard:
            // Their turn is over whatever becomes of the words (answered, a command,
            // not for her): the floor is no longer theirs (M2). The words themselves
            // reach the brain as the server's transcript, which runs `heard(_:)`
            // below; this event never starts or stops a reply (the reply to it was
            // usually requested at the commit, before these words arrived).
            userFloor.closed(at: Date())
            if !voiceHealth.earsOpened || voiceProblem != nil { voiceHealth.earsWorking(); refreshVoiceProblem() }
        case .sound(let sound):
            heardSound(sound)
        case .micLevel(let level):
            micLevel = level
        case .speakingStarted:
            isSpeaking = true
            if voiceProblem != nil { voiceHealth.audioWorking(); refreshVoiceProblem() }
            ledger.speakingStarted(at: Date())
            sense(.speakingStarted)
        case .speechLevel(let level):
            speechLevel = level
            ledger.speechLevel(level, at: Date())
        case .speakingFinished:
            isSpeaking = false
            speechLevel = 0
            ledger.speakingFinished(at: Date())
            curiosity.note(.deeSpoke, at: Date())
            sense(.speakingFinished)
        case .bargeIn:
            // The user talked over Dee: stop and listen.
            stop()
            sense(.bargeIn)
        case .error(let message):
            transcript.append(TranscriptItem(kind: .note, text: "Voice: \(message)"))
            if voiceHealth.error(message) { refreshVoiceProblem() }
        }
    }


    private func heardSound(_ sound: HeardSound) {
        let loudness = max(0, min(1, (sound.loudnessDB + 50) / 40))
        // Social sounds are never "unexpected", but they matter most: laughter is
        // contagious, crying gets concern, applause delights.
        if sound.kind.isSocial {
            let quietMoment = !isSpeaking && !isResponding && !userHoldsFloor
            if sound.kind == .laughter, quietMoment, !sleeping {
                laughAside(intensity: 0.5)
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

    /// The eye regions of the face (0…1, y down).
    static func isOnAnEye(_ p: SIMD2<Double>) -> Bool {
        abs(p.y - 0.47) < 0.12 && abs(abs(p.x - 0.5) - 0.19) < 0.12
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
            if Self.isOnAnEye(p) {
                perform(p.x < 0.5 ? .blinkLeft : .blinkRight)
            } else if wake.isDormant {
                // Tap-to-wake: a single tap outside the eyes.
                tapToTalk()
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
            // Never over the user's turn: a giggle mid-sentence would end it (audit C3).
            if duration > 0.6, !isSpeaking, !userHoldsFloor { laughAside(intensity: 0.7) }
        }
        let gentle: Bool = switch gesture {
        case .pet, .hold, .tap, .doubleTap, .tickle: true
        default: false
        }
        let appraisal = Appraisal.touch(kind)
        let percept = Percept.touch(kind: kind.word, gentle: gentle, at: at)
        lastTouch = TouchInput(kind: kind.word, gentle: gentle, at: Date())
        lastActivityAt = Date()
        if let line, wake.initiativeAllowed, !isResponding, !isSpeaking, !userHoldsFloor, loadState == .ready {
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
            // A friend she knows: start a conversation that remembers them, and say hi —
            // inside an open window; while dormant only with "Speak first" on (one
            // greeting window per arrival).
            guard loadState == .ready, !isResponding, !isSpeaking else { return }
            if wake.isOpen {
                newConversation()
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    self.perceive(.initiative("(You recognise \(person.name) — you know them. Greet them warmly by name.)"))
                }
            } else if wake.isDormant, prefs.speakFirst, !greetedThisArrival, canWake {
                greetedThisArrival = true
                pendingGreeting = person.name
                wake.greetingDue()
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
        case .askWhich:
            // Never their words in the DNA (privacy guard): the model heard them.
            pendingNotes.append("(Several things you remember match what they said. Ask gently which one they mean.)")
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
            lastEngagedAt = Date()
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
            greetedThisArrival = false
            absentSince = Date()
            lastEngagedAt = Date()
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
            if wake.initiativeAllowed, !isResponding, !isSpeaking, !userHoldsFloor, loadState == .ready {
                Task { await react(.wave, then: .gesture("wave")) }
                perceive(.event(.wave, line: "(The user waves at you.)"), alreadyAppraised: true)
            } else {
                Task { await react(.wave, then: .gesture("wave")) }
            }
        case .palm:
            // "Hush": stop talking now.
            stop(hush: true)
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
                    let snap = await mind.tick(userPresent: self.someoneHere, asleep: self.sleeping)
                    self.accept(snap)
                    self.realtime?.noteMood(snap.code)
                }
                self.sense(.tick)
                self.wake.tick(busy: self.windowBusy)
                self.curiosity.asleepSince = self.asleepSince
                self.refreshVoiceProblem()
                self.withdrawSilentReply()
                if ticks % 4 == 0 { self.considerInitiative() }
                // Never fall asleep on someone talking off-camera, or just after they said her name.
                guard !self.isResponding, !self.isSpeaking, !self.userHoldsFloor, let since = self.absentSince else { continue }
                if Date().timeIntervalSince(max(since, self.lastEngagedAt)) >= Self.sleepAfter, !self.sleeping {
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
        // Only inside an open conversation window (v0.6): never a reason to connect.
        guard wake.initiativeAllowed else { return }
        guard Date().timeIntervalSince(lastInitiativeAt) > 20 else { return }
        let busy = isResponding || isSpeaking || ledger.awaitingVoice || userHoldsFloor || (realtime?.isBusy ?? false)
            || voiceProblem != nil
        guard let prompt = curiosity.nextPrompt(at: Date(), snapshot: snap, userPresent: someoneHere, busy: busy) else { return }
        perceive(.initiative(prompt))
    }

    // MARK: - Conversation

    private struct QueuedUtterance {
        var text: String
        var prosody: Prosody?
        var duration: Double
    }

    /// Debug-only text entry (the shipping app is voice and camera only).
    func send(_ raw: String) {
        perceive(.spoken(raw, prosody: nil))
    }

    /// Spoken commands handled without the language model. Whole utterances only
    /// (audit C8: "don't stop", "it's so quiet" used to silence her), and "stop" only
    /// while there is something to stop.
    private func command(in text: String) -> Bool {
        let talking = isSpeaking || isResponding || Date().timeIntervalSince(lastStoppedAt) < 3
        // Her confirmation question about a new wake phrase gets its yes / no first.
        if let outcome = phraseChange.answer(text, current: wake.phrase, at: Date()) {
            switch outcome {
            case .saved(let p, let line):
                prefs.wakePhrase = p
                Task { await wake.setPhrase(p) }
                sayAside(line, style: voiceStyle)
            case .kept(let line):
                sayAside(line, style: voiceStyle)
            }
            return true
        }
        let matcher = wake.matcher
        switch SpokenCommand.match(text, deeIsTalking: talking, stripLeading: { matcher.stripLeading($0) }) {
        case .changeWakePhrase(let raw)?:
            switch phraseChange.propose(raw, current: wake.phrase, at: Date()) {
            case .confirm(_, let line), .invalid(let line), .unchanged(let line):
                sayAside(line, style: voiceStyle)
            }
            return true
        case .stopListening?:
            stop(hush: true)
            // Closes the window now: her local goodbye clip, then the socket closes.
            wake.closeCommand()
            return true
        case .newConversation?:
            stop(hush: true)
            if isResponding { freshStartPending = true } else { freshStart() }
            return true
        case .stop?:
            stop(hush: true)
            return true
        case .sleep?:
            stop(hush: true)
            perform(.yawn)
            // The window closes at once (local goodbye clip, no network).
            wake.closeCommand()
            Task {
                try? await Task.sleep(for: .seconds(2))
                self.sleeping = true
                self.asleepSince = Date()
            }
            return true
        case nil:
            return false
        }
    }

    private func freshStart() {
        newConversation()
        sayAside("Okay! Fresh start.", style: voiceStyle)
    }

    func perceive(_ stimulus: Stimulus, alreadyAppraised: Bool = false) {
        let text: String
        var appraisal: Appraisal?
        var isUser = false
        var kind = TurnLedger.Kind.event
        switch stimulus {
        case .spoken(let raw, _):
            // Typed in Debug (spoken words reach the brain as transcripts instead).
            text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            heard = text
            transcript.append(TranscriptItem(kind: .user, text: text))
            curiosity.note(.userSpoke, at: Date())
            if sleeping { sleeping = false; asleepSince = nil }
            if command(in: text) { return }
            // Debug keyboard: typing to a dormant Dee wakes her like a tap.
            if wake.isDormant { tapToTalk() }
            isUser = true
        case .event(let a, let line):
            text = line
            appraisal = alreadyAppraised ? nil : a
        case .initiative(let line):
            text = line
            kind = .initiative
        case .cortexInitiative:
            // The Cortex already issued its aim into the Stance; the DNA carries it.
            text = ""
            kind = .initiative
        }
        guard brain != nil, loadState == .ready else {
            if isUser { Task { await self.hear(text, prosody: nil, duration: 0) } }
            return
        }
        if isUser {
            // Typed words: whatever Dee was about to say, or was saying, gives way,
            // and the words are always answered (C2).
            let utterance = QueuedUtterance(text: text, prosody: nil, duration: 0)
            stopReply(hush: false)
            if isSpeaking { _ = voice.stopClip() }   // a laugh or canned line
            if isResponding {
                if var q = queuedUtterance {
                    q.text += " " + utterance.text
                    queuedUtterance = q
                } else {
                    queuedUtterance = utterance
                }
                return
            }
            startTurn(user: utterance)
            return
        }
        // Her own initiatives and non-verbal events never start over the user (C3,
        // gate 1 of 3: at send time) or while she is busy; they still land emotionally.
        // v0.6: and only inside an open conversation window (never a reason to connect).
        if !wake.initiativeAllowed || isResponding || isSpeaking || ledger.awaitingVoice || userHoldsFloor
            || (realtime?.isBusy ?? false) {
            if let appraisal { Task { await self.react(appraisal) } }
            return
        }
        startTurn(text: text, appraisal: appraisal, kind: kind)
    }

    /// Starts one turn the app asked for: typed words (`user`), or her initiative /
    /// an event line (`text`). Spoken turns are started by the brain itself
    /// (`brainStartedReply`).
    private func startTurn(user: QueuedUtterance? = nil, text: String = "", appraisal: Appraisal? = nil,
                           kind: TurnLedger.Kind = .reply) {
        guard let brain else { return }
        if kind == .initiative { lastInitiativeAt = Date() }
        wake.responseStarted()
        let answersUser = user != nil
        isResponding = true
        caption = ""
        if asleepSince != nil { asleepSince = nil }
        let (id, previous) = ledger.begin(kind, rate: Double(voiceStyle.rate), at: Date())

        responseTask = Task {
            await self.settling?.value
            if let previous { await self.settle(previous) }
            var request = ReplyRequest.initiative(text)
            if let user {
                var sent = user.text
                if let earlier = ledger.takeCarryOver(at: Date()) { sent = earlier + " " + user.text }
                ledger.setUserText(sent, for: id)
                // The brain runs the words' normal path (people, Mind, Cortex) itself.
                request = .user(words: sent)
            } else if let appraisal {
                await react(appraisal)
            }
            // Gate 2 of 3 for her initiatives and event lines: the user started talking
            // while it was prepared (L1).
            if ledger.mustGiveWay(userHoldsFloor: userHoldsFloor) { stopReply(hush: false) }
            guard ledger.isLive(id) else {
                await endTurn(id)
                return
            }
            ledger.enteredHistory(id)
            // The effort is the brain's (its ThinkingMode); the DNA is its, too.
            await consume(brain.respond(request, state: nil, effort: ThinkingMode.chatEffort), id: id, answersUser: answersUser)
        }
    }

    /// The user's words: appraised by the mind (what + how, adjusted by the Cortex),
    /// then interpreted by the Cortex. The face starts reacting at once.
    @discardableResult
    private func hear(_ text: String, prosody: Prosody?, duration: Double) async -> Appraisal? {
        guard let mind else { return nil }
        let before = mindSnapshot?.code
        let cortex = selfDriver?.cortex
        let (appraisal, snap) = await mind.hear(text, prosody: prosody, adjust: { a in cortex?.adjust(a) ?? a })
        accept(snap)
        baseline = await mind.voiceBaseline
        if let before { realtime?.noteMind(appraisal, before: before, after: snap.code) }
        let loudness = prosody.map { ($0.loudnessDB + 32) / 12 } ?? 0
        sense(.heard(text: text, durationS: duration, loudnessVsBaseline: loudness, appraisal: appraisal))
        return appraisal
    }

    /// One reply's events. Her audio is the session's: the voice plays it and
    /// reports `.speakingStarted` / `.speakingFinished`; the events here are its
    /// transcript, placed on what was actually played.
    private func consume(_ events: AsyncThrowingStream<ReplyEvent, Error>, id: Int, answersUser: Bool) async {
        var deeIndex: Int?
        var full = ""
        /// This reply is still the one to show (not stopped, not superseded).
        func live() -> Bool { ledger.isLive(id) }
        func deeItem() -> Int {
            if let deeIndex { return deeIndex }
            transcript.append(TranscriptItem(kind: .dee, text: "", isStreaming: true))
            deeIndex = transcript.count - 1
            return deeIndex!
        }
        do {
            for try await event in events {
                // What she did say was said, even after the reply was stopped or
                // superseded: the Cortex hears it (the session's history holds it too).
                if case .sentenceFinished(let sentence, true) = event {
                    sense(.deeSaid(tag: nil, sentence: sentence))
                }
                guard live() else { continue }
                switch event {
                case .content(let s):
                    if ledger.mustGiveWay(userHoldsFloor: userHoldsFloor) {
                        // Gate 3 of 3 for initiatives and event lines, until her voice
                        // starts: the user started talking (C3).
                        stopReply(hush: false)
                        continue
                    }
                    showDisclosureCaption()
                    let i = deeItem()
                    if transcript[i].text.isEmpty { caption = "" }
                    transcript[i].text += s
                    caption += s
                    full += s
                    ledger.streamed(s, id: id, voiceSpeaking: isSpeaking, at: Date())
                case .sentenceFinished:
                    break
                case .emotion:
                    break
                case .toolCall(let call):
                    transcript.append(TranscriptItem(kind: .tool, text: "⚙︎ \(call.name)"))
                case .toolResult, .turnCompleted:
                    break
                case .messageCompleted(let message):
                    if let i = deeIndex {
                        transcript[i].isStreaming = false
                        if !message.isEmpty { transcript[i].text = message }
                        if transcript[i].text.isEmpty { transcript.remove(at: i) }
                    }
                    deeIndex = nil
                }
            }
        } catch is CancellationError {
        } catch {
            transcript.append(TranscriptItem(kind: .note, text: error.localizedDescription))
        }
        sense(.deeTurnFinished(text: full))
        // Only her replies to accepted turns keep the window open (not initiatives).
        wake.replyEnded(toAccepted: answersUser)
        await endTurn(id)
    }

    /// The turn's model work is over: settle a stopped reply, then take the next
    /// queued utterance (or the pending fresh start).
    private func endTurn(_ id: Int) async {
        for i in transcript.indices where transcript[i].isStreaming { transcript[i].isStreaming = false }
        if let stopped = ledger.generationEnded(id, voiceSpeaking: isSpeaking, at: Date()) { await settle(stopped) }
        // Another reply may have started meanwhile (the brain answers spoken turns
        // on its own): only the current one decides whether she is responding.
        if ledger.reply?.id == id || ledger.reply == nil { isResponding = false }
        discloseIfStillOwed()
        if freshStartPending {
            freshStartPending = false
            queuedUtterance = nil
            freshStart()
        } else if let q = queuedUtterance {
            queuedUtterance = nil
            startTurn(user: q)
        }
    }

    // MARK: - What was actually said (audit C9)

    /// A one-off line (canned reply, the sorry line). Its audio is not a reply's (L2).
    /// The brain has the session speak it out of band in her voice (docs/DNA.md
    /// §4.2); offline, or over the user, it is dropped.
    private func sayAside(_ line: String, style: VoiceStyle) {
        // Through the open session only: never a reason to connect (W2).
        guard let realtime, wake.isOpen else { return }
        let seconds = Double(line.count) / SpokenReply.charactersPerSecond(rate: Double(style.rate)) + 0.4
        ledger.asideRequested(duration: seconds, voiceSpeaking: isSpeaking, at: Date())
        showDisclosureCaption()
        Task { _ = await realtime.say(line) }
    }

    // MARK: - AI-voice disclosure (OpenAI usage policy)

    private var voiceDisclosed: Bool { UserDefaults.standard.bool(forKey: CloudSettings.Key.disclosed) }

    /// The caption, the first time anything in her AI voice plays (a reply, a laugh,
    /// a canned line) while the spoken disclosure is still owed.
    private func showDisclosureCaption() {
        // OpenAI's policy, for OpenAI voices only (modes 1 and 2).
        guard stack.speaksWithOpenAI, !voiceDisclosed, disclosure == nil else { return }
        disclosure = AIVoiceDisclosure.caption
    }

    /// After a turn: she says the disclosure line at the next quiet moment, until it
    /// has actually been played through; only then is it remembered as done.
    private func discloseIfStillOwed() {
        guard stack.speaksWithOpenAI, wake.isOpen, !voiceDisclosed, !disclosing, disclosure != nil, let realtime else { return }
        disclosing = true
        Task {
            defer { self.disclosing = false }
            try? await Task.sleep(for: .seconds(1))
            guard !self.isResponding, !self.userHoldsFloor, !self.isSpeaking else { return }
            if await realtime.say(AIVoiceDisclosure.line) == .played {
                UserDefaults.standard.set(true, forKey: CloudSettings.Key.disclosed)
                try? await Task.sleep(for: .seconds(4))
                self.disclosure = nil
            }
        }
    }

    /// A short laugh, as an aside — not while a reply waits for her voice: her voice
    /// drops held initiative speech for anything else, and a reply still being
    /// synthesised should not start with a giggle.
    private func laughAside(intensity: Double) {
        guard !ledger.awaitingVoice else { return }
        ledger.asideRequested(duration: 1.5, voiceSpeaking: isSpeaking, at: Date())
        showDisclosureCaption()
        voice.laugh(intensity: intensity, age: mindSnapshot?.age, energy: mindSnapshot?.mood.energy ?? 0.7)
    }

    /// Stops Dee's current reply where it is: her voice (the session is told how
    /// much was played) and the brain.
    private func stopReply(hush: Bool) {
        switch ledger.stop(hush: hush, at: Date()) {
        case .nothing:
            break
        case .cancelGeneration:
            stopVoice()
            if let brain { Task { await brain.cancel() } }
        case .settle(let taken):
            stopVoice()
            let before = settling
            settling = Task { await before?.value; await self.settle(taken) }
        }
    }

    /// Settles a stopped reply. The voice has already told the session how much of
    /// it was played, so the conversation holds what was heard; a reply nobody heard
    /// counts as withdrawn, and its user words carry over to what they say next (C2).
    private func settle(_ r: TurnLedger.Reply) async {
        var withdrawn = !r.inHistory
        if r.inHistory, ledger.settlement(of: r, at: Date()) == .retract {
            withdrawn = true
            transcript.append(TranscriptItem(kind: .note, text: "Nothing of that reply was heard"))
        }
        ledger.settled(r, withdrawn: withdrawn, at: Date())
    }

    /// The user started talking while Dee's initiative or event line was still being
    /// written or held for her voice: it gives way before her first word (C3).
    private func yieldToUser() {
        if ledger.mustGiveWay(userHoldsFloor: true) { stopReply(hush: false) }
    }

    /// A finished reply her voice never started (it held an initiative and dropped
    /// it, or synthesis failed) is withdrawn, so history doesn't keep unsaid words.
    private func withdrawSilentReply() {
        if ledger.isSilentTooLong(at: Date()) { stopReply(hush: false) }
    }

    func stop() { stop(hush: false) }

    /// Stops her voice. Through the brain when there is one, so its next request
    /// waits out the stop (`RealtimeBrain.stopVoice`).
    private func stopVoice() {
        if let realtime { realtime.stopVoice() } else { voice.stopSpeaking() }
    }

    /// - Parameter hush: the user asked for quiet (palm, "stop"): what she was
    ///   answering is not carried over to their next words.
    private func stop(hush: Bool) {
        lastStoppedAt = Date()
        stopReply(hush: hush)
        stopVoice()
        // A barge-in keeps the words that interrupted her; a hush drops what came before it.
        if let realtime {
            Task { await realtime.cancel(hush: hush) }
        } else if let brain {
            Task { await brain.cancel() }
        }
    }

    func newConversation() {
        guard !isResponding else { return }
        let brain = brain
        transcript.removeAll()
        thinkingMode = false
        caption = ""
        heard = ""
        ledger.newConversation()
        queuedUtterance = nil
        // The next turn waits for the fresh start: a turn woken by her name must not
        // have its history wiped while it is being answered (L3).
        let before = settling
        settling = Task { await before?.value; await self.startConversation(brain) }
    }

    /// A new conversation for the Cortex, and for the brain if there is one.
    private func startConversation(_ brain: (any ReplyEngine)?) async {
        let now = Date()
        sense(.conversationStarted(now))
        await brain?.newConversation(persona: await currentPersona(), now: now)
    }

    /// The debug toggle: thinking mode on or off for the rest of the conversation.
    func toggleThinking() {
        realtime?.setThinking(!thinkingMode)
    }
}

// MARK: - BrainHost (what RealtimeBrain needs from the app)

extension DeeModel: BrainHost {
    /// Answer at the commit only when someone is with her and she is awake; else the
    /// brain waits for the words and `heard` decides (her name wakes her, a TV doesn't).
    var answersOnCommit: Bool {
        // v0.6: the one rule every host shares — an open window means engaged and addressed.
        loadState == .ready && backgroundedAt == nil && wake.answers
    }

    var voiceBaseline: Appraiser.VoiceBaseline { baseline }

    func modeSignals(at now: Date) -> CueModeSignals {
        guard let driver = selfDriver else { return CueModeSignals() }
        return CueModeSignals(moment: driver.cortex.moment, identified: people?.currentName != nil, at: now)
    }

    /// The words' normal path. Spoken words get the floor, "is this for me?" and
    /// command checks here (typed words had them in `perceive`). Never stops a reply
    /// on its own: only a command does.
    func heard(_ turn: HeardTurn) async -> HeardVerdict {
        let text = turn.text
        if case .voice = turn.source {
            userFloor.closed(at: Date())
            if !voiceHealth.earsOpened || voiceProblem != nil { voiceHealth.earsWorking(); refreshVoiceProblem() }
            // W1: a server / LAN transcript never wakes her or changes engagement —
            // outside an open window nothing is answered, her name included.
            guard wake.answers, loadState == .ready, backgroundedAt == nil else {
                transcript.append(TranscriptItem(kind: .note, text: "Not answered (no conversation window open)"))
                return .ignored
            }
            lastEngagedAt = Date()
            lastActivityAt = Date()
            heard = text
            transcript.append(TranscriptItem(kind: .user, text: text))
            curiosity.note(.userSpoke, at: Date())
            if sleeping { sleeping = false; asleepSince = nil }
            if command(in: text) {
                if wake.isOpen { wake.acceptedTurn() }
                return .handled
            }
            wake.acceptedTurn()
        }
        if let people, let event = await people.heard(text) { handle(event) }
        let appraisal = await hear(text, prosody: turn.prosody, duration: turn.duration)
        return .answer(appraisal)
    }

    /// No words for that utterance: the user's floor closes anyway.
    func wordsFailed() {
        userFloor.closed(at: Date())
    }

    /// docs/DNA.md §4.1 step 1: the notes are picked (`Cortex.cue`) and their
    /// bookkeeping runs, then everything the DNA reads is gathered.
    func dnaParts(_ r: DNARequest) async -> DNAParts? {
        guard let driver = selfDriver, let mind else { return nil }
        sense(.promptSubmitted)
        if r.pickNotes {
            let (_, effects) = driver.cue(at: r.now)
            for e in effects { execute(e) }
        }
        var person: PersonInputs?
        if let people, let id = people.currentID, let p = await people.store.person(id) {
            let lines = settings.shareMemories ? await people.store.promptMemories(for: id, limit: 9, now: r.now) : []
            person = PersonInputs(person: p, promptMemories: lines)
        }
        let state = await mind.state
        let body = BodyInputs(someoneHere: someoneHere, asleep: sleeping, wokeAt: lastWokeAt, touch: lastTouch,
                              lastUserTurnAt: r.lastUserTurnAt, lastContact: person?.lastSeen)
        let context = DNAContext(aging: AgingInputs(state.age), inner: InnerStateCounters(state), rings: r.rings, body: body,
                                 daily: await daily(mind, at: r.now), shareMemories: settings.shareMemories,
                                 guardCorpus: r.corpus)
        var inputs = driver.cortex.dnaInputs(at: r.now, memories: person, turn: r.turn, appraisal: r.appraisal, context: context)
        // A Cortex initiative's own aim, for that initiative's DNA only (a DNA
        // re-rendered after `forget` or for a retry must not take it).
        if r.turn.kind == .initiative, !r.pickNotes {
            if let issued = initiativeNotes { inputs.stance.notes = issued }
            initiativeNotes = nil
        }
        let notes = Array(pendingNotes.prefix(2))
        pendingNotes.removeAll()
        return DNAParts(inputs: inputs, extraNotes: notes)
    }

    /// `Mind.history(days: 30)`, at most once a minute (it reads SQLite).
    private func daily(_ mind: Mind, at now: Date) async -> [DNADay] {
        if let c = dailyCache, now.timeIntervalSince(c.at) < 60 { return c.days }
        let days = await mind.history(days: 30).map { DNADay(day: $0.day, interactions: $0.interactions, regard: $0.regard) }
        dailyCache = (now, days)
        return days
    }

    /// A spoken turn the brain answered on its own: shown and settled like any reply.
    func brainStartedReply(_ reply: BrainReply) {
        if sleeping { sleeping = false; asleepSince = nil }
        wake.responseStarted()
        isResponding = true
        caption = ""
        let (id, previous) = ledger.begin(.reply, rate: Double(voiceStyle.rate), at: Date())
        ledger.enteredHistory(id)
        Task {
            if let previous { await self.settle(previous) }
            await self.consume(reply.events, id: id, answersUser: true)
        }
    }

    /// They talked over her, she paused, and the brain's answer ended the pause (the
    /// voice emits `.bargeIn` only when it ends a pause itself). Sensed only: the
    /// reply the brain is starting is the answer, so nothing is stopped here. It is
    /// `.bargeInAnswered`, never `.bargeIn`: the Cortex answers `.bargeIn` with
    /// `.stopSpeaking`, and `stop()` cancelled that very answer (tune 5 F1: every
    /// question asked over her went unanswered). A spoken "stop" still stops her
    /// (the command path, `heard`).
    func bargedIn() {
        sense(.bargeInAnswered)
    }

    func thinkingModeChanged(_ on: Bool) {
        guard on != thinkingMode else { return }
        thinkingMode = on
        transcript.append(TranscriptItem(kind: .note, text: on ? "Thinking mode on for this conversation" : "Thinking mode off"))
    }
}

// MARK: - The conversation window's actions (WakeControllerHost)

extension DeeModel: WakeControllerHost {
    func wakeEyes() {
        listeningOff = false
        lastActivityAt = Date()
        perform(.nod)
        _ = voice.playCue(.wake)
        stanceVersion &+= 1
    }

    func listeningOffEyes() {
        listeningOff = true
        heard = ""
        caption = ""
        _ = voice.playCue(.listeningOff)
        stanceVersion &+= 1
        if let line = wake.log.last { Self.log.info("\(line, privacy: .public)") }
    }

    func perkUp() {
        perkedAt = Date()
        stanceVersion &+= 1
    }

    func woken(by source: WakeSource) {
        wokenByVoice()
    }

    func startNewConversation() {
        newConversation()
    }

    func connect(resume: Bool, uplinkFrom: Int64?) {
        guard stack.issue == nil else {
            wake.connectFailed(stack.issue?.message ?? "")
            return
        }
        voice.wake(uplinkFromFrame: uplinkFrom, resume: resume)
    }

    func disconnect() {
        voice.sleep()
    }

    func sayGoodbye() {
        // Local only (a rendered clip, never the network).
        if let clip = VoiceClip(rawValue: "goodbye") { _ = voice.play(clip, deferWhileUserSpeaks: false) }
    }

    func show(problem: String) {
        guard !problem.isEmpty else { return }
        if !wake.availability.isReady, problem == wake.availability.problemText || problem == EarAvailability.unavailableText {
            earProblem = problem
        } else {
            show(notice: problem)
        }
    }

    func clearProblem() {
        earProblem = nil
    }
}
