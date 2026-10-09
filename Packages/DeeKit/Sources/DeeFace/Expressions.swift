import DeeCore
import Foundation

/// The expression library: one target `FaceState` per emotion.
///
/// Every emotion has its own readable silhouette: slab shapes with lids for the
/// subtle ones, glyph eyes (hearts, stars, `> <`, spirals, `–`, `∩`, `U`, dots) for
/// the loud ones, and its own colour. They are targets — the animator springs toward
/// them, so transitions get overshoot and settle for free — and `varied(_:seed:)`
/// adds small per-occurrence asymmetries so Dee never looks exactly the same twice.
public enum Expressions {
    public static func target(for emotion: Emotion) -> FaceState {
        var f = FaceState()
        switch emotion {
        case .neutral:
            f.setEyes(EyeState(gloss: 0.35))

        case .happy:
            // Loona's signature: eyes pushed up into smiling arcs.
            f.setEyes(EyeState(width: 1.1, height: 0.85, radius: 0.5, lowerLid: 0.42, dy: -0.06, gloss: 0.3))
            f.color = FaceColor(hex: 0x9FF5FF)
            f.ears = 0.8

        case .joy:
            // Eyes squeezed shut into big smiling arches, bouncing with laughter.
            f.setEyes(EyeState(width: 1.15, height: 1.0, dy: -0.04, arc: 1))
            f.color = FaceColor(hex: 0xB8FFF0)
            f.giggle = 1
            f.sparkles = 1
            f.ears = 1

        case .love:
            f.setEyes(EyeState(width: 1.05, height: 1.05, heart: 1, gloss: 0.6))
            f.color = FaceColor(hex: 0xFF6FA8)
            f.ears = 0.6

        case .sad:
            f.setEyes(EyeState(width: 0.95, height: 0.88, upperLid: 0.3, upperAngle: -18, tilt: -10, dy: 0.1, tear: 0.35, gloss: 0.3))
            f.color = FaceColor(hex: 0x6FA8FF)
            f.gazeY = 0.35
            f.ears = -1
            f.brightness = 0.85

        case .angry:
            // Hard inward slant; no lower lid, so the scowl is all brow.
            f.setEyes(EyeState(height: 0.85, radius: 0.3, upperLid: 0.35, upperAngle: 32, tilt: 8))
            f.color = FaceColor(hex: 0xFF5A4F)
            f.ears = -0.6

        case .surprised:
            f.setEyes(EyeState(width: 1.12, height: 1.25, radius: 0.5, iris: 0.5, gloss: 0.5))
            f.color = FaceColor(hex: 0xFFFFFF)
            f.ears = 1

        case .curious:
            f.left = EyeState(height: 0.85, upperLid: 0.15, upperAngle: 8, iris: 0.35, gloss: 0.3)
            f.right = EyeState(width: 1.12, height: 1.1, iris: 0.35, gloss: 0.45)
            f.headTilt = 12
            f.question = 0.5
            f.ears = 0.5

        case .sleepy:
            // Heavy lids drooping at the outer corners, still softly lit.
            f.setEyes(EyeState(width: 1.05, height: 0.9, upperLid: 0.66, upperAngle: -8, lowerLid: 0.1, tilt: -8))
            f.color = FaceColor(hex: 0x8FB8E0)
            f.brightness = 0.75
            f.zzz = 0.4
            f.ears = -0.5

        case .asleep:
            // Flat, dim lines.
            f.setEyes(EyeState(width: 1.05, height: 0.5, radius: 0.5, dy: 0.12, line: 1))
            f.color = FaceColor(hex: 0x3F6F90)
            f.brightness = 0.55
            f.zzz = 1
            f.ears = -0.8

        case .thinking:
            // Eyes rolled up and to the side: the eye nearer the gaze tips up toward it.
            f.left = EyeState(width: 0.92, height: 0.92, radius: 0.48, upperLid: 0.16, upperAngle: 6)
            f.right = EyeState(width: 0.95, height: 0.98, radius: 0.48, upperLid: 0.1, upperAngle: -8, tilt: 6)
            f.color = FaceColor(hex: 0xA98CFF)
            f.gazeX = 0.5
            f.gazeY = -0.5
            f.thinkingDots = 1

        case .listening:
            f.setEyes(EyeState(height: 1.06, iris: 0.4, gloss: 0.6))
            f.headTilt = 6
            f.ears = 1

        case .confused:
            f.left = EyeState(width: 0.9, height: 0.7, radius: 0.4, upperLid: 0.15, upperAngle: 15, tilt: -12)
            f.right = EyeState(width: 1.1, height: 1.1, radius: 0.4, upperAngle: -10, gloss: 0.3)
            f.color = FaceColor(hex: 0xB8D8FF)
            f.wobble = 1
            f.question = 1

        case .scared:
            // Shrunken, tall, trembling.
            f.setEyes(EyeState(width: 0.74, height: 1.02, radius: 0.5, upperAngle: -12, tilt: -4, dy: -0.03, iris: 0.2, gloss: 0.3))
            f.color = FaceColor(hex: 0xCFE8FF)
            f.tremble = 1
            f.ears = -1

        case .smug:
            f.left = EyeState(width: 1.05, height: 0.72, radius: 0.4, upperLid: 0.4, upperAngle: 8, lowerLid: 0.2)
            f.right = EyeState(width: 1.05, height: 0.75, radius: 0.4, upperLid: 0.32, upperAngle: 12, lowerLid: 0.22)
            f.color = FaceColor(hex: 0x7FFFE0)
            f.gazeX = 0.35
            f.headTilt = -5

        case .excited:
            f.setEyes(EyeState(width: 1.1, height: 1.1, star: 1))
            f.color = FaceColor(hex: 0xFFD86F)
            f.sparkles = 1
            f.ears = 1

        case .content:
            // Soft, flat, closed smiles — basking.
            f.setEyes(EyeState(width: 1.2, height: 0.62, dy: 0.02, arc: 1))
            f.color = FaceColor(hex: 0xFFC9A0)
            f.headTilt = 6
            f.brightness = 0.95

        case .playful:
            // A wink: one closed arch, one bright open eye.
            f.left = EyeState(width: 1.1, height: 0.85, dy: -0.02, arc: 1)
            f.right = EyeState(width: 1.08, height: 1.06, radius: 0.48, lowerLid: 0.24, dy: -0.03, gloss: 0.6)
            f.color = FaceColor(hex: 0x7DFFB0)
            f.headTilt = -8
            f.giggle = 0.25

        case .mischievous:
            // Sly: slanted lids, smiling lower lids, side-eye.
            f.left = EyeState(width: 1.05, height: 0.7, radius: 0.4, upperLid: 0.32, upperAngle: 18, lowerLid: 0.3, tilt: 6, gloss: 0.3)
            f.right = EyeState(width: 1.05, height: 0.72, radius: 0.4, upperLid: 0.24, upperAngle: 14, lowerLid: 0.3, tilt: 6, gloss: 0.3)
            f.color = FaceColor(hex: 0xC6FF6F)
            f.gazeX = -0.45
            f.gazeY = 0.15

        case .shy:
            // Little bright dot eyes, peeking down and away.
            f.setEyes(EyeState(width: 0.9, height: 0.9, dy: 0.1, tiny: 1))
            f.color = FaceColor(hex: 0xFFA8C8)
            f.gazeX = 0.6
            f.gazeY = 0.55
            f.headTilt = 14
            f.sparkles = 0.2

        case .proud:
            // Chin up, satisfied half-lids over a smile.
            f.setEyes(EyeState(width: 1.1, height: 0.8, radius: 0.5, upperLid: 0.22, lowerLid: 0.38, dy: -0.1, gloss: 0.3))
            f.color = FaceColor(hex: 0xFFC24D)
            f.gazeY = -0.35
            f.headTilt = -4
            f.sparkles = 0.6

        case .skeptical:
            // One eye narrowed, the other raised.
            f.left = EyeState(width: 1.0, height: 0.62, radius: 0.4, upperLid: 0.42, upperAngle: 6, lowerLid: 0.18)
            f.right = EyeState(width: 1.06, height: 1.12, upperAngle: -10, dy: -0.07, gloss: 0.3)
            f.color = FaceColor(hex: 0xB0E0D0)
            f.gazeX = 0.35
            f.headTilt = -5

        case .awe:
            f.setEyes(EyeState(width: 1.18, height: 1.3, radius: 0.5, iris: 0.55, gloss: 1))
            f.color = FaceColor(hex: 0xE8E0FF)
            f.gazeY = -0.3
            f.sparkles = 0.7

        case .pleading:
            // Puppy eyes: big, glossy, brows up in the middle.
            f.setEyes(EyeState(width: 1.1, height: 1.18, radius: 0.5, upperAngle: -10, tilt: -6, gloss: 1))
            f.color = FaceColor(hex: 0xA8D0FF)
            f.headTilt = 8
            f.gazeY = -0.2
            f.tremble = 0.12

        case .bored:
            // Half-lidded "meh": a flat lid over the lower half-dome, looking away.
            f.setEyes(EyeState(width: 1.08, height: 1.0, radius: 0.5, upperLid: 0.5, upperAngle: -10, tilt: -6, dy: 0.08, gloss: 0.15))
            f.color = FaceColor(hex: 0xA0A8C0)
            f.gazeX = -0.45
            f.gazeY = 0.3
            f.brightness = 0.8

        case .lonely:
            // Small round eyes glancing away and down: no lid, just little and far off.
            f.setEyes(EyeState(width: 0.68, height: 0.78, upperAngle: -4, tilt: -8, dy: 0.1, gloss: 0.7))
            f.color = FaceColor(hex: 0x6F7FD8)
            f.gazeX = 0.75
            f.gazeY = 0.4
            f.brightness = 0.7

        case .dizzy:
            f.setEyes(EyeState(width: 1.05, height: 1.05, spiral: 1))
            f.color = FaceColor(hex: 0xE0B0FF)
            f.wobble = 0.7
            f.headTilt = 8

        case .determined:
            // Focused, square-shouldered eyes under a low, nearly level brow, with a bright
            // glint (angry is the hard slant; proud is the soft smile).
            f.setEyes(EyeState(width: 1.12, height: 0.9, radius: 0.28, upperLid: 0.3, upperAngle: 7, dy: -0.02, gloss: 0.5))
            f.color = FaceColor(hex: 0xFF9A3C)
            f.gazeY = -0.1

        case .worried:
            // Brows up in the middle, eyes drawn in toward each other, a nervous quiver.
            f.left = EyeState(width: 0.9, height: 0.95, radius: 0.5, upperLid: 0.12, upperAngle: -22, tilt: -4, dx: 0.04, gloss: 0.35)
            f.right = f.left
            f.right.dx = -0.04
            f.color = FaceColor(hex: 0xFFE8A8)
            f.gazeX = -0.2
            f.tremble = 0.4

        case .grumpy:
            f.setEyes(EyeState(width: 1.08, height: 0.78, radius: 0.35, upperLid: 0.42, upperAngle: 8, lowerLid: 0.2, dy: 0.05))
            f.color = FaceColor(hex: 0xFF8060)
            f.gazeX = 0.2
            f.gazeY = 0.3
            f.brightness = 0.9

        case .hurt:
            // Big wet eyes with a tear rolling down.
            f.setEyes(EyeState(width: 1.05, height: 1.1, radius: 0.5, upperLid: 0.1, upperAngle: -24, tilt: -8, tear: 1, gloss: 0.9))
            f.color = FaceColor(hex: 0x5F9FFF)
            f.gazeY = 0.25
            f.tremble = 0.2

        case .giddy:
            f.setEyes(EyeState(width: 1.05, height: 1.0, chevron: 1))
            f.color = FaceColor(hex: 0xFF9FD8)
            f.giggle = 1
            f.sparkles = 0.8

        case .dreamy:
            f.setEyes(EyeState(width: 1.05, height: 0.9, upperLid: 0.42, lowerLid: 0.18, gloss: 0.7))
            f.color = FaceColor(hex: 0xB0B8FF)
            f.gazeX = -0.35
            f.gazeY = -0.45
            f.headTilt = -7
            f.sparkles = 0.35

        case .relieved:
            f.setEyes(EyeState(width: 1.1, height: 0.8, dy: 0.04, cup: 1))
            f.color = FaceColor(hex: 0x9FFFD0)
            f.headTilt = 4

        case .unimpressed:
            // Deadpan side-eye: flat-topped half eyes, one a touch lower (asleep is the line).
            f.left = EyeState(width: 1.1, height: 0.9, radius: 0.3, upperLid: 0.52, dy: -0.03)
            f.right = EyeState(width: 1.1, height: 0.9, radius: 0.3, upperLid: 0.6, dy: 0.03)
            f.color = FaceColor(hex: 0xC8C8B0)
            f.gazeX = 0.5
            f.headTilt = -3

        case .overwhelmed:
            // Tall, pinched `> <` squeezed shut, pale and wet, shaking (giddy is the pink squee).
            f.setEyes(EyeState(width: 0.85, height: 1.15, chevron: 1, tear: 1))
            f.color = FaceColor(hex: 0xC8B8FF)
            f.tremble = 0.8
            f.wobble = 0.4

        case .hopeful:
            // Bright, glossy, looking up — brows lifted a touch in the middle.
            f.setEyes(EyeState(width: 1.06, height: 1.12, radius: 0.5, upperAngle: -8, dy: -0.04, gloss: 0.95))
            f.color = FaceColor(hex: 0xC8FFA0)
            f.gazeY = -0.4
            f.sparkles = 0.25
        }
        return f
    }

    /// Emotions whose look is lopsided on purpose; their mirror image is just as readable.
    static let asymmetric: Set<Emotion> = [.curious, .confused, .smug, .playful, .mischievous, .skeptical, .thinking, .unimpressed]

    /// `state` with small, seeded per-occurrence variation: a slightly bigger eye on
    /// one side, nudged lids, tilt and gaze bias, sometimes mirrored, sometimes an
    /// alternate glyph (dizzy as `X X`). Colour and overlays are untouched, and every
    /// change stays small enough that the expression still reads at a glance.
    /// `amount` scales the numeric jitter (0 = none).
    public static func varied(_ state: FaceState, emotion: Emotion? = nil, seed: UInt64, amount: Double = 1) -> FaceState {
        guard amount > 0 else { return state }
        var rng = SplitMix64(seed: seed ^ 0xA5A5_5A5A_1234_8765)
        func u(_ r: Double) -> Double { rng.uniform(-r, r) * amount }
        var f = state

        if emotion != .asleep, rng.uniform(0, 1) < (emotion.map { asymmetric.contains($0) } ?? false ? 0.5 : 0.35) {
            f = f.mirrored()
        }
        if emotion == .dizzy, rng.uniform(0, 1) < 0.35 {
            for side in [\FaceState.left, \FaceState.right] {
                f[keyPath: side].cross = f[keyPath: side].spiral
                f[keyPath: side].spiral = 0
            }
        }

        let lopsided = u(0.045)
        func jitter(_ e: inout EyeState, _ side: Double) {
            e.width *= 1 + u(0.04) + side * lopsided * 0.5
            e.height *= 1 + u(0.05) + side * lopsided
            e.dx += u(0.025)
            e.dy += u(0.03)
            e.tilt += u(3)
            if e.upperLid > 0.05 { e.upperLid = max(0, e.upperLid + u(0.05)) }
            if e.lowerLid > 0.05 { e.lowerLid = max(0, e.lowerLid + u(0.045)) }
            if abs(e.upperAngle) > 1 { e.upperAngle += u(4) }
            if e.gloss > 0.05 { e.gloss = min(1, max(0, e.gloss + u(0.12))) }
        }
        jitter(&f.left, 1)
        jitter(&f.right, -1)
        f.headTilt += u(4)
        f.gazeX = min(max(f.gazeX + u(0.12), -1), 1)
        f.gazeY = min(max(f.gazeY + u(0.08), -1), 1)
        return f
    }
}
