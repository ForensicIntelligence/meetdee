import Foundation

/// Synthetic audio for tests.
enum Signal {
    static func sine(hz: Double, amplitude: Double = 0.5, sampleRate: Double = 16_000, seconds: Double) -> [Float] {
        let n = Int(sampleRate * seconds)
        return (0..<n).map { Float(amplitude * sin(2 * .pi * hz * Double($0) / sampleRate)) }
    }

    /// A sawtooth-ish harmonic tone (voice-like: strong harmonics, weak fundamental).
    static func harmonic(hz: Double, amplitude: Double = 0.4, sampleRate: Double = 16_000, seconds: Double) -> [Float] {
        let n = Int(sampleRate * seconds)
        return (0..<n).map { i in
            var v = 0.0
            for h in 1...6 { v += sin(2 * .pi * hz * Double(h) * Double(i) / sampleRate) / Double(h) }
            return Float(amplitude * v / 2)
        }
    }

    /// A tone whose pitch glides linearly from `from` to `to` Hz.
    static func glide(from: Double, to: Double, amplitude: Double = 0.5, sampleRate: Double = 16_000, seconds: Double) -> [Float] {
        let n = Int(sampleRate * seconds)
        var phase = 0.0
        return (0..<n).map { i in
            let f = from + (to - from) * Double(i) / Double(max(n - 1, 1))
            phase += 2 * .pi * f / sampleRate
            return Float(amplitude * sin(phase))
        }
    }

    /// Deterministic white noise.
    static func noise(amplitude: Double, count: Int, seed: UInt64 = 42) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let u = Double(state >> 11) / Double(1 << 53)
            return Float(amplitude * (u * 2 - 1))
        }
    }

    static func frames(_ x: [Float], size: Int) -> [[Float]] {
        stride(from: 0, to: x.count - size + 1, by: size).map { Array(x[$0..<($0 + size)]) }
    }
}
