import Foundation
import Testing
import DeeRealtime
import DeeVoice
import DeeWake
@testable import DeeLocal
import DeeMockServer

@Suite(.serialized) struct ServerProbeTests {
    func probe(_ recorder: TransportRecorder = TransportRecorder()) -> ServerProbe {
        ServerProbe(transport: .live(redirects: .refuse, recorder: recorder))
    }

    @Test func ollamaCapabilitiesAndPicker() async throws {
        let server = try await DeeMockServer.start(cases: [.ollama], models: ["qwen3.8:27b-mlx-bf16", "nimble:latest"])
        defer { server.stop() }
        let caps = try await probe().probe(server.baseURL, key: nil, model: "qwen3.8:27b-mlx-bf16", checkRealtime: true).get()
        #expect(caps.vendor == .ollama)
        #expect(caps.chat)
        #expect(caps.tools)
        #expect(caps.loaded == true)
        #expect(caps.contextLength == 32_768)   // as loaded (/api/ps), not the 262k maximum
        #expect(!caps.realtime)                 // 404 text: not realtime
        #expect(!caps.transcriptions && !caps.speech)
        #expect(caps.models.count == 2)
        // /api/show gives the same capabilities to both here; the picker filters by them.
        #expect(caps.chatModels.map(\.id).contains("qwen3.8:27b-mlx-bf16"))
    }

    @Test func classifierModelFilteredFromPicker() {
        let nimble = ServerModel(id: "nimble:latest", capabilities: ["decision"])
        let qwen = ServerModel(id: "qwen3.8:27b", capabilities: ["completion", "tools", "thinking"])
        let embed = ServerModel(id: "text-embedding-nomic", kind: "embeddings")
        let caps = ServerCapabilities(models: [nimble, qwen, embed])
        #expect(caps.chatModels == [qwen])
        #expect(ServerModel(id: "plain").isChat)
    }

    /// LM Studio answers unknown routes 200 + {"error":…}: decided by body, not status.
    @Test func lmStudioUnknownRoutesAreNotCapabilities() async throws {
        let server = try await DeeMockServer.start(cases: [.lmStudio], models: ["qwen/qwen3.8-27b"])
        defer { server.stop() }
        let caps = try await probe().probe(server.baseURL, key: nil, model: "qwen/qwen3.8-27b").get()
        #expect(caps.vendor == .lmStudio)
        #expect(caps.tools)
        #expect(caps.loaded == true)
        #expect(!caps.realtime && !caps.transcriptions && !caps.speech)
    }

    @Test func audioAndRealtimeWhenOffered() async throws {
        let server = try await DeeMockServer.start(cases: [.transcriptions, .speech, .realtimeWS],
                                                   models: ["llama3", "whisper-1", "kokoro"])
        defer { server.stop() }
        let caps = try await probe().probe(server.baseURL, key: nil, model: "llama3").get()
        #expect(caps.transcriptions && caps.transcriptionModel == "whisper-1")
        #expect(caps.speech && caps.speechModel == "kokoro")
        #expect(caps.realtime)
        #expect(caps.vendor == .other)
    }

    @Test func failuresAreNamed() async throws {
        // Refused port.
        let refused = await probe().probe(URL(string: "http://127.0.0.1:9")!, key: nil)
        #expect(refused == .failure(.unreachable(host: "127.0.0.1:9", vendor: .other)))
        // 401.
        let keyed = try await DeeMockServer.start(cases: [.ollama, .requireKey("lan-secret")])
        defer { keyed.stop() }
        let host = "127.0.0.1:\(keyed.port)"
        #expect(await probe().probe(keyed.baseURL, key: nil) == .failure(.lanNeedsKey(host: host)))
        #expect(try await probe().probe(keyed.baseURL, key: "lan-secret", checkRealtime: false).get().chat)
        // Model missing.
        #expect(await probe().probe(keyed.baseURL, key: "lan-secret", model: "nope", checkRealtime: false)
                == .failure(.modelMissing(host: host, model: "nope")))
        // Redirects are never followed (a 302/307 to a public host is a problem, and nothing went there).
        for c in [MockCase.redirect302, .redirect307] {
            let r = try await DeeMockServer.start(cases: [c])
            let recorder = TransportRecorder()
            #expect(await probe(recorder).probe(r.baseURL, key: nil) == .failure(.redirected(host: "127.0.0.1:\(r.port)")))
            #expect(!recorder.hosts().contains("evil.example.com"))
            r.stop()
        }
    }

    @Test func hangingServerTimesOutQuickly() async throws {
        let server = try await DeeMockServer.start(cases: [.hang])
        defer { server.stop() }
        let start = Date()
        let r = await probe().probe(server.baseURL, key: nil)
        #expect(r == .failure(.timedOut(host: "127.0.0.1:\(server.port)", vendor: .other)))
        #expect(Date().timeIntervalSince(start) < 20)
    }

    @Test func openAIKeyNeverCrossesPlainHTTP() async throws {
        let recorder = TransportRecorder()
        let r = await probe(recorder).probe(URL(string: "http://192.168.1.20:11434")!, key: "sk-proj-abcdefghijklmnopqrstuvwxyz0123")
        #expect(r == .failure(.openAIKeyOverHTTP(host: "192.168.1.20:11434")))
        #expect(recorder.count == 0)
    }

    @Test func testChatMeasuresAndChecksEcho() async throws {
        let server = try await DeeMockServer.start(cases: [.lmStudio, .modelFallback], models: ["qwen/qwen3.8-27b"])
        defer { server.stop() }
        server.setChat { _, _ in .text("Ready.", firstTokenDelay: 0.3) }
        let ok = try await probe().testChat(server.baseURL, key: nil, model: "qwen/qwen3.8-27b").get()
        #expect(ok.firstTokenSeconds >= 0.25)
        let bad = await probe().testChat(server.baseURL, key: nil, model: "other-model")
        #expect(bad == .failure(.modelMismatch(host: "127.0.0.1:\(server.port)", asked: "other-model", got: "qwen/qwen3.8-27b")))
    }
}

@Suite(.serialized) struct ProviderFactoryTests {
    let key = "sk-proj-" + String(repeating: "f", count: 40)   // fake
    var secrets: StaticSecrets { StaticSecrets([SecretAccount.openAI: key]) }

    func lanBrain(_ url: URL) -> EndpointConfig { EndpointConfig(baseURL: url, model: "qwen3.8:27b-mlx-bf16") }

    /// Mode 1 is today's session byte-for-byte (only model/voice from the config).
    @Test func mode1IsTodaysSession() throws {
        var base = RealtimeSessionConfig()
        base.turnDetection = .serverVAD(threshold: 0.5, prefixPaddingMs: 300, silenceDurationMs: 300)
        base.instructions = "x"
        let rt = try ProviderFactory.make(.openAI(voice: "marin"), secrets: secrets, transport: .failing(), base: base)
        #expect(rt.sessionConfig == base)
        #expect(try rt.sessionConfig.sessionPayload().jsonTextForTest() == base.sessionPayload().jsonTextForTest())
        #expect(rt.timing == .realtime)
        #expect(rt.label == .openAI)
    }

    /// W2: building any runtime makes no request.
    @Test func makingARuntimeIsFree() throws {
        for config in [ProviderConfig.openAI(), .lanBrainOpenAIVoice(brain: lanBrain(URL(string: "http://192.168.1.20:11434")!)),
                       .lanEverything(brain: lanBrain(URL(string: "http://192.168.1.20:11434")!), stt: .onDevice, tts: .onDevice)] {
            let recorder = TransportRecorder()
            _ = try ProviderFactory.make(config, secrets: secrets, transport: .failing(recorder: recorder),
                                         speechEngine: { FakeEngine() })
            #expect(recorder.count == 0)
        }
    }

    @Test func refusesInvalidConfigsWithoutNetwork() {
        #expect(throws: ProviderIssue.noOpenAIKey) { try ProviderFactory.make(.openAI(), secrets: StaticSecrets(), transport: .failing()) }
        var bad = ProviderConfig.lanEverything(brain: lanBrain(URL(string: "http://192.168.1.20:11434")!))
        bad.tts = .openAIREST
        #expect(throws: ProviderIssue.partNotAllowed(.voice, .lanEverything)) {
            try ProviderFactory.make(bad, secrets: secrets, transport: .failing())
        }
        var rt = ProviderConfig.lanEverything(brain: lanBrain(URL(string: "http://192.168.1.20:11434")!))
        rt.lanRealtime = true
        #expect(throws: ProviderIssue.partMissing(.brain, host: "192.168.1.20:11434")) {
            try ProviderFactory.make(rt, secrets: secrets, transport: .failing(), capabilities: ServerCapabilities(realtime: false))
        }
    }

    /// W3, mode 3: a whole turn touches only the LAN server, never *.openai.com.
    @Test func mode3NeverContactsOpenAI() async throws {
        let server = try await DeeMockServer.start(cases: [.ollama, .transcriptions, .speech], models: ["qwen3.8:27b-mlx-bf16", "whisper-1", "kokoro"])
        defer { server.stop() }
        server.setTranscribe { _ in "what's my dog's name" }
        let recorder = TransportRecorder()
        let transport = ProviderFactory.transport(for: .lanEverything, recorder: recorder)
        let lan = EndpointConfig(baseURL: server.baseURL, model: "whisper-1")
        let tts = EndpointConfig(baseURL: server.baseURL, model: "kokoro")
        let config = ProviderConfig.lanEverything(brain: lanBrain(server.baseURL), stt: .lan(lan), tts: .lan(tts), voice: "af_heart")
        let engine = FakeEngine()
        let rt = try ProviderFactory.make(config, secrets: secrets, transport: transport,
                                          capabilities: ServerCapabilities(tools: true, vendor: .ollama), speechEngine: { engine })
        #expect(rt.timing == .cascaded(stt: .lanREST))
        let session = RealtimeSession(config: rt.sessionConfig, credentials: rt.credentials, socketFactory: rt.socketFactory)
        let log = EventLog(session)
        try await session.connect()
        // Speech: the engine's detector says voice for 0.5 s, then silence.
        session.feedAudio(Data(count: 48_000 * 2))
        try await Task.sleep(for: .milliseconds(300))
        engine.activity(true, 2_400, 14_400)
        engine.activity(false, 14_400, 50_400)   // the stop + the merge window
        #expect(await log.wait { !$0.compactMap { if case .userTranscript(_, let t) = $0 { t } else { nil } }.isEmpty })
        try await session.requestResponse(dna: sampleDNA)
        #expect(await log.wait { _ in !log.done.isEmpty })
        #expect(log.done.first?.status == "completed")
        #expect(log.audioBytes > 0)
        let records = recorder.records
        #expect(!records.isEmpty)
        #expect(records.allSatisfy { !$0.isOpenAI })
        #expect(Set(records.map(\.purpose)).isSuperset(of: ["stt", "chat", "tts"]))
        #expect(Set(records.map(\.host)) == ["127.0.0.1"])
        await session.close()
    }

    /// W3, mode 2: chat only to the LAN; hearing (mint + socket) and voice only to OpenAI.
    @Test func mode2SplitsExactly() async throws {
        let server = try await DeeMockServer.start(cases: [.ollama])
        defer { server.stop() }
        let recorder = TransportRecorder()
        // OpenAI is offline here (failing for *.openai.com), the LAN is the mock.
        let live = Transport.live(redirects: .refuse)
        let transport = Transport(recorder: recorder, fetch: { r in
            if r.url?.host?.hasSuffix("openai.com") == true { throw URLError(.notConnectedToInternet) }
            return try await live.fetch(r)
        }, stream: { r in
            if r.url?.host?.hasSuffix("openai.com") == true { throw URLError(.notConnectedToInternet) }
            return try await live.stream(r)
        }, socketFactory: { _ in FakeSocket(openFailure: .network("offline")) })
        let rt = try ProviderFactory.make(.lanBrainOpenAIVoice(brain: lanBrain(server.baseURL)), secrets: secrets, transport: transport,
                                          capabilities: ServerCapabilities(tools: true, vendor: .ollama))
        #expect(rt.timing == .cascaded(stt: .openAIRealtime))
        let socket = rt.socketFactory(URLRequest(url: rt.sessionConfig.url))
        do { try await socket.open() } catch {}
        // The mint went to OpenAI (and failed offline): hearing never goes anywhere else.
        let mint = recorder.records.filter { $0.path == "/v1/realtime/client_secrets" }
        #expect(mint.count == 1 && mint.allSatisfy(\.isOpenAI))
        #expect(!recorder.records.contains { $0.host == "127.0.0.1" && $0.purpose == "stt" })
        // The voice is OpenAI's REST speech; the brain is the LAN.
        if case .lan(let host) = rt.label { #expect(host == "127.0.0.1:\(server.port)") } else { Issue.record("label") }
        #expect((rt.clipRenderer as? SpeechEndpointRenderer)?.configuration.isOpenAI == true)
    }
}

extension SessionPayload {
    func jsonTextForTest() throws -> String {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(self), as: UTF8.self)
    }
}
