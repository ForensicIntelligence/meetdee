import Foundation

/// The people Dee knows: names, aliases, face prints and distilled facts, in one
/// on-device SQLite file. Never transcripts.
///
/// Errors from SQLite are not thrown from the (non-throwing) contract methods;
/// the last one is kept in `lastError` and the in-memory state stays consistent
/// with what was actually written.
public actor MemoryStore {
    /// Name of a placeholder person: someone Dee is talking to whose name she does
    /// not know yet. One per session / unrecognised face (`placeholderPerson(session:)`).
    public static let unknownFriendName = "unknown friend"
    /// Calls to `noteEncounter` closer together than this extend the current
    /// encounter (update `lastSeen`) instead of counting a new one.
    public static let encounterGap: TimeInterval = 20 * 60
    /// A pending name heard again within this window counts as heard twice.
    public static let nameConfirmWindow: TimeInterval = 10 * 60
    /// Starting confidence of a remembered fact; each repetition adds `reinforcement`.
    public static let baseConfidence = 0.8
    public static let reinforcement = 0.05
    /// At most this many aliases per person (oldest dropped).
    public static let maxAliases = 6
    /// v3: every stored fact is re-checked against the current FactPolicy /
    /// FactSensitivity rules. Bump this whenever those rules change, so
    /// databases written by older code are re-checked on the next open.
    static let schemaVersion = 3

    public private(set) var faceMatching: FaceMatching
    public private(set) var lastError: String?

    struct StoredPrint {
        var row: Int64
        var print: FacePrint
        var anchor: Bool
        /// Passed `FaceQualityGate` (anchors always did). Kept in memory only: it
        /// matters for placeholders and pending enrolments, which never outlive
        /// the store.
        var quality: Bool
    }

    private let db: MemoryDatabase
    private let calendar: Calendar
    private var gallery: [UUID: [StoredPrint]] = [:] { didSet { rebuildFaceIndex() } }
    private var galleryPrints: [UUID: [FacePrint]] = [:]
    private var galleryAnchors: [UUID: [FacePrint]] = [:]
    /// Read cache, valid while `db.totalChanges` is unchanged (any write clears it).
    private var personCache: [UUID: Person] = [:]
    private var cacheStamp: Int64 = -1
    /// Consecutive single-face frames that agreed on one person (learning gate),
    /// with the time of the last one (`FaceMatching.learnStreakGap`).
    private var streak: (id: UUID, frames: Int, at: Date)?
    private var pending: [UUID: (name: String, at: Date, count: Int)] = [:]
    /// Placeholder ids (all placeholders are created by this store instance:
    /// earlier ones are purged on open). Their prints match without anchors.
    private var placeholders: Set<UUID> = []
    /// Session → the real person its placeholder became (renamed or merged).
    private var sessionOwner: [UUID: UUID] = [:]
    /// A merged-away id → the person it was merged into.
    private var redirects: [UUID: UUID] = [:]
    /// User text (facts, names, aliases) or face prints were deleted or
    /// overwritten: checkpoint(TRUNCATE) once the outermost public call ends.
    private var removalPending = false
    private var batchDepth = 0

    public init(databaseURL: URL?) throws {
        try self.init(databaseURL: databaseURL, faceMatching: FaceMatching())
    }

    /// `databaseURL` should live in a folder used only by Dee (the default is
    /// `Application Support/Dee/`): the folder and the database files are excluded
    /// from iCloud / computer backups and (iOS) given file protection BEFORE the
    /// database is opened. Placeholders left over from earlier sessions are deleted.
    public init(databaseURL: URL?, faceMatching: FaceMatching, calendar: Calendar = .current) throws {
        let path: String
        if let url = databaseURL {
            try Self.prepareFolder(url.deletingLastPathComponent())
            path = url.path
        } else {
            path = ":memory:"
        }
        let db = try MemoryDatabase(path: path)
        try Self.migrate(db)
        if let url = databaseURL { Self.protectFiles(url) }
        // Placeholders are per session; a new store is a new session.
        try db.query("DELETE FROM people WHERE name = ?;", [.text(Self.unknownFriendName)])
        try? db.checkpoint()
        self.db = db
        self.faceMatching = faceMatching
        self.calendar = calendar
        let g = try Self.loadGallery(db)
        self.gallery = g
        (self.galleryPrints, self.galleryAnchors) = Self.index(g, placeholders: [])
    }

    /// `Application Support/Dee/DeeMemory.sqlite`.
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Dee", isDirectory: true).appendingPathComponent("DeeMemory.sqlite")
    }

    public func setFaceMatching(_ tuning: FaceMatching) { faceMatching = tuning }

    // MARK: - Files

    static func prepareFolder(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #if os(iOS) || os(watchOS) || os(visionOS)
        // New files inherit the folder's class, so set it before the database exists.
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dir.path)
        #endif
        excludeFromBackup(dir)
    }

    static func protectFiles(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            #if os(iOS) || os(watchOS) || os(visionOS)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
            #endif
            excludeFromBackup(file)
        }
    }

    static func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    // MARK: - Schema

    private static func migrate(_ db: MemoryDatabase) throws {
        try db.transaction {
            try db.execute("CREATE TABLE IF NOT EXISTS schema_version(version INTEGER NOT NULL);")
            let version = try db.query("SELECT MAX(version) AS v FROM schema_version;").first?["v"]?.int ?? 0
            if version < 1 {
                try db.execute("""
                CREATE TABLE IF NOT EXISTS people(
                    id TEXT PRIMARY KEY, name TEXT NOT NULL,
                    first_met REAL NOT NULL, last_seen REAL NOT NULL, encounters INTEGER NOT NULL DEFAULT 1);
                CREATE TABLE IF NOT EXISTS aliases(
                    person_id TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                    alias TEXT NOT NULL COLLATE NOCASE, PRIMARY KEY(person_id, alias));
                CREATE TABLE IF NOT EXISTS face_prints(
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    person_id TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                    vector BLOB NOT NULL, added_at REAL NOT NULL);
                CREATE INDEX IF NOT EXISTS face_prints_person ON face_prints(person_id);
                CREATE TABLE IF NOT EXISTS facts(
                    id TEXT PRIMARY KEY, person_id TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
                    text TEXT NOT NULL, category TEXT NOT NULL, confidence REAL NOT NULL,
                    created_at REAL NOT NULL, updated_at REAL NOT NULL);
                CREATE INDEX IF NOT EXISTS facts_person ON facts(person_id);
                """)
            }
            if version < 2 {
                try db.execute("""
                ALTER TABLE people ADD COLUMN session TEXT;
                ALTER TABLE facts ADD COLUMN sensitive INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE face_prints ADD COLUMN anchor INTEGER NOT NULL DEFAULT 0;
                """)
                // v1 did not know enrolment from learnt prints: keep each person's
                // oldest prints as anchors.
                try db.execute("""
                UPDATE face_prints SET anchor = 1 WHERE id IN (
                    SELECT f.id FROM face_prints f WHERE
                    (SELECT COUNT(*) FROM face_prints g WHERE g.person_id = f.person_id AND g.id < f.id) < 3);
                """)
            }
            if version < schemaVersion {
                try recheckFacts(db)
                try db.query("DELETE FROM schema_version;")
                try db.query("INSERT INTO schema_version(version) VALUES (?);", [.int(Int64(schemaVersion))])
            }
        }
    }

    /// Re-applies the current rules to every stored fact: facts that
    /// `FactPolicy.isDenied` or `FactPolicy.isSelfHarm` reject are deleted (with
    /// secure_delete; the caller truncates the WAL), and `sensitive` is
    /// recomputed for the rest. Returns how many facts were deleted.
    @discardableResult
    static func recheckFacts(_ db: MemoryDatabase) throws -> Int {
        var deleted = 0
        for r in try db.query("SELECT id, text, category, sensitive FROM facts;") {
            guard let id = r["id"]?.string, let text = r["text"]?.string else { continue }
            if FactPolicy.isDenied(text) || FactPolicy.isSelfHarm(text) {
                try db.query("DELETE FROM facts WHERE id = ?;", [.text(id)])
                deleted += 1
                continue
            }
            let cat = r["category"]?.string.flatMap(Fact.Category.init(rawValue:)) ?? .other
            let sensitive = FactSensitivity.isSensitive(text, category: cat) ? 1 : 0
            if r["sensitive"]?.int != sensitive {
                try db.query("UPDATE facts SET sensitive = ? WHERE id = ?;", [.int(Int64(sensitive)), .text(id)])
            }
        }
        return deleted
    }

    private static func loadGallery(_ db: MemoryDatabase) throws -> [UUID: [StoredPrint]] {
        var out: [UUID: [StoredPrint]] = [:]
        for r in try db.query("SELECT id, person_id, vector, anchor FROM face_prints ORDER BY id;") {
            guard let pid = r["person_id"]?.string.flatMap(UUID.init(uuidString:)),
                  let data = r["vector"]?.data, let fp = FacePrint(blob: data),
                  case .int(let row)? = r["id"] else { continue }
            let anchor = (r["anchor"]?.int ?? 0) != 0
            out[pid, default: []].append(StoredPrint(row: row, print: fp, anchor: anchor, quality: anchor))
        }
        return out
    }

    private func rebuildFaceIndex() {
        (galleryPrints, galleryAnchors) = Self.index(gallery, placeholders: placeholders)
    }

    /// Matchable prints and anchors. A REAL person is recognisable only once they
    /// have anchors (an enrolment of ≥ `minEnrollPrints` quality prints); their
    /// other prints are ignored until then. A placeholder (this session's
    /// unrecognised face) matches on whatever prints it has.
    private static func index(_ g: [UUID: [StoredPrint]], placeholders: Set<UUID>) -> ([UUID: [FacePrint]], [UUID: [FacePrint]]) {
        var prints: [UUID: [FacePrint]] = [:], anchors: [UUID: [FacePrint]] = [:]
        for (id, set) in g {
            let a = set.filter(\.anchor).map(\.print)
            guard !a.isEmpty || placeholders.contains(id) else { continue }
            prints[id] = set.map(\.print)
            anchors[id] = a
        }
        return (prints, anchors)
    }

    private func attempt<T>(_ body: () throws -> T) -> T? {
        do { return try body() } catch {
            lastError = String(describing: error)
            return nil
        }
    }

    /// Folds the WAL back and truncates it, so forgotten text does not linger in
    /// `DeeMemory.sqlite-wal`. Called (once, at the end of the public call)
    /// after every deletion or overwrite of user text or face prints.
    private func checkpoint() {
        _ = attempt { try db.checkpoint() }
    }

    private func markRemoval() { removalPending = true }

    /// Runs one public operation; nested calls share one checkpoint at the end.
    private func batch<T>(_ body: () -> T) -> T {
        batchDepth += 1
        defer {
            batchDepth -= 1
            if batchDepth == 0, removalPending {
                removalPending = false
                checkpoint()
            }
        }
        return body()
    }

    /// Follows merges: an id that was merged away resolves to the person it
    /// became part of (so a stale placeholder id still reaches the right record).
    public func resolve(_ id: UUID) -> UUID {
        var cur = id
        var hops = 0
        while let next = redirects[cur], hops < 16 { cur = next; hops += 1 }
        return cur
    }

    // MARK: - People

    public func people() -> [Person] {
        attempt { try loadPeople(where: nil) } ?? []
    }

    /// The person with this id; a merged-away id resolves to the person it
    /// became part of.
    public func person(_ rawID: UUID) -> Person? {
        let id = resolve(rawID)
        if cacheStamp != db.totalChanges {
            personCache.removeAll(keepingCapacity: true)
            cacheStamp = db.totalChanges
        }
        if let p = personCache[id] { return p }
        guard let p = attempt({ try loadPeople(where: id) })?.first else { return nil }
        personCache[id] = p
        return p
    }

    /// Case-insensitive match on name or alias among REAL people (placeholders are
    /// never returned); an exact name beats an alias, then the most recently seen.
    public func person(named name: String) -> Person? {
        let n = Self.cleanName(name)
        guard !n.isEmpty, n.caseInsensitiveCompare(Self.unknownFriendName) != .orderedSame else { return nil }
        let rows = attempt {
            try db.query("""
            SELECT id FROM people WHERE name = ?1 COLLATE NOCASE
            UNION SELECT person_id AS id FROM aliases WHERE alias = ?1 COLLATE NOCASE;
            """, [.text(n)])
        } ?? []
        let found = rows.compactMap { $0["id"]?.string.flatMap(UUID.init(uuidString:)) }.compactMap(person).filter { !$0.isPlaceholder }
        return found.sorted { ($0.name.caseInsensitiveCompare(n) == .orderedSame ? 0 : 1, $1.lastSeen) < ($1.name.caseInsensitiveCompare(n) == .orderedSame ? 0 : 1, $0.lastSeen) }.first
    }

    private func loadPeople(where only: UUID?) throws -> [Person] {
        let filter = only.map { [MemoryDatabase.Value.text($0.uuidString)] } ?? []
        let peopleRows = try db.query(
            "SELECT * FROM people\(only == nil ? "" : " WHERE id = ?") ORDER BY last_seen DESC;", filter)
        guard !peopleRows.isEmpty else { return [] }
        let aliasRows = try db.query("SELECT person_id, alias FROM aliases\(only == nil ? "" : " WHERE person_id = ?") ORDER BY rowid;", filter)
        let factRows = try db.query("SELECT * FROM facts\(only == nil ? "" : " WHERE person_id = ?") ORDER BY created_at, rowid;", filter)
        var aliases: [String: [String]] = [:]
        for r in aliasRows {
            if let p = r["person_id"]?.string, let a = r["alias"]?.string { aliases[p, default: []].append(a) }
        }
        var facts: [String: [Fact]] = [:]
        for r in factRows {
            guard let p = r["person_id"]?.string, let f = Self.fact(from: r) else { continue }
            facts[p, default: []].append(f)
        }
        return peopleRows.compactMap { r in
            guard let idString = r["id"]?.string, let id = UUID(uuidString: idString), let name = r["name"]?.string else { return nil }
            return Person(id: id, name: name, aliases: aliases[idString] ?? [],
                          firstMet: Date(timeIntervalSince1970: r["first_met"]?.double ?? 0),
                          lastSeen: Date(timeIntervalSince1970: r["last_seen"]?.double ?? 0),
                          encounters: r["encounters"]?.int ?? 1, facts: facts[idString] ?? [],
                          session: r["session"]?.string.flatMap(UUID.init(uuidString:)))
        }
    }

    private static func fact(from r: MemoryDatabase.Row) -> Fact? {
        guard let id = r["id"]?.string.flatMap(UUID.init(uuidString:)), let text = r["text"]?.string else { return nil }
        let cat = r["category"]?.string.flatMap(Fact.Category.init(rawValue:)) ?? .other
        return Fact(id: id, text: text, category: cat, confidence: r["confidence"]?.double ?? baseConfidence,
                    createdAt: Date(timeIntervalSince1970: r["created_at"]?.double ?? 0),
                    updatedAt: Date(timeIntervalSince1970: r["updated_at"]?.double ?? 0),
                    sensitive: (r["sensitive"]?.int ?? 0) != 0)
    }

    private func insertPerson(name: String, at: Date, session: UUID? = nil) throws -> Person {
        let p = Person(name: name, firstMet: at, lastSeen: at, encounters: 1, session: session)
        try db.query("INSERT INTO people(id, name, first_met, last_seen, encounters, session) VALUES (?, ?, ?, ?, 1, ?);",
                     [.text(p.id.uuidString), .text(name), .real(at.timeIntervalSince1970), .real(at.timeIntervalSince1970),
                      session.map { .text($0.uuidString) } ?? .null])
        return p
    }

    /// A person known by voice only (no face yet), e.g. from a phone-style chat.
    @discardableResult
    public func addPerson(named name: String, at: Date) -> Person? {
        let clean = Self.cleanName(name)
        guard !clean.isEmpty, clean.caseInsensitiveCompare(Self.unknownFriendName) != .orderedSame else { return nil }
        return attempt { try insertPerson(name: clean, at: at) }
    }

    /// All real people answering to `name` (name or alias), exact names first.
    func peopleNamed(_ name: String) -> [Person] {
        let n = Self.cleanName(name)
        guard !n.isEmpty, n.caseInsensitiveCompare(Self.unknownFriendName) != .orderedSame else { return [] }
        let rows = attempt {
            try db.query("""
            SELECT id FROM people WHERE name = ?1 COLLATE NOCASE
            UNION SELECT person_id AS id FROM aliases WHERE alias = ?1 COLLATE NOCASE;
            """, [.text(n)])
        } ?? []
        let found = rows.compactMap { $0["id"]?.string.flatMap(UUID.init(uuidString:)) }.compactMap(person).filter { !$0.isPlaceholder }
        return found.sorted { ($0.name.caseInsensitiveCompare(n) == .orderedSame ? 0 : 1, $1.lastSeen) < ($1.name.caseInsensitiveCompare(n) == .orderedSame ? 0 : 1, $0.lastSeen) }
    }

    /// Enrols a face under `name`. Needs at least `faceMatching.minEnrollPrints`
    /// distinct prints, each from a different frame that passed `FaceQualityGate`
    /// (use `FaceEmbedder.enrolmentPrint`, or pass `qualities` — one per print —
    /// and the store drops the prints that fail `gate`); returns nil (and sets
    /// `lastError`) with fewer. The prints become never-trimmed anchors.
    ///
    /// An existing person of that name is reused only when the new prints match
    /// their face, or when `reuse` is true (the app confirmed it is the same
    /// person). Otherwise a second person with the same name is created — a
    /// voice-only "John" is not assumed to be this face.
    @discardableResult
    public func enroll(name: String, facePrints: [FacePrint], at: Date, reuse: Bool = false,
                      qualities: [FaceCaptureQuality]? = nil, gate: FaceQualityGate = FaceQualityGate()) -> Person? {
        batch {
            let clean = Self.cleanName(name)
            guard !clean.isEmpty, clean.caseInsensitiveCompare(Self.unknownFriendName) != .orderedSame else { return nil }
            var candidates = facePrints
            if let qualities {
                candidates = zip(facePrints, qualities).filter { $0.1.passes(gate) }.map(\.0)
            }
            let valid = Self.distinct(candidates)
            guard valid.count >= faceMatching.minEnrollPrints else {
                lastError = "enroll needs \(faceMatching.minEnrollPrints) distinct quality face prints, got \(valid.count)"
                return nil
            }
            if let existing = person(named: clean) {
                let stored = galleryAnchors[existing.id].flatMap { $0.isEmpty ? nil : $0 } ?? galleryPrints[existing.id] ?? []
                let matches = !stored.isEmpty && valid.contains {
                    FaceMatcher.score($0, prints: stored, k: faceMatching.matchNeighbours) <= faceMatching.threshold
                }
                if reuse || matches {
                    addFacePrints(valid, to: existing.id, anchor: true)
                    noteEncounter(existing.id, at: at)
                    return person(existing.id) ?? existing
                }
            }
            guard let p = attempt({ try insertPerson(name: clean, at: at) }) else { return nil }
            addFacePrints(valid, to: p.id, anchor: true)
            return person(p.id) ?? p
        }
    }

    /// Normalised, non-empty, pairwise-distinct prints (order kept).
    static func distinct(_ prints: [FacePrint]) -> [FacePrint] {
        var valid: [FacePrint] = []
        for p in prints where !p.vector.isEmpty && p.vector.contains(where: { $0 != 0 }) {
            let n = p.normalized
            if !valid.contains(where: { $0.distance(to: n) < 1e-3 }) { valid.append(n) }
        }
        return valid
    }

    /// The placeholder for one conversation session (or one unrecognised face):
    /// created on first use, returned again for the same `session`, never shared
    /// with another session. Its facts are never put into the prompt.
    ///
    /// Once the session's placeholder has been confirmed (renamed, or merged into
    /// an existing person) this returns THAT real person, so an app that keeps
    /// asking for the session's placeholder keeps writing to the right record.
    @discardableResult
    public func placeholderPerson(session: UUID, at: Date = Date()) -> Person {
        if let owner = sessionOwner[session], let p = person(resolve(owner)) { return p }
        if let row = attempt({ try db.query("SELECT id FROM people WHERE session = ? AND name = ? LIMIT 1;",
                                             [.text(session.uuidString), .text(Self.unknownFriendName)]) })?.first,
           let id = row["id"]?.string.flatMap(UUID.init(uuidString:)), let p = person(id) {
            return p
        }
        if let p = attempt({ try insertPerson(name: Self.unknownFriendName, at: at, session: session) }) {
            placeholders.insert(p.id)
            return p
        }
        return Person(name: Self.unknownFriendName, firstMet: at, lastSeen: at, session: session)
    }

    /// Deletes a placeholder (session ended without learning a name) and all it held.
    /// Does nothing for a real person.
    public func discardPlaceholder(_ id: UUID) {
        guard let p = person(id), p.isPlaceholder else { return }
        forgetPerson(id)
    }

    /// The last name heard for `id` and not yet confirmed (expires after
    /// `nameConfirmWindow`), with how many times it was heard in that window.
    public func pendingName(for id: UUID, now: Date = Date()) -> (name: String, timesHeard: Int)? {
        guard let p = pending[resolve(id)], now.timeIntervalSince(p.at) <= Self.nameConfirmWindow else { return nil }
        return (p.name, p.count)
    }

    func notePending(_ name: String, for id: UUID, at: Date) {
        if let p = pending[id], p.name.caseInsensitiveCompare(name) == .orderedSame,
           at.timeIntervalSince(p.at) <= Self.nameConfirmWindow {
            pending[id] = (p.name, at, p.count + 1)
        } else {
            pending[id] = (name, at, 1)
        }
    }

    /// Applies a CONFIRMED name (the person said yes, the name was heard twice
    /// within `nameConfirmWindow`, or exactly one face was visible):
    /// - Real person (`id` is not a placeholder): if the name is theirs →
    ///   `.named`; otherwise `.differentSpeaker` and NOTHING changes — a name that
    ///   contradicts theirs is never turned into an alias (use `addAlias`).
    /// - Placeholder + a real person of that name (`choice: .ask`): merged only
    ///   when the faces clearly match (score and nearest anchor within
    ///   `threshold`); a second, separate person when they clearly differ (all
    ///   prints ≥ `differentFaceDistance`); otherwise — including when either has
    ///   no face — `.mergeCandidate` and nothing changes.
    /// - Placeholder otherwise: renamed into a new real person. Its distinct
    ///   prints that passed the quality gate become anchors when there are at
    ///   least `minEnrollPrints`; with fewer they are kept as a pending enrolment
    ///   (not matchable) and `needsEnrolment` is true. Other prints are dropped.
    public func confirm(_ name: String, for rawID: UUID, at: Date = Date(), choice: SameNameChoice = .ask) -> ConfirmResult {
        batch {
            let id = resolve(rawID)
            let clean = Self.cleanName(name)
            guard let p = person(id), !clean.isEmpty,
                  clean.caseInsensitiveCompare(Self.unknownFriendName) != .orderedSame else { return .rejected }
            if !p.isPlaceholder {
                // "John Smith" said by John is John (the app may `addAlias` it).
                guard p.answers(to: clean) || Self.isFullerName(clean, of: p) else {
                    return .differentSpeaker(current: p, heard: clean, candidate: peopleNamed(clean).first { $0.id != id })
                }
                pending[id] = nil
                return .named(p, needsEnrolment: anchorCount(of: id) < faceMatching.minEnrollPrints)
            }
            switch choice {
            case .sameAs(let target):
                let t = resolve(target)
                guard t != id, let existing = person(t), !existing.isPlaceholder else { return .rejected }
                return .merged(into: mergePlaceholder(p, into: existing, at: at))
            case .newPerson:
                break
            case .ask:
                var unsure: Person?
                for existing in peopleNamed(clean) where existing.id != id {
                    switch faceRelation(id, existing.id) {
                    case .same: return .merged(into: mergePlaceholder(p, into: existing, at: at))
                    case .unknown: unsure = unsure ?? existing
                    case .different: continue
                    }
                }
                if let unsure { return .mergeCandidate(placeholder: p, existing: unsure) }
            }
            pending[id] = nil
            if let session = p.session { sessionOwner[session] = id }
            rename(id, to: clean)   // also promotes the placeholder's prints
            return .named(person(id) ?? p, needsEnrolment: anchorCount(of: id) < faceMatching.minEnrollPrints)
        }
    }

    /// Compatible wrapper around `confirm`: returns the person to talk to. A
    /// `.mergeCandidate` is resolved the SAFE way — a new, separate person
    /// (nothing is ever merged on a guess); `.differentSpeaker` returns the
    /// known person unchanged (no alias is added).
    @discardableResult
    public func confirmName(_ name: String, for id: UUID, at: Date = Date()) -> Person {
        let r = confirm(name, for: id, at: at)
        switch r {
        case .mergeCandidate(let placeholder, _):
            return confirm(name, for: id, at: at, choice: .newPerson).person ?? placeholder
        case .rejected:
            return person(resolve(id)) ?? Person(name: Self.cleanName(name), firstMet: at, lastSeen: at)
        default:
            return r.person ?? Person(name: Self.cleanName(name), firstMet: at, lastSeen: at)
        }
    }

    private func mergePlaceholder(_ p: Person, into existing: Person, at: Date) -> Person {
        pending[p.id] = nil
        merge(p.id, into: existing.id)
        noteEncounter(existing.id, at: at)
        return person(existing.id) ?? existing
    }

    enum FaceRelation { case same, different, unknown }

    /// Whether placeholder `a` shows the face of real person `b`. `.same` needs
    /// the placeholder's face AS A WHOLE to match: a strict majority of its
    /// prints AND the centroid of its prints must each be within `threshold`
    /// (score and nearest anchor). One stray print (a frame where the real
    /// person walked past) is never enough. `.different` when every print is at
    /// least `differentFaceDistance` from all of `b`'s anchors.
    private func faceRelation(_ a: UUID, _ b: UUID) -> FaceRelation {
        let pa = (gallery[a] ?? []).map(\.print)
        let anchorsB = (gallery[b] ?? []).filter(\.anchor).map(\.print)
        guard !pa.isEmpty, !anchorsB.isEmpty else { return .unknown }
        let allB = galleryPrints[b] ?? anchorsB
        func matches(_ x: FacePrint) -> Bool {
            let s = FaceMatcher.score(x, prints: allB, k: faceMatching.matchNeighbours)
            let nearest = anchorsB.map { x.distance(to: $0) }.min() ?? .greatestFiniteMagnitude
            return s <= faceMatching.threshold && nearest <= faceMatching.threshold
        }
        var matching = 0
        var allFar = true
        for x in pa {
            if matches(x) { matching += 1 }
            let nearest = anchorsB.map { x.distance(to: $0) }.min() ?? .greatestFiniteMagnitude
            if nearest < faceMatching.differentFaceDistance { allFar = false }
        }
        if matching * 2 > pa.count, let c = Self.centroid(pa), matches(c) { return .same }
        return allFar ? .different : .unknown
    }

    /// Normalised mean of unit prints (nil when empty, mismatched or degenerate).
    static func centroid(_ prints: [FacePrint]) -> FacePrint? {
        guard let n = prints.first?.vector.count, n > 0, prints.allSatisfy({ $0.vector.count == n }) else { return nil }
        var sum = [Float](repeating: 0, count: n)
        for p in prints {
            let v = p.normalized.vector
            for i in 0..<n { sum[i] += v[i] }
        }
        guard sum.contains(where: { $0 != 0 }) else { return nil }
        return FacePrint(vector: sum).normalized
    }

    /// After a placeholder became a real person: distinct quality prints become
    /// anchors when there are enough (other prints are kept only if within
    /// `learnThreshold` of an anchor); otherwise the quality prints wait as a
    /// pending enrolment and the rest are deleted. Returns true when enrolled.
    private func promotePlaceholderPrints(_ id: UUID) -> Bool {
        placeholders.remove(id)
        let set = gallery[id] ?? []
        var chosen: [StoredPrint] = []
        for sp in set where sp.quality && !chosen.contains(where: { $0.print.distance(to: sp.print) < 1e-3 }) { chosen.append(sp) }
        let enrol = chosen.count >= faceMatching.minEnrollPrints
        let promote = enrol ? Array(chosen.prefix(faceMatching.maxAnchorsPerPerson)) : []
        let promoteRows = Set(promote.map(\.row))
        let anchors = promote.map(\.print)
        let drop = set.filter { sp in
            if promoteRows.contains(sp.row) { return false }
            if !enrol { return !sp.quality }
            let near = anchors.map { sp.print.distance(to: $0) }.min() ?? .greatestFiniteMagnitude
            return near > faceMatching.learnThreshold
        }
        let dropRows = Set(drop.map(\.row))
        let ok: Bool? = attempt {
            try db.transaction {
                for r in promoteRows { try db.query("UPDATE face_prints SET anchor = 1 WHERE id = ?;", [.int(r)]) }
                for r in dropRows { try db.query("DELETE FROM face_prints WHERE id = ?;", [.int(r)]) }
            }
            return true
        }
        if ok != nil {
            let kept = set.filter { !dropRows.contains($0.row) }.map { sp -> StoredPrint in
                var sp = sp
                if promoteRows.contains(sp.row) { sp.anchor = true }
                return sp
            }
            gallery[id] = kept.isEmpty ? nil : kept
            if !dropRows.isEmpty { markRemoval() }
        } else {
            rebuildFaceIndex()
        }
        return enrol && ok != nil
    }

    /// Renames a person. A placeholder becomes a real person (its quality prints
    /// become its enrolment, see `confirm`); a real person's old name becomes an alias.
    public func rename(_ rawID: UUID, to name: String) {
        batch {
            let id = resolve(rawID)
            let clean = Self.cleanName(name)
            guard !clean.isEmpty, clean.caseInsensitiveCompare(Self.unknownFriendName) != .orderedSame,
                  let p = person(id), p.name != clean else { return }
            let ok: Bool? = attempt {
                try db.transaction {
                    try db.query("UPDATE people SET name = ?, session = NULL WHERE id = ?;", [.text(clean), .text(id.uuidString)])
                    try db.query("DELETE FROM aliases WHERE person_id = ? AND alias = ? COLLATE NOCASE;", [.text(id.uuidString), .text(clean)])
                    if !p.isPlaceholder, p.name.caseInsensitiveCompare(clean) != .orderedSame {
                        try db.query("INSERT OR IGNORE INTO aliases(person_id, alias) VALUES (?, ?);", [.text(id.uuidString), .text(p.name)])
                    }
                    try capAliases(id)
                }
                return true
            }
            guard ok != nil else { return }
            // The old name row was overwritten.
            if !p.isPlaceholder { markRemoval() }
            if p.isPlaceholder {
                if let session = p.session { sessionOwner[session] = id }
                _ = promotePlaceholderPrints(id)
            }
        }
    }

    /// The ONLY way to give a real person another name.
    public func addAlias(_ alias: String, to rawID: UUID) {
        batch {
            let id = resolve(rawID)
            let clean = Self.cleanName(alias)
            guard !clean.isEmpty, let p = person(id), !p.isPlaceholder, !p.answers(to: clean) else { return }
            _ = attempt {
                try db.transaction {
                    try db.query("INSERT OR IGNORE INTO aliases(person_id, alias) VALUES (?, ?);", [.text(id.uuidString), .text(clean)])
                    try capAliases(id)
                }
            }
        }
    }

    private func capAliases(_ id: UUID) throws {
        try db.query("""
        DELETE FROM aliases WHERE person_id = ?1 AND rowid NOT IN
            (SELECT rowid FROM aliases WHERE person_id = ?1 ORDER BY rowid DESC LIMIT ?2);
        """, [.text(id.uuidString), .int(Int64(Self.maxAliases))])
        if db.changes > 0 { markRemoval() }
    }

    /// Counts a new encounter unless the previous one was under `encounterGap` ago
    /// (then only `lastSeen` moves). Call it as often as you like.
    public func noteEncounter(_ rawID: UUID, at: Date) {
        let id = resolve(rawID)
        guard let p = person(id) else { return }
        let fresh = at.timeIntervalSince(p.lastSeen) >= Self.encounterGap
        guard fresh || at > p.lastSeen else { return }
        _ = attempt {
            try db.query("UPDATE people SET last_seen = MAX(last_seen, ?), encounters = encounters + ? WHERE id = ?;",
                         [.real(at.timeIntervalSince1970), .int(fresh ? 1 : 0), .text(id.uuidString)])
        }
    }

    /// Folds `from` into `into`: facts merged (deduplicated), face prints (anchor
    /// flags kept), aliases (including `from`'s name unless it was a placeholder),
    /// encounter counts and first/last dates combined; `from` is then deleted.
    /// `from`'s id (and session) keep resolving to `into` (see `resolve`).
    public func merge(_ rawFrom: UUID, into rawInto: UUID) {
        batch {
            let from = resolve(rawFrom), into = resolve(rawInto)
            guard from != into, let a = person(from), let b = person(into) else { return }
            let ok: Bool? = attempt {
                try db.transaction {
                    for f in a.facts {
                        _ = try storeFact(f.text, category: f.category, about: into, at: f.updatedAt, confidence: f.confidence, createdAt: f.createdAt)
                    }
                    var names = a.aliases
                    if !a.isPlaceholder { names.insert(a.name, at: 0) }
                    for n in names where n.caseInsensitiveCompare(b.name) != .orderedSame {
                        try db.query("INSERT OR IGNORE INTO aliases(person_id, alias) VALUES (?, ?);", [.text(into.uuidString), .text(n)])
                    }
                    try capAliases(into)
                    try db.query("UPDATE face_prints SET person_id = ? WHERE person_id = ?;", [.text(into.uuidString), .text(from.uuidString)])
                    try db.query("UPDATE people SET first_met = ?, last_seen = ?, encounters = ? WHERE id = ?;", [
                        .real(min(a.firstMet, b.firstMet).timeIntervalSince1970),
                        .real(max(a.lastSeen, b.lastSeen).timeIntervalSince1970),
                        .int(Int64(a.encounters + b.encounters)), .text(into.uuidString),
                    ])
                    try db.query("DELETE FROM people WHERE id = ?;", [.text(from.uuidString)])
                }
                return true
            }
            guard ok != nil else { return }
            placeholders.remove(from)
            redirects[from] = into
            if let session = a.session { sessionOwner[session] = into }
            var moved = gallery[into] ?? []
            moved += gallery[from] ?? []
            moved.sort { $0.row < $1.row }
            gallery[from] = nil
            gallery[into] = moved
            pending[from] = nil
            if streak?.id == from { streak = nil }
            prunePrints(of: into)
            markRemoval()
        }
    }

    /// Deletes one person and everything known about them (and truncates the WAL).
    /// A merged-away id forgets the person it was merged into.
    public func forgetPerson(_ rawID: UUID) {
        batch {
            let id = resolve(rawID)
            _ = attempt { try db.query("DELETE FROM people WHERE id = ?;", [.text(id.uuidString)]) }
            placeholders.remove(id)
            gallery[id] = nil
            pending[id] = nil
            if streak?.id == id { streak = nil }
            redirects = redirects.filter { $0.value != id && $0.key != id }
            sessionOwner = sessionOwner.filter { $0.value != id }
            markRemoval()
        }
    }

    public func forgetEverything() {
        _ = attempt {
            try db.transaction {
                try db.execute("DELETE FROM facts; DELETE FROM face_prints; DELETE FROM aliases; DELETE FROM people;")
            }
            // secure_delete is on; fold the WAL in, shrink the file, then truncate
            // the WAL VACUUM itself just wrote.
            try db.checkpoint()
            try db.execute("VACUUM;")
            try db.checkpoint()
        }
        placeholders = []
        sessionOwner = [:]
        redirects = [:]
        gallery = [:]
        pending = [:]
        streak = nil
        removalPending = false
    }

    /// True when `heard` and one of `p`'s names share their first word and one
    /// is a word-prefix of the other: "John Smith" for John, "John" for John
    /// Smith. "John Doe" for John Smith is NOT the same name.
    static func isFullerName(_ heard: String, of p: Person) -> Bool {
        let h = cleanName(heard).lowercased().split(separator: " ").map(String.init)
        guard !h.isEmpty else { return false }
        for n in [p.name] + p.aliases {
            let w = cleanName(n).lowercased().split(separator: " ").map(String.init)
            guard !w.isEmpty, w != h, w[0] == h[0] else { continue }
            let (short, long) = w.count < h.count ? (w, h) : (h, w)
            if Array(long.prefix(short.count)) == short { return true }
        }
        return false
    }

    static func cleanName(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?\"' "))
    }

    // MARK: - Faces

    /// Adds prints to a person.
    ///
    /// `anchor: true` marks enrolment prints: the caller vouches that each passed
    /// `FaceQualityGate` (e.g. from `FaceEmbedder.enrolmentPrint`). A real person
    /// gets anchors only once they have ≥ `minEnrollPrints` distinct quality prints
    /// in total — fewer wait as a pending enrolment that does not match yet. Anchors
    /// are never trimmed (at most `maxAnchorsPerPerson`; any beyond are ordinary
    /// prints). For a placeholder, quality prints are kept un-anchored until
    /// `confirm` promotes them.
    ///
    /// `passedQualityGate` overrides the quality flag (default: `anchor`), e.g. a
    /// placeholder's capture that passed the gate. Ordinary prints form the
    /// rolling, trimmed set.
    public func addFacePrints(_ prints: [FacePrint], to rawID: UUID, anchor: Bool = false, passedQualityGate: Bool? = nil) {
        batch {
            let id = resolve(rawID)
            let quality = passedQualityGate ?? anchor
            let valid = Self.distinct(prints)
            guard !valid.isEmpty, let p = person(id) else { return }
            let set = gallery[id] ?? []
            let anchorsNow = set.filter(\.anchor).count
            var room = 0
            var promoteRows: [Int64] = []
            if anchor, quality, !p.isPlaceholder {
                room = max(0, faceMatching.maxAnchorsPerPerson - anchorsNow)
                if anchorsNow < faceMatching.minEnrollPrints {
                    // First enrolment: pending quality prints count towards the minimum.
                    let pendingQ = set.filter { $0.quality && !$0.anchor }
                    let pool = Self.distinct(pendingQ.map(\.print) + valid)
                    if anchorsNow + pool.count >= faceMatching.minEnrollPrints {
                        promoteRows = Array(pendingQ.prefix(room).map(\.row))
                        room -= promoteRows.count
                    } else {
                        room = 0
                    }
                }
            }
            let now = Date().timeIntervalSince1970
            var added: [StoredPrint] = []
            let ok: Bool? = attempt {
                try db.transaction {
                    for r in promoteRows { try db.query("UPDATE face_prints SET anchor = 1 WHERE id = ?;", [.int(r)]) }
                    for p in valid {
                        let isAnchor = room > 0
                        if isAnchor { room -= 1 }
                        try db.query("INSERT INTO face_prints(person_id, vector, added_at, anchor) VALUES (?, ?, ?, ?);",
                                     [.text(id.uuidString), .blob(p.blob), .real(now), .int(isAnchor ? 1 : 0)])
                        added.append(StoredPrint(row: db.lastInsertRowID, print: p, anchor: isAnchor, quality: quality))
                    }
                }
                return true
            }
            guard ok != nil else { return }
            let promoted = Set(promoteRows)
            gallery[id] = set.map { sp in
                var sp = sp
                if promoted.contains(sp.row) { sp.anchor = true }
                return sp
            } + added
            prunePrints(of: id)
        }
    }

    private func prunePrints(of id: UUID) {
        guard let set = gallery[id] else { return }
        let anchors = Set(set.indices.filter { set[$0].anchor })
        let drop = FaceMatcher.indicesToDrop(set.map(\.print), keeping: faceMatching.maxPrintsPerPerson, anchors: anchors)
        guard !drop.isEmpty else { return }
        let rows = drop.map { set[$0].row }
        let ok: Bool? = attempt {
            try db.transaction { for r in rows { try db.query("DELETE FROM face_prints WHERE id = ?;", [.int(r)]) } }
            return true
        }
        if ok != nil {
            gallery[id] = set.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
            markRemoval()
        }
    }

    public func facePrintCount(of id: UUID) -> Int { gallery[resolve(id)]?.count ?? 0 }
    public func anchorCount(of id: UUID) -> Int { gallery[resolve(id)]?.filter(\.anchor).count ?? 0 }
    /// The stored prints of one person (oldest first) — for diagnostics and tests.
    public func facePrints(of id: UUID) -> [(print: FacePrint, anchor: Bool)] {
        (gallery[resolve(id)] ?? []).map { ($0.print, $0.anchor) }
    }

    /// Best match for a frame with ONE face, else nil. Learns (see `identifyAll`).
    public func identify(_ print: FacePrint) -> (person: Person, distance: Float)? {
        identifyAll([print], learn: true).first ?? nil
    }

    public func identify(_ print: FacePrint, learn: Bool) -> (person: Person, distance: Float)? {
        identifyAll([print], learn: learn).first ?? nil
    }

    public func identifyAll(_ prints: [FacePrint], learn: Bool = true) -> [(person: Person, distance: Float)?] {
        identifyAll(prints, learn: learn, at: Date())
    }

    /// Identifies all faces of one frame (same order as `prints`). Each person is
    /// assigned to at most one face; unknown or ambiguous faces are nil (the
    /// runner-up is judged by its raw score, even when it fails its anchor check).
    ///
    /// Learning (`learn: true`) happens only when the frame has exactly ONE face,
    /// that face matched the same person for `learnAfterFrames` consecutive
    /// frames each within `learnStreakGap` of the previous one, its mean distance
    /// to that person's closest ANCHOR prints and its nearest anchor are both
    /// within `learnThreshold`, and it is novel (≥ `minNovelty` from every print).
    public func identifyAll(_ prints: [FacePrint], learn: Bool, at now: Date) -> [(person: Person, distance: Float)?] {
        batch {
            let probes = prints.map(\.normalized)
            let assigned = FaceMatcher.assign(probes, among: galleryPrints, anchors: galleryAnchors, tuning: faceMatching)
            if learn {
                if probes.count == 1, let m = assigned[0] {
                    let continues = streak.map { $0.id == m.id && now >= $0.at && now.timeIntervalSince($0.at) <= faceMatching.learnStreakGap } ?? false
                    let frames = continues ? (streak?.frames ?? 0) + 1 : 1
                    streak = (m.id, frames, now)
                    let anchors = galleryAnchors[m.id] ?? []
                    let nearAnchor = anchors.map { probes[0].distance(to: $0) }.min() ?? .greatestFiniteMagnitude
                    let anchorScore = FaceMatcher.score(probes[0], prints: anchors, k: faceMatching.matchNeighbours)
                    if frames >= faceMatching.learnAfterFrames, nearAnchor <= faceMatching.learnThreshold,
                       anchorScore <= faceMatching.learnThreshold,
                       FaceMatcher.isNovel(probes[0], comparedTo: galleryPrints[m.id] ?? [], tuning: faceMatching) {
                        addFacePrints([probes[0]], to: m.id, anchor: false)
                    }
                } else {
                    streak = nil
                }
            }
            return assigned.map { m in m.flatMap { m in person(m.id).map { ($0, m.distance) } } }
        }
    }

    // MARK: - Facts

    /// Stores a fact, merging with what is known:
    /// - same object, opposite feeling ("likes X" vs "dislikes X") → the old one is replaced;
    /// - same single-valued slot (age, home, job, favourite X, marital status…) → updated in place;
    /// - same category and similar words → timestamp refreshed, confidence reinforced,
    ///   the more detailed wording kept.
    /// Returns nil (nothing stored) for an unknown person, empty text, a fact on
    /// the deny-list (hateful, slurs, extremism, violent, drugs, self-referential)
    /// or a self-harm signal ("hates their life"). Sensitivity is decided from
    /// the text, whatever `category` says (`remember(…, category: .work)` of
    /// "is a sex worker" is still sensitive).
    @discardableResult
    public func remember(_ text: String, category: Fact.Category, about id: UUID, at: Date) -> Fact? {
        remember(text, category: category, about: id, at: at, confidence: Self.baseConfidence)
    }

    @discardableResult
    public func remember(_ text: String, category: Fact.Category, about rawID: UUID, at: Date, confidence: Double) -> Fact? {
        batch {
            let id = resolve(rawID)
            let clean = normaliseFactText(text, about: id)
            guard !clean.isEmpty, !FactPolicy.isDenied(clean), !FactPolicy.isDenied(text),
                  !FactPolicy.selfHarm.matches(clean), !FactPolicy.isSelfHarm(text), person(id) != nil else { return nil }
            return attempt { try db.transaction { try storeFact(clean, category: category, about: id, at: at, confidence: confidence, createdAt: at) } }
        }
    }

    private func storeFact(_ text: String, category: Fact.Category, about id: UUID, at: Date, confidence: Double, createdAt: Date) throws -> Fact {
        let existing = try loadFacts(id)
        func update(_ f: Fact, text newText: String, confidence c: Double) throws -> Fact {
            var f = f
            // The old wording is overwritten: it must not linger in the WAL.
            if f.text != newText { markRemoval() }
            f.text = newText
            f.category = category
            f.confidence = min(1, c)
            f.updatedAt = max(f.updatedAt, at)
            f.sensitive = FactSensitivity.isSensitive(newText, category: category)
            try db.query("UPDATE facts SET text = ?, category = ?, confidence = ?, updated_at = ?, sensitive = ? WHERE id = ?;",
                         [.text(f.text), .text(f.category.rawValue), .real(f.confidence), .real(f.updatedAt.timeIntervalSince1970),
                          .int(f.sensitive ? 1 : 0), .text(f.id.uuidString)])
            return f
        }
        if let pol = FactMerge.polarity(text) {
            for f in existing {
                guard let old = FactMerge.polarity(f.text), old.object == pol.object else { continue }
                if old.positive == pol.positive {
                    return try update(f, text: text, confidence: max(f.confidence, confidence) + Self.reinforcement)
                }
                try db.query("DELETE FROM facts WHERE id = ?;", [.text(f.id.uuidString)])
                markRemoval()
            }
        }
        if let slot = FactMerge.slot(text, category: category),
           let f = existing.first(where: { FactMerge.slot($0.text, category: $0.category) == slot }) {
            let same = f.text.caseInsensitiveCompare(text) == .orderedSame
            return try update(f, text: text, confidence: same ? max(f.confidence, confidence) + Self.reinforcement : confidence)
        }
        if let f = existing.first(where: { $0.category == category && FactMerge.similar($0.text, text) }) {
            let keep = text.count >= f.text.count ? text : f.text
            return try update(f, text: keep, confidence: max(f.confidence, confidence) + Self.reinforcement)
        }
        let fact = Fact(text: text, category: category, confidence: min(1, confidence), createdAt: createdAt, updatedAt: at)
        try db.query("INSERT INTO facts(id, person_id, text, category, confidence, created_at, updated_at, sensitive) VALUES (?, ?, ?, ?, ?, ?, ?, ?);", [
            .text(fact.id.uuidString), .text(id.uuidString), .text(fact.text), .text(category.rawValue),
            .real(fact.confidence), .real(fact.createdAt.timeIntervalSince1970), .real(fact.updatedAt.timeIntervalSince1970),
            .int(fact.sensitive ? 1 : 0),
        ])
        return fact
    }

    private func loadFacts(_ id: UUID) throws -> [Fact] {
        try db.query("SELECT * FROM facts WHERE person_id = ? ORDER BY created_at, rowid;", [.text(id.uuidString)]).compactMap(Self.fact(from:))
    }

    /// Third person, no subject, no trailing punctuation: "John likes jazz." → "likes jazz".
    func normaliseFactText(_ text: String, about id: UUID) -> String {
        var t = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .!;,\"'"))
        guard !t.isEmpty else { return t }
        var subjects = ["the user", "user", "they", "he", "she"]
        if let p = person(id), !p.isPlaceholder { subjects = [p.name] + p.aliases + subjects }
        for s in subjects {
            let l = t.lowercased(), ls = s.lowercased()
            if l.hasPrefix(ls + "'s ") { t = "their " + t.dropFirst(s.count + 3); break }
            if l.hasPrefix(ls + " ") {
                t = Self.conjugate(String(t.dropFirst(s.count + 1)))
                break
            }
        }
        if let f = t.first, f.isUppercase, !(t.split(separator: " ").first.map { $0.count > 1 && $0.allSatisfy(\.isUppercase) } ?? false) {
            let firstWord = t.split(separator: " ").first.map(String.init) ?? ""
            if Self.verbStarts.contains(firstWord.lowercased()) { t = f.lowercased() + t.dropFirst() }
        }
        return t
    }

    static let verbStarts: Set<String> = [
        "likes", "loves", "enjoys", "dislikes", "hates", "has", "is", "was", "lives", "works", "studies", "goes",
        "plays", "prefers", "wears", "grew", "moved", "teaches", "owns", "runs", "can't", "doesn't", "birthday",
        "favourite", "favorite", "their", "speaks", "drives", "wants", "needs", "used", "will", "had",
    ]

    /// "like jazz" → "likes jazz", "are a nurse" → "is a nurse" (after a stripped subject).
    static func conjugate(_ t: String) -> String {
        let map = ["like": "likes", "love": "loves", "enjoy": "enjoys", "hate": "hates", "dislike": "dislikes",
                   "have": "has", "are": "is", "live": "lives", "work": "works", "study": "studies", "go": "goes",
                   "play": "plays", "prefer": "prefers", "own": "owns", "don't": "doesn't", "do": "does", "were": "was"]
        var words = t.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = words.first, let rep = map[first.lowercased()] else { return t }
        words[0] = rep
        return words.joined(separator: " ")
    }

    public func forget(factMatching text: String, about id: UUID) -> Bool {
        !forgetFacts(matching: text, about: id).forgotten.isEmpty
    }

    /// Words that carry no meaning in a forget request.
    static let forgetNoise: Set<String> = [
        "forget", "about", "please", "fact", "thing", "stuff", "i", "my", "me", "mine", "that", "what", "you",
        "know", "remember", "said", "told", "in", "at", "on", "by", "from", "do", "does", "not", "any", "anymore",
    ]

    /// Deletes the fact(s) the request clearly means. Matching is on WHOLE words
    /// (lightly stemmed): "dog" never matches inside "hotdog". The query must have
    /// a content word of 3+ letters. One matching fact is deleted; when several
    /// match, only those whose every word the request covers are deleted — if
    /// none is fully covered nothing is deleted and they come back as
    /// `candidates` for the model to confirm. Also understands first-person
    /// phrasings ("that I like jazz"). Truncates the WAL afterwards.
    @discardableResult
    public func forgetFacts(matching text: String, about rawID: UUID) -> ForgetOutcome {
        let id = resolve(rawID)
        let facts = (attempt { try loadFacts(id) }) ?? []
        guard !facts.isEmpty else { return ForgetOutcome() }
        var queries = [normaliseFactText(text, about: id).lowercased()]
        queries += FactExtractor.extract(from: text).map { $0.text.lowercased() }
        // An exact fact text always wins.
        let exact = facts.filter { f in queries.contains { $0 == f.text.lowercased() } }
        var hits: [Fact] = []
        var candidates: [Fact] = []
        if !exact.isEmpty {
            hits = exact
        } else {
            var scored: [(fact: Fact, full: Bool)] = []
            for q in queries {
                let qt = FactMerge.tokens(q).subtracting(Self.forgetNoise)
                guard qt.contains(where: { $0.count >= 3 }) else { continue }
                for f in facts where !scored.contains(where: { $0.fact.id == f.id }) {
                    let ft = FactMerge.tokens(f.text)
                    let shared = qt.intersection(ft)
                    guard !shared.isEmpty, Double(shared.count) / Double(qt.count) >= 0.6 else { continue }
                    scored.append((f, ft.subtracting(Self.forgetNoise).isSubset(of: qt)))
                }
            }
            if scored.count == 1 {
                hits = [scored[0].fact]
            } else if !scored.isEmpty {
                hits = scored.filter(\.full).map(\.fact)
                if hits.isEmpty { candidates = scored.map(\.fact) }
            }
        }
        guard !hits.isEmpty else { return ForgetOutcome(candidates: candidates) }
        return batch { delete(hits).isEmpty ? ForgetOutcome() : ForgetOutcome(forgotten: hits) }
    }

    /// Facts about the person that match a free-text query, best first.
    /// Sensitive facts ARE included (this is what `recall` uses).
    public func search(_ query: String, about rawID: UUID, limit: Int = 8) -> [Fact] {
        let id = resolve(rawID)
        let facts = (attempt { try loadFacts(id) }) ?? []
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let everything: Set<String> = ["", "everything", "all", "anything", "me", "myself", "about me", "what do you know", "what you know"]
        if everything.contains(q) { return Array(ranked(facts, now: Date()).prefix(limit)) }
        return facts.map { ($0, FactMerge.score($0, query: q)) }
            .filter { $0.1 > 0 }
            .sorted { ($0.1, $0.0.confidence, $0.0.updatedAt) > ($1.1, $1.0.confidence, $1.0.updatedAt) }
            .prefix(limit).map(\.0)
    }

    /// Learns from one utterance by `id` (a merged-away id resolves to the
    /// person it became).
    ///
    /// Names are never applied: a name heard becomes `pendingName` (also kept in
    /// `pendingName(for:)`, counting repeats within `nameConfirmWindow`); the app
    /// confirms and calls `confirm`. If the speaker is a known person and the
    /// utterance claims a different name ("I'm Mike…" while Dee thinks it is
    /// John), NOTHING is stored and `differentSpeaker` is set — the face may be
    /// misidentified; switch person and call `learn` again for the right one.
    /// A nickname said with their own name ("I'm Thomas, call me Tom") is only
    /// a `suggestedAlias`. Introductions ("this is Sarah", "meet my friend
    /// Sarah") never count as the speaker's name: they come back in `introduced`.
    ///
    /// Retractions ("my dog died", "I used to like jazz", "I quit my job") delete
    /// the matching facts; "my dog died" with two dogs on record (or "Salt died"
    /// with "cats named Salt and Pepper", which only drops Salt) is resolved by
    /// name, and when it cannot be, nothing is deleted and the facts come back as
    /// `retractionCandidates`. Self-harm statements (`wellbeingConcern`) and
    /// denied content are never stored.
    @discardableResult
    public func learn(from utterance: String, about rawID: UUID, at: Date) -> LearnOutcome {
        batch {
            let id = resolve(rawID)
            guard let p = person(id) else { return LearnOutcome() }
            if FactExtractor.selfHarmSignal(in: utterance) { return LearnOutcome(wellbeingConcern: true) }
            let found = FactExtractor.extract(from: utterance, now: at, calendar: calendar)
            var outcome = LearnOutcome()
            outcome.introduced = FactExtractor.introductions(in: utterance)
            let names = found.compactMap(\.name)
            if let first = names.first {
                if p.isPlaceholder {
                    outcome.pendingName = first
                    outcome.mergeCandidate = person(named: first).flatMap { $0.id == id ? nil : $0.id }
                    notePending(first, for: id, at: at)
                } else {
                    // "I'm John Smith" from John: the same person giving a fuller name.
                    let other = names.filter { !p.answers(to: $0) && !Self.isFullerName($0, of: p) }
                    if other.isEmpty, let full = names.first(where: { !p.answers(to: $0) }) {
                        outcome.suggestedAlias = full
                    }
                    if let n = other.first {
                        if other.count == names.count {
                            // A different name and none of theirs: probably not who
                            // the face says. Store nothing.
                            outcome.pendingName = n
                            outcome.mergeCandidate = person(named: n).flatMap { $0.id == id ? nil : $0.id }
                            outcome.differentSpeaker = true
                            notePending(n, for: id, at: at)
                            return outcome
                        }
                        outcome.suggestedAlias = n
                    }
                }
            }
            for r in found where r.retracts {
                let (gone, ask) = retract(r, about: id)
                outcome.retracted += gone
                for f in ask where !outcome.retractionCandidates.contains(where: { $0.id == f.id }) {
                    outcome.retractionCandidates.append(f)
                }
            }
            for f in found where f.name == nil && !f.retracts {
                if let fact = remember(f.text, category: f.category, about: id, at: at) { outcome.stored.append(fact) }
            }
            return outcome
        }
    }

    static let retractNoise: Set<String> = ["like", "love", "enjoy", "prefer", "adore", "dislike", "hate"]
    static let countWords: Set<String> = ["a", "an", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "some", "my"]

    /// Names listed in a "… named A, B and C" fact, lower-cased.
    static func listedNames(_ text: String) -> [String] {
        let text = " " + text
        guard let r = text.range(of: " named ") else { return [] }
        return String(text[r.upperBound...]).components(separatedBy: ", ")
            .flatMap { $0.components(separatedBy: " and ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// "has a dog named Rex" → "dog"; "has two dogs named …" → "dogs"; "has a mom" → "mom".
    static func livingNoun(_ text: String) -> String? {
        var head = text
        if let r = head.range(of: " named ") { head = String(head[..<r.lowerBound]) }
        let words = head.lowercased().split(separator: " ").map(String.init)
        guard words.first == "has" else { return nil }
        let rest = words.dropFirst().drop { countWords.contains($0) || $0.allSatisfy(\.isNumber) }
        return rest.isEmpty ? nil : rest.joined(separator: " ")
    }

    /// How many animals / people one fact describes.
    static func individuals(_ f: Fact) -> Int {
        let names = listedNames(f.text)
        if !names.isEmpty { return names.count }
        let words = f.text.lowercased().split(separator: " ").map(String.init)
        if words.count >= 2, words[0] == "has" {
            if let n = FactExtractor.parseNumber(words[1]), n > 1 { return n }
            if !["a", "an", "one", "my"].contains(words[1]), let noun = words.last, noun.hasSuffix("s"), !noun.hasSuffix("ss") { return 2 }
        }
        return 1
    }

    /// Deletes (or narrows) the facts a retraction refers to; returns the texts
    /// retracted and, when it is ambiguous, the candidate facts (nothing deleted).
    private func retract(_ r: ExtractedFact, about id: UUID) -> (gone: [String], ask: [Fact]) {
        let facts = (attempt { try loadFacts(id) }) ?? []
        if r.text == "job", r.category == .work {
            let hits = facts.filter { f in
                guard f.category == .work else { return false }
                let s = FactMerge.slot(f.text, category: f.category)
                return s == "job" || s == "employer" || f.text.lowercased() == "works from home"
            }
            return (delete(hits), [])
        }
        let living = r.category == .pet || r.category == .relationship || (r.category == .other && r.text.hasPrefix("named "))
        guard living else {
            let keys = FactMerge.tokens(r.text).subtracting(Self.retractNoise)
            let rPol = FactMerge.polarity(r.text)
            let hits = facts.filter { f in
                guard f.category == r.category else { return false }
                if let rp = rPol, let fp = FactMerge.polarity(f.text) { return rp.object == fp.object && rp.positive == fp.positive }
                return !keys.isEmpty && keys.isSubset(of: FactMerge.tokens(f.text))
            }
            return (delete(hits), [])
        }
        // Pets and people: "my dog died", "my dog Rex died", "Rex died", "my mom passed away".
        let names = Self.listedNames(r.text).map { $0.lowercased() }
        let nounKeys = Self.livingNoun(r.text).map { FactMerge.tokens($0) } ?? []
        let matching = facts.filter { f in
            if r.category == .other {
                guard f.category == .pet || f.category == .relationship else { return false }
            } else if f.category != r.category {
                return false
            }
            let ft = FactMerge.tokens(f.text)
            if !nounKeys.isEmpty, !nounKeys.isSubset(of: ft) { return false }
            if !names.isEmpty {
                let listed = Self.listedNames(f.text).map { $0.lowercased() }
                return names.allSatisfy { listed.contains($0) }
            }
            return true
        }
        guard !matching.isEmpty else { return ([], []) }
        if names.isEmpty {
            // "My dog died": only certain when exactly one dog is on record.
            if matching.count == 1, Self.individuals(matching[0]) <= 1 { return (delete(matching), []) }
            return ([], matching)
        }
        guard matching.count == 1, let f = matching.first else { return ([], matching) }
        let listed = Self.listedNames(f.text)
        let remaining = listed.filter { !names.contains($0.lowercased()) }
        if remaining.isEmpty { return (delete([f]), []) }
        // "Salt died" with "has cats named Salt and Pepper" → "has a cat named Pepper".
        guard let noun = Self.livingNoun(f.text) else { return ([], matching) }
        let removed = listed.filter { names.contains($0.lowercased()) }
        let rebuilt: String
        let gone: String
        if f.category == .pet {
            rebuilt = FactExtractor.petFact(count: nil, animal: noun, names: remaining).text
            gone = FactExtractor.petFact(count: nil, animal: FactExtractor.singularise(noun), names: removed).text
        } else {
            let single = remaining.count == 1 && !Lex.pluralRelations.contains(noun) ? FactExtractor.singularise(noun) : noun
            rebuilt = FactExtractor.relFact(count: nil, rel: single, names: remaining).text
            gone = FactExtractor.relFact(count: nil, rel: FactExtractor.singularise(noun), names: removed).text
        }
        let ok: Bool? = attempt {
            try db.query("UPDATE facts SET text = ?, sensitive = ? WHERE id = ?;",
                         [.text(rebuilt), .int(FactSensitivity.isSensitive(rebuilt, category: f.category) ? 1 : 0), .text(f.id.uuidString)])
            return true
        }
        guard ok != nil else { return ([], []) }
        markRemoval()
        return ([gone], [])
    }

    /// Deletes facts; returns their texts.
    private func delete(_ hits: [Fact]) -> [String] {
        guard !hits.isEmpty else { return [] }
        let ok: Bool? = attempt {
            try db.transaction { for f in hits { try db.query("DELETE FROM facts WHERE id = ?;", [.text(f.id.uuidString)]) } }
            return true
        }
        guard ok != nil else { return [] }
        markRemoval()
        return hits.map(\.text)
    }

    // MARK: - Prompt

    static func tier(_ c: Fact.Category) -> Int {
        switch c {
        case .identity: 0
        case .relationship, .pet: 1
        case .birthday, .work, .place: 2
        case .preference, .dislike, .health: 3
        case .event: 4
        case .other: 5
        }
    }

    /// Ranked facts: identity › relationships/pets › birthday/work/place ›
    /// likes/dislikes/health › events (upcoming soonest first; ones over 2 days
    /// past are dropped) › other. Within a tier: confidence, then most recently updated.
    func ranked(_ facts: [Fact], now: Date) -> [Fact] {
        let today = calendar.startOfDay(for: now)
        let stale = calendar.date(byAdding: .day, value: -2, to: today) ?? today
        let keyed: [(Fact, Int, Double, Date)] = facts.compactMap { f in
            var sub = -f.confidence
            if f.category == .event, let d = DateText.date(in: f.text, calendar) {
                if d < stale { return nil }
                sub = d >= today ? d.timeIntervalSince(today) / 86_400 : 1_000 + today.timeIntervalSince(d) / 86_400
            }
            return (f, Self.tier(f.category), sub, f.updatedAt)
        }
        return keyed.sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if a.2 != b.2 { return a.2 < b.2 }
            return a.3 > b.3
        }.map(\.0)
    }

    /// Most useful facts first, for the persona/system prompt (kept short — 4096
    /// ctx; pass `limit` ≤ 12). Sensitive facts are never included. For a
    /// placeholder only "You don't know their name yet — ask." is returned.
    public func promptMemories(for id: UUID, limit: Int) -> [String] {
        promptMemories(for: id, limit: limit, now: Date())
    }

    public static let askNameLine = "You don't know their name yet — ask."

    public func promptMemories(for id: UUID, limit: Int, now: Date) -> [String] {
        guard limit > 0, let p = person(resolve(id)) else { return [] }
        if p.isPlaceholder { return [Self.askNameLine] }
        var header = "Name: \(p.name)"
        if !p.aliases.isEmpty { header += " (also \(p.aliases.prefix(2).joined(separator: ", ")))" }
        if p.encounters > 1 { header += "; met \(p.encounters) times since \(DateText.monthYear(p.firstMet, calendar))" }
        var lines = [header]
        let nameLower = p.name.lowercased()
        for f in ranked(p.facts.filter { !$0.sensitive }, now: now) where lines.count < limit {
            let l = f.text.lowercased()
            if l == "is called \(nameLower)" || l == "goes by \(nameLower)" { continue }
            lines.append(Self.sentence(subject: p.name, text: f.text))
        }
        return Array(lines.prefix(limit))
    }

    static func sentence(subject: String, text: String, maxLength: Int = 100) -> String {
        let possessive = "\(subject)'s"
        var s: String
        if text.lowercased().hasPrefix("their ") {
            s = possessive + " " + text.dropFirst(6)
        } else if ["birthday ", "favourite ", "favorite ", "last name "].contains(where: { text.lowercased().hasPrefix($0) }) {
            s = possessive + " " + text
        } else {
            s = subject + " " + text
        }
        if s.count > maxLength { s = String(s.prefix(maxLength - 1)) + "…" }
        return s
    }
}
