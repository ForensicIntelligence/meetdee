# DeeSense additions for 0.5 (owner: sense): `Sources/DeeSense`, `Tests/DeeSenseTests`

All changes add to the existing API. Nothing is renamed or removed. Two new `SenseUpdate` cases
break exhaustive `switch`es, so `DeeModel.handle(_ update:)` must add `.head` and `.faces`
cases (or a `default`).

```swift
public enum SenseUpdate: Sendable, Equatable {
    // existing: presence, look, gesture, sight
    /// The present person's head pose in DEGREES, taken from the face observation that is
    /// already computed. yaw: 0 = facing the camera, with the sign Vision reports on the
    /// mirrored frame (use |yaw|). pitch: negative = looking down (SELF.md §7.3).
    /// Sent on arrival, then only when yaw or pitch moves by at least 3° from the last
    /// value sent (0.1° resolution). Only sent while someone is present.
    case head(yaw: Double, pitch: Double)
    /// Every face in the frame, biggest first. Sent at once on arrival, then about every
    /// 1.5 s (3 s under Low Power or thermal limits) while someone is present and a face
    /// is in the frame. Never sent after `.presence(.left)`.
    case faces([FaceCrop])
}

public struct FaceCrop: Sendable, Equatable {     // == means the same frame (===) and the same numbers
    public var image: CGImage   // the FULL front frame, upright and mirrored exactly as Vision saw it; a private copy
    public var box: CGRect      // Vision normalized coordinates (origin bottom-left), relative to `image`
    public var quality: Double  // Vision face-capture quality 0…1, or -1 if not scored
    public var yaw: Double      // degrees (Vision, mirrored frame)
    public var roll: Double     // degrees (Vision, mirrored frame)
    public var area: Double     // box.width (fraction of the frame width)
    public init(image: CGImage, box: CGRect, quality: Double, yaw: Double, roll: Double, area: Double)
}
// Usage: try await FaceEmbedder.print(of: crop.image, faceBox: crop.box)   // orientation .up

public struct SightReport {
    // existing: camera, things, novel
    public var requested: Bool       // true = this answers glanceNow (sent even when `things` is empty)
    public init(camera:things:novel:requested: Bool = false)
}

extension CameraSense {
    /// Classifies one frame now, bypassing the sight pacer, and always yields
    /// `.sight(report)` with `requested == true`. `.back` uses the back camera when
    /// multi-cam is available. If `lookAround` is off, the back camera is switched on
    /// just for this glance (frames from the first ~0.35 s are skipped while exposure
    /// settles) and switched off afterwards. Without multi-cam, `.back` is answered by
    /// the FRONT camera (report.camera == .front). Works while dozing. Ignored while
    /// the camera is stopped. A request that no frame answers within about 2 s is
    /// dropped without a report, so callers must time out (SELF.md waits 1.2 s).
    public func glanceNow(_ side: CameraSide)
}
```

Cost: head pose comes from the existing `DetectFaceRectanglesRequest`, with no extra
Vision work. `DetectFaceCaptureQualityRequest` runs only on the 1.5 s crop ticks, and it
reuses those face observations (`inputFaceObservations`) on the same handler. Those ticks
also make one CIContext copy of the frame. A crop tick holds the one-frame-in-flight slot
until the copy is done.
