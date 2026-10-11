import DeeCore
import DeeRealtime
import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Tune 1: the brain on the session's own DNA API (no DNAWire), the unfinished-turn
/// guard behind `high` eagerness, and what the brain now does around a request that
/// CloudVoice's `respond` / `initiative` used to do.
@Suite(.serialized) @MainActor struct Tune1BrainTests {
    // MARK: Helpers

    /// Walks the trail of one socket and returns every in-band `response.create`
    /// that went out while no DNA was live in that connection's conversation.
    static func bareResponses(_ rig: BrainRig, on s: FakeSocket? = nil) -> [Int] {
        var live: Set<String> = []
        var bare: [Int] = []
        for (i, o) in rig.frames(on: s).enumerated() {
            let type = o["type"] as? String ?? ""
            if type == "conversation.item.create", let item = o["item"] as? [String: Any],
               let id = item["id"] as? String, id.hasPrefix("dna_") {
                live.insert(id)
            } else if type == "conversation.item.delete", let id = o["item_id"] as? String {
                live.remove(id)
            } else if type == "response.create" {
                let r = o["response"] as? [String: Any] ?? [:]
                if r["conversation"] as? String == "none" { continue }      // out of band: no conversation
                if live.isEmpty { bare.append(i) }
            }
        }
        return bare
    }

    // MARK: DNA through the session

    /// The goal: no response ever runs without a DNA — replies, typed turns,
    /// initiatives, tool follow-ups, a session re-request — and there is exactly one
    /// DNA in the conversation after each.
    @Test func noResponseEverRunsWithoutADNA() async throws {
        let rig = try await BrainRig(tools: [FakeTool(name: "recall", reply: "Name: Maya.")])
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"),
                 Srv.callDone("resp_1", item: "item_fc1", call: "call_1", name: "recall", args: "{}"),
                 Srv.responseDone("resp_1"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "tool follow-up")
        rig.push(Srv.responseCreated("resp_2"), Srv.responseDone("resp_2"))
        await rig.settle()
        _ = rig.brain.respond(.user(words: "What's my name?"), state: nil, effort: .low)
        #expect(await rig.until { rig.responseCreates().count == 3 }, "typed")
        rig.push(Srv.responseCreated("resp_3"), Srv.responseDone("resp_3"))
        await rig.settle()
        try rig.quiet(0.6)
        _ = rig.brain.respond(.initiative("Say hi."), state: nil, effort: .low)
        #expect(await rig.until { rig.responseCreates().count == 4 }, "initiative")
        rig.push(Srv.responseCreated("resp_4"), Srv.responseDone("resp_4"))
        await rig.settle()
        #expect(Self.bareResponses(rig).isEmpty, "\(rig.trail())")
        let creates = rig.trail().filter { $0.hasPrefix("dna:") }.count
        let deletes = rig.trail().filter { $0.hasPrefix("delete:dna_") }.count
        #expect(creates - deletes == 1, "exactly one DNA lives in the conversation: \(rig.trail())")
        rig.shutdown()
    }

    /// F9 at the brain: the server refuses the reply's DNA create. The response sent
    /// behind it is held back and sent again behind the previous DNA, restored under
    /// a fresh id; the brain's reply channel sees one start and one end.
    @Test func aRefusedDNACreateNeverLeavesAReplyBare() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.responseDone("resp_1"))
        await rig.settle()
        rig.utterance("item_u2", startMs: 3000, endMs: 3600)
        #expect(await rig.until { rig.responseCreates().count == 2 })
        let create = try #require(rig.frames().last {
            $0["type"] as? String == "conversation.item.create"
                && ((($0["item"] as? [String: Any])?["id"] as? String)?.hasPrefix("dna_") ?? false)
        })
        let eventID = try #require(create["event_id"] as? String)
        rig.socket.push(json: #"{"type":"error","event_id":"ev_err","error":{"type":"invalid_request_error","code":"invalid_value","message":"bad item","event_id":"\#(eventID)"}}"#)
        #expect(await rig.until { rig.responseCreates().count == 3 }, "sent again behind the restored DNA: \(rig.trail())")
        let trail = rig.trail()
        // The restored DNA (fresh id) goes right before the resent request.
        #expect(trail.suffix(2).first?.hasPrefix("dna:") == true && trail.last == "response.create", "\(trail)")
        let restoredID = String(trail.suffix(2).first!.dropFirst(4))
        #expect(rig.dnaText(restoredID) == rig.dnaText("dna_tagabc_1"), "the previous DNA's text, restored")
        rig.shutdown()
    }

    /// The retired wire is a pass-through: nothing it hands the session is rewritten.
    @available(*, deprecated)
    @Test func theRetiredWireIsAPassThrough() {
        let base = FakeSocketFactory([]) { FakeSocket(request: $0, sessionID: "s") }
        let wired = DNAWire().factory(base.factory)
        let socket = wired(URLRequest(url: URL(string: "wss://x")!))
        let dna = #"{"type":"conversation.item.create","item":{"type":"message","role":"system","content":[{"type":"input_text","text":"DEE DNA v2"}]}}"#
        socket.send(dna)
        socket.send(#"{"type":"response.create","response":{"instructions":""}}"#)
        #expect((socket as? FakeSocket)?.sent == [dna, #"{"type":"response.create","response":{"instructions":""}}"#])
    }

    /// A canned line is out of band (`ResponseKind.say`): no DNA, no history line.
    @Test func aCannedLineNeverEntersTheHistory() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        try rig.quiet(0.3)
        var outcome: RealtimeBrain.SayOutcome?
        Task { outcome = await rig.brain.say("Okay. Goodnight!") }
        #expect(await rig.until { rig.responseCreates().count == 1 })
        #expect(!rig.trail().contains { $0.hasPrefix("dna:") }, "\(rig.trail())")
        let meta = (rig.responseCreates().last?["response"] as? [String: Any])?["metadata"] as? [String: Any]
        #expect(meta?["purpose"] != nil, "tagged as the session's out-of-band line")
        rig.push(Srv.responseCreated("resp_c"), Srv.messageAdded("resp_c", "item_c1"))
        for _ in 0..<4 { rig.push(Srv.audio("resp_c", "item_c1", Sig.pcm(ms: 100))) }
        rig.push(Srv.transcript("resp_c", "item_c1", "Okay. Goodnight!"), Srv.audioDone("resp_c", "item_c1"),
                 Srv.transcriptDone("resp_c", "item_c1", "Okay. Goodnight!"), Srv.responseDone("resp_c"))
        for _ in 0..<100 where outcome == nil {
            try rig.step()
            await Task.yield()
        }
        #expect(await rig.until { outcome == .played })
        let turns = await rig.session.recentTurns
        #expect(!turns.contains { $0.text.contains("Goodnight") }, "\(turns)")
        rig.shutdown()
    }

    /// Speech not for her leaves the session's history too (no later seed has it).
    @Test func droppedSpeechLeavesTheHistory() async throws {
        let rig = try await BrainRig(engaged: false)
        try await rig.start()
        rig.host.asleep = true
        rig.utterance("item_u1")
        rig.push(Srv.userTranscript("item_u1", "And now the weather for the weekend ahead."))
        #expect(await rig.until { rig.trail().contains("delete:item_u1") })
        let turns = await rig.session.recentTurns
        #expect(!turns.contains { $0.text.contains("weather") })
        #expect(await rig.session.hasUnansweredUserTurn == false)
        rig.shutdown()
    }

    /// A command is never answered and does not hold the session busy (rollover).
    @Test func aCommandReleasesTheTurn() async throws {
        let rig = try await BrainRig(identified: false, exactWords: true)
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { await rig.session.hasUnansweredUserTurn })
        rig.push(Srv.userTranscript("item_u1", "Goodnight."))
        #expect(await rig.until { rig.host.commands == [.sleep] })
        #expect(await rig.until { await rig.session.hasUnansweredUserTurn == false })
        #expect(rig.responseCreates().isEmpty)
        rig.shutdown()
    }

    /// A new conversation clears the session's history and summary.
    @Test func aNewConversationClearsTheHistory() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        rig.push(Srv.userTranscript("item_u1", "My cat is called Pickle."))
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.responseDone("resp_1"))
        #expect(await rig.until { await rig.session.recentTurns.contains { $0.text.contains("Pickle") } })
        // The turn is over (a turn still being answered is kept by a reset).
        #expect(await rig.until { rig.host.replies.first?.last == .turnCompleted })
        await rig.brain.newConversation(persona: Persona(), now: Date())
        let left = await rig.session.recentTurns
        #expect(left.isEmpty, "\(left) \(rig.brain.trace)")
        #expect(await rig.session.lastSummary == nil)
        rig.shutdown()
    }

    // MARK: Around a request

    /// The timeline still gets `response_create_sent` (the harness measures from it).
    @Test func aReplyMarksTheTimeline() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        let marked = rig.voice.timeline.turns().contains { $0.time(of: .responseCreateSent) != nil }
        #expect(marked)
        rig.shutdown()
    }

    /// A request never goes out within `stopGuard` of a stop of her voice: the
    /// stop's cancel reaches the session first, and CloudVoice's reply gate (which
    /// keeps a response starting within 0.25 s of a stop silent) is past.
    @Test func aRequestWaitsOutARecentStop() async throws {
        let rig = try await BrainRig(tune: { $0.stopGuard = 0.3 })
        try await rig.start()
        rig.brain.stopVoice()
        let start = ContinuousClock.now
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        let waited = ContinuousClock.now - start
        #expect(waited >= .milliseconds(250), "\(waited)")

        // No stop: no wait.
        rig.push(Srv.responseCreated("resp_1"), Srv.responseDone("resp_1"))
        try? await Task.sleep(for: .milliseconds(350))
        let again = ContinuousClock.now
        rig.utterance("item_u2", startMs: 3000, endMs: 3600)
        #expect(await rig.until { rig.responseCreates().count == 2 })
        // Tune 11 review: the stop was ≥ 0.65 s ago, so no guard can apply; isolated this is
        // ~10 ms, under full-suite load the main actor alone took 0.25–0.27 s (3 of 26 runs).
        #expect(ContinuousClock.now - again < .milliseconds(1000))
        rig.shutdown()
    }

    /// Her initiative is refused while the user talks, and taken back when they
    /// start before its first audio (CloudVoice's own initiative gate, kept).
    @Test func anInitiativeGivesWayToTheUser() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        try rig.quiet(0.3)
        _ = rig.brain.respond(.initiative("Ask about their day."), state: nil, effort: .low)
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_i"))
        await rig.settle()
        for _ in 0..<40 where !rig.brain.trace.contains(.yieldedToUser) {
            try rig.talk(0.02)
            await Task.yield()
        }
        #expect(await rig.until { rig.brain.trace.contains(.yieldedToUser) })
        #expect(await rig.until { rig.count("response.cancel") >= 1 }, "\(rig.trail())")
        rig.shutdown()

        let busy = try await BrainRig()
        try await busy.start()
        try busy.talk(0.6)
        for try await _ in busy.brain.respond(.initiative("Say hi."), state: nil, effort: .low) {}
        #expect(busy.responseCreates().isEmpty, "refused while they talk")
        busy.shutdown()
    }

    // MARK: Unfinished turns

    /// "Hold on." committed as its own turn (high eagerness): the unheard fast reply
    /// is taken back, nothing answers it, and the continuation is answered.
    @Test func holdOnIsNeverAnswered() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"))
        rig.push(Srv.userTranscript("item_u1", "Hold on, hold on."))
        #expect(await rig.until { rig.brain.trace.contains(.held("holdOn")) })
        #expect(await rig.until { rig.count("response.cancel") >= 1 }, "the unheard reply is taken back")
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        #expect(await rig.until { await rig.session.hasUnansweredUserTurn == false })
        try? await Task.sleep(for: .milliseconds(400))
        #expect(rig.responseCreates().count == 1, "nothing answers \"hold on\"")

        rig.utterance("item_u2", startMs: 2500, endMs: 4000)
        #expect(await rig.until { rig.responseCreates().count == 2 }, "the rest is answered")
        #expect(Self.bareResponses(rig).isEmpty)
        rig.shutdown()
    }

    /// "I had pasta for dinner, and…": held; the continuation answers both, and
    /// the held turn gets no reply of its own.
    @Test func aTrailingTurnWaitsForTheRest() async throws {
        let rig = try await BrainRig(tune: { $0.trailingWait = 1.0 })
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.userTranscript("item_u1", "I had pasta for dinner, and…"))
        #expect(await rig.until { rig.brain.trace.contains(.held("trailing")) })
        rig.push(Srv.responseCreated("resp_1"), Srv.responseDone("resp_1", status: "cancelled"))
        await rig.settle()
        rig.utterance("item_u2", startMs: 2500, endMs: 3500)
        #expect(await rig.until { rig.responseCreates().count == 2 })
        rig.push(Srv.responseCreated("resp_2"), Srv.responseDone("resp_2"))
        try? await Task.sleep(for: .milliseconds(1300))          // past trailingWait
        #expect(rig.responseCreates().count == 2, "the held turn was answered with the rest")
        rig.shutdown()
    }

    /// A trailing turn nothing follows is answered after `trailingWait`.
    @Test func aTrailingTurnIsAnsweredIfNothingFollows() async throws {
        let rig = try await BrainRig(identified: false, exactWords: true, tune: { $0.trailingWait = 0.3 })     // exact: waits for words
        try await rig.start()
        rig.utterance("item_u1")
        rig.push(Srv.userTranscript("item_u1", "I was going to call my mom and"))
        #expect(await rig.until { rig.brain.trace.contains(.held("trailing")) })
        #expect(rig.responseCreates().isEmpty)
        #expect(await rig.until { rig.responseCreates().count == 1 }, "answered after the wait")
        let dna = try #require(rig.dnaText("dna_tagabc_1"))
        #expect(dna.contains("What it meant:"), "with its words (exact)")
        rig.shutdown()
    }

    /// A reply she is already saying out loud is not taken back.
    @Test func anAudibleReplyIsNotTakenBack() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"))
        #expect(await rig.until { rig.brain.trace.contains(.responseStarted(kind: "reply")) })
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 0, text: "Sure."))
        await rig.settle()
        rig.push(Srv.userTranscript("item_u1", "Wait a second."))
        #expect(await rig.until { rig.host.heardLog.count == 1 })
        await rig.settle()
        #expect(rig.count("response.cancel") == 0)
        #expect(!rig.brain.trace.contains(.held("holdOn")))
        rig.shutdown()
    }
}

@Suite struct UnfinishedTurnTests {
    @Test func holdPhrases() {
        for t in ["Hold on, hold on.", "Hold on.", "hang on", "Wait, wait.", "One sec.", "Just a second, Dee.",
                  "Oh, hold on.", "Um, let me think.", "Give me a minute.", "Hmm, let me see."] {
            #expect(TurnPolicy.unfinished(t) == .holdOn, "\(t)")
        }
    }

    @Test func trailingTurns() {
        for t in ["I had pasta for dinner, and…", "I was going to call my mom and", "We went to the beach and then",
                  "So I went to the um", "It was kind of, um...", "I think the", "Because", "I wanted to tell you but"] {
            #expect(TurnPolicy.unfinished(t) == .trailing, "\(t)")
        }
    }

    @Test func finishedTurns() {
        for t in ["Hold on to your hat, it's windy!", "Can you wait for me?", "I think so.", "It's kind of.",
                  "What's the name of that big red planet?", "Hold on to the rope.", "Wait for me at the door.",
                  "See you then.", "Okay.", "I like it.", "That's what I was thinking of.", "", "Dee, are you awake?",
                  "One second is too long.", "I waited a second"] {
            #expect(TurnPolicy.unfinished(t) == nil, "\(t)")
        }
    }

    /// Tune 3: the session ends turns with the A/B winner, server_vad 300 ms
    /// (tune 2 live: every session.update still said semantic_vad `high`).
    @Test func sessionTurnDetectionIsServerVAD300() throws {
        let c = CloudSettings().sessionConfig()
        #expect(c.turnDetection == CloudSettings.turnDetection)
        let json = String(data: try JSONEncoder().encode(c.sessionPayload()), encoding: .utf8) ?? ""
        #expect(json.contains(#""type":"server_vad""#), "\(json)")
        #expect(json.contains(#""silence_duration_ms":300"#) && json.contains(#""prefix_padding_ms":300"#))
        #expect(json.contains(#""threshold":0.5"#))
        #expect(json.contains(#""create_response":false"#) && json.contains(#""interrupt_response":false"#))
        #expect(!json.contains("eagerness"), "no semantic_vad field")
    }
}
