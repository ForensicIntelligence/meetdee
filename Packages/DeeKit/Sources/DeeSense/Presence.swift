import Foundation

/// Debounced "is someone there?" with a smoothed position for the eyes to follow.
public struct PresenceTracker: Sendable {
    public enum Event: Sendable, Equatable { case arrived, left }

    /// Consecutive sightings needed before someone counts as arrived.
    public var arriveFrames = 3
    /// Seconds without a face before they count as gone.
    public var leaveAfter = 1.5

    public private(set) var isPresent = false
    /// Where the face is, −1…1 (x toward the user's right as they see the screen, y down).
    public private(set) var position: SIMD2<Double>?
    /// Apparent face size (fraction of frame width) — a proxy for distance.
    public private(set) var faceSize = 0.0
    public private(set) var lastSeen: Double?
    /// When the current absence began: nil while someone is present and before the
    /// tracker has seen its first frame. The first `update`/`tick` (with or without a
    /// face) starts the clock — "absent since tracking began" — so times can come from
    /// any monotonic clock (no assumption that t starts at 0).
    public private(set) var absentSince: Double?

    private var streak = 0
    private var started = false

    public init() {}

    /// - Parameters:
    ///   - face: normalised bounding-box centre (Vision coordinates, origin bottom-left,
    ///     mirrored) and width, or nil if no face this frame.
    public mutating func update(face: (center: SIMD2<Double>, width: Double)?, at t: Double) -> Event? {
        begin(at: t)
        if let face {
            streak += 1
            lastSeen = t
            // Map to gaze space; faces cluster near the centre, so amplify a little.
            let target = SIMD2(
                clamp((face.center.x - 0.5) * 2 * 1.5),
                clamp(-(face.center.y - 0.55) * 2 * 1.5)
            )
            position = position.map { $0 + (target - $0) * 0.45 } ?? target
            faceSize = faceSize == 0 ? face.width : faceSize + (face.width - faceSize) * 0.3
            if !isPresent, streak >= arriveFrames {
                isPresent = true
                absentSince = nil
                return .arrived
            }
        } else {
            streak = 0
            if isPresent, let seen = lastSeen, t - seen >= leaveAfter {
                isPresent = false
                position = nil
                absentSince = t
                return .left
            }
        }
        return nil
    }

    /// Lets time pass without a frame (call it from a timer). Detects leaving even when
    /// the camera has stopped delivering frames, without disturbing an arrival streak
    /// that frames are still building.
    public mutating func tick(at t: Double) -> Event? {
        begin(at: t)
        guard let seen = lastSeen, t - seen >= leaveAfter else { return nil }
        streak = 0
        if isPresent {
            isPresent = false
            position = nil
            absentSince = t
            return .left
        }
        return nil
    }

    /// Forgets everyone (e.g. the camera was interrupted). Returns `.left` if someone
    /// was present. Absence counts from `t`.
    public mutating func reset(at t: Double) -> Event? {
        let wasPresent = isPresent
        let size = (arriveFrames, leaveAfter)
        self = PresenceTracker()
        (arriveFrames, leaveAfter) = size
        started = true
        absentSince = t
        return wasPresent ? .left : nil
    }

    private mutating func begin(at t: Double) {
        guard !started else { return }
        started = true
        if !isPresent { absentSince = t }
    }

    /// Seconds nobody has been in view (0 while someone is, and before the first frame).
    public func absentDuration(at t: Double) -> Double {
        guard !isPresent, let since = absentSince else { return 0 }
        return max(0, t - since)
    }

    private func clamp(_ v: Double) -> Double { min(max(v, -1), 1) }
}
