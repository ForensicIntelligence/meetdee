import DeeCore
import DeeRealtime
import DeeSelf
import Foundation

/// The cloud-voice settings (Dee's in-app settings; v0.6 keeps the old UserDefaults keys
/// for the voice and model) and the session config built from them.
public struct CloudSettings: Sendable, Equatable {
    /// UserDefaults keys (Settings.bundle).
    public enum Key {
        /// The old Settings.bundle key field (v0.5). Read only by `KeyIntake.migrateLegacyKey`.
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
    /// Who the session speaks as: its instructions come from `DNAPrompt.sessionInstructions`
    /// (Classic Dee: v11, byte-for-byte; a persona preset: v12 in its name and voice).
    public var persona = Persona()

    public init(voice: String = "marin", model: String = "gpt-realtime-2.1-mini", shareMemories: Bool = true,
                persona: Persona = Persona()) {
        self.persona = persona
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
    ///
    /// Live from tune 3: `sessionConfig` sends it as the session's `turn_detection`
    /// (`RealtimeSessionConfig.turnDetection`); `turnEagerness` is then unused.
    public static let turnDetection = turnDetection(silenceMs: defaultSilenceMs)

    /// Tune 9 (latency): the server VAD's `silence_duration_ms` is a setting. The default
    /// stays 300 (the tune-2 A/B winner); the tune-8 floor analysis projects 250 ms at
    /// about −0.05 s p50 (floor 1.12 → ~1.07 s) with no new splits on barge-in or
    /// backchannel lines, so 250 is the next live A/B. 200 splits the joke set-up and a
    /// continuation: not offered below `silenceRange`.
    public static let defaultSilenceMs = 300
    public static let silenceRange = 200...800
    /// The live operator's A/B knob (the voice harness builds its session with
    /// `CloudSettings(voice:model:)`): `DEE_VAD_SILENCE_MS=250 voice-harness run …`. Never
    /// set in the app; out of `silenceRange` or not a number: ignored.
    public static let silenceEnvironmentKey = "DEE_VAD_SILENCE_MS"

    /// server_vad with `silenceMs` of silence (clamped to `silenceRange`); everything else
    /// as `turnDetection`.
    public static func turnDetection(silenceMs: Int) -> TurnDetection {
        TurnDetection.serverVAD(threshold: 0.5, prefixPaddingMs: 300,
                                silenceDurationMs: min(max(silenceMs, silenceRange.lowerBound), silenceRange.upperBound),
                                createResponse: false, interruptResponse: false)
    }

    /// The silence from the environment (`silenceEnvironmentKey`), if valid.
    public static func silenceOverride(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Int? {
        guard let raw = env[silenceEnvironmentKey]?.trimmingCharacters(in: .whitespaces), let ms = Int(raw),
              silenceRange.contains(ms) else { return nil }
        return ms
    }

    /// `silence_duration_ms` of this session (default 300; the harness knob may set it).
    public var vadSilenceMs = CloudSettings.silenceOverride() ?? CloudSettings.defaultSilenceMs

    /// docs/DNA.md §3/D5: stable instructions (no names, memories or state), the
    /// tools, the voice; turn detection `turnDetection` (server_vad 300 ms) with
    /// `create_response: false` and `interrupt_response: false` (Dee keeps the floor).
    /// Reasoning effort: `ordinaryEffort` (each response sets its own as well).
    public func sessionConfig(tools: [RealtimeTool] = []) -> RealtimeSessionConfig {
        var c = RealtimeSessionConfig()
        c.model = model
        c.eagerness = Self.turnEagerness
        c.turnDetection = Self.turnDetection(silenceMs: vadSilenceMs)
        c.voice = .named(voice)
        c.instructions = DNAPrompt.sessionInstructions(persona: persona)
        c.tools = tools
        c.reasoningEffort = RealtimeBrain.ordinaryEffort.rawValue
        return c
    }
}

/// The OpenAI key entered in Dee's own settings (v0.6: onboarding or the in-app
/// settings — never Settings.bundle, whose fields are plaintext UserDefaults).
///
/// - `absorb(_:)` — the user tapped "Check key": one cheap authenticated GET
///   /v1/models through the recorded `Transport` (X1), then the Keychain. A refused key
///   (401/403) is not stored; offline, the key is stored unvalidated.
/// - `migrateLegacyKey(from:)` — once, before onboarding shows: a key left in the old
///   Settings.bundle field moves to the Keychain with **no network call**, and the
///   plaintext copy is always removed (on a Keychain failure the user re-enters it).
public struct KeyIntake: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// Nothing pasted.
        case nothing
        /// Stored in the Keychain (validated, or unvalidated because offline).
        case stored(validated: Bool)
        /// The key was refused (401/403) or not an OpenAI key: not stored.
        case rejected(String)
    }

    public enum Migration: Sendable, Equatable {
        /// No old field (or an empty one).
        case nothing
        /// Moved to the Keychain (unchecked; the first window will tell).
        case moved
        /// The field held something that is not an OpenAI key: removed, not stored.
        case discarded
        /// The Keychain refused it: removed anyway (K1); the user must enter it again.
        case keychainFailed
    }

    public typealias Fetch = HTTPFetch
    public let keyStore: KeyStore
    public let fetch: Fetch
    public var endpoint = URL(string: "https://api.openai.com/v1/models")!

    /// - Parameter fetch: the recorded transport's fetch (OpenAI: same-host redirects).
    public init(keyStore: KeyStore = KeyStore(), fetch: @escaping Fetch = Transport.openAIDefault.fetch) {
        self.keyStore = keyStore
        self.fetch = fetch
    }

    /// The Keychain refused the key (the outcome text `absorb` returns).
    public static let keychainFailure = "Couldn't save the key in the Keychain."
    /// The old Settings.bundle field (plaintext UserDefaults), read once for migration.
    public static let legacyDefaultsKey = CloudSettings.Key.apiKey

    /// Once, before onboarding: no network, the plaintext copy always removed.
    public func migrateLegacyKey(from defaults: UserDefaults) -> Migration {
        guard let raw = defaults.string(forKey: Self.legacyDefaultsKey) else {
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
            return .nothing
        }
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothing }
        guard let key = KeyStore.normalize(raw) else { return .discarded }
        do { _ = try keyStore.save(key) } catch { return .keychainFailed }
        return .moved
    }

    /// "Check key": validate with one GET, then store.
    public func absorb(_ raw: String) async -> Outcome {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothing }
        guard let key = KeyStore.normalize(raw) else { return .rejected("That doesn't look like an OpenAI key.") }
        var validated = false
        switch await Self.check(key, endpoint: endpoint, fetch: fetch) {
        case .refused: return .rejected("OpenAI refused that key.")
        case .valid: validated = true
        case .unknown: break   // offline: keep it; the session will say so if it is refused later
        }
        do { _ = try keyStore.save(key) } catch { return .rejected(Self.keychainFailure) }
        return .stored(validated: validated)
    }

    public enum Check: Sendable, Equatable { case valid, refused, unknown }

    /// One authenticated GET /v1/models (purpose "models"). Never logs the key.
    public static func check(_ key: String, endpoint: URL = URL(string: "https://api.openai.com/v1/models")!,
                             fetch: Fetch) async -> Check {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("models", forHTTPHeaderField: Transport.purposeHeader)
        do {
            let (_, response) = try await fetch(request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { return .refused }
            return (200..<300).contains(status) ? .valid : .unknown
        } catch {
            return .unknown
        }
    }
}

/// The small status chip in the Release build: what is wrong with Dee's cloud voice,
/// in words for the person in front of Dee (`DeeModel.voiceProblem`).
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
        case .noKey: "I need an OpenAI key — open my settings"
        case .badKey: "That OpenAI key didn't work — open my settings"
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

    /// The face shows Dee's "cloud off" look (eyes, touch and camera stay alive).
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
/// so the first time Dee speaks through the cloud (once per install).
public enum AIVoiceDisclosure {
    /// The line (spoken verbatim through `RealtimeBrain.say`: an out-of-band canned
    /// line, §4.2). The app keeps offering it until it has actually been played.
    public static let line = "Just so you know, my voice is made by an AI."
    /// The on-screen version (shown with the line).
    public static let caption = "Dee's voice is AI-generated (OpenAI)."
}
