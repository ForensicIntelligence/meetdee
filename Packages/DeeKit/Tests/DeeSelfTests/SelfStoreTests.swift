import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

@Suite struct SelfStoreTests {
    static func tempURL(_ name: String = "self") -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DeeSelfTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(name).sqlite")
    }

    /// The minimal DeeMemory `people` table (DeeMemory itself is not opened here).
    static func makePeople(_ url: URL, _ ids: [UUID]) throws {
        let db = try SelfDatabase(path: url.path)
        try db.execute("CREATE TABLE IF NOT EXISTS people(id TEXT PRIMARY KEY, name TEXT NOT NULL);")
        for id in ids { try db.query("INSERT OR IGNORE INTO people(id, name) VALUES(?, 'x')", [.text(id.uuidString)]) }
    }

    static func deletePerson(_ url: URL, _ id: UUID) throws {
        let db = try SelfDatabase(path: url.path)
        try db.query("DELETE FROM people WHERE id = ?", [.text(id.uuidString)])
    }

    static func episode(_ person: UUID?, topics: [String] = ["painting"], gist: String = "John showed me a painting") -> Episode {
        let code = Kit.snap().code
        return Episode(id: UUID(), person: person, start: Kit.t0, end: Kit.t0.addingTimeInterval(60), kind: .shared,
                       topics: topics.compactMap(Subject.init), gist: gist, why: "they seemed proud", valence: 0.6, salience: 0.9,
                       surprise: 0.1, mindBefore: code, mindAfter: Kit.happyNeutralRegard.code, openLoop: UUID())
    }

    static func allWrites(_ p: UUID) -> [SelfWrite] {
        let s = Subject("job interview")!
        var prof = SocialProfile()
        prof.pauseScale = 1.3
        prof.humorReceptiveness = 0.7
        return [
            .episode(episode(p)),
            .intention(Intention(id: UUID(), kind: .followUp, subject: s, person: p, reason: "they were nervous about it",
                                 notBefore: Kit.t0, expires: Kit.t0.addingTimeInterval(7 * 86_400), priority: 0.8, source: "plan", created: Kit.t0)),
            .expectation(Expectation(id: UUID(), person: p, subject: s, due: Kit.t0.addingTimeInterval(86_400),
                                     expires: Kit.t0.addingTimeInterval(8 * 86_400), framing: .nervous)),
            .interest(Interest(subject: Subject("watercolor")!, weight: 0.6, lastTouched: Kit.t0)),
            .facet(Facet(id: UUID(), kind: .taste, subject: Subject("rain sounds")!, innate: 0.4, learned: 0.6, evidence: 3,
                         crystallised: true, revealedAt: Kit.t0, reason: "no idea why, you just do", source: .heuristic, updatedAt: Kit.t0)),
            .lesson(Lesson(id: UUID(), person: p, situation: .moodGuess, createdAt: Kit.t0)),
            .misread(Misread(id: UUID(), person: p, at: Kit.t0, situation: .moodGuess, topic: Subject("mood"), wrongGuess: "sad")),
            .profile(p, prof),
            .boundary(Boundary(id: UUID(), person: p, topic: Subject("job")!, owner: .user, createdAt: Kit.t0)),
            .gag(Gag(id: UUID(), person: p, topic: Subject("toast")!, hookTemplate: 2, uses: 1, laughs: 1)),
            .ritual(Ritual(id: UUID(), person: p, trigger: .firstSightOfDay, variant: 3, mannerism: .bounce, count: 4, streak: 3, lastDone: Kit.t0)),
            .openRepair(p, .ruptured, togetherSecondsLeft: 3600),
            .digest(day: "2026-09-21", person: p, conversations: 1, lowSalience: 2),
        ]
    }

    @Test func freshInMemoryStoreSeedsOnceAndReloadsIdentically() async throws {
        let store = try SelfStore(url: nil)
        #expect(try await store.storedSchemaVersion() == SelfStore.schemaVersion)
        let a = try await store.loadEnduring(personality: Personality(), seed: 7, at: Kit.t0)
        #expect(a == Kit.enduring(seed: 7))
        let b = try await store.loadEnduring(personality: Personality([.openness: 0]), seed: 999, at: Kit.t0.addingTimeInterval(9))
        #expect(b == a, "seeding happens once; later calls load")
    }

    @Test func roundTripsEveryWrite() async throws {
        let url = Self.tempURL()
        try Self.makePeople(url, [Kit.john])
        let store = try SelfStore(url: url)
        _ = try await store.loadEnduring(personality: Personality(), seed: 7, at: Kit.t0)
        let writes = Self.allWrites(Kit.john)
        #expect(try await store.apply(writes) == SelfStore.ApplyResult(applied: writes.count, failed: []))

        guard case .episode(let ep) = writes[0], case .intention(let it) = writes[1], case .expectation(let ex) = writes[2],
              case .interest(let ins) = writes[3], case .facet(let fa) = writes[4], case .lesson(let le) = writes[5],
              case .misread(let mr) = writes[6], case .profile(_, let pr) = writes[7], case .boundary(let bo) = writes[8],
              case .gag(let ga) = writes[9], case .ritual(let ri) = writes[10] else { Issue.record("fixture"); return }
        #expect(try await store.episode(ep.id) == ep)
        #expect(try await store.episodes(person: Kit.john) == [ep])
        #expect(try await store.episodeIndex() == [ep.key])
        #expect(try await store.intentions() == [it])
        #expect(try await store.expectations() == [ex])
        #expect(try await store.interests() == [ins])
        #expect(try await store.facets().contains(fa))
        #expect(try await store.lessons() == [le])
        var mrStored = mr
        mrStored.wrongGuess = nil
        #expect(try await store.misreads() == [mrStored], "the wrong guess is RAM-only")
        #expect(try await store.profiles() == [Kit.john: pr])
        #expect(try await store.boundaries() == [bo])
        #expect(try await store.gags() == [ga])
        #expect(try await store.rituals() == [ri])
        #expect(try await store.openRepairs() == [Kit.john: .ruptured])
        #expect(try await store.digest(day: "2026-09-21", person: Kit.john)! == (1, 2))
        try await store.apply(.digest(day: "2026-09-21", person: Kit.john, conversations: 2, lowSalience: 1))
        #expect(try await store.digest(day: "2026-09-21", person: Kit.john)! == (3, 3))

        let carried = try await store.loadCarried()
        #expect(carried.intentions == [it] && carried.expectations == [ex] && carried.interests == [ins])
        let e = try await store.loadEnduring(personality: Personality(), seed: 1, at: Kit.t0)
        #expect(e.lessons == [le] && e.boundaries == [bo] && e.gags == [ga] && e.rituals == [ri] && e.profiles[Kit.john] == pr)
        #expect(e.episodeIndex == [ep.key])
        #expect(e.facets.count == Kit.enduring().facets.count + 1)

        // Updates replace; uniqueness (kind, subject) and (person, situation) hold.
        var it2 = it
        it2.status = .done
        try await store.apply(.intention(it2))
        #expect(try await store.intentions() == [it2])
        #expect(try await store.loadCarried().intentions.isEmpty)
        try await store.apply(.lesson(Lesson(id: UUID(), person: Kit.john, situation: .moodGuess, evidence: 3, createdAt: Kit.t0)))
        #expect(try await store.lessons().count == 1)
        #expect(try await store.lessons()[0].evidence == 3)
    }

    @Test func reopenedFileKeepsEverything() async throws {
        let url = Self.tempURL()
        try Self.makePeople(url, [Kit.john])
        do {
            let s = try SelfStore(url: url)
            _ = try await s.loadEnduring(personality: Personality(), seed: 11, at: Kit.t0)
            try await s.apply(Self.allWrites(Kit.john))
        }
        let s2 = try SelfStore(url: url)
        let e = try await s2.loadEnduring(personality: Personality(), seed: 0, at: Kit.t0)
        #expect(e.seed == 11)
        #expect(e.signature == Kit.enduring(seed: 11).signature)
        #expect(e.lessons.count == 1)
    }

    /// Review finding 6: DeeMemory deletes a `people` row when it merges a placeholder
    /// into a named person; the self rows must survive that (no cascade).
    @Test func deletingAPeopleRowNoLongerCascades() async throws {
        let url = Self.tempURL()
        try Self.makePeople(url, [Kit.john])
        let store = try SelfStore(url: url)
        try await store.apply(Self.allWrites(Kit.john))
        try Self.deletePerson(url, Kit.john)
        #expect(try await store.boundaries().count == 1)
        #expect(try await store.lessons().count == 1)
        #expect(try await store.episodes(person: Kit.john).count == 1)
    }

    @Test func forgetPersonRemovesOnlyTheirRows() async throws {
        let store = try SelfStore(url: nil)
        try await store.apply(Self.allWrites(Kit.john) + Self.allWrites(Kit.ann) + [.episode(Self.episode(nil, gist: "I heard rain"))])
        #expect(try await store.forgetPerson(Kit.john) == 11)
        #expect(try await store.episodes(person: Kit.john).isEmpty)
        #expect(try await store.episodes(person: Kit.ann).count == 1)
        #expect(try await store.episodes(person: nil).count == 1, "global episodes stay")
        #expect(try await store.lessons().allSatisfy { $0.person == Kit.ann })
        #expect(try await store.profiles().keys.sorted() == [Kit.ann])
        #expect(try await store.boundaries().allSatisfy { $0.person == Kit.ann })
        #expect(try await store.openRepairs().keys.sorted() == [Kit.ann])
        #expect(try await store.digest(day: "2026-09-21", person: Kit.john) == nil)
        #expect(try await store.intentions().allSatisfy { $0.person == Kit.ann })
        #expect(try await store.interests().count == 1, "global interests stay")
    }

    @Test func forgetPeopleSweepsOrphans() async throws {
        let store = try SelfStore(url: nil)
        try await store.apply(Self.allWrites(Kit.john) + Self.allWrites(Kit.ann) + [.episode(Self.episode(nil))])
        #expect(try await store.forgetPeople(notIn: [Kit.ann]) == 11)
        #expect(try await store.episodeIndex().count == 2)
        #expect(try await store.forgetPeople(notIn: [Kit.ann]) == 0)
    }

    /// Placeholder → named person: every row follows; UNIQUE clashes resolve like
    /// `Moment.merge` (the two are checked against each other).
    @Test func mergeRepointsRowsAndResolvesClashes() async throws {
        let store = try SelfStore(url: nil)
        try await store.apply(Self.allWrites(Kit.ann))
        var keep = SocialProfile()
        keep.pauseScale = 0.8
        let johnLesson = Lesson(id: UUID(), person: Kit.john, situation: .moodGuess, evidence: 3, lastApplied: Kit.t0.addingTimeInterval(50),
                                createdAt: Kit.t0.addingTimeInterval(9))
        try await store.apply([.lesson(johnLesson), .profile(Kit.john, keep), .digest(day: "2026-09-21", person: Kit.john, conversations: 4, lowSalience: 0),
                               .boundary(Boundary(id: UUID(), person: Kit.john, topic: Subject("job")!, owner: .user, createdAt: Kit.t0, active: false))])
        try await store.merge(from: Kit.ann, into: Kit.john)
        let lessons = try await store.lessons()
        #expect(lessons.count == 1)
        #expect(lessons[0].id == johnLesson.id && lessons[0].evidence == 5 && lessons[0].createdAt == Kit.t0)
        #expect(lessons[0].lastApplied == Kit.t0.addingTimeInterval(50))
        #expect(try await store.profiles() == [Kit.john: keep], "into's profile wins")
        #expect(try await store.digest(day: "2026-09-21", person: Kit.john)! == (5, 2))
        let b = try await store.boundaries()
        #expect(b.count == 1 && b[0].person == Kit.john && b[0].active, "one boundary, active if either was")
        #expect(try await store.openRepairs() == [Kit.john: .ruptured])
        #expect(try await store.episodes(person: Kit.john).count == 1)
        #expect(try await store.intentions().allSatisfy { $0.person == Kit.john })
        #expect(try await store.expectations().allSatisfy { $0.person == Kit.john })
        for t in SelfStore.personTables {
            #expect(try await store.count(t, person: Kit.ann) == 0, "\(t)")
        }
        // The RAM merge agrees with the store.
        var m = Kit.moment()
        m.enduring.lessons = [Lesson(id: UUID(), person: Kit.ann, situation: .moodGuess, evidence: 2, createdAt: Kit.t0), johnLesson]
        m.merge(from: Kit.ann, into: Kit.john)
        #expect(m.enduring.lessons.map(\.evidence) == [5] && m.enduring.lessons[0].createdAt == Kit.t0)
        #expect(m.enduring.lessons[0].lastApplied == Kit.t0.addingTimeInterval(50))
    }

    /// v1 files (person rows cascading from `people`) are rebuilt plain, rows kept.
    @Test func v1MigratesToPlainPersonColumns() async throws {
        let url = Self.tempURL()
        try Self.makePeople(url, [Kit.john])
        do {
            let s = try SelfStore(url: url)
            try await s.apply([.episode(Self.episode(Kit.john)), .episode(Self.episode(nil))])
        }
        do {
            // Turn the file back into a v1 one: the episode table with its old cascade.
            let db = try SelfDatabase(path: url.path)
            try db.execute("""
                CREATE TABLE episode_v1 AS SELECT * FROM episode; DROP TABLE episode;
                """)
            try db.execute(SelfStore.ddl("episode").replacingOccurrences(of: "person_id TEXT,", with: "person_id TEXT REFERENCES people(id) ON DELETE CASCADE,"))
            try db.execute("INSERT INTO episode SELECT * FROM episode_v1; DROP TABLE episode_v1;")
            try db.query("UPDATE self_meta SET value = '1' WHERE key = 'schema_version'")
            try db.query("INSERT OR REPLACE INTO self_meta(key, value) VALUES('people_fk', '1')")
        }
        let s2 = try SelfStore(url: url)
        #expect(try await s2.storedSchemaVersion() == 2)
        #expect(try await s2.meta("people_fk") == nil)
        #expect(try await s2.episodeIndex().count == 2)
        try Self.deletePerson(url, Kit.john)
        #expect(try await s2.episodeIndex().count == 2, "no cascade any more")
    }

    @Test func newerSchemaIsRefusedAndUntouched() async throws {
        let url = Self.tempURL()
        do {
            let s = try SelfStore(url: url)
            try await s.setMeta("schema_version", "99")
            try await s.checkpoint()
        }
        let before = try Data(contentsOf: url)
        #expect(throws: SelfStore.Failure.newerSchema(found: 99, supported: SelfStore.schemaVersion)) { try SelfStore(url: url) }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func forgetAllKeepsOnlyTheSeededSelf() async throws {
        let url = Self.tempURL()
        try Self.makePeople(url, [Kit.john])
        let store = try SelfStore(url: url)
        let e0 = try await store.loadEnduring(personality: Personality(), seed: 5, at: Kit.t0)
        try await store.apply(Self.allWrites(Kit.john) + [.episode(Self.episode(nil))])
        var learnt = e0
        learnt.facets[0].learned = 0.4
        learnt.facets[0].evidence = 4
        learnt.facets[0].revealedAt = Kit.t0
        try await store.apply(.facet(learnt.facets[0]))
        let loaded = try await store.loadEnduring(personality: Personality(), seed: 0, at: Kit.t0)
        try await store.setMeta("last_reflection", "123")
        let session = try await store.nextSession()
        try await store.forgetAll()
        let e = try await store.loadEnduring(personality: Personality(), seed: 0, at: Kit.t0)
        #expect(e == e0)
        #expect(e == loaded.keepingSeeded(), "Cortex.forgetAll keeps exactly what the store keeps")
        #expect(try await store.nextSession() == session + 1, "the launch counter survives")
        #expect(try await store.meta("last_reflection") == nil)
        #expect(try await store.episodeIndex().isEmpty)
        #expect(try await store.interests().isEmpty)
        #expect(try await store.loadCarried() == Carried())
    }

    @Test func forgetSubjectRemovesEveryRowAboutIt() async throws {
        let store = try SelfStore(url: nil)
        let byGist = Self.episode(nil, topics: ["rain"], gist: "John said they have a job interview Friday")
        try await store.apply([.episode(Self.episode(nil, topics: ["painting", "job interview"])), .episode(Self.episode(nil, topics: ["rain"])), .episode(byGist)]
                              + Self.allWrites(Kit.john).filter { ["intention", "expectation"].contains($0.name) }
                              + [.misread(Misread(id: UUID(), person: Kit.john, at: Kit.t0, situation: .moodGuess, topic: Subject("interviews"))),
                                 .interest(Interest(subject: Subject("interview")!, weight: 0.5, lastTouched: Kit.t0)),
                                 .interest(Interest(subject: Subject("view")!, weight: 0.5, lastTouched: Kit.t0)),
                                 .gag(Gag(id: UUID(), person: nil, topic: Subject("job interview")!, hookTemplate: 0))])
        let gone = try await store.forget(subject: Subject("interview")!)
        #expect(gone.episodes.count == 2 && gone.episodes.contains(byGist.id))
        #expect(gone.rows == 7)
        #expect(try await store.episodeIndex().map(\.topics) == [[Subject("rain")!]])
        #expect(try await store.expectations().isEmpty)
        #expect(try await store.intentions().isEmpty)
        #expect(try await store.misreads().isEmpty)
        #expect(try await store.interests().map(\.subject.text) == ["view"], "whole words only")
        #expect(try await store.gags().isEmpty)
    }

    @Test func recalledWriteBumpsTheCount() async throws {
        let store = try SelfStore(url: nil)
        let ep = Self.episode(nil)
        try await store.apply([.episode(ep), .recalled(episode: ep.id, at: Kit.t0.addingTimeInterval(7))])
        let back = try await store.episode(ep.id)
        #expect(back?.recalled == 1 && back?.lastRecalled == Kit.t0.addingTimeInterval(7))
    }

    /// Review finding 7: a stored seed is never replaced by the caller's new one.
    @Test func undecodableIdentityPieceIsRederivedFromTheStoredSeed() async throws {
        let store = try SelfStore(url: nil)
        let e0 = try await store.loadEnduring(personality: Personality(), seed: 7, at: Kit.t0)
        try await store.apply(.lesson(Lesson(id: UUID(), person: nil, situation: .jokeFlopped, createdAt: Kit.t0)))
        try await store.setMeta("signature", "{not json")
        try await store.setMeta("humour", "slapstick")
        let e = try await store.loadEnduring(personality: Personality(), seed: 999, at: Kit.t0)
        #expect(e.seed == 7 && e.values == e0.values && e.signature == e0.signature && e.humour == e0.humour)
        #expect(e.lessons.count == 1, "learning untouched")
        #expect(try await store.meta("seed") == "7")
    }

    @Test func carriedMisreadsAreTheLastFourteenDays() async throws {
        let store = try SelfStore(url: nil)
        let old = Misread(id: UUID(), person: Kit.john, at: Kit.t0, situation: .moodGuess)
        let recent = Misread(id: UUID(), person: Kit.john, at: Kit.t0.addingTimeInterval(10 * 86_400), situation: .tookLiterally)
        try await store.apply([.misread(old), .misread(recent)])
        #expect(try await store.loadCarried(at: Kit.t0.addingTimeInterval(20 * 86_400)).misreads.map(\.id) == [recent.id])
        #expect(try await store.loadCarried().misreads.count == 2)
    }

    @Test func sessionsCountUp() async throws {
        let store = try SelfStore(url: nil)
        #expect(try await store.nextSession() == 1)
        #expect(try await store.nextSession() == 2)
    }

    @Test func schemaHasNoTranscriptColumnsAndChecksLengths() async throws {
        let store = try SelfStore(url: nil)
        let cols = try await store.columns()
        for (t, cs) in cols {
            for c in cs {
                for banned in ["transcript", "utterance", "text", "partial", "reply", "sentence", "message"] {
                    #expect(!c.lowercased().contains(banned), "\(t).\(c)")
                }
            }
        }
        let lax = try SelfStore(url: nil, assertOnFailedWrites: false)
        var long = Self.episode(nil)
        long.gist = String(repeating: "x", count: 101)
        let r = try await lax.apply([.episode(Self.episode(nil)), .episode(long)])
        #expect(r.applied == 1, "CHECK(length(gist) <= 100)")
        #expect(r.failed.map(\.index) == [1] && r.failed[0].write == "episode" && r.failed[0].reason.contains("CHECK"))
        #expect(try await lax.episodeIndex().count == 1, "the rest of the batch still applies")
    }
}
