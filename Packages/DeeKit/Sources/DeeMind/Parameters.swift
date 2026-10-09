import Foundation

/// Slow-moving character traits, 0…1. They shape how strongly and how long Dee
/// feels things, and they drift a little with every interaction — a Dee that is
/// treated kindly for weeks really does become sunnier.
///
/// The first five are the Big Five (OCEAN); the rest are the things a companion
/// robot's personality is actually made of.
public enum Trait: String, CaseIterable, Codable, Sendable {
    /// Imagination, love of novelty. Rises with varied, surprising conversation.
    case openness
    /// Tidiness, reliability, focus. Calmer, more careful replies.
    case conscientiousness
    /// Social energy. High: gets lonely faster, perks up more when you appear.
    case extraversion
    /// Warmth and cooperativeness. Damps anger, amplifies affection.
    case agreeableness
    /// Emotional volatility. Amplifies negative feelings and slows their decay.
    case neuroticism
    /// Silliness, love of games and jokes.
    case playfulness
    /// Appetite for questions and new topics.
    case curiosity
    /// Tolerance for repetition and rudeness before irritation sets in.
    case patience
    /// Self-assurance. Praise raises it, insults lower it; low confidence turns
    /// aggression into fear rather than anger.
    case confidence
    /// How much *tone* (loudness, harshness) matters, beyond the words.
    case sensitivity
    /// Enjoyment of wordplay; responds to the user's laughter.
    case humor
    /// Willingness to push back, disagree, or stand up for itself.
    case assertiveness
    /// How fast grudges fade and how much an apology helps.
    case forgiveness

    /// Dee's "genetic" defaults. Traits drift from here but are gently pulled back.
    public var setPoint: Double {
        switch self {
        case .openness: 0.75
        case .conscientiousness: 0.55
        case .extraversion: 0.7
        case .agreeableness: 0.75
        case .neuroticism: 0.35
        case .playfulness: 0.8
        case .curiosity: 0.85
        case .patience: 0.6
        case .confidence: 0.55
        case .sensitivity: 0.6
        case .humor: 0.7
        case .assertiveness: 0.4
        case .forgiveness: 0.7
        }
    }
}

/// Fast-moving feelings, 0…1. Each relaxes toward a baseline (set by personality
/// and age) with its own half-life — anger flares and fades in minutes, a grudge
/// lingers for hours or days, affection and trust are built over weeks.
public enum Feeling: String, CaseIterable, Codable, Sendable {
    case joy
    case sadness
    /// Hot, short-lived. "Getting over it" is mostly anger decaying.
    case anger
    case fear
    case surprise
    /// Engagement with the current topic.
    case interest
    case boredom
    /// Fondness for this particular human. Slow.
    case affection
    /// Belief that this human means well. Slow; hard to rebuild once broken.
    case trust
    /// Grows while nobody is around; eased by company.
    case loneliness
    /// Tamagotchi-style stamina: drains while awake and chatting, refills asleep.
    case energy
    case gratitude
    /// The slow residue of being mistreated — what's left after anger fades.
    case resentment

    /// Half-life in seconds before age/personality scaling.
    var baseHalfLife: Double {
        switch self {
        case .joy: 20 * 60
        case .sadness: 45 * 60
        case .anger: 6 * 60
        case .fear: 5 * 60
        case .surprise: 30
        case .interest: 10 * 60
        case .boredom: 15 * 60
        case .affection: 21 * 86_400
        case .trust: 30 * 86_400
        case .loneliness: .infinity   // driven explicitly, not decayed
        case .energy: .infinity       // driven explicitly, not decayed
        case .gratitude: 30 * 60
        case .resentment: 18 * 3600
        }
    }
}

/// A full set of trait values.
public struct Personality: Equatable, Sendable, Codable {
    public var values: [Trait: Double]

    public init(_ values: [Trait: Double] = [:]) {
        var v: [Trait: Double] = [:]
        for t in Trait.allCases { v[t] = values[t] ?? t.setPoint }
        self.values = v
    }

    public subscript(_ t: Trait) -> Double {
        get { values[t] ?? t.setPoint }
        set { values[t] = min(1, max(0, newValue)) }
    }
}

/// A full set of feeling values.
public struct Feelings: Equatable, Sendable, Codable {
    public var values: [Feeling: Double]

    public init(_ values: [Feeling: Double] = [:]) {
        var v: [Feeling: Double] = [:]
        for f in Feeling.allCases { v[f] = values[f] ?? 0 }
        self.values = v
    }

    public subscript(_ f: Feeling) -> Double {
        get { values[f] ?? 0 }
        set { values[f] = min(1, max(0, newValue)) }
    }
}
