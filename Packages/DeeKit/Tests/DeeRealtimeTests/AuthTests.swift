import Foundation
import Synchronization
import Testing
@testable import DeeRealtime

@Suite struct KeyStoreTests {
    @Test func normalizeAndStore() throws {
        let store = KeyStore(storage: MemorySecretStorage())
        #expect(try store.load() == nil)
        #expect(!store.hasKey)
        let key = "sk-proj-" + String(repeating: "a", count: 40)
        #expect(try store.save("  \"\(key)\"\n") == key)
        #expect(try store.load() == key)
        #expect(store.hasKey)
        try store.delete()
        #expect(try store.load() == nil)
        #expect(throws: KeyStoreError.invalidKey) { try store.save("hello") }
        #expect(throws: KeyStoreError.invalidKey) { try store.save("sk-has space " + String(repeating: "a", count: 30)) }
        #expect(KeyStore.redacted(key) == "sk-…aaaa")
    }

    /// The real Keychain. Opt-in (`DEE_KEYCHAIN_TESTS=1`): it touches the login keychain.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DEE_KEYCHAIN_TESTS"] == "1"))
    func keychainRoundTrip() throws {
        let store = KeyStore(account: "test-\(UUID().uuidString)", storage: KeychainStorage(service: "com.dee.realtime.tests"))
        defer { try? store.delete() }
        let key = "sk-test-" + String(repeating: "b", count: 40)
        try store.save(key)
        #expect(try store.load() == key)
        try store.save(key + "c")
        #expect(try store.load() == key + "c")
    }
}

@Suite struct EphemeralKeyTests {
    static let key = "sk-proj-" + String(repeating: "k", count: 40)

    final class Server: @unchecked Sendable {
        let requests = Mutex<[URLRequest]>([])
        let reply: @Sendable (Int) -> (Int, String, [String: String])
        init(_ reply: @escaping @Sendable (Int) -> (Int, String, [String: String])) { self.reply = reply }

        var transport: HTTPTransport {
            { [self] req in
                let n = requests.withLock { $0.append(req); return $0.count }
                let (status, body, headers) = reply(n)
                let response = HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                return (Data(body.utf8), response)
            }
        }
    }

    func auth(_ server: Server, mint: Bool = true, now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_756_310_000) })
        throws -> RealtimeAuth {
        let store = KeyStore(storage: MemorySecretStorage())
        try store.save(Self.key)
        return RealtimeAuth(keyStore: store, mint: mint, safetyIdentifier: "hash123", transport: server.transport, now: now)
    }

    @Test func mintsAFreshSecretForEveryConnection() async throws {
        let server = Server { n in (200, #"{"value":"ek_68af296e8e408191a1120ab638326\#(n)","expires_at":1756310470,"session":{"type":"realtime"}}"#, [:]) }
        let auth = try auth(server)
        let c = try await auth.credential(model: "gpt-realtime-2.1-mini")
        #expect(c == .ephemeral("ek_68af296e8e408191a1120ab6383261", expiresAt: Date(timeIntervalSince1970: 1_756_310_470)))
        #expect(c.isEphemeral)
        // Single-use (the live server refuses a second socket with it:
        // ephemeral_token_already_used, close 3000): never handed out twice, even
        // with nine minutes left on it.
        let again = try await auth.credential(model: "gpt-realtime-2.1-mini")
        #expect(again.bearer == "ek_68af296e8e408191a1120ab6383262")
        #expect(server.requests.withLock { $0.count } == 2)
        _ = try await auth.credential(model: "gpt-realtime-2.1")
        #expect(server.requests.withLock { $0.count } == 3)
        #expect(await auth.minted == 3)

        let req = try #require(server.requests.withLock { $0.first })
        #expect(req.url == RealtimeAuth.clientSecretsURL)
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.key)")
        #expect(req.value(forHTTPHeaderField: "OpenAI-Safety-Identifier") == "hash123")
        let body = json(String(decoding: req.httpBody ?? Data(), as: UTF8.self))
        #expect(body == ["expires_after": ["anchor": "created_at", "seconds": 600],
                         "session": ["type": "realtime", "model": "gpt-realtime-2.1-mini"]])
    }

    @Test func remintsNearExpiry() async throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1_756_310_000))
        let server = Server { n in (200, #"{"value":"ek_\#(n)","expires_at":1756310470}"#, [:]) }
        let auth = try auth(server, now: { clock.withLock { $0 } })
        #expect(try await auth.credential(model: "m").bearer == "ek_1")
        clock.withLock { $0 = Date(timeIntervalSince1970: 1_756_310_420) }   // 50 s left
        #expect(try await auth.credential(model: "m").bearer == "ek_2")
    }

    @Test func fallsBackToDirectKeyWhenMintingUnavailable() async throws {
        let server = Server { _ in (404, #"{"error":{"message":"Not found"}}"#, [:]) }
        let auth = try auth(server)
        #expect(try await auth.credential(model: "m") == .direct(Self.key))
        // Remembered: no second minting attempt.
        #expect(try await auth.credential(model: "m") == .direct(Self.key))
        #expect(server.requests.withLock { $0.count } == 1)

        let flaky = Server { _ in (502, "", [:]) }
        #expect(try await self.auth(flaky).credential(model: "m") == .direct(Self.key))
        let noMint = Server { _ in (200, "{}", [:]) }
        #expect(try await self.auth(noMint, mint: false).credential(model: "m") == .direct(Self.key))
        #expect(noMint.requests.withLock { $0.isEmpty })
    }

    @Test func authAndRateLimitErrorsSurface() async throws {
        let bad = Server { _ in (401, #"{"error":{"message":"Incorrect API key provided"}}"#, [:]) }
        await #expect(throws: RealtimeAuthError.unauthorized(status: 401, message: "Incorrect API key provided")) {
            try await self.auth(bad).credential(model: "m")
        }
        let capped = Server { _ in (429, #"{"error":{"code":"insufficient_quota"}}"#, ["Retry-After": "12"]) }
        await #expect(throws: RealtimeAuthError.rateLimited(retryAfter: 12, code: "insufficient_quota")) {
            try await self.auth(capped).credential(model: "m")
        }
        let empty = RealtimeAuth(keyStore: KeyStore(storage: MemorySecretStorage()), transport: bad.transport)
        await #expect(throws: RealtimeAuthError.noKey) { try await empty.credential(model: "m") }
    }

    @Test func handshakeFailureMapping() {
        func r(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "wss://x")!, statusCode: status, httpVersion: nil, headerFields: headers)!
        }
        #expect(URLSessionRealtimeSocket.handshakeFailure(response: r(401), error: nil) == .unauthorized(status: 401))
        #expect(URLSessionRealtimeSocket.handshakeFailure(response: r(429, ["Retry-After": "7"]), error: nil) == .rateLimited(retryAfter: 7))
        #expect(URLSessionRealtimeSocket.handshakeFailure(response: r(503), error: nil) == .server(status: 503, retryAfter: nil))
        #expect(URLSessionRealtimeSocket.handshakeFailure(response: r(400), error: nil) == .handshake(status: 400))
        #expect(URLSessionRealtimeSocket.handshakeFailure(response: nil, error: nil) == .network("handshake failed"))
    }
}

@Suite struct TranscriptSentenceTests {
    func split(_ deltas: [String]) -> [String] {
        var s = TranscriptSentences()
        var out = deltas.flatMap { s.push($0) }
        if let rest = s.finish() { out.append(rest) }
        return out
    }

    @Test func streamsSentences() {
        #expect(split(["Hello the", "re. How are", " you? I'm", " fine!"]) == ["Hello there.", "How are you?", "I'm fine!"])
        #expect(split(["Wait", "... what?! ", "Okay."]) == ["Wait...", "what?!", "Okay."])
        #expect(split(["She said \"hi.\" Then left."]) == ["She said \"hi.\"", "Then left."])
    }

    @Test func doesNotSplitInsideNumbersOrAbbreviations() {
        #expect(split(["It costs 3.5 dollars. Dr. Bell agrees, e.g. today. So do I. Yes."])
            == ["It costs 3.5 dollars.", "Dr. Bell agrees, e.g. today.", "So do I.", "Yes."])
        #expect(split(["J. R. R. Tolkien wrote it. Nice."]) == ["J. R. R. Tolkien wrote it.", "Nice."])
    }

    @Test func waitsForLookahead() {
        var s = TranscriptSentences()
        #expect(s.push("Done.") == [])
        #expect(s.push(" ") == [])
        #expect(s.push("Next") == ["Done."])
        #expect(s.finish() == "Next")
        #expect(s.finish() == nil)
    }
}

@Suite struct ManualClockTests {
    @Test func wakesInOrderAndCancels() async throws {
        let clock = ManualRealtimeClock(start: 0)
        let order = Mutex<[Int]>([])
        let a = Task { try await clock.sleep(seconds: 2); order.withLock { $0.append(2) } }
        let b = Task { try await clock.sleep(seconds: 1); order.withLock { $0.append(1) } }
        let c = Task { try await clock.sleep(seconds: 5) }
        while clock.sleeperCount < 3 { await Task.yield() }
        clock.advance(by: 3)
        try await a.value
        try await b.value
        #expect(order.withLock { $0 }.sorted() == [1, 2])   // both woke; their tasks race to append
        c.cancel()
        await #expect(throws: CancellationError.self) { try await c.value }
        #expect(clock.sleeperCount == 0)
        #expect(clock.now() == 3)
    }
}
