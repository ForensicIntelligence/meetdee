import DeeCore
import Foundation
import Testing
@testable import DeeFace

/// The expression library: every emotion distinct and readable, glyphs where promised,
/// per-occurrence variation small, seeded and identity-preserving.
@Suite struct ExpressionTests {
    /// A perceptual-ish feature vector: shape, glyphs, lids, colour and overlays,
    /// weighted so that "looks different" means "far apart".
    static func features(_ f: FaceState) -> [Double] {
        func eye(_ e: EyeState) -> [Double] {
            [e.width, e.height, e.upperLid * 1.5, e.upperAngle / 20, e.lowerLid * 1.5, e.tilt / 10, e.dy * 2, e.iris,
             e.heart * 2, e.star * 2, e.chevron * 2, e.spiral * 2, e.cross * 2, e.line * 2, e.arc * 2, e.cup * 2, e.tiny * 2,
             e.tear, e.gloss * 0.5]
        }
        return eye(f.left) + eye(f.right) + [
            f.color.r * 1.5, f.color.g * 1.5, f.color.b * 1.5, f.brightness, f.gazeX * 0.5, f.gazeY * 0.5, f.headTilt / 15,
            f.zzz, f.question, f.sparkles, f.thinkingDots, f.wobble, f.giggle, f.tremble,
        ]
    }

    static func distance(_ a: FaceState, _ b: FaceState) -> Double {
        zip(features(a), features(b)).map { ($0 - $1) * ($0 - $1) }.reduce(0, +).squareRoot()
    }

    @Test func thirtySevenEmotions() {
        #expect(Emotion.allCases.count == 37)
    }

    @Test func everyEmotionHasItsOwnDistinctTarget() {
        let all = Emotion.allCases
        var closest = (Double.infinity, Emotion.neutral, Emotion.neutral)
        for (i, a) in all.enumerated() {
            for b in all[(i + 1)...] {
                let d = Self.distance(Expressions.target(for: a), Expressions.target(for: b))
                #expect(d > 0.5, "\(a) and \(b) look too alike (\(d))")
                if d < closest.0 { closest = (d, a, b) }
            }
        }
        // No two emotions share a target (the v0.3 placeholders aliased many of them).
        let unique = Set(all.map { Expressions.target(for: $0).components })
        #expect(unique.count == all.count)
    }

    @Test func glyphEyesWhereTheyAreReadable() {
        func glyph(_ e: Emotion) -> String { Expressions.target(for: e).left.dominantGlyph }
        #expect(glyph(.love) == "heart")
        #expect(glyph(.excited) == "star")
        #expect(glyph(.giddy) == "chevron")
        #expect(glyph(.overwhelmed) == "chevron")
        #expect(glyph(.dizzy) == "spiral")
        #expect(glyph(.unimpressed) == "slab", "unimpressed is a flat-lidded side-eye; only asleep is the line")
        #expect(glyph(.asleep) == "line")
        #expect(glyph(.joy) == "arc")
        #expect(glyph(.content) == "arc")
        #expect(glyph(.relieved) == "cup")
        #expect(glyph(.shy) == "tiny")
        #expect(Expressions.target(for: .playful).left.dominantGlyph == "arc", "playful is a wink")
        #expect(Expressions.target(for: .playful).right.dominantGlyph == "slab")
        // Tears for hurt (most), sad, overwhelmed; none for the happy family.
        #expect(Expressions.target(for: .hurt).left.tear > Expressions.target(for: .sad).left.tear)
        #expect(Expressions.target(for: .sad).left.tear > 0)
        for e in [Emotion.happy, .joy, .love, .giddy, .content] { #expect(Expressions.target(for: e).left.tear == 0, "\(e)") }
        // Glossy highlights strongest for awe / pleading / hopeful / love.
        let neutralGloss = Expressions.target(for: .neutral).left.gloss
        for e in [Emotion.awe, .pleading, .hopeful, .love] {
            #expect(Expressions.target(for: e).left.gloss > neutralGloss + 0.2, "\(e)")
        }
    }

    @Test func atRestCuriousIsNotTheDefault() {
        // The perpetual-"?" bug: neutral must have no question mark.
        #expect(Expressions.target(for: .neutral).question == 0)
        #expect(FaceAnimator.target(for: FaceInputs()).question == 0)
    }

    @Test func glyphWeightsAreValidForAllTargets() {
        for e in Emotion.allCases {
            let t = Expressions.target(for: e)
            for eye in [t.left, t.right] {
                #expect(eye.glyphWeights.allSatisfy { $0 >= 0 && $0 <= 1 }, "\(e)")
                #expect(eye.glyphAmount <= 1, "\(e)")
                #expect(eye.tear >= 0 && eye.tear <= 1 && eye.gloss >= 0 && eye.gloss <= 1, "\(e)")
            }
        }
    }

    // MARK: - Variation

    @Test(arguments: Emotion.allCases)
    func variationIsSmallSeededAndKeepsIdentity(_ emotion: Emotion) {
        let base = Expressions.target(for: emotion)
        #expect(Expressions.varied(base, emotion: emotion, seed: 1, amount: 0) == base)
        var seen: Set<[Double]> = []
        for seed: UInt64 in 1...12 {
            let v = Expressions.varied(base, emotion: emotion, seed: seed)
            #expect(v == Expressions.varied(base, emotion: emotion, seed: seed), "deterministic")
            seen.insert(v.components)
            // Colour and overlays never vary.
            #expect(v.color == base.color && v.brightness == base.brightness)
            #expect(v.zzz == base.zzz && v.question == base.question && v.sparkles == base.sparkles && v.giggle == base.giggle)
            // Still reads as the same expression: close to the base or to its mirror image.
            var crossed = base
            crossed.left.cross = base.left.spiral; crossed.left.spiral = 0
            crossed.right.cross = base.right.spiral; crossed.right.spiral = 0
            let refs = emotion == .dizzy ? [base, crossed] : [base]
            let d = refs.flatMap { [Self.distance(v, $0), Self.distance(v, $0.mirrored())] }.min()!
            #expect(d < 0.45, "\(emotion) seed \(seed) drifted \(d)")
            // Glyph identity kept (dizzy may swap its spirals for X X).
            let glyphs = Set([v.left.dominantGlyph, v.right.dominantGlyph])
            let want = Set([base.left.dominantGlyph, base.right.dominantGlyph])
            if emotion == .dizzy {
                #expect(glyphs == ["spiral"] || glyphs == ["cross"])
            } else {
                #expect(glyphs == want, "\(emotion) seed \(seed): \(glyphs)")
            }
            for eye in [v.left, v.right] {
                #expect(eye.width > 0.5 && eye.height > 0.3 && eye.upperLid >= 0 && eye.lowerLid >= 0)
            }
            #expect(abs(v.gazeX) <= 1 && abs(v.gazeY) <= 1)
        }
        #expect(seen.count >= 10, "\(emotion): never the same twice, got \(seen.count) distinct of 12")
    }

    @Test func dizzySometimesGoesCrossEyed() {
        let base = Expressions.target(for: .dizzy)
        let crosses = (1...60).filter { Expressions.varied(base, emotion: .dizzy, seed: UInt64($0)).left.dominantGlyph == "cross" }.count
        #expect(crosses > 5 && crosses < 45, "\(crosses)")
    }

    @Test func asymmetricExpressionsAppearOnEitherSide() {
        let base = Expressions.target(for: .playful)
        let sides = (1...40).map { Expressions.varied(base, emotion: .playful, seed: UInt64($0)).left.dominantGlyph }
        #expect(sides.contains("arc") && sides.contains("slab"), "the wink should land on both eyes over time")
    }

    @Test func mirroredTwiceIsIdentity() {
        for e in Emotion.allCases {
            let t = Expressions.target(for: e)
            let m = t.mirrored().mirrored()
            #expect(m == t, "\(e)")
        }
    }

    @Test func animatorRerollsVariationOnEachEntry() {
        var a = FaceAnimator(seed: 77)
        var goals: [FaceState] = []
        for _ in 0..<4 {
            _ = FaceAnimatorTests.run(&a, seconds: 0.5, inputs: FaceInputs(emotion: .happy))
            goals.append(a.goal)
            _ = FaceAnimatorTests.run(&a, seconds: 0.5, inputs: FaceInputs(emotion: .neutral))
        }
        #expect(Set(goals.map(\.components)).count == 4, "happy should look a little different each time")
        // Constant while the emotion holds.
        let g = a.goal
        _ = FaceAnimatorTests.run(&a, seconds: 3, inputs: FaceInputs(emotion: .neutral))
        #expect(a.goal == g)
    }
}
