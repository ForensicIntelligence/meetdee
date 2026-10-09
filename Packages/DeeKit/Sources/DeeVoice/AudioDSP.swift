import Accelerate
import Foundation

// Pure audio analysis: levels, an adaptive energy VAD, YIN pitch, and prosody
// accumulation. No AVFoundation here, so all of it is unit-tested on macOS.

public enum Level {
    /// RMS of a block in dBFS (floor -160).
    public static func rmsDB(_ x: [Float]) -> Double {
        guard !x.isEmpty else { return -160 }
        var sum = 0.0
        for v in x { let d = Double(v); sum += d * d }
        return powerDB(sum / Double(x.count))
    }

    /// Mean power (amplitude²) to dBFS.
    public static func powerDB(_ meanSquare: Double) -> Double {
        guard meanSquare > 1e-16, meanSquare.isFinite else { return -160 }
        return 10 * log10(meanSquare)
    }

    public static func peakDB(_ x: [Float]) -> Double {
        var m: Float = 0
        for v in x { m = max(m, abs(v)) }
        return amplitudeDB(Double(m))
    }

    public static func amplitudeDB(_ a: Double) -> Double {
        guard a > 1e-8, a.isFinite else { return -160 }
        return 20 * log10(a)
    }

    /// dBFS → 0…1 for meters. `floor` maps to 0 and `ceiling` to 1.
    public static func meter(_ db: Double, floor: Double = -60, ceiling: Double = -12) -> Double {
        guard db.isFinite else { return 0 }
        return min(max((db - floor) / (ceiling - floor), 0), 1)
    }
}

/// Cuts a stream of samples into fixed-size frames.
public struct FrameSlicer: Sendable {
    public let frameSize: Int
    private var pending: [Float] = []

    public init(frameSize: Int) {
        self.frameSize = max(1, frameSize)
        pending.reserveCapacity(self.frameSize * 2)
    }

    public mutating func push(_ samples: [Float]) -> [[Float]] {
        pending.append(contentsOf: samples)
        var frames: [[Float]] = []
        var start = 0
        while pending.count - start >= frameSize {
            frames.append(Array(pending[start..<(start + frameSize)]))
            start += frameSize
        }
        if start > 0 { pending.removeFirst(start) }
        return frames
    }

    public mutating func reset() { pending.removeAll(keepingCapacity: true) }
}

/// Energy voice-activity detector with an adaptive noise floor.
///
/// The floor falls quickly to quieter frames and creeps up slowly through
/// sustained noise, so a fan or a fridge soon stops counting as "voice".
public struct EnergyVAD: Sendable {
    /// dB above the noise floor a frame needs to count as voiced.
    public var thresholdAboveFloor: Double = 10
    /// Absolute minimum level for voice (dBFS).
    public var absoluteMinDB: Double = -58
    /// Frames to stay "voiced" after energy drops (bridges gaps between syllables).
    public var hangoverFrames: Int = 5
    /// dB per second the floor rises through sustained sound.
    public var riseWhileQuiet: Double = 3.0
    public var riseWhileVoiced: Double = 1.5

    public private(set) var noiseFloorDB: Double = -70
    public private(set) var isVoiced = false
    private var hang = 0
    private var primed = false

    public init() {}

    /// `allowRise: false` holds the floor where it is through sound that is known
    /// not to be the room (her own echo); it can still fall.
    public mutating func process(frameDB db: Double, frameDuration dt: Double, allowRise: Bool = true) -> Bool {
        let level = db.isFinite ? max(db, -160) : -160
        if !primed {
            noiseFloorDB = min(max(level, -90), -30)
            primed = true
        }
        let loud = level > noiseFloorDB + thresholdAboveFloor && level > absoluteMinDB
        if loud {
            hang = hangoverFrames
            isVoiced = true
        } else if hang > 0 {
            hang -= 1
            isVoiced = true
        } else {
            isVoiced = false
        }
        // Floor tracking.
        if level < noiseFloorDB {
            noiseFloorDB += (level - noiseFloorDB) * 0.25
        } else if allowRise {
            let rate = isVoiced ? riseWhileVoiced : riseWhileQuiet
            noiseFloorDB = min(noiseFloorDB + rate * dt, level)
        }
        noiseFloorDB = min(max(noiseFloorDB, -100), -20)
        return isVoiced
    }

    public mutating func reset() {
        primed = false
        isVoiced = false
        hang = 0
        noiseFloorDB = -70
    }
}

/// Fundamental-frequency estimation (YIN, de Cheveigné & Kawahara 2002).
public enum PitchDetector {
    /// f0 in Hz, or nil when the frame is unvoiced/aperiodic.
    public static func yin(_ x: [Float], sampleRate: Double, minHz: Double = 70, maxHz: Double = 500,
                           threshold: Double = 0.15) -> Double? {
        analyze(x, sampleRate: sampleRate, minHz: minHz, maxHz: maxHz, threshold: threshold, looseThreshold: threshold).f0
    }

    /// One YIN pass: `f0` with the strict `threshold`, and whether the frame is
    /// periodic at all at `looseThreshold` (voicing, where real speech's pitch
    /// glides within a frame). The difference function runs on Accelerate.
    public static func analyze(_ x: [Float], sampleRate: Double, minHz: Double = 70, maxHz: Double = 500,
                               threshold: Double = 0.15, looseThreshold: Double) -> (f0: Double?, periodic: Bool) {
        guard sampleRate > 0, minHz > 0, maxHz > minHz else { return (nil, false) }
        let maxLag = Int(sampleRate / minHz)
        let minLag = max(2, Int(sampleRate / maxHz))
        let w = x.count - maxLag - 1
        guard w >= minLag * 2, maxLag > minLag else { return (nil, false) }

        // d(τ) = Σ x[j]² + Σ x[j+τ]² − 2 Σ x[j]·x[j+τ] over j < w.
        var d = [Double](repeating: 0, count: maxLag + 2)
        var energy0: Float = 0
        var energyTau: Float = 0
        x.withUnsafeBufferPointer { p in
            let base = p.baseAddress!
            vDSP_svesq(base, 1, &energy0, vDSP_Length(w))
            vDSP_svesq(base + 1, 1, &energyTau, vDSP_Length(w))
            for tau in 1...(maxLag + 1) {
                if tau > 1 {
                    // Slide the window [tau, tau + w): drop x[tau-1]², add x[tau+w-1]².
                    let out = base[tau - 1], inn = base[tau + w - 1]
                    energyTau += inn * inn - out * out
                }
                var cross: Float = 0
                vDSP_dotpr(base, 1, base + tau, 1, &cross, vDSP_Length(w))
                d[tau] = max(0, Double(energy0) + Double(energyTau) - 2 * Double(cross))
            }
        }
        var cmnd = [Double](repeating: 1, count: maxLag + 2)
        var running = 0.0
        for tau in 1...(maxLag + 1) {
            running += d[tau]
            cmnd[tau] = running > 0 ? d[tau] * Double(tau) / running : 1
        }
        var periodic = false
        var tauEstimate = -1
        var tau = minLag
        while tau <= maxLag {
            if cmnd[tau] < looseThreshold { periodic = true }
            if cmnd[tau] < threshold {
                while tau + 1 <= maxLag, cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                tauEstimate = tau
                break
            }
            tau += 1
        }
        guard tauEstimate > 0 else { return (nil, periodic) }
        // Parabolic interpolation for sub-sample precision.
        let t = tauEstimate
        var refined = Double(t)
        if t > 1, t + 1 <= maxLag + 1 {
            let a = cmnd[t - 1], b = cmnd[t], c = cmnd[t + 1]
            let denom = a - 2 * b + c
            if abs(denom) > 1e-12 { refined = Double(t) + 0.5 * (a - c) / denom }
        }
        guard refined > 0 else { return (nil, true) }
        let f = sampleRate / refined
        return ((minHz * 0.9...maxHz * 1.1).contains(f) ? f : nil, true)
    }

    /// Box-filter decimation to at most `targetRate` (keeps YIN cheap at 48 kHz).
    public static func decimate(_ x: [Float], sampleRate: Double, targetRate: Double = 16_000) -> ([Float], Double) {
        let factor = max(1, Int(sampleRate / targetRate))
        guard factor > 1 else { return (x, sampleRate) }
        var out = [Float]()
        out.reserveCapacity(x.count / factor)
        var i = 0
        while i + factor <= x.count {
            var s: Float = 0
            for k in 0..<factor { s += x[i + k] }
            out.append(s / Float(factor))
            i += factor
        }
        return (out, sampleRate / Double(factor))
    }
}

/// Collects loudness, peak, voiced time and pitch over one utterance.
public struct ProsodyAccumulator: Sendable {
    private var voicedEnergy = 0.0
    private var voicedSamples = 0
    private var allEnergy = 0.0
    private var allSamples = 0
    private var peak: Float = 0
    private var pitches: [Double] = []
    public private(set) var voicedDuration: Double = 0

    public init() {}

    /// Adds one analysis frame. Pitch is estimated only on voiced frames; the
    /// frame's f0 (Hz) is returned when one was found.
    @discardableResult
    public mutating func add(frame: [Float], sampleRate: Double, voiced: Bool) -> Double? {
        guard !frame.isEmpty, sampleRate > 0 else { return nil }
        var e = 0.0
        var p: Float = 0
        for v in frame {
            let d = Double(v)
            e += d * d
            p = max(p, abs(v))
        }
        allEnergy += e
        allSamples += frame.count
        guard voiced else { return nil }
        peak = max(peak, p)
        voicedEnergy += e
        voicedSamples += frame.count
        voicedDuration += Double(frame.count) / sampleRate
        let (small, rate) = PitchDetector.decimate(frame, sampleRate: sampleRate)
        let f0 = PitchDetector.yin(small, sampleRate: rate)
        if let f0 { pitches.append(f0) }
        return f0
    }

    /// Adds a frame already measured elsewhere (sum of squares, sample count, peak
    /// amplitude, voiced, f0): prosody over a stretch of frames logged earlier.
    public mutating func add(energy: Double, samples: Int, peak: Float, voiced: Bool, f0: Double?, sampleRate: Double) {
        guard samples > 0, sampleRate > 0 else { return }
        allEnergy += energy
        allSamples += samples
        guard voiced else { return }
        self.peak = max(self.peak, peak)
        voicedEnergy += energy
        voicedSamples += samples
        voicedDuration += Double(samples) / sampleRate
        if let f0, f0.isFinite, f0 > 0 { pitches.append(f0) }
    }

    public var isEmpty: Bool { allSamples == 0 }

    public func prosody(text: String) -> VoiceProsody {
        let loudness: Double
        if voicedSamples > 0 {
            loudness = Level.powerDB(voicedEnergy / Double(voicedSamples))
        } else if allSamples > 0 {
            loudness = Level.powerDB(allEnergy / Double(allSamples))
        } else {
            loudness = -100
        }
        let words = Self.wordCount(text)
        let rate = voicedDuration >= 0.25 ? Double(words) / voicedDuration : 0
        let (sd, mean) = Self.pitchStats(pitches)
        return VoiceProsody(
            loudnessDB: max(loudness, -100),
            peakDB: max(Level.amplitudeDB(Double(peak)), -100),
            speechRate: rate,
            pitchVariability: sd,
            meanPitchHz: mean
        )
    }

    public mutating func reset() { self = ProsodyAccumulator() }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace })
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
            .count
    }

    /// (semitone SD, mean Hz), robust to octave errors: values further than ~an
    /// octave-ish (×1.8) from the median are dropped first.
    static func pitchStats(_ f0: [Double]) -> (Double, Double) {
        let valid = f0.filter { $0.isFinite && $0 > 0 }
        guard !valid.isEmpty else { return (0, 0) }
        let sorted = valid.sorted()
        let median = sorted[sorted.count / 2]
        let kept = valid.filter { $0 >= median / 1.8 && $0 <= median * 1.8 }
        guard !kept.isEmpty else { return (0, 0) }
        let mean = kept.reduce(0, +) / Double(kept.count)
        guard kept.count >= 3 else { return (0, mean) }
        let logs = kept.map { 12 * log2($0) }
        let m = logs.reduce(0, +) / Double(logs.count)
        let variance = logs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(logs.count)
        return (sqrt(variance), mean)
    }
}
