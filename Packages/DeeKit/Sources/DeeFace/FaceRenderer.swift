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
        face.translateBy(x: g.center.x + (shake + CGFloat(st.faceDX)) * g.s, y: g.center.y + (CGFloat(st.faceDY) - bob) * g.s)
        face.rotate(by: .degrees(st.headTilt))
        // Squash and stretch (bounce, yawn, startle), volume roughly preserved.
        let squash = CGFloat(min(max(st.squash.isNaN ? 0 : st.squash, -0.4), 0.4))
        face.scaleBy(x: 1 - 0.5 * squash, y: 1 + squash)

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

        // Glyph box: the eye's own size, before the blink squeezes it.
        let gw = max(2, g.eyeW * CGFloat(e.width) * breath * perspective)
        let gh = max(2, g.eyeH * CGFloat(e.height) * breath * perspective * (1 + 0.08 * voice))
        var w = gw * (1 + 0.06 * blink)
        var h = g.eyeH * CGFloat(e.height) * breath * perspective * (1 + 0.12 * voice) * (1 + 0.05 * CGFloat(frame.listen))
        h *= max(0.04, 1 - 0.93 * blink)
        w = max(w, 2)
        h = max(h, 2)

        let cx = side * g.separation + CGFloat(e.dx) * g.eyeW + CGFloat(st.gazeX) * g.s * 0.1
        let cy = CGFloat(e.dy) * g.eyeH + CGFloat(st.gazeY) * g.s * 0.07 - voice * g.s * 0.03 + blink * g.eyeH * 0.12

        // Glyph weights: each 0…1; if they add up past 1 they share the eye.
        let weights = e.glyphWeights
        let total = weights.reduce(0, +)
        let norm = total > 1 ? 1 / total : 1
        let wt = weights.map { CGFloat($0 * norm) }
        let (heartW, starW) = (wt[0], wt[1])
        // Sequential crossfade: the slab is gone before a stroked glyph is half in, so a
        // blend never shows a ghost slab under (or a ghost glyph inside) the other.
        let slab = Self.slabOpacity(CGFloat(total))
        let gloss = CGFloat(min(max(e.gloss.isNaN ? 0 : e.gloss, 0), 1))

        // Layer 1: the filled shapes (slab, heart, star), lens ring and highlights, cut by the lids.
        ctx.drawLayer { eye in
            eye.translateBy(x: cx, y: cy)
            // Positive tilt raises the outer corner: clockwise for the left eye.
            eye.rotate(by: .degrees(isLeft ? e.tilt : -e.tilt))

            let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
            let radius = min(CGFloat(e.radius) * w, h / 2, w / 2)
            let lid = Self.upperLidLine(e, isLeft: isLeft, h: h)

            if slab > 0.001 {
                var base = eye
                base.opacity = Double(slab)
                base.scaleBy(x: 0.5 + 0.5 * slab, y: 0.5 + 0.5 * slab)
                base.fill(Self.slabPath(rect, radius: radius, lid: lid), with: .color(color))
            }
            if heartW > 0.001 {
                let pulse = 1 + 0.08 * CGFloat(sin(2 * .pi * 1.2 * frame.time))
                let sz = max(gw, gh) * (0.55 + 0.45 * heartW) * pulse
                var heart = eye
                heart.opacity = Double(heartW)
                heart.scaleBy(x: 1, y: max(0.05, 1 - 0.93 * blink * 0.6))
                heart.fill(Self.heartPath(CGRect(x: -sz / 2, y: -sz / 2, width: sz, height: sz)), with: .color(color))
            }
            if starW > 0.001 {
                let spin = Angle.degrees(10 * sin(frame.time * 1.5))
                let sz = max(gw, gh) * (0.55 + 0.5 * starW)
                var star = eye
                star.opacity = Double(starW)
                star.scaleBy(x: 1, y: max(0.05, 1 - 0.93 * blink * 0.6))
                star.rotate(by: spin)
                star.fill(Self.starPath(radius: sz / 2), with: .color(color))
            }

            // Wall-E lens ring — not on the glossy puppy eyes, where it would crowd the highlights.
            let ringFade = Self.ringVisibility(gloss: gloss)
            if e.iris > 0.01, slab > 0.5, ringFade > 0.01 {
                let r = CGFloat(e.iris) * min(w, h) * 0.34
                var ring = eye
                ring.opacity = Double((slab * 2 - 1) * ringFade) * 0.5
                ring.stroke(Path(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)), with: .color(background), lineWidth: min(w, h) * 0.045)
            }

            // Specular highlights: a big and a small dot, lit from the upper left on both
            // eyes (one light source), riding on the filled shapes.
            let filled = min(1, slab + heartW + starW)
            if gloss > 0.01, filled > 0.01, blink < 0.6 {
                let m = min(w, h)
                let shine = Double(gloss * filled) * Double(1 - blink / 0.6)
                var hi = eye
                hi.opacity = shine
                let big = m * (0.1 + 0.07 * gloss)
                let small = big * 0.5
                // Up in the corner and down on the far side, clear of the lens ring.
                let bx = -w * 0.24, by = -h * 0.24
                let sx = w * 0.22, sy = h * 0.22
                hi.fill(Path(ellipseIn: CGRect(x: bx - big, y: by - big, width: 2 * big, height: 2 * big)), with: .color(.white))
                hi.fill(Path(ellipseIn: CGRect(x: sx - small, y: sy - small, width: 2 * small, height: 2 * small)), with: .color(.white))
            }

            // Lids are cut out of whatever was drawn.
            // (The slab already has the upper lid built in, with rounded corners; this cut
            // trims the highlights, ring and any heart/star mid-morph to the same line.)
            eye.blendMode = .destinationOut
            if let lid {
                var cut = Path()
                cut.move(to: CGPoint(x: -w, y: -h * 3))
                cut.addLine(to: CGPoint(x: w, y: -h * 3))
                cut.addLine(to: CGPoint(x: w, y: lid.y(w)))
                cut.addLine(to: CGPoint(x: -w, y: lid.y(-w)))
                cut.closeSubpath()
                eye.fill(cut, with: .color(.black))
            }
            if e.lowerLid > 0.001 {
                // A round cheek pushing up, not a shallow chip; it widens as it rises so a
                // big smile cut never leaves sharp horns at the bottom corners.
                let lower = CGFloat(e.lowerLid)
                let drop = h * 0.22
                let eh = 2 * (drop + lower * h)
                let ew = w * min(1.5, 1.15 + 0.8 * lower)
                eye.fill(Path(ellipseIn: CGRect(x: -ew / 2, y: h / 2 + drop - eh / 2, width: ew, height: eh)), with: .color(.black))
            }
        }

        // Layer 2: stroked glyphs (> <, spiral, X, –, ∩, U) and dot eyes. Not lid-cut:
        // a glyph is the whole eye. A blink squashes them vertically.
        if wt[2...].contains(where: { $0 > 0.005 }) {
            let squeeze = max(0.08, 1 - 0.9 * blink)
            let lw = g.eyeW * 0.24
            let inner: CGFloat = isLeft ? 1 : -1
            var layer = ctx
            layer.translateBy(x: cx, y: cy)
            layer.rotate(by: .degrees(isLeft ? e.tilt : -e.tilt))
            layer.scaleBy(x: 1, y: squeeze)
            let style = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
            func glyph(_ k: CGFloat, _ draw: (inout GraphicsContext) -> Void) {
                guard k > 0.005 else { return }
                var c = layer
                c.opacity = Double(Self.glyphOpacity(k))
                let sc = 0.55 + 0.45 * k
                c.scaleBy(x: sc, y: sc)
                draw(&c)
            }
            // > (left eye) / < (right eye): the tip points at the nose.
            glyph(wt[2]) { c in
                let a = gw * 0.3, b = gh * 0.28
                var p = Path()
                p.move(to: CGPoint(x: -inner * a, y: -b))
                p.addLine(to: CGPoint(x: inner * a, y: 0))
                p.addLine(to: CGPoint(x: -inner * a, y: b))
                c.stroke(p, with: .color(color), style: style)
            }
            glyph(wt[3]) { c in
                c.rotate(by: .degrees(-Double(inner) * frame.time * 300))
                c.stroke(Self.spiralPath(radius: min(gw, gh) * 0.44, turns: 2.25), with: .color(color),
                         style: StrokeStyle(lineWidth: lw * 0.55, lineCap: .round, lineJoin: .round))
            }
            glyph(wt[4]) { c in
                let a = min(gw, gh) * 0.3
                var p = Path()
                p.move(to: CGPoint(x: -a, y: -a)); p.addLine(to: CGPoint(x: a, y: a))
                p.move(to: CGPoint(x: -a, y: a)); p.addLine(to: CGPoint(x: a, y: -a))
                c.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: lw * 0.9, lineCap: .round))
            }
            glyph(wt[5]) { c in
                var p = Path()
                p.move(to: CGPoint(x: -gw * 0.42, y: 0)); p.addLine(to: CGPoint(x: gw * 0.42, y: 0))
                c.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: lw * 1.05, lineCap: .round))
            }
            glyph(wt[6]) { c in
                c.stroke(Self.arcPath(rx: gw * 0.4, ry: gh * 0.32, up: true), with: .color(color), style: style)
            }
            glyph(wt[7]) { c in
                c.stroke(Self.arcPath(rx: gw * 0.4, ry: gh * 0.32, up: false), with: .color(color), style: style)
            }
            glyph(wt[8]) { c in
                let r = min(gw, gh) * 0.38
                c.fill(Path(ellipseIn: CGRect(x: -r, y: -r * 1.1, width: 2 * r, height: 2.2 * r)), with: .color(color))
            }
        }

        // Tears: well up under the outer half of the eye, then fall and fade.
        let tear = CGFloat(min(max(e.tear.isNaN ? 0 : e.tear, 0), 1))
        if tear > 0.02 {
            let period = 2.6 - 0.8 * Double(tear)
            let u = (frame.time / period + (isLeft ? 0 : 0.47)).truncatingRemainder(dividingBy: 1)
            let r = g.eyeW * 0.15 * (0.7 + 0.3 * tear)
            let x0 = cx + side * gw * 0.2
            let y0 = cy + max(h, gh * 0.3) / 2 + r * 1.3
            let d = Self.tearDrop(phase: u, amount: tear, start: y0, radius: r, g)
            if d.opacity > 0.002 {
                var drop = ctx
                drop.opacity = d.opacity
                drop.translateBy(x: x0, y: d.y)
                drop.scaleBy(x: d.scale, y: d.scale * d.stretch)
                drop.fill(Self.tearPath(radius: r), with: .color(Color(red: 0.75, green: 0.9, blue: 1)))
            }
        }
    }

    /// One tear at phase `u` (0…1) of its cycle: it wells up under the eye (fading in,
    /// so there is no speck at birth), then rolls a short way down the cheek, fading out
    /// well inside the frame. `start` is the face-space y of the drop's round part.
    static func tearDrop(phase u: Double, amount tear: CGFloat, start y0: CGFloat, radius r: CGFloat, _ g: Geometry)
        -> (y: CGFloat, opacity: Double, scale: CGFloat, stretch: CGFloat) {
        let form = 0.42
        let grow = CGFloat(smoothstep(u / form))
        let fall = u < form ? 0 : CGFloat((u - form) / (1 - form))
        let bottom = g.size.height - g.center.y - r * 1.6 - g.s * 0.03
        let y = min(y0 + fall * fall * g.s * 0.14, bottom)
        let opacity = Double(min(1, tear * 1.6) * ramp(0.3, 0.75, grow) * (1 - ramp(0.25, 0.75, fall)))
        return (y, opacity, max(0.2, grow), 1 + 0.25 * fall)
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
            // Above the bigger (raised) eye, so it follows a mirrored curious/confused look.
            let side = Self.questionSide(st)
            var q = ctx
            q.opacity = st.question
            q.translateBy(x: side * (g.separation + g.s * 0.2), y: -g.s * 0.27 + g.s * 0.012 * CGFloat(sin(t * 2.5)))
            q.rotate(by: .degrees(14 * Double(side)))
            q.draw(Text("?").font(.system(size: g.s * 0.14, weight: .heavy, design: .rounded)).foregroundStyle(color), at: .zero)
        }
        if st.sparkles > 0.02 {
            let spots: [(CGFloat, CGFloat, CGFloat)] = [(-0.42, -0.2, 0.05), (0.43, -0.24, 0.04), (-0.36, 0.22, 0.035), (0.4, 0.2, 0.045), (0, -0.33, 0.03)]
            // Even a little sparkle reads as a twinkle, not a grey speck.
            let level = Self.sparkleOpacity(st.sparkles)
            let grow = CGFloat(0.8 + 0.4 * min(st.sparkles, 1))
            for (i, s) in spots.enumerated() {
                let tw = 0.5 + 0.5 * sin(t * 3.2 + Double(i) * 1.7)
                var sp = ctx
                sp.opacity = level * tw
                sp.translateBy(x: s.0 * g.s, y: s.1 * g.s)
                sp.fill(Self.starPath(radius: s.2 * g.s * grow * CGFloat(0.6 + 0.4 * tw)), with: .color(color))
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

    // MARK: - Helpers

    /// Smoothstep from `a` to `b`.
    static func ramp(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
        guard b > a else { return x < a ? 0 : 1 }
        let c = min(max((x - a) / (b - a), 0), 1)
        return c.isNaN ? 0 : c * c * (3 - 2 * c)
    }

    /// Sequential crossfade between the slab and a stroked glyph, by total glyph weight:
    /// the slab is nearly gone before a glyph shows, so a blend never ghosts.
    static func slabOpacity(_ glyphTotal: CGFloat) -> CGFloat {
        1 - ramp(0, 0.5, min(max(glyphTotal.isNaN ? 0 : glyphTotal, 0), 1))
    }

    static func glyphOpacity(_ weight: CGFloat) -> CGFloat { ramp(0.25, 0.75, weight) }

    /// The lens ring fades out on very glossy eyes, where it would crowd the highlights.
    static func ringVisibility(gloss: CGFloat) -> CGFloat { 1 - ramp(0.62, 0.8, gloss) }

    /// Sparkle overlay opacity for a 0…1 amount: fades in up to 0.15, then never dimmer
    /// than 0.35 and full by 0.5.
    static func sparkleOpacity(_ amount: Double) -> Double {
        let a = amount.isNaN ? 0 : min(max(amount, 0), 1)
        return a < 0.15 ? a / 0.15 * 0.35 : min(1, max(0.35, a * 2))
    }

    /// +1 when the `?` belongs over the right eye (the bigger one), −1 for the left.
    static func questionSide(_ st: FaceState) -> CGFloat {
        st.right.height * st.right.width >= st.left.height * st.left.width ? 1 : -1
    }

    /// The upper lid edge in eye space (y down). Slope is limited so it can never form
    /// a spike where it meets the eye's rounded corner.
    struct LidLine {
        var base: CGFloat
        var slope: CGFloat       // dy/dx, already signed for this eye's inner corner
        func y(_ x: CGFloat) -> CGFloat { base + slope * x }
    }

    static let maxLidSlope: CGFloat = 0.55

    static func upperLidLine(_ e: EyeState, isLeft: Bool, h: CGFloat) -> LidLine? {
        let lidUp = CGFloat(e.upperLid.isNaN ? 0 : e.upperLid)
        let angle = e.upperAngle.isNaN ? 0 : e.upperAngle
        guard lidUp > 0.001 || abs(angle) > 0.5 else { return nil }
        // Inner corner is +x for the left eye, −x for the right eye.
        let inner: CGFloat = isLeft ? 1 : -1
        let slope = min(max(CGFloat(tan(angle * .pi / 180)), -maxLidSlope), maxLidSlope)
        return LidLine(base: -h / 2 + lidUp * h, slope: slope * inner)
    }

    /// The eye slab: a rounded rect, or — under a lid — the rect clipped by the lid line
    /// with every corner rounded (the lid corners a little tighter), so lids are soft.
    static func slabPath(_ rect: CGRect, radius: CGFloat, lid: LidLine?) -> Path {
        let corners = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                       CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
        guard let lid else { return Path(roundedRect: rect, cornerRadius: radius, style: .continuous) }
        // Sutherland–Hodgman against the half-plane below the lid (y ≥ lid.y(x)).
        func inside(_ p: CGPoint) -> Bool { p.y >= lid.y(p.x) }
        var poly: [(CGPoint, CGFloat)] = []
        var clipped = false
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % 4]
            let ina = inside(a), inb = inside(b)
            if ina { poly.append((a, radius)) }
            if ina != inb {
                clipped = true
                // Solve a + t(b − a) on the line.
                let fa = a.y - lid.y(a.x), fb = b.y - lid.y(b.x)
                let t = fa / (fa - fb)
                poly.append((CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y)), radius * 0.6))
            }
        }
        if !clipped { return poly.count == 4 ? Path(roundedRect: rect, cornerRadius: radius, style: .continuous) : Path() }
        return roundedPolygon(poly)
    }

    /// A convex polygon with each vertex rounded by its own radius (shrunk to fit).
    static func roundedPolygon(_ v: [(CGPoint, CGFloat)]) -> Path {
        let n = v.count
        guard n >= 3 else { return Path() }
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }
        var path = Path()
        let first = v[0].0, last = v[n - 1].0
        path.move(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
        for i in 0..<n {
            let p = v[(i + n - 1) % n].0, c = v[i].0, q = v[(i + 1) % n].0
            let lp = dist(p, c), lq = dist(c, q)
            guard lp > 1e-6, lq > 1e-6 else { continue }
            let ux = (p.x - c.x) / lp, uy = (p.y - c.y) / lp
            let vx = (q.x - c.x) / lq, vy = (q.y - c.y) / lq
            let theta = acos(min(max(ux * vx + uy * vy, -1), 1))      // interior angle
            let fit = min(lp, lq) / 2 * tan(theta / 2)
            let r = max(0, min(v[i].1, fit))
            if r < 0.01 || theta > .pi - 1e-3 {
                path.addLine(to: c)
            } else {
                path.addArc(tangent1End: c, tangent2End: q, radius: r)
            }
        }
        path.closeSubpath()
        return path
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

    /// Archimedean spiral centred on the origin.
    static func spiralPath(radius: CGFloat, turns: Double) -> Path {
        var path = Path()
        let steps = Int(turns * 36)
        for i in 0...steps {
            let f = Double(i) / Double(steps)
            let theta = f * turns * 2 * .pi
            let r = radius * CGFloat(0.08 + 0.92 * f)
            let pt = CGPoint(x: r * CGFloat(cos(theta)), y: r * CGFloat(sin(theta)))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }

    /// Half-ellipse stroke: `up` = arch ∩ (smiling closed eye), else cup U.
    static func arcPath(rx: CGFloat, ry: CGFloat, up: Bool) -> Path {
        var path = Path()
        let cy = up ? ry * 0.45 : -ry * 0.45
        for i in 0...28 {
            let theta = Double.pi * Double(i) / 28
            let x = -rx * CGFloat(cos(theta))
            let y = cy + (up ? -1 : 1) * ry * CGFloat(sin(theta))
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }

    /// A droplet: round bottom, pointed top, centred on the round part.
    static func tearPath(radius r: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -2 * r))
        path.addCurve(to: CGPoint(x: r, y: 0), control1: CGPoint(x: r * 0.35, y: -1.3 * r), control2: CGPoint(x: r, y: -0.75 * r))
        path.addArc(center: .zero, radius: r, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        path.addCurve(to: CGPoint(x: 0, y: -2 * r), control1: CGPoint(x: -r, y: -0.75 * r), control2: CGPoint(x: -r * 0.35, y: -1.3 * r))
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
