import Foundation

/// Hand joints we use, independent of Vision so the logic is unit-testable.
public enum HandJoint: String, CaseIterable, Sendable {
    case wrist
    case thumbTip, thumbIP, thumbMP
    case indexTip, indexPIP, indexMCP
    case middleTip, middlePIP, middleMCP
    case ringTip, ringPIP, ringMCP
    case littleTip, littlePIP, littleMCP
}

/// One detected hand. Points are normalised image coordinates, origin bottom-left
/// (Vision's convention), already mirrored so they match what the user sees.
public struct HandPose: Sendable, Equatable {
    public var joints: [HandJoint: SIMD2<Double>]
    public init(_ joints: [HandJoint: SIMD2<Double>]) { self.joints = joints }

    func p(_ j: HandJoint) -> SIMD2<Double>? { joints[j] }

    /// Wrist → middle-finger knuckle: the hand's own unit of length.
    var scale: Double? {
        guard let w = p(.wrist), let m = p(.middleMCP) else { return nil }
        return max(distance(w, m), 1e-3)
    }

    func fingerExtended(tip: HandJoint, pip: HandJoint) -> Bool? {
        guard let w = p(.wrist), let t = p(tip), let k = p(pip) else { return nil }
        return distance(t, w) > distance(k, w) * 1.18
    }

    var extendedFingers: Int {
        [(HandJoint.indexTip, HandJoint.indexPIP), (.middleTip, .middlePIP), (.ringTip, .ringPIP), (.littleTip, .littlePIP)]
            .compactMap { fingerExtended(tip: $0.0, pip: $0.1) }
            .filter { $0 }.count
    }

    var thumbExtended: Bool {
        guard let tip = p(.thumbTip), let ip = p(.thumbIP), let base = p(.indexMCP) else { return false }
        return distance(tip, base) > distance(ip, base) * 1.15
    }

    /// Centre of the palm (average of wrist and knuckles).
    var palm: SIMD2<Double>? {
        let pts = [HandJoint.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP].compactMap { p($0) }
        guard pts.count >= 3 else { return nil }
        return pts.reduce(.zero, +) / Double(pts.count)
    }

    enum Shape: Equatable { case openPalm, thumbsUp, other }

    var shape: Shape {
        guard let s = scale else { return .other }
        if extendedFingers == 4, thumbExtended { return .openPalm }
        if extendedFingers == 0, thumbExtended, let tip = p(.thumbTip), let w = p(.wrist) {
            let others = [HandJoint.indexTip, .middleTip, .ringTip, .littleTip].compactMap { p($0)?.y }
            let highest = others.max() ?? w.y
            if tip.y > highest + 0.35 * s, tip.y > w.y + 0.5 * s { return .thumbsUp }
        }
        return .other
    }
}

public enum Gesture: String, Sendable, Equatable {
    /// Hand waving side to side: "hello" / wake up.
    case wave
    /// Open palm held still toward the camera: "stop" / hush.
    case palm
    /// Thumbs up: "yes" / approval.
    case thumbsUp
}

/// Turns a stream of per-frame hand poses into discrete gestures.
public struct GestureRecognizer: Sendable {
    public var waveWindow = 1.6
    public var palmHold = 0.7
    public var thumbHold = 0.45
    public var cooldown = 2.0

    private var palmTrack: [(t: Double, x: Double, y: Double)] = []
    private var palmSince: Double?
    private var thumbSince: Double?
    private var lastFired: [Gesture: Double] = [:]

    public init() {}

    /// Feed one frame (`nil` when no hand is visible). Returns a gesture when one completes.
    public mutating func update(_ hand: HandPose?, at t: Double) -> Gesture? {
        guard let hand, let scale = hand.scale, let palm = hand.palm else {
            palmTrack.removeAll()
            palmSince = nil
            thumbSince = nil
            return nil
        }

        switch hand.shape {
        case .openPalm:
            thumbSince = nil
            palmTrack.append((t, palm.x, palm.y))
            palmTrack.removeAll { t - $0.t > waveWindow }
            if palmSince == nil { palmSince = t }

            if Self.reversals(palmTrack.map(\.x), minSwing: 0.35 * scale) >= 2 {
                palmTrack.removeAll()
                palmSince = nil
                return fire(.wave, at: t)
            }
            // Held still long enough → palm.
            let recent = palmTrack.filter { t - $0.t <= palmHold }
            let xs = recent.map(\.x), ys = recent.map(\.y)
            if let since = palmSince, t - since >= palmHold,
               let xmin = xs.min(), let xmax = xs.max(), let ymin = ys.min(), let ymax = ys.max(),
               xmax - xmin < 0.25 * scale, ymax - ymin < 0.25 * scale {
                palmSince = nil
                palmTrack.removeAll()
                return fire(.palm, at: t)
            }
        case .thumbsUp:
            palmTrack.removeAll()
            palmSince = nil
            if thumbSince == nil { thumbSince = t }
            if let since = thumbSince, t - since >= thumbHold {
                thumbSince = nil
                return fire(.thumbsUp, at: t)
            }
        case .other:
            palmTrack.removeAll()
            palmSince = nil
            thumbSince = nil
        }
        return nil
    }

    private mutating func fire(_ g: Gesture, at t: Double) -> Gesture? {
        if let last = lastFired[g], t - last < cooldown { return nil }
        lastFired[g] = t
        return g
    }

    /// Direction changes in a 1-D track, counting only swings of at least `minSwing`.
    static func reversals(_ xs: [Double], minSwing: Double) -> Int {
        guard let first = xs.first else { return 0 }
        var hi = first, lo = first
        var direction = 0 // +1 rising, −1 falling, 0 not yet moving
        var count = 0
        for x in xs.dropFirst() {
            switch direction {
            case 0:
                hi = max(hi, x)
                lo = min(lo, x)
                if hi - lo >= minSwing {
                    direction = x == hi ? 1 : -1
                    hi = x
                    lo = x
                }
            case 1:
                if x > hi { hi = x } else if hi - x >= minSwing {
                    count += 1
                    direction = -1
                    lo = x
                }
            default:
                if x < lo { lo = x } else if x - lo >= minSwing {
                    count += 1
                    direction = 1
                    hi = x
                }
            }
        }
        return count
    }
}

@inline(__always) func distance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
    let d = a - b
    return (d.x * d.x + d.y * d.y).squareRoot()
}
