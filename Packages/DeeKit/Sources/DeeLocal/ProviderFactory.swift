import Foundation
import Synchronization
import DeeCore
import DeeRealtime
import DeeVoice
import DeeWake

/// Everything a `VoiceStack` needs for one provider configuration (contract §1): the session config
/// (with its timing profile), credentials, the socket factory (OpenAI, a LAN realtime server, or the
/// in-process `CascadeSocket`), the recorded transport, the clip renderer and who to name in problems.
public struct ProviderRuntime: Sendable {
    public var mode: ProviderMode
    public var sessionConfig: RealtimeSessionConfig
    public var credentials: RealtimeCredentialProvider
    public var socketFactory: RealtimeSocketFactory
    public var transport: Transport
    public var clipRenderer: any ClipRenderer
    public var timing: TimingProfile
    /// Who thinks (problem texts, usage lines).
    public var label: ProviderLabel
    /// Provider problems from inside cascaded sockets (hearing, chat, voice). Single consumer.
    public var problems: AsyncStream<ProviderIssue>
    /// Counters of the cascaded sockets (nil in mode 1 / LAN realtime).
    public var stats: CascadeStats?
    /// Speech-to-text the TurnPolicy word waits should assume.
    public var stt: TimingProfile.CascadeSTT?
    /// The base speech style the cascaded voice is given (nil in mode 1 / LAN realtime).
    public var voiceStyle: String? = nil
}

/// Builds runtimes. Never contacts the network itself (W2: building one while DORMANT is free);
/// never mixes providers (W3): mode 1 only OpenAI, mode 3 never OpenAI, mode 2 OpenAI only for hearing
/// and voice.
public enum ProviderFactory {
    /// The transport a mode should use: OpenAI only → same-host redirects; anything with a LAN part →
    /// no redirects at all (a 30x from the LAN must not carry audio or a key elsewhere; OpenAI's API
    /// doesn't redirect, so mode 2's OpenAI parts lose nothing).
    public static func transport(for mode: ProviderMode, recorder: TransportRecorder = TransportRecorder()) -> Transport {
        Transport.live(redirects: mode == .openAI ? .sameHost : .refuse, recorder: recorder)
    }

    /// - Parameters:
    ///   - base: the app's session config (`CloudSettings.sessionConfig()`); mode 1 changes nothing in it
    ///     but model and voice (byte-for-byte today's session.update).
    ///   - capabilities: the last probe of the brain server (tools / vendor / realtime); nil = assume tools, other vendor.
    ///   - phrase: the wake phrase (a keyword for hearing; name rewriting).
    ///   - uplink: EarCore's per-frame voice evidence (mode 3 turn detection; mode 2 rest-of-burst starts), shared with CloudVoice.
    ///   - speechEngine: on-device recogniser for mode 3 (tests inject a fake).
    ///   - voiceStyle: the persona's base speech style for the cascaded voice (`PersonaPreset.ttsStyle`);
    ///     nil keeps Classic Dee's (`CascadeOptions.voiceStyle`).
    ///   - appleVoice: the persona's on-device voice rule (mode 3 on this iPhone: base pitch and rate of
    ///     the live voice and the clips); nil uses `OnDeviceVoice.personaRule` (nil there = Classic Dee).
    public static func make(_ c: ProviderConfig, secrets: any SecretReader, transport: Transport,
                            base: RealtimeSessionConfig = RealtimeSessionConfig(),
                            capabilities: ServerCapabilities? = nil, phrase: WakePhrase = .default,
                            uplink: UplinkActivity? = nil, voiceStyle: String? = nil, appleVoice: AppleVoiceRule? = nil,
                            speechEngine: (@Sendable () -> any SpeechEngine)? = nil,
                            resolver: any HostResolver = SystemResolver()) throws(ProviderIssue) -> ProviderRuntime {
        if let first = c.validate(secrets: secrets).first { throw first }
        let openAIKey: @Sendable () -> String? = { secrets.secret(account: SecretAccount.openAI) }
        let keyStore = KeyStore(account: SecretAccount.openAI, storage: ReaderStorage(secrets))
        let keywords = Array(Set(["Dee"] + phrase.contextualStrings.prefix(3))).sorted()

        switch c.mode {
        case .openAI:
            var config = base
            config.model = c.openAIModel
            config.voice = .named(c.voice)
            TimingProfile.realtime.apply(to: &config)
            let auth = OpenAIAuth(keyStore: keyStore, transport: transport.fetch)
            let renderer = SpeechEndpointRenderer(configuration: .openAI(voice: .named(c.voice)), key: openAIKey,
                                                  fetch: transport.fetch)
            return ProviderRuntime(mode: .openAI, sessionConfig: config,
                                   credentials: { try await auth.credential(model: $0) },
                                   socketFactory: transport.socketFactory, transport: transport, clipRenderer: renderer,
                                   timing: .realtime, label: .openAI, problems: AsyncStream { $0.finish() }, stats: nil, stt: nil)

        case .lanBrainOpenAIVoice, .lanEverything:
            guard let brain = c.brain else { throw .noLANServer }
            let brainKey = brain.keyAccount.flatMap { secrets.secret(account: $0) }
            let brainClient = CompatClient(base: brain.baseURL, key: brainKey, transport: transport, resolver: resolver)
            let vendor = capabilities?.vendor ?? .other

            // Mode 3 + a LAN server that really speaks realtime (probed): the realtime path, no mint.
            if c.mode == .lanEverything, c.lanRealtime {
                guard capabilities?.realtime == true else { throw .partMissing(.brain, host: brain.hostLabel) }
                var config = base
                var comps = URLComponents(url: brain.baseURL, resolvingAgainstBaseURL: false)!
                comps.scheme = AddressParser.isTLS(brain.baseURL) ? "wss" : "ws"
                comps.path += "/v1/realtime"
                config.endpoint = comps.url!
                config.model = brain.model
                config.voice = .named(c.voice.isEmpty ? "marin" : c.voice)
                TimingProfile.lanRealtime.apply(to: &config)
                let key = brainKey ?? ""
                return ProviderRuntime(mode: c.mode, sessionConfig: config, credentials: { _ in .direct(key) },
                                       socketFactory: transport.socketFactory, transport: transport,
                                       clipRenderer: try lanRenderer(c, secrets: secrets, transport: transport, appleVoice: appleVoice),
                                       timing: .lanRealtime, label: .lan(host: brain.hostLabel),
                                       problems: AsyncStream { $0.finish() }, stats: nil, stt: nil)
            }

            var options = CascadeOptions(model: brain.model)
            options.toolsSupported = capabilities?.tools ?? true
            options.keepAlive = vendor == .ollama ? c.keepAlive : nil
            if let voiceStyle, !voiceStyle.isEmpty { options.voiceStyle = voiceStyle }

            // Hearing.
            let makeHearing: @Sendable () -> any CascadeHearing
            let stt: TimingProfile.CascadeSTT
            switch (c.mode, c.stt) {
            case (.lanBrainOpenAIVoice, _):
                var session = OpenAITranscription.Session()
                session.keywords = keywords
                let auth = OpenAIAuth(keyStore: keyStore, sessionType: .transcription, transcription: session,
                                      transport: transport.fetch)
                makeHearing = { OpenAITranscriptionHearing(transport: transport, credential: { try await auth.credential(model: OpenAITranscription.model) },
                                                             uplink: uplink) }
                stt = .openAIRealtime
            case (.lanEverything, .lan(let e)):
                let key = e.keyAccount.flatMap { secrets.secret(account: $0) }
                let client = CompatClient(base: e.baseURL, key: key, transport: transport, resolver: resolver)
                let engine = speechEngine ?? { OnDeviceSpeechEngine() }
                let model = (e.baseURL == brain.baseURL ? capabilities?.transcriptionModel : nil) ?? e.model   // probe is of the brain server
                makeHearing = { LocalHearing(stt: .lan(client, model: model), engine: engine(), uplink: uplink) }
                stt = .lanREST
            case (.lanEverything, .onDevice):
                let engine = speechEngine ?? { OnDeviceSpeechEngine() }
                makeHearing = { LocalHearing(stt: .onDevice, engine: engine(), uplink: uplink) }
                stt = .onDevice
            default:
                throw .partNotAllowed(.hearing, c.mode)
            }

            // Voice.
            let voice: any CascadeVoice
            switch (c.mode, c.tts) {
            case (.lanBrainOpenAIVoice, .openAIREST):
                let client = CompatClient(base: CompatClient.openAIBase, keyProvider: openAIKey, transport: transport,
                                          resolver: resolver, label: .openAI)
                voice = StreamingSpeechVoice(client: client, voice: c.voice)
            case (.lanEverything, .lan(let e)):
                let key = e.keyAccount.flatMap { secrets.secret(account: $0) }
                let client = CompatClient(base: e.baseURL, key: key, transport: transport, resolver: resolver)
                voice = LANSpeechVoice(client: client, model: (e.baseURL == brain.baseURL ? capabilities?.speechModel : nil) ?? e.model, voice: c.voice.isEmpty ? "af_heart" : c.voice)
            case (.lanEverything, .onDevice):
                voice = OnDeviceVoice(voiceIdentifier: c.voice, persona: appleVoice)
            default:
                throw .partNotAllowed(.voice, c.mode)
            }

            let timing = TimingProfile.cascaded(stt: stt)
            var config = base
            config.model = brain.model
            config.endpoint = URL(string: "wss://cascade.invalid/v1/realtime")!   // never dialled: the factory ignores the request
            TimingProfile.cascaded(stt: stt).apply(to: &config)
            config.voice = .named(c.voice.isEmpty ? "marin" : c.voice)
            let chat = VendorChat(client: brainClient, vendor: vendor)
            let hub = ProblemHub()
            let stats = CascadeStats()
            let cascadeOptions = options
            let factory: RealtimeSocketFactory = { _ in
                let socket = CascadeSocket(options: cascadeOptions, hearing: makeHearing(), chat: chat, voice: voice, stats: stats)
                hub.forward(socket.problems)
                return socket
            }
            let renderer: any ClipRenderer = c.mode == .lanBrainOpenAIVoice
                ? SpeechEndpointRenderer(configuration: .openAI(voice: .named(c.voice)), key: openAIKey, fetch: transport.fetch)
                : try lanRenderer(c, secrets: secrets, transport: transport, appleVoice: appleVoice,
                                  capabilities: { if case .lan(let e) = c.tts, e.baseURL == brain.baseURL { return capabilities }; return nil }())
            return ProviderRuntime(mode: c.mode, sessionConfig: config, credentials: { _ in .direct("") },
                                   socketFactory: factory, transport: transport, clipRenderer: renderer, timing: timing,
                                   label: .lan(host: brain.hostLabel), problems: hub.stream, stats: stats, stt: stt,
                                   voiceStyle: options.voiceStyle)
        }
    }

    /// Mode 3's clip renderer: the LAN speech server, or this iPhone. Never OpenAI.
    static func lanRenderer(_ c: ProviderConfig, secrets: any SecretReader, transport: Transport,
                            appleVoice: AppleVoiceRule? = nil, capabilities: ServerCapabilities? = nil) throws(ProviderIssue) -> any ClipRenderer {
        switch c.tts {
        case .lan(let e):
            let key = e.keyAccount.flatMap { secrets.secret(account: $0) }
            return SpeechEndpointRenderer(configuration: .lan(baseURL: e.baseURL, model: capabilities?.speechModel ?? e.model,
                                                              voice: c.voice.isEmpty ? "af_heart" : c.voice),
                                          key: { key }, keyRequired: false, fetch: transport.fetch)
        case .onDevice:
            // The persona's base pitch and rate, like the live voice.
            let shape = OnDeviceVoice(voiceIdentifier: c.voice.isEmpty ? nil : c.voice, persona: appleVoice)
            return OnDeviceClipRenderer(voiceIdentifier: c.voice.isEmpty ? nil : c.voice,
                                        rate: shape.baseRate, pitch: shape.basePitch)
        default:
            throw .partNotAllowed(.voice, c.mode)
        }
    }
}

/// Fans the problems of every cascaded socket a runtime makes into one stream.
final class ProblemHub: Sendable {
    let stream: AsyncStream<ProviderIssue>
    private let continuation: AsyncStream<ProviderIssue>.Continuation
    init() { (stream, continuation) = AsyncStream<ProviderIssue>.makeStream(bufferingPolicy: .bufferingNewest(16)) }
    func forward(_ s: AsyncStream<ProviderIssue>) {
        let c = continuation
        Task { for await p in s { c.yield(p) } }
    }
}

/// A `SecretReader` as KeyStore storage (read-only).
struct ReaderStorage: SecretStorage {
    let reader: any SecretReader
    init(_ reader: any SecretReader) { self.reader = reader }
    func read(account: String) throws -> String? { reader.secret(account: account) }
    func write(_ value: String, account: String) throws { throw KeyStoreError.invalidKey }
    func remove(account: String) throws {}
}

extension KeychainStorage: SecretReader {
    public func secret(account: String) -> String? { (try? read(account: account)).flatMap { $0?.isEmpty == false ? $0 : nil } }
}

extension MemorySecretStorage: SecretReader {
    public func secret(account: String) -> String? { (try? read(account: account)).flatMap { $0?.isEmpty == false ? $0 : nil } }
}
