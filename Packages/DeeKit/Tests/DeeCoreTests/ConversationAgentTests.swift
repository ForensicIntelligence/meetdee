import Foundation
import Testing
@testable import DeeCore

// MARK: - Fakes

/// A deterministic stand-in for the llama.cpp engine.
///
/// Each `generate` call consumes the next scripted output (split into small pieces;
/// special tags are always whole pieces, like real special tokens). It emulates an
/// append-only engine: it remembers everything "evaluated" (`cached`) and counts every
/// prompt that is not an extension of it as a full prefill. When a generation stops at
/// a stop sequence or `maxTokens`, the unread rest of the script is kept and resumed if
/// the next prompt is exactly the cached state (the model simply carries on).
final class ScriptedGenerator: TextGenerator, @unchecked Sendable {
    struct Call {
        let prompt: String
        let options: GenerationOptions
    }

    private let lock = NSLock()
    private var scripts: [String]
    private var remainder: [String] = []
    private var _calls: [Call] = []
    private var _cached = ""
    private var _fullPrefills = 0
    private var _lastEOG = false
    private var _cancelCount = 0
    private var _resetCount = 0
    private var _pinned: [String] = []
    private var _contextLength: Int
    private var cancelled = false
    private let pieceSize: Int
    private let hangs: Bool

    init(_ scripts: [String] = [], contextLength: Int = 32_768, pieceSize: Int = 4, hangs: Bool = false) {
        self.scripts = scripts
        self._contextLength = contextLength
        self.pieceSize = pieceSize
        self.hangs = hangs
    }

    var contextLength: Int {
        get { lock.withLock { _contextLength } }
        set { lock.withLock { _contextLength = newValue } }
    }
    var calls: [Call] { lock.withLock { _calls } }
    var prompts: [String] { calls.map(\.prompt) }
    var cached: String { lock.withLock { _cached } }
    var fullPrefills: Int { lock.withLock { _fullPrefills } }
    var cancelCount: Int { lock.withLock { _cancelCount } }
    var resetCount: Int { lock.withLock { _resetCount } }
    var pinnedPrefixes: [String] { lock.withLock { _pinned } }
    var lastStopWasEndOfGeneration: Bool { lock.withLock { _lastEOG } }
    private var isCancelled: Bool { lock.withLock { cancelled } }

    func enqueue(_ more: String...) { lock.withLock { scripts += more } }

    static let specialTags = ["<think>", "</think>", "<tool_call>", "</tool_call>"]

    static func split(_ text: String, size: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        var rest = Substring(text)
        while !rest.isEmpty {
            if let tag = specialTags.first(where: { rest.hasPrefix($0) }) {
                if !current.isEmpty { pieces.append(current); current = "" }
                pieces.append(tag)
                rest = rest.dropFirst(tag.count)
                continue
            }
            current.append(rest.removeFirst())
            if current.count >= size { pieces.append(current); current = "" }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    func generate(prompt: String, options: GenerationOptions) -> AsyncThrowingStream<String, Error> {
        let (pieces, hang): ([String], Bool) = lock.withLock {
            _calls.append(Call(prompt: prompt, options: options))
            cancelled = false
            if _cached.isEmpty || !prompt.hasPrefix(_cached) { _fullPrefills += 1 }

            let source: [String]
            if prompt == _cached, !remainder.isEmpty {
                source = remainder
            } else {
                source = scripts.isEmpty ? [] : Self.split(scripts.removeFirst(), size: pieceSize)
            }
            var out: [String] = []
            var text = ""
            var eog = true
            var i = 0
            while i < source.count {
                if out.count >= options.maxTokens { eog = false; break }
                let piece = source[i]
                out.append(piece)
                text += piece
                i += 1
                if options.stopSequences.contains(where: { text.hasSuffix($0) }) { eog = false; break }
            }
            remainder = Array(source[i...])
            _lastEOG = eog
            _cached = prompt + text
            return (out, hangs)
        }

        if !hang {
            return AsyncThrowingStream { c in
                for p in pieces { c.yield(p) }
                c.finish()
            }
        }
        return AsyncThrowingStream { c in
            Task {
                for p in pieces { c.yield(p) }
                let deadline = Date().addingTimeInterval(3)
                while !self.isCancelled, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                c.finish()
            }
        }
    }

    func tokenCount(_ text: String) async throws -> Int { text.count / 4 }

    func cancel() {
        lock.withLock {
            cancelled = true
            _cancelCount += 1
        }
    }

    func reset() async {
        lock.withLock {
            _cached = ""
            remainder = []
            _resetCount += 1
        }
    }

    func setPinnedPrefix(_ prefix: String) async {
        lock.withLock { _pinned.append(prefix) }
    }
}

/// Records the calls it receives.
final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [ToolCall] = []
    func record(_ c: ToolCall) { lock.withLock { _calls.append(c) } }
    var calls: [ToolCall] { lock.withLock { _calls } }
}

struct FakeClockTool: AgentTool {
    let log: CallLog
    var spec: ToolSpec {
        ToolSpec(name: "get_time", description: "Current time.", parameters: [ToolParameter("zone", .string, "Time zone.", required: false)])
    }
    func run(_ call: ToolCall) async throws -> String {
        log.record(call)
        return "12:00 \(call["zone"] ?? "local")"
    }
}

// MARK: - Helpers

private let nonThinkingSuffix = "<|im_start|>assistant\n<think>\n\n</think>\n\n"
private let thinkingSuffix = "<|im_start|>assistant\n<think>\n"
private let fixedDate = Date(timeIntervalSince1970: 1_790_000_000)

private func collect(_ agent: ConversationAgent, _ text: String) async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await e in agent.respond(to: text) { events.append(e) }
    return events
}

private func content(_ events: [AgentEvent]) -> String {
    events.compactMap { if case .content(let s) = $0 { s } else { nil } }.joined()
}

private func reasoning(_ events: [AgentEvent]) -> String {
    events.compactMap { if case .reasoning(let s) = $0 { s } else { nil } }.joined()
}

private func toolCallScript(_ name: String, zone: String = "UTC") -> String {
    "<tool_call>\n<function=\(name)>\n<parameter=zone>\n\(zone)\n</parameter>\n</function>\n</tool_call>"
}

private func makeAgent(_ gen: ScriptedGenerator, tools: ToolRegistry = ToolRegistry(), config: AgentConfig = AgentConfig()) -> ConversationAgent {
    ConversationAgent(generator: gen, tools: tools, config: config, now: fixedDate)
}

// MARK: - Tests

@Suite struct ConversationAgentTests {

    // (1)
    @Test func thinkingIsOffByDefault() async throws {
        let gen = ScriptedGenerator(["[happy] Hi there!"])
        let agent = makeAgent(gen)
        #expect(await agent.thinkingEnabled == false)

        let events = try await collect(agent, "Hello Dee")
        #expect(gen.calls.count == 1)
        #expect(gen.prompts[0].hasSuffix(nonThinkingSuffix))
        #expect(gen.calls[0].options.stopSequences.isEmpty)
        #expect(!events.contains(.thinkingModeChanged(true)))
        #expect(reasoning(events).isEmpty)
        #expect(content(events) == "Hi there!")
        #expect(events.last == .turnCompleted)
    }

    // (2)
    @Test func thinkAboutItTurnsThinkingOn() async throws {
        let gen = ScriptedGenerator(["Seven has no divisors besides one and itself.</think>\n\n[happy] Yes, seven is prime."])
        let agent = makeAgent(gen)

        let events = try await collect(agent, "Please think about it: is 7 prime?")
        #expect(events.first == .thinkingModeChanged(true))
        #expect(await agent.thinkingEnabled)

        #expect(gen.calls.count == 2) // reasoning phase + answer phase
        #expect(gen.prompts[0].hasSuffix(thinkingSuffix))
        #expect(gen.calls[0].options.stopSequences.contains("</think>"))
        #expect(gen.calls[0].options.sampling == AgentConfig().thinkingSampling)
        #expect(gen.calls[1].options.sampling == AgentConfig().chatSampling)

        #expect(reasoning(events) == "Seven has no divisors besides one and itself.")
        #expect(content(events).trimmingCharacters(in: .whitespacesAndNewlines) == "Yes, seven is prime.")
        // OutputParser only strips the "\n\n" after </think> when it is already buffered;
        // the engine stops at </think> so it always arrives in the next piece.
        #expect(content(events) == "Yes, seven is prime.")
        #expect(!content(events).contains("</think>"))
        // All reasoning events come before the first content event.
        let lastReasoning = events.lastIndex { if case .reasoning = $0 { true } else { false } }!
        let firstContent = events.firstIndex { if case .content = $0 { true } else { false } }!
        #expect(lastReasoning < firstContent)

        let reply = try #require(await agent.messages.last)
        #expect(reply.role == .assistant)
        #expect(reply.content == "Yes, seven is prime.")
        #expect(reply.reasoning == "Seven has no divisors besides one and itself.")
        #expect(reply.rawCompletion?.hasPrefix("<think>\n") == true)
    }

    // (3)
    @Test func thinkingStaysOnForTheNextTurn() async throws {
        let gen = ScriptedGenerator([
            "Hmm.</think>\n\n[curious] Probably rain.",
            "Again hmm.</think>\n\n[happy] Sunny tomorrow.",
        ])
        let agent = makeAgent(gen)
        _ = try await collect(agent, "Think about it: will it rain today?")
        let events = try await collect(agent, "And what about tomorrow?")

        #expect(!events.contains(.thinkingModeChanged(true)))
        #expect(!events.contains(.thinkingModeChanged(false)))
        #expect(await agent.thinkingEnabled)
        #expect(gen.prompts[2].hasSuffix(thinkingSuffix))
        #expect(gen.calls[2].options.stopSequences.contains("</think>"))
        #expect(reasoning(events) == "Again hmm.")
        #expect(content(events).trimmingCharacters(in: .whitespacesAndNewlines) == "Sunny tomorrow.")
        // OutputParser only strips the "\n\n" after </think> when it is already buffered;
        // the engine stops at </think> so it always arrives in the next piece.
        #expect(content(events) == "Sunny tomorrow.")
    }

    // (4)
    @Test func newConversationTurnsThinkingOffAndResets() async throws {
        let gen = ScriptedGenerator([
            "Pondering.</think>\n\n[happy] Done.",
            "[happy] Hello again!",
        ])
        let agent = makeAgent(gen)
        _ = try await collect(agent, "Think it through: what's 2+2?")
        #expect(await agent.thinkingEnabled)
        #expect(gen.resetCount == 0)

        await agent.newConversation(now: fixedDate)
        #expect(await agent.thinkingEnabled == false)
        #expect(gen.resetCount == 1)
        #expect(await agent.messages.count == 1)
        #expect(await agent.messages.first?.role == .system)
        #expect(gen.pinnedPrefixes.last?.hasPrefix("<|im_start|>system\n") == true)

        let events = try await collect(agent, "Hi!")
        #expect(!events.contains(.thinkingModeChanged(true)))
        #expect(gen.prompts.last?.hasSuffix(nonThinkingSuffix) == true)
        #expect(gen.prompts.last?.contains("Pondering") == false)
        #expect(content(events) == "Hello again!")
    }

    // (5a)
    @Test func toolLoopExecutesToolAndFeedsResultBack() async throws {
        let log = CallLog()
        let gen = ScriptedGenerator([toolCallScript("get_time"), "[happy] It's noon in UTC."])
        let agent = makeAgent(gen, tools: ToolRegistry([FakeClockTool(log: log)]))

        let events = try await collect(agent, "What time is it in UTC?")
        let expectedCall = ToolCall(name: "get_time", arguments: [ToolArgument("zone", "UTC")])

        #expect(log.calls == [expectedCall])
        #expect(events.contains(.toolCall(expectedCall)))
        #expect(events.contains(.toolResult(name: "get_time", result: "12:00 UTC")))
        #expect(events.contains(.generationStarted(step: 0)))
        #expect(events.contains(.generationStarted(step: 1)))
        #expect(gen.calls.count == 2)
        #expect(gen.prompts[0].contains("<tools>"))
        #expect(gen.prompts[1].contains("<tool_response>\n12:00 UTC\n</tool_response>"))
        #expect(gen.prompts[1].hasSuffix(nonThinkingSuffix))
        #expect(content(events) == "It's noon in UTC.")

        let completed = events.compactMap { if case .messageCompleted(let m) = $0 { m } else { nil } }
        #expect(completed.count == 2)
        #expect(completed[0].toolCalls == [expectedCall])
        #expect(completed[1].content == "It's noon in UTC.")
        #expect(await agent.messages.map(\.role) == [.system, .user, .assistant, .tool, .assistant])
    }

    // (5b)
    @Test func unknownToolYieldsErrorResult() async throws {
        let log = CallLog()
        let gen = ScriptedGenerator([toolCallScript("launch_rocket"), "[sad] I can't do that."])
        let agent = makeAgent(gen, tools: ToolRegistry([FakeClockTool(log: log)]))

        let events = try await collect(agent, "Launch the rocket")
        let results = events.compactMap { if case .toolResult(let n, let r) = $0 { (n, r) } else { nil } }
        #expect(results.count == 1)
        #expect(results.first?.0 == "launch_rocket")
        #expect(results.first?.1.hasPrefix("Error: there is no tool named 'launch_rocket'") == true)
        #expect(results.first?.1.contains("get_time") == true)
        #expect(log.calls.isEmpty)
        #expect(gen.prompts[1].contains("<tool_response>\nError: there is no tool named"))
        #expect(content(events) == "I can't do that.")
    }

    // (5c)
    @Test func maxToolRoundsIsRespected() async throws {
        let log = CallLog()
        var config = AgentConfig()
        config.maxToolRounds = 2
        let gen = ScriptedGenerator(Array(repeating: toolCallScript("get_time"), count: 10))
        let agent = makeAgent(gen, tools: ToolRegistry([FakeClockTool(log: log)]), config: config)

        let events = try await collect(agent, "What time is it?")
        #expect(gen.calls.count == 3) // steps 0, 1, 2
        #expect(log.calls.count == 2)
        #expect(events.filter { if case .toolResult = $0 { true } else { false } }.count == 2)
        #expect(!events.contains(.generationStarted(step: 3)))
        #expect(events.last == .turnCompleted)
    }

    // (6)
    @Test func promptsStayAppendOnlyAcrossTurns() async throws {
        let log = CallLog()
        let gen = ScriptedGenerator([
            "[happy] Hi! Nice to meet you.",
            toolCallScript("get_time"),
            "[happy] It's noon.",
            "Lunch at noon is common.</think>\n\n[curious] Maybe a sandwich?",
        ])
        let agent = makeAgent(gen, tools: ToolRegistry([FakeClockTool(log: log)]))

        _ = try await collect(agent, "Hello!")
        _ = try await collect(agent, "What time is it in UTC?")
        let events = try await collect(agent, "Think about it: what should I eat for lunch?")

        #expect(events.contains(.thinkingModeChanged(true)))
        #expect(gen.calls.count == 5)
        #expect(gen.fullPrefills == 1)
        // Every prompt extends the previous engine state.
        let prompts = gen.prompts
        for i in 1..<prompts.count {
            #expect(prompts[i].hasPrefix(prompts[i - 1]), "prompt \(i) does not extend prompt \(i - 1)")
        }
        // The agent's own re-render of history matches what the engine evaluated.
        let rendered = await agent.render(thinking: false)
        let historyEnd = rendered.dropLast(nonThinkingSuffix.count)
        #expect(historyEnd.hasPrefix(gen.cached))
    }

    // (7)
    @Test func reasoningBudgetForcesAnAnswer() async throws {
        var config = AgentConfig()
        config.reasoningBudget = 5
        let gen = ScriptedGenerator([
            "I keep thinking and thinking and thinking and never stopping at all.",
            "[happy] Forty two.",
        ])
        let agent = makeAgent(gen, config: config)

        let events = try await collect(agent, "Think hard: what is the meaning of life?")
        #expect(events.contains(.reasoningBudgetExhausted))
        #expect(gen.calls.count == 2)
        #expect(gen.calls[0].options.maxTokens == 5)
        #expect(gen.prompts[1].hasSuffix(AgentConfig.budgetNudge))
        #expect(gen.prompts[1].hasPrefix(gen.prompts[0]))
        #expect(gen.fullPrefills == 1)
        #expect(content(events) == "Forty two.")
        #expect(!content(events).contains("time to answer"))

        let budgetIndex = events.firstIndex(of: .reasoningBudgetExhausted)!
        let firstContent = events.firstIndex { if case .content = $0 { true } else { false } }!
        #expect(budgetIndex < firstContent)
        let reply = try #require(await agent.messages.last)
        #expect(reply.content == "Forty two.")
        #expect(reply.rawCompletion?.contains(AgentConfig.budgetNudge) == true)
    }

    // (8a)
    @Test func compactionDropsOldestExchange() async throws {
        var config = AgentConfig()
        config.replyReserve = 50
        let gen = ScriptedGenerator(["[happy] One.", "[happy] Two.", "[happy] Three."])
        let agent = makeAgent(gen, config: config)
        let u1 = "first " + String(repeating: "alpha ", count: 150)
        let u2 = "second " + String(repeating: "bravo ", count: 150)
        let u3 = "third " + String(repeating: "charlie ", count: 30)

        let e1 = try await collect(agent, u1)
        let e2 = try await collect(agent, u2)
        #expect(!e1.contains { if case .compacted = $0 { true } else { false } })
        #expect(!e2.contains { if case .compacted = $0 { true } else { false } })

        // Size the window so turn 3 overflows by a little, but fits without exchange 1.
        let next = PromptBuilder.render(await agent.messages + [.user(u3)], addGenerationPrompt: true, enableThinking: false, mode: .verbatim)
        let needed = next.count / 4
        gen.contextLength = needed + config.replyReserve - 20

        let e3 = try await collect(agent, u3)
        #expect(e3.contains(.compacted(droppedMessages: 2)))
        let messages = await agent.messages
        #expect(messages.map(\.role) == [.system, .user, .assistant, .user, .assistant])
        #expect(messages[0].role == .system)
        #expect(messages[1].content == u2)
        #expect(messages[3].content == u3)
        #expect(content(e3) == "Three.")
        let lastPrompt = try #require(gen.prompts.last)
        #expect(!lastPrompt.contains("first alpha"))
        #expect(lastPrompt.contains("second bravo"))
        #expect(lastPrompt.contains("third charlie"))
        #expect(lastPrompt.hasPrefix("<|im_start|>system\nYou are Dee"))
        #expect(lastPrompt.count / 4 <= gen.contextLength - config.replyReserve)
    }

    // (8b)
    @Test func contextOverflowWhenLatestTurnCannotFit() async throws {
        var config = AgentConfig()
        config.replyReserve = 50
        let gen = ScriptedGenerator(["[happy] Never."], contextLength: 600)
        let agent = makeAgent(gen, config: config)
        let huge = String(repeating: "words ", count: 1000)

        await #expect {
            _ = try await collect(agent, huge)
        } throws: { error in
            guard case GeneratorError.contextOverflow(_, let available) = error else { return false }
            return available == 600
        }
        #expect(gen.calls.isEmpty)
    }

    // (9)
    @Test func emotionsAreEventsNotContent() async throws {
        let gen = ScriptedGenerator(["[happy] Hello there! [excited] Let's play a game."], pieceSize: 3)
        let agent = makeAgent(gen)

        let events = try await collect(agent, "Hi")
        let emotions = events.compactMap { if case .emotion(let e) = $0 { e } else { nil } }
        #expect(emotions == [.happy, .excited])
        let text = content(events)
        #expect(!text.contains("["))
        #expect(!text.contains("happy"))
        #expect(text == "Hello there! Let's play a game.")
        #expect(await agent.messages.last?.content == "Hello there! Let's play a game.")
    }

    // (10)
    @Test func cancellingTheStreamCancelsTheGenerator() async throws {
        let gen = ScriptedGenerator(["[happy] Once upon a time"], hangs: true)
        let agent = makeAgent(gen)

        let consumer = Task {
            var n = 0
            do { for try await _ in agent.respond(to: "Tell me a long story") { n += 1 } } catch {}
            return n
        }
        // Wait until generation is under way.
        let start = Date()
        while gen.calls.isEmpty, Date().timeIntervalSince(start) < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!gen.calls.isEmpty)
        #expect(gen.cancelCount == 0)

        consumer.cancel()
        let cancelStart = Date()
        while gen.cancelCount == 0, Date().timeIntervalSince(cancelStart) < 2 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(gen.cancelCount >= 1)
        _ = await consumer.value
    }
}
