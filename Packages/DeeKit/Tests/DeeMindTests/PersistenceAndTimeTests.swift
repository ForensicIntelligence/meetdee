import DeeCore
import Foundation
import Testing
@testable import DeeMind

/// Persistence robustness (schema, fallbacks, locking, write throttling, snapshot
/// ordering) and the time model (absence, resting, catch-up, reunion), plus the
/// engine-level guards against farming and runaway drift.
@Suite struct PersistenceAndTimeTests {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    static func tempDB() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "DeeMindPersist-\(UUID().uuidString).sqlite")
    }

    static func removeDB(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path(percentEncoded: false) + suffix))
        }
    }

    static func meta(_ url: URL, _ key: String) throws -> String? {
        let db = try SQLiteStore(path: url.path(percentEncoded: false))
        return try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?["value"]?.string
    }

    static func kind() -> Appraisal {
        var a = Appraisal()
        a.warmth = 0.6; a.praise = 0.5; a.affection = 0.6; a.gratitude = 0.3; a.valence = 0.7
        return a
    }

    // MARK: - Schema and load fallbacks (review #3)

    @Test func staleParameterRowsDoNotResetDee() async throws {
        let url = Self.tempDB()
        defer { Self.removeDB(url) }
        let code: MindCode
        do {
            let mind = try Mind(databaseURL: url, now: Self.t0)
            await mind.hear("thank you, you're so clever", at: Self.t0 + 5)
            code = await mind.code
        }
        // A parameter from some other version lingers in the table.
        do {
            let db = try SQLiteStore(path: url.path(percentEncoded: false))
            try db.query("INSERT INTO parameters(name, kind, position, value, byte) VALUES('wisdom', 'trait', 99, 0.5, 128)")
        }
        let reopened = try Mind(databaseURL: url, now: Self.t0 + 10)
        #expect(await reopened.code == code, "an extra row must not wipe Dee")
        #expect(await reopened.state.interactions == 1)
        // The next save rewrites the parameter set, so the stale row is gone.
        await reopened.hear("hello", at: Self.t0 + 20)
        let db = try SQLiteStore(path: url.path(percentEncoded: false))
        #expect(try db.query("SELECT name FROM parameters").count == MindCode.parameterCount)
    }

    @Test func missingParameterRowsFallBackToMindCode() async throws {
        let url = Self.tempDB()
        defer { Self.removeDB(url) }
        let code: MindCode
        do {
            let mind = try Mind(databaseURL: url, now: Self.t0)
            await mind.hear("I love you, buddy", at: Self.t0 + 5)
            code = await mind.code
        }
        do {
            let db = try SQLiteStore(path: url.path(percentEncoded: false))
            try db.execute("DELETE FROM parameters WHERE name IN ('joy', 'openness');")
        }
        #expect(await (try Mind(databaseURL: url, now: Self.t0 + 10)).code == code, "partial rows + mind_code")
        do {
            let db = try SQLiteStore(path: url.path(percentEncoded: false))
            try db.execute("DELETE FROM parameters;")
        }
        let fromCode = try Mind(databaseURL: url, now: Self.t0 + 20)
        #expect(await fromCode.code == code, "no rows at all: the canonical code restores Dee")
        #expect(await fromCode.state.interactions == 1)
    }

    @Test func nothingUsableMeansAFreshDee() async throws {
        let url = Self.tempDB()
        defer { Self.removeDB(url) }
        do { _ = try Mind(databaseURL: url, now: Self.t0) }
        do {
            let db = try SQLiteStore(path: url.path(percentEncoded: false))
            try db.execute("DELETE FROM parameters; UPDATE meta SET value = 'garbage' WHERE key = 'mind_code';")
        }
        let mind = try Mind(databaseURL: url, now: Self.t0 + 1)
        #expect(await mind.state.personality == Personality())
    }

    @Test func newerSchemaIsRefusedNotOverwritten() async throws {
        let url = Self.tempDB()
        defer { Self.removeDB(url) }
        do { _ = try Mind(databaseURL: url, now: Self.t0) }
        do {
            let db = try SQLiteStore(path: url.path(percentEncoded: false))
            try db.execute("UPDATE meta SET value = '99' WHERE key = 'schema_version';")
        }
        #expect(throws: Mind.Failure.self) { _ = try Mind(databaseURL: url, now: Self.t0) }
        #expect(try Self.meta(url, "schema_version") == "99", "left untouched")
    }

    @Test func schemaVersionIsWritten() async throws {
        let url = Self.tempDB()
        defer { Self.removeDB(url) }
        _ = try Mind(databaseURL: url, now: Self.t0)
        #expect(try Self.meta(url, "schema_version") == String(Mind.schemaVersion))
    }

    // MARK: - SQLiteStore (review #9)

    @Test func nestedTransactionsUseSavepoints() throws {
        let db = try SQLiteStore(path: ":memory:")
        try db.execute("CREATE TABLE t(x INTEGER);")
        try db.transaction {
            try db.query("INSERT INTO t VALUES(1)")
            try? db.transaction {
                try db.query("INSERT INTO t VALUES(2)")
                throw SQLiteStore.Failure.step("inner fails")
            }
            try db.transaction { try db.query("INSERT INTO t VALUES(3)") }
        }
        let xs = try db.query("SELECT x FROM t ORDER BY x").compactMap { $0["x"]?.double }
        #expect(xs == [1, 3], "inner failure rolls back only the savepoint")

        #expect(throws: (any Error).self) {
            try db.transaction {
                try db.query("INSERT INTO t VALUES(4)")
                throw SQLiteStore.Failure.step("outer fails")
            }
        }
        #expect(try db.query("SELECT x FROM t").count == 2)
    }

    @Test func concurrentTransactionsOnOneStoreDoNotInterleave() async throws {
        let db = try SQLiteStore(path: ":memory:")
        try db.execute("CREATE TABLE t(x INTEGER);")
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask {
                    try? db.transaction {
                        for j in 0..<20 { try db.query("INSERT INTO t VALUES(?)", [.int(Int64(i * 100 + j))]) }
                    }
                }
            }
        }
        #expect(try db.query("SELECT x FROM t").count == 160)
    }

    @Test func twoMindsOnOneFileBothPersist() async throws {
        let url = Self.tempDB()
        defer { Self.removeDB(url) }
        let a = try Mind(databaseURL: url, now: Self.t0)
        let b = try Mind(databaseURL: url, now: Self.t0)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for i in 0..<30 { await a.hear("hello \(i)", at: Self.t0 + Double(i + 1)) } }
            group.addTask { for i in 0..<30 { await b.hear("hi \(i)", at: Self.t0 + Double(i + 1)) } }
        }
        // Every write committed (busy timeout instead of SQLITE_BUSY): the daily
        // count holds all 60 utterances.
        let history = await a.history()
        #expect(history.map(\.interactions).reduce(0, +) == 60)
    }

    // MARK: - Write throttling and flush (review #17)

    @Test func tickWritesAreThrottledAndFlushed() async throws {
        let url = Self.tempDB()
        defer { Self.removeDB(url) }
        let mind = try Mind(databaseURL: url, now: Self.t0)
        await mind.hear("wow, what a surprise!", at: Self.t0 + 1)   // surprise decays fast → bytes change every tick
        let saved = try Self.meta(url, "updated_at")
        for i in 1...4 { await mind.tick(at: Self.t0 + 1 + Double(i) * 5, userPresent: true, asleep: false) }
        #expect(try Self.meta(url, "updated_at") == saved, "no write within \(Mind.tickPersistInterval) s")
        await mind.flush(at: Self.t0 + 22)
        #expect(try Self.meta(url, "updated_at") != saved, "flush writes what was held back")
        let flushed = try Self.meta(url, "updated_at")
        await mind.flush(at: Self.t0 + 23)
        #expect(try Self.meta(url, "updated_at") == flushed, "nothing pending, nothing written")
        await mind.tick(at: Self.t0 + 60, userPresent: true, asleep: false)
        #expect(try Self.meta(url, "updated_at") != flushed, "the interval elapsed → written")
    }

    @Test func hearRecordsStateAndDailyTogether() async throws {
        let url = Self.tempDB()
        defer { Self.removeDB(url) }
        let mind = try Mind(databaseURL: url, now: Self.t0)
        await mind.hear("thank you", at: Self.t0 + 1)
        let db = try SQLiteStore(path: url.path(percentEncoded: false))
        let daily = try db.query("SELECT code FROM daily")
        #expect(daily.count == 1)
        #expect(daily.first?["code"]?.string == (try Self.meta(url, "mind_code")), "same transaction, same code")
    }

    // MARK: - Snapshot ordering (review #13)

    @Test func snapshotsCarryIncreasingSequenceNumbers() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        let a = await mind.snapshot(at: Self.t0)
        let b = await mind.tick(at: Self.t0 + 1, userPresent: true, asleep: false)
        let c = await mind.hear("hi", at: Self.t0 + 2).snapshot
        let d = await mind.react(.wave, at: Self.t0 + 3)
        let e = await mind.catchUp(to: Self.t0 + 4)
        #expect([a, b, c, d, e].map(\.sequence) == [1, 2, 3, 4, 5].map(UInt64.init))
        #expect(MindSnapshot(code: a.code, age: nil).sequence == 0)
        var later = a
        later.sequence = 99
        #expect(later == a, "equality ignores the sequence")
    }

    // MARK: - Restore (B5) and new state persisted

    @Test func restoreClearsShortTermMemory() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        await mind.hear("you're stupid", at: Self.t0 + 1)
        await mind.hear("sorry", at: Self.t0 + 2)
        await mind.hear("you're stupid", at: Self.t0 + 3)
        let s0 = await mind.state
        #expect(s0.apologyFatigue > 0 && s0.reoffense > 0 && s0.hostileRecent > 0)
        await mind.restore(try #require(MindCode(hex: String(repeating: "80", count: 26))), at: Self.t0 + 4)
        let s = await mind.state
        #expect(s.apologyFatigue == 0 && s.reoffense == 0 && s.hostileRecent == 0 && s.kindRecent == 0)
        #expect(s.lastApologyAt == nil && s.trustGainRecent == 0)
        #expect(s.interactions == 3, "counters are kept")
    }

    @Test func recentHistoryPersists() async throws {
        let url = Self.tempDB()
        defer { Self.removeDB(url) }
        let before: InnerState
        do {
            let mind = try Mind(databaseURL: url, now: Self.t0)
            await mind.hear("I love you", at: Self.t0 + 1)
            await mind.hear("sorry", at: Self.t0 + 2)
            await mind.hear("you're stupid", at: Self.t0 + 3)
            before = await mind.state
        }
        let after = await (try Mind(databaseURL: url, now: Self.t0 + 4)).state
        #expect(abs(after.kindRecent - before.kindRecent) < 1e-9)
        #expect(abs(after.hostileRecent - before.hostileRecent) < 1e-9)
        #expect(abs(after.reoffense - before.reoffense) < 1e-9)
        #expect(abs(after.trustGainRecent - before.trustGainRecent) < 1e-9)
        #expect(abs((after.lastApologyAt?.timeIntervalSince1970 ?? 0) - (before.lastApologyAt?.timeIntervalSince1970 ?? 1)) < 1e-3)
    }

    // MARK: - Time model (B1, E)

    @Test func longTickGapIsModelledAsAbsence() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        // The app was suspended for 6 h; on resume it reports the user as present.
        let snap = await mind.tick(at: Self.t0 + 6 * 3600, userPresent: true, asleep: false)
        #expect(snap.code.feelings[.loneliness] > 0.2, "missed the user while away")
        #expect(snap.code.feelings[.boredom] < 0.2, "not bored by an empty room")
        #expect(snap.code.feelings[.energy] >= 0.79, "rested")
    }

    @Test func catchUpHonoursLastSeenUser() {
        let s = InnerState(updatedAt: Self.t0)
        let end = Self.t0 + 8 * 3600
        let unknown = EmotionEngine.catchUp(s, to: end)
        let seenLate = EmotionEngine.catchUp(s, to: end, lastSeenUserAt: end - 600)
        #expect(seenLate.feelings[.loneliness] < unknown.feelings[.loneliness])
        #expect(EmotionEngine.catchUp(s, to: Self.t0 - 10) == s)
    }

    @Test func restingSlowsButDoesNotStopLoneliness() {
        let s = InnerState(updatedAt: Self.t0)
        let awake = EmotionEngine.advance(s, to: Self.t0 + 4 * 3600, circumstances: .init(userPresent: false, asleep: false))
        let resting = EmotionEngine.advance(s, to: Self.t0 + 4 * 3600, circumstances: .init(userPresent: false, asleep: true))
        #expect(resting.feelings[.loneliness] > 0.05)
        #expect(resting.feelings[.loneliness] < awake.feelings[.loneliness])
        #expect(resting.feelings[.energy] > awake.feelings[.energy])
    }

    @Test func applyAfterLongGapAdvancesAsAbsentAndGivesReunionJoy() {
        var s = InnerState(updatedAt: Self.t0)
        s.feelings[.affection] = 0.7
        s.feelings[.energy] = 0.2
        let gap = Self.t0 + 72 * 3600
        let back = EmotionEngine.apply(Self.kind(), to: s, at: gap)
        #expect(back.feelings[.energy] > 0.6, "slept while away (\(back.feelings[.energy]))")
        #expect(back.feelings[.boredom] < 0.3)

        // Same greeting with no loneliness behind it: less joy.
        var notLonely = EmotionEngine.catchUp(s, to: gap)
        notLonely.feelings[.loneliness] = 0
        let plain = EmotionEngine.apply(Self.kind(), to: notLonely, at: gap)
        #expect(back.feelings[.joy] > plain.feelings[.joy] + 0.03, "reunion joy (\(back.feelings[.joy]) vs \(plain.feelings[.joy]))")

        // A short gap is still treated as present silence.
        let short = EmotionEngine.apply(Appraisal(), to: s, at: Self.t0 + 120)
        #expect(short.feelings[.loneliness] == 0)
    }

    // MARK: - Engine guards

    @Test func trustGainIsCappedPerDay() {
        var s = InnerState(updatedAt: Self.t0)
        let t0 = s.feelings[.trust]
        for i in 1...200 { s = EmotionEngine.apply(Self.kind(), to: s, at: Self.t0 + Double(i) * 30) }
        let elapsedDays = 200 * 30 / 86_400.0   // the budget leaks back at the same daily rate
        #expect(s.feelings[.trust] - t0 <= EmotionEngine.trustGainPerDay * (1 + elapsedDays) + 1e-6)
        // Next day there's room again.
        let tomorrow = EmotionEngine.apply(Self.kind(), to: s, at: Self.t0 + 200 * 30 + 86_400)
        #expect(tomorrow.feelings[.trust] > EmotionEngine.catchUp(s, to: Self.t0 + 200 * 30 + 86_400).feelings[.trust])
    }

    @Test func kindnessHabituatesAndSaturates() {
        let s = InnerState(updatedAt: Self.t0)
        let first = EmotionEngine.apply(Self.kind(), to: s, at: Self.t0 + 1)
        let firstGain = first.feelings[.affection] - s.feelings[.affection]
        var many = first
        for i in 2...20 { many = EmotionEngine.apply(Self.kind(), to: many, at: Self.t0 + Double(i)) }
        let next = EmotionEngine.apply(Self.kind(), to: many, at: Self.t0 + 21)
        #expect(next.feelings[.affection] - many.feelings[.affection] < firstGain * 0.3, "the 21st compliment in a row counts for less")

        var adored = InnerState(updatedAt: Self.t0)
        adored.feelings[.affection] = 0.97
        let more = EmotionEngine.apply(Self.kind(), to: adored, at: Self.t0 + 1)
        #expect(more.feelings[.affection] - 0.97 < firstGain * 0.3, "near the top there's little room left")
    }

    @Test func badIsStrongerThanGoodForTheBond() {
        let s = InnerState(updatedAt: Self.t0)
        var insult = Appraisal()
        insult.hostility = 0.6; insult.valence = -0.6
        var compliment = Appraisal()
        compliment.praise = 0.6; compliment.warmth = 0.3; compliment.valence = 0.6
        let hurt = EmotionEngine.apply(insult, to: s, at: Self.t0 + 1)
        let helped = EmotionEngine.apply(compliment, to: s, at: Self.t0 + 1)
        let lost = (s.feelings[.affection] - hurt.feelings[.affection]) + (s.feelings[.trust] - hurt.feelings[.trust])
        let won = (helped.feelings[.affection] - s.feelings[.affection]) + (helped.feelings[.trust] - s.feelings[.trust])
        #expect(lost > won, "an insult costs more than an equally strong compliment earns (\(lost) vs \(won))")
    }

    @Test func driftDeadbandAndTimeRelaxation() {
        var lukewarm = Appraisal()
        lukewarm.valence = 0.2   // kindness 0.06: inside the deadband
        lukewarm.novelty = 0.5
        let p = EmotionEngine.drift(Personality(), toward: lukewarm, age: nil)
        #expect(p[.agreeableness] == Trait.agreeableness.setPoint)
        #expect(p[.neuroticism] == Trait.neuroticism.setPoint)

        var s = InnerState(updatedAt: Self.t0)
        s.personality[.neuroticism] = 0.6
        let month = EmotionEngine.advance(s, to: Self.t0 + 30 * 86_400, circumstances: .init(userPresent: false, asleep: true))
        let gap = 0.6 - Trait.neuroticism.setPoint
        #expect(abs((month.personality[.neuroticism] - Trait.neuroticism.setPoint) - gap / 2) < 0.01, "half the gap closes in 30 days")
    }

    @Test func reoffenceWeakensApologies() {
        var s = InnerState(updatedAt: Self.t0)
        var insult = Appraisal()
        insult.hostility = 0.7; insult.valence = -0.7
        var apology = Appraisal()
        apology.apology = 0.8
        s = EmotionEngine.apply(apology, to: s, at: Self.t0 + 1)
        #expect(s.reoffense == 0)
        s = EmotionEngine.apply(insult, to: s, at: Self.t0 + 2)
        #expect(s.reoffense == 1, "hostility right after an apology")
        let later = EmotionEngine.advance(s, to: Self.t0 + 2 + 86_400, circumstances: .init(userPresent: false, asleep: true))
        #expect(abs(later.reoffense - 0.5) < 1e-6, "24 h half-life")
        // Insults with no recent apology aren't re-offences.
        var fresh = InnerState(updatedAt: Self.t0)
        fresh = EmotionEngine.apply(insult, to: fresh, at: Self.t0 + 1)
        #expect(fresh.reoffense == 0)
    }
}
