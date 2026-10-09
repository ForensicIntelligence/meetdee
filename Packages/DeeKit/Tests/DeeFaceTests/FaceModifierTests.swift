import DeeCore
import Foundation
import Testing
@testable import DeeFace

/// v0.5 face modifiers (contracts-0.5/face.md): `FaceInputs.readyFace`, `lidSoften` and
/// `tilt`, which carry `DeeSelf.ExpressionIntent`'s fields of the same names.
@Suite struct FaceModifierTests {
    static let dt = 1.0 / 60
    static let activities: [FaceActivity] = [.idle, .listening, .thinking, .speaking]

    static func target(_ e: Emotion = .neutral, _ a: FaceActivity = .idle,
                       ready: Double = 0, soften: Double = 0, tilt: Double = 0) -> FaceState {
        FaceAnimator.target(for: FaceInputs(emotion: e, activity: a, readyFace: ready, lidSoften: soften, tilt: tilt))
    }

    static func settled(_ inputs: FaceInputs, seconds: Double = 2) -> (FaceAnimator, FaceFrame) {
        var a = FaceAnimator(seed: 5)
        a.variationAmount = 0
        a.idleDirectorEnabled = false
        var f = a.step(dt, inputs: inputs)
        for _ in 0 ..< Int(seconds * 60) { f = a.step(dt, inputs: inputs) }
        return (a, f)
    }

    // MARK: - Defaults

    @Test func defaultsAreOffAndInert() {
        let i = FaceInputs()
        #expect(i.readyFace == 0 && i.lidSoften == 0 && i.tilt == 0)
        for e in Emotion.allCases {
            for a in Self.activities + [.sleeping] {
                #expect(Self.target(e, a) == FaceAnimator.target(for: FaceInputs(emotion: e, activity: a)), "\(e) \(a)")
            }
        }
    }

    @Test func sleepingIgnoresAllThree() {
        let base = Self.target(.neutral, .sleeping)
        #expect(Self.target(.neutral, .sleeping, ready: 1, soften: 1, tilt: 1) == base)
    }

    // MARK: - Ready face

    @Test(arguments: [Emotion.neutral, .listening, .curious, .worried, .sleepy])
    func readyFaceLiftsAndOpensTheEyes(_ e: Emotion) {
        for a in Self.activities {
            let base = Self.target(e, a), ready = Self.target(e, a, ready: 1)
            for (b, r) in [(base.left, ready.left), (base.right, ready.right)] where b.glyphAmount < 1 {
                #expect(r.upperLid <= b.upperLid)
                #expect(r.height > b.height && r.width > b.width)
                #expect(r.dy < b.dy, "eyes lift")
                #expect(r.gloss >= b.gloss)
                #expect(r.upperAngle == b.upperAngle && r.lowerLid == b.lowerLid, "a lift, not a new emotion")
            }
            #expect(ready.brightness > base.brightness)
            #expect(ready.headTilt == base.headTilt)
            #expect(ready.gazeX == base.gazeX && ready.gazeY == base.gazeY)
        }
    }

    @Test func readyFaceIsSlight() {
        let base = Self.target(.listening, .listening), ready = Self.target(.listening, .listening, ready: 1)
        #expect(ready.left.height / base.left.height < 1.1)
        #expect(ready.left.width / base.left.width < 1.05)
        #expect(abs(ready.left.dy - base.left.dy) <= 0.06 + 1e-12)
    }

    @Test func readyFaceRaisesSleepyLids() {
        let base = Self.target(.sleepy), ready = Self.target(.sleepy, ready: 1)
        #expect(base.left.upperLid > 0.2)
        #expect(abs(ready.left.upperLid - base.left.upperLid * 0.4) < 1e-9)
    }

    // MARK: - Lid softening

    @Test(arguments: [Emotion.neutral, .listening, .curious, .angry, .worried])
    func lidSoftenLowersAndRelaxes(_ e: Emotion) {
        let base = Self.target(e), soft = Self.target(e, soften: 1)
        for (b, s) in [(base.left, soft.left), (base.right, soft.right)] where b.glyphAmount < 1 {
            #expect(s.upperLid > b.upperLid || s.upperLid == 0.85)
            #expect(abs(s.upperAngle) <= abs(b.upperAngle), "slants relax")
            #expect(s.radius >= b.radius)
            #expect(s.height < b.height)
        }
        #expect(soft.brightness < base.brightness)
        #expect(soft.gazeX == base.gazeX && soft.gazeY == base.gazeY && soft.headTilt == base.headTilt)
    }

    @Test func lidSoftenIsNotLidNarrow() {
        let angry = Self.target(.angry)
        let soft = Self.target(.angry, soften: 1)
        let narrow = FaceAnimator.target(for: FaceInputs(emotion: .angry, lidNarrow: 0.22))
        #expect(abs(soft.left.upperLid - narrow.left.upperLid) < 1e-9, "same drop")
        #expect(narrow.left.upperAngle == angry.left.upperAngle, "narrowing keeps the scowl")
        #expect(abs(soft.left.upperAngle) < abs(angry.left.upperAngle) * 0.5, "softening eases it")
    }

    @Test func readyAndSoftenTogetherPartlyCancel() {
        let base = Self.target(.listening, .listening)
        let both = Self.target(.listening, .listening, ready: 1, soften: 1)
        #expect(abs(both.left.dy - base.left.dy) < 0.06)
        #expect(abs(both.brightness - base.brightness) < 0.02)
    }

    // MARK: - Tilt

    @Test func tiltRollsTheWholeFace() {
        for e in [Emotion.neutral, .curious, .sad, .joy] {
            let base = Self.target(e)
            for v in [-1.0, -0.5, 0.25, 1] {
                let t = Self.target(e, tilt: v)
                #expect(abs(t.headTilt - (base.headTilt + FaceAnimator.maxTiltDegrees * v)) < 1e-9)
                var same = t
                same.headTilt = base.headTilt
                #expect(same == base, "tilt changes only the roll")
            }
        }
        #expect(Self.target(tilt: 5).headTilt == FaceAnimator.maxTiltDegrees)
        #expect(Self.target(tilt: -5).headTilt == -FaceAnimator.maxTiltDegrees)
        // Positive tilt turns the same way as curious's own tilt.
        #expect(Self.target(.curious).headTilt > 0)
    }

    // MARK: - Shared rules

    @Test func glyphEyesKeepTheirShapeButTheHeadStillTilts() {
        let joy = Self.target(.joy)
        #expect(joy.left.glyphAmount == 1)
        let mod = Self.target(.joy, ready: 1, soften: 1, tilt: 1)
        #expect(mod.left == joy.left && mod.right == joy.right)
        #expect(mod.headTilt == joy.headTilt + FaceAnimator.maxTiltDegrees)
    }

    @Test func monotonicInAmount() {
        var lastReadyDY = 1.0, lastSoftLid = -1.0, lastTilt = -100.0
        for k in 0 ... 10 {
            let v = Double(k) / 10
            let r = Self.target(.listening, .listening, ready: v).left.dy
            let s = Self.target(.listening, .listening, soften: v).left.upperLid
            let t = Self.target(.listening, .listening, tilt: v).headTilt
            #expect(r <= lastReadyDY && s >= lastSoftLid && t >= lastTilt)
            lastReadyDY = r; lastSoftLid = s; lastTilt = t
        }
    }

    @Test func extremeInputsStaySane() {
        let base = Self.target(.listening, .listening)
        for v in [-Double.infinity, -9, -1, 0.5, 1, 9, .infinity, .nan] {
            let t = Self.target(.listening, .listening, ready: v, soften: v, tilt: v)
            #expect(t.components.allSatisfy { $0.isFinite })
            #expect(t.left.height > 0 && t.left.upperLid <= 0.85 && t.left.radius <= 0.5)
            #expect(abs(t.headTilt - base.headTilt) <= FaceAnimator.maxTiltDegrees)
        }
        #expect(Self.target(.listening, .listening, ready: .nan, soften: .nan, tilt: .nan) == base)
        #expect(Self.target(.listening, .listening, ready: -3, soften: -3) == base)
    }

    @Test func combinesWithListenPreviewAndLidNarrow() {
        let preview = FaceAnimator.target(for: FaceInputs(emotion: .listening, activity: .listening,
                                                          listenValence: 0.6, listenIntensity: 0.5, lidNarrow: 0.2))
        let all = FaceAnimator.target(for: FaceInputs(emotion: .listening, activity: .listening,
                                                      listenValence: 0.6, listenIntensity: 0.5, lidNarrow: 0.2,
                                                      readyFace: 0.8, tilt: 0.5))
        #expect(all.left.lowerLid == preview.left.lowerLid, "smile arcs kept")
        #expect(all.left.upperLid < preview.left.upperLid && all.left.dy < preview.left.dy)
        #expect(all.headTilt == preview.headTilt + 5)
        let tint = FaceColor(0.9, 0.2, 0.2)
        #expect(FaceAnimator.target(for: FaceInputs(tint: tint, readyFace: 1, lidSoften: 1)).color == tint)
    }

    // MARK: - Animator

    @Test func animatorSettlesOnTheModifiedTarget() {
        let i = FaceInputs(emotion: .listening, activity: .listening, readyFace: 1, tilt: -1)
        let (a, f) = Self.settled(i)
        #expect(abs(f.state.headTilt - a.goal.headTilt) < 0.2)
        #expect(abs(a.goal.headTilt - (Self.target(.listening, .listening).headTilt - 10)) < 1e-9)
        #expect(abs(f.state.left.dy - a.goal.left.dy) < 0.01)
    }

    @Test func modifierChangesDoNotBlinkOrReroll() {
        // Same seed, same emotion and activity: changing only the modifiers leaves the
        // blink track and the random stream (gaze saccades) exactly as without them.
        let base = FaceInputs(emotion: .listening, activity: .listening)
        var plain = Self.settled(base).0, modded = plain
        for k in 0 ..< 600 {
            var i = base
            i.readyFace = Double(k % 10) / 10
            i.lidSoften = Double((k + 5) % 10) / 20
            i.tilt = sin(Double(k) / 4)
            let f0 = plain.step(Self.dt, inputs: base), f1 = modded.step(Self.dt, inputs: i)
            #expect(f0.blink == f1.blink, "a modifier is not an emotion change (frame \(k))")
            #expect(f0.state.gazeX == f1.state.gazeX && f0.state.gazeY == f1.state.gazeY)
        }
        _ = plain.step(Self.dt, inputs: base)
        _ = modded.step(Self.dt, inputs: base)
        #expect(plain.goal == modded.goal, "no variation re-roll")
    }

    @Test func deterministicForSeed() {
        func run() -> [FaceFrame] {
            var a = FaceAnimator(seed: 77)
            return (0 ..< 240).map { k in
                a.step(Self.dt, inputs: FaceInputs(emotion: .curious, activity: .listening,
                                                   readyFace: Double(k % 60) / 60, lidSoften: 0.3, tilt: cos(Double(k) / 30)))
            }
        }
        #expect(run() == run())
    }
}
