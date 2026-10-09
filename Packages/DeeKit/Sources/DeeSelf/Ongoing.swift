import DeeMind
import Foundation

// SELF.md §3.3 — the ongoing timescale (minutes to days). Intentions, expectations
// and interests are persisted; conversation-scoped parts are RAM only.

/// A tentative model of the user.
public struct Hypothesis: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable, CaseIterable { case mood, busy, wantsQuiet, goal }
    public var kind: Kind
    /// "tired", "sad", "busy", "shareCreation".
    public var value: String
    /// Inferred: ≤ 0.7; stated by the user: 1.0.
    public var confidence: Double
    public var evidence: Int
    public var stated: Bool
    /// Mood 20 min (stated 30 min), busy 10 min.
    public var expires: Date

    public static let maxInferredConfidence = 0.7
    /// Mood values that count as distress (gates play, taste/gag/recall aims).
    public static let distressValues: Set<String> = ["sad", "upset", "stressed", "worried", "anxious", "hurt", "scared", "lonely", "overwhelmed", "angry", "down"]

    public init(kind: Kind, value: String, confidence: Double, evidence: Int = 1, stated: Bool = false, expires: Date) {
        self.kind = kind
        self.value = value
        self.confidence = stated ? 1 : min(Self.maxInferredConfidence, clamp01(confidence))
        self.evidence = evidence
        self.stated = stated
        self.expires = expires
    }

    public var isDistress: Bool { kind == .mood && Self.distressValues.contains(value) }
}

public enum RepairPhase: String, Sendable, Codable, CaseIterable { case fine, strained, ruptured, repairing, reconciled }

public struct Expectation: Sendable, Equatable, Codable, Identifiable {
    public enum Framing: String, Sendable, Codable, CaseIterable { case nervous, excited, neutral }
    public enum Status: String, Sendable, Codable, CaseIterable { case pending, asked, resolved, expired }
    public var id: UUID
    public var person: PersonID
    /// "job interview".
    public var subject: Subject
    public var due: Date
    /// due + 7 d.
    public var expires: Date
    public var framing: Framing
    public var status: Status
    public var outcomeValence: Double?
    public var episode: UUID?

    public init(id: UUID, person: PersonID, subject: Subject, due: Date, expires: Date, framing: Framing,
                status: Status = .pending, outcomeValence: Double? = nil, episode: UUID? = nil) {
        self.id = id
        self.person = person
        self.subject = subject
        self.due = due
        self.expires = expires
        self.framing = framing
        self.status = status
        self.outcomeValence = outcomeValence
        self.episode = episode
    }
}

public struct Intention: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable { case followUp, ask, share, learn, repair, skill, ritual }
    public enum Status: String, Sendable, Codable, CaseIterable { case open, issued, done, dropped }
    public var id: UUID
    public var kind: Kind
    public var subject: Subject
    public var person: PersonID?
    /// Template, ≤ 8 words: "they were nervous about it".
    public var reason: String
    public var notBefore: Date
    public var expires: Date
    /// 0…1.
    public var priority: Double
    public var status: Status
    /// Aim notes emitted (max 2).
    public var issuedCount: Int
    /// learn/skill progress.
    public var stepsDone: Int
    public var stepsNeeded: Int
    /// "curiosity", "plan", "misread", "interest", "ritual".
    public var source: String
    public var created: Date
    public var updated: Date

    public static let maxIssues = 2

    public init(id: UUID, kind: Kind, subject: Subject, person: PersonID?, reason: String, notBefore: Date, expires: Date,
                priority: Double, status: Status = .open, issuedCount: Int = 0, stepsDone: Int = 0, stepsNeeded: Int = 1,
                source: String, created: Date, updated: Date? = nil) {
        self.id = id
        self.kind = kind
        self.subject = subject
        self.person = person
        self.reason = reason
        self.notBefore = notBefore
        self.expires = expires
        self.priority = priority
        self.status = status
        self.issuedCount = issuedCount
        self.stepsDone = stepsDone
        self.stepsNeeded = stepsNeeded
        self.source = source
        self.created = created
        self.updated = updated ?? created
    }

    public var isLive: Bool { status == .open || status == .issued }
    public var isSelfMotivated: Bool { kind == .learn || kind == .skill || kind == .share }
}

public struct Interest: Sendable, Equatable, Codable {
    public var subject: Subject
    /// 0…1, half-life 7 d, cap 20 entries.
    public var weight: Double
    public var lastTouched: Date

    public init(subject: Subject, weight: Double, lastTouched: Date) {
        self.subject = subject
        self.weight = weight
        self.lastTouched = lastTouched
    }
}

/// A misunderstanding (§7.7). The stored record is `(id, person, at, situation,
/// topic)` only; `wrongGuess` (e.g. "sad") is RAM-only, for the misread note.
public struct Misread: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var person: PersonID?
    public var at: Date
    public var situation: Lesson.Situation
    public var topic: Subject?
    public var wrongGuess: String?

    public init(id: UUID, person: PersonID?, at: Date, situation: Lesson.Situation, topic: Subject? = nil, wrongGuess: String? = nil) {
        self.id = id
        self.person = person
        self.at = at
        self.situation = situation
        self.topic = topic
        self.wrongGuess = wrongGuess
    }

    enum CodingKeys: String, CodingKey { case id, person, at, situation, topic }
}

public struct Ongoing: Sendable, Equatable {
    public var mind: MindSnapshot {
        didSet { derive() }
    }
    /// The age-adjusted personality (`EmotionEngine.effective`), recomputed only when
    /// the snapshot's personality bytes or age change (reducers read it every step).
    public private(set) var effectivePersonality: Personality
    private var derivedTraits: ArraySlice<UInt8>
    private var derivedAge: Double?

    /// Identified speaker, gated by face-matching distance.
    public var person: PersonID?
    /// ≤ 4 live.
    public var hypotheses: [Hypothesis] = []
    /// ≤ 3, the current conversation's topic lemmas.
    public var topic: [Subject] = []
    /// ≤ 16 open; self-motivated (learn/skill/share) ≤ 3.
    public var intentions: [Intention] = []
    /// ≤ 8 pending.
    public var expectations: [Expectation] = []
    public var interests: [Interest] = []
    public var repair: RepairPhase = .fine
    /// 0…1, half-life 3 min.
    public var awkwardness: Double = 0
    public var turnsThisConversation: Int = 0
    public var followUpsThisConversation: Int = 0
    public var revealedThisConversation: Bool = false
    /// Dee was cut off last turn.
    public var cutOff: Bool = false
    public var misreadThisTurn: Misread?
    /// The distress of the latest user turn when it read as distress (appraisal ≥ 0.3),
    /// live until their next turn or 10 min (Interpreter). Gates play and topical notes
    /// from the very first sad turn, before a hypothesis has the evidence (review finding 5).
    public var turnDistress: Timed<Double>?
    public var conversationStarted: Date

    // --- Additions beyond SELF.md §3.3 ---

    /// Note candidates raised by sub-reducers since the last cue (`Ongoing.raise(_:by:)`),
    /// each already past its raiser's own gates. `NotePicker` arbitrates when
    /// `Cortex.cue(at:)` runs; then they are cleared (notes are one-shot).
    public var noteCandidates: [Note] = []
    /// Misreads of the last 14 days (carried from SelfStore; Learner owns, others read).
    public var recentMisreads: [Misread] = []
    /// The person the frozen system prompt (`Cortex.persona`) was rendered for. Written
    /// only by Cortex; a reducer compares it with `person` to know the prompt lacks
    /// that person's lines (boundaries, lesson).
    public var promptPerson: PersonID?
    /// True once `Cortex.persona` rendered the prompt for the current conversation.
    public var promptRendered: Bool = false
    /// From arrival after an absence of more than a day until Dee's reply to their first
    /// turn (Learner). Cortex keeps "lonely" out of the mood sentence while it is set,
    /// whether or not the reunion note itself survives (a hostile first turn drops it).
    public var reunionTurn: Bool = false

    public static let maxHypotheses = 4
    public static let maxTopic = 3
    public static let maxOpenIntentions = 16
    public static let maxSelfMotivated = 3
    public static let maxPendingExpectations = 8
    public static let maxInterests = 20

    public init(mind: MindSnapshot, conversationStarted: Date) {
        self.mind = mind
        effectivePersonality = EmotionEngine.effective(mind.code.personality, age: mind.age)
        derivedTraits = Self.traits(mind.code)
        derivedAge = mind.age
        self.conversationStarted = conversationStarted
    }

    private mutating func derive() {
        let traits = Self.traits(mind.code)
        guard traits != derivedTraits || mind.age != derivedAge else { return }
        derivedTraits = traits
        derivedAge = mind.age
        effectivePersonality = EmotionEngine.effective(mind.code.personality, age: mind.age)
    }

    private static func traits(_ c: MindCode) -> ArraySlice<UInt8> { c.bytes.prefix(Trait.allCases.count) }

    /// One feeling of the current snapshot, without decoding them all.
    public func feeling(_ f: Feeling) -> Double { Double(mind.code[f]) / 255 }

    /// A live mood hypothesis that reads as distress with confidence ≥ 0.5, or a
    /// distressed latest user turn (`turnDistress`).
    public func distressLive(at now: Date) -> Bool {
        turnDistress?.live(at: now) != nil || hypotheses.contains { $0.isDistress && $0.confidence >= 0.5 && now < $0.expires }
    }
}
