import DeeCore
import Foundation

/// The expression library: one target `FaceState` per emotion.
///
/// Values started from the design brief (docs/research/face.md §5) and were tuned
/// by eye against rendered snapshots. They are targets — the animator springs
/// toward them, so transitions get overshoot and settle for free.
public enum Expressions {
    public static func target(for emotion: Emotion) -> FaceState {
        var f = FaceState()
        switch emotion {
        case .neutral:
            f.setEyes(EyeState())

        case .happy:
            // Loona's signature: eyes pushed up into smiling arcs.
            f.setEyes(EyeState(width: 1.1, height: 0.85, radius: 0.5, lowerLid: 0.42, dy: -0.06))
            f.color = FaceColor(hex: 0x9FF5FF)
            f.ears = 0.8

        case .joy:
            f.setEyes(EyeState(width: 1.15, height: 0.8, radius: 0.5, lowerLid: 0.55, dy: -0.08))
            f.color = FaceColor(hex: 0xB8FFF0)
            f.giggle = 1
            f.sparkles = 1
            f.ears = 1

        case .love:
            f.setEyes(EyeState(width: 1.05, height: 1.05, heart: 1))
            f.color = FaceColor(hex: 0xFF6FA8)
            f.ears = 0.6

        case .sad:
            f.setEyes(EyeState(width: 0.95, height: 0.9, upperLid: 0.3, upperAngle: -18, tilt: -10, dy: 0.1, iris: 0.3))
            f.color = FaceColor(hex: 0x6FA8FF)
            f.gazeY = 0.35
            f.ears = -1
            f.brightness = 0.85

        case .angry:
            f.setEyes(EyeState(height: 0.85, radius: 0.3, upperLid: 0.35, upperAngle: 25, lowerLid: 0.1, tilt: 4))
            f.color = FaceColor(hex: 0xFF5A4F)
            f.ears = -0.6

        case .surprised:
            f.setEyes(EyeState(width: 1.12, height: 1.25, radius: 0.5, iris: 0.5))
            f.color = FaceColor(hex: 0xFFFFFF)
            f.ears = 1

        case .curious:
            f.left = EyeState(height: 0.85, upperLid: 0.15, upperAngle: 8, iris: 0.35)
            f.right = EyeState(width: 1.12, height: 1.1, iris: 0.35)
            f.headTilt = 12
            f.question = 0.6
            f.ears = 0.5

        case .sleepy:
            f.setEyes(EyeState(width: 1.05, height: 0.9, upperLid: 0.6, lowerLid: 0.1, tilt: -4))
            f.color = FaceColor(hex: 0x5F8FB0)
            f.brightness = 0.75
            f.zzz = 0.4
            f.ears = -0.5

        case .asleep:
            f.setEyes(EyeState(width: 1.1, height: 0.07, radius: 0.5, dy: 0.12))
            f.color = FaceColor(hex: 0x3F6F90)
            f.brightness = 0.45
            f.zzz = 1
            f.ears = -0.8

        case .thinking:
            f.setEyes(EyeState(width: 0.92, height: 0.92, radius: 0.48, upperLid: 0.16, upperAngle: 6))
            f.color = FaceColor(hex: 0xA98CFF)
            f.gazeX = 0.5
            f.gazeY = -0.5
            f.thinkingDots = 1

        case .listening:
            f.setEyes(EyeState(height: 1.06, iris: 0.4))
            f.ears = 1

        case .confused:
            f.left = EyeState(width: 0.9, height: 0.7, radius: 0.4, upperLid: 0.15, upperAngle: 15)
            f.right = EyeState(width: 1.1, height: 1.1, radius: 0.4, upperAngle: -10)
            f.wobble = 1
            f.question = 1

        case .scared:
            f.setEyes(EyeState(width: 0.85, height: 1.15, upperAngle: -10, tilt: -6, iris: 0.25))
            f.color = FaceColor(hex: 0xCFE8FF)
            f.tremble = 1
            f.ears = -1

        case .smug:
            f.setEyes(EyeState(width: 1.05, height: 0.6, radius: 0.4, upperLid: 0.4, upperAngle: 10, lowerLid: 0.2))
            f.gazeX = 0.3

        case .excited:
            f.setEyes(EyeState(width: 1.1, height: 1.1, star: 1))
            f.color = FaceColor(hex: 0xFFD86F)
            f.sparkles = 1
            f.ears = 1
        }
        return f
    }
}
