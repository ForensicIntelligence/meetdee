import Foundation

/// Optional age, optional ageing. When enabled, age reshapes personality and how
/// feelings behave: young Dees are playful, volatile and quick to forgive; teens
/// are touchy and hold grudges; older Dees are patient, calm and slow to stir.
public struct AgeSettings: Equatable, Sendable, Codable {
    /// Master switch. Off: Dee is ageless (adult defaults, no age effects).
    public var enabled = false
    /// Off: frozen at `startAge`. On: grows older at `yearsPerDay`.
    public var agingEnabled = false
    /// Age when ageing (re)started, in Dee-years.
    public var startAge = 6.0
    /// Real moment ageing started.
    public var since = Date()
    /// Dee-years per real day (0.1 → a year every ten days; 1/365 → real time).
    public var yearsPerDay = 0.1

    public init(enabled: Bool = false, agingEnabled: Bool = false, startAge: Double = 6, since: Date = Date(), yearsPerDay: Double = 0.1) {
        self.enabled = enabled
        self.agingEnabled = agingEnabled
        self.startAge = startAge
        self.since = since
        self.yearsPerDay = yearsPerDay
    }

    /// Oldest a Dee can get, in Dee-years.
    public static let maxAge = 120.0
    /// Fastest ageing rate: the Settings app's "very fast" (a year per hour).
    public static let maxYearsPerDay = 24.0

    /// Current age in Dee-years (0…`maxAge`), or nil when age is disabled.
    public func age(at now: Date) -> Double? {
        guard enabled else { return nil }
        let start = min(Self.maxAge, max(0, startAge))
        guard agingEnabled else { return start }
        let days = max(0, now.timeIntervalSince(since) / 86_400)
        return min(Self.maxAge, start + days * Self.clampRate(yearsPerDay))
    }

    /// Changes the rate without making Dee jump in age.
    public mutating func setRate(_ yearsPerDay: Double, at now: Date) {
        if let current = age(at: now) { startAge = current }
        since = now
        self.yearsPerDay = Self.clampRate(yearsPerDay)
    }

    static func clampRate(_ r: Double) -> Double { r.isFinite ? min(maxYearsPerDay, max(0, r)) : 0 }
}

public enum LifeStage: String, Sendable, Equatable {
    case baby, child, teen, adult, elder

    public init(age: Double) {
        switch age {
        case ..<3: self = .baby
        case ..<13: self = .child
        case ..<20: self = .teen
        case ..<60: self = .adult
        default: self = .elder
        }
    }

    /// How Dee talks at this stage (goes into the prompt cue).
    public var voiceNote: String {
        switch self {
        case .baby: "You are a baby robot: very short, simple words, lots of wonder and giggles."
        case .child: "You are a young robot child: simple words, boundless curiosity, easily delighted."
        case .teen: "You are a teenage robot: a bit moody and sarcastic, but secretly sweet."
        case .adult: ""
        case .elder: "You are an old, wise robot: gentle, patient, a little nostalgic."
        }
    }
}

/// How age shifts personality and emotional dynamics. Values are interpolated
/// smoothly between key ages so there are no birthday cliffs.
public enum AgeModel {
    struct Key {
        let age: Double
        let traits: [Trait: Double]   // additive offsets
        let halfLifeScale: Double     // <1: moods pass quickly
        let plasticity: Double        // personality learning-rate multiplier
        let energyCeiling: Double
    }

    static let keys: [Key] = [
        Key(age: 0, traits: [.playfulness: 0.15, .curiosity: 0.12, .patience: -0.3, .neuroticism: 0.1, .forgiveness: 0.25, .conscientiousness: -0.3, .confidence: -0.15, .sensitivity: 0.15],
            halfLifeScale: 0.4, plasticity: 2.0, energyCeiling: 1.0),
        Key(age: 8, traits: [.playfulness: 0.15, .curiosity: 0.12, .patience: -0.15, .neuroticism: 0.05, .forgiveness: 0.15, .conscientiousness: -0.15],
            halfLifeScale: 0.6, plasticity: 1.6, energyCeiling: 1.0),
        Key(age: 16, traits: [.neuroticism: 0.15, .assertiveness: 0.12, .agreeableness: -0.1, .sensitivity: 0.12, .forgiveness: -0.15, .patience: -0.1],
            halfLifeScale: 1.1, plasticity: 1.3, energyCeiling: 1.0),
        Key(age: 30, traits: [:], halfLifeScale: 1.0, plasticity: 1.0, energyCeiling: 1.0),
        Key(age: 70, traits: [.patience: 0.18, .conscientiousness: 0.1, .agreeableness: 0.08, .forgiveness: 0.12, .playfulness: -0.12, .curiosity: -0.05, .neuroticism: -0.08],
            halfLifeScale: 1.4, plasticity: 0.5, energyCeiling: 0.75),
        Key(age: 100, traits: [.patience: 0.22, .conscientiousness: 0.1, .agreeableness: 0.1, .forgiveness: 0.15, .playfulness: -0.2, .curiosity: -0.1, .neuroticism: -0.1],
            halfLifeScale: 1.6, plasticity: 0.35, energyCeiling: 0.6),
    ]

    public struct Effect: Sendable, Equatable {
        public var traitOffsets: [Trait: Double] = [:]
        public var halfLifeScale = 1.0
        public var plasticity = 1.0
        public var energyCeiling = 1.0
        public static let none = Effect()
    }

    public static func effect(age: Double?) -> Effect {
        guard let age else { return .none }
        let a = max(0, age)
        let upper = keys.firstIndex { $0.age >= a } ?? keys.count - 1
        let lower = max(0, upper - (keys[upper].age > a ? 1 : 0))
        let k0 = keys[lower], k1 = keys[upper]
        let t = k1.age == k0.age ? 0 : (a - k0.age) / (k1.age - k0.age)
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        var offsets: [Trait: Double] = [:]
        for trait in Trait.allCases {
            offsets[trait] = mix(k0.traits[trait] ?? 0, k1.traits[trait] ?? 0)
        }
        return Effect(traitOffsets: offsets, halfLifeScale: mix(k0.halfLifeScale, k1.halfLifeScale),
                      plasticity: mix(k0.plasticity, k1.plasticity), energyCeiling: mix(k0.energyCeiling, k1.energyCeiling))
    }
}
