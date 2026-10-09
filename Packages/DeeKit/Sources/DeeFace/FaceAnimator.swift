import DeeCore
import Foundation

/// What Dee is doing, as far as the face cares.
public enum FaceActivity: Sendable, Equatable {
    case idle, listening, thinking, speaking, sleeping
}

/// Everything the outside world tells the face, sampled every frame.
public struct FaceInputs: Sendable, Equatable {
    public var emotion: Emotion = .neutral
    public var activity: FaceActivity = .idle
    /// Where to look (−1…1, x right, y down), e.g. the user's face from the camera.
    /// nil = no target: Dee's gaze wanders on its own.
    public var lookAt: SIMD2<Double>?
    /// Dee's own voice level, 0…1 (drives the talking bounce).
    public var speechLevel = 0.0
    /// Microphone level while listening, 0…1.
    public var micLevel = 0.0
    public var reduceMotion = false
    /// Eye colour override — Dee's feelings toward the user (red → yellow → green),
    /// supplied by the mind. nil = the expression's own colour.
    public var tint: FaceColor?

    public init(emotion: Emotion = .neutral, activity: FaceActivity = .idle, lookAt: SIMD2<Double>? = nil, speechLevel: Double = 0, micLevel: Double = 0, reduceMotion: Bool = false, tint: FaceColor? = nil) {
        self.tint = tint
        self.emotion = emotion
        self.activity = activity
        self.lookAt = lookAt
        self.speechLevel = speechLevel
        self.micLevel = micLevel
        self.reduceMotion = reduceMotion
    }
}

/// One rendered frame: the sprung state plus per-frame effects.
public struct FaceFrame: Sendable, Equatable {
    public var state: FaceState
    /// 0 = open, 1 = shut.
    public var blink: Double
    /// Seconds since the animator started (drives glyph motion).
    public var time: Double
    /// Smoothed speech envelope, 0…1.
    public var voice: Double
    /// Smoothed mic envelope while listening, 0…1.
    public var listen: Double
    /// Breathing scale factor around 1.
    public var breath: Double
}

/// Procedural animation for the face.
///
/// Layer stack, bottom to top:
/// 1. expression target (emotion, overridden by activity),
/// 2. springs (stiffness 170, damping ratio 0.75 → a little overshoot and settle),
/// 3. gaze: saccades toward a target or idle wandering, on a faster spring,
/// 4. breathing, blinks, voice bounce and the wobble/giggle/tremble oscillators.
///
/// Deterministic for a given seed so it can be unit-tested frame by frame.
public struct FaceAnimator: Sendable {
    public private(set) var state: FaceState
    private var velocity: [Double]
    public private(set) var time = 0.0
    private var rng: SplitMix64

    // Gaze
    private var gaze = SIMD2<Double>(0, 0)
    private var gazeVelocity = SIMD2<Double>(0, 0)
    private var gazeGoal = SIMD2<Double>(0, 0)
    private var microOffset = SIMD2<Double>(0, 0)
    private var nextSaccade = 0.0
    private var nextMicro = 0.0

    // Blink
    private var blinkStart: Double?
    private var blinkDepth = 1.0
    private var nextBlink = 2.0
    private var pendingDouble = false

    // Envelopes
    private var voiceEnv = 0.0
    private var listenEnv = 0.0

    // Eye colour: its own critically damped spring (never overshoots 0…1).
    private var colorVelocity = SIMD3<Double>(0, 0, 0)

    /// True while something on screen moves fast enough to deserve the display's full
    /// rate (a blink, a saccade, talking). The view drops to 60 Hz otherwise.
    public private(set) var wantsHighFrameRate = false

    private var lastEmotion: Emotion?
    private var lastActivity: FaceActivity?

    public static let stiffness = 170.0
    public static let dampingRatio = 0.75
    static let gazeStiffness = 900.0

    /// Seconds for the mind's eye tint (regard colour) to cover ~63% of a jump, so a
    /// big swing (yellow → red after one shout) reads as a visible shift, not a snap.
    public static let tintTimeConstant = 3.0
    /// Critically damped ω that reaches 1 − 1/e at `tintTimeConstant`
    /// (solves (1 + x)e^−x = e^−1, x ≈ 2.1462).
    static let tintOmega = 2.1462 / tintTimeConstant
    /// Expression colours (no tint) change as fast as the shape spring, minus the overshoot.
    static let expressionColorOmega = stiffness.squareRoot()
    /// Index of `color.r` in `FaceState.components` (g, b follow).
    static let colorIndex = 2 * EyeState.count + 2

    public init(seed: UInt64 = 0xD33, initial: Emotion = .neutral) {
        state = Expressions.target(for: initial)
        velocity = Array(repeating: 0, count: FaceState.count)
        rng = SplitMix64(seed: seed)
        nextBlink = rng.uniform(2, 4)
    }

    /// The expression the face is heading for, given emotion and activity.
    public static func target(for inputs: FaceInputs) -> FaceState {
        var t = activityTarget(for: inputs)
        if let tint = inputs.tint { t.color = tint }
        return t
    }

    static func activityTarget(for inputs: FaceInputs) -> FaceState {
        switch inputs.activity {
        case .sleeping:
            return Expressions.target(for: .asleep)
        case .thinking:
            // Calm moods take the pondering look; strong feelings keep their shape
            // (an insulted Dee stays visibly angry while it works out a reply).
            let calm: Set<Emotion> = [.neutral, .happy, .curious, .thinking, .listening, .sleepy]
            guard calm.contains(inputs.emotion) else {
                var t = Expressions.target(for: inputs.emotion)
                t.thinkingDots = 1
                return t
            }
            var t = Expressions.target(for: .thinking)
            if inputs.emotion == .happy { t.sparkles = 0.3 }
            return t
        case .listening:
            var t = Expressions.target(for: inputs.emotion == .neutral ? .listening : inputs.emotion)
            t.ears = max(t.ears, 0.9)
            t.left.iris = max(t.left.iris, 0.4)
            t.right.iris = max(t.right.iris, 0.4)
            return t
        case .idle, .speaking:
            return Expressions.target(for: inputs.emotion)
        }
    }

    /// Advances by `dt` seconds and returns the frame to draw.
    public mutating func step(_ dt: Double, inputs: FaceInputs) -> FaceFrame {
        // NaN (e.g. a bad timestamp) is treated as "no time passed"; ±∞ clamp like any
        // other out-of-range value. NaN must not reach Int(...) below — it traps.
        let dt = dt.isNaN ? 0 : min(max(dt, 0), 1.0 / 20.0)
        time += dt

        // Blink on mood or activity changes — it hides the snap and reads as "reacting".
        if lastEmotion != nil, lastEmotion != inputs.emotion || lastActivity != inputs.activity,
           blinkStart == nil, inputs.activity != .sleeping {
            startBlink(depth: 1)
        }
        lastEmotion = inputs.emotion
        lastActivity = inputs.activity

        // 1–2. Springs toward the target (computed once per step, shared with gaze).
        let goal = Self.target(for: inputs)
        let target = goal.components
        var x = state.components
        let k = Self.stiffness
        let c = 2 * Self.dampingRatio * k.squareRoot()
        let ci = Self.colorIndex
        let substeps = max(1, Int((dt / (1.0 / 240.0)).rounded(.up)))
        let h = dt / Double(substeps)
        for _ in 0..<substeps {
            for i in x.indices where i < ci || i > ci + 2 {
                let a = k * (target[i] - x[i]) - c * velocity[i]
                velocity[i] += a * h
                x[i] += velocity[i] * h
            }
        }
        // Colour: critically damped, slow for the mind's tint, quick for expressions.
        let w = inputs.tint == nil ? Self.expressionColorOmega : Self.tintOmega
        var col = SIMD3(x[ci], x[ci + 1], x[ci + 2])
        let colGoal = SIMD3(target[ci], target[ci + 1], target[ci + 2])
        for _ in 0..<substeps {
            let a = w * w * (colGoal - col) - 2 * w * colorVelocity
            colorVelocity += a * h
            col += colorVelocity * h
        }
        x[ci] = col.x; x[ci + 1] = col.y; x[ci + 2] = col.z
        state = FaceState(components: x)

        // 3. Gaze.
        updateGaze(dt, inputs: inputs, base: goal)
        state.gazeX = clamp(gaze.x + microOffset.x, -1, 1)
        state.gazeY = clamp(gaze.y + microOffset.y, -1, 1)

        // 4. Envelopes, blink, breath.
        voiceEnv = follow(voiceEnv, inputs.speechLevel, dt, attack: 0.02, release: 0.12)
        listenEnv = follow(listenEnv, inputs.activity == .listening ? inputs.micLevel : 0, dt, attack: 0.03, release: 0.25)
        let blink = updateBlink(inputs)
        let breath = inputs.reduceMotion ? 1 : 1 + 0.015 * sin(2 * .pi * 0.25 * time)

        wantsHighFrameRate = Self.needsHighFrameRate(
            sleeping: inputs.activity == .sleeping,
            blinking: blinkStart != nil || nextBlink - time < 0.05,
            gazeSpeed: (gazeVelocity * gazeVelocity).sum().squareRoot(),
            speaking: inputs.activity == .speaking || voiceEnv > 0.02
        )

        return FaceFrame(state: state, blink: blink, time: time, voice: voiceEnv, listen: listenEnv, breath: breath)
    }

    // MARK: - Gaze

    /// Gaze speed (gaze units/s) above which a saccade is in flight.
    static let saccadeSpeed = 0.15

    static func needsHighFrameRate(sleeping: Bool, blinking: Bool, gazeSpeed: Double, speaking: Bool) -> Bool {
        guard !sleeping else { return false }
        return blinking || speaking || gazeSpeed > saccadeSpeed
    }

    private mutating func updateGaze(_ dt: Double, inputs: FaceInputs, base: FaceState) {
        if time >= nextSaccade {
            if let look = inputs.lookAt {
                // Lock on to the person, with the expression's bias (sad looks down).
                gazeGoal = SIMD2(clamp(look.x * 0.9 + base.gazeX * 0.3, -1, 1), clamp(look.y * 0.9 + base.gazeY * 0.5, -1, 1))
                nextSaccade = time + rng.uniform(0.15, 0.4)
            } else if inputs.activity == .thinking {
                // Pondering: glance between upper corners.
                let side = rng.uniform(0, 1) < 0.5 ? -1.0 : 1.0
                gazeGoal = SIMD2(side * rng.uniform(0.35, 0.6), rng.uniform(-0.65, -0.35))
                nextSaccade = time + rng.uniform(0.9, 2.2)
            } else if inputs.activity == .sleeping {
                gazeGoal = SIMD2(0, 0.2)
                nextSaccade = time + 3
            } else {
                // Idle wandering, mostly near the centre, biased by the expression.
                gazeGoal = SIMD2(clamp(base.gazeX + rng.uniform(-0.4, 0.4), -1, 1), clamp(base.gazeY + rng.uniform(-0.25, 0.25), -1, 1))
                nextSaccade = time + rng.uniform(1.0, 3.2)
            }
            // Big glances often come with a blink.
            if blinkStart == nil, inputs.activity != .sleeping, rng.uniform(0, 1) < 0.2 { startBlink(depth: 1) }
        }
        if time >= nextMicro, !inputs.reduceMotion {
            microOffset = SIMD2(rng.uniform(-0.03, 0.03), rng.uniform(-0.02, 0.02))
            nextMicro = time + rng.uniform(0.2, 0.6)
        }
        // Fast, slightly underdamped spring: saccades snap and settle.
        let k = Self.gazeStiffness
        let c = 2 * 0.8 * k.squareRoot()
        let substeps = max(1, Int((dt / (1.0 / 480.0)).rounded(.up)))
        let h = dt / Double(substeps)
        for _ in 0..<substeps {
            let a = k * (gazeGoal - gaze) - c * gazeVelocity
            gazeVelocity += a * h
            gaze += gazeVelocity * h
        }
    }

    // MARK: - Blink

    static let closeTime = 0.08
    static let holdTime = 0.06
    static let openTime = 0.15

    private mutating func startBlink(depth: Double) {
        blinkStart = time
        blinkDepth = depth
    }

    private mutating func updateBlink(_ inputs: FaceInputs) -> Double {
        if inputs.activity == .sleeping {
            blinkStart = nil
            return 0
        }
        if blinkStart == nil, time >= nextBlink {
            let partial = rng.uniform(0, 1) < 0.2
            startBlink(depth: partial ? rng.uniform(0.7, 0.9) : 1)
            pendingDouble = rng.uniform(0, 1) < 0.125
        }
        guard let start = blinkStart else { return 0 }
        let t = time - start
        let total = Self.closeTime + Self.holdTime + Self.openTime
        if t >= total {
            blinkStart = nil
            if pendingDouble {
                pendingDouble = false
                nextBlink = time + rng.uniform(0.2, 0.4)
            } else {
                let conversational = inputs.activity == .listening || inputs.activity == .speaking
                nextBlink = time + (conversational ? rng.uniform(2, 4) : rng.uniform(3.5, 7))
            }
            return 0
        }
        let v: Double
        if t < Self.closeTime {
            v = easeIn(t / Self.closeTime)
        } else if t < Self.closeTime + Self.holdTime {
            v = 1
        } else {
            v = 1 - easeOut((t - Self.closeTime - Self.holdTime) / Self.openTime)
        }
        return v * blinkDepth
    }

    /// Forces a blink now (e.g. a wink-like reaction).
    public mutating func blinkNow() { startBlink(depth: 1) }
}

// MARK: - Helpers

private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
private func easeIn(_ t: Double) -> Double { t * t }
private func easeOut(_ t: Double) -> Double { 1 - (1 - t) * (1 - t) }

private func follow(_ env: Double, _ input: Double, _ dt: Double, attack: Double, release: Double) -> Double {
    let tau = input > env ? attack : release
    let a = 1 - exp(-dt / tau)
    return env + (input - env) * a
}

/// Small, fast, seedable PRNG (deterministic animation in tests).
struct SplitMix64: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * Double(next() >> 11) / Double(1 << 53)
    }
}
