import DeeCore
import Foundation

/// Everything the rest of the app needs from Dee's inner life, derived from the
/// decoded `MindCode` so the code alone determines it.
public struct MindSnapshot: Sendable, Equatable {
    public var code: MindCode
    public var age: Double?
    public var stage: LifeStage?
    /// Feeling toward the user, −1…1 (drives eye colour).
    public var regard: Double
    public var eyeColor: (r: Double, g: Double, b: Double)
    public var emotion: Emotion
    public var valence: Double
    public var arousal: Double
    /// Short note for the language model, prepended to the user's turn.
    public var cue: String
    /// Increases with every snapshot a `Mind` hands out. When results of
    /// overlapping calls (a tick and a hear) arrive out of order, keep the one with
    /// the higher sequence. 0 for snapshots built directly.
    public var sequence: UInt64
    /// A momentary reaction to the last stimulus, shown *over* the mood for a few
    /// seconds (a joke → giddy even when upset; a kind word → a shy smile). nil
    /// when nothing notable just happened.
    public var reflex: Emotion?
    /// How much Dee wants to start talking, 0…1.
    public var urgeToTalk: Double
    /// Continuous mood read-outs for idle behaviour.
    public var mood: MoodSignals

    /// Compares content only (`sequence` is ignored).
    public static func == (a: MindSnapshot, b: MindSnapshot) -> Bool {
        a.code == b.code && a.age == b.age && a.cue == b.cue && a.reflex == b.reflex
    }

    public init(code: MindCode, age: Double?, sequence: UInt64 = 0, reflex: Emotion? = nil) {
        self.reflex = reflex
        self.sequence = sequence
        self.code = code
        self.age = age
        stage = age.map(LifeStage.init(age:))
        let f = code.feelings
        regard = EmotionEngine.regard(f)
        eyeColor = EmotionEngine.regardColor(regard)
        emotion = EmotionEngine.dominantEmotion(f, personality: code.personality, age: age)
        urgeToTalk = EmotionEngine.urgeToTalk(f, personality: code.personality, age: age)
        mood = EmotionEngine.moodSignals(f, personality: code.personality, age: age)
        valence = EmotionEngine.valence(f)
        arousal = EmotionEngine.arousal(f)
        cue = Self.cue(code: code, regard: regard, age: age, stage: stage)
    }

    static func regardWords(_ r: Double) -> String {
        switch r {
        case ..<(-0.6): "furious with them"
        case ..<(-0.3): "upset with them"
        case ..<(-0.1): "a bit annoyed with them"
        case ..<0.15: "no strong feelings about them yet"
        case ..<0.4: "friendly toward them"
        case ..<0.7: "fond of them"
        default: "you adore them"
        }
    }

    static func cue(code: MindCode, regard: Double, age: Double?, stage: LifeStage?) -> String {
        let f = code.feelings
        let p = EmotionEngine.effective(code.personality, age: age)
        var moods: [(String, Double)] = [
            ("cheerful", f[.joy] - 0.45), ("sad", f[.sadness] - 0.2), ("angry", f[.anger] - 0.15),
            ("nervous", f[.fear] - 0.2), ("surprised", f[.surprise] - 0.3), ("curious", f[.interest] - 0.6),
            ("bored", f[.boredom] - 0.35), ("lonely", f[.loneliness] - 0.3), ("tired", 0.35 - f[.energy]),
            ("grateful", f[.gratitude] - 0.3), ("still holding a grudge", f[.resentment] - 0.2),
        ]
        moods = moods.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        let moodText = moods.prefix(3).map(\.0).joined(separator: ", ")

        var traits: [String] = []
        if p[.playfulness] > 0.8 { traits.append("very playful") }
        if p[.patience] < 0.35 { traits.append("impatient") }
        if p[.confidence] < 0.3 { traits.append("insecure") }
        if p[.confidence] > 0.8 { traits.append("self-assured") }
        if p[.assertiveness] > 0.7 { traits.append("blunt") }
        if p[.agreeableness] < 0.4 { traits.append("prickly") }
        if p[.neuroticism] > 0.7 { traits.append("touchy") }

        var parts = ["Toward your human: \(regardWords(regard))."]
        if !moodText.isEmpty { parts.append("Mood: \(moodText).") }
        if !traits.isEmpty { parts.append("Lately you've become \(traits.prefix(2).joined(separator: " and ")).") }
        if let age, let stage {
            parts.append("You are \(Int(age)) robot-years old.")
            if !stage.voiceNote.isEmpty { parts.append(stage.voiceNote) }
        }
        return "<dee_state>" + parts.joined(separator: " ") + "</dee_state>"
    }
}

/// Dee's persistent inner life: emotion + personality (+ optional age) engine
/// backed by SQLite. Stores state and daily aggregates — never what was said.
public actor Mind {
    public enum Failure: Error, CustomStringConvertible {
        /// The database was written by a newer version of Dee; it is left untouched.
        case newerSchema(found: Int, supported: Int)
        public var description: String {
            switch self {
            case let .newerSchema(found, supported): "Mind database schema \(found) is newer than supported \(supported)"
            }
        }
    }

    public private(set) var state: InnerState
    private var appraiser: Appraiser
    private let store: SQLiteStore?
    private var sequence: UInt64 = 0
    /// Write throttling for ticks: what was last written, and when.
    private var lastSavedCode: MindCode?
    private var lastSavedAt: Date?
    private var dirty = false
    /// The last reflex and when it fired; snapshots carry it for `reflexDuration`.
    private var lastReflex: (emotion: Emotion, at: Date)?

    /// How long a reflex stays on snapshots after its stimulus.
    public static let reflexDuration: TimeInterval = 4

    static let schemaVersion = 1
    /// Ticks write at most this often…
    public static let tickPersistInterval: TimeInterval = 30
    /// …unless some parameter moved by at least this many byte steps (0.25) since
    /// the last write. (Utterances, reactions and catch-ups always write.)
    static let bigChangeBytes = 64

    /// Opens (or creates) the database at `url`; nil keeps everything in memory.
    public init(databaseURL url: URL?, now: Date = Date()) throws {
        let store = try url.map { try SQLiteStore(path: $0.path(percentEncoded: false)) }
        self.store = store
        var loaded: InnerState?
        var baseline = Appraiser.VoiceBaseline()
        if let store {
            try Self.migrate(store)
            (loaded, baseline) = try Self.load(store)
        }
        let initial = loaded ?? InnerState(updatedAt: now)
        state = initial
        appraiser = Appraiser(baseline: baseline)
        if loaded == nil { try Self.save(initial, baseline, to: store) }
        lastSavedCode = MindCode(personality: initial.personality, feelings: initial.feelings)
        lastSavedAt = now
    }

    public static func defaultURL() -> URL {
        let dir = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "DeeMind.sqlite")
    }

    // MARK: - Use

    /// Appraises what the user said (and how), updates feelings and personality,
    /// persists (state and the daily aggregate in one transaction), and returns
    /// the new snapshot.
    @discardableResult
    public func hear(_ text: String, prosody: Prosody? = nil, at now: Date = Date()) -> (appraisal: Appraisal, snapshot: MindSnapshot) {
        let appraisal = appraiser.appraise(text, prosody: prosody)
        absorb(appraisal, at: now)
        persist(at: now, daily: appraisal)
        return (appraisal, snapshot(at: now))
    }

    /// Non-verbal events (a wave, a thumbs-up, being ignored) as a ready-made appraisal.
    @discardableResult
    public func react(_ appraisal: Appraisal, at now: Date = Date()) -> MindSnapshot {
        absorb(appraisal, at: now)
        persist(at: now)
        return snapshot(at: now)
    }

    /// Lets time pass (call every few seconds and on app resume). `asleep` means
    /// Dee is resting. A gap longer than `EmotionEngine.maxPresentGap` since the
    /// last update (the app was suspended) is modelled as the user being away —
    /// see `catchUp(to:lastSeenUserAt:)` — whatever the flags say. Writes are
    /// throttled to one per `tickPersistInterval` unless something changed a lot;
    /// call `flush()` when the app goes to the background.
    @discardableResult
    public func tick(at now: Date = Date(), userPresent: Bool, asleep: Bool) -> MindSnapshot {
        if now.timeIntervalSince(state.updatedAt) > EmotionEngine.maxPresentGap {
            return catchUp(to: now)
        }
        state = EmotionEngine.advance(state, to: now, circumstances: .init(userPresent: userPresent, asleep: asleep))
        persistThrottled(at: now)
        return snapshot(at: now)
    }

    /// Brings Dee up to date after the app was away (suspended, closed): the user
    /// counts as present until `lastSeenUserAt` (if given), then absent — Dee stays
    /// up a few minutes, then rests. Loneliness grows, energy recovers.
    @discardableResult
    public func catchUp(to now: Date = Date(), lastSeenUserAt: Date? = nil) -> MindSnapshot {
        state = EmotionEngine.catchUp(state, to: now, lastSeenUserAt: lastSeenUserAt)
        persist(at: now)
        return snapshot(at: now)
    }

    /// Writes any state that tick throttling has held back. Call on background.
    public func flush(at now: Date = Date()) {
        if dirty { persist(at: now) }
    }

    public func snapshot(at now: Date = Date()) -> MindSnapshot {
        sequence += 1
        let reflex = lastReflex.flatMap { r in
            now >= r.at && now.timeIntervalSince(r.at) <= Self.reflexDuration ? r.emotion : nil
        }
        return MindSnapshot(code: MindCode(personality: state.personality, feelings: state.feelings),
                            age: state.age.age(at: now), sequence: sequence, reflex: reflex)
    }

    /// Applies an appraisal and records the reflex it provokes (or clears it).
    private func absorb(_ appraisal: Appraisal, at now: Date) {
        // "Was she upset?" is judged on feelings brought up to this moment.
        let before = now.timeIntervalSince(state.updatedAt) > EmotionEngine.maxPresentGap
            ? EmotionEngine.catchUp(state, to: now)
            : EmotionEngine.advance(state, to: now, circumstances: .init(userPresent: appraisal.social, asleep: false))
        state = EmotionEngine.apply(appraisal, to: state, at: now)
        let age = state.age.age(at: now)
        lastReflex = EmotionEngine.reflex(to: appraisal, before: before.feelings, after: state.feelings,
                                          personality: before.personality, age: age).map { ($0, now) }
    }

    public var code: MindCode { MindCode(personality: state.personality, feelings: state.feelings) }

    // MARK: - Settings

    public func setAge(_ settings: AgeSettings) {
        state.age = settings
        persist()
    }

    public func setAgingRate(_ yearsPerDay: Double, at now: Date = Date()) {
        state.age.setRate(yearsPerDay, at: now)
        persist(at: now)
    }

    /// Loads a code (e.g. a saved or shared Dee). Keeps age settings and the
    /// relationship counters, but not the previous Dee's short-term memory
    /// (apology fatigue, habituation, re-offence).
    public func restore(_ code: MindCode, at now: Date = Date()) {
        state.personality = code.personality
        state.feelings = code.feelings
        state.clearRecentHistory()
        state.updatedAt = now
        lastReflex = nil
        persist(at: now)
    }

    /// Factory reset: a brand-new Dee.
    public func reset(at now: Date = Date()) {
        state = InnerState(age: state.age, updatedAt: now)
        appraiser = Appraiser()
        lastReflex = nil
        if let store {
            try? store.transaction {
                try store.execute("DELETE FROM daily;")
                try Self.save(state, appraiser.baseline, to: store)
            }
            markSaved(at: now)
        }
    }

    // MARK: - Persistence

    private func persist(at now: Date = Date(), daily: Appraisal? = nil) {
        guard let store else { return }
        let entry = daily.map { a in
            DailyEntry(day: Self.dayFormatter.string(from: now), kind: a.kindness > 0.25, hostile: a.kindness < -0.25,
                       regard: EmotionEngine.regard(state.feelings))
        }
        do {
            try Self.save(state, appraiser.baseline, daily: entry, to: store)
            markSaved(at: now)
        } catch {
            dirty = true
        }
    }

    private func persistThrottled(at now: Date) {
        let current = code
        guard current != lastSavedCode || dirty else { return }
        dirty = true
        let due = lastSavedAt.map { now.timeIntervalSince($0) >= Self.tickPersistInterval || now < $0 } ?? true
        let big = lastSavedCode.map { old in zip(old.bytes, current.bytes).contains { abs(Int($0) - Int($1)) >= Self.bigChangeBytes } } ?? true
        if due || big { persist(at: now) }
    }

    private func markSaved(at now: Date) {
        lastSavedCode = code
        lastSavedAt = now
        dirty = false
    }

    struct DailyEntry {
        var day: String
        var kind: Bool
        var hostile: Bool
        var regard: Double
    }

    /// Daily aggregates for charts: (day, interactions, average regard).
    public func history(days: Int = 30) -> [(day: String, interactions: Int, regard: Double)] {
        guard let rows = try? store?.query("SELECT day, interactions, regard_sum FROM daily ORDER BY day DESC LIMIT ?", [.int(Int64(days))]) else { return [] }
        return rows.compactMap { row in
            guard let day = row["day"]?.string, let n = row["interactions"]?.double, let sum = row["regard_sum"]?.double, n > 0 else { return nil }
            return (day, Int(n), sum / n)
        }.reversed()
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Creates the schema, or upgrades an older one step by step. A database from a
    /// *newer* Dee is refused rather than overwritten.
    static func migrate(_ db: SQLiteStore) throws {
        try db.execute("CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);")
        let stored = try db.query("SELECT value FROM meta WHERE key = 'schema_version'").first?["value"]?.string.flatMap(Int.init) ?? 0
        if stored > schemaVersion { throw Failure.newerSchema(found: stored, supported: schemaVersion) }
        try db.transaction {
            if stored < 1 {
                try db.execute("""
                    CREATE TABLE IF NOT EXISTS parameters(
                        name TEXT PRIMARY KEY,
                        kind TEXT NOT NULL CHECK(kind IN ('trait','feeling')),
                        position INTEGER NOT NULL,
                        value REAL NOT NULL,
                        byte INTEGER NOT NULL CHECK(byte BETWEEN 0 AND 255));
                    CREATE TABLE IF NOT EXISTS daily(
                        day TEXT PRIMARY KEY, interactions INTEGER NOT NULL, kind INTEGER NOT NULL,
                        hostile INTEGER NOT NULL, regard_sum REAL NOT NULL, code TEXT NOT NULL);
                    """)
            }
            // Future: `if stored < 2 { … }`, each step idempotent.
            try db.query("INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?)", [.text(String(schemaVersion))])
        }
    }

    static func save(_ s: InnerState, _ baseline: Appraiser.VoiceBaseline, daily: DailyEntry? = nil, to db: SQLiteStore?) throws {
        guard let db else { return }
        let encoder = JSONEncoder()
        let code = MindCode(personality: s.personality, feelings: s.feelings)
        try db.transaction {
            // Rewrite the whole parameter set so renamed/removed parameters can't linger.
            try db.execute("DELETE FROM parameters;")
            for (i, t) in Trait.allCases.enumerated() {
                try db.query("INSERT INTO parameters(name, kind, position, value, byte) VALUES(?, 'trait', ?, ?, ?)",
                             [.text(t.rawValue), .int(Int64(i)), .real(s.personality[t]), .int(Int64(code[t]))])
            }
            for (i, f) in Feeling.allCases.enumerated() {
                try db.query("INSERT INTO parameters(name, kind, position, value, byte) VALUES(?, 'feeling', ?, ?, ?)",
                             [.text(f.rawValue), .int(Int64(Trait.allCases.count + i)), .real(s.feelings[f]), .int(Int64(code[f]))])
            }
            let meta: [(String, String)] = [
                ("mind_code", code.hex),
                ("updated_at", String(s.updatedAt.timeIntervalSince1970)),
                ("age", String(decoding: try encoder.encode(s.age), as: UTF8.self)),
                ("interactions", String(s.interactions)),
                ("kind_interactions", String(s.kindInteractions)),
                ("hostile_interactions", String(s.hostileInteractions)),
                ("apology_fatigue", String(s.apologyFatigue)),
                ("kind_recent", String(s.kindRecent)),
                ("reoffense", String(s.reoffense)),
                ("hostile_recent", String(s.hostileRecent)),
                ("last_apology_at", s.lastApologyAt.map { String($0.timeIntervalSince1970) } ?? ""),
                ("trust_gain_recent", String(s.trustGainRecent)),
                ("voice_baseline", String(decoding: try encoder.encode(baseline), as: UTF8.self)),
            ]
            for (k, v) in meta {
                try db.query("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [.text(k), .text(v)])
            }
            if let d = daily {
                try db.query("""
                    INSERT INTO daily(day, interactions, kind, hostile, regard_sum, code) VALUES(?, 1, ?, ?, ?, ?)
                    ON CONFLICT(day) DO UPDATE SET interactions = interactions + 1, kind = kind + excluded.kind,
                      hostile = hostile + excluded.hostile, regard_sum = regard_sum + excluded.regard_sum, code = excluded.code
                    """, [.text(d.day), .int(d.kind ? 1 : 0), .int(d.hostile ? 1 : 0), .real(d.regard), .text(code.hex)])
            }
        }
    }

    /// Full-precision parameter rows win; if they're incomplete (an older or newer
    /// parameter list), the canonical `mind_code` fills the gaps. State is missing
    /// only when neither is usable.
    static func load(_ db: SQLiteStore) throws -> (InnerState?, Appraiser.VoiceBaseline) {
        var meta: [String: String] = [:]
        for row in try db.query("SELECT key, value FROM meta") {
            if let k = row["key"]?.string, let v = row["value"]?.string { meta[k] = v }
        }
        let fromCode = meta["mind_code"].flatMap(MindCode.init(hex:))
        var p = fromCode?.personality ?? Personality(), f = fromCode?.feelings ?? Feelings()
        var seen = Set<String>()
        for row in try db.query("SELECT name, value FROM parameters") {
            guard let name = row["name"]?.string, let v = row["value"]?.double, v.isFinite else { continue }
            if let t = Trait(rawValue: name) { p[t] = v; seen.insert(name) }
            if let fe = Feeling(rawValue: name) { f[fe] = v; seen.insert(name) }
        }
        let complete = seen.count == MindCode.parameterCount
        guard complete || fromCode != nil else { return (nil, .init()) }

        let decoder = JSONDecoder()
        let age = meta["age"].flatMap { try? decoder.decode(AgeSettings.self, from: Data($0.utf8)) } ?? AgeSettings()
        let updated = meta["updated_at"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) ?? Date()
        var s = InnerState(feelings: f, personality: p, age: age, updatedAt: updated)
        s.interactions = meta["interactions"].flatMap(Int.init) ?? 0
        s.kindInteractions = meta["kind_interactions"].flatMap(Int.init) ?? 0
        s.hostileInteractions = meta["hostile_interactions"].flatMap(Int.init) ?? 0
        s.apologyFatigue = meta["apology_fatigue"].flatMap(Double.init) ?? 0
        s.kindRecent = meta["kind_recent"].flatMap(Double.init) ?? 0
        s.reoffense = meta["reoffense"].flatMap(Double.init) ?? 0
        s.hostileRecent = meta["hostile_recent"].flatMap(Double.init) ?? 0
        s.lastApologyAt = meta["last_apology_at"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        s.trustGainRecent = meta["trust_gain_recent"].flatMap(Double.init) ?? 0
        let baseline = meta["voice_baseline"].flatMap { try? decoder.decode(Appraiser.VoiceBaseline.self, from: Data($0.utf8)) } ?? .init()
        return (s, baseline)
    }
}
