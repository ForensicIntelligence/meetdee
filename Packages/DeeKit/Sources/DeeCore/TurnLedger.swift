import Foundation

/// The bookkeeping behind Dee's turns (audit C2, C3, C9): which reply is current,
/// how much of it the user has actually heard, whether it must give way to them,
/// and which of the user's words carry over when a reply is withdrawn.
///
/// Pure and clock-free (every call takes `now`), so the app's turn machine can be
/// table-tested; `DeeModel` runs the voice and the language model and tells the
/// ledger what happened, and the ledger answers what that means.
public struct TurnLedger: Sendable {
    /// What a reply answers.
    public enum Kind: Sendable, Equatable {
        /// The user's words: it takes the floor.
        case reply
        /// Something non-verbal (a wave, a long stroke): "(The user waves at you.)".
        case event
        /// Her own initiative.
        case initiative

        /// Never starts over the user (audit C3): gated before the model runs and at
        /// every word until her voice starts, gives way to their first partial, and
        /// is held by the voice while they talk. Only an answer to their words may
        /// end their turn.
        public var givesWay: Bool { self != .reply }
    }

    /// One reply of Dee's, from the prompt to its last played word. Kept until the
    /// model's history matches what was actually heard of it (C9).
    public struct Reply: Sendable, Equatable {
        public let id: Int
        public let kind: Kind
        /// Her speaking rate for this reply (estimates how much of it was heard).
        public let rate: Double
        /// The conversation it belongs to (`TurnLedger.conversation`).
        public let conversation: Int
        /// The user's words it answers, exactly as sent to the model (nil: her
        /// initiative, or an event).
        public internal(set) var userText: String?
        public internal(set) var spoken = SpokenReply()
        public internal(set) var generating = true
        public internal(set) var generationEndedAt: Date?
        /// The model was asked: its history holds this turn.
        public internal(set) var inHistory = false
        public internal(set) var audioEverStarted = false
        /// When her voice started playing this reply; in the future when it was
        /// queued behind an aside (a laugh, a canned line) still playing.
        var audioStartedAt: Date?
        var playedBefore: TimeInterval = 0
        var voiced = VoicedTime()
        /// Streamed while an aside was waiting to start: it plays after the aside.
        var queuedBehindAside = false
        /// Characters streamed when her voice last went quiet on this reply.
        var charsAtLastFinish: Int?
        public internal(set) var audioFinished = false
        public internal(set) var stoppedAt: Date?
        var playedAtStop: TimeInterval?
        /// Stopped by a hush (palm, "stop"): the words it answered are not carried over.
        public internal(set) var hushed = false
        public internal(set) var settled = false

        /// How long her voice said this reply (until it was stopped). Wall time while it plays,
        /// capped by the time her output level was actually voiced once any level
        /// was seen: a wait for the model between sentences is not speech (L2).
        public func played(at now: Date) -> TimeInterval {
            if let playedAtStop { return playedAtStop }
            let wall = playedBefore + (audioStartedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
            return voiced.sawVoice ? min(wall, voiced.total) : wall
        }
    }

    /// What stopping the current reply needs from the app.
    public enum StopOutcome: Sendable, Equatable {
        /// Nothing (no reply, or it was already stopped or settled).
        case nothing
        /// The model is still writing it: cancel; settle when its turn ends.
        case cancelGeneration
        /// Bring the model's history in line with what was heard of this reply.
        case settle(Reply)
    }

    /// Words withdrawn from a stopped turn are answered with the next ones only this soon.
    public static let carryOverLife: TimeInterval = 30
    /// A finished reply whose voice never started (a held initiative the voice
    /// dropped, failed synthesis) is withdrawn after this long.
    public static let silentReplyTimeout: TimeInterval = 10
    /// An aside that has not started playing after this long never will.
    public static let asideStartTimeout: TimeInterval = 2

    public private(set) var reply: Reply?
    /// Bumped by `newConversation()`; carry-over never crosses it.
    public private(set) var conversation = 0
    private var counter = 0
    private var carryOver: (text: String, at: Date, conversation: Int)?
    /// Replies hushed after they were stopped some other way (a barge-in, then "stop").
    private var hushedIDs: Set<Int> = []
    private var aside: Aside?

    struct Aside: Sendable, Equatable {
        let requestedAt: Date
        let duration: TimeInterval
        var startedAt: Date?
    }

    public init() {}

    // MARK: Turns

    /// A new reply starts. Returns its id, and the previous reply if it still needs
    /// settling (settle it before the model runs).
    public mutating func begin(_ kind: Kind, rate: Double, at now: Date) -> (id: Int, previous: Reply?) {
        let previous = takeUnsettled()
        counter += 1
        reply = Reply(id: counter, kind: kind, rate: rate, conversation: conversation)
        return (counter, previous)
    }

    /// The reply is current and not stopped.
    public func isLive(_ id: Int) -> Bool { reply?.id == id && reply?.stoppedAt == nil }

    public mutating func setUserText(_ text: String, for id: Int) {
        if reply?.id == id { reply?.userText = text }
    }

    public mutating func enteredHistory(_ id: Int) {
        if reply?.id == id { reply?.inHistory = true }
    }

    /// The words to put before the user's next ones (C2: "Hi Dee." … "How was your
    /// day?"), if a withdrawn turn left any in this conversation within
    /// `carryOverLife`. Taken once.
    public mutating func takeCarryOver(at now: Date) -> String? {
        guard let c = carryOver else { return nil }
        carryOver = nil
        guard c.conversation == conversation, now.timeIntervalSince(c.at) < Self.carryOverLife else { return nil }
        return c.text
    }

    /// A reply she must not start now: it gives way, has not reached her voice, and
    /// the user holds the floor.
    public func mustGiveWay(userHoldsFloor: Bool) -> Bool {
        guard userHoldsFloor, let r = reply, r.kind.givesWay else { return false }
        return !r.settled && r.stoppedAt == nil && !r.audioEverStarted
    }

    /// The reply is written but her voice has not started it (still synthesising,
    /// or holding an initiative until the user is quiet).
    public var awaitingVoice: Bool {
        guard let r = reply else { return false }
        return !r.settled && !r.generating && !r.audioEverStarted && r.stoppedAt == nil && !r.spoken.text.isEmpty
    }

    /// A finished reply her voice never started, for `silentReplyTimeout`: withdraw it.
    public func isSilentTooLong(at now: Date) -> Bool {
        guard awaitingVoice, let ended = reply?.generationEndedAt else { return false }
        return now.timeIntervalSince(ended) > Self.silentReplyTimeout
    }

    /// The model finished the reply's turn. Returns the reply if it was stopped and
    /// now needs settling.
    /// - Parameter voiceSpeaking: her voice is playing something right now.
    public mutating func generationEnded(_ id: Int, voiceSpeaking: Bool, at now: Date) -> Reply? {
        guard var r = reply, r.id == id else { return nil }
        r.generating = false
        r.generationEndedAt = now
        if r.stoppedAt == nil {
            if r.spoken.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Nothing to say (a tool-only turn): history is exactly what was generated.
                r.settled = true
            } else if r.audioEverStarted, r.audioStartedAt == nil, !voiceSpeaking, r.charsAtLastFinish == r.spoken.text.count {
                // Her voice caught up and went quiet while the model was still busy
                // (a long tool round): every word was played.
                r.audioFinished = true
                r.settled = true
            }
        }
        reply = r
        return r.stoppedAt != nil ? takeUnsettled() : nil
    }

    // MARK: Stopping

    /// Stops the current reply where it is.
    /// - Parameter hush: the user asked for quiet (palm, "stop"): what she was
    ///   answering is not carried over to their next words — also when the reply was
    ///   already stopped by their barge-in a moment before (M1).
    public mutating func stop(hush: Bool, at now: Date) -> StopOutcome {
        if hush {
            carryOver = nil
            if let r = reply { hushedIDs.insert(r.id) }
        }
        guard var r = reply, !r.settled, r.stoppedAt == nil else { return .nothing }
        r.stoppedAt = now
        r.playedAtStop = r.played(at: now)
        if r.audioStartedAt == nil, r.audioEverStarted, r.charsAtLastFinish == r.spoken.text.count {
            // Her voice had caught up and gone quiet (the model was in a tool round):
            // everything streamed so far was heard, however long it took to say.
            let whole = Double(r.spoken.text.count) / SpokenReply.charactersPerSecond(rate: r.rate) + 1
            r.playedAtStop = max(r.playedAtStop ?? 0, whole)
        }
        r.hushed = hush
        reply = r
        if r.generating { return .cancelGeneration }
        if let taken = takeUnsettled() { return .settle(taken) }
        return .nothing
    }

    /// The current reply, marked settled, if it still needs settling and the model
    /// is between turns.
    public mutating func takeUnsettled() -> Reply? {
        guard var r = reply, !r.settled, !r.generating else { return nil }
        r.settled = true
        reply = r
        return r
    }

    /// What to do with a stopped reply's place in the model's history. A reply
    /// stopped after all of its streamed text was heard is still cut to that text:
    /// the model may have written on before the cancel reached it.
    public func settlement(of r: Reply, at now: Date) -> ReplySettlement {
        let decision = ReplySettlement.decide(streamed: r.spoken.text, audioStarted: r.audioEverStarted, audioFinished: r.audioFinished,
                                              playedSeconds: r.playedAtStop ?? r.played(at: now),
                                              charactersPerSecond: SpokenReply.charactersPerSecond(rate: r.rate))
        if decision == .keep, r.stoppedAt != nil, !r.audioFinished {
            return .truncate(r.spoken.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return decision
    }

    /// A reply was settled. Its user words carry over to their next ones when the
    /// turn was withdrawn — not after a hush, and never into a new conversation (L4).
    public mutating func settled(_ r: Reply, withdrawn: Bool, at now: Date) {
        guard withdrawn, !r.hushed, !hushedIDs.contains(r.id), r.conversation == conversation, let words = r.userText else { return }
        carryOver = (words, now, r.conversation)
    }

    /// A new conversation: nothing of the old one carries over.
    public mutating func newConversation() {
        conversation += 1
        reply = nil
        carryOver = nil
        hushedIDs.removeAll()
    }

    // MARK: Her voice (what was actually played, C9)

    /// The app asked her voice for an aside (a laugh, a canned line), which plays
    /// before anything streamed after it. Its audio is not the reply's (L2).
    /// - Parameters:
    ///   - duration: a generous estimate of how long it plays.
    ///   - voiceSpeaking: her voice is already playing (the aside joins it).
    public mutating func asideRequested(duration: TimeInterval, voiceSpeaking: Bool, at now: Date) {
        guard !voiceSpeaking else { return }
        aside = Aside(requestedAt: now, duration: max(0, duration))
    }

    /// A fragment of the reply went to her voice.
    /// - Parameter voiceSpeaking: her voice is already playing (an aside): the
    ///   reply joins it without a new `speakingStarted`, after the aside.
    public mutating func streamed(_ fragment: String, id: Int, voiceSpeaking: Bool, at now: Date) {
        guard var r = reply, r.id == id, r.stoppedAt == nil, !r.settled else { return }
        r.spoken.append(fragment)
        if r.audioStartedAt == nil {
            if voiceSpeaking {
                var start = now
                if let a = aside, let began = a.startedAt { start = max(now, began.addingTimeInterval(a.duration)) }
                r.audioStartedAt = start
                r.audioEverStarted = true
            } else if let a = aside, a.startedAt == nil, now.timeIntervalSince(a.requestedAt) < Self.asideStartTimeout {
                r.queuedBehindAside = true
            }
        }
        reply = r
    }

    /// Her voice started playing. An aside waiting to start is what started; a
    /// reply queued behind it starts when the aside should be over.
    public mutating func speakingStarted(at now: Date) {
        if var a = aside, a.startedAt == nil, now.timeIntervalSince(a.requestedAt) < Self.asideStartTimeout {
            a.startedAt = now
            aside = a
            guard var r = reply, r.queuedBehindAside, r.stoppedAt == nil, !r.settled, r.audioStartedAt == nil else { return }
            r.audioStartedAt = now.addingTimeInterval(a.duration)
            r.audioEverStarted = true
            reply = r
            return
        }
        aside = nil
        guard var r = reply, r.stoppedAt == nil, !r.settled, r.audioStartedAt == nil, !r.spoken.text.isEmpty else { return }
        r.audioStartedAt = now
        r.audioEverStarted = true
        reply = r
    }

    /// Her output level (~30 Hz while she speaks).
    public mutating func speechLevel(_ level: Double, at now: Date) {
        guard var r = reply, r.stoppedAt == nil, !r.settled, let start = r.audioStartedAt, now >= start else { return }
        r.voiced.sample(level, at: now)
        reply = r
    }

    /// Her voice went quiet: everything queued has played (or was stopped).
    public mutating func speakingFinished(at now: Date) {
        aside = nil
        guard var r = reply, r.stoppedAt == nil, !r.settled else { return }
        if let start = r.audioStartedAt {
            r.playedBefore += max(0, now.timeIntervalSince(start))
            r.audioStartedAt = nil
            r.voiced.pause()
            r.charsAtLastFinish = r.spoken.text.count
            if !r.generating { r.audioFinished = true; r.settled = true }
        }
        r.queuedBehindAside = false
        reply = r
    }
}

/// Time her output level was voiced: a word, or a short gap inside a sentence. Long
/// silences (waiting for the model or the synthesiser) don't count.
struct VoicedTime: Sendable, Equatable {
    /// Level above which a sample is speech (the meter reads 0 at -50 dB).
    static let threshold = 0.02
    /// Silence shorter than this after a voiced sample still counts (gaps between words).
    static let hangover: TimeInterval = 0.35
    /// The longest step one sample may add (a lost sample is not a long word).
    static let maxStep: TimeInterval = 0.1

    var total: TimeInterval = 0
    var sawVoice = false
    var lastSampleAt: Date?
    var lastVoicedAt: Date?

    mutating func sample(_ level: Double, at now: Date) {
        defer { lastSampleAt = now }
        let voiced = level > Self.threshold
        let inSpeech = voiced || lastVoicedAt.map { now.timeIntervalSince($0) < Self.hangover } ?? false
        if voiced {
            sawVoice = true
            lastVoicedAt = now
        }
        guard inSpeech, let last = lastSampleAt else { return }
        total += min(Self.maxStep, max(0, now.timeIntervalSince(last)))
    }

    /// Her voice stopped: the next sample starts a new stretch.
    mutating func pause() {
        lastSampleAt = nil
        lastVoicedAt = nil
    }
}

/// Whether the user holds the floor, so Dee's own sounds (initiatives, events,
/// laughs, canned lines) must wait (audit C3).
///
/// - Raw voice activity counts only while someone is engaged with her: a TV in an
///   empty room must not keep her awake forever or block everything (M4).
/// - The Cortex's view of the floor counts only while the user's words are still
///   coming: once an utterance has arrived — answered, a command, or not addressed
///   to her — a floor left at "user speaking" (no `.heard` reached the Cortex) is
///   stale (M2).
public struct UserFloor: Sendable, Equatable {
    /// A partial this recent: they are mid-sentence.
    public static let partialHold: TimeInterval = 2.5

    public private(set) var lastPartialAt = Date.distantPast
    public private(set) var lastActivityAt = Date.distantPast
    public private(set) var lastClosedAt = Date.distantPast

    public init() {}

    /// Live words she is attending to.
    public mutating func partial(at now: Date) {
        lastPartialAt = now
        lastActivityAt = now
    }

    /// A pause inside their turn.
    public mutating func paused(at now: Date) { lastActivityAt = now }

    /// Their utterance arrived (whatever became of it).
    public mutating func closed(at now: Date) {
        lastClosedAt = now
        lastPartialAt = .distantPast
    }

    /// - Parameters:
    ///   - voiceActive: the voice hears someone talking right now (any voice).
    ///   - engaged: someone is with Dee (in view, or spoke to her recently).
    ///   - cortexUserTurn: the Cortex's floor is the user's (speaking or paused).
    ///   - cortexYielding: Dee is yielding the floor after a barge-in.
    public func holds(at now: Date, voiceActive: Bool, engaged: Bool, cortexUserTurn: Bool, cortexYielding: Bool) -> Bool {
        if engaged, voiceActive { return true }
        if now.timeIntervalSince(lastPartialAt) < Self.partialHold { return true }
        if cortexYielding { return true }
        return cortexUserTurn && lastActivityAt > lastClosedAt
    }
}
