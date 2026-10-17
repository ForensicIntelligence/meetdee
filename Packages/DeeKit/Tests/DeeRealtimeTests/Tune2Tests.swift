import Foundation
import Testing
@testable import DeeRealtime

/// Tune 2 (live harness run 20261009-143612, F-FALL): a 429 during a reconnect
/// must be waited out for as long as the server asks and no longer, and the
/// user's words must survive it; a rollover must never switch while the user is
/// mid-turn, and whatever of a turn was still open is carried over.
extension FakeSocket {
    func pushAll(_ events: ServerEvent...) { events.forEach { push($0) } }
}

@Suite struct Tune2Tests {
    /// Audio bytes appended on a socket, in order.
    func appended(_ socket: FakeSocket) -> Data {
        socket.sent(type: "input_audio_buffer.append").reduce(into: Data()) { d, e in
            if case .inputAudioAppend(let b64, _) = e, let pcm = Data(base64Encoded: b64) { d.append(pcm) }
        }
    }

    /// `ms` of mic audio whose every byte is `value` (24 kHz PCM16 = 48 bytes/ms).
    func pcm(_ ms: Int, _ value: UInt8) -> Data { Data(repeating: value, count: ms * 48) }

    /// Feeds `ms` of audio in 20 ms chunks, moving the clock with it.
    func speak(_ h: Harness, ms: Int, value: UInt8, clock: Bool = true) async {
        for _ in 0..<(ms / 20) {
            await h.session.appendAudio(pcm(20, value))
            if clock { h.clock.advance(by: 0.02) }
        }
    }

    func origins(_ h: Harness) -> [Int] {
        h.log.all.compactMap { if case .uplinkOrigin(let f) = $0 { f } else { nil } }
    }

    func seedText(_ socket: FakeSocket) -> String? {
        for e in socket.sent(type: "conversation.item.create") {
            if case .itemCreate(let item, _, _) = e, item.role == "system", item.id == nil,
               let t = item.text, t.hasPrefix("[The conversation continues") { return t }
        }
        return nil
    }

    // MARK: 1. 429: honour the hint, keep the words

    /// Live trace fallback-429: drop at 20.92, the reconnect at 21.74 refused with
    /// `Retry-After: 1`, the next open only at 26.94 (a 5 s floor), live at 28.52.
    /// Now the retry goes out after 1 s plus at most 0.25 s of jitter.
    @Test func a429RetryAfterIsHonouredWithJitterNotFloored() async throws {
        let first = FakeSocket(sessionID: "sess_1")
        let refused = FakeSocket(openFailure: .rateLimited(retryAfter: 1))
        let h = Harness.make(sockets: [first, refused])
        try await h.session.connect()
        first.drop()
        #expect(await h.log.wait { if case .disconnected = $0 { true } else { false } } != nil)
        await h.advance(by: 0.5)                                       // first back-off step
        #expect(await h.log.wait { $0 == .fallbackAdvised(.rateLimited(retryAfter: 1)) } != nil)
        #expect(h.factory.made.count == 2)
        await h.advance(by: 0.99)
        #expect(h.factory.made.count == 2, "retried before the server's Retry-After")
        await h.advance(by: 0.27)                                      // 1.26 s: hint + max jitter
        let third = try #require(await h.factory.waitForSocket(count: 3))
        #expect(await h.log.wait { if case .recovered = $0 { true } else { false } } != nil)
        _ = await h.session.state                                       // the takeover has finished
        #expect(third.isOpen)
    }

    /// The other half of q06: "What did you do today?" was spoken during the
    /// outage and the 2 s buffer kept only "…a day". Even when the server asks
    /// for a long wait (here 5 s), the whole question reaches the new session,
    /// first on its timeline, positioned exactly.
    @Test func aQuestionSpokenDuringA429OutageReachesTheNewSessionWhole() async throws {
        let first = FakeSocket(sessionID: "sess_1")
        let refused = FakeSocket(openFailure: .rateLimited(retryAfter: 5))
        let h = Harness.make(sockets: [first, refused])
        try await h.session.connect()
        await speak(h, ms: 1_000, value: 1)                             // before the drop: live
        first.drop()
        #expect(await h.log.wait { if case .disconnected = $0 { true } else { false } } != nil)
        let fedAtDrop = 1_000 * 48
        await speak(h, ms: 500, value: 2, clock: false)
        await h.advance(by: 0.5)                                        // 429
        #expect(await h.log.wait { $0 == .fallbackAdvised(.rateLimited(retryAfter: 5)) } != nil)
        // Silence, then the question (2.05 s), then silence, all while refused.
        await speak(h, ms: 1_000, value: 2)
        await speak(h, ms: 2_040, value: 9)
        await speak(h, ms: 1_000, value: 2)
        await h.advance(by: 1.9)                                        // past 5 s + max jitter (0.85 s)
        let third = try #require(await h.factory.waitForSocket(count: 3))
        #expect(await h.log.wait { if case .recovered = $0 { true } else { false } } != nil)
        _ = await h.session.state                                       // the takeover has finished
        let got = appended(third)
        let expected = 4_540 * 48
        #expect(got.count == expected, "\(got.count) vs \(expected); \(h.log.all.filter { if case .rateLimits = $0 { false } else { true } }) made \(h.factory.made.count)")
        #expect(got.filter { $0 == 9 }.count == 2_040 * 48, "part of the question was lost")
        #expect(!h.log.contains { if case .uplinkDropped = $0 { true } else { false } })
        #expect(origins(h).last == fedAtDrop / 2)
    }

    /// A refusal that carries its hint only in the message ("try again in 1.5s").
    @Test func aHandshakeRateLimitMessageHintIsUsed() async throws {
        #expect(RealtimeSession.retryHint(in: "Rate limit reached for requests. Please try again in 1.5s.") == 1.5)
        #expect(RealtimeSession.retryHint(in: "Please try again in 350ms. Visit …") == 0.35)
        #expect(RealtimeSession.retryHint(in: "Rate limit reached") == nil)
        let sock = FakeSocket(autoHandshake: false)
        let h = Harness.make(sockets: [sock])
        let connect = Task { try await h.session.connect() }
        #expect(await sock.waitForSent(type: "session.update"))
        sock.push(S.error(type: "rate_limit_error", code: "rate_limit_exceeded",
                          message: "Rate limit reached for requests. Please try again in 1.5s."))
        await #expect(throws: RealtimeSessionError.rateLimited(retryAfter: 1.5)) { try await connect.value }
    }

    /// No hint at all: exponential back-off from 1 s with jitter (0.5–1 s, then
    /// 1–2 s, …), not 30 s; an exhausted limit's `reset_seconds` counts as a hint.
    @Test func anUnhinted429BacksOffExponentiallyFromOneSecond() async throws {
        let first = FakeSocket(sessionID: "sess_1")
        let h = Harness.make(sockets: [first, FakeSocket(openFailure: .rateLimited(retryAfter: nil)),
                                       FakeSocket(openFailure: .rateLimited(retryAfter: nil))])
        try await h.session.connect()
        first.drop()
        #expect(await h.log.wait { if case .disconnected = $0 { true } else { false } } != nil)
        await h.advance(by: 0.5)
        #expect(await h.factory.waitForSocket(count: 2) != nil)
        await h.advance(by: 0.49)
        #expect(h.factory.made.count == 2)
        await h.advance(by: 0.52)                                       // ≤ 1 s
        #expect(await h.factory.waitForSocket(count: 3) != nil)
        await h.advance(by: 0.99)
        #expect(h.factory.made.count == 3)
        await h.advance(by: 1.02)                                       // ≤ 2 s
        #expect(await h.factory.waitForSocket(count: 4) != nil)
        #expect(await h.log.wait { if case .recovered = $0 { true } else { false } } != nil)
        _ = await h.session.state                                       // the takeover has finished
    }

    @Test func anExhaustedRateLimitsResetIsTheHint() async throws {
        let first = FakeSocket(sessionID: "sess_1")
        let h = Harness.make(sockets: [first, FakeSocket(openFailure: .rateLimited(retryAfter: nil))])
        try await h.session.connect()
        first.pushAll(.rateLimitsUpdated(.init(rateLimits: [
            RateLimit(name: "requests", limit: 100, remaining: 0, resetSeconds: 3),
            RateLimit(name: "tokens", limit: 50_000, remaining: 40_000, resetSeconds: 60)])))
        // (not `h.sync()`: its marker is a rate_limits.updated too, and would replace these)
        #expect(await h.log.wait { if case .rateLimits(let l) = $0 { l.first?.remaining == 0 } else { false } } != nil)
        first.drop()
        #expect(await h.log.wait { if case .disconnected = $0 { true } else { false } } != nil)
        await h.advance(by: 0.5)
        #expect(await h.factory.waitForSocket(count: 2) != nil)
        await h.advance(by: 2.99)
        #expect(h.factory.made.count == 2)
        await h.advance(by: 0.6)                                        // 3 s + ≤ 0.55 s jitter
        #expect(await h.factory.waitForSocket(count: 3) != nil)
    }

    /// A 503 (overloaded) with `Retry-After` follows the same rule.
    @Test func a503RetryAfterIsHonoured() async throws {
        let first = FakeSocket(sessionID: "sess_1")
        let h = Harness.make(sockets: [first, FakeSocket(openFailure: .server(status: 503, retryAfter: 2))])
        try await h.session.connect()
        first.drop()
        #expect(await h.log.wait { if case .disconnected = $0 { true } else { false } } != nil)
        await h.advance(by: 0.5)
        #expect(await h.factory.waitForSocket(count: 2) != nil)
        await h.advance(by: 1.99)
        #expect(h.factory.made.count == 2)
        await h.advance(by: 0.45)
        #expect(await h.factory.waitForSocket(count: 3) != nil)
    }

    // MARK: 2. A drop keeps the user's unfinished turn

    /// Speech stopped but not committed when the connection died: the new session
    /// gets that audio again from its `audio_start_ms`, ahead of everything else.
    @Test func aDropAfterSpeechStoppedButBeforeTheCommitReplaysTheUtterance() async throws {
        let h = try await Harness.connected()
        let first = h.socket
        await speak(h, ms: 400, value: 1)                              // room tone
        await speak(h, ms: 800, value: 9)                              // "Are you awake?"
        await speak(h, ms: 300, value: 1)
        first.pushAll(S.speechStarted("u1", ms: 400), S.speechStopped("u1", ms: 1_200))
        await h.sync()
        first.drop()
        await h.advance(by: 0.5)
        let second = try #require(await h.factory.waitForSocket(count: 2))
        #expect(await h.log.wait { if case .recovered = $0 { true } else { false } } != nil)
        _ = await h.session.state                                       // the takeover has finished
        let got = appended(second)
        #expect(got == pcm(800, 9) + pcm(300, 1), "\(got.count) bytes, first \(got.first ?? 0)")
        #expect(origins(h).last == 400 * 24)                           // feed frame of 400 ms
    }

    /// Committed, its reply requested but without audio yet, then the drop: the
    /// turn is replayed (it gets a new commit and a new reply there) and is not
    /// also in the seed. A turn that was answered is not replayed.
    @Test func aDropBeforeTheReplyReplaysTheCommittedTurnNotTheAnsweredOnes() async throws {
        let h = try await Harness.connected()
        let first = h.socket
        await speak(h, ms: 1_000, value: 3)
        first.pushAll(S.speechStarted("u0", ms: 0), S.speechStopped("u0", ms: 1_000), S.committed("u0"),
                   S.userTranscript("u0", "Do you like music?"))
        await h.sync()
        try await h.session.requestResponse()
        first.pushAll(S.responseCreated("r0"), S.messageAdded("r0", "a0"), S.audio("r0", "a0", ms: 100),
                   S.transcriptDone("r0", "a0", "I love it."), S.responseDone("r0"))
        await h.log.wait { $0.responseDone != nil }
        await h.session.playbackFinished()
        await speak(h, ms: 500, value: 1)
        await speak(h, ms: 2_000, value: 9)
        first.pushAll(S.speechStarted("u1", ms: 1_500), S.speechStopped("u1", ms: 3_500), S.committed("u1"),
                   S.userTranscript("u1", "What did you do today?"))
        await h.sync()
        try await h.session.requestResponse()
        first.pushAll(S.responseCreated("r1"))
        await h.sync()
        first.drop()
        await h.advance(by: 0.5)
        let second = try #require(await h.factory.waitForSocket(count: 2))
        #expect(await h.log.wait { if case .recovered = $0 { true } else { false } } != nil)
        _ = await h.session.state                                       // the takeover has finished
        #expect(appended(second) == pcm(2_000, 9))
        let seed = try #require(seedText(second))
        #expect(seed.contains("Person: Do you like music?"))
        #expect(!seed.contains("What did you do today?"))
        #expect(await !h.session.recentTurns.contains { $0.text == "What did you do today?" })
    }

    @Test func aDropWithNothingUnfinishedReplaysNothing() async throws {
        let h = try await Harness.connected()
        let first = h.socket
        await speak(h, ms: 1_000, value: 3)
        first.drop()
        await h.advance(by: 0.5)
        let second = try #require(await h.factory.waitForSocket(count: 2))
        #expect(await h.log.wait { if case .recovered = $0 { true } else { false } } != nil)
        _ = await h.session.state                                       // the takeover has finished
        #expect(appended(second).isEmpty)
        #expect(origins(h).last == 1_000 * 24)
    }

    /// A carried turn is not replayed into a connection that comes back too late.
    @Test func aCarriedTurnGoesStale() async throws {
        var config = Harness.defaultConfig()
        config.reconnectDelays = [20]
        let h = try await Harness.connected(config: config)
        let first = h.socket
        await speak(h, ms: 600, value: 9)
        first.pushAll(S.speechStarted("u1", ms: 0))
        await h.sync()
        first.drop()
        await h.advance(by: 20)
        let second = try #require(await h.factory.waitForSocket(count: 2))
        #expect(await h.log.wait { if case .recovered = $0 { true } else { false } } != nil)
        _ = await h.session.state                                       // the takeover has finished
        #expect(appended(second).isEmpty)
        #expect(await h.log.wait { $0 == .uplinkDropped(frames: 600 * 24, atFeedFrame: 0, atServerMs: nil) } != nil)
    }

    // MARK: 3. Rollover never cuts the user off

    /// Live trace fallback-rollover q02: the idle rollover summarised at 25.56,
    /// "Are you awake?" started at 26.37 (link 1), link 2 was live at 27.57, and
    /// link 1's `speech_stopped` (27.748) let the switch happen before its commit:
    /// the item was never committed anywhere. Now the switch waits for the
    /// commit, the reply, and the end of Dee's playback.
    @Test func aRolloverNeverSwitchesBetweenSpeechStoppedAndTheCommit() async throws {
        var config = Harness.defaultConfig()
        config.rolloverAfter = 60
        let h = try await Harness.connected(config: config)
        let first = h.socket
        if let id = await h.session.addUserText("What's your favorite color?") {
            await h.session.userTurnHandled(itemID: id)
        }
        await h.advance(by: 61)
        #expect(await h.log.wait { $0 == .rolloverStarted(forced: false) } != nil)
        // The old session is asked for its summary; the user starts talking meanwhile.
        #expect(await first.waitForSent(type: "response.create"))
        guard case .responseCreate(let p, _)? = first.sent(type: "response.create").last,
              let purpose = p?.metadata?["purpose"] else { Issue.record("no summary request"); return }
        await speak(h, ms: 400, value: 1)
        first.pushAll(S.speechStarted("item_q02", ms: 25_740))
        first.pushAll(S.responseCreated("r_sum", metadata: ["purpose": purpose]),
                   .outputTextDone(.init(responseID: "r_sum", itemID: "s1", text: "Chatting about colours.")),
                   S.responseDone("r_sum", metadata: ["purpose": purpose]))
        let second = try #require(await h.factory.waitForSocket(count: 2))
        #expect(await second.waitForSent(type: "session.update"))
        await h.settle()
        await speak(h, ms: 800, value: 9)
        first.pushAll(S.speechStopped("item_q02", ms: 27_660))
        #expect(await h.log.wait { $0 == .userSpeechStopped(itemID: "item_q02", audioEndMs: 27_660) } != nil)
        await h.advance(by: 1)
        #expect(!h.log.contains { if case .rolledOver = $0 { true } else { false } }, "switched before the commit")
        #expect(first.closedByClient == nil)
        first.pushAll(S.committed("item_q02"), S.userTranscript("item_q02", "Are you awake?"))
        #expect(await h.log.wait { $0 == .userTranscript(itemID: "item_q02", text: "Are you awake?") } != nil)
        #expect(await h.log.wait { $0 == .userCommitted(itemID: "item_q02", previousItemID: nil) } != nil)
        await h.advance(by: 1)
        #expect(!h.log.contains { if case .rolledOver = $0 { true } else { false } }, "switched before the answer")
        try await h.session.requestResponse()
        first.pushAll(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 300),
                   S.transcriptDone("r1", "a1", "Wide awake!"), S.responseDone("r1"))
        await h.log.wait { $0.responseDone?.status == "completed" }
        await h.advance(by: 1)
        #expect(!h.log.contains { if case .rolledOver = $0 { true } else { false } }, "switched mid-playback")
        await h.session.playbackFinished()
        #expect(await h.log.wait { if case .rolledOver = $0 { true } else { false } } != nil)
        #expect(seedText(second)?.contains("Person: Are you awake?") == true)
        #expect(seedText(second)?.contains("Dee: Wide awake!") == true)
    }

    /// A commit that never comes (the server cleared the buffer) does not hold the
    /// rollover forever.
    @Test func aStoppedSpeechWithoutCommitStopsHoldingAfterCommitWait() async throws {
        var config = Harness.defaultConfig()
        config.rolloverAfter = 60
        config.rolloverSummary = .none
        let h = try await Harness.connected(config: config)
        await h.advance(by: 59)
        h.push(S.speechStarted("u1"), S.speechStopped("u1"))
        await h.sync()
        await h.advance(by: 2)
        await h.advance(by: 1)
        #expect(!h.log.contains { $0 == .rolloverStarted(forced: false) })
        await h.advance(by: 6)
        await h.advance(by: 1)
        #expect(await h.log.wait { $0 == .rolloverStarted(forced: false) } != nil)
    }

    /// Local speech (the app's VAD, ahead of the server's `speech_started`) holds
    /// the rollover too.
    @Test func localSpeechHoldsTheRollover() async throws {
        var config = Harness.defaultConfig()
        config.rolloverAfter = 60
        config.rolloverSummary = .none
        let h = try await Harness.connected(config: config)
        await h.session.setLocalSpeech(true)
        await h.advance(by: 61)
        await h.advance(by: 1)
        #expect(!h.log.contains { $0 == .rolloverStarted(forced: false) })
        await h.session.setLocalSpeech(false)
        await h.advance(by: 1)
        #expect(await h.log.wait { if case .rolledOver = $0 { true } else { false } } != nil)
    }

    /// A forced switch after the user's 30 s grace (the only switch that can
    /// still happen mid-utterance) replays the open utterance into the new session
    /// from its start instead of losing it.
    @Test func aForcedSwitchMidUtteranceCarriesTheAudioOver() async throws {
        var config = Harness.defaultConfig()
        config.rolloverSummary = .none
        let h = try await Harness.connected(config: config)
        let first = h.socket
        await h.advance(by: 59 * 60)
        #expect(await h.log.wait { if case .rolloverStarted = $0 { true } else { false } } != nil)
        _ = await h.factory.waitForSocket(count: 2)
        // The rollover went through at once (idle). Run the next one with speech open.
        #expect(await h.log.wait { if case .rolledOver = $0 { true } else { false } } != nil)
        let second = h.socket
        #expect(second !== first)
        await speak(h, ms: 300, value: 1, clock: false)
        await speak(h, ms: 1_000, value: 9, clock: false)
        second.pushAll(S.speechStarted("u_long", ms: 300))
        await h.sync()
        await h.advance(by: 59 * 60)
        #expect(await h.factory.waitForSocket(count: 3) != nil)
        await h.settle()
        #expect(h.log.count { if case .rolledOver = $0 { true } else { false } } == 1)
        await h.advance(by: 30)
        await h.advance(by: 1)
        let rolled: @Sendable (RealtimeEvent) -> Bool = { if case .rolledOver = $0 { true } else { false } }
        #expect(await h.log.wait { _ in h.log.count(rolled) == 2 } != nil)
        _ = await h.session.state
        let third = h.socket
        #expect(appended(third) == pcm(1_000, 9))
        let fedBeforeSecond = 0                                          // second session started at feed 0
        #expect(origins(h).last == fedBeforeSecond + 300 * 24)
    }

    // MARK: 4. Early commit seam

    @Test func commitUserSpeechOnlyWhileATurnIsOpenAndItsRaceIsQuiet() async throws {
        let h = try await Harness.connected()
        #expect(await !h.session.commitUserSpeech())
        h.push(S.speechStarted("u1"), S.speechStopped("u1"))
        await h.sync()
        #expect(await h.session.commitUserSpeech())
        let eid = try #require(h.socket.sent(type: "input_audio_buffer.commit").last?.eventID)
        // The server's VAD committed first: the empty-buffer error is expected.
        h.push(S.error(code: "input_audio_buffer_commit_empty", message: "buffer too small", eventID: eid))
        h.push(S.committed("u1"))
        await h.sync()
        #expect(!h.log.contains { if case .error = $0 { true } else { false } })
        #expect(await !h.session.commitUserSpeech())
    }
}
