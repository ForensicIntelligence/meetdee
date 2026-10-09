import CoreGraphics
import CoreImage
import Foundation
import ImageIO
#if canImport(Vision)
import Vision
#endif

public enum FaceEmbedderError: Error, Sendable, LocalizedError {
    case unavailable
    case emptyCrop
    case noFeaturePrint
    /// The capture failed `FaceQualityGate` (blurry, too small, turned away, clipped).
    case poorQuality(FaceCaptureQuality)

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Vision feature prints are not available on this platform."
        case .emptyCrop: "The face box does not overlap the image."
        case .noFeaturePrint: "Vision returned an empty feature print."
        case .poorQuality(let q): "Face capture quality too low: \(q)."
        }
    }
}

/// How usable one face capture is for enrolment / learning.
public struct FaceCaptureQuality: Sendable, Equatable, CustomStringConvertible {
    /// Vision face-capture quality (0…1; blur, lighting, expression), nil when unavailable.
    public var score: Float?
    /// Face box width as a fraction of the (upright) frame width.
    public var widthFraction: Double
    /// Head yaw / roll in degrees, nil when unavailable.
    public var yaw: Double?
    public var roll: Double?
    /// The expanded square crop runs past the frame edge (it is padded, not stretched).
    public var clipped: Bool

    public init(score: Float?, widthFraction: Double, yaw: Double?, roll: Double?, clipped: Bool) {
        self.score = score
        self.widthFraction = widthFraction
        self.yaw = yaw
        self.roll = roll
        self.clipped = clipped
    }

    public var description: String {
        "score \(score.map { String(format: "%.2f", $0) } ?? "n/a"), width \(String(format: "%.2f", widthFraction)), yaw \(yaw.map { String(format: "%.0f°", $0) } ?? "n/a"), roll \(roll.map { String(format: "%.0f°", $0) } ?? "n/a")\(clipped ? ", clipped" : "")"
    }

    public func passes(_ gate: FaceQualityGate = FaceQualityGate()) -> Bool {
        if let s = score, s < gate.minScore { return false }
        if score == nil, gate.requireScore { return false }
        if widthFraction < gate.minWidthFraction { return false }
        if let y = yaw, abs(y) > gate.maxYaw { return false }
        if let r = roll, abs(r) > gate.maxRoll { return false }
        if clipped, !gate.allowClipped { return false }
        return true
    }
}

/// Minimum capture quality for an enrolment (anchor) print.
public struct FaceQualityGate: Sendable, Equatable {
    public var minScore: Float = 0.4
    /// Face box at least this fraction of the frame width.
    public var minWidthFraction: Double = 0.15
    public var maxYaw: Double = 20
    public var maxRoll: Double = 20
    /// Faces whose padded crop runs past the frame edge are rejected by default.
    public var allowClipped = false
    /// When Vision cannot score the capture (or finds no face there), reject it.
    /// Set false to accept on size/pose alone.
    public var requireScore = true

    public init() {}
}

public enum FaceEmbedder {
    /// How far the face box is grown on every side before cropping (0.125 per side
    /// = the box becomes 25 % larger), so hairline, ears and jaw contribute.
    public static let expansion: CGFloat = 0.25

    /// Vision feature print of a face crop (normalised Vision bounding box, origin
    /// bottom-left). iOS/macOS; throws when unavailable.
    ///
    /// The image is assumed to be upright already (the box is relative to it).
    public static func print(of image: CGImage, faceBox: CGRect) async throws -> FacePrint {
        try await print(of: image, faceBox: faceBox, orientation: .up)
    }

    /// As above, for a camera frame whose pixels are stored rotated: the image is
    /// first turned upright with `orientation`, and `faceBox` is read in that
    /// upright space (which is what Vision reports when given the same orientation).
    /// A crop that runs past the frame edge is padded with neutral grey — never
    /// clipped and stretched, which would distort the print.
    public static func print(of image: CGImage, faceBox: CGRect, orientation: CGImagePropertyOrientation) async throws -> FacePrint {
        #if canImport(Vision)
        var upright = CIImage(cgImage: image).oriented(orientation)
        upright = upright.transformed(by: CGAffineTransform(translationX: -upright.extent.minX, y: -upright.extent.minY))
        let size = upright.extent.size
        guard let rect = cropRect(faceBox: faceBox, imageSize: size) else { throw FaceEmbedderError.emptyCrop }
        let padding = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: rect)
        let crop = upright.cropped(to: rect).composited(over: padding)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        var request = GenerateImageFeaturePrintRequest()
        request.cropAndScaleAction = .scaleToFill // the crop is square, so nothing is stretched
        let observation = try await request.perform(on: crop)
        let vector = floats(from: observation.data, count: observation.elementCount, isDouble: observation.elementType == .double)
        guard !vector.isEmpty, vector.contains(where: { $0 != 0 }) else { throw FaceEmbedderError.noFeaturePrint }
        return FacePrint(vector: vector).normalized
        #else
        throw FaceEmbedderError.unavailable
        #endif
    }

    /// Size / pose / Vision capture-quality of one face. Runs Vision's
    /// face-capture-quality request on the frame and uses the observation that
    /// overlaps `faceBox` best; falls back to size and clipping alone when Vision
    /// is unavailable or finds no face.
    public static func quality(of image: CGImage, faceBox: CGRect, orientation: CGImagePropertyOrientation = .up) async -> FaceCaptureQuality {
        var upright = CGSize(width: image.width, height: image.height)
        if [.left, .right, .leftMirrored, .rightMirrored].contains(orientation) {
            upright = CGSize(width: upright.height, height: upright.width)
        }
        var score: Float?, yaw: Double?, roll: Double?
        #if canImport(Vision)
        if let faces = try? await DetectFaceCaptureQualityRequest().perform(on: image, orientation: orientation) {
            let best = faces.max { overlap($0.boundingBox.cgRect, faceBox) < overlap($1.boundingBox.cgRect, faceBox) }
            if let f = best, overlap(f.boundingBox.cgRect, faceBox) > 0.3 {
                score = f.captureQuality?.score
                yaw = f.yaw.converted(to: .degrees).value
                roll = f.roll.converted(to: .degrees).value
            }
        }
        #endif
        return quality(faceBox: faceBox, imageSize: upright, score: score, yaw: yaw, roll: roll)
    }

    /// Pure part of `quality(of:faceBox:orientation:)`.
    public static func quality(faceBox: CGRect, imageSize: CGSize, score: Float?, yaw: Double?, roll: Double?) -> FaceCaptureQuality {
        FaceCaptureQuality(score: score, widthFraction: Double(faceBox.width), yaw: yaw, roll: roll,
                           clipped: isClipped(faceBox: faceBox, imageSize: imageSize))
    }

    /// Feature print only when the capture passes `gate`; throws `.poorQuality` otherwise.
    /// Use this for enrolment prints (`MemoryStore.enroll` needs ≥ 3 of them).
    public static func enrolmentPrint(of image: CGImage, faceBox: CGRect, orientation: CGImagePropertyOrientation = .up, gate: FaceQualityGate = FaceQualityGate()) async throws -> FacePrint {
        let q = await quality(of: image, faceBox: faceBox, orientation: orientation)
        guard q.passes(gate) else { throw FaceEmbedderError.poorQuality(q) }
        return try await print(of: image, faceBox: faceBox, orientation: orientation)
    }

    /// Intersection over union of two normalised rects.
    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = i.width * i.height
        return Double(inter / (a.width * a.height + b.width * b.height - inter))
    }

    /// The square crop, in pixel coordinates with a bottom-left origin (Core Image
    /// and Vision share that convention): the box grown by `expansion` and squared
    /// to its longer side. NOT clamped to the image — the part outside is padded —
    /// so the face keeps its proportions at the frame edge. Nil when the square
    /// does not overlap the image.
    public static func cropRect(faceBox: CGRect, imageSize: CGSize) -> CGRect? {
        guard let square = square(faceBox: faceBox, imageSize: imageSize) else { return nil }
        let visible = square.intersection(CGRect(origin: .zero, size: imageSize))
        guard !visible.isNull, visible.width >= 2, visible.height >= 2 else { return nil }
        return square.integral
    }

    /// Whether the expanded square crop runs past the frame edge.
    public static func isClipped(faceBox: CGRect, imageSize: CGSize) -> Bool {
        guard let square = square(faceBox: faceBox, imageSize: imageSize) else { return true }
        return !CGRect(origin: .zero, size: imageSize).insetBy(dx: -0.5, dy: -0.5).contains(square)
    }

    static func square(faceBox: CGRect, imageSize: CGSize) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0, faceBox.width > 0, faceBox.height > 0 else { return nil }
        let px = CGRect(x: faceBox.minX * imageSize.width, y: faceBox.minY * imageSize.height,
                        width: faceBox.width * imageSize.width, height: faceBox.height * imageSize.height)
        let side = max(px.width, px.height) * (1 + expansion)
        return CGRect(x: px.midX - side / 2, y: px.midY - side / 2, width: side, height: side)
    }

    static func floats(from data: Data, count: Int, isDouble: Bool) -> [Float] {
        data.withUnsafeBytes { raw -> [Float] in
            if isDouble {
                let n = min(count, raw.count / MemoryLayout<Double>.size)
                return (0..<n).map { Float(raw.loadUnaligned(fromByteOffset: $0 * 8, as: Double.self)) }
            }
            let n = min(count, raw.count / MemoryLayout<Float>.size)
            return (0..<n).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
    }
}
