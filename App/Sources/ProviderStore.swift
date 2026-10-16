import DeeBrain
import DeeCore
import DeeLocal
import DeeRealtime
import DeeWake
import Foundation
import Network
import Observation

/// What onboarding and the in-app settings edit: the provider (mode, endpoints,
/// models, voice), the keys (Keychain only), the wake phrase and speak-first.
///
/// Nothing here connects on its own (W2): only the user's "Check key" and "Test
/// connection" taps make a request, through a recorded `Transport`. Saving a key or an
/// endpoint never reconnects her or renders clips — the next conversation window
/// picks the change up (`DeeModel.applyProvider` rebuilds only while dormant).
@Observable @MainActor
final class ProviderStore {
    let prefs: DeePrefs
    let secrets: KeychainSecrets
    /// Every user-tapped check goes through this one recorder (X1).
    let recorder = TransportRecorder()

    /// The configuration being edited (saved with `save()`).
    var draft: ProviderConfig
    var wakePhraseText: String
    var speakFirst: Bool
    /// Per-part status after "Test connection" / "Check key".
    private(set) var statuses: [Part: PartStatus] = [:]
    /// Models the brain server listed (chat models only).
    private(set) var brainModels: [String] = []
    private(set) var brainCapabilities: ServerCapabilities?
    private(set) var busy: Part?

    enum Part: String, Hashable, CaseIterable { case openAI, brain, stt, tts }

    enum PartStatus: Equatable {
        case ok(String)
        case warning(String)
        case failed(String)
        var isOK: Bool { if case .ok = self { true } else if case .warning = self { true } else { false } }
        var text: String {
            switch self {
            case .ok(let s), .warning(let s), .failed(let s): s
            }
        }
    }

    init(prefs: DeePrefs = DeePrefs(), secrets: KeychainSecrets = KeychainSecrets()) {
        self.prefs = prefs
        self.secrets = secrets
        draft = prefs.providerConfig ?? .openAI()
        wakePhraseText = prefs.wakePhrase.text
        speakFirst = prefs.speakFirst
    }

    // MARK: - Keys (Keychain only; shown as the last 4 characters)

    var openAIKeyRedacted: String? {
        secrets.secret(account: SecretAccount.openAI).map(KeyStore.redacted)
    }

    func lanKeyRedacted(_ part: LANPart) -> String? {
        secrets.secret(account: SecretAccount.lan(part)).map { "…" + String($0.suffix(4)) }
    }

    /// "Check key": one GET /v1/models, then the Keychain. Never logged.
    func saveOpenAIKey(_ raw: String) async {
        busy = .openAI
        defer { busy = nil }
        let intake = KeyIntake(keyStore: secrets.store(account: SecretAccount.openAI),
                               fetch: Transport.live(redirects: .sameHost, recorder: recorder).fetch)
        switch await intake.absorb(raw) {
        case .nothing:
            statuses[.openAI] = .failed("Paste your OpenAI key first.")
        case .stored(let validated):
            statuses[.openAI] = validated ? .ok("Key works — saved as \(openAIKeyRedacted ?? "sk-…")")
                : .warning("Saved, but I couldn't check it (offline?)")
        case .rejected(let why):
            statuses[.openAI] = .failed(why == "OpenAI refused that key." ? "That OpenAI key didn't work" : why)
        }
    }

    func removeOpenAIKey() {
        try? secrets.store(account: SecretAccount.openAI).delete()
        statuses[.openAI] = nil
    }

    /// An optional LAN bearer key. Refused when it looks like an OpenAI key and the
    /// endpoint is plain http ("it would cross your Wi-Fi unencrypted").
    @discardableResult
    func saveLANKey(_ raw: String, part: LANPart, for endpoint: EndpointConfig?) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if OpenAIKeyShape.looksLikeOpenAIKey(key), let e = endpoint, !AddressParser.isTLS(e.baseURL) {
            return Self.openAIKeyOverHTTP
        }
        do {
            _ = try secrets.store(account: SecretAccount.lan(part)).save(key)
        } catch {
            return KeyIntake.keychainFailure
        }
        setKeyAccount(SecretAccount.lan(part), part: part)
        return nil
    }

    func removeLANKey(_ part: LANPart) {
        try? secrets.store(account: SecretAccount.lan(part)).delete()
        setKeyAccount(nil, part: part)
    }

    static let openAIKeyOverHTTP = "That looks like an OpenAI key; it would cross your Wi-Fi unencrypted."

    private func setKeyAccount(_ account: String?, part: LANPart) {
        switch part {
        case .brain: draft.brain?.keyAccount = account
        case .stt: if case .lan(var e) = draft.stt { e.keyAccount = account; draft.stt = .lan(e) }
        case .tts: if case .lan(var e) = draft.tts { e.keyAccount = account; draft.tts = .lan(e) }
        }
    }

    // MARK: - Mode and endpoints

    func setMode(_ mode: ProviderMode) {
        guard mode != draft.mode else { return }
        let brain = draft.brain
        switch mode {
        case .openAI:
            draft = .openAI(model: draft.openAIModel, voice: CloudSettings.voices.contains(draft.voice) ? draft.voice : "marin")
            draft.brain = brain
        case .lanBrainOpenAIVoice:
            var c = ProviderConfig(mode: .lanBrainOpenAIVoice, openAIModel: draft.openAIModel,
                                   voice: CloudSettings.voices.contains(draft.voice) ? draft.voice : "marin",
                                   brain: brain, stt: .openAIRealtime, tts: .openAIREST)
            c.keepAlive = draft.keepAlive
            draft = c
        case .lanEverything:
            let stt: SpeechPart = brain.map { .lan($0) } ?? .onDevice
            let tts: SpeechPart = brain.map { .lan($0) } ?? .onDevice
            var c = ProviderConfig(mode: .lanEverything, openAIModel: draft.openAIModel, voice: "", brain: brain,
                                   stt: stt, tts: tts)
            c.keepAlive = draft.keepAlive
            draft = c
        }
        statuses[.stt] = nil
        statuses[.tts] = nil
    }

    /// Parses an address the user typed ("192.168.1.20:11434", "mac.local:1234").
    func setBrainAddress(_ text: String) -> String? {
        do {
            let url = try AddressParser.parse(text)
            let model = draft.brain?.baseURL == url ? draft.brain?.model ?? "" : ""
            let account = draft.brain?.keyAccount
            draft.brain = EndpointConfig(baseURL: url, model: model, keyAccount: account)
            if draft.mode == .lanEverything {
                // The speech parts follow the brain server unless set separately.
                if case .lan(let e) = draft.stt, e.baseURL != url, statuses[.stt] == nil { draft.stt = .lan(EndpointConfig(baseURL: url, model: e.model)) }
                if case .lan(let e) = draft.tts, e.baseURL != url, statuses[.tts] == nil { draft.tts = .lan(EndpointConfig(baseURL: url, model: e.model)) }
            }
            statuses[.brain] = nil
            return nil
        } catch {
            return error.issue.message
        }
    }

    func setSpeech(_ part: LANPart, to choice: SpeechPart) {
        switch part {
        case .stt: draft.stt = choice
        case .tts: draft.tts = choice
        case .brain: break
        }
        statuses[part == .stt ? .stt : .tts] = nil
    }

    func setSpeechAddress(_ part: LANPart, _ text: String, model: String) -> String? {
        do {
            let url = try AddressParser.parse(text)
            setSpeech(part, to: .lan(EndpointConfig(baseURL: url, model: model)))
            return nil
        } catch {
            return error.issue.message
        }
    }

    // MARK: - Test connection (user-tapped only)

    /// The LAN brain: a local-network preflight, then the capability probe.
    func testBrain() async {
        guard let brain = draft.brain else {
            statuses[.brain] = .failed("Enter your AI server's address first.")
            return
        }
        busy = .brain
        defer { busy = nil }
        if let problem = await LANPreflight.check(brain.baseURL) {
            statuses[.brain] = .failed(problem)
            return
        }
        let key = brain.keyAccount.flatMap { secrets.secret(account: $0) }
        let result = await ConnectionTest.probe(brain.baseURL, key: key, model: brain.model.isEmpty ? nil : brain.model,
                                                recorder: recorder)
        switch result {
        case .success(let caps):
            brainCapabilities = caps
            prefs.brainCapabilities = caps
            brainModels = caps.chatModelIDs
            if draft.brain?.model.isEmpty ?? true, let first = brainModels.first { draft.brain?.model = first }
            statuses[.brain] = caps.chat ? ConnectionTest.summary(caps, host: brain.hostLabel, model: draft.brain?.model ?? "")
                : .failed("\(brain.hostLabel) doesn't offer an OpenAI-compatible chat API")
            if draft.mode == .lanEverything { applySpeechCapabilities(caps, base: brain) }
        case .failure(let why):
            statuses[.brain] = .failed(why.message)
        }
    }

    /// Mode 3: hearing / voice from the brain server when it offers them, else "on this iPhone".
    private func applySpeechCapabilities(_ caps: ServerCapabilities, base: EndpointConfig) {
        if case .lan(let e) = draft.stt, e.baseURL == base.baseURL {
            if caps.transcriptions { statuses[.stt] = .ok("Hearing: \(base.hostLabel)") }
            else { draft.stt = .onDevice; statuses[.stt] = .warning("\(base.hostLabel) can't transcribe — using “on this iPhone”") }
        }
        if case .lan(let e) = draft.tts, e.baseURL == base.baseURL {
            if caps.speech { statuses[.tts] = .ok("Voice: \(base.hostLabel)") }
            else { draft.tts = .onDevice; statuses[.tts] = .warning("\(base.hostLabel) can't speak — using “on this iPhone”") }
        }
        if draft.stt == .onDevice, statuses[.stt] == nil { statuses[.stt] = .ok("Hearing: on this iPhone (free, private)") }
        if draft.tts == .onDevice, statuses[.tts] == nil { statuses[.tts] = .ok("Voice: on this iPhone (free, private)") }
    }

    /// A separate LAN speech server (mode 3).
    func testSpeech(_ part: LANPart) async {
        let choice = part == .stt ? draft.stt : draft.tts
        let key: Part = part == .stt ? .stt : .tts
        switch choice {
        case .onDevice:
            statuses[key] = .ok(part == .stt ? "Hearing: on this iPhone (free, private)" : "Voice: on this iPhone (free, private)")
        case .openAIRealtime, .openAIREST:
            statuses[key] = openAIKeyRedacted == nil ? .failed("I need an OpenAI key") : .ok("OpenAI")
        case .lan(let e):
            busy = key
            defer { busy = nil }
            if let problem = await LANPreflight.check(e.baseURL) {
                statuses[key] = .failed(problem)
                return
            }
            let k = e.keyAccount.flatMap { secrets.secret(account: $0) }
            switch await ConnectionTest.probe(e.baseURL, key: k, model: nil, recorder: recorder) {
            case .success(let caps):
                let offered = part == .stt ? caps.transcriptions : caps.speech
                statuses[key] = offered ? .ok("\(part == .stt ? "Hearing" : "Voice"): \(e.hostLabel)")
                    : .failed("\(e.hostLabel) doesn't offer \(part == .stt ? "/v1/audio/transcriptions" : "/v1/audio/speech") — choose “on this iPhone”")
            case .failure(let why):
                statuses[key] = .failed(why.message)
            }
        }
    }

    func status(_ part: Part) -> PartStatus? { statuses[part] }

    // MARK: - Ready / save

    var issues: [ProviderIssue] { draft.validate(secrets: secrets) }

    /// Done needs a valid config and every tested part OK (untested LAN parts need a test).
    var isReady: Bool {
        guard issues.isEmpty else { return false }
        switch draft.mode {
        case .openAI:
            return openAIKeyRedacted != nil
        case .lanBrainOpenAIVoice:
            return openAIKeyRedacted != nil && statuses[.brain]?.isOK == true
        case .lanEverything:
            guard statuses[.brain]?.isOK == true else { return false }
            for part in [Part.stt, .tts] {
                let choice = part == .stt ? draft.stt : draft.tts
                if case .lan = choice, statuses[part]?.isOK != true { return false }
            }
            return true
        }
    }

    var wakePhraseError: String? {
        do { _ = try WakePhrase(validating: wakePhraseText); return nil } catch { return error.reason }
    }

    var wakePhraseIsShort: Bool { (try? WakePhrase(validating: wakePhraseText))?.isShort ?? false }

    /// Saves to prefs (no network, no reconnect).
    func save() {
        prefs.providerConfig = draft
        if let p = try? WakePhrase(validating: wakePhraseText) { prefs.wakePhrase = p }
        prefs.speakFirst = speakFirst
    }

    /// Reloads the draft from what is saved (cancel in settings).
    func reload() {
        draft = prefs.providerConfig ?? .openAI()
        wakePhraseText = prefs.wakePhrase.text
        speakFirst = prefs.speakFirst
        statuses = [:]
        brainCapabilities = prefs.brainCapabilities
        brainModels = brainCapabilities?.chatModelIDs ?? []
    }
}

/// Before probing a LAN server: is the network path there, and did iOS allow Local
/// Network access? (iOS blocks LAN traffic silently when it is denied.)
enum LANPreflight {
    static func check(_ base: URL) async -> String? {
        guard let host = base.host(), let port = NWEndpoint.Port(rawValue: UInt16(base.port ?? (base.scheme == "https" ? 443 : 80))) else {
            return "That address isn't complete."
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let label = AddressParser.hostLabel(base)
        let unreachable = ProviderIssue.unreachable(host: label, vendor: vendorGuess(base)).message
        let result: String? = await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            let once = OnceFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take() { c.resume(returning: nil) }
                case .waiting(let error), .failed(let error):
                    let denied = connection.currentPath?.unsatisfiedReason == .localNetworkDenied
                    if denied {
                        if once.take() { c.resume(returning: ProviderIssue.localNetworkDenied.message) }
                    } else if case .posix(let code) = error, code == .ECONNREFUSED {
                        if once.take() { c.resume(returning: unreachable) }
                    } else if case .failed = state {
                        if once.take() { c.resume(returning: unreachable) }
                    }
                default:
                    break
                }
            }
            connection.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if once.take() { c.resume(returning: unreachable) }
            }
        }
        connection.cancel()
        return result
    }

    /// For the "make it listen on your network" hint before a probe has said who it is.
    static func vendorGuess(_ base: URL) -> Vendor {
        switch base.port {
        case 11434: .ollama
        case 1234: .lmStudio
        case 8080: .llamaCpp
        default: .other
        }
    }
}
