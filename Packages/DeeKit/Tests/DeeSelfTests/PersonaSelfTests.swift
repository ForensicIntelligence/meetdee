import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

// Persona presets in the self and the DNA (persona spec §3–§9, §11.3–§11.4, §11.10
// DeeSelfTests). Classic Dee renders byte-for-byte as before (the archetype goldens).
@Suite struct PersonaSelfTests {
    static let values: [String: [Double]] = [   // honesty, kindness, curiosity, independence
        "mira": [0.670, 0.855, 0.912, 0.674], "vera": [0.832, 0.768, 0.762, 0.818],
        "rio": [0.731, 0.749, 0.807, 0.816], "atlas": [0.765, 0.770, 0.743, 0.755],
        "nova": [0.592, 0.825, 0.948, 0.559], "haven": [0.696, 0.871, 0.780, 0.685],
    ]

    /// The traits each spec table marks "(shaped by age)".
    static let shaped: [String: Set<DeeMind.Trait>] = [
        "mira": [.neuroticism, .sensitivity, .assertiveness, .forgiveness],
        "vera": [.patience], "rio": [], "atlas": [.patience],
        "nova": [.agreeableness, .neuroticism, .patience, .sensitivity, .assertiveness, .forgiveness],
        "haven": [.playfulness, .patience, .forgiveness],
    ]

    @Test(arguments: PersonaCatalog.all)
    func valuesMatchTheSpec(_ p: PersonaPreset) {
        let v = SelfSeeder.values(p.storedTraits())
        let got = [v[.honesty], v[.kindness], v[.curiosity], v[.independence]].map { $0 ?? -1 }
        let want = Self.values[p.id] ?? []
        // ±0.001: the spec's numbers are Python's round-half-even of x.xxx5 (Mira curiosity
        // .9125 → .912, Rio .8075 → .807); SelfSeeder rounds half away from zero (.913, .808).
        #expect(zip(got, want).allSatisfy { abs($0 - $1) < 0.0011 } && got.count == want.count, "\(p.id): \(got) vs \(want)")
        let e = SelfSeeder.seed(preset: p, fallbackSeed: 1, at: Kit.t0)
        #expect(e.values == v && e.seed == p.seed)
    }

    @Test(arguments: PersonaCatalog.all)
    func humourPinsBeatTheNoiseForEverySeed(_ p: PersonaPreset) throws {
        let pins = try #require(SelfSeeder.humourPins(p))
        var rng = Rand(seed: 42)
        for _ in 0..<1000 {
            let e = SelfSeeder.seed(personality: p.storedTraits(), seed: rng.next(), at: Kit.t0, pins: pins)
            #expect(e.humour == pins.humour && e.humourSecondary == pins.secondary)
        }
    }

    @Test func noTwoPresetsShareAHumourPairAndClassicIsUnpinned() {
        let pairs = PersonaCatalog.all.compactMap { SelfSeeder.humourPins($0) }.map { "\($0.humour)/\($0.secondary)" }
        #expect(pairs.count == 6 && Set(pairs).count == 6)
        #expect(SelfSeeder.humourPins(PersonaCatalog.classic) == nil)
    }

    /// Pins and tastes never change what the seed draws for the rest (signature, capabilities).
    @Test func pinsLeaveTheRestOfTheSeedAlone() {
        let p = PersonaCatalog.mira.storedTraits()
        let plain = SelfSeeder.seed(personality: p, seed: 9, at: Kit.t0)
        let pinned = SelfSeeder.seed(personality: p, seed: 9, at: Kit.t0, pins: (.deadpan, .wordplay))
        #expect(plain.signature == pinned.signature)
        #expect(plain.facets == pinned.facets)
    }

    @Test func seededTastesAreLatentTasteFacets() {
        let e = SelfSeeder.seed(preset: PersonaCatalog.vera, fallbackSeed: 1, at: Kit.t0)
        let tastes = e.facets.filter { $0.kind == .taste }
        #expect(tastes.map(\.subject.text).sorted() == ["alarm", "being interrupted", "cats", "crosswords", "jazz", "rain"])
        #expect(tastes.allSatisfy { $0.source == .seed && !$0.crystallised && $0.revealedAt == nil })
        #expect(tastes.first { $0.subject.text == "crosswords" }?.innate == 0.6)
        #expect(e.facets.filter { $0.kind != .taste }.count == SelfSeeder.strengths.count + SelfSeeder.limits.count)
    }

    @Test func reseedReplacesTheCharacterAndKeepsWhatBelongsToTheUser() async throws {
        let store = try SelfStore(url: SelfStoreTests.tempURL())
        let classic = try await store.loadEnduring(personality: Personality(), seed: 3, at: Kit.t0)
        try await store.apply(.lesson(Lesson(id: UUID(), person: nil, situation: .moodGuess, evidence: 3, createdAt: Kit.t0)))
        try await store.apply(.facet(Facet(id: UUID(), kind: .taste, subject: Subject("rain sounds")!, innate: 0.4, learned: 0.6,
                                           evidence: 3, crystallised: true, revealedAt: Kit.t0, source: .heuristic, updatedAt: Kit.t0)))
        try await store.apply(.episode(SelfStoreTests.episode(nil)))
        let rio = try await store.reseed(for: PersonaCatalog.rio, fallbackSeed: 5, at: Kit.t0)
        #expect(rio.seed == PersonaCatalog.rio.seed && rio.seed != classic.seed)
        #expect(rio.humour == .gentleTeasing && rio.humourSecondary == .absurd)
        #expect(rio.values == SelfSeeder.values(PersonaCatalog.rio.storedTraits()))
        #expect(rio.lessons.count == 1, "lessons are the user's")
        #expect(rio.episodeIndex.count == 1, "episodes are the user's")
        #expect(rio.facets.contains { $0.subject.text == "rain sounds" && $0.source == .heuristic }, "learned tastes stay")
        #expect(rio.facets.contains { $0.subject.text == "drums" && $0.source == .seed })
        #expect(rio.facets.filter { $0.kind == .strength }.count == SelfSeeder.strengths.count, "capabilities stay")
        #expect(try await store.seededPersona() == "rio")
        // Switching again drops the old preset's seeded tastes.
        let nova = try await store.reseed(for: PersonaCatalog.nova, fallbackSeed: 5, at: Kit.t0)
        #expect(!nova.facets.contains { $0.subject.text == "drums" })
        #expect(nova.facets.contains { $0.subject.text == "stars" })
        // A reload is the same self.
        let again = try await store.loadEnduring(personality: Personality(), seed: 99, at: Kit.t0)
        #expect(again.seed == nova.seed && again.humour == nova.humour && again.signature == nova.signature)
    }

    @Test func freshStoreSeedsFromThePreset() async throws {
        let store = try SelfStore(url: nil)
        let e = try await store.loadEnduring(personality: Personality(), seed: 3, at: Kit.t0, preset: PersonaCatalog.haven)
        #expect(e.seed == PersonaCatalog.haven.seed && e.humour == .selfDeprecatingRobot)
        #expect(e.facets.contains { $0.kind == .strength })
        let reseeded = try await SelfStore(url: nil).reseed(for: PersonaCatalog.mira, fallbackSeed: 1, at: Kit.t0)
        #expect(reseeded.facets.contains { $0.kind == .limit }, "a never-seeded store gets its capabilities too")
    }

    // MARK: DNA

    static func dna(_ p: PersonaPreset) -> DeeDNA {
        var inputs = DNAKit.fondMorning().inputs
        inputs.persona = p
        // The scene's learnt history stays; the character's seeded self is the preset's.
        let seeded = SelfSeeder.seed(preset: p, fallbackSeed: 7, at: Kit.t0)
        inputs.moment.enduring.values = seeded.values
        inputs.moment.enduring.humour = seeded.humour
        inputs.moment.enduring.humourSecondary = seeded.humourSecondary
        inputs.mind = MindSnapshot(code: MindCode(personality: p.code.personality, feelings: inputs.mind.code.feelings),
                                   age: p.age.map(Double.init), sequence: 1)
        return DNAAssembler.assemble(inputs)
    }

    @Test(arguments: PersonaCatalog.all)
    func personaGolden(_ p: PersonaPreset) throws {
        let d = Self.dna(p)
        let text = DNAPrompt.render(d).text
        try DNAGoldenTests.check(text + "\n", file: "persona-\(p.id).dna.txt")
        #expect(text.contains("You are \(p.name), \(p.age!), \(p.pronouns.label): an adult companion living in this phone as a small robot"))
        // Like the archetypes: no cap step, so the scene keeps its knowledge lines.
        let r = DNAPrompt.render(d)
        #expect(!r.steps.contains { $0 == .s7 || DegradeStep.capSteps.contains($0) || $0 == .minimal }, "\(p.id): \(r.steps)")
        // The follow-up is in every DNA that did not need the s4 trim (Haven's longer
        // age-shaped trait lines push this busy scene just past the target).
        if !r.steps.contains(.s4) { #expect(text.contains("Coming up for them: football match"), "\(p.id)") }
        #expect(text.contains("with no apps, clock or internet"), "the tune-7 hard limit stays")
        #expect(text.contains("Age: \(p.age!) robot-years, an adult."))
        #expect(text.contains(p.dnaVoice))
        #expect(text.contains("Always: stay \(p.name);"))
        #expect(!text.contains("tiny") && !text.contains("bright little"))
        #expect(!text.contains("You are Dee"))
        #expect(Set(d.traits.filter(\.ageShifted).map(\.trait)) == Self.shaped[p.id], "\(p.id)")
    }

    @Test func traitMeaningsUseThePersonasPronouns() {
        #expect(DNATables.meaning(.assertiveness, .high) == "says what she thinks; stands her ground", "Classic: v1 text")
        #expect(DNATables.meaning(.assertiveness, .high, pronouns: .he) == "says what he thinks; stands his ground")
        #expect(DNATables.meaning(.assertiveness, .high, pronouns: .they) == "says what they think; stands their ground")
        #expect(DNATables.meaning(.conscientiousness, .high, pronouns: .they) == "careful and precise; keeps their word")
        #expect(DNATables.meaning(.curiosity, .moderate, pronouns: .he) == "asks when something catches him")
        #expect(DNATables.meaning(.patience, .veryLow, pronouns: .they) == "very impatient; repetition makes them snap")
        #expect(DNATables.meaning(.confidence, .veryLow, pronouns: .he) == "very insecure; rudeness frightens him")
        // In the rendered DNA.
        #expect(DNAPrompt.render(Self.dna(PersonaCatalog.rio)).text.contains("says what he thinks; stands his ground"))
        #expect(DNAPrompt.render(Self.dna(PersonaCatalog.atlas)).text.contains("keeps his word"))
        #expect(DNAPrompt.render(Self.dna(PersonaCatalog.vera)).text.contains("says what she thinks; stands her ground"))
    }

    @Test func adultHumourIsNeverTiny() {
        #expect(SelfBlock.humourPhrase(.selfDeprecatingRobot) == "jokes about being a tiny robot", "Classic unchanged")
        #expect(SelfBlock.humourPhrase(.selfDeprecatingRobot, adult: true) == "jokes about being a small robot in a phone")
        let haven = SelfSeeder.seed(preset: PersonaCatalog.haven, fallbackSeed: 1, at: Kit.t0)
        #expect(SelfBlock.render(haven, person: nil, persona: PersonaCatalog.haven).joined().contains("small robot in a phone"))
        let text = DNAPrompt.render(Self.dna(PersonaCatalog.haven)).text
        #expect(text.contains("Your humour: jokes about being a small robot in a phone"), "\(text)")
    }

    // MARK: Session instructions

    @Test func classicSessionInstructionsAreV11ByteForByte() {
        #expect(DNASessionInstructions.current(for: PersonaCatalog.classic) == DNASessionInstructions.v11)
        #expect(DNAPrompt.sessionInstructions(persona: Persona()) == DNASessionInstructions.v11)
        #expect(DNAPrompt.sessionInstructions(preset: PersonaCatalog.classic) == DNASessionInstructions.v11)
    }

    @Test func v12ReplacesOnlyTheIdentityAndItsOwnLines() {
        let v11 = DNASessionInstructions.v11
        #expect(v11.components(separatedBy: DNASessionInstructions.v11Opening).count == 2)
        #expect(v11.components(separatedBy: DNASessionInstructions.v11VoiceLine).count == 2)
        #expect(v11.components(separatedBy: DNASessionInstructions.v11LimitsLine).count == 2)
        #expect(v11.components(separatedBy: "answer as Dee would").count == 2)
        #expect(v11.components(separatedBy: ", as Dee, ").count == 3)
    }

    @Test(arguments: PersonaCatalog.all)
    func sessionInstructionsSpeakAsThePersona(_ p: PersonaPreset) throws {
        let s = DNAPrompt.sessionInstructions(persona: Persona(preset: p))
        #expect(s == DNASessionInstructions.v12(for: p))
        try DNAGoldenTests.check(s + "\n", file: "session-instructions.v12.\(p.id).txt")
        #expect(s.hasPrefix("You are \(p.name), \(p.age!), \(p.pronouns.label): a robot companion"))
        #expect(s.components(separatedBy: p.name).count - 1 >= 4, "the name, at least four times")
        #expect(!s.contains("Dee "), "no Dee except the DEE DNA header")
        #expect(!s.contains("tiny") && !s.contains("bright little robot voice"))
        #expect(s.contains(p.dnaVoice) && s.contains(p.speechStyle!) && s.contains(p.limitsVoice!))
        #expect(s.contains("starts with \"DEE DNA\""), "the header stays the product name")
    }
}
