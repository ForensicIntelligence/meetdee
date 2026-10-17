import DeeBrain
import DeeCore
import DeeFace
import DeeLocal
import DeeRealtime
import DeeVoice
import Foundation
import os

/// Dee's ears and voice for one provider configuration (providers-wake-onboarding §1):
/// the session, the CloudVoice on it, the clips, the timing profile. Built without any
/// request; `CloudVoice` starts DORMANT (no socket, no uplink, no key mint, no clip
/// rendering) and connects only when a conversation window opens.
@MainActor
struct VoiceStack {
    let config: ProviderConfig?
    let voice: CloudVoice
    let clips: ClipCache?
    let timing: TimingProfile
    /// Why this configuration can't work (no key, no server, a bad address…). The voice
    /// then exists only for Dee's local sounds and never connects.
    let issue: ProviderIssue?
    /// Every request this stack makes goes through it (X1): usage + W2/W3 checks.
    let recorder: TransportRecorder
    /// Problems from inside a cascaded socket (hearing, chat, voice) — shown, never a fallback.
    var problems: AsyncStream<ProviderIssue>? = nil

    /// The OpenAI voice disclosure applies (modes 1 and 2).
    var speaksWithOpenAI: Bool { config?.mode == .openAI || config?.mode == .lanBrainOpenAIVoice }

    var statusLine: String {
        guard let c = config else { return "No provider" }
        switch c.mode {
        case .openAI: return "OpenAI: \(c.openAIModel), \(c.voice)"
        case .lanBrainOpenAIVoice: return "LAN brain \(c.brain?.hostLabel ?? "?") \(c.brain?.model ?? ""), OpenAI voice \(c.voice)"
        case .lanEverything: return "LAN \(c.brain?.hostLabel ?? "?") \(c.brain?.model ?? "")"
        }
    }

    /// `persona`: who speaks — the session's instructions and the clips' voice style
    /// (Classic Dee: today's, byte for byte).
    static func make(_ config: ProviderConfig?, secrets: KeychainSecrets,
                     persona: PersonaPreset = PersonaCatalog.classic) -> VoiceStack {
        var vc = CloudVoice.Configuration()
        vc.startsDormant = true
        vc.prepareClipsOnWake = true
        guard let config else {
            return offline(config: nil, issue: .noOpenAIKey, configuration: vc)
        }
        let issues = config.validate(secrets: secrets)
        if let first = issues.first { return offline(config: config, issue: first, configuration: vc) }

        switch config.mode {
        case .openAI:
            // Mode 1: today's gpt-realtime path, byte-for-byte (CloudSettings.sessionConfig,
            // an ephemeral key minted per socket at api.openai.com).
            let recorder = TransportRecorder()
            let transport = Transport.live(redirects: .sameHost, recorder: recorder)
            let keys = secrets.store(account: SecretAccount.openAI)
            let settings = CloudSettings(voice: config.voice, model: config.openAIModel, persona: Persona(preset: persona))
            var clipConfig = ClipCache.Configuration(voice: .named(settings.voice))
            if !persona.isClassic { clipConfig.style = persona.ttsStyle }
            let clips = ClipCache(configuration: clipConfig, key: { try? keys.load() }, fetch: transport.fetch)
            let session = RealtimeSession(config: settings.sessionConfig(),
                                          auth: OpenAIAuth(keyStore: keys, transport: transport.fetch),
                                          socketFactory: transport.socketFactory)
            vc.provider = .openAI
            return VoiceStack(config: config, voice: CloudVoice(session: session, clips: clips, configuration: vc),
                              clips: clips, timing: .realtime, issue: nil, recorder: recorder)
        case .lanBrainOpenAIVoice, .lanEverything:
            return cascaded(config, secrets: secrets, configuration: vc, persona: persona)
        }
    }

    /// Modes 2 / 3 through `ProviderFactory` (DeeLocal): the cascaded socket or a LAN
    /// realtime server, each part on its own transport. Never falls back to another
    /// provider: a failure is an `issue`.
    private static func cascaded(_ config: ProviderConfig, secrets: KeychainSecrets,
                                 configuration: CloudVoice.Configuration, persona: PersonaPreset) -> VoiceStack {
        var vc = configuration
        let prefs = DeePrefs()
        let base = CloudSettings(voice: CloudSettings.voices.contains(config.voice) ? config.voice : "marin",
                                 persona: Persona(preset: persona)).sessionConfig()
        let recorder = TransportRecorder()
        let uplink = UplinkActivity()
        do {
            let runtime = try ProviderFactory.make(config, secrets: secrets,
                                                   transport: ProviderFactory.transport(for: config.mode, recorder: recorder),
                                                   base: base, capabilities: prefs.brainCapabilities,
                                                   phrase: prefs.wakePhrase, uplink: uplink,
                                                   voiceStyle: persona.isClassic ? nil : persona.ttsStyle,
                                                   appleVoice: persona.appleVoice)
            var clipConfig = ClipCache.Configuration()
            if !persona.isClassic { clipConfig.style = persona.ttsStyle }
            let clips = ClipCache(configuration: clipConfig, renderer: runtime.clipRenderer)
            let session = RealtimeSession(config: runtime.sessionConfig, credentials: runtime.credentials,
                                          socketFactory: runtime.socketFactory)
            vc.provider = runtime.label
            vc.uplinkActivity = uplink
            vc.speculativeMax = runtime.timing.speculativeMax
            return VoiceStack(config: config, voice: CloudVoice(session: session, clips: clips, configuration: vc),
                              clips: clips, timing: runtime.timing, issue: nil, recorder: runtime.transport.recorder,
                              problems: runtime.problems)
        } catch {
            return offline(config: config, issue: error, configuration: vc)
        }
    }

    /// A voice that never connects (no provider yet, or one that can't work): Dee's
    /// local sounds only. Its socket factory and credentials fail without a request.
    private static func offline(config: ProviderConfig?, issue: ProviderIssue,
                                configuration: CloudVoice.Configuration) -> VoiceStack {
        let recorder = TransportRecorder()
        let transport = Transport.failing(recorder: recorder)
        let session = RealtimeSession(config: CloudSettings().sessionConfig(),
                                      credentials: { _ in throw RealtimeAuthError.noKey },
                                      socketFactory: transport.socketFactory)
        return VoiceStack(config: config, voice: CloudVoice(session: session, clips: nil, configuration: configuration),
                          clips: nil, timing: .realtime, issue: issue, recorder: recorder)
    }
}

extension DeeModel {
    nonisolated static let log = Logger(subsystem: "ca.forensicintelligence.dee", category: "wake")
}

extension FaceColor {
    func scaled(_ k: Double) -> FaceColor { FaceColor(r * k, g * k, b * k) }
}
