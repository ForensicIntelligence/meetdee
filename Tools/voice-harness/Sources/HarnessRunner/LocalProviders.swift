import DeeLocal
import DeeRealtime
import DeeWake
import Foundation
import HarnessCore

/// `--provider openai|lan-brain|lan` → a `DeeLocal.ProviderFactory` runtime on the
/// runner's taped transport (contract §2/§6). Mode 1 (`openai`) keeps the runner's own
/// `.openAI` connection (today's path); modes 2/3 go through the factory exactly as the
/// app's `VoiceStack` does, with the brain's session config as the base.
///
///     --provider lan-brain --lan 127.0.0.1:11434 --model qwen3.8:27b-mlx-bf16        (mode 2: OpenAI STT/TTS)
///     --provider lan --lan 127.0.0.1:11434 --model qwen3.8:27b-mlx-bf16 \
///         [--stt URL|on-device] [--stt-model M] [--tts URL|on-device] [--tts-model M] [--voice V]   (mode 3)
public enum LocalProviders {
    public static func mode(_ cli: String) -> ProviderMode? {
        switch cli {
        case "openai": .openAI
        case "lan-brain": .lanBrainOpenAIVoice
        case "lan": .lanEverything
        default: nil
        }
    }

    public static func modeName(_ cli: String) -> String { mode(cli)?.rawValue ?? cli }

    /// The provider config the flags describe (no network).
    public static func config(_ cli: String, flags: [String: String]) throws -> ProviderConfig {
        guard let mode = mode(cli) else { throw HarnessError("--provider must be openai, lan-brain or lan") }
        if mode == .openAI { return .openAI(model: flags["model"] ?? "gpt-realtime-2.1-mini", voice: flags["voice"] ?? "marin") }
        guard let lan = flags["lan"] else { throw HarnessError("--provider \(cli) needs --lan HOST[:PORT] (e.g. 127.0.0.1:11434)") }
        guard let model = flags["model"] else { throw HarnessError("--provider \(cli) needs --model ID (e.g. qwen3.8:27b-mlx-bf16)") }
        let base: URL
        do { base = try AddressParser.parse(lan) } catch { throw HarnessError("--lan \(lan): \(error)") }
        let brain = EndpointConfig(baseURL: base, model: model)
        if mode == .lanBrainOpenAIVoice { return .lanBrainOpenAIVoice(brain: brain, voice: flags["voice"] ?? "marin") }
        func part(_ flag: String, model: String?) throws -> SpeechPart {
            guard let v = flags[flag], v != "on-device" else { return .onDevice }
            do { return .lan(EndpointConfig(baseURL: try AddressParser.parse(v), model: model ?? "")) }
            catch { throw HarnessError("--\(flag) \(v): \(error)") }
        }
        return .lanEverything(brain: brain, stt: try part("stt", model: flags["stt-model"]),
                              tts: try part("tts", model: flags["tts-model"]), voice: flags["voice"] ?? "")
    }

    /// Hosts a mode may contact (W3): mode 1 only OpenAI; mode 2 the LAN brain + OpenAI
    /// (hearing and voice only); mode 3 only its LAN endpoints, never `*.openai.com`.
    public static func allowedHosts(_ cli: String, flags: [String: String]) -> (String) -> Bool {
        let lanHosts = Set(["lan", "stt", "tts"].compactMap { flags[$0] }.compactMap { try? AddressParser.parse($0).host })
        let openAI: (String) -> Bool = { $0 == "openai.com" || $0.hasSuffix(".openai.com") }
        switch mode(cli) {
        case .openAI?, nil: return openAI
        case .lanBrainOpenAIVoice?: return { openAI($0) || lanHosts.contains($0) }
        case .lanEverything?: return { lanHosts.contains($0) }
        }
    }

    /// Probes the LAN parts once before the run (models, vendor, tools, audio routes),
    /// then returns the builder the runner calls per scenario. The OpenAI key (mode 2) is
    /// read from the key file at run time and never printed.
    public static func prepare(_ cli: String, flags: [String: String], log: (String) -> Void) async throws -> HarnessProviderBuilder {
        let config = try config(cli, flags: flags)
        var secrets: [String: String] = [:]
        if config.mode == .lanBrainOpenAIVoice { secrets[SecretAccount.openAI] = try KeyFile.load() }
        let issues = config.validate(secrets: StaticSecrets(secrets))
        if let first = issues.first { throw HarnessError("provider config: \(first.message)") }
        var caps: ServerCapabilities?
        if let brain = config.brain {
            let probe = ServerProbe(transport: Transport.live(redirects: .refuse))
            switch await probe.probe(brain.baseURL, key: nil, model: brain.model, checkRealtime: config.mode == .lanEverything,
                                     transcriptionModel: config.stt.endpoint?.model, speechModel: config.tts.endpoint?.model) {
            case .success(let c):
                caps = c
                log("probe \(brain.hostLabel): vendor \(c.vendor.rawValue), chat \(c.chat), tools \(c.tools), realtime \(c.realtime), "
                    + "transcriptions \(c.transcriptions), speech \(c.speech), context \(c.contextLength.map(String.init) ?? "–"), loaded \(c.loaded.map { "\($0)" } ?? "–")")
            case .failure(let issue):
                throw HarnessError("probe \(brain.hostLabel): \(issue.message)")
            }
        }
        let captured = caps
        let staticSecrets = StaticSecrets(secrets)
        return HarnessProviderBuilder(mode: config.mode.rawValue) { tape, base, phraseText in
            let transport = tape.wrap(ProviderFactory.transport(for: config.mode))
            let uplink = UplinkActivity()
            let phrase = (try? WakePhrase(validating: phraseText)) ?? .default
            let runtime: ProviderRuntime
            do {
                runtime = try ProviderFactory.make(config, secrets: staticSecrets, transport: transport, base: base,
                                                   capabilities: captured, phrase: phrase, uplink: uplink)
            } catch let issue as ProviderIssue {
                throw HarnessError("provider: \(issue.message)")
            }
            let stats = runtime.stats
            let problems = AsyncStream<String> { c in
                Task {
                    for await p in runtime.problems { c.yield(p.message) }
                    c.finish()
                }
            }
            return HarnessProvider(sessionConfig: runtime.sessionConfig, credentials: runtime.credentials,
                                   socketFactory: runtime.socketFactory, uplink: uplink,
                                   stats: stats.map { s -> @Sendable () async -> [String: Double] in { @Sendable in Self.dictionary(s.snapshot) } },
                                   problems: problems, timing: runtime.timing)
        }
    }

    /// CascadeStats as the run record's `providerStats` (lists as count / p50 / p90).
    static func dictionary(_ s: CascadeStats.Snapshot) -> [String: Double] {
        var d: [String: Double] = [
            "chatRequests": Double(s.chatRequests), "warmUps": Double(s.warmUps), "committedTurns": Double(s.committedTurns),
            "responses": Double(s.responses), "cancelled": Double(s.cancelled), "toolCalls": Double(s.toolCalls),
            "reasoningCharsDropped": Double(s.reasoningCharsDropped), "thinkEnds": Double(s.thinkEnds),
            "spokenSentences": Double(s.spokenSentences), "promptTokens": Double(s.promptTokens), "cachedTokens": Double(s.cachedTokens),
        ]
        func add(_ name: String, _ x: [Double]) {
            d["\(name).n"] = Double(x.count)
            if let p = Stats.percentile(x, 0.5) { d["\(name).p50"] = p }
            if let p = Stats.percentile(x, 0.9) { d["\(name).p90"] = p }
            if !x.isEmpty { d["\(name).sum"] = x.reduce(0, +) }
        }
        add("firstTokenSeconds", s.firstTokenSeconds)
        add("firstAudioSeconds", s.firstAudioSeconds)
        add("sentenceGaps", s.sentenceGaps)
        return d
    }
}
