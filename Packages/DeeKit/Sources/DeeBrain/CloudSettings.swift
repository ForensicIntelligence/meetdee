import DeeCore
import DeeRealtime
import DeeSelf
import Foundation

/// The cloud-voice settings (Settings › Dee) and the session config built from them.
public struct CloudSettings: Sendable, Equatable {
    /// UserDefaults keys (Settings.bundle).
    public enum Key {
        public static let apiKey = "openAIKey"
        public static let voice = "cloudVoice"
        public static let model = "cloudModel"
        public static let shareMemories = "shareMemoriesWithCloud"
        public static let lastVoice = "cloudVoiceInUse"
        public static let disclosed = "aiVoiceDisclosed"
    }

    /// Voices the realtime models speak (`marin` and `cedar` are the recommended ones).
    public static let voices = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]
    public static let models = ["gpt-realtime-2.1-mini", "gpt-realtime-2.1"]

    public var voice = "marin"
    public var model = "gpt-realtime-2.1-mini"
    public var shareMemories = true

    public init(voice: String = "marin", model: String = "gpt-realtime-2.1-mini", shareMemories: Bool = true) {
        self.voice = Self.voices.contains(voice) ? voice : "marin"
        self.model = Self.models.contains(model) ? model : "gpt-realtime-2.1-mini"
        self.shareMemories = shareMemories
    }

    public init(defaults d: UserDefaults) {
        self.init(voice: d.string(forKey: Key.voice) ?? "marin",
                  model: d.string(forKey: Key.model) ?? "gpt-realtime-2.1-mini",
                  shareMemories: d.object(forKey: Key.shareMemories) as? Bool ?? true)
    }

    /// How eagerly the server ends a user turn (`semantic_vad` eagerness).
    ///
    /// `high` (tune 1). The live harness measured `auto` (= `medium`, 4 s cap)
    /// holding plain turns 0.6–1.0 s past their last word and 3–4.5 s after a
    /// punchline or a filler, which alone breaks the latency gate (p50 ≤ 1.1 s).
    /// `high` (2 s cap) ends plain short turns fast. What it costs — committing
    /// "Hold on." or "…and" as a turn of its own — the brain absorbs: it never
    /// answers an unfinished turn (`TurnPolicy.unfinished`), takes back an unheard
    /// reply to one, and answers the continuation together with it; a reply that
    /// has no audio yet is also cancelled by the session when they go on talking
    /// (`cancelUnspokenReplyOnSpeech`). `low` would wait up to 8 s on every pause.
    public static let turnEagerness = "high"

    /// The turn detection chosen by the tune-2 live A/B (`scratchpad/tune2-brain.md`):
    /// `server_vad`, 300 ms of silence, 300 ms prefix, threshold 0.5, no auto
    /// response or interrupt. Same brain, same fixtures, end of a complete turn →
    /// first audio (p50 / p90): server 300 ms 1.07 / 1.59 s and 1.21 / 1.54 s (the
    /// only config inside the gate, both rounds); server 450 ms 1.40 / 1.94; 600 ms
    /// 1.45 / 1.87; semantic `high` 1.55 / 2.75 and 1.73 / 3.51; `auto` 1.62 / 3.93.
    /// What it costs — a commit at every 0.3 s pause — the brain absorbs from the
    /// transcription deltas (`TurnPolicy.held`: trailing words, "let me", riddles;
    /// an unheard fast reply is taken back) and the session cancels a reply with no
    /// audio yet when they go on (`cancelUnspokenReplyOnSpeech`).
    ///
    /// Live only once `RealtimeSessionConfig` can carry it (ask to DeeRealtime:
    /// `public var turnDetection: TurnDetection?`, used by `sessionPayload` instead
    /// of `.semanticManual(eagerness:)` when set); until then the session runs
    /// semantic_vad at `turnEagerness`.
    public static let turnDetection = TurnDetection(type: "server_vad", createResponse: false, interruptResponse: false,
                                                    threshold: 0.5, prefixPaddingMs: 300, silenceDurationMs: 300)

    /// docs/DNA.md §3/D5: stable instructions (no names, memories or state), the
    /// tools, the voice; `semantic_vad` (eagerness `turnEagerness`) with
    /// `create_response: false` and `interrupt_response: false` is the session's own
    /// default (Dee keeps the floor).
    public func sessionConfig(tools: [RealtimeTool] = []) -> RealtimeSessionConfig {
        var c = RealtimeSessionConfig()
        c.model = model
        c.eagerness = Self.turnEagerness
        c.voice = .named(voice)
        c.instructions = DNASessionInstructions.current
        c.tools = tools
        c.reasoningEffort = ThinkingMode.chatEffort.rawValue
        return c
    }
}

/// The OpenAI key pasted into Settings › Dee: validated, moved to the Keychain, and
/// cleared from UserDefaults (where Settings.bundle fields live, unencrypted).
public struct KeyIntake: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// Nothing pasted.
        case nothing
        /// Stored in the Keychain (validated, or unvalidated because offline).
        case stored(validated: Bool)
        /// The key was refused (401/403) or not an OpenAI key: not stored.
        case rejected(String)
    }

    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    public let keyStore: KeyStore
    public let fetch: Fetch
    public var endpoint = URL(string: "https://api.openai.com/v1/models")!

    public init(keyStore: KeyStore = KeyStore(), fetch: @escaping Fetch = KeyIntake.uncachedFetch) {
        self.keyStore = keyStore
        self.fetch = fetch
    }

    /// The check's own session: ephemeral (no disk cache, cookies or credential
    /// store), so the authenticated request never lands in a `Cache.db`.
    public static let uncachedFetch: Fetch = { request in
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }

    /// The Keychain refused the key (the outcome text `absorb` returns).
    public static let keychainFailure = "Couldn't save the key in the Keychain."

    /// Reads the Settings field, validates with one cheap GET, stores, clears the field.
    /// The field is cleared once the key is in the Keychain, or when it was refused
    /// or is not a key; it is kept only when the Keychain could not save it (so the
    /// pasted key is not lost; the next launch tries again).
    public func absorb(from defaults: UserDefaults) async -> Outcome {
        guard let raw = defaults.string(forKey: CloudSettings.Key.apiKey),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothing }
        let outcome = await absorb(raw)
        if outcome != .rejected(Self.keychainFailure) {
            defaults.removeObject(forKey: CloudSettings.Key.apiKey)
        }
        return outcome
    }

    public func absorb(_ raw: String) async -> Outcome {
        guard let key = KeyStore.normalize(raw) else { return .rejected("That doesn't look like an OpenAI key.") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        var validated = false
        do {
            let (_, response) = try await fetch(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { return .rejected("OpenAI refused that key.") }
            validated = (200..<300).contains(status)
        } catch {
            // Offline: keep it; the session will say so if it is refused later.
        }
        do { _ = try keyStore.save(key) } catch { return .rejected(Self.keychainFailure) }
        return .stored(validated: validated)
    }
}

/// The small status chip in the Release build: what is wrong with her cloud voice,
/// in words for the person in front of her (`DeeModel.voiceProblem`).
public enum CloudStatus: Sendable, Equatable {
    case noKey
    case badKey
    case offline
    case rateLimited
    case quota
    case serverTrouble
    /// Not a cloud problem (microphone off, audio failing): VoiceProblem's own words.
    case other(message: String, symbol: String)

    public init?(_ problem: VoiceProblem?) {
        guard let problem else { return nil }
        switch problem {
        case .cloudVoiceNeedsSetup(let detail):
            self = detail.localizedCaseInsensitiveContains("no openai key") || detail.localizedCaseInsensitiveContains("no key")
                ? .noKey : .badKey
        case .cloudVoiceUnavailable(let detail):
            let d = detail.lowercased()
            if d.contains("rate limit") { self = .rateLimited }
            else if d.contains("quota") || d.contains("spend limit") { self = .quota }
            else if d.contains("server error") { self = .serverTrouble }
            else { self = .offline }
        default:
            self = .other(message: problem.message, symbol: problem.symbol)
        }
    }

    public var message: String {
        switch self {
        case .noKey: "Add your OpenAI key in Settings › Dee"
        case .badKey: "OpenAI refused the key — paste a new one in Settings › Dee"
        case .offline: "No connection — I'll talk again when I'm back online"
        case .rateLimited: "OpenAI is busy (rate limited) — trying again"
        case .quota: "The OpenAI spend limit was reached"
        case .serverTrouble: "My voice service is having trouble — trying again"
        case .other(let m, _): m
        }
    }

    public var symbol: String {
        switch self {
        case .noKey, .badKey: "key.slash"
        case .offline: "icloud.slash"
        case .rateLimited, .serverTrouble: "hourglass"
        case .quota: "creditcard.trianglebadge.exclamationmark"
        case .other(_, let s): s
        }
    }

    /// The face shows her "cloud off" look (eyes, touch and camera stay alive).
    public var cloudOff: Bool {
        if case .other = self { return false }
        return true
    }

    /// Will not fix itself.
    public var needsUser: Bool {
        switch self {
        case .noKey, .badKey, .quota: true
        default: false
        }
    }
}

/// OpenAI's usage policy: people must be told the voice is AI-generated. Dee says
/// it herself the first time she speaks through the cloud (once per install).
public enum AIVoiceDisclosure {
    /// The line (spoken verbatim through `RealtimeBrain.say`: an out-of-band canned
    /// line, §4.2). The app keeps offering it until it has actually been played.
    public static let line = "Just so you know, my voice is made by an AI."
    /// The on-screen version (shown with the line).
    public static let caption = "Dee's voice is AI-generated (OpenAI)."
}
