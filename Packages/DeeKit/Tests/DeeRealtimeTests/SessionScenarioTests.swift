import Foundation
import Testing
@testable import DeeRealtime

/// `RealtimeSession` against scripted server traffic (design §7.2, layer 1).
/// Fake sockets, a manual clock, no network.
@Suite struct SessionScenarioTests {
    // MARK: Connect

    @Test func connectSendsDeeSessionAndAuth() async throws {
        let h = try await Harness.connected()
        #expect(await h.session.state == .listening)
        let first = try #require(h.socket.sentEvents.first)
        guard case .sessionUpdate(let s, _) = first else { Issue.record("first frame \(first.type)"); return }
        #expect(s.model == "gpt-realtime-2.1-mini")
        #expect(s.audio?.input?.turnDetection == .value(.semanticManual()))
        #expect(s.audio?.input?.noiseReduction == .value(.farField))
        #expect(s.audio?.input?.transcription?.value?.model == "gpt-transcribe")
        #expect(h.socket.sent.first?.contains(#""tracing":null"#) == true)   // explicit null, not absent
        #expect(s.truncation == .retentionRatio(0.8))
        #expect(s.audio?.output?.voice == .named("marin"))
        let req = try #require(h.factory.requests.first)
        #expect(req.url?.absoluteString == "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer ek_test")
        #expect(req.value(forHTTPHeaderField: "OpenAI-Beta") == nil)   // GA: no beta header
        #expect(await h.log.wait { if case .connected(let id, _) = $0 { id?.hasPrefix("sess_") == true } else { false } } != nil)
    }

    @Test func rejectedConfigFailsConnect() async throws {
        let sock = FakeSocket(autoHandshake: false)
        let h = Harness.make(sockets: [sock])
        let connect = Task { try await h.session.connect() }
        #expect(await sock.waitForSent(type: "session.update"))
        let eid = sock.sentEvents.first?.eventID
        sock.push(S.error(code: "invalid_value", message: "Invalid voice", eventID: eid))
        await #expect(throws: RealtimeSessionError.configRejected("Invalid voice")) { try await connect.value }
        #expect(await h.session.state == .idle)
    }

    @Test func audioBeforeHandshakeIsKeptAndFlushed() async throws {
        let sock = FakeSocket(autoHandshake: false)
        let h = Harness.make(sockets: [sock])
        let connect = Task { try await h.session.connect() }
        #expect(await sock.waitForSent(type: "session.update"))
        await h.session.appendAudio(Data(repeating: 1, count: 960))   // 20 ms
        await h.session.appendAudio(Data(repeating: 2, count: 960))
        #expect(!sock.sentTypes.contains("input_audio_buffer.append"))
        sock.push(.sessionUpdated(.init(session: SessionInfo(raw: ["id": "sess_x"]))))
        try await connect.value
        let appends = sock.sent(type: "input_audio_buffer.append")
        guard case .inputAudioAppend(let b64, _)? = appends.first else { Issue.record("no flush"); return }
        #expect(Data(base64Encoded: b64) == Data(repeating: 1, count: 960) + Data(repeating: 2, count: 960))
    }

    // MARK: Normal turn

    @Test func normalTurn() async throws {
        let h = try await Harness.connected()
        await h.session.appendAudio(Data(count: 960))
        guard case .inputAudioAppend(let b64, _)? = h.socket.sent(type: "input_audio_buffer.append").first else {
            Issue.record("no append"); return
        }
        #expect(Data(base64Encoded: b64)?.count == 960)

        h.push(S.speechStarted("item_u1"))
        await h.sync()
        #expect(await h.session.state == .userTurn)
        h.push(S.speechStopped("item_u1"), S.committed("item_u1"))
        #expect(await h.log.wait { $0 == .userCommitted(itemID: "item_u1", previousItemID: nil) } != nil)
        #expect(await h.session.state == .listening)

        let outcome = try await h.session.requestResponse(cueItem: "<dee_state>glad</dee_state>")
        #expect(outcome == .sent)
        #expect(await h.session.state == .awaitingResponse)
        let tail = h.socket.sentEvents.suffix(2)
        guard case .itemCreate(let cue, _, _) = tail.first, case .responseCreate(let params, _) = tail.last else {
            Issue.record("expected cue item then response.create, got \(tail.map(\.type))"); return
        }
        #expect(cue.role == "system")
        #expect(cue.text == "<dee_state>glad</dee_state>")
        #expect(params?.maxOutputTokens == .limit(1024))
        #expect(params?.metadata?["dee_turn"] != nil)   // binds response.created to this request
        #expect(params?.conversation == nil)   // default conversation

        h.push(S.responseCreated("resp_1"), S.messageAdded("resp_1", "item_a1"),
               S.transcript("resp_1", "item_a1", "Hi there. How"),
               S.audio("resp_1", "item_a1", ms: 100),
               S.transcript("resp_1", "item_a1", " are you?"),
               S.audio("resp_1", "item_a1", ms: 100),
               S.audioDone("resp_1", "item_a1"),
               S.transcriptDone("resp_1", "item_a1", "Hi there. How are you?"),
               S.responseDone("resp_1", output: [RealtimeItem(id: "item_a1", type: "message", role: "assistant")],
                              usage: Usage(totalTokens: 50)),
               S.userTranscript("item_u1", "Hello Dee"))
        let done = try #require(await h.log.wait { $0.responseDone != nil }?.responseDone)
        #expect(done.status == "completed")
        #expect(done.kind == .reply)
        #expect(done.audioMs == 200)
        #expect(done.usage?.totalTokens == 50)
        #expect(done.transcript == "Hi there. How are you?")
        await h.sync()
        let log = h.log.all
        #expect(log.contains(.responseStarted(responseID: "resp_1", kind: .reply)))
        #expect(log.filter(\.isAudio).count == 2)
        // Before any audio: placed at the speaking rate (9 chars × 62 ms). After the
        // audio is complete: its share of it (the whole item ends at 200 ms), but
        // never before the previous sentence's end (HeardRule: placements are final).
        #expect(log.contains(.assistantSentence(itemID: "item_a1", text: "Hi there.", audioMsHint: 558)))
        #expect(log.contains(.assistantSentence(itemID: "item_a1", text: "How are you?", audioMsHint: 558)))
        #expect(log.contains(.assistantAudioDone(itemID: "item_a1", totalMs: 200)))
        #expect(log.contains(.userTranscript(itemID: "item_u1", text: "Hello Dee")))
        // Still playing until the app says the player drained.
        #expect(await h.session.state == .speaking)
        await h.session.playbackFinished()
        #expect(await h.session.state == .listening)
        let turns = await h.session.recentTurns
        #expect(turns.map(\.text) == ["Hello Dee", "Hi there. How are you?"])
        // Exactly one response.create: Dee never answers by herself.
        #expect(h.sentCount("response.create") == 1)
    }

    @Test func secondRequestWhileGeneratingThrows() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        await #expect(throws: RealtimeSessionError.responseInFlight) { try await h.session.requestResponse() }
    }

    // MARK: Barge-in

    @Test func bargeInMidGenerationCancelsAndTruncatesExactly() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        h.push(S.responseCreated("resp_1"), S.messageAdded("resp_1", "item_a1"))
        for _ in 0..<5 { h.push(S.audio("resp_1", "item_a1", ms: 200)) }   // 1000 ms received
        h.push(S.speechStarted("item_u2"))
        await h.sync()
        #expect(await h.session.state == .speaking)   // audio started: no auto-preempt
        let before = h.socket.sent.count

        let outcome = await h.session.bargeIn(playedMs: 640)
        #expect(outcome.cancelledResponse)
        #expect(outcome.truncatedItemID == "item_a1")
        #expect(outcome.audioEndMs == 640)
        let sent = Array(h.socket.sentEvents.suffix(from: before))
        #expect(sent.map(\.type) == ["response.cancel", "conversation.item.truncate"])
        guard case .responseCancel(let rid, _) = sent[0],
              case .itemTruncate(let item, let index, let end, _) = sent[1] else { Issue.record("\(sent)"); return }
        #expect(rid == "resp_1")
        #expect(item == "item_a1")
        #expect(index == 0)
        #expect(end == 640)   // audio_end_ms == playedMs
        #expect(await h.session.state == .cancelling)

        // Late audio from the cancelled response is never played.
        let audioBefore = h.log.count(\.isAudio)
        h.push(S.audio("resp_1", "item_a1", ms: 200), S.transcript("resp_1", "item_a1", "late words"))
        h.push(S.responseDone("resp_1", status: "cancelled", reason: "client_cancelled"))
        let done = try #require(await h.log.wait { $0.responseDone != nil }?.responseDone)
        #expect(done.status == "cancelled")
        #expect(done.reason == "client_cancelled")
        #expect(h.log.count(\.isAudio) == audioBefore)
        #expect(h.log.contains(.assistantTruncated(itemID: "item_a1", audioEndMs: 640)))
        #expect(await h.session.state == .userTurn)
        #expect(!h.log.contains { if case .assistantTranscriptDelta(_, let d) = $0 { d == "late words" } else { false } })
    }

    @Test func bargeInAfterDoneTruncatesWithoutCancel() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        h.push(S.responseCreated("resp_1"), S.messageAdded("resp_1", "item_a1"),
               S.transcript("resp_1", "item_a1", "One. Two. Three."),
               S.audio("resp_1", "item_a1", ms: 1500),
               S.transcriptDone("resp_1", "item_a1", "One. Two. Three."),
               S.responseDone("resp_1"))
        await h.log.wait { $0.responseDone != nil }
        let before = h.socket.sent.count
        let outcome = await h.session.bargeIn(playedMs: 400)
        #expect(!outcome.cancelledResponse)
        let sent = Array(h.socket.sentEvents.suffix(from: before))
        #expect(sent == [.itemTruncate(itemID: "item_a1", contentIndex: 0, audioEndMs: 400, eventID: sent.first?.eventID)])
        #expect(await h.session.state == .listening)
        // History keeps only what was heard: 1500 ms over 16 characters puts
        // "One." at 0–250 ms and "Two." at 312–562 ms (midpoint 437 > 400).
        let turns = await h.session.recentTurns
        #expect(turns.last?.role == .assistant)
        #expect(turns.last?.text == "One.")
    }

    @Test func bargeInAfterEverythingPlayedSendsNothing() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        h.push(S.responseCreated("resp_1"), S.messageAdded("resp_1", "item_a1"),
               S.audio("resp_1", "item_a1", ms: 500), S.responseDone("resp_1"))
        await h.log.wait { $0.responseDone != nil }
        let before = h.socket.sent.count
        let outcome = await h.session.bargeIn(playedMs: 900)   // clamps to 500 = all of it
        #expect(outcome.truncatedItemID == nil)
        #expect(h.socket.sent.count == before)
    }

    // MARK: Echo

    @Test func echoItemIsDeletedAndNeverAnswered() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        h.push(S.responseCreated("resp_1"), S.messageAdded("resp_1", "item_a1"),
               S.audio("resp_1", "item_a1", ms: 300), S.responseDone("resp_1"))
        await h.log.wait { $0.responseDone != nil }
        // The server hears Dee's own voice through the speaker.
        h.push(S.speechStarted("item_echo"))
        await h.log.wait { $0 == .userSpeechStarted(itemID: "item_echo", audioStartMs: 100) }
        await h.session.rejectEcho(itemID: "item_echo")
        #expect(!h.socket.sentTypes.contains("conversation.item.delete"))   // not committed yet
        h.push(S.speechStopped("item_echo"), S.committed("item_echo"), S.userTranscript("item_echo", "dee's own words"))
        await h.sync()
        let deletes = h.socket.sent(type: "conversation.item.delete")
        #expect(deletes.count == 1)
        if case .itemDelete(let id, _)? = deletes.first { #expect(id == "item_echo") }
        #expect(!h.log.contains { if case .userCommitted("item_echo", _) = $0 { true } else { false } })
        #expect(!h.log.contains { if case .userTranscript("item_echo", _) = $0 { true } else { false } })
        #expect(!h.log.contains { if case .userSpeechStopped("item_echo", _) = $0 { true } else { false } })
        #expect(h.log.contains(.echoRejected(itemID: "item_echo")))
        #expect(h.sentCount("response.create") == 1)   // no reply
        #expect(await h.session.recentTurns.allSatisfy { $0.itemID != "item_echo" })

        // Rejected after commit: deleted at once.
        h.push(S.speechStarted("item_echo2"), S.speechStopped("item_echo2"), S.committed("item_echo2"))
        await h.log.wait { $0 == .userCommitted(itemID: "item_echo2", previousItemID: nil) }
        await h.session.rejectEcho(itemID: "item_echo2")
        #expect(h.socket.sent(type: "conversation.item.delete").count == 2)
    }

    // MARK: Tools

    @Test func toolCallThenOutputThenResponse() async throws {
        let h = try await Harness.connected()
        await h.session.setToolHandler { call in
            #expect(call.name == "recall")
            #expect(call.argumentsJSON?["query"] == "dad")
            return RealtimeToolResult(output: #"{"memory":"his dad fixes clocks"}"#, followUp: .always)
        }
        try await h.session.requestResponse()
        h.push(S.responseCreated("resp_1"), S.functionCallAdded("resp_1", "fc_1", name: "recall"),
               S.callDone("resp_1", "fc_1", call: "call_1", name: "recall", args: #"{"query":"dad"}"#),
               S.responseDone("resp_1", output: [RealtimeItem(id: "fc_1", type: "function_call", status: "completed",
                                                              callID: "call_1", name: "recall", arguments: #"{"query":"dad"}"#)]))
        #expect(await h.log.wait { if case .toolCall(let c) = $0 { c.callID == "call_1" } else { false } } != nil)
        #expect(await h.socket.waitForSent(type: "response.create", count: 2))
        let tail = Array(h.socket.sentEvents.suffix(2))
        guard case .itemCreate(let out, _, _) = tail[0], case .responseCreate = tail[1] else {
            Issue.record("expected output then response.create, got \(tail.map(\.type))"); return
        }
        #expect(out.type == "function_call_output")
        #expect(out.callID == "call_1")
        #expect(out.output == #"{"memory":"his dad fixes clocks"}"#)
        h.push(S.responseCreated("resp_2"))
        #expect(await h.log.wait { $0 == .responseStarted(responseID: "resp_2", kind: .toolFollowUp) } != nil)
    }

    @Test func rememberAfterSpeakingNeedsNoFollowUp() async throws {
        let h = try await Harness.connected()
        await h.session.setToolHandler { _ in RealtimeToolResult(output: #"{"ok":true}"#) }   // .ifSilent
        try await h.session.requestResponse()
        h.push(S.responseCreated("resp_1"), S.messageAdded("resp_1", "item_a1"),
               S.audio("resp_1", "item_a1", ms: 400),
               S.functionCallAdded("resp_1", "fc_1", name: "remember"),
               S.callDone("resp_1", "fc_1", call: "call_r", name: "remember", args: #"{"fact":"likes tea"}"#),
               S.responseDone("resp_1"))
        #expect(await h.socket.waitForSent(type: "conversation.item.create"))
        await h.sync()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.sentCount("response.create") == 1)
        #expect(h.socket.sent(type: "conversation.item.create").count == 1)

        // A bare remember (nothing said) does get a follow-up.
        await h.session.playbackFinished()
        try await h.session.requestResponse()
        h.push(S.responseCreated("resp_2"), S.functionCallAdded("resp_2", "fc_2", name: "remember"),
               S.callDone("resp_2", "fc_2", call: "call_r2", name: "remember", args: "{}"),
               S.responseDone("resp_2"))
        #expect(await h.socket.waitForSent(type: "response.create", count: 3))
    }

    @Test func toolCallsInCancelledResponseGetOutputsButNoFollowUp() async throws {
        let h = try await Harness.connected()
        await h.session.setToolHandler { _ in RealtimeToolResult(output: "{}", followUp: .always) }
        try await h.session.requestResponse()
        h.push(S.responseCreated("resp_1"),
               S.callDone("resp_1", "fc_1", call: "call_1", name: "recall", args: "{}"),
               S.speechStarted("item_u2"))   // user keeps talking → reply preempted
        #expect(await h.log.wait { $0 == .replyPreempted(responseID: "resp_1") } != nil)
        h.push(S.responseDone("resp_1", status: "cancelled", reason: "client_cancelled"))
        #expect(await h.socket.waitForSent(type: "conversation.item.create"))
        await h.sync()
        #expect(h.sentCount("response.create") == 1)
    }

    // MARK: Initiatives

    @Test func initiativeRacingSpeechStartedIsCancelled() async throws {
        let h = try await Harness.connected()
        let sent = await h.session.initiative(instructions: "You notice the lamp; say one short thing about it.")
        #expect(sent == .sent)
        guard case .responseCreate(let p, _)? = h.socket.sent(type: "response.create").last else { Issue.record("no create"); return }
        #expect(p?.instructions == "You notice the lamp; say one short thing about it.")

        // The user starts talking before the server even acknowledged the response.
        h.push(S.speechStarted("item_u1"))
        #expect(await h.log.wait { $0 == .initiativeCancelled(responseID: nil) } != nil)
        h.push(S.responseCreated("resp_i"))
        #expect(await h.socket.waitForSent(type: "response.cancel"))
        guard case .responseCancel(let rid, _)? = h.socket.sent(type: "response.cancel").last else { return }
        #expect(rid == "resp_i")
        h.push(S.messageAdded("resp_i", "item_i"), S.audio("resp_i", "item_i", ms: 200),
               S.responseDone("resp_i", status: "cancelled", reason: "client_cancelled"))
        await h.log.wait { $0.responseDone != nil }
        #expect(h.log.count(\.isAudio) == 0)   // she never talked over the user
        #expect(!h.log.contains(.responseStarted(responseID: "resp_i", kind: .initiative)))
        #expect(await h.session.state == .userTurn)

        // While the user talks, initiatives are refused outright.
        #expect(await h.session.initiative(instructions: "x") == .refused(.userSpeaking))
    }

    @Test func initiativeSecondGateAtFirstAudio() async throws {
        let h = try await Harness.connected()
        #expect(await h.session.initiative(instructions: "Say hi.") == .sent)
        h.push(S.responseCreated("resp_i"), S.speechStarted("item_u1"))
        #expect(await h.log.wait { $0 == .initiativeCancelled(responseID: "resp_i") } != nil)
        #expect(await h.socket.waitForSent(type: "response.cancel"))
        #expect(h.log.count(\.isAudio) == 0)
    }

    @Test func initiativeRefusedWhileBusy() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        #expect(await h.session.initiative(instructions: "x") == .refused(.responseInFlight))
        h.push(S.responseCreated("resp_1"), S.messageAdded("resp_1", "a"), S.audio("resp_1", "a", ms: 100),
               S.responseDone("resp_1"))
        await h.log.wait { $0.responseDone != nil }
        #expect(await h.session.initiative(instructions: "x") == .refused(.speaking))
        await h.session.playbackFinished()
        #expect(await h.session.initiative(instructions: "x") == .sent)
    }

    @Test func replyPreemptedWhenUserContinues() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        h.push(S.responseCreated("resp_1"), S.speechStarted("item_u2"))
        #expect(await h.log.wait { $0 == .replyPreempted(responseID: "resp_1") } != nil)
        #expect(await h.socket.waitForSent(type: "response.cancel"))
        // A new request while the cancel is closing is queued, then sent after done.
        #expect(try await h.session.requestResponse(cueItem: "cue2") == .queued)
        #expect(h.sentCount("response.create") == 1)
        h.push(S.responseDone("resp_1", status: "cancelled", reason: "client_cancelled"))
        #expect(await h.socket.waitForSent(type: "response.create", count: 2))
        #expect(h.socket.sent(type: "conversation.item.create").count == 1)   // cue2
    }

    // MARK: Failures

    @Test func socketDropMidResponseAdvisesFallbackAndReconnectsSeeded() async throws {
        let h = try await Harness.connected()
        h.push(S.speechStarted("u1"), S.speechStopped("u1"), S.committed("u1"), S.userTranscript("u1", "tell me a story"))
        await h.log.wait { $0 == .userTranscript(itemID: "u1", text: "tell me a story") }
        try await h.session.requestResponse()
        h.push(S.responseCreated("resp_1"), S.messageAdded("resp_1", "a1"), S.audio("resp_1", "a1", ms: 300))
        await h.log.wait(\.isAudio)
        let first = h.socket
        first.drop()

        let done = try #require(await h.log.wait { $0.responseDone != nil }?.responseDone)
        #expect(done.status == "failed")
        #expect(done.reason == "connection_lost")
        #expect(await h.log.wait { if case .socketLost(1006, _)? = $0.fallback { true } else { false } } != nil)
        #expect(h.log.contains { if case .disconnected(1006, _) = $0 { true } else { false } })
        #expect(await h.session.state == .connecting)
        // Mic audio during the gap is kept for the new session.
        await h.session.appendAudio(Data(repeating: 7, count: 480))

        await h.advance(by: 0.5)
        let second = try #require(await h.factory.waitForSocket(count: 2))
        #expect(await h.log.wait { if case .recovered = $0 { true } else { false } } != nil)
        #expect(second !== first)
        let types = second.sentTypes
        #expect(types.first == "session.update")
        #expect(types.dropFirst().first == "conversation.item.create")
        guard case .itemCreate(let seed, _, _)? = second.sent(type: "conversation.item.create").first else { return }
        #expect(seed.role == "system")
        #expect(seed.text?.contains("Person: tell me a story") == true)
        #expect(types.contains("input_audio_buffer.append"))
        #expect(await h.session.state == .listening)
    }

    @Test func reconnectBacksOff() async throws {
        var config = Harness.defaultConfig()
        config.reconnectDelays = [0.5, 2]
        let h = try await Harness.connected(config: config, sockets: [
            FakeSocket(), FakeSocket(openFailure: .network("offline")), FakeSocket(openFailure: .network("offline")),
        ])
        h.socket.drop()
        await h.log.wait { $0.fallback != nil }
        await h.advance(by: 0.5)
        #expect(await h.factory.waitForSocket(count: 2) != nil)
        await h.settle()
        await h.advance(by: 1)   // second delay is 2 s: nothing yet
        await h.settle()
        #expect(h.factory.made.count == 2)
        await h.advance(by: 1)
        #expect(await h.factory.waitForSocket(count: 3) != nil)
        await h.settle()
        await h.advance(by: 2)
        #expect(await h.factory.waitForSocket(count: 4) != nil)
        #expect(await h.log.wait { if case .recovered = $0 { true } else { false } } != nil)
        // One fallback advice for the whole outage, not one per attempt.
        #expect(h.log.count { $0.fallback != nil } == 1)
    }

    @Test func rateLimitOnConnectAdvisesFallback() async throws {
        let h = Harness.make(sockets: [FakeSocket(openFailure: .rateLimited(retryAfter: 20))])
        await #expect(throws: RealtimeSessionError.rateLimited(retryAfter: 20)) { try await h.session.connect() }
        #expect(await h.log.wait { $0 == .fallbackAdvised(.rateLimited(retryAfter: 20)) } != nil)
        #expect(await h.session.state == .idle)
    }

    @Test func rateLimitMidSessionFailsTheTurnAndAdvises() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        let eid = h.socket.sent(type: "response.create").last?.eventID
        h.push(S.error(type: "rate_limit_error", code: "rate_limit_exceeded", message: "Rate limit reached", eventID: eid))
        let done = try #require(await h.log.wait { $0.responseDone != nil }?.responseDone)
        #expect(done.status == "failed")
        #expect(await h.log.wait { $0 == .fallbackAdvised(.rateLimited(retryAfter: nil)) } != nil)
        #expect(h.log.contains { if case .error(let i) = $0 { i.kind == .rateLimit } else { false } })
        #expect(await h.session.state == .listening)
        // Spend cap reached on a later response.
        try await h.session.requestResponse()
        h.push(S.responseCreated("resp_2"),
               .responseDone(.init(response: ResponseObject(id: "resp_2", status: "failed", statusDetails:
                    ResponseStatusDetails(type: "failed", reason: nil, error: .init(type: "insufficient_quota", code: "insufficient_quota"))))))
        #expect(await h.log.wait { $0 == .fallbackAdvised(.quotaExceeded) } != nil)
    }

    @Test func missingKeyAndBadKey() async throws {
        let none = Harness.make(credentials: { _ in throw RealtimeAuthError.noKey })
        await #expect(throws: RealtimeSessionError.noKey) { try await none.session.connect() }
        #expect(await none.log.wait { $0 == .fallbackAdvised(.noKey) } != nil)

        // Refused, then refused again with a fresh credential: the key is bad.
        let bad = Harness.make(sockets: [FakeSocket(openFailure: .unauthorized(status: 401)),
                                         FakeSocket(openFailure: .unauthorized(status: 401))])
        await #expect(throws: RealtimeSessionError.unauthorized(nil)) { try await bad.session.connect() }
        #expect(await bad.log.wait { $0 == .fallbackAdvised(.unauthorized) } != nil)
    }

    @Test func noResponseWatchdog() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        // Tune 9 (T8-2): the backstop is `responseTimeout` (10 s), not 2.5 s.
        await h.advance(by: 2.5)
        #expect(!h.log.contains(.fallbackAdvised(.noResponse)))
        await h.advance(by: 7.5)
        #expect(await h.log.wait { $0 == .fallbackAdvised(.noResponse) } != nil)
        #expect(await h.session.state == .cancelling)
        // It shows up late: cancelled at once, never heard.
        h.push(S.responseCreated("resp_late"), S.messageAdded("resp_late", "x"), S.audio("resp_late", "x", ms: 100))
        #expect(await h.socket.waitForSent(type: "response.cancel"))
        h.push(S.responseDone("resp_late", status: "cancelled", reason: "client_cancelled"))
        await h.log.wait { $0.responseDone != nil }
        #expect(h.log.count(\.isAudio) == 0)
        #expect(await h.session.state == .listening)
        // A later healthy response re-arms the advice.
        try await h.session.requestResponse()
        h.push(S.responseCreated("resp_ok"))
        await h.sync()
        try await Task.sleep(for: .milliseconds(1))
        let advices = h.log.count { $0 == .fallbackAdvised(.noResponse) }
        #expect(advices == 1)
    }

    @Test func silentResponseIsGivenUp() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        h.push(S.responseCreated("resp_1"))
        await h.log.wait { $0 == .responseStarted(responseID: "resp_1", kind: .reply) }
        await h.advance(by: 6)
        #expect(await h.log.wait { $0 == .fallbackAdvised(.noResponse) } != nil)
        #expect(await h.socket.waitForSent(type: "response.cancel"))
        #expect(await h.session.state == .cancelling)
    }

    @Test func slowToolFromAnEarlierResponseStillGetsItsOutput() async throws {
        let h = try await Harness.connected()
        let gate = AsyncStream<Void>.makeStream()
        await h.session.setToolHandler { call in
            if call.name == "slow" { for await _ in gate.stream { break } }
            return RealtimeToolResult(output: #"{"\#(call.name)":1}"#, followUp: .never)
        }
        try await h.session.requestResponse()
        h.push(S.responseCreated("r1"), S.callDone("r1", "f1", call: "c_slow", name: "slow", args: "{}"), S.responseDone("r1"))
        await h.log.wait { $0.responseDone?.responseID == "r1" }
        try await h.session.requestResponse()
        h.push(S.responseCreated("r2"), S.callDone("r2", "f2", call: "c_fast", name: "fast", args: "{}"), S.responseDone("r2"))
        await h.log.wait { $0.responseDone?.responseID == "r2" }
        await h.sync()
        #expect(h.socket.sent(type: "conversation.item.create").isEmpty)   // in order: waits for the slow one
        gate.continuation.yield()
        #expect(await h.socket.waitForSent(type: "conversation.item.create", count: 2))
        let outputs = h.socket.sent(type: "conversation.item.create").compactMap { e -> String? in
            if case .itemCreate(let item, _, _) = e { item.callID } else { nil }
        }
        #expect(outputs == ["c_slow", "c_fast"])
    }

    @Test func cancelWatchdogReleasesTheFloor() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        h.push(S.responseCreated("resp_1"))
        await h.sync()
        #expect(await h.session.cancelUnspokenResponse())
        await h.advance(by: 3)   // response.done never arrives
        let done = try #require(await h.log.wait { $0.responseDone != nil }?.responseDone)
        #expect(done.reason == "cancel_timeout")
        #expect(await h.session.state == .listening)
    }

    @Test func feedAudioKeepsOrder() async throws {
        let h = try await Harness.connected()
        for i in 0..<200 { h.session.feedAudio(Data(repeating: UInt8(i), count: 48)) }
        #expect(await h.socket.waitForSent(type: "input_audio_buffer.append", count: 200))
        let firstBytes = h.socket.sent(type: "input_audio_buffer.append").compactMap { e -> UInt8? in
            if case .inputAudioAppend(let b64, _) = e { Data(base64Encoded: b64)?.first } else { nil }
        }
        #expect(firstBytes == (0..<200).map { UInt8($0) })
    }

    @Test func congestedUplinkDropsAudioAndAdvises() async throws {
        let h = try await Harness.connected()
        h.socket.setPendingBytes(500_000)
        await h.session.appendAudio(Data(count: 960))
        #expect(!h.socket.sentTypes.contains("input_audio_buffer.append"))
        #expect(await h.log.wait { $0 == .fallbackAdvised(.congested) } != nil)
        h.socket.setPendingBytes(0)
        await h.session.appendAudio(Data(count: 960))
        #expect(h.socket.sentTypes.contains("input_audio_buffer.append"))
    }

    @Test func moderationErrorMidAudio() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        h.push(S.responseCreated("resp_1"), S.messageAdded("resp_1", "a1"), S.audio("resp_1", "a1", ms: 300),
               S.error(code: "content_policy_violation", message: "This content may violate our usage policies."))
        #expect(await h.log.wait { if case .error(let i) = $0 { i.kind == .moderation } else { false } } != nil)
        #expect(await h.socket.waitForSent(type: "response.cancel"))
        let audio = h.log.count(\.isAudio)
        h.push(S.audio("resp_1", "a1", ms: 300),
               S.responseDone("resp_1", status: "incomplete", reason: "content_filter"))
        let done = try #require(await h.log.wait { $0.responseDone != nil }?.responseDone)
        #expect(done.status == "incomplete")
        #expect(done.reason == "content_filter")
        #expect(h.log.count(\.isAudio) == audio)   // the cut-off tail is not played
        // Not a reason to leave the cloud: no fallback, still connected, next turn works.
        #expect(!h.log.contains { $0.fallback != nil })
        await h.session.playbackFinished()
        #expect(await h.session.state == .listening)
        #expect(try await h.session.requestResponse() == .sent)
    }

    @Test func contentFilterDoneWithoutErrorEvent() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        h.push(S.responseCreated("resp_1"), S.responseDone("resp_1", status: "incomplete", reason: "content_filter"))
        #expect(await h.log.wait { if case .error(let i) = $0 { i.kind == .moderation } else { false } } != nil)
        #expect(await h.session.state == .listening)
    }

    @Test func benignCancelErrorIsSwallowed() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        h.push(S.responseCreated("resp_1"))
        await h.sync()
        await h.session.cancelUnspokenResponse()
        let cid = h.socket.sent(type: "response.cancel").last?.eventID
        h.push(S.error(code: "response_cancel_not_active", message: "no active response", eventID: cid))
        await h.sync()
        #expect(!h.log.contains { if case .error = $0 { true } else { false } })
    }

    // MARK: Rollover

    @Test func rolloverAtIdleGapIsSeededWithSummaryAndRecentTurns() async throws {
        let h = try await Harness.connected()
        let first = h.socket
        h.push(S.speechStarted("u1"), S.speechStopped("u1"), S.committed("u1"), S.userTranscript("u1", "My name is Sam."))
        await h.sync()
        try await h.session.requestResponse()
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 100),
               S.transcriptDone("r1", "a1", "Nice to meet you, Sam!"), S.responseDone("r1"))
        await h.log.wait { $0.responseDone != nil }
        await h.session.playbackFinished()

        await h.advance(by: 50 * 60)
        #expect(await h.log.wait { $0 == .rolloverStarted(forced: false) } != nil)
        // The old session writes the summary out of band, as text.
        #expect(await first.waitForSent(type: "response.create", count: 2))
        guard case .responseCreate(let p, _)? = first.sent(type: "response.create").last else { return }
        #expect(p?.conversation == "none")
        #expect(p?.outputModalities == ["text"])
        let purpose = try #require(p?.metadata?["purpose"])
        first.push(S.responseCreated("r_sum", metadata: ["purpose": purpose]))
        first.push(.outputTextDone(.init(responseID: "r_sum", itemID: "s1", text: "Talking with Sam, who just introduced himself.")))
        first.push(S.responseDone("r_sum", metadata: ["purpose": purpose]))

        let second = try #require(await h.factory.waitForSocket(count: 2))
        #expect(await h.log.wait { if case .rolledOver = $0 { true } else { false } } != nil)
        // The new timeline starts with the next audio fed (none was fed yet).
        let all = h.log.all
        if let r = all.firstIndex(where: { if case .rolledOver = $0 { true } else { false } }), r > 0 {
            #expect(all[r - 1] == .uplinkOrigin(feedFrame: 0))
        }
        #expect(second.sentTypes.prefix(2) == ["session.update", "conversation.item.create"])
        guard case .itemCreate(let seed, _, _)? = second.sent(type: "conversation.item.create").first else { return }
        let text = seed.text ?? ""
        #expect(text.contains("Summary of the conversation so far: Talking with Sam, who just introduced himself."))
        #expect(text.contains("Person: My name is Sam."))
        #expect(text.contains("Dee: Nice to meet you, Sam!"))
        #expect(first.closedByClient?.code == 1000)
        #expect(await h.session.lastSummary == "Talking with Sam, who just introduced himself.")
        // Audio now goes to the new session; the summary never reached the event stream as speech.
        await h.session.appendAudio(Data(count: 96))
        #expect(second.sentTypes.contains("input_audio_buffer.append"))
        #expect(!h.log.contains { if case .responseStarted("r_sum", _) = $0 { true } else { false } })
        #expect(await h.session.state == .listening)
    }

    @Test func rolloverWaitsForIdleThenForcesAt59() async throws {
        var config = Harness.defaultConfig()
        config.rolloverSummary = .none
        let h = try await Harness.connected(config: config)
        h.push(S.speechStarted("u1"))   // the user is mid-utterance for a long time
        await h.sync()
        await h.advance(by: 50 * 60)
        await h.settle()
        #expect(h.factory.made.count == 1)   // not idle: no rollover
        await h.advance(by: 9 * 60)
        #expect(await h.log.wait { $0 == .rolloverStarted(forced: true) } != nil)
        // The new session opens beside the old one, but the user gets 30 s to finish.
        #expect(await h.factory.waitForSocket(count: 2) != nil)
        await h.settle()
        #expect(!h.log.contains { if case .rolledOver = $0 { true } else { false } })
        await h.advance(by: 30)
        #expect(await h.log.wait { if case .rolledOver = $0 { true } else { false } } != nil)
        #expect(h.log.count { $0 == .rolloverStarted(forced: true) } == 1)
    }

    @Test func noRolloverMidSentence() async throws {
        var config = Harness.defaultConfig()
        config.rolloverSummary = .none
        let h = try await Harness.connected(config: config)
        try await h.session.requestResponse()
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 100))
        await h.log.wait(\.isAudio)
        let first = h.socket
        await h.advance(by: 59 * 60 + 30)
        // The new session is opened beside the old one, but not switched to.
        #expect(await h.factory.waitForSocket(count: 2) != nil)
        await h.settle()
        #expect(!h.log.contains { if case .rolledOver = $0 { true } else { false } })
        #expect(first.closedByClient == nil)
        first.push(S.responseDone("r1"))   // on the old (still live) session
        await h.log.wait { $0.responseDone != nil }
        await h.advance(by: 1)
        // Generation finished, but her audio is still playing: still not.
        #expect(!h.log.contains { if case .rolledOver = $0 { true } else { false } })
        await h.session.playbackFinished()
        #expect(await h.log.wait { if case .rolledOver = $0 { true } else { false } } != nil)
        #expect(first.closedByClient?.code == 1000)
        #expect(h.log.count { $0.responseDone != nil } == 1)
    }

    @Test func closeEndsEverything() async throws {
        let h = try await Harness.connected()
        let s = h.socket
        await h.session.close()
        #expect(s.closedByClient?.code == 1000)
        #expect(await h.session.state == .idle)
        #expect(await h.log.wait { $0 == .disconnected(code: 1000, reason: "client") } != nil)
        await #expect(throws: RealtimeSessionError.notConnected) { try await h.session.requestResponse() }
        // No reconnect after a client close.
        await h.advance(by: 60)
        await h.settle()
        #expect(h.factory.made.count == 1)
        // And it can connect again.
        try await h.session.connect()
        #expect(h.factory.made.count == 2)
        #expect(await h.session.state == .listening)
    }

    @Test func updateSessionChangesInstructionsWithoutVoice() async throws {
        let h = try await Harness.connected()
        await h.session.updateSession(instructions: "You are Dee. Sam is here.", speed: 1.2)
        guard case .sessionUpdate(let s, _)? = h.socket.sent(type: "session.update").last else { return }
        #expect(s.instructions == "You are Dee. Sam is here.")
        #expect(s.audio?.output?.speed == 1.2)
        #expect(s.audio?.output?.voice == nil)
        #expect(s.model == nil)
        #expect(await h.session.config.instructions == "You are Dee. Sam is here.")
    }
}
