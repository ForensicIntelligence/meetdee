import DeeCore
import Foundation
import Testing
@testable import DeeMemory

/// Regression tests for the second verification report (new problems 1–6, 8,
/// 9, the self-harm and sensitivity gaps, and cheap over-hiding fixes).
@Suite("Verification 2 regressions")
struct Verify2RegressionTests {
    func texts(_ u: String) -> [String] { FactExtractor.extract(from: u, now: t0, calendar: utc).map(\.text) }
    func names(_ u: String) -> [String] { FactExtractor.extract(from: u, now: t0, calendar: utc).compactMap(\.name) }

    // MARK: 1 — databases written by 0.4.0 are re-checked (schema v3)

    @Test func v1_oldDatabaseIsRecheckedOnOpen() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dee-v3-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("DeeMemory.sqlite")
        let john = UUID()
        // A 0.4.0 database (schema v2), with rows the old rules let through.
        let rows: [(String, Fact.Category, Bool)] = [
            ("likes jazz", .preference, false),
            ("works at Visa", .work, false),
            ("works as a therapist", .work, false),
            ("is a sex worker", .work, false),
            ("is a lesbian", .other, false),
            ("loves Hitler", .preference, false),
            ("hates the Chinese", .dislike, false),
            ("hates their life", .dislike, false),
            ("has their AA meeting tonight", .event, false),
            ("has depression", .work, false),
            ("voted for Trump", .work, false),
            ("hates being alive", .dislike, false),
            ("has cancer", .health, true),
        ]
        do {
            let db = try MemoryDatabase(path: url.path)
            try db.execute("""
            CREATE TABLE schema_version(version INTEGER NOT NULL);
            CREATE TABLE people(id TEXT PRIMARY KEY, name TEXT NOT NULL,
                first_met REAL NOT NULL, last_seen REAL NOT NULL, encounters INTEGER NOT NULL DEFAULT 1, session TEXT);
            CREATE TABLE aliases(person_id TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                alias TEXT NOT NULL COLLATE NOCASE, PRIMARY KEY(person_id, alias));
            CREATE TABLE face_prints(id INTEGER PRIMARY KEY AUTOINCREMENT,
                person_id TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                vector BLOB NOT NULL, added_at REAL NOT NULL, anchor INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX face_prints_person ON face_prints(person_id);
            CREATE TABLE facts(id TEXT PRIMARY KEY, person_id TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                text TEXT NOT NULL, category TEXT NOT NULL, confidence REAL NOT NULL,
                created_at REAL NOT NULL, updated_at REAL NOT NULL, sensitive INTEGER NOT NULL DEFAULT 0);
            CREATE INDEX facts_person ON facts(person_id);
            INSERT INTO schema_version(version) VALUES (2);
            """)
            let at = t0.timeIntervalSince1970
            try db.query("INSERT INTO people(id, name, first_met, last_seen, encounters) VALUES (?, 'John', ?, ?, 1);",
                         [.text(john.uuidString), .real(at), .real(at)])
            for (text, cat, sensitive) in rows {
                try db.query("INSERT INTO facts(id, person_id, text, category, confidence, created_at, updated_at, sensitive) VALUES (?, ?, ?, ?, 0.8, ?, ?, ?);",
                             [.text(UUID().uuidString), .text(john.uuidString), .text(text), .text(cat.rawValue),
                              .real(at), .real(at), .int(sensitive ? 1 : 0)])
            }
        }
        let s = try MemoryStore(databaseURL: url, faceMatching: FaceMatching(), calendar: utc)
        let p = try #require(await s.person(john))
        let kept = Dictionary(uniqueKeysWithValues: p.facts.map { ($0.text, $0.sensitive) })
        // Denied and self-harm rows are gone.
        for gone in ["loves Hitler", "hates the Chinese", "hates their life", "hates being alive"] {
            #expect(kept[gone] == nil, "\(gone) must be deleted")
        }
        // Sensitivity recomputed with today's rules.
        #expect(kept["likes jazz"] == false)
        #expect(kept["works at Visa"] == false)
        #expect(kept["works as a therapist"] == false)
        for hidden in ["is a sex worker", "is a lesbian", "has their AA meeting tonight", "has depression", "voted for Trump", "has cancer"] {
            #expect(kept[hidden] == true, "\(hidden) must be sensitive")
        }
        let prompt = await s.promptMemories(for: john, limit: 12, now: t0)
        #expect(prompt.contains("John likes jazz") && prompt.contains("John works at Visa"))
        for banned in ["sex worker", "lesbian", "Hitler", "Chinese", "their life", "AA", "depression", "Trump", "alive", "cancer"] {
            #expect(!prompt.contains { $0.contains(banned) }, "\(banned) leaked: \(prompt)")
        }
        // The deleted text is not left in the WAL or the main file.
        let wal = (try? FileManager.default.attributesOfItem(atPath: url.path + "-wal")[.size] as? Int) ?? 0
        #expect(wal == 0)
        for suffix in ["", "-wal", "-shm"] {
            guard let data = FileManager.default.contents(atPath: url.path + suffix) else { continue }
            #expect(data.range(of: Data("Hitler".utf8)) == nil, "Hitler in \(suffix)")
            #expect(data.range(of: Data("being alive".utf8)) == nil, "being alive in \(suffix)")
        }
        // The version is now current, so reopening does not redo the work.
        #expect(MemoryStore.schemaVersion == 3)
    }

    // MARK: 2 — one matching print no longer merges a stranger

    @Test func v2_singleStrayPrintDoesNotMerge() async throws {
        let s = try memStore()
        var r = LCG(state: 2002)
        let face = unit(r.vector())
        let john = try #require(await s.enroll(name: "John", facePrints: enrolment(face, &r), at: t0))
        await s.remember("has a wife named Anna", category: .relationship, about: john.id, at: t0)
        // A stranger: three prints of their own face plus one frame of John walking past.
        let stranger = unit(r.vector())
        let g = await s.placeholderPerson(session: UUID(), at: t0)
        await s.addFacePrints(enrolment(stranger, &r, spread: 0.1), to: g.id, passedQualityGate: true)
        await s.addFacePrints([jitter(face, toward: r.vector(), distance: 0.3)], to: g.id)
        let result = await s.confirm("John", for: g.id, at: t0)
        guard case .mergeCandidate(let ph, let existing) = result else { Issue.record("got \(result)"); return }
        #expect(ph.id == g.id && existing.id == john.id)
        let p = await s.confirmName("John", for: g.id, at: t0)
        #expect(p.id != john.id)
        #expect(!(await s.promptMemories(for: p.id, limit: 10, now: t0)).contains { $0.contains("Anna") })

        // A placeholder whose prints are (nearly) all John does merge.
        let h = await s.placeholderPerson(session: UUID(), at: t0)
        await s.addFacePrints([jitter(face, toward: r.vector(), distance: 0.3), jitter(face, toward: r.vector(), distance: 0.35),
                               jitter(stranger, toward: r.vector(), distance: 0.2)], to: h.id)
        guard case .merged(let m) = await s.confirm("John", for: h.id, at: t0) else { Issue.record("should merge"); return }
        #expect(m.id == john.id)
    }

    @Test func v2_centroid() throws {
        let a = FacePrint(vector: [1, 0, 0]), b = FacePrint(vector: [0, 1, 0])
        let c = try #require(MemoryStore.centroid([a, b]))
        #expect(abs(c.distance(to: a) - c.distance(to: b)) < 1e-5)
        #expect(MemoryStore.centroid([]) == nil)
        #expect(MemoryStore.centroid([a, FacePrint(vector: [-1, 0, 0])]) == nil)
    }

    // MARK: 3 — self-harm detection

    @Test(arguments: [
        "My family would be better off without me",
        "You'd all be better off without me",
        "They'd be better off without me",
        "Life isn't worth living",
        "I want to go to sleep and never wake up",
        "I can't do this anymore",
        "I'm a burden to everyone",
        "I feel like jumping off a bridge",
        "kms",
        "honestly I just want to unalive myself",
        "I hate being alive",
        "I hate who I am",
        "I want to die",
        "I'm going to die",
        "I can't take it anymore",
    ])
    func v3_selfHarmSignals(_ u: String) async throws {
        #expect(FactExtractor.selfHarmSignal(in: u), "\(u)")
        #expect(texts(u).isEmpty, "\(u) → \(texts(u))")
        let s = try memStore()
        let john = try await named(s, "John")
        let o = await s.learn(from: u, about: john.id, at: t0)
        #expect(o.wellbeingConcern && o.stored.isEmpty)
    }

    @Test(arguments: [
        "I'm going to die of embarrassment",
        "If I have to sit through another meeting I'm going to die",
        "I wanna die this song is so good",
        "I'm thinking of ending things with Sarah",
        "I ran 10 kms today",
        "I can't do this puzzle",
        "I hate living in Toronto",
        "I never wake up before nine",
    ])
    func v3_notSelfHarm(_ u: String) {
        #expect(!FactExtractor.selfHarmSignal(in: u), "\(u)")
    }

    @Test func v3_selfHarmFactsAreNeverStored() async throws {
        let s = try memStore()
        let john = try await named(s, "John")
        #expect(await s.remember("hates being alive", category: .dislike, about: john.id, at: t0) == nil)
        #expect(await s.remember("hates who they are", category: .dislike, about: john.id, at: t0) == nil)
        #expect(await s.learn(from: "I hate living in Toronto", about: john.id, at: t0).stored.map(\.text) == ["hates living in Toronto"])
    }

    // MARK: 4 — sensitivity regardless of category

    @Test(arguments: [
        ("has depression", Fact.Category.work), ("has cancer", .work), ("is undocumented", .work),
        ("is in debt", .work), ("is getting divorced", .work), ("voted for Trump", .work),
        ("is a Republican", .work), ("earns 40k", .work), ("takes Prozac", .other), ("goes to mass", .other),
        ("goes to mass", .work), ("does coke on weekends", .preference), ("is a bartender at a strip club", .work),
        ("has diabetes", .other), ("is on a work visa", .other), ("owes money to the bank", .other),
        ("makes $90k a year", .work), ("is homeless", .other), ("smokes pot", .preference),
        ("is a Democrat", .other), ("is waiting for a green card", .event),
    ])
    func v4_sensitiveInAnyCategory(_ t: (String, Fact.Category)) async throws {
        #expect(FactSensitivity.isSensitive(t.0, category: t.1), "\(t.0) (\(t.1))")
        let s = try memStore()
        let john = try await named(s, "John")
        let f = try #require(await s.remember(t.0, category: t.1, about: john.id, at: t0))
        #expect(f.sensitive)
        #expect(await s.promptMemories(for: john.id, limit: 10, now: t0) == ["Name: John"])
    }

    @Test(arguments: [
        ("works at Visa", Fact.Category.work), ("works as a therapist", .work), ("is a lawyer", .work),
        ("works in cancer research", .work), ("works at the courthouse", .work), ("likes Christian rock", .preference),
        ("likes trans-Am cars", .preference), ("is an AA battery collector", .preference), ("has a son named Christian", .relationship),
        ("likes the Sex Pistols", .preference), ("likes jazz", .preference), ("is married to Christian", .relationship),
    ])
    func v4_notSensitive(_ t: (String, Fact.Category)) {
        #expect(!FactSensitivity.isSensitive(t.0, category: t.1), "\(t.0) (\(t.1))")
    }

    @Test func v4_drugUseFromSpeechIsHidden() async throws {
        let s = try memStore()
        let john = try await named(s, "John")
        let o = await s.learn(from: "I do coke on weekends", about: john.id, at: t0)
        #expect(!o.stored.isEmpty)
        #expect(o.stored.allSatisfy { $0.sensitive })
        #expect(await s.promptMemories(for: john.id, limit: 10, now: t0) == ["Name: John"])
    }

    @Test func v4_hostilityToPeopleIsDenied() {
        #expect(FactPolicy.isDenied("hates women"))
        #expect(FactPolicy.isDenied("hates fat people"))
        #expect(FactPolicy.isDenied("can't stand old people"))
        #expect(!FactPolicy.isDenied("hates women's football commentary on TV"))
        #expect(!FactPolicy.isDenied("hates fat-free yogurt"))
    }

    // MARK: 5 — a fuller name is the same speaker

    @Test func v5_fullNameIsTheSameSpeaker() async throws {
        let s = try memStore()
        let john = try await named(s, "John")
        let o = await s.learn(from: "I'm John Smith and I love jazz", about: john.id, at: t0)
        #expect(!o.differentSpeaker)
        #expect(o.suggestedAlias == "John Smith")
        #expect(o.stored.map(\.text) == ["loves jazz"])
        guard case .named(let p, _) = await s.confirm("John Smith", for: john.id, at: t0) else { Issue.record("named"); return }
        #expect(p.id == john.id)
        // The other way round, and a different surname.
        let js = try await named(s, "Jane Smith")
        #expect(!(await s.learn(from: "I'm Jane and I like tea", about: js.id, at: t0)).differentSpeaker)
        let other = await s.learn(from: "I'm Jane Doe and I like tea", about: js.id, at: t0)
        #expect(other.differentSpeaker && other.stored.isEmpty)
        guard case .differentSpeaker = await s.confirm("Jane Doe", for: js.id, at: t0) else { Issue.record("different"); return }
        #expect(MemoryStore.isFullerName("john smith", of: john))
        #expect(!MemoryStore.isFullerName("Johnny", of: john))
    }

    // MARK: 6 — more ways of saying a name

    @Test func v6_namePatterns() async throws {
        #expect(names("Mike's my name and I love golf") == ["Mike"])
        #expect(names("Mike is my name") == ["Mike"])
        #expect(names("I'm the plumber, Mike. I love golf") == ["Mike"])
        #expect(names("I'm your driver, Sam") == ["Sam"])
        #expect(names("I'm Anna's dad, Tom") == ["Tom"])
        #expect(names("I'm so sorry, John").isEmpty)
        #expect(names("That's my name").isEmpty)
        let s = try memStore()
        let john = try await named(s, "John")
        for u in ["Mike's my name and I love golf", "I'm the plumber, Mike. I love golf"] {
            let o = await s.learn(from: u, about: john.id, at: t0)
            #expect(o.differentSpeaker && o.stored.isEmpty, "\(u)")
        }
        #expect(await s.person(john.id)?.facts.isEmpty == true)
    }

    // MARK: 8 — merged-away ids resolve everywhere

    @Test func v8_staleIdsResolve() async throws {
        let s = try memStore()
        var r = LCG(state: 2008)
        let face = unit(r.vector())
        let john = try #require(await s.enroll(name: "John", facePrints: enrolment(face, &r), at: t0))
        let g = await s.placeholderPerson(session: UUID(), at: t0)
        guard case .merged = await s.confirm("John", for: g.id, at: t0, choice: .sameAs(john.id)) else { Issue.record("merge"); return }
        #expect(await s.person(g.id)?.id == john.id)
        let before = await s.facePrintCount(of: john.id)
        await s.addFacePrints([jitter(face, toward: r.vector(), distance: 0.2)], to: g.id)
        #expect(await s.facePrintCount(of: john.id) == before + 1)
        await s.remember("likes jazz", category: .preference, about: john.id, at: t0)
        // The tools follow the stale id too.
        let current = Box(g.id)
        let registry = ToolRegistry([ForgetTool(store: s, currentPerson: { current.id })])
        let reply = await registry.execute(call("forget_fact", ["fact": "likes jazz"]))
        #expect(reply.contains("Forgot"), "\(reply)")
        #expect(await s.person(john.id)?.facts.isEmpty == true)
        // forgetPerson with the stale id forgets the person it became.
        await s.forgetPerson(g.id)
        #expect(await s.person(john.id) == nil)
        #expect(await s.people().isEmpty)
    }

    // MARK: 9 — demonyms, circumstances, and introductions that keep their names

    @Test(arguments: ["Congolese", "Senegalese", "Nepalese", "Sudanese", "Togolese", "Beninese", "Guyanese",
                      "Faroese", "Bhutanese", "Homeless", "Unemployed", "Jobless", "Rwandan", "Kazakh"])
    func v9_notNames(_ w: String) {
        #expect(names("Hi, I'm \(w)").isEmpty, "\(w)")
        #expect(names("I'm \(w)").isEmpty, "\(w)")
    }

    @Test func v9_namesAndIntroductionsKeepInformation() async throws {
        #expect(texts("I have a son named Christian") == ["has a son named Christian"])
        #expect(texts("This is Sarah, my wife") == ["has a wife named Sarah"])
        #expect(FactExtractor.introductions(in: "This is Sarah, my wife") == ["Sarah"])
        #expect(texts("Meet my friend Sarah, she lives in Rome") == ["has a friend named Sarah"])
        #expect(FactExtractor.introductions(in: "Meet my friend Sarah, she lives in Rome") == ["Sarah"])
        #expect(FactExtractor.introductions(in: "Hey, this is Tom, my brother") == ["Tom"])
        // Religion statements are still not names.
        #expect(names("I'm Christian").isEmpty)
        let s = try memStore()
        let john = try await named(s, "John")
        let o = await s.learn(from: "This is Sarah, my wife", about: john.id, at: t0)
        #expect(o.introduced == ["Sarah"] && o.pendingName == nil && !o.differentSpeaker)
        #expect(o.stored.map(\.text) == ["has a wife named Sarah"])
        let c = await s.learn(from: "I have a son named Christian", about: john.id, at: t0)
        #expect(c.stored.map(\.sensitive) == [false])
        let lines = await s.promptMemories(for: john.id, limit: 10, now: t0)
        #expect(lines.contains("John has a son named Christian"), "\(lines)")
    }
}
