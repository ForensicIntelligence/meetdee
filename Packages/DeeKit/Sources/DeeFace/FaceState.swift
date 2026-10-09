import Foundation

/// Shape of one eye. Sizes are fractions of the base eye; angles are degrees.
///
/// Dee's eyes are Loona's: glowing rounded slabs with no pupils, emoting through
/// shape. Wall-E contributes the tilt (whole-eye rotation, outer corner up/down)
/// and the lens ring.
///
/// On top of the slab, an eye can morph into a *glyph* — heart, star, chevron
/// (`>` on the left eye, `<` on the right), spiral, cross `X`, flat line `–`,
/// arc `∩`, cup `U` or tiny dot. Glyph weights are 0…1 and spring like everything
/// else, so the slab crossfades and scales into the glyph. Tears and the glossy
/// highlights are overlays, also 0…1.
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
    /// Squeezed chevron: `>` on the left eye, `<` on the right (giggle, overwhelmed).
    public var chevron = 0.0
    /// Rotating spiral (dizzy).
    public var spiral = 0.0
    /// `X` (knocked silly).
    public var cross = 0.0
    /// Flat bar `–` (unimpressed, asleep).
    public var line = 0.0
    /// Closed smiling arch `∩` (joy, content).
    public var arc = 0.0
    /// Closed relaxed cup `U` (relieved, blissful).
    public var cup = 0.0
    /// Small dot eye, pupil-less (shy).
    public var tiny = 0.0
    /// A tear that wells up under the eye and falls, 0…1 (how wet / how often).
    public var tear = 0.0
    /// Two specular highlights that make the eye look glossy and alive.
    public var gloss = 0.0

    public init(width: Double = 1, height: Double = 1, radius: Double = 0.45, upperLid: Double = 0, upperAngle: Double = 0, lowerLid: Double = 0, tilt: Double = 0, dx: Double = 0, dy: Double = 0, iris: Double = 0, heart: Double = 0, star: Double = 0,
                chevron: Double = 0, spiral: Double = 0, cross: Double = 0, line: Double = 0, arc: Double = 0, cup: Double = 0, tiny: Double = 0, tear: Double = 0, gloss: Double = 0) {
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
        self.chevron = chevron
        self.spiral = spiral
        self.cross = cross
        self.line = line
        self.arc = arc
        self.cup = cup
        self.tiny = tiny
        self.tear = tear
        self.gloss = gloss
    }

    static let count = 21
    var components: [Double] {
        [width, height, radius, upperLid, upperAngle, lowerLid, tilt, dx, dy, iris, heart, star,
         chevron, spiral, cross, line, arc, cup, tiny, tear, gloss]
    }
    init(_ c: ArraySlice<Double>) {
        let a = Array(c)
        self.init(width: a[0], height: a[1], radius: a[2], upperLid: a[3], upperAngle: a[4], lowerLid: a[5], tilt: a[6], dx: a[7], dy: a[8], iris: a[9], heart: a[10], star: a[11],
                  chevron: a[12], spiral: a[13], cross: a[14], line: a[15], arc: a[16], cup: a[17], tiny: a[18], tear: a[19], gloss: a[20])
    }

    /// The glyph weights (each clamped to 0…1), in drawing order.
    var glyphWeights: [Double] {
        [heart, star, chevron, spiral, cross, line, arc, cup, tiny].map { min(max($0.isNaN ? 0 : $0, 0), 1) }
    }

    /// How far the eye has left the plain slab, 0…1.
    public var glyphAmount: Double { min(glyphWeights.reduce(0, +), 1) }

    /// The dominant glyph's name, or "slab" — handy for tests and debugging.
    public var dominantGlyph: String {
        let names = ["heart", "star", "chevron", "spiral", "cross", "line", "arc", "cup", "tiny"]
        let w = glyphWeights
        guard let i = w.indices.max(by: { w[$0] < w[$1] }), w[i] > 0.5 else { return "slab" }
        return names[i]
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
    /// Ears: −1 drooped/back, 0 neutral, 1 perked up. (Not drawn by default: Dee is eyes only.)
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
    /// Whole-face translation in units of the face scale (performances: nod, bounce).
    public var faceDX = 0.0
    public var faceDY = 0.0
    /// Squash and stretch: + taller and narrower, − squatter and wider.
    public var squash = 0.0

    public init() {}

    static var count: Int { EyeState.count * 2 + 18 }

    var components: [Double] {
        left.components + right.components + [
            gazeX, gazeY, color.r, color.g, color.b, brightness, headTilt, ears,
            zzz, question, sparkles, thinkingDots, wobble, giggle, tremble,
            faceDX, faceDY, squash,
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
        faceDX = next(); faceDY = next(); squash = next()
    }

    /// Both eyes the same.
    public mutating func setEyes(_ eye: EyeState) {
        left = eye
        right = eye
    }

    /// Swaps the eyes and flips everything sideways (gaze, head tilt), so an
    /// asymmetric expression (a wink, a raised brow) can appear on either side.
    public func mirrored() -> FaceState {
        var m = self
        m.left = right
        m.right = left
        m.left.dx = -right.dx
        m.right.dx = -left.dx
        m.gazeX = -gazeX
        m.headTilt = -headTilt
        m.faceDX = -faceDX
        return m
    }
}
