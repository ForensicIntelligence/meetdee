import Foundation

/// OpenAI realtime **transcription** sessions: mode 2's hearing (the LAN brain
/// answers, OpenAI hears and speaks).
///
/// Pinned by one live probe (2026-10-16, `scratchpad/sttprobe/probe.py`, fixtures
/// q07 / n03, a few cents): `POST /v1/realtime/client_secrets` with
/// `session.type = "transcription"` (the whole input config rides on the mint:
/// format, noise reduction, transcription model, server VAD) → 200 with an `ek_`
/// secret and `object: realtime.transcription_session`; the socket
/// `wss://api.openai.com/v1/realtime?intent=transcription` with that secret opens
/// at once with `session.created` (no `session.update` needed). Then, per turn:
/// `input_audio_buffer.speech_started` (`audio_start_ms`, `item_id`) →
/// `speech_stopped` (`audio_end_ms`) → `committed` (`item_id`, `previous_item_id`)
/// → `conversation.item.added` / `.done` → `…input_audio_transcription.delta`
/// (word by word, ~1 s after the commit) → `…completed` (`transcript`, `usage`).
/// Model `gpt-transcribe` (the same model the realtime session transcribes with);
/// `languages: ["en"]` is echoed. The WebSocket path was chosen over
/// `/v1/audio/transcriptions` per span: it keeps server VAD (300 / 300 / 0.5, the
/// tuned values), streaming deltas, and the same event names the session decodes.
public enum OpenAITranscription {
    /// The transcription socket (the `ek_` secret goes in `Authorization: Bearer`).
    public static let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
    public static let model = "gpt-transcribe"

    /// Server event types of a transcription session (as probed).
    public enum Event {
        public static let sessionCreated = "session.created"
        public static let speechStarted = "input_audio_buffer.speech_started"
        public static let speechStopped = "input_audio_buffer.speech_stopped"
        public static let committed = "input_audio_buffer.committed"
        public static let itemAdded = "conversation.item.added"
        public static let itemDone = "conversation.item.done"
        public static let delta = "conversation.item.input_audio_transcription.delta"
        public static let completed = "conversation.item.input_audio_transcription.completed"
        public static let failed = "conversation.item.input_audio_transcription.failed"
        public static let error = "error"
    }

    /// The session minted for one socket.
    public struct Session: Sendable, Equatable {
        public var model = OpenAITranscription.model
        public var languages: [String] = ["en"]
        /// Words the transcriber should expect ("Dee", the wake phrase).
        public var keywords: [String] = ["Dee"]
        /// Same values as the tuned realtime session (`CloudSettings.turnDetection`).
        public var threshold = 0.5
        public var prefixPaddingMs = 300
        public var silenceDurationMs = 300
        /// `far_field` for a phone on a desk; nil turns it off.
        public var farField = true

        public static let `default` = Session()
        public init() {}

        /// The `session` object of the mint request.
        public func mintSession() -> RealtimeJSON {
            var transcription: [String: RealtimeJSON] = [
                "model": .string(model),
                "languages": .array(languages.map { .string($0) }),
            ]
            let words = keywords.map { $0.components(separatedBy: CharacterSet(charactersIn: "<>\r\n")).joined(separator: " ") }
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !words.isEmpty { transcription["keywords"] = .array(words.map { .string($0) }) }
            let input: [String: RealtimeJSON] = [
                "format": ["type": "audio/pcm", "rate": 24000],
                "noise_reduction": farField ? ["type": "far_field"] : .null,
                "transcription": .object(transcription),
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": .number(threshold),
                    "prefix_padding_ms": .number(Double(prefixPaddingMs)),
                    "silence_duration_ms": .number(Double(silenceDurationMs)),
                ],
            ]
            return ["type": "transcription", "audio": ["input": .object(input)]]
        }
    }
}
