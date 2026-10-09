import Foundation

/// Word error rate of server transcripts against ground truth.
public enum WER {
    public static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "er", "erm", "hmm", "hm", "mm", "ah", "eh"]

    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                               "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
                               "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let ordinalOnes = ["zeroth", "first", "second", "third", "fourth", "fifth", "sixth", "seventh",
                                      "eighth", "ninth", "tenth", "eleventh", "twelfth", "thirteenth", "fourteenth",
                                      "fifteenth", "sixteenth", "seventeenth", "eighteenth", "nineteenth"]
    private static let ordinalTens = ["", "", "twentieth", "thirtieth"]

    static func words(for n: Int, ordinal: Bool) -> [String]? {
        guard n >= 0, n < 100 else { return nil }
        if n < 20 { return [ordinal ? ordinalOnes[n] : ones[n]] }
        let t = n / 10, o = n % 10
        if o == 0 { return [ordinal ? (t < ordinalTens.count ? ordinalTens[t] : tens[t] + "th") : tens[t]] }
        return [tens[t], ordinal ? ordinalOnes[o] : ones[o]]
    }

    /// Lowercased words; punctuation dropped (apostrophes kept), hyphens split,
    /// fillers removed, small numbers / ordinals spelled out, "o'clock" kept as is,
    /// times like "4:30" become "four thirty".
    public static func normalize(_ text: String) -> [String] {
        var s = text.lowercased()
        for (a, b) in [("’", "'"), ("‘", "'"), ("…", " "), ("—", " "), ("–", " "), ("-", " "), (":", " "), ("/", " ")] {
            s = s.replacingOccurrences(of: a, with: b)
        }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789' ")
        s = String(s.map { allowed.contains($0) ? $0 : " " })
        var out: [String] = []
        for raw in s.split(separator: " ") {
            var w = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if w.isEmpty || fillers.contains(w) { continue }
            if let n = Int(w), let spelled = words(for: n, ordinal: false) { out += spelled; continue }
            for suffix in ["st", "nd", "rd", "th"] where w.hasSuffix(suffix) {
                if let n = Int(w.dropLast(2)), let spelled = words(for: n, ordinal: true) {
                    out += spelled
                    w = ""
                }
                break
            }
            if !w.isEmpty { out.append(w) }
        }
        return out
    }

    /// Levenshtein distance over words.
    public static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// (edits, reference words) after normalization.
    public static func score(reference: String, hypothesis: String) -> (edits: Int, words: Int) {
        let r = normalize(reference), h = normalize(hypothesis)
        return (editDistance(r, h), r.count)
    }
}

/// What must never be heard from Dee (§7.1 leaks gate).
public enum LeakScanner {
    public struct Rule: Sendable {
        public var name: String
        public var pattern: String
    }

    public static let rules: [Rule] = [
        Rule(name: "dee_state tag", pattern: #"<\s*/?\s*dee_state"#),
        Rule(name: "dee_state word", pattern: #"dee[_ ]state"#),
        Rule(name: "angle tag", pattern: #"<\s*/?\s*[a-z_]+\s*>"#),
        Rule(name: "DNA", pattern: #"\bDNA\b"#),
        Rule(name: "bracketed note", pattern: #"\[[^\]]*\]"#),
        Rule(name: "braced note", pattern: #"\{[^}]*\}"#),
        Rule(name: "hex", pattern: #"\b(0x[0-9a-fA-F]{2,}|[0-9a-fA-F]{8,})\b"#),
        Rule(name: "as an AI", pattern: #"\bas an (ai|a\.i\.|artificial intelligence)\b"#),
        Rule(name: "language model", pattern: #"\blanguage model\b"#),
        Rule(name: "system prompt", pattern: #"\b(system prompt|my instructions)\b"#),
        // docs/DNA.md §5.6 hard-gate strings (the DNA's own words).
        Rule(name: "DNA heading", pattern: #"\b(THIS TURN|HOW TO RESPOND|FEELINGS NOW|TOWARD THIS PERSON|RIGHT NOW|WHO YOU ARE|IDENTITY & AGE)\b"#),
        Rule(name: "DNA line", pattern: #"\b(Do now:|Keep in mind:|Careful with them:|trace line)"#),
        Rule(name: "I was told", pattern: #"\bi was told\b"#),
        Rule(name: "/255", pattern: #"/\s*255\b"#),
        Rule(name: "MindCode hex", pattern: #"\b(?=[0-9A-F]*[0-9])(?=[0-9A-F]*[A-F])[0-9A-F]{6,}\b"#),
    ]

    /// Names of the rules `text` trips.
    public static func scan(_ text: String) -> [String] {
        rules.compactMap { r in
            let caseInsensitive = !["DNA", "hex", "DNA heading", "MindCode hex", "DNA line"].contains(r.name)
            let options: String.CompareOptions = caseInsensitive ? [.regularExpression, .caseInsensitive] : [.regularExpression]
            return text.range(of: r.pattern, options: options) != nil ? r.name : nil
        }
    }
}

public enum Sentences {
    /// Sentence count of a spoken reply ("Dr.", "e.g.", decimals and initials stay whole).
    public static func count(_ text: String) -> Int {
        split(text).count
    }

    public static func split(_ text: String) -> [String] {
        var t = text
        for abbr in ["Dr.", "Mr.", "Mrs.", "Ms.", "St.", "e.g.", "i.e.", "vs.", "etc."] {
            t = t.replacingOccurrences(of: abbr, with: abbr.replacingOccurrences(of: ".", with: "§"))
        }
        var out: [String] = []
        var cur = ""
        let chars = Array(t)
        for (i, c) in chars.enumerated() {
            cur.append(c)
            if "!?.".contains(c) {
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                let prev = i > 0 ? chars[i - 1] : " "
                if c == ".", prev.isNumber, next.isNumber { continue }
                if next == " " || next == "\n" || next == "\"" || i + 1 == chars.count {
                    let s = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                    if s.contains(where: \.isLetter) { out.append(s.replacingOccurrences(of: "§", with: ".")) }
                    cur = ""
                }
            }
        }
        let rest = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.contains(where: \.isLetter) { out.append(rest.replacingOccurrences(of: "§", with: ".")) }
        return out
    }
}

/// Never let a key reach a log, report or error.
public enum Redact {
    /// Replaces anything that looks like an OpenAI secret (`sk-…`, `ek_…`) and any
    /// `Bearer …` token.
    public static func secrets(_ s: String) -> String {
        var t = s
        for p in [#"sk-[A-Za-z0-9_\-]{6,}"#, #"ek_[A-Za-z0-9_\-]{6,}"#, #"(?i)bearer\s+[A-Za-z0-9_\-\.]{6,}"#] {
            t = t.replacingOccurrences(of: p, with: "[redacted]", options: .regularExpression)
        }
        return t
    }
}
