import Foundation

/// Every event the client sends (GA Realtime interface).
///
/// Decodable too, so trace replay and tests can read back what was sent.
public enum ClientEvent: Sendable, Equatable, Codable {
    case sessionUpdate(SessionPayload, eventID: String? = nil)
    /// `audio`: base64 PCM16 24 kHz mono.
    case inputAudioAppend(audio: String, eventID: String? = nil)
    case inputAudioCommit(eventID: String? = nil)
    case inputAudioClear(eventID: String? = nil)
    case itemCreate(RealtimeItem, previousItemID: String? = nil, eventID: String? = nil)
    case itemRetrieve(itemID: String, eventID: String? = nil)
    /// Cuts an assistant audio item at `audioEndMs` (what was actually played);
    /// the server deletes the transcript of the unplayed part.
    case itemTruncate(itemID: String, contentIndex: Int = 0, audioEndMs: Int, eventID: String? = nil)
    case itemDelete(itemID: String, eventID: String? = nil)
    /// `nil` params = a plain `{"type":"response.create"}`.
    case responseCreate(ResponseParams?, eventID: String? = nil)
    /// `responseID` nil cancels the in-progress default-conversation response.
    case responseCancel(responseID: String? = nil, eventID: String? = nil)
    /// WebRTC / SIP only; never used by Dee's WebSocket client.
    case outputAudioBufferClear(eventID: String? = nil)

    public var type: String {
        switch self {
        case .sessionUpdate: "session.update"
        case .inputAudioAppend: "input_audio_buffer.append"
        case .inputAudioCommit: "input_audio_buffer.commit"
        case .inputAudioClear: "input_audio_buffer.clear"
        case .itemCreate: "conversation.item.create"
        case .itemRetrieve: "conversation.item.retrieve"
        case .itemTruncate: "conversation.item.truncate"
        case .itemDelete: "conversation.item.delete"
        case .responseCreate: "response.create"
        case .responseCancel: "response.cancel"
        case .outputAudioBufferClear: "output_audio_buffer.clear"
        }
    }

    public var eventID: String? {
        switch self {
        case .sessionUpdate(_, let e), .inputAudioAppend(_, let e), .inputAudioCommit(let e),
             .inputAudioClear(let e), .itemCreate(_, _, let e), .itemRetrieve(_, let e),
             .itemTruncate(_, _, _, let e), .itemDelete(_, let e), .responseCreate(_, let e),
             .responseCancel(_, let e), .outputAudioBufferClear(let e):
            e
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(type, forKey: AnyKey("type"))
        try c.encodeIfPresent(eventID, forKey: AnyKey("event_id"))
        switch self {
        case .sessionUpdate(let s, _):
            try c.encode(s, forKey: AnyKey("session"))
        case .inputAudioAppend(let audio, _):
            try c.encode(audio, forKey: AnyKey("audio"))
        case .inputAudioCommit, .inputAudioClear, .outputAudioBufferClear:
            break
        case .itemCreate(let item, let previous, _):
            try c.encodeIfPresent(previous, forKey: AnyKey("previous_item_id"))
            try c.encode(item, forKey: AnyKey("item"))
        case .itemRetrieve(let id, _), .itemDelete(let id, _):
            try c.encode(id, forKey: AnyKey("item_id"))
        case .itemTruncate(let id, let index, let end, _):
            try c.encode(id, forKey: AnyKey("item_id"))
            try c.encode(index, forKey: AnyKey("content_index"))
            try c.encode(end, forKey: AnyKey("audio_end_ms"))
        case .responseCreate(let params, _):
            try c.encodeIfPresent(params, forKey: AnyKey("response"))
        case .responseCancel(let id, _):
            try c.encodeIfPresent(id, forKey: AnyKey("response_id"))
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        let type = try c.decode(String.self, forKey: AnyKey("type"))
        let e = try c.string("event_id")
        switch type {
        case "session.update":
            self = .sessionUpdate(try c.decode(SessionPayload.self, forKey: AnyKey("session")), eventID: e)
        case "input_audio_buffer.append":
            self = .inputAudioAppend(audio: try c.decode(String.self, forKey: AnyKey("audio")), eventID: e)
        case "input_audio_buffer.commit": self = .inputAudioCommit(eventID: e)
        case "input_audio_buffer.clear": self = .inputAudioClear(eventID: e)
        case "output_audio_buffer.clear": self = .outputAudioBufferClear(eventID: e)
        case "conversation.item.create":
            self = .itemCreate(try c.decode(RealtimeItem.self, forKey: AnyKey("item")),
                               previousItemID: try c.string("previous_item_id"), eventID: e)
        case "conversation.item.retrieve":
            self = .itemRetrieve(itemID: try c.decode(String.self, forKey: AnyKey("item_id")), eventID: e)
        case "conversation.item.delete":
            self = .itemDelete(itemID: try c.decode(String.self, forKey: AnyKey("item_id")), eventID: e)
        case "conversation.item.truncate":
            self = .itemTruncate(itemID: try c.decode(String.self, forKey: AnyKey("item_id")),
                                 contentIndex: try c.lenientInt("content_index") ?? 0,
                                 audioEndMs: try c.lenientInt("audio_end_ms") ?? 0, eventID: e)
        case "response.create":
            self = .responseCreate(try c.value(ResponseParams.self, "response"), eventID: e)
        case "response.cancel":
            self = .responseCancel(responseID: try c.string("response_id"), eventID: e)
        default:
            throw DecodingError.dataCorruptedError(forKey: AnyKey("type"), in: c,
                                                   debugDescription: "unknown client event \(type)")
        }
    }

    /// The JSON text that goes on the socket.
    public func jsonText() throws -> String { try Wire.encode(self) }
}
