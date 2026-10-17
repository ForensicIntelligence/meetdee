import Foundation

// DeeSelf — the self-model (SELF.md, binding design for v0.5 "Someone").
//
// One `Moment` (three timescales), one pure reducer (`Cortex`) built from nine small
// sub-reducers, one interpretation of now (`Stance`), and pure projections of it to
// every expressive channel. Pure code in this module never reads the clock, never
// uses global randomness and never creates UUIDs on its own: time arrives as `at now:
// Date`, randomness is the seeded `Rand` threaded through `Cortex`, and ids come from
// `rng.uuid()`. (`SelfStore`, the only impure part, is exempt; a lint test enforces it.)

/// A value that is live until a moment in time.
public struct Timed<Value: Sendable & Equatable>: Sendable, Equatable {
    public var value: Value
    public var until: Date
    public init(_ value: Value, until: Date) {
        self.value = value
        self.until = until
    }
    public func live(at now: Date) -> Value? { now < until ? value : nil }
}

/// Mirrors `DeeSense.CameraSide` (DeeSelf does not depend on DeeSense).
public enum CameraSide: String, Sendable, Equatable, Hashable, Codable, CaseIterable { case front, back }

/// DeeMemory's `Person.id`.
public typealias PersonID = UUID

/// Lexicon-safe subject: at most 4 words and 40 characters, lower-cased, whitespace
/// collapsed. Built from labels, noun lemmas and plan subjects — never free text, so
/// nothing a user said verbatim can be stored through it.
public struct Subject: Sendable, Equatable, Hashable, Codable, Comparable, CustomStringConvertible {
    public let text: String

    public static let maxWords = 4
    public static let maxCharacters = 40
    /// Words that are never a subject on their own.
    public static let stoplist: Set<String> = [
        "a", "an", "the", "it", "this", "that", "these", "those", "thing", "things", "stuff",
        "i", "me", "you", "he", "she", "we", "they", "him", "her", "us", "them", "my", "your",
        "and", "or", "but", "so", "of", "to", "in", "on", "at", "um", "uh", "er", "hmm",
    ]

    /// nil if empty, longer than 4 words or 40 characters, or a lone stop word.
    public init?(_ raw: String) {
        let words = raw.lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0 == "_" })
            .map { $0.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "'-"))) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty, words.count <= Self.maxWords else { return nil }
        if words.count == 1, Self.stoplist.contains(words[0]) { return nil }
        let text = words.joined(separator: " ")
        guard text.count <= Self.maxCharacters else { return nil }
        self.text = text
    }

    public var words: [String] { text.split(separator: " ").map(String.init) }
    public var description: String { text }
    public static func < (a: Subject, b: Subject) -> Bool { a.text < b.text }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let s = Subject(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "not a subject: \(raw.prefix(40))"))
        }
        self = s
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(text)
    }
}

/// SplitMix64: tiny, seedable, `Sendable`, and identical on every platform. The one
/// source of randomness in DeeSelf. (DeeMind's own `Rand` is internal to DeeMind,
/// so DeeSelf carries this public twin with the same algorithm.)
public struct Rand: Sendable, Equatable {
    public private(set) var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in 0..<1.
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

    /// Uniform in `range`.
    public mutating func double(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * unit()
    }

    /// True with probability `p`.
    public mutating func chance(_ p: Double) -> Bool { unit() < p }

    /// Uniform index in 0..<n (n ≥ 1).
    public mutating func index(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }

    /// A deterministic RFC 4122 v4-shaped UUID.
    public mutating func uuid() -> UUID {
        let a = next(), b = next()
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i] = UInt8(truncatingIfNeeded: a >> (8 * UInt64(i))) }
        for i in 0..<8 { bytes[8 + i] = UInt8(truncatingIfNeeded: b >> (8 * UInt64(i))) }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Weighted pick; weights ≤ 0 are never chosen unless all are, then uniform.
    public mutating func weighted(_ weights: [Double]) -> Int {
        let w = weights.map { $0.isFinite ? max(0, $0) : 0 }
        let total = w.reduce(0, +)
        guard total > 0 else { return index(weights.count) }
        var r = unit() * total
        for (i, x) in w.enumerated() {
            r -= x
            if r < 0 { return i }
        }
        return w.lastIndex { $0 > 0 } ?? 0
    }
}

/// Stable 64-bit hash (FNV-1a, then a SplitMix finaliser). Swift's `Hasher` is
/// randomised per process, so anything seeded must use this instead.
public enum StableHash {
    public static func of(_ text: String, seed: UInt64 = 0) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325 ^ seed
        for b in text.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        var r = Rand(seed: h)
        return r.next()
    }

    /// Deterministic value in −1…1 for (seed, text).
    public static func unit(_ text: String, seed: UInt64) -> Double {
        Double(of(text, seed: seed) >> 11) / Double(1 << 53) * 2 - 1
    }
}

@inline(__always) func clamp01(_ x: Double) -> Double { x.isFinite ? min(1, max(0, x)) : 0 }
@inline(__always) func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { x.isFinite ? min(hi, max(lo, x)) : lo }
/// Exponential decay factor for `dt` seconds at half-life `h`.
@inline(__always) func halfLife(_ dt: TimeInterval, _ h: TimeInterval) -> Double { dt <= 0 ? 1 : pow(0.5, dt / h) }

/// One laughter test for every reducer (sound labels from the classifier: "laughter",
/// "belly_laugh", "chuckle_chortle", "snicker", "giggling"…). Review finding 19: five
/// reducers used five different label sets.
public enum Laughter {
    public static let labels: Set<String> = ["laughter", "laugh", "laughing", "baby_laughter", "belly_laugh", "giggle", "giggling",
                                             "chuckle", "chuckling", "chuckle_chortle", "chortle", "snicker", "snickering", "titter"]

    public static func isLaughter(_ label: String) -> Bool {
        let l = label.lowercased()
        return labels.contains(l) || l.contains("laugh") || l.contains("giggl") || l.contains("chuckl") || l.contains("snicker")
            || l.contains("chortl")
    }
}

/// Subjects Dee must never form a taste about, reveal an opinion on, or set Dee a
/// learn / share goal about (review findings 1 and 21): people and relationships,
/// health, death and grief, and a few heavy life events. Whole-word, plural-tolerant.
public enum SensitiveSubjects {
    public static let words: Set<String> = [
        // People and relationships (a third party is never a "taste").
        "mum", "mom", "mother", "mummy", "mommy", "dad", "father", "daddy", "parent", "sister", "brother", "sibling", "son",
        "daughter", "child", "children", "kid", "baby", "grandma", "grandmother", "grandpa", "grandfather", "granny", "nan",
        "nana", "grandparent", "aunt", "auntie", "uncle", "cousin", "niece", "nephew", "wife", "husband", "partner", "spouse",
        "boyfriend", "girlfriend", "ex", "fiance", "fiancee", "family", "friend", "boss", "colleague", "coworker", "co-worker",
        "teacher", "neighbour", "neighbor", "roommate", "flatmate", "stepmom", "stepdad", "in-law", "people", "person",
        // Health.
        "chemo", "chemotherapy", "cancer", "tumour", "tumor", "surgery", "operation", "hospital", "illness", "disease", "sick",
        "diagnosis", "biopsy", "scan", "mri", "x-ray", "therapy", "therapist", "depression", "anxiety", "pain", "injury",
        "medication", "pill", "treatment", "doctor", "doctor's", "dentist", "dentist's", "clinic", "results", "symptom",
        "pregnancy", "miscarriage", "disability", "rehab", "addiction",
        // Death and grief.
        "funeral", "death", "dead", "died", "dying", "grave", "grief", "loss", "cemetery", "memorial", "burial", "suicide",
        // Heavy life events.
        "divorce", "breakup", "break-up", "separation", "custody", "court", "hearing", "lawyer", "trial", "abuse", "debt",
        "eviction", "redundancy", "layoff", "unemployment",
    ]

    public static func contains(_ s: Subject) -> Bool {
        s.words.contains { w in
            let bare = w.hasSuffix("'s") ? String(w.dropLast(2)) : w
            return words.contains(bare) || words.contains { Subject.same(bare, $0) }
        }
    }
}
