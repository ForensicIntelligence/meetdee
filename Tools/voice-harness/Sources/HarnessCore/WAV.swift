import Foundation

/// Mono PCM16 RIFF/WAVE files, which is all the harness stores (24 kHz).
public enum WAV {
    public enum Failure: Error, CustomStringConvertible {
        case notWave(String)
        case unsupported(String)

        public var description: String {
            switch self {
            case .notWave(let m): "not a WAVE file: \(m)"
            case .unsupported(let m): "unsupported WAVE: \(m)"
            }
        }
    }

    public struct Audio: Sendable, Equatable {
        public var sampleRate: Int
        /// −1…1.
        public var samples: [Float]

        public init(sampleRate: Int, samples: [Float]) {
            self.sampleRate = sampleRate
            self.samples = samples
        }

        public var duration: Double { Double(samples.count) / Double(max(sampleRate, 1)) }
    }

    /// PCM16 little-endian mono WAV bytes (samples clipped to −1…1).
    public static func encode(_ samples: [Float], sampleRate: Int) -> Data {
        var d = Data()
        let dataBytes = samples.count * 2
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        d.append(pcm16(samples))
        return d
    }

    /// Raw PCM16 LE (no header).
    public static func pcm16(_ samples: [Float]) -> Data {
        var out = Data(count: samples.count * 2)
        out.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for (i, s) in samples.enumerated() {
                let v = max(-1, min(1, s))
                p[i] = Int16(clamping: Int((v * 32767).rounded())).littleEndian
            }
        }
        return out
    }

    /// Decodes raw PCM16 LE.
    public static func floats(pcm16 data: Data) -> [Float] {
        let n = data.count / 2
        var out = [Float](repeating: 0, count: n)
        data.withUnsafeBytes { raw in
            for i in 0..<n {
                let lo = UInt16(raw[2 * i]), hi = UInt16(raw[2 * i + 1])
                out[i] = Float(Int16(bitPattern: lo | (hi << 8))) / 32768
            }
        }
        return out
    }

    public static func write(_ samples: [Float], sampleRate: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(samples, sampleRate: sampleRate).write(to: url, options: .atomic)
    }

    public static func read(_ url: URL) throws -> Audio {
        try decode(Data(contentsOf: url), name: url.lastPathComponent)
    }

    /// Reads RIFF chunks; PCM16 (mono, or the first channel of several).
    public static func decode(_ d: Data, name: String = "") throws -> Audio {
        let b = [UInt8](d)
        guard b.count >= 12, String(decoding: b[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: b[8..<12], as: UTF8.self) == "WAVE" else { throw Failure.notWave(name) }
        func u32(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        var i = 12
        var rate = 0, channels = 0, bits = 0, format = 0
        while i + 8 <= b.count {
            let id = String(decoding: b[i..<i + 4], as: UTF8.self)
            let size = u32(i + 4)
            let body = i + 8
            if id == "fmt " {
                format = u16(body); channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
            } else if id == "data" {
                guard format == 1 || format == 0xFFFE, bits == 16, channels >= 1 else {
                    throw Failure.unsupported("\(name) format \(format) bits \(bits) channels \(channels)")
                }
                let end = min(b.count, body + size)
                let frames = (end - body) / (2 * channels)
                var out = [Float](repeating: 0, count: frames)
                for f in 0..<frames {
                    let k = body + f * 2 * channels
                    out[f] = Float(Int16(bitPattern: UInt16(b[k]) | UInt16(b[k + 1]) << 8)) / 32768
                }
                return Audio(sampleRate: rate, samples: out)
            }
            i = body + size + (size & 1)
        }
        throw Failure.notWave("\(name): no data chunk")
    }
}
