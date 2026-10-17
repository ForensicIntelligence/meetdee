import Foundation

/// What Dee said lately, word by word: a server item that Dee's echo opened (and
/// that the local evidence couldn't settle) is judged by its words. Dee's own
/// words coming back are Dee's echo; words Dee never said are someone else's —
/// the user talking on inside an item Dee's voice had opened ("Don't stop. Keep
/// going." under Dee's loud echo, no echo cancellation).
public struct HerWords: Sendable, Equatable {
    /// Dee's words this recent can come back as echo.
    public static let window = 20.0
    static let capacity = 400

    /// Single words a person says on their own over Dee: one of these that Dee
    /// didn't say is enough. Any other lone word (a mis-heard fragment of Dee's
    /// echo, "Dee.") isn't.
    static let loneUserWords: Set<String> = [
        "stop", "wait", "no", "yes", "yeah", "yep", "okay", "ok", "mhm", "mm", "hmm", "uh", "huh", "what", "sorry", "hey",
        "hello", "please", "thanks", "really", "right", "sure", "cool", "nice", "wow",
    ]

    private var words: [(t: Double, w: String)] = []

    public init() {}

    public static func == (a: HerWords, b: HerWords) -> Bool { a.words.map(\.w) == b.words.map(\.w) }

    /// Dee's transcript text as it is spoken (or generated) at `t`.
    public mutating func add(_ text: String, at t: Double) {
        for w in Self.words(text) { words.append((t, w)) }
        if words.count > Self.capacity { words.removeFirst(words.count - Self.capacity) }
    }

    /// The transcript `text` of an item at `t` is only Dee's own words coming back
    /// (or nothing at all): Dee's echo. False when it holds words Dee didn't say
    /// lately — two or more, or one a person says on its own ("Stop."). `strict`
    /// (nothing but the words says it may be the user): three or more, as Dee's echo
    /// comes back garbled too ("Years old." for "Here's a little thought").
    ///
    /// Tune 13 (T12-6, live interrupt-echo20 q02: "Are you awake?" deleted because "are" and
    /// "you" were somewhere in Dee's reply): a short item, or one that asks (`?`, or `asks`: a
    /// rising sound), is Dee's echo only as a phrase of Dee's — its words in Dee's order, side by
    /// side. In a short item a word Dee didn't say stands for one Dee did (Dee's echo comes back
    /// garbled); in one that asks, every word must be Dee's.
    public func isHerEcho(_ text: String, at t: Double, strict: Bool = false, asks: Bool = false) -> Bool {
        let said = words.filter { t - $0.t <= Self.window }.map(\.w)
        let heard = Self.words(text)
        guard !heard.isEmpty else { return true }
        let foreign = heard.filter { w in !said.contains { Self.same($0, w) } }
        if asks || text.contains("?") { return foreign.isEmpty && Self.phrase(heard, in: said, wildcards: false) }
        if foreign.count >= (strict ? 3 : 2) { return false }
        if foreign.count == 1, heard.count == 1, Self.loneUserWords.contains(foreign[0]) { return false }
        if heard.count >= 2, heard.count <= Self.shortItem { return Self.phrase(heard, in: said, wildcards: true) }
        return true
    }

    /// Up to this many words, an item is Dee's echo only as a phrase of Dee's.
    static let shortItem = 4

    /// `heard` side by side, in order, somewhere in `said` (`wildcards`: a word Dee never said
    /// matches any one word of Dee's).
    static func phrase(_ heard: [String], in said: [String], wildcards: Bool) -> Bool {
        guard heard.count <= said.count else { return false }
        let known = heard.map { w in said.contains { same($0, w) } }
        for start in 0...(said.count - heard.count) {
            if heard.indices.allSatisfy({ i in (wildcards && !known[i]) || same(said[start + i], heard[i]) }) { return true }
        }
        return false
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    /// The same word, allowing a transcription's clipped ending ("here" / "here's").
    static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return short.count >= 3 && long.hasPrefix(short)
    }
}
