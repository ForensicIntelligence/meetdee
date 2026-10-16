import Foundation
import DeeRealtime

// Provider configuration (contract 0.6 §1). Persisted by the app as JSON under
// `ProviderConfig.defaultsKey`. It never holds a secret (K1): keys live in the
// Keychain under `SecretAccount` names and are only referenced here by account.

/// The three ways Dee can think, hear and speak.
public enum ProviderMode: String, Codable, Sendable, CaseIterable {
    /// Mode 1: OpenAI gpt-realtime for everything (today's path).
    case openAI
    /// Mode 2: a LAN server thinks; OpenAI hears (realtime transcription) and speaks (/v1/audio/speech).
    case lanBrainOpenAIVoice
    /// Mode 3: LAN servers (or this iPhone) for everything; never OpenAI.
    case lanEverything

    /// Plain-language name for UI.
    public var title: String {
        switch self {
        case .openAI: "OpenAI for everything"
        case .lanBrainOpenAIVoice: "Your Mac's brain, OpenAI's voice"
        case .lanEverything: "Your own network for everything"
        }
    }
}

/// One OpenAI-compatible endpoint on the LAN.
public struct EndpointConfig: Codable, Sendable, Equatable, Hashable {
    /// Normalised by `AddressParser`: scheme + host + port (+ path prefix), no userinfo,
    /// query or fragment, no trailing `/v1`.
    public var baseURL: URL
    /// Model id as the server lists it (may be empty for TTS/STT servers that ignore it).
    public var model: String
    /// Keychain account of its optional bearer key (`SecretAccount.lan(_:)`), nil = no key.
    public var keyAccount: String?

    public init(baseURL: URL, model: String, keyAccount: String? = nil) {
        self.baseURL = baseURL
        self.model = model
        self.keyAccount = keyAccount
    }

    /// "192.168.1.20:11434" for messages.
    public var hostLabel: String { AddressParser.hostLabel(baseURL) }
}

/// Where one speech part (hearing or voice) runs.
public enum SpeechPart: Codable, Sendable, Equatable, Hashable {
    /// OpenAI realtime transcription session over WebSocket (mode 2 hearing).
    case openAIRealtime
    /// OpenAI REST (`/v1/audio/speech` for voice, `/v1/audio/transcriptions` for hearing).
    case openAIREST
    /// A LAN OpenAI-compatible endpoint.
    case lan(EndpointConfig)
    /// Apple's on-device speech on this iPhone (free, private).
    case onDevice

    public var isOpenAI: Bool {
        switch self {
        case .openAIRealtime, .openAIREST: true
        case .lan, .onDevice: false
        }
    }

    public var endpoint: EndpointConfig? { if case .lan(let e) = self { e } else { nil } }
}

/// Which LAN part a key or endpoint belongs to.
public enum LANPart: String, Codable, Sendable, CaseIterable { case brain, stt, tts }

/// Keychain account names (service `com.dee.realtime`, `KeyStore(account:)`).
public enum SecretAccount {
    public static let openAI = "openai.api-key"
    public static func lan(_ part: LANPart) -> String { "lan.\(part.rawValue).key" }
}

/// Reads secrets (Keychain in the app, memory in tests). Never logs them.
public protocol SecretReader: Sendable {
    func secret(account: String) -> String?
}

/// A dictionary-backed `SecretReader` for tests and previews.
public struct StaticSecrets: SecretReader {
    public var values: [String: String]
    public init(_ values: [String: String] = [:]) { self.values = values }
    public func secret(account: String) -> String? { values[account].flatMap { $0.isEmpty ? nil : $0 } }
}

public struct ProviderConfig: Codable, Sendable, Equatable {
    public static let defaultsKey = "providerConfig"

    public var mode: ProviderMode
    /// Mode 1 realtime model.
    public var openAIModel: String = "gpt-realtime-2.1-mini"
    /// Voice name: OpenAI voice (modes 1/2), LAN TTS voice id, or an AVSpeech voice identifier (on-device).
    public var voice: String = "marin"
    /// The LAN chat server (modes 2/3).
    public var brain: EndpointConfig?
    public var stt: SpeechPart
    public var tts: SpeechPart
    /// Mode 3 only: use the LAN server's `/v1/realtime` (only after a probe completed the WS upgrade + session.updated).
    public var lanRealtime: Bool = false
    /// Ollama `keep_alive` sent on every LAN chat request.
    public var keepAlive: String = "30m"

    public init(mode: ProviderMode, openAIModel: String = "gpt-realtime-2.1-mini", voice: String = "marin",
                brain: EndpointConfig? = nil, stt: SpeechPart, tts: SpeechPart, lanRealtime: Bool = false,
                keepAlive: String = "30m") {
        self.mode = mode; self.openAIModel = openAIModel; self.voice = voice; self.brain = brain
        self.stt = stt; self.tts = tts; self.lanRealtime = lanRealtime; self.keepAlive = keepAlive
    }

    public static func openAI(model: String = "gpt-realtime-2.1-mini", voice: String = "marin") -> ProviderConfig {
        ProviderConfig(mode: .openAI, openAIModel: model, voice: voice, stt: .openAIRealtime, tts: .openAIRealtime)
    }

    public static func lanBrainOpenAIVoice(brain: EndpointConfig, voice: String = "marin") -> ProviderConfig {
        ProviderConfig(mode: .lanBrainOpenAIVoice, voice: voice, brain: brain, stt: .openAIRealtime, tts: .openAIREST)
    }

    /// `stt` / `tts`: `.lan(...)` or `.onDevice`; default = the brain server for both.
    public static func lanEverything(brain: EndpointConfig, stt: SpeechPart? = nil, tts: SpeechPart? = nil,
                                     voice: String = "", lanRealtime: Bool = false) -> ProviderConfig {
        ProviderConfig(mode: .lanEverything, voice: voice, brain: brain,
                       stt: stt ?? .lan(brain), tts: tts ?? .lan(brain), lanRealtime: lanRealtime)
    }

    /// Everything that keeps this configuration from working, without touching the network.
    /// Empty = usable. Secrets are checked with `secrets` when given (presence only).
    public func validate(secrets: (any SecretReader)? = nil) -> [ProviderIssue] {
        var issues: [ProviderIssue] = []
        func checkLAN(_ e: EndpointConfig, part: LANPart) {
            do {
                _ = try AddressParser.validateBase(e.baseURL)
            } catch {
                issues.append(error.issue)
            }
            if part == .brain, e.model.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(.noModelChosen(host: e.hostLabel))
            }
            if let account = e.keyAccount, let key = secrets?.secret(account: account),
               OpenAIKeyShape.looksLikeOpenAIKey(key), !AddressParser.isTLS(e.baseURL) {
                issues.append(.openAIKeyOverHTTP(host: e.hostLabel))
            }
        }
        let needsOpenAIKey: Bool
        switch mode {
        case .openAI:
            needsOpenAIKey = true
            if openAIModel.isEmpty { issues.append(.noModelChosen(host: "OpenAI")) }
        case .lanBrainOpenAIVoice:
            needsOpenAIKey = true
            if let brain { checkLAN(brain, part: .brain) } else { issues.append(.noLANServer) }
            if stt != .openAIRealtime && stt != .openAIREST { issues.append(.partNotAllowed(.hearing, mode)) }
            if tts != .openAIREST { issues.append(.partNotAllowed(.voice, mode)) }
        case .lanEverything:
            needsOpenAIKey = false
            if let brain { checkLAN(brain, part: .brain) } else { issues.append(.noLANServer) }
            // W3: never OpenAI in mode 3.
            if stt.isOpenAI { issues.append(.partNotAllowed(.hearing, mode)) }
            if tts.isOpenAI { issues.append(.partNotAllowed(.voice, mode)) }
            if case .lan(let e) = stt { checkLAN(e, part: .stt) }
            if case .lan(let e) = tts { checkLAN(e, part: .tts) }
        }
        if needsOpenAIKey, let secrets {
            if secrets.secret(account: SecretAccount.openAI) == nil { issues.append(.noOpenAIKey) }
        }
        var seen = Set<ProviderIssue>()
        return issues.filter { seen.insert($0).inserted }
    }

    /// The label used in problem texts for the part that thinks.
    public var brainLabel: ProviderLabel {
        switch mode {
        case .openAI: .openAI
        case .lanBrainOpenAIVoice, .lanEverything: .lan(host: brain?.hostLabel ?? "?")
        }
    }

    // Decoding tolerates missing optional fields (older saved configs).
    enum CodingKeys: String, CodingKey { case mode, openAIModel, voice, brain, stt, tts, lanRealtime, keepAlive }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(ProviderMode.self, forKey: .mode)
        openAIModel = try c.decodeIfPresent(String.self, forKey: .openAIModel) ?? "gpt-realtime-2.1-mini"
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? "marin"
        brain = try c.decodeIfPresent(EndpointConfig.self, forKey: .brain)
        stt = try c.decodeIfPresent(SpeechPart.self, forKey: .stt) ?? (mode == .lanEverything ? .onDevice : .openAIRealtime)
        tts = try c.decodeIfPresent(SpeechPart.self, forKey: .tts) ?? (mode == .openAI ? .openAIRealtime : mode == .lanEverything ? .onDevice : .openAIREST)
        lanRealtime = try c.decodeIfPresent(Bool.self, forKey: .lanRealtime) ?? false
        keepAlive = try c.decodeIfPresent(String.self, forKey: .keepAlive) ?? "30m"
    }
}

/// Shape checks on key text (no network).
public enum OpenAIKeyShape {
    /// `sk-…`: an OpenAI key (refused over plain http to the LAN).
    public static func looksLikeOpenAIKey(_ key: String) -> Bool {
        key.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("sk-")
    }
}
