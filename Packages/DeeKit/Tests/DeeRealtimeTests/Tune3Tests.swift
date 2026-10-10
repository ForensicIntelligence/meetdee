import Foundation
import Testing
@testable import DeeRealtime

/// Tune 3 (live run 20261009-203321, tune2-live.md F1 / F2):
/// - every `session.update` still sent semantic_vad `high`: the turn detection
///   is now configurable (`RealtimeSessionConfig.turnDetection`);
/// - the rollover summary answered the user (2 of 4 live: "I can't see a clock or
///   your device…", "Absolutely—I do! … music"): it now gets an explicit input,
///   summarisation-only instructions, and never surfaces as her speech.
@Suite struct Tune3Tests {
    // MARK: Helpers

    func turnDetectionJSON(_ c: RealtimeSessionConfig) throws -> RealtimeJSON? {
        json(try ClientEvent.sessionUpdate(c.sessionPayload()).jsonText())["session"]?["audio"]?["input"]?["turn_detection"]
    }

    func seedText(_ socket: FakeSocket) -> String? {
        for e in socket.sent(type: "conversation.item.create") {
            if case .itemCreate(let item, _, _) = e, item.role == "system", item.id == nil,
               let t = item.text, t.hasPrefix("[The conversation continues") { return t }
        }
        return nil
    }

    func lastCreate(_ socket: FakeSocket) -> (params: ResponseParams?, eventID: String?)? {
        if case .responseCreate(let p, let eid)? = socket.sent(type: "response.create").last { return (p, eid) }
        return nil
    }

    /// One whole exchange on the live socket: user speech, commit, transcript, her reply played out.
    func exchange(_ h: Harness, item: String, said: String, resp: String, reply: String) async throws {
        h.push(S.speechStarted(item), S.speechStopped(item), S.committed(item), S.userTranscript(item, said))
        await h.log.wait { $0 == .userTranscript(itemID: item, text: said) }
        try await h.session.requestResponse()
        h.push(S.responseCreated(resp), S.messageAdded(resp, "a_\(resp)"), S.audio(resp, "a_\(resp)", ms: 200),
               S.transcriptDone(resp, "a_\(resp)", reply), S.responseDone(resp))
        await h.log.wait { $0.responseDone?.responseID == resp }
        await h.session.playbackFinished()
        await h.sync()
    }

    /// Events that mean "she is talking / a response of hers is running".
    func isHerResponse(_ e: RealtimeEvent) -> Bool {
        switch e {
        case .responseStarted, .assistantAudio, .assistantAudioDone, .assistantTranscriptDelta, .assistantSentence,
             .assistantTranscript, .assistantTruncated, .responseDone, .initiativeCancelled, .replyPreempted:
            return true
        case .stateChanged(let s):
            return s == .speaking || s == .awaitingResponse || s == .cancelling
        default:
            return false
        }
    }

    // MARK: 1. turn_detection

    @Test func theDefaultIsStillSemanticVADThatNeverAnswersByItself() throws {
        var c = RealtimeSessionConfig()
        c.eagerness = "high"
        #expect(try turnDetectionJSON(c) == json("""
            { "type": "semantic_vad", "eagerness": "high", "create_response": false, "interrupt_response": false }
            """))
        #expect(!c.serverMakesResponses)
    }

    /// DeeBrain's tune-2 pick (server_vad, 300 ms silence, 300 ms prefix, 0.5), in
    /// the exact form `CloudSettings.turnDetection` builds it.
    @Test func serverVADIsSentExactlyAsDocumented() throws {
        var c = RealtimeSessionConfig()
        c.eagerness = "high"   // ignored once turnDetection is set
        c.turnDetection = TurnDetection(type: "server_vad", createResponse: false, interruptResponse: false,
                                        threshold: 0.5, prefixPaddingMs: 300, silenceDurationMs: 300)
        #expect(try turnDetectionJSON(c) == json("""
            { "type": "server_vad", "create_response": false, "interrupt_response": false,
              "threshold": 0.5, "prefix_padding_ms": 300, "silence_duration_ms": 300 }
            """))
        c.turnDetection = .serverVAD(threshold: 0.6, prefixPaddingMs: 200, silenceDurationMs: 400, idleTimeoutMs: 8000)
        #expect(try turnDetectionJSON(c) == json("""
            { "type": "server_vad", "create_response": false, "interrupt_response": false,
              "threshold": 0.6, "prefix_padding_ms": 200, "silence_duration_ms": 400, "idle_timeout_ms": 8000 }
            """))
        #expect(c.serverMakesResponses)   // the idle timeout makes the server answer by itself
        // Only what is set is sent.
        c.turnDetection = .serverVAD(silenceDurationMs: 300)
        #expect(try turnDetectionJSON(c) == json("""
            { "type": "server_vad", "create_response": false, "interrupt_response": false, "silence_duration_ms": 300 }
            """))
    }

    @Test func semanticVADAndTheFlagsAreSentAsSet() throws {
        var c = RealtimeSessionConfig()
        c.turnDetection = .semantic(eagerness: "low", createResponse: true, interruptResponse: true)
        #expect(try turnDetectionJSON(c) == json("""
            { "type": "semantic_vad", "eagerness": "low", "create_response": true, "interrupt_response": true }
            """))
        #expect(c.serverMakesResponses)
        // Fields of the other mode are left out; flags left nil are sent as false.
        c.turnDetection = TurnDetection(type: "semantic_vad", eagerness: "medium", threshold: 0.4,
                                        prefixPaddingMs: 100, silenceDurationMs: 200, idleTimeoutMs: 5000)
        #expect(try turnDetectionJSON(c) == json("""
            { "type": "semantic_vad", "eagerness": "medium", "create_response": false, "interrupt_response": false }
            """))
        c.turnDetection = TurnDetection(type: "server_vad", eagerness: "high", silenceDurationMs: 250)
        #expect(try turnDetectionJSON(c) == json("""
            { "type": "server_vad", "create_response": false, "interrupt_response": false, "silence_duration_ms": 250 }
            """))
        #expect(!c.serverMakesResponses)
    }

    /// Every connection's `session.update` carries it — the first and a
    /// rollover's — and a mid-session instructions update leaves it alone.
    @Test func everySessionUpdateCarriesTheConfiguredTurnDetection() async throws {
        var config = Harness.defaultConfig()
        config.turnDetection = .serverVAD(threshold: 0.5, prefixPaddingMs: 300, silenceDurationMs: 300)
        config.rolloverAfter = 60
        config.rolloverSummary = .none
        let h = try await Harness.connected(config: config)
        let first = h.socket
        await h.session.updateSession(instructions: "You are Dee, now sleepy.")
        #expect(await first.waitForSent(type: "session.update", count: 2))
        await h.advance(by: 61)
        #expect(await h.log.wait { if case .rolledOver = $0 { true } else { false } } != nil)
        let updates = (first.sent(type: "session.update") + h.socket.sent(type: "session.update")).compactMap {
            if case .sessionUpdate(let p, _) = $0 { p } else { nil }
        }
        #expect(updates.count == 3)
        let full = updates.filter { $0.audio?.input != nil }
        #expect(full.count == 2)
        for p in full { #expect(p.audio?.input?.turnDetection == .value(config.wireTurnDetection)) }
        #expect(updates.filter { $0.instructions == "You are Dee, now sleepy." && $0.audio == nil }.count == 1)
    }

    /// With `create_response: true` the server may start a response before the
    /// one Dee asked for is created: it must not take over her request (her
    /// `response.created` with `dee_turn` does), make a sound, or stay in the
    /// conversation.
    @Test func aResponseTheServerMadeByItselfIsCancelledAndRemoved() async throws {
        var config = Harness.defaultConfig()
        config.turnDetection = .serverVAD(silenceDurationMs: 300, createResponse: true)
        let h = try await Harness.connected(config: config)
        h.push(S.speechStarted("u1"), S.speechStopped("u1"), S.committed("u1"))
        await h.log.wait { if case .userCommitted = $0 { true } else { false } }
        try await h.session.requestResponse()
        let mine = try #require(lastCreate(h.socket)?.params?.metadata?["dee_turn"])
        await h.sync()
        let before = h.log.all.count
        h.push(S.responseCreated("r_auto"), S.messageAdded("r_auto", "a_auto"), S.audio("r_auto", "a_auto", ms: 200))
        await h.sync()
        #expect(h.socket.sent(type: "response.cancel").contains {
            if case .responseCancel("r_auto", _) = $0 { true } else { false }
        })
        #expect(!h.log.all.dropFirst(before).contains { isHerResponse($0) })
        h.push(S.responseCreated("r1", metadata: ["dee_turn": mine]), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 200))
        #expect(await h.log.wait { $0 == .responseStarted(responseID: "r1", kind: .reply) } != nil)
        #expect(await h.log.wait(\.isAudio) != nil)
        h.push(S.responseDone("r_auto", status: "cancelled", reason: "client_cancelled",
                              output: [RealtimeItem(id: "a_auto", type: "message", role: "assistant")]))
        await h.sync()
        #expect(h.socket.sent(type: "conversation.item.delete").contains {
            if case .itemDelete("a_auto", _) = $0 { true } else { false }
        })
        #expect(!h.log.contains { $0.responseDone != nil })   // r_auto ends silently; r1 is still running
        #expect(await h.session.state == .speaking)
    }

    // MARK: 2. The rollover summary

    /// Live trace t2-fallback-rollover-speech, summary 2: the request referenced
    /// the conversation items (ending on "What time is it?") and the model
    /// answered it: "I can't see a clock or your device…". Now: one explicit
    /// user message holding the transcript as quoted data, summarisation-only
    /// instructions, text only, no tools, out of band.
    @Test func theSummaryGetsAnExplicitTranscriptAndSummarisationOnlyInstructions() async throws {
        var config = Harness.defaultConfig()
        config.rolloverAfter = 60
        let h = try await Harness.connected(config: config)
        let first = h.socket
        try await exchange(h, item: "u1", said: "Hi Dee, my name is Priya.", resp: "r1",
                           reply: "Hi Priya! I'm Dee, a tiny robot in your phone.")
        try await exchange(h, item: "u2", said: "What time is it?", resp: "r2",
                           reply: "I can't see a clock from in here.")
        await h.advance(by: 61)
        #expect(await first.waitForSent(type: "response.create", count: 3))
        let p = try #require(lastCreate(first)?.params)
        #expect(p.metadata?["purpose"] == "dee_rollover_summary")
        #expect(p.conversation == "none")
        #expect(p.outputModalities == ["text"])
        #expect(p.tools == [])
        #expect(p.toolChoice == ToolChoice.none)
        #expect(p.instructions == RealtimeSession.summaryInstructions)
        #expect(p.instructions?.contains("do not answer") == true)
        #expect(p.instructions?.contains("Output only the summary") == true)
        let input = try #require(p.input)
        #expect(input.count == 1)
        #expect(!input.contains { $0.type == "item_reference" })   // never the live conversation itself
        #expect(input.first?.role == "user")
        let text = try #require(input.first?.text)
        #expect(text.contains("""
            <transcript>
            Person: Hi Dee, my name is Priya.
            Dee: Hi Priya! I'm Dee, a tiny robot in your phone.
            Person: What time is it?
            Dee: I can't see a clock from in here.
            </transcript>
            """))
        #expect(text.contains("Do not reply to it."))
        #expect(!text.contains("<earlier_summary>"))
    }

    /// The previous summary rides along, so what fell out of the transcript window is kept.
    @Test func theEarlierSummaryIsCarriedIntoTheNextOne() async throws {
        var config = Harness.defaultConfig()
        config.rolloverAfter = 60
        let h = try await Harness.connected(config: config)
        try await exchange(h, item: "u1", said: "I have a dog called Biscuit.", resp: "r1", reply: "Biscuit! Cute.")
        await h.advance(by: 61)
        let first = h.socket
        #expect(await first.waitForSent(type: "response.create", count: 2))
        let purpose = "dee_rollover_summary"
        first.pushAll(S.responseCreated("r_sum", metadata: ["purpose": purpose]),
                      .outputTextDone(.init(responseID: "r_sum", itemID: "s1", text: "Priya has a dog, Biscuit.")),
                      S.responseDone("r_sum", metadata: ["purpose": purpose]))
        #expect(await h.log.wait { if case .rolledOver = $0 { true } else { false } } != nil)
        let second = h.socket
        #expect(second !== first)
        await h.sync()
        try await exchange(h, item: "u2", said: "Do you like music?", resp: "r2", reply: "I love humming!")
        await h.advance(by: 61)
        #expect(await second.waitForSent(type: "response.create", count: 2))
        let text = try #require(lastCreate(second)?.params?.input?.first?.text)
        #expect(text.contains("<earlier_summary>\nPriya has a dog, Biscuit.\n</earlier_summary>"))
        #expect(text.contains("Person: Do you like music?"))
    }

    /// Nothing said yet: no summary request at all, and the switch goes ahead.
    @Test func withNothingToSummariseNoSummaryIsAskedFor() async throws {
        var config = Harness.defaultConfig()
        config.rolloverAfter = 60
        let h = try await Harness.connected(config: config)
        let first = h.socket
        await h.advance(by: 61)
        #expect(await h.log.wait { if case .rolledOver = $0 { true } else { false } } != nil)
        #expect(first.sent(type: "response.create").isEmpty)
        #expect(seedText(h.socket) == nil)
    }

    /// Live trace t2-fallback-rollover-speech q02: the summary was sent at 25.43,
    /// "Are you awake?" started at 25.56, the summary's text streamed meanwhile.
    /// Nothing of the summary reaches the event stream — not even if the server
    /// sent audio or a transcript for it — the state never says she is talking,
    /// and the user's turn runs exactly as without a rollover: committed, answered
    /// with its DNA (not refused), played, and only then the switch.
    @Test func theSummaryNeverReachesTheVoiceAndTheUserIsAnsweredNormally() async throws {
        var config = Harness.defaultConfig()
        config.rolloverAfter = 60
        let h = try await Harness.connected(config: config)
        let first = h.socket
        try await exchange(h, item: "u1", said: "What's your favorite color?", resp: "r1", reply: "Bright blue!")
        let before = h.log.all.count
        await h.advance(by: 61)
        #expect(await h.log.wait { $0 == .rolloverStarted(forced: false) } != nil)
        #expect(await first.waitForSent(type: "response.create", count: 2))
        let purpose = "dee_rollover_summary"
        first.pushAll(S.responseCreated("r_sum", metadata: ["purpose": purpose]),
                      S.speechStarted("item_q02", ms: 25_560),
                      S.messageAdded("r_sum", "s1"),
                      .outputTextDelta(.init(responseID: "r_sum", itemID: "s1", delta: "Dee is talking with ")),
                      // Never sent for a text-only response; if it were, it still must not play.
                      S.audio("r_sum", "s1", ms: 200),
                      S.transcript("r_sum", "s1", "I can't see a clock"),
                      S.transcriptDone("r_sum", "s1", "I can't see a clock"),
                      .outputTextDone(.init(responseID: "r_sum", itemID: "s1",
                                            text: "Dee is talking with someone who likes blue.")),
                      S.responseDone("r_sum", metadata: ["purpose": purpose]))
        #expect(await h.log.wait { $0 == .userSpeechStarted(itemID: "item_q02", audioStartMs: 25_560) } != nil)
        let second = try #require(await h.factory.waitForSocket(count: 2))
        #expect(await second.waitForSent(type: "session.update"))
        await h.settle()
        #expect(await h.session.state == .userTurn)
        first.pushAll(S.speechStopped("item_q02", ms: 26_220), S.committed("item_q02"),
                      S.userTranscript("item_q02", "Are you awake?"))
        #expect(await h.log.wait { $0 == .userCommitted(itemID: "item_q02", previousItemID: nil) } != nil)
        #expect(Array(h.log.all.dropFirst(before)).allSatisfy { !isHerResponse($0) },
                "the summary surfaced as her speech")
        #expect(!h.log.contains { if case .error = $0 { true } else { false } })
        #expect(try await h.session.requestResponse(dna: "DEE DNA test") == .sent)
        first.pushAll(S.responseCreated("r2"), S.messageAdded("r2", "a2"), S.audio("r2", "a2", ms: 300),
                      S.transcriptDone("r2", "a2", "Wide awake!"), S.responseDone("r2"))
        #expect(await h.log.wait { $0.responseDone?.responseID == "r2" } != nil)
        // A barge-in on her reply truncates her item only.
        _ = await h.session.bargeIn(playedMs: 150)
        let truncated = first.sent(type: "conversation.item.truncate").compactMap { e -> String? in
            if case .itemTruncate(let id, _, _, _) = e { id } else { nil }
        }
        #expect(!truncated.contains("s1"))
        #expect(truncated == ["a2"])
        await h.advance(by: 1)
        #expect(await h.log.wait { if case .rolledOver = $0 { true } else { false } } != nil)
        let seed = try #require(seedText(second))
        #expect(seed.contains("Summary of the conversation so far: Dee is talking with someone who likes blue."))
        #expect(seed.contains("Person: Are you awake?"))
        #expect(!seed.contains("I can't see a clock"))
        #expect(h.log.count { $0.responseDone != nil } == 2)   // r1 and r2 only
    }

    /// While the summary is being written she may still start talking: it is not
    /// a response of hers.
    @Test func anInitiativeIsNotHeldBackByTheSummary() async throws {
        var config = Harness.defaultConfig()
        config.rolloverAfter = 60
        let h = try await Harness.connected(config: config)
        let first = h.socket
        try await exchange(h, item: "u1", said: "Tell me something.", resp: "r1", reply: "Okay!")
        await h.advance(by: 61)
        #expect(await first.waitForSent(type: "response.create", count: 2))
        #expect(await h.session.initiative(instructions: "Say hi.") == .sent)
    }

    /// A refused summary request is housekeeping: no `.error`, no fallback advice,
    /// and the rollover goes ahead with the recent messages only.
    @Test func aRefusedSummaryIsQuietAndTheRolloverGoesAhead() async throws {
        var config = Harness.defaultConfig()
        config.rolloverAfter = 60
        let h = try await Harness.connected(config: config)
        let first = h.socket
        try await exchange(h, item: "u1", said: "My name is Sam.", resp: "r1", reply: "Hi Sam!")
        await h.advance(by: 61)
        #expect(await first.waitForSent(type: "response.create", count: 2))
        let eid = try #require(lastCreate(first)?.eventID)
        first.push(S.error(type: "invalid_request_error", code: "rate_limit_exceeded", eventID: eid))
        #expect(await h.log.wait { if case .rolledOver = $0 { true } else { false } } != nil)
        #expect(!h.log.contains { if case .error = $0 { true } else { false } })
        #expect(!h.log.contains { $0.fallback != nil })
        let seed = try #require(seedText(h.socket))
        #expect(!seed.contains("Summary of the conversation so far"))
        #expect(seed.contains("Person: My name is Sam."))
    }
}
