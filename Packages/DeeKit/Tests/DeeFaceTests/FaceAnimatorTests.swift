import DeeCore
import Foundation
import SwiftUI
import Testing
@testable import DeeFace

/// Behavioural tests for the procedural face animator. They check directions and
/// invariants (convergence, overshoot-then-settle, blink cadence, bounds) rather than
/// exact tuning constants.
@Suite struct FaceAnimatorTests {
    static let dt = 1.0 / 60

    /// Components the gaze layer overwrites every frame (gazeX, gazeY).
    static let gazeIndices: Set<Int> = [2 * EyeState.count, 2 * EyeState.count + 1]

    static func run(_ a: inout FaceAnimator, seconds: Double, inputs: FaceInputs, dt: Double = dt) -> [FaceFrame] {
        var frames: [FaceFrame] = []
        for _ in 0..<Int((seconds / dt).rounded()) { frames.append(a.step(dt, inputs: inputs)) }
        return frames
    }

    static func maxError(_ a: FaceState, _ b: FaceState, skipping skip: Set<Int> = gazeIndices) -> Double {
        let x = a.components, y = b.components
        return x.indices.filter { !skip.contains($0) }.map { abs(x[$0] - y[$0]) }.max() ?? 0
    }

    /// Contiguous runs of blink > 0: (start time, end time, peak).
    static func blinkEpisodes(_ frames: [FaceFrame]) -> [(start: Double, end: Double, peak: Double)] {
        var out: [(Double, Double, Double)] = []
        var cur: (Double, Double, Double)?
        for f in frames {
            if f.blink > 1e-9 {
                if cur == nil { cur = (f.time, f.time, f.blink) }
                cur!.1 = f.time
                cur!.2 = max(cur!.2, f.blink)
            } else if let c = cur {
                out.append(c)
                cur = nil
            }
        }
        if let c = cur { out.append(c) }
        return out
    }

    // MARK: - Springs

    @Test(arguments: Emotion.allCases)
    func convergesToEachEmotionWithinTwoSeconds(_ emotion: Emotion) {
        // Start from a far-away expression so every emotion has real distance to cover.
        let start: Emotion = emotion == .asleep ? .surprised : .asleep
        var a = FaceAnimator(seed: 1, initial: start)
        let inputs = FaceInputs(emotion: emotion, reduceMotion: true)
        let target = FaceAnimator.target(for: inputs)
        let initialError = Self.maxError(a.state, target)
        _ = Self.run(&a, seconds: 2.0, inputs: inputs)
        let err = Self.maxError(a.state, target)
        // Angles are in degrees, so allow a relative tolerance against the starting gap.
        #expect(err < max(0.02, initialError * 0.02), "\(emotion): residual \(err) of \(initialError)")
    }

    @Test func springsOvershootALittleThenSettle() {
        var a = FaceAnimator(seed: 3, initial: .neutral)
        let inputs = FaceInputs(emotion: .surprised, reduceMotion: true)
        let goal = Expressions.target(for: .surprised).left.height // 1.25, up from 1.0
        let start = a.state.left.height
        let frames = Self.run(&a, seconds: 3.0, inputs: inputs)
        let heights = frames.map(\.state.left.height)
        let peak = heights.max()!
        let span = goal - start
        #expect(peak > goal, "underdamped spring should overshoot")
        #expect(peak - goal < 0.2 * span, "overshoot should be small, got \(peak - goal) of \(span)")
        #expect(abs(heights.last! - goal) < 0.005 * span + 1e-6, "should settle on target")
    }

    @Test func faceStateComponentsRoundTrip() {
        for e in Emotion.allCases {
            let s = Expressions.target(for: e)
            #expect(s.components.count == FaceState.count)
            #expect(FaceState(components: s.components) == s, "\(e)")
        }
        var custom = FaceState()
        custom.left = EyeState(width: 0.1, height: 0.2, radius: 0.3, upperLid: 0.4, upperAngle: 5, lowerLid: 0.6, tilt: 7, dx: 0.8, dy: 0.9, iris: 0.11, heart: 0.12, star: 0.13)
        custom.right = EyeState(width: 1.1, height: 1.2, radius: 1.3, upperLid: 1.4, upperAngle: -5, lowerLid: 1.6, tilt: -7, dx: -0.8, dy: -0.9, iris: 0.21, heart: 0.22, star: 0.23)
        custom.gazeX = 0.31; custom.gazeY = -0.32
        custom.color = FaceColor(0.17, 0.27, 0.37)
        custom.brightness = 0.47; custom.headTilt = 12; custom.ears = -0.5
        custom.zzz = 0.67; custom.question = 0.77; custom.sparkles = 0.87; custom.thinkingDots = 0.97
        custom.wobble = 0.15; custom.giggle = 0.25; custom.tremble = 0.35
        #expect(FaceState(components: custom.components) == custom)
        // Every component is distinct, so a swapped slot would be caught.
        #expect(Set(custom.components.dropLast()).count == FaceState.count - 1)
    }

    // MARK: - Blink

    @Test func firstNaturalBlinkWithinExpectedInterval() {
        for seed: UInt64 in [1, 2, 3, 42, 0xD33] {
            var a = FaceAnimator(seed: seed)
            let frames = Self.run(&a, seconds: 6, inputs: FaceInputs())
            let first = frames.first { $0.blink > 0 }
            #expect(first != nil, "seed \(seed): no blink in 6 s")
            if let first { #expect(first.time <= 4.0 + 2 * Self.dt, "seed \(seed): first blink at \(first.time)") }
        }
    }

    @Test func blinkClosesFullyAndReopens() {
        var a = FaceAnimator(seed: 5)
        _ = Self.run(&a, seconds: 0.1, inputs: FaceInputs())
        a.blinkNow()
        let frames = Self.run(&a, seconds: 0.5, inputs: FaceInputs())
        let blinks = frames.map(\.blink)
        #expect(blinks.max()! > 0.99, "a forced blink should shut the eyes")
        #expect(blinks.allSatisfy { $0 >= 0 && $0 <= 1 })
        // Fully open again within close + hold + open (~0.29 s) plus a frame.
        let reopened = frames.first { $0.time > frames[0].time + 0.3 + Self.dt && $0.blink == 0 }
        #expect(reopened != nil)
        #expect(frames.last!.blink == 0)
    }

    @Test func doubleAndPartialBlinksOccurOverLongRuns() {
        var sawPartial = false, sawDouble = false
        for seed: UInt64 in [1, 2, 3, 4, 5] {
            var a = FaceAnimator(seed: seed)
            let frames = Self.run(&a, seconds: 300, inputs: FaceInputs())
            let eps = Self.blinkEpisodes(frames)
            #expect(eps.count > 20, "seed \(seed): only \(eps.count) blinks in 5 min")
            #expect(eps.allSatisfy { $0.end - $0.start < 0.35 }, "every blink should reopen")
            if eps.contains(where: { $0.peak > 0.5 && $0.peak < 0.95 }) { sawPartial = true }
            for (p, n) in zip(eps, eps.dropFirst()) where n.start - p.end < 0.5 { sawDouble = true }
        }
        #expect(sawPartial, "expected some partial blinks")
        #expect(sawDouble, "expected some double blinks")
    }

    @Test func noBlinkingWhileSleeping() {
        var a = FaceAnimator(seed: 9, initial: .asleep)
        let frames = Self.run(&a, seconds: 60, inputs: FaceInputs(activity: .sleeping))
        #expect(frames.allSatisfy { $0.blink == 0 })
        // Even a forced blink is suppressed while asleep.
        a.blinkNow()
        let more = Self.run(&a, seconds: 1, inputs: FaceInputs(activity: .sleeping))
        #expect(more.allSatisfy { $0.blink == 0 })
    }

    @Test func fallingAsleepMidBlinkOpensNothingAndStaysShut() {
        var a = FaceAnimator(seed: 9)
        _ = Self.run(&a, seconds: 0.2, inputs: FaceInputs())
        a.blinkNow()
        _ = a.step(Self.dt, inputs: FaceInputs())
        let frames = Self.run(&a, seconds: 5, inputs: FaceInputs(activity: .sleeping))
        #expect(frames.allSatisfy { $0.blink == 0 })
    }

    // MARK: - dt clamping

    @Test func hugeOrNegativeDtIsClamped() {
        var a = FaceAnimator(seed: 11)
        let inputs = FaceInputs(emotion: .excited)
        let f1 = a.step(1000, inputs: inputs)
        #expect(f1.time <= 0.1, "a huge dt must be clamped, time jumped to \(f1.time)")
        #expect(f1.state.components.allSatisfy { $0.isFinite })
        let f2 = a.step(.infinity, inputs: inputs)
        #expect(f2.time.isFinite && f2.time <= 0.2)
        #expect(f2.state.components.allSatisfy { $0.isFinite })
        let f3 = a.step(-5, inputs: inputs)
        #expect(f3.time == f2.time, "negative dt must not run time backwards")
        // A long stall of huge dts still converges without blowing up.
        var last = f3
        for _ in 0..<200 { last = a.step(10, inputs: inputs) }
        #expect(last.state.components.allSatisfy { $0.isFinite })
        #expect(Self.maxError(last.state, FaceAnimator.target(for: inputs)) < 0.05)
        #expect(last.blink.isFinite && last.breath.isFinite && last.voice.isFinite)
    }

    /// Regression: `step(.nan)` used to trap in `Int((dt / (1/240)).rounded(.up))`.
    @Test func nanDtDoesNotCrashOrPoisonState() {
        var a = FaceAnimator(seed: 11)
        let f = a.step(.nan, inputs: FaceInputs())
        #expect(f.time == 0, "NaN counts as no time passing")
        #expect(f.state.components.allSatisfy { $0.isFinite })
        let g = a.step(-.infinity, inputs: FaceInputs(emotion: .angry))
        #expect(g.time == 0)
        // Normal stepping carries on afterwards.
        let frames = Self.run(&a, seconds: 1, inputs: FaceInputs(emotion: .angry, tint: FaceColor(1, 0, 0)))
        #expect(frames.allSatisfy { $0.state.components.allSatisfy(\.isFinite) && $0.blink.isFinite })
        #expect(frames.last!.time > 0.9)
    }

    // MARK: - Gaze

    @Test func gazeFollowsLookAtWithinBounds() {
        let targets: [SIMD2<Double>] = [[0.8, -0.6], [-0.7, 0.5], [0, 0], [5, -5], [-9, 9]]
        for look in targets {
            var a = FaceAnimator(seed: 13)
            let inputs = FaceInputs(lookAt: look)
            let frames = Self.run(&a, seconds: 1.5, inputs: inputs)
            #expect(frames.allSatisfy { abs($0.state.gazeX) <= 1 && abs($0.state.gazeY) <= 1 })
            let g = frames.last!.state
            let want = SIMD2(min(max(look.x, -1), 1), min(max(look.y, -1), 1))
            if abs(want.x) > 0.1 { #expect(g.gazeX.sign == want.x.sign, "look \(look) gaze \(g.gazeX)") }
            if abs(want.y) > 0.1 { #expect(g.gazeY.sign == want.y.sign, "look \(look) gaze \(g.gazeY)") }
            #expect(abs(g.gazeX - want.x) < 0.25 && abs(g.gazeY - want.y) < 0.25, "look \(look) → \(g.gazeX), \(g.gazeY)")
        }
    }

    @Test func gazeTracksAMovingTarget() {
        var a = FaceAnimator(seed: 14)
        _ = Self.run(&a, seconds: 1, inputs: FaceInputs(lookAt: [-0.8, 0]))
        let left = a.state.gazeX
        _ = Self.run(&a, seconds: 1, inputs: FaceInputs(lookAt: [0.8, 0]))
        let right = a.state.gazeX
        #expect(left < -0.4)
        #expect(right > 0.4)
    }

    @Test func idleGazeStaysInBounds() {
        var a = FaceAnimator(seed: 15)
        for activity in [FaceActivity.idle, .thinking, .listening, .speaking, .sleeping] {
            let frames = Self.run(&a, seconds: 20, inputs: FaceInputs(emotion: .curious, activity: activity))
            #expect(frames.allSatisfy { abs($0.state.gazeX) <= 1 && abs($0.state.gazeY) <= 1 }, "\(activity)")
        }
    }

    // MARK: - Colour

    @Test func tintOverridesExpressionColour() {
        let red = FaceColor(1, 0, 0)
        for e in Emotion.allCases {
            #expect(FaceAnimator.target(for: FaceInputs(emotion: e, tint: red)).color == red)
        }
        // Also wins over activity targets.
        #expect(FaceAnimator.target(for: FaceInputs(activity: .sleeping, tint: red)).color == red)
        #expect(FaceAnimator.target(for: FaceInputs(activity: .thinking, tint: red)).color == red)
        // Without a tint the expression's own colour is used.
        #expect(FaceAnimator.target(for: FaceInputs(emotion: .love)).color == Expressions.target(for: .love).color)

        // The tint is smoothed (~3 s time constant) but does arrive.
        var a = FaceAnimator(seed: 17, initial: .happy)
        _ = Self.run(&a, seconds: 15, inputs: FaceInputs(emotion: .happy, tint: red))
        let c = a.state.color
        #expect(abs(c.r - 1) < 0.02 && abs(c.g) < 0.02 && abs(c.b) < 0.02)
    }

    /// Realism rec 13: a big regard swing (yellow → red after one shout) should read as a
    /// visible shift over a few seconds, not a snap — and never overshoot.
    @Test func tintJumpShiftsSmoothlyOverAboutThreeSeconds() {
        let yellow = FaceColor(1, 0.85, 0.2), red = FaceColor(1, 0.1, 0.1)
        var a = FaceAnimator(seed: 5, initial: .neutral)
        _ = Self.run(&a, seconds: 30, inputs: FaceInputs(tint: yellow))
        #expect(abs(a.state.color.g - yellow.g) < 1e-3)
        let frames = Self.run(&a, seconds: 20, inputs: FaceInputs(tint: red))
        let g = frames.map(\.state.color.g)
        func progress(at seconds: Double) -> Double {
            (yellow.g - g[Int(seconds * 60) - 1]) / (yellow.g - red.g)
        }
        #expect(progress(at: 0.25) < 0.1, "no snap: \(progress(at: 0.25))")
        #expect(progress(at: 1) < 0.5)
        #expect(abs(progress(at: FaceAnimator.tintTimeConstant) - (1 - exp(-1))) < 0.05, "~63% at τ, got \(progress(at: FaceAnimator.tintTimeConstant))")
        #expect(progress(at: 10) > 0.98)
        // Critically damped: monotonic, never past the target.
        #expect(zip(g, g.dropFirst()).allSatisfy { $1 <= $0 + 1e-12 })
        #expect(g.allSatisfy { $0 >= red.g - 1e-9 })
    }

    /// Without a tint, expression colours still change quickly — and without overshoot.
    @Test func expressionColourIsQuickAndNeverOvershoots() {
        var a = FaceAnimator(seed: 6, initial: .neutral)
        let frames = Self.run(&a, seconds: 2, inputs: FaceInputs(emotion: .angry, reduceMotion: true))
        let goal = Expressions.target(for: .angry).color
        let start = Expressions.target(for: .neutral).color
        let after05 = frames[29].state.color
        #expect(abs(after05.r - goal.r) + abs(after05.g - goal.g) + abs(after05.b - goal.b) < 0.05, "settled within 0.5 s")
        for f in frames {
            for (v, lo, hi) in [(f.state.color.r, min(start.r, goal.r), max(start.r, goal.r)),
                                (f.state.color.g, min(start.g, goal.g), max(start.g, goal.g)),
                                (f.state.color.b, min(start.b, goal.b), max(start.b, goal.b))] {
                #expect(v >= lo - 1e-9 && v <= hi + 1e-9)
            }
        }
    }

    @Test func rendererClampsColour() {
        var st = FaceState()
        st.color = FaceColor(1.3, -0.2, .nan)
        st.brightness = 1.1
        let c = FaceRenderer.eyeRGB(st)
        #expect(c.r == 1 && c.g == 0 && c.b == 0)
        st.color = FaceColor(0.5, 0.25, 1)
        st.brightness = 0.5
        let d = FaceRenderer.eyeRGB(st)
        #expect(d.r == 0.25 && d.g == 0.125 && d.b == 0.5)
    }

    // MARK: - Frame rate

    @Test func wantsHighFrameRateOnlyForFastMotion() {
        // Speaking: always high.
        var a = FaceAnimator(seed: 31)
        for _ in 0..<120 {
            _ = a.step(Self.dt, inputs: FaceInputs(activity: .speaking, speechLevel: 0.5, reduceMotion: true))
            #expect(a.wantsHighFrameRate)
        }
        // Sleeping: never.
        var s = FaceAnimator(seed: 32)
        for _ in 0..<600 {
            _ = s.step(Self.dt, inputs: FaceInputs(activity: .sleeping))
            #expect(!s.wantsHighFrameRate)
        }
        // Idle: high during a blink, low most of the rest of the time.
        var b = FaceAnimator(seed: 33)
        _ = Self.run(&b, seconds: 2, inputs: FaceInputs())
        b.blinkNow()
        _ = b.step(Self.dt, inputs: FaceInputs())
        #expect(b.wantsHighFrameRate, "mid-blink")
        var high = 0, n = 0
        for _ in 0..<(60 * 60) {
            let f = b.step(Self.dt, inputs: FaceInputs())
            n += 1
            if b.wantsHighFrameRate { high += 1 }
            if f.blink > 0.05 { #expect(b.wantsHighFrameRate, "blink at t=\(f.time) must be high-rate") }
        }
        let share = Double(high) / Double(n)
        #expect(share > 0.02 && share < 0.4, "idle face should mostly run at 60 Hz, high share \(share)")
    }

    @Test func frameRatePolicy() {
        typealias R = FaceFrameRate
        #expect(R.minimumInterval(sleeping: false, wantsHighFrameRate: false, reduceMotion: false, lowPower: false, thermal: .nominal) == 1.0 / 60)
        #expect(R.minimumInterval(sleeping: false, wantsHighFrameRate: true, reduceMotion: false, lowPower: false, thermal: .fair) == 1.0 / 120)
        #expect(R.minimumInterval(sleeping: true, wantsHighFrameRate: true, reduceMotion: false, lowPower: false, thermal: .nominal) == 1.0 / 30)
        #expect(R.minimumInterval(sleeping: false, wantsHighFrameRate: true, reduceMotion: true, lowPower: false, thermal: .nominal) == 1.0 / 30)
        #expect(R.minimumInterval(sleeping: false, wantsHighFrameRate: true, reduceMotion: false, lowPower: true, thermal: .nominal) == 1.0 / 30)
        #expect(R.minimumInterval(sleeping: false, wantsHighFrameRate: true, reduceMotion: false, lowPower: false, thermal: .serious) == 1.0 / 30)
        #expect(R.minimumInterval(sleeping: false, wantsHighFrameRate: false, reduceMotion: false, lowPower: false, thermal: .critical) == 1.0 / 30)
    }

    /// The renderer still draws every expression (single-layer glow path) without trapping.
    @MainActor @Test func rendererDrawsEveryExpression() throws {
        for e in Emotion.allCases {
            var a = FaceAnimator(seed: 3, initial: e)
            let frame = a.step(Self.dt, inputs: FaceInputs(emotion: e, tint: FaceColor(1.2, -0.1, 0.5)))
            let view = Canvas { ctx, size in FaceRenderer(showEars: true).draw(frame, in: &ctx, size: size) }
                .frame(width: 200, height: 160)
            let r = ImageRenderer(content: view)
            #expect(r.cgImage != nil, "\(e)")
        }
    }

    // MARK: - Determinism & motion

    @Test func sameSeedIsDeterministic() {
        var a = FaceAnimator(seed: 99), b = FaceAnimator(seed: 99)
        let script: [FaceInputs] = [
            FaceInputs(), FaceInputs(emotion: .happy, activity: .listening, micLevel: 0.6),
            FaceInputs(emotion: .angry, lookAt: [0.3, 0.2], tint: FaceColor(1, 0, 0)),
            FaceInputs(activity: .speaking, speechLevel: 0.8), FaceInputs(activity: .thinking),
        ]
        for inputs in script {
            let fa = Self.run(&a, seconds: 3, inputs: inputs)
            let fb = Self.run(&b, seconds: 3, inputs: inputs)
            #expect(fa == fb)
        }
        var c = FaceAnimator(seed: 100), d = FaceAnimator(seed: 99)
        #expect(Self.run(&c, seconds: 10, inputs: FaceInputs()) != Self.run(&d, seconds: 10, inputs: FaceInputs()))
    }

    @Test func reduceMotionDisablesBreathing() {
        var a = FaceAnimator(seed: 21)
        let still = Self.run(&a, seconds: 6, inputs: FaceInputs(reduceMotion: true))
        #expect(still.allSatisfy { $0.breath == 1 })
        var b = FaceAnimator(seed: 21)
        let breathing = Self.run(&b, seconds: 6, inputs: FaceInputs())
        let bs = breathing.map(\.breath)
        #expect(bs.max()! > 1.005 && bs.min()! < 0.995, "breathing should oscillate around 1")
        #expect(bs.allSatisfy { abs($0 - 1) < 0.05 }, "breathing should be subtle")
    }

    @Test func speechAndMicEnvelopesFollowInputs() {
        var a = FaceAnimator(seed: 23)
        let talk = Self.run(&a, seconds: 0.5, inputs: FaceInputs(activity: .speaking, speechLevel: 1))
        #expect(talk.last!.voice > 0.9)
        let quiet = Self.run(&a, seconds: 1.5, inputs: FaceInputs(activity: .speaking, speechLevel: 0))
        #expect(quiet.last!.voice < 0.05)
        // Mic level only counts while listening.
        let idleMic = Self.run(&a, seconds: 0.5, inputs: FaceInputs(activity: .idle, micLevel: 1))
        #expect(idleMic.last!.listen < 0.05)
        let listen = Self.run(&a, seconds: 0.5, inputs: FaceInputs(activity: .listening, micLevel: 1))
        #expect(listen.last!.listen > 0.9)
    }
}
