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
final class BufferConverter {
    let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(target: AVAudioFormat) { self.target = target }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer.deepCopy() }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
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
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}
