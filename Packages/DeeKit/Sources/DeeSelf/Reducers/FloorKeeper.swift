import DeeCore
import Foundation

/// Sub-reducer 1 — the conversational floor (SELF.md §4.2, §3.5).
///
/// Owns: `momentary.floor`, `momentary.llmTag` (tag reconciliation),
/// `momentary.floorEvents`, `momentary.aversionUntil`, `ongoing.cutOff`,
/// `ongoing.turnsThisConversation`, and Dee-interrupts detection.
/// Requests: gaze for Dee's turn (`.deeTurn`: user / thinking aversion / away while
/// thinking) and the user's turn (`.userTurn`: user, also while yielding); the
/// `thinking` signature reaction on `.promptSubmitted`; the cut-off note.
/// Reads: voice percepts, the mood snapshot, the live reflex.
///
/// Status: complete for 0.5.1 (+ 0.5.1 review fixes: the reconciled tag is capped and
/// refreshed per sentence, `.deeSpeaking` times out, a late `.deeSaid` after a barge-in
/// is ignored, and a barge-in during the user's own turn keeps the user's floor).
/// Voice-loop fixes (audit C3): Dee's own sound during the user's turn does not end
/// it, and a pause after a barge-in hands the floor to the user (not a timed yield).
/// Review fix (M2): `.userSpeaking` times out too, when their words never arrive as
/// `.heard` (a spoken command, an utterance she did not answer).
public struct FloorKeeper: SubReducer {
    public static let name = "FloorKeeper"

    /// The reconciled tag stays this long after speech ends.
    public static let tagLinger: TimeInterval = 1.5
    /// The user resuming within this long of Dee starting counts as Dee interrupting.
    public static let interruptWindow: TimeInterval = 1
    /// Thinking aversion at sentence starts.
    public static let aversionChance = 0.3
    public static let aversionDuration: TimeInterval = 0.6
    /// Failsafes so a lost event can't wedge the floor.
    public static let yieldingTimeout: TimeInterval = 2
    public static let pausedTimeout: TimeInterval = 12
    /// No partial or pause for this long while `.userSpeaking` (their final words
    /// never reached the Cortex: a spoken command, an utterance not answered) → idle.
    public static let userSpeakingTimeout: TimeInterval = 8
    public static let thinkingTimeout: TimeInterval = 45
    /// No sentence for this long while `.deeSpeaking` (a lost `speakingFinished`) → idle.
    public static let speakingTimeout: TimeInterval = 20
    /// A reconciled tag lives at most this long past its latest sentence.
    public static let speakingTagCap: TimeInterval = 15

    /// When the current user turn started (for Listener's "spoken ≥ 1.5 s" rule).
    public private(set) var userTurnStarted: Date?
    /// Sentences Dee has started in the current reply.
    public private(set) var sentencesThisReply = 0
    /// The last reconciliation verdict (tests, traces).
    public private(set) var lastVerdict: TagReconciler.Verdict?
    /// When Dee last started a sentence (speaking timeout).
    public private(set) var lastSentenceAt: Date?
    /// When the user's turn last showed life: a partial or a pause (speaking timeout).
    public private(set) var lastUserSignAt: Date?
    /// The current tag is lingering after speech ended (never refreshed by a sentence).
    var tagLingering = false

    public init() {}

    public mutating func reduce(_ p: Percept, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        let now = m.now
        var effects: [Effect] = []
        switch p {
        case .partial:
            lastUserSignAt = now
            userResumed(&m, now: now, effects: &effects)

        case .pause(let turnEnd, let hesitation):
            lastUserSignAt = now
            switch m.momentary.floor {
            case .userSpeaking:
                m.momentary.floor = .userPaused(since: now, turnEnd: turnEnd, hesitation: hesitation)
            case .userPaused(let since, _, _):
                m.momentary.floor = .userPaused(since: since, turnEnd: turnEnd, hesitation: hesitation)
            case .yielding:
                // They barged in and are mid-turn (a voice without live partials only
                // reports their pauses): their floor, not a 2 s yield that times out
                // to idle while they are still talking.
                userTurnStarted = userTurnStarted ?? now
                m.momentary.floorEvents.append(.userStarted)
                m.momentary.floor = .userPaused(since: now, turnEnd: turnEnd, hesitation: hesitation)
            default:
                break   // a stale pause estimate after the turn ended
            }

        case .heard:
            if !m.momentary.floor.isUserTurn { userResumed(&m, now: now, effects: &effects) }
            m.momentary.floor = .idle
            m.ongoing.turnsThisConversation += 1
            m.momentary.floorEvents.append(.userFinished)
            userTurnStarted = nil

        case .promptSubmitted:
            m.momentary.floor = .deeThinking(since: now)
            m.momentary.requestReaction(.thinking, by: Self.name)
            sentencesThisReply = 0

        case .speakingStarted:
            // A sound while the user holds the floor (a laugh, a canned line) is an
            // interjection, not Dee taking her turn: their turn stays open, so their
            // next words are not misread as them interrupting her (audit C3). Her
            // reply's sentences (`.deeSaid`) still take the floor.
            if !m.momentary.floor.isUserTurn {
                if case .deeSpeaking = m.momentary.floor {} else { m.momentary.floor = .deeSpeaking(since: now) }
            }
            m.ongoing.cutOff = false

        case .deeSaid(let tag, _):
            // A sentence that was already in flight when the user barged in: stale.
            if case .yielding = m.momentary.floor { break }
            if case .deeSpeaking = m.momentary.floor {} else { m.momentary.floor = .deeSpeaking(since: now) }
            lastSentenceAt = now
            let cap = now.addingTimeInterval(Self.speakingTagCap)
            if let tag {
                let reflex = m.momentary.reflex?.live(at: now)
                let r = TagReconciler.reconcile(tag, mind: m.ongoing.mind, liveReflex: reflex)
                lastVerdict = r.verdict
                if r.verdict == .substituted { m.momentary.floorEvents.append(.tagSubstituted) }
                m.momentary.llmTag = Timed(r.emotion, until: cap)
                tagLingering = false
            } else if let current = m.momentary.llmTag {
                if current.live(at: now) == nil {
                    m.momentary.llmTag = nil   // an untagged reply after the last one faded
                } else if !tagLingering {
                    m.momentary.llmTag = Timed(current.value, until: cap)   // still this reply's tag
                }
            }
            // Thinking aversion at 30% of sentence starts (never the first).
            // TODO(0.5.2): "never on the final sentence" needs the chunker to flag the last one.
            if sentencesThisReply > 0, rng.chance(Self.aversionChance) {
                m.momentary.aversionUntil = now.addingTimeInterval(Self.aversionDuration)
            }
            sentencesThisReply += 1
            m.momentary.floorEvents.append(.deeSentence)

        case .speakingFinished:
            if case .deeSpeaking = m.momentary.floor { m.momentary.floor = .idle }
            lingerTag(&m, now: now)
            m.momentary.floorEvents.append(.deeFinished)

        case .deeTurnFinished:
            if case .deeThinking = m.momentary.floor { m.momentary.floor = .idle }

        case .bargeIn:
            if case .deeSpeaking(let since) = m.momentary.floor, now.timeIntervalSince(since) <= Self.interruptWindow {
                m.momentary.floorEvents.append(.deeInterrupted)
            }
            // A partial usually arrives first and already gave the user the floor: keep it.
            if !m.momentary.floor.isUserTurn { m.momentary.floor = .yielding(since: now) }
            if !m.ongoing.cutOff { m.ongoing.raise(.cutOff(), by: Self.name) }
            m.ongoing.cutOff = true
            m.momentary.floorEvents.append(.cutOff)
            lingerTag(&m, now: now)
            effects.append(.stopSpeaking)

        case .conversationStarted:
            m.momentary.floor = .idle
            m.momentary.llmTag = nil
            m.momentary.aversionUntil = nil
            userTurnStarted = nil
            sentencesThisReply = 0

        case .asleep(true):
            m.momentary.floor = .idle
            m.momentary.llmTag = nil
            userTurnStarted = nil

        case .tick:
            switch m.momentary.floor {
            case .yielding(let since) where now.timeIntervalSince(since) > Self.yieldingTimeout:
                m.momentary.floor = .idle
            case .userPaused(let since, _, _) where now.timeIntervalSince(since) > Self.pausedTimeout:
                m.momentary.floor = .idle
                userTurnStarted = nil
            case .userSpeaking(let since) where now.timeIntervalSince(max(since, lastUserSignAt ?? since)) > Self.userSpeakingTimeout:
                m.momentary.floor = .idle
                userTurnStarted = nil
            case .deeThinking(let since) where now.timeIntervalSince(since) > Self.thinkingTimeout:
                m.momentary.floor = .idle
            case .deeSpeaking(let since) where now.timeIntervalSince(max(since, lastSentenceAt ?? since)) > Self.speakingTimeout:
                m.momentary.floor = .idle
                lingerTag(&m, now: now)
            default:
                break
            }

        default:
            break
        }
        requestGaze(&m, now: now)
        return effects
    }

    public mutating func conversationStarted(at d: Date, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        m.ongoing.turnsThisConversation = 0
        m.ongoing.cutOff = false
        return []
    }

    /// §5 gaze for the floor: Dee's turn (4), the user's turn and yielding (5).
    func requestGaze(_ m: inout Moment, now: Date) {
        switch m.momentary.floor {
        case .deeSpeaking:
            if let until = m.momentary.aversionUntil, now < until {
                m.momentary.requestGaze(.away, hold: until.timeIntervalSince(now), priority: .deeTurn, by: Self.name)
            } else {
                m.momentary.requestGaze(.user, hold: 1, priority: .deeTurn, by: Self.name)
            }
        case .deeThinking:
            m.momentary.requestGaze(.away, hold: 0.6, priority: .deeTurn, by: Self.name)
        case .userSpeaking, .userPaused, .yielding:
            m.momentary.requestGaze(.user, hold: 1, priority: .userTurn, by: Self.name)
        case .idle:
            break
        }
    }

    /// The user is talking (a partial, or a final with no partials before it).
    mutating func userResumed(_ m: inout Moment, now: Date, effects: inout [Effect]) {
        switch m.momentary.floor {
        case .userSpeaking:
            break
        case .userPaused:
            m.momentary.floor = .userSpeaking(since: userTurnStarted ?? now)
        case .deeSpeaking(let since):
            // Half-duplex: speech over Dee means a barge-in is coming; if it came within
            // 1 s of her starting, she interrupted them.
            if now.timeIntervalSince(since) <= Self.interruptWindow {
                m.momentary.floorEvents.append(.deeInterrupted)
            }
            m.momentary.floor = .userSpeaking(since: now)
            userTurnStarted = now
            m.momentary.floorEvents.append(.userStarted)
            lingerTag(&m, now: now)
        case .deeThinking, .idle, .yielding:
            m.momentary.floor = .userSpeaking(since: now)
            userTurnStarted = now
            m.momentary.floorEvents.append(.userStarted)
        }
    }

    mutating func lingerTag(_ m: inout Moment, now: Date) {
        if let t = m.momentary.llmTag, t.until > now.addingTimeInterval(Self.tagLinger) {
            m.momentary.llmTag = Timed(t.value, until: now.addingTimeInterval(Self.tagLinger))
        }
        if m.momentary.llmTag != nil { tagLingering = true }
    }

    public static func slice(of m: Moment) -> [String: String] {
        [
            "floor": m.momentary.floor.name,
            "llmTag": m.momentary.llmTag?.live(at: m.now)?.rawValue ?? "-",
            "cutOff": String(m.ongoing.cutOff),
            "turns": String(m.ongoing.turnsThisConversation),
            "events": m.momentary.floorEvents.map(\.rawValue).joined(separator: ","),
        ]
    }
}
