import Testing
@testable import DeeCore

// MARK: - Helpers

/// Feeds `pieces` one at a time, then finishes.
private func run(_ pieces: [String], thinking: Bool = false) -> [OutputEvent] {
    var parser = OutputParser(thinking: thinking)
    var events: [OutputEvent] = []
    for p in pieces { events += parser.feed(p) }
    events += parser.finish()
    return events
}

private func run(_ text: String, thinking: Bool = false) -> [OutputEvent] {
    run([text], thinking: thinking)
}

/// Merges adjacent content/content and reasoning/reasoning events; drops empty text events.
private func normalize(_ events: [OutputEvent]) -> [OutputEvent] {
    var out: [OutputEvent] = []
    for e in events {
        switch e {
        case .content(let s):
            if s.isEmpty { continue }
            if case .content(let prev)? = out.last { out[out.count - 1] = .content(prev + s) } else { out.append(e) }
        case .reasoning(let s):
            if s.isEmpty { continue }
            if case .reasoning(let prev)? = out.last { out[out.count - 1] = .reasoning(prev + s) } else { out.append(e) }
        default:
            out.append(e)
        }
    }
    return out
}

private func chunks(_ text: String, size: Int) -> [String] {
    var result: [String] = []
    var current = ""
    for ch in text {
        current.append(ch)
        if current.count == size { result.append(current); current = "" }
    }
    if !current.isEmpty { result.append(current) }
    return result
}

/// Deterministic pseudo-random chunk sizes 1...5 (LCG seeded).
private func lcgChunks(_ text: String, seed: UInt64) -> [String] {
    var state = seed &* 6364136223846793005 &+ 1442695040888963407
    var result: [String] = []
    var current = ""
    var target = 1
    for ch in text {
        current.append(ch)
        if current.count >= target {
            result.append(current); current = ""
            state = state &* 6364136223846793005 &+ 1442695040888963407
            target = Int((state >> 33) % 5) + 1
        }
    }
    if !current.isEmpty { result.append(current) }
    return result
}

/// All chunkings exercised by the property test.
private func allChunkings(_ text: String) -> [[String]] {
    var result: [[String]] = []
    let chars = Array(text)
    for i in 0...chars.count {
        result.append([String(chars[..<i]), String(chars[i...])])
    }
    result.append(chunks(text, size: 1))
    result.append(chunks(text, size: 3))
    result.append(chunks(text, size: 7))
    for seed in 1...4 { result.append(lcgChunks(text, seed: UInt64(seed))) }
    return result
}

/// Returns a description of the first chunking whose events differ from the whole-text events.
private func chunkingMismatch(_ text: String, thinking: Bool) -> String? {
    let whole = normalize(run(text, thinking: thinking))
    for pieces in allChunkings(text) {
        let got = normalize(run(pieces, thinking: thinking))
        if got != whole {
            return "pieces=\(pieces.map { String(reflecting: $0) })\n whole=\(whole)\n   got=\(got)"
        }
    }
    return nil
}

// MARK: - Suite

@Suite struct OutputParserTests {

    // MARK: Plain content

    @Test func plainContent() {
        #expect(normalize(run("Hello there, friend!")) == [.content("Hello there, friend!")])
    }

    @Test func emptyStream() {
        #expect(run("") == [])
        #expect(run([], thinking: true) == [])
    }

    @Test func contentIsEmittedIncrementally() {
        var p = OutputParser(thinking: false)
        #expect(p.feed("Hello ") == [.content("Hello ")])
        #expect(p.feed("world") == [.content("world")])
        #expect(p.finish() == [])
    }

    @Test func partialTagTailIsHeldBackThenFlushed() {
        var p = OutputParser(thinking: false)
        #expect(p.feed("a <tool_") == [.content("a ")])
        #expect(p.finish() == [.content("<tool_")])
    }

    @Test func lessThanThatIsNotATagPassesThrough() {
        #expect(normalize(run(["1 <", " 2 and x<y"])) == [.content("1 < 2 and x<y")])
    }

    // MARK: Emotion tags

    @Test func lowercaseEmotionTag() {
        #expect(normalize(run("[happy] Hi!")) == [.emotion(.happy), .content("Hi!")])
    }

    @Test func capitalizedEmotionTag() {
        #expect(normalize(run("[Happy] Hi!")) == [.emotion(.happy), .content("Hi!")])
    }

    @Test func synonymEmotionTag() {
        #expect(normalize(run("[laughing] Ha")) == [.emotion(.joy), .content("Ha")])
        #expect(normalize(run("[shocked]Oh")) == [.emotion(.surprised), .content("Oh")])
    }

    @Test func emoPrefixedTag() {
        #expect(normalize(run("[emo:sad] Oh no.")) == [.emotion(.sad), .content("Oh no.")])
    }

    @Test func emotionTagMidSentence() {
        #expect(normalize(run("Well [curious] what is that?"))
                == [.content("Well "), .emotion(.curious), .content("what is that?")])
    }

    @Test func multipleEmotionTags() {
        #expect(normalize(run("[sad] Oh. [excited] Wait, yes!"))
                == [.emotion(.sad), .content("Oh. "), .emotion(.excited), .content("Wait, yes!")])
    }

    @Test func unknownTagPassesThroughAsText() {
        #expect(normalize(run("[foo] bar")) == [.content("[foo] bar")])
    }

    @Test func footnotePassesThroughAsText() {
        #expect(normalize(run("See note [1] for more.")) == [.content("See note [1] for more.")])
    }

    @Test func overlongBracketPassesThrough() {
        let text = "[this is a really long bracketed aside] ok"
        #expect(normalize(run(text)) == [.content(text)])
    }

    @Test func unterminatedBracketAtEndIsFlushedAsText() {
        #expect(normalize(run("Look at this [")) == [.content("Look at this [")])
        #expect(normalize(run("Look [hap")) == [.content("Look [hap")])
    }

    @Test func unterminatedBracketIsHeldUntilClose() {
        var p = OutputParser(thinking: false)
        #expect(p.feed("Hi [hap") == [.content("Hi ")])
        #expect(p.feed("py] there") == [.emotion(.happy), .content("there")])
        #expect(p.finish() == [])
    }

    @Test func bracketWithNewlineIsNotWaitedOn() {
        var p = OutputParser(thinking: false)
        #expect(normalize(p.feed("[a\nb")) == [.content("[a\nb")])
    }

    @Test func tagThenSpaceSplitAcrossPieces() {
        #expect(normalize(run(["[happy]", " Hi"])) == [.emotion(.happy), .content("Hi")])
        #expect(normalize(run(["[happy]", "", " Hi"])) == [.emotion(.happy), .content("Hi")])
    }

    @Test func onlyOneSpaceIsSwallowedAfterTag() {
        #expect(normalize(run("[happy]  Hi")) == [.emotion(.happy), .content(" Hi")])
    }

    @Test func tagAtEndOfStream() {
        #expect(normalize(run("Bye [sleepy]")) == [.content("Bye "), .emotion(.sleepy)])
    }

    // MARK: Reasoning mode

    @Test func reasoningThenContent() {
        #expect(normalize(run("Let me think.</think>\n\n[happy] Sure!", thinking: true))
                == [.reasoning("Let me think."), .emotion(.happy), .content("Sure!")])
    }

    @Test func doubleNewlineAfterThinkCloseIsDropped() {
        #expect(normalize(run("hmm</think>\n\nAnswer", thinking: true))
                == [.reasoning("hmm"), .content("Answer")])
    }

    @Test func isReasoningFlips() {
        var p = OutputParser(thinking: true)
        #expect(p.isReasoning)
        _ = p.feed("x</think>")
        #expect(!p.isReasoning)
        #expect(!OutputParser(thinking: false).isReasoning)
    }

    @Test func reasoningPartialCloseHeldBack() {
        var p = OutputParser(thinking: true)
        #expect(p.feed("abc</thi") == [.reasoning("abc")])
        #expect(p.feed("nk>\n\nDone") == [.content("Done")])
    }

    @Test func unterminatedReasoningFlushedAtFinish() {
        #expect(normalize(run("still thinking </th", thinking: true)) == [.reasoning("still thinking </th")])
    }

    @Test func emotionTagsInsideReasoningAreLiteral() {
        #expect(normalize(run("[happy] maybe</think>ok", thinking: true))
                == [.reasoning("[happy] maybe"), .content("ok")])
    }

    @Test func strayThinkTagsInContentAreDropped() {
        #expect(normalize(run("Hello <think>there</think> friend"))
                == [.content("Hello there friend")])
        #expect(normalize(run("a</think>b")) == [.content("ab")])
    }

    @Test func strayCloseBeforeOpenInSameBuffer() {
        // Source picks `<think>` range first even when `</think>` occurs earlier.
        #expect(normalize(run("a</think>b<think>c")) == [.content("abc")])
    }

    // MARK: Tool calls

    private let weatherCall = "<tool_call>\n<function=get_weather>\n<parameter=city>\nParis\n</parameter>\n</function>\n</tool_call>"

    @Test func singleToolCall() {
        var p = OutputParser(thinking: false)
        var events = p.feed(weatherCall)
        events += p.finish()
        let call = ToolCall(name: "get_weather", arguments: [ToolArgument("city", "Paris")])
        #expect(normalize(events) == [.toolCall(call)])
        #expect(p.completedToolCalls == [call])
    }

    @Test func multipleToolCalls() {
        let text = weatherCall + "\n<tool_call>\n<function=clock>\n</function>\n</tool_call>"
        var p = OutputParser(thinking: false)
        var events = p.feed(text)
        events += p.finish()
        let a = ToolCall(name: "get_weather", arguments: [ToolArgument("city", "Paris")])
        let b = ToolCall(name: "clock")
        #expect(normalize(events) == [.toolCall(a), .content("\n"), .toolCall(b)])
        #expect(p.completedToolCalls == [a, b])
    }

    @Test func contentBeforeToolCall() {
        let text = "[curious] Let me check. " + weatherCall
        #expect(normalize(run(text)) == [
            .emotion(.curious), .content("Let me check. "),
            .toolCall(ToolCall(name: "get_weather", arguments: [ToolArgument("city", "Paris")])),
        ])
    }

    @Test func toolCallHeldUntilClosed() {
        var p = OutputParser(thinking: false)
        #expect(p.feed("<tool_call>\n<function=x>") == [])
        #expect(p.feed("\n</function>\n</tool_") == [])
        #expect(p.feed("call>") == [.toolCall(ToolCall(name: "x"))])
    }

    @Test func multiLineParameterValue() {
        let text = "<tool_call>\n<function=note>\n<parameter=body>\nline one\nline two\n\nline four\n</parameter>\n<parameter=title>\nT\n</parameter>\n</function>\n</tool_call>"
        let expected = ToolCall(name: "note", arguments: [
            ToolArgument("body", "line one\nline two\n\nline four"),
            ToolArgument("title", "T"),
        ])
        #expect(normalize(run(text)) == [.toolCall(expected)])
    }

    @Test func missingParameterCloseRunsToNextTag() {
        let text = "<tool_call>\n<function=f>\n<parameter=a>\n1\n<parameter=b>\n2\n</function>\n</tool_call>"
        let expected = ToolCall(name: "f", arguments: [ToolArgument("a", "1"), ToolArgument("b", "2")])
        #expect(normalize(run(text)) == [.toolCall(expected)])
    }

    @Test func unterminatedToolCallIsSalvaged() {
        let text = "Sure. <tool_call>\n<function=get_weather>\n<parameter=city>\nRome\n</parameter>\n</function>"
        var p = OutputParser(thinking: false)
        var events = p.feed(text)
        #expect(normalize(events) == [.content("Sure. ")])
        events += p.finish()
        let call = ToolCall(name: "get_weather", arguments: [ToolArgument("city", "Rome")])
        #expect(normalize(events) == [.content("Sure. "), .toolCall(call)])
        #expect(p.completedToolCalls == [call])
    }

    @Test func unterminatedGarbageToolCallIsMalformed() {
        #expect(normalize(run("<tool_call>\nnot a call")) == [.malformedToolCall("\nnot a call")])
    }

    @Test func garbageToolCallIsMalformed() {
        var p = OutputParser(thinking: false)
        var events = p.feed("<tool_call>{\"name\": \"x\"}</tool_call> after")
        events += p.finish()
        #expect(normalize(events) == [.malformedToolCall("{\"name\": \"x\"}"), .content(" after")])
        #expect(p.completedToolCalls.isEmpty)
    }

    @Test func emptyFunctionNameIsMalformed() {
        #expect(normalize(run("<tool_call><function=  ></function></tool_call>"))
                == [.malformedToolCall("<function=  ></function>")])
    }

    @Test func emotionTagAfterToolCall() {
        let text = "<tool_call><function=x></function></tool_call>[happy] Done"
        #expect(normalize(run(text)) == [.toolCall(ToolCall(name: "x")), .emotion(.happy), .content("Done")])
    }

    // MARK: partialSuffixLength

    @Test func partialSuffixLengthCases() {
        let tags = ["<tool_call>", "<think>", "</think>"]
        #expect(OutputParser.partialSuffixLength(of: "", matching: tags) == 0)
        #expect(OutputParser.partialSuffixLength(of: "hello", matching: tags) == 0)
        #expect(OutputParser.partialSuffixLength(of: "hello <", matching: tags) == 1)
        #expect(OutputParser.partialSuffixLength(of: "x</", matching: tags) == 2)
        #expect(OutputParser.partialSuffixLength(of: "x<t", matching: tags) == 2)
        #expect(OutputParser.partialSuffixLength(of: "x<tool_cal", matching: tags) == 9)
        #expect(OutputParser.partialSuffixLength(of: "x</think", matching: tags) == 7)
        // A complete tag is not a *proper* prefix.
        #expect(OutputParser.partialSuffixLength(of: "<think>", matching: ["<think>"]) == 0)
        // Shorter than tag, entire text is a prefix.
        #expect(OutputParser.partialSuffixLength(of: "<thi", matching: ["<think>"]) == 4)
        #expect(OutputParser.partialSuffixLength(of: "<x", matching: tags) == 0)
        #expect(OutputParser.partialSuffixLength(of: "abc", matching: []) == 0)
        // Longest match across tags wins.
        #expect(OutputParser.partialSuffixLength(of: "a<", matching: ["<b", "<"]) == 1)
        #expect(OutputParser.partialSuffixLength(of: "a</thin", matching: ["<think>", "</think>"]) == 6)
    }

    // MARK: parseToolCall

    @Test func parseToolCallBasic() {
        let call = OutputParser.parseToolCall("\n<function=get_time>\n<parameter=zone>\nUTC\n</parameter>\n</function>\n")
        #expect(call == ToolCall(name: "get_time", arguments: [ToolArgument("zone", "UTC")]))
        #expect(call?["zone"] == "UTC")
    }

    @Test func parseToolCallNoArguments() {
        #expect(OutputParser.parseToolCall("<function=clock></function>") == ToolCall(name: "clock"))
    }

    @Test func parseToolCallTrimsNames() {
        #expect(OutputParser.parseToolCall("<function= f >\n<parameter= k >v</parameter></function>")
                == ToolCall(name: "f", arguments: [ToolArgument("k", "v")]))
    }

    @Test func parseToolCallStripsOnlyOneNewline() {
        #expect(OutputParser.parseToolCall("<function=f><parameter=k>\n\nv\n\n</parameter></function>")
                == ToolCall(name: "f", arguments: [ToolArgument("k", "\nv\n")]))
    }

    @Test func parseToolCallMissingParameterCloseBeforeFunctionClose() {
        #expect(OutputParser.parseToolCall("<function=f><parameter=k>\nv\n</function>")
                == ToolCall(name: "f", arguments: [ToolArgument("k", "v")]))
    }

    @Test func parseToolCallMissingEverythingRunsToEnd() {
        #expect(OutputParser.parseToolCall("<function=f><parameter=k>\nvalue")
                == ToolCall(name: "f", arguments: [ToolArgument("k", "value")]))
    }

    @Test func parseToolCallRejectsGarbage() {
        #expect(OutputParser.parseToolCall("") == nil)
        #expect(OutputParser.parseToolCall("{\"name\":\"x\"}") == nil)
        #expect(OutputParser.parseToolCall("<function=noclose") == nil)
        #expect(OutputParser.parseToolCall("<function=></function>") == nil)
    }

    @Test func parseToolCallValueContainingAngleBrackets() {
        #expect(OutputParser.parseToolCall("<function=f><parameter=expr>\n1 < 2 > 0\n</parameter></function>")
                == ToolCall(name: "f", arguments: [ToolArgument("expr", "1 < 2 > 0")]))
    }

    // MARK: Chunking property

    struct Sample: Sendable, CustomTestStringConvertible {
        let text: String
        let thinking: Bool
        var testDescription: String { (thinking ? "[T] " : "") + String(reflecting: text) }
    }

    static let samples: [Sample] = [
        .init(text: "Hello world", thinking: false),
        .init(text: "[happy] Hi there!", thinking: false),
        .init(text: "[Happy] Hi", thinking: false),
        .init(text: "[laughing] That's funny.", thinking: false),
        .init(text: "[emo:sad] Oh no.", thinking: false),
        .init(text: "[foo] bar", thinking: false),
        .init(text: "See [1] and [2].", thinking: false),
        .init(text: "Look at this [", thinking: false),
        .init(text: "Look [hap", thinking: false),
        .init(text: "[sad]Oh. [excited] Yes!", thinking: false),
        .init(text: "[happy]  two spaces", thinking: false),
        .init(text: "a < b and c<d <", thinking: false),
        .init(text: "[a\nb] text", thinking: false),
        .init(text: "[this is a really long aside, way too long] ok", thinking: false),
        .init(text: "x <think>y</think> z", thinking: false),
        .init(text: "Hello <thinking about it>", thinking: false),
        .init(text: "<tool_call>\n<function=clock>\n</function>\n</tool_call>", thinking: false),
        .init(text: "[curious] Let me check. <tool_call>\n<function=get_weather>\n<parameter=city>\nParis\n</parameter>\n</function>\n</tool_call>", thinking: false),
        .init(text: "<tool_call><function=a></function></tool_call>\n<tool_call><function=b><parameter=x>1</parameter></function></tool_call> done", thinking: false),
        .init(text: "<tool_call>\n<function=note>\n<parameter=body>\nl1\nl2 [happy] <b>\n</parameter>\n</function>\n</tool_call>", thinking: false),
        .init(text: "<tool_call><function=f><parameter=a>1<parameter=b>2</function></tool_call>", thinking: false),
        .init(text: "Ok <tool_call>\n<function=x>\n<parameter=y>\nz", thinking: false),
        .init(text: "<tool_call>garbage</tool_call>[happy] after", thinking: false),
        .init(text: "<tool_call>junk", thinking: false),
        .init(text: "<tool_call><function=x></function></tool_call>[happy] Done", thinking: false),
        .init(text: "Thinking hard about it. 2 < 3.", thinking: true),
        .init(text: "a </thi b</think>Answer [happy] yes", thinking: true),
        .init(text: "plan [happy] stuff</think>[curious] Hmm <tool_call><function=t></function></tool_call>", thinking: true),
        .init(text: "unterminated reasoning </th", thinking: true),
        .init(text: "caf\u{E9} \u{1F600} [love] \u{2764}\u{FE0F}", thinking: false),
    ]

    /// Samples where "</think>" is followed by newlines; the parser drops them only
    /// when they are already in the buffer at the moment `</think>` is consumed.
    static let thinkNewlineSamples: [Sample] = [
        .init(text: "Let me think.</think>\n\n[happy] Sure!", thinking: true),
        .init(text: "hmm</think>\n\nAnswer", thinking: true),
    ]

    @Test(arguments: samples)
    func chunkingInvariance(_ sample: Sample) {
        let mismatch = chunkingMismatch(sample.text, thinking: sample.thinking)
        #expect(mismatch == nil, "\(mismatch ?? "")")
    }

    @Test(arguments: thinkNewlineSamples)
    func chunkingInvarianceAfterThinkClose(_ sample: Sample) {
        let mismatch = chunkingMismatch(sample.text, thinking: sample.thinking)
        #expect(mismatch == nil, "\(mismatch ?? "")")
    }

    @Test func newlinesAfterThinkCloseSplitAcrossPieces() {
        #expect(normalize(run(["hmm</think>", "\n\nAnswer"], thinking: true))
                == [.reasoning("hmm"), .content("Answer")])
    }
}
