import Foundation
import DeeRealtime

/// One `/v1/chat/completions` message.
public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case system, user, assistant, tool }
    public var role: Role
    public var content: String
    public var toolCalls: [ChatToolCall]
    public var toolCallID: String?
    /// The function a `tool` message answers (Ollama native wants the name, not the id).
    public var toolName: String?

    public init(role: Role, content: String, toolCalls: [ChatToolCall] = [], toolCallID: String? = nil,
                toolName: String? = nil) {
        self.role = role; self.content = content; self.toolCalls = toolCalls; self.toolCallID = toolCallID
        self.toolName = toolName
    }

    public static func system(_ s: String) -> ChatMessage { .init(role: .system, content: s) }
    public static func user(_ s: String) -> ChatMessage { .init(role: .user, content: s) }
    public static func assistant(_ s: String) -> ChatMessage { .init(role: .assistant, content: s) }

    /// OpenAI shape.
    var json: RealtimeJSON {
        var o: [String: RealtimeJSON] = ["role": .string(role.rawValue), "content": .string(content)]
        if !toolCalls.isEmpty {
            o["tool_calls"] = .array(toolCalls.map {
                ["id": .string($0.id), "type": "function",
                 "function": ["name": .string($0.name), "arguments": .string($0.arguments)]]
            })
        }
        if let toolCallID { o["tool_call_id"] = .string(toolCallID) }
        return .object(o)
    }

    /// Ollama native `/api/chat` shape (tool arguments as an object, no ids).
    var ollamaJSON: RealtimeJSON {
        var o: [String: RealtimeJSON] = ["role": .string(role.rawValue), "content": .string(content)]
        if !toolCalls.isEmpty {
            o["tool_calls"] = .array(toolCalls.map {
                ["function": ["name": .string($0.name),
                              "arguments": RealtimeJSON.parse($0.arguments) ?? .object([:])]]
            })
        }
        if role == .tool, let toolName { o["tool_name"] = .string(toolName) }
        return .object(o)
    }
}

/// A function call the model made.
public struct ChatToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    /// JSON text.
    public var arguments: String
    public init(id: String, name: String, arguments: String) { self.id = id; self.name = name; self.arguments = arguments }
}

/// A function offered to the model (built from `RealtimeTool`, same order every request).
public struct ChatTool: Sendable, Equatable {
    public var name: String
    public var description: String?
    public var parameters: RealtimeJSON?
    public init(name: String, description: String?, parameters: RealtimeJSON?) {
        self.name = name; self.description = description; self.parameters = parameters
    }
    public init(_ t: RealtimeTool) { self.init(name: t.name, description: t.description, parameters: t.parameters) }

    var json: RealtimeJSON {
        var f: [String: RealtimeJSON] = ["name": .string(name)]
        if let description { f["description"] = .string(description) }
        f["parameters"] = parameters ?? ["type": "object", "properties": .object([:])]
        return ["type": "function", "function": .object(f)]
    }
}

/// Everything one chat request carries.
public struct ChatRequest: Sendable, Equatable {
    public var model: String
    public var messages: [ChatMessage]
    public var tools: [ChatTool]
    public var maxTokens: Int?
    public var temperature: Double?
    /// Ollama `keep_alive` (nil: not sent).
    public var keepAlive: String?

    public init(model: String, messages: [ChatMessage], tools: [ChatTool] = [], maxTokens: Int? = nil,
                temperature: Double? = nil, keepAlive: String? = nil) {
        self.model = model; self.messages = messages; self.tools = tools; self.maxTokens = maxTokens
        self.temperature = temperature; self.keepAlive = keepAlive
    }

    /// `/v1/chat/completions` body: streaming, usage included, reasoning off (`reasoning_effort:"none"`, which
    /// both Ollama and LM Studio honour; `think:false` is ignored on /v1).
    func openAIBody() -> Data {
        var o: [String: RealtimeJSON] = [
            "model": .string(model),
            "messages": .array(messages.map(\.json)),
            "stream": true,
            "stream_options": ["include_usage": true],
            "reasoning_effort": "none",
        ]
        if !tools.isEmpty { o["tools"] = .array(tools.map(\.json)) }
        if let maxTokens { o["max_tokens"] = .number(Double(maxTokens)) }
        if let temperature { o["temperature"] = .number(temperature) }
        if let keepAlive { o["keep_alive"] = .string(keepAlive) }
        return Data(RealtimeJSON.object(o).jsonText.utf8)
    }

    /// Ollama native `/api/chat` body (`think:false` works there; NDJSON stream).
    func ollamaBody() -> Data {
        var o: [String: RealtimeJSON] = [
            "model": .string(model),
            "messages": .array(messages.map(\.ollamaJSON)),
            "stream": true,
            "think": false,
        ]
        if !tools.isEmpty { o["tools"] = .array(tools.map(\.json)) }
        var options: [String: RealtimeJSON] = [:]
        if let maxTokens { options["num_predict"] = .number(Double(maxTokens)) }
        if let temperature { options["temperature"] = .number(temperature) }
        if !options.isEmpty { o["options"] = .object(options) }
        if let keepAlive { o["keep_alive"] = .string(keepAlive) }
        return Data(RealtimeJSON.object(o).jsonText.utf8)
    }
}

/// Token counts of one chat response.
public struct ChatUsage: Sendable, Equatable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var cachedTokens: Int?
    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, cachedTokens: Int? = nil) {
        self.promptTokens = promptTokens; self.completionTokens = completionTokens; self.cachedTokens = cachedTokens
    }
}

/// One decoded piece of a chat stream.
public enum ChatPiece: Sendable, Equatable {
    /// Visible content (not yet think-stripped).
    case content(String)
    /// Reasoning text (`delta.reasoning`, `delta.reasoning_content`, Ollama `thinking`): never spoken.
    case reasoning(Int)
    /// Tool call fragment, accumulated by index.
    case toolCallDelta(index: Int, id: String?, name: String?, arguments: String)
    /// Ollama native: a whole call (arguments object).
    case toolCall(ChatToolCall)
    case finish(reason: String)
    case usage(ChatUsage)
    case model(String)
    /// An error object inside a 200 stream.
    case error(status: Int?, message: String)
}

enum ChatChunkDecoder {
    /// One SSE `data:` JSON (OpenAI chunk shape).
    static func decodeOpenAI(_ text: String) -> [ChatPiece] {
        guard let j = RealtimeJSON.parse(text) else { return [] }
        if let e = j["error"] {
            let message = e["message"]?.stringValue ?? e.stringValue ?? "error"
            return [.error(status: e["code"]?.intValue, message: message)]
        }
        var out: [ChatPiece] = []
        if let m = j["model"]?.stringValue, !m.isEmpty { out.append(.model(m)) }
        if case .array(let choices) = j["choices"] ?? .null, let c = choices.first {
            let d = c["delta"] ?? c["message"] ?? .null
            if let r = d["reasoning"]?.stringValue, !r.isEmpty { out.append(.reasoning(r.count)) }
            if let r = d["reasoning_content"]?.stringValue, !r.isEmpty { out.append(.reasoning(r.count)) }
            if let s = d["content"]?.stringValue, !s.isEmpty { out.append(.content(s)) }
            if case .array(let calls) = d["tool_calls"] ?? .null {
                for (i, call) in calls.enumerated() {
                    let f = call["function"] ?? .null
                    let args: String = f["arguments"]?.stringValue ?? (f["arguments"].map { $0 == .null ? "" : $0.jsonText } ?? "")
                    out.append(.toolCallDelta(index: call["index"]?.intValue ?? i, id: call["id"]?.stringValue,
                                              name: f["name"]?.stringValue, arguments: args))
                }
            }
            if let f = c["finish_reason"]?.stringValue { out.append(.finish(reason: f)) }
        }
        if let u = j["usage"], u != .null {
            out.append(.usage(ChatUsage(promptTokens: u["prompt_tokens"]?.intValue,
                                        completionTokens: u["completion_tokens"]?.intValue,
                                        cachedTokens: u["prompt_tokens_details"]?["cached_tokens"]?.intValue)))
        }
        return out
    }

    /// One Ollama `/api/chat` NDJSON line.
    static func decodeOllama(_ text: String, callCounter: inout Int) -> [ChatPiece] {
        guard let j = RealtimeJSON.parse(text) else { return [] }
        if let e = j["error"] {
            return [.error(status: nil, message: e.stringValue ?? e["message"]?.stringValue ?? "error")]
        }
        var out: [ChatPiece] = []
        if let m = j["model"]?.stringValue, !m.isEmpty { out.append(.model(m)) }
        let msg = j["message"] ?? .null
        if let t = msg["thinking"]?.stringValue, !t.isEmpty { out.append(.reasoning(t.count)) }
        if let s = msg["content"]?.stringValue, !s.isEmpty { out.append(.content(s)) }
        if case .array(let calls) = msg["tool_calls"] ?? .null {
            for call in calls {
                let f = call["function"] ?? .null
                callCounter += 1
                let args: String
                if let s = f["arguments"]?.stringValue { args = s } else { args = (f["arguments"] ?? .object([:])).jsonText }
                out.append(.toolCall(ChatToolCall(id: call["id"]?.stringValue ?? "call_ollama_\(callCounter)",
                                                  name: f["name"]?.stringValue ?? "", arguments: args)))
            }
        }
        if j["done"]?.boolValue == true {
            out.append(.usage(ChatUsage(promptTokens: j["prompt_eval_count"]?.intValue,
                                        completionTokens: j["eval_count"]?.intValue)))
            out.append(.finish(reason: j["done_reason"]?.stringValue ?? "stop"))
        }
        return out
    }
}
