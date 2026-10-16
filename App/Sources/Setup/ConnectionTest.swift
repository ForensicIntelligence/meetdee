import DeeLocal
import DeeRealtime
import Foundation

/// "Test connection" (user-tapped only): DeeLocal's capability probe of a LAN server
/// over a recorded, redirect-refusing transport (N1/X1), worded for the setup screens.
enum ConnectionTest {
    struct Failure: Error, Equatable { let message: String }

    static func probe(_ base: URL, key: String?, model: String?, recorder: TransportRecorder) async -> Result<ServerCapabilities, Failure> {
        let transport = Transport.live(redirects: .refuse, recorder: recorder)
        switch await ServerProbe(transport: transport).probe(base, key: key, model: model) {
        case .success(let caps): return .success(caps)
        case .failure(let issue): return .failure(Failure(message: issue.message))
        }
    }

    /// One line for the brain row: the model, tools, and a warning when it isn't loaded.
    static func summary(_ caps: ServerCapabilities, host: String, model: String) -> ProviderStore.PartStatus {
        var parts = ["\(caps.vendorName) at \(host)"]
        if !model.isEmpty { parts.append(model) }
        if caps.tools { parts.append("tools") }
        if caps.loaded == false {
            return .warning(parts.joined(separator: " · ") + " — the first answer after a pause takes a while (the model loads)")
        }
        return .ok(parts.joined(separator: " · "))
    }
}

extension ServerCapabilities {
    /// Chat-capable model ids (embedding / speech models filtered out).
    var chatModelIDs: [String] { chatModels.map(\.id) }

    var vendorName: String {
        switch vendor {
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .llamaCpp: "llama.cpp"
        case .vllm: "vLLM"
        case .localAI: "LocalAI"
        case .openAI: "OpenAI-compatible"
        case .other: "Server"
        }
    }
}
