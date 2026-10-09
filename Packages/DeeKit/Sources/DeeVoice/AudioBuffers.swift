import AVFAudio
import Foundation

/// Carries a non-Sendable value across a queue hop the caller has made safe.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

extension AVAudioPCMBuffer {
    /// An independent copy (tap and synthesizer buffers may be reused after the callback).
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frameLength, 1)) else { return nil }
        copy.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let sp = s.mData, let dp = d.mData else { continue }
            memcpy(dp, sp, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return copy
    }

    /// Channel 0 as Float samples, whatever the PCM sample format.
    func firstChannelSamples() -> [Float] {
        let n = Int(frameLength)
        guard n > 0 else { return [] }
        let stride = format.isInterleaved ? Int(format.channelCount) : 1
        if let ch = floatChannelData {
            let p = ch[0]
            if stride == 1 { return Array(UnsafeBufferPointer(start: p, count: n)) }
            return (0..<n).map { p[$0 * stride] }
        }
        if let ch = int16ChannelData {
            let p = ch[0]
            return (0..<n).map { Float(p[$0 * stride]) / 32768 }
        }
        if let ch = int32ChannelData {
            let p = ch[0]
            return (0..<n).map { Float(p[$0 * stride]) / 2_147_483_648 }
        }
        return []
    }
}

/// Converts PCM buffers to one target format, rebuilding the converter if the
/// source format changes (route changes can do that).
///
/// A sample-rate converter keeps the last few milliseconds of every stream in its
/// filter. For continuous streams (the microphone) that is fine; for a stream that
/// ends (one TTS sentence) call `finish()` to drain that tail and reset the
/// converter, or it plays at the start of the next stream (audit C13).
final class BufferConverter {
    let target: AVAudioFormat
    private var converter: AVAudioConverter?
    /// Input was converted since the last `finish()` / `reset()`: the filter may hold a tail.
    private var primed = false

    init(target: AVAudioFormat) { self.target = target }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer.deepCopy() }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
            primed = false
        }
        guard let converter, buffer.frameLength > 0 else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        primed = true
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }

    /// End of stream: returns what the converter still holds of this stream (nil if
    /// nothing) and resets it, so the next stream starts clean.
    func finish() -> AVAudioPCMBuffer? {
        guard let converter, primed else { return nil }
        primed = false
        defer { converter.reset() }
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192) else { return nil }
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }

    /// Drops whatever the converter holds (playback was stopped mid-stream).
    func reset() {
        converter?.reset()
        primed = false
    }
}

/// Raw 16-bit little-endian mono PCM, the realtime API's `audio/pcm` payload.
enum PCM16 {
    /// Channel 0 of `buffer` as Int16 LE bytes (the buffer must already be at the wanted rate).
    static func data(from buffer: AVAudioPCMBuffer) -> Data {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return Data() }
        if let ch = buffer.int16ChannelData, buffer.format.channelCount == 1 || !buffer.format.isInterleaved {
            return Data(bytes: ch[0], count: n * 2)
        }
        var out = [Int16](repeating: 0, count: n)
        let s = buffer.firstChannelSamples()
        for i in 0..<min(n, s.count) { out[i] = int16(s[i]) }
        return out.withUnsafeBytes { Data($0) }
    }

    static func int16(_ x: Float) -> Int16 {
        guard x.isFinite else { return 0 }
        return Int16(max(-32768, min(32767, (x * 32768).rounded())))
    }

    /// Samples of `data` (an odd trailing byte is ignored).
    static func samples(_ data: Data) -> [Int16] {
        let n = data.count / 2
        var out = [Int16](repeating: 0, count: n)
        out.withUnsafeMutableBytes { dst in _ = data.copyBytes(to: dst, count: n * 2) }
        return out
    }
}
