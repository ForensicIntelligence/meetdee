import Foundation
import Network
import CryptoKit
import Synchronization

// Offline OpenAI-compatible + Ollama-native + LM Studio-native HTTP server for tests and the
// harness (contract 0.6 §6). Network.framework only, bound to 127.0.0.1 on a free port.
// Never used by the app.

/// What a scripted chat answer looks like.
public struct MockChatReply: Sendable, Equatable {
    public var reasoning: [String] = []
    /// LM Studio puts reasoning in `delta.reasoning_content` instead of `delta.reasoning`.
    public var reasoningField = "reasoning"
    public var content: [String] = []
    public var toolCalls: [MockToolCall] = []
    /// Tool call arguments streamed in this many pieces (1 = one chunk, like Ollama/LMS).
    public var toolArgPieces = 1
    public var firstTokenDelay: Double = 0
    public var chunkDelay: Double = 0
    public var finishReason: String?
    /// The model id put in every chunk (nil: the requested one).
    public var model: String?
    /// HTTP status (≥ 400 sends an OpenAI-shape error body instead of a stream).
    public var status = 200
    public var errorMessage = "error"
    /// 200 with an `{"error":…}` JSON body (no stream).
    public var errorBodyWith200 = false
    public var promptTokens = 100
    public var cachedTokens = 0
    public var completionTokens = 20

    public init(content: [String] = [], reasoning: [String] = [], toolCalls: [MockToolCall] = [],
                firstTokenDelay: Double = 0, chunkDelay: Double = 0) {
        self.content = content; self.reasoning = reasoning; self.toolCalls = toolCalls
        self.firstTokenDelay = firstTokenDelay; self.chunkDelay = chunkDelay
    }

    public static func text(_ s: String, firstTokenDelay: Double = 0) -> MockChatReply {
        // Word-sized chunks, like a real server.
        var chunks: [String] = []
        var cur = ""
        for ch in s {
            cur.append(ch)
            if ch == " " { chunks.append(cur); cur = "" }
        }
        if !cur.isEmpty { chunks.append(cur) }
        return MockChatReply(content: chunks, firstTokenDelay: firstTokenDelay)
    }
}

public struct MockToolCall: Sendable, Equatable {
    public var id: String
    public var name: String
    public var arguments: String
    public init(id: String, name: String, arguments: String) { self.id = id; self.name = name; self.arguments = arguments }
}

/// One request the server saw.
public struct MockRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data
    public var at: Date

    /// Parsed JSON body (nil for multipart/empty).
    public var json: Any? { try? JSONSerialization.jsonObject(with: body) }
    public var jsonObject: [String: Any]? { json as? [String: Any] }
    public var authorization: String? { headers["authorization"] }
}

/// Behaviours (contract §6 list).
public enum MockCase: Sendable, Hashable {
    /// Ollama fingerprint: `/api/version`, `/api/show`, `/api/ps`, native `/api/chat`; unknown → 404 text.
    case ollama
    /// LM Studio fingerprint: `/api/v0/models`; unknown routes → **200** `{"error":…}`.
    case lmStudio
    /// `/v1/audio/transcriptions` works.
    case transcriptions
    /// `/v1/audio/speech` works (PCM16).
    case speech
    /// `/v1/realtime` completes a WebSocket upgrade and answers `session.update` with `session.created`/`updated`.
    case realtimeWS
    /// Every request needs `Authorization: Bearer <key>`, else 401.
    case requireKey(String)
    /// An unknown model id is answered by the loaded one (LM Studio).
    case modelFallback
    /// Every path answers 302 / 307 to a public host.
    case redirect302
    case redirect307
    /// Accepts the TCP connection and never answers.
    case hang
}

public final class DeeMockServer: @unchecked Sendable {
    public typealias ChatScript = @Sendable (_ request: MockRequest, _ index: Int) -> MockChatReply
    public typealias TranscribeScript = @Sendable (_ request: MockRequest) -> String
    public typealias RealtimeScript = @Sendable (_ clientEvent: [String: Any]) -> [[String: Any]]

    public let cases: Set<MockCase>
    public private(set) var baseURL: URL
    public var port: UInt16 { UInt16(baseURL.port ?? 0) }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dee.mockserver")
    private struct State {
        var requests: [MockRequest] = []
        var chatCount = 0
        var connections: [ObjectIdentifier: NWConnection] = [:]
        var models: [String]
        var loaded: String
        var chat: ChatScript
        var transcribe: TranscribeScript
        var realtime: RealtimeScript?
        var contextLength: Int
        var capabilities: [String]
        var wsMessages: [String] = []
        var greeting: [[String: Any]] = []
        var speechRate = 24_000
    }
    private let state: Mutex<State>

    /// Starts on 127.0.0.1 at a free port.
    public static func start(cases: Set<MockCase> = [.ollama], models: [String] = ["qwen3.8:27b-mlx-bf16"],
                             capabilities: [String] = ["completion", "tools", "thinking"],
                             contextLength: Int = 262_144,
                             chat: ChatScript? = nil) async throws -> DeeMockServer {
        let s = try DeeMockServer(cases: cases, models: models, capabilities: capabilities, contextLength: contextLength,
                                  chat: chat ?? { _, _ in .text("Hello there! How are you today?") })
        try await s.begin()
        return s
    }

    private init(cases: Set<MockCase>, models: [String], capabilities: [String], contextLength: Int,
                 chat: @escaping ChatScript) throws {
        self.cases = cases
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params)
        state = Mutex(State(models: models, loaded: models.first ?? "", chat: chat,
                            transcribe: { _ in "hello dee" }, realtime: nil, contextLength: contextLength,
                            capabilities: capabilities))
        baseURL = URL(string: "http://127.0.0.1:0")!
    }

    private func begin() async throws {
        let ready = Mutex<CheckedContinuation<Void, Error>?>(nil)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            ready.withLock { $0 = c }
            listener.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready:
                    if let p = self?.listener.port?.rawValue { self?.baseURL = URL(string: "http://127.0.0.1:\(p)")! }
                    ready.withLock { $0?.resume(); $0 = nil }
                case .failed(let e):
                    ready.withLock { $0?.resume(throwing: e); $0 = nil }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.cancel()
        let conns = state.withLock { s -> [NWConnection] in
            defer { s.connections.removeAll() }
            return Array(s.connections.values)
        }
        conns.forEach { $0.cancel() }
    }

    deinit { listener.cancel() }

    // MARK: Scripting

    public var requests: [MockRequest] { state.withLock { $0.requests } }
    public func requests(path: String) -> [MockRequest] { requests.filter { $0.path == path } }
    public func clearRequests() { state.withLock { $0.requests.removeAll() } }
    public func setChat(_ script: @escaping ChatScript) { state.withLock { $0.chat = script; $0.chatCount = 0 } }
    public func setTranscribe(_ script: @escaping TranscribeScript) { state.withLock { $0.transcribe = script } }
    public func setRealtime(_ script: @escaping RealtimeScript) { state.withLock { $0.realtime = script } }
    public func setModels(_ models: [String], loaded: String? = nil) {
        state.withLock { $0.models = models; $0.loaded = loaded ?? models.first ?? "" }
    }
    /// Events sent as soon as a `/v1/realtime` socket opens (a transcription session's `session.created`).
    public func setRealtimeGreeting(_ events: [[String: Any]]) {
        let boxed = events.map { UncheckedDict($0) }
        state.withLock { $0.greeting = boxed.map(\.value) }
    }
    /// Sample rate of `/v1/audio/speech` WAV answers (PCM answers are always 24 kHz).
    public func setSpeechRate(_ rate: Int) { state.withLock { $0.speechRate = rate } }
    /// Text frames received on `/v1/realtime`.
    public var realtimeMessages: [String] { state.withLock { $0.wsMessages } }

    // MARK: Connections

    private func accept(_ conn: NWConnection) {
        state.withLock { $0.connections[ObjectIdentifier(conn)] = conn }
        conn.stateUpdateHandler = { [weak self, weak conn] st in
            if case .cancelled = st, let conn { _ = self?.state.withLock { $0.connections.removeValue(forKey: ObjectIdentifier(conn)) } }
            if case .failed = st { conn?.cancel() }
        }
        conn.start(queue: queue)
        if cases.contains(.hang) { return }
        readRequest(conn, buffer: Data())
    }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                self.handle(req, on: conn)
            } else if complete || error != nil {
                conn.cancel()
            } else {
                self.readRequest(conn, buffer: buf)
            }
        }
    }

    /// A whole request (headers + Content-Length body), or nil if more bytes are needed.
    static func parse(_ data: Data) -> MockRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        let body = data[bodyStart..<(bodyStart + length)]
        var path = String(first[1])
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }
        return MockRequest(method: String(first[0]), path: path, headers: headers, body: Data(body), at: Date())
    }

    // MARK: Routing

    private func handle(_ req: MockRequest, on conn: NWConnection) {
        state.withLock { $0.requests.append(req) }
        if cases.contains(.redirect302) || cases.contains(.redirect307) {
            let code = cases.contains(.redirect302) ? "302 Found" : "307 Temporary Redirect"
            send(conn, status: code, headers: ["Location": "https://evil.example.com\(req.path)"], body: Data())
            return
        }
        if let key = cases.compactMap({ if case .requireKey(let k) = $0 { k } else { nil } }).first,
           req.authorization != "Bearer \(key)" {
            json(conn, status: 401, ["error": ["message": "Incorrect API key provided", "type": "invalid_request_error",
                                               "code": "invalid_api_key"]])
            return
        }
        switch (req.method, req.path) {
        case ("GET", "/v1/models"):
            let models = state.withLock { $0.models }
            json(conn, status: 200, ["object": "list", "data": models.map { ["id": $0, "object": "model", "owned_by": "library"] }])
        case ("POST", "/v1/chat/completions"):
            chat(req, conn, native: false)
        case ("POST", "/api/chat") where cases.contains(.ollama):
            chat(req, conn, native: true)
        case ("GET", "/api/version") where cases.contains(.ollama):
            json(conn, status: 200, ["version": "0.35.1"])
        case ("POST", "/api/show") where cases.contains(.ollama):
            let (caps, ctx, models) = state.withLock { ($0.capabilities, $0.contextLength, $0.models) }
            let name = (req.jsonObject?["model"] as? String) ?? (req.jsonObject?["name"] as? String) ?? ""
            if !models.contains(name) {
                json(conn, status: 404, ["error": "model '\(name)' not found"])
            } else {
                json(conn, status: 200, ["capabilities": caps, "model_info": ["general.architecture": "qwen3",
                                                                               "qwen3.context_length": ctx]])
            }
        case ("GET", "/api/ps") where cases.contains(.ollama):
            let (loaded, ctx) = state.withLock { ($0.loaded, $0.contextLength) }
            json(conn, status: 200, ["models": [["name": loaded, "model": loaded, "context_length": min(ctx, 32_768)]]])
        case ("GET", "/api/v0/models") where cases.contains(.lmStudio):
            let (models, loaded, ctx) = state.withLock { ($0.models, $0.loaded, $0.contextLength) }
            json(conn, status: 200, ["object": "list", "data": models.map {
                ["id": $0, "object": "model", "type": "llm", "state": $0 == loaded ? "loaded" : "not-loaded",
                 "capabilities": ["tool_use"], "max_context_length": ctx] as [String: Any]
            }])
        case ("POST", "/v1/audio/transcriptions") where cases.contains(.transcriptions):
            let t = state.withLock { $0.transcribe }(req)
            json(conn, status: 200, ["text": t])
        case ("POST", "/v1/audio/speech") where cases.contains(.speech):
            speech(req, conn)
        case ("GET", "/v1/realtime") where cases.contains(.realtimeWS):
            upgrade(req, conn)
        default:
            unknown(req, conn)
        }
    }

    private func unknown(_ req: MockRequest, _ conn: NWConnection) {
        if cases.contains(.lmStudio) {
            json(conn, status: 200, ["error": "Unexpected endpoint or method. (\(req.method) \(req.path))"])
        } else if cases.contains(.ollama) {
            send(conn, status: "404 Not Found", headers: ["Content-Type": "text/plain"], body: Data("404 page not found".utf8))
        } else {
            json(conn, status: 404, ["error": ["message": "not found", "type": "invalid_request_error"]])
        }
    }

    // MARK: Chat

    private func chat(_ req: MockRequest, _ conn: NWConnection, native: Bool) {
        let body = req.jsonObject ?? [:]
        let asked = body["model"] as? String ?? ""
        let (script, index, models, loaded) = state.withLock { s -> (ChatScript, Int, [String], String) in
            s.chatCount += 1
            return (s.chat, s.chatCount - 1, s.models, s.loaded)
        }
        var reply = script(req, index)
        if !models.contains(asked) {
            if cases.contains(.modelFallback) {
                reply.model = reply.model ?? loaded
            } else {
                let msg = "model '\(asked)' not found"
                if native { json(conn, status: 404, ["error": msg]) } else {
                    json(conn, status: 404, ["error": ["message": msg, "type": "not_found_error", "param": NSNull(), "code": NSNull()]])
                }
                return
            }
        }
        if reply.status >= 400 {
            json(conn, status: reply.status, ["error": ["message": reply.errorMessage, "type": "server_error", "code": NSNull()]])
            return
        }
        if reply.errorBodyWith200 {
            json(conn, status: 200, ["error": ["message": reply.errorMessage, "type": "invalid_request", "code": "bad"]])
            return
        }
        let model = reply.model ?? asked
        let stream = (body["stream"] as? Bool) ?? false
        var events: [Data] = []
        let id = "chatcmpl-\(index)"
        func sse(_ o: [String: Any]) -> Data {
            Data(("data: " + String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self) + "\n\n").utf8)
        }
        func nd(_ o: [String: Any]) -> Data {
            Data((String(decoding: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), as: UTF8.self) + "\n").utf8)
        }
        func chunk(_ delta: [String: Any], finish: String? = nil) -> [String: Any] {
            ["id": id, "object": "chat.completion.chunk", "model": model,
             "choices": [["index": 0, "delta": delta, "finish_reason": finish as Any? ?? NSNull()]]]
        }
        let finish = reply.finishReason ?? (reply.toolCalls.isEmpty ? "stop" : "tool_calls")
        if native {
            for r in reply.reasoning { events.append(nd(["model": model, "message": ["role": "assistant", "content": "", "thinking": r], "done": false])) }
            for c in reply.content { events.append(nd(["model": model, "message": ["role": "assistant", "content": c], "done": false])) }
            if !reply.toolCalls.isEmpty {
                let calls: [[String: Any]] = reply.toolCalls.map { call in
                    ["function": ["name": call.name,
                                  "arguments": (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) ?? [:]]]
                }
                events.append(nd(["model": model, "message": ["role": "assistant", "content": "", "tool_calls": calls], "done": false]))
            }
            events.append(nd(["model": model, "message": ["role": "assistant", "content": ""], "done": true,
                              "done_reason": "stop", "prompt_eval_count": reply.promptTokens, "eval_count": reply.completionTokens]))
        } else if stream {
            events.append(sse(chunk(["role": "assistant", "content": ""])))
            for r in reply.reasoning { events.append(sse(chunk([reply.reasoningField: r]))) }
            for c in reply.content { events.append(sse(chunk(["content": c]))) }
            for (i, call) in reply.toolCalls.enumerated() {
                let pieces = max(1, reply.toolArgPieces)
                let args = Array(call.arguments)
                let size = max(1, Int((Double(args.count) / Double(pieces)).rounded(.up)))
                var parts: [String] = stride(from: 0, to: args.count, by: size).map { String(args[$0..<min($0 + size, args.count)]) }
                if parts.isEmpty { parts = [""] }
                for (j, part) in parts.enumerated() {
                    var f: [String: Any] = ["arguments": part]
                    var tc: [String: Any] = ["index": i]
                    if j == 0 { f["name"] = call.name; tc["id"] = call.id; tc["type"] = "function" }
                    tc["function"] = f
                    events.append(sse(chunk(["tool_calls": [tc]])))
                }
            }
            events.append(sse(chunk([:], finish: finish)))
            events.append(sse(["id": id, "object": "chat.completion.chunk", "model": model, "choices": [] as [Any],
                               "usage": ["prompt_tokens": reply.promptTokens, "completion_tokens": reply.completionTokens,
                                         "total_tokens": reply.promptTokens + reply.completionTokens,
                                         "prompt_tokens_details": ["cached_tokens": reply.cachedTokens]]]))
            events.append(Data("data: [DONE]\n\n".utf8))
        } else {
            let text = reply.content.joined()
            json(conn, status: 200, ["id": id, "object": "chat.completion", "model": model,
                                     "choices": [["index": 0, "message": ["role": "assistant", "content": text],
                                                  "finish_reason": finish]],
                                     "usage": ["prompt_tokens": reply.promptTokens, "completion_tokens": reply.completionTokens]])
            return
        }
        let type = native ? "application/x-ndjson" : "text/event-stream"
        streamOut(conn, contentType: type, events: events, first: reply.firstTokenDelay, gap: reply.chunkDelay)
    }

    // MARK: Speech

    private func speech(_ req: MockRequest, _ conn: NWConnection) {
        let text = (req.jsonObject?["input"] as? String) ?? ""
        let fmt = (req.jsonObject?["response_format"] as? String) ?? "mp3"
        guard fmt == "pcm" || fmt == "wav" else {
            json(conn, status: 400, ["error": ["message": "unsupported format", "type": "invalid_request_error"]])
            return
        }
        // 60 ms of PCM16 per character, a quiet 220 Hz tone (never silence: tests check levels).
        let rate = fmt == "wav" ? state.withLock { $0.speechRate } : 24_000
        let frames = max(rate / 10, text.count * rate * 60 / 1000)
        var pcm = Data(capacity: frames * 2 + 44)
        if fmt == "wav" {
            func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) } }
            func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) } }
            pcm.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + frames * 2)); pcm.append(contentsOf: Array("WAVE".utf8))
            pcm.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
            pcm.append(contentsOf: Array("data".utf8)); u32(UInt32(frames * 2))
        }
        for i in 0..<frames {
            let v = Int16(3000 * sin(Double(i) * 2 * .pi * 220 / Double(rate)))
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var events: [Data] = []
        var at = 0
        while at < pcm.count { let n = min(9600, pcm.count - at); events.append(pcm.subdata(in: at..<(at + n))); at += n }
        streamOut(conn, contentType: fmt == "wav" ? "audio/wav" : "audio/pcm", events: events, first: 0, gap: 0.005)
    }

    // MARK: Output

    private func streamOut(_ conn: NWConnection, contentType: String, events: [Data], first: Double, gap: Double) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        func step(_ i: Int) {
            guard i < events.count else {
                conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            conn.send(content: events[i], completion: .contentProcessed { [weak self] error in
                guard error == nil, let self else { conn.cancel(); return }
                self.queue.asyncAfter(deadline: .now() + gap) { step(i + 1) }
            })
        }
        queue.asyncAfter(deadline: .now() + first) { step(0) }
    }

    private func json(_ conn: NWConnection, status: Int, _ object: Any) {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        send(conn, status: "\(status) \(Self.reason(status))", headers: ["Content-Type": "application/json"], body: body)
    }

    private func send(_ conn: NWConnection, status: String, headers: [String: String], body: Data) {
        var head = "HTTP/1.1 \(status)\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        conn.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
    }

    static func reason(_ s: Int) -> String {
        switch s {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }

    // MARK: WebSocket (/v1/realtime)

    private func upgrade(_ req: MockRequest, _ conn: NWConnection) {
        guard req.headers["upgrade"]?.lowercased() == "websocket", let key = req.headers["sec-websocket-key"] else {
            json(conn, status: 400, ["error": ["message": "websocket required", "type": "invalid_request_error"]])
            return
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        for g in state.withLock({ $0.greeting }) {
            let d = (try? JSONSerialization.data(withJSONObject: g)) ?? Data()
            conn.send(content: Self.encodeFrame(opcode: 0x1, d), completion: .contentProcessed { _ in })
        }
        readFrames(conn, buffer: Data())
    }

    private func readFrames(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            while let (opcode, payload, used) = Self.frame(buf) {
                buf = Data(buf.dropFirst(used))
                switch opcode {
                case 0x1: self.realtimeText(String(decoding: payload, as: UTF8.self), conn)
                case 0x8: conn.send(content: Self.encodeFrame(opcode: 0x8, Data([0x03, 0xE8])), completion: .contentProcessed { _ in conn.cancel() }); return
                case 0x9: conn.send(content: Self.encodeFrame(opcode: 0xA, payload), completion: .contentProcessed { _ in })
                default: break
                }
            }
            if complete || error != nil { conn.cancel(); return }
            self.readFrames(conn, buffer: buf)
        }
    }

    private func realtimeText(_ text: String, _ conn: NWConnection) {
        state.withLock { $0.wsMessages.append(text) }
        guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        var replies: [[String: Any]] = []
        if let script = state.withLock({ $0.realtime }) {
            replies = script(o)
        } else if (o["type"] as? String) == "session.update" {
            var session = (o["session"] as? [String: Any]) ?? [:]
            session["id"] = "sess_mock"
            let first = state.withLock { s in s.wsMessages.filter { $0.contains("\"session.update\"") }.count == 1 }
            if first { replies.append(["type": "session.created", "event_id": "ev_c", "session": session]) }
            replies.append(["type": "session.updated", "event_id": "ev_u", "session": session])
        }
        for r in replies {
            let d = (try? JSONSerialization.data(withJSONObject: r)) ?? Data()
            conn.send(content: Self.encodeFrame(opcode: 0x1, d), completion: .contentProcessed { _ in })
        }
    }

    /// One client frame (masked), or nil if incomplete.
    static func frame(_ b: Data) -> (UInt8, Data, Int)? {
        let bytes = [UInt8](b)
        guard bytes.count >= 2 else { return nil }
        let opcode = bytes[0] & 0x0F
        let masked = bytes[1] & 0x80 != 0
        var len = Int(bytes[1] & 0x7F)
        var i = 2
        if len == 126 {
            guard bytes.count >= 4 else { return nil }
            len = Int(bytes[2]) << 8 | Int(bytes[3]); i = 4
        } else if len == 127 {
            guard bytes.count >= 10 else { return nil }
            len = 0
            for k in 2..<10 { len = len << 8 | Int(bytes[k]) }
            i = 10
        }
        var mask: [UInt8] = [0, 0, 0, 0]
        if masked {
            guard bytes.count >= i + 4 else { return nil }
            mask = Array(bytes[i..<(i + 4)]); i += 4
        }
        guard bytes.count >= i + len else { return nil }
        var payload = Array(bytes[i..<(i + len)])
        if masked { for k in 0..<payload.count { payload[k] ^= mask[k % 4] } }
        return (opcode, Data(payload), i + len)
    }

    static func encodeFrame(opcode: UInt8, _ payload: Data) -> Data {
        var out = Data([0x80 | opcode])
        if payload.count < 126 {
            out.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            out.append(126); out.append(UInt8(payload.count >> 8)); out.append(UInt8(payload.count & 0xFF))
        } else {
            out.append(127)
            for k in (0..<8).reversed() { out.append(UInt8((payload.count >> (k * 8)) & 0xFF)) }
        }
        out.append(payload)
        return out
    }
}

/// `[String: Any]` crossing into the server's lock (JSON values only).
struct UncheckedDict: @unchecked Sendable { let value: [String: Any]; init(_ v: [String: Any]) { value = v } }
