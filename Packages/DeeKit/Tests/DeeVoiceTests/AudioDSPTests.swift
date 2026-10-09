import Foundation
import Testing
@testable import DeeVoice

@Suite struct LevelTests {
    @Test func sineRMS() {
        // RMS of a sine with amplitude A is A/√2 → 20·log10(0.5/√2) ≈ -9.03 dBFS.
        let db = Level.rmsDB(Signal.sine(hz: 440, amplitude: 0.5, seconds: 0.5))
        #expect(abs(db - (-9.03)) < 0.1)
        #expect(abs(Level.peakDB(Signal.sine(hz: 440, amplitude: 0.5, seconds: 0.5)) - (-6.02)) < 0.05)
    }

    @Test func silenceAndEdgeCases() {
        #expect(Level.rmsDB([]) == -160)
        #expect(Level.rmsDB([Float](repeating: 0, count: 100)) == -160)
        #expect(Level.amplitudeDB(.nan) == -160)
        #expect(Level.meter(-100) == 0)
        #expect(Level.meter(0) == 1)
        #expect(Level.meter(.nan) == 0)
        #expect(abs(Level.meter(-36) - 0.5) < 1e-9)
    }
}

@Suite struct FrameSlicerTests {
    @Test func slicesAcrossPushes() {
        var s = FrameSlicer(frameSize: 4)
        let a = s.push([1, 2, 3])
        #expect(a.isEmpty)
        let f = s.push([4, 5, 6, 7, 8, 9])
        #expect(f == [[1, 2, 3, 4], [5, 6, 7, 8]])
        let g = s.push([10, 11, 12])
        #expect(g == [[9, 10, 11, 12]])
        s.reset()
        let h = s.push([1, 2, 3])
        #expect(h.isEmpty)
    }
}

@Suite struct EnergyVADTests {
    let dt = 0.04

    @Test func quietIsUnvoicedSpeechIsVoiced() {
        var vad = EnergyVAD()
        let quiet = Signal.noise(amplitude: 0.002, count: 640)
        for _ in 0..<25 {
            let v = vad.process(frameDB: Level.rmsDB(quiet), frameDuration: dt)
            #expect(v == false)
        }
        let voice = Signal.harmonic(hz: 180, amplitude: 0.3, seconds: 0.04)
        let v = vad.process(frameDB: Level.rmsDB(voice), frameDuration: dt)
        #expect(v)
    }

    @Test func hangoverBridgesShortGaps() {
        var vad = EnergyVAD()
        for _ in 0..<20 { _ = vad.process(frameDB: -70, frameDuration: dt) }
        let loud = vad.process(frameDB: -20, frameDuration: dt)
        let hang = vad.process(frameDB: -70, frameDuration: dt)   // within hangover
        #expect(loud && hang)
        for _ in 0..<vad.hangoverFrames { _ = vad.process(frameDB: -70, frameDuration: dt) }
        let after = vad.process(frameDB: -70, frameDuration: dt)
        #expect(after == false)
    }

    @Test func floorAdaptsToSteadyNoise() {
        var vad = EnergyVAD()
        for _ in 0..<20 { _ = vad.process(frameDB: -70, frameDuration: dt) }
        // A fan switches on at -40 dBFS and stays on.
        var voicedAtEnd = true
        for _ in 0..<(30 * 25) { voicedAtEnd = vad.process(frameDB: -40, frameDuration: dt) }
        #expect(voicedAtEnd == false)
        #expect(vad.noiseFloorDB > -50)
    }

    @Test func tooQuietIsNeverVoice() {
        var vad = EnergyVAD()
        for _ in 0..<20 { _ = vad.process(frameDB: -100, frameDuration: dt) }
        let v = vad.process(frameDB: -65, frameDuration: dt)
        #expect(v == false)
    }
}

@Suite struct PitchDetectorTests {
    @Test(arguments: [90.0, 140, 220, 330, 440])
    func sinePitch(hz: Double) throws {
        let f = try #require(PitchDetector.yin(Signal.sine(hz: hz, seconds: 0.04), sampleRate: 16_000))
        #expect(abs(f - hz) / hz < 0.02)
    }

    @Test func harmonicVoiceLikePitch() throws {
        let f = try #require(PitchDetector.yin(Signal.harmonic(hz: 150, seconds: 0.04), sampleRate: 16_000))
        #expect(abs(f - 150) < 4)
    }

    @Test func decimatedFrom48k() throws {
        let x = Signal.sine(hz: 200, sampleRate: 48_000, seconds: 0.04)
        let (small, rate) = PitchDetector.decimate(x, sampleRate: 48_000)
        #expect(rate == 16_000)
        #expect(small.count == x.count / 3)
        let f = try #require(PitchDetector.yin(small, sampleRate: rate))
        #expect(abs(f - 200) < 4)
    }

    @Test func noiseAndSilenceHaveNoPitch() {
        #expect(PitchDetector.yin(Signal.noise(amplitude: 0.3, count: 640), sampleRate: 16_000) == nil)
        #expect(PitchDetector.yin([Float](repeating: 0, count: 640), sampleRate: 16_000) == nil)
        #expect(PitchDetector.yin([0.1, 0.2], sampleRate: 16_000) == nil)
        #expect(PitchDetector.yin(Signal.sine(hz: 200, seconds: 0.04), sampleRate: 0) == nil)
    }
}

@Suite struct ProsodyTests {
    let sr = 16_000.0
    let frame = 640

    func accumulate(_ x: [Float], voiced: Bool = true) -> ProsodyAccumulator {
        var p = ProsodyAccumulator()
        for f in Signal.frames(x, size: frame) { p.add(frame: f, sampleRate: sr, voiced: voiced) }
        return p
    }

    @Test func steadyToneIsFlat() {
        let p = accumulate(Signal.harmonic(hz: 200, amplitude: 0.3, seconds: 1)).prosody(text: "hello there")
        #expect(abs(p.meanPitchHz - 200) < 5)
        #expect(p.pitchVariability < 0.3)
    }

    @Test func glideIsLively() {
        // 150 → 300 Hz is one octave: uniform in Hz, SD in semitones ≈ 3.4.
        let p = accumulate(Signal.glide(from: 150, to: 300, seconds: 1.2)).prosody(text: "wow")
        #expect(p.pitchVariability > 2.5)
        #expect(p.pitchVariability < 4.5)
        #expect(p.meanPitchHz > 180 && p.meanPitchHz < 260)
    }

    @Test func loudnessPeakAndRate() {
        let acc = accumulate(Signal.sine(hz: 220, amplitude: 0.5, seconds: 2))
        let p = acc.prosody(text: "one two three four five six")
        #expect(abs(p.loudnessDB - (-9.03)) < 0.2)
        #expect(abs(p.peakDB - (-6.02)) < 0.1)
        #expect(abs(acc.voicedDuration - 2) < 0.05)
        #expect(abs(p.speechRate - 3) < 0.1)
    }

    @Test func unvoicedFramesDoNotCount() {
        var p = ProsodyAccumulator()
        for f in Signal.frames(Signal.sine(hz: 220, amplitude: 0.5, seconds: 1), size: frame) {
            p.add(frame: f, sampleRate: sr, voiced: true)
        }
        for f in Signal.frames(Signal.noise(amplitude: 0.001, count: 16_000), size: frame) {
            p.add(frame: f, sampleRate: sr, voiced: false)
        }
        let out = p.prosody(text: "a b")
        #expect(abs(p.voicedDuration - 1) < 0.05)
        #expect(abs(out.loudnessDB - (-9.03)) < 0.2)
        #expect(abs(out.speechRate - 2) < 0.1)
    }

    @Test func emptyAndUnvoicedOnly() {
        let empty = ProsodyAccumulator().prosody(text: "hi")
        #expect(empty == VoiceProsody(loudnessDB: -100, peakDB: -100, speechRate: 0, pitchVariability: 0, meanPitchHz: 0))
        let quiet = accumulate(Signal.noise(amplitude: 0.01, count: 16_000), voiced: false).prosody(text: "hi")
        #expect(quiet.loudnessDB < -40 && quiet.loudnessDB > -50)
        #expect(quiet.meanPitchHz == 0)
        #expect(quiet.speechRate == 0)
    }

    @Test func octaveErrorsAreRejected() {
        let (sd, mean) = ProsodyAccumulator.pitchStats([200, 201, 199, 200, 400, 100, 202])
        #expect(sd < 0.2)
        #expect(abs(mean - 200.4) < 1)
        let none = ProsodyAccumulator.pitchStats([])
        #expect(none.0 == 0 && none.1 == 0)
        #expect(ProsodyAccumulator.pitchStats([180, 182]).0 == 0)
    }

    @Test func wordCount() {
        #expect(ProsodyAccumulator.wordCount("Hello, world! It's 3 o'clock -- ok") == 6)
        #expect(ProsodyAccumulator.wordCount("  ") == 0)
    }
}
