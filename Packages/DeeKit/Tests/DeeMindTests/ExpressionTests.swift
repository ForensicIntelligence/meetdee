import DeeCore
import Foundation
import Testing
@testable import DeeMind

/// The resting expression (`dominantEmotion`): read as deviation from baseline,
/// personality-aware, rich across the vocabulary, and never "curious" at rest.
@Suite struct ExpressionTests {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Feelings at the default baseline, with overrides.
    static func profile(_ v: [Feeling: Double], personality: Personality = Personality()) -> Feelings {
        var f = EmotionEngine.baselines(personality: personality, age: nil)
        for (k, x) in v { f[k] = x }
        return f
    }

    static func top(_ f: Feelings, _ p: Personality = Personality()) -> String {
        EmotionEngine.expressionScores(f, personality: p, age: nil).sorted { $0.score > $1.score }.prefix(3)
            .map { "\($0.emotion.rawValue) \(String(format: "%.2f", $0.score))" }.joined(separator: ", ")
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let expected: Emotion
        let feelings: [Feeling: Double]
        let traits: [DeeMind.Trait: Double]
        init(_ e: Emotion, _ f: [Feeling: Double], traits: [DeeMind.Trait: Double] = [:]) { expected = e; feelings = f; self.traits = traits }
        var testDescription: String { expected.rawValue }
    }

    static let cases: [Case] = [
        Case(.angry, [.anger: 0.8]),
        Case(.grumpy, [.anger: 0.25, .resentment: 0.2]),
        Case(.hurt, [.sadness: 0.42, .resentment: 0.3]),
        Case(.sad, [.sadness: 0.5]),
        Case(.scared, [.fear: 0.7]),
        Case(.worried, [.fear: 0.25]),
        Case(.overwhelmed, [.surprise: 0.6, .fear: 0.55]),
        Case(.lonely, [.loneliness: 0.7]),
        Case(.pleading, [.loneliness: 0.6, .affection: 0.85, .boredom: 0.3]),
        Case(.bored, [.boredom: 0.45]),
        Case(.unimpressed, [.boredom: 0.4, .joy: 0.3], traits: [.assertiveness: 0.8]),
        Case(.sleepy, [.energy: 0.1]),
        Case(.dreamy, [.energy: 0.45]),
        Case(.surprised, [.surprise: 0.7]),
        Case(.dizzy, [.surprise: 0.6, .energy: 0.25]),
        Case(.awe, [.surprise: 0.6, .interest: 1, .joy: 0.55]),
        Case(.confused, [.surprise: 0.6, .interest: 0.9, .joy: 0.3]),
        Case(.curious, [.interest: 0.95]),
        Case(.skeptical, [.interest: 0.75, .resentment: 0.35]),
        Case(.determined, [.interest: 0.9, .anger: 0.35, .energy: 0.9]),
        Case(.love, [.affection: 0.9, .joy: 0.6]),
        Case(.joy, [.joy: 0.95]),
        Case(.giddy, [.joy: 0.95, .surprise: 0.4]),
        Case(.excited, [.joy: 0.8, .interest: 0.95, .energy: 0.9]),
        Case(.happy, [.joy: 0.65]),
        Case(.playful, [.joy: 0.65, .interest: 0.65]),
        Case(.mischievous, [.joy: 0.7, .resentment: 0.2, .anger: 0.1], traits: [.humor: 0.9, .assertiveness: 0.7]),
        Case(.hopeful, [.sadness: 0.35, .joy: 0.65]),
        Case(.relieved, [.fear: 0.3, .joy: 0.65, .gratitude: 0.3]),
        Case(.proud, [.gratitude: 0.5]),
        Case(.smug, [.gratitude: 0.5], traits: [.assertiveness: 0.85]),
        Case(.shy, [.gratitude: 0.5], traits: [.confidence: 0.2]),
        Case(.content, [.affection: 0.6, .trust: 0.6]),
        Case(.neutral, [.affection: 0.25, .trust: 0.35]),
    ]

    @Test(arguments: cases) func profileMapsToSensibleEmotion(_ c: Case) {
        let p = Personality(c.traits)
        let f = Self.profile(c.feelings, personality: p)
        let got = EmotionEngine.dominantEmotion(f, personality: p, age: nil)
        #expect(got == c.expected, "expected \(c.expected), top: \(Self.top(f, p))")
    }

    @Test func everyExpressibleEmotionIsReachable() {
        let covered = Set(Self.cases.map(\.expected))
        let missing = EmotionEngine.expressibleEmotions.filter { !covered.contains($0) }
        #expect(missing.isEmpty, "unreachable: \(missing)")
        #expect(EmotionEngine.expressibleEmotions.count == Emotion.allCases.count - 3)
        #expect(!EmotionEngine.expressibleEmotions.contains(.asleep))
    }

    @Test func freshDeeAtRestIsNotCurious() {
        for age in [nil, 1.0, 8, 16, 35, 80] as [Double?] {
            for traits in [Personality(), Personality([.curiosity: 1, .openness: 1]), Personality([.curiosity: 0.2])] {
                let f = EmotionEngine.baselines(personality: traits, age: age)
                let e = EmotionEngine.dominantEmotion(f, personality: traits, age: age)
                #expect(e != .curious, "age \(String(describing: age)): \(Self.top(f, traits))")
                #expect([.content, .neutral, .dreamy].contains(e), "calm default, got \(e)")
            }
        }
        // And through the snapshot (decoded code), as the face sees it.
        let s = MindSnapshot(code: MindCode(personality: Personality(), feelings: InnerState(updatedAt: Self.t0).feelings), age: nil)
        #expect(s.emotion != .curious)
        #expect(s.emotion == .content)
    }

    @Test func calmDefaultVariesThroughTheDay() {
        // Hours of quiet company: energy drains, Dee drifts from content to dreamy
        // (and later sleepy) — never stuck on one face, never "curious".
        var s = InnerState(updatedAt: Self.t0)
        var seen: [Emotion] = []
        for h in 0...14 {
            let now = Self.t0 + Double(h) * 3600
            s = EmotionEngine.advance(s, to: now, circumstances: .init(userPresent: true, asleep: false))
            // Keep boredom from building, as conversation would.
            s.feelings[.boredom] = EmotionEngine.baselines(personality: s.personality, age: nil)[.boredom]
            let e = EmotionEngine.dominantEmotion(s.feelings, personality: s.personality, age: nil)
            #expect(e != .curious)
            if seen.last != e { seen.append(e) }
        }
        #expect(seen.first == .content)
        #expect(seen.contains(.dreamy))
        #expect(seen.contains(.sleepy))
    }

    @Test func personalityColoursTheSameFeelings() {
        let confident = Personality([.confidence: 0.9])
        let insecure = Personality([.confidence: 0.15])
        #expect(EmotionEngine.dominantEmotion(Self.profile([.gratitude: 0.5], personality: confident), personality: confident, age: nil) == .proud)
        #expect(EmotionEngine.dominantEmotion(Self.profile([.gratitude: 0.5], personality: insecure), personality: insecure, age: nil) == .shy)
        // Deviation, not absolute: interest that's merely this Dee's normal isn't curiosity.
        let nosy = Personality([.curiosity: 1])
        let normal = EmotionEngine.baselines(personality: nosy, age: nil)
        #expect(EmotionEngine.dominantEmotion(normal, personality: nosy, age: nil) != .curious)
    }

    @Test func snapshotCarriesMoodAndUrge() {
        let calm = MindSnapshot(code: MindCode(personality: Personality(), feelings: Self.profile([:])), age: nil)
        let lonelyBored = MindSnapshot(code: MindCode(personality: Personality(), feelings: Self.profile([.loneliness: 0.8, .boredom: 0.6])), age: nil)
        let exhausted = MindSnapshot(code: MindCode(personality: Personality(), feelings: Self.profile([.energy: 0.05])), age: nil)
        #expect(lonelyBored.urgeToTalk > calm.urgeToTalk + 0.2)
        #expect(exhausted.urgeToTalk < calm.urgeToTalk)
        for s in [calm, lonelyBored, exhausted] {
            #expect((0...1).contains(s.urgeToTalk))
            #expect((-1...1).contains(s.mood.valence))
            for v in [s.mood.curiosity, s.mood.boredom, s.mood.playfulness, s.mood.affection, s.mood.energy, s.mood.loneliness, s.mood.arousal] {
                #expect((0...1).contains(v))
            }
        }
        #expect(lonelyBored.mood.loneliness > 0.7)
        #expect(lonelyBored.mood.boredom > calm.mood.boredom)
        let angry = MindSnapshot(code: MindCode(personality: Personality(), feelings: Self.profile([.anger: 0.8])), age: nil)
        let merry = MindSnapshot(code: MindCode(personality: Personality(), feelings: Self.profile([.joy: 0.9])), age: nil)
        #expect(merry.mood.playfulness > angry.mood.playfulness + 0.3)
        #expect(calm.reflex == nil)
    }
}
