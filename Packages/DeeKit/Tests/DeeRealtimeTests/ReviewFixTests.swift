import Foundation
import Synchronization
import Testing
@testable import DeeRealtime

/// Regression tests for the stage-1 review findings (R1–R13), one or more each.
@Suite struct ReviewFixTests {
    private static let rolledOver: @Sendable (RealtimeEvent) -> Bool = { if case .rolledOver = $0 { true } else { false } }

    // MARK: R1 / R4 / R5 — forced rollover

    /// R1: a reply that starts while the forced rollover is summarising is never cut off.
    @Test func forcedRolloverNeverKillsAReplyThatStartedDuringIt() async throws {
        let h = try await Harness.connected()
        let first = h.socket
        // Something to summarise (with nothing said, no summary is asked for).
        if let id = await h.session.addUserText("Hi Dee.") { await h.session.userTurnHandled(itemID: id) }
        await h.advance(by: 59 * 60 + 1)
        #expect(await h.log.wait { $0 == .rolloverStarted(forced: true) } != nil)
        #expect(await first.waitForSent(type: "response.create", count: 1))   // the summary request
        let purpose = try #require({ () -> String? in
            if case .responseCreate(let p, _)? = first.sent(type: "response.create").last { p?.metadata?["purpose"] } else { nil }
        }())
        // Meanwhile the user speaks and Dee answers.
        h.push(S.speechStarted("u1"), S.speechStopped("u1"), S.committed("u1"))
        await h.log.wait { if case .userCommitted = $0 { true } else { false } }
        try await h.session.requestResponse()
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 300))
        await h.log.wait(\.isAudio)
        // The summary finishes and the new session opens: parked, not switched to.
        h.push(S.responseCreated("r_sum", metadata: ["purpose": purpose]),
               .outputTextDone(.init(responseID: "r_sum", itemID: "s1", text: "sum")),
               S.responseDone("r_sum", metadata: ["purpose": purpose]))
        #expect(await h.factory.waitForSocket(count: 2) != nil)
        await h.advance(by: 1)
        #expect(!h.log.contains { Self.rolledOver($0) })
        #expect(first.closedByClient == nil)
        #expect(await h.session.state == .speaking)
        // r1 ends normally on the old session; then playback drains and it switches.
        first.push(S.audio("r1", "a1", ms: 300)); first.push(S.responseDone("r1"))
        let done = try #require(await h.log.wait { $0.responseDone != nil }?.responseDone)
        #expect(done.status == "completed")
        #expect(done.audioMs == 600)
        await h.session.playbackFinished()
        #expect(await h.log.wait { Self.rolledOver($0) } != nil)
        #expect(first.closedByClient?.code == 1000)
        #expect(h.log.count { $0.responseDone != nil } == 1)
        #expect(h.log.count { $0 == .rolloverStarted(forced: true) } == 1)
    }

    /// R4: never while Dee's audio is still playing; a barge-in in that tail still truncates.
    @Test func forcedRolloverWaitsForPlayback() async throws {
        var config = Harness.defaultConfig()
        config.rolloverSummary = .none
        let h = try await Harness.connected(config: config)
        let first = h.socket
        try await h.session.requestResponse()
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 3000),
               S.transcriptDone("r1", "a1", "One. Two."), S.responseDone("r1"))
        await h.log.wait { $0.responseDone != nil }
        await h.advance(by: 59 * 60 + 1)
        #expect(await h.factory.waitForSocket(count: 2) != nil)
        await h.advance(by: 1)
        #expect(!h.log.contains { Self.rolledOver($0) })
        #expect(await h.session.state == .speaking)
        // 3000 ms over "One. Two.": "One." spans 0–1333 ms (midpoint 667).
        let outcome = await h.session.bargeIn(playedMs: 1000)
        #expect(outcome.truncatedItemID == "a1")
        #expect(first.sent(type: "conversation.item.truncate").count == 1)
        // Now quiet: it switches, and the seed has only what was heard.
        await h.advance(by: 1)
        #expect(await h.log.wait { Self.rolledOver($0) } != nil)
        let second = h.factory.made[1]
        guard case .itemCreate(let seed, _, _)? = second.sent(type: "conversation.item.create").first else {
            Issue.record("no seed"); return
        }
        #expect(seed.text?.contains("Dee: One.") == true)
        #expect(seed.text?.contains("Two.") == false)
    }

    /// R5: a failing forced rollover backs off and is announced once.
    @Test func failedForcedRolloverBacksOff() async throws {
        var config = Harness.defaultConfig()
        config.rolloverSummary = .none
        let factory = FakeSocketFactory([FakeSocket()]) { req in FakeSocket(request: req, openFailure: .network("offline")) }
        let clock = ManualRealtimeClock()
        let session = RealtimeSession(config: config, credentials: { _ in .direct("sk-x") },
                                      socketFactory: factory.factory, clock: clock)
        let h = Harness(session: session, factory: factory, clock: clock, log: EventLog(session.events))
        try await session.connect()
        await h.advance(by: 59 * 60)
        for _ in 0..<10 { await h.advance(by: 1) }
        await h.settle()
        #expect(h.log.count { $0 == .rolloverStarted(forced: true) } == 1)
        #expect(factory.made.count <= 3, "\(factory.made.count) sockets in 10 s")
        #expect(h.log.count { if case .error(let i) = $0 { i.code == "rollover_failed" } else { false } } <= 2)
    }

    /// The old session dies while the new one is parked: the parked one takes over at once.
    @Test func parkedSessionTakesOverWhenTheOldOneDies() async throws {
        var config = Harness.defaultConfig()
        config.rolloverSummary = .none
        let h = try await Harness.connected(config: config)
        let first = h.socket
        h.push(S.speechStarted("u1"))   // not idle: the rollover parks
        await h.sync()
        await h.advance(by: 50 * 60)
        await h.settle()
        #expect(h.factory.made.count == 1)   // non-forced waits for idle to even start
        await h.advance(by: 9 * 60)
        let second = try #require(await h.factory.waitForSocket(count: 2))
        // Parked (open and configured) before the old one dies; under load the
        // handshake can take longer than one settle (tune 2: flaked at load 20).
        for _ in 0..<400 where await !h.session.hasParkedSession { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(await h.session.hasParkedSession)
        first.drop()
        #expect(await h.log.wait { if case .recovered = $0 { true } else { false } } != nil)
        #expect(!h.log.contains { $0.fallback != nil })   // seamless: no fallback advice
        #expect(h.factory.made.count == 2)
        await h.session.appendAudio(Data(count: 96))
        #expect(second.sentTypes.contains("input_audio_buffer.append"))
    }

    // MARK: R2 — token cap

    @Test func tokenCapIsAboutFortySecondsAndSurfaces() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        guard case .responseCreate(let p, _)? = h.socket.sent(type: "response.create").last else { Issue.record("no create"); return }
        #expect(p?.maxOutputTokens == .limit(1024))
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 200),
               S.responseDone("r1", status: "incomplete", reason: "max_output_tokens"))
        let done = try #require(await h.log.wait { $0.responseDone != nil }?.responseDone)
        #expect(done.hitTokenLimit)
    }

    // MARK: R3 / R11 — echo

    /// R3: Dee's echo during playback does not preempt the tool follow-up.
    @Test func echoDuringPlaybackDoesNotPreemptFollowUp() async throws {
        let h = try await Harness.connected()
        await h.session.setToolHandler { _ in RealtimeToolResult(output: "{}", followUp: .always) }
        try await h.session.requestResponse()
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 2000),
               S.functionCallAdded("r1", "fc1", name: "recall"),
               S.callDone("r1", "fc1", call: "c1", name: "recall", args: "{}"),
               S.responseDone("r1"))
        #expect(await h.socket.waitForSent(type: "response.create", count: 2))   // follow-up, still playing
        h.push(S.speechStarted("echo1"))
        await h.sync()
        await h.session.rejectEcho(itemID: "echo1")
        h.push(S.responseCreated("r2"), S.messageAdded("r2", "a2"), S.audio("r2", "a2", ms: 200))
        await h.sync()
        #expect(!h.log.contains { if case .replyPreempted = $0 { true } else { false } })
        #expect(h.log.contains { if case .assistantAudio("a2", _) = $0 { true } else { false } })
        #expect(h.sentCount("response.cancel") == 0)
    }

    /// R3: the follow-up started on a gate that saw only echo (speech over playback)
    /// even if that speech is still open when the tool returns.
    @Test func followUpIsRequestedWhileEchoIsUndecided() async throws {
        let h = try await Harness.connected()
        let gate = AsyncStream<Void>.makeStream()
        await h.session.setToolHandler { _ in
            for await _ in gate.stream { break }
            return RealtimeToolResult(output: "{}", followUp: .always)
        }
        try await h.session.requestResponse()
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 2000),
               S.callDone("r1", "fc1", call: "c1", name: "recall", args: "{}"), S.responseDone("r1"),
               S.speechStarted("echo1"))
        await h.sync()
        gate.continuation.yield()
        #expect(await h.socket.waitForSent(type: "response.create", count: 2))
    }

    /// R3 (second line of defence): a follow-up preempted by speech that started
    /// after playback ended is requested again when that speech is rejected as echo.
    @Test func followUpPreemptedByEchoIsRequestedAgain() async throws {
        let h = try await Harness.connected()
        await h.session.setToolHandler { _ in RealtimeToolResult(output: "{}", followUp: .always) }
        try await h.session.requestResponse()
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 500),
               S.callDone("r1", "fc1", call: "c1", name: "recall", args: "{}"), S.responseDone("r1"))
        #expect(await h.socket.waitForSent(type: "response.create", count: 2))
        await h.session.playbackFinished()
        h.push(S.responseCreated("r2"), S.speechStarted("echo_tail"))   // the room's reverb tail
        #expect(await h.log.wait { $0 == .replyPreempted(responseID: "r2") } != nil)
        h.push(S.responseDone("r2", status: "cancelled", reason: "client_cancelled"))
        await h.log.wait { $0.responseDone?.responseID == "r2" }
        await h.session.rejectEcho(itemID: "echo_tail")
        #expect(h.sentCount("response.create") == 3)
        h.push(S.responseCreated("r3"))
        #expect(await h.log.wait { $0 == .responseStarted(responseID: "r3", kind: .toolFollowUp) } != nil)
    }

    /// R11: rejecting a committed item withdraws the unspoken reply requested for it.
    @Test func rejectEchoAfterCommitWithdrawsItsReply() async throws {
        let h = try await Harness.connected()
        h.push(S.speechStarted("u_echo"), S.speechStopped("u_echo"), S.committed("u_echo"))
        await h.log.wait { $0 == .userCommitted(itemID: "u_echo", previousItemID: nil) }
        try await h.session.requestResponse()
        h.push(S.responseCreated("r1"))
        await h.sync()
        await h.session.rejectEcho(itemID: "u_echo")
        #expect(await h.log.wait { $0 == .replyPreempted(responseID: "r1") } != nil)
        #expect(h.sent("response.cancel").contains { if case .responseCancel("r1", _) = $0 { true } else { false } })
        h.push(S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 200),
               S.responseDone("r1", status: "cancelled", reason: "client_cancelled"))
        await h.log.wait { $0.responseDone != nil }
        #expect(h.log.count(\.isAudio) == 0)
        #expect(h.sentCount("response.create") == 1)   // and nothing re-requested
    }

    // MARK: R6 — stale mic audio

    @Test func audioFromAFailedConnectIsNotReplayedLater() async throws {
        let sock1 = FakeSocket(autoHandshake: false)
        let h = Harness.make(sockets: [sock1])
        let connect = Task { try await h.session.connect() }
        #expect(await sock1.waitForSent(type: "session.update"))
        await h.session.appendAudio(Data(repeating: 9, count: 4800))
        sock1.push(S.error(code: "invalid_value", message: "bad", eventID: sock1.sentEvents.first?.eventID))
        _ = try? await connect.value
        await h.advance(by: 300)
        try await h.session.connect()
        #expect(h.socket.sent(type: "input_audio_buffer.append").isEmpty)
    }

    @Test func oldAudioIsNotFlushedAfterALongReconnect() async throws {
        var config = Harness.defaultConfig()
        config.reconnectDelays = [10]
        let h = try await Harness.connected(config: config)
        h.socket.drop()
        await h.log.wait { $0.fallback != nil }
        await h.session.appendAudio(Data(repeating: 7, count: 480))   // then the mic went quiet
        await h.advance(by: 10)
        let second = try #require(await h.factory.waitForSocket(count: 2))
        #expect(await h.log.wait { if case .recovered = $0 { true } else { false } } != nil)
        #expect(second.sent(type: "input_audio_buffer.append").isEmpty)
    }

    // MARK: R7 — history

    @Test func truncatedHistoryKeepsOnlyHeardSentences() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"),
               S.transcript("r1", "a1", "I went to the park. "),
               S.audio("r1", "a1", ms: 100),
               S.transcript("r1", "a1", "Then it rained hard. "),
               S.audio("r1", "a1", ms: 100),
               S.transcript("r1", "a1", "We ran home"),
               S.audio("r1", "a1", ms: 4000),
               S.transcriptDone("r1", "a1", "I went to the park. Then it rained hard. We ran home"),
               S.responseDone("r1"))
        await h.log.wait { $0.responseDone != nil }
        // 4200 ms over 52 characters: "park." ends at 1534 ms (midpoint 767).
        await h.session.bargeIn(playedMs: 900)
        #expect(await h.session.recentTurns.last?.text == "I went to the park.")
    }

    @Test func midGenerationTrimUsesTheSpeakingRate() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        // The transcript is far ahead of the audio (typical).
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"),
               S.transcript("r1", "a1", "I went to the park. Then it rained hard. We ran "),
               S.audio("r1", "a1", ms: 1200))
        await h.log.wait(\.isAudio)
        let hints = h.log.all.compactMap { e -> Int? in if case .assistantSentence(_, _, let ms) = e { ms } else { nil } }
        #expect(hints == [19 * 62, 40 * 62])   // speaking rate, not the 0 ms received so far
        await h.session.bargeIn(playedMs: 1000)
        h.push(S.responseDone("r1", status: "cancelled", reason: "client_cancelled"))
        await h.log.wait { $0.responseDone != nil }
        #expect(await h.session.recentTurns.last?.text == "I went to the park.")
    }

    // MARK: R8 — queued requests

    @Test func queuedRequestGetsAResponseDoneOnDrop() async throws {
        var config = Harness.defaultConfig()
        config.autoReconnect = false
        let h = try await Harness.connected(config: config)
        try await h.session.requestResponse()
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 500))
        await h.log.wait(\.isAudio)
        await h.session.bargeIn(playedMs: 200)
        #expect(try await h.session.requestResponse() == .queued)
        h.socket.drop()
        await h.log.wait { if case .disconnected = $0 { true } else { false } }
        let dones = h.log.all.compactMap(\.responseDone)
        #expect(dones.count == 2)
        #expect(dones.last?.reason == "connection_lost")
        #expect(dones.last?.responseID == nil)
    }

    @Test func secondQueuedRequestSupersedesTheFirst() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        h.push(S.responseCreated("r1"))
        await h.sync()
        await h.session.cancelUnspokenResponse()
        #expect(try await h.session.requestResponse(cueItem: "a") == .queued)
        #expect(try await h.session.requestResponse(cueItem: "b") == .queued)
        #expect(await h.log.wait { $0.responseDone?.reason == "superseded" } != nil)
        h.push(S.responseDone("r1", status: "cancelled", reason: "client_cancelled"))
        #expect(await h.socket.waitForSent(type: "response.create", count: 2))
        guard case .itemCreate(let cue, _, _)? = h.socket.sent(type: "conversation.item.create").last else { return }
        #expect(cue.text == "b")
    }

    @Test func closeEndsAQueuedRequest() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        await h.session.cancelUnspokenResponse()
        #expect(try await h.session.requestResponse() == .queued)
        await h.session.close()
        await h.log.wait { $0 == .disconnected(code: 1000, reason: "client") }
        #expect(h.log.all.compactMap(\.responseDone).count == 2)
    }

    // MARK: R9 — late response.created

    @Test func lateResponseCreatedDoesNotHijackTheNextRequest() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        let oldTag = try #require(Self.turnTag(h.socket))
        await h.advance(by: 10)     // response watchdog (tune 9: `responseTimeout` 10 s)
        await h.advance(by: 5.5)    // cancel watchdog → responseDone(no_response)
        await h.log.wait { $0.responseDone != nil }
        try await h.session.requestResponse()
        let newTag = try #require(Self.turnTag(h.socket))
        #expect(oldTag != newTag)
        h.push(S.responseCreated("r_old", metadata: ["dee_turn": oldTag]))   // finally, for request 1
        h.push(S.responseCreated("r_new", metadata: ["dee_turn": newTag]),
               S.messageAdded("r_new", "a_new"), S.audio("r_new", "a_new", ms: 200))
        await h.sync()
        #expect(h.log.contains { if case .assistantAudio("a_new", _) = $0 { true } else { false } })
        #expect(h.log.contains(.responseStarted(responseID: "r_new", kind: .reply)))
        #expect(!h.log.contains(.responseStarted(responseID: "r_old", kind: .reply)))
        #expect(h.sent("response.cancel").contains { if case .responseCancel("r_old", _) = $0 { true } else { false } })
    }

    private static func turnTag(_ socket: FakeSocket) -> String? {
        if case .responseCreate(let p, _)? = socket.sent(type: "response.create").last { p?.metadata?["dee_turn"] } else { nil }
    }

    // MARK: R10 — refused ephemeral secret

    @Test func refusedEphemeralSecretIsInvalidatedAndRetriedOnce() async throws {
        let calls = Mutex((credentials: 0, invalidated: 0))
        let factory = FakeSocketFactory([FakeSocket(openFailure: .unauthorized(status: 401)), FakeSocket()])
        let session = RealtimeSession(
            config: Harness.defaultConfig(),
            credentials: { _ in
                let n = calls.withLock { $0.credentials += 1; return $0.credentials }
                return .ephemeral("ek_\(n)", expiresAt: Date().addingTimeInterval(600))
            },
            invalidateCredential: { calls.withLock { $0.invalidated += 1 } },
            socketFactory: factory.factory, clock: ManualRealtimeClock())
        try await session.connect()
        #expect(calls.withLock { $0.credentials } == 2)
        #expect(calls.withLock { $0.invalidated } == 1)
        #expect(factory.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer ek_2")
        #expect(await session.state == .listening)
    }

    @Test func refusedDirectKeyIsNotRetried() async throws {
        let invalidated = Mutex(0)
        let factory = FakeSocketFactory([FakeSocket(openFailure: .unauthorized(status: 401)), FakeSocket()])
        let session = RealtimeSession(config: Harness.defaultConfig(), credentials: { _ in .direct("sk-bad") },
                                      invalidateCredential: { invalidated.withLock { $0 += 1 } },
                                      socketFactory: factory.factory, clock: ManualRealtimeClock())
        await #expect(throws: RealtimeSessionError.unauthorized(nil)) { try await session.connect() }
        #expect(invalidated.withLock { $0 } == 0)
        #expect(factory.made.count == 1)
    }

    // MARK: R12 — connect while an open is in flight

    @Test func connectWaitsForAnOpenStillUnwinding() async throws {
        let slow = FakeSocket(autoHandshake: false)
        let h = Harness.make(sockets: [slow])
        let first = Task { try await h.session.connect() }
        #expect(await slow.waitForSent(type: "session.update"))
        await h.session.close()
        try await h.session.connect()   // must not return without connecting
        await #expect(throws: RealtimeSessionError.closed) { try await first.value }
        #expect(await h.session.state == .listening)
        #expect(h.factory.made.count == 2)
        #expect(try await h.session.requestResponse() == .sent)
    }

    // MARK: R13 — speed between turns

    @Test func speedChangeWaitsForTheResponseToEnd() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        let before = h.sentCount("session.update")
        await h.session.updateSession(speed: 1.2)
        #expect(h.sentCount("session.update") == before)
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 100), S.responseDone("r1"))
        #expect(await h.socket.waitForSent(type: "session.update", count: before + 1))
        guard case .sessionUpdate(let s, _)? = h.socket.sent(type: "session.update").last else { return }
        #expect(s.audio?.output?.speed == 1.2)
        #expect(s.instructions == nil)
        // Instructions are not held back.
        try await h.session.requestResponse()
        await h.session.updateSession(instructions: "You are Dee. Sam is here.", speed: 0.9)
        guard case .sessionUpdate(let s2, _)? = h.socket.sent(type: "session.update").last else { return }
        #expect(s2.instructions == "You are Dee. Sam is here.")
        #expect(s2.audio == nil)
    }
}

private extension Harness {
    func sent(_ type: String) -> [ClientEvent] { socket.sent(type: type) }
}
