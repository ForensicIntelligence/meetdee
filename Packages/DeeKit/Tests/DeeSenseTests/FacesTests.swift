import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import DeeSense

/// v0.5 camera additions: face crops, their pacing, head pose and one-shot glances.
@Suite struct FacesTests {
    /// `#expect` cannot wrap a mutating call; evaluate first, then expect.
    func check(_ ok: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(ok, sourceLocation: sourceLocation)
    }

    static func image(width: Int = 64, height: Int = 48) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    static func face(_ x: Double, _ y: Double, _ w: Double, _ h: Double? = nil, yaw: Double = 0, roll: Double = 0, pitch: Double = 0) -> DetectedFace {
        DetectedFace(box: CGRect(x: x, y: y, width: w, height: h ?? w), yaw: yaw, roll: roll, pitch: pitch)
    }

    // MARK: - FaceCrops

    @Test func cropsAreAllFacesBiggestFirst() {
        let img = Self.image()
        let crops = FaceCrops.make(image: img, faces: [
            Self.face(0.1, 0.1, 0.1), Self.face(0.5, 0.4, 0.3), Self.face(0.7, 0.1, 0.2),
        ], qualities: [])
        #expect(crops.map(\.area) == [0.3, 0.2, 0.1])
        #expect(crops.map(\.box.minX) == [0.5, 0.7, 0.1])
        #expect(crops.allSatisfy { $0.image === img })
        #expect(crops.allSatisfy { $0.area == Double($0.box.width) })
    }

    @Test func equalSizesOrderedLeftToRightThenBottomUp() {
        let crops = FaceCrops.make(image: Self.image(), faces: [
            Self.face(0.6, 0.5, 0.2), Self.face(0.2, 0.6, 0.2), Self.face(0.2, 0.1, 0.2),
        ], qualities: [])
        #expect(crops.map { [$0.box.minX, $0.box.minY] } == [[0.2, 0.1], [0.2, 0.6], [0.6, 0.5]])
    }

    @Test func qualityMatchedByBestOverlapElseMinusOne() {
        let faces = [Self.face(0.1, 0.1, 0.3), Self.face(0.6, 0.6, 0.2)]
        let crops = FaceCrops.make(image: Self.image(), faces: faces, qualities: [
            (CGRect(x: 0.12, y: 0.1, width: 0.3, height: 0.3), 0.8),   // good overlap with face 1
            (CGRect(x: 0.25, y: 0.1, width: 0.3, height: 0.3), 0.3),   // weaker overlap with face 1
            (CGRect(x: 0.0, y: 0.8, width: 0.1, height: 0.1), 0.9),    // overlaps nothing
        ])
        #expect(crops.count == 2)
        #expect(crops[0].quality == 0.8)
        #expect(crops[1].quality == -1)
    }

    @Test func qualityClampedAndNonFiniteIgnored() {
        let f = [Self.face(0.2, 0.2, 0.4)]
        let box = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        #expect(FaceCrops.make(image: Self.image(), faces: f, qualities: [(box, 1.7)]).first?.quality == 1)
        #expect(FaceCrops.make(image: Self.image(), faces: f, qualities: [(box, -0.2)]).first?.quality == 0)
        #expect(FaceCrops.make(image: Self.image(), faces: f, qualities: [(box, .nan)]).first?.quality == -1)
    }

    @Test func lowOverlapDoesNotMatch() {
        // IoU of these two is well under 0.3.
        let crops = FaceCrops.make(image: Self.image(), faces: [Self.face(0.1, 0.1, 0.2)],
                                   qualities: [(CGRect(x: 0.25, y: 0.1, width: 0.2, height: 0.2), 0.9)])
        #expect(crops.first?.quality == -1)
        #expect(FaceCrops.overlap(CGRect(x: 0, y: 0, width: 1, height: 1), CGRect(x: 0, y: 0, width: 1, height: 1)) == 1)
        #expect(FaceCrops.overlap(CGRect(x: 0, y: 0, width: 0.1, height: 0.1), CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)) == 0)
    }

    @Test func degenerateBoxesDroppedAndAnglesSanitised() {
        let crops = FaceCrops.make(image: Self.image(), faces: [
            Self.face(0.1, 0.1, 0), Self.face(.nan, 0.1, 0.2), Self.face(0.1, 0.1, 0.2, -0.1),
            Self.face(0.3, 0.3, 0.2, yaw: .nan, roll: .infinity),
            Self.face(0.6, 0.3, 0.1, yaw: 21.5, roll: -7),
        ], qualities: [])
        #expect(crops.count == 2)
        #expect(crops[0].yaw == 0 && crops[0].roll == 0)
        #expect(crops[1].yaw == 21.5 && crops[1].roll == -7)
    }

    @Test func noFacesNoCrops() {
        #expect(FaceCrops.make(image: Self.image(), faces: [], qualities: [(CGRect(x: 0, y: 0, width: 1, height: 1), 1)]).isEmpty)
    }

    @Test func faceCropEqualityIsFrameIdentityAndNumbers() {
        let a = Self.image(), b = Self.image()
        let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.3)
        let x = FaceCrop(image: a, box: box, quality: 0.5, yaw: 1, roll: 2, area: 0.3)
        #expect(x == FaceCrop(image: a, box: box, quality: 0.5, yaw: 1, roll: 2, area: 0.3))
        #expect(x != FaceCrop(image: b, box: box, quality: 0.5, yaw: 1, roll: 2, area: 0.3))
        #expect(x != FaceCrop(image: a, box: box, quality: 0.6, yaw: 1, roll: 2, area: 0.3))
        #expect(SenseUpdate.faces([x]) == .faces([x]))
        #expect(SenseUpdate.faces([x]) != .faces([]))
        #expect(SenseUpdate.head(yaw: 1, pitch: -2) == .head(yaw: 1, pitch: -2))
        #expect(SenseUpdate.head(yaw: 1, pitch: -2) != .head(yaw: 1, pitch: 2))
    }

    // MARK: - FacesPacer

    @Test func cropsImmediatelyOnArrivalThenEveryInterval() {
        var p = FacesPacer()
        check(p.due(at: 10.0, present: true, arrived: true, faceFound: true))
        var ticks: [Double] = []
        // 12 fps for 5 s.
        for i in 1...60 {
            let t = 10.0 + Double(i) / 12
            if p.due(at: t, present: true, arrived: false, faceFound: true) { ticks.append(t) }
        }
        #expect(ticks.count == 3)  // 11.5, 13.0, 14.5
        for (i, t) in ticks.enumerated() { #expect(abs(t - (11.5 + 1.5 * Double(i))) < 0.09) }
    }

    @Test func cropTickWaitsForAFrameWithAFace() {
        var p = FacesPacer()
        check(p.due(at: 0, present: true, arrived: true, faceFound: true))
        check(!p.due(at: 1.6, present: true, arrived: false, faceFound: false))
        check(p.due(at: 1.7, present: true, arrived: false, faceFound: true))
        check(!p.due(at: 1.8, present: true, arrived: false, faceFound: true))
    }

    @Test func nobodyPresentNoCropsAndNextArrivalIsImmediate() {
        var p = FacesPacer()
        check(!p.due(at: 0, present: false, arrived: false, faceFound: true))
        check(p.due(at: 1, present: true, arrived: true, faceFound: true))
        check(!p.due(at: 1.2, present: false, arrived: false, faceFound: false))   // left
        check(p.due(at: 1.4, present: true, arrived: false, faceFound: true))      // back: no stale schedule
        // Arrival always fires, even mid-interval.
        check(p.due(at: 1.5, present: true, arrived: true, faceFound: true))
        p.reset()
        check(p.due(at: 1.6, present: true, arrived: false, faceFound: true))
    }

    @Test func constrainedDoublesTheCropInterval() {
        var p = FacesPacer()
        p.constrained = true
        #expect(p.effectiveInterval == 3)
        check(p.due(at: 0, present: true, arrived: true, faceFound: true))
        check(!p.due(at: 2.0, present: true, arrived: false, faceFound: true))
        check(p.due(at: 3.0, present: true, arrived: false, faceFound: true))
    }

    // MARK: - HeadPoseFilter

    @Test func headFirstSightingAlwaysSent() {
        var h = HeadPoseFilter()
        let p = h.update(visionYaw: 4.04, visionPitch: 12.0)
        #expect(p?.yaw == 4.0)
        #expect(p?.pitch == -12.0)   // Vision nods-down positive → ours down negative
    }

    @Test func headSmallJitterSuppressedMeaningfulChangeSent() {
        var h = HeadPoseFilter()
        _ = h.update(visionYaw: 0, visionPitch: 0)
        check(h.update(visionYaw: 2.9, visionPitch: -2.9) == nil)
        check(h.update(visionYaw: -2.5, visionPitch: 1) == nil)
        let yawMove = h.update(visionYaw: 3.2, visionPitch: 0)
        #expect(yawMove?.yaw == 3.2 && yawMove?.pitch == 0)
        // Threshold is measured from the last *sent* value, so slow drift still reports.
        check(h.update(visionYaw: 5, visionPitch: 0) == nil)
        check(h.update(visionYaw: 6.3, visionPitch: 0) != nil)
        let pitchMove = h.update(visionYaw: 6.3, visionPitch: 20)
        #expect(pitchMove?.pitch == -20)
    }

    @Test func headForgetResendsAndNonFiniteIgnored() {
        var h = HeadPoseFilter()
        _ = h.update(visionYaw: 10, visionPitch: 0)
        check(h.update(visionYaw: 10, visionPitch: 0) == nil)
        h.forget()
        check(h.update(visionYaw: 10, visionPitch: 0) != nil)
        check(h.update(visionYaw: .nan, visionPitch: 0) == nil)
        check(h.update(visionYaw: 40, visionPitch: .infinity) == nil)
        #expect(h.last?.yaw == 10)
    }

    @Test func headRoundingAndNoNegativeZero() {
        #expect(HeadPoseFilter.round(1.26) == 1.3)
        #expect(HeadPoseFilter.round(-0.04).sign == .plus)
        var h = HeadPoseFilter()
        let p = h.update(visionYaw: -0.01, visionPitch: 0.01)
        #expect(p?.yaw.sign == .plus && p?.pitch.sign == .plus)
    }

    // MARK: - GlanceRequests

    @Test func backGlanceFallsBackToFrontWithoutMultiCam() {
        var g = GlanceRequests()
        check(g.request(.back, at: 0, backAvailable: false, backRunning: false) == .front)
        #expect(!g.wants(.back) && g.wants(.front))
        check(g.take(.front, at: 0))
        #expect(!g.wants(.front))
        check(!g.take(.front, at: 0.1))  // one-shot
    }

    @Test func backGlanceWarmsUpOnlyWhenTheBackCameraWasOff() {
        var g = GlanceRequests()
        check(g.request(.back, at: 10, backAvailable: true, backRunning: false) == .back)
        check(!g.take(.back, at: 10.1))     // still exposing
        check(!g.take(.front, at: 10.4))    // the other camera doesn't answer it
        check(g.take(.back, at: 10.36))
        g.request(.back, at: 20, backAvailable: true, backRunning: true)
        check(g.take(.back, at: 20))
    }

    @Test func frontGlanceIsImmediate() {
        var g = GlanceRequests()
        check(g.request(.front, at: 5, backAvailable: true, backRunning: false) == .front)
        check(g.take(.front, at: 5))
    }

    @Test func glanceExpiresWhenNoFrameArrives() {
        var g = GlanceRequests()
        g.request(.back, at: 0, backAvailable: true, backRunning: false)
        check(!g.expire(at: 2.0))
        check(g.expire(at: 2.4))
        #expect(!g.wants(.back))
        check(!g.take(.back, at: 2.5))
    }

    @Test func repeatRequestKeepsWarmStartAndExtendsDeadline() {
        var g = GlanceRequests()
        g.request(.back, at: 0, backAvailable: true, backRunning: false)
        g.request(.back, at: 1, backAvailable: true, backRunning: false)
        #expect(g.pending[.back] == .init(notBefore: 0.35, expires: 3.35))
        #expect(g.pending.count == 1)
    }

    @Test func backBecomingUnavailableMovesTheRequestToFront() {
        var g = GlanceRequests()
        g.request(.back, at: 0, backAvailable: true, backRunning: false)
        g.backUnavailable(at: 0.1)
        #expect(!g.wants(.back) && g.wants(.front))
        check(g.take(.front, at: 0.1))
        // No pending back request: nothing appears.
        g.backUnavailable(at: 1)
        #expect(!g.wants(.front))
        g.request(.front, at: 2, backAvailable: true, backRunning: true)
        g.removeAll()
        #expect(g.pending.isEmpty)
    }

    @Test func sightReportRequestedDefaultsFalse() {
        #expect(!SightReport(camera: .front, things: [], novel: []).requested)
        #expect(SightReport(camera: .back, things: [], novel: [], requested: true).requested)
        #expect(SightReport(camera: .back, things: [], novel: [], requested: true) != SightReport(camera: .back, things: [], novel: []))
    }

    // MARK: - Frame copy

    @Test func framesCopyToCGImageOfTheSameSize() throws {
        for format in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] {
            var pb: CVPixelBuffer?
            let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
            #expect(CVPixelBufferCreate(nil, 64, 48, format, attrs, &pb) == kCVReturnSuccess)
            let pixels = try #require(pb)
            CVPixelBufferLockBaseAddress(pixels, [])
            if format == kCVPixelFormatType_32BGRA, let base = CVPixelBufferGetBaseAddress(pixels) {
                memset(base, 0x80, CVPixelBufferGetDataSize(pixels))
            } else {
                for plane in 0..<CVPixelBufferGetPlaneCount(pixels) {
                    if let base = CVPixelBufferGetBaseAddressOfPlane(pixels, plane) {
                        memset(base, 0x80, CVPixelBufferGetBytesPerRowOfPlane(pixels, plane) * CVPixelBufferGetHeightOfPlane(pixels, plane))
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            let image = try #require(CameraSense.cgImage(pixels))
            #expect(image.width == 64 && image.height == 48)
            // A real bitmap copy (not a lazy view onto the capture buffer): its bytes are
            // readable and a mid-grey frame stays mid-grey-ish.
            let data = try #require(image.dataProvider?.data as Data?)
            #expect(data.count >= 64 * 48 * 4)
            let mid = Int(data[(24 * image.bytesPerRow) + 32 * 4])
            #expect((96...160).contains(mid))
        }
    }
}
