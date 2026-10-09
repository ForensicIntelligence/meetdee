import Foundation

/// Dee's state as one decodable value: 26 bytes, written as 52 hex characters.
///
/// Layout (fixed — append-only if parameters are ever added, with a new version):
///
///     bytes  0…12  personality, in `Trait.allCases` order
///                  openness, conscientiousness, extraversion, agreeableness,
///                  neuroticism, playfulness, curiosity, patience, confidence,
///                  sensitivity, humor, assertiveness, forgiveness
///     bytes 13…25  feelings, in `Feeling.allCases` order
///                  joy, sadness, anger, fear, surprise, interest, boredom,
///                  affection, trust, loneliness, energy, gratitude, resentment
///
/// Each byte is the parameter scaled 0…255 (0.0 → 00, 1.0 → FF). Everything Dee
/// shows the world — eye colour, expression, the mood cue the language model reads
/// — is computed from the *decoded* code, so a code fully determines behaviour.
public struct MindCode: Equatable, Hashable, Sendable, CustomStringConvertible, Codable {
    public static let parameterCount = Trait.allCases.count + Feeling.allCases.count   // 26
    public private(set) var bytes: [UInt8]

    public init(personality: Personality, feelings: Feelings) {
        bytes = Trait.allCases.map { Self.quantize(personality[$0]) }
            + Feeling.allCases.map { Self.quantize(feelings[$0]) }
    }

    /// Parses 52 hex characters (case-insensitive; spaces and dashes ignored).
    public init?(hex: String) {
        let clean = hex.filter { !$0.isWhitespace && $0 != "-" }
        // Only hex digits: `UInt8(_:radix:)` alone would also accept a "+" sign.
        guard clean.count == Self.parameterCount * 2, clean.allSatisfy(\.isHexDigit) else { return nil }
        var out: [UInt8] = []
        var i = clean.startIndex
        while i < clean.endIndex {
            let j = clean.index(i, offsetBy: 2)
            guard let b = UInt8(clean[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        bytes = out
    }

    public var hex: String { bytes.map { String(format: "%02X", $0) }.joined() }
    public var description: String { hex }

    /// Grouped for humans: personality · feelings.
    public var display: String {
        let t = bytes[0..<Trait.allCases.count].map { String(format: "%02X", $0) }.joined()
        let f = bytes[Trait.allCases.count...].map { String(format: "%02X", $0) }.joined()
        return "\(t)·\(f)"
    }

    public var personality: Personality {
        var p = Personality()
        for (i, t) in Trait.allCases.enumerated() { p[t] = Double(bytes[i]) / 255 }
        return p
    }

    public var feelings: Feelings {
        var f = Feelings()
        let offset = Trait.allCases.count
        for (i, feeling) in Feeling.allCases.enumerated() { f[feeling] = Double(bytes[offset + i]) / 255 }
        return f
    }

    public subscript(_ t: Trait) -> UInt8 { bytes[Trait.allCases.firstIndex(of: t)!] }
    public subscript(_ f: Feeling) -> UInt8 { bytes[Trait.allCases.count + Feeling.allCases.firstIndex(of: f)!] }

    static func quantize(_ v: Double) -> UInt8 { UInt8((min(1, max(0, v)) * 255).rounded()) }
}
