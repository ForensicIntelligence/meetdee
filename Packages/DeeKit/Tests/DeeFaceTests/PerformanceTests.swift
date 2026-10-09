import DeeCore
import Foundation
import Testing
@testable import DeeFace

/// Performances (timed parameter tracks), the idle director and touch glances.
@Suite struct PerformanceTests {
    static let dt = 1.0 / 60

    static func quietAnimator(seed: UInt64 = 5) -> FaceAnimator {
        var a = FaceAnimator(seed: seed)
        a.idleDirectorEnabled = false
        return a
    }

    // MARK: - Tracks

    @Test(arguments: Performance.allCases)
    func trackStartsAndEndsAtRestAndDoesSomething(_ p: Performance) {
        let move = Move.perform(p)
        let rest = Pose()
        #expect(move.pose(at: 0, side: 1) == rest || Self.magnitude(move.pose(at: 0, side: 1)) < 1e-6, "\(p) must start from rest")
        #expect(Self.magnitude(move.pose(at: move.duration, side: 1)) < 1e-3, "\(p) must end at rest")
        #expect(move.pose(at: move.duration + 1, side: -1) == rest)
        var peak = 0.0
        for i in 0...200 {
            let t = move.duration * Double(i) / 200
            for side in [-1.0, 1.0] {
                let pose = move.pose(at: t, side: side)
                let m = Self.magnitude(pose)
                #expect(m.isFinite, "\(p) at \(t)")
                peak = max(peak, m)
                // Applying it keeps the face sane.
                let s = pose.applied(to: Expressions.target(for: .neutral))
                #expect(s.components.allSatisfy { $0.isFinite })
                #expect(abs(s.gazeX) <= 1 && abs(s.gazeY) <= 1)
                #expect(s.left.height > 0 && s.right.height > 0)
            }
        }
        #expect(peak > 0.1, "\(p) barely moves (\(peak))")
        #expect(move.duration > 0.2 && move.duration < 3.5)
    }

    static func magnitude(_ p: Pose) -> Double {
        func eye(_ e: EyePose) -> Double {
            abs(e.close) + abs(e.widthScale) + abs(e.heightScale) + abs(e.dx) + abs(e.dy) + abs(e.upperLid) + abs(e.lowerLid)
                + abs(e.tilt) / 10 + abs(e.arc) + abs(e.chevron) + abs(e.spiral) + abs(e.line) + abs(e.cup) + abs(e.gloss) + abs(e.tear)
        }
        return eye(p.left) + eye(p.right) + abs(p.headTilt) / 10 + abs(p.faceDX) * 10 + abs(p.faceDY) * 10 + abs(p.squash) * 10
            + p.gazeWeight + abs(p.tremble) + abs(p.wobble) + abs(p.brightness) + abs(p.sparkles)
    }

    @Test func winkClosesOneEyeOnlyAndBothSidesHappen() {
        let mid = Move.perform(.wink).pose(at: 0.4, side: -1)
        #expect(mid.left.arc > 0.9 && mid.right.arc == 0)
        let other = Move.perform(.wink).pose(at: 0.4, side: 1)
        #expect(other.right.arc > 0.9 && other.left.arc == 0)
        let bl = Move.perform(.blinkLeft).pose(at: 0.1, side: 1)
        #expect(bl.left.close > 0.9 && bl.right.close == 0)
        let br = Move.perform(.blinkRight).pose(at: 0.1, side: -1)
        #expect(br.right.close > 0.9 && br.left.close == 0)
    }

    @Test func signatureShapes() {
        func at(_ p: Performance, _ f: Double) -> Pose { Move.perform(p).pose(at: Move.perform(p).duration * f, side: 1) }
        #expect(at(.giggle, 0.4).left.arc > 0.9)
        #expect(at(.dizzySpin, 0.5).left.spiral > 0.9)
        #expect(at(.yawn, 0.45).left.chevron > 0.9 && at(.yawn, 0.45).squash > 0.05)
        #expect(at(.contentSquint, 0.5).left.arc > 0.9)
        #expect(at(.startle, 0.1).left.heightScale > 0.25)
        #expect(at(.squint, 0.5).left.upperLid > 0.2 && at(.squint, 0.5).left.lowerLid > 0.15)
        #expect(at(.sigh, 0.5).left.upperLid > 0.25 && at(.sigh, 0.5).faceDY > 0)
        #expect(at(.shiver, 0.5).tremble > 0.8)
        // Look-around visits both sides.
        let xs = stride(from: 0.0, through: 2.9, by: 0.05).map { Move.perform(.lookAround).pose(at: $0, side: 1).gaze.x }
        #expect(xs.max()! > 0.7 && xs.min()! < -0.7)
        // Eye-roll passes over the top.
        let ys = stride(from: 0.0, through: 1.4, by: 0.05).map { Move.perform(.eyeRoll).pose(at: $0, side: 1).gaze.y }
        #expect(ys.min()! < -0.8)
        // Nod moves vertically, head-shake horizontally.
        let nod = stride(from: 0.0, through: 0.95, by: 0.02).map { Move.perform(.nod).pose(at: $0, side: 1) }
        #expect(nod.map(\.faceDY).max()! > 0.02 && nod.allSatisfy { $0.faceDX == 0 })
        let shake = stride(from: 0.0, through: 1.1, by: 0.02).map { Move.perform(.headShake).pose(at: $0, side: 1).faceDX }
        #expect(shake.max()! > 0.02 && shake.min()! < -0.02)
        let bounce = stride(from: 0.0, through: 0.95, by: 0.02).map { Move.perform(.bounce).pose(at: $0, side: 1).faceDY }
        #expect(bounce.min()! < -0.04)
    }

    // MARK: - Requests

    @Test func newRequestIdTriggersOnce() {
        var a = Self.quietAnimator()
        var inputs = FaceInputs()
        _ = FaceAnimatorTests.run(&a, seconds: 0.5, inputs: inputs)
        #expect(a.activePerformances.isEmpty)
        inputs.performance = PerformanceRequest(id: 1, performance: .giggle)
        _ = a.step(Self.dt, inputs: inputs)
        #expect(a.activePerformances == [.giggle])
        // The same request held for a long time plays once and ends.
        _ = FaceAnimatorTests.run(&a, seconds: 3, inputs: inputs)
        #expect(a.activePerformances.isEmpty)
        // A new id plays again, even for the same performance.
        inputs.performance = PerformanceRequest(id: 2, performance: .giggle)
        _ = a.step(Self.dt, inputs: inputs)
        #expect(a.activePerformances == [.giggle])
        // A different one layers on top.
        inputs.performance = PerformanceRequest(id: 3, performance: .nod)
        _ = a.step(Self.dt, inputs: inputs)
        #expect(Set(a.activePerformances) == [.giggle, .nod])
        // perform(_:) is the direct equivalent.
        var b = Self.quietAnimator()
        b.perform(.wink)
        #expect(b.activePerformances == [.wink])
    }

    /// Reflexes sit above mood: Dee can laugh at a joke while sad or angry.
    @Test(arguments: [Emotion.sad, .angry, .hurt, .grumpy, .lonely, .scared])
    func giggleWinsOverABadMood(_ mood: Emotion) {
        var a = Self.quietAnimator()
        _ = FaceAnimatorTests.run(&a, seconds: 2, inputs: FaceInputs(emotion: mood))
        var inputs = FaceInputs(emotion: mood)
        inputs.performance = PerformanceRequest(id: 9, performance: .giggle)
        let frames = FaceAnimatorTests.run(&a, seconds: 0.6, inputs: inputs)
        let f = frames.last!
        #expect(f.state.left.dominantGlyph == "arc" && f.state.right.dominantGlyph == "arc", "\(mood): \(f.state.left.dominantGlyph)")
        #expect(f.state.left.arc > 0.9)
        // The pose layer doesn't disturb the sprung base: the mood is still there underneath.
        #expect(a.state.left.arc < 0.05)
        // And the mood comes back afterwards.
        let after = FaceAnimatorTests.run(&a, seconds: 2, inputs: inputs).last!
        #expect(after.state.left.arc < 0.05)
    }

    @Test func performancesWantHighFrameRateWhenFast() {
        var a = Self.quietAnimator(seed: 8)
        _ = FaceAnimatorTests.run(&a, seconds: 1, inputs: FaceInputs(reduceMotion: true))
        a.perform(.bounce)
        var highs = 0, n = 0
        for _ in 0..<40 {
            _ = a.step(Self.dt, inputs: FaceInputs(reduceMotion: true))
            n += 1
            if a.wantsHighFrameRate { highs += 1 }
        }
        #expect(highs == n, "a bounce should run at the full rate")
        #expect(Move.perform(.sigh).isFast == false && Move.perform(.giggle).isFast)
        // Never while asleep.
        var s = Self.quietAnimator()
        s.perform(.dizzySpin)
        for _ in 0..<60 {
            _ = s.step(Self.dt, inputs: FaceInputs(activity: .sleeping))
            #expect(!s.wantsHighFrameRate)
        }
    }

    @Test func naturalBlinksWaitOutAWink() {
        var a = Self.quietAnimator(seed: 12)
        var all: [FaceFrame] = []
        for _ in 0..<30 {
            a.perform(.wink)
            all += FaceAnimatorTests.run(&a, seconds: 0.5, inputs: FaceInputs())
        }
        #expect(all.allSatisfy { $0.blink == 0 }, "no full blink while a wink holds the eyes")
    }

    // MARK: - Idle director

    static func spontaneousMoves(mood: FaceMood, emotion: Emotion = .neutral, activity: FaceActivity = .idle,
                                 seconds: Double, seed: UInt64 = 21, reduceMotion: Bool = false) -> [(Double, Move)] {
        var a = FaceAnimator(seed: seed)
        var seen: [(Double, Move)] = []
        var lastStarts: Set<Double> = []
        let inputs = FaceInputs(emotion: emotion, activity: activity, reduceMotion: reduceMotion, mood: mood)
        for _ in 0..<Int(seconds / dt) {
            _ = a.step(dt, inputs: inputs)
            for m in a.moves where !lastStarts.contains(m.start) {
                seen.append((m.start, m.move))
            }
            lastStarts = Set(a.moves.map(\.start))
        }
        return seen
    }

    @Test func idleDirectorKeepsHerAliveEveryFewSeconds() {
        for seed: UInt64 in [1, 2, 3] {
            let moves = Self.spontaneousMoves(mood: FaceMood(), seconds: 180, seed: seed)
            // Something small every ~4–12 s (gap measured from the end of the last move).
            #expect(moves.count >= 180 / 15 && moves.count <= 180 / 4, "seed \(seed): \(moves.count) moves in 3 min")
            for (p, n) in zip(moves, moves.dropFirst()) {
                #expect(n.0 - p.0 <= 12 + 3.5, "seed \(seed): \(n.0 - p.0) s of nothing")
                #expect(n.0 - p.0 >= 3.5, "seed \(seed): too busy")
            }
            #expect(Set(moves.map(\.1)).count >= 4, "seed \(seed): should vary its moves")
        }
    }

    @Test func idleDirectorRespectsActivity() {
        let talking = Self.spontaneousMoves(mood: FaceMood(), activity: .speaking, seconds: 180)
        let idle = Self.spontaneousMoves(mood: FaceMood(), seconds: 180)
        #expect(talking.count < idle.count, "less while talking")
        #expect(talking.count >= 3)
        #expect(!talking.contains { $0.1 == .perform(.yawn) || $0.1 == .perform(.lookAround) })
        let asleep = Self.spontaneousMoves(mood: FaceMood(), activity: .sleeping, seconds: 300)
        #expect(asleep.allSatisfy { $0.1 == .sleepyShuffle }, "only a sleepy shuffle while asleep")
        #expect(asleep.count >= 3 && asleep.count <= 300 / 20)
        #expect(Self.spontaneousMoves(mood: FaceMood(), seconds: 120, reduceMotion: true).isEmpty, "Reduce Motion: no spontaneous acting")
        var off = FaceAnimator(seed: 4)
        off.idleDirectorEnabled = false
        _ = FaceAnimatorTests.run(&off, seconds: 60, inputs: FaceInputs())
        #expect(off.moves.isEmpty)
    }

    /// Share of the director's picks per move for a mood (pure, sampled over the roll).
    static func distribution(_ mood: FaceMood, emotion: Emotion = .neutral, activity: FaceActivity = .idle) -> [Move: Double] {
        var counts: [Move: Double] = [:]
        let n = 2000
        for i in 0..<n {
            if let m = FaceAnimator.chooseIdleMove(mood: mood, emotion: emotion, activity: activity, last: nil, roll: (Double(i) + 0.5) / Double(n)) {
                counts[m, default: 0] += 1.0 / Double(n)
            }
        }
        return counts
    }

    @Test func moodSteersTheDirector() {
        func share(_ d: [Move: Double], _ moves: [Move]) -> Double { moves.reduce(0) { $0 + (d[$1] ?? 0) } }
        let flat = FaceMood(curiosity: 0, boredom: 0, playfulness: 0, energy: 1, affection: 0, arousal: 0)
        var curious = flat; curious.curiosity = 1
        var bored = flat; bored.boredom = 1
        var playful = flat; playful.playfulness = 1
        var tired = flat; tired.energy = 0.1
        var loving = flat; loving.affection = 1

        #expect(share(Self.distribution(curious), [.perform(.lookAround), .perform(.squint), .tilt, .perform(.doubleTake)]) > 0.75)
        #expect(share(Self.distribution(bored), [.perform(.yawn), .perform(.eyeRoll), .perform(.sigh)]) > 0.75)
        #expect(share(Self.distribution(playful), [.perform(.wink), .perform(.bounce)]) > 0.6)
        #expect(share(Self.distribution(tired), [.perform(.yawn), .perform(.sigh)]) > 0.6)
        #expect((Self.distribution(tired)[.perform(.yawn)] ?? 0) > 0.4)
        #expect((Self.distribution(loving)[.perform(.contentSquint)] ?? 0) > 0.5)
        // A gloomy Dee winks and bounces less (but still can).
        let gloomy = Self.distribution(playful, emotion: .sad)
        let cheery = Self.distribution(FaceMood(curiosity: 0, boredom: 0, playfulness: 1, energy: 1, affection: 0, arousal: 0), emotion: .happy)
        #expect((gloomy[.perform(.wink)] ?? 0) < (cheery[.perform(.wink)] ?? 0))
        // Listening favours nods; sleeping only shuffles.
        #expect((Self.distribution(FaceMood(), activity: .listening)[.perform(.nod)] ?? 0) > 0.3)
        let sleeping = Self.distribution(FaceMood(), activity: .sleeping)
        #expect(sleeping.count == 1 && abs((sleeping[.sleepyShuffle] ?? 0) - 1) < 1e-9)
        // Not the same move twice in a row when there's a choice.
        let again = (0..<200).compactMap { FaceAnimator.chooseIdleMove(mood: curious, emotion: .neutral, activity: .idle, last: .perform(.lookAround), roll: Double($0) / 200) }
        #expect(Double(again.filter { $0 == .perform(.lookAround) }.count) / 200 < 0.25)
    }

    @Test func idleGapPolicy() {
        for r in stride(from: 0.0, through: 1.0, by: 0.1) {
            let g = FaceAnimator.idleGap(mood: FaceMood(), activity: .idle, roll: r)
            #expect(g >= 3.5 && g <= 12)
            #expect(FaceAnimator.idleGap(mood: FaceMood(), activity: .speaking, roll: r) >= 9)
            #expect(FaceAnimator.idleGap(mood: FaceMood(), activity: .sleeping, roll: r) >= 20)
        }
        let excited = FaceMood(arousal: 1), calm = FaceMood(energy: 0.2, arousal: 0)
        #expect(FaceAnimator.idleGap(mood: excited, activity: .idle, roll: 0.5) < FaceAnimator.idleGap(mood: calm, activity: .idle, roll: 0.5))
    }

    // MARK: - Touch

    @Test func eyesGlanceAtTheFinger() {
        for (touch, sx, sy) in [(SIMD2(0.05, 0.9), -1.0, 1.0), (SIMD2(0.95, 0.1), 1.0, -1.0), (SIMD2(0.9, 0.85), 1.0, 1.0)] {
            var a = Self.quietAnimator()
            var inputs = FaceInputs(lookAt: [-sx * 0.8, 0])   // the camera says the other way…
            inputs.touchPoint = touch                          // …but the finger wins.
            let frames = FaceAnimatorTests.run(&a, seconds: 0.4, inputs: inputs)
            let g = frames.last!.state
            #expect(g.gazeX * sx > 0 && abs(g.gazeX) > 0.6, "\(touch): \(g.gazeX)")
            #expect(g.gazeY * sy > 0 && abs(g.gazeY) > 0.5, "\(touch): \(g.gazeY)")
        }
        #expect(FaceAnimator.gaze(towardTouch: [0.5, 0.47]) == [0, 0])
        let far = FaceAnimator.gaze(towardTouch: [-3, 9])
        #expect(far.x == -1 && far.y == 1)
        // A new touch makes her notice (a quick widen).
        var a = Self.quietAnimator()
        _ = FaceAnimatorTests.run(&a, seconds: 1, inputs: FaceInputs())
        var t = FaceInputs()
        t.touchPoint = [0.5, 0.5]
        _ = a.step(Self.dt, inputs: t)
        #expect(a.moves.contains { $0.move == .notice })
    }

    @Test func fullDeterminismWithPerformancesAndDirector() {
        var a = FaceAnimator(seed: 66), b = FaceAnimator(seed: 66)
        var inputs = FaceInputs(mood: FaceMood(curiosity: 0.9, playfulness: 0.8))
        inputs.performance = PerformanceRequest(id: 4, performance: .eyeRoll)
        #expect(FaceAnimatorTests.run(&a, seconds: 30, inputs: inputs) == FaceAnimatorTests.run(&b, seconds: 30, inputs: inputs))
    }

    @Test func faceInputsDefaults() {
        let i = FaceInputs()
        #expect(i.mood == FaceMood())
        #expect(i.touchPoint == nil && i.performance == nil)
        let m = FaceMood()
        #expect(m.curiosity == 0.5 && m.boredom == 0 && m.playfulness == 0.5 && m.energy == 0.8 && m.affection == 0.4 && m.arousal == 0.3)
        #expect(Performance.allCases.count == 17)
    }
}
