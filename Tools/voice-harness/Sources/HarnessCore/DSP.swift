import Accelerate
import Foundation

/// Small, deterministic signal helpers.
public enum DSP {
    public static func db(_ linear: Double) -> Double { 20 * log10(max(linear, 1e-12)) }
    public static func linear(_ db: Double) -> Double { pow(10, db / 20) }

    public static func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        var acc = 0.0
        for v in x { acc += Double(v) * Double(v) }
        return (acc / Double(x.count)).squareRoot()
    }

    public static func rms(_ x: [Float]) -> Double { rms(x[...]) }

    public static func peak(_ x: [Float]) -> Double { Double(x.map { abs($0) }.max() ?? 0) }

    /// A speech interval in samples, `[start, end)`.
    public struct Span: Codable, Sendable, Equatable {
        public var start: Int
        public var end: Int
        public init(start: Int, end: Int) { self.start = start; self.end = end }
        public var length: Int { end - start }
    }

    /// Voiced regions: 10 ms frames above `max(floorDB, loudestFrame − rangeDB)`,
    /// gaps shorter than `mergeGap` seconds bridged (stops and plosives inside words),
    /// islands shorter than `minSpan` seconds dropped (clicks).
    public static func speechSpans(_ x: [Float], sampleRate: Int, floorDB: Double = -55, rangeDB: Double = 38,
                                   mergeGap: Double = 0.2, minSpan: Double = 0.04) -> [Span] {
        let hop = max(1, sampleRate / 100)
        guard x.count >= hop else { return [] }
        var levels: [Double] = []
        var i = 0
        while i < x.count {
            levels.append(db(rms(x[i..<min(x.count, i + hop)])))
            i += hop
        }
        let threshold = max(floorDB, (levels.max() ?? floorDB) - rangeDB)
        var spans: [Span] = []
        var open: Int?
        for (k, l) in levels.enumerated() {
            if l > threshold {
                if open == nil { open = k }
            } else if let o = open {
                spans.append(Span(start: o * hop, end: min(x.count, k * hop)))
                open = nil
            }
        }
        if let o = open { spans.append(Span(start: o * hop, end: x.count)) }
        let gap = Int(mergeGap * Double(sampleRate))
        var merged: [Span] = []
        for s in spans {
            if let last = merged.last, s.start - last.end < gap {
                merged[merged.count - 1].end = s.end
            } else {
                merged.append(s)
            }
        }
        let minLen = Int(minSpan * Double(sampleRate))
        return merged.filter { $0.length >= minLen }
    }

    /// RMS over the voiced spans only (active speech level), dBFS.
    public static func activeLevelDB(_ x: [Float], sampleRate: Int) -> Double {
        let spans = speechSpans(x, sampleRate: sampleRate)
        var acc = 0.0, n = 0
        for s in spans { for v in x[s.start..<s.end] { acc += Double(v) * Double(v) }; n += s.length }
        guard n > 0 else { return db(rms(x)) }
        return db((acc / Double(n)).squareRoot())
    }

    public static func scaled(_ x: [Float], by g: Double) -> [Float] {
        var out = x
        var gf = Float(g)
        vDSP_vsmul(x, 1, &gf, &out, 1, vDSP_Length(x.count))
        return out
    }

    /// Scales to an active speech level of `targetDB`, then limits peaks to `ceilingDB`.
    public static func normalized(_ x: [Float], sampleRate: Int, targetDB: Double, ceilingDB: Double = -1) -> [Float] {
        let level = activeLevelDB(x, sampleRate: sampleRate)
        var y = scaled(x, by: linear(targetDB - level))
        let ceiling = linear(ceilingDB)
        let p = peak(y)
        if p > ceiling { y = scaled(y, by: ceiling / p) }
        return y
    }

    /// Linear-phase-free plain linear interpolation resampler (fixture prep only).
    public static func resampled(_ x: [Float], from: Int, to: Int) -> [Float] {
        guard from != to, !x.isEmpty else { return x }
        let n = Int((Double(x.count) * Double(to) / Double(from)).rounded())
        var out = [Float](repeating: 0, count: n)
        let step = Double(from) / Double(to)
        for i in 0..<n {
            let p = Double(i) * step
            let k = Int(p)
            let f = Float(p - Double(k))
            let a = x[min(k, x.count - 1)], b = x[min(k + 1, x.count - 1)]
            out[i] = a + (b - a) * f
        }
        return out
    }

    /// Full linear convolution (vDSP).
    public static func convolve(_ x: [Float], _ h: [Float]) -> [Float] {
        guard !x.isEmpty, !h.isEmpty else { return [] }
        let n = x.count + h.count - 1
        var padded = [Float](repeating: 0, count: n + h.count - 1)
        for (i, v) in x.enumerated() { padded[h.count - 1 + i] = v }
        var out = [Float](repeating: 0, count: n)
        let reversed = Array(h.reversed())
        vDSP_conv(padded, 1, reversed, 1, &out, 1, vDSP_Length(n), vDSP_Length(h.count))
        return out
    }

    /// 5 ms raised-cosine fades at both ends.
    public static func faded(_ x: [Float], sampleRate: Int, seconds: Double = 0.005) -> [Float] {
        var y = x
        let n = min(Int(seconds * Double(sampleRate)), x.count / 2)
        guard n > 0 else { return y }
        for i in 0..<n {
            let g = Float(0.5 - 0.5 * cos(Double.pi * Double(i) / Double(n)))
            y[i] *= g
            y[x.count - 1 - i] *= g
        }
        return y
    }
}

/// Deterministic RNG (SplitMix64) so synthesized beds are byte-stable.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform −1…1.
    public mutating func signed() -> Float { Float(Double(next() >> 11) / Double(1 << 53)) * 2 - 1 }
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// One-pole / biquad helpers for the synthesized beds.
public struct OnePole: Sendable {
    var a: Float
    var z: Float = 0
    public init(cutoff: Double, sampleRate: Int) { a = Float(exp(-2 * Double.pi * cutoff / Double(sampleRate))) }
    public mutating func lowpass(_ x: Float) -> Float { z = (1 - a) * x + a * z; return z }
}

public struct Biquad: Sendable {
    var b0, b1, b2, a1, a2: Float
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    /// RBJ band-pass (constant 0 dB peak gain).
    public static func bandpass(center: Double, q: Double, sampleRate: Int) -> Biquad {
        let w = 2 * Double.pi * center / Double(sampleRate)
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(b0: Float(alpha / a0), b1: 0, b2: Float(-alpha / a0),
                      a1: Float(-2 * cos(w) / a0), a2: Float((1 - alpha) / a0))
    }

    /// RBJ high-pass.
    public static func highpass(cutoff: Double, q: Double = 0.707, sampleRate: Int) -> Biquad {
        let w = 2 * Double.pi * cutoff / Double(sampleRate)
        let alpha = sin(w) / (2 * q), c = cos(w)
        let a0 = 1 + alpha
        return Biquad(b0: Float((1 + c) / 2 / a0), b1: Float(-(1 + c) / a0), b2: Float((1 + c) / 2 / a0),
                      a1: Float(-2 * c / a0), a2: Float((1 - alpha) / a0))
    }

    public mutating func process(_ x: Float) -> Float {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}
