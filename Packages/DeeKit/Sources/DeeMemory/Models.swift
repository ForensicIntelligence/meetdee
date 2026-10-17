import Foundation

/// A face feature vector (Vision `GenerateImageFeaturePrintRequest`, revision 2).
/// Vectors are stored L2-normalised, so `distance` is the Euclidean (L2) distance
/// Vision itself reports for revision-2 prints: 0 = identical, √2 ≈ 1.41 =
/// orthogonal, 2 = opposite. (For unit vectors d² = 2 − 2·cosine.)
public struct FacePrint: Sendable, Equatable, Codable {
    public var vector: [Float]

    public init(vector: [Float]) {
        self.vector = vector
    }

    /// Euclidean distance after L2 normalisation of both vectors. Mismatched lengths
    /// or empty / all-zero vectors are "infinitely" far (`.greatestFiniteMagnitude`).
    public func distance(to other: FacePrint) -> Float {
        let a = vector, b = other.vector
        guard a.count == b.count, !a.isEmpty else { return .greatestFiniteMagnitude }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return .greatestFiniteMagnitude }
        let cosine = max(-1, min(1, dot / (na.squareRoot() * nb.squareRoot())))
        return max(0, 2 - 2 * cosine).squareRoot()
    }

    /// The same print scaled to unit length (no-op for an all-zero vector).
    public var normalized: FacePrint {
        let n = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard n > 0 else { return self }
        return FacePrint(vector: vector.map { $0 / n })
    }

    /// Little-endian Float32 bytes, for the `face_prints.vector` BLOB.
    var blob: Data {
        var d = Data(capacity: vector.count * 4)
        for f in vector {
            var bits = f.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { d.append(contentsOf: $0) }
        }
        return d
    }

    init?(blob: Data) {
        guard blob.count % 4 == 0, !blob.isEmpty else { return nil }
        var v = [Float]()
        v.reserveCapacity(blob.count / 4)
        let bytes = [UInt8](blob)
        var i = 0
        while i < bytes.count {
            let bits = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
            v.append(Float(bitPattern: bits))
            i += 4
        }
        self.vector = v
    }
}

public struct Fact: Sendable, Equatable, Codable, Identifiable {
    public enum Category: String, Sendable, Codable, CaseIterable {
        case identity, preference, dislike, relationship, pet, work, place, health, event, birthday, other
    }

    public var id: UUID
    /// Third person without a subject, e.g. "likes jazz", "has a dog named Miso".
    public var text: String
    public var category: Category
    public var confidence: Double
    public var createdAt: Date
    public var updatedAt: Date
    /// Health conditions, religion, sexuality, politics…: kept for `recall` only and
    /// never put into the system prompt (`promptMemories`), where Dee might bring
    /// them up in front of other people. Set by `FactSensitivity` on every write.
    public var sensitive: Bool

    public init(id: UUID = UUID(), text: String, category: Category, confidence: Double = 0.8, createdAt: Date, updatedAt: Date? = nil, sensitive: Bool? = nil) {
        self.id = id
        self.text = text
        self.category = category
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.sensitive = sensitive ?? FactSensitivity.isSensitive(text, category: category)
    }

    enum CodingKeys: String, CodingKey { case id, text, category, confidence, createdAt, updatedAt, sensitive }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        category = try c.decode(Category.self, forKey: .category)
        confidence = try c.decode(Double.self, forKey: .confidence)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        sensitive = try c.decodeIfPresent(Bool.self, forKey: .sensitive) ?? FactSensitivity.isSensitive(text, category: category)
    }
}

public struct Person: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var aliases: [String]
    public var firstMet: Date
    public var lastSeen: Date
    public var encounters: Int
    public var facts: [Fact]
    /// For a placeholder: the conversation session (or unrecognised face) it belongs
    /// to. Placeholders are never shared between sessions.
    public var session: UUID?

    public init(id: UUID = UUID(), name: String, aliases: [String] = [], firstMet: Date, lastSeen: Date, encounters: Int = 1, facts: [Fact] = [], session: UUID? = nil) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.firstMet = firstMet
        self.lastSeen = lastSeen
        self.encounters = encounters
        self.facts = facts
        self.session = session
    }

    /// True for an "unknown friend" placeholder: someone Dee is talking to whose
    /// name Dee does not know yet (one per session / unrecognised face).
    public var isPlaceholder: Bool { name == MemoryStore.unknownFriendName }

    /// Case-insensitive match against the name and every alias.
    public func answers(to name: String) -> Bool {
        let n = MemoryStore.cleanName(name)
        guard !n.isEmpty else { return false }
        return ([self.name] + aliases).contains { $0.caseInsensitiveCompare(n) == .orderedSame }
    }
}

public struct ExtractedFact: Sendable, Equatable {
    public var text: String
    public var category: Fact.Category
    /// Set for self-introductions ("I'm John", "call me Johnny"). Never applied
    /// directly: `MemoryStore.learn` turns it into a pending name.
    public var name: String?
    /// "My dog died", "I used to like jazz", "I don't live in Toronto anymore":
    /// `text` describes what is no longer true; the store deletes matching facts.
    public var retracts: Bool

    public init(text: String, category: Fact.Category, name: String? = nil, retracts: Bool = false) {
        self.text = text
        self.category = category
        self.name = name
        self.retracts = retracts
    }
}

/// What `MemoryStore.learn(from:about:at:)` did with one utterance.
public struct LearnOutcome: Sendable, Equatable {
    /// Facts written (new or merged), as stored.
    public var stored: [Fact]
    /// A name that was heard but NOT applied. Confirm it (ask, hear it again within
    /// `MemoryStore.nameConfirmWindow`, or exactly one face visible) and then call
    /// `confirmName(_:for:)`. When it contradicts a known person's name nothing at
    /// all was stored: the face may be misidentified — switch person first.
    public var pendingName: String?
    /// An existing (non-placeholder) person already called `pendingName`.
    public var mergeCandidate: UUID?
    /// Texts of facts deleted because the utterance said they are no longer true.
    public var retracted: [String]
    /// A retraction matched several facts (or one fact about several animals /
    /// people, e.g. "my dog died" with Rex and Max): nothing was deleted — ask which.
    public var retractionCandidates: [Fact]
    /// The speaker is a known person who claimed a name that is not theirs
    /// ("I'm Mike" while the face says John): probably someone else is speaking.
    /// Nothing was stored. Switch person; `confirm` will never alias it.
    public var differentSpeaker: Bool
    /// A nickname heard together with the person's own name ("I'm Thomas but
    /// everyone calls me Tom"). Not applied: call `addAlias` once confirmed.
    public var suggestedAlias: String?
    /// People the speaker introduced ("this is Sarah", "meet my friend Sarah").
    public var introduced: [String]
    /// The utterance was a self-harm / wellbeing signal: nothing was stored.
    public var wellbeingConcern: Bool

    public init(stored: [Fact] = [], pendingName: String? = nil, mergeCandidate: UUID? = nil, retracted: [String] = [],
                retractionCandidates: [Fact] = [], differentSpeaker: Bool = false, suggestedAlias: String? = nil,
                introduced: [String] = [], wellbeingConcern: Bool = false) {
        self.stored = stored
        self.pendingName = pendingName
        self.mergeCandidate = mergeCandidate
        self.retracted = retracted
        self.retractionCandidates = retractionCandidates
        self.differentSpeaker = differentSpeaker
        self.suggestedAlias = suggestedAlias
        self.introduced = introduced
        self.wellbeingConcern = wellbeingConcern
    }
}

/// What `MemoryStore.confirm(_:for:at:choice:)` did with a confirmed name.
public enum ConfirmResult: Sendable, Equatable {
    /// The placeholder is now a real person with this name, or `id` was already a
    /// person answering to it. `needsEnrolment`: they have fewer than
    /// `FaceMatching.minEnrollPrints` anchors (too few quality prints were seen),
    /// so they cannot be recognised by face yet — add ≥ 3 quality prints with
    /// `addFacePrints(_:to:anchor: true)` / `enroll`.
    case named(Person, needsEnrolment: Bool)
    /// The placeholder was the same face as an existing person of that name and
    /// was merged into them; this is that person.
    case merged(into: Person)
    /// A person of that name exists but the store cannot tell whether this is
    /// them (one or both have no face, or the faces are neither clearly the same
    /// nor clearly different). NOTHING changed: ask ("Are you the John I met in
    /// March?"), then call `confirm` again with `.sameAs(existing.id)` or `.newPerson`.
    case mergeCandidate(placeholder: Person, existing: Person)
    /// `id` is a known person and the name is not theirs: a different person is
    /// probably speaking (the face was misidentified). NOTHING changed and no
    /// alias was added (aliases only via `addAlias`). `candidate` is a real person
    /// already called `heard`, if any — switch to them or to a placeholder.
    case differentSpeaker(current: Person, heard: String, candidate: Person?)
    /// Unknown id or unusable name.
    case rejected

    /// The person to talk to now (`current` for `differentSpeaker`, the untouched
    /// placeholder for `mergeCandidate`), nil for `rejected`.
    public var person: Person? {
        switch self {
        case .named(let p, _): p
        case .merged(let p): p
        case .mergeCandidate(let p, _): p
        case .differentSpeaker(let p, _, _): p
        case .rejected: nil
        }
    }
}

/// How `confirm` treats an existing real person with the confirmed name.
public enum SameNameChoice: Sendable, Equatable {
    /// Merge only when the faces clearly match; separate when they clearly
    /// differ; otherwise return `.mergeCandidate` and change nothing.
    case ask
    /// The app confirmed this is that person: merge the placeholder into them.
    case sameAs(UUID)
    /// The app confirmed it is someone new: never merge.
    case newPerson
}

/// What `MemoryStore.forgetFacts(matching:about:)` did.
public struct ForgetOutcome: Sendable, Equatable {
    /// Facts actually deleted.
    public var forgotten: [Fact]
    /// Several facts matched only partly, so nothing was deleted: ask which one
    /// and call again with its exact text.
    public var candidates: [Fact]

    public init(forgotten: [Fact] = [], candidates: [Fact] = []) {
        self.forgotten = forgotten
        self.candidates = candidates
    }
}

/// Tunables for face identification. Defaults are for Vision revision-2 feature
/// prints of a ~25 %-expanded, upright, padded face crop. Vision's generic feature
/// print is not a dedicated face-recognition model, so calibrate on device: log
/// same-person and different-person distances and set `threshold` between them.
public struct FaceMatching: Sendable, Equatable {
    /// A person matches only when their score (mean of the `matchNeighbours`
    /// closest prints) AND their nearest enrolment (anchor) print are at most
    /// this far away. The anchor gate bounds drift: nothing further than
    /// `threshold` from what was enrolled can ever match.
    public var threshold: Float = 0.62
    /// A new print may be learnt only when it is at most this far from one of the
    /// person's ANCHOR prints (never relative to a previously learnt print).
    public var learnThreshold: Float = 0.45
    /// The winner must beat the runner-up *person* by at least this much,
    /// otherwise identification is ambiguous and returns nil. 0.08 until the
    /// thresholds have been calibrated on a device.
    public var ambiguityMargin: Float = 0.08
    /// A confident print is only added if it is at least this far from every
    /// print already stored for that person (keeps the set diverse).
    public var minNovelty: Float = 0.12
    /// Rolling set size per person (anchors + learnt prints).
    public var maxPrintsPerPerson: Int = 12
    /// Enrolment (anchor) prints kept per person; never trimmed.
    public var maxAnchorsPerPerson: Int = 6
    /// A person's score is the mean distance to this many of their closest prints
    /// (fewer when they have fewer prints).
    public var matchNeighbours: Int = 2
    /// Learning happens only after this many consecutive single-face frames
    /// agreed on the same person.
    public var learnAfterFrames: Int = 3
    /// `enroll` needs at least this many distinct prints (from different frames,
    /// each passing `FaceQualityGate`).
    public var minEnrollPrints: Int = 3
    /// `confirm` treats a placeholder whose prints are all at least this far from
    /// a same-named person's anchors as a DIFFERENT person (unrelated faces sit
    /// near √2 ≈ 1.41). It merges only within `threshold` (score and nearest
    /// anchor, as identification does); in between it asks (`.mergeCandidate`).
    public var differentFaceDistance: Float = 0.9
    /// The `learnAfterFrames` agreeing frames must each follow the previous one
    /// within this many seconds, or the streak restarts.
    public var learnStreakGap: TimeInterval = 2

    public init() {}
}

/// Pure face-matching logic (separate from the store so it can be unit-tested).
public enum FaceMatcher {
    /// Mean distance from `probe` to the `k` closest of `prints` (∞ when empty).
    public static func score(_ probe: FacePrint, prints: [FacePrint], k: Int) -> Float {
        guard !prints.isEmpty else { return .greatestFiniteMagnitude }
        let d = prints.map { probe.distance(to: $0) }.sorted()
        let n = max(1, min(k, d.count))
        return d.prefix(n).reduce(0, +) / Float(n)
    }

    /// Every person for one probe, best raw score first: (id, score, eligible),
    /// where `eligible` means their nearest anchor is within `threshold` too.
    static func ranked(_ probe: FacePrint, among gallery: [UUID: [FacePrint]], anchors: [UUID: [FacePrint]], tuning: FaceMatching) -> [(id: UUID, score: Float, eligible: Bool)] {
        var out: [(id: UUID, score: Float, eligible: Bool)] = []
        for (id, prints) in gallery {
            let s = score(probe, prints: prints, k: tuning.matchNeighbours)
            let a = anchors[id] ?? []
            let nearestAnchor = (a.isEmpty ? prints : a).map { probe.distance(to: $0) }.min() ?? .greatestFiniteMagnitude
            out.append((id, s, nearestAnchor <= tuning.threshold))
        }
        out.sort { $0.score < $1.score }
        return out
    }

    /// Best person for one probe (all prints treated as anchors).
    public static func best(_ probe: FacePrint, among gallery: [UUID: [FacePrint]], tuning: FaceMatching = FaceMatching()) -> (id: UUID, distance: Float)? {
        best(probe, among: gallery, anchors: gallery, tuning: tuning)
    }

    /// Best person whose score is under `tuning.threshold` (and whose nearest
    /// anchor is too), provided the runner-up is at least `ambiguityMargin` worse.
    public static func best(_ probe: FacePrint, among gallery: [UUID: [FacePrint]], anchors: [UUID: [FacePrint]], tuning: FaceMatching = FaceMatching()) -> (id: UUID, distance: Float)? {
        assign([probe], among: gallery, anchors: anchors, tuning: tuning).first ?? nil
    }

    /// Identifies every face of one frame at once: each person is assigned to at
    /// most one face (closest pairs first); ambiguous faces get nil.
    public static func assign(_ probes: [FacePrint], among gallery: [UUID: [FacePrint]], anchors: [UUID: [FacePrint]], tuning: FaceMatching = FaceMatching()) -> [(id: UUID, distance: Float)?] {
        var pairs: [(probe: Int, id: UUID, d: Float)] = []
        for (i, probe) in probes.enumerated() {
            let r = ranked(probe, among: gallery, anchors: anchors, tuning: tuning)
            guard let first = r.first(where: \.eligible), first.score <= tuning.threshold else { continue }
            // Ambiguity is judged against the real runner-up by raw score, even one
            // that fails its own anchor check.
            if r.contains(where: { $0.id != first.id && $0.score - first.score < tuning.ambiguityMargin }) { continue }
            for c in r where c.eligible && c.score <= tuning.threshold { pairs.append((i, c.id, c.score)) }
        }
        pairs.sort { $0.d < $1.d }
        var result = [(id: UUID, distance: Float)?](repeating: nil, count: probes.count)
        var taken = Set<UUID>()
        var done = Set<Int>()
        for p in pairs where !taken.contains(p.id) && !done.contains(p.probe) {
            // Only a probe's own best candidate may be used: a face whose best
            // person was taken by a closer face stays unknown rather than being
            // pushed onto a worse match.
            let own = pairs.filter { $0.probe == p.probe }.min { $0.d < $1.d }
            guard own?.id == p.id else { continue }
            result[p.probe] = (p.id, p.d)
            taken.insert(p.id)
            done.insert(p.probe)
        }
        return result
    }

    /// Whether `probe` adds information to `prints` (far enough from all of them).
    public static func isNovel(_ probe: FacePrint, comparedTo prints: [FacePrint], tuning: FaceMatching = FaceMatching()) -> Bool {
        guard let nearest = prints.map({ probe.distance(to: $0) }).min() else { return true }
        return nearest >= tuning.minNovelty
    }

    /// Indices (into `prints`, oldest first) to drop so at most `max` remain:
    /// repeatedly finds the closest pair and drops its OLDER non-anchor member —
    /// the set stays diverse and slowly follows changes in appearance, while
    /// enrolment (anchor) prints are never dropped.
    public static func indicesToDrop(_ prints: [FacePrint], keeping max: Int, anchors: Set<Int> = []) -> [Int] {
        guard max >= 0, prints.count > max else { return [] }
        var alive = Array(prints.indices)
        var dropped: [Int] = []
        while alive.count > max {
            let droppable = alive.filter { !anchors.contains($0) }
            if droppable.isEmpty { break }
            if alive.count < 2 { dropped.append(alive.removeFirst()); continue }
            var bestPair: (Int, Int)?
            var bestD = Float.greatestFiniteMagnitude
            for i in 0..<alive.count {
                for j in (i + 1)..<alive.count {
                    let a = alive[i], b = alive[j]
                    if anchors.contains(a) && anchors.contains(b) { continue }
                    let d = prints[a].distance(to: prints[b])
                    if d < bestD { bestD = d; bestPair = (i, j) }
                }
            }
            guard let (i, j) = bestPair else { break }
            // alive is in insertion order, so index i is the older one — unless it is an anchor.
            let victim = anchors.contains(alive[i]) ? j : i
            dropped.append(alive.remove(at: victim))
        }
        return dropped.sorted()
    }
}
