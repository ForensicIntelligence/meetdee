import Foundation

/// Cleans model text into something a speech synthesizer should say out loud:
/// no `[emotion]` tags, no markdown, no emoji. Stage directions like `*giggles*`
/// become a little spoken laugh, because Dee laughs out loud. Parenthesised asides
/// and `<…>` tags (with the body of state blocks like `<dee_state>`) are never
/// spoken; see `SpeechText.dropAsides(_:)`.
public enum SpeechText {
    /// Removes `( … )` asides and `<…>` tags — and the whole body of state/reasoning
    /// blocks such as `<dee_state>…</dee_state>` — so stage directions and leaked
    /// cue notes are never spoken. An unclosed `(` drops the rest. Emoticons like
    /// ":(" and comparisons like "3 < 4" are kept.
    public static func dropAsides(_ text: String) -> String {
        AsideFilter.strip(text)
    }

    public static func clean(_ text: String) -> String {
        var s = AsideFilter.strip(text)
        // Code blocks are never read aloud.
        s = replace(s, #"```[\s\S]*?(```|$)"#, with: " ")
        // Images and links keep their visible text.
        s = replace(s, #"!\[([^\]]*)\]\([^)]*\)"#, with: "$1")
        s = replace(s, #"\[([^\]]+)\]\((?:[^)]*)\)"#, with: "$1")
        // [emotion] and similar bracketed tags, <tags>.
        s = replace(s, #"\[[^\[\]\n]{0,40}\]"#, with: " ")
        s = replace(s, #"</?[A-Za-z][^<>\n]{0,40}>"#, with: " ")
        // Laughing stage directions → an actual laugh.
        s = replace(s, #"(?i)\*{1,2}\s*(?:[a-z]+\s+)?(?:laugh|laughs|laughing|giggle|giggles|giggling|chuckle|chuckles|chuckling|snicker|snickers|hehe+|haha+)[^*\n]{0,24}\*{1,2}"#, with: "Hehe!")
        // Line-level markdown.
        s = replace(s, #"(?m)^\s{0,3}#{1,6}\s+"#, with: "")
        s = replace(s, #"(?m)^\s{0,3}>\s?"#, with: "")
        s = replace(s, #"(?m)^\s*(?:[-*+•]|\d{1,3}[.)])\s+"#, with: "")
        s = replace(s, #"(?m)^\s*(?:-{3,}|\*{3,}|_{3,})\s*$"#, with: " ")
        s = s.replacingOccurrences(of: "|", with: " ")
        // Emphasis and inline code markers.
        s = replace(s, #"(\*{1,3}|_{2,3})([^*_\n]+?)\1"#, with: "$2")
        s = replace(s, #"(?<![A-Za-z0-9])_([^_\n]+?)_(?![A-Za-z0-9])"#, with: "$1")
        s = replace(s, #"`([^`]*)`"#, with: "$1")
        s = s.replacingOccurrences(of: "*", with: "")
        s = s.replacingOccurrences(of: "~~", with: "")
        s = stripEmoji(s)
        s = replace(s, #"\s+"#, with: " ")
        s = replace(s, #" ([,.!?;:…])"#, with: "$1")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing left but punctuation → nothing to say.
        if !s.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) { return "" }
        return s
    }

    static func stripEmoji(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            let v = u.value
            if v == 0x200D || v == 0x20E3 || (0xFE00...0xFE0F).contains(v) { continue }   // ZWJ, keycap, variation selectors
            if (0x1F3FB...0x1F3FF).contains(v) || (0x1F1E6...0x1F1FF).contains(v) { continue } // skin tones, flags
            if (0xE0020...0xE007F).contains(v) { continue }                                  // tag sequences
            if u.properties.isEmojiPresentation { continue }
            if u.properties.isEmoji && v >= 0x2000 { continue }   // text-default pictographs (☺ ✔ ❤), but not digits/#/*
            out.append(u)
        }
        return String(out)
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: NSRegularExpression] = [:]

    static func replace(_ s: String, _ pattern: String, with template: String) -> String {
        cacheLock.lock()
        let re: NSRegularExpression
        if let cached = cache[pattern] {
            re = cached
        } else {
            re = try! NSRegularExpression(pattern: pattern)
            cache[pattern] = re
        }
        cacheLock.unlock()
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
}

/// Splits streamed LLM text into speakable sentences as soon as each one is
/// complete, so Dee starts talking while the model is still writing.
///
/// - Splits after `.`, `!`, `?`, `…` (and runs like `?!` or `...`) followed by
///   whitespace, and on line breaks.
/// - Does not split after abbreviations ("Dr.", "e.g."), initials ("J."), list
///   numbers at the start of a line, or inside numbers ("3.5", "1,000.25").
/// - A terminator at the very end of the buffer waits for the next character (the
///   stream might continue "3." → "3.5").
/// - Very long runs without an end are cut at a comma or space so she never waits
///   too long.
/// - `flush()` (endStream) emits whatever is left.
/// - Text inside `( … )` and `<…>` (and the body of `<dee_state>`-like blocks) is
///   dropped as it streams in, even when split across fragments: stage directions
///   and leaked state are never spoken.
/// - Every emitted sentence is passed through `SpeechText.clean`; empty ones vanish.
public struct SentenceChunker: Sendable {
    public var maxLength: Int

    private var buffer: String = ""
    private var asides = AsideFilter()

    public init(maxLength: Int = 220) {
        self.maxLength = max(40, maxLength)
    }

    /// Text received but not yet emitted.
    public var pending: String { buffer }

    public mutating func append(_ fragment: String) -> [String] {
        buffer += asides.feed(fragment)
        var out: [String] = []
        while let cut = nextBoundary() {
            let sentence = String(buffer[..<cut])
            buffer = String(buffer[cut...])
            let cleaned = SpeechText.clean(sentence)
            if !cleaned.isEmpty { out.append(cleaned) }
        }
        return out
    }

    public mutating func flush() -> [String] {
        let rest = buffer + asides.finish()
        buffer = ""
        // Split whatever is left on its own boundaries first (end-of-buffer counts now).
        var chunker = SentenceChunker(maxLength: maxLength)
        var out = chunker.append(rest + "\n")
        let tail = SpeechText.clean(chunker.buffer)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    public mutating func reset() {
        buffer = ""
        asides.reset()
    }

    static let terminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»", "*", "_"]
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "mt", "ft", "vs", "etc", "e.g", "i.e",
        "eg", "ie", "no", "nos", "approx", "inc", "ltd", "co", "corp", "dept", "est", "fig", "jan",
        "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec", "mon", "tue",
        "wed", "thu", "fri", "sat", "sun", "a.m", "p.m", "u.s", "u.k", "u.s.a", "ph.d", "vol",
        "min", "max", "sec", "hr", "hrs", "oz", "lb", "lbs", "cf", "al",
    ]

    /// Index just past the next complete sentence in `buffer`, or nil.
    private func nextBoundary() -> String.Index? {
        let chars = buffer
        var i = chars.startIndex
        var lastSoftBreak: String.Index?
        var lastSpace: String.Index?
        var count = 0
        while i < chars.endIndex {
            let c = chars[i]
            count += 1
            if c == "\n" {
                let next = chars.index(after: i)
                // Skip blank-only prefixes: a newline right at the start is just whitespace.
                if chars[chars.startIndex..<i].allSatisfy({ $0.isWhitespace }) {
                    i = next
                    continue
                }
                return next
            }
            if Self.terminators.contains(c) {
                // Consume a run of terminators and closers ("?!", "...", ".\")").
                var j = chars.index(after: i)
                while j < chars.endIndex, Self.terminators.contains(chars[j]) || Self.closers.contains(chars[j]) {
                    j = chars.index(after: j)
                }
                guard j < chars.endIndex else { return nil }   // wait for what follows
                if chars[j].isWhitespace, !isFalseStop(at: i, in: chars) {
                    return j
                }
                i = j
                continue
            }
            if c == "," || c == ";" || c == ":" || c == "—" {
                if count > maxLength / 3 { lastSoftBreak = chars.index(after: i) }
            } else if c == " " {
                lastSpace = chars.index(after: i)
            }
            if count >= maxLength {
                return lastSoftBreak ?? lastSpace ?? chars.index(after: i)
            }
            i = chars.index(after: i)
        }
        return nil
    }

    /// A "." that does not end a sentence: abbreviation, initial or leading list number.
    private func isFalseStop(at dot: String.Index, in s: String) -> Bool {
        guard s[dot] == "." else { return false }
        // The token before the dot.
        var start = dot
        while start > s.startIndex {
            let p = s.index(before: start)
            if s[p].isWhitespace || s[p] == "(" || s[p] == "\"" || s[p] == "“" { break }
            start = p
        }
        let token = s[start..<dot].lowercased()
        if token.isEmpty { return false }
        if Self.abbreviations.contains(token) { return true }
        // Single-letter initial ("J. R. R. Tolkien") — but not "I." or "a." that end
        // sentences often enough? "I." is rare as an ending; treat uppercase single letters as initials.
        if token.count == 1, let ch = s[start..<dot].first, ch.isUppercase, ch != "I" { return true }
        // Dotted acronyms like "u.s.a" not in the list.
        if token.contains("."), token.split(separator: ".").allSatisfy({ $0.count == 1 }) { return true }
        // "1." at the start of a line is a list marker.
        if token.allSatisfy(\.isNumber) {
            let before = s[s.startIndex..<start]
            if let lastNonSpace = before.last(where: { $0 != " " && $0 != "\t" }) {
                return lastNonSpace == "\n"
            }
            return true
        }
        return false
    }
}
