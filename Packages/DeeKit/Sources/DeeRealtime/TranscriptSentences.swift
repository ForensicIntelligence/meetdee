import Foundation

/// Splits a streamed assistant transcript into sentences as the deltas arrive.
///
/// A sentence closes at `.`, `!`, `?` or `…` (plus any closing quotes or
/// brackets) once the next non-space character is seen, so "3.5", "e.g. this"
/// and "Mr. Bell" stay whole. `finish()` flushes the remainder when the
/// transcript is done. Pure value type; the session keeps one per item.
public struct TranscriptSentences: Sendable, Equatable {
    private var buffer = ""

    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "st", "jr", "sr", "vs", "etc", "e.g", "i.e", "approx", "mt", "prof",
    ]
    private static let enders: Set<Character> = [".", "!", "?", "…"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]"]

    public init() {}

    /// Appends a delta; returns the sentences it completed.
    public mutating func push(_ delta: String) -> [String] {
        buffer += delta
        var out: [String] = []
        while let cut = nextCut() {
            let sentence = String(buffer[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[cut...])
            if !sentence.isEmpty { out.append(sentence) }
        }
        return out
    }

    /// The unfinished tail as a final sentence (nil if only whitespace).
    public mutating func finish() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    /// Index just past a sentence end that is followed by whitespace and then
    /// a non-space character, or nil.
    private func nextCut() -> String.Index? {
        var i = buffer.startIndex
        while i < buffer.endIndex {
            let ch = buffer[i]
            guard Self.enders.contains(ch) else { i = buffer.index(after: i); continue }
            // Extend over repeated enders ("?!", "...") and closing quotes.
            var end = buffer.index(after: i)
            while end < buffer.endIndex, Self.enders.contains(buffer[end]) || Self.closers.contains(buffer[end]) {
                end = buffer.index(after: end)
            }
            guard end < buffer.endIndex else { return nil }          // need lookahead
            guard buffer[end].isWhitespace else { i = end; continue }  // "3.5", "a.m"
            var next = end
            while next < buffer.endIndex, buffer[next].isWhitespace { next = buffer.index(after: next) }
            guard next < buffer.endIndex else { return nil }          // wait for the next word
            if ch == ".", isAbbreviation(before: i) { i = end; continue }
            return end
        }
        return nil
    }

    private func isAbbreviation(before dot: String.Index) -> Bool {
        var start = dot
        while start > buffer.startIndex {
            let p = buffer.index(before: start)
            if buffer[p].isLetter || buffer[p] == "." { start = p } else { break }
        }
        let word = buffer[start..<dot].lowercased()
        if Self.abbreviations.contains(word) { return true }
        // Single initials ("J. R. R.") are not sentence ends; "I." and "A." are words.
        return word.count == 1 && buffer[start].isUppercase && word != "i" && word != "a"
    }
}
