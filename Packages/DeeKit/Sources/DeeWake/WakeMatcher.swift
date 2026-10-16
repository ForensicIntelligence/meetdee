import Foundation

/// How a wake match was made, strongest first.
public enum MatchTier: Int, Sendable, Codable, Comparable, CaseIterable {
    /// The phrase's words exactly.
    case exact
    /// An explicit alias ("heidi", "kd", the joined words) — may span fewer words.
    case alias
    /// Letter edit distance within `letterRatio` on a window of the phrase's word count.
    case letters
    /// Sound-key distance within `keyDistance` (keys of ≥ 3 letters only).
    case phonetic

    public static func < (a: MatchTier, b: MatchTier) -> Bool { a.rawValue < b.rawValue }
}

public struct WakeMatch: Sendable, Equatable {
    public var tier: MatchTier
    /// The matched window, normalised ("hey dee", "heidi").
    public var matched: String
    /// Index into the texts passed to `match` (0 = best transcription).
    public var textIndex: Int
    /// Word positions of the window in that text's normalised words.
    public var wordRange: Range<Int>
}

/// Text matcher for the wake phrase (contract §3).
///
/// Windows are exactly the phrase's word count, over the best text and every
/// alternative, volatile or final: (a) exact, (b) explicit alias (any 1–4 word window
/// whose joined letters equal an alias's), (c) letter Levenshtein of the joined window
/// ≤ `letterRatio` × phrase letters, (d) `PhoneticKey` distance ≤ `keyDistance`, only
/// when the phrase key has ≥ 3 letters. A bare key never matches a shorter window, so
/// "had", "hot", "head", "her robe" never wake "Hey Dee".
public struct WakeMatcher: Sendable {
    public struct Thresholds: Sendable, Equatable, Codable, CustomStringConvertible {
        public var keyDistance: Int
        public var letterRatio: Double

        public init(keyDistance: Int, letterRatio: Double) {
            self.keyDistance = keyDistance
            self.letterRatio = letterRatio
        }

        /// Pinned by `WakeCorpus.tune` (grid keyDistance 0–2 × letterRatio 0.15–0.45):
        /// the smallest values with recall ≥ 0.95 and zero negatives on every corpus
        /// phrase. `WakeCorpusTests` fails if a re-tune flips them.
        public static let tuned = Thresholds(keyDistance: 0, letterRatio: 0.15)

        public var description: String { "keyDistance \(keyDistance), letterRatio \(letterRatio)" }
    }

    public let phrase: WakePhrase
    public let thresholds: Thresholds
    /// Tiers exact + alias only (false-wake backoff).
    public let strict: Bool

    private let joinedPhrase: String
    private let phraseKey: PhoneticKey
    private let joinedAliases: [String]

    public init(_ phrase: WakePhrase, _ thresholds: Thresholds = .tuned, strict: Bool = false) {
        self.phrase = phrase
        self.thresholds = thresholds
        self.strict = strict
        joinedPhrase = phrase.words.joined()
        phraseKey = phrase.key
        joinedAliases = Array(Set(phrase.aliases.map { $0.replacingOccurrences(of: " ", with: "") }))
    }

    public static func normalizedWords(_ s: String) -> [String] { WakeText.words(s) }

    /// The strongest match in any of `texts`, or nil.
    ///
    /// - Parameter isFinal: false for a volatile result, whose end is where the
    ///   recogniser has got to, not a pause — so a one-word match there needs real
    ///   punctuation after it ("…an old computer" mid-sentence never wakes).
    /// - Parameter startsAfterBreak: the text's start follows a pause or a sentence end
    ///   (false when the recogniser cut a final mid-sentence: "…an old" | "computer").
    public func match(_ texts: [String], isFinal: Bool = true, startsAfterBreak: Bool = true) -> WakeMatch? {
        var best: WakeMatch?
        for (index, text) in texts.enumerated() {
            let tokens = WakeText.tokens(text)
            var breaks = WakeText.breaks(text, tokens)
            if !isFinal, let last = breaks.indices.last {
                let tail = text[tokens[last].range.upperBound...]
                breaks[last].after = tail.contains { WakeText.breakCharacters.contains($0) }
            }
            if !startsAfterBreak, !breaks.isEmpty {
                let head = text[..<tokens[0].range.lowerBound]
                breaks[0].before = head.contains { WakeText.breakCharacters.contains($0) }
            }
            guard let m = match(words: tokens.map(\.word), textIndex: index, breaks: breaks) else { continue }
            if best == nil || m.tier < best!.tier { best = m }
            if m.tier == .exact { break }
        }
        return best
    }

    /// - Parameter breaks: punctuation around each word. When given, a one-word match
    ///   (a one-word phrase, or a one-word alias) counts only in *address position*:
    ///   opening the text (or after punctuation, or after a greeting that does) AND
    ///   closing it or followed by punctuation — "Computer, what time is it?" wakes,
    ///   "an old computer museum" and "Heidi Klum was on TV" don't.
    func match(words: [String], textIndex: Int = 0, breaks: [WakeText.Breaks]? = nil) -> WakeMatch? {
        guard !words.isEmpty else { return nil }
        var best: WakeMatch?
        func addressed(_ i: Int) -> Bool {
            guard let breaks, breaks.count == words.count else { return true }
            let opens = breaks[i].before
                || (i > 0 && Self.addressGreetings.contains(words[i - 1]) && breaks[i - 1].before)
            return opens && breaks[i].after
        }
        func consider(_ tier: MatchTier, _ range: Range<Int>) {
            if range.count == 1, !addressed(range.lowerBound) { return }
            if best == nil || tier < best!.tier {
                best = WakeMatch(tier: tier, matched: words[range].joined(separator: " "), textIndex: textIndex, wordRange: range)
            }
        }
        let n = phrase.words.count
        // (a) exact, and (c)/(d) on windows of exactly n words.
        if words.count >= n {
            for start in 0...(words.count - n) {
                let window = Array(words[start..<(start + n)])
                let range = start..<(start + n)
                if window == phrase.words {
                    consider(.exact, range)
                    if best?.tier == .exact { return best }
                    continue
                }
                if strict { continue }
                let joined = window.joined()
                if Double(WakeText.levenshtein(joined, joinedPhrase)) <= thresholds.letterRatio * Double(joinedPhrase.count) {
                    consider(.letters, range)
                } else if phraseKey.value.count >= 3 {
                    let key = PhoneticKey(words: window)
                    if key.value.count >= 3, key.distance(to: phraseKey) <= thresholds.keyDistance { consider(.phonetic, range) }
                }
            }
        }
        // (b) aliases: any 1–4 word window whose joined letters equal an alias.
        if !joinedAliases.isEmpty, best.map({ $0.tier > .alias }) ?? true {
            outer: for size in 1...min(WakePhrase.maxWords, words.count) {
                for start in 0...(words.count - size) {
                    let joined = words[start..<(start + size)].joined()
                    if joinedAliases.contains(joined) {
                        consider(.alias, start..<(start + size))
                        if best?.tier == .alias { break outer }
                    }
                }
            }
        }
        return best
    }

    /// The first phrase word plus a prefix of the next at the end of `text` (the
    /// "perking up" cue while the recogniser is still writing), or a full match.
    /// One-word phrases: a prefix of at least 3 letters and half the word.
    public func candidate(_ text: String) -> Bool {
        let words = WakeText.words(text)
        guard let last = words.last else { return false }
        if match(words: words) != nil { return true }
        let p = phrase.words
        if p.count == 1 {
            let need = max(3, (p[0].count + 1) / 2)
            return last.count >= need && p[0].hasPrefix(last)
        }
        // words end with p[0..<k] + a non-empty prefix of p[k], k ≥ 1.
        for k in 1..<p.count {
            guard words.count >= k + 1 else { continue }
            let tail = Array(words.suffix(k + 1))
            if Array(tail.prefix(k)) == Array(p.prefix(k)), p[k].hasPrefix(tail[k]) { return true }
        }
        return false
    }

    /// `text` without the phrase at its start (and the punctuation after it), original
    /// casing kept: "Computer, go to sleep" → "go to sleep"; "Heidi, stop" → "stop" for
    /// "Hey Dee". Leading "um"/"uh"/"oh" may come first. Unchanged when it doesn't open
    /// with the phrase; "" when it is only the phrase.
    public func stripLeading(_ text: String) -> String {
        let tokens = WakeText.tokens(text)
        var skip = 0
        while skip < tokens.count, Self.fillers.contains(tokens[skip].word) { skip += 1 }
        let words = tokens.map(\.word)
        guard skip < words.count else { return text }
        let loose = WakeMatcher(phrase, thresholds, strict: false)
        var end: Int?
        let maxSize = min(WakePhrase.maxWords, words.count - skip)
        for size in stride(from: maxSize, through: 1, by: -1) {
            let range = skip..<(skip + size)
            if let m = loose.match(words: Array(words[range])), m.wordRange == 0..<size {
                end = range.upperBound
                break
            }
        }
        guard let end else { return text }
        guard end < tokens.count else { return "" }
        return String(text[tokens[end].range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let fillers: Set<String> = ["um", "uh", "oh", "erm", "hmm", "so"]
    /// Words that may open an address before a one-word phrase ("Okay, Computer").
    static let addressGreetings: Set<String> = ["hey", "hi", "hello", "okay", "oh", "um", "uh", "yo"]

    // MARK: - Name variants (on-device STT)

    /// Her name's recogniser spellings in *address* position rewritten to "Dee", for the
    /// on-device speech-to-text backend: "Heidi, what's up?" → "Hey Dee, what's up?",
    /// "Hey D, look" → "Hey Dee, look", "Thanks, KD." → "Thanks, Dee." A variant inside
    /// a sentence ("Heidi Klum was on TV", "vitamin D") is left alone.
    public static func rewriteNameVariants(_ text: String) -> String {
        let tokens = WakeText.tokens(text)
        guard !tokens.isEmpty else { return text }
        var replacements: [(Range<String.Index>, String)] = []
        func followedByBreak(_ i: Int) -> Bool {
            let end = tokens[i].range.upperBound
            guard end < text.endIndex else { return true }
            let next = i + 1 < tokens.count ? tokens[i + 1].range.lowerBound : text.endIndex
            return text[end..<next].contains { ",.!?;:—-".contains($0) }
        }
        func precededByBreak(_ i: Int) -> Bool {
            guard i > 0 else { return true }
            return text[tokens[i - 1].range.upperBound..<tokens[i].range.lowerBound].contains { ",.!?;:—".contains($0) }
        }
        var i = 0
        var start = 0
        while start < tokens.count, fillers.contains(tokens[start].word) { start += 1 }
        while i < tokens.count {
            let w = tokens[i].word
            let atStart = i == start
            let lastWord = i == tokens.count - 1
            // "KD", "K.D." (two tokens "k" "d")
            if w == "k", i + 1 < tokens.count, tokens[i + 1].word == "d", atStart || precededByBreak(i), followedByBreak(i + 1) {
                replacements.append((tokens[i].range.lowerBound..<tokens[i + 1].range.upperBound, atStart ? "Hey Dee" : "Dee"))
                i += 2
                continue
            }
            if mergedGreetingVariants.contains(w), (atStart && followedByBreak(i)) || (atStart && lastWord) {
                replacements.append((tokens[i].range, "Hey Dee"))
            } else if w == "kd", (atStart || precededByBreak(i)) && (followedByBreak(i) || lastWord) {
                replacements.append((tokens[i].range, atStart ? "Hey Dee" : "Dee"))
            } else if w == "d" {
                let afterGreeting = i > 0 && greetings.contains(tokens[i - 1].word) && i - 1 == start
                if (afterGreeting && (followedByBreak(i) || lastWord)) || (atStart && followedByBreak(i)) || (lastWord && precededByBreak(i)) {
                    replacements.append((tokens[i].range, "Dee"))
                }
            }
            i += 1
        }
        guard !replacements.isEmpty else { return text }
        var out = text
        for (range, s) in replacements.reversed() { out.replaceSubrange(range, with: s) }
        return out
    }

    static let mergedGreetingVariants: Set<String> = ["heidi", "haidee", "haydee", "haidi", "heydee"]
    static let greetings: Set<String> = ["hey", "hi", "hello", "okay", "thanks", "thank", "you", "bye", "night", "morning"]
}
