import Foundation

/// 24 kHz → 16 kHz mono PCM16 (the analyzer's best format), streaming.
///
/// Windowed-sinc low-pass at 7.2 kHz evaluated at every 1.5th input sample (two
/// phases, 16 taps each). Tracks the 24 kHz frame of every output sample so the
/// analyzer's clock maps 1:1 onto capture frames; a gap in the input frames resets it.
public struct Downsampler24to16: Sendable {
    static let halfWidth = 8
    static let cutoff = 0.3   // cycles per input sample (7.2 kHz / 24 kHz)
    static let phases: [[Float]] = [0.0, 0.5].map { frac in
        (-(halfWidth - 1)...halfWidth).map { k -> Float in
            let x = Double(k) - frac
            let sinc = x == 0 ? 1 : sin(.pi * 2 * cutoff * x) / (.pi * 2 * cutoff * x)
            let w = 0.5 + 0.5 * cos(.pi * x / Double(halfWidth + 1))
            return Float(2 * cutoff * sinc * w)
        }
    }

    private var history: [Float] = []
    /// 24 kHz frame of `history[0]`.
    private var historyFrame: Int64 = 0
    /// Next output position, in input samples from `historyFrame` (multiple of 0.5).
    private var position: Double = 0
    private var expectedFrame: Int64?

    public init() {}

    /// Downsample one chunk. Returns the 16 kHz samples and the 24 kHz capture frame of
    /// the first one (nil when the chunk produced nothing yet).
    public mutating func process(_ pcm24k: [Int16], firstFrame24k: Int64) -> (samples: [Int16], firstFrame24k: Int64?) {
        if expectedFrame != firstFrame24k {
            history.removeAll()
            historyFrame = firstFrame24k
            position = 0
        }
        expectedFrame = firstFrame24k + Int64(pcm24k.count)
        history.append(contentsOf: pcm24k.map { Float($0) })
        var out: [Int16] = []
        var firstFrame: Int64?
        let hw = Self.halfWidth
        while Int(position.rounded(.down)) + hw < history.count {
            let base = Int(position.rounded(.down))
            let phase = position - Double(base) >= 0.25 ? 1 : 0
            let taps = Self.phases[phase]
            var acc: Float = 0
            for (j, k) in (-(hw - 1)...hw).enumerated() {
                let idx = base + k
                if idx >= 0 { acc += history[idx] * taps[j] }
            }
            if firstFrame == nil { firstFrame = historyFrame + Int64(position.rounded()) }
            out.append(Int16(max(-32768, min(32767, acc.rounded()))))
            position += 1.5
        }
        // Keep what the next outputs still need.
        let drop = max(0, Int(position.rounded(.down)) - hw)
        if drop > 0 {
            history.removeFirst(drop)
            historyFrame += Int64(drop)
            position -= Double(drop)
        }
        return (out, firstFrame)
    }
}
