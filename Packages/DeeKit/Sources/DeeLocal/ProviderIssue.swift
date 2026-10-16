import Foundation
import DeeRealtime

/// Which part of a provider a problem is about.
public enum ProviderPartKind: String, Codable, Sendable, Equatable { case brain, hearing, voice }

/// What a LAN server is (for hints).
public enum Vendor: String, Codable, Sendable, Equatable {
    case ollama, lmStudio, llamaCpp, vllm, localAI, openAI, other
}

/// Everything that can keep a provider from working, worded for the user (contract §7).
///
/// Never carries a key, a response body or spoken text: only hosts, model ids and
/// status codes (K1).
public enum ProviderIssue: Error, Sendable, Equatable, Hashable {
    case noOpenAIKey
    case badOpenAIKey
    case noLANServer
    case noModelChosen(host: String)
    case invalidAddress(String)
    case localNetworkDenied
    case unreachable(host: String, vendor: Vendor)
    case timedOut(host: String, vendor: Vendor)
    case lanNeedsKey(host: String)
    case modelMissing(host: String, model: String)
    case modelLoading(host: String, model: String)
    case redirected(host: String)
    case publicHTTP(host: String)
    case openAIKeyOverHTTP(host: String)
    case notCompatible(host: String)
    case server(host: String, status: Int)
    case modelMismatch(host: String, asked: String, got: String)
    /// A part this mode may not use (e.g. OpenAI in mode 3).
    case partNotAllowed(ProviderPartKind, ProviderMode)
    /// The LAN lacks this part (onboarding offers "on this iPhone").
    case partMissing(ProviderPartKind, host: String)
    /// Mode 2: the realtime transcription mint/session was refused (400/404). No fallback.
    case transcriptionUnavailable
    case onDeviceSpeechUnavailable(ProviderPartKind)
    case rateLimited(ProviderLabel)

    /// The chip / onboarding text.
    public var message: String {
        switch self {
        case .noOpenAIKey: "I need an OpenAI key — open my settings"
        case .badOpenAIKey: "That OpenAI key didn't work"
        case .noLANServer: "I need the address of your AI server — open my settings"
        case .noModelChosen(let host): "Pick a model on \(host) in my settings"
        case .invalidAddress(let text): "\"\(text)\" isn't an address I understand"
        case .localNetworkDenied: "Dee needs Local Network access — Settings › Privacy & Security › Local Network"
        case .unreachable(let host, let vendor), .timedOut(let host, let vendor):
            "I can't reach the AI server at \(host). " + Self.listenHint(vendor)
        case .lanNeedsKey(let host): "The AI server at \(host) wants a key"
        case .modelMissing(let host, let model): "\(host) doesn't have \(model)"
        case .modelLoading(_, let model): "The AI server is loading \(model)…"
        case .redirected(let host): "\(host) tried to send me elsewhere"
        case .publicHTTP: "Use https for servers outside your home network"
        case .openAIKeyOverHTTP:
            "That looks like an OpenAI key; it would cross your Wi-Fi unencrypted"
        case .notCompatible(let host): "\(host) doesn't speak the OpenAI API"
        case .server(let host, let status): "The AI server at \(host) had a problem (\(status))"
        case .modelMismatch(let host, let asked, _): "\(host) answered with a different model than \(asked)"
        case .partNotAllowed(let part, let mode):
            switch (part, mode) {
            case (_, .lanEverything): "In this mode nothing goes to OpenAI — pick your server or this iPhone for \(part.rawValue)"
            default: "That choice for \(part.rawValue) doesn't fit this mode"
            }
        case .partMissing(let part, let host):
            "\(host) can't do \(part == .hearing ? "hearing" : "voices") — I can use this iPhone for that"
        case .transcriptionUnavailable: "OpenAI hearing isn't available for this key"
        case .onDeviceSpeechUnavailable(let part):
            part == .hearing ? "This iPhone can't transcribe speech right now" : "This iPhone has no voice for me yet"
        case .rateLimited(let label): "\(label.spokenName.prefix(1).uppercased() + label.spokenName.dropFirst()) says I'm talking too much — give me a minute"
        }
    }

    /// How to make a LAN server listen on the network, by vendor.
    public static func listenHint(_ vendor: Vendor) -> String {
        switch vendor {
        case .ollama: "Turn on Expose Ollama to the network (OLLAMA_HOST=0.0.0.0)."
        case .lmStudio: "Start the server with network access (bind 0.0.0.0)."
        default: "Make sure it listens on your network, not just localhost."
        }
    }

    /// The user must act (vs. a transient problem).
    public var needsUser: Bool {
        switch self {
        case .timedOut, .modelLoading, .server, .rateLimited: false
        default: true
        }
    }
}
