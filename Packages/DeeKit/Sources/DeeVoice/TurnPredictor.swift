import Foundation

// Predictive end of turn (docs/SELF.md §7.1). Pure value types, no audio framework:
// `ListeningCore` feeds frames and partial text; at every in-turn pause longer than
// 150 ms it asks for an `Estimate` (turn-end and hesitation probabilities plus the
// hold time the endpoint detector should wait).

/// Scores whether a pause in the user's speech is the end of their turn.
///
/// **Lexical** features use only partial text that has been stable for ≥ 300 ms
/// (never punctuation alone). **Prosodic** features use the YIN f0 track in
/// semitones relative to the speaker's long-term mean, and the frame dB envelope.
///
/// `turnEnd = σ(bias + Σ wᵢxᵢ)`;
/// `hesitation = max(fillerRate·2, restart 0.5, (pause > 0.6 s ∧ trailing) 0.7, slow 0.4)`;
/// `hold = clamp(lerp(1.4, 0.45, turnEnd) · pauseScale, 0.35, 2.5)`, at least 1.8 s
/// when `hesitation ≥ 0.6`.
public struct TurnPredictor: Sendable {

    // MARK: Public value types

    /// The binary/continuous features of one pause (all 0 or 1 except as noted).
    public struct Features: Sendable, Equatable {
        public var lexComplete = 0.0
        public var lexTrailing = 0.0
        public var filler = 0.0
        /// The stable text is a question ("?" after ≥ 2 real words). Not in the
        /// SELF.md table; a small extra syntactic cue (punctuation never stands alone).
        public var lexQuestion = 0.0
        public var f0Fall = 0.0
        public var f0Rise = 0.0
        public var f0Flat = 0.0
        public var energyDrop = 0.0
        public var short = 0.0

        public init(lexComplete: Double = 0, lexTrailing: Double = 0, filler: Double = 0, lexQuestion: Double = 0,
                    f0Fall: Double = 0, f0Rise: Double = 0, f0Flat: Double = 0, energyDrop: Double = 0,
                    short: Double = 0) {
            self.lexComplete = lexComplete
            self.lexTrailing = lexTrailing
            self.filler = filler
            self.lexQuestion = lexQuestion
            self.f0Fall = f0Fall
            self.f0Rise = f0Rise
            self.f0Flat = f0Flat
            self.energyDrop = energyDrop
            self.short = short
        }

        /// Feature vector in a fixed order (for Debug calibration logging; no text).
        public var vector: [Double] {
            [lexComplete, lexTrailing, filler, lexQuestion, f0Fall, f0Rise, f0Flat, energyDrop, short]
        }
    }

    /// Logistic weights. Hand-set defaults from SELF.md §7.1.
    public struct Weights: Sendable, Equatable {
        public var bias = -0.2
        public var lexComplete = 1.2
        public var lexTrailing = -2.5
        public var filler = -1.5
        public var lexQuestion = 0.5
        public var f0Fall = 0.9
        public var f0Rise = 0.6
        public var f0Flat = -0.5
        public var energyDrop = 0.5
        public var short = -0.4

        public init() {}

        public static let standard = Weights()

        func dot(_ f: Features) -> Double {
            bias + lexComplete * f.lexComplete + lexTrailing * f.lexTrailing + filler * f.filler
                + lexQuestion * f.lexQuestion + f0Fall * f.f0Fall + f0Rise * f.f0Rise + f0Flat * f.f0Flat
                + energyDrop * f.energyDrop + short * f.short
        }
    }

    /// What the predictor concluded at one pause.
    public struct Estimate: Sendable, Equatable {
        /// 0…1: probability the user has finished their turn.
        public var turnEnd: Double
        /// 0…1: how hesitant the user sounds (holding the floor while searching).
        public var hesitation: Double
        /// Seconds of quiet the endpoint detector should wait (0.35…2.5).
        public var hold: Double
        public var features: Features
        /// Length of the pause so far (seconds since the last sounding frame).
        public var pause: Double

        public init(turnEnd: Double, hesitation: Double, hold: Double, features: Features, pause: Double) {
            self.turnEnd = turnEnd
            self.hesitation = hesitation
            self.hold = hold
            self.features = features
            self.pause = pause
        }
    }

    // MARK: Constants

    public static let trailingWords: Set<String> = [
        "and", "but", "so", "because", "or", "the", "a", "an", "to", "of", "with", "my", "like", "if", "then", "that",
    ]
    /// Fillers after collapsing repeated letters ("ummm" → "um", "hmmm" → "hm", "mm" → "m").
    public static let fillerWords: Set<String> = ["um", "uh", "er", "erm", "hm", "m", "uhm", "ehm"]

    public static let minPause = 0.15
    public static let stableTextAge = 0.3
    public static let slopeWindow = 0.4
    public static let energyWindow = 0.2
    public static let fallSlope = -4.0
    public static let riseSlope = 4.0
    public static let flatSlope = 1.5
    public static let energyDropDB = 6.0
    public static let holdRange: ClosedRange<Double> = 0.35...2.5
    public static let holdConfident = 0.45
    public static let holdUnsure = 1.4
    public static let hesitationHold = 1.8
    public static let hesitationThreshold = 0.6
    public static let longPause = 0.6
    /// Default quiet interval (before any pause estimate), scaled by `pauseScale`.
    public static let defaultHold = 0.8

    // MARK: Pure scoring

    static func sigmoid(_ x: Double) -> Double { 1 / (1 + exp(-x)) }

    /// `σ(bias + Σ wᵢxᵢ)`.
    public static func turnEnd(_ f: Features, weights: Weights = .standard) -> Double {
        sigmoid(weights.dot(f))
    }

    /// `clamp(lerp(1.4, 0.45, turnEnd) · pauseScale, 0.35, 2.5)`; ≥ 1.8 when hesitant.
    public static func hold(turnEnd: Double, hesitation: Double, pauseScale: Double) -> Double {
        let p = min(max(turnEnd.isFinite ? turnEnd : 0, 0), 1)
        let scale = pauseScale.isFinite && pauseScale > 0 ? pauseScale : 1
        var h = (holdUnsure + (holdConfident - holdUnsure) * p) * scale
        h = min(max(h, holdRange.lowerBound), holdRange.upperBound)
        if hesitation >= hesitationThreshold { h = max(h, hesitationHold) }
        return h
    }

    /// Lowercased words with surrounding punctuation stripped ("And," → "and").
    public static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { token -> String? in
            let w = token.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            return w.isEmpty ? nil : w
        }
    }

    /// "ummm" → "um", "hmmm" → "hm", "mm" → "m".
    static func collapse(_ w: String) -> String {
        var out = ""
        for c in w where c != out.last { out.append(c) }
        return out
    }

    public static func isFiller(_ word: String) -> Bool { fillerWords.contains(collapse(word)) }
    public static func isTrailing(_ word: String) -> Bool { trailingWords.contains(word) }

    /// Lexical features of stable partial text.
    public static func lexical(_ text: String) -> Features {
        let w = words(text)
        var f = Features()
        f.short = w.count < 2 ? 1 : 0
        guard let last = w.last else { return f }
        let filler = isFiller(last)
        let trailing = isTrailing(last)
        f.filler = filler ? 1 : 0
        f.lexTrailing = trailing ? 1 : 0
        f.lexComplete = w.count >= 3 && !filler && !trailing ? 1 : 0
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let realWords = w.filter { !isFiller($0) }.count
        f.lexQuestion = trimmed.hasSuffix("?") && realWords >= 2 && !filler && !trailing ? 1 : 0
        return f
    }

    /// Fraction of words that are fillers.
    public static func fillerRate(_ text: String) -> Double {
        let w = words(text)
        guard !w.isEmpty else { return 0 }
        return Double(w.filter(isFiller).count) / Double(w.count)
    }

    /// A self-repair in the last few words: a cut-off word ("I wa-") or an
    /// immediate repetition ("I I want", "the the").
    public static func hasRestart(_ text: String) -> Bool {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).suffix(8).map(String.init)
        for t in tokens where t.count > 1 && (t.hasSuffix("-") || t.hasSuffix("—") || t.hasSuffix("–")) { return true }
        let w = words(tokens.joined(separator: " ")).filter { !isFiller($0) }
        guard w.count >= 2 else { return false }
        for i in 1..<w.count where w[i] == w[i - 1] { return true }
        return false
    }

    /// `max(fillerRate·2, restart 0.5, (pause > 0.6 s ∧ trailing) 0.7, (rate < 0.7·baseline) 0.4)`, 0…1.
    public static func hesitation(text: String, pause: Double, speechRate: Double?, baselineRate: Double?) -> Double {
        var h = fillerRate(text) * 2
        if hasRestart(text) { h = max(h, 0.5) }
        if pause > longPause, let last = words(text).last, isTrailing(last) { h = max(h, 0.7) }
        if let r = speechRate, let b = baselineRate, b > 0, r > 0, r < 0.7 * b { h = max(h, 0.4) }
        return min(max(h, 0), 1)
    }

    /// Least-squares slope (units per second) of `(t, v)` points.
    static func slope(_ pts: [(t: Double, v: Double)]) -> Double? {
        guard pts.count >= 3 else { return nil }
        let n = Double(pts.count)
        let mt = pts.reduce(0) { $0 + $1.t } / n
        let mv = pts.reduce(0) { $0 + $1.v } / n
        var num = 0.0, den = 0.0
        for p in pts {
            num += (p.t - mt) * (p.v - mv)
            den += (p.t - mt) * (p.t - mt)
        }
        guard den > 1e-9 else { return nil }
        return num / den
    }

    /// Prosodic features from the pitch track (semitones, absolute) and the
    /// sounding-frame dB envelope of this turn. `personMean` in semitones.
    static func prosodic(pitch: [(t: Double, v: Double)], energy: [(t: Double, v: Double)],
                         lastSounding: Double, personMean: Double?) -> Features {
        var f = Features()
        // Final 400 ms of voiced pitch, octave errors (> 7 st from the window median) dropped.
        let window = pitch.filter { $0.t >= lastSounding - slopeWindow - 1e-9 }
        if window.count >= 3 {
            let sorted = window.map(\.v).sorted()
            let median = sorted[sorted.count / 2]
            let kept = window.filter { abs($0.v - median) <= 7 }
            if let s = slope(kept) {
                let level = kept.reduce(0) { $0 + $1.v } / Double(kept.count)
                if s < fallSlope { f.f0Fall = 1 }
                if s > riseSlope { f.f0Rise = 1 }
                if abs(s) < flatSlope, level >= (personMean ?? level) - 0.25 { f.f0Flat = 1 }
            }
        }
        // Final 200 ms vs the turn's mean (energy mean, in dB).
        if energy.count >= 4 {
            let tail = energy.filter { $0.t >= lastSounding - energyWindow - 1e-9 }
            if !tail.isEmpty, tail.count < energy.count {
                let mean = Level.powerDB(energy.reduce(0) { $0 + pow(10, $1.v / 10) } / Double(energy.count))
                let tailMean = Level.powerDB(tail.reduce(0) { $0 + pow(10, $1.v / 10) } / Double(tail.count))
                if tailMean < mean - energyDropDB { f.energyDrop = 1 }
            }
        }
        return f
    }

    // MARK: Streaming state

    public var weights = Weights.standard
    /// Learned (or pushed) speech rate in words per second; nil until known.
    public var baselineRate: Double?
    /// Long-term mean f0 of the current speaker in semitones (12·log2 Hz); nil until heard.
    public private(set) var personMeanSemitones: Double?

    private var text = ""
    private var textSince = -Double.infinity
    private var lastStableText = ""
    private var pitch: [(t: Double, v: Double)] = []
    private var energy: [(t: Double, v: Double)] = []
    private var soundingTime = 0.0
    private var lastSounding: Double?
    private var pauseStart: Double?
    private var evaluatedThisPause = false
    private var lastStableEvaluated: String?
    private var crossedLongPause = false
    private var pauses: [Double] = []
    public private(set) var last: Estimate?

    public init() {}

    /// Seconds of sounding (above-threshold) speech in the current turn.
    public var voicedTime: Double { soundingTime }
    /// Durations of the within-turn pauses the user resumed from, this turn.
    public var withinTurnPauses: [Double] { pauses }

    /// Text that has stayed unchanged for at least 300 ms.
    public func stableText(at t: Double) -> String {
        t - textSince >= Self.stableTextAge - 1e-9 ? text : lastStableText
    }

    public mutating func partial(_ newText: String, at t: Double) {
        guard newText != text else { return }
        if t - textSince >= Self.stableTextAge - 1e-9 { lastStableText = text }
        text = newText
        textSince = t
    }

    /// One analysis frame. `sounding`: energy above the VAD threshold (not hangover).
    public mutating func frame(sounding: Bool, db: Double, f0Hz: Double?, duration dt: Double, at t: Double) {
        guard sounding else { return }
        if let start = pauseStart, let ls = lastSounding {
            let gap = t - dt - ls
            if gap >= Self.minPause - 1e-9, start <= t { pauses.append(gap) }
        }
        pauseStart = nil
        evaluatedThisPause = false
        lastStableEvaluated = nil
        crossedLongPause = false
        lastSounding = t
        soundingTime += dt
        energy.append((t, db))
        if energy.count > 1500 { energy.removeFirst(energy.count - 1500) }
        if let f0 = f0Hz, f0.isFinite, f0 > 0 {
            let st = 12 * log2(f0)
            pitch.append((t, st))
            if pitch.count > 400 { pitch.removeFirst(pitch.count - 400) }
            // Slow speaker mean: ~16 s of voiced pitch.
            if let m = personMeanSemitones { personMeanSemitones = m + (st - m) * 0.0025 } else { personMeanSemitones = st }
        }
    }

    /// Called every frame/tick while listening. Returns a fresh estimate when one
    /// is due: once at 150 ms into a pause, again when the stable text changes
    /// during it, and once when it crosses 0.6 s.
    public mutating func update(at t: Double, pauseScale: Double) -> Estimate? {
        guard let ls = lastSounding, soundingTime >= 0.2 else { return nil }
        let pause = t - ls
        guard pause >= Self.minPause - 1e-9 else { return nil }
        if pauseStart == nil { pauseStart = ls }
        let stable = stableText(at: t)
        let long = pause > Self.longPause
        let due = !evaluatedThisPause || stable != lastStableEvaluated || (long && !crossedLongPause)
        guard due else { return nil }
        evaluatedThisPause = true
        lastStableEvaluated = stable
        if long { crossedLongPause = true }
        let e = estimate(stableText: stable, pause: pause, pauseScale: pauseScale)
        last = e
        return e
    }

    /// The estimate for a pause of `pause` seconds given `stableText` (uses the
    /// prosody collected so far).
    public func estimate(stableText: String, pause: Double, pauseScale: Double) -> Estimate {
        var f = Self.lexical(stableText)
        let p = Self.prosodic(pitch: pitch, energy: energy, lastSounding: lastSounding ?? 0,
                              personMean: personMeanSemitones)
        f.f0Fall = p.f0Fall
        f.f0Rise = p.f0Rise
        f.f0Flat = p.f0Flat
        f.energyDrop = p.energyDrop
        let turnEnd = Self.turnEnd(f, weights: weights)
        let n = Self.words(stableText).count
        let rate: Double? = soundingTime >= 1 && n >= 3 ? Double(n) / soundingTime : nil
        let hes = Self.hesitation(text: stableText, pause: pause, speechRate: rate, baselineRate: baselineRate)
        return Estimate(turnEnd: turnEnd, hesitation: hes,
                        hold: Self.hold(turnEnd: turnEnd, hesitation: hes, pauseScale: pauseScale),
                        features: f, pause: pause)
    }

    /// End of the turn: learns the speech-rate baseline, returns the within-turn
    /// pauses (for `PauseScaleLearner`) and clears per-turn state.
    public mutating func endTurn(text finalText: String) -> [Double] {
        let n = Self.words(finalText).count
        if soundingTime >= 1, n >= 3 {
            let r = Double(n) / soundingTime
            baselineRate = baselineRate.map { $0 + (r - $0) * 0.2 } ?? r
        }
        let out = pauses
        resetTurn()
        return out
    }

    /// Clears per-turn state (keeps the speaker's pitch mean and rate baseline).
    public mutating func resetTurn() {
        text = ""
        textSince = -.infinity
        lastStableText = ""
        pitch.removeAll()
        energy.removeAll()
        soundingTime = 0
        lastSounding = nil
        pauseStart = nil
        evaluatedThisPause = false
        lastStableEvaluated = nil
        crossedLongPause = false
        pauses.removeAll()
        last = nil
    }

    /// A different person: forget the pitch mean and rate baseline too.
    public mutating func resetSpeaker() {
        resetTurn()
        personMeanSemitones = nil
        baselineRate = nil
    }
}

/// Per-person pause scale (SELF.md §7.1): an EWMA (α = 0.1) of each turn's median
/// within-turn pause ÷ 0.5 s, shrunk toward 1.0 by a prior of 10 pseudo-observations,
/// clamped to 0.7…1.6.
public struct PauseScaleLearner: Sendable, Equatable {
    public static let range: ClosedRange<Double> = 0.7...1.6
    public static let alpha = 0.1
    public static let priorObservations = 10.0
    public static let referencePause = 0.5

    /// EWMA of observations (nil before the first).
    public private(set) var ewma: Double?
    public private(set) var observations: Int
    /// A value pushed from outside (stored profile, clipped-speaker bump); learning continues from it.
    private var base: Double

    public init(scale: Double = 1, observations: Int = 0) {
        base = Self.clamp(scale)
        self.observations = max(0, observations)
        ewma = nil
    }

    static func clamp(_ v: Double) -> Double {
        min(max(v.isFinite ? v : 1, range.lowerBound), range.upperBound)
    }

    /// The scale to use: the prior/pushed value shrunk with the learned EWMA.
    public var scale: Double {
        guard let e = ewma, observations > 0 else { return base }
        let n = Double(observations)
        let k = Self.priorObservations
        return Self.clamp((k * base + n * e) / (k + n))
    }

    /// One turn's within-turn pauses (seconds). Turns without pauses teach nothing.
    public mutating func observe(pauses: [Double]) {
        let valid = pauses.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !valid.isEmpty else { return }
        let median = valid.count % 2 == 1 ? valid[valid.count / 2]
            : (valid[valid.count / 2 - 1] + valid[valid.count / 2]) / 2
        let obs = median / Self.referencePause
        ewma = ewma.map { $0 + (obs - $0) * Self.alpha } ?? obs
        observations += 1
    }

    /// Replaces the scale (e.g. a stored profile value when someone is identified).
    public mutating func set(_ value: Double) {
        self = PauseScaleLearner(scale: value)
    }
}
