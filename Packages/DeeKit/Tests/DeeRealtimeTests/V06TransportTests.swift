import Foundation
import Network
import Synchronization
import Testing
@testable import DeeRealtime

// v0.6 (docs/contracts-0.6/providers-wake-onboarding.md): the one recorded
// transport (X1), redirect refusal (N1), keys (K1), OpenAI auth by type, the
// transcription mint, timing profiles, reconfigure / resume.

/// A tiny loopback HTTP/1.1 server (Network.framework) for the live client.
final class LoopbackHTTP: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback.http")
    private let hits = Mutex<[String]>([])
    private(set) var port: UInt16 = 0
    /// path → raw response bytes (sent in parts, `gap` seconds apart).
    typealias Route = @Sendable (_ port: UInt16) -> [Data]
    private let routes: [String: Route]
    private let gap: Double

    init(routes: [String: Route], gap: Double = 0.25) async throws {
        self.routes = routes
        self.gap = gap
        listener = try NWListener(using: .tcp, on: .any)
        let l = listener
        let ready = Mutex<CheckedContinuation<UInt16, Error>?>(nil)
        l.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        let p: UInt16 = try await withCheckedThrowingContinuation { c in
            ready.withLock { $0 = c }
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: ready.withLock { $0.take() }?.resume(returning: l.port?.rawValue ?? 0)
                case .failed(let e): ready.withLock { $0.take() }?.resume(throwing: e)
                default: break
                }
            }
            l.start(queue: queue)
        }
        port = p
    }

    deinit { listener.cancel() }

    var paths: [String] { hits.withLock { $0 } }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self, let data, let head = String(data: data, encoding: .utf8) else { conn.cancel(); return }
            let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            self.hits.withLock { $0.append(path) }
            let parts = self.routes[path]?(self.port) ?? [Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)]
            self.send(parts, on: conn)
        }
    }

    private func send(_ parts: [Data], on conn: NWConnection) {
        guard let first = parts.first else { conn.cancel(); return }
        conn.send(content: first, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            if parts.count == 1 {
                conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in conn.cancel() })
            } else {
                self.queue.asyncAfter(deadline: .now() + self.gap) { self.send(Array(parts.dropFirst()), on: conn) }
            }
        })
    }

    static func text(_ status: String, _ body: String, headers: [String] = []) -> Data {
        let h = (["HTTP/1.1 \(status)", "Content-Length: \(body.utf8.count)", "Connection: close"] + headers).joined(separator: "\r\n")
        return Data((h + "\r\n\r\n" + body).utf8)
    }
}

@Suite struct V06TransportTests {
    // MARK: X1 recorder

    @Test func theRecorderSeesEveryCallWithoutHeadersBodiesOrQueries() async throws {
        let recorder = TransportRecorder()
        let seen = Mutex<[URLRequest]>([])
        let t = Transport(recorder: recorder, fetch: { req in
            seen.withLock { $0.append(req) }
            return (Data("ok".utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, socketFactory: { FakeSocket(request: $0) })
        var r = URLRequest(url: URL(string: "https://api.openai.com/v1/models?key=sk-secret#frag")!)
        r.setValue("Bearer sk-proj-SECRET", forHTTPHeaderField: "Authorization")
        r.setValue("models", forHTTPHeaderField: Transport.purposeHeader)
        _ = try await t.fetch(r)
        let streamed = try await t.stream(URLRequest(url: URL(string: "http://192.168.1.20:11434/v1/chat/completions")!))
        var body = Data()
        for try await d in streamed.body { body.append(d) }
        #expect(body == Data("ok".utf8))       // a fetch-only transport streams the whole body once
        _ = t.socketFactory(URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime?model=m")!))

        let rec = recorder.records
        #expect(rec.map(\.kind) == [.http, .stream, .webSocket])
        #expect(rec[0] == TransportRecord(kind: .http, method: "GET", scheme: "https", host: "api.openai.com", port: nil,
                                          path: "/v1/models", purpose: "models"))
        #expect(rec[1].host == "192.168.1.20" && rec[1].port == 11434 && !rec[1].isOpenAI)
        #expect(rec[2].isOpenAI && rec[2].path == "/v1/realtime")
        // Nothing in a record can hold a key or words.
        #expect(!"\(rec)".contains("sk-"))
        #expect(!"\(rec)".contains("frag"))
        // The purpose label never leaves the phone.
        #expect(seen.withLock { $0 }.allSatisfy { $0.value(forHTTPHeaderField: Transport.purposeHeader) == nil })
        #expect(recorder.hosts() == ["api.openai.com", "192.168.1.20"])
    }

    @Test func aFailingTransportRecordsThenFails() async {
        let t = Transport.failing()
        await #expect(throws: URLError.self) { _ = try await t.fetch(URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)) }
        let s = t.socketFactory(URLRequest(url: URL(string: "wss://api.openai.com/v1/realtime")!))
        await #expect(throws: SocketFailure.self) { try await s.open() }
        #expect(t.recorder.count == 2)
    }

    // MARK: N1 redirects

    @Test func redirectPolicies() {
        let a = URL(string: "https://api.openai.com/v1/x")!
        #expect(RedirectPolicy.sameHost.allows(from: a, to: URL(string: "https://api.openai.com/v1/y")!))
        #expect(!RedirectPolicy.sameHost.allows(from: a, to: URL(string: "https://evil.example.com/v1/y")!))
        #expect(!RedirectPolicy.sameHost.allows(from: a, to: URL(string: "http://api.openai.com/v1/y")!))
        #expect(!RedirectPolicy.refuse.allows(from: a, to: a))
    }

    @Test func aLANClientNeverFollowsARedirect() async throws {
        let server = try await LoopbackHTTP(routes: [
            "/v1/models": { port in [LoopbackHTTP.text("302 Found", "", headers: ["Location: http://127.0.0.1:\(port)/landing"])] },
            "/landing": { _ in [LoopbackHTTP.text("200 OK", "landed")] },
        ])
        let lan = Transport.live(redirects: .refuse)
        let (_, response) = try await lan.fetch(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/v1/models")!))
        #expect((response as? HTTPURLResponse)?.statusCode == 302)
        // Streams too.
        let streamed = try await lan.stream(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/v1/models")!))
        #expect(streamed.response.statusCode == 302)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!server.paths.contains("/landing"))

        // An OpenAI-style client follows the same host only.
        let openAI = Transport.live(redirects: .sameHost)
        let (body, ok) = try await openAI.fetch(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/v1/models")!))
        #expect((ok as? HTTPURLResponse)?.statusCode == 200 && body == Data("landed".utf8))
    }

    @Test func aStreamArrivesInPiecesAsTheServerSendsThem() async throws {
        let server = try await LoopbackHTTP(routes: [
            "/sse": { _ in [Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\ndata: one\n\n".utf8),
                            Data("data: two\n\n".utf8)] },
        ], gap: 0.3)
        let t = Transport.live(redirects: .refuse)
        let r = try await t.stream(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/sse")!))
        #expect(r.response.statusCode == 200)
        var pieces: [(Data, ContinuousClock.Instant)] = []
        for try await d in r.body { pieces.append((d, .now)) }
        #expect(String(decoding: pieces.map(\.0).reduce(Data(), +), as: UTF8.self) == "data: one\n\ndata: two\n\n")
        #expect(pieces.count >= 2)
        if pieces.count >= 2 { #expect(pieces.last!.1 - pieces.first!.1 > .milliseconds(150)) }
    }

    @Test func aRefusedPortFailsAtOnce() async throws {
        let t = Transport.live(redirects: .refuse, requestTimeout: 3)
        let start = ContinuousClock.now
        await #expect(throws: (any Error).self) { _ = try await t.fetch(URLRequest(url: URL(string: "http://127.0.0.1:9/v1/models")!)) }
        await #expect(throws: (any Error).self) { _ = try await t.stream(URLRequest(url: URL(string: "http://127.0.0.1:9/v1/models")!)) }
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    // MARK: X1 guard

    /// No `URLSession(` / `URLSession.shared` in DeeRealtime or DeeVoice outside
    /// `DeeRealtime/Transport*.swift`: every connection goes through the recorder.
    @Test func noURLSessionOutsideTheTransport() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        var offenders: [String] = []
        for module in ["DeeRealtime", "DeeVoice"] {
            let dir = sources.appendingPathComponent(module)
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
                if module == "DeeRealtime", name.hasPrefix("Transport") { continue }
                let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
                let code = text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .joined(separator: "\n")
                if code.contains("URLSession(") || code.contains("URLSession.shared") || code.contains(".webSocketTask(") {
                    offenders.append("\(module)/\(name)")
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}

@Suite struct V06KeyAndAuthTests {
    static let key = "sk-proj-" + String(repeating: "k", count: 40)

    final class Server: @unchecked Sendable {
        let requests = Mutex<[URLRequest]>([])
        let status: Int
        let body: String
        init(status: Int, body: String) { self.status = status; self.body = body }
        var transport: HTTPFetch {
            { [self] req in
                requests.withLock { $0.append(req) }
                return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
        var bodies: [RealtimeJSON] { requests.withLock { $0 }.compactMap { $0.httpBody.flatMap { try? JSONDecoder().decode(RealtimeJSON.self, from: $0) } } }
    }

    func store() throws -> KeyStore {
        let s = KeyStore(storage: MemorySecretStorage())
        try s.save(Self.key)
        return s
    }

    @Test func opaqueKeysForLANServers() throws {
        let lan = KeyStore(account: KeyStore.lanAccount("brain"), kind: .opaque, storage: MemorySecretStorage())
        #expect(lan.account == "lan.brain.key")
        #expect(try lan.save("  my-ollama-token\n") == "my-ollama-token")
        #expect(throws: KeyStoreError.invalidKey) { try lan.save("two words") }
        #expect(throws: KeyStoreError.invalidKey) { try lan.save("   ") }
        // The OpenAI account still demands an sk- key.
        #expect(throws: KeyStoreError.invalidKey) { try KeyStore(storage: MemorySecretStorage()).save("my-ollama-token") }
    }

    @Test func theMintOnlyEverGoesToOpenAI() async throws {
        let server = Server(status: 200, body: #"{"value":"ek_1","expires_at":1756310470}"#)
        let auth = OpenAIAuth(keyStore: try store(), transport: server.transport)
        _ = try await auth.credential(model: "gpt-realtime-2.1-mini")
        let req = try #require(server.requests.withLock { $0.first })
        #expect(req.url == URL(string: "https://api.openai.com/v1/realtime/client_secrets")!)
        #expect(req.value(forHTTPHeaderField: Transport.purposeHeader) == "mint")
        #expect(server.bodies.first?["session"]?["type"]?.stringValue == "realtime")
        #expect(await auth.sessionType == .realtime)
    }

    @Test func aTranscriptionMintCarriesTheProbedSession() async throws {
        let server = Server(status: 200, body: #"{"value":"ek_t","expires_at":1756310470}"#)
        var session = OpenAITranscription.Session()
        session.keywords = ["Dee", "Hey <Robo>"]
        let auth = OpenAIAuth(keyStore: try store(), sessionType: .transcription, mint: false, transcription: session,
                              transport: server.transport)
        let c = try await auth.credential(model: "ignored")
        #expect(c.isEphemeral && c.bearer == "ek_t")         // always minted, even with mint: false
        let s = try #require(server.bodies.first?["session"])
        #expect(s["type"]?.stringValue == "transcription")
        let input = try #require(s["audio"]?["input"])
        #expect(input["transcription"]?["model"]?.stringValue == "gpt-transcribe")
        #expect(input["transcription"]?["keywords"] == .array(["Dee", "Hey  Robo"]))
        #expect(input["turn_detection"] == ["type": "server_vad", "threshold": 0.5, "prefix_padding_ms": 300, "silence_duration_ms": 300])
        #expect(input["format"] == ["type": "audio/pcm", "rate": 24000])
        #expect(OpenAITranscription.url.absoluteString == "wss://api.openai.com/v1/realtime?intent=transcription")
    }

    @Test(arguments: [400, 404, 405, 501])
    func aRefusedTranscriptionMintIsAHardProblemNeverTheKeyItself(status: Int) async throws {
        let server = Server(status: status, body: #"{"error":{"code":"nope"}}"#)
        let auth = OpenAIAuth(keyStore: try store(), sessionType: .transcription, transport: server.transport)
        await #expect(throws: RealtimeAuthError.transcriptionUnavailable(status: status)) {
            try await auth.credential(model: "m")
        }
        // A realtime auth still falls back to the key on the same answer (v0.5 behaviour).
        let rt = OpenAIAuth(keyStore: try store(), transport: server.transport)
        #expect(try await rt.credential(model: "m") == .direct(Self.key))
    }

    @Test func aTranscriptionMintNeverFallsBackOnNetworkTrouble() async throws {
        let auth = OpenAIAuth(keyStore: try store(), sessionType: .transcription,
                              transport: { _ in throw URLError(.timedOut) })
        await #expect(throws: URLError.self) { try await auth.credential(model: "m") }
        #expect(RealtimeSession.map(RealtimeAuthError.transcriptionUnavailable(status: 404))
                == .unauthorized("OpenAI hearing isn't available for this key (HTTP 404)"))
    }
}

@Suite struct V06TimingProfileTests {
    @Test func realtimeIsTodaysValuesExactly() throws {
        let today = RealtimeSessionConfig()
        var applied = RealtimeSessionConfig()
        TimingProfile.realtime.apply(to: &applied)
        #expect(applied == today)
        #expect(TimingProfile.realtime.stallRetry && !TimingProfile.realtime.slowClipOncePerWindow)
        #expect(TimingProfile.realtime.wordWaitScale == 1)
        // Pinned values (a change here changes mode 1).
        #expect([today.responseTimeout, today.firstAudioTimeout, today.cancelUnstartedWait] == [10, 6, 2.5])
        #expect([today.rolloverAfter, today.forceRolloverAfter] == [3000, 3540])
        // The bytes of session.update are unchanged by the profile.
        let a = try ClientEvent.sessionUpdate(applied.sessionPayload(), eventID: "x").jsonText()
        let b = try ClientEvent.sessionUpdate(today.sessionPayload(), eventID: "x").jsonText()
        #expect(RealtimeJSON.parse(a) == RealtimeJSON.parse(b) && RealtimeJSON.parse(a) != nil)
    }

    @Test func cascadedWaitsForASlowLANModelAndNeverRollsOver() {
        let p = TimingProfile.cascaded(stt: .lanREST)
        var c = RealtimeSessionConfig()
        p.apply(to: &c)
        #expect(c.responseTimeout == 90 && c.firstAudioTimeout == 90)
        #expect(c.rolloverAfter == .infinity && c.forceRolloverAfter == .infinity)
        #expect(!p.stallRetry && p.slowClipOncePerWindow)
        #expect(p.wordWaitScale > TimingProfile.cascaded(stt: .onDevice).wordWaitScale)
        #expect(TimingProfile.lanRealtime.rolloverAfter == .infinity)
        #expect(TimingProfile.lanRealtime.firstAudioTimeout == TimingProfile.realtime.firstAudioTimeout)
    }

    @Test func providerLabels() {
        #expect(ProviderLabel.openAI.spokenName == "OpenAI")
        #expect(ProviderLabel.lan(host: "studio.local").spokenName == "the AI server at studio.local")
        #expect(ProviderLabel.onDevice.name == "this iPhone")
    }

    @Test func uplinkActivityIsPositionedOnTheFeedStream() {
        let a = UplinkActivity()
        a.record(frames: 960, voice: false)
        a.record(frames: 960, voice: true)
        a.record(frames: 960, voice: true)
        #expect(a.voiceActive(atFedFrame: 0) == false)
        #expect(a.voiceActive(atFedFrame: 1000) == true)
        #expect(a.voiceActive(atFedFrame: 2879) == true)
        #expect(a.voiceActive(atFedFrame: 2880) == nil)
        #expect(a.voiceNow && a.latestFedFrame == 2880)
    }
}

@Suite struct V06SessionTests {
    @Test func reconfigureOnlyWhileNothingIsOpen() async throws {
        let h = try await Harness.connected()
        var c = Harness.defaultConfig()
        c.model = "lan-model"
        #expect(await h.session.reconfigure(c) == false)
        #expect(await h.session.config.model != "lan-model")
        await h.session.close()
        #expect(await h.session.reconfigure(c))
        try await h.session.connect()
        #expect(h.factory.requests.last?.url?.absoluteString.contains("model=lan-model") == true)
    }

    @Test func aResumedWindowStartsWithTheSeedAndAFreshOneDoesNot() async throws {
        let h = try await Harness.connected()
        _ = await h.session.addUserText("My name is Tomas.")
        await h.session.close()
        try await h.session.connect(resume: true)
        let resumed = h.socket.sentTypes
        #expect(resumed.prefix(2) == ["session.update", "conversation.item.create"], "\(resumed)")
        #expect(h.socket.sent.dropFirst().first?.contains("Tomas") == true)
        #expect(h.socket.sent.dropFirst().first?.contains("The conversation continues") == true)

        await h.session.close()
        try await h.session.connect(resume: false)
        #expect(h.socket.sentTypes == ["session.update"])

        // A new conversation after a long sleep: nothing left to seed.
        await h.session.close()
        await h.session.resetConversation()
        try await h.session.connect(resume: true)
        #expect(h.socket.sentTypes == ["session.update"])
    }

    @Test func aKeylessLANRealtimeServerGetsNoAuthorizationHeader() async throws {
        let h = Harness.make(credentials: { _ in .direct("") })
        try await h.session.connect()
        #expect(h.factory.requests.last?.value(forHTTPHeaderField: "Authorization") == nil)
        let k = Harness.make(credentials: { _ in .direct("lan-token") })
        try await k.session.connect()
        #expect(k.factory.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer lan-token")
    }

    @Test func aClosedSessionNeverReconnectsOrRollsOverHowEverLongItSleeps() async throws {
        let h = try await Harness.connected()
        await h.session.close()
        for _ in 0..<240 { h.clock.advance(by: 30) }       // two hours
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.factory.made.count == 1)
        #expect(await h.session.state == .idle)
    }

    @Test func aLANRealtimeSessionNeverRollsOver() async throws {
        var c = Harness.defaultConfig()
        TimingProfile.lanRealtime.apply(to: &c)
        let h = try await Harness.connected(config: c)
        for _ in 0..<150 { h.clock.advance(by: 60); await Task.yield() }   // 2.5 hours
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.factory.made.count == 1)
        // The same driving rolls a gpt-realtime session over (the check can see one).
        let rt = try await Harness.connected()
        for _ in 0..<150 { rt.clock.advance(by: 60); await Task.yield() }
        _ = await rt.factory.waitForSocket(count: 2, timeout: 2)
        #expect(rt.factory.made.count >= 2)
    }
}
