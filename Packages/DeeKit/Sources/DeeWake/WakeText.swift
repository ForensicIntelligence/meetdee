import Foundation

/// Text normalisation shared by the phrase rules, the matcher and the phonetic key.
///
/// Lower case, diacritics folded, curly apostrophes folded and then dropped
/// ("Dee's" → "dees"), every other non-letter/digit a word break, so dotted letters
/// split ("K.D." → "k d"). "ok" / "o k" become "okay" so "OK Pixel" and "Okay Pixel"
/// are the same words.
enum WakeText {
    /// A word of the original text with its range there (for `stripLeading`).
    struct Token: Sendable, Equatable {
        var word: String
        var range: Range<String.Index>
    }

    static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var current = ""
        var start: String.Index?
        var i = text.startIndex
        func flush(_ end: String.Index) {
            if let s = start, !current.isEmpty { result.append(Token(word: current, range: s..<end)) }
            current = ""
            start = nil
        }
        while i < text.endIndex {
            let ch = text[i]
            if ch == "'" || ch == "’" || ch == "‘" {
                // Apostrophes inside a word are dropped, never a break ("dee's" → "dees").
                i = text.index(after: i)
                continue
            }
            let folded = String(ch).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US")).lowercased()
            if folded.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) && !folded.isEmpty {
                if start == nil { start = i }
                current += folded
            } else {
                flush(i)
            }
            i = text.index(after: i)
        }
        flush(text.endIndex)
        return canonical(result)
    }

    /// "ok" → "okay"; "o k" → "okay" (dotted "O.K.").
    private static func canonical(_ tokens: [Token]) -> [Token] {
        var out: [Token] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t.word == "ok" {
                out.append(Token(word: "okay", range: t.range))
            } else if t.word == "o", i + 1 < tokens.count, tokens[i + 1].word == "k" {
                out.append(Token(word: "okay", range: t.range.lowerBound..<tokens[i + 1].range.upperBound))
                i += 1
            } else {
                out.append(t)
            }
            i += 1
        }
        return out
    }

    static func words(_ text: String) -> [String] { tokens(text).map(\.word) }

    /// Per token: punctuation (or the text edge) right before / after it.
    struct Breaks: Sendable, Equatable { var before: Bool; var after: Bool }

    static let breakCharacters: Set<Character> = [",", ".", "!", "?", ";", ":", "—", "–", "…"]

    static func breaks(_ text: String, _ tokens: [Token]) -> [Breaks] {
        tokens.indices.map { i in
            let lo = i == 0 ? text.startIndex : tokens[i - 1].range.upperBound
            let hi = i + 1 < tokens.count ? tokens[i + 1].range.lowerBound : text.endIndex
            let before = i == 0 || text[lo..<tokens[i].range.lowerBound].contains { breakCharacters.contains($0) }
            let after = i + 1 == tokens.count || text[tokens[i].range.upperBound..<hi].contains { breakCharacters.contains($0) }
            return Breaks(before: before, after: after)
        }
    }

    /// Levenshtein distance over characters.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[y.count]
    }
}
