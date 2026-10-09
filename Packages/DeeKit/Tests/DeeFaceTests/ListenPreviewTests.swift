import DeeCore
import Foundation
import Testing
@testable import DeeFace

/// v0.5 face contract (SELF.md §2, §3.5, §7.2): the listening preview, lid narrowing,
/// projection gaze points, and the pinned `Performance` raw values that
/// `DeeSelf.Mannerism` mirrors.
@Suite struct ListenPreviewTests {
    static let dt = 1.0 / 60

    static func listening(_ valence: Double, _ intensity: Double, emotion: Emotion = .listening) -> FaceInputs {
        FaceInputs(emotion: emotion, activity: .listening, listenValence: valence, listenIntensity: intensity)
    }

    static func settled(_ inputs: FaceInputs, seconds: Double = 2, seed: UInt64 = 11) -> FaceAnimator {
        var a = FaceAnimator(seed: seed)
        a.variationAmount = 0
        a.idleDirectorEnabled = false
        for _ in 0..<Int(seconds * 60) { _ = a.step(dt, inputs: inputs) }
        return a
    }

    // MARK: - Performance raw values (mirrored by DeeSelf.Mannerism)

    @Test func performanceRawValuesArePinned() {
        let expected = [
            "wink", "blinkLeft", "blinkRight", "yawn", "eyeRoll", "doubleTake", "nod", "headShake", "giggle",
            "squint", "lookAround", "startle", "sigh", "bounce", "shiver", "contentSquint", "dizzySpin",
        ]
        #expect(Performance.allCases.map(\.rawValue) == expected)
        for raw in expected { #expect(Performance(rawValue: raw)?.rawValue == raw) }
        #expect(Performance(rawValue: "Nod") == nil)
    }

    // MARK: - Defaults and inertness

    @Test func defaultsAreOff() {
        let i = FaceInputs()
        #expect(i.listenValence == 0 && i.listenIntensity == 0 && i.lidNarrow == 0)
        // Old call sites (no new arguments) produce the exact pre-0.5 target.
        let plain = FaceAnimator.target(for: FaceInputs(emotion: .listening, activity: .listening))
        #expect(FaceAnimator.target(for: Self.listening(0, 0)) == plain)
        #expect(FaceAnimator.target(for: Self.listening(0.9, 0)) == plain)
        #expect(FaceAnimator.target(for: Self.listening(0, 1)) == plain)
    }

    @Test(arguments: [FaceActivity.idle, .thinking, .speaking, .sleeping])
    func previewOnlyAppliesWhileListening(_ activity: FaceActivity) {
        let base = FaceAnimator.target(for: FaceInputs(emotion: .neutral, activity: activity))
        let with = FaceAnimator.target(for: FaceInputs(emotion: .neutral, activity: activity, listenValence: -1, listenIntensity: 1))
        #expect(with == base)
    }

    @Test func weightSaturatesAndClamps() {
        #expect(FaceAnimator.listenPreviewWeight(valence: 0.25, intensity: 1) == 0.5)
        #expect(FaceAnimator.listenPreviewWeight(valence: 0.5, intensity: 0.5) == 0.5)
        #expect(FaceAnimator.listenPreviewWeight(valence: 3, intensity: 7) == 1)
        #expect(FaceAnimator.listenPreviewWeight(valence: -3, intensity: 0.4) == -0.4)
        #expect(FaceAnimator.listenPreviewWeight(valence: 0.8, intensity: -1) == 0)
        #expect(FaceAnimator.listenPreviewWeight(valence: .nan, intensity: 1) == 0)
        #expect(FaceAnimator.listenPreviewWeight(valence: 1, intensity: .infinity) == 0)
        #expect(FaceAnimator.listenPreviewWeight(valence: .infinity, intensity: 1) == 0)
    }

    // MARK: - Direction

    @Test func positivePreviewMakesSoftSmileArcs() {
        let plain = FaceAnimator.target(for: Self.listening(0, 0))
        let pos = FaceAnimator.target(for: Self.listening(0.6, 0.5))
        for (p, e) in [(plain.left, pos.left), (plain.right, pos.right)] {
            #expect(e.lowerLid > p.lowerLid + 0.15, "smile arcs from below")
            #expect(e.height < p.height)
            #expect(e.dy < p.dy)
            #expect(e.upperAngle == p.upperAngle && e.upperLid == p.upperLid, "no concern")
            #expect(e.dominantGlyph == "slab", "a preview, not a glyph")
            #expect(e.lowerLid < Expressions.target(for: .happy).left.lowerLid, "softer than full happy")
        }
        #expect(pos.color.g >= plain.color.g)
    }

    @Test func negativePreviewMakesConcernedLids() {
        let plain = FaceAnimator.target(for: Self.listening(0, 0))
        let neg = FaceAnimator.target(for: Self.listening(-0.6, 0.5))
        for (p, e) in [(plain.left, neg.left), (plain.right, neg.right)] {
            #expect(e.upperAngle < p.upperAngle - 5, "inner corners raised")
            #expect(e.upperLid > p.upperLid)
            #expect(e.tilt < p.tilt)
            #expect(e.lowerLid == p.lowerLid, "no smile")
        }
        // Drawn in toward each other.
        #expect(neg.left.dx > plain.left.dx && neg.right.dx < plain.right.dx)
        #expect(neg.ears < plain.ears)
    }

    @Test func intensityScalesMonotonically() {
        var lastLower = -1.0, lastAngle = 1.0
        for k in 0...10 {
            let i = Double(k) / 10
            let pos = FaceAnimator.target(for: Self.listening(0.7, i))
            let neg = FaceAnimator.target(for: Self.listening(-0.7, i))
            #expect(pos.left.lowerLid >= lastLower)
            #expect(neg.left.upperAngle <= lastAngle)
            lastLower = pos.left.lowerLid
            lastAngle = neg.left.upperAngle
        }
        let half = FaceAnimator.target(for: Self.listening(1, 0.5)).left.lowerLid
        let full = FaceAnimator.target(for: Self.listening(1, 1)).left.lowerLid
        #expect(abs(half - 0.2) < 1e-9 && abs(full - 0.4) < 1e-9)
    }

    @Test func previewNeverMovesGaze() {
        let plain = FaceAnimator.target(for: Self.listening(0, 0))
        for v in [-1.0, -0.3, 0.3, 1] {
            let t = FaceAnimator.target(for: Self.listening(v, 1))
            #expect(t.gazeX == plain.gazeX && t.gazeY == plain.gazeY)
        }
    }

    @Test func tintStillWinsOverPreviewColour() {
        let tint = FaceColor(0.2, 0.9, 0.3)
        var i = Self.listening(-1, 1)
        i.tint = tint
        #expect(FaceAnimator.target(for: i).color == tint)
    }

    @Test func glyphReflexEyesAreLeftAlone() {
        // A giggle-like reflex during listening (joy = ∩ arcs) must not get extra lids.
        let plain = FaceAnimator.target(for: Self.listening(0, 0, emotion: .joy))
        let neg = FaceAnimator.target(for: Self.listening(-1, 1, emotion: .joy))
        #expect(neg.left == plain.left && neg.right == plain.right)
    }

    @Test func extremeInputsStaySane() {
        for v in [-Double.infinity, -50, -1, 1, 50, .infinity, .nan] {
            for i in [-1.0, 0.5, 1, 9, .nan] {
                let t = FaceAnimator.target(for: Self.listening(v, i))
                #expect(t.components.allSatisfy { $0.isFinite })
                #expect(t.left.height > 0 && t.right.height > 0)
                #expect(t.left.upperLid <= 0.85 && t.left.lowerLid <= 0.85)
            }
        }
    }

    // MARK: - Animator behaviour

    @Test func animatorSettlesTowardPreviewWithoutBlinkingOrRerolling() {
        var a = Self.settled(Self.listening(0, 0))
        let plainGoal = a.goal
        // Previews arrive at ≤ 2 Hz and change continuously: no reaction blink each time.
        var blinked = false
        for k in 0..<120 {
            let v = 0.2 + 0.4 * Double(k % 30) / 30
            let f = a.step(Self.dt, inputs: Self.listening(v, 0.5))
            if f.blink > 0.5, k < 20 { blinked = true }
        }
        #expect(!blinked, "preview changes must not trigger the emotion-change blink")
        let f = a.step(Self.dt, inputs: Self.listening(0.6, 0.5))
        #expect(a.goal.left.lowerLid > plainGoal.left.lowerLid + 0.15)
        #expect(abs(f.state.left.lowerLid - a.goal.left.lowerLid) < 0.05, "springs follow")
    }

    @Test func deterministicForSeed() {
        func run() -> [FaceFrame] {
            var a = FaceAnimator(seed: 42)
            var out: [FaceFrame] = []
            for k in 0..<240 {
                let v = sin(Double(k) / 20)
                out.append(a.step(Self.dt, inputs: Self.listening(v, 0.5)))
            }
            return out
        }
        #expect(run() == run())
    }

    @Test func mutualGazeHoldsWhilePreviewing() {
        let user = SIMD2<Double>(0.2, -0.1)
        var plain = Self.listening(0, 0)
        plain.lookAt = user
        var neg = Self.listening(-1, 0.5)
        neg.lookAt = user
        let a = Self.settled(plain), b = Self.settled(neg)
        #expect(abs(a.state.gazeX - b.state.gazeX) < 0.07)
        #expect(abs(a.state.gazeY - b.state.gazeY) < 0.07)
    }

    // MARK: - Lid narrowing and gaze points

    @Test func lidNarrowLowersUpperLidsOnSlabEyesOnly() {
        let base = FaceAnimator.target(for: FaceInputs())
        let narrow = FaceAnimator.target(for: FaceInputs(lidNarrow: FaceGaze.examineLids))
        #expect(abs(narrow.left.upperLid - (base.left.upperLid + 0.2)) < 1e-9)
        #expect(abs(narrow.right.upperLid - (base.right.upperLid + 0.2)) < 1e-9)
        let joy = FaceAnimator.target(for: FaceInputs(emotion: .joy))
        #expect(FaceAnimator.target(for: FaceInputs(emotion: .joy, lidNarrow: 1)) == joy)
        #expect(FaceAnimator.target(for: FaceInputs(activity: .sleeping, lidNarrow: 1)) == FaceAnimator.target(for: FaceInputs(activity: .sleeping)))
        let max = FaceAnimator.target(for: FaceInputs(emotion: .sleepy, lidNarrow: .infinity))
        #expect(max.left.upperLid <= 0.85 && max.left.upperLid.isFinite)
        #expect(FaceAnimator.target(for: FaceInputs(lidNarrow: .nan)) == base)
    }

    @Test func gazePointsAreInRangeAndPointTheRightWay() {
        #expect(FaceGaze.away.x < 0 && FaceGaze.away.y < 0, "up-left")
        #expect(FaceGaze.examineBack == SIMD2(0, 0.35))
        #expect(FaceGaze.examineLids == 0.2)
        #expect(FaceGaze.side(1).x > 0.5 && FaceGaze.side(-1).x < -0.5)
        #expect(FaceGaze.side(9) == FaceGaze.side(1))
        #expect(FaceGaze.side(.nan) == SIMD2(0, 0))
        for p in [FaceGaze.away, FaceGaze.examineBack, FaceGaze.side(-3)] {
            #expect(abs(p.x) <= 1 && abs(p.y) <= 1)
        }
    }

    @Test func awayGazeActuallyLooksAway() {
        var i = FaceInputs(activity: .speaking)
        i.lookAt = FaceGaze.away
        let a = Self.settled(i, seconds: 1)
        #expect(a.state.gazeX < -0.3 && a.state.gazeY < -0.3)
    }
}
