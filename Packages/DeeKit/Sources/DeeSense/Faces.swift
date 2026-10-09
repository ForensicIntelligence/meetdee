import CoreGraphics
import Foundation

// v0.5 additions to the camera: head pose (`SenseUpdate.head`), face crops for
// recognition (`SenseUpdate.faces`) and one-shot glances (`CameraSense.glanceNow`).
// Everything here is pure (no AVFoundation, no Vision) so it is unit-tested directly.

// MARK: - Face crops

/// One face in a camera frame, ready for `DeeMemory.FaceEmbedder.print(of:faceBox:)`.
///
/// `image` is the whole front-camera frame, already upright and mirrored exactly as
/// Vision saw it (selfie view: image-left is the user's left), so `box` is valid for it
/// without any orientation. It is a private copy: holding it does not hold a capture
/// buffer. Several crops from the same frame share one `image`.
public struct FaceCrop: Sendable, Equatable {
    /// The full upright, mirrored frame (immutable).
    public var image: CGImage
    /// Vision normalised rect (0…1, origin bottom-left) relative to `image`.
    public var box: CGRect
    /// Vision face-capture quality 0…1, or −1 when Vision could not score this face.
    public var quality: Double
    /// Degrees, as Vision reports it on the mirrored frame (use the magnitude for "frontal").
    public var yaw: Double
    /// Degrees, as Vision reports it on the mirrored frame.
    public var roll: Double
    /// Face width as a fraction of the frame width (`box.width`): a proxy for distance.
    public var area: Double

    public init(image: CGImage, box: CGRect, quality: Double, yaw: Double, roll: Double, area: Double) {
        self.image = image
        self.box = box
        self.quality = quality
        self.yaw = yaw
        self.roll = roll
        self.area = area
    }

    /// Same frame (identity) and same numbers.
    public static func == (a: FaceCrop, b: FaceCrop) -> Bool {
        a.image === b.image && a.box == b.box && a.quality == b.quality
            && a.yaw == b.yaw && a.roll == b.roll && a.area == b.area
    }
}

/// A face as the camera's Vision pass found it (angles in degrees). Internal.
struct DetectedFace: Sendable, Equatable {
    var box: CGRect
    var yaw: Double
    var roll: Double
    var pitch: Double
}

enum FaceCrops {
    /// Quality observations are matched to faces by overlap above this IoU.
    static let matchOverlap = 0.3

    /// All faces, biggest first (ties: left to right, then bottom to top, so the order
    /// is deterministic). Each face takes the capture-quality score of the quality
    /// observation that overlaps it best (IoU > `matchOverlap`), else −1. Faces with a
    /// degenerate or non-finite box are dropped.
    static func make(image: CGImage, faces: [DetectedFace], qualities: [(box: CGRect, score: Double)]) -> [FaceCrop] {
        faces
            .filter { valid($0.box) }
            .sorted { a, b in
                if a.box.width != b.box.width { return a.box.width > b.box.width }
                if a.box.minX != b.box.minX { return a.box.minX < b.box.minX }
                return a.box.minY < b.box.minY
            }
            .map { f in
                let best = qualities
                    .filter { $0.score.isFinite }
                    .map { (iou: overlap($0.box, f.box), score: $0.score) }
                    .filter { $0.iou > matchOverlap }
                    .max { $0.iou < $1.iou }
                let quality = best.map { min(1, max(0, $0.score)) } ?? -1
                return FaceCrop(image: image, box: f.box, quality: quality,
                                yaw: f.yaw.isFinite ? f.yaw : 0, roll: f.roll.isFinite ? f.roll : 0,
                                area: Double(f.box.width))
            }
    }

    static func valid(_ r: CGRect) -> Bool {
        r.origin.x.isFinite && r.origin.y.isFinite && r.size.width.isFinite && r.size.height.isFinite
            && r.size.width > 0 && r.size.height > 0
    }

    /// Intersection over union of two normalised rects.
    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = i.width * i.height
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? Double(inter / union) : 0
    }
}

/// When to send `.faces`: right away on arrival, then every `interval` (1.5 s; 3 s when
/// constrained) while someone is present and a face is actually in this frame. Pure.
struct FacesPacer: Sendable {
    var interval = 1.5
    var constrained = false
    private var next = -Double.infinity

    var effectiveInterval: Double { constrained ? interval * 2 : interval }

    /// True (and schedules the next tick) when this analysed frame should carry crops.
    /// A frame with no face never counts (the tick waits for the next frame with one).
    mutating func due(at t: Double, present: Bool, arrived: Bool, faceFound: Bool) -> Bool {
        guard present else { next = -.infinity; return false }
        guard faceFound else { return false }
        guard arrived || t >= next - 0.005 else { return false }
        next = t + effectiveInterval
        return true
    }

    /// Nobody is here any more: the next arrival sends crops at once.
    mutating func reset() { next = -.infinity }
}

// MARK: - Head pose

/// Head yaw/pitch for `SenseUpdate.head`, in degrees. Sends a value when the head is
/// first seen and afterwards only when yaw or pitch moved by ≥ `threshold` from the
/// last value sent, so 12 fps of Vision jitter becomes a few updates a second at most
/// while someone is actually moving. Pure.
///
/// Convention (SELF.md §3.2/§7.3): yaw as Vision reports it on the mirrored frame
/// (0 = facing the camera; use |yaw|); pitch **negative = looking down** (Vision's
/// pitch is positive nodding down, so it is negated — see `pitchSign`).
struct HeadPoseFilter: Sendable {
    /// Degrees of change worth reporting.
    var threshold = 3.0
    /// Applied to Vision's pitch so that looking down is negative.
    static let pitchSign = -1.0

    private(set) var last: (yaw: Double, pitch: Double)?

    /// A face's pose this frame (Vision degrees). Returns the pose to send, if any.
    mutating func update(visionYaw: Double, visionPitch: Double) -> (yaw: Double, pitch: Double)? {
        guard visionYaw.isFinite, visionPitch.isFinite else { return nil }
        let yaw = Self.round(visionYaw)
        let pitch = Self.round(visionPitch * Self.pitchSign)
        if let last, abs(last.yaw - yaw) < threshold, abs(last.pitch - pitch) < threshold { return nil }
        last = (yaw, pitch)
        return (yaw, pitch)
    }

    /// The face is gone: the next sighting is reported whatever its pose.
    mutating func forget() { last = nil }

    /// 0.1° resolution (and no −0).
    static func round(_ v: Double) -> Double {
        let r = (v * 10).rounded() / 10
        return r == 0 ? 0 : r
    }
}

// MARK: - One-shot glances

/// Pending `glanceNow` requests. Pure.
///
/// A request for the back camera stays on the back camera when this device can run it
/// (multi-cam, not given up on); otherwise it becomes a front glance. A back glance that
/// has to switch the back camera on waits `warmUp` seconds so the first frames (dark,
/// unexposed) are skipped. Requests expire after `timeout` if no frame arrives (the
/// camera is stopped or interrupted); one request per side, a repeat just refreshes it.
struct GlanceRequests: Sendable {
    struct Pending: Sendable, Equatable {
        var notBefore: Double
        var expires: Double
    }

    var warmUp = 0.35
    var timeout = 2.0
    private(set) var pending: [CameraSide: Pending] = [:]

    /// Records a request; returns the side it will actually use.
    @discardableResult
    mutating func request(_ side: CameraSide, at t: Double, backAvailable: Bool, backRunning: Bool) -> CameraSide {
        let use: CameraSide = side == .back && !backAvailable ? .front : side
        let wait = use == .back && !backRunning ? warmUp : 0
        let new = Pending(notBefore: t + wait, expires: t + wait + timeout)
        if let old = pending[use] {
            // Keep an earlier start (it is already warming), extend the deadline.
            pending[use] = Pending(notBefore: min(old.notBefore, new.notBefore), expires: max(old.expires, new.expires))
        } else {
            pending[use] = new
        }
        return use
    }

    /// Whether a frame from `side` at `t` should be classified for a request (and
    /// consumes the request when so).
    mutating func take(_ side: CameraSide, at t: Double) -> Bool {
        guard let p = pending[side], t >= p.notBefore - 0.005 else { return false }
        pending[side] = nil
        return true
    }

    func wants(_ side: CameraSide) -> Bool { pending[side] != nil }

    /// The back camera turned out to be unusable: move a pending back request to the front.
    mutating func backUnavailable(at t: Double) {
        guard pending.removeValue(forKey: .back) != nil else { return }
        if pending[.front] == nil { pending[.front] = Pending(notBefore: t, expires: t + timeout) }
    }

    /// Drops requests nobody could answer. Returns true if any were dropped.
    @discardableResult
    mutating func expire(at t: Double) -> Bool {
        let before = pending.count
        pending = pending.filter { t < $0.value.expires }
        return pending.count != before
    }

    mutating func removeAll() { pending.removeAll() }
}
