import Foundation
import Testing
@testable import DeeSense

/// Gesture recognition and presence tracking from synthetic (Vision-free) inputs.
/// Coordinates are Vision's: normalised, origin bottom-left, y up.
@Suite struct SenseTests {
    static let fps = 12.0

    // MARK: - Synthetic hands

    static func moved(_ joints: [HandJoint: SIMD2<Double>], by d: SIMD2<Double>) -> HandPose {
        HandPose(joints.mapValues { $0 + d })
    }

    /// Fingers spread and straight, thumb out to the side.
    static func openPalm(_ d: SIMD2<Double> = .zero) -> HandPose {
        moved([
            .wrist: [0.5, 0.2],
            .thumbMP: [0.40, 0.30], .thumbIP: [0.35, 0.33], .thumbTip: [0.26, 0.36],
            .indexMCP: [0.42, 0.40], .indexPIP: [0.41, 0.52], .indexTip: [0.40, 0.65],
            .middleMCP: [0.47, 0.40], .middlePIP: [0.47, 0.53], .middleTip: [0.47, 0.67],
            .ringMCP: [0.53, 0.40], .ringPIP: [0.53, 0.52], .ringTip: [0.54, 0.65],
            .littleMCP: [0.58, 0.39], .littlePIP: [0.59, 0.49], .littleTip: [0.60, 0.60],
        ], by: d)
    }

    static let fistJoints: [HandJoint: SIMD2<Double>] = [
        .wrist: [0.5, 0.2],
        .thumbMP: [0.43, 0.33], .thumbIP: [0.44, 0.37], .thumbTip: [0.46, 0.39],
        .indexMCP: [0.44, 0.40], .indexPIP: [0.44, 0.47], .indexTip: [0.44, 0.36],
        .middleMCP: [0.48, 0.40], .middlePIP: [0.48, 0.47], .middleTip: [0.48, 0.36],
        .ringMCP: [0.52, 0.40], .ringPIP: [0.52, 0.47], .ringTip: [0.52, 0.36],
        .littleMCP: [0.56, 0.40], .littlePIP: [0.56, 0.46], .littleTip: [0.56, 0.36],
    ]

    static func fist(_ d: SIMD2<Double> = .zero) -> HandPose { moved(fistJoints, by: d) }

    /// A fist with the thumb pointing straight up.
    static func thumbsUp(_ d: SIMD2<Double> = .zero) -> HandPose {
        var j = fistJoints
        j[.thumbMP] = [0.44, 0.44]
        j[.thumbIP] = [0.44, 0.52]
        j[.thumbTip] = [0.44, 0.66]
        return moved(j, by: d)
    }

    /// Feeds `pose(t)` at 12 fps from `start` for `seconds`; returns fired gestures with times.
    static func feed(_ r: inout GestureRecognizer, from start: Double = 0, seconds: Double, _ pose: (Double) -> HandPose?) -> [(t: Double, g: Gesture)] {
        var out: [(Double, Gesture)] = []
        let n = Int((seconds * fps).rounded())
        for i in 0..<n {
            let t = start + Double(i) / fps
            if let g = r.update(pose(t), at: t) { out.append((t, g)) }
        }
        return out
    }

    // MARK: - Shape classification

    @Test func classifiesSyntheticShapes() {
        #expect(Self.openPalm().shape == .openPalm)
        #expect(Self.fist().shape == .other)
        #expect(Self.thumbsUp().shape == .thumbsUp)
        #expect(Self.openPalm().extendedFingers == 4)
        #expect(Self.fist().extendedFingers == 0)
        #expect(Self.openPalm().thumbExtended)
        #expect(!Self.fist().thumbExtended)
        // Translation-invariant.
        #expect(Self.openPalm([0.2, 0.15]).shape == .openPalm)
        #expect(Self.thumbsUp([-0.2, 0.1]).shape == .thumbsUp)
        // Upside-down thumb is not a thumbs-up.
        let down = HandPose(Self.thumbsUp().joints.mapValues { SIMD2($0.x, 1 - $0.y) })
        #expect(down.shape != .thumbsUp)
        // Missing wrist → no scale → other.
        var noWrist = Self.openPalm().joints
        noWrist[.wrist] = nil
        #expect(HandPose(noWrist).shape == .other)
    }

    // MARK: - Gestures

    @Test func waveFromOscillatingOpenPalm() {
        var r = GestureRecognizer()
        let fired = Self.feed(&r, seconds: r.waveWindow) { t in
            Self.openPalm([0.12 * sin(2 * .pi * t / 0.6), 0])
        }
        #expect(fired.map(\.g) == [.wave], "got \(fired)")
        if let first = fired.first { #expect(first.t <= r.waveWindow) }
    }

    @Test func singleSwipeIsNotAWave() {
        var r = GestureRecognizer()
        // One sweep left→right (one direction change at most).
        let fired = Self.feed(&r, seconds: 0.5) { t in Self.openPalm([-0.15 + 0.6 * t, 0]) }
        #expect(!fired.contains { $0.g == .wave })
    }

    @Test func tinyJitterIsNotAWave() {
        var r = GestureRecognizer()
        let fired = Self.feed(&r, seconds: 1.5) { t in Self.openPalm([0.01 * sin(2 * .pi * t / 0.3), 0]) }
        #expect(!fired.contains { $0.g == .wave })
    }

    @Test func stillOpenPalmHeldBecomesPalm() {
        var r = GestureRecognizer()
        let fired = Self.feed(&r, seconds: 1.2) { _ in Self.openPalm() }
        #expect(fired.map(\.g) == [.palm])
        if let f = fired.first {
            #expect(f.t >= r.palmHold, "fired too early at \(f.t)")
            #expect(f.t <= r.palmHold + 2 / Self.fps)
        }
    }

    @Test func briefPalmIsNotPalm() {
        var r = GestureRecognizer()
        let fired = Self.feed(&r, seconds: r.palmHold * 0.6) { _ in Self.openPalm() }
        #expect(fired.isEmpty)
    }

    @Test func thumbsUpHeldFires() {
        var r = GestureRecognizer()
        let fired = Self.feed(&r, seconds: 1.0) { _ in Self.thumbsUp() }
        #expect(fired.map(\.g) == [.thumbsUp])
        if let f = fired.first {
            #expect(f.t >= r.thumbHold)
            #expect(f.t <= r.thumbHold + 2 / Self.fps)
        }
    }

    @Test func fistNeverFires() {
        var r = GestureRecognizer()
        #expect(Self.feed(&r, seconds: 5) { t in Self.fist([0.1 * sin(t * 10), 0]) }.isEmpty)
    }

    @Test func cooldownPreventsRepeats() {
        var r = GestureRecognizer()
        let fired = Self.feed(&r, seconds: 6) { _ in Self.thumbsUp() }
        #expect(fired.count >= 2, "a long hold should eventually re-fire after cooldown")
        for (a, b) in zip(fired, fired.dropFirst()) {
            #expect(b.t - a.t >= r.cooldown, "fired again after only \(b.t - a.t) s")
        }
        // Cooldown is per gesture: a palm right after a thumbs-up still fires.
        var r2 = GestureRecognizer()
        let t1 = Self.feed(&r2, seconds: 0.6) { _ in Self.thumbsUp() }
        let t2 = Self.feed(&r2, from: 0.6, seconds: 1.0) { _ in Self.openPalm() }
        #expect(t1.map(\.g) == [.thumbsUp])
        #expect(t2.map(\.g) == [.palm])
    }

    @Test func nilHandResetsHolds() {
        var r = GestureRecognizer()
        // Palm for most of the hold, hand lost for a frame, palm again.
        let a = Self.feed(&r, seconds: r.palmHold * 0.8) { _ in Self.openPalm() }
        #expect(r.update(nil, at: 0.6) == nil)
        let b = Self.feed(&r, from: 0.61, seconds: r.palmHold * 0.8) { _ in Self.openPalm() }
        #expect(a.isEmpty && b.isEmpty, "the hold timer must restart after the hand is lost")

        var r2 = GestureRecognizer()
        let c = Self.feed(&r2, seconds: r2.thumbHold * 0.8) { _ in Self.thumbsUp() }
        #expect(r2.update(nil, at: 0.4) == nil)
        let d = Self.feed(&r2, from: 0.41, seconds: r2.thumbHold * 0.8) { _ in Self.thumbsUp() }
        #expect(c.isEmpty && d.isEmpty)

        // Wave track also resets: half a wave, lose the hand, half a wave → no wave.
        var r3 = GestureRecognizer()
        let e = Self.feed(&r3, seconds: 0.4) { t in Self.openPalm([0.12 * sin(2 * .pi * t / 0.6), 0]) }
        _ = r3.update(nil, at: 0.45)
        let f = Self.feed(&r3, from: 0.5, seconds: 0.4) { t in Self.openPalm([0.12 * sin(2 * .pi * t / 0.6), 0]) }
        #expect(!(e + f).contains { $0.g == .wave })
    }

    @Test func otherShapeResetsHolds() {
        var r = GestureRecognizer()
        let fired = Self.feed(&r, seconds: 3) { t in
            // Alternate thumbs-up and fist every 0.3 s — never held long enough.
            Int(t / 0.3) % 2 == 0 ? Self.thumbsUp() : Self.fist()
        }
        #expect(fired.isEmpty)
    }

    @Test func reversalsUnitCases() {
        #expect(GestureRecognizer.reversals([], minSwing: 0.1) == 0)
        #expect(GestureRecognizer.reversals([0.5], minSwing: 0.1) == 0)
        #expect(GestureRecognizer.reversals([0, 0.1, 0.2, 0.3, 0.4], minSwing: 0.1) == 0)
        #expect(GestureRecognizer.reversals([0, 1, 0], minSwing: 0.5) == 1)
        #expect(GestureRecognizer.reversals([0, 1, 0, 1], minSwing: 0.5) == 2)
        #expect(GestureRecognizer.reversals([1, 0, 1, 0, 1], minSwing: 0.5) == 3)
        // Swings smaller than minSwing don't count.
        #expect(GestureRecognizer.reversals([0, 0.05, 0, 0.05, 0, 0.05], minSwing: 0.1) == 0)
        // Small jitter inside a big swing doesn't add reversals.
        #expect(GestureRecognizer.reversals([0, 0.5, 0.48, 1.0, 0.0], minSwing: 0.3) == 1)
        // Falling first works too.
        #expect(GestureRecognizer.reversals([1, 0, 1], minSwing: 0.5) == 1)
    }

    // MARK: - Presence

    static let centre = (center: SIMD2<Double>(0.5, 0.55), width: 0.3)

    @Test func arrivesAfterArriveFrames() {
        var p = PresenceTracker()
        var events: [PresenceTracker.Event?] = []
        for i in 0..<p.arriveFrames + 2 { events.append(p.update(face: Self.centre, at: Double(i) * 0.1)) }
        #expect(events[p.arriveFrames - 1] == .arrived)
        #expect(events.compactMap { $0 } == [.arrived], "arrives exactly once")
        #expect(p.isPresent)
    }

    @Test func interruptedStreakDoesNotArrive() {
        var p = PresenceTracker()
        var t = 0.0
        for _ in 0..<5 {
            for _ in 0..<(p.arriveFrames - 1) { #expect(p.update(face: Self.centre, at: t) == nil); t += 0.1 }
            #expect(p.update(face: nil, at: t) == nil); t += 0.1
        }
        #expect(!p.isPresent)
    }

    @Test func leavesAfterLeaveAfterSeconds() {
        var p = PresenceTracker()
        for i in 0..<p.arriveFrames { _ = p.update(face: Self.centre, at: Double(i) * 0.1) }
        #expect(p.isPresent)
        let lastSeen = Double(p.arriveFrames - 1) * 0.1
        // Short dropout: still here.
        #expect(p.update(face: nil, at: lastSeen + p.leaveAfter * 0.5) == nil)
        #expect(p.isPresent)
        #expect(p.absentDuration(at: lastSeen + 1) == 0)
        // Gone after leaveAfter.
        let leftAt = lastSeen + p.leaveAfter + 0.01
        #expect(p.update(face: nil, at: leftAt) == .left)
        #expect(!p.isPresent)
        #expect(p.position == nil)
        #expect(p.update(face: nil, at: leftAt + 1) == nil, "leaves only once")
        #expect(abs(p.absentDuration(at: leftAt + 3) - 3) < 1e-9)
        #expect(p.absentDuration(at: leftAt - 1) == 0, "never negative")
    }

    @Test func reappearingResetsLeaveTimer() {
        var p = PresenceTracker()
        for i in 0..<p.arriveFrames { _ = p.update(face: Self.centre, at: Double(i) * 0.1) }
        var t = 0.3
        // Flickery detection: a face every ~1 s never counts as leaving.
        for _ in 0..<10 {
            t += p.leaveAfter * 0.6
            #expect(p.update(face: nil, at: t) == nil)
            #expect(p.update(face: Self.centre, at: t) == nil)
        }
        #expect(p.isPresent)
    }

    @Test func positionMappingSigns() {
        func settled(_ c: SIMD2<Double>) -> SIMD2<Double> {
            var p = PresenceTracker()
            for i in 0..<10 { _ = p.update(face: (c, 0.3), at: Double(i) * 0.1) }
            return p.position!
        }
        let left = settled([0.3, 0.55])
        let right = settled([0.7, 0.55])
        let high = settled([0.5, 0.85])
        let low = settled([0.5, 0.25])
        let mid = settled([0.5, 0.55])
        #expect(left.x < 0, "face on image-left → look left")
        #expect(right.x > 0)
        #expect(high.y < 0, "face high in frame (Vision y up) → look up (gaze y down-positive)")
        #expect(low.y > 0)
        #expect(abs(mid.x) < 1e-9 && abs(mid.y) < 1e-9)
        // Extremes stay in gaze range.
        for c: SIMD2<Double> in [[0, 0], [1, 1], [0, 1], [1, 0]] {
            let p = settled(c)
            #expect(abs(p.x) <= 1 && abs(p.y) <= 1)
        }
    }

    @Test func positionIsSmoothed() {
        var p = PresenceTracker()
        for i in 0..<10 { _ = p.update(face: ([0.3, 0.55], 0.3), at: Double(i) * 0.1) }
        let before = p.position!
        _ = p.update(face: ([0.7, 0.55], 0.3), at: 1.0)
        let after = p.position!
        let jumpTarget = (0.7 - 0.5) * 2 * 1.5
        #expect(after.x > before.x, "moves toward the new face")
        #expect(after.x < min(jumpTarget, 1), "but does not jump all the way in one frame")
    }

    @Test func faceSizeTracksWidth() {
        var p = PresenceTracker()
        _ = p.update(face: (SIMD2(0.5, 0.5), 0.2), at: 0)
        #expect(abs(p.faceSize - 0.2) < 1e-9)
        for i in 1..<30 { _ = p.update(face: (SIMD2(0.5, 0.5), 0.5), at: Double(i) * 0.1) }
        #expect(p.faceSize > 0.45 && p.faceSize <= 0.5)
    }

    @Test func absentDurationBeforeAnyoneArrives() {
        var p = PresenceTracker()
        // Before the first frame there is no absence clock (no assumption that t starts at 0).
        #expect(p.absentSince == nil)
        #expect(p.absentDuration(at: 7) == 0)
        #expect(!p.isPresent)
        // The first frame (face or not) starts it: absent since tracking began.
        _ = p.update(face: nil, at: 1000)
        #expect(p.absentSince == 1000)
        #expect(p.absentDuration(at: 1007) == 7)
        var q = PresenceTracker()
        _ = q.tick(at: 50)
        #expect(q.absentDuration(at: 52) == 2)
        // Arrival clears it.
        for i in 0..<p.arriveFrames { _ = p.update(face: Self.centre, at: 1010 + Double(i) * 0.1) }
        #expect(p.isPresent && p.absentSince == nil && p.absentDuration(at: 2000) == 0)
    }

    // MARK: - Presence without frames

    static func arrived(at t0: Double = 100) -> PresenceTracker {
        var p = PresenceTracker()
        for i in 0..<p.arriveFrames { _ = p.update(face: Self.centre, at: t0 + Double(i) * 0.1) }
        return p
    }

    @Test func tickDetectsLeavingWhenFramesStop() {
        var p = Self.arrived()
        let lastSeen = p.lastSeen!
        #expect(p.tick(at: lastSeen + p.leaveAfter * 0.5) == nil)
        #expect(p.isPresent)
        #expect(p.tick(at: lastSeen + p.leaveAfter) == .left)
        #expect(!p.isPresent && p.position == nil)
        #expect(p.absentDuration(at: lastSeen + p.leaveAfter + 2) == 2)
        #expect(p.tick(at: lastSeen + 10) == nil, "leaves only once")
    }

    @Test func tickDoesNotDisturbAnArrivalStreak() {
        var p = PresenceTracker()
        _ = p.update(face: Self.centre, at: 0)
        #expect(p.tick(at: 0.05) == nil)
        _ = p.update(face: Self.centre, at: 0.1)
        #expect(p.tick(at: 0.15) == nil)
        #expect(p.update(face: Self.centre, at: 0.2) == .arrived, "ticks between frames must not reset the streak")
        // ...but a long gap does: the next sightings start a fresh streak.
        var q = PresenceTracker()
        _ = q.update(face: Self.centre, at: 0)
        _ = q.update(face: Self.centre, at: 0.1)
        _ = q.tick(at: 5)
        #expect(q.update(face: Self.centre, at: 5.1) == nil)
    }

    @Test func resetForgetsEveryone() {
        var p = Self.arrived()
        p.leaveAfter = 3
        #expect(p.reset(at: 200) == .left)
        #expect(!p.isPresent && p.position == nil && p.lastSeen == nil)
        #expect(p.leaveAfter == 3, "tuning survives a reset")
        #expect(p.absentDuration(at: 205) == 5)
        #expect(p.reset(at: 300) == nil, "nobody to forget")
    }

    // MARK: - Pacing

    /// Feeds sensor frames at `deviceFPS` for `seconds`; returns admitted times and hand-run times.
    static func pace(_ pacer: inout SensePacer, deviceFPS: Double = 15, seconds: Double, from t0: Double = 1000,
                     someoneHere: Bool = true, handSeen: (Double) -> Bool = { _ in false }) -> (frames: [Double], hands: [Double]) {
        var frames: [Double] = [], hands: [Double] = []
        for i in 0..<Int(seconds * deviceFPS) {
            let t = t0 + Double(i) / deviceFPS
            guard pacer.admit(at: t) else { continue }
            frames.append(t)
            if pacer.wantsHands(at: t, someoneHere: someoneHere) {
                hands.append(t)
                pacer.handResult(found: handSeen(t), at: t)
            }
        }
        return (frames, hands)
    }

    @Test func pacerAveragesTheRequestedRate() {
        var p = SensePacer()
        let r = Self.pace(&p, seconds: 10)
        #expect(abs(Double(r.frames.count) / 10 - 12) < 0.5, "15 fps in → ~12 fps analysed, got \(r.frames.count)")
        #expect(abs(Double(r.hands.count) / 10 - 6) < 1.1, "hand scan ≤ ~6 fps, got \(r.hands.count)")
        #expect(Double(r.hands.count) / 10 <= 6.01)
        #expect(p.deviceFramesPerSecond == 15)
    }

    @Test func pacerSkipsHandsWithNobodyAndWhileDozing() {
        var p = SensePacer()
        #expect(Self.pace(&p, seconds: 5, someoneHere: false).hands.isEmpty)
        var d = SensePacer()
        d.dozing = true
        let r = Self.pace(&d, seconds: 10)
        #expect(r.hands.isEmpty, "face only while dozing")
        #expect(abs(Double(r.frames.count) / 10 - 2) < 0.3, "~2 fps while dozing, got \(r.frames.count)")
        #expect(d.deviceFramesPerSecond < 15)
    }

    @Test func pacerBacksOffWhenConstrained() {
        var p = SensePacer()
        p.constrained = true
        let r = Self.pace(&p, seconds: 10)
        #expect(abs(Double(r.frames.count) / 10 - 6) < 0.5, "got \(r.frames.count)")
        #expect(Double(r.hands.count) / 10 <= 3.01)
        #expect(p.deviceFramesPerSecond < 15)
    }

    @Test func pacerBurstsHandPoseOnceAHandIsSeen() {
        var p = SensePacer()
        let r = Self.pace(&p, seconds: 2, handSeen: { _ in true })
        #expect(Double(r.hands.count) / 2 > 9, "hand in view → hand pose at the face rate, got \(r.hands.count)")
    }

    @Test func pacerClampsSillyRates() {
        var p = SensePacer()
        p.framesPerSecond = 0
        #expect(p.faceRate == 1)
        #expect(Self.pace(&p, seconds: 5).frames.count <= 6)
    }

    /// End to end on synthetic hands: a brisk 2.5 Hz wave sampled the way the camera
    /// samples it (15 fps sensor, paced analysis, hand scan) is still recognised.
    @Test func waveSurvivesHandPacing() {
        var pacer = SensePacer()
        var r = GestureRecognizer()
        var fired: [Gesture] = []
        let t0 = 1000.0
        for i in 0..<Int(3 * 15) {
            let t = t0 + Double(i) / 15
            guard pacer.admit(at: t), pacer.wantsHands(at: t, someoneHere: true) else { continue }
            let pose = Self.openPalm([0.12 * sin(2 * .pi * 2.5 * (t - t0) + 0.4), 0])
            pacer.handResult(found: true, at: t)
            if let g = r.update(pose, at: t) { fired.append(g) }
        }
        #expect(fired.contains(.wave), "got \(fired)")
    }

    // MARK: - CameraSense plumbing

    @Test func lookChangedThreshold() {
        #expect(!CameraSense.lookChanged(from: nil, to: nil))
        #expect(CameraSense.lookChanged(from: nil, to: [0, 0]))
        #expect(CameraSense.lookChanged(from: [0, 0], to: nil))
        #expect(!CameraSense.lookChanged(from: [0, 0], to: [0.005, -0.005]))
        #expect(CameraSense.lookChanged(from: [0, 0], to: [0.02, 0]))
    }

    @Test func framesPerSecondIsClampedAndThreadSafe() async {
        let camera = CameraSense()
        #expect(camera.framesPerSecond == 12)
        camera.framesPerSecond = 0
        #expect(camera.framesPerSecond == 1)
        camera.framesPerSecond = -.infinity
        #expect(camera.framesPerSecond == 1)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask {
                    for j in 0..<500 {
                        camera.framesPerSecond = Double(1 + (i + j) % 20)
                        _ = camera.framesPerSecond
                        camera.isDozing = j.isMultiple(of: 2)
                    }
                }
            }
        }
        #expect(camera.framesPerSecond >= 1)
        camera.isDozing = true
        #expect(camera.isDozing)
        camera.shutdown()
    }

    @Test func shutdownFinishesTheStream() async {
        let camera = CameraSense()
        let reader = Task { () -> Int in
            var n = 0
            for await _ in camera.updates { n += 1 }
            return n
        }
        camera.shutdown()
        camera.shutdown() // idempotent
        #expect(await reader.value == 0)
    }
}
