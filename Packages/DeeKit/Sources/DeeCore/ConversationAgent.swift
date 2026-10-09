import Foundation

/// Everything the UI, voice and face need to know while Dee answers.
public enum AgentEvent: Sendable, Equatable {
    /// Thinking mode switched for this conversation (user asked, or new conversation).
    case thinkingModeChanged(Bool)
    /// A generation step began (`step` > 0 means a follow-up after tool results).
    case generationStarted(step: Int)
    case reasoning(String)
    case content(String)
    case emotion(Emotion)
    case toolCall(ToolCall)
    case toolResult(name: String, result: String)
    /// The reasoning budget ran out and the answer was forced.
    case reasoningBudgetExhausted
    /// Old turns were dropped to fit the context window.
    case compacted(droppedMessages: Int)
    /// One assistant message is complete (there may be several per turn with tools).
    case messageCompleted(ChatMessage)
    /// The whole turn is done.
    case turnCompleted
}

public struct AgentConfig: Sendable {
    /// Tokens kept free for the reply when thinking is off / on.
    public var replyReserve: Int = 640
    public var thinkingReplyReserve: Int = 1600
    /// Max tokens of reasoning before Dee is nudged to answer.
    public var reasoningBudget: Int = 1024
    public var maxReplyTokens: Int = 512
    public var maxToolRounds: Int = 4
    public var chatSampling: SamplingConfig = .chat
    public var thinkingSampling: SamplingConfig = .thinking

    public init() {}

    /// Appended to the reasoning when the budget runs out (then `</think>`).
    static let budgetNudge = "\n\nI have thought about this enough; time to answer briefly.\n</think>\n\n"
}

/// Drives one conversation: prompt rendering, thinking mode, the generate → tool →
/// generate loop, and context-window management.
public actor ConversationAgent {
    public let generator: any TextGenerator
    public private(set) var tools: ToolRegistry
    public private(set) var messages: [ChatMessage] = []
    public private(set) var thinkingEnabled = false
    public var config: AgentConfig
    private var persona: Persona
    private var conversationStart: Date

    public init(generator: any TextGenerator, tools: ToolRegistry = ToolRegistry(), persona: Persona = Persona(), config: AgentConfig = AgentConfig(), now: Date = Date()) {
        self.generator = generator
        self.tools = tools
        self.persona = persona
        self.config = config
        self.conversationStart = now
        self.messages = [.system(persona.systemPrompt(date: now))]
    }

    // MARK: - Conversation lifecycle

    /// Starts over: clears history, turns thinking off, forgets model state.
    public func newConversation(persona: Persona? = nil, now: Date = Date()) async {
        if let persona { self.persona = persona }
        conversationStart = now
        messages = [.system(self.persona.systemPrompt(date: now))]
        thinkingEnabled = false
        await generator.reset()
        await generator.setPinnedPrefix(systemBlock())
    }

    /// Restores a saved conversation (thinking state included).
    public func restore(messages saved: [ChatMessage], thinking: Bool) async {
        guard saved.first?.role == .system else { return }
        messages = saved
        thinkingEnabled = thinking
        await generator.reset()
        await generator.setPinnedPrefix(systemBlock())
    }

    public func setTools(_ registry: ToolRegistry) async {
        tools = registry
        await generator.setPinnedPrefix(systemBlock())
    }

    public func setThinking(_ on: Bool) { thinkingEnabled = on }

    /// Stops the current turn: the in-flight generation ends, no further phases,
    /// tool calls or follow-up steps run. Sticky until the next turn starts.
    public func cancel() {
        turnCancelled = true
        generator.cancel()
    }

    private var turnCancelled = false
    private var isCancelled: Bool { turnCancelled || Task.isCancelled }

    /// The system block exactly as rendered at the head of every prompt.
    func systemBlock() -> String {
        guard let system = messages.first, system.role == .system else { return "" }
        // Render with a throwaway user turn and cut at its start.
        let probe = PromptBuilder.render([system, .user("x")], tools: tools.specs, addGenerationPrompt: false)
        return probe.components(separatedBy: "\(PromptBuilder.imStart)user\n").first ?? ""
    }

    // MARK: - Responding

    /// Handles one user utterance end to end.
    /// - Parameter state: optional inner-state note (from DeeMind) prepended to the
    ///   user's turn, e.g. `<dee_state>Toward your human: fond of them…</dee_state>`.
    public nonisolated func respond(to text: String, state: String? = nil) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runTurn(text, state: state, emit: { continuation.yield($0) })
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable reason in
                guard case .cancelled = reason else { return }
                task.cancel()
                Task { await self.cancel() }
            }
        }
    }

    private func runTurn(_ text: String, state: String?, emit: @Sendable (AgentEvent) -> Void) async throws {
        turnCancelled = false
        switch ThinkingIntent.detect(in: text) {
        case .enable where !thinkingEnabled:
            thinkingEnabled = true
            emit(.thinkingModeChanged(true))
        case .disable where thinkingEnabled:
            thinkingEnabled = false
            emit(.thinkingModeChanged(false))
        default: break
        }

        let spoken = PromptBuilder.sanitize(text)
        messages.append(.user(state.map { "\($0)\n\(spoken)" } ?? spoken))
        let userIndex = messages.count - 1

        for step in 0...config.maxToolRounds {
            if isCancelled { break }
            // Only the first step of a turn may think; follow-ups after tool results
            // answer directly (the template's own convention for the current turn).
            let thinking = thinkingEnabled && step == 0
            let prompt: String
            do {
                prompt = try await preparePrompt(thinking: thinking, emit: emit)
            } catch {
                // Leave history well-formed: an unanswered user turn would poison
                // every later prompt.
                if step == 0, messages.indices.contains(userIndex), messages[userIndex].role == .user, userIndex == messages.count - 1 {
                    messages.removeLast()
                }
                throw error
            }
            emit(.generationStarted(step: step))

            let message = try await generateMessage(prompt: prompt, thinking: thinking, emit: emit)
            messages.append(message)
            emit(.messageCompleted(message))

            guard !message.toolCalls.isEmpty else { break }
            if isCancelled || step == config.maxToolRounds {
                // Keep the transcript well-formed: every call gets a response.
                for _ in message.toolCalls {
                    messages.append(.tool(isCancelled ? "Skipped: the user interrupted." : "Skipped: too many tool calls in one turn."))
                }
                break
            }
            for call in message.toolCalls {
                let result = PromptBuilder.sanitize(await tools.execute(call))
                emit(.toolResult(name: call.name, result: result))
                messages.append(.tool(result))
            }
        }
        emit(.turnCompleted)
    }

    /// Renders the prompt, compacting history first if it would not fit.
    private func preparePrompt(thinking: Bool, emit: @Sendable (AgentEvent) -> Void) async throws -> String {
        let reserve = thinking ? config.thinkingReplyReserve : config.replyReserve
        let budget = generator.contextLength - reserve
        var prompt = render(thinking: thinking)
        var count = try await generator.tokenCount(prompt)
        guard count > budget else { return prompt }

        // A full re-prefill is coming anyway: first shed stale reasoning, which
        // alone may be enough to fit.
        stripHistoricalRawCompletions()
        prompt = render(thinking: thinking)
        count = try await generator.tokenCount(prompt)

        // Then drop the oldest whole exchanges (keep system + the current user turn).
        var dropped = 0
        while count > budget {
            guard let cut = oldestDroppableRange() else {
                throw GeneratorError.contextOverflow(needed: count + reserve, available: generator.contextLength)
            }
            dropped += cut.count
            messages.removeSubrange(cut)
            prompt = render(thinking: thinking)
            count = try await generator.tokenCount(prompt)
        }
        emit(.compacted(droppedMessages: dropped))
        return prompt
    }

    func render(thinking: Bool) -> String {
        PromptBuilder.render(messages, tools: tools.specs, addGenerationPrompt: true, enableThinking: thinking, mode: .verbatim)
    }

    /// Range from the first non-system message up to (not including) the next user
    /// message — one complete exchange. Never touches the latest user query.
    func oldestDroppableRange() -> Range<Int>? {
        guard let lastUser = messages.lastIndex(where: { $0.role == .user }), lastUser > 1 else { return nil }
        let start = 1
        var end = start + 1
        while end < lastUser, messages[end].role != .user { end += 1 }
        return start..<end
    }

    func stripHistoricalRawCompletions() {
        guard let lastUser = messages.lastIndex(where: { $0.role == .user }) else { return }
        for i in messages.indices where i < lastUser && messages[i].role == .assistant {
            messages[i].rawCompletion = nil
        }
    }

    private func generateMessage(prompt: String, thinking: Bool, emit: @Sendable (AgentEvent) -> Void) async throws -> ChatMessage {
        var acc = MessageAccumulator(thinking: thinking)

        if thinking {
            // Phase 1: reasoning only, stopping at </think> or the budget.
            try await stream(prompt, &acc, GenerationOptions(sampling: config.thinkingSampling, maxTokens: config.reasoningBudget, stopSequences: ["</think>"]), emit)
            if acc.parser.isReasoning, !generator.lastStopWasEndOfGeneration, !isCancelled {
                emit(.reasoningBudgetExhausted)
                acc.feed(AgentConfig.budgetNudge, emit)
            }
            // Phase 2: the answer.
            if !generator.lastStopWasEndOfGeneration, !isCancelled {
                try await stream(prompt, &acc, GenerationOptions(sampling: config.chatSampling, maxTokens: config.maxReplyTokens), emit)
            }
        } else {
            try await stream(prompt, &acc, GenerationOptions(sampling: config.chatSampling, maxTokens: config.maxReplyTokens), emit)
        }
        // Only trust an unterminated tool call if the model ended the turn itself.
        acc.finish(salvageToolCall: generator.lastStopWasEndOfGeneration && !isCancelled, emit)
        return acc.message()
    }

    /// Streams one generation into `acc`. Never breaks out early: every piece the
    /// engine evaluated must land in `acc.raw`, so the next prompt is an exact
    /// extension of the engine's state.
    private func stream(_ prompt: String, _ acc: inout MessageAccumulator, _ options: GenerationOptions, _ emit: @Sendable (AgentEvent) -> Void) async throws {
        let full = prompt + acc.generatedSoFar
        for try await piece in generator.generate(prompt: full, options: options) {
            acc.feed(piece, emit)
        }
    }
}

/// Collects one assistant message from the raw stream.
struct MessageAccumulator: Sendable {
    var parser: OutputParser
    let prefix: String
    var raw: String
    var content = ""
    var reasoning = ""
    var calls: [ToolCall] = []

    init(thinking: Bool) {
        parser = OutputParser(thinking: thinking)
        prefix = PromptBuilder.generationPrefix(thinking: thinking)
        raw = prefix
    }

    /// Text generated after the prompt's generation prefix.
    var generatedSoFar: String { String(raw.dropFirst(prefix.count)) }

    mutating func feed(_ piece: String, _ emit: @Sendable (AgentEvent) -> Void) {
        raw += piece
        handle(parser.feed(piece), emit)
    }

    mutating func finish(salvageToolCall: Bool, _ emit: @Sendable (AgentEvent) -> Void) {
        handle(parser.finish(salvageToolCall: salvageToolCall), emit)
    }

    private mutating func handle(_ events: [OutputEvent], _ emit: @Sendable (AgentEvent) -> Void) {
        for event in events {
            switch event {
            case .reasoning(let s): reasoning += s; emit(.reasoning(s))
            case .content(let s): content += s; emit(.content(s))
            case .emotion(let e): emit(.emotion(e))
            case .toolCall(let c): calls.append(c); emit(.toolCall(c))
            case .malformedToolCall: break
            }
        }
    }

    func message() -> ChatMessage {
        let r = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatMessage(
            role: .assistant,
            content: content.trimmingCharacters(in: .whitespacesAndNewlines),
            reasoning: r.isEmpty ? nil : r,
            toolCalls: calls,
            rawCompletion: raw
        )
    }
}
