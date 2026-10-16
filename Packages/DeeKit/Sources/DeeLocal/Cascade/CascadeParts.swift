import Foundation
import DeeRealtime

// The pluggable parts of the cascaded pipeline (contract §2): hearing (turn
// detection + speech-to-text), the chat brain, and her voice (text-to-speech).
// `CascadeSocket` drives them and speaks the realtime wire protocol to the session.

/// What hearing reports, on the socket's fed-frame clock (24 kHz frames since the socket opened).
public enum HearingEvent: Sendable, Equatable {
    /// Turn `turn` began (audio_start_ms = frame / 24, prefix padding included).
    case speechStarted(turn: Int, frame: Int64)
    case speechStopped(turn: Int, frame: Int64)
    /// Turn `turn` is closed: it becomes a user item. Always before its transcripts.
    case committed(turn: Int)
    case transcriptDelta(turn: Int, delta: String)
    case transcriptCompleted(turn: Int, text: String)
    case transcriptFailed(turn: Int, message: String)
    /// Hearing stopped working (never falls back to another provider).
    case failed(ProviderIssue)
}

/// Turn detection + speech-to-text for one socket.
public protocol CascadeHearing: AnyObject, Sendable {
    /// Starts; events go to `sink` in order. Throws a `ProviderIssue` when it can't start.
    func start(sink: @escaping @Sendable (HearingEvent) -> Void) async throws
    /// PCM16 mono 24 kHz, in uplink order (frame = the first sample's fed frame).
    func feed(_ pcm: Data, atFrame frame: Int64)
    /// `input_audio_buffer.commit`: close the open turn now (or make one from the buffer).
    func commitNow()
    /// `input_audio_buffer.clear`.
    func clear()
    /// Words to expect ("Dee", the wake phrase).
    func setKeywords(_ words: [String])
    func stop()
    /// Which timing profile fits it.
    var timingSTT: TimingProfile.CascadeSTT { get }
}

/// How one sentence should sound.
public struct SpeechDelivery: Sendable, Equatable {
    /// OpenAI-style voice instructions (style + the DNA's `Voice:` words).
    public var instructions: String?
    /// 0.25…1.5 (session speed).
    public var speed: Double
    /// Pitch multiplier for on-device voices (1 = neutral).
    public var pitch: Float
    public init(instructions: String? = nil, speed: Double = 1, pitch: Float = 1) {
        self.instructions = instructions; self.speed = speed; self.pitch = pitch
    }
}

/// Her voice: text in, PCM16 mono 24 kHz out (streamed).
public protocol CascadeVoice: Sendable {
    /// Warm the engine / connection (inside an open window only).
    func prepare() async
    func synthesize(_ text: String, delivery: SpeechDelivery) -> AsyncThrowingStream<Data, Error>
    var label: ProviderLabel { get }
}

/// The chat brain (one LAN OpenAI-compatible server).
public protocol CascadeChat: Sendable {
    func stream(_ request: ChatRequest, nativeRoute: Bool) -> AsyncThrowingStream<ChatPiece, Error>
    var host: String { get }
    var vendor: Vendor { get }
    var label: ProviderLabel { get }
}

/// A chat client tagged with its vendor (Ollama gets keep_alive and the native route after tools).
public struct VendorChat: CascadeChat {
    public let client: CompatClient
    public let vendor: Vendor
    public let firstByteDeadline: Double
    public init(client: CompatClient, vendor: Vendor, firstByteDeadline: Double = 90) {
        self.client = client; self.vendor = vendor; self.firstByteDeadline = firstByteDeadline
    }
    public var host: String { client.host }
    public var label: ProviderLabel { client.label }
    public func stream(_ request: ChatRequest, nativeRoute: Bool) -> AsyncThrowingStream<ChatPiece, Error> {
        client.chat(request, route: nativeRoute && vendor == .ollama ? .ollamaNative : .openAI,
                    firstByteDeadline: firstByteDeadline, purpose: request.maxTokens == 1 ? "warmup" : "chat")
    }
}

/// Options of one cascaded socket.
public struct CascadeOptions: Sendable, Equatable {
    /// Chat model id on the LAN server.
    public var model: String
    /// Offer the session's tools to the model (only if the probe saw tool support).
    public var toolsSupported = true
    /// Ollama `keep_alive` (nil: not sent).
    public var keepAlive: String?
    /// History messages kept (plus an on-phone rolling summary of older ones).
    public var historyLimit = 12
    /// Warm-up requests (LAN brain only): one at open, one per speech start when the prefix changed.
    public var warmUps = true
    /// A response waits at most this long for pending transcripts before answering what it has.
    public var transcriptWait: Double = 8
    /// Max tokens when the session gives none.
    public var defaultMaxTokens = 300
    /// Verify `chunk.model` against `model` (LM Studio silently answers with another model).
    public var checkModelEcho = true
    /// Base voice style (OpenAI-style instructions), like ClipCache's.
    public var voiceStyle = "You are Dee, a small, sweet, playful robot companion with a bright, youthful, expressive voice."

    public init(model: String) { self.model = model }
}

/// The tool-use paragraph appended to the session instructions for chat models (measured:
/// with full DNA and no explicit policy, `remember` was never called).
public enum CascadePrompt {
    public static let toolPolicy = """
    TOOLS: You can call functions. Before answering anything about what you know of this person \
    (their name, pets, family, likes, plans, what they told you before), call recall first and answer from its result; \
    never guess or invent a fact you could recall. When they tell you something about themselves worth keeping, \
    call remember with it, then answer briefly. Never say you are calling a tool. Never read out tool results verbatim.
    """

    /// Spoken plainly: no markdown, no emoji, no stage directions (chat models default to them).
    public static let speechStyle = """
    You are speaking out loud through a small robot: plain spoken words only — no markdown, no lists, no emoji, \
    no asterisks or stage directions, no thinking out loud.
    """

    /// Marks the per-turn context on the user message.
    public static func userTurn(volatileDNA: String, notes: [String], transcript: String?) -> String {
        var parts: [String] = []
        if !volatileDNA.isEmpty { parts.append(volatileDNA) }
        if !notes.isEmpty { parts.append(notes.joined(separator: "\n")) }
        if let transcript {
            parts.append("THEY JUST SAID:\n\(transcript)")
        } else {
            parts.append("Nobody said anything new: it's your turn to speak (see THIS TURN).")
        }
        return parts.joined(separator: "\n\n")
    }

    /// The verbatim line of a `say` (RealtimeBrain.say), so it is spoken without a model call.
    public static func verbatimLine(_ instructions: String?) -> (line: String, voiceWords: String?)? {
        guard let s = instructions else { return nil }
        let marker = "and nothing else: \""
        guard s.hasPrefix("Say exactly this"), let r = s.range(of: marker) else { return nil }
        let rest = s[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let line = String(rest[..<end])
        let after = rest[rest.index(after: end)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (line, after.isEmpty ? nil : after)
    }

    /// The DNA's `Voice: …` words (section 8), for TTS instructions.
    public static func voiceWords(inDNA dna: String) -> String? {
        for line in dna.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Voice:") { return t }
        }
        return nil
    }
}
