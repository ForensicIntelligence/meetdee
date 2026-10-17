import Foundation
import DeeRealtime

/// A failed call to an OpenAI-compatible server, classified (no bodies, no keys).
public enum CompatError: Error, Sendable, Equatable {
    case transport(HTTPFailure)
    case status(Int, code: String?)
    case redirected
    case notCompatible
    case modelMissing(String)
    case modelMismatch(asked: String, got: String)
    case streamError(String)
    case address(AddressError)
    /// An `sk-` key would cross the LAN over plain http.
    case keyOverHTTP

    /// The user-facing problem for a server at `host`.
    public func issue(host: String, vendor: Vendor = .other, model: String = "", label: ProviderLabel? = nil) -> ProviderIssue {
        let isOpenAI = label == .openAI
        switch self {
        case .transport(let f):
            switch f {
            case .timedOut: return .timedOut(host: host, vendor: vendor)
            case .localNetworkDenied: return .localNetworkDenied
            default: return .unreachable(host: host, vendor: vendor)
            }
        case .status(let s, _) where s == 401 || s == 403: return isOpenAI ? .badOpenAIKey : .lanNeedsKey(host: host)
        case .status(429, _): return .rateLimited(label ?? .lan(host: host))
        case .status(404, _): return model.isEmpty ? .notCompatible(host: host) : .modelMissing(host: host, model: model)
        case .status(let s, _): return .server(host: host, status: s)
        case .redirected: return .redirected(host: host)
        case .notCompatible: return .notCompatible(host: host)
        case .modelMissing(let m): return .modelMissing(host: host, model: m)
        case .modelMismatch(let a, let g): return .modelMismatch(host: host, asked: a, got: g)
        case .streamError: return .server(host: host, status: 200)
        case .address(let e): return e.issue
        case .keyOverHTTP: return .openAIKeyOverHTTP(host: host)
        }
    }
}

/// A model a server lists.
public struct ServerModel: Codable, Sendable, Equatable, Hashable {
    public var id: String
    /// From vendor APIs: "completion"/"tools"/"thinking"/"vision" (Ollama), "tool_use" (LM Studio).
    public var capabilities: [String]
    /// `llm`, `vlm`, `embeddings`, `whisper`, `tts`, … when known.
    public var kind: String?
    public var loaded: Bool?
    public var contextLength: Int?

    public init(id: String, capabilities: [String] = [], kind: String? = nil, loaded: Bool? = nil, contextLength: Int? = nil) {
        self.id = id; self.capabilities = capabilities; self.kind = kind; self.loaded = loaded; self.contextLength = contextLength
    }

    /// Can chat: not an embedding/classifier/speech model.
    public var isChat: Bool {
        let k = (kind ?? "").lowercased()
        if ["embeddings", "embedding", "whisper", "tts", "stt"].contains(k) { return false }
        let lowered = id.lowercased()
        if lowered.contains("embed") || lowered.contains("whisper") || lowered.contains("tts") || lowered.contains("kokoro") { return false }
        if !capabilities.isEmpty {
            let c = Set(capabilities.map { $0.lowercased() })
            if c.contains("completion") || c.contains("tool_use") || c.contains("tools") || c.contains("chat") { return true }
            if kind == nil || k.isEmpty { return false }   // Ollama caps without "completion" (e.g. ["decision"])
        }
        return true
    }

    public var supportsTools: Bool? {
        guard !capabilities.isEmpty else { return nil }
        let c = Set(capabilities.map { $0.lowercased() })
        return c.contains("tools") || c.contains("tool_use")
    }
}

/// HTTP client for one OpenAI-compatible base URL (`…/v1/*`, plus Ollama/LM Studio native routes).
public struct CompatClient: Sendable {
    public let base: URL
    let keyProvider: @Sendable () -> String?
    var key: String? { keyProvider().flatMap { $0.isEmpty ? nil : $0 } }
    let transport: Transport
    let resolver: any HostResolver
    let label: ProviderLabel

    /// - Parameter key: bearer (optional for LAN). An `sk-` key is refused over plain http (N1).
    /// `transport`: built by `ProviderFactory` (`Transport.live(redirects: .refuse)` for LAN parts,
    /// `.sameHost` for OpenAI parts) so every call is recorded (X1).
    public init(base: URL, key: String?, transport: Transport, resolver: any HostResolver = SystemResolver(),
                label: ProviderLabel? = nil) {
        let k = key.flatMap { $0.isEmpty ? nil : $0 }
        self.init(base: base, keyProvider: { k }, transport: transport, resolver: resolver, label: label)
    }

    /// The key is read per request (a key replaced in settings applies to the next request).
    public init(base: URL, keyProvider: @escaping @Sendable () -> String?, transport: Transport,
                resolver: any HostResolver = SystemResolver(), label: ProviderLabel? = nil) {
        self.base = base
        self.keyProvider = keyProvider
        self.transport = transport
        self.resolver = resolver
        let isOpenAI = base.host?.lowercased() == "api.openai.com"
        self.label = label ?? (isOpenAI ? .openAI : .lan(host: AddressParser.hostLabel(base)))
    }

    public static let openAIBase = URL(string: "https://api.openai.com")!

    public var host: String { AddressParser.hostLabel(base) }

    /// `base` + `/v1/…` or a native path.
    func url(_ path: String) async throws(CompatError) -> URL {
        let effective: URL
        do { effective = try await NetworkPolicy.effectiveURL(base, resolver: resolver) } catch { throw .address(error) }
        if let k = self.key, OpenAIKeyShape.looksLikeOpenAIKey(k), !AddressParser.isTLS(effective),
           effective.host?.lowercased() != "api.openai.com" {
            throw .keyOverHTTP
        }
        var s = effective.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s + path)!
    }

    func request(_ path: String, method: String = "GET", body: Data? = nil, contentType: String? = "application/json",
                 timeout: Double, purpose: String) async throws(CompatError) -> URLRequest {
        var r = URLRequest(url: try await url(path))
        r.setValue(purpose, forHTTPHeaderField: Transport.purposeHeader)
        r.httpMethod = method
        r.timeoutInterval = timeout
        r.httpShouldHandleCookies = false
        r.cachePolicy = .reloadIgnoringLocalCacheData
        if let key = self.key { r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if let body { r.httpBody = body; if let contentType { r.setValue(contentType, forHTTPHeaderField: "Content-Type") } }
        return r
    }

    /// Sends and classifies: transport errors, 3xx (refused redirect), ≥ 400.
    func send(_ r: URLRequest, deadline: Double) async throws(CompatError) -> (Data, HTTPURLResponse) {
        let result: (Data, HTTPURLResponse)
        do {
            let fetch = transport.fetch
            let (data, response) = try await withDeadline(deadline) { try await fetch(r) }
            guard let http = response as? HTTPURLResponse else { throw HTTPFailure.other("not http") }
            result = (data, http)
        } catch {
            throw .transport(HTTPFailure.classify(error))
        }
        try Self.check(result.1, body: result.0)
        return result
    }

    static func check(_ response: HTTPURLResponse, body: Data?) throws(CompatError) {
        let s = response.statusCode
        if (300..<400).contains(s) { throw .redirected }
        if s >= 400 {
            let code = body.flatMap { RealtimeJSON.parse(String(decoding: $0, as: UTF8.self)) }
                .flatMap { $0["error"]?["code"]?.stringValue ?? $0["error"]?["type"]?.stringValue }
            if s == 404, let body, let msg = RealtimeJSON.parse(String(decoding: body, as: UTF8.self))?["error"],
               let text = (msg["message"]?.stringValue ?? msg.stringValue)?.lowercased(),
               text.contains("model"), text.contains("not found") {
                throw .modelMissing("")
            }
            throw .status(s, code: code.map(Self.safeCode))
        }
    }

    /// Error codes are kept only if they look like codes (an error message can echo a key).
    static func safeCode(_ c: String) -> String {
        let ok = c.count <= 40 && !c.hasPrefix("sk") && c.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
        return ok ? c : "error"
    }

    // MARK: Models

    /// `GET /v1/models`. LM Studio answers unknown routes with 200 + `{"error":…}`: decided by body.
    public func models(deadline: Double = 3) async throws(CompatError) -> [ServerModel] {
        let (data, _) = try await send(try await request("/v1/models", timeout: deadline, purpose: "models"), deadline: deadline)
        guard let j = RealtimeJSON.parse(String(decoding: data, as: UTF8.self)), j["error"] == nil,
              case .array(let list) = j["data"] ?? .null else { throw .notCompatible }
        return list.compactMap { m in m["id"]?.stringValue.map { ServerModel(id: $0) } }
    }

    // MARK: Chat

    public enum Route: Sendable, Equatable {
        case openAI       // /v1/chat/completions SSE
        case ollamaNative // /api/chat NDJSON
    }

    /// Streams one chat response. The stream ends after `.finish` (or throws `CompatError`).
    /// `firstByteDeadline`: no response headers within it → `.transport(.timedOut)`.
    /// `lane`: held from before the request until its HTTP stream has closed (one request at a
    /// time per server, `ChatLane`). `rateLimit`: HTTP 429 before any byte of the answer is
    /// waited out and retried (honouring `Retry-After`) within its budget, then fails as `.status(429)`.
    public func chat(_ req: ChatRequest, route: Route = .openAI, firstByteDeadline: Double = 90, purpose: String = "chat",
                     lane: ChatLane? = nil, rateLimit: RateLimitRetry = .none)
        -> AsyncThrowingStream<ChatPiece, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                if let lane {
                    guard await lane.acquire() else { continuation.finish(throwing: CancellationError()); return }
                    if Task.isCancelled {
                        await lane.release()
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                }
                await chatBody(req, route: route, firstByteDeadline: firstByteDeadline, purpose: purpose,
                               rateLimit: rateLimit, continuation: continuation)
                if let lane { await lane.release() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func chatBody(_ req: ChatRequest, route: Route, firstByteDeadline: Double, purpose: String,
                          rateLimit: RateLimitRetry, continuation: AsyncThrowingStream<ChatPiece, Error>.Continuation) async {
                do {
                    let path = route == .openAI ? "/v1/chat/completions" : "/api/chat"
                    let body = route == .openAI ? req.openAIBody() : req.ollamaBody()
                    var (response, bytes): (HTTPURLResponse, AsyncThrowingStream<Data, Error>)
                    var attempt = 0
                    var waitedSoFar = 0.0
                    while true {
                        let r = try await request(path, method: "POST", body: body, timeout: firstByteDeadline, purpose: purpose)
                        do {
                            let stream = transport.stream
                            let s = try await withDeadline(firstByteDeadline) { try await stream(r) }
                            (response, bytes) = (s.response, s.body)
                        } catch let e as CompatError {
                            throw e
                        } catch {
                            throw CompatError.transport(HTTPFailure.classify(error))
                        }
                        guard response.statusCode == 429 else { break }
                        let wait = RateLimitRetry.delay(retryAfter: response.value(forHTTPHeaderField: "Retry-After"), attempt: attempt)
                        guard waitedSoFar + wait <= rateLimit.budget + 1e-9 else { break }
                        // Busy (a single-slot server, or another client on it): wait, then ask again.
                        do { for try await _ in bytes {} } catch {}
                        try await Task.sleep(for: .seconds(wait))
                        waitedSoFar += wait
                        attempt += 1
                    }
                    if response.statusCode >= 300 {
                        var body = Data()
                        do { for try await c in bytes { body.append(c); if body.count > 8192 { break } } } catch {}
                        do { try Self.check(response, body: body) } catch {
                            if case CompatError.modelMissing = error { throw CompatError.modelMissing(req.model) }
                            throw error
                        }
                    }
                    var sse = SSEParser()
                    var lines = LineSplitter()
                    var counter = 0
                    var finished = false
                    func handle(_ pieces: [ChatPiece]) throws {
                        for p in pieces {
                            if case .error(let status, let message) = p {
                                if let status, status >= 400 { throw CompatError.status(status, code: nil) }
                                if message.lowercased().contains("not found") && message.lowercased().contains("model") {
                                    throw CompatError.modelMissing(req.model)
                                }
                                throw CompatError.streamError(String(message.prefix(80)))
                            }
                            continuation.yield(p)
                            if case .finish = p { finished = true }
                        }
                    }
                    do {
                        for try await chunk in bytes {
                            if route == .openAI {
                                for e in sse.push(chunk) {
                                    switch e {
                                    case .data(let t): try handle(ChatChunkDecoder.decodeOpenAI(t))
                                    case .done: finished = true
                                    }
                                }
                            } else {
                                for line in lines.push(chunk) where !line.isEmpty {
                                    try handle(ChatChunkDecoder.decodeOllama(line, callCounter: &counter))
                                }
                            }
                        }
                    } catch let e as CompatError {
                        throw e
                    } catch {
                        throw CompatError.transport(HTTPFailure.classify(error))
                    }
                    if route == .openAI {
                        for e in sse.finish() { if case .data(let t) = e { try handle(ChatChunkDecoder.decodeOpenAI(t)) } }
                    } else if let rest = lines.finish() {
                        try handle(ChatChunkDecoder.decodeOllama(rest, callCounter: &counter))
                    }
                    if !finished { continuation.yield(.finish(reason: "stop")) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
    }

    // MARK: Audio

    /// `POST /v1/audio/transcriptions` (multipart; WAV of the span). Returns the text.
    public func transcribe(wav: Data, model: String, language: String? = "en", prompt: String? = nil,
                           deadline: Double = 30) async throws(CompatError) -> String {
        let boundary = "dee-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        if !model.isEmpty { field("model", model) }
        if let language { field("language", language) }
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }
        field("response_format", "json")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let r = try await request("/v1/audio/transcriptions", method: "POST", body: body,
                                  contentType: "multipart/form-data; boundary=\(boundary)", timeout: deadline,
                                  purpose: "stt")
        let (data, response) = try await send(r, deadline: deadline)
        let text = String(decoding: data, as: UTF8.self)
        if let j = RealtimeJSON.parse(text) {
            if j["error"] != nil { throw .notCompatible }
            if let t = j["text"]?.stringValue { return t.trimmingCharacters(in: .whitespacesAndNewlines) }
            throw .notCompatible
        }
        if (response.value(forHTTPHeaderField: "Content-Type") ?? "").hasPrefix("text/plain") {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw .notCompatible
    }

    /// `POST /v1/audio/speech` streamed raw PCM16 mono (24 kHz for OpenAI; `sampleRate` for others).
    public func speech(text: String, model: String, voice: String, instructions: String?, speed: Double? = nil,
                       format: String = "pcm", firstByteDeadline: Double = 20, purpose: String = "tts") -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var o: [String: RealtimeJSON] = ["model": .string(model), "input": .string(text),
                                                     "voice": .string(voice), "response_format": .string(format)]
                    if let instructions, !instructions.isEmpty { o["instructions"] = .string(instructions) }
                    if let speed { o["speed"] = .number(speed) }
                    let r = try await request("/v1/audio/speech", method: "POST",
                                              body: Data(RealtimeJSON.object(o).jsonText.utf8), timeout: firstByteDeadline,
                                              purpose: purpose)
                    let (response, bytes): (HTTPURLResponse, AsyncThrowingStream<Data, Error>)
                    do {
                        let stream = transport.stream
                        let s = try await withDeadline(firstByteDeadline) { try await stream(r) }
                        (response, bytes) = (s.response, s.body)
                    } catch {
                        throw CompatError.transport(HTTPFailure.classify(error))
                    }
                    let type = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                    if response.statusCode >= 300 || type.contains("json") || type.hasPrefix("text/") {
                        var body = Data()
                        do { for try await c in bytes { body.append(c); if body.count > 8192 { break } } } catch {}
                        try Self.check(response, body: body)
                        throw CompatError.notCompatible
                    }
                    do {
                        for try await c in bytes { continuation.yield(c) }
                    } catch {
                        throw CompatError.transport(HTTPFailure.classify(error))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Vendor routes

    /// Raw JSON of a GET/POST on a native route; nil on any failure (fingerprinting only).
    func nativeJSON(_ path: String, method: String = "GET", body: RealtimeJSON? = nil, deadline: Double = 3,
                    purpose: String = "probe") async -> (Int, RealtimeJSON?)? {
        guard let r = try? await request(path, method: method, body: body.map { Data($0.jsonText.utf8) }, timeout: deadline,
                                         purpose: purpose) else { return nil }
        let fetch = transport.fetch
        guard let (data, response) = try? await withDeadline(deadline, { try await fetch(r) }),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, RealtimeJSON.parse(String(decoding: data, as: UTF8.self)))
    }
}
