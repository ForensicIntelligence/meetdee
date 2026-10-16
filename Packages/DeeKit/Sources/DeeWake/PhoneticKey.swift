import Foundation

/// A small Metaphone-style sound key for wake matching.
///
/// Consonant skeleton of the words joined together: vowels dropped except a leading
/// one, voiced/unvoiced pairs merged (D/T, B/P, G/K, V/F, Z/S), common digraphs folded
/// (PH→F, CK→K, SH/CH→X, TH→T, QU→KW, X→KS, soft C→S, soft G→J), H/W/Y kept only
/// before a vowel at a word start (H) or before a vowel (W/Y), doubled letters merged
/// within a word.
///
///     "hey dee" / "heidi" / "haidee" / "hey d" / "hi dee" → HT
///     "kd" → KT, "lady" → LT, "computer" → KMPTR, "hey robo" → HRP, "okay pixel" → OKPKSL
///
/// Two-letter keys collide with ordinary words ("hot", "had", "head" are HT too), so
/// the matcher only compares keys of three or more letters (contract §3 tier d).
public struct PhoneticKey: Sendable, Equatable, Hashable, CustomStringConvertible {
    public let value: String

    public init(_ text: String) {
        value = Self.key(WakeText.words(text))
    }

    init(words: [String]) {
        value = Self.key(words)
    }

    public var description: String { value }

    /// Levenshtein distance between the keys.
    public func distance(to other: PhoneticKey) -> Int { WakeText.levenshtein(value, other.value) }

    static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]

    static func key(_ words: [String]) -> String {
        var out: [Character] = []
        var first = true
        for word in words {
            let letters = Array(word.filter { $0.isLetter })
            var i = 0
            func at(_ k: Int) -> Character? { k >= 0 && k < letters.count ? letters[k] : nil }
            func isVowel(_ k: Int) -> Bool { at(k).map { vowels.contains($0) } ?? false }
            let wordStart = out.count
            // Doubled letters merge inside a word only: "her robe" (HR·RP) stays apart
            // from "hey robo" (H·RP).
            func emit(_ c: Character) {
                if out.count > wordStart, out.last == c { return }
                out.append(c)
            }
            while i < letters.count {
                let c = letters[i]
                let n = at(i + 1)
                var consumed = 1
                switch c {
                case "a", "e", "i", "o", "u":
                    if first && out.isEmpty { emit(Character(c.uppercased())) }
                case "y":
                    if isVowel(i + 1) && n != "y" { emit("Y") } else if first && out.isEmpty && i == 0 { emit("Y") }
                case "w":
                    if n == "h" { if isVowel(i + 2) { emit("W") }; consumed = 2 } else if isVowel(i + 1) { emit("W") }
                case "h":
                    if i == 0 && isVowel(i + 1) { emit("H") }
                case "p":
                    if n == "h" { emit("F"); consumed = 2 } else { emit("P") }
                case "b": emit("P")
                case "c":
                    if n == "k" { emit("K"); consumed = 2 } else if n == "h" { emit("X"); consumed = 2 } else if let n, ["e", "i", "y"].contains(n) { emit("S") } else { emit("K") }
                case "k", "q":
                    if c == "q", n == "u" { emit("K"); emit("W"); consumed = 2 } else { emit("K") }
                case "g":
                    if n == "h" { consumed = 2 } else if let n, ["e", "i", "y"].contains(n) { emit("J") } else { emit("K") }
                case "j": emit("J")
                case "d", "t":
                    if c == "t", n == "h" { consumed = 2 }
                    if c == "d", n == "g" { emit("J"); consumed = 2 } else { emit("T") }
                case "s":
                    if n == "h" { emit("X"); consumed = 2 } else { emit("S") }
                case "z": emit("S")
                case "x": emit("K"); emit("S")
                case "f", "v": emit("F")
                case "l", "m", "n", "r": emit(Character(c.uppercased()))
                default:
                    if c.isLetter { emit(Character(c.uppercased())) }
                }
                i += consumed
            }
            first = false
        }
        return String(out)
    }
}
