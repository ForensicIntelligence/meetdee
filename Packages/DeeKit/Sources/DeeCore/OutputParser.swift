import Foundation

/// What the model's raw text stream means, one event at a time.
public enum OutputEvent: Sendable, Equatable {
    /// Chain-of-thought text (thinking mode only). Never spoken.
    case reasoning(String)
    /// Visible reply text, with tags and tool markup removed.
    case content(String)
    /// An emotion cue such as `[happy]`.
    case emotion(Emotion)
    /// A complete, parsed `<tool_call>` block.
    case toolCall(ToolCall)
    /// A `<tool_call>` block that could not be parsed (raw text included for logging).
    case malformedToolCall(String)
}

/// Incremental parser for Qwen3.5 output.
///
/// Feed it decoded token pieces as they arrive; it emits events as soon as they are
/// unambiguous and holds back only the shortest tail that could still turn into a
/// tag (`<`, `</thi`, `[hap`…). Call `finish()` at end of stream to flush.
public struct OutputParser: Sendable {
    private enum State: Sendable { case reasoning, content, toolCall }

    private var state: State
    private var buffer = ""
    private var swallowSpace = false
    private var salvage = true
    /// After `</think>` the template emits "\n\n"; drop leading newlines of the
    /// answer even when they arrive in later pieces (or a later generation).
    private var swallowNewlines = false
    /// Raw text of every tool-call block seen so far, for the transcript.
    public private(set) var completedToolCalls: [ToolCall] = []

    /// - Parameter thinking: true when the prompt ended with `<think>\n` (reasoning first).
    public init(thinking: Bool) {
        state = thinking ? .reasoning : .content
    }

    public var isReasoning: Bool { state == .reasoning }

    public mutating func feed(_ text: String) -> [OutputEvent] {
        buffer += text
        let events = drain(final: false)
        watchForLeaks(events)
        return events
    }

    /// Flushes everything still buffered.
    /// - Parameter salvageToolCall: parse an unterminated `<tool_call>` at the end
    ///   of the stream. Only safe when the model ended the turn itself; after a
    ///   token limit or a cancel the call is probably truncated and is reported
    ///   as malformed instead of being executed.
    public mutating func finish(salvageToolCall: Bool = true) -> [OutputEvent] {
        salvage = salvageToolCall
        let events = drain(final: true)
        watchForLeaks(events)
        return events
    }

    // MARK: - Leak detection (dev-only, v0.5)

    /// Hidden per-turn context that showed up in the visible reply. Dev-only
    /// diagnostics: nothing is filtered or changed, the events are untouched.
    public enum Leak: Sendable, Equatable, Hashable {
        /// The reply contains the `<dee_state>` tag (opening, closing or bare name).
        case stateTag
        /// The reply repeats the start of the mood sentence ("Toward your human: …").
        case moodSentence
        /// The reply repeats one of `watchedNotes` verbatim (case and whitespace
        /// insensitive, with or without its parentheses). Carries the note as given.
        case note(String)
    }

    /// The parenthesised notes of this turn's `<dee_state>` cue (see
    /// `OutputParser.notes(inState:)`). A visible reply that repeats one sets a leak.
    public var watchedNotes: [String] = [] {
        didSet { leaks = Self.leaks(in: visibleText, notes: watchedNotes) }
    }
    /// Leaks seen so far in the visible reply (`.content` events only — reasoning is
    /// never spoken). In order of kind: tag, mood sentence, then notes.
    public private(set) var leaks: [Leak] = []
    /// True once any leak was seen. Dev-only flag; never alters parsing.
    public var leaked: Bool { !leaks.isEmpty }
    /// Every `.content` string emitted so far, concatenated.
    public private(set) var visibleText = ""

    private mutating func watchForLeaks(_ events: [OutputEvent]) {
        var grew = false
        for case .content(let s) in events { visibleText += s; grew = true }
        if grew { leaks = Self.leaks(in: visibleText, notes: watchedNotes) }
    }

    /// Notes shorter than this (inside the parentheses) are too generic to call a
    /// verbatim repeat.
    public static let minimumLeakNoteLength = 12

    /// Pure leak check of a finished reply against this turn's notes.
    public static func leaks(in reply: String, notes: [String] = []) -> [Leak] {
        let text = leakNormalized(reply)
        guard !text.isEmpty else { return [] }
        var found: [Leak] = []
        if text.contains("dee_state") { found.append(.stateTag) }
        if text.contains("toward your human:") { found.append(.moodSentence) }
        var seen = Set<String>()
        for note in notes {
            var inner = Substring(note.trimmingCharacters(in: .whitespacesAndNewlines))
            if inner.hasPrefix("(") { inner = inner.dropFirst() }
            if inner.hasSuffix(")") { inner = inner.dropLast() }
            let needle = leakNormalized(String(inner))
            guard needle.count >= minimumLeakNoteLength, seen.insert(needle).inserted else { continue }
            if text.contains(needle) { found.append(.note(note)) }
        }
        return found
    }

    /// The top-level parenthesised notes in a `<dee_state>…</dee_state>` cue (or any
    /// text), parentheses included, in order. Unbalanced trailing text is ignored.
    public static func notes(inState state: String) -> [String] {
        var out: [String] = []
        var depth = 0
        var current = ""
        for ch in state {
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
    static func leakNormalized(_ s: String) -> String {
        var t = s.lowercased()
        for (a, b) in [("\u{2019}", "'"), ("\u{2018}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\"")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: - Internals

    private static let thinkClose = "</think>"
    private static let thinkOpen = "<think>"
    private static let toolOpen = "<tool_call>"
    private static let toolClose = "</tool_call>"
    private static let maxTagLength = 16

    private mutating func drain(final: Bool) -> [OutputEvent] {
        var events: [OutputEvent] = []
        while !buffer.isEmpty {
            if swallowNewlines, state == .content {
                let trimmed = buffer.drop(while: { $0 == "\n" })
                if trimmed.isEmpty { buffer = ""; break }
                buffer = String(trimmed)
                swallowNewlines = false
            }
            if swallowSpace, state == .content {
                swallowSpace = false
                if buffer.hasPrefix(" ") { buffer.removeFirst(); continue }
            }
            switch state {
            case .reasoning:
                if let r = buffer.range(of: Self.thinkClose) {
                    append(.reasoning(String(buffer[..<r.lowerBound])), to: &events)
                    buffer = String(buffer[r.upperBound...])
                    state = .content
                    swallowNewlines = true
                    continue
                }
                let keep = final ? 0 : Self.partialSuffixLength(of: buffer, matching: [Self.thinkClose])
                append(.reasoning(String(buffer.dropLast(keep))), to: &events)
                buffer = String(buffer.suffix(keep))
                return events

            case .content:
                // Earliest special construct in the buffer.
                let toolRange = buffer.range(of: Self.toolOpen)
                let bracketIndex = buffer.firstIndex(of: "[")
                let strayThink = [buffer.range(of: Self.thinkOpen), buffer.range(of: Self.thinkClose)]
                    .compactMap { $0 }
                    .min { $0.lowerBound < $1.lowerBound }

                var cut = buffer.endIndex
                if let t = toolRange { cut = min(cut, t.lowerBound) }
                if let b = bracketIndex { cut = min(cut, b) }
                if let s = strayThink { cut = min(cut, s.lowerBound) }

                if cut == buffer.endIndex {
                    // Nothing special in sight; hold back a tail that might begin a tag.
                    let keep = final ? 0 : Self.partialSuffixLength(of: buffer, matching: [Self.toolOpen, Self.thinkOpen, Self.thinkClose])
                    append(.content(String(buffer.dropLast(keep))), to: &events)
                    buffer = String(buffer.suffix(keep))
                    return events
                }
                if cut > buffer.startIndex {
                    append(.content(String(buffer[..<cut])), to: &events)
                    buffer = String(buffer[cut...])
                    continue
                }

                // Buffer starts with a special construct.
                if let t = toolRange, t.lowerBound == buffer.startIndex {
                    buffer = String(buffer[t.upperBound...])
                    state = .toolCall
                    continue
                }
                if let s = strayThink, s.lowerBound == buffer.startIndex {
                    // A model that re-opens/closes think blocks mid-reply: drop the tag.
                    buffer = String(buffer[s.upperBound...])
                    continue
                }
                // Starts with "[": an emotion tag, or just a bracket.
                if let close = buffer.firstIndex(of: "]") {
                    let inner = String(buffer[buffer.index(after: buffer.startIndex)..<close])
                    if inner.count <= Self.maxTagLength, let emotion = Emotion(tag: inner.replacingOccurrences(of: "emo:", with: "")) {
                        events.append(.emotion(emotion))
                        buffer = String(buffer[buffer.index(after: close)...])
                        // Swallow the single space that usually follows a tag, even
                        // when it arrives in a later piece.
                        swallowSpace = true
                    } else {
                        append(.content("["), to: &events)
                        buffer.removeFirst()
                    }
                    continue
                }
                if !final, buffer.count <= Self.maxTagLength + 1, !buffer.contains("\n") {
                    return events // wait for "]"
                }
                append(.content("["), to: &events)
                buffer.removeFirst()

            case .toolCall:
                if let r = buffer.range(of: Self.toolClose) {
                    let body = String(buffer[..<r.lowerBound])
                    buffer = String(buffer[r.upperBound...])
                    state = .content
                    if let call = Self.parseToolCall(body) {
                        completedToolCalls.append(call)
                        events.append(.toolCall(call))
                    } else {
                        events.append(.malformedToolCall(body))
                    }
                    continue
                }
                if final {
                    // Unterminated block at end of stream: try to salvage it.
                    if salvage, let call = Self.parseToolCall(buffer) {
                        completedToolCalls.append(call)
                        events.append(.toolCall(call))
                    } else {
                        events.append(.malformedToolCall(buffer))
                    }
                    buffer = ""
                }
                return events
            }
        }
        return events
    }

    private func append(_ event: OutputEvent, to events: inout [OutputEvent]) {
        switch event {
        case .content(let s) where s.isEmpty, .reasoning(let s) where s.isEmpty: return
        case .content(let s):
            if case .content(let prev)? = events.last { events[events.count - 1] = .content(prev + s) } else { events.append(event) }
        case .reasoning(let s):
            if case .reasoning(let prev)? = events.last { events[events.count - 1] = .reasoning(prev + s) } else { events.append(event) }
        default: events.append(event)
        }
    }

    /// Length of the longest suffix of `text` that is a proper prefix of any tag.
    static func partialSuffixLength(of text: String, matching tags: [String]) -> Int {
        var best = 0
        for tag in tags {
            let maxLen = min(tag.count - 1, text.count)
            guard maxLen > 0 else { continue }
            for len in stride(from: maxLen, to: best, by: -1) where text.hasSuffix(tag.prefix(len)) {
                best = len
                break
            }
        }
        return best
    }

    /// Parses `<function=name>\n<parameter=k>\nv\n</parameter>\n</function>`.
    public static func parseToolCall(_ body: String) -> ToolCall? {
        guard let fStart = body.range(of: "<function=") else { return nil }
        guard let nameEnd = body.range(of: ">", range: fStart.upperBound..<body.endIndex) else { return nil }
        let name = body[fStart.upperBound..<nameEnd.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        var args: [ToolArgument] = []
        var cursor = nameEnd.upperBound
        while let pStart = body.range(of: "<parameter=", range: cursor..<body.endIndex),
              let pNameEnd = body.range(of: ">", range: pStart.upperBound..<body.endIndex) {
            let key = body[pStart.upperBound..<pNameEnd.lowerBound].trimmingCharacters(in: .whitespaces)
            let valueEnd = body.range(of: "</parameter>", range: pNameEnd.upperBound..<body.endIndex)
            // Tolerate a missing </parameter>: value runs to the next tag.
            let stop = valueEnd?.lowerBound
                ?? body.range(of: "<parameter=", range: pNameEnd.upperBound..<body.endIndex)?.lowerBound
                ?? body.range(of: "</function>", range: pNameEnd.upperBound..<body.endIndex)?.lowerBound
                ?? body.endIndex
            var value = String(body[pNameEnd.upperBound..<stop])
            if value.hasPrefix("\n") { value.removeFirst() }
            if value.hasSuffix("\n") { value.removeLast() }
            args.append(ToolArgument(key, value))
            cursor = valueEnd?.upperBound ?? stop
        }
        return ToolCall(name: name, arguments: args)
    }
}
