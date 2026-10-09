import Accelerate
import Foundation

/// Synthetic echo: Dee's own played output fed back into the microphone, delayed,
/// through a room impulse response, at `gainDB` (applied to the direct path).
/// Models the residual echo when voice-processing AEC is weak or off (§7.4).
public struct EchoConfig: Codable, Sendable, Equatable {
    public var gainDB: Double
    public var delayMs: Double
    /// Convolve with the room impulse response (else a pure delayed copy).
    public var reverb: Bool

    public init(gainDB: Double, delayMs: Double, reverb: Bool = true) {
        self.gainDB = gainDB; self.delayMs = delayMs; self.reverb = reverb
    }
}

/// What the harness's "microphone" hears, block by block:
///
///     mic = Σ scheduled fixtures  +  room bed (looped, at the scenario's SNR)
///         + echo(Dee's rendered output)
///
/// Fixtures are placed sample-exactly on an absolute frame clock (the same clock as
/// the manual AudioGraph's render position), so ground-truth onsets and ends of
/// speech convert to harness times exactly. Not thread-safe: the runner owns it
/// behind a lock.
public final class MicMixer {
    public let sampleRate: Int
    /// Reference active speech level used to turn an SNR into a bed gain (dBFS).
    public var referenceSpeechDB: Double = -24

    /// The next frame `next(_:)` will produce.
    public private(set) var frame: Int = 0

    private struct Source {
        var id: String
        var start: Int
        var samples: [Float]
        var end: Int { start + samples.count }
    }
    private var sources: [Source] = []

    private var bed: [Float] = []
    private var bedGain: Float = 0
    private var bedPos = 0

    private var echo: EchoConfig?
    private var ir: [Float] = [1]
    private var irReversed: [Float] = [1]
    private var echoGain: Float = 0
    private var delayFrames = 0
    /// Dee's output history: `history[i]` is the output at frame `historyBase + i`.
    private var history: [Float] = []
    private var historyBase = 0

    public init(sampleRate: Int = 24_000) { self.sampleRate = sampleRate }

    // MARK: Configuration

    /// A looped room bed at `snrDB` below the reference speech level (nil = silence).
    public func setBed(_ samples: [Float]?, snrDB: Double) {
        guard let samples, !samples.isEmpty else { bed = []; bedGain = 0; return }
        bed = samples
        let level = DSP.db(DSP.rms(samples))
        bedGain = Float(DSP.linear(referenceSpeechDB - snrDB - level))
        bedPos = 0
    }

    /// The bed's effective level after gain (dBFS), for the report.
    public var bedLevelDB: Double? { bed.isEmpty ? nil : DSP.db(DSP.rms(bed)) + DSP.db(Double(bedGain)) }

    /// Echo on (`config`) or off (nil). `impulse`: room IR used when `config.reverb`.
    public func setEcho(_ config: EchoConfig?, impulse: [Float]? = nil) {
        echo = config
        guard let config else { echoGain = 0; return }
        echoGain = Float(DSP.linear(config.gainDB))
        delayFrames = max(0, Int((config.delayMs / 1000 * Double(sampleRate)).rounded()))
        ir = (config.reverb ? impulse : nil) ?? [1]
        if ir.isEmpty { ir = [1] }
        irReversed = Array(ir.reversed())
    }

    public var echoConfig: EchoConfig? { echo }

    // MARK: Fixtures

    /// Places `samples` starting at `frame` (absolute); returns that frame.
    @discardableResult
    public func schedule(_ samples: [Float], id: String, at start: Int) -> Int {
        sources.append(Source(id: id, start: max(start, frame), samples: samples))
        return max(start, frame)
    }

    /// Plays `samples` from the next block on (after any fixture still playing).
    @discardableResult
    public func play(_ samples: [Float], id: String) -> Int {
        let after = sources.map(\.end).max() ?? frame
        return schedule(samples, id: id, at: max(frame, after))
    }

    /// Plays at the next block even if another fixture is still sounding (overlap).
    @discardableResult
    public func playNow(_ samples: [Float], id: String) -> Int { schedule(samples, id: id, at: frame) }

    /// A fixture is scheduled or sounding.
    public var fixtureActive: Bool { sources.contains { $0.end > frame } }

    /// Frame where the last scheduled fixture ends.
    public var fixturesEnd: Int { sources.map(\.end).max() ?? frame }

    // MARK: Blocks

    /// Dee's rendered output for frames `[frame, frame + block.count)`. Call before
    /// `next` for the same block (the echo may use it when the delay is shorter than
    /// a block).
    public func pushOutput(_ block: [Float]) {
        let expectedEnd = historyBase + history.count
        if expectedEnd < frame { history += [Float](repeating: 0, count: frame - expectedEnd) }
        history += block
        // Keep what the echo can still reach.
        let keep = delayFrames + ir.count + 4 * max(block.count, 1)
        if history.count > keep * 2 {
            let drop = history.count - keep
            history.removeFirst(drop)
            historyBase += drop
        }
    }

    /// The next `count` microphone frames, plus the clean user-speech part alone.
    public func next(_ count: Int) -> (mic: [Float], speech: [Float]) {
        var speech = [Float](repeating: 0, count: count)
        let a = frame, b = frame + count
        for s in sources where s.end > a && s.start < b {
            let from = max(a, s.start), to = min(b, s.end)
            for f in from..<to { speech[f - a] += s.samples[f - s.start] }
        }
        sources.removeAll { $0.end <= b }
        var mic = speech
        if !bed.isEmpty {
            for i in 0..<count {
                mic[i] += bedGain * bed[bedPos]
                bedPos += 1
                if bedPos >= bed.count { bedPos = 0 }
            }
        }
        if echo != nil, echoGain > 0 {
            let e = echoBlock(start: a, count: count)
            for i in 0..<count { mic[i] += e[i] }
        }
        for i in 0..<count { mic[i] = max(-1, min(1, mic[i])) }
        frame = b
        return (mic, speech)
    }

    /// echo[n] = g · Σₖ h[k] · out[n − D − k] for n in [start, start+count).
    func echoBlock(start: Int, count: Int) -> [Float] {
        let L = ir.count
        let from = start - delayFrames - (L - 1)
        let n = count + L - 1
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let idx = from + i - historyBase
            if idx >= 0 && idx < history.count { x[i] = history[idx] }
        }
        var y = [Float](repeating: 0, count: count)
        if L == 1 {
            for i in 0..<count { y[i] = x[i] * ir[0] }
        } else {
            vDSP_conv(x, 1, irReversed, 1, &y, 1, vDSP_Length(count), vDSP_Length(L))
        }
        var g = echoGain
        vDSP_vsmul(y, 1, &g, &y, 1, vDSP_Length(count))
        return y
    }
}
