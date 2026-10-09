import AVFAudio
import Foundation
import Synchronization

/// The microphone as 24 kHz mono PCM16 — what the realtime API's
/// `input_audio_buffer.append` takes — with the last 2 s always kept, so the first
/// words reach the server even when they were spoken before the socket was up.
///
/// Fed from the `AudioGraph` mic tap (in order, one thread at a time). While
/// `isEnabled` is false nothing is converted or kept. `open(preroll:)` returns a
/// stream that starts with up to `preroll` seconds of what was already captured
/// and continues with live audio, with no gap and no overlap.
///
/// Every chunk carries its position on the capture timeline (`startFrame`, 24 kHz
/// frames since capture was enabled) and the host time of its first sample (from
/// the mic tap's input timestamp; the 48→24 kHz resampler adds ≈ 8 ms on top), so
/// server offsets (`audio_start_ms`) can be mapped back to local prosody.
///
/// Nothing is ever dropped between `open` and the consumer: the stream buffers
/// without bound (48 KB per second of backlog), because a silent gap would shift
/// every later server offset. A consumer that falls hopelessly behind should
/// `close()` and reopen (the chunks' `startFrame` shows the jump).
public final class PCM16Capture: @unchecked Sendable {
    public static let sampleRate = 24_000.0
    public static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    /// Seconds of audio always kept for `open(preroll:)`.
    public static let prerollCapacity = 2.0

    public struct Chunk: Sendable, Equatable {
        /// Int16 LE mono samples at 24 kHz.
        public var data: Data
        /// Position of the first sample on the capture timeline (24 kHz frames).
        public var startFrame: Int64
        /// Host seconds (`systemUptime`) of the first sample.
        public var hostTime: Double

        public var frames: Int { data.count / 2 }
        public var durationMs: Double { Double(frames) * 1000 / PCM16Capture.sampleRate }
    }

    private struct State {
        var enabled = false
        var ring: [Int16]
        var ringHead = 0          // next write index
        var ringCount = 0
        var captured: Int64 = 0   // frames since enabled
        /// Host time of the most recent sample and its frame position.
        var lastHost = 0.0
        var lastFrame: Int64 = 0
        var continuation: AsyncStream<Chunk>.Continuation?
    }

    private let state: Mutex<State>
    /// Tap-thread only (serialized by the graph's funnel); rebuilds itself when a
    /// route change changes the input format.
    private let converter = BufferConverter(target: PCM16Capture.format)
    private let ringCapacity = Int(PCM16Capture.sampleRate * PCM16Capture.prerollCapacity)

    public init() {
        state = Mutex(State(ring: [Int16](repeating: 0, count: Int(PCM16Capture.sampleRate * PCM16Capture.prerollCapacity))))
    }

    /// Convert and keep microphone audio. Turning it off clears the pre-roll and
    /// ends an open stream.
    public var isEnabled: Bool {
        get { state.withLock { $0.enabled } }
        set {
            let ended = state.withLock { s -> AsyncStream<Chunk>.Continuation? in
                guard s.enabled != newValue else { return nil }
                s.enabled = newValue
                s.ringCount = 0
                s.ringHead = 0
                s.captured = 0
                guard !newValue else { return nil }
                defer { s.continuation = nil }
                return s.continuation
            }
            ended?.finish()
        }
    }

    /// 24 kHz frames captured since enabled (the capture timeline's "now").
    public var capturedFrames: Int64 { state.withLock { $0.captured } }

    /// Host time at which capture-timeline frame `frame` was (or will be) spoken,
    /// extrapolated from the latest chunk.
    public func hostTime(ofFrame frame: Int64) -> Double {
        state.withLock { s in s.lastHost + Double(frame - s.lastFrame) / Self.sampleRate }
    }

    /// The most recent `seconds` of audio (≤ 2 s) without opening a stream.
    public func preroll(seconds: Double = PCM16Capture.prerollCapacity) -> Chunk {
        state.withLock { s in prerollChunk(&s, seconds: seconds) }
    }

    /// Starts delivering audio: first up to `preroll` seconds already captured,
    /// then every new chunk. One consumer at a time: opening again ends the
    /// previous stream. The stream ends on `close()` or when capture is disabled.
    public func open(preroll seconds: Double = PCM16Capture.prerollCapacity) -> AsyncStream<Chunk> {
        let (stream, continuation) = AsyncStream<Chunk>.makeStream(bufferingPolicy: .unbounded)
        let old = state.withLock { s -> AsyncStream<Chunk>.Continuation? in
            let old = s.continuation
            let first = prerollChunk(&s, seconds: seconds)
            if !first.data.isEmpty { continuation.yield(first) }
            s.continuation = continuation
            return old
        }
        old?.finish()
        return stream
    }

    /// Like `open(preroll:)`, but the pre-roll starts at capture-timeline frame
    /// `frame` (clamped to what is still kept and to at most `maxPreroll` seconds
    /// back): resuming a stream after a pause or a reconnect with exactly the audio
    /// that was never sent, no duplicates.
    public func open(from frame: Int64, maxPreroll seconds: Double = PCM16Capture.prerollCapacity) -> AsyncStream<Chunk> {
        let (stream, continuation) = AsyncStream<Chunk>.makeStream(bufferingPolicy: .unbounded)
        let old = state.withLock { s -> AsyncStream<Chunk>.Continuation? in
            let old = s.continuation
            let back = max(0, s.captured - frame)
            let cap = Int64(max(0, seconds) * Self.sampleRate)
            let first = prerollChunk(&s, frames: Int(min(back, cap)))
            if !first.data.isEmpty { continuation.yield(first) }
            s.continuation = continuation
            return old
        }
        old?.finish()
        return stream
    }

    /// Ends the open stream (capture and the pre-roll keep running).
    public func close() {
        let c = state.withLock { s -> AsyncStream<Chunk>.Continuation? in
            defer { s.continuation = nil }
            return s.continuation
        }
        c?.finish()
    }

    /// Mic tap (in order, one thread at a time). `t`: host time of the buffer's last
    /// sample.
    func consume(_ buffer: AVAudioPCMBuffer, at t: Double) {
        guard state.withLock({ $0.enabled }) else { return }
        guard let converted = converter.convert(buffer), converted.frameLength > 0 else { return }
        let data = PCM16.data(from: converted)
        let samples = PCM16.samples(data)
        let inputDuration = Double(buffer.frameLength) / max(buffer.format.sampleRate, 1)
        let c = state.withLock { s -> (AsyncStream<Chunk>.Continuation, Chunk)? in
            guard s.enabled else { return nil }
            let chunk = Chunk(data: data, startFrame: s.captured, hostTime: t - inputDuration)
            for v in samples {
                s.ring[s.ringHead] = v
                s.ringHead = (s.ringHead + 1) % ringCapacity
            }
            s.ringCount = min(s.ringCount + samples.count, ringCapacity)
            s.captured += Int64(samples.count)
            s.lastHost = t
            s.lastFrame = s.captured
            guard let cont = s.continuation else { return nil }
            return (cont, chunk)
        }
        if let (cont, chunk) = c { cont.yield(chunk) }
    }

    private func prerollChunk(_ s: inout State, seconds: Double) -> Chunk {
        prerollChunk(&s, frames: Int(max(0, seconds) * Self.sampleRate))
    }

    private func prerollChunk(_ s: inout State, frames: Int) -> Chunk {
        let want = min(s.ringCount, max(0, frames))
        var out = [Int16](repeating: 0, count: want)
        var idx = (s.ringHead - want + ringCapacity) % ringCapacity
        for i in 0..<want {
            out[i] = s.ring[idx]
            idx = (idx + 1) % ringCapacity
        }
        let start = s.captured - Int64(want)
        let host = s.lastHost - Double(s.lastFrame - start) / Self.sampleRate
        return Chunk(data: out.withUnsafeBytes { Data($0) }, startFrame: start, hostTime: host)
    }
}
