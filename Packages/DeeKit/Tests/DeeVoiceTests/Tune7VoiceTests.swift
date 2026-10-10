import AVFAudio
import DeeCore
import DeeRealtime
import Foundation
import Testing
@testable import DeeVoice

// Tune 7 (scratchpad/tune6-live.md; traces Tools/voice-harness/Traces/20261010-035320):
// (T6-1) dropping the server's empty tail of a burst the voice committed must never cancel
// the answer the brain asked for in the meantime (interrupt-clean q02 "Are you awake?",
// interrupt-fan15 q08: `conversation.item.delete` + `response.cancel` in the same tick).
// (T6-4) with no echo cancellation, an onset over her that her loud echo masks pauses her
// at once (a probe) and the ear listens into her silence (stop-mood-echo20 c03 / backchannel-
// echo10 c03 "Wait, stop talking for a second.": paused 1.04–1.06 s after the onset).

// MARK: - T6-1: the empty tail's drop waits for the answer's first audio

@Suite(.serialized) struct EmptyTailKeepsTheAnswerTests {
    /// t2-interrupt-clean q02 (live 40.39–41.21): our quick commit of the hold, `committed`
    /// item_q, the server's stop + commit of the unannounced tail, the brain's request
    /// (40.684: after the tail's commit, so the session keyed the reply to the tail), then
    /// the tail's empty transcript (41.113) → the voice dropped it at once → the session
    /// cancelled the reply in the same tick ("Yes, I" never played).
    /// `createdFirst`: response.created came before the empty transcript (live), or after
    /// it (the request still on its way: only the `.responseCreateSent` mark says so).
    @Test(arguments: [true, false])
    func theEmptyTailIsDroppedOnlyOnceTheAnswerIsSafe(createdFirst: Bool) async throws {
        let rig = try LoopRig()
        try await rig.start()
        try await rig.pausedBy("item_q", talk: 1.0)
        let committedAfter = try await rig.stepUntil(1.0) { !rig.sent("input_audio_buffer.commit").isEmpty }
        try #require(committedAfter != nil, "no quick commit")
        rig.push(Srv.committed("item_q"))
        await rig.settle()
        try rig.quiet(0.16)
        rig.push(Srv.speechStopped("item_tail", ms: rig.uplinkMsNow - 90), Srv.committed("item_tail"))
        try rig.quiet(0.08)
        rig.push(Srv.userTranscript("item_q", "Are you awake?"))
        try rig.quiet(0.1)
        // The brain answers: its `.responseCreateSent` mark, then the request (after the tail's commit).
        _ = try await rig.voice.respond()
        #expect(await rig.waitSent("response.create"))
        let cancelsBefore = rig.sent("response.cancel").count
        if createdFirst {
            rig.push(Srv.responseCreated("resp_2"))
            await rig.settle()
        }
        // The tail's words: nothing.
        rig.push(Srv.userTranscript("item_tail", ""))
        await rig.settle()
        try rig.quiet(0.3)
        await rig.settle()
        #expect(rig.sent("response.cancel").count == cancelsBefore, "the answer was cancelled by the tail's drop")
        #expect(!deleted(rig, "item_tail"), "the tail was dropped while the answer had no audio yet")
        if !createdFirst {
            rig.push(Srv.responseCreated("resp_2"))
            await rig.settle()
            try rig.quiet(0.1)
            #expect(!deleted(rig, "item_tail"))
        }
        // The answer's first audio: now the tail goes, and nothing of the answer.
        let from = rig.output.count
        rig.reply("resp_2", "item_a2", ms: 800)
        rig.push(Srv.responseDone("resp_2"))
        // Tune 10: waited on events, not on time. The drop goes with the answer's first
        // audio (voice → session → socket, asynchronously); under full-suite load the
        // event pumps lag real time, and a fixed 0.2 s + one settle (or 1 s of 20 ms
        // steps) flaked. Everything up to `response.done` handled, then the frame.
        let done = await rig.brain.wait(timeout: 20) {
            if case .session(.responseDone(let r)) = $0, r.responseID == "resp_2" { true } else { false }
        }
        try #require(done != nil, "the answer's events never arrived")
        let dropped = await rig.socket.waitForSent(timeout: 20) { frames in
            frames.contains { $0.contains("conversation.item.delete") && $0.contains("item_tail") }
        }
        #expect(dropped, "the empty tail was never dropped")
        try rig.quiet(1.0)
        await rig.settle()
        #expect(rig.sent("response.cancel").count == cancelsBefore)
        #expect(rig.audibleMs(fromSample: from) > 700, "the answer never played")
        rig.voice.shutdown()
    }

    /// No reply anywhere near: the empty tail goes at once, as before.
    @Test func withNoReplyComingTheTailGoesAtOnce() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try await rig.pausedBy("item_q", talk: 1.0)
        _ = try await rig.stepUntil(1.0) { !rig.sent("input_audio_buffer.commit").isEmpty }
        rig.push(Srv.committed("item_q"))
        await rig.settle()
        try rig.quiet(0.16)
        rig.push(Srv.speechStopped("item_tail", ms: rig.uplinkMsNow - 90), Srv.committed("item_tail"))
        try rig.quiet(0.6)                       // her first reply's response is long done (`doneGuard`)
        rig.push(Srv.userTranscript("item_tail", ""))
        await rig.settle()
        try rig.quiet(0.1)
        await rig.settle()
        #expect(deleted(rig, "item_tail"))
        rig.voice.shutdown()
    }

    private func deleted(_ rig: LoopRig, _ item: String) -> Bool {
        rig.sent("conversation.item.delete").contains { $0["item_id"] as? String == item }
    }
}

// MARK: - T6-4: a probe pauses her when her loud echo masks the user

/// The live failure, on EarCore with the fixture voices: no echo cancellation, her echo
/// at −20 dB through the room IR with her voice at −16 dBFS (louder than the user), so the
/// user's voice sits under her echo. The server opened an item on her echo 0.27 s before
/// the user began, saw it 0.14 s after; stopped it at "Wait," (0.73 / 0.82 s) and put
/// "stop talking…" in a second item (0.46 / 0.88 s). Live, she paused only once that
/// second item's sound was decided, 1.06 s after the onset.
private func c03UnderLoudEcho(voice: String, gainDB: Double, level: Double, user: String? = "c03") throws -> RoomSim {
    var sim = RoomSim(seconds: 9, aec: false)
    sim.honorProbes = true
    sim.setEcho(gainDB: gainDB, delayMs: 80, ir: try HarnessFixture.wav("ir/room.wav"))
    RoomSim.place(try herReply("q01", levelDB: level, seconds: 1.5), into: &sim.her, at: RoomSim.sample(0.3))
    let herStart = RoomSim.sample(3.0)
    RoomSim.place(try herReply(voice, levelDB: level, seconds: 5.5), into: &sim.her, at: herStart)
    let onset = herStart + 1200 * 24
    if let user {
        let u = try HarnessFixture.utterance(user)
        RoomSim.place(u.samples, into: &sim.user, at: onset - u.onset)
    }
    sim.server = [(onset + RoomSim.sample(0.14), .start("u", onsetSample: onset - RoomSim.sample(0.27))),
                  (onset + RoomSim.sample(0.82), .stop("u", endSample: onset + RoomSim.sample(0.73)))]
    if user == "c03" {
        sim.server += [(onset + RoomSim.sample(0.88), .start("u2", onsetSample: onset + RoomSim.sample(0.46))),
                       (onset + RoomSim.sample(2.6), .stop("u2", endSample: onset + RoomSim.sample(2.4)))]
    }
    sim.tag = "t7-\(voice)-\(Int(-gainDB))"
    sim.run()
    return sim
}

private func isBarge(_ a: EarCore.Action) -> Bool { if case .bargeIn = a { true } else { false } }

@Suite(.serialized) struct ProbeUnderLoudEchoTests {
    static let onset = RoomSim.time(RoomSim.sample(3.0) + 1200 * 24)

    /// stop-mood-echo20 c03 (live: paused 1.06 s after the onset; tune 5: 0.22 s). Now she
    /// is paused (the probe) within 0.6 s of the onset, and their voice in her silence
    /// confirms it as a barge-in.
    @Test(arguments: ["l02", "f01", "l01", "d02", "q01", "l04"])
    func waitStopTalkingUnderHerEchoPausesHerAtOnce(voice: String) throws {
        let sim = try c03UnderLoudEcho(voice: voice, gainDB: -20, level: -16)
        let probe = try #require(sim.probes.first, "never paused (no probe) under her echo")
        #expect(probe - Self.onset <= 0.6, "paused \(probe - Self.onset) s after the onset")
        let barge = try #require(sim.firstTime(isBarge), "the probe was never confirmed: \(sim.probeEnds)")
        #expect(sim.probeEnds.allSatisfy { $0 > barge }, "she went on over them before it was confirmed")
        #expect(!sim.actions.contains(.rejectEcho(itemID: "u2")))
    }

    /// The same at −10 dB (backchannel-echo10 c03, live 1.04 s): paused within 0.6 s for
    /// every voice but one (her l02 voice hides even the "Wait,": the second item decides).
    @Test func waitStopTalkingUnderHerLouderEcho() throws {
        var late: [String] = []
        for voice in ["l02", "f01", "l01", "d02", "q01", "l04"] {
            let sim = try c03UnderLoudEcho(voice: voice, gainDB: -10, level: -20)
            let paused = [sim.probes.first, sim.firstTime(isBarge)].compactMap { $0 }.min()
            if paused == nil || paused! - Self.onset > 0.6 { late.append("\(voice): \(paused.map { $0 - Self.onset } ?? -1)") }
            #expect(sim.firstTime(isBarge) != nil, "\(voice): never stopped")
        }
        #expect(late.count <= 1, "\(late)")
    }

    /// Nobody talks: her echo opens the item. A probe (when her echo leaves a hint) ends
    /// on its own, she goes on, and it is never a barge-in.
    @Test(arguments: [(-20.0, -16.0), (-20.0, -20.0), (-10.0, -20.0), (-20.0, -12.0)])
    func herEchoAloneNeverStopsHer(gainDB: Double, level: Double) throws {
        for voice in ["l02", "f01", "l01", "d02", "q01", "l04"] {
            let sim = try c03UnderLoudEcho(voice: voice, gainDB: gainDB, level: level, user: nil)
            #expect(sim.firstTime(isBarge) == nil, "\(voice): she cut herself on her echo")
            #expect(sim.probes.count == sim.probeEnds.count, "\(voice): a probe never ended")
            for (a, b) in zip(sim.probes, sim.probeEnds) {
                #expect(b - a <= EarCore.probeMax + 0.05, "\(voice): paused \(b - a) s")
            }
        }
    }

    /// With echo cancellation there is no probe: the sound decides as before.
    @Test func noProbeWithEchoCancellation() throws {
        var sim = RoomSim(seconds: 8)
        sim.honorProbes = true
        sim.setEcho(gainDB: -30, delayMs: 80, ir: try HarnessFixture.wav("ir/room.wav"))
        RoomSim.place(try herReply("l02", seconds: 5.5), into: &sim.her, at: RoomSim.sample(1.0))
        let onset = RoomSim.sample(2.2)
        let u = try HarnessFixture.utterance("c03")
        RoomSim.place(u.samples, into: &sim.user, at: onset - u.onset)
        sim.server = [(onset + 6_000, .start("u", onsetSample: onset)), (onset + 60_000, .stop("u", endSample: onset + 55_000))]
        sim.run()
        #expect(sim.probes.isEmpty)
        #expect(sim.firstTime(isBarge) != nil)
    }
}

// MARK: - T6-4 in CloudVoice: the probe's pause, its confirmation, its end

@Suite(.serialized) struct ProbeLoopTests {
    /// Her reply playing with no echo cancellation and an onset over her the ear can't
    /// settle: the probe (as its hint starts one in her loud echo) pauses her at once; the
    /// brain hears nothing yet. Their voice in her silence makes it a hold from the pause:
    /// `.paused`, and — when the brain answers — the barge-in mark at the pause.
    @Test func theProbePausesHerAndTheirVoiceMakesItAHold() async throws {
        let rig = try LoopRig()
        _ = rig.graph.setManualFacts(aecActive: false, outputLatency: 0)
        let holds = Collector(rig.voice.holdEvents)
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 6000)])
        try rig.quiet(0.8)
        rig.push(Srv.speechStarted("item_u", ms: rig.uplinkMsNow - 60))
        await rig.settle()
        #expect(rig.voice.floorHold == nil)
        rig.voice.probeForTesting("item_u")
        let probeAt = rig.voice.graph.now
        #expect(rig.voice.isProbing)
        #expect(rig.voice.floorHold == nil, "a probe is not a hold for the brain yet")
        let pausedAt = rig.output.count
        try rig.quiet(0.1)
        #expect(rig.audibleMs(fromSample: pausedAt + Int(LoopRig.rate * 0.04)) < 30, "she talked on")
        #expect(holds.all.isEmpty)
        try rig.talk(0.5)
        await rig.settle()
        let hold = try #require(rig.voice.floorHold, "their voice in her silence never confirmed it")
        #expect(hold.items == ["item_u"])
        #expect(abs(hold.since - probeAt) < 0.03, "the hold starts at the pause")
        #expect(holds.all.first == .paused(itemID: "item_u"), "\(holds.all)")
        #expect(!rig.voice.isProbing)
        #expect(rig.audibleMs(fromSample: pausedAt + Int(LoopRig.rate * 0.04)) < 30, "she talked over them")
        // The brain answers their words: the barge-in is marked at the pause.
        rig.push(Srv.speechStopped("item_u", ms: rig.uplinkMsNow - 50), Srv.committed("item_u"),
                 Srv.userTranscript("item_u", "Wait, stop talking for a second."))
        await rig.settle()
        _ = try? await rig.voice.respond()
        await rig.settle()
        let mark = rig.timeline.turns().flatMap(\.marks).first { $0.stage == .bargeIn }
        #expect(mark.map { abs($0.t - probeAt) < 0.03 } == true, "\(String(describing: mark))")
        rig.voice.shutdown()
    }

    /// Nobody speaks into her silence: she goes on from exactly where she paused; nothing
    /// is announced, nothing cut, the brain never hears of it.
    @Test func aQuietProbeEndsAndSheGoesOn() async throws {
        let rig = try LoopRig()
        _ = rig.graph.setManualFacts(aecActive: false, outputLatency: 0)
        let holds = Collector(rig.voice.holdEvents)
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 3000)])
        try rig.quiet(0.8)
        rig.push(Srv.speechStarted("item_u", ms: rig.uplinkMsNow - 60))
        await rig.settle()
        rig.voice.probeForTesting("item_u")
        #expect(rig.voice.isProbing)
        let ended = try await rig.stepUntil(EarCore.probeMax + 0.2) { !rig.voice.isProbing }
        let took = try #require(ended, "the probe never ended")
        #expect(took <= EarCore.probeEchoClear + EarCore.probeQuiet + 0.1, "paused \(took) s for nobody")
        #expect(rig.voice.floorHold == nil)
        let resumedAt = rig.output.count
        try rig.quiet(0.3)
        #expect(rig.audibleMs(fromSample: resumedAt) > 250, "she never went on")
        try rig.quiet(3.0)
        await rig.settle()
        let played = try #require(rig.itemPlayed("item_a1"))
        #expect(played.ms == 3000 && !played.cut, "\(played)")
        #expect(holds.all.isEmpty, "\(holds.all)")
        #expect(!rig.voiceEvents.contains(.bargeIn))
        #expect(rig.sent("conversation.item.truncate").isEmpty)
        rig.voice.shutdown()
    }
}

// MARK: - T6-3: a backchannel misheard as a short fragment still lets her go on

@Suite struct MisheardFragmentTests {
    /// tune6-live T6-3: "Go on." → "Grand.", "Keep going" → "Put going." / "She.",
    /// "Mm-hm." → "MMHN." + "Done.".
    @Test func liveMisreadsAreFragments() {
        for t in ["Put going.", "Grand.", "She.", "Done.", "MMHN.", "Mm hn."] {
            #expect(Backchannel.isBackchannel(t, inHold: true), "\(t)")
        }
        #expect(Backchannel.isBackchannel("MMHN."))                // a hum anywhere
        // Outside a hold, or in a settled partial, a fragment is not a backchannel.
        #expect(!Backchannel.isBackchannel("Grand."))
        #expect(!Backchannel.isBackchannel("I'm", inHold: true, final: false))
    }

    @Test func turnsAreNeverFragments() {
        for t in ["Stop.", "Wait.", "Wait, stop.", "Who made you?", "Are you awake?", "Hello Dee.", "Hey.", "No.",
                  "Hold on.", "Tell me.", "Why", "I'm hungry.", "That's wrong.", "Be quiet, please.", "Call 911.",
                  "What time is it", "Stop talking for a second."] {
            #expect(!Backchannel.isMisheardFragment(t), "\(t)")
            #expect(!Backchannel.isBackchannel(t, inHold: true), "\(t)")
        }
    }
}

@Suite(.serialized) struct MisheardBackchannelLoopTests {
    /// t2-backchannel-echo10 bc01 (live 83.72): "Go on." over her came back as "Grand."
    /// and she was cut at 2005 ms. In a hold, in a short burst, its full transcript is a
    /// "go on": she resumes from where she paused; nothing is cut.
    @Test(arguments: [("Grand.", ["Grand", "."]), ("Put going.", ["Put", " going", "."]), ("She.", ["She", "."])])
    func aMisheardGoOnResumesHer(text: String, words: [String]) async throws {
        let rig = try LoopRig()
        let holds = Collector(rig.voice.holdEvents)
        try await rig.start()
        try await rig.pausedBy("item_u2", talk: 0.58)
        _ = try #require(try await rig.stepUntil(0.6) { !rig.sent("input_audio_buffer.commit").isEmpty }, "no commit")
        rig.push(Srv.committed("item_u2"))
        try rig.quiet(0.12)
        rig.deltas("item_u2", words)
        try rig.quiet(0.2)
        rig.push(Srv.userTranscript("item_u2", text))
        let resumed = try await rig.stepUntil(0.6) { rig.voice.floorHold == nil }
        #expect(resumed != nil, "\"\(text)\" never let her go on: \(holds.all) \(rig.timeline.turns().flatMap(\.marks).compactMap(\.detail))")
        try rig.quiet(1.5)
        await rig.settle()
        #expect(rig.sent("conversation.item.truncate").isEmpty, "\"\(text)\" cut her")
        #expect(!rig.voiceEvents.contains(.bargeIn))
        #expect(rig.voice.wasBackchannel(itemID: "item_u2"))
        #expect(holds.all.contains { if case .resumed(["item_u2"], _, "words") = $0 { true } else { false } }, "\(holds.all)")
        rig.voice.shutdown()
    }
}
