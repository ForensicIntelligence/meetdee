import AVFAudio
import DeeCore
import DeeRealtime
import Foundation
import Testing
@testable import DeeVoice

// Tune 6 (scratchpad/tune5-live.md T5-2; traces Tools/voice-harness/Traces/20261010-020243):
// (1) the voice's quick commit of a hold splits their burst; the server goes on in
// an item it never announces (no speech_started) and stops / commits that one. The
// open speech must end there — in the voice (`userIsSpeaking`) and in the session
// (its "never start over someone" gate cancelled every answer at its first delta).
// (2) "I'm listening." starting just after she went on from "Keep going." never
// pauses her again: its words decide.

@Suite(.serialized) struct QuickCommitTailTests {
    /// t2-interrupt-clean q02 "Are you awake?" (live, 39.4–42.3 s): speech_started
    /// item_q over her reply → hold → our commit (40.37) → committed item_q (40.44)
    /// → speech_stopped + committed of the unannounced tail (40.60) → transcripts
    /// "Are you awake?" / "" → the brain answers (41.06) → its first delta (41.61)
    /// came with a `response.cancel` in the same ms, and so did the retry's. She
    /// never answered. Now: their speech is over at the tail's stop, the answer plays.
    @Test func theUnannouncedTailEndsTheirSpeechAndTheAnswerPlays() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try await rig.pausedBy("item_q", talk: 1.0)
        // They stop; the voice commits the burst itself (quick commit).
        let committedAfter = try await rig.stepUntil(1.0) { !rig.sent("input_audio_buffer.commit").isEmpty }
        #expect(committedAfter != nil, "no quick commit")
        rig.push(Srv.committed("item_q"))
        await rig.settle()
        try rig.quiet(0.16)
        // The server's own stop + commit, of an item it never announced.
        rig.push(Srv.speechStopped("item_tail", ms: rig.uplinkMsNow - 90), Srv.committed("item_tail"))
        try rig.quiet(0.18)
        rig.push(Srv.userTranscript("item_q", "Are you awake?"))
        try rig.quiet(0.2)
        rig.push(Srv.userTranscript("item_tail", ""))
        await rig.settle()
        // The voice: their speech is over (live: `userIsSpeaking` held 8 s, to their next onset).
        try rig.quiet(0.7)
        #expect(!rig.voice.userIsSpeaking, "their speech still open after the tail's stop")
        #expect(rig.voice.floorHold?.wordsAt != nil || rig.voice.floorHold == nil)

        // The brain answers (cutting her where she paused).
        _ = try await rig.voice.respond()
        #expect(await rig.waitSent("response.create"))
        let cancelsBefore = rig.sent("response.cancel").count
        rig.push(Srv.responseCreated("resp_2"))
        rig.reply("resp_2", "item_a2", ms: 800)
        rig.push(Srv.responseDone("resp_2"))
        await rig.settle()
        let from = rig.output.count
        try rig.quiet(1.2)
        await rig.settle()
        // The voice never drops or cancels the new answer itself.
        #expect(!rig.timeline.turns().flatMap(\.marks).contains { $0.detail?.contains("stopped before it started") == true })
        // The session's open-speech gate (DeeRealtime): fixed in tune 6.
        #expect(rig.sent("response.cancel").count == cancelsBefore, "the answer was cancelled at its first audio")
        #expect(rig.audibleMs(fromSample: from) > 700, "the answer never played")
        rig.voice.shutdown()
    }

    /// The same with EarCore alone: the committed open item ends at the next item's
    /// stop or commit, not at its own (it never comes).
    @Test func earCoreClosesTheCommittedOpenItemAtTheTail() {
        var core = EarCore()
        _ = core.setConnected(true, at: 0)
        _ = core.serverSpeechStarted(itemID: "q", onset: 0.9, at: 1.0)
        #expect(core.serverOpen == "q")
        _ = core.serverItemCommitted(itemID: "q", at: 2.0)
        #expect(core.serverOpen == "q", "our commit: they may be talking on")
        #expect(core.userIsSpeaking(at: 2.0))
        _ = core.serverSpeechStopped(itemID: "tail", end: 2.1, at: 2.2)
        #expect(core.serverOpen == nil)
        #expect(!core.userIsSpeaking(at: 3.0))
        // A commit of the tail without its stop closes it too.
        _ = core.serverSpeechStarted(itemID: "q2", onset: 4.0, at: 4.1)
        _ = core.serverItemCommitted(itemID: "q2", at: 5.0)
        _ = core.serverItemCommitted(itemID: "tail2", at: 5.2)
        #expect(core.serverOpen == nil)
        // An ordinary item: another item's stop never closes it.
        _ = core.serverSpeechStarted(itemID: "q3", onset: 6.0, at: 6.1)
        _ = core.serverSpeechStopped(itemID: "zz", end: 6.2, at: 6.3)
        #expect(core.serverOpen == "q3")
    }
}

@Suite(.serialized) struct AfterResumeTests {
    /// Her reply paused by "Keep going." and gone on from its words; then.
    private func resumedByKeepGoing(_ rig: LoopRig) async throws {
        try await rig.start()
        try await rig.pausedBy("item_u2", talk: 0.6)
        try rig.quiet(0.1)
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 100), Srv.committed("item_u2"))
        try rig.quiet(0.1)
        rig.deltas("item_u2", ["Keep", " going", "."])
        rig.push(Srv.userTranscript("item_u2", "Keep going."))
        let resumed = try await rig.stepUntil(1.0) { rig.voice.floorHold == nil }
        try #require(resumed != nil, "never went on")
    }

    /// t2-backchannel-fan15 / kitchen15 c05 (live): "Keep going." resumed her; "I'm
    /// listening." began 0.04–0.3 s later, over her again. Before: its onset paused
    /// her once more (tune5-voice.md, open item). Now she talks on; its words make
    /// it a backchannel; nothing is cut.
    @Test func imListeningJustAfterSheWentOnNeverPausesHer() async throws {
        let rig = try LoopRig()
        let holds = Collector(rig.voice.holdEvents)
        try await resumedByKeepGoing(rig)
        try rig.quiet(0.3)
        let onset = rig.output.count
        try rig.talk(0.15)
        rig.push(Srv.speechStarted("item_u3", ms: rig.uplinkMsNow - 150))
        await rig.settle()
        try rig.talk(0.65)
        await rig.settle()
        #expect(rig.voice.floorHold == nil, "\"I'm listening.\" paused her again")
        // She talked through it (her tone, not silence, while they spoke).
        #expect(rig.audibleMs(fromSample: onset) > 600, "she went quiet: \(rig.audibleMs(fromSample: onset)) ms")
        try rig.quiet(0.12)
        rig.push(Srv.speechStopped("item_u3", ms: rig.uplinkMsNow - 120), Srv.committed("item_u3"))
        // First words that settle on their own ("I'm still"): not a turn yet.
        rig.deltas("item_u3", ["I'm", " still"])
        try rig.quiet(0.25)
        #expect(rig.voice.floorHold == nil, "the settled \"I'm still\" paused her")
        rig.deltas("item_u3", [" listening", "."])
        try rig.quiet(0.1)
        rig.push(Srv.userTranscript("item_u3", "I'm still listening."))
        try rig.quiet(0.3)
        await rig.settle()
        #expect(rig.voice.floorHold == nil, "\"I'm still listening.\" paused her")
        #expect(rig.voice.wasBackchannel(itemID: "item_u3"))
        #expect(holds.all.contains(.resumed(itemIDs: ["item_u3"], text: "I'm still listening.", why: "after-resume")), "\(holds.all)")
        #expect(rig.sent("conversation.item.truncate").isEmpty)
        #expect(!rig.voiceEvents.contains(.bargeIn))
        rig.voice.shutdown()
    }

    /// A real turn right after she went on is still heard: its words pause her and
    /// the brain answers it.
    @Test func aQuestionJustAfterSheWentOnPausesHerByItsWords() async throws {
        let rig = try LoopRig()
        try await resumedByKeepGoing(rig)
        try rig.quiet(0.3)
        try rig.talk(0.15)
        rig.push(Srv.speechStarted("item_u3", ms: rig.uplinkMsNow - 150))
        await rig.settle()
        try rig.talk(0.65)
        try rig.quiet(0.12)
        rig.push(Srv.speechStopped("item_u3", ms: rig.uplinkMsNow - 120), Srv.committed("item_u3"))
        rig.deltas("item_u3", ["Wait", ",", " what", " time", " is", " it", "?"])
        let paused = try await rig.stepUntil(0.6) { rig.voice.floorHold != nil }
        #expect(paused != nil, "a question over her never paused her")
        #expect(!rig.voice.wasBackchannel(itemID: "item_u3"))
        rig.voice.shutdown()
    }

    /// Long after she went on, an onset pauses her on its sound as always.
    @Test func anOnsetLongAfterTheResumePausesHerAsAlways() async throws {
        let rig = try LoopRig()
        try await resumedByKeepGoing(rig)
        try rig.quiet(CloudVoice.resumeGrace + 0.3)
        try rig.talk(0.15)
        rig.push(Srv.speechStarted("item_u3", ms: rig.uplinkMsNow - 150))
        await rig.settle()
        try rig.talk(0.4)
        #expect(rig.voice.floorHold?.itemID == "item_u3")
        rig.voice.shutdown()
    }
}

@Suite struct MayBecomeBackchannelTests {
    @Test func prefixesOfContinuers() {
        for p in ["", "I'm", "I'm listen", "Keep", "Keep going, I'm", "Mm", "Go", "I'm listening."] {
            #expect(Backchannel.mayBecomeBackchannel(p), "\(p)")
        }
        for p in ["Wait", "Why", "I'm hungry", "Keep going, why", "Stop", "Go on?", "Is it"] {
            #expect(!Backchannel.mayBecomeBackchannel(p), "\(p)")
        }
    }
}
