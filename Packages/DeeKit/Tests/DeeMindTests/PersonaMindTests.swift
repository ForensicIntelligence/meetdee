import DeeCore
import Foundation
import Testing
@testable import DeeMind

// Persona presets in the Mind (persona spec §4–§9 tables, §11.2, §11.9, §11.10 DeeMindTests).
@Suite struct PersonaMindTests {
    /// The approved MindCodes (scratchpad calc-final.out), with `MindCode.quantize`'s
    /// round-half-away-from-zero: a stored value of exactly .700 is 178.5 → B3 here, where
    /// the spec's Python round-half-even printed B2 (Vera, Rio, Nova, Haven and Classic,
    /// one byte each; no trait level changes). Classic's is today's code, as the
    /// fond-morning golden's trace shows.
    static let codes: [String: String] = [
        "mira": "D973D1CA49D1E6979E91BF72C37E120007009014668600CC0000",
        "vera": "A6BD73AA367FABBFC78CB3B3A6680D0006007A14668500B80000",
        "rio": "B361D9A338D9BF78BF55D1B9D9840F0006008314668300CC0000",
        "atlas": "8CAA59AB2D8AB7C9BF80A68CC6650C0006007E14668500BA0000",
        "nova": "F25973BF60B3E6AB73B0B34AC664150009009014668500CC0000",
        "haven": "A68273D03799B8D29EB39E7AD86B0D0006007E14668800B60000",
        "classic": "BF8CB3BF59CCD9998C99B366B377120008008C14668600CC0000",
    ]

    /// Effective trait levels per the spec tables (0 veryLow … 4 veryHigh), trait order.
    static let levels: [String: [Int]] = [
        "mira": [4, 2, 4, 3, 1, 4, 4, 2, 3, 3, 3, 2, 3],
        "vera": [3, 3, 2, 3, 0, 2, 3, 4, 3, 2, 3, 3, 3],
        "rio": [3, 1, 4, 3, 1, 4, 3, 2, 3, 1, 4, 3, 4],
        "atlas": [2, 3, 1, 3, 0, 2, 3, 4, 3, 2, 3, 2, 4],
        "nova": [4, 1, 2, 3, 2, 3, 4, 3, 2, 3, 3, 1, 3],
        "haven": [3, 2, 2, 4, 0, 2, 3, 4, 3, 3, 3, 2, 4],
    ]

    static func level(_ byte: Int) -> Int { byte < 51 ? 0 : byte < 102 ? 1 : byte < 153 ? 2 : byte < 204 ? 3 : 4 }

    static func effectiveBytes(_ p: PersonaPreset) -> [Int] {
        let eff = EmotionEngine.effective(p.code.personality, age: p.age.map(Double.init))
        return Trait.allCases.map { Int(MindCode.quantize(eff[$0])) }
    }

    @Test(arguments: PersonaCatalog.all + [PersonaCatalog.classic])
    func codeIsTheApprovedOne(_ p: PersonaPreset) {
        #expect(p.code.hex == Self.codes[p.id], "CODE \(p.id): \(p.code.hex) vs \(Self.codes[p.id] ?? "")")
    }

    @Test(arguments: PersonaCatalog.all)
    func effectiveLevelsMatchTheTablesWithMargin(_ p: PersonaPreset) {
        let bytes = Self.effectiveBytes(p)
        #expect(bytes.map(Self.level) == Self.levels[p.id], "\(p.id): \(bytes)")
        for (t, b) in zip(Trait.allCases, bytes) {
            #expect([51, 102, 153, 204].allSatisfy { abs(b - $0) >= 4 }, "\(p.id).\(t): \(b) sits on a level edge")
        }
        // The effective traits are the design targets (within one byte of quantisation).
        for (i, t) in Trait.allCases.enumerated() {
            #expect(abs(bytes[i] - Int(MindCode.quantize(p.traitTargets[i]))) <= 1, "\(p.id).\(t)")
        }
    }

    @Test(arguments: PersonaCatalog.all)
    func feelingsAreTheBaselinesAtTheAge(_ p: PersonaPreset) {
        let base = EmotionEngine.baselines(personality: p.code.personality, age: p.age.map(Double.init))
        let want = MindCode(personality: p.code.personality, feelings: base)
        #expect(p.code == want)
    }

    @Test func classicIsTodaysDee() {
        let c = PersonaCatalog.classic
        #expect(c.setPoints == MindCode(personality: Personality(), feelings: Feelings()).personality)
        #expect(c.ageSettings(at: Date()) == nil, "Classic keeps the age settings it has")
        #expect(InnerState().setPoints == Personality() && InnerState().personaID == "classic")
    }

    @Test func applySetsAgeSetPointsAndCodeAndKeepsCounters() async throws {
        let mind = try Mind(databaseURL: nil)
        await mind.hear("You're lovely, thank you so much!")
        let before = await mind.state.interactions
        let now = Date()
        await mind.apply(PersonaCatalog.vera, at: now)
        let s = await mind.state
        let id = await mind.personaID
        #expect(s.personaID == "vera" && id == "vera")
        #expect(s.age.enabled && !s.age.agingEnabled && s.age.startAge == 46)
        #expect(s.age.yearsPerDay == AgeSettings.adultYearsPerDay, "real time if they turn ageing on")
        #expect(s.setPoints == PersonaCatalog.vera.setPoints)
        #expect(MindCode(personality: s.personality, feelings: s.feelings).hex == Self.codes["vera"])
        #expect(s.interactions == before, "relationship counters are kept")
    }

    /// Relaxation and the elastic pull go toward the preset's set points, not Classic's.
    @Test func traitsRelaxTowardThePresetsSetPoints() async throws {
        var s = InnerState(updatedAt: Date(timeIntervalSince1970: 0))
        s.setPoints = PersonaCatalog.atlas.setPoints
        let later = Date(timeIntervalSince1970: 365 * 86_400)
        let after = EmotionEngine.advance(s, to: later, circumstances: .init(userPresent: false, asleep: true))
        for t in Trait.allCases {
            #expect(abs(after.personality[t] - s.setPoints[t]) < 0.01, "\(t): \(after.personality[t]) vs \(s.setPoints[t])")
        }
        let neutral = Appraisal()
        var p = Personality()
        for _ in 0..<500 { p = EmotionEngine.drift(p, toward: neutral, age: nil, setPoints: PersonaCatalog.atlas.setPoints) }
        #expect(abs(p[.extraversion] - PersonaCatalog.atlas.setPoints[.extraversion]) < 0.01)
    }

    @Test func resetRestoresTheCurrentPreset() async throws {
        let mind = try Mind(databaseURL: nil)
        let now = Date()
        await mind.apply(PersonaCatalog.nova, at: now)
        for _ in 0..<5 { await mind.hear("You are useless and annoying, shut up!", at: now) }
        await mind.reset(at: now)
        let s = await mind.state
        #expect(s.personaID == "nova")
        #expect(MindCode(personality: s.personality, feelings: s.feelings).hex == Self.codes["nova"])
    }

    @Test func personaAndSetPointsPersist() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dee-persona-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "mind.sqlite")
        do {
            let mind = try Mind(databaseURL: url)
            await mind.apply(PersonaCatalog.rio)
        }
        let again = try Mind(databaseURL: url)
        let s = await again.state
        #expect(s.personaID == "rio")
        #expect(s.setPoints == PersonaCatalog.rio.setPoints)
        #expect(s.age.startAge == 27 && s.age.enabled)
    }

    /// An install from before the presets (schema 1, no persona keys) is Classic Dee with
    /// today's set points and its own unchanged code.
    @Test func migrationFromBeforeThePresetsIsClassic() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "dee-persona-mig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "mind.sqlite")
        let code: MindCode
        do {
            let mind = try Mind(databaseURL: url)
            await mind.hear("Hello there, I love talking to you!")
            code = await mind.code
        }
        do {
            let db = try SQLiteStore(path: url.path(percentEncoded: false))
            try db.execute("DELETE FROM meta WHERE key IN ('persona', 'set_points');")
            try db.execute("UPDATE meta SET value = '1' WHERE key = 'schema_version';")
        }
        let old = try Mind(databaseURL: url)
        let s = await old.state
        #expect(s.personaID == "classic")
        #expect(s.setPoints == MindCode(personality: Personality(), feelings: Feelings()).personality)
        let now = await old.code
        #expect(now == code, "nothing changes for current users")
    }
}
