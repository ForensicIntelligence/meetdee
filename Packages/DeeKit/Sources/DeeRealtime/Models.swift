import Foundation

// Wire objects shared by client and server events (GA Realtime interface).
// Field names follow the API reference exactly (snake_case on the wire).
// Every optional is omitted when nil; the few fields that must be sent as an
// explicit JSON `null` (tracing, turn_detection, …) use `Nullable`.

/// A field that can be absent (Swift `nil`), explicitly `null`, or a value.
/// Use as `Nullable<T>?`: `nil` omits the key, `.null` writes `null`.
public enum Nullable<Wrapped: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    case null
    case value(Wrapped)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self = c.decodeNil() ? .null : .value(try c.decode(Wrapped.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .value(let v): try c.encode(v)
        }
    }

    public var value: Wrapped? { if case .value(let v) = self { v } else { nil } }
}

/// `max_output_tokens`: an integer 1…4096 or the string `"inf"`.
public enum MaxTokens: Codable, Sendable, Equatable {
    case inf
    case limit(Int)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self), s == "inf" { self = .inf; return }
        if let i = try? c.decode(Int.self) { self = .limit(i); return }
        self = .limit(Int(try c.decode(Double.self)))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .inf: try c.encode("inf")
        case .limit(let n): try c.encode(n)
        }
    }
}

// MARK: - Items

/// One content part of a message item.
public struct RealtimeContent: Codable, Sendable, Equatable {
    /// `input_text`, `input_audio`, `input_image`, `output_text`, `output_audio`
    /// (and the legacy `text` / `audio` seen in some examples).
    public var type: String?
    public var text: String?
    public var transcript: String?
    /// Base64 audio (never present in `response.done`).
    public var audio: String?
    public var format: String?
    public var imageURL: String?
    public var detail: String?

    enum CodingKeys: String, CodingKey {
        case type, text, transcript, audio, format, detail
        case imageURL = "image_url"
    }

    public init(type: String?, text: String? = nil, transcript: String? = nil, audio: String? = nil,
                format: String? = nil, imageURL: String? = nil, detail: String? = nil) {
        self.type = type; self.text = text; self.transcript = transcript; self.audio = audio
        self.format = format; self.imageURL = imageURL; self.detail = detail
    }

    public static func inputText(_ text: String) -> RealtimeContent { .init(type: "input_text", text: text) }
    public static func outputText(_ text: String) -> RealtimeContent { .init(type: "output_text", text: text) }
}

/// A conversation item: message, function call, function call output or a
/// reference to an existing item (`item_reference`, only inside `response.input`).
public struct RealtimeItem: Codable, Sendable, Equatable {
    public var id: String?
    public var object: String?
    /// `message`, `function_call`, `function_call_output`, `item_reference`, `mcp_*`.
    public var type: String
    /// `completed`, `incomplete`, `in_progress`.
    public var status: String?
    /// `system`, `user`, `assistant` (messages only).
    public var role: String?
    public var content: [RealtimeContent]?
    public var callID: String?
    public var name: String?
    public var arguments: String?
    public var output: String?

    enum CodingKeys: String, CodingKey {
        case id, object, type, status, role, content, name, arguments, output
        case callID = "call_id"
    }

    public init(id: String? = nil, object: String? = nil, type: String, status: String? = nil, role: String? = nil,
                content: [RealtimeContent]? = nil, callID: String? = nil, name: String? = nil,
                arguments: String? = nil, output: String? = nil) {
        self.id = id; self.object = object; self.type = type; self.status = status; self.role = role
        self.content = content; self.callID = callID; self.name = name; self.arguments = arguments
        self.output = output
    }

    /// A system message: per-turn state or context ("smaller updates" per the docs).
    public static func systemMessage(_ text: String, id: String? = nil) -> RealtimeItem {
        RealtimeItem(id: id, type: "message", role: "system", content: [.inputText(text)])
    }

    public static func userText(_ text: String, id: String? = nil) -> RealtimeItem {
        RealtimeItem(id: id, type: "message", role: "user", content: [.inputText(text)])
    }

    public static func functionCallOutput(callID: String, output: String) -> RealtimeItem {
        RealtimeItem(type: "function_call_output", callID: callID, output: output)
    }

    public static func reference(_ id: String) -> RealtimeItem { RealtimeItem(id: id, type: "item_reference") }

    /// The spoken or written text of a message item (transcript first, then text).
    public var text: String? {
        let parts = (content ?? []).compactMap { $0.transcript ?? $0.text }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

// MARK: - Tools

/// A function the model may call (`type: "function"`).
public struct RealtimeTool: Codable, Sendable, Equatable {
    public var type: String
    public var name: String
    public var description: String?
    /// JSON Schema of the arguments.
    public var parameters: RealtimeJSON?

    public init(name: String, description: String?, parameters: RealtimeJSON?) {
        self.type = "function"; self.name = name; self.description = description; self.parameters = parameters
    }
}

/// `tool_choice`: `"auto"`, `"none"`, `"required"` or a forced function.
public enum ToolChoice: Codable, Sendable, Equatable {
    case auto, none, required
    case function(String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            switch s {
            case "none": self = .none
            case "required": self = .required
            default: self = .auto
            }
            return
        }
        let o = try c.decode([String: String].self)
        self = .function(o["name"] ?? "")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .auto: try c.encode("auto")
        case .none: try c.encode("none")
        case .required: try c.encode("required")
        case .function(let name): try c.encode(["type": "function", "name": name])
        }
    }
}

// MARK: - Session

/// `audio/pcm` at 24 kHz (the only PCM rate Realtime accepts), or G.711.
public struct AudioFormat: Codable, Sendable, Equatable {
    public var type: String
    public var rate: Int?

    public init(type: String, rate: Int?) { self.type = type; self.rate = rate }
    public static let pcm24k = AudioFormat(type: "audio/pcm", rate: 24_000)
}

public struct NoiseReduction: Codable, Sendable, Equatable {
    /// `near_field` (headset) or `far_field` (room / phone on a desk).
    public var type: String
    public init(type: String) { self.type = type }
    public static let farField = NoiseReduction(type: "far_field")
    public static let nearField = NoiseReduction(type: "near_field")
}

/// Input transcription. Runs asynchronously after commit and does not drive the
/// model (the model hears the audio itself).
public struct InputTranscription: Codable, Sendable, Equatable {
    public var model: String?
    public var language: String?
    public var languages: [String]?
    public var keywords: [String]?
    public var prompt: String?
    /// Only supported with `gpt-realtime-whisper` in GA sessions.
    public var delay: String?

    public init(model: String?, language: String? = nil, languages: [String]? = nil, keywords: [String]? = nil,
                prompt: String? = nil, delay: String? = nil) {
        self.model = model; self.language = language; self.languages = languages; self.keywords = keywords
        self.prompt = prompt; self.delay = delay
    }
}

/// `turn_detection`: `server_vad` or `semantic_vad`.
public struct TurnDetection: Codable, Sendable, Equatable {
    public var type: String
    public var createResponse: Bool?
    public var interruptResponse: Bool?
    /// semantic_vad: `low`, `medium`, `high`, `auto`.
    public var eagerness: String?
    public var threshold: Double?
    public var prefixPaddingMs: Int?
    public var silenceDurationMs: Int?
    public var idleTimeoutMs: Int?

    enum CodingKeys: String, CodingKey {
        case type, eagerness, threshold
        case createResponse = "create_response"
        case interruptResponse = "interrupt_response"
        case prefixPaddingMs = "prefix_padding_ms"
        case silenceDurationMs = "silence_duration_ms"
        case idleTimeoutMs = "idle_timeout_ms"
    }

    public init(type: String, createResponse: Bool? = nil, interruptResponse: Bool? = nil, eagerness: String? = nil,
                threshold: Double? = nil, prefixPaddingMs: Int? = nil, silenceDurationMs: Int? = nil,
                idleTimeoutMs: Int? = nil) {
        self.type = type; self.createResponse = createResponse; self.interruptResponse = interruptResponse
        self.eagerness = eagerness; self.threshold = threshold; self.prefixPaddingMs = prefixPaddingMs
        self.silenceDurationMs = silenceDurationMs; self.idleTimeoutMs = idleTimeoutMs
    }

    /// Semantic VAD that still reports speech start/stop but never answers or
    /// interrupts on its own: Dee keeps the floor decisions.
    public static func semanticManual(eagerness: String = "auto") -> TurnDetection {
        TurnDetection(type: "semantic_vad", createResponse: false, interruptResponse: false, eagerness: eagerness)
    }

    /// `semantic_vad`: a model decides when the turn is over. `eagerness` `low`,
    /// `medium`, `high` or `auto` (max waits 8 / 4 / 2 / 4 s); nil is omitted.
    public static func semantic(eagerness: String? = nil, createResponse: Bool = false,
                                interruptResponse: Bool = false) -> TurnDetection {
        TurnDetection(type: "semantic_vad", createResponse: createResponse, interruptResponse: interruptResponse,
                      eagerness: eagerness)
    }

    /// `server_vad`: the turn ends after `silenceDurationMs` of silence (API
    /// default 500), with `prefixPaddingMs` of audio kept before the onset (300)
    /// and an activation `threshold` 0…1 (0.5). `idleTimeoutMs` (nil: none) makes
    /// the server answer by itself after that much silence past her last audio
    /// (`RealtimeSession` cancels such responses). nil fields are omitted.
    public static func serverVAD(threshold: Double? = nil, prefixPaddingMs: Int? = nil,
                                 silenceDurationMs: Int? = nil, idleTimeoutMs: Int? = nil,
                                 createResponse: Bool = false, interruptResponse: Bool = false) -> TurnDetection {
        TurnDetection(type: "server_vad", createResponse: createResponse, interruptResponse: interruptResponse,
                      threshold: threshold, prefixPaddingMs: prefixPaddingMs, silenceDurationMs: silenceDurationMs,
                      idleTimeoutMs: idleTimeoutMs)
    }
}

public struct AudioInputConfig: Codable, Sendable, Equatable {
    public var format: AudioFormat?
    public var noiseReduction: Nullable<NoiseReduction>?
    public var transcription: Nullable<InputTranscription>?
    public var turnDetection: Nullable<TurnDetection>?

    enum CodingKeys: String, CodingKey {
        case format, transcription
        case noiseReduction = "noise_reduction"
        case turnDetection = "turn_detection"
    }

    public init(format: AudioFormat? = nil, noiseReduction: Nullable<NoiseReduction>? = nil,
                transcription: Nullable<InputTranscription>? = nil, turnDetection: Nullable<TurnDetection>? = nil) {
        self.format = format; self.noiseReduction = noiseReduction; self.transcription = transcription
        self.turnDetection = turnDetection
    }
}

/// A built-in voice name (`marin`, `cedar`, …) or a custom voice `{ "id": … }`.
public enum RealtimeVoice: Codable, Sendable, Equatable {
    case named(String)
    case custom(id: String)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .named(s); return }
        self = .custom(id: try c.decode([String: String].self)["id"] ?? "")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .named(let s): try c.encode(s)
        case .custom(let id): try c.encode(["id": id])
        }
    }
}

public struct AudioOutputConfig: Codable, Sendable, Equatable {
    public var format: AudioFormat?
    public var voice: RealtimeVoice?
    /// 0.25…1.5; changeable only between turns.
    public var speed: Double?

    public init(format: AudioFormat? = nil, voice: RealtimeVoice? = nil, speed: Double? = nil) {
        self.format = format; self.voice = voice; self.speed = speed
    }
}

public struct AudioConfig: Codable, Sendable, Equatable {
    public var input: AudioInputConfig?
    public var output: AudioOutputConfig?
    public init(input: AudioInputConfig? = nil, output: AudioOutputConfig? = nil) {
        self.input = input; self.output = output
    }
}

/// `truncation`: `"auto"`, `"disabled"` or a retention ratio.
public enum Truncation: Codable, Sendable, Equatable {
    case auto
    case disabled
    case retentionRatio(Double, postInstructionsTokens: Int? = nil)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = s == "disabled" ? .disabled : .auto; return }
        let o = try c.decode(RealtimeJSON.self)
        self = .retentionRatio(o["retention_ratio"]?.doubleValue ?? 1,
                               postInstructionsTokens: o["token_limits"]?["post_instructions"]?.intValue)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .auto: try c.encode("auto")
        case .disabled: try c.encode("disabled")
        case .retentionRatio(let r, let limit):
            var o: [String: RealtimeJSON] = ["type": "retention_ratio", "retention_ratio": .number(r)]
            if let limit { o["token_limits"] = ["post_instructions": .number(Double(limit))] }
            try c.encode(RealtimeJSON.object(o))
        }
    }
}

public struct Reasoning: Codable, Sendable, Equatable {
    /// `minimal`, `low`, `medium`, `high` (+ `xhigh` on some models).
    public var effort: String?
    public init(effort: String?) { self.effort = effort }
}

/// The `session` object of `session.update` (a `RealtimeSessionCreateRequest`).
/// Only the fields present are changed by an update.
public struct SessionPayload: Codable, Sendable, Equatable {
    public var type: String
    public var model: String?
    public var instructions: String?
    public var outputModalities: [String]?
    public var audio: AudioConfig?
    public var tools: [RealtimeTool]?
    public var toolChoice: ToolChoice?
    public var maxOutputTokens: MaxTokens?
    public var truncation: Truncation?
    /// `.null` disables tracing (Dee always sends this).
    public var tracing: Nullable<RealtimeJSON>?
    public var reasoning: Reasoning?
    public var include: [String]?
    public var parallelToolCalls: Bool?

    enum CodingKeys: String, CodingKey {
        case type, model, instructions, audio, tools, truncation, tracing, reasoning, include
        case outputModalities = "output_modalities"
        case toolChoice = "tool_choice"
        case maxOutputTokens = "max_output_tokens"
        case parallelToolCalls = "parallel_tool_calls"
    }

    public init(type: String = "realtime", model: String? = nil, instructions: String? = nil,
                outputModalities: [String]? = nil, audio: AudioConfig? = nil, tools: [RealtimeTool]? = nil,
                toolChoice: ToolChoice? = nil, maxOutputTokens: MaxTokens? = nil, truncation: Truncation? = nil,
                tracing: Nullable<RealtimeJSON>? = nil, reasoning: Reasoning? = nil, include: [String]? = nil,
                parallelToolCalls: Bool? = nil) {
        self.type = type; self.model = model; self.instructions = instructions
        self.outputModalities = outputModalities; self.audio = audio; self.tools = tools
        self.toolChoice = toolChoice; self.maxOutputTokens = maxOutputTokens; self.truncation = truncation
        self.tracing = tracing; self.reasoning = reasoning; self.include = include
        self.parallelToolCalls = parallelToolCalls
    }
}

/// The session object the server echoes in `session.created` / `session.updated`.
/// Kept as raw JSON (the schema is large); typed accessors for what Dee reads.
public struct SessionInfo: Codable, Sendable, Equatable {
    public var raw: RealtimeJSON

    public init(raw: RealtimeJSON) { self.raw = raw }
    public init(from decoder: Decoder) throws { raw = try RealtimeJSON(from: decoder) }
    public func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }

    public var id: String? { raw["id"]?.stringValue }
    public var model: String? { raw["model"]?.stringValue }
    public var instructions: String? { raw["instructions"]?.stringValue }
    /// Unix seconds.
    public var expiresAt: Double? { raw["expires_at"]?.doubleValue }
    public var voice: String? { raw["audio"]?["output"]?["voice"]?.stringValue }
}

// MARK: - Responses

/// The `response` object of `response.create` (`RealtimeResponseCreateParams`).
/// Every field overrides the session for this response only.
public struct ResponseParams: Codable, Sendable, Equatable {
    /// `"auto"` (default conversation) or `"none"` (out-of-band).
    public var conversation: String?
    /// Replaces the context for this response (`[]` = no context).
    public var input: [RealtimeItem]?
    public var instructions: String?
    public var maxOutputTokens: MaxTokens?
    public var metadata: [String: String]?
    public var outputModalities: [String]?
    public var tools: [RealtimeTool]?
    public var toolChoice: ToolChoice?
    public var audio: AudioConfig?
    public var reasoning: Reasoning?

    enum CodingKeys: String, CodingKey {
        case conversation, input, instructions, metadata, tools, audio, reasoning
        case maxOutputTokens = "max_output_tokens"
        case outputModalities = "output_modalities"
        case toolChoice = "tool_choice"
    }

    public init(conversation: String? = nil, input: [RealtimeItem]? = nil, instructions: String? = nil,
                maxOutputTokens: MaxTokens? = nil, metadata: [String: String]? = nil,
                outputModalities: [String]? = nil, tools: [RealtimeTool]? = nil, toolChoice: ToolChoice? = nil,
                audio: AudioConfig? = nil, reasoning: Reasoning? = nil) {
        self.conversation = conversation; self.input = input; self.instructions = instructions
        self.maxOutputTokens = maxOutputTokens; self.metadata = metadata; self.outputModalities = outputModalities
        self.tools = tools; self.toolChoice = toolChoice; self.audio = audio; self.reasoning = reasoning
    }
}

public struct ResponseStatusDetails: Codable, Sendable, Equatable {
    /// `completed`, `cancelled`, `failed`, `incomplete`.
    public var type: String?
    /// `turn_detected`, `client_cancelled`, `max_output_tokens`, `content_filter`.
    public var reason: String?
    public var error: ErrorBrief?

    public struct ErrorBrief: Codable, Sendable, Equatable {
        public var type: String?
        public var code: String?
    }
}

public struct Usage: Codable, Sendable, Equatable {
    public var totalTokens: Int?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var inputTokenDetails: InputDetails?
    public var outputTokenDetails: OutputDetails?

    public struct InputDetails: Codable, Sendable, Equatable {
        public var textTokens: Int?
        public var audioTokens: Int?
        public var imageTokens: Int?
        public var cachedTokens: Int?
        public var cachedTokensDetails: Cached?

        public struct Cached: Codable, Sendable, Equatable {
            public var textTokens: Int?
            public var audioTokens: Int?
            public var imageTokens: Int?
            enum CodingKeys: String, CodingKey {
                case textTokens = "text_tokens", audioTokens = "audio_tokens", imageTokens = "image_tokens"
            }
        }

        enum CodingKeys: String, CodingKey {
            case textTokens = "text_tokens", audioTokens = "audio_tokens", imageTokens = "image_tokens"
            case cachedTokens = "cached_tokens", cachedTokensDetails = "cached_tokens_details"
        }
    }

    public struct OutputDetails: Codable, Sendable, Equatable {
        public var textTokens: Int?
        public var audioTokens: Int?
        enum CodingKeys: String, CodingKey { case textTokens = "text_tokens", audioTokens = "audio_tokens" }
    }

    enum CodingKeys: String, CodingKey {
        case totalTokens = "total_tokens", inputTokens = "input_tokens", outputTokens = "output_tokens"
        case inputTokenDetails = "input_token_details", outputTokenDetails = "output_token_details"
    }

    public init(totalTokens: Int? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil,
                inputTokenDetails: InputDetails? = nil, outputTokenDetails: OutputDetails? = nil) {
        self.totalTokens = totalTokens; self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.inputTokenDetails = inputTokenDetails; self.outputTokenDetails = outputTokenDetails
    }
}

/// The `response` object of `response.created` / `response.done`.
public struct ResponseObject: Codable, Sendable, Equatable {
    public var id: String?
    public var object: String?
    /// `in_progress`, `completed`, `cancelled`, `failed`, `incomplete`.
    public var status: String?
    public var statusDetails: ResponseStatusDetails?
    public var output: [RealtimeItem]?
    public var conversationID: String?
    public var outputModalities: [String]?
    public var maxOutputTokens: MaxTokens?
    public var audio: RealtimeJSON?
    public var usage: Usage?
    public var metadata: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id, object, status, output, audio, usage, metadata
        case statusDetails = "status_details"
        case conversationID = "conversation_id"
        case outputModalities = "output_modalities"
        case maxOutputTokens = "max_output_tokens"
    }

    public init(id: String? = nil, object: String? = nil, status: String? = nil,
                statusDetails: ResponseStatusDetails? = nil, output: [RealtimeItem]? = nil,
                conversationID: String? = nil, outputModalities: [String]? = nil, maxOutputTokens: MaxTokens? = nil,
                audio: RealtimeJSON? = nil, usage: Usage? = nil, metadata: [String: String]? = nil) {
        self.id = id; self.object = object; self.status = status; self.statusDetails = statusDetails
        self.output = output; self.conversationID = conversationID; self.outputModalities = outputModalities
        self.maxOutputTokens = maxOutputTokens; self.audio = audio; self.usage = usage; self.metadata = metadata
    }
}

// MARK: - Errors, limits

/// The `error` object of a server `error` event (also used by transcription failures).
public struct APIError: Codable, Sendable, Equatable {
    public var type: String?
    public var code: String?
    public var message: String?
    public var param: String?
    /// The `event_id` of the client event that caused it, if any.
    public var eventID: String?

    enum CodingKeys: String, CodingKey {
        case type, code, message, param
        case eventID = "event_id"
    }

    public init(type: String?, code: String?, message: String?, param: String? = nil, eventID: String? = nil) {
        self.type = type; self.code = code; self.message = message; self.param = param; self.eventID = eventID
    }
}

public struct RateLimit: Codable, Sendable, Equatable {
    /// `requests` or `tokens`.
    public var name: String
    public var limit: Int?
    public var remaining: Int?
    public var resetSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case name, limit, remaining
        case resetSeconds = "reset_seconds"
    }

    public init(name: String, limit: Int?, remaining: Int?, resetSeconds: Double?) {
        self.name = name; self.limit = limit; self.remaining = remaining; self.resetSeconds = resetSeconds
    }
}
