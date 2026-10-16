import DeeCore
import DeeWake
import Foundation

/// What the app (DeeModel) does for the conversation window. All on the main actor;
/// nothing here may touch the network except `connect`.
@MainActor
public protocol WakeControllerHost: AnyObject {
    /// The instant "I heard you" look (before any network call).
    func wakeEyes()
    /// The distinct "not listening" look (soft idle drift) + optional soft local chime.
    func listeningOffEyes()
    /// A candidate match: she perks up a little (no state change, no network).
    func perkUp()
    /// Clear `sleeping`, stamp lastEngagedAt.
    func woken(by source: WakeSource)
    /// Start a fresh conversation first (dormant ≥ 300 s): no resume seed.
    func startNewConversation()
    /// Connect (`CloudVoice.wake`); the uplink starts at `uplinkFrom` (24 kHz capture
    /// frame, already − 0.3 s; nil = now).
    func connect(resume: Bool, uplinkFrom: Int64?)
    /// `CloudVoice.sleep()`: close the uplink and the socket, stop reconnects.
    func disconnect()
    /// Her local goodbye (a clip, never the network).
    func sayGoodbye()
    func show(problem: String)
    /// The ear is back: drop its problem.
    func clearProblem()
}

/// Drives the pure `ConversationWindow` for the app (providers-wake-onboarding §4):
/// feeds it the local wake ear's hits, taps, greetings, the voice's connection state,
/// accepted turns and ticks, performs its actions through the host in order, keeps the
/// usage counters, the false-wake backoff and the logs (numbers only).
///
/// W1: there is no input here for a server transcript — only the on-device ear, a tap
/// or the opt-in greeting can open the window.
@MainActor
public final class WakeController {
    public weak var host: (any WakeControllerHost)?
    public private(set) var window = ConversationWindow()
    public private(set) var phrase: WakePhrase
    public private(set) var availability: EarAvailability = .notAsked
    public private(set) var usage: UsageCounter
    /// Privacy-safe lines ("window closed: open 42 s, …"); the app prints them.
    public private(set) var log: [String] = []
    /// Mode for the usage buckets (`ProviderMode.rawValue`).
    public var mode: String
    /// Persist the counters (UserDefaults JSON in the app).
    public var persistUsage: ((UsageCounter) -> Void)?
    /// The one initiative a greeting window allows has not been used yet.
    public private(set) var greetingInitiativeOpen = false

    /// The on-device ear (set before `start`).
    public var ear: (any WakeEar)?
    private let monotonic: () -> TimeInterval
    private let wallClock: () -> Date
    private var tasks: [Task<Void, Never>] = []
    private var connectedAt: TimeInterval?
    private var openedAt: TimeInterval?
    private var responses = 0

    public init(phrase: WakePhrase, ear: (any WakeEar)?, mode: String, usage: UsageCounter = UsageCounter(),
                monotonic: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                wallClock: @escaping () -> Date = { Date() }) {
        self.phrase = phrase
        self.ear = ear
        self.mode = mode
        self.usage = usage
        self.monotonic = monotonic
        self.wallClock = wallClock
    }

    // MARK: State

    public var isOpen: Bool { window.isOpen }
    public var isDormant: Bool { window.isDormant }
    /// The one rule every host shares (`Engagement.answers`).
    public var answers: Bool { Engagement.answers(window) }
    /// Initiatives, Cortex cues, curiosity, asides, touch/sound model turns.
    public var initiativeAllowed: Bool { Engagement.initiativeAllowed(window: window.state) }
    public var matcher: WakeMatcher { WakeMatcher(phrase) }

    // MARK: Ear

    /// Starts the on-device ear and listens to it. Never starts anything else.
    public func start() async {
        guard let ear, tasks.isEmpty else { return }
        tasks.append(Task { [weak self] in
            for await hit in ear.hits {
                guard let self else { return }
                self.input(.phraseHeard(hit))
            }
        })
        tasks.append(Task { [weak self] in
            for await _ in ear.candidates {
                guard let self, self.window.isDormant else { continue }
                self.host?.perkUp()
            }
        })
        tasks.append(Task { [weak self] in
            for await a in ear.availability {
                guard let self else { return }
                self.earChanged(a)
            }
        })
        await ear.start(phrase: phrase)
    }

    /// Back in the foreground: an ear that was unavailable (permission, assets, too
    /// warm) is started again so it re-checks.
    public func recheckEar() async {
        guard let ear, !availability.isReady, !tasks.isEmpty else { return }
        await ear.start(phrase: phrase)
    }

    public func stop() async {
        for t in tasks { t.cancel() }
        tasks = []
        await ear?.stop()
    }

    public func setPhrase(_ p: WakePhrase) async {
        phrase = p
        await ear?.setPhrase(p)
    }

    func earChanged(_ a: EarAvailability) {
        let was = availability
        availability = a
        if a.isReady {
            if !was.isReady, was != .notAsked { host?.clearProblem() }
            return
        }
        input(.earLost(a))
    }

    // MARK: Inputs

    public func tapToTalk(captureFrame: Int64?) { input(.tapToTalk(captureFrame: captureFrame)) }
    public func greetingDue() { input(.greetingDue) }
    public func connected() { input(.connected) }
    public func connectFailed(_ problem: String) { input(.connectFailed(problem)) }
    public func acceptedTurn() { input(.acceptedTurn) }
    public func replyEnded(toAccepted: Bool) { input(.replyEnded(toAccepted: toAccepted)) }
    public func closeCommand() { input(.closeCommand) }
    public func backgrounded() { input(.background) }
    public func providerChanged() { input(.providerChanged) }
    public func tick(busy: Busy) { input(.tick(busy: busy)) }

    /// A response she produced in this window (reply, initiative, greeting).
    public func responseStarted() {
        guard !window.isDormant else { return }
        responses += 1
        usage.addResponse(mode: mode, at: wallClock())
        persistUsage?(usage)
    }

    /// The greeting window's one initiative was used.
    public func usedGreetingInitiative() { greetingInitiativeOpen = false }

    @discardableResult
    public func input(_ i: ConversationWindow.Input) -> [ConversationWindow.Action] {
        let before = window.state
        let actions = window.handle(i, now: monotonic())
        for a in actions { perform(a, before: before) }
        return actions
    }

    // MARK: Actions

    private func perform(_ a: ConversationWindow.Action, before: ConversationWindow.State) {
        let now = monotonic()
        switch a {
        case .eyesWake:
            host?.wakeEyes()
        case .woken(let source):
            host?.woken(by: source)
        case .connect(let resume):
            if !resume { host?.startNewConversation() }
            var from: Int64?
            if case .waking(_, let onset, _) = window.state { from = onset.map { max(0, $0 - ConversationWindow.prerollFrames) } }
            host?.connect(resume: resume, uplinkFrom: from)
        case .warmUp:
            break // the cascaded socket warms itself up on connect (DeeLocal)
        case .markUsageStart:
            openedAt = now
            responses = 0
            connectedAt = nil
            usage.addWindow(mode: mode, at: wallClock())
            persistUsage?(usage)
        case .openUplink:
            // CloudVoice opens the uplink itself at connect, from the frame given to `connect`.
            connectedAt = now
        case .allowInitiative:
            greetingInitiativeOpen = true
        case .closeUplink:
            break // part of `disconnect` (CloudVoice.sleep closes the uplink first)
        case .sayGoodbye:
            host?.sayGoodbye()
        case .disconnect:
            greetingInitiativeOpen = false
            host?.disconnect()
        case .logUsage:
            let streamed = connectedAt.map { max(0, now - $0) } ?? 0
            let open = openedAt.map { max(0, now - $0) } ?? 0
            usage.addStreamed(streamed, mode: mode, at: wallClock())
            persistUsage?(usage)
            log.append(UsageCounter.windowLog(openSeconds: open, streamedSeconds: streamed, responses: responses, mode: mode))
            connectedAt = nil
            openedAt = nil
        case .eyesListeningOff:
            host?.listeningOffEyes()
        case .problem(let text):
            host?.show(problem: text)
        case .likelyFalseWake:
            usage.addFalseWake(mode: mode, at: wallClock())
            persistUsage?(usage)
        case .matcherStrict(let strict):
            Task { [ear] in await ear?.setStrict(strict) }
        }
    }
}
