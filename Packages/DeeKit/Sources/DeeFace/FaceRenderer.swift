import SwiftUI

/// Draws a `FaceFrame` into a `GraphicsContext`. Stateless, so the same code renders
/// the live face and the PNG snapshots used to review expressions.
public struct FaceRenderer: Sendable {
    public var background: Color
    public var showEars: Bool

    public init(background: Color = Color(red: 0.02, green: 0.027, blue: 0.04), showEars: Bool = false) {
        self.background = background
        self.showEars = showEars
    }

    struct Geometry {
        let size: CGSize
        let s: CGFloat          // face scale
        let center: CGPoint
        let eyeW: CGFloat
        let eyeH: CGFloat
        let separation: CGFloat

        init(_ size: CGSize) {
            self.size = size
            s = min(size.width, size.height * 1.15)
            center = CGPoint(x: size.width / 2, y: size.height * 0.47)
            eyeW = s * 0.25
            eyeH = s * 0.33
            separation = s * 0.19
        }
    }

    public func draw(_ frame: FaceFrame, in context: inout GraphicsContext, size: CGSize) {
        let g = Geometry(size)
        let st = frame.state
        let color = Self.eyeColor(st)

        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(background))

        var face = context
        // Whole-face motion: head tilt, head-shake, giggle, shiver.
        let t = frame.time
        let shake = CGFloat(st.wobble * 0.035 * sin(2 * .pi * 2.6 * t) + st.tremble * 0.012 * sin(2 * .pi * 13 * t))
        let bob = CGFloat(st.giggle * 0.03 * abs(sin(2 * .pi * 3 * t)))
        face.translateBy(x: g.center.x + shake * g.s, y: g.center.y - bob * g.s)
        face.rotate(by: .degrees(st.headTilt))

        if showEars { drawEars(st, g, color, &face) }

        // Crisp eyes with a soft glow: both eyes are drawn once, into one layer, and the
        // glow is that layer's shadow (one blur pass) rather than a second blurred copy.
        var lit = face
        lit.addFilter(.shadow(color: color.opacity(0.75), radius: g.s * 0.05))
        lit.drawLayer { eyes in
            drawEyes(frame, g, color, &eyes)
        }
        drawGlyphs(frame, g, color, &face)
    }

    /// Sprung colour × brightness, clamped to 0…1 so a spring overshoot can never make
    /// an extended-range colour (which flashes on wide-gamut displays). NaN → 0.
    static func eyeRGB(_ st: FaceState) -> (r: Double, g: Double, b: Double) {
        func unit(_ v: Double) -> Double { v.isNaN ? 0 : min(max(v, 0), 1) }
        let k = unit(st.brightness)
        return (unit(st.color.r) * k, unit(st.color.g) * k, unit(st.color.b) * k)
    }

    static func eyeColor(_ st: FaceState) -> Color {
        let c = eyeRGB(st)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    // MARK: - Eyes

    private func drawEyes(_ frame: FaceFrame, _ g: Geometry, _ color: Color, _ ctx: inout GraphicsContext) {
        drawEye(frame, frame.state.left, isLeft: true, g, color, &ctx)
        drawEye(frame, frame.state.right, isLeft: false, g, color, &ctx)
    }

    private func drawEye(_ frame: FaceFrame, _ e: EyeState, isLeft: Bool, _ g: Geometry, _ color: Color, _ ctx: inout GraphicsContext) {
        let st = frame.state
        let blink = CGFloat(frame.blink)
        let voice = CGFloat(frame.voice)
        let side: CGFloat = isLeft ? -1 : 1
        // Looking toward one side makes that eye a touch bigger (cheap perspective).
        let perspective = 1 + 0.06 * CGFloat(st.gazeX) * side
        let breath = CGFloat(frame.breath)

        var w = g.eyeW * CGFloat(e.width) * breath * perspective * (1 + 0.06 * blink)
        var h = g.eyeH * CGFloat(e.height) * breath * perspective * (1 + 0.12 * voice) * (1 + 0.05 * CGFloat(frame.listen))
        h *= max(0.04, 1 - 0.93 * blink)
        w = max(w, 2)
        h = max(h, 2)

        let cx = side * g.separation + CGFloat(e.dx) * g.eyeW + CGFloat(st.gazeX) * g.s * 0.1
        let cy = CGFloat(e.dy) * g.eyeH + CGFloat(st.gazeY) * g.s * 0.07 - voice * g.s * 0.03 + blink * g.eyeH * 0.12

        ctx.drawLayer { eye in
            eye.translateBy(x: cx, y: cy)
            // Positive tilt raises the outer corner: clockwise for the left eye.
            eye.rotate(by: .degrees(isLeft ? e.tilt : -e.tilt))

            let morph = CGFloat(max(e.heart, e.star))
            let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
            let radius = min(CGFloat(e.radius) * w, h / 2, w / 2)

            if morph < 0.999 {
                var base = eye
                base.opacity = Double(1 - morph)
                base.fill(Path(roundedRect: rect, cornerRadius: radius, style: .continuous), with: .color(color))
            }
            if e.heart > 0.001 {
                let pulse = 1 + 0.08 * CGFloat(sin(2 * .pi * 1.2 * frame.time))
                let sz = max(w, h) * (0.55 + 0.45 * CGFloat(e.heart)) * pulse * max(0.05, 1 - 0.93 * blink * 0.6)
                var heart = eye
                heart.opacity = e.heart
                heart.fill(Self.heartPath(CGRect(x: -sz / 2, y: -sz / 2, width: sz, height: sz)), with: .color(color))
            }
            if e.star > 0.001 {
                let spin = Angle.degrees(10 * sin(frame.time * 1.5))
                let sz = max(w, h) * (0.55 + 0.5 * CGFloat(e.star))
                var star = eye
                star.opacity = e.star
                star.rotate(by: spin)
                star.fill(Self.starPath(radius: sz / 2), with: .color(color))
            }

            // Wall-E lens ring.
            if e.iris > 0.01, morph < 0.5 {
                let r = CGFloat(e.iris) * min(w, h) * 0.34
                var ring = eye
                ring.opacity = Double(1 - morph * 2) * 0.5
                ring.stroke(Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)), with: .color(background), lineWidth: min(w, h) * 0.045)
            }

            // Lids are cut out of whatever was drawn.
            eye.blendMode = .destinationOut
            let lidUp = CGFloat(e.upperLid)
            let slope = CGFloat(tan(e.upperAngle * .pi / 180))
            if lidUp > 0.001 || abs(e.upperAngle) > 0.5 {
                // Inner corner is +x for the left eye, −x for the right eye.
                let inner: CGFloat = isLeft ? 1 : -1
                let base = -h / 2 + lidUp * h
                func y(_ x: CGFloat) -> CGFloat { base + slope * x * inner }
                var lid = Path()
                lid.move(to: CGPoint(x: -w, y: -h * 3))
                lid.addLine(to: CGPoint(x: w, y: -h * 3))
                lid.addLine(to: CGPoint(x: w, y: y(w)))
                lid.addLine(to: CGPoint(x: -w, y: y(-w)))
                lid.closeSubpath()
                eye.fill(lid, with: .color(.black))
            }
            if e.lowerLid > 0.001 {
                let drop = h * 0.35
                let eh = 2 * (drop + CGFloat(e.lowerLid) * h)
                let ew = w * 1.5
                eye.fill(Path(ellipseIn: CGRect(x: -ew / 2, y: h / 2 + drop - eh / 2, width: ew, height: eh)), with: .color(.black))
            }
        }
    }

    // MARK: - Ears

    private func drawEars(_ st: FaceState, _ g: Geometry, _ color: Color, _ ctx: inout GraphicsContext) {
        let lift = CGFloat(st.ears)
        for side: CGFloat in [-1, 1] {
            var ear = ctx
            ear.opacity = 0.5
            ear.translateBy(x: side * g.s * 0.4, y: -g.s * 0.31 - lift * g.s * 0.025)
            // Perked: upright-ish. Drooped: flopped outward.
            ear.rotate(by: .degrees(Double(side * (22 - lift * 18))))
            let len = g.s * 0.13
            let wid = g.s * 0.055
            var p = Path()
            p.move(to: CGPoint(x: -wid / 2, y: 0))
            p.addQuadCurve(to: CGPoint(x: 0, y: -len), control: CGPoint(x: -wid * 0.7, y: -len * 0.7))
            p.addQuadCurve(to: CGPoint(x: wid / 2, y: 0), control: CGPoint(x: wid * 0.7, y: -len * 0.7))
            p.closeSubpath()
            ear.fill(p, with: .color(color))
        }
    }

    // MARK: - Glyphs

    private func drawGlyphs(_ frame: FaceFrame, _ g: Geometry, _ color: Color, _ ctx: inout GraphicsContext) {
        let st = frame.state
        let t = frame.time

        if st.zzz > 0.02 {
            for i in 0..<3 {
                let phase = (t / 2.4 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                let size = g.s * (0.05 + 0.03 * CGFloat(i))
                let p = CGPoint(x: g.separation + g.s * (0.14 + 0.08 * CGFloat(phase)), y: -g.s * (0.18 + 0.18 * CGFloat(phase)))
                var z = ctx
                z.opacity = st.zzz * sin(.pi * phase)
                z.draw(Text("z").font(.system(size: size, weight: .heavy, design: .rounded)).foregroundStyle(color), at: p)
            }
        }
        if st.question > 0.02 {
            var q = ctx
            q.opacity = st.question
            q.translateBy(x: g.separation + g.s * 0.2, y: -g.s * 0.27 + g.s * 0.012 * CGFloat(sin(t * 2.5)))
            q.rotate(by: .degrees(14))
            q.draw(Text("?").font(.system(size: g.s * 0.14, weight: .heavy, design: .rounded)).foregroundStyle(color), at: .zero)
        }
        if st.sparkles > 0.02 {
            let spots: [(CGFloat, CGFloat, CGFloat)] = [(-0.42, -0.2, 0.05), (0.43, -0.24, 0.04), (-0.36, 0.22, 0.035), (0.4, 0.2, 0.045), (0, -0.33, 0.03)]
            for (i, s) in spots.enumerated() {
                let tw = 0.5 + 0.5 * sin(t * 3.2 + Double(i) * 1.7)
                var sp = ctx
                sp.opacity = st.sparkles * tw
                sp.translateBy(x: s.0 * g.s, y: s.1 * g.s)
                sp.fill(Self.starPath(radius: s.2 * g.s * CGFloat(0.6 + 0.4 * tw)), with: .color(color))
            }
        }
        if st.thinkingDots > 0.02 {
            for i in 0..<3 {
                let hop = abs(sin(t * 3.5 - Double(i) * 0.7))
                let r = g.s * 0.018
                let p = CGPoint(x: -g.s * 0.06 + CGFloat(i) * g.s * 0.06, y: -g.s * 0.33 - CGFloat(hop) * g.s * 0.025)
                var d = ctx
                d.opacity = st.thinkingDots * (0.45 + 0.55 * hop)
                d.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
            }
        }
    }

    // MARK: - Shapes

    static func heartPath(_ r: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height) }
        var path = Path()
        path.move(to: p(0.5, 0.95))
        path.addCurve(to: p(0.0, 0.36), control1: p(0.18, 0.78), control2: p(0.0, 0.6))
        path.addCurve(to: p(0.5, 0.22), control1: p(0.0, 0.06), control2: p(0.42, 0.0))
        path.addCurve(to: p(1.0, 0.36), control1: p(0.58, 0.0), control2: p(1.0, 0.06))
        path.addCurve(to: p(0.5, 0.95), control1: p(1.0, 0.6), control2: p(0.82, 0.78))
        path.closeSubpath()
        return path
    }

    /// Four-point sparkle star centred on the origin.
    static func starPath(radius r: CGFloat) -> Path {
        let inner = r * 0.32
        var path = Path()
        for i in 0..<8 {
            let angle = Double(i) * .pi / 4 - .pi / 2
            let rr = i.isMultiple(of: 2) ? r : inner
            let pt = CGPoint(x: CGFloat(cos(angle)) * rr, y: CGFloat(sin(angle)) * rr)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }
}
