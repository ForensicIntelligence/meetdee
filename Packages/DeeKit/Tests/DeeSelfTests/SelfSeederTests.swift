import DeeMind
import Foundation
import Testing
@testable import DeeSelf

@Suite struct SelfSeederTests {
    static let tastes = ["rain sounds", "vacuum cleaners", "guitar", "dog", "toaster", "thunder", "jazz", "blender", "cat", "lamp"]

    @Test func sameSeedAndPersonalitySameSelf() {
        for seed: UInt64 in [0, 1, 7, 42, .max] {
            let a = SelfSeeder.seed(personality: Personality(), seed: seed, at: Kit.t0)
            let b = SelfSeeder.seed(personality: Personality(), seed: seed, at: Kit.t0)
            #expect(a == b)
            for t in Self.tastes {
                #expect(SelfSeeder.innateTaste(Subject(t)!, seed: seed, personality: Personality())
                        == SelfSeeder.innateTaste(Subject(t)!, seed: seed, personality: Personality()))
            }
        }
    }

    @Test func differentSeedsGiveDifferentDees() {
        let selves = (0..<40).map { SelfSeeder.seed(personality: Personality(), seed: UInt64($0) &* 0x9E37_79B9, at: Kit.t0) }
        #expect(Set(selves.map(\.signature.linesVariant)).count == 40)
        #expect(Set(selves.map { $0.signature.repertoire[.amused]!.map(\.mannerism.rawValue).joined() }).count > 3)
        let tasteA = Self.tastes.map { SelfSeeder.innateTaste(Subject($0)!, seed: 1, personality: Personality()) }
        let tasteB = Self.tastes.map { SelfSeeder.innateTaste(Subject($0)!, seed: 2, personality: Personality()) }
        #expect(tasteA != tasteB)
    }

    @Test func valuesComeFromTraitsAndAreFixed() {
        var p = Personality()
        p[.agreeableness] = 1
        p[.assertiveness] = 0
        let v = SelfSeeder.values(p)
        #expect(v[.kindness] == 1)
        #expect(v.count == Value.allCases.count)
        #expect(SelfSeeder.seed(personality: p, seed: 1, at: Kit.t0).values == SelfSeeder.seed(personality: p, seed: 99, at: Kit.t0).values,
                "values do not depend on the seed")
    }

    @Test func humourFollowsTraitFit() {
        var deadpan = Personality()
        deadpan[.humor] = 1; deadpan[.extraversion] = 0; deadpan[.playfulness] = 0; deadpan[.openness] = 0; deadpan[.agreeableness] = 0
        var absurd = Personality()
        absurd[.openness] = 1; absurd[.playfulness] = 1; absurd[.assertiveness] = 0; absurd[.conscientiousness] = 0; absurd[.humor] = 0
        for seed: UInt64 in 0..<20 {
            #expect(SelfSeeder.seed(personality: deadpan, seed: seed, at: Kit.t0).humour == .deadpan)
            #expect(SelfSeeder.seed(personality: absurd, seed: seed, at: Kit.t0).humour == .absurd)
            let e = SelfSeeder.seed(personality: Personality(), seed: seed, at: Kit.t0)
            #expect(e.humour != e.humourSecondary)
        }
    }

    @Test func signatureHasTwoOrThreeDistinctPerSlot() {
        for seed: UInt64 in 0..<50 {
            let sig = SelfSeeder.seed(personality: Personality(), seed: seed, at: Kit.t0).signature
            #expect(Set(sig.repertoire.keys) == Set(Signature.Slot.allCases))
            for (_, list) in sig.repertoire {
                #expect((2...3).contains(list.count))
                #expect(Set(list.map(\.mannerism)).count == list.count)
                #expect(list.allSatisfy { $0.base > 0 })
            }
            #expect((0...0.6).contains(sig.prePause))
        }
    }

    @Test func capabilityFacetsSeeded() {
        let e = Kit.enduring()
        #expect(e.facets.filter { $0.kind == .strength }.map(\.subject.text) == SelfSeeder.strengths.sorted())
        #expect(e.facets.filter { $0.kind == .limit }.map(\.subject.text) == SelfSeeder.limits.sorted())
        #expect(e.facets.allSatisfy { $0.source == .seed && $0.crystallised })
        #expect(!e.facets.contains { $0.kind == .taste })
    }

    @Test func innateTasteRangeAndTraitFit() {
        var nervous = Personality()
        nervous[.neuroticism] = 1
        for seed: UInt64 in 0..<100 {
            for t in Self.tastes {
                let x = SelfSeeder.innateTaste(Subject(t)!, seed: seed, personality: Personality())
                #expect((-1...1).contains(x))
            }
        }
        // Loud machines: the trait term alone is −0.4 for a very neurotic Dee.
        let mean = (0..<200).map { SelfSeeder.innateTaste(Subject("vacuum cleaners")!, seed: UInt64($0), personality: nervous) }.reduce(0, +) / 200
        #expect(mean < -0.25)
        #expect(SelfSeeder.category(of: Subject("rain sounds")!) == .nature)
        #expect(SelfSeeder.category(of: Subject("old lamp")!) == .other)
    }

    /// Golden: the seeded self for (default personality, seed 7). Regenerate with
    /// DEE_UPDATE_GOLDENS=1 only for an intended change.
    @Test func goldenDefaultSeed7() throws {
        let e = SelfSeeder.seed(personality: Personality(), seed: 7, at: Kit.t0)
        var slice: [String: String] = [
            "humour": e.humour.rawValue, "humour2": e.humourSecondary.rawValue,
            "values": Value.allCases.map { "\($0.rawValue)=\(e.values[$0]!)" }.joined(separator: ","),
            "prePause": String(e.signature.prePause), "linesVariant": String(e.signature.linesVariant),
        ]
        for slot in Signature.Slot.allCases {
            slice["slot." + slot.rawValue] = e.signature.repertoire[slot]!.map { "\($0.mannerism.rawValue):\($0.base)" }.joined(separator: ",")
        }
        for t in Self.tastes { slice["taste." + t] = String(SelfSeeder.innateTaste(Subject(t)!, seed: 7, personality: Personality())) }
        let g = GoldenTrace(reducer: "SelfSeeder", name: "default-seed7", steps: [TraceStep(t: 0, percept: "seed", effects: [], slice: slice)])
        if let diff = try Golden.check(g) { Issue.record(Comment(rawValue: diff)) }
    }
}
