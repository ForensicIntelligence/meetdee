import DeeCore
import DeeMemory
import DeeMind
import Foundation

extension Signature.Slot: CodingKeyRepresentable {}
extension Value: CodingKeyRepresentable {}

/// SELF.md §10 — persistence for the self-model.
///
/// The tables live in the DeeMemory database file (`MemoryStore.defaultURL()`), on a
/// connection of their own (WAL, foreign keys, secure_delete, 2 s busy timeout). The
/// schema version (`self_meta.schema_version`) is independent of DeeMemory's; a newer
/// schema is refused and left untouched, and upgrades run step by step.
///
/// Person-scoped rows carry a plain `person_id` (schema v2). They deliberately do
/// **not** cascade from DeeMemory's `people(id)`: DeeMemory deletes a person row when it
/// merges a placeholder into a named person, which would silently wipe the self rows
/// (boundaries, lessons, profile…). The app keeps the two in step instead:
/// `merge(from:into:)` on `MemoryStore.merge`, `forgetPerson(_:)` on
/// `MemoryStore.forgetPerson` / `discardPlaceholder`, `forgetAll()` on
/// `forgetEverything()`, and `forgetPeople(notIn:)` at launch as a sweep.
///
/// Never stored: Momentary, hypotheses, topic, utterances, partials, replies, spoken
/// sentences. Stored strings come only from labels, subjects (≤ 4 words), person ids,
/// and template output, with length CHECKs.
public actor SelfStore {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case newerSchema(found: Int, supported: Int)
        public var description: String {
            switch self {
            case let .newerSchema(found, supported): "Self database schema \(found) is newer than supported \(supported)"
            }
        }
    }

    /// One write `apply` could not perform (a CHECK violation, a bug). Never silent.
    public struct FailedWrite: Sendable, Equatable {
        /// Index in the batch.
        public var index: Int
        /// `SelfWrite.name`.
        public var write: String
        public var reason: String
    }

    public struct ApplyResult: Sendable, Equatable {
        public var applied: Int
        public var failed: [FailedWrite]
    }

    /// What `forget(subject:)` removed; pass `episodes` to `Cortex.forget(episodes:)`.
    public struct Forgotten: Sendable, Equatable {
        public var rows: Int
        public var episodes: [UUID]
    }

    /// v1: the §10.2 schema (person rows cascading from `people`). v2: plain `person_id`.
    public static let schemaVersion = 2

    let db: SelfDatabase
    public let url: URL?
    /// In DEBUG builds a failed write in `apply` trips an assertion (tests that write
    /// invalid rows on purpose turn it off).
    public let assertOnFailedWrites: Bool

    /// Opens (or creates) the self tables in the database at `url`; nil keeps
    /// everything in memory (tests).
    public init(url: URL?, assertOnFailedWrites: Bool = true) throws {
        self.url = url
        self.assertOnFailedWrites = assertOnFailedWrites
        if let url {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        db = try SelfDatabase(path: url?.path(percentEncoded: false) ?? ":memory:")
        try Self.migrate(db)
    }

    /// The DeeMemory database file (the app opens `MemoryStore` first).
    public static func open(at url: URL = MemoryStore.defaultURL()) throws -> SelfStore {
        try SelfStore(url: url)
    }

    // MARK: - Schema

    static let personTables = ["episode", "expectation", "intention", "lesson", "misread", "social_profile",
                               "boundary", "gag", "ritual", "open_repair", "digest"]

    /// DDL for one table (v2: plain `person_id`, no foreign key).
    static func ddl(_ table: String, name: String? = nil) -> String {
        let t = name ?? table
        switch table {
        case "episode": return """
            CREATE TABLE \(t) (
              id TEXT PRIMARY KEY, person_id TEXT,
              start REAL, end REAL, kind TEXT, topics TEXT,
              gist TEXT NOT NULL CHECK(length(gist) <= 100), why TEXT CHECK(why IS NULL OR length(why) <= 60),
              expected TEXT CHECK(expected IS NULL OR length(expected) <= 60), changed TEXT CHECK(changed IS NULL OR length(changed) <= 60),
              valence REAL, salience REAL, surprise REAL, mind_before BLOB, mind_after BLOB,
              recalled INTEGER DEFAULT 0, last_recalled REAL, open_loop TEXT);
            """
        case "expectation": return """
            CREATE TABLE \(t) (
              id TEXT PRIMARY KEY, person_id TEXT NOT NULL,
              subject TEXT NOT NULL CHECK(length(subject) <= 40), due REAL, expires REAL, framing TEXT, status TEXT,
              outcome REAL, episode_id TEXT);
            """
        case "intention": return """
            CREATE TABLE \(t) (
              id TEXT PRIMARY KEY, kind TEXT, subject TEXT CHECK(length(subject) <= 40), person_id TEXT,
              reason TEXT CHECK(length(reason) <= 60), not_before REAL, expires REAL, priority REAL, status TEXT, issued_count INTEGER,
              steps_done INTEGER, steps_needed INTEGER, source TEXT, created REAL, updated REAL);
            """
        case "lesson": return """
            CREATE TABLE \(t) (
              id TEXT PRIMARY KEY, person_id TEXT,
              situation TEXT NOT NULL, do_instead TEXT NOT NULL CHECK(length(do_instead) <= 76), evidence INTEGER, last_applied REAL, created REAL,
              UNIQUE(person_id, situation));
            """
        case "misread": return """
            CREATE TABLE \(t) (
              id TEXT PRIMARY KEY, person_id TEXT,
              at REAL, situation TEXT, topic TEXT CHECK(topic IS NULL OR length(topic) <= 40));
            """
        case "social_profile": return """
            CREATE TABLE \(t) (
              person_id TEXT PRIMARY KEY,
              pause_scale REAL DEFAULT 1.0, pause_n INTEGER DEFAULT 0, backchannel_rate REAL DEFAULT 1.0,
              humor_receptiveness REAL DEFAULT 0.5, mood_inference_gain REAL DEFAULT 1.0,
              silence_comfort REAL DEFAULT 0.3, kindness_ema REAL DEFAULT 0, updated_at REAL);
            """
        case "boundary": return """
            CREATE TABLE \(t) (
              id TEXT PRIMARY KEY, person_id TEXT NOT NULL,
              topic TEXT NOT NULL CHECK(length(topic) <= 40), owner TEXT CHECK(owner IN ('user','dee')), created_at REAL, active INTEGER);
            """
        case "gag": return """
            CREATE TABLE \(t) (
              id TEXT PRIMARY KEY, person_id TEXT, topic TEXT CHECK(length(topic) <= 40),
              hook_template INTEGER, uses INTEGER, laughs INTEGER, flat_streak INTEGER, last_used REAL, retired INTEGER);
            """
        case "ritual": return """
            CREATE TABLE \(t) (
              id TEXT PRIMARY KEY, person_id TEXT,
              trigger TEXT, variant INTEGER, mannerism TEXT, count INTEGER, streak INTEGER, last_done REAL);
            """
        case "open_repair": return """
            CREATE TABLE \(t) (person_id TEXT PRIMARY KEY, phase TEXT, together_seconds_left REAL);
            """
        case "digest": return """
            CREATE TABLE \(t) (day TEXT NOT NULL, person_id TEXT, conversations INTEGER, low_salience INTEGER);
            """
        default: preconditionFailure("unknown table \(table)")
        }
    }

    static let indexes = """
        CREATE INDEX IF NOT EXISTS episode_person_end ON episode(person_id, end DESC);
        CREATE UNIQUE INDEX IF NOT EXISTS digest_key ON digest(day, ifnull(person_id, ''));
        """

    /// Creates or upgrades the schema, step by step, each step idempotent.
    static func migrate(_ db: SelfDatabase) throws {
        try db.execute("CREATE TABLE IF NOT EXISTS self_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        let stored = try db.query("SELECT value FROM self_meta WHERE key = 'schema_version'").first?["value"]?.string.flatMap(Int.init) ?? 0
        if stored > schemaVersion { throw Failure.newerSchema(found: stored, supported: schemaVersion) }
        guard stored < schemaVersion else { return }
        try db.transaction {
            if stored < 1 {
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS facet (
                      id TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK(kind IN ('taste','strength','limit')),
                      subject TEXT NOT NULL CHECK(length(subject) <= 40),
                      innate REAL, learned REAL, polarity REAL, evidence INTEGER, contrary INTEGER,
                      crystallised INTEGER, revealed_at REAL, reason TEXT CHECK(reason IS NULL OR length(reason) <= 60),
                      source TEXT, updated_at REAL, UNIQUE(kind, subject));
                    CREATE TABLE IF NOT EXISTS interest (subject TEXT PRIMARY KEY CHECK(length(subject) <= 40), weight REAL, last REAL);
                    """)
                for t in personTables where try !db.tableExists(t) { try db.execute(ddl(t)) }
            } else {
                // v1 → v2: rebuild the person tables without `REFERENCES people(id) ON
                // DELETE CASCADE` (DeeMemory merges delete people rows). Rows are kept.
                for t in personTables {
                    try db.execute("DROP TABLE IF EXISTS \(t)_v2;")
                    try db.execute(ddl(t, name: "\(t)_v2"))
                    try db.execute("INSERT INTO \(t)_v2 SELECT * FROM \(t); DROP TABLE \(t); ALTER TABLE \(t)_v2 RENAME TO \(t);")
                }
            }
            try db.execute(indexes)
            try db.query("DELETE FROM self_meta WHERE key = 'people_fk'")
            try db.query("INSERT OR REPLACE INTO self_meta(key, value) VALUES('schema_version', ?)", [.text(String(schemaVersion))])
        }
    }

    // MARK: - Meta

    public func meta(_ key: String) throws -> String? {
        try db.query("SELECT value FROM self_meta WHERE key = ?", [.text(key)]).first?["value"]?.string
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try db.query("INSERT OR REPLACE INTO self_meta(key, value) VALUES(?, ?)", [.text(key), .text(value)])
    }

    public func storedSchemaVersion() throws -> Int { try meta("schema_version").flatMap(Int.init) ?? 0 }

    // MARK: - Enduring

    /// Loads the enduring self, seeding it on first use (`SelfSeeder`, with `seed`;
    /// pass a random value the first time). Seeding is written once and never redone:
    /// once a seed is stored, `newSeed` is never used again. If a stored piece (values,
    /// humour, signature) no longer decodes, only that piece is re-derived from the
    /// **stored** seed and rewritten; facets and everything learnt are untouched.
    ///
    /// `preset` (a persona preset, first use only): the self is seeded from the preset
    /// instead (`SelfSeeder.seed(preset:)`: its fixed seed, humour pins and tastes).
    public func loadEnduring(personality: Personality, seed newSeed: UInt64, at now: Date,
                             preset: PersonaPreset? = nil) throws -> Enduring {
        let dec = JSONDecoder()
        if let seedText = try meta("seed"), let seed = UInt64(seedText) {
            var reseeded: Enduring?
            func derived() -> Enduring {
                if let r = reseeded { return r }
                let r = SelfSeeder.seed(personality: personality, seed: seed, at: now)
                reseeded = r
                return r
            }
            let enc = JSONEncoder()
            enc.outputFormatting = .sortedKeys
            var values = try meta("values").flatMap { try? dec.decode([Value: Double].self, from: Data($0.utf8)) }
            if values == nil {
                values = derived().values
                try setMeta("values", String(decoding: try enc.encode(values), as: UTF8.self))
            }
            var humour = try meta("humour").flatMap(HumourStyle.init(rawValue:))
            if humour == nil {
                humour = derived().humour
                try setMeta("humour", derived().humour.rawValue)
            }
            var humour2 = try meta("humour2").flatMap(HumourStyle.init(rawValue:))
            if humour2 == nil {
                humour2 = derived().humourSecondary
                try setMeta("humour2", derived().humourSecondary.rawValue)
            }
            var signature = try meta("signature").flatMap { try? dec.decode(Signature.self, from: Data($0.utf8)) }
            if signature == nil {
                signature = derived().signature
                try setMeta("signature", String(decoding: try enc.encode(derived().signature), as: UTF8.self))
            }
            var e = Enduring(seed: seed, values: values!, humour: humour!, humourSecondary: humour2!, signature: signature!)
            e.facets = try facets()
            e.lessons = try lessons()
            e.profiles = try profiles()
            e.boundaries = try boundaries()
            e.gags = try gags()
            e.rituals = try rituals()
            e.episodeIndex = try episodeIndex(limit: Enduring.maxEpisodeIndex)
            return e
        }
        if let preset, !preset.isClassic {
            let e = SelfSeeder.seed(preset: preset, fallbackSeed: newSeed, at: now)
            try saveSeeded(e)
            try setMeta("persona", preset.id)
            return e
        }
        let e = SelfSeeder.seed(personality: personality, seed: newSeed, at: now)
        try saveSeeded(e)
        return e
    }

    /// A persona switch (persona spec §11.3/§11.8): the seeded self (seed, values, humour,
    /// signature and the seeded tastes) is replaced by the preset's; capability facets,
    /// learned tastes, episodes, profiles, lessons, boundaries, gags and rituals are kept,
    /// because they belong to the user, not the character. Returns the new enduring self.
    @discardableResult
    public func reseed(for preset: PersonaPreset, fallbackSeed: UInt64, at now: Date) throws -> Enduring {
        let e = SelfSeeder.seed(preset: preset, fallbackSeed: fallbackSeed, at: now)
        guard try meta("seed") != nil else {
            // Never seeded (a fresh install): the whole seeded self, capabilities included.
            try saveSeeded(e)
            try setMeta("persona", preset.id)
            return try loadEnduring(personality: preset.storedTraits(), seed: e.seed, at: now)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        try db.transaction {
            try db.query("DELETE FROM facet WHERE kind = 'taste' AND source = 'seed'")
            try setMeta("seed", String(e.seed))
            try setMeta("values", String(decoding: try enc.encode(e.values), as: UTF8.self))
            try setMeta("humour", e.humour.rawValue)
            try setMeta("humour2", e.humourSecondary.rawValue)
            try setMeta("signature", String(decoding: try enc.encode(e.signature), as: UTF8.self))
            try setMeta("persona", preset.id)
            for f in e.facets where f.kind == .taste { try write(.facet(f)) }
        }
        return try loadEnduring(personality: preset.storedTraits(), seed: e.seed, at: now)
    }

    /// The persona the seeded self belongs to (nil: seeded before the presets = Classic).
    public func seededPersona() throws -> String? { try meta("persona") }

    func saveSeeded(_ e: Enduring) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        try db.transaction {
            try setMeta("seed", String(e.seed))
            try setMeta("values", String(decoding: try enc.encode(e.values), as: UTF8.self))
            try setMeta("humour", e.humour.rawValue)
            try setMeta("humour2", e.humourSecondary.rawValue)
            try setMeta("signature", String(decoding: try enc.encode(e.signature), as: UTF8.self))
            for f in e.facets { try write(.facet(f)) }
        }
    }

    /// Persisted ongoing state for a new Cortex: live intentions, pending expectations,
    /// interests, open ruptures, and misreads of the 14 days before `now` (all when nil).
    public func loadCarried(at now: Date? = nil) throws -> Carried {
        let since = now.map { $0.addingTimeInterval(-Self.misreadWindow) } ?? .distantPast
        return Carried(intentions: try intentions(live: true), expectations: try expectations(pending: true),
                       interests: try interests(), openRepair: try openRepairs(),
                       misreads: try misreads().filter { $0.at >= since }, lastContact: try lastContact())
    }

    /// The last stored contact per person: the latest of their episode ends, ritual
    /// performances and conversation digests (a digest day counts as its last second,
    /// so an absence is never overstated).
    public func lastContact() throws -> [PersonID: Date] {
        var out: [PersonID: Date] = [:]
        func note(_ id: PersonID?, _ d: Date?) {
            guard let id, let d else { return }
            out[id] = max(out[id] ?? d, d)
        }
        for r in try db.query("SELECT person_id, MAX(end) AS t FROM episode WHERE person_id IS NOT NULL GROUP BY person_id") {
            note(Self.uuid(r["person_id"]), Self.date(r["t"]))
        }
        for r in try db.query("SELECT person_id, MAX(last_done) AS t FROM ritual WHERE person_id IS NOT NULL GROUP BY person_id") {
            note(Self.uuid(r["person_id"]), Self.date(r["t"]))
        }
        for r in try db.query("SELECT person_id, MAX(day) AS d FROM digest WHERE person_id IS NOT NULL AND conversations > 0 GROUP BY person_id") {
            note(Self.uuid(r["person_id"]), r["d"]?.string.flatMap(Self.endOfDay))
        }
        return out
    }

    /// `yyyy-MM-dd` (a local day, as `EpisodeBuilder.day` writes it) → its last second
    /// anywhere on Earth (UTC end of day + 12 h), so an absence is never overstated.
    static func endOfDay(_ day: String) -> Date? {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (p[0], p[1], p[2], 23, 59, 59)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal.date(from: c)?.addingTimeInterval(12 * 3600)
    }

    /// Lesson minting looks back this far (§7.7).
    public static let misreadWindow: TimeInterval = 14 * 86_400

    /// Increments and returns the launch counter (mixed into Cortex's random streams so
    /// each launch differs; pass it to `Cortex.init(session:)`).
    public func nextSession() throws -> UInt64 {
        let n = (try meta("session").flatMap(UInt64.init) ?? 0) &+ 1
        try setMeta("session", String(n))
        return n
    }

    // MARK: - Writes

    /// Applies a batch in one transaction. A write that fails on its own (a CHECK
    /// violation, a bug) is rolled back alone and reported in `failed` — and trips an
    /// assertion in DEBUG unless `assertOnFailedWrites` is off — without aborting the rest.
    @discardableResult
    public func apply(_ writes: [SelfWrite]) throws -> ApplyResult {
        let result = try db.transaction {
            var r = ApplyResult(applied: 0, failed: [])
            for (i, w) in writes.enumerated() {
                do {
                    try db.transaction { try write(w) }
                    r.applied += 1
                } catch {
                    r.failed.append(FailedWrite(index: i, write: w.name, reason: String(describing: error)))
                }
            }
            return r
        }
        if assertOnFailedWrites, let f = result.failed.first {
            assertionFailure("SelfStore.apply: \(result.failed.count) write(s) failed, first \(f.write): \(f.reason)")
        }
        return result
    }

    @discardableResult
    public func apply(_ write: SelfWrite) throws -> ApplyResult { try apply([write]) }

    func write(_ w: SelfWrite) throws {
        switch w {
        case .episode(let e):
            try db.query("""
                INSERT OR REPLACE INTO episode(id, person_id, start, end, kind, topics, gist, why, expected, changed,
                  valence, salience, surprise, mind_before, mind_after, recalled, last_recalled, open_loop)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(e.id.uuidString), Self.id(e.person), .real(e.start.timeIntervalSince1970), .real(e.end.timeIntervalSince1970),
                      .text(e.kind.rawValue), .text(Self.json(e.topics.map(\.text))), .text(e.gist), Self.text(e.why), Self.text(e.expected),
                      Self.text(e.changed), .real(e.valence), .real(e.salience), .real(e.surprise), .blob(Data(e.mindBefore.bytes)),
                      .blob(Data(e.mindAfter.bytes)), .int(Int64(e.recalled)), Self.date(e.lastRecalled), Self.id(e.openLoop)])
        case .deleteEpisode(let id):
            try db.query("DELETE FROM episode WHERE id = ?", [.text(id.uuidString)])
        case .recalled(let id, let at):
            try db.query("UPDATE episode SET recalled = recalled + 1, last_recalled = ? WHERE id = ?",
                         [.real(at.timeIntervalSince1970), .text(id.uuidString)])
        case .intention(let i):
            try db.query("""
                INSERT OR REPLACE INTO intention(id, kind, subject, person_id, reason, not_before, expires, priority, status,
                  issued_count, steps_done, steps_needed, source, created, updated) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(i.id.uuidString), .text(i.kind.rawValue), .text(i.subject.text), Self.id(i.person), .text(i.reason),
                      .real(i.notBefore.timeIntervalSince1970), .real(i.expires.timeIntervalSince1970), .real(i.priority),
                      .text(i.status.rawValue), .int(Int64(i.issuedCount)), .int(Int64(i.stepsDone)), .int(Int64(i.stepsNeeded)),
                      .text(i.source), .real(i.created.timeIntervalSince1970), .real(i.updated.timeIntervalSince1970)])
        case .expectation(let x):
            try db.query("""
                INSERT OR REPLACE INTO expectation(id, person_id, subject, due, expires, framing, status, outcome, episode_id)
                VALUES(?,?,?,?,?,?,?,?,?)
                """, [.text(x.id.uuidString), .text(x.person.uuidString), .text(x.subject.text), .real(x.due.timeIntervalSince1970),
                      .real(x.expires.timeIntervalSince1970), .text(x.framing.rawValue), .text(x.status.rawValue),
                      x.outcomeValence.map { .real($0) } ?? .null, Self.id(x.episode)])
        case .interest(let i):
            try db.query("INSERT OR REPLACE INTO interest(subject, weight, last) VALUES(?,?,?)",
                         [.text(i.subject.text), .real(i.weight), .real(i.lastTouched.timeIntervalSince1970)])
        case .facet(let f):
            try db.query("DELETE FROM facet WHERE kind = ? AND subject = ? AND id != ?", [.text(f.kind.rawValue), .text(f.subject.text), .text(f.id.uuidString)])
            try db.query("""
                INSERT OR REPLACE INTO facet(id, kind, subject, innate, learned, polarity, evidence, contrary, crystallised,
                  revealed_at, reason, source, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [.text(f.id.uuidString), .text(f.kind.rawValue), .text(f.subject.text), .real(f.innate), .real(f.learned),
                      .real(f.polarity), .int(Int64(f.evidence)), .int(Int64(f.contrary)), .int(f.crystallised ? 1 : 0),
                      Self.date(f.revealedAt), Self.text(f.reason), .text(f.source.rawValue), .real(f.updatedAt.timeIntervalSince1970)])
        case .lesson(let l):
            try db.query("DELETE FROM lesson WHERE person_id IS ? AND situation = ? AND id != ?", [Self.id(l.person), .text(l.situation.rawValue), .text(l.id.uuidString)])
            try db.query("""
                INSERT OR REPLACE INTO lesson(id, person_id, situation, do_instead, evidence, last_applied, created)
                VALUES(?,?,?,?,?,?,?)
                """, [.text(l.id.uuidString), Self.id(l.person), .text(l.situation.rawValue), .text(l.doInstead),
                      .int(Int64(l.evidence)), Self.date(l.lastApplied), .real(l.createdAt.timeIntervalSince1970)])
        case .deleteLesson(let id):
            try db.query("DELETE FROM lesson WHERE id = ?", [.text(id.uuidString)])
        case .misread(let r):
            try db.query("INSERT OR REPLACE INTO misread(id, person_id, at, situation, topic) VALUES(?,?,?,?,?)",
                         [.text(r.id.uuidString), Self.id(r.person), .real(r.at.timeIntervalSince1970), .text(r.situation.rawValue),
                          Self.text(r.topic?.text)])
        case .profile(let person, let p):
            try db.query("""
                INSERT OR REPLACE INTO social_profile(person_id, pause_scale, pause_n, backchannel_rate, humor_receptiveness,
                  mood_inference_gain, silence_comfort, kindness_ema, updated_at) VALUES(?,?,?,?,?,?,?,?,?)
                """, [.text(person.uuidString), .real(p.pauseScale), .int(Int64(p.pauseN)), .real(p.backchannelRate),
                      .real(p.humorReceptiveness), .real(p.moodInferenceGain), .real(p.silenceComfort), .real(p.kindnessEMA), .null])
        case .boundary(let b):
            try db.query("INSERT OR REPLACE INTO boundary(id, person_id, topic, owner, created_at, active) VALUES(?,?,?,?,?,?)",
                         [.text(b.id.uuidString), .text(b.person.uuidString), .text(b.topic.text), .text(b.owner.rawValue),
                          .real(b.createdAt.timeIntervalSince1970), .int(b.active ? 1 : 0)])
        case .gag(let g):
            try db.query("""
                INSERT OR REPLACE INTO gag(id, person_id, topic, hook_template, uses, laughs, flat_streak, last_used, retired)
                VALUES(?,?,?,?,?,?,?,?,?)
                """, [.text(g.id.uuidString), Self.id(g.person), .text(g.topic.text), .int(Int64(g.hookTemplate)), .int(Int64(g.uses)),
                      .int(Int64(g.laughs)), .int(Int64(g.flatStreak)), Self.date(g.lastUsed), .int(g.retired ? 1 : 0)])
        case .ritual(let r):
            try db.query("""
                INSERT OR REPLACE INTO ritual(id, person_id, trigger, variant, mannerism, count, streak, last_done)
                VALUES(?,?,?,?,?,?,?,?)
                """, [.text(r.id.uuidString), Self.id(r.person), .text(r.trigger.rawValue), .int(Int64(r.variant)),
                      .text(r.mannerism.rawValue), .int(Int64(r.count)), .int(Int64(r.streak)), Self.date(r.lastDone)])
        case .openRepair(let person, let phase, let left):
            try db.query("INSERT OR REPLACE INTO open_repair(person_id, phase, together_seconds_left) VALUES(?,?,?)",
                         [.text(person.uuidString), .text(phase.rawValue), .real(left)])
        case .clearOpenRepair(let person):
            try db.query("DELETE FROM open_repair WHERE person_id = ?", [.text(person.uuidString)])
        case .digest(let day, let person, let conversations, let low):
            let key: [SelfDatabase.Value] = [.text(day), Self.id(person)]
            if try db.query("SELECT 1 FROM digest WHERE day = ? AND person_id IS ?", key).isEmpty {
                try db.query("INSERT INTO digest(day, person_id, conversations, low_salience) VALUES(?,?,?,?)",
                             key + [.int(Int64(conversations)), .int(Int64(low))])
            } else {
                try db.query("UPDATE digest SET conversations = conversations + ?, low_salience = low_salience + ? WHERE day = ? AND person_id IS ?",
                             [.int(Int64(conversations)), .int(Int64(low))] + key)
            }
        }
    }

    // MARK: - Reads

    public func facets() throws -> [Facet] {
        try db.query("SELECT * FROM facet ORDER BY kind, subject").compactMap { r in
            guard let id = Self.uuid(r["id"]), let kind = r["kind"]?.string.flatMap(Facet.Kind.init(rawValue:)),
                  let subject = r["subject"]?.string.flatMap(Subject.init) else { return nil }
            return Facet(id: id, kind: kind, subject: subject, innate: r["innate"]?.double ?? 0, learned: r["learned"]?.double ?? 0,
                         polarity: r["polarity"]?.double, evidence: r["evidence"]?.int ?? 0, contrary: r["contrary"]?.int ?? 0,
                         crystallised: (r["crystallised"]?.int ?? 0) != 0, revealedAt: Self.date(r["revealed_at"]),
                         reason: r["reason"]?.string, source: r["source"]?.string.flatMap(Facet.Source.init(rawValue:)) ?? .heuristic,
                         updatedAt: Self.date(r["updated_at"]) ?? .distantPast)
        }
    }

    public func lessons() throws -> [Lesson] {
        try db.query("SELECT * FROM lesson ORDER BY created, id").compactMap { r in
            guard let id = Self.uuid(r["id"]), let s = r["situation"]?.string.flatMap(Lesson.Situation.init(rawValue:)) else { return nil }
            return Lesson(id: id, person: Self.uuid(r["person_id"]), situation: s, doInstead: r["do_instead"]?.string,
                          evidence: r["evidence"]?.int ?? 0, lastApplied: Self.date(r["last_applied"]),
                          createdAt: Self.date(r["created"]) ?? .distantPast)
        }
    }

    public func misreads() throws -> [Misread] {
        try db.query("SELECT * FROM misread ORDER BY at, id").compactMap { r in
            guard let id = Self.uuid(r["id"]), let s = r["situation"]?.string.flatMap(Lesson.Situation.init(rawValue:)) else { return nil }
            return Misread(id: id, person: Self.uuid(r["person_id"]), at: Self.date(r["at"]) ?? .distantPast, situation: s,
                           topic: r["topic"]?.string.flatMap(Subject.init))
        }
    }

    public func profiles() throws -> [PersonID: SocialProfile] {
        var out: [PersonID: SocialProfile] = [:]
        for r in try db.query("SELECT * FROM social_profile") {
            guard let id = Self.uuid(r["person_id"]) else { continue }
            var p = SocialProfile()
            p.pauseScale = r["pause_scale"]?.double ?? p.pauseScale
            p.pauseN = r["pause_n"]?.int ?? p.pauseN
            p.backchannelRate = r["backchannel_rate"]?.double ?? p.backchannelRate
            p.humorReceptiveness = r["humor_receptiveness"]?.double ?? p.humorReceptiveness
            p.moodInferenceGain = r["mood_inference_gain"]?.double ?? p.moodInferenceGain
            p.silenceComfort = r["silence_comfort"]?.double ?? p.silenceComfort
            p.kindnessEMA = r["kindness_ema"]?.double ?? p.kindnessEMA
            out[id] = p
        }
        return out
    }

    public func boundaries() throws -> [Boundary] {
        try db.query("SELECT * FROM boundary ORDER BY created_at, id").compactMap { r in
            guard let id = Self.uuid(r["id"]), let person = Self.uuid(r["person_id"]),
                  let topic = r["topic"]?.string.flatMap(Subject.init),
                  let owner = r["owner"]?.string.flatMap(Boundary.Owner.init(rawValue:)) else { return nil }
            return Boundary(id: id, person: person, topic: topic, owner: owner, createdAt: Self.date(r["created_at"]) ?? .distantPast,
                            active: (r["active"]?.int ?? 0) != 0)
        }
    }

    public func gags() throws -> [Gag] {
        try db.query("SELECT * FROM gag ORDER BY id").compactMap { r in
            guard let id = Self.uuid(r["id"]), let topic = r["topic"]?.string.flatMap(Subject.init) else { return nil }
            return Gag(id: id, person: Self.uuid(r["person_id"]), topic: topic, hookTemplate: r["hook_template"]?.int ?? 0,
                       uses: r["uses"]?.int ?? 0, laughs: r["laughs"]?.int ?? 0, flatStreak: r["flat_streak"]?.int ?? 0,
                       lastUsed: Self.date(r["last_used"]), retired: (r["retired"]?.int ?? 0) != 0)
        }
    }

    public func rituals() throws -> [Ritual] {
        try db.query("SELECT * FROM ritual ORDER BY id").compactMap { r in
            guard let id = Self.uuid(r["id"]), let trigger = r["trigger"]?.string.flatMap(Ritual.Trigger.init(rawValue:)),
                  let m = r["mannerism"]?.string.flatMap(Mannerism.init(rawValue:)) else { return nil }
            return Ritual(id: id, person: Self.uuid(r["person_id"]), trigger: trigger, variant: r["variant"]?.int ?? 0, mannerism: m,
                          count: r["count"]?.int ?? 0, streak: r["streak"]?.int ?? 0, lastDone: Self.date(r["last_done"]))
        }
    }

    public func intentions(live: Bool = false) throws -> [Intention] {
        let sql = live ? "SELECT * FROM intention WHERE status IN ('open','issued') ORDER BY created, id" : "SELECT * FROM intention ORDER BY created, id"
        return try db.query(sql).compactMap { r in
            guard let id = Self.uuid(r["id"]), let kind = r["kind"]?.string.flatMap(Intention.Kind.init(rawValue:)),
                  let subject = r["subject"]?.string.flatMap(Subject.init),
                  let status = r["status"]?.string.flatMap(Intention.Status.init(rawValue:)) else { return nil }
            let created = Self.date(r["created"]) ?? .distantPast
            return Intention(id: id, kind: kind, subject: subject, person: Self.uuid(r["person_id"]), reason: r["reason"]?.string ?? "",
                             notBefore: Self.date(r["not_before"]) ?? created, expires: Self.date(r["expires"]) ?? created,
                             priority: r["priority"]?.double ?? 0, status: status, issuedCount: r["issued_count"]?.int ?? 0,
                             stepsDone: r["steps_done"]?.int ?? 0, stepsNeeded: r["steps_needed"]?.int ?? 1,
                             source: r["source"]?.string ?? "", created: created, updated: Self.date(r["updated"]))
        }
    }

    public func expectations(pending: Bool = false) throws -> [Expectation] {
        let sql = pending ? "SELECT * FROM expectation WHERE status IN ('pending','asked') ORDER BY due, id" : "SELECT * FROM expectation ORDER BY due, id"
        return try db.query(sql).compactMap { r in
            guard let id = Self.uuid(r["id"]), let person = Self.uuid(r["person_id"]),
                  let subject = r["subject"]?.string.flatMap(Subject.init),
                  let framing = r["framing"]?.string.flatMap(Expectation.Framing.init(rawValue:)),
                  let status = r["status"]?.string.flatMap(Expectation.Status.init(rawValue:)),
                  let due = Self.date(r["due"]), let expires = Self.date(r["expires"]) else { return nil }
            return Expectation(id: id, person: person, subject: subject, due: due, expires: expires, framing: framing,
                               status: status, outcomeValence: r["outcome"]?.double, episode: Self.uuid(r["episode_id"]))
        }
    }

    public func interests() throws -> [Interest] {
        try db.query("SELECT * FROM interest ORDER BY weight DESC, subject").compactMap { r in
            guard let s = r["subject"]?.string.flatMap(Subject.init) else { return nil }
            return Interest(subject: s, weight: r["weight"]?.double ?? 0, lastTouched: Self.date(r["last"]) ?? .distantPast)
        }
    }

    public func openRepairs() throws -> [PersonID: RepairPhase] {
        var out: [PersonID: RepairPhase] = [:]
        for r in try db.query("SELECT person_id, phase FROM open_repair WHERE together_seconds_left > 0") {
            if let id = Self.uuid(r["person_id"]), let p = r["phase"]?.string.flatMap(RepairPhase.init(rawValue:)) { out[id] = p }
        }
        return out
    }

    public func episode(_ id: UUID) throws -> Episode? {
        try db.query("SELECT * FROM episode WHERE id = ?", [.text(id.uuidString)]).first.flatMap(Self.episode)
    }

    /// Bodies for a person (nil = global ones), newest first.
    public func episodes(person: PersonID?, limit: Int = 20) throws -> [Episode] {
        try db.query("SELECT * FROM episode WHERE person_id IS ? ORDER BY end DESC, id LIMIT ?", [Self.id(person), .int(Int64(limit))])
            .compactMap(Self.episode)
    }

    public func episodeIndex(limit: Int = Enduring.maxEpisodeIndex) throws -> [EpisodeKey] {
        try db.query("SELECT id, person_id, end, topics, salience, recalled FROM episode ORDER BY end DESC, id LIMIT ?", [.int(Int64(limit))])
            .compactMap { r in
                guard let id = Self.uuid(r["id"]) else { return nil }
                return EpisodeKey(id: id, person: Self.uuid(r["person_id"]), end: Self.date(r["end"]) ?? .distantPast,
                                  topics: Self.topics(r["topics"]), salience: r["salience"]?.double ?? 0, recalled: r["recalled"]?.int ?? 0)
            }
    }

    public func digest(day: String, person: PersonID?) throws -> (conversations: Int, lowSalience: Int)? {
        try db.query("SELECT conversations, low_salience FROM digest WHERE day = ? AND person_id IS ?", [.text(day), Self.id(person)]).first
            .map { ($0["conversations"]?.int ?? 0, $0["low_salience"]?.int ?? 0) }
    }

    static func episode(_ r: SelfDatabase.Row) -> Episode? {
        guard let id = Self.uuid(r["id"]), let kind = r["kind"]?.string.flatMap(Episode.Kind.init(rawValue:)),
              let gist = r["gist"]?.string, let before = code(r["mind_before"]), let after = code(r["mind_after"]) else { return nil }
        return Episode(id: id, person: uuid(r["person_id"]), start: date(r["start"]) ?? .distantPast, end: date(r["end"]) ?? .distantPast,
                       kind: kind, topics: topics(r["topics"]), gist: gist, why: r["why"]?.string, expected: r["expected"]?.string,
                       changed: r["changed"]?.string, valence: r["valence"]?.double ?? 0, salience: r["salience"]?.double ?? 0,
                       surprise: r["surprise"]?.double ?? 0, mindBefore: before, mindAfter: after, recalled: r["recalled"]?.int ?? 0,
                       lastRecalled: date(r["last_recalled"]), openLoop: uuid(r["open_loop"]))
    }

    // MARK: - Forget

    /// "Forget that" (call after `Cortex.forget(subject:)` and after applying any
    /// pending writes): episodes tagged with `subject` or whose gist / why / expected /
    /// changed name it, and expectations, intentions, misreads, interests and gags whose
    /// subject or topic overlaps it (whole words, either way: "interview" ~ "job
    /// interview"). Learnt taste facets about it go; boundaries and seeded facets stay. Then checkpoints the WAL.
    @discardableResult
    public func forget(subject: Subject) throws -> Forgotten {
        let result = try db.transaction {
            var gone = Forgotten(rows: 0, episodes: [])
            for r in try db.query("SELECT id, topics, gist, why, expected, changed FROM episode") {
                let texts = ["gist", "why", "expected", "changed"].compactMap { r[$0]?.string }
                guard Self.topics(r["topics"]).contains(where: { $0.overlaps(subject) }) || texts.contains(where: subject.appears(in:)),
                      let id = Self.uuid(r["id"]) else { continue }
                try db.query("DELETE FROM episode WHERE id = ?", [.text(id.uuidString)])
                gone.episodes.append(id)
            }
            gone.rows += gone.episodes.count
            // Learnt tastes about it go too (review finding 1); seeded facets stay.
            for r in try db.query("SELECT id, subject FROM facet WHERE source IS NOT 'seed'") {
                guard let s = r["subject"]?.string.flatMap(Subject.init), s.overlaps(subject), let k = r["id"] else { continue }
                try db.query("DELETE FROM facet WHERE id = ?", [k])
                gone.rows += 1
            }
            for (table, key, column) in [("expectation", "id", "subject"), ("intention", "id", "subject"), ("misread", "id", "topic"),
                                         ("interest", "subject", "subject"), ("gag", "id", "topic")] {
                for r in try db.query("SELECT \(key) AS k, \(column) AS s FROM \(table)") {
                    guard let s = r["s"]?.string.flatMap(Subject.init), s.overlaps(subject), let k = r["k"] else { continue }
                    try db.query("DELETE FROM \(table) WHERE \(key) = ?", [k])
                    gone.rows += 1
                }
            }
            return gone
        }
        try db.checkpoint()
        return result
    }

    /// Everything about one person (call with `MemoryStore.forgetPerson` /
    /// `discardPlaceholder`, after `Cortex.forgetPerson`). Returns rows removed.
    @discardableResult
    public func forgetPerson(_ id: PersonID) throws -> Int {
        let n = try db.transaction {
            var n = 0
            for t in Self.personTables {
                n += try db.query("SELECT 1 FROM \(t) WHERE person_id = ?", [.text(id.uuidString)]).count
                try db.query("DELETE FROM \(t) WHERE person_id = ?", [.text(id.uuidString)])
            }
            return n
        }
        try db.checkpoint()
        return n
    }

    /// Sweep: removes person rows whose person is not in `known` (DeeMemory's people),
    /// e.g. after a crash between a DeeMemory delete and `forgetPerson`. Global rows
    /// (NULL person) stay. Returns rows removed.
    @discardableResult
    public func forgetPeople(notIn known: [PersonID]) throws -> Int {
        let keep = Set(known.map(\.uuidString))
        let n = try db.transaction {
            var n = 0
            for t in Self.personTables {
                for r in try db.query("SELECT DISTINCT person_id FROM \(t) WHERE person_id IS NOT NULL") {
                    guard let p = r["person_id"]?.string, !keep.contains(p) else { continue }
                    n += try db.query("SELECT 1 FROM \(t) WHERE person_id = ?", [.text(p)]).count
                    try db.query("DELETE FROM \(t) WHERE person_id = ?", [.text(p)])
                }
            }
            return n
        }
        if n > 0 { try db.checkpoint() }
        return n
    }

    /// DeeMemory folded `from` into `into` (call with `MemoryStore.merge`, after
    /// `Cortex.merge`). Rows are re-pointed; clashes resolved like `Moment.merge`:
    /// lesson (person, situation) → into's row, evidence summed, earliest created,
    /// latest applied; social profile and open repair → into's; digest (day) → summed;
    /// boundary (topic, owner) → into's, active if either was; ritual (trigger) → into's.
    public func merge(from: PersonID, into: PersonID) throws {
        guard from != into else { return }
        let f = SelfDatabase.Value.text(from.uuidString), i = SelfDatabase.Value.text(into.uuidString)
        try db.transaction {
            for r in try db.query("SELECT situation, evidence, created, last_applied FROM lesson WHERE person_id = ?", [f]) {
                guard let sit = r["situation"] else { continue }
                if try db.query("SELECT 1 FROM lesson WHERE person_id = ? AND situation = ?", [i, sit]).isEmpty { continue }
                try db.query("""
                    UPDATE lesson SET evidence = evidence + ?, created = min(ifnull(created, ?), ifnull(?, created)),
                      last_applied = max(ifnull(last_applied, ?), ifnull(?, last_applied))
                    WHERE person_id = ? AND situation = ?
                    """, [r["evidence"] ?? .int(0), r["created"] ?? .null, r["created"] ?? .null,
                          r["last_applied"] ?? .null, r["last_applied"] ?? .null, i, sit])
                try db.query("DELETE FROM lesson WHERE person_id = ? AND situation = ?", [f, sit])
            }
            for t in ["social_profile", "open_repair"] {
                if try !db.query("SELECT 1 FROM \(t) WHERE person_id = ?", [i]).isEmpty {
                    try db.query("DELETE FROM \(t) WHERE person_id = ?", [f])
                }
            }
            for r in try db.query("SELECT day, conversations, low_salience FROM digest WHERE person_id = ?", [f]) {
                guard let day = r["day"] else { continue }
                if try db.query("SELECT 1 FROM digest WHERE person_id = ? AND day = ?", [i, day]).isEmpty { continue }
                try db.query("UPDATE digest SET conversations = conversations + ?, low_salience = low_salience + ? WHERE person_id = ? AND day = ?",
                             [r["conversations"] ?? .int(0), r["low_salience"] ?? .int(0), i, day])
                try db.query("DELETE FROM digest WHERE person_id = ? AND day = ?", [f, day])
            }
            for r in try db.query("SELECT id, topic, owner, active FROM boundary WHERE person_id = ?", [f]) {
                guard let id = r["id"], let topic = r["topic"], let owner = r["owner"] else { continue }
                if try db.query("SELECT 1 FROM boundary WHERE person_id = ? AND topic = ? AND owner = ?", [i, topic, owner]).isEmpty { continue }
                if (r["active"]?.int ?? 0) != 0 {
                    try db.query("UPDATE boundary SET active = 1 WHERE person_id = ? AND topic = ? AND owner = ?", [i, topic, owner])
                }
                try db.query("DELETE FROM boundary WHERE id = ?", [id])
            }
            for r in try db.query("SELECT id, trigger FROM ritual WHERE person_id = ?", [f]) {
                guard let id = r["id"], let trigger = r["trigger"] else { continue }
                if try !db.query("SELECT 1 FROM ritual WHERE person_id = ? AND trigger = ?", [i, trigger]).isEmpty {
                    try db.query("DELETE FROM ritual WHERE id = ?", [id])
                }
            }
            for t in Self.personTables { try db.query("UPDATE \(t) SET person_id = ? WHERE person_id = ?", [i, f]) }
        }
    }

    /// Wipes everything except the seeded self (seed, values, humour, signature and
    /// the seeded facets, reset to their seeded state — `Enduring.keepingSeeded()`).
    /// Pair with `MemoryStore.forgetEverything()`; call `Cortex.forgetAll()` first.
    public func forgetAll() throws {
        try db.transaction {
            for t in Self.personTables { try db.execute("DELETE FROM \(t);") }
            try db.execute("DELETE FROM interest;")
            try db.execute("DELETE FROM facet WHERE source IS NOT 'seed';")
            try db.execute("UPDATE facet SET learned = 0, polarity = innate, evidence = 0, contrary = 0, revealed_at = NULL, reason = NULL;")
            try db.execute("""
                DELETE FROM self_meta WHERE key NOT IN ('schema_version', 'seed', 'values', 'humour', 'humour2', 'signature', 'session', 'persona');
                """)
        }
        try db.checkpoint()
    }

    /// Rows of `table` for `person` (tests).
    func count(_ table: String, person: PersonID) throws -> Int {
        try db.query("SELECT 1 FROM \(table) WHERE person_id = ?", [.text(person.uuidString)]).count
    }

    /// Folds the WAL back into the main file (so deleted text does not linger in `-wal`).
    public func checkpoint() throws { try db.checkpoint() }

    /// Column names of every table (schema policy tests).
    public func columns() throws -> [String: [String]] {
        var out: [String: [String]] = [:]
        for r in try db.query("SELECT name FROM sqlite_master WHERE type = 'table'") {
            guard let t = r["name"]?.string else { continue }
            out[t] = try db.query("SELECT name FROM pragma_table_info(?)", [.text(t)]).compactMap { $0["name"]?.string }
        }
        return out
    }

    /// Every TEXT value stored in the self tables (privacy tests).
    public func allText() throws -> [String] {
        var out: [String] = []
        for (t, _) in try columns() where t == "self_meta" || t == "facet" || t == "interest" || Self.personTables.contains(t) {
            for row in try db.query("SELECT * FROM \(t)") { out += row.values.compactMap(\.string) }
        }
        return out
    }

    // MARK: - Coding helpers

    static func id(_ u: UUID?) -> SelfDatabase.Value { u.map { .text($0.uuidString) } ?? .null }
    static func text(_ s: String?) -> SelfDatabase.Value { s.map { .text($0) } ?? .null }
    static func date(_ d: Date?) -> SelfDatabase.Value { d.map { .real($0.timeIntervalSince1970) } ?? .null }
    static func date(_ v: SelfDatabase.Value?) -> Date? { v?.double.map(Date.init(timeIntervalSince1970:)) }
    static func uuid(_ v: SelfDatabase.Value?) -> UUID? { v?.string.flatMap(UUID.init(uuidString:)) }
    static func json(_ a: [String]) -> String { (try? String(decoding: JSONEncoder().encode(a), as: UTF8.self)) ?? "[]" }
    static func topics(_ v: SelfDatabase.Value?) -> [Subject] {
        guard let s = v?.string, let a = try? JSONDecoder().decode([String].self, from: Data(s.utf8)) else { return [] }
        return a.compactMap(Subject.init)
    }
    static func code(_ v: SelfDatabase.Value?) -> MindCode? {
        guard let d = v?.data, d.count == MindCode.parameterCount else { return nil }
        return MindCode(hex: d.map { String(format: "%02X", $0) }.joined())
    }
}
