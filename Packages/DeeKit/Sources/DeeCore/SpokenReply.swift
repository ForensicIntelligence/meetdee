import Foundation

/// The text of one reply as it went to the voice, and how much of it the user has
/// actually heard (audit C9).
///
/// The language model writes far faster (10–15 words/s) than Dee speaks (~2.5
/// words/s), so by the time someone talks over her the whole reply is usually
/// written and in her history. That history must only hold what she said out loud;
/// otherwise she "remembers" telling them things they never heard. Without word
/// timings from the voice, the heard part is estimated from how long she has been
/// speaking, conservatively (whole words only; a cut sentence ends in "—", which
/// also tells the model she was cut off).
public struct SpokenReply: Sendable, Equatable {
    /// Everything streamed to the voice for this reply, in order.
    public private(set) var text = ""

    public init() {}

    public mutating func append(_ fragment: String) { text += fragment }

    /// Her speaking speed at an `AVSpeechUtterance`-style `rate` (0…1, default 0.5),
    /// on the slow side so the estimate never credits her with unheard words.
    public static func charactersPerSecond(rate: Double) -> Double {
        13 * max(0.2, min(1, rate)) / 0.5
    }

    /// What a listener has heard after `seconds` of her speaking this reply.
    public func heard(afterSeconds seconds: Double, charactersPerSecond: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        return Self.prefix(of: text, characters: Int((seconds * charactersPerSecond).rounded(.down)))
    }

    /// The first `n` characters of `text`, cut back to whole words. A cut inside a
    /// sentence ends with "—".
    public static func prefix(of text: String, characters n: Int) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard n > 0 else { return "" }
        guard n < t.count else { return t }
        let cut = t.index(t.startIndex, offsetBy: n)
        var head = t[..<cut]
        if !t[cut].isWhitespace {
            // Mid-word: that word was not heard yet.
            guard let space = head.lastIndex(where: \.isWhitespace) else { return "" }
            head = head[..<space]
        }
        var kept = String(head).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = kept.last else { return "" }
        if ".!?…".contains(last) { return kept }
        while let l = kept.last, ",;:-—–".contains(l) { kept.removeLast() }
        kept = kept.trimmingCharacters(in: .whitespaces)
        return kept.isEmpty ? "" : kept + "—"
    }
}

/// What happens to a reply's place in the model's history once Dee is stopped (by a
/// barge-in, a hush, a "stop", or the user saying something new before she spoke).
public enum ReplySettlement: Sendable, Equatable {
    /// Everything she wrote was heard: history stays as it is.
    case keep
    /// Only this much was heard: the reply in history becomes this.
    case truncate(String)
    /// Nothing was heard: as far as the conversation goes, the turn never happened.
    case retract

    /// - Parameters:
    ///   - streamed: the reply text sent to the voice.
    ///   - audioStarted / audioFinished: her voice for this reply started / played out.
    ///   - playedSeconds: how long she had been speaking it when she was stopped.
    public static func decide(streamed: String, audioStarted: Bool, audioFinished: Bool,
                              playedSeconds: Double, charactersPerSecond: Double) -> ReplySettlement {
        if audioFinished { return .keep }
        guard audioStarted else { return .retract }
        let whole = streamed.trimmingCharacters(in: .whitespacesAndNewlines)
        let heard = SpokenReply.prefix(of: whole, characters: Int((max(0, playedSeconds) * charactersPerSecond).rounded(.down)))
        if heard.isEmpty { return .retract }
        return heard == whole ? .keep : .truncate(heard)
    }
}
