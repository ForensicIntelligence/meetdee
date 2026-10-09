import Foundation

/// A short, self-contained bit of face acting, layered over whatever the current
/// expression is. A `giggle` turns the eyes into bouncing `∩` arches even when Dee
/// is sad or cross: reflexes sit above mood, which is what makes her feel alive.
public enum Performance: String, CaseIterable, Sendable, Equatable {
    case wink, blinkLeft, blinkRight, yawn, eyeRoll, doubleTake, nod, headShake, giggle,
         squint, lookAround, startle, sigh, bounce, shiver, contentSquint, dizzySpin
}

/// Ask the face to perform once. A request with a new `id` triggers it; the same id
/// seen again (every frame) does nothing.
public struct PerformanceRequest: Sendable, Equatable {
    public var id: Int
    public var performance: Performance
    public init(id: Int, performance: Performance) {
        self.id = id
        self.performance = performance
    }
}

/// The slow mood signals that steer the idle director (all 0…1).
public struct FaceMood: Sendable, Equatable {
    public var curiosity, boredom, playfulness, energy, affection, arousal: Double
    public init(curiosity: Double = 0.5, boredom: Double = 0, playfulness: Double = 0.5, energy: Double = 0.8, affection: Double = 0.4, arousal: Double = 0.3) {
        self.curiosity = curiosity
        self.boredom = boredom
        self.playfulness = playfulness
        self.energy = energy
        self.affection = affection
        self.arousal = arousal
    }
}

// MARK: - Moves (performances plus a few internal ones)

/// Everything the animator can act out: the public performances, plus internal
/// idle moves the director uses (a curious head tilt, a sleepy shuffle, a quick
/// widen when touched).
enum Move: Hashable, Sendable {
    case perform(Performance)
    case tilt
    case sleepyShuffle
    case notice

    var duration: Double {
        switch self {
        case .perform(let p):
            switch p {
            case .wink: 0.8
            case .blinkLeft, .blinkRight: 0.34
            case .yawn: 2.6
            case .eyeRoll: 1.4
            case .doubleTake: 1.25
            case .nod: 0.95
            case .headShake: 1.1
            case .giggle: 1.6
            case .squint: 1.5
            case .lookAround: 2.9
            case .startle: 0.95
            case .sigh: 2.3
            case .bounce: 0.95
            case .shiver: 1.1
            case .contentSquint: 1.9
            case .dizzySpin: 2.5
            }
        case .tilt: 2.6
        case .sleepyShuffle: 2.4
        case .notice: 0.55
        }
    }

    /// Moves quick enough to need the display's full frame rate.
    var isFast: Bool {
        switch self {
        case .perform(let p):
            switch p {
            case .yawn, .squint, .sigh, .contentSquint: false
            default: true
            }
        case .notice: true
        case .tilt, .sleepyShuffle: false
        }
    }

    /// Moves that close or squeeze the eyes; natural blinks wait them out.
    var occupiesEyes: Bool {
        switch self {
        case .perform(let p):
            switch p {
            case .wink, .blinkLeft, .blinkRight, .yawn, .giggle, .contentSquint, .dizzySpin: true
            default: false
            }
        default: false
        }
    }
}

/// One move in flight. `side` (±1) picks the eye for a wink, the direction of an
/// eye-roll or first glance, so repeats don't look identical.
struct ActiveMove: Sendable, Equatable {
    var move: Move
    var start: Double
    var side: Double
    func isDone(at time: Double) -> Bool { time - start >= move.duration }
}

// MARK: - Poses

/// Additive deltas for one eye.
struct EyePose: Sendable, Equatable {
    var close = 0.0            // 0 open … 1 shut (height collapses)
    var widthScale = 0.0       // fractional change
    var heightScale = 0.0
    var dx = 0.0, dy = 0.0
    var upperLid = 0.0, lowerLid = 0.0, tilt = 0.0
    var arc = 0.0, chevron = 0.0, spiral = 0.0, line = 0.0, cup = 0.0
    var gloss = 0.0, tear = 0.0
    /// 0…1: pulls the eye's tilt, lid slant and size back to a level, ordinary eye (a
    /// laugh or a wink opens a cross, sad, small or grumpy eye up instead of keeping
    /// its scowl). Applied before the scales, so a giggle is the same size in any mood.
    var level = 0.0

    static func + (a: EyePose, b: EyePose) -> EyePose {
        EyePose(close: a.close + b.close, widthScale: a.widthScale + b.widthScale, heightScale: a.heightScale + b.heightScale,
                dx: a.dx + b.dx, dy: a.dy + b.dy, upperLid: a.upperLid + b.upperLid, lowerLid: a.lowerLid + b.lowerLid,
                tilt: a.tilt + b.tilt, arc: a.arc + b.arc, chevron: a.chevron + b.chevron, spiral: a.spiral + b.spiral,
                line: a.line + b.line, cup: a.cup + b.cup, gloss: a.gloss + b.gloss, tear: a.tear + b.tear,
                level: a.level + b.level)
    }

    var glyphOverride: Double { min(1, max(0, arc) + max(0, chevron) + max(0, spiral) + max(0, line) + max(0, cup)) }
}

/// Additive deltas for the whole face at one instant of a performance.
struct Pose: Sendable, Equatable {
    var left = EyePose()
    var right = EyePose()
    var headTilt = 0.0
    var faceDX = 0.0, faceDY = 0.0, squash = 0.0
    /// Gaze pulled toward `gaze` with `gazeWeight` (0…1).
    var gaze = SIMD2<Double>(0, 0)
    var gazeWeight = 0.0
    var tremble = 0.0, wobble = 0.0, giggle = 0.0
    var brightness = 0.0, sparkles = 0.0
    /// 0…1: warms the eye colour toward a soft gold, so a laugh over a red or blue mood
    /// reads as "laughing despite herself" rather than "angry laughing".
    var warmth = 0.0

    /// The gold a laugh warms toward, and how far it gets at full warmth.
    static let warmColor = FaceColor(hex: 0xFFE0A0)
    static let warmMix = 0.45

    mutating func both(_ f: (inout EyePose) -> Void) {
        f(&left)
        f(&right)
    }

    static func + (a: Pose, b: Pose) -> Pose {
        var p = Pose()
        p.left = a.left + b.left
        p.right = a.right + b.right
        p.headTilt = a.headTilt + b.headTilt
        p.faceDX = a.faceDX + b.faceDX
        p.faceDY = a.faceDY + b.faceDY
        p.squash = a.squash + b.squash
        let w = a.gazeWeight + b.gazeWeight
        if w > 1e-9 { p.gaze = (a.gaze * a.gazeWeight + b.gaze * b.gazeWeight) / w }
        p.gazeWeight = min(1, w)
        p.tremble = a.tremble + b.tremble
        p.wobble = a.wobble + b.wobble
        p.giggle = a.giggle + b.giggle
        p.brightness = a.brightness + b.brightness
        p.sparkles = a.sparkles + b.sparkles
        p.warmth = a.warmth + b.warmth
        return p
    }

    /// Damps the big whole-face motion (for Reduce Motion).
    func calmed(_ k: Double) -> Pose {
        var p = self
        p.faceDX *= k; p.faceDY *= k; p.squash *= k
        p.headTilt *= k; p.tremble *= k; p.wobble *= k; p.giggle *= k
        return p
    }

    /// `state` with this pose layered on top.
    func applied(to state: FaceState) -> FaceState {
        var s = state
        Self.apply(left, to: &s.left)
        Self.apply(right, to: &s.right)
        s.headTilt += headTilt
        s.faceDX += faceDX
        s.faceDY += faceDY
        s.squash += squash
        if gazeWeight > 0 {
            let w = min(max(gazeWeight, 0), 1)
            s.gazeX = min(max(s.gazeX + (gaze.x - s.gazeX) * w, -1), 1)
            s.gazeY = min(max(s.gazeY + (gaze.y - s.gazeY) * w, -1), 1)
        }
        s.tremble = max(0, s.tremble + tremble)
        s.wobble = max(0, s.wobble + wobble)
        s.giggle = max(0, s.giggle + giggle)
        s.brightness = max(0, s.brightness + brightness)
        s.sparkles = min(1, max(0, s.sparkles + sparkles))
        let warm = min(max(warmth.isNaN ? 0 : warmth, 0), 1) * Self.warmMix
        if warm > 0 {
            s.color.r += (Self.warmColor.r - s.color.r) * warm
            s.color.g += (Self.warmColor.g - s.color.g) * warm
            s.color.b += (Self.warmColor.b - s.color.b) * warm
            // Mixing toward gold greys out a blue mood; lift it back to full intensity so
            // the laugh stays luminous (only ever brightens).
            let peak = max(s.color.r, s.color.g, s.color.b)
            if peak > 0.05, peak < 1 {
                let lift = 1 + (1 / peak - 1) * warm / Self.warmMix
                s.color.r *= lift; s.color.g *= lift; s.color.b *= lift
            }
        }
        return s
    }

    private static func apply(_ p: EyePose, to e: inout EyeState) {
        let level = min(max(p.level.isNaN ? 0 : p.level, 0), 1)
        if level > 0 {
            e.width += (1 - e.width) * level
            e.height += (1 - e.height) * level
            e.tilt *= 1 - level
            e.upperAngle *= 1 - level
        }
        e.width *= max(0.2, 1 + p.widthScale)
        e.height *= max(0.05, 1 + p.heightScale) * max(0.04, 1 - 0.93 * min(max(p.close, 0), 1))
        e.dx += p.dx
        e.dy += p.dy
        e.upperLid = max(0, e.upperLid + p.upperLid)
        e.lowerLid = max(0, e.lowerLid + p.lowerLid)
        e.tilt += p.tilt
        // A glyph a performance asks for takes over from whatever glyph was showing.
        let take = p.glyphOverride
        if take > 0 {
            let keep = 1 - take
            e.heart *= keep; e.star *= keep; e.chevron *= keep; e.spiral *= keep; e.cross *= keep
            e.line *= keep; e.arc *= keep; e.cup *= keep; e.tiny *= keep
            e.arc += max(0, p.arc)
            e.chevron += max(0, p.chevron)
            e.spiral += max(0, p.spiral)
            e.line += max(0, p.line)
            e.cup += max(0, p.cup)
        }
        e.gloss = min(1, max(0, e.gloss + p.gloss))
        e.tear = min(1, max(0, e.tear + p.tear))
    }
}

// MARK: - Tracks

/// Smooth 0…1 envelope: rises over `rise` from `a`, holds, falls over `fall` to `b`.
func envelope(_ t: Double, from a: Double, to b: Double, rise: Double, fall: Double) -> Double {
    guard t > a, t < b else { return 0 }
    let up = rise > 0 ? smoothstep((t - a) / rise) : 1
    let down = fall > 0 ? smoothstep((b - t) / fall) : 1
    return min(up, down)
}

func smoothstep(_ x: Double) -> Double {
    let c = min(max(x, 0), 1)
    return c * c * (3 - 2 * c)
}

/// The blink-shaped close/hold/open curve used by single-eye blinks.
private func blinkCurve(_ t: Double) -> Double {
    if t < 0 { return 0 }
    if t < 0.08 { return (t / 0.08) * (t / 0.08) }
    if t < 0.14 { return 1 }
    let o = (t - 0.14) / 0.2
    return o >= 1 ? 0 : 1 - (1 - (1 - o) * (1 - o))
}

/// Piecewise gaze path through `(time, point)` keys with smoothstep easing.
private func path(_ t: Double, _ keys: [(Double, SIMD2<Double>)]) -> SIMD2<Double> {
    guard let first = keys.first else { return .zero }
    if t <= first.0 { return first.1 }
    for (a, b) in zip(keys, keys.dropFirst()) where t < b.0 {
        let k = smoothstep((t - a.0) / (b.0 - a.0))
        return a.1 + (b.1 - a.1) * k
    }
    return keys.last!.1
}

extension Move {
    /// The pose `t` seconds into this move. Pure, so every frame of every move can be
    /// unit-tested and rendered.
    func pose(at t: Double, side s: Double) -> Pose {
        var p = Pose()
        let d = duration
        guard t >= 0, t <= d else { return p }
        let tau = 2 * Double.pi
        switch self {
        case .perform(let perf):
            switch perf {
            case .wink:
                let e = envelope(t, from: 0, to: d, rise: 0.12, fall: 0.28)
                var wink = EyePose(), other = EyePose()
                wink.arc = e
                wink.heightScale = -0.12 * e
                other.lowerLid = 0.22 * e
                other.heightScale = 0.05 * e
                other.gloss = 0.3 * e
                // The open eye opens up too: a grumpy or smug lid lifts and levels for the wink.
                other.upperLid = -0.35 * e
                other.level = e
                if s < 0 { p.left = wink; p.right = other } else { p.right = wink; p.left = other }
                p.headTilt = -s * 7 * e
                p.faceDY = -0.012 * e

            case .blinkLeft:
                p.left.close = blinkCurve(t)
            case .blinkRight:
                p.right.close = blinkCurve(t)

            case .yawn:
                // Stretch tall, eyes squeezed into > <, then a sleepy reopening with a tiny tear.
                let e = envelope(t, from: 0.1, to: 2.05, rise: 0.55, fall: 0.45)
                let after = envelope(t, from: 1.7, to: d, rise: 0.25, fall: 0.45)
                p.both {
                    $0.chevron = e
                    $0.heightScale = -0.15 * e
                    $0.upperLid = 0.35 * after
                    $0.tilt = -4 * after
                }
                if s < 0 { p.left.tear = 0.5 * after } else { p.right.tear = 0.5 * after }
                p.squash = 0.09 * e - 0.02 * after
                p.faceDY = -0.025 * e
                p.headTilt = s * 5 * e
                p.brightness = -0.06 * after

            case .eyeRoll:
                // Gaze sweeps from one side, over the top, to the other, ending in a flat look.
                let w = envelope(t, from: 0, to: d, rise: 0.12, fall: 0.3)
                let prog = smoothstep((t - 0.05) / 0.95)
                let theta = s > 0 ? Double.pi * (1 - prog) : Double.pi * prog
                p.gaze = SIMD2(cos(theta) * 0.85, -abs(sin(theta)) * 0.9 - 0.1)
                p.gazeWeight = w
                let roll = p.gaze
                p.both { $0.dx = 0.28 * roll.x * w; $0.dy = 0.2 * roll.y * w }
                p.headTilt = -s * 4 * w
                let flat = envelope(t, from: 0.75, to: d, rise: 0.2, fall: 0.3)
                p.both { $0.upperLid = 0.28 * flat }

            case .doubleTake:
                let glance = envelope(t, from: 0, to: 0.38, rise: 0.06, fall: 0.1)
                let back = envelope(t, from: 0.48, to: d, rise: 0.05, fall: 0.35)
                let pop = envelope(t, from: 0.48, to: 1.05, rise: 0.06, fall: 0.35)
                p.gaze = SIMD2(s * 0.75, 0)
                p.gazeWeight = max(glance * 0.8, back)
                p.both {
                    $0.heightScale = 0.32 * pop
                    $0.widthScale = 0.08 * pop
                    $0.gloss = 0.3 * pop
                }
                p.faceDX = s * 0.025 * pop
                p.squash = 0.05 * pop

            case .nod:
                let e = envelope(t, from: 0, to: d, rise: 0.1, fall: 0.2)
                p.faceDY = 0.035 * max(0, sin(tau * t / 0.46)) * e
                p.gaze = SIMD2(0, 0.15)
                p.gazeWeight = 0.3 * e
                p.both { $0.lowerLid = 0.14 * e }

            case .headShake:
                let e = envelope(t, from: 0, to: d, rise: 0.12, fall: 0.3)
                let osc = sin(tau * 2.7 * t)
                p.faceDX = 0.04 * osc * e
                p.headTilt = 3 * osc * e
                p.gaze = SIMD2(-0.3 * osc, 0)
                p.gazeWeight = 0.5 * e
                p.both { $0.upperLid = 0.1 * e }

            case .giggle:
                let e = envelope(t, from: 0, to: d, rise: 0.12, fall: 0.35)
                // A real laugh, whatever the mood: the arches lift, level out, light up and
                // warm, the tears and the trembling stop.
                p.both {
                    $0.arc = e
                    $0.heightScale = -0.05 * e
                    $0.widthScale = 0.08 * e
                    $0.dy = -0.06 * e
                    $0.tear = -1 * e
                    $0.level = e
                }
                p.faceDY = -0.028 * abs(sin(tau * 3.2 * t)) * e
                p.squash = 0.03 * sin(tau * 6.4 * t) * e
                p.headTilt = s * 4 * e
                p.gaze = SIMD2(0, -0.1)
                p.gazeWeight = 0.7 * e
                p.tremble = -1 * e
                p.brightness = 0.3 * e
                p.sparkles = 0.45 * e
                p.warmth = e

            case .squint:
                let e = envelope(t, from: 0, to: d, rise: 0.3, fall: 0.35)
                p.both {
                    $0.upperLid = 0.3 * e
                    $0.lowerLid = 0.22 * e
                    $0.widthScale = 0.06 * e
                }
                p.gaze = SIMD2(0, 0)
                p.gazeWeight = 0.5 * e
                p.headTilt = s * 4 * e
                p.squash = -0.02 * e

            case .lookAround:
                let w = envelope(t, from: 0, to: d, rise: 0.12, fall: 0.35)
                let g = path(t, [(0.0, SIMD2(0, 0)), (0.25, SIMD2(s * 0.85, -0.1)), (1.05, SIMD2(s * 0.85, -0.05)),
                                 (1.35, SIMD2(-s * 0.85, 0.05)), (2.15, SIMD2(-s * 0.8, 0.1)), (2.5, SIMD2(0, 0))])
                p.gaze = g
                p.gazeWeight = w
                p.both { $0.dx = 0.3 * g.x * w; $0.dy = 0.15 * g.y * w }
                p.headTilt = 6 * g.x * w
                p.faceDX = 0.02 * g.x * w

            case .startle:
                let e = envelope(t, from: 0, to: d, rise: 0.05, fall: 0.6)
                let jolt = envelope(t, from: 0, to: 0.45, rise: 0.03, fall: 0.3)
                p.both {
                    $0.heightScale = 0.38 * e
                    $0.widthScale = -0.08 * e
                    $0.gloss = 0.35 * e
                }
                p.faceDY = -0.04 * e
                p.squash = 0.07 * e
                p.tremble = 0.7 * jolt

            case .sigh:
                let e = envelope(t, from: 0, to: d, rise: 0.65, fall: 0.8)
                p.both {
                    $0.upperLid = 0.32 * e
                    $0.tilt = -5 * e
                }
                p.faceDY = 0.03 * e
                p.squash = -0.045 * e
                p.gaze = SIMD2(s * 0.2, 0.35)
                p.gazeWeight = 0.5 * e
                p.brightness = -0.08 * e

            case .bounce:
                let e = envelope(t, from: 0, to: d, rise: 0.05, fall: 0.15)
                let hop = abs(sin(Double.pi * t / 0.46))
                p.faceDY = -0.055 * hop * e
                p.squash = (0.07 * hop - 0.035 * (1 - hop)) * e
                p.both { $0.lowerLid = 0.16 * e; $0.gloss = 0.2 * e }

            case .shiver:
                let e = envelope(t, from: 0, to: d, rise: 0.08, fall: 0.3)
                p.tremble = 1.0 * e
                p.faceDX = 0.008 * sin(tau * 17 * t) * e
                p.squash = -0.025 * e
                p.both {
                    $0.widthScale = -0.08 * e
                    $0.heightScale = -0.06 * e
                    $0.upperLid = 0.08 * e
                }

            case .contentSquint:
                let e = envelope(t, from: 0, to: d, rise: 0.4, fall: 0.55)
                // Basking: soft arches that stay a good size even over a small, dim mood.
                p.both {
                    $0.arc = e
                    $0.heightScale = -0.12 * e
                    $0.widthScale = 0.12 * e
                    $0.tear = -1 * e
                    $0.level = e
                }
                p.gaze = SIMD2(0, 0)
                p.gazeWeight = 0.5 * e
                p.headTilt = s * 6 * e
                p.faceDY = 0.01 * e
                p.brightness = 0.25 * e
                p.warmth = 0.7 * e

            case .dizzySpin:
                let e = envelope(t, from: 0, to: d, rise: 0.2, fall: 0.5)
                let ph = tau * 0.9 * t
                p.both { $0.spiral = e }
                p.headTilt = 10 * sin(ph) * e
                p.faceDX = 0.03 * cos(ph) * e
                p.faceDY = 0.02 * sin(ph) * e
                p.wobble = 0.3 * e
            }

        case .tilt:
            // A curious head tilt with the near eye opening a little wider.
            let e = envelope(t, from: 0, to: d, rise: 0.35, fall: 0.5)
            p.headTilt = s * 13 * e
            if s > 0 { p.right.heightScale = 0.1 * e } else { p.left.heightScale = 0.1 * e }
            p.both { $0.gloss = 0.2 * e }
            p.gaze = SIMD2(-s * 0.1, -0.12)
            p.gazeWeight = 0.4 * e

        case .sleepyShuffle:
            // Settling in sleep: a slow roll and a sink.
            let e = envelope(t, from: 0, to: d, rise: 0.7, fall: 0.9)
            p.headTilt = s * 5 * e
            p.faceDX = s * 0.012 * e
            p.faceDY = 0.012 * e
            p.squash = -0.025 * e

        case .notice:
            let e = envelope(t, from: 0, to: d, rise: 0.06, fall: 0.35)
            p.both { $0.heightScale = 0.12 * e; $0.gloss = 0.25 * e }
            p.squash = 0.02 * e
        }
        return p
    }
}

// MARK: - Gaze targets for projections (v0.5)

/// Fixed gaze points (in `FaceInputs.lookAt` units: −1…1, x right, y down) for the
/// `DeeSelf` gaze intents that are not "look at the user" or "wander", so
/// `Projector` maps them 1:1 without numbers of its own (SELF.md §3.5, §5).
public enum FaceGaze {
    /// Thinking aversion: a glance up and to the (screen) left, held ~0.6 s.
    public static let away = SIMD2<Double>(-0.5, -0.55)
    /// Studying something the back camera sees: eyes drop (gazeY +0.35) ...
    public static let examineBack = SIMD2<Double>(0, 0.35)
    /// ... and narrow (`FaceInputs.lidNarrow`).
    public static let examineLids = 0.2
    /// `GazeIntent.side(s)` (sound direction, −1…1) as a look point: horizontal, at eye level.
    public static func side(_ s: Double) -> SIMD2<Double> {
        SIMD2(s.isFinite ? clamp(s, -1, 1) * 0.8 : 0, 0)
    }
}
