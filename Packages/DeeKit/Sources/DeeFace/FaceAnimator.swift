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
    /// Slow mood signals that steer the idle director's spontaneous performances.
    public var mood: FaceMood = FaceMood()
    /// A finger on the screen (0…1, y down): the eyes glance at it.
    public var touchPoint: SIMD2<Double>?
    /// A performance to play once; a new `id` triggers it.
    public var performance: PerformanceRequest?
    /// Listening preview (v0.5, SELF.md §7.2): the valence of what the user is saying
    /// so far, −1…1, from a throwaway appraisal of the partial transcript. Read only
    /// while `activity == .listening`: positive pushes the eyes toward soft smile arcs,
    /// negative toward concerned, inner-raised lids. Saturates at |0.5|.
    public var listenValence = 0.0
    /// How strongly the listening preview shows, 0…1 (default 0 = off). `DeeSelf`'s
    /// `Listener` caps it at 0.5, which gives a visibly partial, "previewing" reaction.
    public var listenIntensity = 0.0
    /// Extra upper-lid narrowing, 0…1 (default 0), for gaze that studies something:
    /// `GazeIntent.examineBack` maps to `FaceGaze.examineLids` (0.2). Slab eyes only.
    public var lidNarrow = 0.0
    /// The attentive "about to answer" face, 0…1 (default 0; v0.5, SELF.md §7.1):
    /// `DeeSelf.ExpressionIntent.readyFace`. Slab eyes lift, open and widen slightly
    /// and gain a little shine. Any activity but sleeping.
    public var readyFace = 0.0
    /// Softer, lowered lids, 0…1 (default 0; SELF.md §7.2 hesitation):
    /// `ExpressionIntent.lidSoften`. Upper lids drop gently, lid slants relax, corners
    /// round and the glow dims a touch (unlike `lidNarrow`, which only studies).
    public var lidSoften = 0.0
    /// Head tilt, −1…1 (default 0; pending question, hesitation): `ExpressionIntent.tilt`.
    /// Adds `tilt × FaceAnimator.maxTiltDegrees` to the whole-face roll (`headTilt`),
    /// on top of the expression's own tilt; positive turns the same way as curious.
    public var tilt = 0.0

    public init(emotion: Emotion = .neutral, activity: FaceActivity = .idle, lookAt: SIMD2<Double>? = nil, speechLevel: Double = 0, micLevel: Double = 0, reduceMotion: Bool = false, tint: FaceColor? = nil,
                mood: FaceMood = FaceMood(), touchPoint: SIMD2<Double>? = nil, performance: PerformanceRequest? = nil,
                listenValence: Double = 0, listenIntensity: Double = 0, lidNarrow: Double = 0,
                readyFace: Double = 0, lidSoften: Double = 0, tilt: Double = 0) {
        self.readyFace = readyFace
        self.lidSoften = lidSoften
        self.tilt = tilt
        self.listenValence = listenValence
        self.listenIntensity = listenIntensity
        self.lidNarrow = lidNarrow
        self.mood = mood
        self.touchPoint = touchPoint
        self.performance = performance
        self.tint = tint
        self.emotion = emotion
        self.activity = activity
        self.lookAt = lookAt
        self.speechLevel = speechLevel
        self.micLevel = micLevel
        self.reduceMotion = reduceMotion
    }
}

/// One rendered frame: the sprung state, the performance layer and per-frame effects.
public struct FaceFrame: Sendable, Equatable {
    /// What to draw: the sprung expression with any performance layered on top.
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
/// 1. expression target (emotion, overridden by activity), with small seeded
///    per-occurrence variation re-rolled each time an expression is entered,
/// 2. springs (stiffness 170, damping ratio 0.75 → a little overshoot and settle),
/// 3. gaze: saccades toward a finger, a target or idle wandering, on a faster spring,
/// 4. performances (requested, or chosen by the idle director from `FaceMood`),
///    as timed additive parameter tracks,
/// 5. breathing, blinks, voice bounce and the wobble/giggle/tremble oscillators.
///
/// Deterministic for a given seed so it can be unit-tested frame by frame.
public struct FaceAnimator: Sendable {
    /// The sprung expression (with gaze), before the performance layer.
    public private(set) var state: FaceState
    /// The (varied) expression the springs are currently heading for.
    public private(set) var goal: FaceState
    private var velocity: [Double]
    public private(set) var time = 0.0
    private var rng: SplitMix64

    /// Scales the per-occurrence variation (0 = canonical expressions, e.g. snapshots).
    public var variationAmount = 1.0
    /// Spontaneous idle performances on/off (on by default).
    public var idleDirectorEnabled = true

    // Variation
    private var variationSeed: UInt64 = 0
    private var lastExpression: Emotion?

    // Gaze
    private var gaze = SIMD2<Double>(0, 0)
    private var gazeVelocity = SIMD2<Double>(0, 0)
    private var gazeGoal = SIMD2<Double>(0, 0)
    private var microOffset = SIMD2<Double>(0, 0)
    private var nextSaccade = 0.0
    private var nextMicro = 0.0
    private var touching = false

    // Blink
    private var blinkStart: Double?
    private var blinkDepth = 1.0
    private var nextBlink = 2.0
    private var pendingDouble = false

    // Performances
    private(set) var moves: [ActiveMove] = []
    private var lastRequestID: Int?
    private var nextIdleMove = 0.0
    private var lastIdleMove: Move?
    /// Performances currently playing (requested or spontaneous).
    public var activePerformances: [Performance] {
        moves.compactMap { if case .perform(let p) = $0.move { p } else { nil } }
    }

    // Envelopes
    private var voiceEnv = 0.0
    private var listenEnv = 0.0

    // Eye colour: its own critically damped spring (never overshoots 0…1).
    private var colorVelocity = SIMD3<Double>(0, 0, 0)

    /// True while something on screen moves fast enough to deserve the display's full
    /// rate (a blink, a saccade, talking, a lively performance). The view drops to 60 Hz otherwise.
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
        goal = state
        velocity = Array(repeating: 0, count: FaceState.count)
        rng = SplitMix64(seed: seed)
        nextBlink = rng.uniform(2, 4)
        variationSeed = rng.next()
        nextIdleMove = rng.uniform(3, 7)
    }

    /// The expression the face is heading for, given emotion and activity (canonical,
    /// without per-occurrence variation).
    public static func target(for inputs: FaceInputs) -> FaceState {
        var t = activityTarget(for: inputs)
        if inputs.activity != .sleeping {
            applyLidNarrow(&t, amount: inputs.lidNarrow)
            applyFaceModifiers(&t, readyFace: inputs.readyFace, lidSoften: inputs.lidSoften, tilt: inputs.tilt)
        }
        if let tint = inputs.tint { t.color = tint }
        return t
    }

    // MARK: - Listening preview (v0.5)

    /// |valence| at which the preview's direction is fully committed.
    public static let listenValenceSaturation = 0.5

    /// The signed preview weight, −1…1: `intensity × clamp(valence / 0.5, −1, 1)`.
    /// 0 when either input is 0 or not finite.
    public static func listenPreviewWeight(valence: Double, intensity: Double) -> Double {
        guard valence.isFinite, intensity.isFinite else { return 0 }
        return clamp(intensity, 0, 1) * clamp(valence / listenValenceSaturation, -1, 1)
    }

    /// Colours the preview leans toward at full weight: happy's bright cyan, and a
    /// paler, cooler blue for concern (not worried's cream, which mixes to green and
    /// would read as the regard tint's "fond").
    static let listenWarm = Expressions.target(for: .happy).color
    static let listenConcern = FaceColor(hex: 0xB4CCE6)

    /// Blends the listening preview into a listening target, in place. Positive weight
    /// pushes the lower lids up into soft smile arcs (toward `happy`); negative raises
    /// the inner brows and draws the eyes in (toward `worried`). Glyph eyes (a live
    /// reflex like a giggle's `∩`) are left alone, eye by eye. Gaze is never touched,
    /// so mutual gaze holds while Dee previews.
    static func applyListenPreview(_ t: inout FaceState, valence: Double, intensity: Double) {
        let w = listenPreviewWeight(valence: valence, intensity: intensity)
        guard w != 0 else { return }
        let pos = max(w, 0), neg = max(-w, 0)
        func shape(_ e: inout EyeState, inward: Double) {
            let slab = 1 - e.glyphAmount
            guard slab > 0 else { return }
            let p = pos * slab, n = neg * slab
            // Positive: smile arcs from below, eyes lift a touch, a bit more shine.
            e.lowerLid = max(e.lowerLid, 0.4 * p)
            e.height *= 1 - 0.12 * p - 0.05 * n
            e.width *= 1 + 0.06 * p - 0.06 * n
            e.dy += -0.05 * p
            e.gloss = min(1, e.gloss + 0.15 * p)
            e.iris *= 1 - 0.8 * p                       // the lens would be clipped by the arcs
            // Negative: inner corners raised (sad slant), a little lid, eyes drawn in.
            e.upperAngle += -30 * n
            e.upperLid = max(e.upperLid, 0.2 * n)
            e.tilt += -4 * n
            e.dx += inward * 0.04 * n
            e.radius = min(0.5, e.radius + 0.05 * n)
        }
        // Eyes are drawn in: left eye moves right (+dx), right eye moves left.
        shape(&t.left, inward: 1)
        shape(&t.right, inward: -1)
        t.color = mix(t.color, w > 0 ? listenWarm : listenConcern, (w > 0 ? 0.55 : 0.45) * abs(w))
        t.ears = clamp(t.ears - 0.6 * neg, -1, 1)
        t.tremble = max(t.tremble, 0.15 * neg)
        t.brightness = clamp(t.brightness + 0.04 * pos - 0.04 * neg, 0, 1.2)
    }

    /// Lowers the upper lids of slab eyes by `amount` (0…1, clamped; scaled 1:1 into lid fraction).
    static func applyLidNarrow(_ t: inout FaceState, amount: Double) {
        let a = amount.isFinite ? clamp(amount, 0, 1) : 0
        guard a > 0 else { return }
        for side in [\FaceState.left, \FaceState.right] {
            let slab = 1 - t[keyPath: side].glyphAmount
            t[keyPath: side].upperLid = min(0.85, t[keyPath: side].upperLid + a * slab)
        }
    }

    // MARK: - Face modifiers (v0.5: ready face, lid softening, tilt)

    /// Degrees of head roll at `tilt` ±1.
    public static let maxTiltDegrees = 10.0

    /// Blends `DeeSelf`'s face modifiers into a target, in place: ready face, then lid
    /// softening (so both at once partly cancel), then tilt. Inputs are clamped
    /// (ready / soften 0…1, tilt −1…1; NaN or ±∞ count as 0). Lid and shape changes
    /// touch slab eyes only, eye by eye (a glyph reflex is left alone); tilt rolls the
    /// whole face. Gaze is never touched. All zero → the target is unchanged.
    static func applyFaceModifiers(_ t: inout FaceState, readyFace: Double, lidSoften: Double, tilt: Double) {
        func unit(_ v: Double) -> Double { v.isFinite ? clamp(v, 0, 1) : 0 }
        let r = unit(readyFace), s = unit(lidSoften)
        let roll = tilt.isFinite ? clamp(tilt, -1, 1) : 0
        guard r > 0 || s > 0 || roll != 0 else { return }
        func shape(_ e: inout EyeState) {
            let slab = 1 - e.glyphAmount
            guard slab > 0 else { return }
            let rw = r * slab, sw = s * slab
            // Ready: lids lift, eyes open a touch taller and wider and sit higher, more shine.
            e.upperLid *= 1 - 0.6 * rw
            e.height *= 1 + 0.08 * rw
            e.width *= 1 + 0.04 * rw
            e.dy += -0.06 * rw
            e.gloss = min(1, e.gloss + 0.15 * rw)
            // Soft: upper lids drop gently, slants relax toward level, corners round.
            e.upperLid = min(0.85, e.upperLid + 0.22 * sw)
            e.upperAngle *= 1 - 0.6 * sw
            e.radius = min(0.5, e.radius + 0.06 * sw)
            e.height *= 1 - 0.04 * sw
            e.dy += 0.02 * sw
        }
        shape(&t.left)
        shape(&t.right)
        if r > 0 { t.ears = min(1, max(t.ears, t.ears + 0.4 * r)) }
        t.brightness = max(0, t.brightness + 0.05 * r - 0.06 * s)
        t.headTilt += maxTiltDegrees * roll
    }

    private static func mix(_ a: FaceColor, _ b: FaceColor, _ f: Double) -> FaceColor {
        let f = clamp(f, 0, 1)
        return FaceColor(a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f)
    }

    static let calmForThinking: Set<Emotion> = [.neutral, .happy, .curious, .thinking, .listening, .sleepy, .content, .bored]

    /// The emotion whose look is actually on screen (activities override some).
    static func expressedEmotion(for inputs: FaceInputs) -> Emotion {
        switch inputs.activity {
        case .sleeping: .asleep
        case .thinking: calmForThinking.contains(inputs.emotion) ? .thinking : inputs.emotion
        case .listening: inputs.emotion == .neutral ? .listening : inputs.emotion
        case .idle, .speaking: inputs.emotion
        }
    }

    static func activityTarget(for inputs: FaceInputs) -> FaceState {
        switch inputs.activity {
        case .sleeping:
            return Expressions.target(for: .asleep)
        case .thinking:
            // Calm moods take the pondering look; strong feelings keep their shape
            // (an insulted Dee stays visibly angry while it works out a reply).
            guard calmForThinking.contains(inputs.emotion) else {
                var t = Expressions.target(for: inputs.emotion)
                t.thinkingDots = 1
                return t
            }
            var t = Expressions.target(for: .thinking)
            if inputs.emotion == .happy || inputs.emotion == .content { t.sparkles = 0.3 }
            return t
        case .listening:
            var t = Expressions.target(for: inputs.emotion == .neutral ? .listening : inputs.emotion)
            t.ears = max(t.ears, 0.9)
            // The Wall-E lens only suits open slab eyes.
            if t.left.glyphAmount < 0.5 { t.left.iris = max(t.left.iris, 0.4) }
            if t.right.glyphAmount < 0.5 { t.right.iris = max(t.right.iris, 0.4) }
            // Dee's face starts reacting before the user has finished (SELF.md §7.2).
            applyListenPreview(&t, valence: inputs.listenValence, intensity: inputs.listenIntensity)
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

        // Each time an expression is entered it gets a fresh little variation.
        let expressed = Self.expressedEmotion(for: inputs)
        if lastExpression != nil, lastExpression != expressed { variationSeed = rng.next() }
        lastExpression = expressed

        // 1–2. Springs toward the (varied) target, computed once per step, shared with gaze.
        goal = Expressions.varied(Self.target(for: inputs), emotion: expressed, seed: variationSeed, amount: variationAmount)
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

        // 4. Performances: requests, then the idle director, then the pose layer.
        updatePerformances(inputs)
        var pose = Pose()
        for m in moves { pose = pose + m.move.pose(at: time - m.start, side: m.side) }
        if inputs.reduceMotion { pose = pose.calmed(0.3) }
        let shown = pose.applied(to: state)

        // 5. Envelopes, blink, breath.
        voiceEnv = follow(voiceEnv, inputs.speechLevel, dt, attack: 0.02, release: 0.12)
        listenEnv = follow(listenEnv, inputs.activity == .listening ? inputs.micLevel : 0, dt, attack: 0.03, release: 0.25)
        let blink = updateBlink(inputs)
        let breath = inputs.reduceMotion ? 1 : 1 + 0.015 * sin(2 * .pi * 0.25 * time)

        wantsHighFrameRate = Self.needsHighFrameRate(
            sleeping: inputs.activity == .sleeping,
            blinking: blinkStart != nil || nextBlink - time < 0.05,
            gazeSpeed: (gazeVelocity * gazeVelocity).sum().squareRoot(),
            speaking: inputs.activity == .speaking || voiceEnv > 0.02,
            performing: moves.contains { $0.move.isFast }
        )

        return FaceFrame(state: shown, blink: blink, time: time, voice: voiceEnv, listen: listenEnv, breath: breath)
    }

    // MARK: - Performances

    /// Plays a performance now (same as a new `PerformanceRequest`).
    public mutating func perform(_ performance: Performance) {
        start(.perform(performance))
    }

    private mutating func start(_ move: Move) {
        moves.removeAll { $0.move == move }
        if moves.count >= 3 { moves.removeFirst() }
        moves.append(ActiveMove(move: move, start: time, side: rng.uniform(0, 1) < 0.5 ? -1 : 1))
        // Don't let the director pile something on right after.
        nextIdleMove = max(nextIdleMove, time + move.duration + rng.uniform(1.5, 3))
    }

    private mutating func updatePerformances(_ inputs: FaceInputs) {
        moves.removeAll { $0.isDone(at: time) }
        if let req = inputs.performance, req.id != lastRequestID {
            lastRequestID = req.id
            start(.perform(req.performance))
        }
        // Being touched: a quick widen of attention.
        let touchedNow = inputs.touchPoint != nil
        if touchedNow, !touching, inputs.activity != .sleeping { start(.notice) }
        touching = touchedNow

        guard idleDirectorEnabled, !inputs.reduceMotion else { return }
        guard time >= nextIdleMove else { return }
        guard moves.isEmpty else {
            nextIdleMove = time + 0.5
            return
        }
        let move = Self.chooseIdleMove(mood: inputs.mood, emotion: inputs.emotion, activity: inputs.activity,
                                       last: lastIdleMove, roll: rng.uniform(0, 1))
        if let move {
            start(move)
            lastIdleMove = move
        }
        nextIdleMove = time + (move?.duration ?? 0) + Self.idleGap(mood: inputs.mood, activity: inputs.activity, roll: rng.uniform(0, 1))
    }

    /// Seconds of stillness before the director's next idea: ~4–12 s when idle
    /// (sooner when aroused, later when tired), rarer in conversation, rare asleep.
    static func idleGap(mood: FaceMood, activity: FaceActivity, roll: Double) -> Double {
        let r = min(max(roll, 0), 1)
        switch activity {
        case .sleeping:
            return 22 + 25 * r
        case .speaking, .listening:
            return 9 + 12 * r
        case .thinking:
            return 10 + 10 * r
        case .idle:
            let tired = 1 - clamp(mood.energy, 0, 1)
            let pace = (1.15 - 0.4 * clamp(mood.arousal, 0, 1)) * (1 + 0.25 * tired)
            return clamp((3 + 7 * r) * pace, 3.5, 12)
        }
    }

    /// Mood-weighted pick of a spontaneous move (pure: `roll` is a uniform 0…1 draw).
    static func idleWeights(mood m: FaceMood, emotion: Emotion, activity: FaceActivity) -> [(Move, Double)] {
        func c(_ v: Double) -> Double { clamp(v, 0, 1) }
        let curious = c(m.curiosity), bored = c(m.boredom), playful = c(m.playfulness)
        let energy = c(m.energy), affection = c(m.affection), arousal = c(m.arousal)
        let tired = 1 - energy
        let gloomy: Set<Emotion> = [.sad, .angry, .scared, .hurt, .lonely, .worried, .grumpy, .overwhelmed]
        let cheer = gloomy.contains(emotion) ? 0.25 : 1.0

        switch activity {
        case .sleeping:
            return [(.sleepyShuffle, 1)]
        case .thinking:
            return [(.perform(.squint), 0.5), (.tilt, 0.5)]
        case .speaking:
            return [
                (.tilt, 0.4 + 0.5 * curious), (.perform(.squint), 0.2), (.perform(.wink), 0.5 * playful * cheer),
                (.perform(.contentSquint), 0.6 * affection * cheer), (.perform(.bounce), 0.25 * playful * energy * cheer),
                (.perform(.nod), 0.3),
            ]
        case .listening:
            return [
                (.perform(.nod), 0.9), (.tilt, 0.4 + 0.6 * curious), (.perform(.squint), 0.25 * curious),
                (.perform(.contentSquint), 0.5 * affection * cheer),
            ]
        case .idle:
            return [
                (.perform(.lookAround), 0.25 + 1.3 * curious),
                (.perform(.squint), 0.55 * curious),
                (.tilt, 0.8 * curious),
                (.perform(.doubleTake), 0.15 * curious),
                (.perform(.yawn), 1.3 * bored + 1.8 * max(0, tired - 0.35)),
                (.perform(.eyeRoll), 0.85 * bored),
                (.perform(.sigh), 0.8 * bored + 0.3 * tired),
                (.perform(.wink), 0.9 * playful * cheer),
                (.perform(.bounce), (0.6 * playful * energy + 0.3 * arousal) * cheer),
                (.perform(.contentSquint), 1.2 * affection * cheer),
                (.perform(.blinkLeft), 0.08),
                (.perform(.blinkRight), 0.08),
            ]
        }
    }

    static func chooseIdleMove(mood: FaceMood, emotion: Emotion, activity: FaceActivity, last: Move?, roll: Double) -> Move? {
        var weights = idleWeights(mood: mood, emotion: emotion, activity: activity)
        // Not the same thing twice in a row (unless it's the only option).
        if weights.count > 1 { weights = weights.map { $0.0 == last ? ($0.0, $0.1 * 0.15) : $0 } }
        let total = weights.reduce(0) { $0 + max(0, $1.1) }
        guard total > 0 else { return nil }
        var r = clamp(roll, 0, 0.999_999) * total
        for (move, w) in weights where w > 0 {
            if r < w { return move }
            r -= w
        }
        return weights.last { $0.1 > 0 }?.0
    }

    // MARK: - Gaze

    /// Gaze speed (gaze units/s) above which a saccade is in flight.
    static let saccadeSpeed = 0.15

    static func needsHighFrameRate(sleeping: Bool, blinking: Bool, gazeSpeed: Double, speaking: Bool, performing: Bool = false) -> Bool {
        guard !sleeping else { return false }
        return blinking || speaking || performing || gazeSpeed > saccadeSpeed
    }

    /// Converts a touch location (0…1 in the face view, y down) to gaze units.
    /// The eyes sit a little above the middle of the view.
    public static func gaze(towardTouch p: SIMD2<Double>) -> SIMD2<Double> {
        SIMD2(clamp((p.x - 0.5) * 2.2, -1, 1), clamp((p.y - 0.47) * 2.2, -1, 1))
    }

    private mutating func updateGaze(_ dt: Double, inputs: FaceInputs, base: FaceState) {
        if let touch = inputs.touchPoint, inputs.activity != .sleeping {
            // A finger on the glass wins over everything: glance straight at it.
            gazeGoal = Self.gaze(towardTouch: touch)
            if time >= nextSaccade { nextSaccade = time + rng.uniform(0.6, 1.2) }
        } else if time >= nextSaccade {
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
            if blinkStart == nil, inputs.activity != .sleeping, rng.uniform(0, 1) < 0.2, !moves.contains(where: { $0.move.occupiesEyes }) {
                startBlink(depth: 1)
            }
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
        // A wink, a yawn or a giggle already has the eyes busy: natural blinks wait.
        if blinkStart == nil, time >= nextBlink, moves.contains(where: { $0.move.occupiesEyes }) {
            nextBlink = time + 0.3
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

func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v.isNaN ? lo : min(max(v, lo), hi) }
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
