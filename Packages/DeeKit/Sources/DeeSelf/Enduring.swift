import DeeMind
import Foundation

// SELF.md §3.4 — the enduring timescale (weeks and longer). Persisted by SelfStore.

public enum Value: String, Sendable, Codable, CaseIterable { case honesty, kindness, curiosity, independence }

public enum HumourStyle: String, Sendable, Codable, CaseIterable {
    case wordplay, deadpan, absurd, gentleTeasing, selfDeprecatingRobot
}

/// Mirrors `DeeFace.Performance` raw values exactly, in the same order. DeeSelf must
/// not depend on DeeFace, so the list is pinned as a literal in
/// `DeeSelfTests.MannerismPinTests` (and DeeFace pins its side in
/// `ListenPreviewTests.performanceRawValuesArePinned`). The app's Projector maps
/// 1:1 with `Performance(rawValue: mannerism.rawValue)!`.
public enum Mannerism: String, Sendable, Codable, CaseIterable {
    case wink, blinkLeft, blinkRight, yawn, eyeRoll, doubleTake, nod, headShake, giggle,
         squint, lookAround, startle, sigh, bounce, shiver, contentSquint, dizzySpin
}

public struct WeightedMannerism: Sendable, Equatable, Codable {
    public var mannerism: Mannerism
    public var base: Double
    /// + favours high energy.
    public var energyBias: Double
    /// + favours playGate.
    public var playBias: Double

    public init(mannerism: Mannerism, base: Double, energyBias: Double, playBias: Double) {
        self.mannerism = mannerism
        self.base = base
        self.energyBias = energyBias
        self.playBias = playBias
    }

    /// weight = base + energyBias·(energy − 0.5) + playBias·[playGate], floored at 0.01.
    public func weight(energy: Double, playGate: Bool) -> Double {
        max(0.01, base + energyBias * (energy - 0.5) + (playGate ? playBias : 0))
    }
}

/// Small seeded repertoire per slot; weights shift with state. Never a single fixed variant.
public struct Signature: Sendable, Equatable, Codable {
    public enum Slot: String, Sendable, Codable, CaseIterable { case thinking, amused, fond, doubtful, greeting }
    /// 2–3 entries per slot.
    public var repertoire: [Slot: [WeightedMannerism]]
    /// Seed for canned-line variants.
    public var linesVariant: UInt64
    /// 0…0.6 s, ∝ patience.
    public var prePause: TimeInterval

    public init(repertoire: [Slot: [WeightedMannerism]], linesVariant: UInt64, prePause: TimeInterval) {
        self.repertoire = repertoire
        self.linesVariant = linesVariant
        self.prePause = prePause
    }

    /// Seeded pick from `slot`: weighted by state, and never the same variant three
    /// times in a row (`recent` = the last picks, newest last).
    public func pick(_ slot: Slot, energy: Double, playGate: Bool, recent: [Mannerism], rng: inout Rand) -> Mannerism? {
        guard var options = repertoire[slot], !options.isEmpty else { return nil }
        if recent.count >= 2, recent[recent.count - 1] == recent[recent.count - 2], options.count > 1 {
            options.removeAll { $0.mannerism == recent[recent.count - 1] }
        }
        let i = rng.weighted(options.map { $0.weight(energy: energy, playGate: playGate) })
        return options[i].mannerism
    }
}

public struct Facet: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable { case taste, strength, limit }
    public enum Source: String, Sendable, Codable, CaseIterable { case seed, heuristic, reflection }
    public var id: UUID
    public var kind: Kind
    /// "rain sounds", "timers".
    public var subject: Subject
    /// Taste: hash(seed, subject) ⊕ trait fit, −1…1.
    public var innate: Double
    /// Taste: EMA of episode valence, −1…1.
    public var learned: Double
    /// 0.5·innate + 0.5·learned.
    public var polarity: Double
    public var evidence: Int
    /// Evidence against the crystallised sign.
    public var contrary: Int
    /// evidence ≥ 3 && |polarity| ≥ 0.35.
    public var crystallised: Bool
    /// nil = latent.
    public var revealedAt: Date?
    /// ≤ 8 words, template or (S7) grounded reflection.
    public var reason: String?
    public var source: Source
    public var updatedAt: Date

    public init(id: UUID, kind: Kind, subject: Subject, innate: Double, learned: Double = 0, polarity: Double? = nil,
                evidence: Int = 0, contrary: Int = 0, crystallised: Bool = false, revealedAt: Date? = nil,
                reason: String? = nil, source: Source, updatedAt: Date) {
        self.id = id
        self.kind = kind
        self.subject = subject
        self.innate = innate
        self.learned = learned
        self.polarity = polarity ?? (0.5 * innate + 0.5 * learned)
        self.evidence = evidence
        self.contrary = contrary
        self.crystallised = crystallised
        self.revealedAt = revealedAt
        self.reason = reason
        self.source = source
        self.updatedAt = updatedAt
    }
}

public struct Lesson: Sendable, Equatable, Codable, Identifiable {
    public enum Situation: String, Sendable, Codable, CaseIterable {
        /// Dee guessed a mood and was corrected.
        case moodGuess
        /// "I was joking".
        case tookLiterally
        /// "No, the other one".
        case wrongReferent
        /// Dee spoke over a slow speaker.
        case interruptedThem
        /// Playful reply → flat/negative.
        case jokeFlopped
        /// Busy/quiet signals after Dee's questions.
        case askedTooMuch

        /// The template stored as `Lesson.doInstead` (no names, no user text).
        public var doInstead: String {
            switch self {
            case .moodGuess: "ask how they feel, not guess"
            case .tookLiterally: "check if they're joking"
            case .wrongReferent: "check which one they mean"
            case .interruptedThem: "wait a bit before answering"
            case .jokeFlopped: "keep jokes low-key"
            case .askedTooMuch: "ask fewer questions"
            }
        }
    }
    public var id: UUID
    /// nil = a general lesson.
    public var person: PersonID?
    public var situation: Situation
    /// Template: "check whether they're joking".
    public var doInstead: String
    /// ≥ 2 to exist; retired below 1.
    public var evidence: Int
    public var lastApplied: Date?
    public var createdAt: Date

    public init(id: UUID, person: PersonID?, situation: Situation, doInstead: String? = nil, evidence: Int = 2,
                lastApplied: Date? = nil, createdAt: Date) {
        self.id = id
        self.person = person
        self.situation = situation
        self.doInstead = doInstead ?? situation.doInstead
        self.evidence = evidence
        self.lastApplied = lastApplied
        self.createdAt = createdAt
    }
}

/// Per person; learnt.
public struct SocialProfile: Sendable, Equatable, Codable {
    /// 0.7…1.6, shrinkage prior 10 obs at 1.0.
    public var pauseScale = 1.0
    public var pauseN = 0
    /// 0 disables.
    public var backchannelRate = 1.0
    /// EWMA α 0.15.
    public var humorReceptiveness = 0.5
    /// ×0.85 per correction, floor 0.4, +0.02 per confirmation.
    public var moodInferenceGain = 1.0
    /// 0…1.
    public var silenceComfort = 0.3
    /// Predicted valence for prediction-error "surprise".
    public var kindnessEMA = 0.0

    public init() {}
}

public struct Episode: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable { case conversation, followUp, misread, discovery, repair, play, shared }
    public var id: UUID
    public var person: PersonID?
    public var start: Date
    public var end: Date
    public var kind: Kind
    /// ≤ 3.
    public var topics: [Subject]
    /// ≤ 100 chars, template-filled from slots.
    public var gist: String
    /// ≤ 8 words, from the largest feeling delta.
    public var why: String?
    /// ≤ 8 words: "I thought he'd be nervous".
    public var expected: String?
    /// ≤ 8 words: "now I ask about his playing".
    public var changed: String?
    public var valence: Double
    public var salience: Double
    /// |predicted − actual| valence.
    public var surprise: Double
    public var mindBefore: MindCode
    public var mindAfter: MindCode
    public var recalled: Int
    public var lastRecalled: Date?
    /// The intention it spawned.
    public var openLoop: UUID?

    public static let maxGist = 100

    public init(id: UUID, person: PersonID?, start: Date, end: Date, kind: Kind, topics: [Subject], gist: String,
                why: String? = nil, expected: String? = nil, changed: String? = nil, valence: Double, salience: Double,
                surprise: Double = 0, mindBefore: MindCode, mindAfter: MindCode, recalled: Int = 0,
                lastRecalled: Date? = nil, openLoop: UUID? = nil) {
        self.id = id
        self.person = person
        self.start = start
        self.end = end
        self.kind = kind
        self.topics = Array(topics.prefix(3))
        self.gist = String(gist.prefix(Self.maxGist))
        self.why = why
        self.expected = expected
        self.changed = changed
        self.valence = valence
        self.salience = salience
        self.surprise = surprise
        self.mindBefore = mindBefore
        self.mindAfter = mindAfter
        self.recalled = recalled
        self.lastRecalled = lastRecalled
        self.openLoop = openLoop
    }

    public var key: EpisodeKey {
        EpisodeKey(id: id, person: person, end: end, topics: topics, salience: salience, recalled: recalled)
    }
}

/// The RAM index Cortex keeps for recall (≤ 300); bodies come from SelfStore on demand.
public struct EpisodeKey: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var person: PersonID?
    public var end: Date
    public var topics: [Subject]
    public var salience: Double
    public var recalled: Int

    public init(id: UUID, person: PersonID?, end: Date, topics: [Subject], salience: Double, recalled: Int) {
        self.id = id
        self.person = person
        self.end = end
        self.topics = topics
        self.salience = salience
        self.recalled = recalled
    }
}

public struct Gag: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var person: PersonID?
    public var topic: Subject
    /// Index into the humour-style hook table.
    public var hookTemplate: Int
    public var uses: Int
    public var laughs: Int
    public var flatStreak: Int
    public var lastUsed: Date?
    public var retired: Bool

    public init(id: UUID, person: PersonID?, topic: Subject, hookTemplate: Int, uses: Int = 0, laughs: Int = 0,
                flatStreak: Int = 0, lastUsed: Date? = nil, retired: Bool = false) {
        self.id = id
        self.person = person
        self.topic = topic
        self.hookTemplate = hookTemplate
        self.uses = uses
        self.laughs = laughs
        self.flatStreak = flatStreak
        self.lastUsed = lastUsed
        self.retired = retired
    }
}

public struct Ritual: Sendable, Equatable, Codable, Identifiable {
    public enum Trigger: String, Sendable, Codable, CaseIterable { case firstSightOfDay, goodnight, returnHome }
    public var id: UUID
    public var person: PersonID?
    public var trigger: Trigger
    /// Phrase variant, coined once from humour style + seed.
    public var variant: Int
    public var mannerism: Mannerism
    public var count: Int
    public var streak: Int
    public var lastDone: Date?

    public init(id: UUID, person: PersonID?, trigger: Trigger, variant: Int, mannerism: Mannerism, count: Int = 0,
                streak: Int = 0, lastDone: Date? = nil) {
        self.id = id
        self.person = person
        self.trigger = trigger
        self.variant = variant
        self.mannerism = mannerism
        self.count = count
        self.streak = streak
        self.lastDone = lastDone
    }
}

public struct Boundary: Sendable, Equatable, Codable, Identifiable {
    public enum Owner: String, Sendable, Codable, CaseIterable { case user, dee }
    public var id: UUID
    public var person: PersonID
    public var topic: Subject
    public var owner: Owner
    public var createdAt: Date
    public var active: Bool

    public init(id: UUID, person: PersonID, topic: Subject, owner: Owner, createdAt: Date, active: Bool = true) {
        self.id = id
        self.person = person
        self.topic = topic
        self.owner = owner
        self.createdAt = createdAt
        self.active = active
    }
}

public struct Enduring: Sendable, Equatable {
    public var seed: UInt64
    /// Weights from traits at seeding; never change.
    public var values: [Value: Double]
    /// Primary; the secondary stays latent.
    public var humour: HumourStyle
    public var humourSecondary: HumourStyle
    public var signature: Signature
    public var facets: [Facet]
    public var lessons: [Lesson]
    public var profiles: [PersonID: SocialProfile]
    public var boundaries: [Boundary]
    public var gags: [Gag]
    public var rituals: [Ritual]
    /// Episodes are not held in RAM wholesale: an index of ≤ 300 for recall.
    public var episodeIndex: [EpisodeKey]

    public static let maxEpisodeIndex = 300

    public init(seed: UInt64, values: [Value: Double], humour: HumourStyle, humourSecondary: HumourStyle,
                signature: Signature, facets: [Facet] = [], lessons: [Lesson] = [], profiles: [PersonID: SocialProfile] = [:],
                boundaries: [Boundary] = [], gags: [Gag] = [], rituals: [Ritual] = [], episodeIndex: [EpisodeKey] = []) {
        self.seed = seed
        self.values = values
        self.humour = humour
        self.humourSecondary = humourSecondary
        self.signature = signature
        self.facets = facets
        self.lessons = lessons
        self.profiles = profiles
        self.boundaries = boundaries
        self.gags = gags
        self.rituals = rituals
        self.episodeIndex = episodeIndex
    }

    /// The person's profile, or the in-memory default (unknown people never learn).
    public func profile(_ person: PersonID?) -> SocialProfile {
        person.flatMap { profiles[$0] } ?? SocialProfile()
    }
}

/// SELF.md §3.4 — the whole state at one instant.
public struct Moment: Sendable, Equatable {
    public var momentary: Momentary
    public var ongoing: Ongoing
    public var enduring: Enduring
    public var now: Date
    /// Increments every step.
    public var seq: UInt64

    public init(momentary: Momentary = Momentary(), ongoing: Ongoing, enduring: Enduring, now: Date, seq: UInt64 = 0) {
        self.momentary = momentary
        self.ongoing = ongoing
        self.enduring = enduring
        self.now = now
        self.seq = seq
    }

    public var profile: SocialProfile { enduring.profile(ongoing.person) }
}
