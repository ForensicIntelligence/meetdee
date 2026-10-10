import AVFAudio
import DeeCore
import DeeRealtime
import Foundation
import Testing
@testable import DeeVoice

// Tune 4 (scratchpad/tune3-live.md; traces Tools/voice-harness/Traces/20261009-224148):
// (1) the speculative-reply gate — a reply's audio held in the player until the
// brain releases or discards it; (2) the server's tail item after the voice's own
// quick commit, and empty transcripts, never end a hold; (3) a quick burst's
// partial words that aren't "go on" wait for the transcript ("Go on." → "Jeron.").

// MARK: - (1) Player gate

@Suite struct PlayerGateTests {
    /// A gated utterance is buffered, never rendered; released, it starts within
    /// one render cycle and its played time counts from its first sample.
    @Test func aGatedUtterancePlaysOnlyOnceReleasedAndCountsExactly() throws {
        var r = try ManualRig()
        r.player.gate(utterance: "item_s")
        r.player.enqueue(PCMTone.data(ms: 1000), utterance: "item_s")
        r.player.finish(utterance: "item_s")
        try r.render(500)
        #expect(r.firstAudibleMs() == nil, "a gated reply was heard")
        #expect(r.log.started.isEmpty && r.log.finished.isEmpty)
        #expect(r.player.playedMs(utterance: "item_s") == 0)
        #expect(r.player.isGated(utterance: "item_s"))
        #expect(r.player.bufferedMs(utterance: "item_s") == 1000)
        #expect(r.player.isBusy)

        r.player.release(utterance: "item_s")
        let at = r.renderedMs
        try r.render(1300)
        let first = try #require(r.firstAudibleMs())
        #expect(first - at <= 25, "released audio started \(first - at) ms late")
        #expect(r.log.started == ["item_s"])
        #expect(r.log.finished.map(\.0) == ["item_s"] && r.log.finished.first?.1 == 1000
                && r.log.finished.first?.2 == false)
        #expect(abs(r.audibleMs() - 1000) < 15)
    }

    /// Released while still streaming: it starts with `minTargetMs` buffered, not
    /// the (adapted) jitter target.
    @Test func aReleaseStartsWithTheMinimumBuffer() throws {
        var r = try ManualRig()
        // A network that fell behind twice: the jitter target is up from 120 ms.
        r.player.enqueue(PCMTone.data(ms: 150), utterance: "item_x")
        try r.render(250)
        r.player.enqueue(PCMTone.data(ms: 200), utterance: "item_x")
        try r.render(350)
        r.player.finish(utterance: "item_x")
        try r.render(50)
        #expect(r.player.targetMs >= 150, "\(r.player.targetMs)")
        let quiet = r.output.count
        r.player.gate(utterance: "item_s")
        r.player.enqueue(PCMTone.data(ms: 140), utterance: "item_s")    // open: more to come
        try r.render(100)
        #expect(r.output[quiet...].allSatisfy { abs($0) <= 0.01 })
        r.player.release(utterance: "item_s")
        let at = r.output.count
        try r.render(20)
        #expect(r.output[at...].contains { abs($0) > 0.01 }, "a released reply waited for the jitter target")
    }

    /// Discarded: gone without a trace — no events, nothing rendered, no echo
    /// reference energy, late audio for it dropped, the ring given back.
    @Test func aDiscardLeavesNoTrace() throws {
        var r = try ManualRig()
        r.player.gate(utterance: "item_s")
        r.player.enqueue(PCMTone.data(ms: 800), utterance: "item_s")
        try r.render(200)
        _ = r.player.takeReference()
        #expect(r.player.discard(utterance: "item_s") == 800)
        #expect(!r.player.isBusy)
        r.player.enqueue(PCMTone.data(ms: 300), utterance: "item_s")    // a late delta
        try r.render(600)
        #expect(r.firstAudibleMs() == nil)
        #expect(r.log.all.allSatisfy { if case .level = $0 { true } else { false } }, "\(r.log.all)")
        #expect(r.player.takeReference().allSatisfy { $0.energy == 0 })
        #expect(r.player.bufferedMs == 0)
        // The next reply plays as usual.
        r.player.enqueue(PCMTone.data(ms: 500), utterance: "item_b")
        r.player.finish(utterance: "item_b")
        try r.render(700)
        #expect(r.log.started == ["item_b"])
        #expect(abs(r.audibleMs() - 500) < 15)
    }

    /// A gated utterance queued between two others, discarded: the render skips
    /// its audio — nothing of it plays, the next one follows the first.
    @Test func aDiscardInTheMiddleIsSkipped() throws {
        var r = try ManualRig()
        r.player.enqueue(PCMTone.data(ms: 300, hz: 300), utterance: "item_a")
        r.player.gate(utterance: "item_s")
        r.player.enqueue(PCMTone.data(ms: 400, hz: 900), utterance: "item_s")
        r.player.enqueue(PCMTone.data(ms: 300, hz: 300), utterance: "item_c")
        r.player.finish(utterance: "item_c")
        try r.render(100)
        r.player.discard(utterance: "item_s")
        try r.render(900)
        #expect(r.log.started == ["item_a", "item_c"])
        #expect(r.log.finished.map(\.1) == [300, 300])
        #expect(abs(r.audibleMs() - 600) < 25, "\(r.audibleMs()) ms audible")
    }
}

// MARK: - (1) Speculative replies on the real voice loop

extension LoopRig {
    /// A committed user turn answered speculatively: `speculate()`, `respond()`,
    /// the server's response with `ms` of audio (done when `done`).
    func speculativeTurn(resp: String = "resp_1", item: String = "item_a1", ms: Int = 1500,
                         done: Bool = true, audio: Bool = true) async throws {
        push(Srv.speechStarted("item_u1", ms: 100), Srv.speechStopped("item_u1", ms: 200), Srv.committed("item_u1"))
        _ = await brain.wait { if case .session(.userCommitted) = $0 { true } else { false } }
        voice.speculate()
        _ = try await voice.respond()
        push(Srv.responseCreated(resp))
        if audio { reply(resp, item, ms: ms) }
        if done { push(Srv.responseDone(resp)) }
        await settle()
    }

    func marks(_ stage: TurnTimeline.Stage) -> [TurnTimeline.Mark] {
        timeline.turns().flatMap(\.marks).filter { $0.stage == stage }
    }
}

@Suite(.serialized) struct SpeculativeReplyTests {
    @Test func aHeldReplyIsSilentUntilReleasedThenPlaysWhole() async throws {
        let rig = try LoopRig()
        let spec = Collector(rig.voice.speculativeEvents)
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.speculativeTurn()
        let at = rig.output.count
        try rig.quiet(0.6)
        await rig.settle()
        #expect(rig.audibleMs(fromSample: at) == 0, "a held reply was heard")
        let held = try #require(rig.voice.speculative)
        #expect(held.phase == .buffered && held.responseID == "resp_1" && held.items == ["item_a1"])
        #expect(held.bufferedMs == 1500 && held.complete)
        #expect(!rig.voiceEvents.contains(.speakingStarted))
        #expect(!rig.brain.all.contains { if case .sentenceStarted = $0 { true } else { false } })
        #expect(spec.all.contains(.started(responseID: "resp_1")))
        #expect(spec.all.contains { if case .ready("resp_1", "item_a1", _) = $0 { true } else { false } })

        #expect(rig.voice.releaseSpeculative(responseID: "resp_1"))
        #expect(rig.voice.speculative == nil)
        let released = rig.output.count
        try rig.quiet(0.06)
        #expect(rig.audibleMs(fromSample: released) > 20, "released audio did not start at once")
        try rig.quiet(1.8)
        await rig.settle()
        let played = try #require(rig.itemPlayed("item_a1"))
        #expect(played.ms == 1500 && !played.cut)
        #expect(rig.sent("conversation.item.truncate").isEmpty)
        #expect(spec.all.contains(.released(responseID: "resp_1", bufferedMs: 1500)))
        #expect(rig.voiceEvents.contains(.speakingStarted))
        rig.voice.shutdown()
    }

    /// Discarded after its audio came: nothing heard, no flush / cut / barge-in
    /// marks, no echo tail (an initiative right after is not refused as
    /// "speaking"); the server keeps none of it (truncated at 0).
    @Test func aDiscardedReplyLeavesNoSideEffects() async throws {
        let rig = try LoopRig()
        let spec = Collector(rig.voice.speculativeEvents)
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.speculativeTurn(done: false)
        try rig.quiet(0.3)
        #expect(rig.voice.discardSpeculative(responseID: "resp_x") == false, "a foreign id discarded it")
        #expect(rig.voice.discardSpeculative(responseID: "resp_1"))
        #expect(await rig.waitSent("conversation.item.truncate"))
        let trunc = rig.sent("conversation.item.truncate")
        #expect(trunc.count == 1 && trunc.first?["item_id"] as? String == "item_a1" && trunc.first?["audio_end_ms"] as? Int == 0)
        #expect(await rig.waitSent("response.cancel"))
        rig.push(Srv.responseDone("resp_1", status: "cancelled", reason: "client_cancelled"))
        let at = rig.output.count
        rig.reply("resp_1", "item_a1", ms: 300)                // late deltas
        await rig.settle()
        try rig.quiet(0.8)
        await rig.settle()
        #expect(rig.audibleMs(fromSample: at) == 0)
        #expect(rig.voice.speculative == nil && !rig.voice.graph.player.isBusy)
        #expect(spec.all.contains(.discarded(responseID: "resp_1", items: ["item_a1"], bufferedMs: 1500, byVoice: false, why: "brain")))
        #expect(rig.marks(.flushed).isEmpty && rig.marks(.truncateSent).isEmpty && rig.marks(.cancelSent).isEmpty)
        #expect(rig.marks(.bargeIn).isEmpty && rig.marks(.firstAudioPlayed).isEmpty)
        #expect(!rig.voiceEvents.contains(.bargeIn) && !rig.voiceEvents.contains(.speakingStarted))
        #expect(rig.itemPlayed("item_a1") == nil)
        #expect(rig.voice.floorHold == nil)
        // No echo of hers in the room, nothing "playing" for the session.
        #expect(await rig.voice.initiative(instructions: "Say hi.") == .sent)
        rig.voice.shutdown()
    }

    /// Discarded before any audio: the response is cancelled, and audio already
    /// on its way never plays.
    @Test func aDiscardBeforeAudioCancelsIt() async throws {
        let rig = try LoopRig()
        let spec = Collector(rig.voice.speculativeEvents)
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.speculativeTurn(done: false, audio: false)
        #expect(rig.voice.speculative?.phase == .waiting)
        #expect(rig.voice.discardSpeculative())
        #expect(await rig.waitSent("response.cancel"))
        let at = rig.output.count
        rig.reply("resp_1", "item_a1", ms: 500)
        rig.push(Srv.responseDone("resp_1", status: "cancelled", reason: "client_cancelled"))
        await rig.settle()
        try rig.quiet(0.8)
        #expect(rig.audibleMs(fromSample: at) == 0)
        #expect(spec.all.contains { if case .discarded("resp_1", [], 0, false, "brain") = $0 { true } else { false } })
        rig.voice.shutdown()
    }

    /// Nobody decides: the voice discards it `speculativeMax` after arming.
    @Test func anUndecidedSpeculationTimesOut() async throws {
        let rig = try LoopRig()
        let spec = Collector(rig.voice.speculativeEvents)
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.speculativeTurn()
        try rig.quiet(CloudVoice.speculativeMax + 0.2)
        await rig.settle()
        #expect(rig.voice.speculative == nil)
        #expect(spec.all.contains { if case .discarded(_, _, _, true, "timeout") = $0 { true } else { false } })
        #expect(rig.audibleMs(fromSample: 0) == 0)
        rig.voice.shutdown()
    }

    /// The user starts talking while a reply is held: it is speech over silence
    /// (accepted at once, no pause — nothing of hers is playing).
    @Test func speechOverAHeldReplyIsSpeechOverSilence() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.speculativeTurn()
        try rig.quiet(0.3)
        try rig.talk(0.3)
        rig.push(Srv.speechStarted("item_u2", ms: rig.uplinkMsNow - 250))
        await rig.settle()
        try rig.talk(0.3)
        await rig.settle()
        #expect(rig.voice.floorHold == nil)
        #expect(rig.brainSession { if case .userSpeechStarted("item_u2", _) = $0 { true } else { false } }.count == 1)
        #expect(rig.voice.discardSpeculative())
        try rig.quiet(0.5)
        #expect(rig.audibleMs(fromSample: 0) == 0)
        rig.voice.shutdown()
    }

    /// A cut (`stopSpeaking`) takes a held reply with it, reported to the brain.
    @Test func aCutTakesTheHeldReply() async throws {
        let rig = try LoopRig()
        let spec = Collector(rig.voice.speculativeEvents)
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.speculativeTurn()
        rig.voice.stopSpeaking()
        await rig.settle()
        try rig.quiet(0.5)
        #expect(rig.voice.speculative == nil)
        #expect(spec.all.contains { if case .discarded(_, ["item_a1"], _, true, "cut") = $0 { true } else { false } })
        #expect(rig.audibleMs(fromSample: 0) == 0)
        #expect(rig.voice.releaseSpeculative() == false)
        rig.voice.shutdown()
    }
}

// MARK: - (2) The server's tail after our quick commit; empty transcripts

@Suite(.serialized) struct HoldTailTests {
    /// t2-backchannel-echo10 bc01 (live 89.30–90.80): "Go on." paused her; the
    /// voice committed it at 90.17; the server's VAD ended "the rest" as its own
    /// item I9wISW (speech_stopped end 0.13 s after the commit, committed at once,
    /// transcript "" at 90.79), and that empty item flushed her (2,285 ms). Now the
    /// tail is part of the burst: she goes on, it is a backchannel for the brain,
    /// its "" never reaches the brain, and it leaves the conversation.
    @Test func theServersEmptyTailAfterOurCommitIsPartOfTheBurst() async throws {
        let rig = try LoopRig()
        let holds = Collector(rig.voice.holdEvents)
        try await rig.start()
        try await rig.pausedBy("item_u2", talk: 0.58)
        #expect(try await rig.stepUntil(0.6) { !rig.sent("input_audio_buffer.commit").isEmpty } != nil)
        let commitMs = rig.uplinkMsNow
        rig.push(Srv.committed("item_u2"))
        try rig.quiet(0.08)
        rig.push(Srv.speechStopped("item_tail", ms: commitMs + 130), Srv.committed("item_tail"))
        await rig.settle()
        let h = try #require(rig.voice.floorHold)
        #expect(h.tails == ["item_tail"] && h.itemID == "item_u2", "\(h)")
        try rig.quiet(0.08)
        rig.deltas("item_u2", ["Go", " on", "."])
        let resumed = try await rig.stepUntil(0.5) { rig.voice.floorHold == nil }
        #expect(resumed != nil, "she never went on")
        #expect(rig.voice.wasBackchannel(itemID: "item_tail") && rig.voice.wasBackchannel(itemID: "item_u2"))
        #expect(holds.all.contains { if case .resumed(let items, _, "words") = $0 { Set(items) == ["item_u2", "item_tail"] } else { false } },
                "\(holds.all)")
        rig.push(Srv.userTranscript("item_u2", "Go on."))
        try rig.quiet(0.2)
        rig.push(Srv.userTranscript("item_tail", ""))
        await rig.settle()
        #expect(rig.brainSession { if case .userTranscript("item_tail", _) = $0 { true } else { false } }.isEmpty)
        #expect(await rig.waitSent("conversation.item.delete"))
        #expect(rig.sent("conversation.item.delete").contains { $0["item_id"] as? String == "item_tail" })
        try rig.quiet(6)
        await rig.settle()
        #expect(rig.itemPlayed("item_a1").map { $0.ms == 6000 && !$0.cut } == true)
        #expect(rig.sent("conversation.item.truncate").isEmpty && rig.sent("response.cancel").isEmpty)
        #expect(!rig.voiceEvents.contains(.bargeIn))
        rig.voice.shutdown()
    }

    /// t2-backchannel-fan15 bc01 shape with the tail after the resume: it is still
    /// the burst's — a backchannel for the brain (`.resumed(why: "tail")`).
    @Test func aTailAfterSheWentOnIsABackchannelToo() async throws {
        let rig = try LoopRig()
        let holds = Collector(rig.voice.holdEvents)
        try await rig.start()
        try await rig.pausedBy("item_u2", talk: 0.58)
        #expect(try await rig.stepUntil(0.6) { !rig.sent("input_audio_buffer.commit").isEmpty } != nil)
        let commitMs = rig.uplinkMsNow
        rig.push(Srv.committed("item_u2"))
        try rig.quiet(0.12)
        rig.deltas("item_u2", ["Go", " on", "."])
        #expect(try await rig.stepUntil(0.5) { rig.voice.floorHold == nil } != nil)
        rig.push(Srv.speechStopped("item_tail", ms: commitMs + 150), Srv.committed("item_tail"))
        await rig.settle()
        #expect(rig.voice.wasBackchannel(itemID: "item_tail"))
        #expect(holds.all.contains(.resumed(itemIDs: ["item_tail"], text: "", why: "tail")), "\(holds.all)")
        rig.voice.shutdown()
    }

    /// Not a tail: their voice went on after our commit and the server's item
    /// ends a second later — a turn's words, never swallowed as a backchannel.
    @Test func speechAfterOurCommitIsNeverATail() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try await rig.pausedBy("item_u2", talk: 0.4)
        #expect(try await rig.stepUntil(0.5) { !rig.sent("input_audio_buffer.commit").isEmpty } != nil)
        let commitMs = rig.uplinkMsNow
        rig.push(Srv.committed("item_u2"))
        try rig.talk(0.9)
        rig.push(Srv.speechStopped("item_u3", ms: commitMs + 1000), Srv.committed("item_u3"))
        await rig.settle()
        #expect(rig.voice.floorHold?.tails.isEmpty ?? true)
        #expect(!rig.voice.wasBackchannel(itemID: "item_u3"))
        rig.voice.shutdown()
    }

    /// An empty transcript never ends a hold: nothing was said in it — she goes
    /// on (live, an empty item cut her).
    @Test func anEmptyTranscriptNeverEndsAHold() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try await rig.pausedBy("item_u2", talk: 0.3)
        #expect(try await rig.stepUntil(0.6) { !rig.sent("input_audio_buffer.commit").isEmpty } != nil)
        rig.push(Srv.committed("item_u2"))
        try rig.quiet(0.2)
        rig.push(Srv.userTranscript("item_u2", ""))
        let resumed = try await rig.stepUntil(0.5) { rig.voice.floorHold == nil }
        #expect(resumed != nil, "an empty item kept her paused")
        try rig.quiet(6.5)
        await rig.settle()
        #expect(rig.itemPlayed("item_a1").map { !$0.cut } == true)
        #expect(rig.sent("conversation.item.truncate").isEmpty)
        #expect(!rig.voiceEvents.contains(.bargeIn))
        rig.voice.shutdown()
    }
}

// MARK: - (3) "Go on." heard as "Jeron."

@Suite(.serialized) struct MisheardGoOnTests {
    /// t2-backchannel-echo20 bc01 (live 89.58–90.99): "Go on." (0.58 s) was
    /// committed by the voice at 90.47; the server's tail stopped 0.09 s later;
    /// the deltas said "Jeron." at 90.78 and she was flushed at 90.99 — before
    /// its transcript. Now "Jeron." is how a soft "go on" comes back: she goes on.
    @Test func goOnHeardAsJeronLetsHerGoOn() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try await rig.pausedBy("item_u2", talk: 0.58)
        #expect(try await rig.stepUntil(0.6) { !rig.sent("input_audio_buffer.commit").isEmpty } != nil)
        let commitMs = rig.uplinkMsNow
        rig.push(Srv.committed("item_u2"))
        try rig.quiet(0.04)
        rig.push(Srv.speechStopped("item_tail", ms: commitMs + 90))
        try rig.quiet(0.14)
        rig.deltas("item_u2", ["J", "eron", "."])
        let resumed = try await rig.stepUntil(0.5) { rig.voice.floorHold == nil }
        #expect(resumed != nil, "she stayed paused for \"Jeron.\"")
        #expect(rig.voice.wasBackchannel(itemID: "item_u2"))
        try rig.quiet(6.5)
        await rig.settle()
        #expect(rig.itemPlayed("item_a1").map { !$0.cut } == true)
        #expect(rig.sent("conversation.item.truncate").isEmpty)
        rig.voice.shutdown()
    }

    /// A quick burst's settled partial words that aren't "go on" don't end the
    /// hold before its transcript — at most `holdFinalWait` after its last delta.
    @Test func aQuickBurstsOtherWordsWaitForTheTranscriptBounded() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try await rig.pausedBy("item_u2", talk: 0.5)
        #expect(try await rig.stepUntil(0.6) { !rig.sent("input_audio_buffer.commit").isEmpty } != nil)
        rig.push(Srv.committed("item_u2"))
        try rig.quiet(0.12)
        rig.deltas("item_u2", ["Hm", "pf", "."])
        try rig.quiet(0.3)
        await rig.settle()
        #expect(rig.voice.floorHold != nil && rig.voice.floorHold?.wordsAt == nil, "decided on partial words")
        let decided = try await rig.stepUntil(0.6) { rig.voice.floorHold?.wordsAt != nil }
        #expect(decided != nil, "never decided without a transcript")
        rig.voice.shutdown()
    }

    @Test func misheardGoOnsAreBackchannelsButStopsAreNot() {
        for t in ["Jeron.", "Geron.", "Go-on.", "Goan."] { #expect(Backchannel.isBackchannel(t), "\(t)") }
        for t in ["Stop.", "Wait.", "Jerry, stop.", "Be quiet, please.", "Wait, stop talking for a second."] {
            #expect(!Backchannel.isBackchannel(t), "\(t)")
        }
    }
}
