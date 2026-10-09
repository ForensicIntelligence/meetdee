import Foundation

/// Streaming filter that removes what must never be spoken (SELF.md §2, §14):
/// parenthesised asides — stage directions like "(smiles)" and leaked cue notes like
/// "(Ask about one choice they made in it.)" — and angle-bracket tags, including the
/// whole body of state/reasoning blocks such as `<dee_state>…</dee_state>` or
/// `<think>…</think>`.
///
/// - `( … )` (and full-width `（ … ）`) is dropped with nesting. An unclosed `(` drops
///   everything to the end of the stream: silence beats speaking a leaked note.
///   Emoticons are kept: a `(` right after `:` `;` `=` is literal (":("), and so is a
///   markdown link target `](url)` (the link text is spoken by `SpeechText.clean`).
/// - `<…>` is a tag only when `<` is followed by a letter, `/` or `!`; "3 < 4" and
///   "<3" are literal. A tag running past a newline or 160 characters was not a tag
///   and is released as text.
/// - Formatting / unknown tags (`<b>`, `<em>`, `<excited>`) drop only the tag itself.
///   State-like tags (`dee_state`, `think`, `note`, anything containing "state" or
///   "think", …) drop their whole body up to the matching `</name>`; unclosed, to the
///   end of the stream.
/// - Feed fragments in any split; the result is the same as filtering the whole text.
struct AsideFilter: Sendable {
    static let blockTags: Set<String> = [
        "dee_state", "deestate", "state", "think", "thinking", "thought", "thoughts", "reasoning", "reflection",
        "scratchpad", "note", "notes", "cue", "system", "internal", "aside", "stage", "stage_direction",
        "inner", "inner_monologue", "monologue", "tool_call", "tool_response", "function_call", "context", "memory",
    ]
    static let maxTagLength = 160

    private enum Mode: Sendable, Equatable {
        case text
        /// Saw `<`; the next character decides.
        case lessThan
        /// Inside `<…`, collecting the tag.
        case tag(String)
        /// Dropping up to `</name>`; `tail` holds the last few characters seen.
        case block(name: String, tail: String)
    }

    private var mode = Mode.text
    private var parenDepth = 0
    private var lastOut: Character?

    init() {}

    /// Filters one fragment; returns the speakable part decided so far.
    mutating func feed(_ fragment: String) -> String {
        var out = ""
        for c in fragment { step(c, into: &out) }
        return out
    }

    /// End of stream: releases a pending literal `<`, drops unclosed asides/blocks.
    mutating func finish() -> String {
        var out = ""
        switch mode {
        case .lessThan: out = "<"
        case .tag(let body): out = "<" + body
        case .text, .block: break
        }
        if parenDepth > 0 { out = "" }
        reset()
        return out
    }

    mutating func reset() {
        mode = .text
        parenDepth = 0
        lastOut = nil
    }

    /// The whole text at once.
    static func strip(_ s: String) -> String {
        var f = AsideFilter()
        return f.feed(s) + f.finish()
    }

    private mutating func emit(_ c: Character, into out: inout String) {
        guard parenDepth == 0 else { return }
        out.append(c)
        lastOut = c
    }

    private mutating func emit(_ s: String, into out: inout String) {
        for c in s { emit(c, into: &out) }
    }

    private mutating func step(_ c: Character, into out: inout String) {
        switch mode {
        case .block(let name, var tail):
            tail.append(contentsOf: c.lowercased())
            let close = "</" + name + ">"
            if tail.hasSuffix(close) {
                mode = .text
            } else {
                if tail.count > close.count + 4 { tail.removeFirst(tail.count - close.count - 4) }
                mode = .block(name: name, tail: tail)
            }
        case .lessThan:
            if c.isLetter || c == "/" || c == "!" {
                mode = .tag(String(c))
            } else {
                mode = .text
                emit("<", into: &out)
                step(c, into: &out)
            }
        case .tag(var body):
            if c == ">" {
                mode = .text
                closeTag(body)
            } else if c == "\n" || body.count >= Self.maxTagLength {
                mode = .text
                emit("<" + body, into: &out)
                step(c, into: &out)
            } else {
                body.append(c)
                mode = .tag(body)
            }
        case .text:
            switch c {
            case "<":
                mode = .lessThan
            case "(", "（":
                if parenDepth == 0, let p = lastOut, p == ":" || p == ";" || p == "=" || p == "]" {
                    emit(c, into: &out)          // emoticon ":(", markdown link "](url)"
                } else {
                    parenDepth += 1
                }
            case ")", "）":
                if parenDepth > 0 { parenDepth -= 1 } else { emit(c, into: &out) }
            default:
                emit(c, into: &out)
            }
        }
    }

    private mutating func closeTag(_ body: String) {
        guard let first = body.first, first.isLetter else { return }   // </x>, <!-- -->: just the tag
        if body.hasSuffix("/") { return }                               // <br/>
        let name = String(body.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ":" }).lowercased()
        if Self.blockTags.contains(name) || name.contains("state") || name.contains("think") {
            mode = .block(name: name, tail: "")
        }
    }
}
