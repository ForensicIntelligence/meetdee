import DeeCore

/// How Dee's voice sounds right now, from Dee's mood (`Projector.voice`). The
/// realtime voice can't take pitch or volume per sentence; `sessionSpeed` maps
/// the rate onto the session's `audio.output.speed` (applied between turns), and
/// the mood itself reaches the model through the per-turn cue.
public struct VoiceStyle: Sendable, Equatable {
    /// Pitch multiplier, 0.5…2 (1 = Dee's natural voice).
    public var pitch: Float
    /// Speaking rate on a 0…1 scale (0.5 = typical); see `sessionSpeed`.
    public var rate: Float
    /// Volume, 0…1.
    public var volume: Float

    public init(pitch: Float, rate: Float, volume: Float) {
        self.pitch = pitch
        self.rate = rate
        self.volume = volume
    }

    /// `rate` as a realtime `audio.output.speed`: the resting rate is 1.0, the
    /// slowest (sleepy, sad) ≈ 0.85 and the quickest (giddy, excited) ≈ 1.15.
    public var sessionSpeed: Double {
        let r = Double(rate).isFinite ? Double(rate) : Self.baseRate
        let k = 0.15 / (Self.rateRange.upperBound - Self.baseRate)
        return Self.clamp(1 + (r - Self.baseRate) * k, 0.8...1.2)
    }

    /// Dee's resting voice: cute, a touch high, a touch quick.
    public static let standard = VoiceStyle(pitch: Float(basePitch), rate: Float(baseRate), volume: 1)

    static let basePitch = 1.35
    static let baseRate = 0.52
    static let pitchRange: ClosedRange<Double> = 0.5...2.0
    /// Kept well inside 0…1 so Dee always stays intelligible.
    static let rateRange: ClosedRange<Double> = 0.36...0.64
    static let volumeRange: ClosedRange<Double> = 0.4...1.0

    /// The voice for a feeling.
    ///
    /// - emotion: what Dee feels *right now*. Pass the mind's momentary `reflex` when
    ///   there is one, so a joke still gets a giddy laugh even when Dee's mood is low.
    /// - age: robot-years (nil when age is switched off). Babies are higher, elders a
    ///   little lower and slower.
    /// - energy: 0…1. Low energy slows and lowers Dee — but bright, reflexive
    ///   feelings (joy, giddy, excited, playful, happy, surprised) only feel half of
    ///   that drag, because reflexes sit above mood: Dee can still light up.
    public static func forMood(emotion: Emotion, age: Double?, energy: Double) -> VoiceStyle {
        let e = shape(for: emotion)
        var pitch = basePitch + e.pitch
        var rate = baseRate + e.rate
        var volume = e.volume

        if let age, age.isFinite {
            pitch += interpolate(age, agePitch)
            rate += interpolate(age, ageRate)
        }

        let en = energy.isFinite ? min(max(energy, 0), 1) : 0.6
        let drag = isBright(emotion) ? 0.5 : 1.0
        if en < 0.5 {
            let low = (0.5 - en) * drag          // 0…0.5
            rate -= low * 0.14
            pitch -= low * 0.10
            volume -= low * 0.20
        } else if en > 0.75 {
            let high = en - 0.75                 // 0…0.25
            rate += high * 0.08
            pitch += high * 0.08
        }

        return VoiceStyle(
            pitch: Float(clamp(pitch, pitchRange)),
            rate: Float(clamp(rate, rateRange)),
            volume: Float(clamp(volume, volumeRange))
        )
    }

    /// Feelings that read as a reflexive lift (laughing, lighting up).
    static func isBright(_ e: Emotion) -> Bool {
        switch e {
        case .joy, .giddy, .excited, .playful, .happy, .surprised, .love: true
        default: false
        }
    }

    struct Shape { var pitch: Double; var rate: Double; var volume: Double }

    /// Per-emotion deltas from the base voice. Exhaustive on purpose: a new emotion
    /// must be given a voice.
    static func shape(for e: Emotion) -> Shape {
        switch e {
        case .neutral:     Shape(pitch: 0, rate: 0, volume: 1)
        case .happy:       Shape(pitch: 0.08, rate: 0.02, volume: 1)
        case .joy:         Shape(pitch: 0.14, rate: 0.04, volume: 1)
        case .love:        Shape(pitch: 0.06, rate: -0.03, volume: 0.9)
        case .sad:         Shape(pitch: -0.16, rate: -0.08, volume: 0.8)
        case .angry:       Shape(pitch: -0.06, rate: 0.04, volume: 1)
        case .surprised:   Shape(pitch: 0.16, rate: 0.03, volume: 1)
        case .curious:     Shape(pitch: 0.06, rate: 0, volume: 0.95)
        case .sleepy:      Shape(pitch: -0.12, rate: -0.12, volume: 0.7)
        case .asleep:      Shape(pitch: -0.16, rate: -0.15, volume: 0.5)
        case .thinking:    Shape(pitch: -0.02, rate: -0.04, volume: 0.9)
        case .listening:   Shape(pitch: 0, rate: -0.01, volume: 0.9)
        case .confused:    Shape(pitch: 0.04, rate: -0.04, volume: 0.95)
        case .scared:      Shape(pitch: 0.12, rate: 0.06, volume: 0.85)
        case .smug:        Shape(pitch: -0.04, rate: -0.02, volume: 1)
        case .excited:     Shape(pitch: 0.18, rate: 0.08, volume: 1)
        case .content:     Shape(pitch: 0.02, rate: -0.03, volume: 0.9)
        case .playful:     Shape(pitch: 0.12, rate: 0.04, volume: 1)
        case .mischievous: Shape(pitch: 0.06, rate: 0.02, volume: 0.9)
        case .shy:         Shape(pitch: 0.08, rate: -0.05, volume: 0.75)
        case .proud:       Shape(pitch: 0.02, rate: 0, volume: 1)
        case .skeptical:   Shape(pitch: -0.05, rate: -0.03, volume: 0.95)
        case .awe:         Shape(pitch: 0.08, rate: -0.05, volume: 0.85)
        case .pleading:    Shape(pitch: 0.15, rate: -0.04, volume: 0.85)
        case .bored:       Shape(pitch: -0.10, rate: -0.07, volume: 0.8)
        case .lonely:      Shape(pitch: -0.12, rate: -0.07, volume: 0.8)
        case .dizzy:       Shape(pitch: 0.05, rate: -0.06, volume: 0.9)
        case .determined:  Shape(pitch: -0.03, rate: 0.02, volume: 1)
        case .worried:     Shape(pitch: 0.05, rate: 0.03, volume: 0.85)
        case .grumpy:      Shape(pitch: -0.12, rate: -0.02, volume: 0.95)
        case .hurt:        Shape(pitch: -0.12, rate: -0.07, volume: 0.8)
        case .giddy:       Shape(pitch: 0.20, rate: 0.09, volume: 1)
        case .dreamy:      Shape(pitch: 0.02, rate: -0.08, volume: 0.8)
        case .relieved:    Shape(pitch: 0, rate: -0.04, volume: 0.95)
        case .unimpressed: Shape(pitch: -0.10, rate: -0.04, volume: 0.9)
        case .overwhelmed: Shape(pitch: 0.08, rate: 0.05, volume: 0.9)
        case .hopeful:     Shape(pitch: 0.08, rate: 0, volume: 0.95)
        }
    }

    // Age curves (robot-years → delta), piecewise linear between key ages.
    static let agePitch: [(Double, Double)] = [(0, 0.18), (3, 0.12), (12, 0.05), (20, 0), (60, 0), (90, -0.08), (120, -0.10)]
    static let ageRate: [(Double, Double)] = [(0, -0.02), (3, 0), (12, 0.01), (20, 0), (60, 0), (90, -0.05), (120, -0.06)]

    static func interpolate(_ x: Double, _ points: [(Double, Double)]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if x <= first.0 { return first.1 }
        if x >= last.0 { return last.1 }
        for i in 1..<points.count where x <= points[i].0 {
            let (x0, y0) = points[i - 1], (x1, y1) = points[i]
            return y0 + (y1 - y0) * (x - x0) / (x1 - x0)
        }
        return last.1
    }

    static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double {
        v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : r.lowerBound
    }
}

/// Little vocal laughs, so Dee can giggle at a joke whatever Dee's mood.
public enum Laughter {
    /// A short laugh, longer and brighter with intensity (0…1). `variant` picks among
    /// equivalent phrasings so Dee never sounds quite the same twice.
    public static func phrase(intensity: Double, variant: Int) -> String {
        let i = intensity.isFinite ? min(max(intensity, 0), 1) : 0.5
        let options: [String]
        switch i {
        case ..<0.34: options = ["Hehe.", "Heh!", "Hm-hm!"]
        case ..<0.67: options = ["Hehe!", "Hee hee!", "Haha!", "Ehehe!"]
        default:      options = ["Hahaha!", "Ahahaha!", "Hee hee hee!", "Hahaha, oh!"]
        }
        let k = ((variant % options.count) + options.count) % options.count
        return options[k]
    }

    /// The voice for a laugh: giddy, lifted further by intensity.
    public static func style(intensity: Double, age: Double?, energy: Double) -> VoiceStyle {
        let i = intensity.isFinite ? min(max(intensity, 0), 1) : 0.5
        var s = VoiceStyle.forMood(emotion: .giddy, age: age, energy: max(energy, 0.5))
        s.pitch = Float(VoiceStyle.clamp(Double(s.pitch) + 0.08 * i, VoiceStyle.pitchRange))
        s.rate = Float(VoiceStyle.clamp(Double(s.rate) + 0.03 * i, VoiceStyle.rateRange))
        return s
    }
}
