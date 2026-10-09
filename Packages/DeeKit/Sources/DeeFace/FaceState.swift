import Foundation

/// Shape of one eye. Sizes are fractions of the base eye; angles are degrees.
///
/// Dee's eyes are Loona's: glowing rounded slabs with no pupils, emoting through
/// shape. Wall-E contributes the tilt (whole-eye rotation, outer corner up/down)
/// and the lens ring.
public struct EyeState: Equatable, Sendable {
    public var width = 1.0
    public var height = 1.0
    /// Corner radius as a fraction of the eye width (0.5 = pill).
    public var radius = 0.45
    /// Fraction of the eye hidden by the upper lid.
    public var upperLid = 0.0
    /// Upper lid slant. Positive: inner corner lower (angry). Negative: outer lower (sad).
    public var upperAngle = 0.0
    /// Upward-arched lower lid ("^ ^" happy eyes): fraction of height cut away.
    public var lowerLid = 0.0
    /// Whole-eye rotation. Positive: outer corner up. Negative: droopy (sad).
    public var tilt = 0.0
    /// Offset in units of base eye size.
    public var dx = 0.0
    public var dy = 0.0
    /// Wall-E lens ring, 0 = none, 1 = large.
    public var iris = 0.0
    /// Morph toward a heart / four-point star, 0…1.
    public var heart = 0.0
    public var star = 0.0

    public init(width: Double = 1, height: Double = 1, radius: Double = 0.45, upperLid: Double = 0, upperAngle: Double = 0, lowerLid: Double = 0, tilt: Double = 0, dx: Double = 0, dy: Double = 0, iris: Double = 0, heart: Double = 0, star: Double = 0) {
        self.width = width
        self.height = height
        self.radius = radius
        self.upperLid = upperLid
        self.upperAngle = upperAngle
        self.lowerLid = lowerLid
        self.tilt = tilt
        self.dx = dx
        self.dy = dy
        self.iris = iris
        self.heart = heart
        self.star = star
    }

    static let count = 12
    var components: [Double] { [width, height, radius, upperLid, upperAngle, lowerLid, tilt, dx, dy, iris, heart, star] }
    init(_ c: ArraySlice<Double>) {
        let a = Array(c)
        self.init(width: a[0], height: a[1], radius: a[2], upperLid: a[3], upperAngle: a[4], lowerLid: a[5], tilt: a[6], dx: a[7], dy: a[8], iris: a[9], heart: a[10], star: a[11])
    }
}

/// An RGB colour as plain doubles so it can be sprung like everything else.
public struct FaceColor: Equatable, Sendable {
    public var r, g, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    public init(hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
    public static let cyan = FaceColor(hex: 0x7FE7FF)
}

/// Everything that defines Dee's face at an instant (before blink and time-based
/// effects, which the animator layers on top).
public struct FaceState: Equatable, Sendable {
    public var left = EyeState()
    public var right = EyeState()
    /// Where Dee is looking, −1…1 (x right, y down).
    public var gazeX = 0.0
    public var gazeY = 0.0
    public var color = FaceColor.cyan
    public var brightness = 1.0
    /// Whole-face roll in degrees (curious head tilt).
    public var headTilt = 0.0
    /// Ears: −1 drooped/back, 0 neutral, 1 perked up.
    public var ears = 0.0
    // Overlays and effects, 0…1 intensities.
    public var zzz = 0.0
    public var question = 0.0
    public var sparkles = 0.0
    public var thinkingDots = 0.0
    /// Horizontal head-shake (confused), vertical giggle (joy), fast shiver (scared).
    public var wobble = 0.0
    public var giggle = 0.0
    public var tremble = 0.0

    public init() {}

    static var count: Int { EyeState.count * 2 + 16 }

    var components: [Double] {
        left.components + right.components + [
            gazeX, gazeY, color.r, color.g, color.b, brightness, headTilt, ears,
            zzz, question, sparkles, thinkingDots, wobble, giggle, tremble, 0,
        ]
    }

    init(components c: [Double]) {
        let n = EyeState.count
        left = EyeState(c[0..<n])
        right = EyeState(c[n..<(2 * n)])
        var i = 2 * n
        func next() -> Double { defer { i += 1 }; return c[i] }
        gazeX = next(); gazeY = next()
        color = FaceColor(next(), next(), next())
        brightness = next(); headTilt = next(); ears = next()
        zzz = next(); question = next(); sparkles = next(); thinkingDots = next()
        wobble = next(); giggle = next(); tremble = next()
    }

    /// Both eyes the same.
    public mutating func setEyes(_ eye: EyeState) {
        left = eye
        right = eye
    }
}
