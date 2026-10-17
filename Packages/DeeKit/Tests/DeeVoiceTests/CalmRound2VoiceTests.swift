import Foundation
import Testing
@testable import DeeVoice

// Calm round 2 (scratchpad calm/live.md, verdict NOT-SHIP; decisions D1 / D2). After 0.6.0 the
// user said "Wow! It works! But it's too sensitive to interruptions" — the TV, and their own
// short sounds (mm-hm, yeah, laughs, coughs, breaths) — in OpenAI mode 1. Round 1 ducked Dee
// for every onset but paused Dee again after 0.50 s of voice, so 15 of 33 continuers still
// went silent live; TV words still cut Dee and were answered; a stop under heavy echo was
// missed. Round 2: while ducked, Dee pauses only for a stop word or Dee's name (at its first
// transcript delta), or ~1.2 s of continuous near voice; in a loud room the voice must stand
// clearly above the bed. Each test reproduces a live trace first.

// MARK: - Fixtures over Dee, at the ear (the harness's mixing, `RoomSim`)

enum Round2 {
    /// A harness fixture over Dee's reply (l02 at −20 dBFS from 9 s, so a bed is learned
    /// first), the server's item for it (announced 0.35 s in, its stop 0.45 s after the end),
    /// the ear honouring its own ducks. `cond`: clean, echo10/echo20 (no AEC), tv15, fan15.
    static func overHer(_ id: String, cond: String) throws -> (sim: RoomSim, onset: Double, end: Double) {
        let herStart = 9.0
        var s = RoomSim(seconds: herStart + 8, aec: !cond.hasPrefix("echo"))
        s.core.duckOnOnset = true
        s.honorDucks = true
        switch cond {
        case "echo10": s.setEcho(gainDB: -10, delayMs: 80, ir: try HarnessFixture.wav("ir/room.wav"))
        case "echo20": s.setEcho(gainDB: -20, delayMs: 80, ir: try HarnessFixture.wav("ir/room.wav"))
        case "tv15": s.setBed(try HarnessFixture.wav("noise/tv.wav"), snrDB: 15)
        case "fan15": s.setBed(try HarnessFixture.wav("noise/fan.wav"), snrDB: 15)
        default: break
        }
        RoomSim.place(try herReply("l02", levelDB: -20, seconds: 7.5), into: &s.her, at: RoomSim.sample(herStart))
        let p = try s.say(id, at: herStart + 2.0)
        s.server = [(p.onset + RoomSim.sample(0.35), .start("item_x", onsetSample: p.onset - RoomSim.sample(0.1))),
                    (p.end + RoomSim.sample(0.45), .stop("item_x", endSample: p.end + RoomSim.sample(0.1)))]
        s.run()
        return (s, RoomSim.time(p.onset), RoomSim.time(p.end))
    }

    static func sustained(_ s: RoomSim) -> Bool { s.actions.contains { if case .sustained = $0 { true } else { false } } }
    static func bargedIn(_ s: RoomSim) -> Bool { s.actions.contains { if case .bargeIn = $0 { true } else { false } } }
    static func ducked(_ s: RoomSim) -> Bool { s.actions.contains { if case .duck = $0 { true } else { false } } }

    /// Fixture `id` as 48 kHz samples for `LoopRig` (from just before its onset to just after
    /// its end), scaled by `gain`.
    static func audio(_ id: String, gain: Float = 1) throws -> [Float] {
        let u = try HarnessFixture.utterance(id)
        let a = max(0, u.onset - 240), b = min(u.samples.count, u.end + 480)
        return EchoTenRoom.upsample(Array(u.samples[a..<b])).map { $0 * gain }
    }
}

// MARK: - 1. Continuers never pause Dee (live T1: 15 of 33 paused by the 0.50 s sustain)

@Suite(.serialized) struct Round2ContinuerTests {
    /// Live calm-bc-clean (193633): «MMHM.» bc02, «Aha.» bc04, «Mm.» bc07, «Oh wow.» bc08,
    /// «Mm-hmm.» bc11, «Okay.» bc12 each gave `duck … via=onset` at +0.14 s, then
    /// `hold … why=sustained all=0.52` at +0.50–0.54 s. Their counted voice really is past
    /// round 1's 0.50 s (reproduced here), and under round 2's `sustainVoice` (1.2 s).
    @Test(arguments: ["bc02", "bc04", "bc07", "bc08", "bc11", "bc12"])
    func theLiveContinuersWerePastRoundOnesBar(id: String) throws {
        let r = try Round2.overHer(id, cond: "clean")
        #expect(r.sim.sustainPeak.all >= 0.50 - 1e-9, "\(id): \(r.sim.sustainPeak)")
        #expect(r.sim.sustainPeak.all < CalmTuning.sustainVoice, "\(id): \(r.sim.sustainPeak)")
    }

    /// Every continuer and short sound of the harness, in every condition: Dee may duck, never
    /// pauses (no `.sustained`, no local-only barge-in).
    @Test(arguments: ["clean", "echo10", "echo20", "tv15", "fan15"])
    func continuersAndSoundsNeverPause(cond: String) throws {
        var paused: [String] = []
        for id in ["bc01", "bc02", "bc03", "bc04", "bc05", "bc06", "bc07", "bc08", "bc09", "bc10", "bc11", "bc12",
                   "ns01", "ns02", "ns03", "ns04", "ns05", "ns06", "ns07", "ns08", "ns09", "ns10", "ns11"] {
            let r = try Round2.overHer(id, cond: cond)
            if Round2.sustained(r.sim) || Round2.bargedIn(r.sim) { paused.append(id) }
        }
        #expect(paused.isEmpty, "\(cond): paused for \(paused)")
    }

    /// Continuous voice still pauses Dee: the long command c03 (2.3 s) in a quiet room.
    @Test func aLongTurnStillPausesBySound() throws {
        let r = try Round2.overHer("c03", cond: "clean")
        let t = try #require(r.sim.firstTime { if case .sustained = $0 { true } else { false } }, "\(r.sim.actions)")
        #expect(t - r.onset <= 2.1, "sustained \(t - r.onset) s in")
    }
}

// MARK: - 1b. A short question is answered without an early pause (live T4: q08 "Who made you?")

@Suite(.serialized) struct Round2QuestionTests {
    /// The real "Who made you?" (0.75 s) over Dee: ducked, never paused by its sound (round 1
    /// paused at 0.56 s: its voice counts 0.72 s); its words pause Dee (`why=answer`) — the
    /// brain's answer then ends the reply as in 0.6.0.
    @Test func whoMadeYouIsAnsweredByItsWords() async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(try Round2.audio("q08"), w)
        #expect(rig.voice.floorHold?.phase == .ducked, "\(rig.notes.map(\.text))")
        #expect(!rig.hasNote("sustained") && !w.held, "\(rig.notes.map(\.text))")
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 100), Srv.committed("item_u2"))
        await rig.settle()
        try rig.idle(0.1, w)
        rig.deltas("item_u2", ["Who", " made", " you", "?"])
        rig.push(Srv.userTranscript("item_u2", "Who made you?"))
        await rig.settle()
        #expect(rig.hasNote("hold item_u2 why=answer"), "\(rig.notes.map(\.text))")
        #expect(rig.graph.player.isHeld)
        _ = try await rig.voice.respond()
        #expect(await rig.waitSent("conversation.item.truncate"))
        rig.voice.shutdown()
    }
}

// MARK: - 2. TV rooms (live T2)

@Suite(.serialized) struct Round2TVRoomTests {
    /// Live: of 30 ducks in the tv15 runs, 1 had the TV gain (−6 dB): round 1's TV test (the
    /// share of voice-like frames among the bed's frames) never held, because the bed learns
    /// only the frames under its gate, where the harness TV is not voice-like. Reproduced on
    /// the harness bed itself; round 2 calls any bed this loud a TV room.
    @Test func theHarnessTVIsATVRoom() throws {
        var s = RoomSim(seconds: 14)
        s.core.duckOnOnset = true
        s.setBed(try HarnessFixture.wav("noise/tv.wav"), snrDB: 15)
        s.run()
        #expect(!s.core.bed.tvLike, "round 1's test (reproduced: it never found the TV)")
        let c = try #require(s.core.bed.ceilingDB)
        #expect(c >= CalmTuning.loudBedDB, "ceiling \(c)")
        #expect(s.core.tvRoom)
        // Calm off: never (0.6.0 has no TV room).
        var off = RoomSim(seconds: 6)
        off.setBed(try HarnessFixture.wav("noise/tv.wav"), snrDB: 15)
        off.run()
        #expect(!off.core.tvRoom)
    }

    @Test func aQuietRoomIsNoTVRoom() throws {
        var s = RoomSim(seconds: 8)
        s.core.duckOnOnset = true
        s.setBed(try HarnessFixture.wav("noise/fan.wav"), snrDB: 40)
        s.run()
        #expect(!s.core.tvRoom, "ceiling \(String(describing: s.core.bed.ceilingDB))")
    }

    /// The user's own words over Dee in the TV room are still theirs: every interruption of
    /// calm-ask-tv15 has its own voice over the TV (`CalmTuning.itemSustain` / share).
    @Test(arguments: ["c01", "c03", "c04", "c06", "c07", "c08", "q01", "q02", "q03", "q04", "q05", "q08"])
    func theirInterruptionsStandAboveTheTV(id: String) throws {
        let r = try Round2.overHer(id, cond: "tv15")
        #expect(r.sim.core.tvRoom)
        let v = try #require(r.sim.core.itemSustain(itemID: "item_x", until: r.end + 1))
        let need = CalmTuning.hasCommandWord(id.hasPrefix("c") ? "stop" : "") ? CalmTuning.commandVoice : CalmTuning.itemSustain
        #expect(v.voice >= need, "\(id): \(v)")
        #expect(id.hasPrefix("c") || v.voice >= CalmTuning.itemSustainShare * v.span, "\(id): \(v)")
    }
}

/// The harness TV bed in a `LoopRig` (48 kHz), with TV speech louder than its bed.
final class Round2TVLoop: @unchecked Sendable {
    let rig: LoopRig
    private let bed: [Float]
    private var pos = 0
    private let gain: Float

    init(duckOnOnset: Bool) throws {
        rig = try LoopRig(duckOnOnset: duckOnOnset)
        bed = EchoTenRoom.upsample(try HarnessFixture.wav("noise/tv.wav"))
        gain = Float(pow(10, (-24 - 15 - Level.rmsDB(bed)) / 20))      // tv15
    }

    func next(_ seconds: Double) -> [Float] {
        let n = Int(seconds * LoopRig.rate)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = bed[pos] * gain; pos = (pos + 1) % bed.count }
        return out
    }

    func feed(_ seconds: Double, _ w: PlayerWatch) throws { try rig.feed(next(seconds), w) }

    /// `x` over the bed.
    func mixed(_ x: [Float]) -> [Float] {
        let b = next(Double(x.count) / LoopRig.rate)
        return zip(x, b).map { $0 + $1 }
    }

    /// 8 s of TV, then Dee's quiet reply.
    func setUp(_ w: PlayerWatch) async throws {
        try await rig.start()
        try feed(8.0, w)
        rig.push(Srv.speechStarted("item_u1", ms: 100), Srv.speechStopped("item_u1", ms: 200), Srv.committed("item_u1"))
        _ = await rig.brain.wait { if case .session(.userCommitted) = $0 { true } else { false } }
        _ = try await rig.voice.respond()
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"))
        for _ in 0..<100 { rig.push(Srv.audio("resp_1", "item_a1", PCMTone.data(ms: 100, hz: 440, amplitude: 0.03))) }
        rig.push(Srv.audioDone("resp_1", "item_a1"), Srv.responseDone("resp_1"))
        await rig.settle()
        try feed(0.8, w)
    }

    /// The TV says `id` with its level (RMS) `aboveCeiling` dB over the bed's ceiling (0: as
    /// loud as the TV's own loud parts, which cross the room bar), after `lead` (a cough, …);
    /// the server opens `item` for it.
    func tvSays(_ id: String, aboveCeiling: Double, lead: [Float] = [], item: String, _ w: PlayerWatch) async throws {
        let c = try #require(rig.voice.earBed.ceilingDB)
        let u = try Round2.audio(id)
        let g = Float(pow(10, (c + aboveCeiling - Level.rmsDB(u)) / 20))
        try await rig.over(mixed(lead + u.map { $0 * g }), item: item, onsetAfter: 0.16 + Double(lead.count) / LoopRig.rate, w)
        try feed(0.3, w)
        rig.push(Srv.speechStopped(item, ms: rig.uplinkMsNow - 300), Srv.committed(item))
        await rig.settle()
        try feed(0.2, w)
    }
}

@Suite(.serialized) struct Round2TVWordsTests {
    /// Live calm-ask-tv15 94.92: `barge_in: -` / `hold - why=localOnly` with no server item,
    /// 2.0 s of silence, then the reply cut. Round 2: in a TV room the local-only run (no
    /// server item) neither pauses nor ducks Dee.
    @Test func theLocalOnlyRunNeverPausesInATVRoom() async throws {
        let tv = try Round2TVLoop(duckOnOnset: true)
        let w = PlayerWatch()
        try await tv.setUp(w)
        try #require(tv.rig.voice.floorHold == nil)
        let c = try #require(tv.rig.voice.earBed.ceilingDB)
        try tv.rig.feed(tv.mixed(Calm.voice(1.8, amplitude: Calm.harmonicAmplitude(db: c + 5))), w)
        await tv.rig.settle()
        try tv.feed(0.3, w)
        #expect(!w.held && !tv.rig.hasNote("hold") && !tv.rig.hasNote("duck"), "\(tv.rig.notes.map(\.text))")
        tv.rig.voice.shutdown()
    }

    /// Elsewhere the local-only run ducks Dee (round 1 paused Dee at once, `why=localOnly`), and
    /// only continuous voice past `sustainVoice` then pauses; calm off, 0.6.0's pause.
    @Test(arguments: [(true, 1.0), (true, 1.8), (false, 1.8)])
    func theLocalOnlyRunDucksElsewhere(calm: Bool, seconds: Double) async throws {
        let rig = try LoopRig(duckOnOnset: calm)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try rig.feed(Calm.voice(seconds), w)
        await rig.settle()
        try rig.idle(0.3, w)
        await rig.settle()
        let notes = rig.notes.map(\.text)
        if !calm {
            #expect(rig.hasNote("hold - why=legacy") && w.held, "\(notes)")
        } else {
            #expect(rig.hasNote("duck - gain=-12 via=localOnly"), "\(notes)")
            #expect(!rig.hasNote("hold - why=localOnly"), "\(notes)")
            #expect(w.held == (seconds > CalmTuning.sustainVoice + 0.3), "\(notes)")
        }
        rig.voice.shutdown()
    }

    /// Live calm-bc-tv15 136.90: the TV's «What's.» over Dee → `duck … gain=-12 via=onset`
    /// (round 1 never knew the room was a TV room), `hold … why=answer`, a cut, and a reply to
    /// the TV. Round 2: the TV room is known (−6 dB duck), the item has no voice of its own
    /// over the TV, its words are ambient: dropped, never a pause, never answered.
    @Test func theTVsWhatsNeverCutsDee() async throws {
        let tv = try Round2TVLoop(duckOnOnset: true)
        let w = PlayerWatch()
        try await tv.setUp(w)
        try await tv.tvSays("q06", aboveCeiling: 0, item: "item_tv", w)
        tv.rig.deltas("item_tv", ["What", "'s", "."])
        tv.rig.push(Srv.userTranscript("item_tv", "What's."))
        await tv.rig.settle()
        try tv.feed(0.4, w)
        await tv.rig.settle()
        let notes = tv.rig.notes.map(\.text)
        #expect(!w.held && tv.rig.truncates == 0 && tv.rig.bargeIns == 0, "\(notes)")
        #expect(!tv.rig.hasNote("hold item_tv"), "\(notes)")
        #expect(tv.rig.hasNote("duck item_tv gain=-6"), "\(notes)")
        #expect(tv.rig.hasNote("ambient item_tv"), "\(notes)")
        #expect(tv.rig.voice.isAmbient(itemID: "item_tv", text: "What's."))
        #expect(await tv.rig.waitSent("conversation.item.delete"), "the TV's item stays in the conversation")
        tv.rig.voice.shutdown()
    }

    /// 0.6.0 (calm off) on the same TV phrase: Dee went silent for the TV.
    @Test func theTVsWhats_flagOff_reproduces() async throws {
        let tv = try Round2TVLoop(duckOnOnset: false)
        let w = PlayerWatch()
        try await tv.setUp(w)
        try await tv.tvSays("q06", aboveCeiling: 0, item: "item_tv", w)
        #expect(w.held, "\(tv.rig.notes.map(\.text))")
        tv.rig.voice.shutdown()
    }

    /// Live calm-sounds-tv15 ns02 (re-run 202402, 13.96): a cough, then TV speech
    /// «I did the beginning.» 1.2 s later: `duck via=detector`, `hold why=sustained`, a cut and
    /// an answer. Round 2: no sustain (the TV is under the TV bar), the words are ambient.
    @Test func tvSpeechAfterACoughIsNeverAnswered() async throws {
        let tv = try Round2TVLoop(duckOnOnset: true)
        let w = PlayerWatch()
        try await tv.setUp(w)
        let cough = Calm.hiss(0.12, amplitude: 0.2) + Calm.hiss(0.1, amplitude: 0.08, seed: 9)
        try await tv.tvSays("q07", aboveCeiling: 0, lead: cough + tv.next(1.0), item: "item_tv", w)
        tv.rig.push(Srv.userTranscript("item_tv", "I did the beginning."))
        await tv.rig.settle()
        try tv.feed(0.4, w)
        await tv.rig.settle()
        let notes = tv.rig.notes.map(\.text)
        #expect(tv.rig.hasNote("duck item_tv gain=-6"), "\(notes)")
        #expect(tv.rig.hasNote("ambient item_tv"), "\(notes)")
        #expect(!tv.rig.hasNote("sustained"), "\(notes)")
        #expect(!w.held && tv.rig.truncates == 0 && tv.rig.bargeIns == 0, "\(notes)")
        #expect(!tv.rig.hasNote("hold item_tv"), "\(notes)")
        tv.rig.voice.shutdown()
    }

    /// Control: the user's own "Who made you?" at the phone in the same TV room is theirs.
    @Test func theirQuestionInTheTVRoomStillPausesDee() async throws {
        let tv = try Round2TVLoop(duckOnOnset: true)
        let w = PlayerWatch()
        try await tv.setUp(w)
        try await tv.rig.over(tv.mixed(try Round2.audio("q08")), item: "item_u2", w)
        try tv.feed(0.3, w)
        tv.rig.push(Srv.speechStopped("item_u2", ms: tv.rig.uplinkMsNow - 300), Srv.committed("item_u2"))
        await tv.rig.settle()
        tv.rig.push(Srv.userTranscript("item_u2", "Who made you?"))
        await tv.rig.settle()
        try tv.feed(0.1, w)
        await tv.rig.settle()
        #expect(tv.rig.hasNote("hold item_u2"), "\(tv.rig.notes.map(\.text))")
        #expect(!tv.rig.hasNote("ambient"), "\(tv.rig.notes.map(\.text))")
        tv.rig.voice.shutdown()
    }

    /// A stop word the TV says ("Wait!") pauses Dee only with the item's own voice over the TV.
    @Test func theTVsStopWordNeverPausesDee() async throws {
        let tv = try Round2TVLoop(duckOnOnset: true)
        let w = PlayerWatch()
        try await tv.setUp(w)
        try await tv.tvSays("c08", aboveCeiling: 0, item: "item_tv", w)
        tv.rig.deltas("item_tv", ["Wait", "."])
        await tv.rig.settle()
        try tv.feed(0.2, w)
        await tv.rig.settle()
        #expect(tv.rig.hasNote("duck item_tv gain=-6"), "\(tv.rig.notes.map(\.text))")
        #expect(!tv.rig.hasNote("hold item_tv"), "\(tv.rig.notes.map(\.text))")
        #expect(!w.held, "\(tv.rig.notes.map(\.text))")
        tv.rig.voice.shutdown()
    }
}

// MARK: - 3. A stop under heavy echo (live T5: t2-backchannel-echo10 c03)

@Suite(.serialized) struct Round2EchoStopTests {
    /// Live t2-backchannel-echo10 c03 (195702, 134.54): "Wait, stop talking for a second."
    /// over Dee's un-cancelled echo (−10 dB). Echo items «Bye.» and «Went.» were rejected
    /// first; the user's item ducked only at +1.38 s, and its words came only at its commit
    /// (deltas at +2.91 s). Reproduced on the harness mixing: here the ear never hears the
    /// user's voice under the echo, the item is rejected as Dee's echo at its commit, and
    /// round 1 never paused Dee at all. Round 2: the stop word in its first delta pauses Dee.
    @Test(arguments: [true, false])
    func aStopInAnItemRejectedAsEchoStillPausesDee(stop: Bool) async throws {
        let room = try EchoTenRoom(duckOnOnset: true)
        let replyStart = try await room.startReply(her: "l03", seconds: 8)
        let r = LoopRig.rate
        let u = try room.say("c03", atSample: replyStart + Int(1.4 * r))
        func at(_ s: Double) -> Int { u.onset + Int(s * r) }
        try room.run(untilSample: at(-0.44))
        room.rig.push(Srv.speechStarted("item_e1", ms: room.ms(atSample: at(-0.86))))
        await room.rig.settle()
        try room.run(untilSample: at(0.08))
        room.rig.push(Srv.speechStopped("item_e1", ms: room.ms(atSample: at(-0.11))), Srv.committed("item_e1"))
        room.rig.push(Srv.speechStarted("item_e2", ms: room.ms(atSample: at(-0.25))))
        await room.rig.settle()
        try room.run(untilSample: at(0.26))
        room.rig.deltas("item_e1", ["Bye", "."])
        try room.run(untilSample: at(0.51))
        room.rig.push(Srv.userTranscript("item_e1", "Bye."))
        await room.rig.settle()
        try room.run(untilSample: at(0.82))
        room.rig.push(Srv.speechStopped("item_e2", ms: room.ms(atSample: at(0.72))), Srv.committed("item_e2"))
        await room.rig.settle()
        try room.run(untilSample: at(0.90))
        room.rig.push(Srv.speechStarted("item_u3", ms: room.ms(atSample: at(0.49))))
        await room.rig.settle()
        try room.run(untilSample: at(0.96))
        room.rig.deltas("item_e2", ["Went", "."])
        await room.rig.settle()
        try room.run(untilSample: at(1.17))
        room.rig.push(Srv.userTranscript("item_e2", "Went."))
        await room.rig.settle()
        try room.run(untilSample: at(2.77))
        room.rig.push(Srv.speechStopped("item_u3", ms: room.ms(atSample: at(2.68))), Srv.committed("item_u3"))
        await room.rig.settle()
        try room.run(untilSample: at(2.91))
        let t0 = room.rig.graph.now
        room.rig.deltas("item_u3", stop ? ["Stop", " talking", " for", " a", " second", "."] : ["Nice", " one", "."])
        await room.rig.settle()
        if stop {
            let hold = try #require(room.rig.note("hold - why=stopword") ?? room.rig.note("hold item_u3"), "\(room.notes)")
            #expect(hold.t - t0 < 0.05, "paused \(hold.t - t0) s after the first delta")
            #expect(room.rig.graph.player.isHeld)
        } else {
            #expect(!room.rig.graph.player.isHeld, "Dee paused for words that stop nothing: \(room.notes)")
        }
        room.rig.voice.shutdown()
    }

    /// With no echo cancellation the ear's sustain test cannot count a voice under Dee's echo:
    /// the server's open item stands in for its length (`EarCore.serverSustain`). The long
    /// command pauses Dee before its end; no continuer does (checked in every condition above).
    @Test(arguments: ["echo10", "echo20"])
    func aLongCommandUnderEchoPausesBeforeItsWords(cond: String) throws {
        let r = try Round2.overHer("c03", cond: cond)
        let t = try #require(r.sim.firstTime { if case .sustained = $0 { true } else { false } }, "\(r.sim.actions)")
        #expect(t < r.end, "\(cond): sustained \(t - r.onset) s in, after the words ended")
    }

    /// The rule needs words Dee did not say: Dee's own "stop" in the echo never pauses Dee.
    @Test func herOwnStopWordInTheEchoNeverPausesHer() {
        var words = HerWords()
        words.add("Nothing can stop a curious robot like me.", at: 10)
        #expect(words.isHerEcho("Stop.", at: 11, strict: false, asks: false))
        #expect(!words.isHerEcho("Stop talking for a second.", at: 11, strict: false, asks: false))
    }
}

// MARK: - 4. Dee's own cap end over a sound (live T3: calm-sounds-clean ns09)

@Suite(.serialized) struct Round2OwnEndTests {
    /// Live calm-sounds-clean ns09 (202402, 156.14): "Ha ha!" over Dee → `duck` at +0.22 s;
    /// Dee's own sentence cap at +1.16 s escalated the duck (`hold why=brain`, `barge_in`,
    /// `bargeInSensed`); its transcript came back empty, and the brain answered the laugh with
    /// a 5.9 s reply. Round 2: Dee's own end releases the duck (no barge-in), and the voice
    /// claims the item's empty words; failed words are still the brain's to answer.
    @Test(arguments: ["", nil, "Who made you?"] as [String?])
    func herOwnEndOverALaughIsNoBargeIn(text: String?) async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let holds = Collector(rig.voice.holdEvents)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(try Round2.audio("ns09"), w)
        #expect(rig.voice.floorHold?.phase == .ducked, "\(rig.notes.map(\.text))")
        rig.voice.stopSpeaking(ownEnd: true)
        await rig.settle()
        #expect(rig.hasNote("unduck item_u2 (stopped)"), "\(rig.notes.map(\.text))")
        #expect(!rig.hasNote("hold item_u2"), "\(rig.notes.map(\.text))")
        #expect(rig.truncates == 1, "Dee's reply ends where Dee stopped")
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 100), Srv.committed("item_u2"))
        if let text {
            rig.push(Srv.userTranscript("item_u2", text))
        } else {
            rig.push(.inputTranscriptionFailed(.init(itemID: "item_u2", error: nil)))
        }
        await rig.settle()
        try rig.idle(0.1)
        await rig.settle()
        #expect(rig.voice.holdClaims(itemID: "item_u2") == (text == ""), "\(String(describing: text))")
        #expect(!holds.all.contains { if case .ended = $0 { true } else { false } }, "\(holds.all)")
        #expect(rig.bargeIns == 0)
        if text == "Ha ha." { #expect(rig.voice.isHoldBackchannel(itemID: "item_u2", text: "Ha ha.")) }
        rig.voice.shutdown()
    }

    /// Calm off: `stopSpeaking(ownEnd:)` is `stopSpeaking()` (the 0.6.0 cut of the hold).
    @Test func calmOffOwnEndIsAPlainStop() async throws {
        let rig = try LoopRig(duckOnOnset: false)
        let holds = Collector(rig.voice.holdEvents)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(try Round2.audio("ns09"), w)
        #expect(rig.voice.floorHold?.phase == .paused)
        rig.voice.stopSpeaking(ownEnd: true)
        await rig.settle()
        #expect(holds.all.contains { if case .ended = $0 { true } else { false } })
        #expect(!rig.voice.holdClaims(itemID: "item_u2"))
        rig.voice.shutdown()
    }
}

// MARK: - 5. Silence at the first delta of a stop word, Dee's name

@Suite(.serialized) struct Round2FirstDeltaTests {
    /// Live calm-ask-clean: lone "Stop." / "Wait." went silent at `hold why=stopword`
    /// +1.16–1.26 s, after the deltas settled (`holdSettle`) or the full transcript. Round 2:
    /// at the first delta that holds the word, before any settle and before the transcript.
    @Test(arguments: [("c01", "Stop"), ("c08", "Wait")])
    func aLoneStopPausesAtItsFirstDelta(id: String, word: String) async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(try Round2.audio(id), w)
        #expect(rig.voice.floorHold?.phase == .ducked && !w.held)
        #expect(try await rig.commitWhenAsked("item_u2", w))
        let t0 = rig.graph.now
        rig.deltas("item_u2", [word])
        await rig.settle()
        let hold = try #require(rig.note("hold item_u2 why=stopword"), "\(rig.notes.map(\.text))")
        #expect(hold.t - t0 < 0.005)
        rig.deltas("item_u2", ["."])
        rig.push(Srv.userTranscript("item_u2", "\(word)."))
        _ = try await rig.idleUntil(2.0) { rig.truncates > 0 }
        #expect(rig.truncates == 1, "the stop ends the reply")
        rig.voice.shutdown()
    }

    /// Dee's name — or the persona's — said over Dee pauses Dee at its first delta.
    @Test(arguments: [(["Dee", ","], [String]()), (["Mira", ","], ["Mira"]), (["Okay", " Dee", "."], [String]())])
    func theirNameForDeePausesDee(words: [String], names: [String]) async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        rig.voice.setAddressNames(names)
        try await rig.calmReply()
        try await rig.over(Calm.voice(0.5), w)
        #expect(try await rig.commitWhenAsked("item_u2", w))
        rig.deltas("item_u2", words)
        await rig.settle()
        #expect(rig.hasNote("hold item_u2 why=stopword"), "\(words): \(rig.notes.map(\.text))")
        rig.voice.shutdown()
    }

    /// A continuer is never a stop at its first delta ("Mm-hm", "Yeah", "Okay", "Right").
    @Test func continuersAreNoStopWords() {
        for t in ["Mm-hm.", "Okay.", "Mm.", "Aha.", "Oh wow.", "Yeah.", "Right.", "I see.", "Don't stop.",
                  "No, keep going.", "Go on.", "Haha, yeah.", "What's."] {
            #expect(!CalmTuning.hasCommandWord(t), "\(t)")
        }
        for t in ["Stop", "Wait", "Stop talking for a second.", "Wait, I have a question.", "Hold on,", "Hold up.",
                  "Okay Dee.", "Excuse me.", "One second."] {
            #expect(CalmTuning.hasCommandWord(t), "\(t)")
        }
        #expect(CalmTuning.hasCommandWord("Mira, hold", names: ["Mira"]))
        #expect(!CalmTuning.hasCommandWord("Mirage", names: ["Mira"]))
        #expect(CalmTuning.isStrongStop("Stop talking for a second.") && CalmTuning.isStrongStop("Wait."))
        #expect(!CalmTuning.isStrongStop("No.") && !CalmTuning.isStrongStop("What?"))
    }
}
