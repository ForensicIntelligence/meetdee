import Accelerate
import Foundation
import Synchronization

/// Power spectra on one fixed grid — the bins of a 24 kHz, 512-point FFT
/// (46.875 Hz apart) from ~94 Hz to ~4 kHz — whatever the input's sample rate.
/// Band powers are in mean-square units: over all frequencies they add up to the
/// segment's mean square, so mic and reference spectra compare directly.
final class BandSpectrum: @unchecked Sendable {
    static let binHz = 24_000.0 / 512
    static let lowBand = 2
    static let highBand = 85
    /// Bands below ~1 kHz: where a voice has most of its energy.
    static let voiceBands = 20
    static var count: Int { highBand - lowBand + 1 }

    let size: Int
    private let dft: vDSP.DiscreteFourierTransform<Float>
    private let window: [Float]
    /// FFT bins (this size) that make up each grid band.
    private let ranges: [Range<Int>]

    private init?(rate: Double) {
        let ideal = 512 * rate / 24_000
        var n = 64
        while Double(n) < ideal * 0.9 { n *= 2 }
        guard let dft = try? vDSP.DiscreteFourierTransform(count: n, direction: .forward, transformType: .complexComplex,
                                                           ofType: Float.self) else { return nil }
        size = n
        self.dft = dft
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        let hz = rate / Double(n)
        ranges = (Self.lowBand...Self.highBand).map { b in
            let lo = (Double(b) - 0.5) * Self.binHz, hi = (Double(b) + 0.5) * Self.binHz
            let a = Int((lo / hz).rounded(.up)), z = Int((hi / hz).rounded(.up))
            return a..<max(a + 1, z)
        }
    }

    private static let cache = Mutex<[Int: BandSpectrum]>([:])

    static func forRate(_ rate: Double) -> BandSpectrum? {
        let key = Int(rate.rounded())
        guard key >= 8_000 else { return nil }
        return cache.withLock { c in
            if let s = c[key] { return s }
            let s = BandSpectrum(rate: Double(key))
            c[key] = s
            return s
        }
    }

    /// Grid band powers of `x` (exactly `size` samples).
    func bands(_ x: ArraySlice<Float>) -> [Double] {
        let input = Array(x)
        let ms = Double(vDSP.meanSquare(input))
        guard ms > 1e-14, input.count == size else { return [Double](repeating: 0, count: Self.count) }
        let windowed = vDSP.multiply(input, window)
        let zeros = [Float](repeating: 0, count: size)
        var re = [Float](repeating: 0, count: size), im = [Float](repeating: 0, count: size)
        dft.transform(inputReal: windowed, inputImaginary: zeros, outputReal: &re, outputImaginary: &im)
        let half = size / 2 + 1
        let power = vDSP.add(vDSP.square(re[0..<half]), vDSP.square(im[0..<half]))
        let total = 2 * Double(vDSP.sum(power)) - Double(power[0]) - Double(power[half - 1])
        guard total > 0 else { return [Double](repeating: 0, count: Self.count) }
        let scale = 2 * ms / total
        return power.withUnsafeBufferPointer { p in
            ranges.map { r in Double(vDSP.sum(p[r.clamped(to: 0..<half)])) * scale }
        }
    }
}

/// Dee's echo per frequency: what the microphone would hold of Dee's playback in
/// each band, so a voice *under* Dee's loud echo still shows where Dee is quiet.
///
/// Two people talking rarely fill the same frequencies at the same moment: Dee's
/// harmonics and the user's interleave, and each pauses inside words. With no
/// echo cancellation (or a weak one) Dee's echo can be as loud as the user, so the
/// broadband level can't tell them apart — but per band it can.
///
/// - **Reference.** Dee's rendered audio (`EchoReference.Bin.samples`) in 10 ms
///   hops: band powers, smeared by Dee's room's reverb (`decayDBPerHop`).
/// - **Echo path.** The delay is `EchoReference`'s; the gain per band is learned
///   as a high percentile of mic ÷ reference while the broadband model has a
///   clear echo match and the user isn't talking (`learn`). Until most bands are
///   learned it says nothing (`analyze` returns nil): the broadband bar decides.
/// - **Near-end.** Per hop, the energy in bands the echo can't explain (the mic
///   over `marginDB` above the predicted echo and the room's noise in that band);
///   over a frame its level, its share of the frame's energy, and how much of it
///   lies below 1 kHz (a voice; a tap or a clink is mostly higher).
struct SpectralEcho: Sendable {
    static let hop = 0.01
    static let refRate = 24_000.0
    static let decayPerHop = pow(10, -1.5 / 10)
    static let marginDB = 6.0
    /// Near-end: at least this share of the frame's energy unexplained…
    static let minFraction = 0.3
    /// …at least this much of it below 1 kHz.
    static let minLowShare = 0.5
    static let capacity = 256
    static let learnCapacity = 200
    static let minLearned = 60
    static let learnPercentile = 0.6
    /// A hop teaches the per-band gain only when its unexplained share is below this.
    static let learnFraction = 0.15
    /// Share of bands learned before the model speaks.
    static let readyShare = 0.7

    struct Result: Sendable, Equatable {
        /// Level of what Dee's echo doesn't explain (dBFS, mean square).
        var nearDB: Double
        /// Its share of the frame's energy (90 Hz – 4 kHz).
        var fraction: Double
        /// Its share below 1 kHz.
        var lowShare: Double

        var isVoice: Bool { fraction >= SpectralEcho.minFraction && lowShare >= SpectralEcho.minLowShare }
    }

    private var B: Int { BandSpectrum.count }
    private var refTail: [Float] = []
    /// Dee's rendered audio of the last `historySeconds` (24 kHz), ending at hop `refLast`.
    private var history: [Float] = []
    static let historySeconds = 0.6
    private var smear: [Double] = []
    /// Smeared reference band powers, `capacity` hops × bands, by hop index.
    private var ref: [Double] = []
    private var refLast: Int64?
    private var lastRefTime = -Double.infinity

    private var micTail: [Float] = []
    private var micRate = 0.0

    /// Learned echo gain per band (0: not yet).
    private var gain: [Double] = []
    private var ratios: [Float] = []
    private var ratioHead: [Int] = []
    private var ratioCount: [Int] = []
    private var sinceSolve = 0
    private var noise: [Double] = []

    var outputLatency = 0.0

    init() {
        let b = BandSpectrum.count
        ref = [Double](repeating: 0, count: Self.capacity * b)
        smear = [Double](repeating: 0, count: b)
        gain = [Double](repeating: 0, count: b)
        ratios = [Float](repeating: 0, count: Self.learnCapacity * b)
        ratioHead = [Int](repeating: 0, count: b)
        ratioCount = [Int](repeating: 0, count: b)
        noise = [Double](repeating: -1, count: b)
    }

    /// Forget the echo path (the route changed); the room's noise stays.
    mutating func reset() {
        let keepNoise = noise, latency = outputLatency
        self = SpectralEcho()
        noise = keepNoise
        outputLatency = latency
    }

    /// Bands with enough learned echo gain for the model to speak.
    var ready: Bool {
        Double(gain.filter { $0 > 0 }.count) >= Self.readyShare * Double(B)
    }

    // MARK: Reference

    mutating func addReference(_ bins: [EchoReference.Bin]) {
        guard let fft = BandSpectrum.forRate(Self.refRate) else { return }
        for bin in bins where !bin.samples.isEmpty && bin.t.isFinite {
            let i = EchoReference.index(bin.t)
            lastRefTime = max(lastRefTime, bin.t)
            if let last = refLast, i <= last { continue }       // late or duplicate: skip
            refTail.append(contentsOf: bin.samples)
            if refTail.count > fft.size { refTail.removeFirst(refTail.count - fft.size) }
            let hopN = Int(Self.refRate * Self.hop)
            if let last = refLast {
                var j = last + 1
                if i - last > Int64(Self.capacity) { j = i - Int64(Self.capacity) + 1 }
                if i - last > 1 {                               // a gap: silence in Dee's history
                    history.append(contentsOf: [Float](repeating: 0, count: Int(min(i - last - 1, 64)) * hopN))
                }
                while j < i {                                   // a gap: Dee's reverb decays
                    for b in 0..<B { smear[b] *= Self.decayPerHop }
                    store(j)
                    j += 1
                }
            }
            history.append(contentsOf: bin.samples.count == hopN ? bin.samples : Array(bin.samples.prefix(hopN))
                           + [Float](repeating: 0, count: max(0, hopN - bin.samples.count)))
            let keep = Int(Self.refRate * Self.historySeconds)
            if history.count > keep + 4 * hopN { history.removeFirst(history.count - keep) }
            let p = refTail.count == fft.size ? fft.bands(refTail[...]) : [Double](repeating: 0, count: B)
            for b in 0..<B { smear[b] = max(p[b], smear[b] * Self.decayPerHop) }
            store(i)
            refLast = i
        }
    }

    private mutating func store(_ i: Int64) {
        let k = slot(i) * B
        for b in 0..<B { ref[k + b] = smear[b] }
    }

    private func slot(_ i: Int64) -> Int {
        let c = Int64(Self.capacity)
        return Int(((i % c) + c) % c)
    }

    /// Dee's smeared reference that can reach mic hop `i`, per band (max over the lags).
    private func reach(_ i: Int64, delay: Double?) -> [Double] {
        var out = [Double](repeating: 0, count: B)
        guard let last = refLast else { return out }
        let (lo, hi): (Int64, Int64)
        if let delay {
            let d = Int64((delay / Self.hop).rounded())
            (lo, hi) = (d - 2, d + 2)
        } else {
            (lo, hi) = (Int64((EchoReference.minLag / Self.hop).rounded()) - 2,
                        Int64(((EchoReference.maxLag + outputLatency) / Self.hop).rounded()) + 2)
        }
        var lag = max(lo, 0)
        while lag <= hi {
            let j = i - lag
            if j <= last, last - j < Int64(Self.capacity) {
                let k = slot(j) * B
                for b in 0..<B { out[b] = max(out[b], ref[k + b]) }
            } else if j > last, j - last < Int64(Self.capacity) {
                // After Dee's last hop: Dee's reverb keeps decaying.
                let f = pow(Self.decayPerHop, Double(j - last))
                let k = slot(last) * B
                for b in 0..<B { out[b] = max(out[b], ref[k + b] * f) }
            }
            lag += 1
        }
        return out
    }

    /// Dee's pitches in the audio that can still be in the mic at `t`: Dee's 40 ms
    /// windows from `delay` back through Dee's room's reverb (`reverbSpan`) — the
    /// tail of a syllable Dee finished keeps its pitch in the room. Nil when Dee's
    /// history doesn't reach (no delay known yet): nothing can be told apart.
    func herPitches(at t: Double, delay: Double?) -> [Double]? {
        guard let last = refLast, let delay else { return nil }
        let hopN = Int(Self.refRate * Self.hop)
        let i = EchoReference.index(t - delay)
        let back = Int(last - i)
        guard back >= 0 else { return nil }
        var out: [Double] = []
        var shift = 0
        while Double(shift) * Self.hop <= Self.reverbSpan + 1e-9 {
            let end = history.count - (back + shift) * hopN
            let start = end - 4 * hopN
            guard start >= 0, end <= history.count else { return out.isEmpty ? nil : out }
            let x = Array(history[start..<end])
            if Level.rmsDB(x) > -55 {
                let (small, rate) = PitchDetector.decimate(x, sampleRate: Self.refRate)
                let p = PitchDetector.analyzeLoose(small, sampleRate: rate, looseThreshold: 0.35)
                if let f = p.f0 ?? p.looseF0 { out.append(f) }
            }
            shift += 4
        }
        return out
    }

    /// Dee's reverb keeps a finished syllable's pitch in the room this long.
    static let reverbSpan = 0.32

    /// `f` is a voice other than Dee's: no pitch of Dee's that can still be in the
    /// room is near it (octave errors aside). Unknown (`nil`), or no pitch of Dee's
    /// to compare with (Dee's onset, an unvoiced stretch — live tune 2: Dee paused
    /// for Dee's own echo 0.66 s into a reply): not told apart. In Dee's real gaps
    /// Dee's echo is low and the broadband bar hears the user anyway.
    static func differentVoice(_ f: Double, from hers: [Double]?) -> Bool {
        guard let hers, !hers.isEmpty, f > 0 else { return false }
        for her in hers where her > 0 {
            for k in [1.0, 2.0, 0.5] where abs(f / (her * k) - 1) < 0.1 { return false }
        }
        return true
    }

    // MARK: Microphone

    /// One mic frame ending at `t`: its 10 ms hops against Dee's predicted echo.
    /// `delay`: the echo delay when known; `broadbandGain`: the broadband echo gain
    /// (the per-band prior); `learn`: the frame is Dee's alone (a clear echo
    /// match, nobody talking) — its bands teach the per-band gain. Returns nil
    /// when the model can't speak (no reference, not learned yet).
    mutating func analyze(_ samples: [Float], rate: Double, endingAt t: Double, delay: Double?,
                          broadbandGain: Double?, learn: Bool) -> Result? {
        guard let fft = BandSpectrum.forRate(rate), !samples.isEmpty else { return nil }
        if rate != micRate { micRate = rate; micTail = [] }
        let hopN = max(1, Int((rate * Self.hop).rounded()))
        let hops = max(1, samples.count / hopN)
        let haveRef = t - lastRefTime < 1.0
        guard haveRef else {
            // Dee's voice isn't around: nothing to compare (only keep the tail).
            micTail.append(contentsOf: samples)
            if micTail.count > fft.size { micTail.removeFirst(micTail.count - fft.size) }
            return nil
        }
        let start = micTail.count
        micTail.append(contentsOf: samples)
        var u = 0.0, uLow = 0.0, total = 0.0
        var counted = 0
        let margin = pow(10, Self.marginDB / 10)
        for h in 0..<hops {
            let end = start + min(samples.count, (h + 1) * hopN)
            guard end >= fft.size else { continue }
            let m = fft.bands(micTail[(end - fft.size)..<end])
            let i = EchoReference.index(t - Double(hops - 1 - h) * Self.hop)
            let r = haveRef ? reach(i, delay: delay) : [Double](repeating: 0, count: B)
            let herActive = r.reduce(0, +) >= pow(10, EchoReference.activeDB / 10)
            // The room's own noise per band, learned while Dee's voice can't reach the mic.
            if r.reduce(0, +) < pow(10, (EchoReference.activeDB - 20) / 10) {
                for b in 0..<B {
                    if noise[b] < 0 || m[b] < noise[b] { noise[b] = noise[b] < 0 ? m[b] : 0.7 * noise[b] + 0.3 * m[b] }
                    else { noise[b] *= 1.005 }
                }
            }
            // The echo per band: learned, or (until then) the broadband gain.
            var g = gain
            if let bg = broadbandGain { for b in 0..<B where g[b] <= 0 { g[b] = bg } }
            var hopU = 0.0, hopTotal = 0.0
            for b in 0..<B {
                hopU += max(0, m[b] - margin * g[b] * r[b] - 2 * max(noise[b], 0))
                hopTotal += m[b]
            }
            // Only a hop Dee's echo explains teaches the model (never the user's voice in it).
            if learn, herActive, hopTotal > 0, hopU / hopTotal < Self.learnFraction {
                let peak = r.max() ?? 0
                for b in 0..<B where r[b] >= peak * 1e-3 && r[b] > 0 {
                    let x = Float(max(m[b] - max(noise[b], 0), 0) / r[b])
                    ratios[b * Self.learnCapacity + ratioHead[b]] = x
                    ratioHead[b] = (ratioHead[b] + 1) % Self.learnCapacity
                    ratioCount[b] = min(ratioCount[b] + 1, Self.learnCapacity)
                }
                sinceSolve += 1
                if sinceSolve >= 10 { sinceSolve = 0; solve() }
            }
            for b in 0..<B {
                let unexplained = max(0, m[b] - margin * g[b] * r[b] - 2 * max(noise[b], 0))
                u += unexplained
                if b < BandSpectrum.voiceBands { uLow += unexplained }
                total += m[b]
            }
            counted += 1
        }
        if micTail.count > fft.size { micTail.removeFirst(micTail.count - fft.size) }
        guard haveRef, ready, counted > 0, total > 0 else { return nil }
        return Result(nearDB: Level.powerDB(u / Double(counted)), fraction: u / total, lowShare: u > 0 ? uLow / u : 0)
    }

    /// Per-band gains from what was learned.
    private mutating func solve() {
        for b in 0..<B where ratioCount[b] >= Self.minLearned {
            let base = b * Self.learnCapacity
            var xs = Array(ratios[base..<(base + ratioCount[b])])
            xs.sort()
            let k = min(xs.count - 1, Int(Double(xs.count - 1) * Self.learnPercentile))
            gain[b] = max(Double(xs[k]), 1e-9)
        }
    }
}
