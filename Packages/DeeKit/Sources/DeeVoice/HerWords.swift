import Foundation

/// What Dee said lately, word by word: a server item that her echo opened (and
/// that the local evidence couldn't settle) is judged by its words. Her own
/// words coming back are her echo; words she never said are someone else's —
/// the user talking on inside an item her voice had opened ("Don't stop. Keep
/// going." under her loud echo, no echo cancellation).
public struct HerWords: Sendable, Equatable {
    /// Her words this recent can come back as echo.
    public static let window = 20.0
    static let capacity = 400

    /// Single words a person says on their own over her: one of these that she
    /// didn't say is enough. Any other lone word (a mis-heard fragment of her
    /// echo, "Dee.") isn't.
    static let loneUserWords: Set<String> = [
        "stop", "wait", "no", "yes", "yeah", "yep", "okay", "ok", "mhm", "mm", "hmm", "uh", "huh", "what", "sorry", "hey",
        "hello", "please", "thanks", "really", "right", "sure", "cool", "nice", "wow",
    ]

    private var words: [(t: Double, w: String)] = []

    public init() {}

    public static func == (a: HerWords, b: HerWords) -> Bool { a.words.map(\.w) == b.words.map(\.w) }

    /// Her transcript text as it is spoken (or generated) at `t`.
    public mutating func add(_ text: String, at t: Double) {
        for w in Self.words(text) { words.append((t, w)) }
        if words.count > Self.capacity { words.removeFirst(words.count - Self.capacity) }
    }

    /// The transcript `text` of an item at `t` is only her own words coming back
    /// (or nothing at all): her echo. False when it holds words she didn't say
    /// lately — two or more, or one a person says on its own ("Stop."). `strict`
    /// (nothing but the words says it may be the user): three or more, as her echo
    /// comes back garbled too ("Years old." for "Here's a little thought").
    public func isHerEcho(_ text: String, at t: Double, strict: Bool = false) -> Bool {
        let said = words.filter { t - $0.t <= Self.window }.map(\.w)
        let heard = Self.words(text)
        guard !heard.isEmpty else { return true }
        let foreign = heard.filter { w in !said.contains { Self.same($0, w) } }
        if foreign.count >= (strict ? 3 : 2) { return false }
        if foreign.count == 1, heard.count == 1, Self.loneUserWords.contains(foreign[0]) { return false }
        return true
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
