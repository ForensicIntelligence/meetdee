import DeeBrain
import DeeCore
import DeeMemory
import DeeMind
import DeeRealtime
import DeeSelf
import DeeVoice
import DeeWake
import Foundation
import HarnessCore
import Synchronization

/// A lock-protected value that closures can capture (Mutex is not copyable).
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func withLock<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

/// The harness's simulated wall clock: real time plus an offset that host steps
/// move forward ("the next day"). The brain, the Mind and the Cortex all read it.
public final class HarnessClock: Sendable {
    private let offset = Mutex<TimeInterval>(0)
    public init() {}
    public func now() -> Date { Date().addingTimeInterval(offset.withLock { $0 }) }
    public func advance(_ seconds: TimeInterval) { offset.withLock { $0 += seconds } }
    public var skipped: TimeInterval { offset.withLock { $0 } }
}

/// `BrainHost` for the harness: what `StandaloneHost` does (commands, "is this for
/// me?", Mind preview → Cortex.adjust → commit → `.heard`, DNA inputs), plus what
/// DeeModel does around it that a multi-turn, multi-"day" run needs:
/// - the simulated clock everywhere (`HarnessClock`), so a plan made "yesterday" is
///   followed up today and time apart is real to the Mind;
/// - the Cortex's effects are executed: `.persist` writes go to a real `SelfStore`
///   and `.remember` facts to the real `MemoryStore` (both in a temp dir), a Cortex
///   `.initiative` becomes `brain.respond(.initiative(""))`, a `.say` a canned line;
/// - every heard sentence of Dee's is reported to the runner (truncation check);
/// - the people layer the app runs on the user's words (`App/People.swift`): a
///   stranger is a placeholder person in `MemoryStore`, facts are learnt into it, and a
///   name they give is confirmed — from then on Dee knows who Dee is talking to, and
///   the next DNA says "Their name is …" (DeeModel's note).
@MainActor
final class HarnessHost: BrainHost {
    /// A confirmed identity, as the app sends it (`DeeModel`: `.identified(id, distance: 0)`).
    /// Tune-2 live cause: 0.6 is one unconfirmed sighting (the Interpreter needs 3), so the
    /// Cortex had no person all scenario: reunion, follow-ups and rituals were silently off.
    static let confirmedDistance: Float = 0
    /// A/B switch: `DEE_HARNESS_CORTEX_STOP=0` skips the app's `stop()` on a Cortex
    /// `.stopSpeaking` (default: run it, as DeeModel does).
    static let cortexStopOff = ProcessInfo.processInfo.environment["DEE_HARNESS_CORTEX_STOP"] == "0"
    let mind: Mind
    let memory: MemoryStore
    let selfStore: SelfStore
    let clock: HarnessClock
    var person: PersonID?
    weak var brain: RealtimeBrain?
    private(set) var cortex: Cortex

    var engaged = true
    var asleep = false
    var someoneHere = true
    var shareMemories = true

    // 0.6 wake (providers-wake-onboarding §4). `.alwaysOpen` (the tune2 baseline): the
    // window never closes and close commands don't close it. `.phrase`: the app's own
    // `WakeController` drives the window from the on-device ear only; nothing is
    // answered outside a window and no server transcript (Dee's name included) opens it.
    var wakeMode: WakeMode = .alwaysOpen
    private(set) var wake: WakeController?
    weak var voice: CloudVoice?
    var wakePhrase = WakePhrase.default
    private var phraseChange = WakePhraseChange()
    /// Wake events for the run record ("eyesWake", "connect resume=true", …).
    var onWake: ((String) -> Void)?
    private var tickTask: Task<Void, Never>?

    /// The one engagement rule (`Engagement.answers`); always true in `.alwaysOpen`.
    var windowAnswers: Bool { wakeMode == .alwaysOpen || (wake?.answers ?? false) }

    private(set) var heardLog: [(text: String, verdict: HeardVerdict)] = []
    private(set) var commands: [SpokenCommand] = []
    private(set) var said: [String] = []
    private(set) var voiceBaseline = Appraiser.VoiceBaseline()
    private(set) var initiativesStarted = 0
    private(set) var persisted = 0
    var onSentence: ((String, Bool) -> Void)?
    /// Barge-ins the brain reported (`bargedIn`) and Cortex `.stopSpeaking` effects run.
    private(set) var bargeInsSensed = 0
    private(set) var stopsExecuted = 0
    /// Overrides what `.stopSpeaking` does (tests); nil: the app's `stop()` on the brain.
    var stopSpeaking: (() -> Void)?
    var onNote: ((String) -> Void)?
    private var snapshot: MindSnapshot
    private var speakingUntil = Date.distantPast
    private var initiativeNotes: [Note]?
    private var pending: [SelfWrite] = []
    private var lastSeenAt: Date?
    /// The people layer: this conversation's placeholder (a stranger) and notes for the next DNA.
    private let peopleSession = UUID()
    private(set) var placeholder: PersonID?
    private(set) var extraNotes: [String] = []
    /// The person Dee is talking to changed (memory tools follow it).
    var onPerson: ((PersonID?) -> Void)?

    init(mind: Mind, memory: MemoryStore, selfStore: SelfStore, person: PersonID?, clock: HarnessClock) async throws {
        self.mind = mind
        self.memory = memory
        self.selfStore = selfStore
        self.person = person
        self.clock = clock
        let now = clock.now()
        let snap = await mind.snapshot(at: now)
        snapshot = snap
        let enduring = try await selfStore.loadEnduring(personality: snap.code.personality, seed: 7, at: now)
        let carried = try await selfStore.loadCarried(at: now)
        let session = try await selfStore.nextSession()
        cortex = Cortex(enduring: enduring, mind: snap, at: now, carried: carried, session: session,
                        utcOffset: TimeInterval(TimeZone.current.secondsFromGMT(for: now)))
        voiceBaseline = await mind.voiceBaseline
        _ = cortex.step(.conversationStarted(now), mind: snap, at: now)
        if let person { _ = cortex.step(.identified(person, distance: Self.confirmedDistance), mind: snap, at: now) }
        _ = cortex.step(.presence(arrived: true), mind: snap, at: now)
        lastSeenAt = now
    }

    // MARK: Body / clock (host steps)

    /// Steps the Cortex and executes what it asks for (as DeeModel would).
    @discardableResult
    func sense(_ p: Percept) -> [Effect] {
        let now = clock.now()
        let effects = cortex.step(p, mind: snapshot, at: now)
        execute(effects)
        return effects
    }

    func execute(_ effects: [Effect]) {
        for e in effects {
            switch e {
            case .persist(let w):
                pending.append(w)
            case .remember(let fact, let who):
                let memory = self.memory, at = clock.now()
                Task { await memory.remember(fact.text, category: fact.category, about: who, at: at) }
            case .initiative:
                // Its aim lives in this step's Stance only: keep it for the initiative's DNA.
                initiativeNotes = cortex.stance.notes
                initiativesStarted += 1
                onNote?("cortex initiative")
                if let brain { consume(brain.respond(.initiative(""), state: nil, effort: .low)) }
            case .say(let line):
                onNote?("cortex canned line")
                if let brain { Task { _ = await brain.say(line) } }
            case .stopSpeaking:
                // DeeModel.execute(.stopSpeaking) → stop(): the brain stops Dee's voice and
                // cancels (not a hush). The Cortex asks for it on `.bargeIn` (FloorKeeper).
                onNote?("cortex stopSpeaking")
                stopsExecuted += 1
                if let stopSpeaking { stopSpeaking() } else if Self.cortexStopOff {
                    onNote?("cortex stopSpeaking skipped (DEE_HARNESS_CORTEX_STOP=0)")
                } else if let brain {
                    brain.stopVoice()
                    Task { await brain.cancel(hush: false) }
                }
            default:
                break
            }
        }
        if pending.count >= 12 { Task { await save() } }
    }

    func save() async {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        if let result = try? await selfStore.apply(batch) { persisted += batch.count - result.failed.count }
    }

    func leave() {
        someoneHere = false
        lastSeenAt = clock.now()
        sense(.faceLost)
        sense(.presence(arrived: false))
    }

    /// Time passes with nobody here: the Mind catches up on the time apart.
    func advance(hours: Double) async {
        let before = snapshot.code
        clock.advance(hours * 3600)
        let now = clock.now()
        snapshot = await mind.catchUp(to: now, lastSeenUserAt: someoneHere ? nil : lastSeenAt)
        brain?.noteCause(.timeAlone, before: before, after: snapshot.code, at: now)
        execute(cortex.flush(at: now))
        await save()
        sense(.tick)
    }

    func newConversation() async {
        let now = clock.now()
        sense(.conversationStarted(now))
        await brain?.newConversation(persona: Persona(), now: now)
    }

    func arrive() {
        someoneHere = true
        engaged = true
        sense(.presence(arrived: true))
        if let person { sense(.identified(person, distance: Self.confirmedDistance)) }
    }

    // MARK: BrainHost

    var answersOnCommit: Bool { windowAnswers && engaged && !asleep }

    func modeSignals(at now: Date) -> CueModeSignals {
        CueModeSignals(moment: cortex.moment, identified: person != nil, at: now)
    }

    func heard(_ turn: HeardTurn) async -> HeardVerdict {
        let now = clock.now()
        if case .voice = turn.source {
            // Outside a window nothing is for Dee, Dee's name included (W1).
            guard windowAnswers else {
                heardLog.append((turn.text, .ignored))
                return .ignored
            }
            let talking = now < speakingUntil || turn.replyRequested
            if wakeMode == .phrase, let outcome = phraseChange.answer(turn.text, current: wakePhrase, at: now) {
                if case .saved(let p, _) = outcome { wakePhrase = p; Task { await wake?.setPhrase(p) } }
                onNote?("wake phrase answer \(outcome)")
                wake?.acceptedTurn()
                heardLog.append((turn.text, .handled))
                return .handled
            }
            let matcher = WakeMatcher(wakePhrase)
            if let c = SpokenCommand.match(turn.text, deeIsTalking: talking, stripLeading: { matcher.stripLeading($0) }) {
                commands.append(c)
                onNote?("command \(c)")
                if c == .stop || c.closesWindow { await brain?.cancel(hush: true) }
                if wakeMode == .phrase {
                    if case .changeWakePhrase(let raw) = c {
                        onNote?("wake phrase prompt \(phraseChange.propose(raw, current: wakePhrase, at: now))")
                        wake?.acceptedTurn()
                    }
                    if c.closesWindow { wake?.closeCommand() }
                }
                heardLog.append((turn.text, .handled))
                return .handled
            }
            guard answersOnCommit else {
                heardLog.append((turn.text, .ignored))
                return .ignored
            }
            if wakeMode == .phrase { wake?.acceptedTurn() }
        }
        await people(turn.text, at: now)
        let before = snapshot.code
        let cortex = self.cortex
        let (appraisal, snap) = await mind.hear(turn.text, prosody: turn.prosody, at: now, adjust: { cortex.adjust($0) })
        snapshot = snap
        voiceBaseline = await mind.voiceBaseline
        brain?.noteMind(appraisal, before: before, after: snap.code, at: now)
        let loudness = turn.prosody.map { ($0.loudnessDB + 32) / 12 } ?? 0
        sense(.heard(text: turn.text, durationS: turn.duration, loudnessVsBaseline: loudness, appraisal: appraisal))
        heardLog.append((turn.text, .answer(appraisal)))
        return .answer(appraisal)
    }

    func wordsFailed() { onNote?("words failed") }

    /// What `People.heard` does in the app (one face in view: a name is confirmed at once).
    func people(_ text: String, at now: Date) async {
        if person == nil, placeholder == nil {
            let p = await memory.placeholderPerson(session: peopleSession, at: now)
            placeholder = p.id
            onPerson?(p.id)
        }
        guard let id = person ?? placeholder else { return }
        let outcome = await memory.learn(from: text, about: id, at: now)
        if !outcome.introduced.isEmpty {
            extraNotes.append("They're introducing \(outcome.introduced.joined(separator: " and ")) to you. Say hello to them.")
        }
        guard let name = outcome.pendingName, person == nil else { return }
        switch await memory.confirm(name, for: id, at: now, choice: .ask) {
        case .named(let p, _), .merged(into: let p):
            person = p.id
            placeholder = nil
            onPerson?(p.id)
            extraNotes.append("Their name is \(p.name). You will remember it.")
            onNote?("learnt a name")
            sense(.identified(p.id, distance: Self.confirmedDistance))
        default:
            break
        }
    }

    func dnaParts(_ r: DNARequest) async -> DNAParts? {
        let now = r.now
        if r.pickNotes {
            sense(.promptSubmitted)
            let (_, effects) = cortex.cue(at: now)
            execute(effects)
        }
        var personInputs: PersonInputs?
        if let id = person, let p = await memory.person(id) {
            let lines = shareMemories ? await memory.promptMemories(for: id, limit: 9, now: now) : []
            personInputs = PersonInputs(person: p, promptMemories: lines)
        }
        let state = await mind.state
        let days = await mind.history(days: 30).map { DNADay(day: $0.day, interactions: $0.interactions, regard: $0.regard) }
        let body = BodyInputs(someoneHere: someoneHere, asleep: asleep, lastUserTurnAt: r.lastUserTurnAt,
                              lastContact: personInputs?.lastSeen)
        let context = DNAContext(aging: AgingInputs(state.age), inner: InnerStateCounters(state), rings: r.rings, body: body,
                                 daily: days, shareMemories: shareMemories, guardCorpus: r.corpus)
        var inputs = cortex.dnaInputs(at: now, memories: personInputs, turn: r.turn, appraisal: r.appraisal, context: context)
        if r.turn.kind == .initiative, !r.pickNotes {
            if let issued = initiativeNotes { inputs.stance.notes = issued }
            initiativeNotes = nil
        }
        let notes = extraNotes
        extraNotes = []
        return DNAParts(inputs: inputs, extraNotes: notes)
    }

    func brainStartedReply(_ reply: BrainReply) { consume(reply.events) }

    /// Consumes a reply stream the way DeeModel does (deeSaid per heard sentence).
    func consume(_ events: AsyncThrowingStream<ReplyEvent, Error>) {
        Task { @MainActor in
            do {
                for try await e in events {
                    switch e {
                    case .content:
                        self.speakingUntil = self.clock.now().addingTimeInterval(3)
                    case .sentenceFinished(let s, let heard):
                        self.onSentence?(s, heard)
                        if heard {
                            self.said.append(s)
                            self.sense(.deeSaid(tag: nil, sentence: s))
                        }
                    case .turnCompleted:
                        self.sense(.deeTurnFinished(text: ""))
                        if self.wakeMode == .phrase { self.wake?.replyEnded(toAccepted: true) }
                    default:
                        break
                    }
                }
            } catch {}
        }
    }

    func thinkingModeChanged(_ on: Bool) { onNote?("thinking \(on)") }

    // MARK: Wake (phrase mode)

    /// Phrase mode: the app's `WakeController` on the on-device `ear`, ticking every
    /// 0.25 s with `busy` (what keeps a window open), on the harness `clock`.
    func startWake(phrase: WakePhrase, ear: any WakeEar, clock: @escaping @Sendable () -> TimeInterval,
                   busy: @escaping @Sendable () -> Busy) async {
        wakeMode = .phrase
        wakePhrase = phrase
        let c = WakeController(phrase: phrase, ear: ear, mode: "harness", monotonic: clock)
        c.host = self
        wake = c
        await c.start()
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let w = self.wake else { return }
                w.tick(busy: busy())
            }
        }
    }

    func stopWake() async {
        tickTask?.cancel()
        tickTask = nil
        await wake?.stop()
    }

    /// The voice's connection state (the runner is the single consumer of `awakeStates`).
    func voiceState(_ s: CloudVoice.AwakeState) {
        guard wakeMode == .phrase, let w = wake else { return }
        switch s {
        case .awake: w.connected()
        case .failed(let p): w.connectFailed(p.message)
        case .waking, .dormant: break
        }
    }

    /// A tap outside the eyes ("tap to talk").
    func tapToTalk() { wake?.tapToTalk(captureFrame: voice?.captureFrame) }

    /// App parity (DeeModel.bargedIn, tune 5 F1): the brain's answer ended a floor hold, so
    /// the Cortex senses `.bargeInAnswered` (same floor bookkeeping as `.bargeIn`, but no
    /// `.stopSpeaking`: stopping here cancelled the very answer to a question asked over Dee).
    /// Its effects run as the app runs them.
    func bargedIn() {
        bargeInsSensed += 1
        onNote?("brain bargedIn")
        sense(.bargeInAnswered)
    }
}

/// What DeeModel does for the window, in the harness: the voice connects / sleeps,
/// everything else is recorded (no clips, no UI).
extension HarnessHost: WakeControllerHost {
    func wakeEyes() { onWake?("eyesWake") }
    func listeningOffEyes() { onWake?("eyesListeningOff") }
    func perkUp() { onWake?("perkUp") }
    func woken(by source: WakeSource) {
        asleep = false
        engaged = true
        onWake?("woken \(source.rawValue)")
    }
    func startNewConversation() {
        onWake?("newConversation")
        Task { await newConversation() }
    }
    func connect(resume: Bool, uplinkFrom: Int64?) {
        onWake?("connect resume=\(resume)")
        voice?.wake(uplinkFromFrame: uplinkFrom, resume: resume)
    }
    func disconnect() {
        onWake?("disconnect")
        voice?.sleep()
    }
    func sayGoodbye() { onWake?("goodbye") }
    func show(problem: String) { onWake?("problem \(problem)") }
    func clearProblem() { onWake?("problem cleared") }
}

/// `--brain realtime`: DeeBrain's real `RealtimeBrain` on a `HarnessHost` with real
/// DeeMind / DeeSelf / DeeMemory state in a temp directory, so every reply and initiative carries the current Dee DNA.
///
/// The brain is the single consumer of `CloudVoice.brainEvents` (it starts its own
/// loops), so the runner records the run from the wire (`SocketTap` +
/// `WireRecorder`) instead of from those events.
public final class RealtimeBrainAdapter: HarnessBrain, @unchecked Sendable {
    public let name = "realtime"
    public var ownsBrainEvents: Bool { true }
    public var supportsWake: Bool { true }
    public let clock = HarnessClock()
    public let stateDirectory: URL
    let scenario: Scenario
    let voiceName: String
    let mind: Mind
    let memory: MemoryStore
    let selfStore: SelfStore
    let toolbox: BrainToolbox
    private let personBox = Box<UUID?>(nil)
    private let traces = Box<[BrainTrace]>([])
    @MainActor private var brain: RealtimeBrain?
    @MainActor private var host: HarnessHost?

    /// - Parameter stateRoot: where this scenario's Mind / memory / self databases go.
    public init(scenario: Scenario, stateRoot: URL, voice: String) throws {
        self.scenario = scenario
        voiceName = voice
        let safe = scenario.name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        stateDirectory = stateRoot.appendingPathComponent(String(safe))
        try? FileManager.default.removeItem(at: stateDirectory)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        mind = try Mind(databaseURL: stateDirectory.appendingPathComponent("mind.sqlite"), now: clock.now())
        memory = try MemoryStore(databaseURL: stateDirectory.appendingPathComponent("memory.sqlite"))
        selfStore = try SelfStore(url: stateDirectory.appendingPathComponent("self.sqlite"))
        let box = personBox
        toolbox = BrainToolbox(tools: BrainToolbox.memoryTools(store: memory, currentPerson: { box.withLock { $0 } }))
    }

    public func configure(_ config: inout RealtimeSessionConfig) {
        var c = CloudSettings(voice: voiceName, model: config.model).sessionConfig(tools: toolbox.realtimeTools)
        c.endpoint = config.endpoint
        config = c
    }

    /// The session carries the DNA itself (tune 1): the socket factory is used unchanged.
    public func wrapSocketFactory(_ base: @escaping RealtimeSocketFactory) -> RealtimeSocketFactory { base }

    private let timingBox = Box<TimingProfile?>(nil)

    /// LAN modes: the brain runs on the provider's timing, as in the app.
    public func use(timing: TimingProfile) { timingBox.withLock { $0 = timing } }

    public func attach(voice: CloudVoice, log: HarnessLog) async {
        do {
            try await setUp(voice: voice, log: log)
        } catch {
            log.note("realtime brain set-up failed: \(error)")
        }
    }

    @MainActor
    private func setUp(voice: CloudVoice, log: HarnessLog) async throws {
        var person: UUID?
        if scenario.stranger != true {
            let setup = scenario.person ?? .init(name: "Alex", knownDays: 20)
            let met = clock.now().addingTimeInterval(-(setup.knownDays ?? 20) * 86_400)
            person = await memory.addPerson(named: setup.name ?? "Alex", at: met)?.id
        }
        personBox.withLock { $0 = person }
        let host = try await HarnessHost(mind: mind, memory: memory, selfStore: selfStore, person: person, clock: clock)
        let clock = self.clock
        let options: RealtimeBrain.Options = timingBox.withLock { $0 }.map { .init(timing: $0) } ?? .init()
        let brain = RealtimeBrain(voice: voice, host: host, toolbox: toolbox, options: options,
                                  clock: { clock.now() })
        host.brain = brain
        host.voice = voice
        host.onWake = { log.wake?($0) }
        host.onSentence = { text, heard in log.sentence?(text, heard) }
        let box = personBox
        host.onPerson = { id in box.withLock { $0 = id } }
        host.onNote = { log.note($0) }
        let traces = self.traces
        brain.onTrace = { t in
            traces.withLock { $0.append(t) }
            log.trace?("\(t)")
        }
        self.host = host
        self.brain = brain
    }

    public func start() async {
        await MainActor.run { () -> RealtimeBrain? in self.brain }?.start()
    }

    public func handle(_ event: CloudVoice.BrainEvent) async {}

    public func setTurnInstructions(_ instructions: String?) async {}

    public func speak(_ line: String, initiative: Bool) async -> SpeakResult? {
        guard let brain = await MainActor.run(body: { self.brain }) else { return .refused("no brain", retryable: false) }
        let mark = traces.withLock { $0.count }
        if initiative {
            let stream = brain.respond(.initiative(line), state: nil, effort: .low)
            await MainActor.run { self.host?.consume(stream) }
            // The brain answers in its loop: sent (a DNA went out) or refused.
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                let new = traces.withLock { Array($0.dropFirst(mark)) }
                for t in new {
                    switch t {
                    case .dnaSent(_, let kind, _, _, _, _, _, _, _) where kind == "initiative": return .sent
                    case .initiativeRefused(let why): return .refused(why, retryable: true)
                    case .requestFailed(let why):
                        return .refused(why, retryable: why.contains("userSpeaking") || why.contains("speaking") || why.contains("responseInFlight"))
                    default: continue
                    }
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return .refused("no decision within 2 s", retryable: false)
        }
        let result = Box<RealtimeBrain.SayOutcome?>(nil)
        Task { @MainActor in
            let o = await brain.say(line)
            result.withLock { $0 = o }
        }
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            if case .refused(let why)? = result.withLock({ $0 }) {
                return .refused(why, retryable: why.contains("userSpeaking") || why.contains("speaking") || why.contains("responseInFlight"))
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return .sent
    }

    public func perform(_ action: Scenario.HostAction) async -> String {
        guard let host = await MainActor.run(body: { self.host }) else { return "no host" }
        var done: [String] = []
        if action.leave == true { await MainActor.run { host.leave() }; done.append("left") }
        if let h = action.advanceHours { await host.advance(hours: h); done.append(String(format: "+%.0f h", h)) }
        if let day = action.advanceToWeekday,
           let h = Scenario.HostAction.hours(from: clock.now(), toNext: day, at: action.atHour ?? 18) {
            await host.advance(hours: h)
            done.append(String(format: "+%.1f h (next %@)", h, day))
        }
        if action.newConversation == true { await host.newConversation(); done.append("new conversation") }
        if action.arrive == true { await MainActor.run { host.arrive() }; done.append("arrived") }
        return done.joined(separator: ", ")
    }

    public func startWake(_ config: HarnessWakeConfig) async {
        guard let host = await MainActor.run(body: { self.host }) else { return }
        await host.startWake(phrase: config.phrase, ear: config.ear, clock: config.clock, busy: config.busy)
    }

    public func voiceState(_ state: CloudVoice.AwakeState) async {
        await MainActor.run { self.host?.voiceState(state) }
    }

    public func tapToTalk() async {
        await MainActor.run { self.host?.tapToTalk() }
    }

    /// Phrase mode: the window state the host answers by (nil: always open).
    public func windowOpen() async -> Bool? {
        await MainActor.run { () -> Bool? in
            guard let h = self.host, h.wakeMode == .phrase else { return nil }
            return h.windowAnswers
        }
    }

    public func detach() async {
        if let host = await MainActor.run(body: { self.host }) { await host.stopWake() }
        await MainActor.run {
            self.brain?.stop()
        }
        if let host = await MainActor.run(body: { self.host }) { await host.save() }
        await mind.flush(at: clock.now())
    }

    /// How many self writes reached the store, initiatives the Cortex started (for notes).
    public func stats() async -> (persisted: Int, initiatives: Int, commands: Int) {
        await MainActor.run { (self.host?.persisted ?? 0, self.host?.initiativesStarted ?? 0, self.host?.commands.count ?? 0) }
    }
}
