import Foundation
import DeeRealtime

/// What a LAN server can do (contract §1), from `ServerProbe.probe`.
public struct ServerCapabilities: Codable, Sendable, Equatable {
    public var models: [ServerModel]
    /// Completed a WebSocket upgrade at `/v1/realtime` and answered `session.update` with `session.updated`.
    public var realtime: Bool
    /// `/v1/chat/completions` exists (models listed in OpenAI shape).
    public var chat: Bool
    /// The chosen (or best) chat model takes `tools` (vendor capability, or a test request).
    public var tools: Bool
    /// `/v1/audio/transcriptions` answered a tiny WAV with text (with `transcriptionModel`).
    public var transcriptions: Bool
    public var transcriptionModel: String?
    /// `/v1/audio/speech` answered with audio (with `speechModel`).
    public var speech: Bool
    public var speechModel: String?
    public var vendor: Vendor
    /// Context length of the chosen model as loaded (`/api/ps`) or its maximum (`/api/show`, `/api/v0/models`).
    public var contextLength: Int?
    /// Whether the chosen model is in memory now (a first answer may take tens of seconds if not).
    public var loaded: Bool?
    public var probedAt: Date

    public init(models: [ServerModel] = [], realtime: Bool = false, chat: Bool = false, tools: Bool = false,
                transcriptions: Bool = false, transcriptionModel: String? = nil, speech: Bool = false,
                speechModel: String? = nil, vendor: Vendor = .other, contextLength: Int? = nil, loaded: Bool? = nil,
                probedAt: Date = Date()) {
        self.models = models; self.realtime = realtime; self.chat = chat; self.tools = tools
        self.transcriptions = transcriptions; self.transcriptionModel = transcriptionModel; self.speech = speech
        self.speechModel = speechModel; self.vendor = vendor; self.contextLength = contextLength; self.loaded = loaded
        self.probedAt = probedAt
    }

    /// Models for the picker (embeddings, classifiers, speech models filtered out).
    public var chatModels: [ServerModel] { models.filter(\.isChat) }

    /// A warning when the context can't hold Dee's prompt + history + an answer.
    public func contextWarning(promptTokens: Int = 3_000, historyTokens: Int = 1_500, maxTokens: Int = 300) -> String? {
        guard let contextLength, contextLength < promptTokens + historyTokens + maxTokens else { return nil }
        return "This model's context (\(contextLength) tokens) is too small for Dee (about \(promptTokens + historyTokens + maxTokens) needed)."
    }
}

/// Result of a 1-token chat test.
public struct ChatTestResult: Sendable, Equatable {
    /// Seconds to the first token (a cold model shows here: "first answer after a pause takes N s").
    public var firstTokenSeconds: Double
    /// The model id the server answered with.
    public var answeredModel: String?
    public var usedTools: Bool
}

/// Probes a LAN OpenAI-compatible server (contract §1/§2): models, vendor routes, realtime WS,
/// audio endpoints, tools, context. Every request goes through `transport` (recorded) and only to
/// `base` — run only on a user's "Test connection" (W2 allows nothing else while dormant).
public struct ServerProbe: Sendable {
    public let transport: Transport
    public let resolver: any HostResolver
    public var modelsDeadline: Double = 3
    public var chatDeadline: Double = 90

    public init(transport: Transport, resolver: any HostResolver = SystemResolver()) {
        self.transport = transport
        self.resolver = resolver
    }

    func client(_ base: URL, key: String?) -> CompatClient {
        CompatClient(base: base, key: key, transport: transport, resolver: resolver)
    }

    /// Everything but a chat request. `model`: the one the user picked (for tools/context/loaded).
    public func probe(_ base: URL, key: String?, model: String? = nil, checkRealtime: Bool = true,
                      transcriptionModel: String? = nil, speechModel: String? = nil, speechVoice: String? = nil) async
        -> Result<ServerCapabilities, ProviderIssue> {
        let c = client(base, key: key)
        if let k = key, OpenAIKeyShape.looksLikeOpenAIKey(k), !AddressParser.isTLS(base) {
            return .failure(.openAIKeyOverHTTP(host: c.host))
        }
        var caps = ServerCapabilities()
        let listed: [ServerModel]
        do {
            listed = try await c.models(deadline: modelsDeadline)
        } catch {
            // An audio-only server may have no /v1/models: still probe audio when models were named.
            if transcriptionModel == nil && speechModel == nil {
                return .failure(error.issue(host: c.host, vendor: await vendor(c), label: c.label))
            }
            listed = []
        }
        caps.chat = !listed.isEmpty
        caps.vendor = await vendor(c)
        caps.models = await enrich(listed, client: c, vendor: caps.vendor)
        let chosen = model.flatMap { m in caps.models.first { $0.id == m } } ?? caps.chatModels.first
        if let chosen {
            caps.contextLength = chosen.contextLength
            caps.loaded = chosen.loaded
            caps.tools = chosen.supportsTools ?? false
            if chosen.supportsTools == nil, caps.chat {
                caps.tools = await toolsWork(c, model: chosen.id)
            }
        }
        if let model, !model.isEmpty, caps.chat, !caps.models.contains(where: { $0.id == model }) {
            return .failure(.modelMissing(host: c.host, model: model))
        }
        // Audio: only with a model that answers (a route alone proves nothing: Ollama has the route, no model).
        let sttCandidates = ([transcriptionModel].compactMap { $0 } + listed.map(\.id).filter(Self.looksLikeSTT)).uniqued()
        for m in sttCandidates.prefix(3) where await transcriptionWorks(c, model: m) {
            caps.transcriptions = true; caps.transcriptionModel = m; break
        }
        let ttsCandidates = ([speechModel].compactMap { $0 } + listed.map(\.id).filter(Self.looksLikeTTS)).uniqued()
        for m in ttsCandidates.prefix(3) where await speechWorks(c, model: m, voice: speechVoice ?? "af_heart") {
            caps.speech = true; caps.speechModel = m; break
        }
        if checkRealtime { caps.realtime = await realtimeWorks(base, key: key, model: chosen?.id ?? model ?? "") }
        caps.probedAt = Date()
        return .success(caps)
    }

    static func looksLikeSTT(_ id: String) -> Bool {
        let s = id.lowercased()
        return ["whisper", "transcribe", "parakeet", "stt", "canary", "moonshine"].contains(where: s.contains)
    }

    static func looksLikeTTS(_ id: String) -> Bool {
        let s = id.lowercased()
        return ["tts", "kokoro", "piper", "orpheus", "speech", "xtts", "sesame", "csm"].contains(where: s.contains)
    }

    /// Ollama (`/api/version`), LM Studio (`/api/v0/models`), llama.cpp (`/props`), else other.
    func vendor(_ c: CompatClient) async -> Vendor {
        if let (s, j) = await c.nativeJSON("/api/version"), s == 200, j?["version"]?.stringValue != nil { return .ollama }
        if let (s, j) = await c.nativeJSON("/api/v0/models"), s == 200, j?["error"] == nil, j?["data"] != nil { return .lmStudio }
        if let (s, j) = await c.nativeJSON("/props"), s == 200, j?["default_generation_settings"] != nil { return .llamaCpp }
        return .other
    }

    /// Capabilities, kind, loaded state and context from the vendor's own routes.
    func enrich(_ models: [ServerModel], client c: CompatClient, vendor: Vendor) async -> [ServerModel] {
        switch vendor {
        case .ollama:
            var loaded: [String: Int?] = [:]
            if let (_, j) = await c.nativeJSON("/api/ps"), case .array(let list) = j?["models"] ?? .null {
                for m in list {
                    if let name = m["name"]?.stringValue ?? m["model"]?.stringValue { loaded[name] = m["context_length"]?.intValue }
                }
            }
            var out: [ServerModel] = []
            for var m in models {
                if let (s, j) = await c.nativeJSON("/api/show", method: "POST", body: ["model": .string(m.id)]), s == 200, let j {
                    if case .array(let caps) = j["capabilities"] ?? .null { m.capabilities = caps.compactMap(\.stringValue) }
                    if case .object(let info) = j["model_info"] ?? .null {
                        m.contextLength = info.first { $0.key.hasSuffix(".context_length") }?.value.intValue
                    }
                }
                if let ctx = loaded[m.id] { m.loaded = true; if let ctx { m.contextLength = ctx } } else { m.loaded = false }
                out.append(m)
            }
            return out
        case .lmStudio:
            guard let (_, j) = await c.nativeJSON("/api/v0/models"), case .array(let list) = j?["data"] ?? .null else { return models }
            var byID: [String: RealtimeJSON] = [:]
            for m in list { if let id = m["id"]?.stringValue { byID[id] = m } }
            return models.map { var m = $0
                if let info = byID[m.id] {
                    m.kind = info["type"]?.stringValue
                    if case .array(let caps) = info["capabilities"] ?? .null { m.capabilities = caps.compactMap(\.stringValue) }
                    m.loaded = info["state"]?.stringValue == "loaded"
                    m.contextLength = info["loaded_context_length"]?.intValue ?? info["max_context_length"]?.intValue
                }
                return m
            }
        default:
            return models
        }
    }

    /// A 1-token request with a dummy tool; a 400 means no tools.
    func toolsWork(_ c: CompatClient, model: String) async -> Bool {
        let req = ChatRequest(model: model, messages: [.user("Say hi.")],
                              tools: [ChatTool(name: "noop", description: "Does nothing.", parameters: ["type": "object", "properties": .object([:])])],
                              maxTokens: 1)
        do {
            for try await _ in c.chat(req, firstByteDeadline: chatDeadline, purpose: "probe") {}
            return true
        } catch {
            return false
        }
    }

    /// One tiny request: time to first token, model echo, tools.
    public func testChat(_ base: URL, key: String?, model: String, tools: Bool = false) async -> Result<ChatTestResult, ProviderIssue> {
        let c = client(base, key: key)
        let start = Date()
        var first: Double?
        var answered: String?
        let req = ChatRequest(model: model, messages: [.system("Answer with one word."), .user("Ready?")],
                              tools: tools ? [ChatTool(name: "noop", description: "Does nothing.", parameters: nil)] : [],
                              maxTokens: 4)
        do {
            for try await piece in c.chat(req, firstByteDeadline: chatDeadline, purpose: "probe") {
                switch piece {
                case .model(let m): answered = answered ?? m
                case .content, .reasoning, .toolCallDelta, .toolCall: if first == nil { first = Date().timeIntervalSince(start) }
                default: break
                }
            }
        } catch {
            return .failure(error.providerIssue(host: c.host, model: model, label: c.label))
        }
        if let answered, !CascadeEngine.sameModel(answered, model) {
            return .failure(.modelMismatch(host: c.host, asked: model, got: answered))
        }
        return .success(ChatTestResult(firstTokenSeconds: first ?? Date().timeIntervalSince(start), answeredModel: answered, usedTools: tools))
    }

    /// 0.5 s of quiet noise as WAV; any text answer (even empty) proves the endpoint + model.
    public func transcriptionWorks(_ c: CompatClient, model: String) async -> Bool {
        var pcm = Data(capacity: 24_000)
        var seed: UInt32 = 1
        for _ in 0..<12_000 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let v = Int16(truncatingIfNeeded: Int32(seed >> 16) % 200 - 100)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        do {
            _ = try await c.transcribe(wav: WAV.pcm16(pcm, rate: 24_000), model: model, deadline: 20)
            return true
        } catch {
            return false
        }
    }

    public func speechWorks(_ c: CompatClient, model: String, voice: String) async -> Bool {
        var bytes = 0
        do {
            for try await chunk in c.speech(text: "Hi.", model: model, voice: voice, instructions: nil, format: "wav",
                                            firstByteDeadline: 20, purpose: "probe") {
                bytes += chunk.count
            }
        } catch {
            return false
        }
        return bytes > 44
    }

    /// WS upgrade at `/v1/realtime` + `session.updated` within 3 s (anything else: not realtime).
    public func realtimeWorks(_ base: URL, key: String?, model: String) async -> Bool {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return false }
        comps.scheme = AddressParser.isTLS(base) ? "wss" : "ws"
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + "/v1/realtime"
        if !model.isEmpty { comps.queryItems = [URLQueryItem(name: "model", value: model)] }
        guard let url = comps.url else { return false }
        var r = URLRequest(url: url)
        if let key, !key.isEmpty { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        r.setValue("probe", forHTTPHeaderField: Transport.purposeHeader)
        let socket = transport.socketFactory(r)
        defer { socket.close(code: 1000, reason: nil) }
        do {
            try await withDeadline(3) { try await socket.open() }
        } catch {
            return false
        }
        let update = ClientEvent.sessionUpdate(SessionPayload(type: "realtime", model: model.isEmpty ? nil : model,
                                                              instructions: "probe"))
        guard let text = try? update.jsonText() else { return false }
        socket.send(text)
        let incoming = socket.incoming
        return (try? await withDeadline(3) {
            for await e in incoming {
                guard case .text(let t) = e else { return false }
                if case .sessionUpdated = ServerEvent.parse(t) { return true }
                if case .error = ServerEvent.parse(t) { return false }
            }
            return false
        }) ?? false
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
