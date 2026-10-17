import Accelerate
import AVFAudio
import DeeCore
import DeeRealtime
import Foundation
import Synchronization
import Testing
@testable import DeeVoice

// Regression tests for the defects the live voice harness found
// (scratchpad/harness-foundation.md), reproduced offline from the harness's own
// fixtures (Tools/voice-harness/Fixtures: real TTS utterances, the fan / kitchen
// beds, the room IR) mixed the way its MicMixer mixes them: user + looped bed at
// an SNR against −24 dBFS speech + Dee's rendered output fed back delayed, through
// the room IR, at a gain.

// MARK: - Fixtures

enum HarnessFixture {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tools/voice-harness/Fixtures")

    struct Utterance {
        var samples: [Float]
        var onset: Int
        var end: Int
    }

    static func wav(_ relative: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: root.appendingPathComponent(relative))
        let format = file.processingFormat
        #expect(format.sampleRate == 24_000, "\(relative) is \(format.sampleRate) Hz")
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    static func utterance(_ id: String) throws -> Utterance {
        let data = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let list = try #require(manifest["utterances"] as? [[String: Any]])
        let u = try #require(list.first { $0["id"] as? String == id }, "no fixture \(id)")
        return Utterance(samples: try wav("utterances/\(id).wav"),
                         onset: try #require(u["onsetSample"] as? Int), end: try #require(u["endOfSpeechSample"] as? Int))
    }

    static func rmsDB(_ x: [Float]) -> Double { Level.rmsDB(x) }
}

// MARK: - The room, frame by frame, around a real EarCore

/// One scenario on EarCore at 24 kHz / 40 ms frames on the graph clock, the way
/// CloudVoice drives it: Dee's rendered output as echo reference before each mic
/// frame, Dee's playback level, server speech events at the times a server would
/// send them. A barge-in flushes Dee (Dee's output and its echo stop).
struct RoomSim {
    static let rate = 24_000.0
    static let frame = 960
    static let t0 = 100.0

    var core = EarCore()
    var her: [Float]                 // Dee's output on the absolute sample clock (0 = silent)
    var user: [Float]
    var bed: [Float] = []
    var bedGain: Float = 0
    var echoGain: Float = 0
    var echoDelay = 0
    var ir: [Float] = [1]
    var log: [(t: Double, action: EarCore.Action)] = []
    var cutAt: Int?                  // sample where Dee was flushed
    var server: [(sample: Int, event: ServerSpeech)] = []
    var initiativeEvery: Double?     // re-arm `initiativePending` this often (s)
    var speakingFrames = 0
    var frames = 0
    var tag = ""
    /// The uplink as CloudVoice sends it (`UplinkGate` with EarCore's bar), when on.
    var gateUplink = false
    var gate = UplinkGate()
    var mic: [Float] = []
    var sent: [Float] = []
    var bars: [Double?] = []
    /// Tune 7: on `.probe` CloudVoice pauses Dee (Dee's output and its echo go
    /// silent, the player stays busy) until `.probeEnded` / `.bargeIn`. Off: probes
    /// are ignored (Dee plays on).
    var honorProbes = false
    var probes: [Double] = []
    var probeEnds: [Double] = []
    var probing = false

    enum ServerSpeech {
        case start(String, onsetSample: Int)
        case stop(String, endSample: Int)
    }

    init(seconds: Double, aec: Bool = true) {
        let n = Int(seconds * Self.rate)
        her = [Float](repeating: 0, count: n)
        user = [Float](repeating: 0, count: n)
        core.aecActive = aec
        _ = core.setConnected(true, at: Self.t0)
    }

    static func time(_ sample: Int) -> Double { t0 + Double(sample) / rate }
    static func sample(_ seconds: Double) -> Int { Int(seconds * rate) }

    /// `x` scaled so its voiced part sits at `levelDB`, placed so it begins at `at`.
    static func place(_ x: [Float], into y: inout [Float], at start: Int, gain: Float = 1) {
        for i in 0..<x.count where start + i < y.count && start + i >= 0 { y[start + i] += x[i] * gain }
    }

    mutating func setBed(_ samples: [Float], snrDB: Double) {
        bed = samples
        bedGain = Float(pow(10, (-24 - snrDB - Level.rmsDB(samples)) / 20))
    }

    mutating func setEcho(gainDB: Double, delayMs: Double, ir: [Float]?) {
        echoGain = Float(pow(10, gainDB / 20))
        echoDelay = Int(delayMs / 1000 * Self.rate)
        self.ir = ir ?? [1]
    }

    var actions: [EarCore.Action] { log.map(\.action) }

    func firstTime(_ match: (EarCore.Action) -> Bool) -> Double? { log.first { match($0.action) }?.t }

    /// Runs the whole scenario.
    mutating func run() {
        let n = her.count
        var playing = false
        var silentBlocks = 0
        var nextServer = 0
        server.sort { $0.sample < $1.sample }
        var nextInitiative = initiativeEvery.map { Self.t0 + $0 }
        var bedPos = 0
        for k in 0..<(n / Self.frame) {
            let a = k * Self.frame, b = a + Self.frame
            let t = Self.time(b)
            // Dee's output this block (silent after a flush).
            if probing { for i in a..<b { her[i] = 0 } }    // paused (the rest is dropped here)
            var out = Array(her[a..<b])
            if let c = cutAt { for i in 0..<out.count where a + i >= c { out[i] = 0 } }
            if let c = cutAt, c < b { for i in max(a, c)..<b { her[i] = 0 } }
            // Playback state, as the player reports it.
            let hasAudio = out.contains { $0 != 0 }
            if hasAudio, !playing, cutAt == nil {
                playing = true
                record(core.playbackStarted(at: Self.time(a), aside: false), at: Self.time(a))
            }
            // The reference (render precedes capture).
            var bins: [EchoReference.Bin] = []
            for j in 0..<4 {
                let s = Array(out[(j * 240)..<((j + 1) * 240)])
                bins.append(.init(t: Self.time(a + (j + 1) * 240), energy: s.reduce(0) { $0 + Double($1 * $1) } / 240, samples: s))
            }
            core.reference(bins)
            if playing { core.playbackLevel(Level.meter(Level.rmsDB(out), floor: -50, ceiling: -12), at: t) }
            // The microphone.
            var mic = Array(user[a..<b])
            if !bed.isEmpty {
                for i in 0..<Self.frame { mic[i] += bedGain * bed[bedPos]; bedPos = (bedPos + 1) % bed.count }
            }
            if echoGain > 0 {
                let e = echoBlock(start: a)
                for i in 0..<Self.frame { mic[i] += e[i] }
            }
            record(core.frame(mic, sampleRate: Self.rate, at: t), at: t)
            if gateUplink {
                gate.barDB = core.uplinkBarDB
                bars.append(gate.barDB)
                var pcm = mic.map { Int16(max(-32_768, min(32_767, ($0 * 32_768).rounded()))) }
                gate.process(&pcm, startFrame: Int64(a))
                self.mic += mic
                sent += pcm.map { Float($0) / 32_768 }
            }
            if let d = core.debugFrame, ProcessInfo.processInfo.environment["EAR_DEBUG"] == tag {
                print(String(format: "EAR %.2f db %.1f floor %.1f bar %.1f f0 %@ low %.2f vl %d ab %d g %@ spk %d",
                             t - Self.t0, d.db, d.floor, d.bar, d.f0.map { String(format: "%.0f", $0) } ?? "-", d.low,
                             d.voiceLike ? 1 : 0, d.above ? 1 : 0, core.echo.gainDB.map { String(format: "%.1f", $0) } ?? "-",
                             core.userIsSpeaking(at: t) ? 1 : 0) + " " + core.debugState)
            }
            // Server speech events due by now.
            while nextServer < server.count, server[nextServer].sample <= b {
                switch server[nextServer].event {
                case .start(let id, let onset):
                    record(core.serverSpeechStarted(itemID: id, onset: Self.time(onset), at: t), at: t)
                case .stop(let id, let end):
                    record(core.serverSpeechStopped(itemID: id, end: Self.time(end), at: t), at: t)
                }
                nextServer += 1
            }
            record(core.tick(at: t), at: t)
            if let due = nextInitiative, t >= due {
                core.initiativePending = true
                nextInitiative = due + (initiativeEvery ?? 1)
            }
            frames += 1
            if core.userIsSpeaking(at: t) { speakingFrames += 1 }
            // Dee stops: flushed by a barge-in, or Dee's audio ran out (the player
            // goes idle once an utterance has played; 200 ms of nothing ends it).
            silentBlocks = hasAudio || probing ? 0 : silentBlocks + 1
            if playing, let c = cutAt, c <= b {
                playing = false
                record(core.playbackFinished(at: t), at: t)
            } else if playing, silentBlocks >= 5 {
                playing = false
                record(core.playbackFinished(at: t), at: t)
            }
        }
    }

    private mutating func record(_ actions: [EarCore.Action], at t: Double) {
        for a in actions {
            log.append((t, a))
            if case .bargeIn = a, cutAt == nil {
                cutAt = Int(((t - Self.t0) * Self.rate).rounded())
            }
            if case .bargeIn = a { probing = false }
            if case .probe = a, honorProbes, cutAt == nil {
                probes.append(t)
                probing = true
            }
            if case .probeEnded = a, probing {
                probeEnds.append(t)
                probing = false
            }
        }
    }

    /// echo[n] = g · Σ h[k] · Dee[n − D − k] for the block starting at `start`.
    private func echoBlock(start: Int) -> [Float] {
        let L = ir.count
        let from = start - echoDelay - (L - 1)
        let count = Self.frame
        var x = [Float](repeating: 0, count: count + L - 1)
        for i in 0..<x.count {
            let idx = from + i
            if idx >= 0 && idx < her.count { x[i] = her[idx] }
        }
        var y = [Float](repeating: 0, count: count)
        let reversed = Array(ir.reversed())
        vDSP_conv(x, 1, reversed, 1, &y, 1, vDSP_Length(count), vDSP_Length(L))
        var g = echoGain
        vDSP_vsmul(y, 1, &g, &y, 1, vDSP_Length(count))
        return y
    }
}

/// Dee's voice for the scenarios: a long TTS turn from the fixtures at `levelDB`
/// (gpt-realtime replies sit around −20 dBFS).
private func herVoice(_ id: String = "l02", levelDB: Double = -20, seconds: Double? = nil) throws -> [Float] {
    let u = try HarnessFixture.utterance(id)
    var x = Array(u.samples[u.onset..<u.end])
    if let seconds { x = Array(x.prefix(Int(seconds * RoomSim.rate))) }
    let g = Float(pow(10, (levelDB + 24) / 20))                       // fixtures are normalized to −24 dBFS active
    return x.map { $0 * g }
}

private func isBargeIn(_ a: EarCore.Action) -> Bool { if case .bargeIn = a { true } else { false } }
private func isReject(_ a: EarCore.Action) -> Bool { if case .rejectEcho = a { true } else { false } }

// MARK: - (1) A real interruption over a steady fan

@Suite(.serialized) struct FanBargeInTests {
    /// Fan at 15 dB SNR, no echo: "Wait, stop talking for a second" over Dee's reply
    /// barges in quickly and is never deleted as echo (harness: 4/4 deleted before).
    @Test(arguments: [900, 1200, 1500, 2000])
    func waitStopTalkingOverAFanBargesIn(atMs: Int) throws {
        var sim = RoomSim(seconds: 9)
        sim.tag = "fan\(atMs)"
        sim.setBed(try HarnessFixture.wav("noise/fan.wav"), snrDB: 15)
        let herStart = RoomSim.sample(1.0)
        RoomSim.place(try herVoice(), into: &sim.her, at: herStart)
        let c03 = try HarnessFixture.utterance("c03")
        let onset = herStart + atMs * 24
        let start = onset - c03.onset
        RoomSim.place(c03.samples, into: &sim.user, at: start)
        let end = start + c03.end
        // The server's VAD: onset reported ~250 ms late, end ~500 ms after it.
        sim.server = [(onset + 6_000, .start("item_u", onsetSample: onset)),
                      (end + 12_000, .stop("item_u", endSample: end))]
        sim.run()

        let barge = try #require(sim.firstTime(isBargeIn), "no barge-in over the fan (\(sim.actions.filter { !isEmit($0) }))")
        let latency = barge - RoomSim.time(onset)
        #expect(latency <= 0.5, "barge-in took \(latency) s after the onset at \(RoomSim.time(onset) - RoomSim.t0): \(sim.log.filter { !isEmit($0.action) }.map { "\($0.t - RoomSim.t0) \($0.action)" })")
        #expect(!sim.actions.contains(.rejectEcho(itemID: "item_u")), "the user's words were deleted as echo")
        #expect(sim.actions.contains(.bargeIn(itemID: "item_u")))
    }

    /// A short "Stop." that is over before the sustained-evidence bar is reached
    /// is still kept (accepted), never deleted as echo: near-end voice exists.
    @Test func shortNearEndVoiceIsNeverDeletedAsEcho() throws {
        var sim = RoomSim(seconds: 6)
        sim.setBed(try HarnessFixture.wav("noise/fan.wav"), snrDB: 15)
        let herStart = RoomSim.sample(1.0)
        RoomSim.place(try herVoice(), into: &sim.her, at: herStart)
        let c01 = try HarnessFixture.utterance("c01")                 // "Stop." (loud, ~0.6 s)
        let onset = herStart + 1_300 * 24
        let start = onset - c01.onset
        RoomSim.place(c01.samples.map { $0 * 0.45 }, into: &sim.user, at: start)   // ≈ −24 dBFS
        let end = start + c01.end
        sim.server = [(onset + 6_000, .start("item_u", onsetSample: onset)),
                      (end + 12_000, .stop("item_u", endSample: end))]
        sim.run()
        #expect(!sim.actions.contains(.rejectEcho(itemID: "item_u")))
        #expect(sim.actions.contains(.bargeIn(itemID: "item_u")) || sim.actions.contains(.acceptOnset(itemID: "item_u")))
    }

    /// The decision itself: an onset whose window holds pitched near-end voice
    /// (too short for the sustained bar) is accepted at `speech_stopped`.
    @Test func finalDecisionKeepsAnOnsetWithNearEndVoice() {
        var h = EarHarness()
        h.startPlayback()
        h.echo(0.6)
        h.clear()
        h.serverStart("item_u", onset: h.t)
        h.voice(0.22)                                     // under the 0.28 s sustain
        h.echo(0.3)
        h.serverStop("item_u")
        #expect(!h.decisions.contains(.rejectEcho(itemID: "item_u")))
        #expect(h.decisions.contains(.bargeIn(itemID: "item_u")))
    }

    /// The same window without near-end voice is still rejected as echo.
    @Test func finalDecisionStillRejectsPureEcho() {
        var h = EarHarness()
        h.startPlayback()
        h.echo(0.6)
        h.serverStart("item_e", onset: h.t)
        h.echo(0.5)
        h.clear()
        h.serverStop("item_e")
        #expect(h.decisions == [.rejectEcho(itemID: "item_e")])
    }
}

private func isEmit(_ a: EarCore.Action) -> Bool {
    switch a {
    case .emit, .uplink, .localSpeech: true
    default: false
    }
}

// MARK: - (2) Dee's own echo never barges in; the user over Dee's echo still does

@Suite(.serialized) struct EchoGatingTests {
    /// Residual echo at −20 dB / 80 ms through the room IR over the kitchen bed
    /// (the harness's smoke-echo): an onset the server opens on Dee's echo is
    /// rejected, Dee is never cut, nothing of it is accepted.
    @Test(arguments: [(-20.0, 80.0, "kitchen"), (-10.0, 40.0, "kitchen"), (-20.0, 120.0, "fan"), (-30.0, 200.0, "fan")])
    func herEchoNeverBargesIn(gainDB: Double, delayMs: Double, bed: String) throws {
        var sim = RoomSim(seconds: 9)
        sim.tag = "echo\(Int(gainDB))\(bed)"
        sim.setBed(try HarnessFixture.wav("noise/\(bed).wav"), snrDB: 15)
        sim.setEcho(gainDB: gainDB, delayMs: delayMs, ir: try HarnessFixture.wav("ir/room.wav"))
        let herStart = RoomSim.sample(0.8)
        let voice = try herVoice(seconds: 7)
        RoomSim.place(voice, into: &sim.her, at: herStart)
        // The server's VAD hears Dee's echo several times.
        for (k, at) in [0.3, 2.0, 4.1].enumerated() {
            let onset = herStart + RoomSim.sample(at)
            sim.server.append((onset + 7_000, .start("item_e\(k)", onsetSample: onset)))
            sim.server.append((onset + RoomSim.sample(1.2), .stop("item_e\(k)", endSample: onset + RoomSim.sample(0.9))))
        }
        // And once right after Dee stops (Dee's echo tail).
        let after = herStart + voice.count + RoomSim.sample(0.05)
        sim.server.append((after + 7_000, .start("item_tail", onsetSample: after)))
        sim.server.append((after + RoomSim.sample(0.7), .stop("item_tail", endSample: after + RoomSim.sample(0.4))))
        sim.run()

        #expect(!sim.actions.contains(where: isBargeIn), "Dee cut in on Dee's own echo")
        for id in ["item_e0", "item_e1", "item_e2", "item_tail"] {
            #expect(sim.actions.contains(.rejectEcho(itemID: id)), "\(id) was not rejected")
            #expect(!sim.actions.contains(.acceptOnset(itemID: id)), "\(id) was taken for the user")
        }
        #expect(sim.core.echo.gain != nil, "the echo path was never learned")
    }

    /// The user talking over Dee's echo still barges in (harness: "Hold on, hold
    /// on" 900 ms into Dee's reply, kitchen + −20 dB echo).
    @Test(arguments: [("c06", "kitchen", -20.0, 80.0), ("c03", "kitchen", -20.0, 80.0), ("c03", "fan", -20.0, 120.0)])
    func userOverHerEchoStillBargesIn(fixture: String, bed: String, gainDB: Double, delayMs: Double) throws {
        var sim = RoomSim(seconds: 8)
        sim.setBed(try HarnessFixture.wav("noise/\(bed).wav"), snrDB: 15)
        sim.setEcho(gainDB: gainDB, delayMs: delayMs, ir: try HarnessFixture.wav("ir/room.wav"))
        // An earlier reply taught Dee the echo path (as in a real conversation).
        let first = try herVoice("l01", seconds: 2.0)
        RoomSim.place(first, into: &sim.her, at: RoomSim.sample(0.3))
        let herStart = RoomSim.sample(3.5)
        RoomSim.place(try herVoice(), into: &sim.her, at: herStart)
        let u = try HarnessFixture.utterance(fixture)
        let onset = herStart + 900 * 24
        let start = onset - u.onset
        RoomSim.place(u.samples, into: &sim.user, at: start)
        sim.server = [(onset + 6_000, .start("item_u", onsetSample: onset)),
                      (start + u.end + 12_000, .stop("item_u", endSample: start + u.end))]
        sim.run()
        let barge = try #require(sim.firstTime(isBargeIn), "the user over Dee's echo didn't barge in")
        #expect(barge - RoomSim.time(onset) <= 0.5, "\(barge - RoomSim.time(onset)) s")
        #expect(sim.actions.contains(.bargeIn(itemID: "item_u")))
        #expect(!sim.actions.contains(.rejectEcho(itemID: "item_u")))
    }

    /// Live harness, smoke-echo: the server opened "user" speech on the kitchen
    /// bed just before Dee's reply started ("Okay." — nobody spoke) and Dee cut
    /// in on Dee's own reply 340 ms in. Room noise before Dee's playback is never near-end voice:
    /// the onset is deleted and Dee plays on.
    @Test(arguments: [2.0, 6.0, 10.0])
    func roomNoiseOnsetJustBeforeHerReplyIsNotTheUser(herAt: Double) throws {
        var sim = RoomSim(seconds: herAt + 5)
        sim.tag = "noise\(Int(herAt))"
        sim.setBed(try HarnessFixture.wav("noise/kitchen.wav"), snrDB: 15)
        sim.setEcho(gainDB: -20, delayMs: 80, ir: try HarnessFixture.wav("ir/room.wav"))
        RoomSim.place(try herVoice("l01", seconds: 1.5), into: &sim.her, at: RoomSim.sample(0.3))   // an earlier reply
        let herStart = RoomSim.sample(herAt)
        RoomSim.place(try herVoice(seconds: 4), into: &sim.her, at: herStart)
        let onset = herStart - RoomSim.sample(0.3)
        sim.server = [(herStart + RoomSim.sample(0.34), .start("item_n", onsetSample: onset)),
                      (herStart + RoomSim.sample(2.5), .stop("item_n", endSample: herStart + RoomSim.sample(2.0)))]
        sim.run()
        #expect(!sim.actions.contains(where: isBargeIn), "Dee cut in on Dee's reply for room noise")
        #expect(sim.actions.contains(.rejectEcho(itemID: "item_n")))
    }

    /// Dee's echo alone never builds the local-only barge-in either (no server onset at all).
    @Test func herLoudEchoNeverBargesInLocally() throws {
        var sim = RoomSim(seconds: 9)
        sim.setBed(try HarnessFixture.wav("noise/kitchen.wav"), snrDB: 20)
        sim.setEcho(gainDB: -10, delayMs: 40, ir: try HarnessFixture.wav("ir/room.wav"))
        RoomSim.place(try herVoice(seconds: 8), into: &sim.her, at: RoomSim.sample(0.5))
        sim.run()
        #expect(!sim.actions.contains(where: isBargeIn))
    }
}

// MARK: - EchoReference on its own

@Suite struct EchoReferenceTests {
    /// Dee's envelope: syllable-like bursts.
    static func envelope(seconds: Double, seed: UInt64 = 3) -> [Double] {
        var state = seed
        var out: [Double] = []
        var on = true, left = 0
        for _ in 0..<Int(seconds * 100) {
            if left == 0 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                on.toggle()
                left = 5 + Int(state >> 60)
            }
            left -= 1
            out.append(on ? 0.01 : 1e-7)                    // −20 dBFS speech, silence
        }
        return out
    }

    @Test func learnsTheDelayAndGainOfAnEcho() {
        var e = EchoReference()
        let ref = Self.envelope(seconds: 3)
        let floor = 1e-6
        for i in 0..<ref.count {
            let t = Double(i + 1) * EchoReference.bin
            e.addReference(energy: ref[i], at: t)
            let lagged = i >= 8 ? ref[i - 8] : 0                // 80 ms
            e.addMic(energy: floor + lagged * 0.01, floor: floor, at: t)   // −20 dB echo
        }
        #expect(e.delay != nil)
        #expect(abs((e.delay ?? 0) - 0.08) < 0.011, "delay \(String(describing: e.delay))")
        #expect(abs((e.gainDB ?? 0) - -20) < 3, "gain \(String(describing: e.gainDB))")   // a clean echo: any percentile
        #expect(e.confident)
        // Prediction: Dee's echo where Dee spoke.
        let t = Double(ref.count) * EchoReference.bin
        #expect((e.predicted(at: t + 0.08) ?? 0) <= 0.01 * 0.01 * 1.01)
    }

    @Test func noEchoLearnsThatNothingComesBack() {
        var e = EchoReference()
        let ref = Self.envelope(seconds: 2)
        let floor = 1e-5
        for i in 0..<ref.count {
            let t = Double(i + 1) * EchoReference.bin
            e.addReference(energy: ref[i], at: t)
            e.addMic(energy: floor * (i % 3 == 0 ? 1.3 : 0.9), floor: floor, at: t)
        }
        #expect(e.gainDB != nil)
        #expect((e.gainDB ?? 0) < -30, "\(String(describing: e.gainDB))")
    }

    @Test func doubleTalkNeverShrinksAKnownEcho() {
        var e = EchoReference()
        let ref = Self.envelope(seconds: 3)
        let floor = 1e-6
        for i in 0..<ref.count {
            let t = Double(i + 1) * EchoReference.bin
            e.addReference(energy: ref[i], at: t)
            e.addMic(energy: floor + (i >= 8 ? ref[i - 8] : 0) * 0.01, floor: floor, at: t)
        }
        let learned = e.gainDB ?? 0
        // The user talks over Dee for 1.5 s: loud, uncorrelated.
        let more = Self.envelope(seconds: 1.5, seed: 9)
        for j in 0..<more.count {
            let i = ref.count + j
            let t = Double(i + 1) * EchoReference.bin
            e.addReference(energy: ref[j % ref.count], at: t)
            e.addMic(energy: floor + ref[(j + ref.count - 8) % ref.count] * 0.01 + more[j] * 0.5, floor: floor, at: t)
        }
        #expect((e.gainDB ?? -100) >= learned - 1, "\(learned) → \(String(describing: e.gainDB))")
    }

    @Test func unknownWithoutReference() {
        var e = EchoReference()
        for i in 0..<300 { e.addMic(energy: 1e-4, floor: 1e-6, at: Double(i) * 0.01) }
        #expect(e.gain == nil)
        #expect((e.predicted(at: 3) ?? 0) == 0)          // nothing of Dee's to explain anything
        #expect(!e.hasReference(at: 3))
    }
}

// MARK: - (3) Noise is not "the user is speaking"

@Suite(.serialized) struct NoiseIsNotSpeechTests {
    /// 20 s of the kitchen bed (tap, hum, clinks) at 15 dB SNR with nobody there:
    /// never "user speaking", and initiatives offered every second are never cancelled.
    @Test(arguments: ["kitchen", "fan"])
    func roomNoiseNeverBlocksInitiatives(bed: String) throws {
        var sim = RoomSim(seconds: 20)
        sim.setBed(try HarnessFixture.wav("noise/\(bed).wav"), snrDB: 15)
        sim.initiativeEvery = 1.0
        sim.run()
        #expect(sim.speakingFrames == 0, "\(bed): user speaking in \(sim.speakingFrames)/\(sim.frames) frames")
        #expect(!sim.actions.contains(.cancelInitiative))
    }

    /// The same room with someone talking: they are speaking, and they beat an initiative.
    @Test func aVoiceInTheKitchenIsSpeech() throws {
        var sim = RoomSim(seconds: 5)
        sim.tag = "kitchenq"
        sim.setBed(try HarnessFixture.wav("noise/kitchen.wav"), snrDB: 15)
        let q = try HarnessFixture.utterance("q01")
        RoomSim.place(q.samples, into: &sim.user, at: RoomSim.sample(2.0))
        sim.initiativeEvery = 0.5
        sim.run()
        #expect(sim.speakingFrames > 20, "\(sim.speakingFrames)")
        let cancel = try #require(sim.firstTime { $0 == .cancelInitiative })
        #expect(cancel - RoomSim.time(RoomSim.sample(2.0) + q.onset) < 0.4)
    }

    /// Broadband bursts (claps, clinks) above the floor are sound, not speech.
    @Test func unpitchedBurstsAreNotSpeech() {
        var h = EarHarness()
        for k in 0..<6 {
            h.signal(Signal.noise(amplitude: 0.2, count: 3_200, seed: UInt64(10 + k)))
            h.quiet(0.3)
        }
        #expect(!h.core.userIsSpeaking(at: h.t))
        h.voice(0.3)
        #expect(h.core.userIsSpeaking(at: h.t))
    }

    @Test func lowBandShareSeparatesVoiceFromHiss() {
        let voice = Signal.harmonic(hz: 180, amplitude: 0.3, sampleRate: 24_000, seconds: 0.04)
        let hiss = Signal.noise(amplitude: 0.3, count: 960)
        let clink = Signal.sine(hz: 3_200, amplitude: 0.3, sampleRate: 24_000, seconds: 0.04)
        #expect(EarCore.lowBandShare(voice, sampleRate: 24_000) > 0.6)
        #expect(EarCore.lowBandShare(hiss, sampleRate: 24_000) < EarCore.voiceBandShare)
        #expect(EarCore.lowBandShare(clink, sampleRate: 24_000) < EarCore.voiceBandShare)
    }

    @Test func theFloorDoesNotClimbOnHerEcho() {
        var vad = EnergyVAD()
        for _ in 0..<25 { _ = vad.process(frameDB: -60, frameDuration: 0.04) }
        let before = vad.noiseFloorDB
        for _ in 0..<100 { _ = vad.process(frameDB: -45, frameDuration: 0.04, allowRise: false) }
        #expect(abs(vad.noiseFloorDB - before) < 0.01)
        for _ in 0..<5 { _ = vad.process(frameDB: -70, frameDuration: 0.04, allowRise: false) }
        #expect(vad.noiseFloorDB < before)                  // it may still fall
    }
}

// MARK: - (4) Render-clock times in offline manual rendering, (5) test facts

@Suite(.serialized) struct ManualGraphClockTests {
    @Test func startedAndFlushedAreOnTheGraphClock() throws {
        let graph = try AudioGraph.manual(sampleRate: 24_000, channels: 1, outputLatency: 0.05)
        let timeline = TurnTimeline()
        graph.player.timeline = timeline
        let started = Mutex<[Double]>([])
        graph.player.addObserver { e in if case .started(_, let at) = e { started.withLock { $0.append(at) } } }
        for _ in 0..<50 { _ = try graph.render(frames: 480) }          // 1.0 s
        #expect(abs(graph.now - 1.0) < 1e-9)
        graph.player.enqueue(PCMTone.data(ms: 500, hz: 440, amplitude: 0.3), utterance: "item_a")
        graph.player.finish(utterance: "item_a")
        for _ in 0..<10 { _ = try graph.render(frames: 480) }          // 1.2 s
        let at = try #require(started.withLock { $0.first })
        // First sample rendered at 1.0 s (+ the route's 50 ms), not ~0.
        #expect(abs(at - 1.05) < 0.021, "\(at)")
        let mark = try #require(timeline.turns().flatMap(\.marks).first { $0.stage == .firstAudioPlayed })
        #expect(abs(mark.t - 1.05) < 0.021, "\(mark.t)")
        _ = graph.player.flush()
        let flushed = try #require(timeline.turns().flatMap(\.marks).first { $0.stage == .flushed })
        #expect(abs(flushed.t - graph.now) < 1e-6, "\(flushed.t) vs \(graph.now)")
    }

    @Test func referenceIsHerRenderedEnergyOnTheGraphClock() throws {
        let graph = try AudioGraph.manual(sampleRate: 24_000, channels: 1)
        for _ in 0..<25 { _ = try graph.render(frames: 480) }          // 0.5 s
        _ = graph.player.takeReference()
        graph.player.enqueue(PCMTone.data(ms: 300, hz: 300, amplitude: 0.5), utterance: "item_a")
        graph.player.finish(utterance: "item_a")
        for _ in 0..<25 { _ = try graph.render(frames: 480) }          // 1.0 s
        let bins = graph.player.takeReference()
        #expect(bins.count == 50)
        #expect(abs((bins.first?.t ?? 0) - 0.51) < 1e-6)
        #expect(abs((bins.last?.t ?? 0) - 1.0) < 1e-6)
        let loud = bins.filter { $0.energy > 0.1 }                       // 0.5² / 2 = 0.125
        #expect(loud.count >= 29 && loud.count <= 31, "\(loud.count)")
        #expect(abs((loud.first?.t ?? 0) - 0.51) < 0.011)
        #expect(graph.player.takeReference().isEmpty)
    }

    @Test func manualFactsAreConfigurable() async throws {
        let graph = try AudioGraph.manual(sampleRate: 24_000, aecActive: false, outputLatency: 0.08)
        #expect(graph.facts?.aecActive == false)
        #expect(graph.facts?.outputLatency == 0.08)
        #expect(graph.player.outputLatency == 0.08)
        let seen = Mutex<[AudioGraph.Facts]>([])
        graph.addObserver { e in if case .running(let f) = e { seen.withLock { $0.append(f) } } }
        #expect(graph.setManualFacts(aecActive: true, outputLatency: 0.02))
        #expect(seen.withLock { $0.last?.aecActive } == true)
        #expect(graph.facts?.outputLatency == 0.02)
        #expect(!AudioGraph().setManualFacts(aecActive: true, outputLatency: 0))
    }

    /// CloudVoice takes the manual graph's facts into its ear (AEC off → the
    /// half-duplex margins), and the reference reaches the ear.
    @Test func cloudVoiceAppliesManualFacts() async throws {
        let graph = try AudioGraph.manual(sampleRate: 24_000, aecActive: false, outputLatency: 0.06)
        let factory = FakeSocketFactory([]) { FakeSocket(request: $0, sessionID: "sess_f") }
        let session = RealtimeSession(config: RealtimeSessionConfig(),
                                      credentials: { _ in .ephemeral("ek_test", expiresAt: Date().addingTimeInterval(600)) },
                                      socketFactory: factory.factory, clock: ManualRealtimeClock())
        var c = CloudVoice.Configuration()
        c.autoTick = false
        c.classifySounds = false
        let voice = CloudVoice(session: session, graph: graph, timeline: TurnTimeline(), configuration: c)
        await voice.start()
        #expect(voice.earFacts == (aec: false, latency: 0.06))
        graph.setManualFacts(aecActive: true, outputLatency: 0.01)
        #expect(voice.earFacts == (aec: true, latency: 0.01))
        voice.shutdown()
    }
}

// MARK: - (6) One rule for what was heard

@Suite struct HeardRuleAgreementTests {
    /// For any hints and any cut point, SentenceClock's heard sentences are
    /// exactly `HeardRule.heardCount` (what the session keeps in its history).
    @Test func sentenceClockAgreesWithTheSessionsRule() {
        var state: UInt64 = 77
        func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(state >> 33) % n
        }
        for trial in 0..<400 {
            let count = 1 + next(5)
            var hints: [Int] = []
            var at = 0
            for _ in 0..<count {
                at += next(5) == 0 ? -next(300) : 200 + next(2_000)   // sometimes a hint goes backwards
                hints.append(max(at, 0))
            }
            let played = next((hints.max() ?? 0) + 400)
            var clock = SentenceClock()
            let id = "item_\(trial)"
            var events: [SentenceClock.Event] = []
            events += clock.itemStarted(id)
            for (i, h) in hints.enumerated() { events += clock.add(itemID: id, text: "s\(i).", endMs: h) }
            events += clock.itemFinished(id, playedMs: played, cut: true)
            let heard = events.filter { if case .finished(_, _, _, true) = $0 { true } else { false } }.count
            // Sentences finish in order; the heard ones are a prefix.
            #expect(heard == HeardRule.heardCount(hints: hints, playedMs: played), "hints \(hints) played \(played)")
        }
    }
}

// MARK: - The whole loop: CloudVoice feeds Dee's rendered output to the ear

/// LoopRig with Dee's real echo in the microphone: what Dee rendered `delayMs`
/// ago at `gainDB`, plus room noise.
private final class EchoRoom: @unchecked Sendable {
    let rig: LoopRig
    let gain: Float
    let delay: Int
    private var seed: UInt64 = 500

    init(gainDB: Double, delayMs: Double) throws {
        rig = try LoopRig()
        gain = Float(pow(10, gainDB / 20))
        delay = Int(delayMs / 1000 * LoopRig.rate)
    }

    /// 20 ms of mic: noise + Dee's echo (+ `user`, 48 kHz, when given).
    func step(user: [Float]? = nil) throws {
        let n = Int(LoopRig.rate * 0.02)
        let out = rig.output
        let start = out.count                        // this block's first sample
        seed += 1
        var mic = Signal.noise(amplitude: 0.001, count: n, seed: seed)
        for i in 0..<n {
            let j = start + i - delay
            if j >= 0 && j < out.count { mic[i] += out[j] * gain }
            if let user { mic[i] += user[i] }
        }
        try rig.step(mic)
    }

    func run(_ seconds: Double) throws { for _ in 0..<Int((seconds / 0.02).rounded()) { try step() } }

    func talk(_ seconds: Double, amplitude: Double = 0.3) throws {
        let x = Signal.harmonic(hz: 180, amplitude: amplitude, sampleRate: LoopRig.rate, seconds: seconds)
        for f in Signal.frames(x, size: Int(LoopRig.rate * 0.02)) { try step(user: f) }
    }

    /// Dee's reply: a real TTS voice (speech-like envelope), in 100 ms deltas.
    func reply(_ resp: String, _ item: String, seconds: Double) throws {
        let voice = try herVoice(seconds: seconds)
        rig.push(Srv.messageAdded(resp, item))
        var i = 0
        while i < voice.count {
            let chunk = voice[i..<min(i + 2_400, voice.count)]
            let pcm: [Int16] = chunk.map { Int16(max(-1, min(1, $0)) * 32767) }
            rig.push(Srv.audio(resp, item, pcm.withUnsafeBytes { Data($0) }))
            i += 2_400
        }
        rig.push(Srv.audioDone(resp, item))
    }

    var uplinkMs: Int { rig.uplink().count / 24 }
}

@Suite(.serialized) struct CloudVoiceEchoLoopTests {
    private func startReply(_ room: EchoRoom, seconds: Double) async throws {
        let rig = room.rig
        try await rig.start()
        try room.run(0.3)
        rig.push(Srv.speechStarted("item_u1", ms: 100), Srv.speechStopped("item_u1", ms: 200), Srv.committed("item_u1"))
        _ = await rig.brain.wait { if case .session(.userCommitted) = $0 { true } else { false } }
        _ = try await rig.voice.respond()
        rig.push(Srv.responseCreated("resp_1"))
        try room.reply("resp_1", "item_a1", seconds: seconds)
        rig.push(Srv.responseDone("resp_1"))
        await rig.settle()
    }

    /// Loud residual echo (−6 dB, 80 ms): the server opens "user" speech on it
    /// mid-reply; it is deleted, Dee plays on, the brain never sees it, and the
    /// echo path was learned from Dee's own rendered audio.
    @Test func herEchoIsDeletedAndSheKeepsTalking() async throws {
        let room = try EchoRoom(gainDB: -6, delayMs: 80)
        let rig = room.rig
        try await startReply(room, seconds: 4)
        try room.run(1.5)
        rig.push(Srv.speechStarted("item_e", ms: room.uplinkMs - 300))
        await rig.settle()
        try room.run(0.8)
        rig.push(Srv.speechStopped("item_e", ms: room.uplinkMs - 100), Srv.committed("item_e"))
        #expect(await rig.waitSent("conversation.item.delete"))
        #expect(rig.sent("conversation.item.delete").first?["item_id"] as? String == "item_e")
        try room.run(2.5)
        #expect(rig.sent("conversation.item.truncate").isEmpty, "Dee cut in on Dee's own echo")
        #expect(!rig.voiceEvents.contains(.bargeIn))
        #expect(rig.brainSession { if case .userSpeechStarted("item_e", _) = $0 { true } else { false } }.isEmpty)
        let learned = rig.voice.learnedEcho
        #expect(learned.gainDB != nil, "the echo path was never learned")
        if let d = learned.delay { #expect(abs(d - 0.08) <= 0.03, "delay \(d)") }
        rig.voice.shutdown()
    }

    /// The user talking over Dee (and Dee's echo) still cuts Dee at once.
    @Test func theUserOverHerEchoStillBargesIn() async throws {
        let room = try EchoRoom(gainDB: -12, delayMs: 80)
        let rig = room.rig
        try await startReply(room, seconds: 4)
        try room.run(1.5)
        try room.talk(0.1, amplitude: 0.5)                  // ≈ −14 dBFS; Dee's echo peaks ≈ −23
        rig.push(Srv.speechStarted("item_u2", ms: room.uplinkMs - 150))
        await rig.settle()
        try room.talk(0.4, amplitude: 0.5)
        #expect(rig.voice.floorHold?.itemID == "item_u2")             // paused at once: their words decide
        rig.push(Srv.speechStopped("item_u2", ms: room.uplinkMs), Srv.committed("item_u2"),
                 Srv.userTranscript("item_u2", "Stop."))
        await rig.settle()
        try room.run(CloudVoice.holdAfterWords + 0.1)                   // no brain to answer: the voice ends it
        #expect(await rig.events.wait { $0 == .bargeIn } != nil)
        #expect(await rig.waitSent("conversation.item.truncate"))
        #expect(rig.sent("conversation.item.delete").isEmpty)
        rig.voice.shutdown()
    }
}

// MARK: - Sweep: Dee's echo over every bed, gain and delay the harness uses

@Suite(.serialized) struct EchoSweepTests {
    /// Dee's voices: two by default, all four with `DEE_SWEEP=full`.
    static let voices = ProcessInfo.processInfo.environment["DEE_SWEEP"] == "full" ? ["l02", "l01", "d02", "f01"] : ["l02", "f01"]

    /// Echo-only: Dee's reply with the server opening "user" speech on Dee's echo
    /// three times. Never a barge-in, every onset rejected.
    @Test(arguments: [("kitchen", -20.0, 80.0), ("kitchen", -10.0, 40.0), ("fan", -20.0, 120.0), ("tv", -30.0, 200.0),
                      ("kitchen", -30.0, 200.0), ("fan", -10.0, 40.0), ("tv", -20.0, 80.0)])
    func herEchoAcrossVoices(bed: String, gainDB: Double, delayMs: Double) throws {
        var failures: [String] = []
        for voice in Self.voices {
            var sim = RoomSim(seconds: 9)
            sim.tag = "sweep-\(bed)\(Int(gainDB))-\(voice)"
            sim.setBed(try HarnessFixture.wav("noise/\(bed).wav"), snrDB: bed == "tv" ? 20 : 15)
            sim.setEcho(gainDB: gainDB, delayMs: delayMs, ir: try HarnessFixture.wav("ir/room.wav"))
            let herStart = RoomSim.sample(1.1)
            let v = try herVoice(voice, seconds: 7)
            RoomSim.place(v, into: &sim.her, at: herStart)
            for (k, at) in [0.4, 2.2, 4.4].enumerated() {
                let onset = herStart + RoomSim.sample(at)
                sim.server.append((onset + 7_000, .start("e\(k)", onsetSample: onset)))
                sim.server.append((onset + RoomSim.sample(1.3), .stop("e\(k)", endSample: onset + RoomSim.sample(1.0))))
            }
            sim.run()
            let barged = sim.actions.contains(where: isBargeIn)
            let accepted = sim.actions.filter { if case .acceptOnset = $0 { true } else { false } }
            if barged || !accepted.isEmpty { failures.append("\(voice): barged \(barged) accepted \(accepted)") }
        }
        #expect(failures.isEmpty, "\(bed) \(gainDB) dB \(delayMs) ms: \(failures)")
    }

    /// The user ("Wait, stop talking for a second" / "Hold on, hold on") over
    /// Dee and Dee's echo: never missed, never deleted; within 0.5 s at the
    /// harness's −30 dB residual echo. At −20 dB the room IR makes Dee's echo about
    /// as loud as the user (≈ −8 dB re Dee's output): the short "Wait," before
    /// c03's pause is masked and the barge-in lands on "stop talking" (≤ 1.2 s).
    @Test(arguments: [("kitchen", -20.0, 80.0), ("fan", -20.0, 120.0), ("tv", -30.0, 200.0), ("fan", -30.0, 40.0),
                      ("kitchen", -30.0, 120.0)])
    func userOverHerAcrossVoices(bed: String, gainDB: Double, delayMs: Double) throws {
        var failures: [String] = []
        for voice in Self.voices {
            for (fixture, atMs) in [("c03", 900), ("c06", 1500)] {
                var sim = RoomSim(seconds: 9)
                sim.setBed(try HarnessFixture.wav("noise/\(bed).wav"), snrDB: bed == "tv" ? 20 : 15)
                sim.setEcho(gainDB: gainDB, delayMs: delayMs, ir: try HarnessFixture.wav("ir/room.wav"))
                RoomSim.place(try herVoice("q01", seconds: 1.5), into: &sim.her, at: RoomSim.sample(0.3))
                let herStart = RoomSim.sample(3.0)
                RoomSim.place(try herVoice(voice, seconds: 5.5), into: &sim.her, at: herStart)
                let u = try HarnessFixture.utterance(fixture)
                let onset = herStart + atMs * 24
                let start = onset - u.onset
                RoomSim.place(u.samples, into: &sim.user, at: start)
                sim.server = [(onset + 6_000, .start("u", onsetSample: onset)),
                              (start + u.end + 12_000, .stop("u", endSample: start + u.end))]
                sim.run()
                let barge = sim.firstTime(isBargeIn).map { $0 - RoomSim.time(onset) }
                let limit = gainDB <= -30 ? 0.5 : 1.2
                if barge == nil || barge! > limit || sim.actions.contains(.rejectEcho(itemID: "u")) {
                    failures.append("\(voice)/\(fixture): \(barge.map { String(format: "%.2f s", $0) } ?? "none")")
                }
            }
        }
        #expect(failures.isEmpty, "\(bed) \(gainDB) dB \(delayMs) ms: \(failures)")
    }
}
