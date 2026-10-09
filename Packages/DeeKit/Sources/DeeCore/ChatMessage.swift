import Foundation

/// Who said a thing. Mirrors the roles the Qwen3.5 chat template understands.
public enum Role: String, Codable, Sendable {
    case system, user, assistant, tool
}

/// One named argument of a tool call. Arguments are kept as an ordered list (not a
/// dictionary) because the chat template renders them in insertion order and the
/// model was trained on that order.
public struct ToolArgument: Codable, Sendable, Equatable {
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// A function call the model asked for, parsed from its
/// `<tool_call><function=name><parameter=k>v</parameter></function></tool_call>` output.
public struct ToolCall: Codable, Sendable, Equatable {
    public var name: String
    public var arguments: [ToolArgument]

    public init(name: String, arguments: [ToolArgument] = []) {
        self.name = name
        self.arguments = arguments
    }

    public subscript(_ key: String) -> String? {
        arguments.first { $0.name == key }?.value
    }
}

public struct ChatMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var role: Role
    /// Visible text. For assistant messages this excludes reasoning and tool-call markup.
    public var content: String
    /// Chain-of-thought produced while thinking mode was on (assistant only).
    public var reasoning: String?
    /// Tool calls the assistant made in this message (assistant only).
    public var toolCalls: [ToolCall]
    /// Assistant only: the exact text the model produced after `<|im_start|>assistant\n`,
    /// including the `<think>…</think>` block and any raw `<tool_call>` markup. Rendering
    /// this verbatim keeps the prompt byte-identical to what is already in the model's
    /// KV/recurrent state, so the next turn only needs to evaluate the new suffix.
    public var rawCompletion: String?
    public var date: Date

    public init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        reasoning: String? = nil,
        toolCalls: [ToolCall] = [],
        rawCompletion: String? = nil,
        date: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.rawCompletion = rawCompletion
        self.date = date
    }

    public static func system(_ text: String) -> ChatMessage { .init(role: .system, content: text) }
    public static func user(_ text: String) -> ChatMessage { .init(role: .user, content: text) }
    public static func assistant(_ text: String, reasoning: String? = nil, toolCalls: [ToolCall] = []) -> ChatMessage {
        .init(role: .assistant, content: text, reasoning: reasoning, toolCalls: toolCalls)
    }
    public static func tool(_ text: String) -> ChatMessage { .init(role: .tool, content: text) }
}
