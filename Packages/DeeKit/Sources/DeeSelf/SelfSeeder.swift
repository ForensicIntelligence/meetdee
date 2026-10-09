import DeeMind
import Foundation

/// SELF.md §7.9 — seeds the enduring self once, deterministically from the traits
/// and a seed: the same (personality, seed) always gives the same Dee.
public enum SelfSeeder {
    /// A brand-new enduring self. `now` stamps the seeded facets only.
    public static func seed(personality p: Personality, seed: UInt64, at now: Date) -> Enduring {
        var rng = Rand(seed: seed ^ 0x5E_ED_5E_ED_00_00_00_01)
        let scores = humourScores(p, rng: &rng)
        let ranked = HumourStyle.allCases.sorted { (scores[$0]!, $1.rawValue) > (scores[$1]!, $0.rawValue) }
        let signature = signature(p, rng: &rng)
        let facets = capabilityFacets(rng: &rng, at: now)
        return Enduring(seed: seed, values: values(p), humour: ranked[0], humourSecondary: ranked[1],
                        signature: signature, facets: facets)
    }

    // MARK: Values (fixed; weights from traits)

    public static func values(_ p: Personality) -> [Value: Double] {
        [
            .honesty: round3(0.4 + 0.3 * p[.conscientiousness] + 0.3 * p[.assertiveness]),
            .kindness: round3(0.3 + 0.7 * p[.agreeableness]),
            .curiosity: round3(0.3 + 0.35 * p[.curiosity] + 0.35 * p[.openness]),
            .independence: round3(0.3 + 0.35 * p[.assertiveness] + 0.35 * p[.confidence]),
        ]
    }

    // MARK: Humour (trait fit + seeded noise ±0.1)

    public static func humourFit(_ p: Personality) -> [HumourStyle: Double] {
        [
            .deadpan: p[.humor] * (1 - p[.extraversion]),
            .gentleTeasing: p[.playfulness] * p[.assertiveness],
            .absurd: p[.openness] * p[.playfulness],
            .wordplay: p[.openness] * p[.conscientiousness],
            .selfDeprecatingRobot: p[.agreeableness] * (1 - p[.confidence]),
        ]
    }

    static func humourScores(_ p: Personality, rng: inout Rand) -> [HumourStyle: Double] {
        let fit = humourFit(p)
        var out: [HumourStyle: Double] = [:]
        for s in HumourStyle.allCases { out[s] = fit[s]! + rng.double(in: -0.1...0.1) }
        return out
    }

    // MARK: Signature repertoire

    /// Candidate mannerisms per slot with their trait fit.
    static func pool(_ slot: Signature.Slot, _ p: Personality) -> [(Mannerism, Double)] {
        switch slot {
        case .thinking:
            [(.squint, p[.conscientiousness]), (.lookAround, p[.curiosity]), (.blinkLeft, 0.8 * p[.openness]),
             (.blinkRight, 0.8 * (1 - p[.extraversion]) + 0.2)]
        case .amused:
            [(.giggle, p[.playfulness]), (.wink, p[.humor] * p[.assertiveness] + 0.2), (.contentSquint, 0.8 * p[.agreeableness]),
             (.bounce, p[.extraversion] * p[.playfulness]), (.eyeRoll, (1 - p[.agreeableness]) + 0.3 * p[.humor] * (1 - p[.extraversion]))]
        case .fond:
            [(.contentSquint, p[.agreeableness]), (.blinkLeft, 0.5 * p[.sensitivity] + 0.1), (.nod, 0.7 * p[.conscientiousness]),
             (.wink, 0.6 * p[.playfulness]), (.bounce, 0.6 * p[.extraversion])]
        case .doubtful:
            [(.squint, p[.conscientiousness]), (.eyeRoll, p[.assertiveness] * (1 - p[.agreeableness]) + 0.2),
             (.headShake, p[.assertiveness]), (.doubleTake, 0.7 * p[.openness])]
        case .greeting:
            [(.bounce, p[.extraversion]), (.wink, p[.playfulness] * p[.humor]), (.nod, 0.8 * p[.conscientiousness]),
             (.doubleTake, 0.6 * p[.openness]), (.lookAround, 0.5 * p[.curiosity])]
        }
    }

    public static func energyBias(_ m: Mannerism) -> Double {
        switch m {
        case .bounce: 0.8
        case .giggle: 0.4
        case .lookAround: 0.3
        case .wink, .doubleTake: 0.2
        case .sigh, .yawn: -0.6
        case .contentSquint: -0.3
        case .squint, .blinkLeft, .blinkRight: -0.2
        default: 0
        }
    }

    public static func playBias(_ m: Mannerism) -> Double {
        switch m {
        case .giggle, .wink: 0.4
        case .bounce: 0.3
        case .eyeRoll: 0.2
        default: 0
        }
    }

    static func signature(_ p: Personality, rng: inout Rand) -> Signature {
        var rep: [Signature.Slot: [WeightedMannerism]] = [:]
        for slot in Signature.Slot.allCases {
            let scored = pool(slot, p).map { ($0.0, $0.1 + rng.double(in: -0.15...0.15)) }
            let k = rng.chance(0.5) ? 3 : 2
            let top = scored.sorted { ($0.1, $1.0.rawValue) > ($1.1, $0.0.rawValue) }.prefix(k)
            rep[slot] = top.map { WeightedMannerism(mannerism: $0.0, base: round3(0.2 + max(0, $0.1)),
                                                    energyBias: energyBias($0.0), playBias: playBias($0.0)) }
        }
        return Signature(repertoire: rep, linesVariant: rng.next(), prePause: round3(0.6 * p[.patience]))
    }

    // MARK: Strengths and limits (from capabilities)

    public static let strengths = ["two cameras", "hearing sounds", "remembering faces"]
    public static let limits = ["moving around", "the internet", "picking things up"]

    /// Sorted by (kind, subject), the order `SelfStore` loads them in.
    static func capabilityFacets(rng: inout Rand, at now: Date) -> [Facet] {
        let facets = strengths.map { Facet(id: rng.uuid(), kind: .strength, subject: Subject($0)!, innate: 0.6, learned: 0, polarity: 0.6,
                              crystallised: true, source: .seed, updatedAt: now) }
        + limits.map { Facet(id: rng.uuid(), kind: .limit, subject: Subject($0)!, innate: -0.6, learned: 0, polarity: -0.6,
                             crystallised: true, source: .seed, updatedAt: now) }
        return facets.sorted { ($0.kind.rawValue, $0.subject.text) < ($1.kind.rawValue, $1.subject.text) }
    }

    // MARK: Innate tastes

    public enum TasteCategory: String, Sendable, CaseIterable { case animals, loudMachines, nature, music, other }

    static let categoryWords: [(TasteCategory, Set<String>)] = [
        (.loudMachines, ["vacuum", "vacuums", "blender", "drill", "alarm", "siren", "engine", "mower", "dryer", "hoover", "jackhammer", "leaf blower", "blower", "motorcycle"]),
        (.animals, ["dog", "dogs", "cat", "cats", "bird", "birds", "horse", "fish", "rabbit", "hamster", "puppy", "kitten", "parrot", "duck"]),
        (.nature, ["rain", "wind", "ocean", "waves", "thunder", "forest", "tree", "trees", "flower", "flowers", "sunset", "snow", "river", "stars"]),
        (.music, ["music", "guitar", "piano", "singing", "song", "drum", "drums", "violin", "jazz", "choir"]),
    ]

    public static func category(of s: Subject) -> TasteCategory {
        let words = Set(s.words)
        for (c, set) in categoryWords where !words.isDisjoint(with: set) { return c }
        return .other
    }

    /// Trait fit of a category, −1…1 (openness → novelty, neuroticism → dislike of loud machines).
    public static func traitFit(_ c: TasteCategory, _ p: Personality) -> Double {
        switch c {
        case .animals: clamp((p[.agreeableness] - 0.5) * 1.6, -1, 1)
        case .loudMachines: -(0.3 + 0.7 * p[.neuroticism])
        case .nature: clamp(0.8 * p[.openness] - 0.2, -1, 1)
        case .music: clamp(0.6 * p[.playfulness] + 0.3 * p[.openness] - 0.3, -1, 1)
        case .other: clamp(p[.openness] - 0.5, -1, 1)
        }
    }

    /// innate = 0.6·hashUnit(seed, subject) + 0.4·traitFit(category), in −1…1.
    public static func innateTaste(_ s: Subject, seed: UInt64, personality p: Personality) -> Double {
        round3(clamp(0.6 * StableHash.unit(s.text, seed: seed) + 0.4 * traitFit(category(of: s), p), -1, 1))
    }

    static func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}
