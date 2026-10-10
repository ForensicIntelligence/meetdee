import Foundation

/// Echo-reference gating: what of the microphone Dee's own playback explains.
///
/// The player reports the energy of every 10 ms of audio it rendered (`Bin`, on
/// the graph clock, silence included); the microphone is fed in 10 ms bins too.
/// From the two envelopes this model learns the echo path:
///
/// - **Delay.** Every `learnEvery` mic bins, over the last `window`, it searches
///   lags of `minLag`…`maxLag` (plus the route's output latency) for the best
///   correlation between her (reverb-smeared) envelope and the mic's excess over
///   the noise floor. A clear match (`confident`) sets the delay.
/// - **Gain.** With a clear match, the median mic/reference ratio at that delay
///   (blended in dB). Without one (the echo is lost in the room, or the user talks
///   over her), the first estimate is a high percentile of the same ratio, so a
///   room where her echo never shows learns "echo ≈ nothing" and a noisy room with
///   a faint echo still errs on the safe side. Later, a low-correlation window may
///   only *lower* a known gain, and only when the echo clearly vanished (≥ 10 dB):
///   double talk never talks the model into a smaller echo.
///
/// `predicted(at:)` is the echo energy expected in the mic bin ending at `t`:
/// gain × her smeared envelope at the learned delay (± `jitter`), or over the whole
/// lag range before a delay is known. Before a gain is learned, `prior` (0 dB)
/// stands in: in her first moments everything she could explain counts as her. An onset whose energy this explains is her playback; the
/// user's voice over her shows up as energy well above it.
public struct EchoReference: Sendable {
    /// One bin of her rendered output: mean square over `EchoReference.bin`
    /// seconds ending at `t` (graph clock, render time).
    public struct Bin: Sendable, Equatable {
        public var t: Double
        public var energy: Double
        /// The bin's rendered samples (24 kHz; empty when not kept), for the
        /// per-band echo model (`SpectralEcho`).
        public var samples: [Float]
        public init(t: Double, energy: Double, samples: [Float] = []) {
            self.t = t
            self.energy = energy
            self.samples = samples
        }
    }

    public static let bin = 0.01
    public static let minLag = 0.02
    public static let maxLag = 0.20
    /// Bins searched around the delay when predicting (render / capture jitter).
    static let jitterBins = 2
    /// Her room reverb: the smeared envelope decays this much per bin (≈ RT60 0.4 s).
    static let reverbDecayDBPerBin = 1.5
    /// Learning window (bins).
    static let windowBins = 150
    static let learnEvery = 3
    /// Her output counts as "speaking" at this level (dBFS mean square).
    static let activeDB = -50.0
    /// Bins of her speaking a learning window needs.
    static let minActiveBins = 15
    /// Correlation that counts as a clear echo match.
    public static let confidentCorrelation = 0.6
    static let gainBlend = 0.3
    /// Percentile of mic / reference taken as her echo gain with a clear match: her
    /// room reverb makes the ratio swing; the gain must cover its peaks.
    static let confidentPercentile = 0.5
    /// Percentile of the ratio taken when the echo isn't clearly visible.
    static let uncertainPercentile = 0.75
    /// A low-correlation window may lower a known gain only when it is this much smaller.
    static let vanishDB = 10.0
    /// Without a clear match, a first estimate is at most this (dB).
    static let uncorrelatedCeilingDB = -20.0

    private static let capacity = 512
    private var ref = [Double](repeating: 0, count: EchoReference.capacity)
    private var refLast: Int64?
    private var smear = 0.0
    private var lastRefTime = -Double.infinity

    private var mic = [Double](repeating: 0, count: EchoReference.capacity)
    /// The mic's excess over the floor in bins her voice can't reach (the room
    /// wobbling on its own), for `idleExcess`.
    private var idle = [Double](repeating: 0, count: EchoReference.idleBins)
    private var idleHead = 0
    private var idleCount = 0
    static let idleBins = 300
    static let idlePercentile = 0.9

    /// The room's typical excess over its floor with her out of the room (energy):
    /// subtracted before an uncorrelated echo estimate.
    var idleExcess: Double {
        guard idleCount >= 50 else { return 0 }
        let sorted = idle.prefix(idleCount).sorted()
        return sorted[Int(Double(sorted.count - 1) * Self.idlePercentile)]
    }
    private var micLast: Int64?
    private var sinceLearn = 0

    /// Extra delay of the route (s): the lag range is extended by it.
    public var outputLatency = 0.0

    /// Learned delay (s) from render to the mic; nil until a clear match.
    public private(set) var delay: Double?
    /// Learned echo gain (energy ratio, mic / rendered); nil until learned.
    public private(set) var gain: Double?
    /// Correlation of the last learning pass.
    public private(set) var correlation = 0.0
    /// The last learning pass found a clear match.
    public private(set) var confident = false

    public init() {}

    /// Forget everything learned (the route or echo cancellation changed).
    public mutating func reset() {
        let (latency, prior) = (outputLatency, self.prior)
        self = EchoReference()
        outputLatency = latency
        self.prior = prior
    }

    /// Reference arrived recently (her player is rendering).
    public func hasReference(at t: Double) -> Bool { t - lastRefTime < 1.0 }

    /// The learned gain in dB (nil until learned).
    public var gainDB: Double? { gain.map { Level.powerDB($0) } }

    // MARK: Input

    public mutating func addReference(_ bins: [Bin]) {
        for b in bins { addReference(energy: b.energy, at: b.t) }
    }

    public mutating func addReference(energy: Double, at t: Double) {
        guard t.isFinite else { return }
        let i = Self.index(t)
        let e = energy.isFinite ? max(energy, 0) : 0
        lastRefTime = max(lastRefTime, t)
        let decay = pow(10, -Self.reverbDecayDBPerBin / 10)
        if let last = refLast {
            if i <= last {
                // Late or duplicate bin: fold it in where it belongs.
                guard last - i < Int64(Self.capacity) else { return }
                let k = slot(i)
                ref[k] = max(ref[k], e)
                return
            }
            var j = last + 1
            if i - last > Int64(Self.capacity) { j = i - Int64(Self.capacity) + 1; smear = 0 }
            while j < i {
                smear *= decay
                ref[slot(j)] = smear
                j += 1
            }
        }
        smear = max(e, smear * decay)
        ref[slot(i)] = smear
        refLast = i
    }

    /// One mic bin ending at `t`: `energy` mean square, `floor` the room's noise
    /// energy (mean square) now.
    public mutating func addMic(energy: Double, floor: Double, at t: Double) {
        guard t.isFinite else { return }
        let i = Self.index(t)
        let excess = max((energy.isFinite ? energy : 0) - max(floor, 0), 0)
        if let last = micLast {
            guard i > last else {
                if last - i < Int64(Self.capacity) { mic[slot(i)] = excess }
                return
            }
            var j = last + 1
            if i - last > Int64(Self.capacity) { j = i - Int64(Self.capacity) + 1 }
            while j < i { mic[slot(j)] = 0; j += 1 }
        }
        mic[slot(i)] = excess
        micLast = i
        // Her envelope can't reach this bin (nothing of hers in the whole lag
        // range): the room's own excess over its floor.
        if reach(i) < pow(10, Self.activeDB / 10) * 0.01 {
            idle[idleHead] = excess
            idleHead = (idleHead + 1) % Self.idleBins
            idleCount = min(idleCount + 1, Self.idleBins)
        }
        sinceLearn += 1
        if sinceLearn >= Self.learnEvery {
            sinceLearn = 0
            learn(at: i)
        }
    }

    // MARK: Prediction

    /// Echo gain assumed before one is learned (energy ratio; 0 dB: her echo may
    /// be as loud as she is). Only her very first moments ever use it.
    public var prior: Double? = 1.0

    /// Expected echo energy in the mic bin ending at `t` (nil: not learned and no prior).
    public func predicted(at t: Double) -> Double? {
        guard let gain = gain ?? prior else { return nil }
        return gain * reach(Self.index(t))
    }

    /// Mean expected echo energy over the mic bins ending in `(from, to]`.
    public func predicted(from a: Double, to b: Double) -> Double? {
        guard let gain = gain ?? prior else { return nil }
        return gain * reach(from: a, to: b)
    }

    /// Her smeared envelope that can reach the mic bins ending in `(from, to]`
    /// (mean energy, before the echo gain): what any gain, learned later,
    /// multiplies.
    public func reach(from a: Double, to b: Double) -> Double {
        let lo = Self.index(a) + 1, hi = Self.index(b)
        guard hi >= lo else { return reach(hi) }
        var sum = 0.0
        for i in lo...hi { sum += reach(i) }
        return sum / Double(hi - lo + 1)
    }

    /// Her smeared envelope that can reach mic bin `i`: max over the lag window.
    private func reach(_ i: Int64) -> Double {
        let (lo, hi): (Int64, Int64)
        if let delay {
            let d = Int64((delay / Self.bin).rounded())
            lo = d - Int64(Self.jitterBins)
            hi = d + Int64(Self.jitterBins)
        } else {
            lo = minLagBins - Int64(Self.jitterBins)
            hi = maxLagBins + Int64(Self.jitterBins)
        }
        var m = 0.0
        var lag = max(lo, 0)
        while lag <= hi {
            m = max(m, refValue(i - lag))
            lag += 1
        }
        return m
    }

    // MARK: Learning

    private var minLagBins: Int64 { Int64((Self.minLag / Self.bin).rounded()) }
    private var maxLagBins: Int64 { Int64(((Self.maxLag + max(outputLatency, 0)) / Self.bin).rounded()) }

    private mutating func learn(at newest: Int64) {
        let first = newest - Int64(Self.windowBins) + 1
        let active = pow(10, Self.activeDB / 10)
        var best: (lag: Int64, rho: Double) = (minLagBins, -1)
        var lag = minLagBins
        var anyActive = false
        while lag <= maxLagBins {
            // Correlation inside her speech only: an echo follows her syllables;
            // someone who merely starts talking when she does doesn't.
            var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0
            var count = 0
            for i in first...newest {
                let a = refValue(i - lag)
                guard a >= active else { continue }
                count += 1
                let x = a.squareRoot(), y = micValue(i).squareRoot()
                sx += x; sy += y; sxx += x * x; syy += y * y; sxy += x * y
            }
            if count >= Self.minActiveBins {
                anyActive = true
                let fn = Double(count)
                let vx = sxx - sx * sx / fn, vy = syy - sy * sy / fn
                let rho = vx > 1e-18 && vy > 1e-18 ? (sxy - sx * sy / fn) / (vx * vy).squareRoot() : 0
                if rho > best.rho { best = (lag, rho) }
            }
            lag += 1
        }
        guard anyActive else { return }
        correlation = best.rho
        confident = best.rho >= Self.confidentCorrelation
        if confident {
            delay = Double(best.lag) * Self.bin
            guard let g = ratio(window: first...newest, lag: best.lag, percentile: Self.confidentPercentile) else { return }
            if let old = gain, old > 0, g > 0, g < old {
                // Louder at once (never under-predict her), quieter slowly.
                gain = pow(10, (Level.powerDB(old) * (1 - Self.gainBlend) + Level.powerDB(g) * Self.gainBlend) / 10)
            } else {
                gain = g
            }
        } else {
            // A first estimate only once her audio has been playing long enough for
            // an echo at any delay in range to have arrived.
            if gain == nil {
                var covered = 0
                for i in first...newest where refValue(i - maxLagBins - Int64(Self.jitterBins)) >= active { covered += 1 }
                guard covered >= Self.minActiveBins else { return }
            }
            let lagForRatio = delay.map { Int64(($0 / Self.bin).rounded()) } ?? best.lag
            // The room alone wobbles above its floor too (a fan's beat, a TV): what
            // the mic shows with her out of the room is not her echo.
            guard let g = ratio(window: first...newest, lag: lagForRatio, percentile: Self.uncertainPercentile, jitter: true,
                                minus: idleExcess) else { return }
            if let old = gain {
                if g < old * pow(10, -Self.vanishDB / 10) {
                    gain = pow(10, (Level.powerDB(max(old, 1e-16)) * (1 - Self.gainBlend) + Level.powerDB(max(g, 1e-16)) * Self.gainBlend) / 10)
                }
            } else {
                // A loud echo would correlate with her: a loud, uncorrelated mic is
                // the user (or the room), so a first estimate without a match is
                // capped — her echo is at most this, or it would have shown.
                gain = min(g, pow(10, Self.uncorrelatedCeilingDB / 10))
            }
        }
    }

    /// Percentile of mic / reference over the window's bins where she clearly spoke.
    private func ratio(window: ClosedRange<Int64>, lag: Int64, percentile: Double, jitter: Bool = false,
                       minus idle: Double = 0) -> Double? {
        let active = pow(10, Self.activeDB / 10)
        var peak = 0.0
        for i in window { peak = max(peak, refValue(i - lag)) }
        let bar = max(active, peak * 0.1)
        var ratios: [Double] = []
        ratios.reserveCapacity(window.count)
        for i in window {
            var a = refValue(i - lag)
            if jitter {
                for d in 1...Int64(Self.jitterBins) { a = max(a, refValue(i - lag - d), refValue(i - lag + d)) }
            }
            guard a >= bar else { continue }
            ratios.append(max(micValue(i) - idle, 0) / a)
        }
        guard ratios.count >= Self.minActiveBins / 2 else { return nil }
        ratios.sort()
        let k = min(ratios.count - 1, max(0, Int((Double(ratios.count - 1) * percentile).rounded())))
        return ratios[k]
    }

    // MARK: Storage

    static func index(_ t: Double) -> Int64 { Int64((t / bin).rounded()) }

    private func slot(_ i: Int64) -> Int {
        let c = Int64(Self.capacity)
        return Int(((i % c) + c) % c)
    }

    private func refValue(_ i: Int64) -> Double {
        guard let last = refLast, i <= last, last - i < Int64(Self.capacity) else {
            // After her last bin: her envelope keeps decaying.
            if let last = refLast, i > last, i - last < Int64(Self.capacity) {
                return smear * pow(10, -Self.reverbDecayDBPerBin * Double(i - last) / 10)
            }
            return 0
        }
        return ref[slot(i)]
    }

    private func micValue(_ i: Int64) -> Double {
        guard let last = micLast, i <= last, last - i < Int64(Self.capacity) else { return 0 }
        return mic[slot(i)]
    }
}
