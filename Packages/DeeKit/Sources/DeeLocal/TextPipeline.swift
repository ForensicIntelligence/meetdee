import Foundation
import DeeRealtime

/// Streaming removal of hidden reasoning from chat content (contract T1).
///
/// Rules (measured on Ollama /v1 + qwen3.8, prov-map-local):
/// (a) `<think>…</think>` blocks are dropped, also when split across chunks;
/// (b) a `</think>` before any text was let through drops everything before it;
/// (c) a `</think>` after text was let through ends the response there (the
///     text already out is a whole answer; what follows repeats it);
/// (d) leading blank lines are trimmed.
public struct ThinkStripper: Sendable, Equatable {
    public enum Output: Sendable, Equatable {
        case text(String)
        /// Stop generating: everything after this is hidden or a repeat.
        case end
    }

    private var pending = ""          // held: may be the start of a tag, or text before the first emit
    private var inThink = false
    private var emittedAny = false
    private var ended = false

    static let open = "<think>"
    static let close = "</think>"

    public init() {}

    public var hasEnded: Bool { ended }

    public mutating func push(_ chunk: String) -> [Output] {
        guard !ended else { return [] }
        pending += chunk
        var out: [Output] = []
        while !ended {
            if inThink {
                if let r = pending.range(of: Self.close) {
                    pending = String(pending[r.upperBound...])
                    inThink = false
                    continue
                }
                // Keep only a possible partial close tag.
                pending = Self.partialSuffix(of: pending, tag: Self.close)
                break
            }
            let openR = pending.range(of: Self.open)
            let closeR = pending.range(of: Self.close)
            if let c = closeR, openR == nil || c.lowerBound < openR!.lowerBound {
                let before = String(pending[..<c.lowerBound])
                pending = String(pending[c.upperBound...])
                if emittedAny {
                    // (c)
                    ended = true
                    out.append(.end)
                    pending = ""
                    break
                }
                // (b): nothing out yet → whatever came before was reasoning.
                _ = before
                continue
            }
            if let o = openR {
                let before = String(pending[..<o.lowerBound])
                pending = String(pending[o.upperBound...])
                emit(before, into: &out)
                inThink = true
                continue
            }
            // No tag: emit all but a possible partial tag at the end.
            let keepOpen = Self.partialSuffix(of: pending, tag: Self.open)
            let keepClose = Self.partialSuffix(of: pending, tag: Self.close)
            let keep = keepOpen.count >= keepClose.count ? keepOpen : keepClose
            let cut = pending.index(pending.endIndex, offsetBy: -keep.count)
            emit(String(pending[..<cut]), into: &out)
            pending = keep
            break
        }
        return out
    }

    /// End of stream: an unclosed `<think>` is dropped; a held partial tag is text.
    public mutating func finish() -> [Output] {
        guard !ended else { return [] }
        var out: [Output] = []
        if !inThink { emit(pending, into: &out) }
        pending = ""
        return out
    }

    private mutating func emit(_ s: String, into out: inout [Output]) {
        var s = s
        if !emittedAny {
            // (d)
            s = String(s.drop(while: { $0.isWhitespace }))
        }
        guard !s.isEmpty else { return }
        emittedAny = true
        out.append(.text(s))
    }

    static func isBlank(_ s: String) -> Bool { s.allSatisfy(\.isWhitespace) }

    /// The longest suffix of `s` that is a proper prefix of `tag`.
    static func partialSuffix(of s: String, tag: String) -> String {
        let maxLen = min(s.count, tag.count - 1)
        guard maxLen > 0 else { return "" }
        for len in stride(from: maxLen, through: 1, by: -1) {
            let suffix = String(s.suffix(len))
            if tag.hasPrefix(suffix) { return suffix }
        }
        return ""
    }
}

/// Makes model text speakable: no markdown, no emoji, no stage directions, no speaker label (T1).
public enum SpeechCleaner {
    public static func clean(_ text: String) -> String {
        var s = text
        // Links [text](url) → text.
        s = s.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        // Code fences and inline code markers.
        s = s.replacingOccurrences(of: "```", with: "")
        s = s.replacingOccurrences(of: "`", with: "")
        // Bold / strike markers keep their words.
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "__", with: "")
        s = s.replacingOccurrences(of: "~~", with: "")
        // *giggles* / *tilts head*: a short single-asterisk span is a stage direction, never said.
        s = s.replacingOccurrences(of: #"\*[^*\n]{1,40}\*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "*", with: "")
        // Headings and bullets at line starts.
        s = s.replacingOccurrences(of: #"(?m)^\s{0,3}#{1,6}\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?m)^\s*[-•]\s+"#, with: "", options: .regularExpression)
        // Speaker label.
        s = s.replacingOccurrences(of: #"^\s*(Dee|DEE|Assistant)\s*:\s*"#, with: "", options: .regularExpression)
        s = removeEmoji(s)
        // Whitespace.
        s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+([,.!?…])"#, with: "$1", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    public static func removeEmoji(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            let p = u.properties
            let isPictograph = p.isEmojiPresentation || (p.isEmoji && u.value > 0x238C)
            if isPictograph { continue }
            if u.value == 0xFE0F || u.value == 0xFE0E || u.value == 0x200D { continue }   // selectors, ZWJ
            if (0x1F3FB...0x1F3FF).contains(u.value) { continue }                       // skin tones
            out.append(u)
        }
        return String(out)
    }
}

/// Cuts streamed text into TTS chunks: whole sentences (the same rule as the session's
/// `TranscriptSentences`: `.`/`!`/`?`/`…` plus closers, followed by whitespace and a next word;
/// "3.5", "Mr. Bell" and initials stay whole), except that the first chunk may end at a comma after
/// at least four words so the first audio starts sooner. Long runs without punctuation are cut at a space.
public struct SentenceChunker: Sendable, Equatable {
    private var head = ""
    private var emittedFirst = false
    public var firstClauseMinWords = 4
    public var maxChunkCharacters = 220

    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "st", "jr", "sr", "vs", "etc", "e.g", "i.e", "approx", "mt", "prof",
    ]
    private static let enders: Set<Character> = [".", "!", "?", "…"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]"]

    public init() {}

    public mutating func push(_ text: String) -> [String] {
        head += text
        var out: [String] = []
        while true {
            if let cut = nextCut() {
                emit(upTo: cut, into: &out)
                continue
            }
            if !emittedFirst, let cut = earlyClauseCut() {
                emit(upTo: cut, into: &out)
                continue
            }
            if head.count > maxChunkCharacters,
               let cut = head[..<head.index(head.startIndex, offsetBy: maxChunkCharacters)].lastIndex(of: " ") {
                emit(upTo: cut, into: &out)
                continue
            }
            break
        }
        return out
    }

    public mutating func finish() -> [String] {
        let tail = head.trimmingCharacters(in: .whitespacesAndNewlines)
        head = ""
        return tail.isEmpty ? [] : [tail]
    }

    private mutating func emit(upTo cut: String.Index, into out: inout [String]) {
        let chunk = String(head[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        head = String(head[cut...])
        if !chunk.isEmpty { out.append(chunk); emittedFirst = true }
    }

    private func earlyClauseCut() -> String.Index? {
        var i = head.startIndex
        while let comma = head[i...].firstIndex(where: { $0 == "," || $0 == ";" || $0 == "—" }) {
            let end = head.index(after: comma)
            guard end < head.endIndex else { return nil }                        // need to see what follows
            let words = head[..<comma].split(whereSeparator: \.isWhitespace)
            if words.count >= firstClauseMinWords, head[end].isWhitespace { return end }   // "1,000" stays whole
            i = end
        }
        return nil
    }

    private func nextCut() -> String.Index? {
        var i = head.startIndex
        while i < head.endIndex {
            let ch = head[i]
            if ch == "\n" {
                let before = head[..<i].trimmingCharacters(in: .whitespaces)
                if !before.isEmpty { return head.index(after: i) }
                i = head.index(after: i); continue
            }
            guard Self.enders.contains(ch) else { i = head.index(after: i); continue }
            var end = head.index(after: i)
            while end < head.endIndex, Self.enders.contains(head[end]) || Self.closers.contains(head[end]) {
                end = head.index(after: end)
            }
            guard end < head.endIndex else { return nil }
            guard head[end].isWhitespace else { i = end; continue }
            var next = end
            while next < head.endIndex, head[next].isWhitespace { next = head.index(after: next) }
            guard next < head.endIndex else { return nil }
            if ch == ".", isAbbreviation(before: i) { i = end; continue }
            return end
        }
        return nil
    }

    private func isAbbreviation(before dot: String.Index) -> Bool {
        var start = dot
        while start > head.startIndex {
            let p = head.index(before: start)
            if head[p].isLetter || head[p] == "." { start = p } else { break }
        }
        let word = head[start..<dot].lowercased()
        if Self.abbreviations.contains(word) { return true }
        return word.count == 1 && head[start].isUppercase && word != "i" && word != "a"
    }
}
