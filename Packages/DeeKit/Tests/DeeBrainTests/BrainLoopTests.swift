import DeeCore
import DeeRealtime
import DeeSelf
import Foundation
import Testing
@testable import DeeBrain

@Suite(.serialized) @MainActor struct BrainLoopTests {
    /// docs/DNA.md §4.1: a DNA item goes in right before every response.create; from
    /// the second response on, the previous DNA is deleted right after the new one.
    @Test func dnaPrecedesEveryResponseCreateAndThePreviousIsDeleted() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        #expect(rig.trail() == ["dna:dna_tagabc_1", "response.create"])
        rig.push(Srv.responseCreated("resp_1"), Srv.responseDone("resp_1"))
        await rig.settle()

        rig.utterance("item_u2", startMs: 3000, endMs: 3800)
        #expect(await rig.until { rig.responseCreates().count == 2 })
        #expect(rig.trail() == ["dna:dna_tagabc_1", "response.create",
                                "dna:dna_tagabc_2", "delete:dna_tagabc_1", "response.create"])
        // Replies never override the session instructions (D6).
        for r in rig.responseCreates() {
            #expect((r["response"] as? [String: Any])?["instructions"] == nil)
        }
        let dna = try #require(rig.dnaText("dna_tagabc_2"))
        #expect(dna.hasPrefix("DEE DNA v6 · reply · response 2"))
        #expect(dna.contains("Their words: judge them yourself"), "fast mode DNA")
        rig.shutdown()
    }

    /// Initiatives carry a DNA too (speaking first), and no per-response instructions.
    @Test func initiativesCarryDNA() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        try rig.quiet(0.2)
        var events: [ReplyEvent] = []
        let stream = rig.brain.respond(.initiative("(Ask one short question about the red ball you just noticed.)"),
                                       state: nil, effort: .low)
        #expect(await rig.until { rig.responseCreates().count == 1 })
        #expect(rig.trail() == ["dna:dna_tagabc_1", "response.create"])
        let dna = try #require(rig.dnaText("dna_tagabc_1"))
        #expect(dna.hasPrefix("DEE DNA v6 · you speak first"))
        #expect(dna.contains("What to open with: Ask one short question about the red ball"))
        #expect(!dna.contains("[") && !dna.contains("noticed.)"), "the directive's parentheses are gone")
        let r = try #require(rig.responseCreates().first?["response"] as? [String: Any])
        #expect(r["instructions"] == nil, "an empty instructions override is never sent")
        rig.push(Srv.responseCreated("resp_1"), Srv.responseDone("resp_1"))
        for try await e in stream { events.append(e) }
        #expect(events.last == .turnCompleted)
        rig.shutdown()
    }

    /// The typed (debug keyboard) path: the words go in as a user text item, then
    /// the DNA (exact mode, with what they meant), then response.create.
    @Test func keyboardTextBecomesAUserItem() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        let stream = rig.brain.respond(.user(words: "You are wonderful, thank you so much!"), state: nil, effort: .low)
        #expect(await rig.until { rig.responseCreates().count == 1 })
        #expect(rig.trail() == ["user:You are wonderful, thank you so much!", "dna:dna_tagabc_2", "response.create"])
        let dna = try #require(rig.dnaText("dna_tagabc_2"))
        #expect(dna.contains("What it meant:"), "exact mode DNA")
        #expect(rig.brain.guardCorpus.texts == 1)
        #expect(rig.host.heardLog.map(\.text) == ["You are wonderful, thank you so much!"])
        rig.push(Srv.responseCreated("resp_1"), Srv.responseDone("resp_1"))
        for try await _ in stream {}
        rig.shutdown()
    }

    /// Fast mode answers at the commit; exact mode (a stranger's first turn) waits
    /// for the words and puts their meaning in the DNA; with no words in time it
    /// falls back to fast.
    @Test func exactVersusFastMode() async throws {
        // Fast: an identified person, ordinary state.
        let fast = try await BrainRig(identified: true)
        try await fast.start()
        fast.utterance("item_u1")
        #expect(await fast.until { fast.responseCreates().count == 1 }, "fast mode asks at the commit")
        #expect(fast.brain.trace.contains(.committed(plan: "respondFast")))
        fast.shutdown()

        // Exact: nobody identified, first turn (name capture).
        let exact = try await BrainRig(identified: false, exactWords: true)
        try await exact.start()
        exact.utterance("item_u1")
        await exact.settle()
        #expect(exact.responseCreates().isEmpty, "exact mode waits for the words")
        exact.push(Srv.userTranscript("item_u1", "Hi, I'm Maya."))
        #expect(await exact.until { exact.responseCreates().count == 1 })
        let dna = try #require(exact.dnaText("dna_tagabc_1"))
        #expect(dna.contains("What it meant:"))
        #expect(exact.brain.trace.contains(.committed(plan: "waitForWords")))
        exact.shutdown()

        // Exact, but the transcript never comes in time: fast after 0.4 s.
        let late = try await BrainRig(identified: false, exactWords: true)
        try await late.start()
        late.utterance("item_u1")
        let start = ContinuousClock.now
        #expect(await late.until { late.responseCreates().count == 1 })
        let waited = ContinuousClock.now - start
        #expect(waited >= .milliseconds(350), "\(waited)")
        #expect(late.brain.trace.contains(.exactTimedOut))
        #expect(late.dnaText("dna_tagabc_1")?.contains("Their words: judge them yourself") == true)
        late.shutdown()
    }

    /// Every transcript feeds the 5-gram guard corpus, answered or not.
    @Test func guardCorpusIsFed() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        rig.push(Srv.userTranscript("item_u1", "My golden retriever Max chewed my favourite red slippers again."))
        #expect(await rig.until { rig.brain.guardCorpus.texts == 1 })
        // The corpus is fed before the host hears it (an await later): poll.
        #expect(await rig.until { rig.host.heardLog.count == 1 })
        rig.shutdown()
    }

    /// Asleep (or nobody engaged): the TV is never answered; her name is, with the
    /// words in the DNA.
    @Test func speechNotForHerIsNotAnswered() async throws {
        let rig = try await BrainRig(engaged: false)
        try await rig.start()
        rig.host.asleep = true
        rig.utterance("item_u1")
        rig.push(Srv.userTranscript("item_u1", "And now the weather for the weekend ahead."))
        #expect(await rig.until { rig.host.heardLog.count == 1 })
        await rig.settle()
        #expect(rig.responseCreates().isEmpty)
        #expect(rig.host.heardLog.first?.verdict == .ignored)
        #expect(rig.brain.trace.contains(.committed(plan: "waitForAddress")))

        rig.utterance("item_u2", startMs: 4000, endMs: 5000)
        rig.push(Srv.userTranscript("item_u2", "Dee, are you awake?"))
        #expect(await rig.until { rig.responseCreates().count == 1 })
        #expect(rig.dnaText("dna_tagabc_1")?.contains("What it meant:") == true)
        #expect(!rig.host.asleep, "her name woke her")
        rig.shutdown()
    }

    /// A spoken command is carried out, never answered.
    @Test func aCommandIsNotAnswered() async throws {
        let rig = try await BrainRig(identified: false, exactWords: true)    // exact: waits for the words
        try await rig.start()
        rig.utterance("item_u1")
        rig.push(Srv.userTranscript("item_u1", "Goodnight."))
        #expect(await rig.until { rig.host.commands == [.sleep] })
        await rig.settle()
        try? await Task.sleep(for: .milliseconds(450))
        #expect(rig.responseCreates().isEmpty)
        rig.shutdown()
    }

    /// The fast reply is never cancelled by its own transcript (no stopSpeaking on
    /// the user-utterance path), and a failed transcript closes the floor.
    @Test func theTranscriptNeverCancelsTheFastReply() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.userTranscript("item_u1", "Tell me something nice about rainbows."))
        #expect(await rig.until { rig.host.heardLog.count == 1 })
        await rig.settle()
        #expect(rig.count("response.cancel") == 0)

        rig.utterance("item_u2", startMs: 5000, endMs: 5600)
        rig.push(Srv.transcriptFailed("item_u2"))
        #expect(await rig.until { rig.host.wordsFailedCount == 1 })
        rig.shutdown()
    }

    /// Tools: a call runs through the toolbox, its output goes back, the follow-up
    /// reuses the live DNA. After `forget`, a fresh DNA replaces it first.
    @Test func toolRoundTripAndForgetReplacesTheDNA() async throws {
        let rig = try await BrainRig(tools: [FakeTool(name: "recall", reply: "Name: Maya. Likes jazz."),
                                             FakeTool(name: "forget", reply: "Forgot: likes jazz.")])
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"),
                 Srv.callDone("resp_1", item: "item_fc1", call: "call_1", name: "recall", args: #"{"query":"everything"}"#),
                 Srv.responseDone("resp_1"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "recall is always spoken")
        #expect(rig.trail() == ["dna:dna_tagabc_1", "response.create", "output:call_1", "response.create"])
        let output = rig.frames().first { ($0["item"] as? [String: Any])?["call_id"] as? String == "call_1" }
        #expect(((output?["item"] as? [String: Any])?["output"] as? String) == "Name: Maya. Likes jazz.")
        rig.push(Srv.responseCreated("resp_2"), Srv.responseDone("resp_2"))
        await rig.settle()

        rig.utterance("item_u2", startMs: 4000, endMs: 4800)
        #expect(await rig.until { rig.responseCreates().count == 3 })
        rig.push(Srv.responseCreated("resp_3"),
                 Srv.callDone("resp_3", item: "item_fc2", call: "call_2", name: "forget", args: #"{"fact":"jazz"}"#),
                 Srv.responseDone("resp_3"))
        #expect(await rig.until { rig.responseCreates().count == 4 }, "a silent forget is acknowledged")
        // The fresh DNA replaces the live one before the tool output and its follow-up.
        #expect(Array(rig.trail().suffix(4)) == ["dna:dna_tagabc_3", "delete:dna_tagabc_2", "output:call_2", "response.create"],
                "\(rig.trail())")
        #expect(rig.brain.trace.contains { if case .dnaReplaced = $0 { true } else { false } })
        rig.shutdown()
    }

    /// A reconnect starts a connection with no DNA: the first response there
    /// inserts a fresh one and deletes nothing (the old id lived on the old socket).
    @Test func reconnectClearsTheDNAId() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        let first = rig.socket
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates(on: first).count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.responseDone("resp_1"), on: first)
        await rig.settle()
        first.drop()
        #expect(await rig.until { !rig.brain.connected })
        for _ in 0..<40 where rig.factory.made.count < 2 {
            rig.clock.advance(by: 0.5)          // the session's reconnect back-off
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await rig.until { rig.factory.made.count == 2 && rig.brain.connected })
        let second = rig.socket
        #expect(second !== first)
        rig.utterance("item_u2", startMs: 300, endMs: 900)
        #expect(await rig.until { rig.responseCreates(on: second).count == 1 })
        // A fresh DNA under the new connection's own tag (the counter runs on).
        #expect(rig.trail(on: second).filter { $0 != "item:system" } == ["dna:dna_tagabc_2", "response.create"],
                "\(rig.trail(on: second))")
        #expect(!rig.trail(on: second).contains { $0.hasPrefix("delete:") })
        rig.shutdown()
    }

    /// Her sentences reach the host as playback passes them (deeSaid), and the
    /// reply's channel ends after her audio played out.
    @Test func deeSaidFollowsPlayback() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.reply("resp_1", "item_a1", ms: 800, text: "Hello there. Nice to see you.")
        await rig.settle()
        #expect(rig.host.said.isEmpty, "nothing is said before it is played")
        // Tune 5: the speculative gate re-checks once more (`releaseRecheck`) before
        // audio that was ready at the commit plays.
        for _ in 0..<120 {
            try rig.step()
            if rig.host.said.count == 2 { break }
            await Task.yield()
        }
        #expect(await rig.until { rig.host.said == ["Hello there.", "Nice to see you."] }, "\(rig.host.said)")
        #expect(await rig.until { rig.host.replies.first?.last == .turnCompleted })
        rig.shutdown()
    }

    /// The local prosody tap reads how the turn was said at the commit and the fast
    /// DNA carries it. Tune 3: a raised voice no longer waits for its words (live, the
    /// 0.4 s wait timed out 7 of 9 times); it is answered at once, loud in the DNA.
    @Test func loudSpeechIsAnsweredFastWithItsLoudness() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        try rig.quiet(0.3)
        try rig.talk(0.8, amplitude: 0.5)           // ≈ −14 dBFS: well above the baseline
        try rig.quiet(0.2)
        rig.utterance("item_u1", startMs: 300, endMs: 1100)
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "respondFast")) })
        #expect(await rig.until { rig.responseCreates().count == 1 })
        let loud = try #require(rig.dnaText("dna_tagabc_1"))
        #expect(!loud.contains("How they said it: soft"), "\(loud)")
        rig.shutdown()

        let soft = try await BrainRig()
        try await soft.start()
        try soft.quiet(0.3)
        try soft.talk(0.8, amplitude: 0.03)         // ≈ −38 dBFS
        try soft.quiet(0.2)
        soft.utterance("item_u1", startMs: 300, endMs: 1100)
        #expect(await soft.until { soft.brain.trace.contains(.committed(plan: "respondFast")) })
        #expect(await soft.until { soft.responseCreates().count == 1 })
        let dna = try #require(soft.dnaText("dna_tagabc_1"))
        #expect(dna.contains("How they said it: soft") || dna.contains("How they said it: normal"), "\(dna)")
        soft.shutdown()
    }
}
