import Foundation
import Testing
@testable import HarnessCore

@Suite("MicMixer")
struct MixerTests {
    let rate = 24_000

    func tone(_ n: Int, amplitude: Float = 0.5, hz: Double = 440) -> [Float] {
        (0..<n).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / 24_000)) }
    }

    /// Runs the mixer for `blocks` with `output` as Dee's played audio, returns the mic.
    func drive(_ m: MicMixer, blocks: Int, block: Int = 480, output: (Int) -> [Float]) -> [Float] {
        var mic: [Float] = []
        for b in 0..<blocks {
            m.pushOutput(output(b))
            mic += m.next(block).mic
        }
        return mic
    }

    @Test func fixturesLandSampleExactlyAndInOrder() {
        let m = MicMixer(sampleRate: rate)
        _ = m.next(480)                                   // frame 480
        let a = [Float](repeating: 0.25, count: 1000)
        let b = [Float](repeating: -0.5, count: 300)
        #expect(m.play(a, id: "a") == 480)
        #expect(m.play(b, id: "b") == 1480)               // queued after a
        #expect(m.schedule([0.1], id: "c", at: 2_000) == 2_000)
        var mic: [Float] = []
        for _ in 0..<5 { mic += m.next(480).speech }      // frames 480..<2880
        #expect(mic[0] == 0.25 && mic[999] == 0.25)
        #expect(mic[1000] == -0.5 && mic[1299] == -0.5)
        #expect(mic[1300] == 0)
        #expect(abs(mic[2000 - 480] - 0.1) < 1e-6)
        #expect(!m.fixtureActive)
    }

    @Test func playNowOverlaps() {
        let m = MicMixer(sampleRate: rate)
        m.play([Float](repeating: 0.2, count: 960), id: "base")
        _ = m.next(480)
        #expect(m.playNow([Float](repeating: 0.3, count: 480), id: "barge") == 480)
        let s = m.next(480).speech
        #expect(abs(s[0] - 0.5) < 1e-6)
    }

    @Test func bedGainMeetsTheSNR() {
        let m = MicMixer(sampleRate: rate)
        let bed = Beds.fan(seconds: 2, sampleRate: rate)
        m.setBed(bed, snrDB: 15)
        #expect(abs((m.bedLevelDB ?? 0) - (-24 - 15)) < 0.05)
        var mic: [Float] = []
        for _ in 0..<100 { mic += m.next(480).mic }       // 2 s of bed alone
        #expect(abs(DSP.db(DSP.rms(mic)) - (-39)) < 0.3)
        m.setBed(nil, snrDB: 0)
        #expect(m.bedLevelDB == nil)
        #expect(m.next(480).mic.allSatisfy { $0 == 0 })
    }

    @Test func echoIsDelayedAndAttenuated() {
        let m = MicMixer(sampleRate: rate)
        m.setEcho(EchoConfig(gainDB: -20, delayMs: 50, reverb: false))
        // One impulse in Dee's output at frame 100.
        let mic = drive(m, blocks: 10) { b in
            var x = [Float](repeating: 0, count: 480)
            if b == 0 { x[100] = 1 }
            return x
        }
        let d = 50 * 24                                  // 1200 frames
        #expect(abs(mic[100 + d] - 0.1) < 1e-6)
        #expect(mic.enumerated().filter { $0.offset != 100 + d }.allSatisfy { abs($0.element) < 1e-7 })
    }

    @Test func echoShorterThanABlockUsesTheSameBlock() {
        let m = MicMixer(sampleRate: rate)
        m.setEcho(EchoConfig(gainDB: 0, delayMs: 5, reverb: false))     // 120 frames < 480
        let mic = drive(m, blocks: 2) { b in
            var x = [Float](repeating: 0, count: 480)
            if b == 0 { x[10] = 0.5 }
            return x
        }
        #expect(abs(mic[130] - 0.5) < 1e-6)
    }

    @Test func reverbEchoEqualsTheFullConvolution() {
        let ir = Beds.roomImpulse(sampleRate: rate)
        let m = MicMixer(sampleRate: rate)
        m.setEcho(EchoConfig(gainDB: -10, delayMs: 120, reverb: true), impulse: ir)
        let out = tone(480 * 40, amplitude: 0.3)
        let mic = drive(m, blocks: 40) { b in Array(out[(b * 480)..<((b + 1) * 480)]) }
        let reference = DSP.convolve(out, ir)
        let g = Float(DSP.linear(-10))
        let d = 120 * 24
        var maxErr: Float = 0
        for i in d..<mic.count { maxErr = max(maxErr, abs(mic[i] - g * reference[i - d])) }
        #expect(maxErr < 1e-4)
        #expect(mic[0..<d].allSatisfy { abs($0) < 1e-7 })
    }

    @Test func echoOffAddsNothing() {
        let m = MicMixer(sampleRate: rate)
        m.setEcho(nil)
        let mic = drive(m, blocks: 5) { _ in tone(480) }
        #expect(mic.allSatisfy { $0 == 0 })
    }

    @Test func micIsClipped() {
        let m = MicMixer(sampleRate: rate)
        m.play([Float](repeating: 0.9, count: 480), id: "a")
        m.playNow([Float](repeating: 0.9, count: 480), id: "b")
        #expect(m.next(480).mic.allSatisfy { $0 <= 1 })
    }
}

@Suite("Signals and fixtures")
struct SignalTests {
    @Test func wavRoundTrips() throws {
        let x: [Float] = [0, 0.5, -0.5, 1, -1, 0.25]
        let a = try WAV.decode(WAV.encode(x, sampleRate: 24_000))
        #expect(a.sampleRate == 24_000)
        #expect(zip(a.samples, x).allSatisfy { abs($0 - $1) < 1.0 / 16_000 })
    }

    @Test func wavSkipsUnknownChunks() throws {
        var d = WAV.encode([0.5, -0.5], sampleRate: 16_000)
        // Insert a LIST chunk before "data".
        let list = Data("LIST".utf8) + Data([4, 0, 0, 0]) + Data("abcd".utf8)
        d.insert(contentsOf: list, at: 36)
        let a = try WAV.decode(d)
        #expect(a.samples.count == 2 && a.sampleRate == 16_000)
    }

    @Test func assemblerGroundTruthIsExact() {
        let rate = 24_000
        let word = (0..<12_000).map { Float(0.3 * sin(2 * Double.pi * 200 * Double($0) / 24_000)) }  // 0.5 s
        let a = FixtureAssembler.assemble([.audio(word), .pause(1.2), .audio(word)], sampleRate: rate, levelDB: -24)
        #expect(a.spans.count == 2)
        let lead = Int(FixtureAssembler.lead * 24_000)
        #expect(abs(a.onset - lead) <= 240)                      // within 10 ms
        let gap = Double(a.spans[1].start - a.spans[0].end) / 24_000
        #expect(abs(gap - 1.2) < 0.08)                            // the scripted pause (+ the 30 ms pads)
        #expect(abs(a.samples.count - a.endOfSpeech - Int(FixtureAssembler.tail * 24_000)) <= 960)
        #expect(abs(DSP.activeLevelDB(a.samples, sampleRate: rate) - (-24)) < 0.5)
    }

    @Test func catalogIsCompleteAndUsesUserVoicesOnly() {
        let all = FixtureCatalog.all
        #expect(all.count >= 60)
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(Set(all.map(\.category)) == Set(FixtureCategory.allCases))
        #expect(!all.contains { ["marin", "cedar"].contains($0.voice) })
        for c in [FixtureCategory.pause06, .pause12, .pause20] {
            #expect(all.filter { $0.category == c }.count >= 3)
        }
        #expect(all.filter { $0.category == .pause12 }.allSatisfy { $0.pauses == [1.2] })
        #expect(Set(all.map(\.style)) == Set(FixtureStyle.allCases))
        #expect(all.contains { $0.engine == .say } && all.contains { $0.engine == .openai })
    }

    @Test func bedsAreDeterministicAndAtLevel() {
        let a = Beds.kitchen(seconds: 3, sampleRate: 24_000)
        let b = Beds.kitchen(seconds: 3, sampleRate: 24_000)
        #expect(a == b)
        #expect(abs(DSP.db(DSP.rms(Beds.fan(seconds: 3, sampleRate: 24_000))) - Beds.bedLevelDB) < 2)
        let ir = Beds.roomImpulse(sampleRate: 24_000)
        #expect(ir[0] == 1 || DSP.peak(ir) == 1)
        // The tail decays: last 50 ms is > 40 dB below the first 50 ms.
        let head = DSP.rms(ir[0..<1200]), tail = DSP.rms(ir[(ir.count - 1200)...])
        #expect(DSP.db(tail) < DSP.db(head) - 40)
    }

    /// The committed fixtures match their manifest (skipped before `fixtures` ran).
    @Test func committedFixturesMatchTheManifest() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures")
        guard let manifest = try? FixtureManifest.load(dir.appendingPathComponent("manifest.json")) else { return }
        #expect(manifest.utterances.count >= 60)
        var total = 0
        for u in manifest.utterances {
            let url = dir.appendingPathComponent(u.file)
            let a = try WAV.read(url)
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            #expect(a.sampleRate == 24_000)
            #expect(a.samples.count == u.samples)
            #expect(u.onsetSample < u.endOfSpeechSample && u.endOfSpeechSample <= u.samples)
            #expect(u.spans.first?.start == u.onsetSample && u.spans.last?.end == u.endOfSpeechSample)
            if !u.scriptedPauses.isEmpty {
                let longest = zip(u.spans, u.spans.dropFirst()).map { Double($1.start - $0.end) / 24_000 }.max() ?? 0
                #expect(longest >= (u.scriptedPauses.max() ?? 0) - 0.05, "\(u.id)")
            }
        }
        #expect(total < 40_000_000)
        #expect(manifest.noise.map(\.id).sorted() == ["fan", "kitchen", "tv"])
        #expect(!manifest.impulseResponses.isEmpty)
    }
}
