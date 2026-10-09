import DeeCore
import DeeMemory
import DeeRealtime
@testable import DeeSelf
import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Wave-2 review fixes, end to end on the rig (real CloudVoice, session,
/// Mind and Cortex). Each test is named after what used to go wrong.
@Suite(.serialized) @MainActor struct BrainReviewFixTests {
    /// Correctness #1: a barge-in's cancel never drops the utterance that caused it
    /// (its commit can reach the brain just before the cancel). A hush does.
    @Test func aBargeInKeepsTheTurnThatInterrupted() async throws {
        let rig = try await BrainRig(identified: false)          // exact: waits for the words
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "waitForWords")) })
        await rig.brain.cancel()                                  // DeeModel's barge-in path
        rig.push(Srv.userTranscript("item_u1", "Wait, what?"))
        #expect(await rig.until { rig.responseCreates().count == 1 }, "the interruption is answered")
        rig.shutdown()

        let hush = try await BrainRig(identified: false)
        try await hush.start()
        hush.utterance("item_u1")
        #expect(await hush.until { hush.brain.trace.contains(.committed(plan: "waitForWords")) })
        await hush.brain.cancel(hush: true)
        hush.push(Srv.userTranscript("item_u1", "Tell me a story."))
        #expect(await hush.until { hush.host.heardLog.count == 1 })
        try? await Task.sleep(for: .milliseconds(500))
        #expect(hush.responseCreates().isEmpty, "a hush drops what was said before it")
        hush.shutdown()
    }

    /// Correctness #2: speech that was not for her leaves the realtime conversation,
    /// and its words never reach a reconnect's seed.
    @Test func ignoredSpeechLeavesTheConversationAndTheSeed() async throws {
        let rig = try await BrainRig(engaged: false)
        try await rig.start()
        rig.host.asleep = true
        let first = rig.socket
        rig.utterance("item_u1")
        rig.push(Srv.userTranscript("item_u1", "And now the weather for the weekend ahead."))
        #expect(await rig.until { rig.trail(on: first).contains("delete:item_u1") })
        #expect(rig.responseCreates(on: first).isEmpty)

        first.drop()
        #expect(await rig.until { !rig.brain.connected })
        for _ in 0..<40 where rig.factory.made.count < 2 {
            rig.clock.advance(by: 0.5)
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await rig.until { rig.factory.made.count == 2 && rig.brain.connected })
        let second = rig.socket
        await rig.settle()
        #expect(!second.sent.contains { $0.contains("weather") }, "the TV is not in the new connection's seed")
        rig.shutdown()
    }

    /// Correctness #12: a reply asked for at the commit is taken back (unheard) when
    /// the words turn out not to be for her.
    @Test func aFastReplyToSpeechNotForHerIsTakenBack() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"))
        await rig.settle()
        rig.host.engaged = false                                  // they walked away; the TV talks
        rig.push(Srv.userTranscript("item_u1", "Coming up after the break, the sports."))
        #expect(await rig.until { rig.trail().contains("delete:item_u1") })
        #expect(await rig.until { rig.count("response.cancel") >= 1 })
        rig.shutdown()
    }

    /// Correctness #3: a rollover (new connection) forgets utterances of the old one,
    /// and an unanswered "is this for me?" wait never blocks initiatives for good.
    @Test func pendingTurnsDoNotOutliveTheirConnection() async throws {
        let rig = try await BrainRig(engaged: false)
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "waitForAddress")) })
        try rig.quiet(0.2)
        for try await _ in rig.brain.respond(.initiative("Say hello."), state: nil, effort: .low) {}
        #expect(rig.brain.trace.contains(.initiativeRefused("busy")), "words awaited")
        rig.brain.inject(.session(.rolledOver(sessionID: "sess_new")))
        await rig.settle()
        _ = rig.brain.respond(.initiative("Say hello."), state: nil, effort: .low)
        #expect(await rig.until { rig.responseCreates().count == 1 }, "the old connection's utterance is gone")
        rig.shutdown()

        let late = try await BrainRig(engaged: false, tune: { $0.addressWait = 0.2 })
        try await late.start()
        late.utterance("item_u1")
        #expect(await late.until { late.trail().contains("delete:item_u1") }, "given up after addressWait")
        try late.quiet(0.2)
        _ = late.brain.respond(.initiative("Say hello."), state: nil, effort: .low)
        #expect(await late.until { late.responseCreates().count == 1 })
        late.shutdown()
    }

    /// Correctness #4: a reply refused because a response was in flight is retried
    /// when that response is done — with what exact mode knew.
    @Test func aRefusedReplyIsRetriedWithItsWords() async throws {
        let rig = try await BrainRig(identified: false)
        try await rig.start()
        // The session only sees what the brain sends; the user turns are injected.
        rig.brain.inject(.session(.userCommitted(itemID: "item_u1", previousItemID: nil)))
        rig.brain.inject(.session(.userTranscript(itemID: "item_u1", text: "Hi, I'm Maya.")))
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.brain.inject(.session(.userCommitted(itemID: "item_u2", previousItemID: nil)))
        rig.brain.inject(.session(.userTranscript(itemID: "item_u2", text: "I just got back from a long trip to Lisbon.")))
        #expect(await rig.until { rig.host.heardLog.count == 2 })
        await rig.settle()
        #expect(rig.brain.trace.filter { if case .requestFailed = $0 { true } else { false } }.count == 2,
                "refused at the commit and again with the words")
        #expect(rig.responseCreates().count == 1, "refused: a response is in flight")
        rig.push(Srv.responseCreated("resp_1"), Srv.responseDone("resp_1"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "retried once the response is done")
        let dna = try #require(rig.dnaText("dna_tagabc_2"))
        #expect(dna.contains("Answer their last words again"), "\(dna.prefix(80)) \(rig.brain.trace)")
        #expect(dna.contains("What it meant:"), "the retry keeps the words it had")
        rig.shutdown()
    }

    /// Correctness #7: a reply still playing is not closed by the channel tail.
    @Test func aReplyIsNotClosedWhilePlaying() async throws {
        let rig = try await BrainRig(tune: { $0.channelTail = 0.1 })
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"))
        await rig.settle()
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 0, text: "Once upon a time."))
        rig.push(Srv.responseDone("resp_1"))
        try? await Task.sleep(for: .milliseconds(400))
        #expect(rig.host.replies.first?.contains(.turnCompleted) == false, "still playing: still her turn")
        rig.brain.inject(.itemPlayed(itemID: "item_a1", playedMs: 30_000, cut: false))
        #expect(await rig.until { rig.host.replies.first?.last == .turnCompleted })
        rig.shutdown()
    }

    /// Correctness #9: a slow tool (a permission prompt) keeps the turn open and
    /// holds initiatives back until its answer has been asked for.
    @Test func aSlowToolKeepsTheTurn() async throws {
        let rig = try await BrainRig(tools: [SlowTool(name: "calendar_events", seconds: 0.8)])
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"),
                 Srv.callDone("resp_1", item: "item_fc1", call: "call_1", name: "calendar_events", args: "{}"),
                 Srv.responseDone("resp_1"))
        try? await Task.sleep(for: .milliseconds(500))           // past toolFollowUpWait (0.3 s)
        #expect(rig.host.replies.first?.contains(.turnCompleted) == false)
        for try await _ in rig.brain.respond(.initiative("Say hello."), state: nil, effort: .low) {}
        #expect(rig.brain.trace.contains(.initiativeRefused("busy")))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "the tool's answer is spoken")
        rig.shutdown()
    }

    /// Correctness #10 / spec F4: a canned line is out of band with the current Voice
    /// words, is not reported as a reply, and says whether it was played.
    @Test func aCannedLineIsAnOutOfBandAside() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.responseDone("resp_1"))
        #expect(await rig.until { rig.host.replies.first?.last == .turnCompleted })
        try rig.quiet(0.3)
        let replies = rig.host.replies.count
        var outcome: RealtimeBrain.SayOutcome?
        Task { outcome = await rig.brain.say("Okay. Goodnight!") }
        #expect(await rig.until { rig.responseCreates().count == 2 })
        let r = try #require(rig.responseCreates().last?["response"] as? [String: Any])
        #expect(r["conversation"] as? String == "none")
        #expect((r["input"] as? [Any])?.isEmpty == true)
        let instructions = r["instructions"] as? String ?? ""
        #expect(instructions.contains("Okay. Goodnight!"))
        #expect(instructions.contains("\nVoice: "), "the current DNA's Voice words")
        #expect(rig.trail().last == "response.create" && rig.count("dna:dna_tagabc_2") == 0, "no DNA for a canned line")

        rig.push(Srv.responseCreated("resp_c", metadata: ["dee_canned": "1"]), Srv.messageAdded("resp_c", "item_c1"))
        for _ in 0..<6 { rig.push(Srv.audio("resp_c", "item_c1", Sig.pcm(ms: 100))) }
        rig.push(Srv.transcript("resp_c", "item_c1", "Okay. Goodnight!"), Srv.audioDone("resp_c", "item_c1"),
                 Srv.transcriptDone("resp_c", "item_c1", "Okay. Goodnight!"), Srv.responseDone("resp_c"))
        for _ in 0..<120 where outcome == nil {
            try rig.step()
            await Task.yield()
        }
        #expect(await rig.until { outcome != nil })
        #expect(outcome == .played)
        #expect(rig.host.replies.count == replies, "an aside is not a reply")
        rig.shutdown()

        let offline = try await BrainRig()
        #expect(await offline.brain.say("Hello.") == .refused("not connected"))
    }

    /// Spec F7: speech that preempts a reply gets a fresh `retry` DNA ready on the
    /// wire for the session's own re-request.
    @Test func aPreemptedReplyGetsAFreshRetryDNA() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.responseDone("resp_1"))
        await rig.settle()
        rig.brain.inject(.session(.replyPreempted(responseID: "resp_1")))
        #expect(await rig.until { rig.brain.trace.contains { if case .dnaReplaced = $0 { true } else { false } } })
        _ = try? await rig.session.requestResponse()              // as the session re-requests
        #expect(await rig.until { rig.responseCreates().count == 2 })
        #expect(Array(rig.trail().suffix(3)) == ["dna:dna_tagabc_2", "delete:dna_tagabc_1", "response.create"])
        #expect(rig.dnaText("dna_tagabc_2")?.contains("Answer their last words again") == true)
        rig.shutdown()
    }

    /// Correctness #5: a new conversation clears the realtime conversation (the DNA stays).
    @Test func aNewConversationClearsWhatTheModelRemembers() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.reply("resp_1", "item_a1", ms: 300, text: "Hi there.")
        await rig.settle()
        for _ in 0..<100 where rig.host.replies.first?.last != .turnCompleted {
            try rig.step()                                      // she says it; the turn ends
            await Task.yield()
        }
        #expect(await rig.until { rig.host.replies.first?.last == .turnCompleted })
        await rig.brain.newConversation(persona: Persona(), now: Date())
        let trail = rig.trail()
        #expect(trail.contains("delete:item_u1") && trail.contains("delete:item_a1"), "\(trail)")
        #expect(!trail.contains("delete:dna_tagabc_1"), "the live DNA stays")
        rig.shutdown()
    }

    /// Spec F11 (§5.4): the brain's trace and the wire's events carry no text.
    @Test func theTraceHoldsNoText() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        rig.push(Srv.userTranscript("item_u1", "My golden retriever Maxwell chewed my favourite slippers."))
        #expect(await rig.until { rig.responseCreates().count == 1 && rig.host.heardLog.count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.responseDone("resp_1"))
        await rig.settle()
        _ = rig.brain.respond(.user(words: "Tell me about pelicans, please."), state: nil, effort: .low)
        #expect(await rig.until { rig.responseCreates().count == 2 })
        let dna = try #require(rig.dnaText("dna_tagabc_1"))
        let trace = "\(rig.brain.trace)"
        for word in ["retriever", "Maxwell", "slippers", "pelicans", "DEE DNA", "RIGHT NOW", "Voice:"] {
            #expect(!trace.contains(word), "\(word)")
        }
        let sent = rig.brain.trace.compactMap { t -> String? in if case .dnaSent(_, _, _, _, _, _, _, let sha, _) = t { sha } else { nil } }
        #expect(sent.first == DNARender(text: dna, estimatedTokens: 0, steps: [], dropped: [], sectionBytes: [], fixedEchoes: 0).sha256)
        #expect(sent.allSatisfy { $0.count == 64 })
        rig.shutdown()
    }

    /// Spec F2 / F11: "Share memories" off end to end — no memory tools in the session,
    /// no facts in the DNA; and no shared moments or running jokes through the notes.
    @Test func shareMemoriesOffEndToEnd() async throws {
        let store = try MemoryStore(databaseURL: nil)
        let maya = try #require(await store.addPerson(named: "Maya", at: Date()))
        _ = await store.remember("likes jazz", category: .preference, about: maya.id, at: Date())
        _ = await store.remember("has a dog named Miso", category: .pet, about: maya.id, at: Date())
        let id = maya.id
        let rig = try await BrainRig(tools: BrainToolbox.memoryTools(store: store, currentPerson: { id }, share: false),
                                     memory: store, person: id)
        rig.host.shareMemories = false
        try await rig.start()
        let tools = rig.frames().filter { $0["type"] as? String == "session.update" }
            .compactMap { ($0["session"] as? [String: Any])?["tools"] as? [[String: Any]] }
            .flatMap { $0.compactMap { $0["name"] as? String } }
        #expect(!tools.contains("recall") && !tools.contains("remember") && !tools.contains("forget"), "\(tools)")
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        let dna = try #require(rig.dnaText("dna_tagabc_1"))
        #expect(!dna.contains("jazz") && !dna.contains("Miso"), "\(dna)")
        #expect(dna.contains("Memories are private"))
        rig.shutdown()

        // The notes and hooks the assembler lets through are dropped by the brain.
        let host = rig.host
        guard var parts = await host.dnaParts(DNARequest(turn: TurnContext(), pickNotes: false)) else {
            Issue.record("no parts"); return
        }
        parts.inputs.shareMemories = false
        var dna2 = DNAAssembler.assemble(parts.inputs)
        dna2.now.notes = [NoteLine(kind: .recall, role: .context, priority: 9, text: "You remember: they told me about their job interview"),
                          NoteLine(kind: .gagCallback, role: .aim, priority: 14, text: "bring back the pineapple joke"),
                          NoteLine(kind: .followUp, role: .aim, priority: 7, text: "ask how the interview went")]
        dna2.selfModel.gags = ["the pineapple pizza thing"]
        RealtimeBrain.keepMemoriesPrivate(&dna2)
        let text = DNAPrompt.render(dna2, guard: DNAGuardCorpus()).text
        #expect(!text.contains("You remember") && !text.contains("pineapple"), "\(text)")
        #expect(text.contains("ask how the interview went"), "a follow-up (a subject) still comes through")
    }
}

/// A tool that takes its time (a permission prompt).
struct SlowTool: AgentTool {
    let name: String
    let seconds: Double
    var spec: ToolSpec { ToolSpec(name: name, description: "Slow \(name).", parameters: []) }
    func run(_ call: ToolCall) async throws -> String {
        try? await Task.sleep(for: .seconds(seconds))
        return "No events."
    }
}
