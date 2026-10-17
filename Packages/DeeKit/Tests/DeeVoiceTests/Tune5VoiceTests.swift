import AVFAudio
import DeeCore
import DeeRealtime
import Foundation
import Testing
@testable import DeeVoice

// Tune 5 (scratchpad/tune4-live.md; traces Tools/voice-harness/Traces/20261010-003257):
// (1) `EarCore.voiceActive` / `lastVoiceTime` — "their voice now", 0.15 s hangover,
// never on for a bed; (2) "Keep going" misheard and split by the server's VAD is
// still one backchannel; (3) F2: in kitchen / TV beds `userIsSpeaking` stayed on
// 0.8–2.8 s after they stopped and held ready replies (live 0.6–1.26 s).

/// The user alone in a room bed (no Dee, no server), EarCore frame by frame:
/// per frame, `userIsSpeaking` and `voiceActive`.
struct BedProbe {
    var sim: RoomSim
    var speaking: [Bool] = []
    var active: [Bool] = []
    var debugFrom: Double? = ProcessInfo.processInfo.environment["T5_FROM"].flatMap(Double.init)

    init(bed: String?, snrDB: Double = 15, seconds: Double) throws {
        sim = RoomSim(seconds: seconds)
        if let bed { sim.setBed(try HarnessFixture.wav("noise/\(bed).wav"), snrDB: snrDB) }
    }

    mutating func run() {
        var bedPos = 0
        let n = sim.user.count / RoomSim.frame
        for k in 0..<n {
            let a = k * RoomSim.frame, b = a + RoomSim.frame
            let t = RoomSim.time(b)
            var mic = Array(sim.user[a..<b])
            if !sim.bed.isEmpty {
                for i in 0..<RoomSim.frame { mic[i] += sim.bedGain * sim.bed[bedPos]; bedPos = (bedPos + 1) % sim.bed.count }
            }
            _ = sim.core.frame(mic, sampleRate: RoomSim.rate, at: t)
            _ = sim.core.tick(at: t)
            if let lo = debugFrom, t - RoomSim.t0 >= lo, t - RoomSim.t0 <= lo + 0.8, let d = sim.core.debugFrame {
                print(String(format: "FR %.2f db %.1f floor %.1f bar %@ f0 %@ low %.2f vl %d act %d", t - RoomSim.t0, d.db, d.floor,
                             sim.core.uplinkBarDB.map { String(format: "%.1f", $0) } ?? "-", d.f0.map { String(format: "%.0f", $0) } ?? "-",
                             d.low, d.voiceLike ? 1 : 0, sim.core.voiceActive(at: t) ? 1 : 0) + " " + sim.core.debugState.components(separatedBy: "minBar").last!)
            }
            speaking.append(sim.core.userIsSpeaking(at: t))
            active.append(sim.core.voiceActive(at: t))
        }
    }

    static func frame(_ sample: Int) -> Int { sample / RoomSim.frame }

    /// Seconds after `end` until the flag is false and stays false for `quiet` s (or to `limit`).
    func releaseAfter(_ end: Int, _ flags: [Bool], limit: Int) -> Double {
        let from = Self.frame(end)
        var i = from
        while i < min(limit, flags.count), flags[i] { i += 1 }
        return Double(i - from) * Double(RoomSim.frame) / RoomSim.rate
    }

    /// Seconds the flag was on in `[a, b)` samples.
    func onSeconds(_ a: Int, _ b: Int, _ flags: [Bool]) -> Double {
        let lo = max(0, Self.frame(a)), hi = min(flags.count, Self.frame(b))
        guard hi > lo else { return 0 }
        return Double(flags[lo..<hi].filter { $0 }.count) * Double(RoomSim.frame) / RoomSim.rate
    }
}


/// The fillers-kitchen15 / drops-tv15 lines (live F2: ready replies held 0.86–1.26 s
/// on k08, p20c, k04, p06c), 2.5 s apart.
private let f2Lines = ["f01", "f02", "f03", "f04", "f05", "t03", "k03", "t04", "k08", "p20c", "p06c", "k04"]

// MARK: - (3) F2: a bed never keeps "the user is speaking" on

@Suite(.serialized) struct BedSpeechReleaseTests {
    /// tune4-live F2. Before: kitchen15 `userIsSpeaking` let go 0.80–2.80 s after the
    /// end of speech (k08 2.48, p20c 2.80); tv15 f03 was on 0.88 s more after it.
    /// Now it lets go with its 0.6 s hold (+ a consonant), and `voiceActive` within 0.3 s.
    @Test(arguments: ["kitchen", "tv", "fan"])
    func speakingLetsGoAfterTheirLastWord(bed: String) throws {
        var p = try BedProbe(bed: bed, seconds: 80)
        var placed: [Placed] = []
        var at = 3.0
        for id in f2Lines {
            let u = try p.sim.say(id, at: at)
            placed.append(u)
            at = Double(u.end) / RoomSim.rate + 2.5
        }
        p.run()
        for (i, u) in placed.enumerated() {
            let next = i + 1 < placed.count ? placed[i + 1].onset : p.sim.user.count
            let lim = BedProbe.frame(next)
            let off = p.releaseAfter(u.end, p.speaking, limit: lim)
            #expect(off <= EarCore.userSpeechHold + EarCore.speechBridge + 0.05, "\(bed) \(u.id): userIsSpeaking held \(off) s")
            let activeOff = p.releaseAfter(u.end, p.active, limit: lim)
            #expect(activeOff <= 0.3, "\(bed) \(u.id): voiceActive held \(activeOff) s")
            let late = p.onSeconds(u.end + RoomSim.sample(EarCore.userSpeechHold + EarCore.speechBridge + 0.1), next, p.speaking)
            #expect(late == 0, "\(bed) \(u.id): the bed turned userIsSpeaking on for \(late) s after they stopped")
            let lateActive = p.onSeconds(u.end + RoomSim.sample(0.3), next, p.active)
            #expect(lateActive == 0, "\(bed) \(u.id): the bed turned voiceActive on for \(lateActive) s")
            // While they talk it is on from the first syllables, most of the time.
            let span = Double(u.end - u.onset) / RoomSim.rate
            #expect(p.onSeconds(u.onset, u.end, p.active) / span >= 0.4, "\(bed) \(u.id): voiceActive barely on")
            #expect(p.onSeconds(u.onset, u.end, p.speaking) / span >= 0.7, "\(bed) \(u.id): userIsSpeaking barely on")
        }
    }

    /// A bed alone (the TV's talkers included), from its first second: never their voice.
    @Test(arguments: ["kitchen", "tv", "fan"])
    func aBedAloneIsNeverTheirVoice(bed: String) throws {
        var p = try BedProbe(bed: bed, seconds: 40)
        p.run()
        #expect(!p.active.contains(true), "\(bed): voiceActive on \(p.active.filter { $0 }.count) frames")
        #expect(!p.speaking.contains(true), "\(bed): userIsSpeaking on \(p.speaking.filter { $0 }.count) frames")
        #expect(p.sim.core.lastVoiceTime == -.infinity)
    }
}

// MARK: - (1) voiceActive: quick on, quick off (F3: the release raced their next words)

@Suite(.serialized) struct VoiceActiveTests {
    /// t2-backchannel-fan15 l05 (live F3): "I couldn't sleep last night. [0.59 s] I kept
    /// going over…"; the gate released 0.15 s after they went on (`userIsSpeaking`
    /// was false: no server onset yet). `voiceActive` is off in that pause within
    /// 0.3 s and back on within 0.2 s of their next word — onset for onset of the
    /// clean line (frames ≥ −36 dBFS: 12 dB under its active level).
    @Test(arguments: ["fan", "kitchen", "tv"])
    func voiceActiveFollowsEveryPhrase(bed: String) throws {
        var p = try BedProbe(bed: bed, seconds: 16)
        let u = try p.sim.say("l05", at: 3.0)
        p.run()
        // The truth: the clean line's own frames.
        let frames = p.active.count
        var truth = [Bool](repeating: false, count: frames)
        for k in 0..<frames {
            let a = k * RoomSim.frame
            truth[k] = Level.rmsDB(Array(p.sim.user[a..<(a + RoomSim.frame)])) >= -36
        }
        // Phrases: truth runs separated by ≥ 0.4 s of quiet.
        var phrases: [(Int, Int)] = []
        var k = BedProbe.frame(u.onset - RoomSim.sample(0.2))
        while k < frames {
            guard truth[k] else { k += 1; continue }
            let start = k
            var end = k, quiet = 0
            while k < frames, quiet < 10 { if truth[k] { end = k; quiet = 0 } else { quiet += 1 }; k += 1 }
            phrases.append((start, end))
        }
        #expect(phrases.count >= 2, "l05 has its 0.59 s pause: \(phrases)")
        let dt = Double(RoomSim.frame) / RoomSim.rate
        if ProcessInfo.processInfo.environment["T5_DEBUG"] != nil {
            for ph in phrases {
                let row = (max(0, ph.0 - 3)...min(frames - 1, ph.0 + 10)).map { "\(truth[$0] ? "T" : ".")\(p.active[$0] ? "A" : "_")" }
                print("PH \(bed) \(Double(ph.0) * dt - 3)…\(Double(ph.1) * dt - 3) \(row.joined(separator: " "))")
            }
        }
        for (n, ph) in phrases.enumerated() {
            let on = (ph.0..<min(frames, ph.0 + 10)).first { p.active[$0] }
            // The line's first sound is an unvoiced breath (0.12 s, no pitch): not voice.
            let limit = n == 0 ? 0.3 : 0.2
            #expect(on.map { Double($0 - ph.0) * dt <= limit + 1e-9 } == true, "\(bed) phrase \(n): voiceActive on late \(String(describing: on.map { Double($0 - ph.0) * dt }))")
            guard n + 1 < phrases.count else { continue }
            let offAt = ((ph.1 + 1)..<phrases[n + 1].0).first { !p.active[$0] }
            #expect(offAt.map { Double($0 - ph.1) * dt <= 0.3 } == true, "\(bed) phrase \(n): voiceActive held through the pause")
        }
    }
}

// MARK: - (2) Continuers

@Suite struct Tune5ContinuerTests {
    /// tune4-live F6 (kitchen15 / echo20 c05 "Keep going, I'm listening." split by
    /// server_vad): "Sheep going." / "She's not going." / "I'm listening.".
    @Test func misheardKeepGoingsAndListening() {
        for t in ["Sheep going.", "She's going.", "Shes going", "Sheep going, I'm listening.", "I'm listening.",
                  "I'm listening", "Keep going, I'm listening.", "Keep going I'm listening.", "Go on, go on.",
                  "Keep going. I'm listening.", "Mm-hm, keep going."] {
            #expect(Backchannel.isBackchannel(t), "\(t)")
        }
        // A real sentence anywhere else: only a continuer in a hold, in a short burst.
        #expect(!Backchannel.isBackchannel("She's not going."))
        #expect(Backchannel.isBackchannel("She's not going.", inHold: true))
        #expect(Backchannel.isBackchannel("She's not going, I'm listening.", inHold: true))
        for t in ["She's not going to the party.", "She's going to call me.", "Stop.", "Wait, stop talking for a second.",
                  "Keep going, wait.", "I'm listening to music.", "Sheep going? What sheep?", "She's not going, stop."] {
            #expect(!Backchannel.isBackchannel(t, inHold: true), "\(t)")
        }
    }
}

// MARK: - (2) A split / misheard "Keep going" in a hold (the real CloudVoice)

@Suite(.serialized) struct SplitBackchannelTests {
    /// t2-backchannel-kitchen15 c05 (live): item 1 "Keep going" heard as "Sheep going."
    /// (speech_stopped + commit), item 2 "I'm listening." started 0.26 s later; the
    /// brain answered "Sheep going", which cut Dee (2.06 s), then answered "I'm
    /// listening." as a turn. Now: "Sheep going." is "go on"; the brain's go-on
    /// waits while item 2 is still being said; Dee goes on once its words say
    /// "go on" too, and both items are backchannels.
    @Test func sheepGoingThenImListeningIsOneBackchannel() async throws {
        let rig = try LoopRig()
        let holds = Collector(rig.voice.holdEvents)
        try await rig.start()
        try await rig.pausedBy("item_u2", talk: 0.7)
        try rig.quiet(0.08)
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 80), Srv.committed("item_u2"))
        try rig.talk(0.12)
        rig.push(Srv.speechStarted("item_u3", ms: rig.uplinkMsNow - 120))
        rig.deltas("item_u2", ["She", "ep", " going", "."])
        await rig.settle()
        try rig.talk(0.1)
        // The brain: "Sheep going." is a backchannel — go on.
        #expect(rig.voice.continueAfterBackchannel())
        let during = rig.output.count
        try rig.talk(0.55)
        await rig.settle()
        #expect(rig.voice.floorHold != nil, "Dee went on over \"I'm listening\"")
        #expect(rig.audibleMs(fromSample: during) == 0, "Dee talked over them")
        #expect(rig.voice.floorHold?.wordsAt == nil, "\"Sheep going.\" was taken as a turn")
        // One long burst (live: the server's own stop and commit, 0.16 s after the words).
        try rig.quiet(0.16)
        rig.push(Srv.speechStopped("item_u3", ms: rig.uplinkMsNow - 160), Srv.committed("item_u3"))
        try rig.quiet(0.12)
        rig.deltas("item_u3", ["I'm", " listening", "."])
        let resumed = try await rig.stepUntil(0.6) { rig.voice.floorHold == nil }
        #expect(resumed != nil, "never went on")
        #expect(rig.voice.wasBackchannel(itemID: "item_u2") && rig.voice.wasBackchannel(itemID: "item_u3"))
        #expect(holds.all.contains { if case .resumed(let items, _, _) = $0 { Set(items) == ["item_u2", "item_u3"] } else { false } },
                "\(holds.all)")
        try rig.quiet(7)
        await rig.settle()
        #expect(rig.itemPlayed("item_a1").map { !$0.cut } == true)
        #expect(rig.sent("conversation.item.truncate").isEmpty)
        #expect(!rig.voiceEvents.contains(.bargeIn))
        rig.voice.shutdown()
    }

    /// t2-backchannel-echo20 c05 (live): our quick commit of "Keep going", heard as
    /// "She's not going."; "I'm listening." started 0.33 s after. A short burst in
    /// a hold: a continuer — Dee waits for item 2 and goes on; the brain's check
    /// (`isHoldBackchannel`) agrees.
    @Test func shesNotGoingInAShortBurstIsAContinuer() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try await rig.pausedBy("item_u2", talk: 0.6)
        #expect(try await rig.stepUntil(0.6) { !rig.sent("input_audio_buffer.commit").isEmpty } != nil)
        rig.push(Srv.committed("item_u2"))
        try rig.talk(0.15)
        rig.deltas("item_u2", ["She's", " not", " going", "."])
        rig.push(Srv.speechStarted("item_u3", ms: rig.uplinkMsNow - 150))
        await rig.settle()
        try rig.talk(0.5)
        rig.push(Srv.userTranscript("item_u2", "She's not going."))
        await rig.settle()
        #expect(rig.voice.isHoldBackchannel(itemID: "item_u2", text: "She's not going."))
        #expect(rig.voice.floorHold?.wordsAt == nil, "\"She's not going.\" ended the hold")
        // Live: one long burst to the voice; the server's stop and commit 0.09 s after it.
        try rig.quiet(0.1)
        rig.push(Srv.speechStopped("item_u3", ms: rig.uplinkMsNow - 90), Srv.committed("item_u3"))
        try rig.quiet(0.12)
        rig.deltas("item_u3", ["I'm", " listening", "."])
        #expect(try await rig.stepUntil(0.6) { rig.voice.floorHold == nil } != nil, "never went on")
        #expect(rig.voice.wasBackchannel(itemID: "item_u2") && rig.voice.wasBackchannel(itemID: "item_u3"))
        #expect(rig.voice.isHoldBackchannel(itemID: "item_u2", text: "She's not going."))
        try rig.quiet(0.5)
        #expect(rig.sent("conversation.item.truncate").isEmpty)
        rig.voice.shutdown()
    }

    /// The same words said at length (a real answer over Dee): a turn.
    @Test func shesNotGoingSaidAtLengthIsATurn() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try await rig.pausedBy("item_u2", talk: 1.8)
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow), Srv.committed("item_u2"))
        try rig.quiet(0.12)
        rig.deltas("item_u2", ["She's", " not", " going", "."])
        rig.push(Srv.userTranscript("item_u2", "She's not going."))
        try rig.quiet(0.3)
        await rig.settle()
        #expect(rig.voice.floorHold?.wordsAt != nil, "a long \"She's not going.\" was swallowed")
        #expect(!rig.voice.isHoldBackchannel(itemID: "item_u2", text: "She's not going."))
        // Not in a hold at all: never.
        #expect(!rig.voice.isHoldBackchannel(itemID: "item_zz", text: "She's not going."))
        rig.voice.shutdown()
    }
}

// MARK: - (1) The CloudVoice surface the brain's release gate reads

@Suite(.serialized) struct VoiceActiveSurfaceTests {
    /// F3 (fan15 l05): 0.2 s after their last word `userVoiceActive` is already
    /// false (the gate may release) while `userIsSpeaking` still holds; their next
    /// word turns it on within 0.1 s, so a re-check at release sees it.
    @Test func voiceActiveLetsGoFastAndComesBackFast() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        #expect(!rig.voice.userVoiceActive && rig.voice.userQuietFor == .infinity)
        try rig.talk(0.6)
        #expect(rig.voice.userVoiceActive && rig.voice.userQuietFor <= 0.05)
        try rig.quiet(0.2)
        #expect(!rig.voice.userVoiceActive, "voiceActive held 0.2 s after their voice")
        #expect(rig.voice.userIsSpeaking, "userIsSpeaking keeps its 0.6 s hold")
        #expect(rig.voice.userQuietFor >= 0.15 && rig.voice.userQuietFor <= 0.25)
        let last = rig.voice.lastUserVoiceAt
        try rig.talk(0.1)
        #expect(rig.voice.userVoiceActive, "their next word was not seen within 0.1 s")
        #expect(rig.voice.lastUserVoiceAt > last)
        rig.voice.shutdown()
    }
}
