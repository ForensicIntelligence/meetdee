import Foundation
import Testing
@testable import DeeSense

/// Touch interpretation from synthetic sample streams (view units 0…1, y down).
@Suite struct TouchTests {
    typealias Fired = [(t: Double, g: TouchGesture)]

    // MARK: - Stream builders

    static func tap(id: Int, at t: Double, _ p: SIMD2<Double> = [0.5, 0.5], duration: Double = 0.08, radius: Double = 20) -> [TouchSample] {
        [
            TouchSample(id: id, time: t, location: p, majorRadius: radius, phase: .began),
            TouchSample(id: id, time: t + duration / 2, location: p + [0.002, 0.001], majorRadius: radius, phase: .moved),
            TouchSample(id: id, time: t + duration, location: p + [0.003, 0.001], majorRadius: radius, phase: .ended),
        ]
    }

    /// A continuous contact sampled at `hz`, following `path(τ)` (τ = seconds since start).
    static func stroke(id: Int, from t0: Double, duration: Double, hz: Double = 60,
                       radius: (Double) -> Double = { _ in 20 }, end: TouchSample.Phase = .ended,
                       _ path: (Double) -> SIMD2<Double>) -> [TouchSample] {
        var out = [TouchSample(id: id, time: t0, location: path(0), majorRadius: radius(0), phase: .began)]
        let n = max(1, Int((duration * hz).rounded()))
        for i in 1...n {
            let tau = Double(i) / hz
            out.append(TouchSample(id: id, time: t0 + tau, location: path(tau), majorRadius: radius(tau), phase: i == n ? end : .moved))
        }
        return out
    }

    /// Feeds samples in time order, ticking at `tickHz` until `until`.
    static func run(_ ti: inout TouchInterpreter, _ samples: [TouchSample], until: Double, tickHz: Double = 30) -> Fired {
        var events: [(t: Double, sample: TouchSample?)] = samples.map { ($0.time, $0) }
        var t = 0.0
        while t <= until { events.append((t, nil)); t += 1 / tickHz }
        events.sort { $0.t == $1.t ? ($0.sample != nil && $1.sample == nil) : $0.t < $1.t }
        var fired: Fired = []
        for e in events {
            let out = e.sample.map { ti.add($0) } ?? ti.tick(at: e.t)
            fired += out.map { (e.t, $0) }
        }
        return fired
    }

    static func run(_ samples: [TouchSample], until: Double) -> Fired {
        var ti = TouchInterpreter()
        return run(&ti, samples, until: until)
    }

    static func kinds(_ f: Fired) -> [String] {
        f.map {
            switch $0.g {
            case .tap: "tap"
            case .doubleTap: "doubleTap"
            case .pet: "pet"
            case .hold: "hold"
            case .pokes: "pokes"
            case .slap: "slap"
            case .tickle: "tickle"
            }
        }
    }

    /// Teaches the interpreter the user's ordinary fingertip size with a few spaced taps.
    static func withBaseline(radius: Double = 20) -> (TouchInterpreter, Double) {
        var ti = TouchInterpreter()
        var samples: [TouchSample] = []
        for i in 0..<4 { samples += tap(id: 100 + i, at: Double(i) * 1.0, radius: radius) }
        _ = run(&ti, samples, until: 4.5)
        return (ti, 5.0)
    }

    // MARK: - Taps

    @Test func singleTapFiresAfterTheDoubleTapWindow() {
        let f = Self.run(Self.tap(id: 1, at: 0.1, [0.3, 0.4]), until: 1.5)
        #expect(Self.kinds(f) == ["tap"], "got \(f)")
        if let e = f.first {
            #expect(e.g == .tap(at: [0.3, 0.4]))
            #expect(e.t > 0.18 + 0.3 - 1e-9 && e.t < 0.18 + 0.3 + 0.1, "fired at \(e.t)")
        }
    }

    @Test func doubleTap() {
        let s = Self.tap(id: 1, at: 0.1, [0.5, 0.5]) + Self.tap(id: 2, at: 0.35, [0.52, 0.5])
        let f = Self.run(s, until: 2)
        #expect(Self.kinds(f) == ["doubleTap"], "got \(f)")
        #expect(f.first?.g == .doubleTap(at: [0.5, 0.5]))
    }

    @Test func slowTapsAreSeparateTaps() {
        let s = Self.tap(id: 1, at: 0.1) + Self.tap(id: 2, at: 1.0)
        #expect(Self.kinds(Self.run(s, until: 2.5)) == ["tap", "tap"])
    }

    @Test func quickTapsFarApartAreNotADoubleTap() {
        let s = Self.tap(id: 1, at: 0.1, [0.1, 0.1]) + Self.tap(id: 2, at: 0.3, [0.9, 0.9])
        #expect(Self.kinds(Self.run(s, until: 2)) == ["tap", "tap"])
    }

    @Test func twoFingersTogetherAreOneTap() {
        let s = Self.tap(id: 1, at: 0.1, [0.4, 0.5]) + Self.tap(id: 2, at: 0.12, [0.6, 0.5])
        let f = Self.run(s, until: 1.5)
        #expect(Self.kinds(f) == ["tap"], "got \(f)")
        if case .tap(let p)? = f.first?.g { #expect(abs(p.x - 0.5) < 0.01) }
    }

    @Test func longStillPressIsNotATap() {
        let s = Self.stroke(id: 1, from: 0.1, duration: 0.5) { _ in [0.5, 0.5] }
        #expect(Self.run(s, until: 2).isEmpty)
    }

    @Test func cancelledTouchMeansNothing() {
        var s = Self.tap(id: 1, at: 0.1)
        s[2].phase = .cancelled
        #expect(Self.run(s, until: 1.5).isEmpty)
    }

    // MARK: - Pokes

    @Test func rapidTapsArePokesNotTaps() {
        var s: [TouchSample] = []
        for i in 0..<6 { s += Self.tap(id: i, at: 0.1 + Double(i) * 0.2, [0.5 + 0.01 * Double(i % 2), 0.5]) }
        let f = Self.run(s, until: 3)
        #expect(Set(Self.kinds(f)) == ["pokes"], "got \(f)")
        let counts = f.compactMap { if case .pokes(let c, _, _) = $0.g { c } else { nil } }
        #expect(counts.first == 3, "the third tap triggers")
        #expect(counts.reduce(0, +) == 6)
        if case .pokes(_, let rate, _)? = f.last?.g { #expect(abs(rate - 5) < 0.6, "rate \(rate)") }
        // First pokes event lands with the third tap, not after the burst.
        #expect((f.first?.t ?? 9) < 0.6)
    }

    @Test func leftoverPokesAreSentWhenTheBurstEnds() {
        var s: [TouchSample] = []
        for i in 0..<4 { s += Self.tap(id: i, at: 0.1 + Double(i) * 0.25) }
        let f = Self.run(s, until: 3)
        let counts = f.compactMap { if case .pokes(let c, _, _) = $0.g { c } else { nil } }
        #expect(counts == [3, 1], "got \(f)")
        #expect(!Self.kinds(f).contains("tap"))
    }

    @Test func pokeTotalsRunThroughTheBurst() {
        // 10 rapid pokes: events at 3, 6, 9 and the leftover 1 when the burst ends.
        var s: [TouchSample] = []
        for i in 0..<10 { s += Self.tap(id: i, at: 0.1 + Double(i) * 0.15) }
        let f = Self.run(s, until: 4)
        let pokes = f.compactMap { if case .pokes(let c, _, let total) = $0.g { (c, total) } else { nil } }
        #expect(pokes.map(\.0) == [3, 3, 3, 1], "got \(f)")
        #expect(pokes.map(\.1) == [3, 6, 9, 10], "total is the running count, got \(pokes)")
        // A new burst starts counting again.
        var s2: [TouchSample] = []
        for i in 0..<3 { s2 += Self.tap(id: 50 + i, at: 5 + Double(i) * 0.15) }
        var ti = TouchInterpreter()
        _ = Self.run(&ti, s, until: 4)
        let next = Self.run(&ti, s2, until: 7).compactMap { if case .pokes(_, _, let total) = $0.g { total } else { nil } }
        #expect(next == [3], "got \(next)")
    }

    @Test func threeTapsWithinTheWindowArePokes() {
        var s: [TouchSample] = []
        for i in 0..<3 { s += Self.tap(id: i, at: 0.1 + Double(i) * 0.6) }
        let f = Self.run(s, until: 3.5)
        #expect(Self.kinds(f).contains("pokes"), "got \(f)")
    }

    @Test func doubleTapThenALaterTapIsNotPoking() {
        let s = Self.tap(id: 1, at: 0.1) + Self.tap(id: 2, at: 0.35) + Self.tap(id: 3, at: 1.3)
        #expect(Self.kinds(Self.run(s, until: 2.5)) == ["doubleTap", "tap"])
    }

    // MARK: - Hold

    @Test func stillFingerIsAHoldRepeatedWithCumulativeDuration() {
        // A resting finger sends almost nothing; time (ticks) carries the hold.
        let s = [
            TouchSample(id: 1, time: 0.1, location: [0.5, 0.5], majorRadius: 22, phase: .began),
            TouchSample(id: 1, time: 0.6, location: [0.505, 0.5], majorRadius: 22, phase: .moved),
            TouchSample(id: 1, time: 3.0, location: [0.505, 0.5], majorRadius: 22, phase: .ended),
        ]
        let f = Self.run(s, until: 4)
        #expect(Set(Self.kinds(f)) == ["hold"], "got \(f)")
        let durations = f.compactMap { if case .hold(let d) = $0.g { d } else { nil } }
        #expect(durations.count >= 2 && durations.count <= 3, "got \(durations)")
        #expect((durations.first ?? 0) >= 0.8 && (durations.first ?? 9) < 0.9)
        #expect(durations == durations.sorted())
        #expect(f.allSatisfy { $0.t <= 3.0 }, "nothing after release")
    }

    @Test func palmRestingIsAHugNotASlap() {
        var s: [TouchSample] = []
        for i in 0..<4 {
            s += Self.stroke(id: i, from: 0.1 + Double(i) * 0.01, duration: 2, hz: 10, radius: { _ in 40 }) { _ in [0.3 + 0.1 * Double(i), 0.5] }
        }
        let f = Self.run(s, until: 3)
        #expect(Self.kinds(f).contains("hold"))
        #expect(!Self.kinds(f).contains("slap"))
        #expect(!Self.kinds(f).contains("tap"))
    }

    @Test func holdWhileTheOtherHandTaps() {
        var s = [
            TouchSample(id: 1, time: 0.1, location: [0.2, 0.2], majorRadius: 20, phase: .began),
            TouchSample(id: 1, time: 3.0, location: [0.2, 0.2], majorRadius: 20, phase: .ended),
        ]
        s += Self.tap(id: 2, at: 1.5, [0.8, 0.8])
        let k = Self.kinds(Self.run(s, until: 3.5))
        #expect(k.contains("hold") && k.filter { $0 == "tap" }.count == 1, "got \(k)")
    }

    // MARK: - Pet

    static func backAndForth(_ tau: Double, amplitude: Double = 0.15, hz: Double = 0.5) -> SIMD2<Double> {
        [0.5 + amplitude * sin(2 * .pi * hz * tau), 0.5 + 0.02 * sin(2 * .pi * hz * tau * 0.5)]
    }

    @Test func slowStrokingIsGentlePetting() {
        let s = Self.stroke(id: 1, from: 0.1, duration: 3.5) { Self.backAndForth($0) }
        let f = Self.run(s, until: 4)
        #expect(Set(Self.kinds(f)) == ["pet"], "got \(Self.kinds(f))")
        let pets = f.compactMap { if case .pet(let d, let g) = $0.g { (d, g) } else { nil } }
        #expect(pets.count >= 3, "periodic while stroking, got \(pets.count)")
        #expect(pets.map(\.0) == pets.map(\.0).sorted(), "cumulative duration")
        #expect((pets.last?.0 ?? 0) > 2)
        for p in pets { #expect(p.1 > 0.7, "gentleness \(p.1)") }
        // Roughly once a second.
        let times = f.map(\.t)
        for (a, b) in zip(times, times.dropFirst()) { #expect(b - a >= 0.99) }
    }

    @Test func roughRubbingIsLessGentle() {
        var seed: UInt64 = 7
        func noise() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) - 0.5 }
        let gentle = Self.stroke(id: 1, from: 0.1, duration: 3) { Self.backAndForth($0) }
        let rough = Self.stroke(id: 1, from: 0.1, duration: 3, radius: { _ in 20 + 12 * noise() }) { tau in
            Self.backAndForth(tau, amplitude: 0.25, hz: 1.1) + [0.02 * noise(), 0.02 * noise()]
        }
        func meanGentleness(_ f: Fired) -> Double? {
            let g = f.compactMap { if case .pet(_, let g) = $0.g { g } else { nil } }
            return g.isEmpty ? nil : g.reduce(0, +) / Double(g.count)
        }
        let g = meanGentleness(Self.run(gentle, until: 3.5)) ?? 0
        let r = meanGentleness(Self.run(rough, until: 3.5)) ?? 0
        #expect(g > 0.7)
        #expect(r < 0.45, "rough gentleness \(r)")
    }

    @Test func pettingContinuesAcrossLiftedStrokes() {
        var s: [TouchSample] = []
        for i in 0..<5 {
            let t0 = 0.1 + Double(i) * 0.9
            s += Self.stroke(id: i, from: t0, duration: 0.6) { tau in [0.3 + 0.5 * tau, 0.5] }
        }
        let f = Self.run(s, until: 5.5)
        let durations = f.compactMap { if case .pet(let d, _) = $0.g { d } else { nil } }
        #expect(durations.count >= 3, "got \(Self.kinds(f))")
        #expect((durations.last ?? 0) > 3, "one session across strokes, got \(durations)")
        #expect(!Self.kinds(f).contains("slap"))
    }

    @Test func petStopsWhenStrokingStops() {
        // Stroke for 2 s, then rest the finger without moving for 3 s.
        var s = Self.stroke(id: 1, from: 0.1, duration: 2, end: .moved) { Self.backAndForth($0) }
        s.append(TouchSample(id: 1, time: 5.1, location: s.last!.location, majorRadius: 20, phase: .ended))
        let f = Self.run(s, until: 6)
        #expect(f.filter { if case .pet = $0.g { $0.t > 2.6 } else { false } }.isEmpty, "got \(f)")
        #expect(!Self.kinds(f).contains("hold"), "a moving finger that pauses isn't a hug")
    }

    // MARK: - Tickle

    @Test func quickSmallJigglesAreATickle() {
        let s = Self.stroke(id: 1, from: 0.1, duration: 2.2, hz: 120) { tau in
            [0.5 + 0.02 * sin(2 * .pi * 6 * tau), 0.5 + 0.015 * cos(2 * .pi * 5 * tau)]
        }
        let f = Self.run(s, until: 3)
        let k = Self.kinds(f)
        #expect(k.contains("tickle"), "got \(k)")
        #expect(!k.contains("pet") && !k.contains("hold") && !k.contains("slap") && !k.contains("tap"), "got \(k)")
        let durations = f.compactMap { if case .tickle(let d) = $0.g { d } else { nil } }
        #expect(durations.count >= 2)
        #expect(durations == durations.sorted())
        #expect(f.allSatisfy { $0.t < 2.3 + 0.7 })
    }

    @Test func shortStrokesWithSidewaysJitterArePettingNotTickling() {
        // Review #13: short strokes (span ≤ tickleMaxSpan) turning around every ~0.6 s,
        // with fast sideways jitter across the stroke. Old code counted the jitter's
        // reversals and blocked the pet.
        let s = Self.stroke(id: 1, from: 0.1, duration: 3.5) { tau in
            [0.5 + 0.08 * sin(2 * .pi * 0.8 * tau), 0.5 + 0.006 * (Int(tau * 16).isMultiple(of: 2) ? 1 : -1)]
        }
        let k = Self.kinds(Self.run(s, until: 4))
        #expect(k.contains("pet"), "got \(k)")
        #expect(!k.contains("tickle"), "got \(k)")
    }

    @Test func slowTurnaroundsOnTheMainAxisAreNotATickle() {
        // Small back-and-forth at 1.55 Hz: reversals ~0.32 s apart, so 4 fit inside the
        // 1 s window (old code: tickle), but each gap is over `tickleMaxGap`.
        let s = Self.stroke(id: 1, from: 0.1, duration: 3, hz: 120) { tau in [0.5 + 0.03 * sin(2 * .pi * 1.55 * tau), 0.5] }
        #expect(!Self.kinds(Self.run(s, until: 3.5)).contains("tickle"))
    }

    @Test func twoFingerTickle() {
        var s: [TouchSample] = []
        for id in 0..<2 {
            s += Self.stroke(id: id, from: 0.1 + 0.03 * Double(id), duration: 1.5, hz: 120) { tau in
                [0.4 + 0.2 * Double(id) + 0.015 * sin(2 * .pi * 4 * tau), 0.5]
            }
        }
        #expect(Self.kinds(Self.run(s, until: 2)).contains("tickle"))
    }

    // MARK: - Slap

    @Test func wideShortContactIsASlapOnceTheBaselineIsKnown() {
        var (ti, t0) = Self.withBaseline(radius: 20)
        #expect(abs((ti.baselineRadius ?? 0) - 20) < 0.5)
        let f = Self.run(&ti, Self.tap(id: 1, at: t0, duration: 0.1, radius: 48), until: t0 + 1.5)
        #expect(Self.kinds(f.filter { $0.t >= t0 }) == ["slap"], "got \(f)")
        if case .slap(let force)? = f.last?.g { #expect(force > 0.4 && force <= 1, "force \(force)") }
    }

    @Test func ordinaryTapIsNotASlapAndPalmsDontShiftTheBaseline() {
        var (ti, t0) = Self.withBaseline(radius: 20)
        let f = Self.run(&ti, Self.tap(id: 1, at: t0, radius: 24), until: t0 + 1.5)
        #expect(Self.kinds(f.filter { $0.t >= t0 }) == ["tap"])
        _ = Self.run(&ti, Self.stroke(id: 2, from: t0 + 2, duration: 1.5, hz: 10, radius: { _ in 60 }) { _ in [0.5, 0.5] }, until: t0 + 4)
        #expect((ti.baselineRadius ?? 0) < 26)
    }

    @Test func veryWideContactIsASlapEvenWithoutABaseline() {
        let f = Self.run(Self.tap(id: 1, at: 0.1, duration: 0.09, radius: 60), until: 1)
        #expect(Self.kinds(f) == ["slap"])
    }

    @Test func fastShortBroadSwipeIsASlap() {
        // A hand (broader than a fingertip, not palm-wide) smacking across 0.12 of the face.
        let s = Self.stroke(id: 1, from: 0.1, duration: 0.03, hz: 120, radius: { _ in 36 }) { tau in [0.2 + 4.0 * tau, 0.5] }
        let f = Self.run(s, until: 1)
        #expect(Self.kinds(f) == ["slap"], "got \(f)")
        if case .slap(let force)? = f.first?.g { #expect(force >= 0.15) }
    }

    @Test func fastBroadContactIsASlapAgainstTheBaselineToo() {
        var (ti, t0) = Self.withBaseline(radius: 20)
        let s = Self.stroke(id: 1, from: t0, duration: 0.03, hz: 120, radius: { _ in 25 }) { tau in [0.2 + 4.0 * tau, 0.5] }
        let f = Self.run(&ti, s, until: t0 + 1)
        #expect(Self.kinds(f.filter { $0.t >= t0 }) == ["slap"], "1.25× the fingertip, fast, short: got \(f)")
    }

    @Test func quickFingertipFlickIsNotASlap() {
        // Review #12: a 0.1 s flick across 30% of the face at fingertip size.
        let flick = Self.stroke(id: 1, from: 0.1, duration: 0.1, hz: 120) { tau in [0.2 + 3.0 * tau, 0.5] }
        #expect(!Self.kinds(Self.run(flick, until: 1)).contains("slap"))
        // Fast and short but fingertip-sized: still not a slap.
        let jab = Self.stroke(id: 1, from: 0.1, duration: 0.03, hz: 120) { tau in [0.2 + 4.0 * tau, 0.5] }
        #expect(!Self.kinds(Self.run(jab, until: 1)).contains("slap"))
        // Broad but travelling far (a swipe of the hand across the face) isn't a slap either.
        let swipe = Self.stroke(id: 1, from: 0.1, duration: 0.1, hz: 120, radius: { _ in 36 }) { tau in [0.2 + 4.0 * tau, 0.5] }
        #expect(!Self.kinds(Self.run(swipe, until: 1)).contains("slap"))
    }

    @Test func oneJitterySampleDoesNotMakeASlapSpeedSpike() {
        // 240 Hz samples of a broad, slow, short contact with a single 0.02 jump in one
        // 1/240 s step: instantaneous speed 4.8/s, but over ≥ 8 ms it is ≈ 2.4/s.
        var s = [TouchSample(id: 1, time: 0.1, location: [0.5, 0.5], majorRadius: 36, phase: .began)]
        var x = 0.5
        for i in 1...24 {
            x += i == 12 ? 0.02 : 0.0015
            s.append(TouchSample(id: 1, time: 0.1 + Double(i) / 240, location: [x, 0.5], majorRadius: 36, phase: i == 24 ? .ended : .moved))
        }
        let f = Self.run(s, until: 1)
        #expect(!Self.kinds(f).contains("slap"), "got \(f)")
    }

    @Test func flatHandBurstIsOneSlap() {
        var s: [TouchSample] = []
        for i in 0..<4 { s += Self.tap(id: i, at: 0.1 + 0.015 * Double(i), [0.3 + 0.1 * Double(i), 0.5], duration: 0.1, radius: 22) }
        let f = Self.run(s, until: 1.5)
        #expect(Self.kinds(f) == ["slap"], "got \(f)")
    }

    @Test func slapForceGrowsWithWidth() {
        var (a, t0) = Self.withBaseline()
        var b = a
        let soft = Self.run(&a, Self.tap(id: 1, at: t0, duration: 0.1, radius: 34), until: t0 + 1)
        let hard = Self.run(&b, Self.tap(id: 1, at: t0, duration: 0.1, radius: 70), until: t0 + 1)
        guard case .slap(let s)? = soft.last?.g, case .slap(let h)? = hard.last?.g else {
            Issue.record("expected slaps: \(soft) \(hard)")
            return
        }
        #expect(h > s)
    }

    // MARK: - Robustness

    @Test func staleMovingFingersAreForgotten() {
        var ti = TouchInterpreter()
        _ = ti.add(TouchSample(id: 1, time: 0, location: [0.5, 0.5], majorRadius: 20, phase: .began))
        _ = ti.add(TouchSample(id: 1, time: 0.2, location: [0.7, 0.5], majorRadius: 20, phase: .moved))
        #expect(ti.activeTouches == 1)
        _ = ti.tick(at: 61)
        #expect(ti.activeTouches == 0)
    }

    @Test func aLongStillHugNeverGoesStale() {
        // Review #14: a finger resting still for minutes sends nothing; it must stay a hold.
        var ti = TouchInterpreter()
        _ = ti.add(TouchSample(id: 1, time: 0, location: [0.5, 0.5], majorRadius: 22, phase: .began))
        var last: Double?
        var t = 0.0
        while t <= 300 {
            for g in ti.tick(at: t) { if case .hold(let d) = g { last = d } }
            t += 0.5
        }
        #expect(ti.activeTouches == 1)
        #expect((last ?? 0) > 299, "still a hold after 5 minutes, got \(String(describing: last))")
        #expect(ti.needsFastTicks)
        // Lifting ends it as usual.
        _ = ti.add(TouchSample(id: 1, time: 300.5, location: [0.5, 0.5], majorRadius: 22, phase: .ended))
        #expect(ti.activeTouches == 0)
        // The safety cap still forgets a still finger whose `ended` never came.
        var lost = TouchInterpreter()
        _ = lost.add(TouchSample(id: 2, time: 0, location: [0.5, 0.5], majorRadius: 22, phase: .began))
        _ = lost.tick(at: 3601)
        #expect(lost.activeTouches == 0)
    }

    @Test func needsFastTicksWhileAnythingIsPending() {
        var ti = TouchInterpreter()
        #expect(!ti.needsFastTicks)
        // Finger down.
        _ = ti.add(TouchSample(id: 1, time: 0, location: [0.5, 0.5], majorRadius: 20, phase: .began))
        #expect(ti.needsFastTicks)
        // Lifted as a tap: still pending the double-tap window.
        _ = ti.add(TouchSample(id: 1, time: 0.08, location: [0.5, 0.5], majorRadius: 20, phase: .ended))
        #expect(ti.activeTouches == 0)
        #expect(ti.needsFastTicks, "a tap waits out the double-tap window")
        #expect(ti.tick(at: 0.5) == [.tap(at: [0.5, 0.5])])
        #expect(!ti.needsFastTicks)
        // A poke burst stays open until it has been quiet for `pokeGap`.
        var s: [TouchSample] = []
        for i in 0..<3 { s += Self.tap(id: 10 + i, at: 1 + Double(i) * 0.15) }
        for sample in s { _ = ti.add(sample) }
        #expect(ti.activeTouches == 0)
        #expect(ti.needsFastTicks, "poke burst still open")
        _ = ti.tick(at: 3)
        #expect(!ti.needsFastTicks)
    }

    @Test func cancelAllForgetsEveryFinger() {
        var ti = TouchInterpreter()
        _ = ti.add(TouchSample(id: 1, time: 0, location: [0.3, 0.5], majorRadius: 20, phase: .began))
        _ = ti.add(TouchSample(id: 2, time: 0.01, location: [0.6, 0.5], majorRadius: 20, phase: .began))
        ti.cancelAll()
        #expect(ti.activeTouches == 0)
        #expect(ti.tick(at: 2).isEmpty)
        #expect(!ti.needsFastTicks)
    }

    @Test func unknownIdsAndDuplicateBeginsAreHarmless() {
        var ti = TouchInterpreter()
        #expect(ti.add(TouchSample(id: 9, time: 0, location: [0.5, 0.5], majorRadius: 20, phase: .moved)).isEmpty)
        #expect(ti.add(TouchSample(id: 9, time: 0.1, location: [0.5, 0.5], majorRadius: 20, phase: .ended)).isEmpty)
        _ = ti.add(TouchSample(id: 1, time: 0.2, location: [0.5, 0.5], majorRadius: 20, phase: .began))
        _ = ti.add(TouchSample(id: 1, time: 0.25, location: [0.5, 0.5], majorRadius: 20, phase: .began))
        #expect(ti.activeTouches == 1)
        _ = ti.add(TouchSample(id: 1, time: 0.3, location: [0.5, 0.5], majorRadius: 0, phase: .ended))
        #expect(ti.activeTouches == 0)
    }

    @Test func zeroRadiusNeverSlaps() {
        // Simulators and some hardware report 0.
        let f = Self.run(Self.tap(id: 1, at: 0.1, radius: 0), until: 1)
        #expect(Self.kinds(f) == ["tap"])
    }
}
