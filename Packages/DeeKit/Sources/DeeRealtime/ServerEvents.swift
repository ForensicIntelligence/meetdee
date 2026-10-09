import Foundation

/// Every server event Dee acts on (GA Realtime interface). Anything else — new
/// event types, WebRTC-only events, MCP events — decodes to `.unknown`, and a
/// known type with a missing field decodes to `.malformed`. Decoding never
/// throws: an odd frame from the server must never break the conversation.
///
/// `event_id` is optional everywhere: the reference marks it required, but some
/// documented examples omit it.
public enum ServerEvent: Sendable, Equatable, Codable {
    case error(ErrorEvent)
    case sessionCreated(SessionEvent)
    case sessionUpdated(SessionEvent)

    case itemAdded(ItemEvent)
    case itemDone(ItemEvent)
    /// Older name for `itemAdded`; still listed in the reference.
    case itemCreated(ItemEvent)
    case itemRetrieved(ItemEvent)
    case itemTruncated(ItemTruncated)
    case itemDeleted(ItemRef)

    case inputTranscriptionDelta(TranscriptionDelta)
    case inputTranscriptionCompleted(TranscriptionCompleted)
    case inputTranscriptionFailed(TranscriptionFailed)

    case inputAudioCommitted(Committed)
    case inputAudioCleared(Bare)
    case speechStarted(SpeechStarted)
    case speechStopped(SpeechStopped)
    case inputAudioTimeout(TimeoutTriggered)

    case responseCreated(ResponseEvent)
    case responseDone(ResponseEvent)
    case outputItemAdded(OutputItem)
    case outputItemDone(OutputItem)
    case outputTextDelta(PartDelta)
    case outputTextDone(PartText)
    case outputAudioDelta(PartDelta)
    case outputAudioDone(PartRef)
    case outputAudioTranscriptDelta(PartDelta)
    case outputAudioTranscriptDone(PartText)
    case functionCallArgumentsDelta(FunctionCallDelta)
    case functionCallArgumentsDone(FunctionCallDone)

    case rateLimitsUpdated(RateLimits)

    case unknown(type: String, raw: RealtimeJSON)
    case malformed(type: String, raw: RealtimeJSON, reason: String)

    // MARK: Payloads

    public struct Bare: Codable, Sendable, Equatable {
        public var eventID: String?
        enum CodingKeys: String, CodingKey { case eventID = "event_id" }
        public init(eventID: String? = nil) { self.eventID = eventID }
    }

    public struct ErrorEvent: Codable, Sendable, Equatable {
        public var eventID: String?
        public var error: APIError
        enum CodingKeys: String, CodingKey { case eventID = "event_id", error }
        public init(eventID: String? = nil, error: APIError) { self.eventID = eventID; self.error = error }
    }

    public struct SessionEvent: Codable, Sendable, Equatable {
        public var eventID: String?
        public var session: SessionInfo
        enum CodingKeys: String, CodingKey { case eventID = "event_id", session }
        public init(eventID: String? = nil, session: SessionInfo) { self.eventID = eventID; self.session = session }
    }

    public struct ItemEvent: Codable, Sendable, Equatable {
        public var eventID: String?
        public var previousItemID: String?
        public var item: RealtimeItem
        enum CodingKeys: String, CodingKey { case eventID = "event_id", previousItemID = "previous_item_id", item }
        public init(eventID: String? = nil, previousItemID: String? = nil, item: RealtimeItem) {
            self.eventID = eventID; self.previousItemID = previousItemID; self.item = item
        }
    }

    public struct ItemTruncated: Codable, Sendable, Equatable {
        public var eventID: String?
        public var itemID: String
        public var contentIndex: Int?
        public var audioEndMs: Int
        enum CodingKeys: String, CodingKey {
            case eventID = "event_id", itemID = "item_id", contentIndex = "content_index", audioEndMs = "audio_end_ms"
        }
        public init(eventID: String? = nil, itemID: String, contentIndex: Int? = 0, audioEndMs: Int) {
            self.eventID = eventID; self.itemID = itemID; self.contentIndex = contentIndex; self.audioEndMs = audioEndMs
        }
    }

    public struct ItemRef: Codable, Sendable, Equatable {
        public var eventID: String?
        public var itemID: String
        enum CodingKeys: String, CodingKey { case eventID = "event_id", itemID = "item_id" }
        public init(eventID: String? = nil, itemID: String) { self.eventID = eventID; self.itemID = itemID }
    }

    public struct TranscriptionDelta: Codable, Sendable, Equatable {
        public var eventID: String?
        public var itemID: String
        public var contentIndex: Int?
        public var delta: String
        enum CodingKeys: String, CodingKey {
            case eventID = "event_id", itemID = "item_id", contentIndex = "content_index", delta
        }
        public init(eventID: String? = nil, itemID: String, contentIndex: Int? = 0, delta: String) {
            self.eventID = eventID; self.itemID = itemID; self.contentIndex = contentIndex; self.delta = delta
        }
    }

    public struct TranscriptionCompleted: Codable, Sendable, Equatable {
        public var eventID: String?
        public var itemID: String
        public var contentIndex: Int?
        public var transcript: String
        /// `{type:"tokens", …}` or `{type:"duration", seconds}` depending on the model.
        public var usage: RealtimeJSON?
        enum CodingKeys: String, CodingKey {
            case eventID = "event_id", itemID = "item_id", contentIndex = "content_index", transcript, usage
        }
        public init(eventID: String? = nil, itemID: String, contentIndex: Int? = 0, transcript: String,
                    usage: RealtimeJSON? = nil) {
            self.eventID = eventID; self.itemID = itemID; self.contentIndex = contentIndex
            self.transcript = transcript; self.usage = usage
        }
    }

    public struct TranscriptionFailed: Codable, Sendable, Equatable {
        public var eventID: String?
        public var itemID: String
        public var contentIndex: Int?
        public var error: APIError?
        enum CodingKeys: String, CodingKey {
            case eventID = "event_id", itemID = "item_id", contentIndex = "content_index", error
        }
        public init(eventID: String? = nil, itemID: String, contentIndex: Int? = 0, error: APIError?) {
            self.eventID = eventID; self.itemID = itemID; self.contentIndex = contentIndex; self.error = error
        }
    }

    public struct Committed: Codable, Sendable, Equatable {
        public var eventID: String?
        public var previousItemID: String?
        public var itemID: String
        enum CodingKeys: String, CodingKey {
            case eventID = "event_id", previousItemID = "previous_item_id", itemID = "item_id"
        }
        public init(eventID: String? = nil, previousItemID: String? = nil, itemID: String) {
            self.eventID = eventID; self.previousItemID = previousItemID; self.itemID = itemID
        }
    }

    public struct SpeechStarted: Codable, Sendable, Equatable {
        public var eventID: String?
        /// Milliseconds since the session's audio started, including prefix padding.
        public var audioStartMs: Int
        /// The user item this speech will become once committed.
        public var itemID: String
        enum CodingKeys: String, CodingKey { case eventID = "event_id", audioStartMs = "audio_start_ms", itemID = "item_id" }
        public init(eventID: String? = nil, audioStartMs: Int, itemID: String) {
            self.eventID = eventID; self.audioStartMs = audioStartMs; self.itemID = itemID
        }
    }

    public struct SpeechStopped: Codable, Sendable, Equatable {
        public var eventID: String?
        public var audioEndMs: Int
        public var itemID: String
        enum CodingKeys: String, CodingKey { case eventID = "event_id", audioEndMs = "audio_end_ms", itemID = "item_id" }
        public init(eventID: String? = nil, audioEndMs: Int, itemID: String) {
            self.eventID = eventID; self.audioEndMs = audioEndMs; self.itemID = itemID
        }
    }

    public struct TimeoutTriggered: Codable, Sendable, Equatable {
        public var eventID: String?
        public var audioStartMs: Int?
        public var audioEndMs: Int?
        public var itemID: String?
        enum CodingKeys: String, CodingKey {
            case eventID = "event_id", audioStartMs = "audio_start_ms", audioEndMs = "audio_end_ms", itemID = "item_id"
        }
    }

    public struct ResponseEvent: Codable, Sendable, Equatable {
        public var eventID: String?
        public var response: ResponseObject
        enum CodingKeys: String, CodingKey { case eventID = "event_id", response }
        public init(eventID: String? = nil, response: ResponseObject) { self.eventID = eventID; self.response = response }
    }

    public struct OutputItem: Codable, Sendable, Equatable {
        public var eventID: String?
        public var responseID: String?
        public var outputIndex: Int?
        public var item: RealtimeItem
        enum CodingKeys: String, CodingKey {
            case eventID = "event_id", responseID = "response_id", outputIndex = "output_index", item
        }
        public init(eventID: String? = nil, responseID: String?, outputIndex: Int? = 0, item: RealtimeItem) {
            self.eventID = eventID; self.responseID = responseID; self.outputIndex = outputIndex; self.item = item
        }
    }

    /// `response.output_{text,audio,audio_transcript}.delta`.
    public struct PartDelta: Codable, Sendable, Equatable {
        public var eventID: String?
        public var responseID: String
        public var itemID: String
        public var outputIndex: Int?
        public var contentIndex: Int?
        /// Text, or base64 PCM16 for `response.output_audio.delta`.
        public var delta: String
        enum CodingKeys: String, CodingKey {
            case eventID = "event_id", responseID = "response_id", itemID = "item_id"
            case outputIndex = "output_index", contentIndex = "content_index", delta
        }
        public init(eventID: String? = nil, responseID: String, itemID: String, outputIndex: Int? = 0,
                    contentIndex: Int? = 0, delta: String) {
            self.eventID = eventID; self.responseID = responseID; self.itemID = itemID
            self.outputIndex = outputIndex; self.contentIndex = contentIndex; self.delta = delta
        }
    }

    /// `response.output_text.done` (`text`) / `response.output_audio_transcript.done` (`transcript`).
    public struct PartText: Codable, Sendable, Equatable {
        public var eventID: String?
        public var responseID: String
        public var itemID: String
        public var outputIndex: Int?
        public var contentIndex: Int?
        public var text: String

        public init(eventID: String? = nil, responseID: String, itemID: String, outputIndex: Int? = 0,
                    contentIndex: Int? = 0, text: String) {
            self.eventID = eventID; self.responseID = responseID; self.itemID = itemID
            self.outputIndex = outputIndex; self.contentIndex = contentIndex; self.text = text
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            eventID = try c.string("event_id")
            responseID = try c.decode(String.self, forKey: AnyKey("response_id"))
            itemID = try c.decode(String.self, forKey: AnyKey("item_id"))
            outputIndex = try c.lenientInt("output_index")
            contentIndex = try c.lenientInt("content_index")
            guard let t = try c.string("transcript") ?? c.string("text") else {
                throw DecodingError.keyNotFound(AnyKey("text"), .init(codingPath: c.codingPath,
                                                                      debugDescription: "no text/transcript"))
            }
            text = t
        }

        /// Encodes the text under `key` (`text` or `transcript`).
        func encode(to encoder: Encoder, textKey key: String) throws {
            var c = encoder.container(keyedBy: AnyKey.self)
            try c.encodeIfPresent(eventID, forKey: AnyKey("event_id"))
            try c.encode(responseID, forKey: AnyKey("response_id"))
            try c.encode(itemID, forKey: AnyKey("item_id"))
            try c.encodeIfPresent(outputIndex, forKey: AnyKey("output_index"))
            try c.encodeIfPresent(contentIndex, forKey: AnyKey("content_index"))
            try c.encode(text, forKey: AnyKey(key))
        }

        public func encode(to encoder: Encoder) throws { try encode(to: encoder, textKey: "text") }
    }

    public struct PartRef: Codable, Sendable, Equatable {
        public var eventID: String?
        public var responseID: String
        public var itemID: String
        public var outputIndex: Int?
        public var contentIndex: Int?
        enum CodingKeys: String, CodingKey {
            case eventID = "event_id", responseID = "response_id", itemID = "item_id"
            case outputIndex = "output_index", contentIndex = "content_index"
        }
        public init(eventID: String? = nil, responseID: String, itemID: String, outputIndex: Int? = 0,
                    contentIndex: Int? = 0) {
            self.eventID = eventID; self.responseID = responseID; self.itemID = itemID
            self.outputIndex = outputIndex; self.contentIndex = contentIndex
        }
    }

    public struct FunctionCallDelta: Codable, Sendable, Equatable {
        public var eventID: String?
        public var responseID: String
        public var itemID: String
        public var outputIndex: Int?
        public var callID: String
        public var delta: String
        enum CodingKeys: String, CodingKey {
            case eventID = "event_id", responseID = "response_id", itemID = "item_id"
            case outputIndex = "output_index", callID = "call_id", delta
        }
    }

    public struct FunctionCallDone: Codable, Sendable, Equatable {
        public var eventID: String?
        public var responseID: String
        public var itemID: String
        public var outputIndex: Int?
        public var callID: String
        /// Present in the reference example though not in the schema; the
        /// session falls back to the function_call item's name.
        public var name: String?
        public var arguments: String
        enum CodingKeys: String, CodingKey {
            case eventID = "event_id", responseID = "response_id", itemID = "item_id"
            case outputIndex = "output_index", callID = "call_id", name, arguments
        }
        public init(eventID: String? = nil, responseID: String, itemID: String, outputIndex: Int? = 0,
                    callID: String, name: String?, arguments: String) {
            self.eventID = eventID; self.responseID = responseID; self.itemID = itemID
            self.outputIndex = outputIndex; self.callID = callID; self.name = name; self.arguments = arguments
        }
    }

    public struct RateLimits: Codable, Sendable, Equatable {
        public var eventID: String?
        public var rateLimits: [RateLimit]
        enum CodingKeys: String, CodingKey { case eventID = "event_id", rateLimits = "rate_limits" }
        public init(eventID: String? = nil, rateLimits: [RateLimit]) {
            self.eventID = eventID; self.rateLimits = rateLimits
        }
    }

    // MARK: Type names

    public var type: String {
        switch self {
        case .error: "error"
        case .sessionCreated: "session.created"
        case .sessionUpdated: "session.updated"
        case .itemAdded: "conversation.item.added"
        case .itemDone: "conversation.item.done"
        case .itemCreated: "conversation.item.created"
        case .itemRetrieved: "conversation.item.retrieved"
        case .itemTruncated: "conversation.item.truncated"
        case .itemDeleted: "conversation.item.deleted"
        case .inputTranscriptionDelta: "conversation.item.input_audio_transcription.delta"
        case .inputTranscriptionCompleted: "conversation.item.input_audio_transcription.completed"
        case .inputTranscriptionFailed: "conversation.item.input_audio_transcription.failed"
        case .inputAudioCommitted: "input_audio_buffer.committed"
        case .inputAudioCleared: "input_audio_buffer.cleared"
        case .speechStarted: "input_audio_buffer.speech_started"
        case .speechStopped: "input_audio_buffer.speech_stopped"
        case .inputAudioTimeout: "input_audio_buffer.timeout_triggered"
        case .responseCreated: "response.created"
        case .responseDone: "response.done"
        case .outputItemAdded: "response.output_item.added"
        case .outputItemDone: "response.output_item.done"
        case .outputTextDelta: "response.output_text.delta"
        case .outputTextDone: "response.output_text.done"
        case .outputAudioDelta: "response.output_audio.delta"
        case .outputAudioDone: "response.output_audio.done"
        case .outputAudioTranscriptDelta: "response.output_audio_transcript.delta"
        case .outputAudioTranscriptDone: "response.output_audio_transcript.done"
        case .functionCallArgumentsDelta: "response.function_call_arguments.delta"
        case .functionCallArgumentsDone: "response.function_call_arguments.done"
        case .rateLimitsUpdated: "rate_limits.updated"
        case .unknown(let t, _), .malformed(let t, _, _): t
        }
    }

    // MARK: Coding

    /// Decodes one text frame. Never throws.
    public static func parse(_ text: String) -> ServerEvent {
        parse(data: Data(text.utf8))
    }

    /// Decodes one frame. The fast path decodes once; only odd frames pay for a
    /// second pass into raw JSON (to keep them for logs and traces).
    public static func parse(data: Data) -> ServerEvent {
        let failure: Error
        do {
            return try JSONDecoder().decode(ServerEvent.self, from: data)
        } catch {
            failure = error
        }
        guard let raw = try? JSONDecoder().decode(RealtimeJSON.self, from: data) else {
            return .malformed(type: "", raw: .string(String(decoding: data, as: UTF8.self)), reason: "not JSON")
        }
        guard let type = raw["type"]?.stringValue else {
            return .malformed(type: "", raw: raw, reason: "no type")
        }
        if case DecodingError.dataCorrupted(let ctx) = failure, ctx.debugDescription.hasPrefix("unknown server event") {
            return .unknown(type: type, raw: raw)
        }
        return .malformed(type: type, raw: raw, reason: String(describing: failure))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let type = try c.decode(String.self, forKey: AnyKey("type"))
        func p<T: Decodable>(_: T.Type) throws -> T { try T(from: decoder) }
        switch type {
        case "error": self = .error(try p(ErrorEvent.self))
        case "session.created": self = .sessionCreated(try p(SessionEvent.self))
        case "session.updated": self = .sessionUpdated(try p(SessionEvent.self))
        case "conversation.item.added": self = .itemAdded(try p(ItemEvent.self))
        case "conversation.item.done": self = .itemDone(try p(ItemEvent.self))
        case "conversation.item.created": self = .itemCreated(try p(ItemEvent.self))
        case "conversation.item.retrieved": self = .itemRetrieved(try p(ItemEvent.self))
        case "conversation.item.truncated": self = .itemTruncated(try p(ItemTruncated.self))
        case "conversation.item.deleted": self = .itemDeleted(try p(ItemRef.self))
        case "conversation.item.input_audio_transcription.delta":
            self = .inputTranscriptionDelta(try p(TranscriptionDelta.self))
        case "conversation.item.input_audio_transcription.completed":
            self = .inputTranscriptionCompleted(try p(TranscriptionCompleted.self))
        case "conversation.item.input_audio_transcription.failed":
            self = .inputTranscriptionFailed(try p(TranscriptionFailed.self))
        case "input_audio_buffer.committed": self = .inputAudioCommitted(try p(Committed.self))
        case "input_audio_buffer.cleared": self = .inputAudioCleared(try p(Bare.self))
        case "input_audio_buffer.speech_started": self = .speechStarted(try p(SpeechStarted.self))
        case "input_audio_buffer.speech_stopped": self = .speechStopped(try p(SpeechStopped.self))
        case "input_audio_buffer.timeout_triggered": self = .inputAudioTimeout(try p(TimeoutTriggered.self))
        case "response.created": self = .responseCreated(try p(ResponseEvent.self))
        case "response.done": self = .responseDone(try p(ResponseEvent.self))
        case "response.output_item.added": self = .outputItemAdded(try p(OutputItem.self))
        case "response.output_item.done": self = .outputItemDone(try p(OutputItem.self))
        case "response.output_text.delta": self = .outputTextDelta(try p(PartDelta.self))
        case "response.output_text.done": self = .outputTextDone(try p(PartText.self))
        case "response.output_audio.delta": self = .outputAudioDelta(try p(PartDelta.self))
        case "response.output_audio.done": self = .outputAudioDone(try p(PartRef.self))
        case "response.output_audio_transcript.delta": self = .outputAudioTranscriptDelta(try p(PartDelta.self))
        case "response.output_audio_transcript.done": self = .outputAudioTranscriptDone(try p(PartText.self))
        case "response.function_call_arguments.delta":
            self = .functionCallArgumentsDelta(try p(FunctionCallDelta.self))
        case "response.function_call_arguments.done":
            self = .functionCallArgumentsDone(try p(FunctionCallDone.self))
        case "rate_limits.updated": self = .rateLimitsUpdated(try p(RateLimits.self))
        default:
            throw DecodingError.dataCorruptedError(forKey: AnyKey("type"), in: c,
                                                   debugDescription: "unknown server event \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .unknown(_, let raw), .malformed(_, let raw, _):
            try raw.encode(to: encoder)
            return
        default: break
        }
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(type, forKey: AnyKey("type"))
        switch self {
        case .error(let x): try x.encode(to: encoder)
        case .sessionCreated(let x), .sessionUpdated(let x):
            try c.encodeIfPresent(x.eventID, forKey: AnyKey("event_id"))
            try c.encode(x.session, forKey: AnyKey("session"))
        case .itemAdded(let x), .itemDone(let x), .itemCreated(let x), .itemRetrieved(let x): try x.encode(to: encoder)
        case .itemTruncated(let x): try x.encode(to: encoder)
        case .itemDeleted(let x): try x.encode(to: encoder)
        case .inputTranscriptionDelta(let x): try x.encode(to: encoder)
        case .inputTranscriptionCompleted(let x): try x.encode(to: encoder)
        case .inputTranscriptionFailed(let x): try x.encode(to: encoder)
        case .inputAudioCommitted(let x): try x.encode(to: encoder)
        case .inputAudioCleared(let x): try x.encode(to: encoder)
        case .speechStarted(let x): try x.encode(to: encoder)
        case .speechStopped(let x): try x.encode(to: encoder)
        case .inputAudioTimeout(let x): try x.encode(to: encoder)
        case .responseCreated(let x), .responseDone(let x): try x.encode(to: encoder)
        case .outputItemAdded(let x), .outputItemDone(let x): try x.encode(to: encoder)
        case .outputTextDelta(let x), .outputAudioDelta(let x), .outputAudioTranscriptDelta(let x):
            try x.encode(to: encoder)
        case .outputTextDone(let x): try x.encode(to: encoder, textKey: "text")
        case .outputAudioTranscriptDone(let x): try x.encode(to: encoder, textKey: "transcript")
        case .outputAudioDone(let x): try x.encode(to: encoder)
        case .functionCallArgumentsDelta(let x): try x.encode(to: encoder)
        case .functionCallArgumentsDone(let x): try x.encode(to: encoder)
        case .rateLimitsUpdated(let x): try x.encode(to: encoder)
        case .unknown, .malformed: break
        }
    }

    /// JSON text as the server would send it (used by fakes and replay).
    public func jsonText() throws -> String { try Wire.encode(self) }
}
