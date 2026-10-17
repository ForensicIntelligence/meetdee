import Foundation
import Synchronization
import Testing
@testable import DeeRealtime

/// Tune 1 (voice harness findings + the brain's asks): single-use client secrets,
/// the DNA lifecycle in the session (DNA.md §4.1 / N4, F9), dropping and resetting
/// conversation items, out-of-band `say`, unanswered turns vs idle, and one
/// source of truth for what of a cut reply was heard (`HeardRule`).
@Suite struct Tune1Tests {
    func userTurn(_ h: Harness, _ item: String, text: String? = nil) async {
        h.push(S.speechStarted(item), S.speechStopped(item), S.committed(item))
        if let text { h.push(S.userTranscript(item, text)) }
        await h.sync()
    }

    func assistantTurns(_ h: Harness) async -> [String] {
        await h.session.recentTurns.filter { $0.role == .assistant }.map(\.text)
    }

    /// The DNA items created on a socket: (id, text, create event id).
    func dnaCreates(_ socket: FakeSocket) -> [(id: String, text: String, eventID: String?)] {
        socket.sent(type: "conversation.item.create").compactMap { e in
            guard case .itemCreate(let item, _, let eid) = e, item.role == "system", let id = item.id,
                  id.hasPrefix("dna_") else { return nil }
            return (id, item.text ?? "", eid)
        }
    }

    func deletes(_ socket: FakeSocket) -> [String] {
        socket.sent(type: "conversation.item.delete").compactMap { e in
            if case .itemDelete(let id, _) = e { id } else { nil }
        }
    }

    func turnTag(_ socket: FakeSocket) -> String? {
        guard case .responseCreate(let p, _)? = socket.sent(type: "response.create").last else { return nil }
        return p?.metadata?["dee_turn"]
    }

    /// Types of the frames sent after the first `count` (audio ignored).
    func typesAfter(_ socket: FakeSocket, _ count: Int) -> [String] {
        Array(socket.sentTypes.dropFirst(count)).filter { $0 != "input_audio_buffer.append" }
    }

    // MARK: 1. Ephemeral secrets are single-use

    static let key = "sk-proj-" + String(repeating: "k", count: 40)

    /// Plays the live server: a bearer it has seen before is refused the way the
    /// API does it (`error ephemeral_token_already_used`, then close 3000).
    final class SingleUseServer: @unchecked Sendable {
        let bearers = Mutex<[String]>([])
        let mints = Mutex(0)
        let refusals = Mutex(0)

        var transport: HTTPTransport {
            { [self] req in
                let n = mints.withLock { $0 += 1; return $0 }
                let body = #"{"value":"ek_secret_\#(n)","expires_at":\#(Int(Date().timeIntervalSince1970) + 600)}"#
                return (Data(body.utf8), HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }
        }

        func socket(_ req: URLRequest) -> FakeSocket {
            let bearer = req.value(forHTTPHeaderField: "Authorization") ?? ""
            let reused = bearers.withLock { b -> Bool in
                defer { b.append(bearer) }
                return b.contains(bearer)
            }
            guard reused else { return FakeSocket(request: req, sessionID: "sess_\(Int.random(in: 1000...9999))") }
            refusals.withLock { $0 += 1 }
            let s = FakeSocket(request: req, autoHandshake: false)
            s.push(S.error(type: "invalid_request_error", code: "ephemeral_token_already_used",
                           message: "Ephemeral token has already been used."))
            s.drop(code: 3000, failure: .network("closed by server (3000)"))
            return s
        }
    }

    func singleUseHarness(_ server: SingleUseServer, config: RealtimeSessionConfig = Harness.defaultConfig(),
                          credentials: RealtimeCredentialProvider? = nil,
                          invalidate: RealtimeCredentialInvalidator? = nil) throws -> Harness {
        let store = KeyStore(storage: MemorySecretStorage([KeyStore.defaultAccount: Self.key]))
        let auth = RealtimeAuth(keyStore: store, transport: server.transport)
        let factory = FakeSocketFactory { server.socket($0) }
        let clock = ManualRealtimeClock()
        let session = RealtimeSession(config: config,
                                      credentials: credentials ?? { try await auth.credential(model: $0) },
                                      invalidateCredential: invalidate ?? { await auth.invalidate() },
                                      socketFactory: factory.factory, clock: clock)
        return Harness(session: session, factory: factory, clock: clock, log: EventLog(session.events))
    }

    /// Regression (harness defect 1): a reconnect within the secret's 10 minutes
    /// used to reuse the cached `ek_` and was refused until it expired.
    @Test func reconnectWithinTenMinutesMintsAFreshSecret() async throws {
        let server = SingleUseServer()
        let h = try singleUseHarness(server)
        try await h.session.connect()
        h.factory.made[0].drop()
        #expect(await h.log.wait { if case .disconnected = $0 { true } else { false } } != nil)
        await h.advance(by: 0.5)
        #expect(await h.log.wait { if case .recovered = $0 { true } else { false } } != nil)
        let bearers = server.bearers.withLock { $0 }
        #expect(bearers == ["Bearer ek_secret_1", "Bearer ek_secret_2"])
        #expect(server.refusals.withLock { $0 } == 0)
        #expect(!h.log.contains { $0.fallback == .unauthorized })
        #expect(await h.session.state == .listening)
    }

    /// The same for a rollover a few minutes in (make-before-break: both sockets
    /// live at once, each with its own secret).
    @Test func rolloverWithinTenMinutesMintsAFreshSecret() async throws {
        let server = SingleUseServer()
        var config = Harness.defaultConfig()
        config.rolloverAfter = 120
        config.rolloverSummary = .none
        let h = try singleUseHarness(server, config: config)
        try await h.session.connect()
        await h.advance(by: 121)
        #expect(await h.log.wait { if case .rolledOver = $0 { true } else { false } } != nil)
        #expect(server.bearers.withLock { $0 } == ["Bearer ek_secret_1", "Bearer ek_secret_2"])
        #expect(server.refusals.withLock { $0 } == 0)
        #expect(!h.log.contains { if case .error(let i) = $0 { i.code == "rollover_failed" } else { false } })
    }

    /// A provider that hands the same secret out again (as `RealtimeAuth` used to):
    /// the refusal (error + close 3000 before `session.updated`) discards it and
    /// the open is retried once with a fresh credential, without a fallback.
    @Test func aRefusedSecretIsDiscardedAndTheOpenRetried() async throws {
        let server = SingleUseServer()
        let calls = Mutex(0)
        let invalidations = Mutex(0)
        let h = try singleUseHarness(server, credentials: { _ in
            let n = calls.withLock { $0 += 1; return $0 }
            // Calls 1 and 2 return the same secret; after the refusal, a new one.
            return .ephemeral(n <= 2 ? "ek_same" : "ek_new_\(n)", expiresAt: Date().addingTimeInterval(600))
        }, invalidate: { invalidations.withLock { $0 += 1 } })
        try await h.session.connect()
        h.factory.made[0].drop()
        await h.advance(by: 0.5)
        #expect(await h.log.wait { if case .recovered = $0 { true } else { false } } != nil)
        #expect(server.refusals.withLock { $0 } == 1)
        #expect(invalidations.withLock { $0 } == 1)
        #expect(server.bearers.withLock { $0 } == ["Bearer ek_same", "Bearer ek_same", "Bearer ek_new_3"])
        // The refusal was handled inside the open: no fallback for it.
        #expect(h.log.count { $0.fallback != nil } == 1)   // only the socketLost of the drop
    }

    /// Refused again with a fresh secret: not the key's fault (`.unauthorized`
    /// would stop for good) — a transient failure, and reconnecting goes on.
    @Test func aSecretRefusedTwiceKeepsReconnecting() async throws {
        let server = SingleUseServer()
        let h = try singleUseHarness(server, credentials: { _ in .ephemeral("ek_always_same", expiresAt: Date().addingTimeInterval(600)) })
        try await h.session.connect()
        h.factory.made[0].drop()
        await h.advance(by: 0.5)
        #expect(await h.factory.waitForSocket(count: 3) != nil)        // refused, retried fresh, refused
        await h.settle()
        #expect(!h.log.contains { $0.fallback == .unauthorized })
        #expect(await h.session.state == .connecting)
        let before = h.factory.made.count
        await h.advance(by: 1)
        #expect(await h.factory.waitForSocket(count: before + 1) != nil)   // still trying
    }

    @Test func credentialRefusalClassification() {
        #expect(RealtimeIssue.isCredentialRefusal(APIError(type: "invalid_request_error", code: "ephemeral_token_already_used", message: nil)))
        #expect(RealtimeIssue.isCredentialRefusal(APIError(type: nil, code: "client_secret_expired", message: nil)))
        #expect(RealtimeIssue.isCredentialRefusal(APIError(type: nil, code: "token_expired", message: nil)))
        #expect(!RealtimeIssue.isCredentialRefusal(APIError(type: "invalid_request_error", code: "invalid_value", message: nil)))
        #expect(!RealtimeIssue.isCredentialRefusal(APIError(type: nil, code: "rate_limit_exceeded", message: nil)))
        #expect(RealtimeIssue.isCredentialRefusal(closeCode: 3000))
        #expect(!RealtimeIssue.isCredentialRefusal(closeCode: 1000))
        #expect(!RealtimeIssue.isCredentialRefusal(closeCode: 1006))
    }

    // MARK: 2a. DNA lifecycle (DNA.md §4.1, N4)

    @Test func dnaIsCreatedThenThePreviousDeletedThenTheResponse() async throws {
        let h = try await Harness.connected()
        await userTurn(h, "u1")
        let n0 = h.socket.sent.count
        try await h.session.requestResponse(dna: "DEE DNA one")
        #expect(typesAfter(h.socket, n0) == ["conversation.item.create", "response.create"])
        let first = try #require(dnaCreates(h.socket).last)
        #expect(first.id.hasPrefix("dna_") && first.id.count <= 32)
        #expect(first.text == "DEE DNA one")
        guard case .responseCreate(let p, _)? = h.socket.sent(type: "response.create").last else { Issue.record("no response"); return }
        #expect(p?.instructions == nil)
        #expect(p?.conversation == nil)
        // Confirmed by the server: the live one.
        h.push(.itemAdded(.init(item: RealtimeItem(id: first.id, type: "message", role: "system"))))
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 100),
               S.transcriptDone("r1", "a1", "Hi."), S.responseDone("r1"))
        await h.sync()
        #expect(await h.session.liveDNAItemID == first.id)
        await h.session.playbackFinished()

        await userTurn(h, "u2")
        let n1 = h.socket.sent.count
        try await h.session.requestResponse(dna: "DEE DNA two")
        #expect(typesAfter(h.socket, n1) == ["conversation.item.create", "conversation.item.delete", "response.create"])
        let second = try #require(dnaCreates(h.socket).last)
        #expect(second.id != first.id && second.text == "DEE DNA two")
        #expect(deletes(h.socket).last == first.id)
        // Not live until confirmed.
        #expect(await h.session.liveDNAItemID == nil)
        h.push(.itemAdded(.init(item: RealtimeItem(id: second.id, type: "message", role: "system"))),
               .itemDeleted(.init(itemID: first.id)))
        await h.sync()
        #expect(await h.session.liveDNAItemID == second.id)
    }

    @Test func initiativeCarriesADNAAndToolFollowUpsReuseIt() async throws {
        let h = try await Harness.connected()
        #expect(await h.session.initiative(dna: "DEE DNA hello") == .sent)
        #expect(dnaCreates(h.socket).map(\.text) == ["DEE DNA hello"])
        // A tool round trip: the follow-up rides on the live DNA.
        await h.session.setToolHandler { _ in RealtimeToolResult(output: "{}", followUp: .always) }
        h.push(S.responseCreated("r1"), S.functionCallAdded("r1", "f1", name: "recall"),
               S.callDone("r1", "f1", call: "c1", name: "recall", args: "{}"),
               S.responseDone("r1", output: [RealtimeItem(id: "f1", type: "function_call")]))
        #expect(await h.socket.waitForSent(type: "response.create", count: 2))
        #expect(dnaCreates(h.socket).count == 1)
        #expect(deletes(h.socket).isEmpty)
    }

    /// F9: the server refuses the new DNA. The response sent right behind it is
    /// given up before it starts and sent again behind the previous DNA, restored
    /// under a fresh id: no response runs without a DNA, and the happy path never
    /// waited for a confirmation.
    @Test func aRefusedDNAHoldsTheResponseBehindThePreviousOne() async throws {
        let h = try await Harness.connected()
        await userTurn(h, "u1")
        try await h.session.requestResponse(dna: "DEE DNA one")
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 100),
               S.transcriptDone("r1", "a1", "Hi."), S.responseDone("r1"))
        await h.sync()
        await h.session.playbackFinished()

        await userTurn(h, "u2")
        try await h.session.requestResponse(dna: "DEE DNA two")
        let refused = try #require(dnaCreates(h.socket).last)
        let oldTurn = try #require(turnTag(h.socket))
        let n = h.socket.sent.count
        h.push(S.error(type: "invalid_request_error", code: "invalid_value", message: "bad item", eventID: refused.eventID))
        await h.sync()
        // Restored, then the same request again (new token).
        #expect(typesAfter(h.socket, n) == ["conversation.item.create", "response.create"])
        let restored = try #require(dnaCreates(h.socket).last)
        #expect(restored.text == "DEE DNA one" && restored.id != refused.id)
        let newTurn = try #require(turnTag(h.socket))
        #expect(newTurn != oldTurn)
        #expect(h.log.contains { if case .error(let i) = $0 { i.eventID == refused.eventID } else { false } })

        // The DNA-less response the server made anyway is cancelled unheard and its item deleted.
        h.push(S.responseCreated("r_orphan", metadata: ["dee_turn": oldTurn]),
               S.responseCreated("r2", metadata: ["dee_turn": newTurn]))
        await h.sync()
        let cancels = h.socket.sent(type: "response.cancel").compactMap { e -> String? in
            if case .responseCancel(let id, _) = e { id } else { nil }
        }
        #expect(cancels == ["r_orphan"])
        #expect(!h.log.contains(.responseStarted(responseID: "r_orphan", kind: .reply)))
        #expect(h.log.contains(.responseStarted(responseID: "r2", kind: .reply)))
        h.push(S.responseDone("r_orphan", status: "cancelled",
                              output: [RealtimeItem(id: "a_orphan", type: "message", role: "assistant")]))
        await h.sync()
        #expect(deletes(h.socket).contains("a_orphan"))
        // r2 is the request's one and only response.
        h.push(S.messageAdded("r2", "a2"), S.audio("r2", "a2", ms: 100), S.transcriptDone("r2", "a2", "Sure."),
               S.responseDone("r2"))
        await h.sync()
        #expect(h.log.count { $0.responseDone != nil } == 2)
    }

    @Test func aRefusedFirstDNAFailsTheRequestInsteadOfRunningBare() async throws {
        let h = try await Harness.connected()
        await userTurn(h, "u1")
        try await h.session.requestResponse(dna: "DEE DNA one")
        let refused = try #require(dnaCreates(h.socket).last)
        let turn = try #require(turnTag(h.socket))
        h.push(S.error(type: "invalid_request_error", code: "invalid_value", eventID: refused.eventID))
        let done = try #require(await h.log.wait { $0.responseDone != nil }?.responseDone)
        #expect(done.status == "failed" && done.reason == "dna_rejected")
        h.push(S.responseCreated("r_bare", metadata: ["dee_turn": turn]))
        await h.sync()
        #expect(h.socket.sentTypes.contains("response.cancel"))
        #expect(!h.log.contains { if case .responseStarted = $0 { true } else { false } })
        #expect(await h.session.state == .listening)
    }

    @Test func replaceDNASwapsNowAndARefusedReplacementRestores() async throws {
        let h = try await Harness.connected()
        await userTurn(h, "u1")
        try await h.session.requestResponse(dna: "DEE DNA one")
        let one = try #require(dnaCreates(h.socket).last)
        let n = h.socket.sent.count
        await h.session.replaceDNA("DEE DNA forgotten")
        #expect(typesAfter(h.socket, n) == ["conversation.item.create", "conversation.item.delete"])
        let two = try #require(dnaCreates(h.socket).last)
        #expect(deletes(h.socket) == [one.id])
        h.push(S.error(code: "invalid_value", eventID: two.eventID))
        await h.sync()
        let three = try #require(dnaCreates(h.socket).last)
        #expect(three.text == "DEE DNA one" && three.id != one.id)
        // Errors for the session's own DNA deletes (already gone) are not reported.
        let del = h.socket.sent(type: "conversation.item.delete").last?.eventID
        h.push(S.error(code: "item_not_found", eventID: del))
        await h.sync()
        #expect(!h.log.contains { if case .error(let i) = $0 { i.code == "item_not_found" } else { false } })
    }

    /// A new connection starts with no DNA; a response there that brings none of
    /// its own (a re-request, a follow-up) gets the last DNA, under a new id.
    @Test func aNewConnectionStartsWithoutDNAAndNeverAnswersBare() async throws {
        let h = try await Harness.connected()
        await userTurn(h, "u1")
        try await h.session.requestResponse(dna: "DEE DNA one")
        let one = try #require(dnaCreates(h.socket).last)
        h.push(.itemAdded(.init(item: RealtimeItem(id: one.id, type: "message", role: "system"))))
        await h.sync()
        h.socket.drop()
        await h.advance(by: 0.5)
        #expect(await h.log.wait { if case .recovered = $0 { true } else { false } } != nil)
        #expect(await h.session.liveDNAItemID == nil)
        let second = h.socket
        #expect(dnaCreates(second).isEmpty)   // the seed carries no DNA
        await userTurn(h, "u2")
        try await h.session.requestResponse()
        let again = try #require(dnaCreates(second).last)
        #expect(again.text == "DEE DNA one" && again.id != one.id)
        #expect(deletes(second).isEmpty)
    }

    // MARK: 2b. Dropping user items, resetting the conversation

    @Test func dropUserItemDeletesItAndItsLine() async throws {
        let h = try await Harness.connected()
        await userTurn(h, "u1", text: "Turn the TV down")
        #expect(await h.session.recentTurns.map(\.text) == ["Turn the TV down"])
        await h.session.dropUserItem(itemID: "u1")
        #expect(deletes(h.socket) == ["u1"])
        #expect(await h.session.recentTurns.isEmpty)
        // Not yet committed: deleted at its commit, never reported.
        h.push(S.speechStarted("u2"))
        await h.sync()
        await h.session.dropUserItem(itemID: "u2")
        h.push(S.speechStopped("u2"), S.committed("u2"), S.userTranscript("u2", "on the news tonight"))
        await h.sync()
        #expect(deletes(h.socket) == ["u1", "u2"])
        #expect(!h.log.contains(.userCommitted(itemID: "u2", previousItemID: nil)))
        #expect(!h.log.contains(.userTranscript(itemID: "u2", text: "on the news tonight")))
        #expect(await h.session.recentTurns.isEmpty)
        #expect(await !h.session.hasUnansweredUserTurn)
    }

    /// TV speech preempted Dee's pending reply; dropping it brings the reply back.
    @Test func droppingTheSpeechThatPreemptedAReplyResumesIt() async throws {
        let h = try await Harness.connected()
        await userTurn(h, "u1")
        try await h.session.requestResponse(dna: "DEE DNA one")
        h.push(S.responseCreated("r1"), S.speechStarted("tv1"))
        #expect(await h.log.wait { if case .replyPreempted = $0 { true } else { false } } != nil)
        h.push(S.responseDone("r1", status: "cancelled", reason: "client_cancelled"))
        await h.sync()
        await h.session.dropUserItem(itemID: "tv1")
        #expect(await h.socket.waitForSent(type: "response.create", count: 2))
        // On the live DNA: no second DNA create.
        #expect(dnaCreates(h.socket).count == 1)
        // And a reply for dropped speech is withdrawn while unheard.
        h.push(S.responseCreated("r2"), S.responseDone("r2"))
        await h.sync()
        await userTurn(h, "tv2")
        try await h.session.requestResponse(dna: "DEE DNA two")
        await h.session.dropUserItem(itemID: "tv2")
        #expect(await h.session.state == .cancelling)
    }

    @Test func resetConversationDeletesEverythingButWhatIsKept() async throws {
        let h = try await Harness.connected()
        await userTurn(h, "u1", text: "My name is Sam.")
        try await h.session.requestResponse(dna: "DEE DNA one")
        let dna = try #require(dnaCreates(h.socket).last)
        h.push(.itemAdded(.init(item: RealtimeItem(id: dna.id, type: "message", role: "system"))),
               S.responseCreated("r1"), S.messageAdded("r1", "a1"),
               .itemAdded(.init(item: RealtimeItem(id: "a1", type: "message", role: "assistant"))),
               S.audio("r1", "a1", ms: 100), S.transcriptDone("r1", "a1", "Hi Sam."), S.responseDone("r1"))
        await h.sync()
        await h.session.playbackFinished()
        await userTurn(h, "u2", text: "Start over.")
        #expect(await h.session.recentTurns.count == 3)

        await h.session.resetConversation(keeping: ["u2"])
        #expect(Set(deletes(h.socket)) == ["u1", "a1"])
        #expect(!deletes(h.socket).contains(dna.id))
        #expect(await h.session.recentTurns.map(\.text) == ["Start over."])
        #expect(await h.session.lastSummary == nil)
        #expect(await h.session.liveDNAItemID == dna.id)
    }

    @Test func typedTextIsAUserItemTheNextReplyAnswers() async throws {
        let h = try await Harness.connected()
        let id = try #require(await h.session.addUserText("  What's the weather?  "))
        #expect(id.hasPrefix("txt_") && id.count <= 32)
        guard case .itemCreate(let item, _, _)? = h.socket.sent(type: "conversation.item.create").last else { Issue.record("none"); return }
        #expect(item.id == id && item.role == "user" && item.text == "What's the weather?")
        #expect(await h.session.recentTurns.map(\.text) == ["What's the weather?"])
        #expect(await h.session.hasUnansweredUserTurn)
        try await h.session.requestResponse(dna: "DEE DNA typed")
        #expect(await !h.session.hasUnansweredUserTurn)
        #expect(h.socket.sentTypes.suffix(3) == ["conversation.item.create", "conversation.item.create", "response.create"])
    }

    // MARK: 2c. Out-of-band say

    @Test func sayGoesOutOfBandAndStaysOutOfTheHistory() async throws {
        let h = try await Harness.connected()
        await userTurn(h, "u1", text: "Hello")
        try await h.session.requestResponse(dna: "DEE DNA one")
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 100),
               S.transcriptDone("r1", "a1", "Hi."), S.responseDone("r1"))
        await h.sync()
        await h.session.playbackFinished()

        let n = h.socket.sent.count
        #expect(await h.session.say(instructions: "Say exactly: One sec.\nVoice: soft") == .sent)
        #expect(typesAfter(h.socket, n) == ["response.create"])   // no DNA, no cue
        guard case .responseCreate(let p, _)? = h.socket.sent(type: "response.create").last else { Issue.record("none"); return }
        #expect(p?.conversation == "none")
        #expect(p?.input == [])
        #expect(p?.tools == [])
        #expect(p?.outputModalities == ["audio"])
        #expect(p?.instructions == "Say exactly: One sec.\nVoice: soft")
        let turn = try #require(p?.metadata?["dee_turn"])
        h.push(S.responseCreated("r_say", metadata: ["dee_turn": turn, "purpose": "dee_say"]),
               S.messageAdded("r_say", "s1"), S.audio("r_say", "s1", ms: 800),
               S.transcriptDone("r_say", "s1", "One sec."), S.responseDone("r_say"))
        await h.sync()
        #expect(h.log.contains(.responseStarted(responseID: "r_say", kind: .say)))
        #expect(h.log.contains { if case .assistantAudio("s1", _) = $0 { true } else { false } })
        // Never in the history; a barge-in sends no truncate for it.
        #expect(await assistantTurns(h) == ["Hi."])
        let o = await h.session.bargeIn(playedMs: 300)
        #expect(o.truncations.isEmpty)
        #expect(h.socket.sent(type: "conversation.item.truncate").isEmpty)
        // Gated like an initiative.
        h.push(S.speechStarted("u2"))
        await h.sync()
        #expect(await h.session.say(instructions: "Say exactly: Hm.") == .refused(.userSpeaking))
    }

    @Test func sayIsCancelledIfTheUserStartsFirst() async throws {
        let h = try await Harness.connected()
        #expect(await h.session.say(instructions: "Say exactly: Okay.") == .sent)
        let turn = try #require(turnTag(h.socket))
        h.push(S.responseCreated("r_say", metadata: ["dee_turn": turn]), S.speechStarted("u1"))
        #expect(await h.log.wait { $0 == .initiativeCancelled(responseID: "r_say") } != nil)
    }

    // MARK: 2d. An unanswered committed turn is not idle

    @Test func anUnansweredTurnHoldsTheRollover() async throws {
        var config = Harness.defaultConfig()
        config.rolloverAfter = 60
        config.rolloverSummary = .none
        let h = try await Harness.connected(config: config)
        await h.advance(by: 55)
        await userTurn(h, "u1")
        #expect(await h.session.hasUnansweredUserTurn)
        await h.advance(by: 6)
        await h.advance(by: 1)
        #expect(h.factory.made.count == 1)                         // waiting for Dee's answer
        #expect(!h.log.contains { $0 == .rolloverStarted(forced: false) })
        await h.session.userTurnHandled(itemID: "u1")              // e.g. a command
        await h.advance(by: 1)
        #expect(await h.log.wait { $0 == .rolloverStarted(forced: false) } != nil)
    }

    @Test func unansweredTurnsAreAnsweredByARequestAndExpire() async throws {
        var config = Harness.defaultConfig()
        config.rolloverAfter = 60
        config.rolloverSummary = .none
        let h = try await Harness.connected(config: config)
        await userTurn(h, "u1")
        try await h.session.requestResponse()
        #expect(await !h.session.hasUnansweredUserTurn)
        h.push(S.responseCreated("r1"), S.responseDone("r1"))
        await h.sync()
        await userTurn(h, "u2")                                    // never answered, never handled
        await h.advance(by: 15)
        #expect(await h.session.hasUnansweredUserTurn)
        await h.advance(by: 50)                                    // past rolloverAfter, and past the hold
        await h.advance(by: 1)
        #expect(await !h.session.hasUnansweredUserTurn)
        #expect(await h.log.wait { $0 == .rolloverStarted(forced: false) } != nil)
    }

    // MARK: 3. What was heard: one source of truth

    /// The live case (harness defect 8, trace smoke-echo item_EXAjRJhKNTbWkk9LkgHst):
    /// audio and transcript arrive interleaved, the item's audio (9950 ms) completes
    /// before the cut at 3660 ms. The session used to re-derive placements from the
    /// complete audio (81.6 ms/char) and keep 1 sentence while DeeVoice, on the hints
    /// it had been given, reported 2 heard. Now both use the emitted hints.
    @Test func aCutReplyKeepsExactlyWhatTheHintsSayWasHeard() async throws {
        let h = try await Harness.connected()
        await userTurn(h, "u1")
        try await h.session.requestResponse()
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"),
               S.transcript("r1", "a1", "Oh, Hitch, that’s a"), S.audio("r1", "a1", ms: 400),
               S.transcript("r1", "a1", " fun name."), S.audio("r1", "a1", ms: 800),
               S.transcript("r1", "a1", " Could be a movie star,"), S.audio("r1", "a1", ms: 400),
               S.transcript("r1", "a1", " a robot, maybe a little rascal."), S.audio("r1", "a1", ms: 1600),
               S.transcript("r1", "a1", " I’m curious—what’s"), S.audio("r1", "a1", ms: 2400),
               S.audio("r1", "a1", ms: 2000),
               S.transcript("r1", "a1", " Hitch up to today?"), S.audio("r1", "a1", ms: 2350),
               S.audioDone("r1", "a1"),
               S.transcriptDone("r1", "a1", "Oh, Hitch, that’s a fun name. Could be a movie star, a robot, maybe a little rascal. I’m curious—what’s Hitch up to today?"),
               S.responseDone("r1"))
        await h.sync()
        let hints = h.log.all.compactMap { e -> (String, Int)? in
            if case .assistantSentence("a1", let t, let ms) = e { (t, ms) } else { nil }
        }
        #expect(hints.count == 3)
        let o = await h.session.bargeIn(playedMs: 3660)
        let cut = try #require(o.truncations.first)
        let expected = HeardRule.heardCount(hints: hints.map(\.1), playedMs: 3660)
        #expect(cut.heardSentences == expected)
        #expect(expected == 2, "\(hints)")
        let heard = hints.prefix(expected).map(\.0).joined(separator: " ")
        #expect(cut.heardText == heard)
        #expect(await assistantTurns(h) == [heard])
        #expect(await h.session.heardText(itemID: "a1") == heard)
    }

    /// Property: for any sentences, audio pacing and cut, the session keeps exactly
    /// the `HeardRule` prefix of the hints it emitted.
    @Test func historyAlwaysMatchesTheRuleOnTheEmittedHints() async throws {
        var rng = SplitMix(seed: 0xDEE)
        let words = ["Sure", "the red ball", "is under the couch", "I think", "maybe", "let's look", "okay", "wow"]
        for round in 0..<40 {
            let h = try await Harness.connected()
            await userTurn(h, "u\(round)")
            try await h.session.requestResponse()
            let item = "a\(round)", resp = "r\(round)"
            h.push(S.responseCreated(resp), S.messageAdded(resp, item))
            let sentences = (0..<Int(rng.next() % 5 + 1)).map { _ in
                (0..<Int(rng.next() % 4 + 1)).map { _ in words[Int(rng.next() % UInt64(words.count))] }
                    .joined(separator: " ") + "."
            }
            var total = 0
            for s in sentences {
                h.push(S.transcript(resp, item, s + " "))
                let ms = Int(rng.next() % 1500) + 20
                total += ms
                h.push(S.audio(resp, item, ms: ms))
            }
            if rng.next() % 2 == 0 { h.push(S.audioDone(resp, item)) }
            h.push(S.transcriptDone(resp, item, sentences.joined(separator: " ")), S.responseDone(resp))
            await h.sync()
            let hints = h.log.all.compactMap { e -> (String, Int)? in
                if case .assistantSentence(item, let t, let ms) = e { (t, ms) } else { nil }
            }
            #expect(hints.map(\.0) == sentences)
            #expect(zip(hints.dropFirst(), hints).allSatisfy { $0.1 >= $1.1 })   // never decreasing
            let played = Int(rng.next() % UInt64(total + 1))
            let o = await h.session.bargeIn(playedMs: played)
            let n = HeardRule.heardCount(hints: hints.map(\.1), playedMs: min(played, total))
            let kept = hints.prefix(n).map(\.0).joined(separator: " ")
            if played < total {
                #expect(o.truncations.first?.heardSentences == n, "round \(round)")
                #expect(await assistantTurns(h) == (kept.isEmpty ? [] : [kept]), "round \(round) played \(played) \(hints)")
            }
        }
    }

    @Test func heardRuleMatchesTheSentenceClockCutRule() {
        // Placements clamp to the previous end; a sentence counts when it started
        // and its midpoint was played (SentenceClock `.cut`), or when playback passed its end.
        #expect(HeardRule.placements([500, 300, 900]).map { [$0.start, $0.end] } == [[0, 500], [500, 500], [500, 900]])
        #expect(HeardRule.heardCount(hints: [1798, 5208, 9950], playedMs: 3660) == 2)
        #expect(HeardRule.heardCount(hints: [1798, 5208, 9950], playedMs: 3502) == 1)
        #expect(HeardRule.heardCount(hints: [1798, 5208, 9950], playedMs: 0) == 0)
        #expect(HeardRule.heardCount(hints: [0, 0], playedMs: 0) == 0)
        #expect(HeardRule.heardCount(hints: [100], playedMs: 50) == 1)
        #expect(HeardRule.heardCount(hints: [100, 200], playedMs: 100) == 1)   // second not started
    }

    /// The speaking rate is learned from completed replies, so the next reply's
    /// hints sit closer to Dee's real audio.
    @Test func theSpeakingRateIsLearned() async throws {
        let h = try await Harness.connected()
        #expect(await h.session.speakingRateMsPerCharacter == 62)
        await userTurn(h, "u1")
        try await h.session.requestResponse()
        let text = String(repeating: "Hello there friend. ", count: 4).trimmingCharacters(in: .whitespaces)   // 79 chars
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 79 * 80),
               S.audioDone("r1", "a1"), S.transcriptDone("r1", "a1", text), S.responseDone("r1"))
        await h.sync()
        #expect(abs(await h.session.speakingRateMsPerCharacter - 80) < 0.01)
        await h.session.playbackFinished()
        await userTurn(h, "u2")
        try await h.session.requestResponse()
        h.push(S.responseCreated("r2"), S.messageAdded("r2", "a2"), S.transcript("r2", "a2", "Okay then. And"))
        await h.sync()
        #expect(h.log.contains(.assistantSentence(itemID: "a2", text: "Okay then.", audioMsHint: 800)))
    }
}

/// Deterministic generator for the property test.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
