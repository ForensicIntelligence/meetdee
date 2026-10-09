import Foundation

/// Everything that configures a `RealtimeSession`: the wire session (sent in
/// `session.update`) and the client's own behaviour (timeouts, rollover,
/// reconnect, backpressure).
public struct RealtimeSessionConfig: Sendable, Equatable {
    // MARK: Wire session

    public var model = "gpt-realtime-2.1-mini"
    /// `wss://api.openai.com/v1/realtime`; `?model=` is appended.
    public var endpoint = URL(string: "wss://api.openai.com/v1/realtime")!
    /// Fixed for the life of a session (the API refuses changes after the first audio).
    public var voice: RealtimeVoice = .named("marin")
    /// Persona + self + memories + style. Keep byte-stable within a session so
    /// prompt caching works; change it with `updateSession(instructions:)`.
    public var instructions = ""
    public var tools: [RealtimeTool] = []
    public var toolChoice: ToolChoice = .auto
    /// semantic_vad eagerness: `low` (8 s max wait), `medium`/`auto` (4 s), `high` (2 s).
    public var eagerness = "auto"
    /// `far_field` for a phone on a desk; nil turns noise reduction off.
    public var noiseReduction: NoiseReduction? = .farField
    /// Input transcription (feeds `.userTranscript`). `gpt-transcribe` is the
    /// committed-turn model (WebSocket only); nil turns it off.
    public var transcription: InputTranscription? = InputTranscription(
        model: "gpt-transcribe", languages: ["en"], keywords: ["Dee"])
    /// Server-side truncation keeps this fraction of the context when full
    /// (amortises truncation, keeps the cache warm). nil = server default.
    public var truncationRetention: Double? = 0.8
    /// 0.25…1.5. Applied between turns only.
    public var speed: Double = 1.0
    /// `minimal` / `low` / `medium` / `high`; nil = server default.
    public var reasoningEffort: String? = "low"
    /// Default per-response cap for replies, initiatives and tool follow-ups.
    /// Counts audio (20 tokens per second of speech), transcript and reasoning
    /// tokens, so 1024 is roughly 40 s of speech: a runaway guard, not a style
    /// control (keep replies short through the instructions). A reply that hits it
    /// ends with `.responseDone` reason `max_output_tokens`.
    public var maxOutputTokens: Int? = 1024
    /// Stable hashed user id, sent as `OpenAI-Safety-Identifier`.
    public var safetyIdentifier: String?

    // MARK: Client behaviour

    /// Socket open + `session.update` → `session.updated` must finish within this.
    public var connectTimeout: Double = 10
    /// `response.create` → `response.created` deadline; past it the response is
    /// abandoned and `.fallbackAdvised(.noResponse)` is emitted.
    public var responseTimeout: Double = 2.5
    /// `response.created` → first audio deadline (tool-only responses exempt); past
    /// it the response is cancelled and `.fallbackAdvised(.noResponse)` is emitted.
    public var firstAudioTimeout: Double = 6
    /// After `response.cancel`, a `response.done` that never comes is assumed after this.
    public var cancelTimeout: Double = 3
    /// Realtime sessions end at 60 minutes. A rollover opens the new session next
    /// to the old one (make-before-break) and switches at a quiet moment: after
    /// `rolloverAfter` only when fully idle; after `forceRolloverAfter` as soon as
    /// nothing is generating or playing (and the user has finished, or 30 s passed).
    public var rolloverAfter: Double = 50 * 60
    public var forceRolloverAfter: Double = 59 * 60
    /// How the rollover summary is made.
    public var rolloverSummary: SummaryMode = .outOfBand
    public var summaryTimeout: Double = 6
    /// Recent messages (user + Dee) replayed into a new session ("the last 6 turns").
    public var seedMessages = 12
    /// Name used for Dee in the seed transcript.
    public var assistantName = "Dee"
    /// Reconnect on unexpected drops (seeded like a rollover).
    public var autoReconnect = true
    /// Back-off between reconnect attempts (the last value repeats).
    public var reconnectDelays: [Double] = [0.5, 1, 2, 4, 8, 15, 30]
    /// Mic audio is dropped (and `.fallbackAdvised(.congested)` emitted) while more
    /// than this many bytes are queued on the socket (~3 s of base64 PCM16).
    public var maxUplinkBacklogBytes = 192_000
    /// Mic audio appended while (re)connecting is kept, up to this, and sent once ready.
    public var preconnectBufferMs = 2_000
    /// User speech that starts before a reply's first audio cancels the reply
    /// (`.replyPreempted`): she never answers half a thought. Speech that starts
    /// while her previous audio is still playing is left to the app (it may be
    /// her echo: `rejectEcho` or `bargeIn` decides).
    public var cancelUnspokenReplyOnSpeech = true
    /// Speaking rate used to place sentences on the audio timeline before an
    /// item's audio is complete (ms per transcript character at speed 1.0). The
    /// starting value only: with `calibrateSpeakingRate` the session learns the
    /// voice's real rate from every completed reply (live: 40–82 ms/char).
    public var estimatedMsPerCharacter: Double = 62
    /// Learn the speaking rate from completed replies (audio ms ÷ transcript
    /// characters, smoothed). Sentence hints get closer to the real audio, so the
    /// heard/not-heard split of a cut reply (`HeardRule`) is closer to what the
    /// listener heard.
    public var calibrateSpeakingRate = true
    /// A committed user turn nobody has answered yet (no `requestResponse`, no
    /// `userTurnHandled` / `dropUserItem` / `rejectEcho`) keeps the session busy
    /// (no rollover switch) for at most this many seconds after its commit.
    public var unansweredHold: Double = 20

    public enum SummaryMode: Sendable, Equatable {
        /// Ask the old session itself (out-of-band text response, `conversation: "none"`).
        case outOfBand
        /// Seed only the recent messages.
        case none
    }

    public init() {}

    /// The full `session.update` payload. `includeVoice` is false for mid-session
    /// updates (the voice is frozen after the first audio).
    public func sessionPayload(includeVoice: Bool = true) -> SessionPayload {
        let input = AudioInputConfig(
            format: .pcm24k,
            noiseReduction: noiseReduction.map { .value($0) } ?? .null,
            transcription: transcription.map { .value(Self.sanitized($0)) } ?? .null,
            turnDetection: .value(.semanticManual(eagerness: eagerness)))
        let output = AudioOutputConfig(format: .pcm24k, voice: includeVoice ? voice : nil,
                                       speed: min(max(speed, 0.25), 1.5))
        return SessionPayload(
            type: "realtime",
            model: model,
            instructions: instructions,
            outputModalities: ["audio"],
            audio: AudioConfig(input: input, output: output),
            tools: tools,
            toolChoice: tools.isEmpty ? nil : toolChoice,
            truncation: truncationRetention.map { .retentionRatio($0) },
            tracing: .null,
            reasoning: reasoningEffort.map { Reasoning(effort: $0) })
    }

    /// Keywords may not contain `<`, `>` or line breaks (the API rejects the update).
    static func sanitized(_ t: InputTranscription) -> InputTranscription {
        var t = t
        t.keywords = t.keywords?
            .map { $0.components(separatedBy: CharacterSet(charactersIn: "<>\r\n")).joined(separator: " ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return t
    }

    /// `wss://…/v1/realtime?model=…`.
    public var url: URL {
        var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var q = c.queryItems ?? []
        q.removeAll { $0.name == "model" }
        q.append(URLQueryItem(name: "model", value: model))
        c.queryItems = q
        return c.url!
    }
}

/// Where the session is in a conversation.
public enum RealtimeState: String, Sendable, Equatable {
    /// No connection.
    case idle
    /// Opening (or re-opening) a connection.
    case connecting
    /// Connected; nobody is talking and nothing is being generated.
    case listening
    /// The server heard the user start talking (`speech_started` open).
    case userTurn
    /// `response.create` sent; no audio yet.
    case awaitingResponse
    /// Audio is arriving, or the app is still playing it.
    case speaking
    /// `response.cancel` sent; waiting for `response.done`.
    case cancelling
}

/// Why a response was created.
public enum ResponseKind: String, Sendable, Equatable {
    /// Answering a committed user turn (`requestResponse`).
    case reply
    /// Dee speaks first (`initiative`).
    case initiative
    /// Speaking after tool outputs.
    case toolFollowUp
    /// A verbatim line out of band (`say`): `conversation: "none"`, never in the
    /// conversation or the history, no DNA, no tools.
    case say
}

/// The local voice pipeline should take this turn (or stay in charge).
public enum FallbackReason: Sendable, Equatable {
    /// The socket dropped (network change, server close, ping timeout).
    case socketLost(code: Int, detail: String?)
    /// Could not connect at all.
    case connectFailed(String)
    /// `response.created` did not arrive within `responseTimeout`.
    case noResponse
    /// 429 / rate-limit error. Retry after `retryAfter` seconds when given.
    case rateLimited(retryAfter: Double?)
    /// Quota or the project's hard spend cap.
    case quotaExceeded
    /// The key was refused (401 / 403 / invalid_api_key), after one retry with a
    /// freshly minted secret.
    case unauthorized
    /// No key stored.
    case noKey
    /// The uplink cannot keep up; mic audio is being dropped.
    case congested
    /// Server-side failure (5xx / server_error).
    case serverError(String?)
}

/// A server `error` that did not end the session, classified.
public struct RealtimeIssue: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case moderation, rateLimit, quota, auth, server, invalidRequest, sessionExpired, other
    }
    public var kind: Kind
    public var code: String?
    public var message: String?
    /// The client event that caused it, if any.
    public var eventID: String?

    public init(kind: Kind, code: String?, message: String?, eventID: String?) {
        self.kind = kind; self.code = code; self.message = message; self.eventID = eventID
    }

    public static func classify(_ e: APIError) -> Kind {
        let code = (e.code ?? "").lowercased()
        let type = (e.type ?? "").lowercased()
        let message = (e.message ?? "").lowercased()
        if ["insufficient_quota", "billing_hard_limit_reached", "spend_limit_reached"].contains(code)
            || message.contains("quota") || message.contains("spend limit") { return .quota }
        if code == "rate_limit_exceeded" || code == "slow_down" || type == "rate_limit_error" { return .rateLimit }
        if code == "invalid_api_key" || type == "authentication_error" || code == "unauthorized" { return .auth }
        let moderation = ["moderation", "content_policy", "content_filter", "safety", "policy_violation"]
        if moderation.contains(where: { code.contains($0) || type.contains($0) }) { return .moderation }
        if code == "session_expired" || message.contains("maximum duration") { return .sessionExpired }
        if type == "server_error" || code == "server_error" || code == "server_is_overloaded" { return .server }
        if type == "invalid_request_error" { return .invalidRequest }
        return .other
    }

    /// The server refused the socket's bearer itself — an `ek_` client secret
    /// already used (`ephemeral_token_already_used`), expired or revoked — as
    /// opposed to the project key being wrong. A freshly minted secret fixes it.
    public static func isCredentialRefusal(_ e: APIError) -> Bool {
        let code = (e.code ?? "").lowercased()
        if code.contains("ephemeral") || code.contains("client_secret") { return true }
        if code.contains("token"), ["used", "expired", "invalid", "revoked"].contains(where: code.contains) { return true }
        return false
    }

    /// WebSocket close codes the server uses to refuse a socket's credentials
    /// (3000 unauthorized, 3003 forbidden, 4001/4003, 1008 policy violation).
    public static func isCredentialRefusal(closeCode: Int) -> Bool {
        [3000, 3003, 4001, 4003, 1008].contains(closeCode)
    }
}

/// A function call from the model.
public struct RealtimeToolCall: Sendable, Equatable {
    public var callID: String
    public var name: String
    /// JSON text of the arguments.
    public var arguments: String
    public var responseID: String
    public var itemID: String

    public init(callID: String, name: String, arguments: String, responseID: String, itemID: String) {
        self.callID = callID; self.name = name; self.arguments = arguments
        self.responseID = responseID; self.itemID = itemID
    }

    /// The arguments parsed (nil if not JSON).
    public var argumentsJSON: RealtimeJSON? { RealtimeJSON.parse(arguments) }
}

/// What a tool handler returns.
public struct RealtimeToolResult: Sendable, Equatable {
    public enum FollowUp: Sendable, Equatable {
        /// Always ask the model to speak with the result (`recall`).
        case always
        /// Never (a silent side effect).
        case never
        /// Only if the response that made the call said nothing aloud (`remember`
        /// at the end of a spoken turn needs no follow-up; a bare `remember` does).
        case ifSilent
    }
    /// Sent as `function_call_output.output` (usually JSON text).
    public var output: String
    public var followUp: FollowUp

    public init(output: String, followUp: FollowUp = .ifSilent) { self.output = output; self.followUp = followUp }
}

public typealias RealtimeToolHandler = @Sendable (RealtimeToolCall) async -> RealtimeToolResult

/// One finished message, for history mirroring and rollover seeding.
public struct ConversationTurn: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public var role: Role
    public var text: String
    public var itemID: String?

    public init(role: Role, text: String, itemID: String?) { self.role = role; self.text = text; self.itemID = itemID }
}

/// How a response ended.
public struct ResponseSummary: Sendable, Equatable {
    public var responseID: String?
    public var kind: ResponseKind
    /// `completed`, `cancelled`, `failed`, `incomplete`.
    public var status: String
    /// `turn_detected`, `client_cancelled`, `max_output_tokens`, `content_filter`,
    /// or Dee's own `connection_lost` / `closed` / `superseded` / `no_response` /
    /// `cancel_timeout`.
    public var reason: String?
    public var usage: Usage?
    /// Milliseconds of audio received for this response.
    public var audioMs: Int
    public var itemIDs: [String]
    /// What was said (the assistant transcript; nil if nothing).
    public var transcript: String?
    /// `status_details.error.code` for failed responses.
    public var errorCode: String?

    /// The reply was cut off by `max_output_tokens` (she stopped mid-sentence).
    public var hitTokenLimit: Bool { status == "incomplete" && reason == "max_output_tokens" }
}

/// What `bargeIn(cuts:)` / `bargeIn(playedMs:)` did.
public struct BargeInOutcome: Sendable, Equatable {
    public struct Truncation: Sendable, Equatable {
        public var itemID: String
        public var audioEndMs: Int
        /// How many of the item's sentences (as emitted in `.assistantSentence`)
        /// count as heard by `HeardRule` at `audioEndMs`. The session's history
        /// keeps exactly these; DeeVoice's `SentenceClock` reports exactly these
        /// as `.finished(heard: true)`.
        public var heardSentences: Int
        /// Those sentences joined (nil: none).
        public var heardText: String?
        public init(itemID: String, audioEndMs: Int, heardSentences: Int = 0, heardText: String? = nil) {
            self.itemID = itemID; self.audioEndMs = audioEndMs
            self.heardSentences = heardSentences; self.heardText = heardText
        }
    }
    /// A generating response was cancelled.
    public var cancelledResponse = false
    /// Every assistant item truncated, and where, in the order given.
    public var truncations: [Truncation] = []
    /// The first item truncated, and where.
    public var truncatedItemID: String? { truncations.first?.itemID }
    public var audioEndMs: Int? { truncations.first?.audioEndMs }
    public init() {}
}

/// What `requestResponse` did.
public enum RequestOutcome: Sendable, Equatable {
    case sent
    /// A cancelled response is still closing; this one is sent after its `response.done`.
    /// A later queued request replaces it (`.responseDone` reason `superseded`).
    case queued
}

/// What `initiative` did.
public enum InitiativeOutcome: Sendable, Equatable {
    case sent
    case refused(Refusal)

    public enum Refusal: String, Sendable, Equatable {
        case notConnected, userSpeaking, responseInFlight, speaking
    }
}

public enum RealtimeSessionError: Error, Sendable, Equatable {
    case notConnected
    /// A response is already generating; barge in or wait for `.responseDone`.
    case responseInFlight
    case noKey
    case unauthorized(String?)
    case rateLimited(retryAfter: Double?)
    case socket(SocketFailure)
    /// The server rejected `session.update` (the message says which field).
    case configRejected(String?)
    case timeout
    /// `close()` was called while connecting.
    case closed
}

/// Everything the session reports. Single consumer (`RealtimeSession.events`).
public enum RealtimeEvent: Sendable, Equatable {
    case connected(sessionID: String?, model: String?)
    case stateChanged(RealtimeState)
    case disconnected(code: Int?, reason: String?)
    /// Connected again after a drop (seeded with summary + recent messages).
    case recovered(sessionID: String?)

    case userSpeechStarted(itemID: String, audioStartMs: Int)
    case userSpeechStopped(itemID: String, audioEndMs: Int)
    /// The user's audio became conversation item `itemID`. Request a reply now.
    case userCommitted(itemID: String, previousItemID: String?)
    case userTranscriptDelta(itemID: String, delta: String)
    case userTranscript(itemID: String, text: String)
    case userTranscriptFailed(itemID: String, message: String?)
    /// `rejectEcho` deleted this item; it will get no transcript and no reply.
    case echoRejected(itemID: String)

    case responseStarted(responseID: String, kind: ResponseKind)
    /// PCM16 mono 24 kHz, ready for the player.
    case assistantAudio(itemID: String, pcm: Data)
    case assistantAudioDone(itemID: String, totalMs: Int)
    case assistantTranscriptDelta(itemID: String, delta: String)
    /// A complete sentence of the transcript. `audioMsHint` = estimated offset (ms
    /// into the item's audio) where the sentence ends: proportional to its share of
    /// the transcript once the item's audio is complete, else from the speaking
    /// rate. Emit `deeSaid` when playback passes it.
    case assistantSentence(itemID: String, text: String, audioMsHint: Int)
    case assistantTranscript(itemID: String, text: String)
    /// The server copy of this item now ends at `audioEndMs` (what was played).
    case assistantTruncated(itemID: String, audioEndMs: Int)
    case responseDone(ResponseSummary)

    case toolCall(RealtimeToolCall)
    /// An initiative was cancelled before any audio because the user started talking.
    case initiativeCancelled(responseID: String?)
    /// A reply was cancelled before any audio because the user kept talking (or
    /// `rejectEcho` withdrew the turn it answered). Request a new reply after the
    /// next `.userCommitted`. If the speech that preempted it is later rejected as
    /// echo, the session re-requests it by itself (a new `.responseStarted`).
    case replyPreempted(responseID: String?)

    case rateLimits([RateLimit])
    /// Mic audio given to the session (`feedAudio` / `appendAudio`) never reached
    /// the server: `frames` 24 kHz frames of it (exact), dropped while the uplink
    /// was congested, the feed queue overflowed, or the (re)connect buffer
    /// overflowed or went stale. `atFeedFrame` is where it was in the feed stream
    /// (every frame fed since the session was created, dropped or not, counted
    /// in order: the app can count the same). The server's `audio_start_ms` /
    /// `audio_end_ms` skip it. `atServerMs` (informational): where on the live
    /// session's input timeline the gap is; nil when no session was live.
    case uplinkDropped(frames: Int, atFeedFrame: Int, atServerMs: Int?)
    /// The live session's input timeline (server offset 0 of `audio_start_ms` /
    /// `audio_end_ms`) starts at feed frame `feedFrame`; frames after it reach
    /// that timeline in order, except those `.uplinkDropped` reports. Emitted just
    /// before every `.connected` and `.rolledOver`, so the app can rebase its map
    /// exactly even for audio it fed before it saw the event.
    case uplinkOrigin(feedFrame: Int)
    case error(RealtimeIssue)
    case fallbackAdvised(FallbackReason)

    /// Once per rollover (again only if it becomes forced).
    case rolloverStarted(forced: Bool)
    case rolledOver(sessionID: String?)
}
