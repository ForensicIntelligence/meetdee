import AVFAudio
import DeeCore
import DeeRealtime
import Foundation
import Testing
@testable import DeeVoice

// Regression tests for the defects of the tune-1 live run
// (scratchpad/tune1-live.md, traces Tools/voice-harness/Traces/20261009-143612),
// reproduced offline from the harness's fixtures the way `Tune1VoiceTests` does.

// MARK: - Helpers

/// A user fixture placed so its speech onset lands at `at` seconds.
struct Placed {
    var id: String
    var onset: Int
    var end: Int
}

extension RoomSim {
    /// Places fixture `id` (scaled by `gain`) so its speech onset is at `seconds`.
    @discardableResult
    mutating func say(_ id: String, at seconds: Double, gain: Float = 1) throws -> Placed {
        let u = try HarnessFixture.utterance(id)
        let onset = RoomSim.sample(seconds)
        let start = onset - u.onset
        RoomSim.place(u.samples.map { $0 * gain }, into: &user, at: start)
        return Placed(id: id, onset: onset, end: start + u.end)
    }

    /// Energy ratio (dB) of what was sent to what the mic heard over `[a, b)` samples.
    func sentRatioDB(_ a: Int, _ b: Int) -> Double {
        let lo = max(0, a), hi = min(b, sent.count)
        guard hi > lo else { return 0 }
        var es = 0.0, em = 0.0
        for i in lo..<hi { es += Double(sent[i] * sent[i]); em += Double(mic[i] * mic[i]) }
        return Level.powerDB(es / Double(hi - lo)) - Level.powerDB(em / Double(hi - lo))
    }

    /// Level (dBFS) of what was sent over `[a, b)` samples.
    func sentDB(_ a: Int, _ b: Int) -> Double {
        let lo = max(0, a), hi = min(b, sent.count)
        guard hi > lo else { return -160 }
        return Level.rmsDB(Array(sent[lo..<hi]))
    }
}

// MARK: - (1) The TV bed never reaches the server between the user's words

@Suite(.serialized) struct UplinkGateTests {
    /// pauses-tv15 / fillers-holds-tv15 / two-part-tv15 (15 live drops): the TV at
    /// 15 dB SNR opened the server's VAD at 1.28 s and kept the item open 18 s,
    /// merging "In tonight's news, the City Council approved…" with p06a and
    /// p06b into one turn. With the gate, the TV between the user's turns goes up
    /// attenuated by ≥ 20 dB (the server hears silence there), while the user's
    /// own words — onset to end, mid-sentence pauses included — go through whole.
    @Test(arguments: ["tv", "fan", "kitchen"])
    func theBedBetweenTurnsIsGatedAndTheUserGoesThrough(bed: String) throws {
        var sim = RoomSim(seconds: 34)
        sim.gateUplink = true
        sim.setBed(try HarnessFixture.wav("noise/\(bed).wav"), snrDB: 15)
        let turns = [try sim.say("p06a", at: 3.0), try sim.say("p06b", at: 13.0),
                     try sim.say("q01", at: 21.0), try sim.say("c05", at: 27.5)]   // c05: the soft voice
        sim.run()
        for p in turns {
            let ratio = sim.sentRatioDB(p.onset, p.end)
            #expect(ratio >= -1.0, "\(bed) \(p.id): the user's words lost \(ratio) dB")
            // The very start of the turn (its first 60 ms of sound) is not clipped away.
            let head = sim.sentRatioDB(p.onset, p.onset + RoomSim.sample(0.06))
            #expect(head >= -6, "\(bed) \(p.id): onset clipped by \(head) dB")
        }
        // The bed alone, well away from any turn (after the 2 s it takes to learn).
        var gaps: [(Int, Int)] = []
        var from = RoomSim.sample(2.5)
        for p in turns {
            gaps.append((from, p.onset - RoomSim.sample(0.3)))
            from = p.end + RoomSim.sample(UplinkGate.hangover + 0.15)
        }
        let bedDB = -24 - 15.0
        for (a, b) in gaps where b - a > RoomSim.sample(0.5) {
            let out = sim.sentDB(a, b)
            if bed == "tv" || bed == "fan" {
                #expect(out <= bedDB - 20, "\(bed): the bed went up at \(out) dBFS in \(Double(a) / RoomSim.rate)…\(Double(b) / RoomSim.rate) s")
            }
        }
        if bed == "tv" {
            // The soft voice (c05) never taught the gate to shut the user out: the
            // bar stays within reach of a normal voice (−24 dBFS active).
            let bar = try #require(sim.core.uplinkBarDB)
            #expect(bar <= -29.5, "bar \(bar)")
        }
    }

    /// A quiet room (the clean runs): the gate never touches the user's speech.
    @Test func aQuietRoomIsNeverGatedOnSpeech() throws {
        var sim = RoomSim(seconds: 22)
        sim.gateUplink = true
        let turns = [try sim.say("q01", at: 1.0), try sim.say("p06a", at: 6.0), try sim.say("c05", at: 16.0)]
        sim.run()
        for p in turns {
            #expect(sim.sentRatioDB(p.onset, p.end) >= -0.3, "\(p.id)")
            #expect(sim.sentRatioDB(p.onset, p.onset + RoomSim.sample(0.06)) >= -1, "\(p.id) onset")
        }
    }

    /// The user talking from the very first second over the TV: the bed is learned
    /// with their voice in it, yet their words are never gated away.
    @Test func talkingFromTheFirstSecondOverTheTV() throws {
        var sim = RoomSim(seconds: 20)
        sim.gateUplink = true
        sim.setBed(try HarnessFixture.wav("noise/tv.wav"), snrDB: 15)
        let turns = [try sim.say("l05", at: 0.2), try sim.say("q01", at: 14.0)]
        sim.run()
        for p in turns {
            let ratio = sim.sentRatioDB(p.onset, p.end)
            #expect(ratio >= -1.5, "\(p.id): \(ratio) dB")
        }
    }

    /// The gate itself: below the bar 30 dB down after the hangover, above it whole,
    /// no bar → untouched.
    @Test func gateBlocks() {
        var g = UplinkGate()
        var quiet = [Int16](repeating: 300, count: 24_000)            // ≈ −41 dBFS
        var copy = quiet
        g.process(&copy, startFrame: 0)
        #expect(copy == quiet)                                         // no bar: as is
        g.barDB = -35
        g.process(&quiet, startFrame: 24_000)
        #expect(abs(Int(quiet.last!)) <= 10)                           // −30 dB
        var loud = [Int16](repeating: 3_000, count: 4_800)             // ≈ −21 dBFS
        let before = loud
        g.process(&loud, startFrame: 48_000)
        #expect(loud.suffix(4_000).allSatisfy { $0 == 3_000 })         // opened within 2 ms
        #expect(loud.first! < before.first!)                           // ramped, no click
        var tail = [Int16](repeating: 300, count: 24_000)
        g.process(&tail, startFrame: 52_800)
        #expect(tail[Int(0.3 * 24_000)] == 300)                        // hangover keeps the word end
        #expect(abs(Int(tail.last!)) <= 10)
    }

    /// The bed's ceiling is where its loud seconds go (a TV's quieter seconds don't
    /// pull it down), and a bed that changed is followed once its old slices left.
    @Test func bedCeilingFollowsTheLoudSecondsAndExpires() {
        var bed = RoomBed()
        var t = 0.0
        while t < 6 {
            t += 0.04
            let loudSecond = Int(t) % 4 != 0
            bed.add((loudSecond ? -36.0 : -40.0) + Double(Int(t * 25) % 5) - 2, duration: 0.04, at: t)
        }
        #expect(bed.ceilingDB.map { $0 >= -35 && $0 <= -33 } ?? false, "\(String(describing: bed.ceilingDB))")
        // The bed drops by 15 dB (the tap turned off): after a window it follows.
        while t < 16 {
            t += 0.04
            bed.add(-55 + Double(Int(t * 25) % 5) - 2, duration: 0.04, at: t)
        }
        #expect(bed.ceilingDB.map { $0 <= -52 } ?? false, "\(String(describing: bed.ceilingDB))")
        // No frames for a long time (she talks): the last ceiling stands.
        bed.advance(to: 40)
        #expect(bed.ceilingDB != nil)
    }
}

/// Her reply for the scenarios: a long TTS turn from the fixtures at `levelDB`.
func herReply(_ id: String = "l02", levelDB: Double = -20, seconds: Double? = nil) throws -> [Float] {
    let u = try HarnessFixture.utterance(id)
    var x = Array(u.samples[u.onset..<u.end])
    if let seconds { x = Array(x.prefix(Int(seconds * RoomSim.rate))) }
    let g = Float(pow(10, (levelDB + 24) / 20))
    return x.map { $0 * g }
}

private func isBargeIn(_ a: EarCore.Action) -> Bool { if case .bargeIn = a { true } else { false } }

// MARK: - (2) Real speech over her reply is never deleted as echo

@Suite(.serialized) struct SoftVoiceOverTheRoomTests {
    /// long-fan15 c05 / long-kitchen15 c05 (live: `item_EXCreyZQ…` deleted as
    /// echo): the soft "Keep going, I'm listening." (−32 dBFS) 1.5 s into her
    /// reply over a fan or the kitchen at 15 dB SNR (no echo). The fixed bar 9 dB
    /// over the floor sat above the soft voice; over a known bed it is the bed's
    /// ceiling + 3 dB, and the words are the user's.
    @Test(arguments: ["fan", "kitchen"])
    func softKeepGoingOverTheBedIsTheUser(bed: String) throws {
        var sim = RoomSim(seconds: 16)
        sim.tag = "soft\(bed)"
        sim.setBed(try HarnessFixture.wav("noise/\(bed).wav"), snrDB: 15)
        try sim.say("q01", at: 0.5)                                   // the turn she answers
        let herStart = RoomSim.sample(4.0)
        RoomSim.place(try herReply(seconds: 8), into: &sim.her, at: herStart)
        let c05 = try sim.say("c05", at: 5.5)
        // The live server: speech_started ~0.3 s after the onset (its audio_start
        // ~0.3 s before it), speech_stopped ~0.8 s after the end.
        sim.server = [(c05.onset + RoomSim.sample(0.27), .start("item_u", onsetSample: c05.onset - RoomSim.sample(0.3))),
                      (c05.end + RoomSim.sample(0.8), .stop("item_u", endSample: c05.end + RoomSim.sample(0.7)))]
        sim.run()
        #expect(!sim.actions.contains(.rejectEcho(itemID: "item_u")), "\(bed): the soft words were deleted as echo")
        #expect(sim.actions.contains(.bargeIn(itemID: "item_u")) || sim.actions.contains(.acceptOnset(itemID: "item_u")))
    }

    /// The same beds with only her voice: nothing she says is ever taken for the
    /// user (the lower bar over a known bed doesn't let the bed through).
    @Test(arguments: ["fan", "kitchen", "tv"])
    func theBedAloneNeverBargesIn(bed: String) throws {
        var sim = RoomSim(seconds: 14)
        sim.setBed(try HarnessFixture.wav("noise/\(bed).wav"), snrDB: 15)
        try sim.say("q01", at: 0.5)
        let herStart = RoomSim.sample(4.0)
        RoomSim.place(try herReply(seconds: 8), into: &sim.her, at: herStart)
        // The server opens "speech" on the bed twice while she talks (a TV would).
        for (k, at) in [5.0, 8.0].enumerated() {
            let s = RoomSim.sample(at)
            sim.server.append((s + RoomSim.sample(0.3), .start("item_b\(k)", onsetSample: s)))
            sim.server.append((s + RoomSim.sample(1.6), .stop("item_b\(k)", endSample: s + RoomSim.sample(1.2))))
        }
        sim.run()
        #expect(!sim.actions.contains(where: isBargeIn), "\(bed): she was cut by the room")
        for k in 0..<2 { #expect(sim.actions.contains(.rejectEcho(itemID: "item_b\(k)")), "\(bed) item_b\(k)") }
    }
}

// MARK: - (2) Real speech over her loud echo (no echo cancellation)

@Suite(.serialized) struct LoudEchoNearEndTests {
    /// long-echo10 c02 / c05 and fillers-holds-echo10 k03 (live: deleted as echo):
    /// her echo at −10 dB / 80 ms through the room IR with echo cancellation off
    /// — about as loud as the user — opened a server item on her own voice (0.1 s
    /// into her reply); the user then spoke inside that same item. The item holds
    /// their words: it must never be deleted as echo.
    @Test(arguments: [("c02", 1.5, -10.0), ("c05", 1.5, -10.0), ("k03", 1.0, -10.0), ("c02", 1.5, -20.0)])
    func theUserInsideAnItemHerEchoOpenedIsKept(fixture: String, after: Double, gainDB: Double) throws {
        var sim = RoomSim(seconds: 14, aec: false)
        sim.tag = "loud\(fixture)\(Int(-gainDB))"
        sim.setEcho(gainDB: gainDB, delayMs: 80, ir: try HarnessFixture.wav("ir/room.wav"))
        // An earlier reply taught her the echo path.
        RoomSim.place(try herReply("l01", seconds: 2.5), into: &sim.her, at: RoomSim.sample(0.3))
        let herStart = RoomSim.sample(4.0)
        RoomSim.place(try herReply(seconds: 7), into: &sim.her, at: herStart)
        let u = try sim.say(fixture, at: 4.0 + after)
        let echoOnset = herStart + RoomSim.sample(0.1)
        sim.server = [(echoOnset + RoomSim.sample(0.6), .start("item_x", onsetSample: echoOnset)),
                      (u.end + RoomSim.sample(0.7), .stop("item_x", endSample: u.end + RoomSim.sample(0.6)))]
        sim.run()
        #expect(!sim.actions.contains(.rejectEcho(itemID: "item_x")), "\(fixture) at \(gainDB) dB: the user's words were deleted as echo")
        // Kept: taken for the user on the sound, or (her echo as loud as them)
        // left to its words — never deleted on the sound alone.
        #expect(sim.actions.contains(.bargeIn(itemID: "item_x")) || sim.actions.contains(.acceptOnset(itemID: "item_x"))
                || sim.actions.contains(.deferToWords(itemID: "item_x", strict: true)) || sim.actions.contains(.deferToWords(itemID: "item_x", strict: false)))
    }
}

// MARK: - (4) "Keep going" over her voice is a backchannel: she goes on

@Suite struct BackchannelTests {
    /// The same rule as the brain's floor logic (DeeBrain `TurnPolicy`'s cases).
    @Test func backchannels() {
        for t in ["Keep going, I'm listening.", "Don't stop, keep going.", "Mm-hm.", "Uh-huh.", "Go on.", "Yeah, go on.",
                  "Keep going.", "No, keep going.", "Okay, keep going, Dee.", "mhm", "Really?", "Yeah.", "Keep going. I'm listening.",
                  "Cheap, going.", "MMHN.", "Hmm.", "Mmm-hmm.", "An MHM."] {
            #expect(Backchannel.isBackchannel(t), "\(t)")
        }
        for t in ["Wait, stop talking for a second.", "Stop.", "No.", "Keep going with what?", "What did you say?",
                  "Yeah, but what about the moon?", "Okay, stop.", "Hold on.", "", "I like volcanoes too.", "Dee."] {
            #expect(!Backchannel.isBackchannel(t), "\(t)")
        }
    }
}

extension LoopRig {
    /// A committed turn answered with her reply: `items` (id, ms) in one response.
    func answerWith(_ items: [(String, Int)], text: String? = nil, done: Bool = true) async throws {
        push(Srv.speechStarted("item_u1", ms: 100), Srv.speechStopped("item_u1", ms: 200), Srv.committed("item_u1"))
        _ = await brain.wait { if case .session(.userCommitted) = $0 { true } else { false } }
        _ = try await voice.respond()
        push(Srv.responseCreated("resp_1"))
        for (item, ms) in items { reply("resp_1", item, ms: ms) }
        if let text, let first = items.first { push(Srv.transcript("resp_1", first.0, text)) }
        if done { push(Srv.responseDone("resp_1")) }
        await settle()
    }

    var uplinkMsNow: Int { uplink().count / 24 }

    func itemPlayed(_ item: String) -> (ms: Int, cut: Bool)? {
        brain.all.compactMap { e -> (Int, Bool)? in
            if case .itemPlayed(item, let ms, let cut) = e { (ms, cut) } else { nil }
        }.first
    }
}

@Suite(.serialized) struct FloorHoldLoopTests {
    /// long-* c02 / c05 (the user's decision: "keep going" while she talks is a
    /// backchannel, not a barge-in): the barge-in pauses her at once; their words
    /// are "Keep going, I'm listening." — she goes on from exactly where she
    /// paused. Nothing is cut or cancelled, no `.bargeIn`, the item plays whole.
    @Test func keepGoingResumesWhereSheStopped() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 2000)])
        try rig.quiet(0.6)
        try rig.talk(0.15)
        rig.push(Srv.speechStarted("item_u2", ms: rig.uplinkMsNow - 150))
        await rig.settle()
        try rig.talk(0.3)
        #expect(rig.voice.floorHold?.itemID == "item_u2")
        let paused = rig.voice.graph.player.playedMs(utterance: "item_a1")
        let pausedAt = rig.output.count
        try rig.quiet(0.4)
        #expect(rig.audibleMs(fromSample: pausedAt) < 10, "she kept talking over them")
        #expect(rig.voice.graph.player.playedMs(utterance: "item_a1") - paused <= 6)
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 200), Srv.committed("item_u2"),
                 Srv.userTranscript("item_u2", "Keep going, I'm listening."))
        await rig.settle()
        try rig.quiet(0.04)
        #expect(rig.voice.floorHold == nil)
        try rig.quiet(1.8)
        let played = try #require(rig.itemPlayed("item_a1"))
        #expect(played.ms == 2000 && !played.cut, "\(played)")
        #expect(rig.sent("conversation.item.truncate").isEmpty)
        #expect(rig.sent("response.cancel").isEmpty)
        #expect(!rig.voiceEvents.contains(.bargeIn))
        // The brain still sees their (accepted) words; it doesn't answer a backchannel.
        #expect(rig.brainSession { $0 == .userTranscript(itemID: "item_u2", text: "Keep going, I'm listening.") }.count == 1)
        rig.voice.shutdown()
    }

    /// Live tune 2: "Don't stop, keep going." paused her 4.2 s — the server held
    /// its turn 2.3 s past the words. In a hold, once the server has stopped
    /// their speech and they have been quiet for `holdCommitSilence`, the item is
    /// committed at once. Never while they talk, never before `speech_stopped`
    /// (a commit mid-speech split "Keep going. / I'm listening." live).
    @Test func theirWordsAreAskedForAsSoonAsTheyStop() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 4000)])
        try rig.quiet(0.6)
        try rig.talk(0.15)
        rig.push(Srv.speechStarted("item_u2", ms: rig.uplinkMsNow - 150))
        await rig.settle()
        try rig.talk(0.5)
        #expect(rig.voice.floorHold?.itemID == "item_u2")
        try rig.quiet(0.6)
        await rig.settle()
        #expect(rig.sent("input_audio_buffer.commit").isEmpty, "committed before the server stopped their speech")
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 500))
        await rig.settle()
        try rig.quiet(0.1)
        await rig.settle()
        #expect(await rig.waitSent("input_audio_buffer.commit"))
        try rig.quiet(0.3)
        await rig.settle()
        #expect(rig.sent("input_audio_buffer.commit").count == 1)
        rig.voice.shutdown()
    }

    /// Live tune 2: what they said came back as two items ("Don't stop." then
    /// "Keep going.") and an empty one: all of it decides together, an empty
    /// transcript decides nothing, and she goes on.
    @Test func splitWordsDecideTogether() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 5000)])
        try rig.quiet(0.6)
        try rig.talk(0.15)
        rig.push(Srv.speechStarted("item_u2", ms: rig.uplinkMsNow - 150))
        await rig.settle()
        try rig.talk(0.3)
        #expect(rig.voice.floorHold?.itemID == "item_u2")
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 50), Srv.committed("item_u2"),
                 Srv.speechStarted("item_u3", ms: rig.uplinkMsNow))
        await rig.settle()
        try rig.talk(0.3)                                   // still talking: "Keep going."
        rig.push(Srv.userTranscript("item_u2", "Don't stop."))
        await rig.settle()
        try rig.talk(0.2)
        #expect(rig.voice.floorHold != nil, "resumed while they were still talking")
        rig.push(Srv.speechStopped("item_u3", ms: rig.uplinkMsNow), Srv.committed("item_u3"),
                 Srv.userTranscript("item_u3", "Keep going."),
                 Srv.speechStarted("item_u4", ms: rig.uplinkMsNow + 100))
        await rig.settle()
        try rig.quiet(0.1)
        rig.push(Srv.speechStopped("item_u4", ms: rig.uplinkMsNow), Srv.committed("item_u4"), Srv.userTranscript("item_u4", ""))
        await rig.settle()
        try rig.quiet(0.5)
        #expect(rig.voice.floorHold == nil)
        try rig.quiet(4.5)
        #expect(rig.itemPlayed("item_a1").map { $0.ms == 5000 && !$0.cut } == true, "\(String(describing: rig.itemPlayed("item_a1")))")
        #expect(rig.sent("conversation.item.truncate").isEmpty)
        rig.voice.shutdown()
    }

    /// The settled first words decide as soon as they are in (~0.15 s), before the
    /// full transcript: "Mm-hm." — she goes on.
    @Test func settledWordsResumeBeforeTheTranscript() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 2500)])
        try rig.quiet(0.5)
        try rig.talk(0.15)
        rig.push(Srv.speechStarted("item_u2", ms: rig.uplinkMsNow - 150))
        await rig.settle()
        try rig.talk(0.25)
        #expect(rig.voice.floorHold != nil)
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 100), Srv.committed("item_u2"),
                 .inputTranscriptionDelta(.init(itemID: "item_u2", delta: "Mm-hm.")))
        await rig.settle()
        try rig.quiet(0.1)
        #expect(rig.voice.floorHold != nil)                  // not settled yet
        try rig.quiet(0.1)
        #expect(rig.voice.floorHold == nil)                  // settled: she goes on
        let at = rig.output.count
        try rig.quiet(0.3)
        #expect(rig.audibleMs(fromSample: at) > 250)
        rig.push(Srv.userTranscript("item_u2", "Mm-hm."))
        await rig.settle()
        try rig.quiet(2.0)
        #expect(rig.itemPlayed("item_a1").map { $0.ms == 2500 && !$0.cut } == true)
        #expect(rig.sent("conversation.item.truncate").isEmpty)
        rig.voice.shutdown()
    }

    /// No words that say "go on" by `holdWordsWait` after their speech stopped:
    /// her reply ends where she paused, announced as the barge-in it was (timed
    /// when she paused).
    @Test func aHoldWithoutWordsEndsAsABargeIn() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 3000)])
        try rig.quiet(0.6)
        try rig.talk(0.15)
        rig.push(Srv.speechStarted("item_u2", ms: rig.uplinkMsNow - 150))
        await rig.settle()
        try rig.talk(0.3)
        let hold = try #require(rig.voice.floorHold)
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 100), Srv.committed("item_u2"))
        await rig.settle()
        try rig.quiet(CloudVoice.holdWordsWait - 0.3)
        #expect(rig.voice.floorHold != nil)
        try rig.quiet(0.5)
        #expect(rig.voice.floorHold == nil)
        #expect(await rig.waitSent("conversation.item.truncate"))
        #expect(await rig.events.wait { $0 == .bargeIn } != nil)
        let mark = rig.timeline.turns().flatMap(\.marks).first { $0.stage == .bargeIn }
        #expect(mark.map { abs($0.t - hold.since) < 0.01 } == true, "\(String(describing: mark)) vs \(hold.since)")
        rig.voice.shutdown()
    }

    /// The brain answers the words (a real turn): `respond` ends the paused reply
    /// first, exactly where she paused.
    @Test func respondingEndsAHold() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 3000)])
        try rig.quiet(0.6)
        try rig.talk(0.15)
        rig.push(Srv.speechStarted("item_u2", ms: rig.uplinkMsNow - 150))
        await rig.settle()
        try rig.talk(0.3)
        #expect(rig.voice.floorHold != nil)
        let paused = rig.voice.graph.player.playedMs(utterance: "item_a1")
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 100), Srv.committed("item_u2"))
        await rig.settle()
        _ = try? await rig.voice.respond()
        #expect(rig.voice.floorHold == nil)
        #expect(await rig.waitSent("conversation.item.truncate"))
        let t = try #require(rig.sent("conversation.item.truncate").first)
        #expect(abs((t["audio_end_ms"] as? Int ?? -1) - paused) <= 6, "\(t) vs \(paused)")
        // The brain is answering their words: no `.bargeIn` for the app (its stop
        // would cancel that new reply); the barge-in is on the timeline, at the pause.
        try rig.quiet(0.1)
        #expect(!rig.voiceEvents.contains(.bargeIn))
        #expect(rig.timeline.turns().flatMap(\.marks).contains { $0.stage == .bargeIn })
        #expect(rig.sent("response.create").count == 2)                 // the answer was not cancelled
        #expect(rig.sent("response.cancel").count <= 1)
        rig.voice.shutdown()
    }
}

// MARK: - (3) Her next item never starts over the user

@Suite(.serialized) struct BoundaryCollisionLoopTests {
    /// long-echo20 c05 (live collision): a two-item response; the user started
    /// talking near the end of her first item, the onset was still being decided
    /// when it ended, and the second item started playing over them (cut 30 ms
    /// later). Now the second item waits at the boundary while an onset with
    /// near-end voice is undecided; the user's "Mm-hm." then lets it play whole.
    @Test func theNextItemWaitsWhileTheUserMayBeTalking() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 600), ("item_a2", 1500)])
        try rig.quiet(0.46)
        // A word starts (too short to decide on yet), the server opens an item…
        try rig.talk(0.08)
        rig.push(Srv.speechStarted("item_u2", ms: rig.uplinkMsNow - 80))
        await rig.settle()
        // …and her first item runs out while it is still being decided.
        try rig.quiet(0.2)
        #expect(rig.voice.graph.player.playedMs(utterance: "item_a1") == 600)
        #expect(rig.voice.graph.player.playedMs(utterance: "item_a2") == 0, "her next item started over the user")
        try rig.talk(0.3)
        #expect(rig.voice.floorHold?.itemID == "item_u2")
        #expect(rig.voice.graph.player.playedMs(utterance: "item_a2") == 0, "her next item started over the user")
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 100), Srv.committed("item_u2"),
                 Srv.userTranscript("item_u2", "Mm-hm."))
        await rig.settle()
        try rig.quiet(2.2)
        #expect(rig.itemPlayed("item_a2").map { $0.ms == 1500 && !$0.cut } == true, "\(String(describing: rig.itemPlayed("item_a2")))")
        #expect(rig.sent("conversation.item.truncate").isEmpty)
        rig.voice.shutdown()
    }

    /// An echo-only onset (no near-end voice) at the boundary never delays her.
    @Test func herEchoOnsetNeverHoldsTheNextItem() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 600), ("item_a2", 1000)])
        try rig.quiet(0.5)
        rig.push(Srv.speechStarted("item_e", ms: rig.uplinkMsNow - 60))
        await rig.settle()
        try rig.quiet(0.5)
        #expect(rig.voice.graph.player.playedMs(utterance: "item_a2") > 200)
        rig.voice.shutdown()
    }
}

// MARK: - (2) An item her loud echo opened is judged by its words

@Suite struct HerWordsTests {
    @Test func herOwnWordsComingBackAreHerEcho() {
        var w = HerWords()
        w.add("Here's a little thought. The kettle sings, the window hums, and somewhere far a soft rain comes.", at: 10)
        for t in ["Here.", "The kettle sings.", "", "window", "soft rain comes", "Dee."] {
            #expect(w.isHerEcho(t, at: 12), "\(t)")
        }
        // long-echo10: the user inside items her echo opened.
        for t in ["Don't stop. Keep going.", "Keep going. I'm listening.", "I'm listening.", "Stop.",
                  "tell her about my new job. Do you think she'll be happy?"] {
            #expect(!w.isHerEcho(t, at: 12), "\(t)")
        }
        // Her words from long ago don't count.
        #expect(!w.isHerEcho("the kettle sings", at: 10 + HerWords.window + 1))
        // Strict (only her echo model's misses hinted at a voice): her echo comes
        // back garbled (tune 2 live: "Years old." for "Here's a little thought"):
        // two strange words are not enough, three are.
        #expect(w.isHerEcho("Years old.", at: 12, strict: true))
        #expect(!w.isHerEcho("Years old.", at: 12))
        #expect(!w.isHerEcho("Don't stop. Keep going.", at: 12, strict: true))
        #expect(!w.isHerEcho("Stop.", at: 12, strict: true))
    }
}

@Suite(.serialized) struct WordsDecideLoopTests {
    /// The item her echo opened holds the user's words: everything held back
    /// reaches the brain in order, the item is kept; "keep going" lets her go on.
    @Test func theUsersWordsKeepTheItem() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 3000)], text: "Okay, so the meeting ran long and nobody wanted it.")
        try rig.quiet(0.5)
        rig.push(Srv.speechStarted("item_x", ms: rig.uplinkMsNow - 200))
        await rig.settle()
        try rig.quiet(0.1)
        rig.voice.deferToWordsForTesting("item_x")
        #expect(rig.voice.itemsAwaitingWords == ["item_x"])
        rig.push(Srv.speechStopped("item_x", ms: rig.uplinkMsNow - 50), Srv.committed("item_x"))
        await rig.settle()
        try rig.quiet(0.1)
        #expect(rig.brainSession { if case .userCommitted("item_x", _) = $0 { true } else { false } }.isEmpty,
                "the brain saw the item before its words decided it")
        rig.push(Srv.userTranscript("item_x", "Don't stop. Keep going."))
        await rig.settle()
        try rig.quiet(0.1)
        #expect(rig.voice.itemsAwaitingWords.isEmpty)
        let order = rig.brainSession {
            switch $0 {
            case .userSpeechStarted("item_x", _), .userSpeechStopped("item_x", _), .userCommitted("item_x", _),
                 .userTranscript("item_x", _): true
            default: false
            }
        }
        #expect(order.count == 4, "\(order)")
        if order.count == 4 {
            if case .userSpeechStarted = order[0] {} else { Issue.record("\(order)") }
            if case .userTranscript = order[3] {} else { Issue.record("\(order)") }
        }
        #expect(rig.sent("conversation.item.delete").isEmpty)
        #expect(rig.sent("conversation.item.truncate").isEmpty)   // a backchannel: she goes on
        rig.voice.shutdown()
    }

    /// Its words are hers: deleted as her echo; the brain never sees any of it.
    @Test func herOwnWordsDeleteTheItem() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 3000)], text: "Okay, so the meeting ran long and nobody wanted it.")
        try rig.quiet(0.5)
        rig.push(Srv.speechStarted("item_x", ms: rig.uplinkMsNow - 200))
        await rig.settle()
        try rig.quiet(0.1)
        rig.voice.deferToWordsForTesting("item_x")
        rig.push(Srv.speechStopped("item_x", ms: rig.uplinkMsNow - 50), Srv.committed("item_x"),
                 Srv.userTranscript("item_x", "the meeting ran long"))
        #expect(await rig.waitSent("conversation.item.delete"))
        #expect(rig.brainSession {
            switch $0 {
            case .userSpeechStarted("item_x", _), .userSpeechStopped("item_x", _), .userCommitted("item_x", _),
                 .userTranscript("item_x", _): true
            default: false
            }
        }.isEmpty)
        rig.voice.shutdown()
    }

    /// The user's words in it were a real interruption: she stops (late, but she
    /// stops) and the barge-in is announced.
    @Test func aRealInterruptionInItCutsHer() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 4000)], text: "Okay, so the meeting ran long and nobody wanted it.")
        try rig.quiet(0.5)
        rig.push(Srv.speechStarted("item_x", ms: rig.uplinkMsNow - 200))
        await rig.settle()
        try rig.quiet(0.1)
        rig.voice.deferToWordsForTesting("item_x")
        rig.push(Srv.speechStopped("item_x", ms: rig.uplinkMsNow - 50), Srv.committed("item_x"),
                 Srv.userTranscript("item_x", "Wait, stop talking for a second."))
        await rig.settle()
        // Quiet at once (held); nobody answers them here, so the voice ends it.
        #expect(rig.voice.floorHold?.itemID == "item_x")
        let at = rig.output.count
        try rig.quiet(0.2)
        #expect(rig.audibleMs(fromSample: at) < 10)
        try rig.quiet(CloudVoice.holdAfterWords)
        #expect(await rig.waitSent("conversation.item.truncate"))
        #expect(await rig.events.wait { $0 == .bargeIn } != nil)
        rig.voice.shutdown()
    }
}

// MARK: - The TV is not "the user speaking"; the user's own voice is local speech

@Suite(.serialized) struct TVIsNotTheUserTests {
    /// 20 s of the TV bed (four `say` voices, 15 dB below a talker) with nobody
    /// there: never local speech for the session (a rollover would wait on it
    /// forever), and nothing cancelled for it.
    @Test func theTVNeverHoldsTheFloor() throws {
        var sim = RoomSim(seconds: 20)
        sim.setBed(try HarnessFixture.wav("noise/tv.wav"), snrDB: 15)
        sim.run()
        let late = sim.log.filter { $0.t > RoomSim.t0 + 3 }.map(\.action)
        #expect(!late.contains(.localSpeech(true)), "the TV counted as the user's voice")
        #expect(!late.contains(.cancelInitiative))
    }

    /// A question over the same TV: the user's voice is local speech (on at the
    /// onset, off after it), and they are speaking.
    @Test func aQuestionOverTheTVIsLocalSpeech() throws {
        var sim = RoomSim(seconds: 12)
        sim.setBed(try HarnessFixture.wav("noise/tv.wav"), snrDB: 15)
        let q = try sim.say("q01", at: 6.0)
        sim.run()
        let on = sim.log.first { $0.action == .localSpeech(true) && $0.t > RoomSim.t0 + 3 }?.t
        let off = sim.log.first { $0.action == .localSpeech(false) && $0.t > RoomSim.time(q.onset) }?.t
        let onAt = try #require(on, "the user's voice was never local speech")
        #expect(onAt - RoomSim.time(q.onset) <= 0.3, "local speech came \(onAt - RoomSim.time(q.onset)) s after the onset")
        let offAt = try #require(off)
        #expect(offAt >= RoomSim.time(q.end) && offAt - RoomSim.time(q.end) <= EarCore.userSpeechHold + 0.3)
    }
}

// MARK: - (1) The gate on the real uplink

@Suite(.serialized) struct UplinkGateLoopTests {
    /// CloudVoice on a manual graph with the TV bed at the mic (48 kHz): what the
    /// server receives between the user's words is the TV 30 dB down; their words
    /// arrive whole.
    @Test func theServerGetsTheUserNotTheTV() async throws {
        let rig = try LoopRig()
        let tv = try HarnessFixture.wav("noise/tv.wav")
        let g = Float(pow(10, (-24 - 15 - Level.rmsDB(tv)) / 20))
        var pos = 0
        func tvBlock(_ n: Int) -> [Float] {
            var out = [Float](repeating: 0, count: n)
            for i in 0..<n { out[i] = tv[(pos + i / 2) % tv.count] * g }   // 24 → 48 kHz
            pos += n / 2
            return out
        }
        try await rig.start()
        let n = Int(LoopRig.rate * 0.02)
        for _ in 0..<200 { try rig.step(tvBlock(n)) }                     // 4 s of TV
        let voice = Signal.harmonic(hz: 180, amplitude: 0.1, sampleRate: LoopRig.rate, seconds: 1.0)   // ≈ −27 dBFS
        let talkFrom = rig.uplink().count
        for f in Signal.frames(voice, size: n) {
            var m = tvBlock(n)
            for i in 0..<n { m[i] += f[i] }
            try rig.step(m)
        }
        let talkTo = rig.uplink().count
        for _ in 0..<100 { try rig.step(tvBlock(n)) }                     // 2 s of TV
        #expect(await rig.waitUplink(ms: Double(rig.uplink().count) / 24))
        let up = rig.uplink().map { Float($0) / 32_768 }
        let state = rig.voice.uplinkGateState
        #expect(state.barDB != nil, "the bed was never learned")
        // TV alone (after the bed is learned, away from the words + hangover).
        let tvAfter = Level.rmsDB(Array(up[(talkTo + 24 * 700)..<min(up.count, talkTo + 24 * 1800)]))
        let tvBefore = Level.rmsDB(Array(up[(24 * 2500)..<(talkFrom - 24 * 100)]))
        #expect(tvBefore <= -39 - 20 && tvAfter <= -39 - 20, "TV sent at \(tvBefore) / \(tvAfter) dBFS")
        // Their words: whole (the TV under them included).
        let words = Level.rmsDB(Array(up[(talkFrom + 24 * 50)..<(talkTo - 24 * 50)]))
        #expect(words >= Level.rmsDB(voice) - 1, "words sent at \(words) dBFS, spoken at \(Level.rmsDB(voice))")
        rig.voice.shutdown()
    }
}

// MARK: - Her first line never cuts herself (tune 2 live self-trigger)

@Suite(.serialized) struct FirstLineEchoTests {
    /// t2-backchannel-echo10 live (an intermediate tune-2 build): her very first
    /// line ("Here's a little thought…", echo −10 dB, no echo cancellation) opened
    /// a server item on its own echo; the per-band echo model, barely learned,
    /// missed her last syllable's reverb, and a pitch it couldn't place counted as
    /// another voice: she paused for herself, then answered "Years old.". Her
    /// short first line over every echo the harness uses: never a barge-in, never
    /// accepted; left to its words only strictly (her garbled echo is not enough).
    @Test(arguments: [(-10.0, false), (-20.0, false), (-20.0, true), (-30.0, true)])
    func herFirstShortLineNeverCutsHerself(gainDB: Double, aec: Bool) throws {
        var failures: [String] = []
        let full = ProcessInfo.processInfo.environment["DEE_SWEEP"] == "full"
        for id in full ? ["q01", "q02", "l02", "f01", "d02"] : ["q01", "l02"] {
            for at in full ? [0.1, 0.24, 0.5, 1.0] : [0.24, 1.0] {
                var sim = RoomSim(seconds: 7, aec: aec)
                sim.setEcho(gainDB: gainDB, delayMs: 80, ir: try HarnessFixture.wav("ir/room.wav"))
                let herStart = RoomSim.sample(1.0)
                RoomSim.place(try herReply(id, seconds: 5), into: &sim.her, at: herStart)
                let onset = herStart + RoomSim.sample(at)
                sim.server = [(onset + RoomSim.sample(0.4), .start("e", onsetSample: onset)),
                              (onset + RoomSim.sample(1.6), .stop("e", endSample: onset + RoomSim.sample(1.4)))]
                sim.run()
                let barged = sim.actions.contains { if case .bargeIn = $0 { true } else { false } }
                if barged || sim.actions.contains(.acceptOnset(itemID: "e"))
                    || sim.actions.contains(.deferToWords(itemID: "e", strict: false)) {
                    failures.append("\(id)@\(at)")
                }
            }
        }
        #expect(failures.isEmpty, "\(gainDB) dB aec \(aec): \(failures)")
    }

    /// t2-backchannel-echo20 live: 0.66 s into a later reply the server opened an
    /// item on her echo and she paused for it — her history held no pitch to
    /// compare the mic's with, and "no pitch of hers" counted as another voice.
    /// Only a pitch of hers that is near the mic's says "hers"; none to compare
    /// with says nothing. (Not reproduced with the fixture voices offline.)
    @Test func noPitchOfHersToCompareIsNotAnotherVoice() {
        #expect(!SpectralEcho.differentVoice(210, from: []))
        #expect(!SpectralEcho.differentVoice(210, from: nil))
        #expect(!SpectralEcho.differentVoice(210, from: [205]))
        #expect(!SpectralEcho.differentVoice(210, from: [104]))          // her octave below
        #expect(SpectralEcho.differentVoice(130, from: [205, 198]))
    }
}
