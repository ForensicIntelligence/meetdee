import DeeCore
import DeeRealtime
import DeeSelf
import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Tune 3 (live run 20261009-203321, tune2-live.md): the A/B turn detection on the
/// wire, minimal effort for ordinary turns, hum backchannels, the voice's floor holds,
/// and narration in any sentence. Each test replays the live trace where it can.
@Suite(.serialized) @MainActor struct Tune3BrainTests {
    typealias T2 = Tune2BrainTests

    /// Her reply `resp_1` / `item_a1` is playing (audio out, first sentence started).
    static func sheIsTalking(_ rig: BrainRig, _ sentence: String = "So the volcano went whoosh.") async {
        rig.utterance("item_u1")
        _ = await rig.until { rig.responseCreates().count == 1 }
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"))
        _ = await rig.until { rig.brain.trace.contains(.responseStarted(kind: "reply")) }
        for _ in 0..<5 { rig.push(Srv.audio("resp_1", "item_a1", Sig.pcm(ms: 100))) }
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 0, text: sentence))
        await rig.settle()
    }

    /// A user item over her voice: started, stopped, committed.
    static func over(_ rig: BrainRig, _ item: String) async {
        rig.push(Srv.speechStarted(item, ms: 3000))
        await rig.settle()
        rig.push(Srv.speechStopped(item, ms: 3600), Srv.committed(item))
    }

    // MARK: (1) Turn detection and effort

    /// F1: every session.update of the live run said semantic_vad `high`. The first
    /// session.update on the wire now carries the A/B winner.
    @Test func theSessionRunsServerVAD300() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        let update = try #require(rig.frames().first { $0["type"] as? String == "session.update" })
        let td = (((update["session"] as? [String: Any])?["audio"] as? [String: Any])?["input"] as? [String: Any])?["turn_detection"]
            as? [String: Any]
        #expect(td?["type"] as? String == "server_vad", "\(String(describing: td))")
        #expect(td?["silence_duration_ms"] as? Int == 300 && td?["prefix_padding_ms"] as? Int == 300)
        #expect((td?["threshold"] as? Double) == 0.5)
        #expect(td?["create_response"] as? Bool == false && td?["interrupt_response"] as? Bool == false)
        rig.shutdown()
    }

    /// F1 model share: create → first audio followed the reasoning tokens (0 tokens
    /// 0.44 s, 200+ 1.64 s p50). An ordinary turn asks for `minimal`; a fast turn is
    /// never re-asked just because its words are ordinary.
    @Test func ordinaryTurnsAskForMinimalEffort() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        let r = try #require(rig.responseCreates().first?["response"] as? [String: Any])
        #expect((r["reasoning"] as? [String: Any])?["effort"] as? String == "minimal", "\(r)")
        rig.push(Srv.userTranscript("item_u1", "What's your favourite colour?"))
        #expect(await rig.until { rig.host.heardLog.count == 1 })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.responseCreates().count == 1, "no rethink for an ordinary turn")
        #expect(RealtimeBrain.effective(.low) == .minimal && RealtimeBrain.effective(.medium) == .medium)
        rig.shutdown()
    }

    /// F1 brain share: the exact waits that timed out live (a stranger's first turn,
    /// t2-tools-clean / t2-fallback-rollover-speech at 5.3–5.6 s) are fast now.
    @Test func aStrangersFirstTurnIsAnsweredAtTheCommit() async throws {
        let rig = try await BrainRig(identified: false)
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "respondFast")) }, "\(rig.brain.trace)")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        #expect(!rig.brain.trace.contains(.exactTimedOut))
        rig.shutdown()
    }

    // MARK: (2) Backchannels and floor holds

    /// F4, t2-backchannel-kitchen15 bc02 ("Mm-hm." heard as "MMHN.") and
    /// t2-backchannel-echo20 bc02 ("HM."): the voice resumed her both times, then the
    /// brain's reply cut her. Now both are backchannels: no reply.
    @Test(arguments: ["MMHN.", "HM.", "Mm.", "Uh-huh."])
    func aHumOverHerVoiceIsNotAnswered(_ hum: String) async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await Self.sheIsTalking(rig)
        await Self.over(rig, "item_u2")
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "waitForPartial")) })
        T2.deltas(rig, "item_u2", hum)
        #expect(await rig.until { rig.brain.trace.contains(.backchannel("continued")) }, "\(hum): \(rig.brain.trace)")
        rig.push(Srv.userTranscript("item_u2", hum))
        #expect(await rig.until { rig.host.heardLog.count == 1 })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.responseCreates().count == 1, "\(hum): no reply to a hum")
        #expect(rig.count("response.cancel") == 0, "her voice was not stopped")
        rig.shutdown()
    }

    /// The voice settled the hold as a backchannel (`.resumed`) before the brain had
    /// words: the committed item is released, never answered, never holds the session.
    @Test func aHoldTheVoiceResumedIsNotAnswered() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await Self.sheIsTalking(rig)
        await Self.over(rig, "item_u2")
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "waitForPartial")) })
        rig.brain.injectHold(.resumed(itemIDs: ["item_u2"], text: "Go on.", why: "words"))
        #expect(await rig.until { rig.brain.trace.contains(.backchannel("resumed-words")) }, "\(rig.brain.trace)")
        try? await Task.sleep(for: .milliseconds(800))                  // past overlapWait
        #expect(rig.responseCreates().count == 1, "no reply")
        #expect(await rig.until { await rig.session.hasUnansweredUserTurn == false })
        rig.push(Srv.userTranscript("item_u2", "Go on."))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.responseCreates().count == 1, "nor when its words come")
        rig.shutdown()
    }

    /// The voice no longer emits `.bargeIn` when the brain's answer ends a hold: the
    /// brain tells the host. A hold the voice ended itself was announced by the voice.
    @Test func aHoldEndedByTheAnswerIsSensedAsABargeIn() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.brain.injectHold(.paused(itemID: "item_u2"))
        rig.brain.injectHold(.ended(itemIDs: ["item_u2"], byVoice: false))
        #expect(await rig.until { rig.host.bargeIns == 1 })
        #expect(rig.brain.trace.contains(.bargeInSensed))
        rig.brain.injectHold(.ended(itemIDs: ["item_u3"], byVoice: true))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.host.bargeIns == 1, "the voice announced that one itself")
        rig.shutdown()
    }

    // MARK: (3) Narration in any sentence

    /// F6, t2-fillers-clean f01 verbatim: the preamble was her second sentence, past
    /// the old 7-word window, and was heard. Now she stops before it; what she already
    /// said stands (no retry: she answered).
    @Test func narrationInALaterSentenceIsNeverHeard() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        #expect(await rig.until { rig.brain.trace.contains(.responseStarted(kind: "reply")) })
        for _ in 0..<5 { rig.push(Srv.audio("resp_1", "item_a1", Sig.pcm(ms: 100))) }
        T2.assistantDelta(rig, "resp_1", "item_a1", "Oh no, that sounds a bit disappointing. ")
        T2.assistantDelta(rig, "resp_1", "item_a1", "Let me think about how to respond. ")
        T2.assistantDelta(rig, "resp_1", "item_a1", "Bummer!")
        #expect(await rig.until { rig.brain.trace.contains(.narrationStop) }, "\(rig.brain.trace)")
        #expect(!rig.brain.trace.contains(.preamble(cut: true)), "nothing cut while her answer plays")
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 0, text: "Oh no, that sounds a bit disappointing."))
        rig.brain.inject(.sentenceFinished(itemID: "item_a1", index: 0, text: "Oh no, that sounds a bit disappointing.", heard: true))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!rig.brain.trace.contains(.preamble(cut: true)))
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 1, text: "Let me think about how to respond."))
        #expect(await rig.until { rig.brain.trace.contains(.preamble(cut: true)) }, "stopped before the narration")
        rig.push(Srv.responseDone("resp_1"))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.responseCreates().count == 1, "no retry: she had answered")
        rig.shutdown()
    }

    /// A first-sentence preamble keeps the tune-2 path (cut, answered again).
    @Test func aFirstSentencePreambleIsStillCutAndRetried() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        T2.assistantDelta(rig, "resp_1", "item_a1", "Nice, let me think about what I can")
        #expect(await rig.until { rig.brain.trace.contains(.preamble(cut: true)) })
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "answered again")
        rig.shutdown()
    }
}

@Suite struct Tune3PolicyTests {
    /// F4: the brain uses the voice's rule (with hums).
    @Test func humsAreBackchannels() {
        for t in ["MMHN.", "HM.", "Mm.", "mm", "Uh-huh.", "Mm-hm.", "Hmm.", "Keep going, I'm listening.", "Don't stop, keep going."] {
            #expect(TurnPolicy.isBackchannel(t), "\(t)")
            #expect(TurnPolicy.isBackchannel(t) == Backchannel.isBackchannel(t))
        }
        for t in ["Stop.", "Wait, stop talking for a second.", "Hmm, what's the name of that big red planet?", "No."] {
            #expect(!TurnPolicy.isBackchannel(t), "\(t)")
        }
    }

    /// F6: every sentence start, the first with the broad preamble set, later ones with
    /// narration about answering, looking up or saving only.
    @Test func narrationInAnySentence() {
        #expect(TurnPolicy.metaSentence(in: "Oh no, that sounds a bit disappointing. Let me think about how to respond. Bummer!") == 1)
        #expect(TurnPolicy.metaSentence(in: "Nice, let me think about what I can") == 0)
        #expect(TurnPolicy.metaSentence(in: "Two whole days! Let me check what I remember about you.") == 1)
        #expect(TurnPolicy.metaSentence(in: "Got it. I'll note that for later.") == 1)
        // Tune 9 (T8-4): thinking aloud after a real answer is narration too (the harness gate
        // and the judge counted "Let me think about the next one." as a leak).
        #expect(TurnPolicy.metaSentence(in: "Octopuses have three hearts, which is wild. Let me think of another one!") == 1)
        #expect(TurnPolicy.metaSentence(in: "That's a tough one. Let me think about it with you.") == 1)
        #expect(TurnPolicy.metaSentence(in: "Octopuses have three hearts, which is wild. Want another one?") == nil)
        #expect(TurnPolicy.metaSentence(in: "Mars is red because of rust. It's dusty up there.") == nil)
        #expect(TurnPolicy.sentences("A. B? C… d") == ["A.", "B?", "C…", "d"])
        #expect(TurnPolicy.sentences("It's 3.5 metres.") == ["It's 3.5 metres."])
    }

    /// F1: loud and stranger turns are fast; what needs the words still waits.
    @Test func exactOnlyWhereTheWordsMatter() {
        var c = TurnPolicy.Context(signals: CueModeSignals(unidentifiedSpeaker: true, turnsThisConversation: 0),
                                   prosody: ProsodyRead(loudness: 0.8, intensity: 0.9))
        #expect(TurnPolicy.onCommit(c) == .respondFast)
        c.signals.distressLive = true
        #expect(TurnPolicy.onCommit(c) == .waitForWords)
    }
}
