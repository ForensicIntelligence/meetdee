import Foundation

/// Hidden per-turn context that showed up in what Dee said: the model read out
/// part of its `<dee_state>` cue instead of acting on it. Dev-only diagnostics for
/// the brain and the harness ("persona drift"): nothing is filtered or changed.
public enum CueLeak: Sendable, Equatable, Hashable {
    /// The reply contains the `<dee_state>` tag (opening, closing or bare name).
    case stateTag
    /// The reply repeats the start of the mood sentence ("Toward your human: …").
    case moodSentence
    /// The reply repeats one of the turn's notes verbatim (case and whitespace
    /// insensitive, with or without its parentheses). Carries the note as given.
    case note(String)

    /// Notes shorter than this (inside the parentheses) are too generic to call a
    /// verbatim repeat.
    public static let minimumNoteLength = 12

    /// Leak check of a reply (or a transcript so far) against this turn's notes.
    /// In order of kind: tag, mood sentence, then notes; duplicates once.
    public static func find(in reply: String, notes: [String] = []) -> [CueLeak] {
        let text = normalized(reply)
        guard !text.isEmpty else { return [] }
        var found: [CueLeak] = []
        if text.contains("dee_state") { found.append(.stateTag) }
        if text.contains("toward your human:") { found.append(.moodSentence) }
        var seen = Set<String>()
        for note in notes {
            var inner = Substring(note.trimmingCharacters(in: .whitespacesAndNewlines))
            if inner.hasPrefix("(") { inner = inner.dropFirst() }
            if inner.hasSuffix(")") { inner = inner.dropLast() }
            let needle = normalized(String(inner))
            guard needle.count >= minimumNoteLength, seen.insert(needle).inserted else { continue }
            if text.contains(needle) { found.append(.note(note)) }
        }
        return found
    }

    /// The top-level parenthesised notes in a `<dee_state>…</dee_state>` cue (or any
    /// text), parentheses included, in order. Unbalanced trailing text is ignored.
    public static func notes(inCue cue: String) -> [String] {
        var out: [String] = []
        var depth = 0
        var current = ""
        for ch in cue {
            if ch == "(" {
                depth += 1
                current.append(ch)
            } else if ch == ")", depth > 0 {
                depth -= 1
                current.append(ch)
                if depth == 0 { out.append(current); current = "" }
            } else if depth > 0 {
                current.append(ch)
            }
        }
        return out
    }

    /// Lowercased, typographic quotes/apostrophes straightened, whitespace collapsed.
    static func normalized(_ s: String) -> String {
        var t = s.lowercased()
        for (a, b) in [("\u{2019}", "'"), ("\u{2018}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\"")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Watches one reply's transcript as it streams in, for leaks of this turn's cue.
public struct CueLeakWatch: Sendable, Equatable {
    /// The parenthesised notes of this turn's cue (`CueLeak.notes(inCue:)`).
    public var notes: [String] {
        didSet { leaks = CueLeak.find(in: text, notes: notes) }
    }
    /// Everything fed so far, concatenated.
    public private(set) var text = ""
    /// Leaks seen so far.
    public private(set) var leaks: [CueLeak] = []
    public var leaked: Bool { !leaks.isEmpty }

    public init(notes: [String] = []) { self.notes = notes }

    /// Watches the notes of this cue.
    public init(cue: String) { self.init(notes: CueLeak.notes(inCue: cue)) }

    /// The next piece of the transcript. A leak split across pieces is found once
    /// its last piece arrives.
    public mutating func feed(_ piece: String) {
        guard !piece.isEmpty else { return }
        text += piece
        leaks = CueLeak.find(in: text, notes: notes)
    }
}
