import Accelerate
import DeeRealtime
import Foundation
import Testing
@testable import DeeVoice

// Tune 11 (scratchpad/tune10-live.md; reports Tools/voice-harness/Reports/20261010-130349,
// -134832 solo; traces Tools/voice-harness/Traces/<same>):
// (T10-2b) backchannel-echo10 bc01 (main run, 76.0–78.6): with no echo cancellation Dee's own
//   echo opened an item 1.5 s into Dee's reply, the server heard it as "Sorry.", and — "sorry"
//   being a word a person says alone — it was the user's, stopped Dee (truncate at 2165 ms)
//   and was answered. Their "Go on." came 0.3 s later as "Sure.", too late.
// (T10-3) backchannel-echo10 c01 (solo, 165.5–168): "Stop." over Dee, the server heard
//   "Doc."; one word that isn't Dee's can never reach the two- or three-new-word bar, so the
//   item was deleted as Dee's echo and Dee talked on: a missed barge-in and a drop.
// One rule for both: a one-word item over Dee's un-cancelled voice that the ear left to its
// words is judged by Dee's echo model (`EarCore.echoExplains`), not by which word came back.

// MARK: - The rig: Dee's real echo in the microphone, through the room

/// LoopRig with no echo cancellation and Dee's rendered output fed back into the microphone
/// the way the harness's MicMixer does it (−10 dB, 80 ms, through the room IR), plus a
/// harness fixture said by the user.
final class EchoTenRoom: @unchecked Sendable {
    let rig: LoopRig
    private let gain: Float
    private let delay: Int
    private let irReversed: [Float]
    private var user: [Float] = []            // 48 kHz, on the mic's sample clock
    private var seed: UInt64 = 900

    init(gainDB: Double = -10, delayMs: Double = 80, duckOnOnset: Bool? = nil) throws {
        rig = try LoopRig(duckOnOnset: duckOnOnset)
        gain = Float(pow(10, gainDB / 20))
        delay = Int(delayMs / 1000 * LoopRig.rate)
        irReversed = Array(Self.upsample(try HarnessFixture.wav("ir/room.wav")).reversed())
    }

    /// 24 kHz → 48 kHz (linear).
    static func upsample(_ x: [Float]) -> [Float] {
        var y = [Float](repeating: 0, count: x.count * 2)
        for i in 0..<x.count {
            y[2 * i] = x[i]
            y[2 * i + 1] = i + 1 < x.count ? (x[i] + x[i + 1]) / 2 : x[i]
        }
        return y
    }

    /// Microphone samples so far (= samples rendered so far).
    var micSamples: Int { rig.output.count }
    /// The uplink's ms at mic sample `n`.
    func ms(atSample n: Int) -> Int { Int(Double(n) / LoopRig.rate * 1000) }

    /// Fixture `id` said so its speech onset is at mic sample `onset`; returns its onset
    /// and end on the mic's sample clock.
    @discardableResult
    func say(_ id: String, atSample onset: Int) throws -> (onset: Int, end: Int) {
        let u = try HarnessFixture.utterance(id)
        let x = Self.upsample(u.samples)
        let start = onset - 2 * u.onset
        if user.count < start + x.count { user += [Float](repeating: 0, count: start + x.count - user.count) }
        for i in 0..<x.count where start + i >= 0 { user[start + i] += x[i] }
        return (onset, start + 2 * u.end)
    }

    /// 20 ms: noise + Dee's echo through the room + the user.
    func step() throws {
        let n = Int(LoopRig.rate * 0.02)
        let out = rig.output
        let a = out.count
        seed += 1
        var mic = Signal.noise(amplitude: 0.001, count: n, seed: seed)
        // echo[k] = g · Σ h[j] · out[k − D − j]
        let L = irReversed.count
        let from = a - delay - (L - 1)
        var x = [Float](repeating: 0, count: n + L - 1)
        for i in 0..<x.count {
            let j = from + i
            if j >= 0 && j < out.count { x[i] = out[j] }
        }
        var y = [Float](repeating: 0, count: n)
        vDSP_conv(x, 1, irReversed, 1, &y, 1, vDSP_Length(n), vDSP_Length(L))
        for i in 0..<n {
            mic[i] += y[i] * gain
            if a + i < user.count { mic[i] += user[a + i] }
        }
        try rig.step(mic)
    }

    func run(_ seconds: Double) throws { for _ in 0..<Int((seconds / 0.02).rounded()) { try step() } }

    func run(untilSample s: Int) throws { while micSamples < s { try step() } }

    /// Dee's reply `item_a1`: a harness TTS voice (`her`) at −20 dBFS, as the server's audio.
    /// Returns the mic sample where it starts playing.
    func startReply(her: String, seconds: Double) async throws -> Int {
        _ = rig.graph.setManualFacts(aecActive: false, outputLatency: 0)
        try await rig.start()
        try run(0.3)
        rig.push(Srv.speechStarted("item_u1", ms: 100), Srv.speechStopped("item_u1", ms: 200), Srv.committed("item_u1"))
        _ = await rig.brain.wait { if case .session(.userCommitted) = $0 { true } else { false } }
        _ = try await rig.voice.respond()
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"))
        let voice = try herReply(her, levelDB: -20, seconds: seconds)
        var i = 0
        while i < voice.count {
            let chunk = voice[i..<min(i + 2_400, voice.count)]
            let pcm: [Int16] = chunk.map { Int16(max(-1, min(1, $0)) * 32767) }
            rig.push(Srv.audio("resp_1", "item_a1", pcm.withUnsafeBytes { Data($0) }))
            i += 2_400
        }
        rig.push(Srv.audioDone("resp_1", "item_a1"), Srv.responseDone("resp_1"))
        await rig.settle()
        let start = micSamples
        try step()
        await rig.settle()
        return start
    }

    /// The server's item over Dee: onset (mic sample) announced 0.3 s after it, its end
    /// 0.09 s after that with the commit, its words 0.26 s later, the transcript 0.2 s after.
    func serverItem(_ item: String, onset: Int, end: Int, words: [String], text: String) async throws {
        try run(untilSample: onset + Int(0.3 * LoopRig.rate))
        rig.push(Srv.speechStarted(item, ms: ms(atSample: onset)))
        await rig.settle()
        try run(untilSample: max(end + Int(0.09 * LoopRig.rate), micSamples))
        rig.push(Srv.speechStopped(item, ms: ms(atSample: end)), Srv.committed(item))
        await rig.settle()
        try run(0.26)
        rig.deltas(item, words)
        await rig.settle()
        try run(0.2)
        rig.push(Srv.userTranscript(item, text))
        await rig.settle()
        try run(0.4)
        await rig.settle()
    }

    var deleted: [String] { rig.sent("conversation.item.delete").compactMap { $0["item_id"] as? String } }
    var notes: [String] { rig.timeline.turns().flatMap(\.marks).compactMap(\.detail) }
}

// MARK: - T10-2b / T10-3: one word over Dee's un-cancelled voice, judged by Dee's echo model

@Suite(.serialized) struct OneWordOverHerEchoTests {
    /// Live T10-2b (backchannel-echo10 bc01, main run 20261010-130349, 76.0–78.6): Dee's reply
    /// started 75.10; Dee's echo alone opened item `…V11tMw` (speech_started 76.595, its end
    /// 76896 ms), words "Sorry." (77.10), "words of …: the user (settled)", hold, truncate at
    /// 2165 ms. Their "Go on." began at its end. Dee's echo model explains the item's sound:
    /// it is Dee's echo whatever its word — deleted, never a hold, Dee talks on.
    @Test(arguments: [("l03", 2.4), ("j01", 2.4), ("l05", 4.8)])
    func herEchoHeardAsSorryNeverStopsHer(her: String, at: Double) async throws {
        let room = try EchoTenRoom()
        let replyStart = try await room.startReply(her: her, seconds: 8)
        let onset = replyStart + Int(at * LoopRig.rate)
        let end = onset + Int(0.5 * LoopRig.rate)
        try room.say("bc01", atSample: end)                                   // "Go on." at its end
        try await room.serverItem("item_e", onset: onset, end: end, words: ["Sorry", "."], text: "Sorry.")
        #expect(room.deleted.contains("item_e"), "Dee's echo \"Sorry.\" was not deleted: \(room.notes.suffix(10))")
        #expect(room.rig.sent("conversation.item.truncate").isEmpty, "Dee was cut by Dee's own echo")
        room.rig.voice.shutdown()
    }

    /// Live T10-3 (backchannel-echo10 c01, solo 20261010-134832, 165.5–168): Dee's reply
    /// started 165.04; "Stop." 0.9 s into it (item `…9tKQw4`, speech_started 166.283, end
    /// 167104 ms), heard as "Doc." (167.45), "words of …: Dee's echo", deleted at 167.657 while
    /// Dee talked on. Their voice is in the item where Dee's echo can't be: it is the user's
    /// whatever its word — kept, and the brain is never told it is "go on".
    @Test(arguments: [("l03", 2.4), ("l05", 4.2)])
    func stopHeardAsDocIsNotDeletedAsHerEcho(her: String, at: Double) async throws {
        let room = try EchoTenRoom()
        let replyStart = try await room.startReply(her: her, seconds: 8)
        let u = try room.say("c01", atSample: replyStart + Int(at * LoopRig.rate))
        let onset = u.onset - Int(0.1 * LoopRig.rate), end = u.end + Int(0.1 * LoopRig.rate)
        try await room.serverItem("item_s", onset: onset, end: end, words: ["Doc", "."], text: "Doc.")
        #expect(!room.deleted.contains("item_s"), "\"Stop.\" heard as \"Doc.\" was deleted as Dee's echo: \(room.notes.suffix(10))")
        #expect(!room.rig.voice.isMisheardFragment(itemID: "item_s", text: "Doc."), "the brain would hear \"go on\"")
        #expect(!room.rig.voice.isHoldBackchannel(itemID: "item_s", text: "Doc."))
        room.rig.voice.shutdown()
    }

    /// When the sound can't tell (here the probe paused Dee and only 0.12 s of "Stop." stood
    /// out of Dee's echo), the words decide as before: "Stop." is the user's.
    @Test func whenTheSoundCantTellTheWordsDecide() async throws {
        let room = try EchoTenRoom()
        let replyStart = try await room.startReply(her: "j01", seconds: 8)
        let u = try room.say("c01", atSample: replyStart + Int(2.4 * LoopRig.rate))
        let onset = u.onset - Int(0.1 * LoopRig.rate), end = u.end + Int(0.1 * LoopRig.rate)
        try await room.serverItem("item_s", onset: onset, end: end, words: ["Stop", "."], text: "Stop.")
        #expect(!room.deleted.contains("item_s"), "\(room.notes.suffix(10))")
        #expect(!room.rig.voice.isMisheardFragment(itemID: "item_s", text: "Stop."))
        room.rig.voice.shutdown()
    }
}

// MARK: - The rule's measure, on the ear alone (RoomSim, the harness's mixing)

@Suite(.serialized) struct EchoExplainsTests {
    private func sim(her: String) throws -> RoomSim {
        var sim = RoomSim(seconds: 12, aec: false)
        sim.setEcho(gainDB: -10, delayMs: 80, ir: try HarnessFixture.wav("ir/room.wav"))
        try sim.say("q01", at: 0.3)
        RoomSim.place(try herReply(her, levelDB: -20, seconds: 8.5), into: &sim.her, at: RoomSim.sample(3.0))
        return sim
    }

    /// T10-2b's shape: Dee's echo alone opens a 0.5 s item, "Go on." begins at its end; the
    /// ear leaves it to its words (strict), and Dee's echo model explains its sound — or
    /// can't tell (l03: 0.12 s stood out; then the words decide), never "a voice".
    @Test(arguments: [("l03", 2.4, nil), ("j01", 2.4, true), ("l05", 4.8, true)] as [(String, Double, Bool?)])
    func herEchoIsExplained(her: String, at: Double, explained: Bool?) throws {
        var s = try sim(her: her)
        let on = 3.0 + at, end = on + 0.5
        let p = try s.say("bc01", at: end)
        s.server = [(RoomSim.sample(on + 0.4), .start("item_x", onsetSample: RoomSim.sample(on))),
                    (RoomSim.sample(end + 0.09), .stop("item_x", endSample: RoomSim.sample(end))),
                    (p.onset + RoomSim.sample(0.18), .start("item_y", onsetSample: p.onset - RoomSim.sample(0.1)))]
        s.run()
        #expect(s.actions.contains(.deferToWords(itemID: "item_x", strict: true)), "\(s.actions)")
        #expect(s.core.echoExplains(itemID: "item_x", at: RoomSim.t0 + 12) == explained)
    }

    /// T10-3's shape: "Stop." (c01) over Dee; the ear leaves it to its words, and Dee's
    /// echo model can't explain it.
    @Test(arguments: [("l03", 2.4), ("l05", 4.2), ("j01", 2.4)])
    func aStopUnderHerEchoIsAVoice(her: String, at: Double) throws {
        var s = try sim(her: her)
        let p = try s.say("c01", at: 3.0 + at)
        let on = p.onset - RoomSim.sample(0.1), end = p.end + RoomSim.sample(0.1)
        s.server = [(on + RoomSim.sample(0.44), .start("item_x", onsetSample: on)),
                    (end + RoomSim.sample(0.1), .stop("item_x", endSample: end))]
        s.run()
        #expect(s.actions.contains { if case .deferToWords("item_x", _) = $0 { true } else { false } }, "\(s.actions)")
        #expect(s.core.echoExplains(itemID: "item_x", at: RoomSim.t0 + 12) == false)
    }
}

// MARK: - Review risk 7: "Unh." / "Uhn." are not hums

@Suite struct UNoHumTests {
    @Test func uWithoutAnMIsNoHum() {
        for w in ["unh", "uhn", "un", "nu", "hun", "nun"] { #expect(!Backchannel.isHum(w), "\(w)") }
        for w in ["nhn", "hnn", "nn", "hn", "mmhn", "mhm", "nnhnn", "umm", "uhm", "mm"] { #expect(Backchannel.isHum(w), "\(w)") }
        #expect(!Backchannel.isBackchannel("Unh."))
        #expect(Backchannel.isBackchannel("NNHN."))
    }
}
