import Foundation
import simd

/// One raw touch sample from the face view (UIKit's `UITouch`, flattened so the
/// interpreter is pure and testable with synthetic streams).
public struct TouchSample: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case began, moved, ended, cancelled }
    public var id: Int
    public var time: Double                // seconds, monotonic
    public var location: SIMD2<Double>     // 0…1 in the face view, y down
    public var majorRadius: Double         // points (UITouch.majorRadius)
    public var phase: Phase
    public init(id: Int, time: Double, location: SIMD2<Double>, majorRadius: Double, phase: Phase) {
        self.id = id
        self.time = time
        self.location = location
        self.majorRadius = majorRadius
        self.phase = phase
    }
}

/// What a touch *meant*.
public enum TouchGesture: Sendable, Equatable {
    case tap(at: SIMD2<Double>)
    case doubleTap(at: SIMD2<Double>)
    case pet(duration: Double, gentleness: Double)  // slow strokes; gentleness 0…1
    case hold(duration: Double)                     // still, steady contact ("a hug")
    case pokes(count: Int, rate: Double, total: Int) // rapid repeated taps; total = pokes so far in the burst
    case slap(force: Double)                        // fast, hard, short contact; 0…1
    case tickle(duration: Double)                   // quick small jiggles
}

/// Turns raw touches on Dee's face into gestures with feeling: taps, double taps,
/// petting, holding, pokes, slaps and tickles.
///
/// Feed every `UITouch` sample to `add(_:)` and call `tick(at:)` regularly (10–60 Hz)
/// — a finger resting still sends no events, so holds, the single-vs-double-tap
/// decision and the end of a poke burst are driven by time. `needsFastTicks` says
/// when that matters: tick at ~30 Hz while it is true and as slowly as you like
/// (or not at all) otherwise.
///
/// Timing of what comes out:
/// - `tap` once the double-tap window (`doubleTapGap`) has passed quietly;
///   `doubleTap` the same way after the second tap.
/// - `pokes` as soon as the third tap lands within `pokeWindow`, then for every
///   further `pokeBatch` taps and once more when the burst ends with any left over.
///   `count` is the number of new pokes in that event (the first event counts the
///   three that started the burst), `total` the running number of pokes in the burst
///   so far (3, 6, 9, … — what escalation should key on), `rate` is taps per second
///   over the burst so far.
/// - `pet`, `hold` and `tickle` first fire when recognised, then every
///   `repeatEvery` seconds while they continue, with the cumulative duration.
/// - `slap` when the (short) contact ends, or when a burst of ≥3 fingers that
///   landed together all lift quickly (a flat-hand slap). A short contact is a slap
///   when it is wide (a palm), or when it is fast *and* broader than a fingertip
///   *and* short in travel — a quick fingertip flick across the face is not a slap.
///
/// Multi-touch safe: every finger is tracked by id; two fingers landing together
/// count as one tap; several still fingers are one hold; several stroking fingers
/// one pet.
public struct TouchInterpreter: Sendable {
    // MARK: Tunables (view units are 0…1 of the face view; seconds; points)

    var tapMaxDuration = 0.3
    var tapMaxTravel = 0.04
    /// Quiet time after a tap before it is final; also the largest gap for a double tap.
    var doubleTapGap = 0.3
    var doubleTapDistance = 0.15
    /// Fingers landing this close together form one tap / a slap group.
    var simultaneity = 0.08
    var pokeWindow = 1.5
    /// A poke burst ends after this long without a tap.
    var pokeGap = 0.75
    var pokeBatch = 3

    var slapMaxDuration = 0.2
    var slapSpeed = 3.0
    var slapMinTravel = 0.05
    /// A fast contact travelling this far or more is a flick/swipe, not a slap.
    var slapMaxTravel = 0.15
    var slapRadiusRatio = 1.6
    /// A fast (non-wide) contact must still be at least this much broader than the
    /// user's fingertip to be a slap (a hand, not a flick).
    var slapFastRadiusRatio = 1.2
    /// Speeds are measured over at least this long, so one jittery sample at
    /// 240 Hz can't fake a slap-speed spike.
    var speedWindow = 0.008
    /// Before the user's baseline is known, a contact this wide (points) is a slap.
    var slapAbsoluteRadius = 45.0
    var slapBurstFingers = 3
    var slapBurstMaxDuration = 0.25

    var holdAfter = 0.8
    var holdMaxDrift = 0.035

    var petMinPath = 0.12
    var petMinContact = 0.5
    var petMaxSpeed = 2.0
    var petSessionGap = 1.2

    var tickleReversals = 4
    var tickleWindow = 1.0
    /// Reversals further apart than this break the chain (a tickle jiggles at ≳3 Hz;
    /// a stroke turning around does not).
    var tickleMaxGap = 0.3
    var tickleMinExcursion = 0.006
    var tickleMaxSpan = 0.2
    var tickleEndAfter = 0.6

    var repeatEvery = 1.0
    /// A *moving* finger silent this long (no `ended`, no samples) is forgotten.
    var staleAfter = 60.0
    /// A still (holding) finger legitimately sends nothing, so it is only forgotten
    /// after this much longer safety cap — a long cuddle stays a hold.
    var holdStaleAfter = 3600.0

    // MARK: State

    struct Finger: Sendable {
        var start: Double
        var startLocation: SIMD2<Double>
        var last: Double
        var location: SIMD2<Double>
        var startRadius: Double
        var maxRadius: Double
        var maxDrift = 0.0
        var path = 0.0
        var peakSpeed = 0.0
        var velocity: SIMD2<Double>?
        var moving = false
        var group: Int?
        // Per-axis reversal detection (tickle).
        var direction: SIMD2<Double> = .zero
        var anchor: SIMD2<Double>
        var recent: [(t: Double, p: SIMD2<Double>)] = []
    }

    struct Tap: Sendable { var start: Double; var end: Double; var at: SIMD2<Double> }

    struct Segment: Sendable { var t: Double; var speed: Double; var jerk: Double?; var radius: Double }

    private var fingers: [Int: Finger] = [:]
    private var now = -Double.infinity

    // Taps / pokes.
    private var pendingTaps: [Tap] = []
    private var recentTaps: [Tap] = []
    private var poking = false
    private var pokeStart = 0.0
    private var pokeCount = 0
    private var pokeUnsent = 0
    private var lastTapTime = -Double.infinity

    // Slap groups (fingers landing together).
    private struct Group: Sendable { var start: Double; var members: Set<Int>; var ended: Int = 0; var lastEnd: Double = 0; var maxRadius: Double = 0 }
    private var groups: [Int: Group] = [:]
    private var nextGroup = 0

    // User's ordinary finger size.
    private(set) var baselineRadius: Double?
    private(set) var baselineSamples = 0

    // Hold.
    private var holdStart: Double?
    private var holdLastEmit = -Double.infinity

    // Pet.
    private var petStart: Double?
    private var petLastMove = -Double.infinity
    private var petLastAccum = -Double.infinity
    private var petPath = 0.0
    private var petContact = 0.0
    private var petContactAtEmit = 0.0
    private var petLastEmit = -Double.infinity
    private var petEmitted = false
    private var petSegments: [Segment] = []

    // Tickle.
    private var reversals: [Double] = []
    private var tickleStart: Double?
    private var tickleLastReversal = -Double.infinity
    private var tickleLastEmit = -Double.infinity

    public init() {}

    /// Number of fingers currently down.
    public var activeTouches: Int { fingers.count }

    /// True while time-driven output may be due: fingers are down (holds, pets,
    /// tickles), a tap is waiting out the double-tap window, or a poke burst is still
    /// open. Tick at ~30 Hz while this is true so reactions aren't late.
    public var needsFastTicks: Bool { !fingers.isEmpty || !pendingTaps.isEmpty || poking }

    /// Forgets every finger (e.g. the view disappeared or the app went to the
    /// background without `touchesCancelled`). Taps already made still resolve.
    public mutating func cancelAll() {
        for id in Array(fingers.keys) { cancelled(id) }
    }

    // MARK: - Input

    public mutating func add(_ sample: TouchSample) -> [TouchGesture] {
        let t = sample.time
        var out = advance(to: t)
        switch sample.phase {
        case .began: began(sample, &out)
        case .moved: moved(sample, &out)
        case .ended: moved(sample, &out); ended(sample.id, at: t, &out)
        case .cancelled: cancelled(sample.id)
        }
        out += advance(to: t)
        return out
    }

    public mutating func tick(at t: Double) -> [TouchGesture] {
        // A still finger sends nothing while it holds, so only moving fingers go
        // stale at `staleAfter`; holding ones get the much longer safety cap.
        for (id, f) in fingers where t - f.last > (f.moving ? staleAfter : holdStaleAfter) { cancelled(id) }
        return advance(to: t)
    }

    // MARK: - Phases

    private mutating func began(_ s: TouchSample, _ out: inout [TouchGesture]) {
        if fingers[s.id] != nil { cancelled(s.id) }   // id reused without an end
        var f = Finger(start: s.time, startLocation: s.location, last: s.time, location: s.location,
                       startRadius: s.majorRadius, maxRadius: s.majorRadius, anchor: s.location)
        f.recent = [(s.time, s.location)]
        // Fingers landing together form a group (a flat hand).
        let partners = fingers.filter { abs($0.value.start - s.time) <= simultaneity }
        if let existing = partners.compactMap({ $0.value.group }).first {
            f.group = existing
            groups[existing]?.members.insert(s.id)
        } else if !partners.isEmpty {
            let g = nextGroup
            nextGroup += 1
            var members = Set(partners.keys)
            members.insert(s.id)
            groups[g] = Group(start: partners.values.map(\.start).min() ?? s.time, members: members)
            for id in partners.keys { fingers[id]?.group = g }
            f.group = g
        }
        fingers[s.id] = f
    }

    private mutating func moved(_ s: TouchSample, _ out: inout [TouchGesture]) {
        guard var f = fingers[s.id] else { return }
        let t = max(s.time, f.last)
        let dt = t - f.last
        let step = s.location - f.location
        let len = length(step)
        f.maxRadius = max(f.maxRadius, s.majorRadius)
        f.path += len
        f.maxDrift = max(f.maxDrift, length(s.location - f.startLocation))
        var jerk: Double?
        var speed = 0.0
        if dt > 0, len > 0 {
            let v = step / max(dt, 1.0 / 240)
            speed = length(v)
            if let pv = f.velocity { jerk = length(v - pv) }
            f.velocity = v
        }
        if f.maxDrift > holdMaxDrift { f.moving = true }
        f.recent.append((t, s.location))
        f.recent.removeAll { t - $0.t > tickleWindow }
        // Peak speed over ≥ `speedWindow` (the newest earlier sample at least that old).
        if let q = f.recent.last(where: { t - $0.t >= speedWindow }) {
            f.peakSpeed = max(f.peakSpeed, length(s.location - q.p) / (t - q.t))
        }
        detectReversals(&f, at: t, location: s.location)
        f.last = t
        f.location = s.location
        fingers[s.id] = f

        // Petting: movement from fingers that are really moving and not tickling.
        if f.moving, len > 0, !isTickling(at: t) {
            if petStart == nil || t - petLastMove > petSessionGap { startPet(at: t - min(dt, 0.1)) }
            petPath += len
            let accumFrom = max(petLastAccum, t - min(dt, 0.1))
            if t > accumFrom { petContact += t - accumFrom }
            petLastAccum = t
            petLastMove = t
            petSegments.append(Segment(t: t, speed: speed, jerk: jerk, radius: s.majorRadius))
            petSegments.removeAll { t - $0.t > 2 }
        }
    }

    private mutating func ended(_ id: Int, at t: Double, _ out: inout [TouchGesture]) {
        guard let f = fingers.removeValue(forKey: id) else { return }
        let duration = t - f.start

        // Group (flat hand): slap when every finger lifted quickly.
        if let gid = f.group, var g = groups[gid] {
            g.ended += 1
            g.lastEnd = t
            g.maxRadius = max(g.maxRadius, f.maxRadius)
            groups[gid] = g
            if g.ended >= g.members.count {
                groups[gid] = nil
                if g.members.count >= slapBurstFingers {
                    if g.lastEnd - g.start <= slapBurstMaxDuration {
                        out.append(.slap(force: burstForce(fingers: g.members.count, radius: g.maxRadius)))
                    }
                    return
                }
            } else if g.members.count >= slapBurstFingers {
                return
            }
        }

        if duration <= slapMaxDuration, let force = slapForce(f) {
            out.append(.slap(force: force))
            return
        }
        learnBaseline(f)
        if duration <= tapMaxDuration, f.maxDrift <= tapMaxTravel {
            tapped(Tap(start: f.start, end: t, at: f.startLocation), &out)
        }
    }

    private mutating func cancelled(_ id: Int) {
        guard let f = fingers.removeValue(forKey: id) else { return }
        if let gid = f.group, var g = groups[gid] {
            g.members.remove(id)
            groups[gid] = g.members.count <= g.ended ? nil : g
        }
    }

    // MARK: - Taps, double taps, pokes

    private mutating func tapped(_ tap: Tap, _ out: inout [TouchGesture]) {
        // Two fingers landing together are one tap.
        if let last = recentTaps.last, abs(last.start - tap.start) <= simultaneity {
            let mid = (last.at + tap.at) / 2
            recentTaps[recentTaps.count - 1].at = mid
            if let p = pendingTaps.last, p.start == last.start { pendingTaps[pendingTaps.count - 1].at = mid }
            return
        }
        recentTaps.removeAll { tap.start - $0.start > pokeWindow }
        // Only an unbroken run counts (a double tap and then a tap a second later isn't poking).
        if let last = recentTaps.last, tap.start - last.start > pokeGap { recentTaps.removeAll() }
        recentTaps.append(tap)
        lastTapTime = tap.end

        if poking {
            pokeCount += 1
            pokeUnsent += 1
            if pokeUnsent >= pokeBatch { sendPokes(&out) }
            return
        }
        if recentTaps.count >= 3 {
            poking = true
            pokeStart = recentTaps[0].start
            pokeCount = recentTaps.count
            pokeUnsent = recentTaps.count
            pendingTaps.removeAll()
            sendPokes(&out)
            return
        }
        pendingTaps.append(tap)
    }

    private mutating func sendPokes(_ out: inout [TouchGesture]) {
        guard pokeUnsent > 0 else { return }
        let span = lastTapTime - pokeStart
        let rate = span > 0 ? Double(pokeCount - 1) / span : Double(pokeCount)
        out.append(.pokes(count: pokeUnsent, rate: rate, total: pokeCount))
        pokeUnsent = 0
    }

    private mutating func resolveTaps(at t: Double, _ out: inout [TouchGesture]) {
        if poking, t - lastTapTime > pokeGap {
            sendPokes(&out)
            poking = false
            recentTaps.removeAll()
        }
        guard let last = pendingTaps.last, t - last.end > doubleTapGap else { return }
        // A young, still finger may be the second tap: wait for it.
        let maybeTap = fingers.values.contains { t - $0.start <= tapMaxDuration && $0.maxDrift <= tapMaxTravel }
        guard !maybeTap else { return }
        var i = 0
        while i < pendingTaps.count {
            let a = pendingTaps[i]
            if i + 1 < pendingTaps.count {
                let b = pendingTaps[i + 1]
                if b.start - a.end <= doubleTapGap, length(b.at - a.at) <= doubleTapDistance {
                    out.append(.doubleTap(at: a.at))
                    i += 2
                    continue
                }
            }
            out.append(.tap(at: a.at))
            i += 1
        }
        pendingTaps.removeAll()
    }

    // MARK: - Slaps

    private func radiusRatio(_ r: Double) -> Double? {
        guard r > 0, let b = baselineRadius, baselineSamples >= 3, b > 0 else { return nil }
        return r / b
    }

    /// Contact size relative to the user's fingertip; before the baseline is known,
    /// relative to a nominal fingertip (`slapAbsoluteRadius / slapRadiusRatio`).
    private func contactRatio(_ r: Double) -> Double {
        guard r > 0, r.isFinite else { return 0 }
        return radiusRatio(r) ?? r / (slapAbsoluteRadius / slapRadiusRatio)
    }

    private func isWide(_ r: Double) -> Bool {
        guard r > 0 else { return false }
        if let ratio = radiusRatio(r) { return ratio >= slapRadiusRatio }
        return r >= slapAbsoluteRadius
    }

    /// Force of a short contact, or nil when it wasn't a slap.
    func slapForce(_ f: Finger) -> Double? {
        let wide = isWide(f.maxRadius)
        let fast = f.peakSpeed >= slapSpeed && f.maxDrift >= slapMinTravel && f.maxDrift < slapMaxTravel
            && contactRatio(f.maxRadius) >= slapFastRadiusRatio
        guard wide || fast else { return nil }
        var force = 0.0
        if wide {
            let ratio = radiusRatio(f.maxRadius) ?? f.maxRadius / (slapAbsoluteRadius / slapRadiusRatio)
            force = max(force, (ratio - 1.3) / 1.7)
        }
        if fast { force = max(force, (f.peakSpeed - 2) / 6) }
        return min(1, max(0.15, force))
    }

    private func burstForce(fingers n: Int, radius: Double) -> Double {
        var force = Double(n - 2) / 3
        if let ratio = radiusRatio(radius) { force = max(force, (ratio - 1.3) / 1.7) }
        return min(1, max(0.3, force))
    }

    private mutating func learnBaseline(_ f: Finger) {
        let r = f.startRadius
        guard r > 0, r.isFinite else { return }
        if let b = baselineRadius {
            if baselineSamples >= 3, r / b >= slapRadiusRatio { return }   // a palm, not a fingertip
            let clamped = min(max(r, b * 0.5), b * 1.5)
            baselineRadius = b + (clamped - b) * 0.2
        } else {
            guard r < slapAbsoluteRadius else { return }
            baselineRadius = r
        }
        baselineSamples += 1
    }

    // MARK: - Tickle

    private mutating func detectReversals(_ f: inout Finger, at t: Double, location p: SIMD2<Double>) {
        // Only turnarounds along the finger's main axis of motion count: sideways
        // jitter during a stroke is not a jiggle.
        let main = mainAxis(f.recent)
        for axis in 0..<2 {
            let d = p[axis] - f.anchor[axis]
            if f.direction[axis] == 0 {
                if abs(d) >= tickleMinExcursion { f.direction[axis] = d > 0 ? 1 : -1; f.anchor[axis] = p[axis] }
            } else if d * f.direction[axis] > 0 {
                f.anchor[axis] = p[axis]                       // further the same way
            } else if abs(d) >= tickleMinExcursion {
                f.direction[axis] = -f.direction[axis]         // turned around
                f.anchor[axis] = p[axis]
                if axis == main, span(f.recent) <= tickleMaxSpan {
                    if let last = reversals.last, t - last > tickleMaxGap { reversals.removeAll() }
                    reversals.append(t)
                }
            }
        }
        reversals.removeAll { t - $0 > tickleWindow }
        if reversals.count >= tickleReversals {
            if tickleStart == nil || t - tickleLastReversal > tickleEndAfter {
                tickleStart = reversals.first ?? t
                tickleLastEmit = -.infinity
            }
            tickleLastReversal = t
        } else if tickleStart != nil, reversals.last == t {
            tickleLastReversal = t
        }
    }

    /// 0 (x) or 1 (y): the axis with the larger extent over the recent samples.
    private func mainAxis(_ pts: [(t: Double, p: SIMD2<Double>)]) -> Int {
        guard let first = pts.first else { return 0 }
        var lo = first.p, hi = first.p
        for q in pts { lo = pointwiseMin(lo, q.p); hi = pointwiseMax(hi, q.p) }
        return hi.y - lo.y > hi.x - lo.x ? 1 : 0
    }

    private func span(_ pts: [(t: Double, p: SIMD2<Double>)]) -> Double {
        guard let first = pts.first else { return 0 }
        var lo = first.p, hi = first.p
        for q in pts { lo = pointwiseMin(lo, q.p); hi = pointwiseMax(hi, q.p) }
        return max(hi.x - lo.x, hi.y - lo.y)
    }

    private func isTickling(at t: Double) -> Bool {
        tickleStart != nil && t - tickleLastReversal <= tickleEndAfter
    }

    // MARK: - Pet

    private mutating func startPet(at t: Double) {
        petStart = t
        petPath = 0
        petContact = 0
        petContactAtEmit = 0
        petLastEmit = -.infinity
        petLastAccum = t
        petEmitted = false
        petSegments.removeAll()
    }

    /// 0…1: slow, steady-pressure, smooth strokes are gentle.
    func gentleness() -> Double {
        let segs = petSegments
        guard !segs.isEmpty else { return 0.5 }
        let meanSpeed = petContact > 0 ? petPath / petContact : segs.map(\.speed).reduce(0, +) / Double(segs.count)
        let speedScore = clamp01(1 - (meanSpeed - 0.25) / 1.35)
        let speeds = segs.map(\.speed).filter { $0 > 0 }
        let meanV = speeds.isEmpty ? 0 : speeds.reduce(0, +) / Double(speeds.count)
        let jerks = segs.compactMap(\.jerk)
        let smooth: Double
        if jerks.isEmpty || meanV <= 0 { smooth = 0.6 } else {
            let ratio = (jerks.reduce(0, +) / Double(jerks.count)) / meanV
            smooth = clamp01(1 - (ratio - 0.15) / 0.85)
        }
        let radii = segs.map(\.radius).filter { $0 > 0 }
        var steady = 0.7
        if radii.count >= 3 {
            let m = radii.reduce(0, +) / Double(radii.count)
            let sd = (radii.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(radii.count)).squareRoot()
            steady = clamp01(1 - (sd / max(m, 1e-6)) / 0.35)
        }
        return clamp01(0.5 * speedScore + 0.25 * smooth + 0.25 * steady)
    }

    // MARK: - Time

    private mutating func advance(to t: Double) -> [TouchGesture] {
        now = max(now, t)
        let t = now
        var out: [TouchGesture] = []
        resolveTaps(at: t, &out)

        // Hold: still fingers past `holdAfter`.
        let still = isTickling(at: t) ? [] : fingers.values.filter { !$0.moving && t - $0.start >= holdAfter }
        if let earliest = still.map(\.start).min() {
            if holdStart == nil { holdStart = earliest; holdLastEmit = -.infinity }
            if let hs = holdStart, t - holdLastEmit >= repeatEvery - 1e-9 {
                out.append(.hold(duration: t - hs))
                holdLastEmit = t
            }
        } else {
            holdStart = nil
        }

        // Tickle.
        if let ts = tickleStart {
            if t - tickleLastReversal > tickleEndAfter {
                tickleStart = nil
            } else if t - tickleLastEmit >= repeatEvery - 1e-9 {
                out.append(.tickle(duration: max(0, t - ts)))
                tickleLastEmit = t
            }
        }

        // Pet.
        if let ps = petStart {
            if t - petLastMove > petSessionGap {
                petStart = nil
            } else if petPath >= petMinPath, petContact >= petMinContact, !isTickling(at: t),
                      petContact > 0, petPath / petContact <= petMaxSpeed,
                      t - petLastEmit >= repeatEvery - 1e-9, t - petLastMove <= 0.35,
                      !petEmitted || petContact - petContactAtEmit >= 0.2 {
                out.append(.pet(duration: t - ps, gentleness: gentleness()))
                petLastEmit = t
                petContactAtEmit = petContact
                petEmitted = true
            }
        }
        return out
    }
}

private func clamp01(_ x: Double) -> Double { min(1, max(0, x.isFinite ? x : 0)) }
