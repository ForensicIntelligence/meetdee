import DeeCore
import DeeMemory
import DeeMind
import Foundation

// docs/DNA.md §1 — the Dee DNA snapshot: everything that makes Dee's next words Dee's,
// as plain values. Built by `DNAAssembler.assemble` (pure), turned into text by
// `DNAPrompt.render`. Holds no user text (the 5-gram corpus never enters it).

/// Five levels shared by the 13 traits (§2.3), from a byte.
public enum TraitLevel: Int, Sendable, Equatable, Codable, CaseIterable, Comparable {
    case veryLow, low, moderate, high, veryHigh

    public init(byte b: Int) {
        switch b {
        case ..<51: self = .veryLow
        case ..<102: self = .low
        case ..<153: self = .moderate
        case ..<204: self = .high
        default: self = .veryHigh
        }
    }

    public var words: String {
        switch self {
        case .veryLow: "very low"
        case .low: "low"
        case .moderate: "moderate"
        case .high: "high"
        case .veryHigh: "very high"
        }
    }

    public static func < (a: TraitLevel, b: TraitLevel) -> Bool { a.rawValue < b.rawValue }
}

/// Seven levels for feelings (§2.4); energy has its own five words.
public enum FeelingLevel: Int, Sendable, Equatable, Codable, CaseIterable, Comparable {
    case none, trace, little, some, quite, very, overwhelming

    public init(byte b: Int) {
        switch b {
        case ..<13: self = .none
        case ..<51: self = .trace
        case ..<102: self = .little
        case ..<153: self = .some
        case ..<204: self = .quite
        case ..<240: self = .very
        default: self = .overwhelming
        }
    }

    public var words: String {
        switch self {
        case .none: "none"
        case .trace: "a trace"
        case .little: "a little"
        case .some: "some"
        case .quite: "quite"
        case .very: "very"
        case .overwhelming: "overwhelming"
        }
    }

    /// Energy's own words (0–50 exhausted … 204–255 full of beans).
    public static func energyWords(byte b: Int) -> String {
        switch b {
        case ..<51: "exhausted"
        case ..<102: "tired"
        case ..<153: "okay"
        case ..<204: "lively"
        default: "full of beans"
        }
    }

    public static func < (a: FeelingLevel, b: FeelingLevel) -> Bool { a.rawValue < b.rawValue }
}

public enum Trend: String, Sendable, Equatable, Codable, CaseIterable {
    case risingFast = "rising fast"
    case rising = "rising"
    case steady = "steady"
    case easing = "easing"
    case fallingFast = "falling fast"

    public init(delta d: Int) {
        if d >= 51 { self = .risingFast }
        else if d >= 13 { self = .rising }
        else if d >= -12 { self = .steady }
        else if d >= -50 { self = .easing }
        else { self = .fallingFast }
    }
}

public enum PartOfDay: String, Sendable, Equatable, Codable, CaseIterable {
    case lateNight = "late night"
    case earlyMorning = "early morning"
    case morning = "morning"
    case midday = "midday"
    case afternoon = "afternoon"
    case evening = "evening"
    case night = "night"

    public init(hour h: Int) {
        switch h {
        case 0...4: self = .lateNight
        case 5...8: self = .earlyMorning
        case 9...11: self = .morning
        case 12...13: self = .midday
        case 14...17: self = .afternoon
        case 18...21: self = .evening
        default: self = .night
        }
    }
}

/// Wall-clock fields from `now + utcOffset` (proleptic Gregorian, computed by hand so no
/// locale, calendar or time zone of the device can change them).
public struct LocalTime: Sendable, Equatable {
    public var year: Int
    public var month: Int
    public var day: Int
    /// 0 = Sunday … 6 = Saturday.
    public var weekday: Int
    public var hour: Int
    public var minute: Int
    /// Whole local days since 1970-01-01.
    public var dayNumber: Int

    public init(_ date: Date, utcOffset: TimeInterval) {
        let t = Int((date.timeIntervalSince1970 + utcOffset).rounded(.down))
        let days = Int((Double(t) / 86_400).rounded(.down))
        let secs = t - days * 86_400
        hour = secs / 3600
        minute = (secs % 3600) / 60
        dayNumber = days
        weekday = ((days % 7) + 11) % 7   // 1970-01-01 was a Thursday (4)
        // Civil-from-days (H. Hinnant).
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        day = doy - (153 * mp + 2) / 5 + 1
        month = mp < 10 ? mp + 3 : mp - 9
        year = yoe + era * 400 + (month <= 2 ? 1 : 0)
    }

    public static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    public static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                                "October", "November", "December"]

    /// "Friday 9 October 2026, 7:05" (12-hour clock; the part of day disambiguates).
    public var text: String {
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        let mm = minute < 10 ? "0\(minute)" : "\(minute)"
        return "\(Self.weekdays[weekday]) \(day) \(Self.months[month - 1]) \(year), \(h12):\(mm)"
    }

    public var partOfDay: PartOfDay { PartOfDay(hour: hour) }

    /// "October 2026".
    public var monthYear: String { "\(Self.months[month - 1]) \(year)" }
}

public enum EyeColour: String, Sendable, Equatable, Codable, CaseIterable {
    case red, orange, yellow, yellowGreen = "yellow-green", green

    /// Matches `EmotionEngine.regardColor`'s hue bands.
    public init(regard r: Double) {
        switch r {
        case ...(-0.6): self = .red
        case ..<(-0.2): self = .orange
        case ..<0.15: self = .yellow
        case ..<0.5: self = .yellowGreen
        default: self = .green
        }
    }
}

public struct TraitReading: Sendable, Equatable {
    public var trait: Trait
    /// `MindSnapshot.code[trait]`.
    public var byte: Int
    /// Age-adjusted (`EmotionEngine.effective`), quantised.
    public var effectiveByte: Int
    /// From `effectiveByte`.
    public var level: TraitLevel
    public var meaning: String
    public var compactMeaning: String
    /// |effectiveByte − byte| ≥ 13.
    public var ageShifted: Bool
}

public struct FeelingReading: Sendable, Equatable {
    public var feeling: Feeling
    public var byte: Int
    /// Quantised `EmotionEngine.baselines(personality:age:)`.
    public var usualByte: Int
    public var level: FeelingLevel
    /// Level words (energy uses its own).
    public var levelWords: String
    public var trend: Trend
    public var cause: CauseLabel?
    /// Effect clause (notable lines only).
    public var effect: String?
    /// level ≥ a little ∧ |byte − usual| ≥ 26, or energy ≤ 101.
    public var notable: Bool

    public var deviation: Int { byte - usualByte }
}

public struct ReflexReading: Sendable, Equatable {
    public var emotion: Emotion
    public var secondsAgo: Double
    public var cause: CauseLabel?
}

public struct RelationshipReading: Sendable, Equatable {
    public enum Who: Sendable, Equatable {
        case named(String, aliases: [String])
        case placeholder
        case unidentified
    }
    public var who: Who
    public var regard: Double
    public var regardWords: String
    public var eyeColour: EyeColour
    public var affection: Int
    public var trust: Int
    public var repair: RepairPhase
    public var awkwardness: Double
    /// ≤ 5, newest first.
    public var userBoundaries: [Subject]
    public var deeBoundaryStated: Bool
    public var profile: SocialProfile
    /// How to read this person, from a lesson about *them* (§2.5), or nil.
    public var lesson: String?
    /// A "wait a bit before answering" lesson applies: the app delays the reply (a timing
    /// behaviour the model cannot perform, so it is never rendered; live eval R2).
    public var waitBeforeAnswering: Bool
    // History.
    public var encounters: Int
    /// "October 2025" (local), when first met.
    public var firstMetMonth: String?
    /// Seconds since they last talked (nil = unknown).
    public var sinceLastTalk: TimeInterval?
    /// "warmer" / "steady" / "cooler" from `Mind.history`, nil without data.
    public var recentTrend: String?
    public var rudeCount: Int
    public var kindCount: Int
    public var apologiesCountLess: Bool
}

public struct FollowUpLine: Sendable, Equatable {
    public var subject: Subject
    public var framing: Expectation.Framing
    /// Days since due (follow-ups) or until due (upcoming).
    public var days: Int
}

public struct KnowledgeReading: Sendable, Equatable {
    /// Telegraphic facts (§2.7), ≤ 8.
    public var facts: [String]
    public var episodes: [EpisodeLine]
    public var followUps: [FollowUpLine]
    public var upcoming: [FollowUpLine]
    public var interests: [Subject]
    public var shareMemories: Bool
    /// Nobody identified or a placeholder: nothing is known.
    public var unknownPerson: Bool
}

public struct SelfReading: Sendable, Equatable {
    /// Top 3 values, as `SelfBlock.lines` orders them.
    public var topValues: [Value]
    public var humour: HumourStyle
    public var humourSecondary: HumourStyle
    /// "love rain sounds" (revealed, crystallised, non-sensitive), ≤ 3.
    public var tastes: [String]
    /// Capability lines ("You can see through two cameras."), ≤ 2 each.
    public var strengths: [String]
    public var limits: [String]
    public var lessonGeneral: String?
    public var rituals: [Ritual.Trigger]
    /// Gag hooks, ≤ 2.
    public var gags: [String]
    /// Top mannerism per signature slot, in `Signature.Slot.allCases` order.
    public var mannerisms: [(slot: Signature.Slot, mannerism: Mannerism)]

    public static func == (a: SelfReading, b: SelfReading) -> Bool {
        a.topValues == b.topValues && a.humour == b.humour && a.humourSecondary == b.humourSecondary && a.tastes == b.tastes
            && a.strengths == b.strengths && a.limits == b.limits && a.lessonGeneral == b.lessonGeneral && a.rituals == b.rituals
            && a.gags == b.gags && a.mannerisms.map(\.slot) == b.mannerisms.map(\.slot)
            && a.mannerisms.map(\.mannerism) == b.mannerisms.map(\.mannerism)
    }
}

public struct SeenThing: Sendable, Equatable {
    public var subject: Subject
    public var camera: CameraSide?
    public var sharedWithUser: Bool
    public var heldUp: Bool
}

public struct HypothesisLine: Sendable, Equatable {
    public var kind: Hypothesis.Kind
    public var value: String
    public var stated: Bool
}

public struct NoteLine: Sendable, Equatable {
    public var kind: Note.Kind
    public var role: Note.Role
    public var priority: Int
    /// `Note.text` with its outer parentheses stripped.
    public var text: String
}

public struct IntentionLine: Sendable, Equatable {
    public var action: String
    public var priority: Double
    public var reason: String
}

public struct NowReading: Sendable, Equatable {
    public var someoneHere: Bool
    public var mutualGazeSeconds: Double?
    public var asleep: Bool
    public var wokeSecondsAgo: Double?
    public var sees: [SeenThing]
    public var focus: String
    public var lastSound: String?
    public var touch: String?
    public var touchSecondsAgo: Double?
    public var floor: String
    public var cutOff: Bool
    public var hypotheses: [HypothesisLine]
    public var distressLive: Bool
    public var playGate: Bool
    public var notes: [NoteLine]
    public var intentions: [IntentionLine]
    public var turnsThisConversation: Int
    public var conversationMinutes: Int
    public var reunion: Bool
}

/// The derived response guidance of §2.9.
public struct Guidance: Sendable, Equatable {
    public enum Rule: String, Sendable, Equatable, Codable, CaseIterable {
        case g1 = "G1", g2 = "G2", g3 = "G3", g4 = "G4", g5 = "G5", g6 = "G6", g7 = "G7", g8 = "G8"
        case g9 = "G9", g10 = "G10", g11 = "G11", g12 = "G12", g13 = "G13", g14 = "G14", g15 = "G15", g16 = "G16"
    }
    public var length: String
    public var energyLevel: Double
    public var energyWord: String
    public var warmth: Double
    public var warmthWord: String
    public var playfulness: Double
    public var playfulnessWord: String
    /// The expression the voice line describes (`Stance.expression`, app states resolved).
    public var voiceEmotion: Emotion
    public var voice: String
    /// Rules whose condition holds, in G1…G16 order.
    public var rules: [Rule]
    public var doLines: [String]
    public var avoidLines: [String]
}

/// docs/DNA.md §1 — the snapshot.
public struct DeeDNA: Sendable, Equatable {
    /// v2: guard/minimal/lesson/length fixes of the 2026-10-09 review and live eval.
    /// v3 (tune 2): session instructions v3 (silent tools, counted length) and the
    /// Length line with its word budget.
    /// v4 (tune 3): session instructions v4, "Ask now, first" follow-ups, the reunion
    /// greeting with the time apart, "last talked" from before this conversation.
    /// v5 (tune 4): session instructions v5, the Length line counted "in all" and
    /// stopped after the last allowed sentence, a due follow-up asked first (with the
    /// greeting after time apart in the same sentence), the greeting kept until a
    /// reply of Dee's was actually heard (`TurnContext.heardReplies`).
    /// v6 (tune 5): session instructions v6; time apart in words everywhere ("nearly a
    /// week", "a couple of days"; never a number of days or hours); G14 never asks them
    /// to finish their words.
    /// v7 (tune 6): session instructions v7; a hard no-app limit in the identity line and
    /// the Always line; the due follow-up as the very first sentence (the hello inside
    /// it); the person's name as a sentence ("Their name is Priya.").
    /// v8 (tune 7): session instructions v8; the due follow-up's opening words spelled out
    /// ("Hi Alex," and the question, all in one; the time apart only after it).
    /// v9 (tune 8): session instructions v9; the follow-up form only with an "Ask now, first"
    /// line, their words never said back, their question answered in the first sentence.
    /// v10 (tune 9): session instructions v10; nothing primes "I heard you", no thinking
    /// aloud anywhere in a reply, one reply per turn (never a lead-in, then a second one).
    /// v11 (tune 12): session instructions v11; Dee's day is small concrete things, never Dee's process.
    public static let version = "v11"

    public var turn: TurnContext
    // §1.2
    public var name: String
    public var localTime: LocalTime
    public var partOfDay: PartOfDay
    public var age: Double?
    public var stage: LifeStage?
    public var aging: AgingInputs
    public var mindCode: MindCode
    // §1.3
    public var traits: [TraitReading]
    public var feelings: [FeelingReading]
    public var valence: Double
    public var arousal: Double
    public var restingExpression: Emotion
    public var blend: [String]
    public var reflex: ReflexReading?
    public var moodBand: EmotionBand
    public var mood: MoodSignals
    public var urgeToTalk: Double
    public var inner: InnerStateCounters
    // §1.5–§1.7
    public var relationship: RelationshipReading
    public var knowledge: KnowledgeReading
    public var selfModel: SelfReading
    // §1.8–§1.9
    public var now: NowReading
    public var appraisal: TurnAppraisal
    // §2.9
    public var guidance: Guidance
    /// The persona preset (identity line, pronouns in the trait meanings, Voice phrase).
    public var persona: PersonaPreset = PersonaCatalog.classic
}
