import Foundation

/// What woke her.
public enum WakeSource: String, Sendable, Equatable, Codable {
    /// The wake phrase, heard on the device.
    case phrase
    /// A tap outside the eyes / the "Tap to talk" chip.
    case tap
    /// "Speak first when she sees someone": one greeting window for a newly arrived
    /// known person.
    case greeting
}

/// What keeps an open window from timing out (TurnPolicy.initiativeAllowed inputs).
/// `someoneTalking` must be the turn policy's notion of a person talking to her now
/// (EarCore's bed-proof voice with a turn in progress), never raw speech energy.
public struct Busy: Sendable, Equatable {
    public var replyOutstanding: Bool
    public var toolRunning: Bool
    public var awaitingWords: Bool
    public var holdActive: Bool
    public var someoneTalking: Bool

    public init(replyOutstanding: Bool = false, toolRunning: Bool = false, awaitingWords: Bool = false,
                holdActive: Bool = false, someoneTalking: Bool = false) {
        self.replyOutstanding = replyOutstanding
        self.toolRunning = toolRunning
        self.awaitingWords = awaitingWords
        self.holdActive = holdActive
        self.someoneTalking = someoneTalking
    }

    public static let idle = Busy()
    public var any: Bool { replyOutstanding || toolRunning || awaitingWords || holdActive || someoneTalking }
}

/// DORMANT ⇄ CONVERSATION (contract §4). Pure: the hosts (DeeModel, StandaloneHost,
/// HarnessHost) feed inputs with a monotonic `now` (seconds) and perform the actions
/// in order.
///
/// DORMANT means silent: no socket, no request, no audio. The only ways out are the
/// on-device `WakeEar` hit, a tap, or the opt-in greeting — never a server transcript
/// (W1): there is deliberately no input carrying one.
public struct ConversationWindow: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case dormant
        /// Connecting. `onsetFrame` is the wake utterance's start on the 24 kHz capture
        /// clock (phrase onset, or the tap time); nil = from now (greeting).
        case waking(source: WakeSource, onsetFrame: Int64?, at: TimeInterval)
        /// `lastAccepted` = the last accepted turn / her reply to one / phrase / tap.
        case open(lastAccepted: TimeInterval, openedAt: TimeInterval)
    }

    public enum Input: Sendable, Equatable {
        /// The on-device ear heard the phrase. Also refines the onset while waking
        /// when a final result places it (`onsetFromFinal`).
        case phraseHeard(WakeHit)
        /// A tap outside the eyes / on the chip; `captureFrame` = 24 kHz frame at the tap.
        case tapToTalk(captureFrame: Int64?)
        /// Speak-first is on and a known person just arrived (host: ≤ 1 per arrival).
        case greetingDue
        case connected
        case connectFailed(String)
        /// A user turn her HeardRule answered or held (not ignored / echo / misheard).
        case acceptedTurn
        /// Her reply ended; `toAccepted` = it answered an accepted turn (initiatives and
        /// replies to unanswered initiatives don't keep the window open).
        case replyEnded(toAccepted: Bool)
        case tick(busy: Busy)
        /// "go to sleep" / "stop listening" / "that's all", with or without the phrase.
        case closeCommand
        case background
        case providerChanged
        /// The ear became unavailable (permission, assets, thermal).
        case earLost(EarAvailability)
    }

    public enum Action: Sendable, Equatable {
        /// Instant eye reaction (the opposite of `eyesListeningOff`).
        case eyesWake
        /// Clear `sleeping`, stamp lastEngagedAt.
        case woken(WakeSource)
        /// `CloudVoice.wake`: open the provider link; `resume` = re-seed the recent
        /// conversation (false after ≥ 300 s dormant: a new conversation).
        case connect(resume: Bool)
        case warmUp
        case markUsageStart
        /// Start the uplink from this 24 kHz capture frame (onset − 0.3 s), nil = now.
        case openUplink(fromFrame: Int64?)
        /// The greeting window: one initiative allowed.
        case allowInitiative
        case closeUplink
        /// Play her local goodbye clip (no network).
        case sayGoodbye
        /// `CloudVoice.sleep()`: close the socket, stop reconnect/rollover, restart the ear.
        case disconnect
        case logUsage
        /// The distinct "not listening" look (soft idle drift), on every → dormant.
        case eyesListeningOff
        case problem(String)
        /// A phrase-woken window closed with no accepted turn (UsageCounter.falseWakes).
        case likelyFalseWake
        /// Matcher strictness for the false-wake backoff (`WakeEar.setStrict`).
        case matcherStrict(Bool)
    }

    // MARK: Constants (contract §3/§4)

    public static let idleClose: TimeInterval = 60
    public static let hardCap: TimeInterval = 600
    public static let wakingTimeout: TimeInterval = 6
    /// Dormant this long → the next window is a new conversation (no resume seed).
    public static let resumeLimit: TimeInterval = 300
    /// The uplink starts this long before the wake onset.
    public static let prerollSeconds: TimeInterval = 0.3
    public static let prerollFrames: Int64 = 7_200
    public static let falseWakeLimit = 3
    public static let falseWakeSpan: TimeInterval = 600
    public static let strictFor: TimeInterval = 900

    public private(set) var state: State = .dormant
    /// Accepted turns in the current window.
    public private(set) var acceptedTurns = 0
    public private(set) var strictUntil: TimeInterval?
    private var dormantSince: TimeInterval?
    private var lastAcceptedTurn: TimeInterval = 0
    private var lastBusy: TimeInterval?
    private var wokenBy: WakeSource?
    private var onsetFromFinal = false
    private var falseWakes: [TimeInterval] = []

    public init() {}

    public var isOpen: Bool { if case .open = state { true } else { false } }
    public var isDormant: Bool { state == .dormant }
    public var isStrict: Bool { strictUntil != nil }
    public var source: WakeSource? { wokenBy }

    public mutating func handle(_ input: Input, now: TimeInterval) -> [Action] {
        switch state {
        case .dormant:
            return dormant(input, now: now)
        case .waking(let source, let onset, let at):
            return waking(input, source: source, onset: onset, at: at, now: now)
        case .open(let last, let opened):
            return open(input, lastAccepted: last, openedAt: opened, now: now)
        }
    }

    // MARK: - States

    private mutating func dormant(_ input: Input, now: TimeInterval) -> [Action] {
        switch input {
        case .phraseHeard(let hit):
            onsetFromFinal = hit.onsetFromFinal
            return wake(.phrase, onset: hit.onsetFrame ?? hit.detectedFrame, now: now)
        case .tapToTalk(let frame):
            onsetFromFinal = false
            return wake(.tap, onset: frame, now: now)
        case .greetingDue:
            onsetFromFinal = false
            return wake(.greeting, onset: nil, now: now)
        case .earLost(let a):
            return [.problem(a.problemText ?? EarAvailability.unavailableText)]
        case .tick:
            return expireStrict(now)
        default:
            // acceptedTurn / replyEnded / connected … while dormant: nothing (W1/W2).
            return []
        }
    }

    private mutating func wake(_ source: WakeSource, onset: Int64?, now: TimeInterval) -> [Action] {
        let resume = dormantSince.map { now - $0 < Self.resumeLimit } ?? true
        state = .waking(source: source, onsetFrame: onset, at: now)
        wokenBy = source
        acceptedTurns = 0
        lastBusy = nil
        return [.eyesWake, .woken(source), .connect(resume: resume), .warmUp, .markUsageStart]
    }

    private mutating func waking(_ input: Input, source: WakeSource, onset: Int64?, at: TimeInterval, now: TimeInterval) -> [Action] {
        switch input {
        case .connected:
            state = .open(lastAccepted: now, openedAt: now)
            lastAcceptedTurn = now
            let from = onset.map { max(0, $0 - Self.prerollFrames) }
            var actions: [Action] = [.openUplink(fromFrame: from)]
            if source == .greeting { actions.append(.allowInitiative) }
            return actions
        case .connectFailed(let p):
            return close(now: now, extra: [.problem(p)], countFalseWake: false)
        case .phraseHeard(let hit):
            // A final result placing the onset better than the first (volatile) hit.
            if source == .phrase, hit.onsetFromFinal, !onsetFromFinal, let f = hit.onsetFrame {
                onsetFromFinal = true
                state = .waking(source: source, onsetFrame: f, at: at)
            }
            return []
        case .tick:
            if now - at >= Self.wakingTimeout {
                return close(now: now, extra: [.problem(Self.connectTimeoutText)], countFalseWake: false)
            }
            return []
        case .closeCommand, .background, .providerChanged:
            return close(now: now, countFalseWake: false)
        case .earLost(let a):
            return close(now: now, extra: [.problem(a.problemText ?? EarAvailability.unavailableText)], countFalseWake: false)
        default:
            return []
        }
    }

    private mutating func open(_ input: Input, lastAccepted: TimeInterval, openedAt: TimeInterval, now: TimeInterval) -> [Action] {
        switch input {
        case .acceptedTurn:
            acceptedTurns += 1
            lastAcceptedTurn = now
            state = .open(lastAccepted: now, openedAt: openedAt)
            return []
        case .replyEnded(let toAccepted):
            if toAccepted { state = .open(lastAccepted: now, openedAt: openedAt) }
            return []
        case .phraseHeard, .tapToTalk:
            state = .open(lastAccepted: now, openedAt: openedAt)
            return []
        case .tick(let busy):
            if busy.any { lastBusy = now }
            let quietFrom = max(lastAccepted, lastBusy ?? lastAccepted)
            if now - lastAcceptedTurn >= Self.hardCap || (!busy.any && now - quietFrom >= Self.idleClose) {
                return close(now: now, countFalseWake: true)
            }
            return []
        case .closeCommand:
            return close(now: now, goodbye: true, countFalseWake: false)
        case .background, .providerChanged:
            return close(now: now, countFalseWake: false)
        case .earLost(let a):
            return close(now: now, extra: [.problem(a.problemText ?? EarAvailability.unavailableText)], countFalseWake: false)
        case .connected, .connectFailed, .greetingDue:
            return []
        }
    }

    // MARK: - Closing

    private mutating func close(now: TimeInterval, goodbye: Bool = false, extra: [Action] = [], countFalseWake: Bool) -> [Action] {
        let wasOpen = isOpen
        var actions: [Action] = []
        if wasOpen { actions.append(.closeUplink) }
        if goodbye { actions.append(.sayGoodbye) }
        actions.append(.disconnect)
        if wasOpen { actions.append(.logUsage) }
        actions += extra
        actions.append(.eyesListeningOff)
        if countFalseWake, wokenBy == .phrase, acceptedTurns == 0 {
            actions.append(.likelyFalseWake)
            falseWakes = falseWakes.filter { now - $0 < Self.falseWakeSpan } + [now]
            if falseWakes.count >= Self.falseWakeLimit {
                if strictUntil == nil { actions.append(.matcherStrict(true)) }
                strictUntil = now + Self.strictFor
                falseWakes.removeAll()
            }
        }
        state = .dormant
        dormantSince = now
        wokenBy = nil
        return actions
    }

    private mutating func expireStrict(_ now: TimeInterval) -> [Action] {
        guard let until = strictUntil, now >= until else { return [] }
        strictUntil = nil
        return [.matcherStrict(false)]
    }

    static let connectTimeoutText = "I couldn't connect in time — try again"
}

/// The one engagement rule every host calls (contract §4): an open window means she
/// is engaged and addressed; outside it nothing is answered. Her name in a server or
/// LAN transcript never changes this (W1).
public enum Engagement {
    public static func answers(window: ConversationWindow.State) -> Bool {
        if case .open = window { return true }
        return false
    }

    public static func answers(_ window: ConversationWindow) -> Bool { answers(window: window.state) }

    /// Initiatives, Cortex cues, curiosity, asides, touch/sound model turns and clip
    /// rendering: only inside an open window (a greeting window is one).
    public static func initiativeAllowed(window: ConversationWindow.State) -> Bool { answers(window: window) }
}
