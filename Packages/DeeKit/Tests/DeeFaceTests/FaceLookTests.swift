import CoreGraphics
import DeeCore
import Foundation
import SwiftUI
import Testing
@testable import DeeFace

/// The v0.4 visual-critique fixes: laughs over a bad mood, glitch-free blends and
/// tears, soft lids, and expressions that no longer share a silhouette.
private func target(_ e: Emotion) -> FaceState { Expressions.target(for: e) }

@Suite struct FaceLookTests {
    // MARK: 1. Laughing over a bad mood

    static func giggling(_ mood: Emotion, _ move: Performance = .giggle, at t: Double = 0.5, side: Double = 1) -> FaceState {
        Move.perform(move).pose(at: t, side: side).applied(to: target(mood))
    }

    @Test(arguments: [Emotion.sad, .angry, .hurt, .lonely, .grumpy, .scared])
    func giggleOverABadMoodIsARealLaugh(_ mood: Emotion) {
        let base = target(mood)
        let s = Self.giggling(mood)
        let neutralGiggle = Self.giggling(.neutral)
        for (eye, was) in [(s.left, base.left), (s.right, base.right)] {
            #expect(eye.dominantGlyph == "arc")
            #expect(eye.tear == 0, "\(mood): a laugh stops the tears")
            #expect(abs(eye.tilt) < 0.01 && abs(eye.upperAngle) < 0.01, "\(mood): the arches are level")
            // The same size as an ordinary giggle, whatever the mood's eye size.
            #expect(abs(eye.width - neutralGiggle.left.width) < 1e-9 && abs(eye.height - neutralGiggle.left.height) < 1e-9)
            #expect(eye.dy < was.dy, "\(mood): the eyes lift")
        }
        #expect(s.tremble == 0)
        #expect(s.brightness >= base.brightness + 0.29, "\(mood): lit up")
        #expect(s.gazeY < base.gazeY || base.gazeY <= -0.1, "\(mood): looks up, not down")
        // Warmer: nearer the laugh gold than the mood colour was, and at full intensity.
        func dist(_ c: FaceColor) -> Double {
            let w = Pose.warmColor
            return ((c.r - w.r) * (c.r - w.r) + (c.g - w.g) * (c.g - w.g) + (c.b - w.b) * (c.b - w.b)).squareRoot()
        }
        #expect(dist(s.color) < dist(base.color), "\(mood): warmer")
        #expect(max(s.color.r, s.color.g, s.color.b) > 0.99, "\(mood): luminous, not greyed out")
    }

    @Test func giggleOverAngryIsNotAngryLaughing() {
        let s = Self.giggling(.angry)
        let angry = target(.angry).color
        #expect(s.color.g > angry.g + 0.15, "red warms toward gold")
    }

    @Test func contentSquintOverLonelyIsNotTinyOrDim() {
        let lonely = target(.lonely)
        let s = Self.giggling(.lonely, .contentSquint, at: 0.9)
        #expect(s.left.dominantGlyph == "arc")
        #expect(s.left.width > 1.05, "the arches don't shrink to nothing: \(s.left.width)")
        #expect(s.brightness >= lonely.brightness + 0.24)
        #expect(s.left.tear == 0)
    }

    @Test func winkOpensAGrumpyEye() {
        let grumpy = target(.grumpy)
        let s = Self.giggling(.grumpy, .wink, at: 0.4, side: 1)
        #expect(s.right.dominantGlyph == "arc", "the winking eye")
        #expect(s.left.dominantGlyph == "slab")
        #expect(s.left.upperLid < grumpy.left.upperLid - 0.3, "the open eye's lid lifts")
        #expect(abs(s.left.tilt) < 0.01 && abs(s.left.upperAngle) < 0.01)
    }

    @Test func warmthAndLevelAreZeroAtRestAndAdd() {
        #expect(Pose().warmth == 0 && EyePose().level == 0)
        for p in Performance.allCases {
            let m = Move.perform(p)
            #expect(m.pose(at: m.duration, side: 1).warmth < 1e-3, "\(p)")
            #expect(m.pose(at: m.duration, side: 1).left.level < 1e-3, "\(p)")
        }
        var a = Pose(); a.warmth = 0.4; a.left.level = 0.3
        var b = Pose(); b.warmth = 0.5; b.left.level = 0.2
        #expect(abs((a + b).warmth - 0.9) < 1e-12 && abs((a + b).left.level - 0.5) < 1e-12)
        // No warmth leaves the colour alone; NaN is ignored.
        var nan = Pose(); nan.warmth = .nan
        #expect(nan.applied(to: target(.sad)).color == target(.sad).color)
    }

    // MARK: 2. Blends don't ghost

    @Test func slabAndGlyphNeverBothClearlyVisible() {
        for i in 0...100 {
            let k = CGFloat(i) / 100
            let slab = FaceRenderer.slabOpacity(k), glyph = FaceRenderer.glyphOpacity(k)
            #expect(slab * glyph < 0.04, "ghosting at \(k): slab \(slab) glyph \(glyph)")
            #expect(slab >= 0 && slab <= 1 && glyph >= 0 && glyph <= 1)
        }
        #expect(FaceRenderer.slabOpacity(0) == 1 && FaceRenderer.glyphOpacity(0) == 0)
        #expect(FaceRenderer.slabOpacity(1) == 0 && FaceRenderer.glyphOpacity(1) == 1)
        #expect(FaceRenderer.slabOpacity(.nan) == 1)
    }

    // MARK: 3. Tears stay in the frame

    @Test func tearsFadeBeforeTheBottomOfTheFrame() {
        for size in [CGSize(width: 220, height: 170), CGSize(width: 390, height: 300), CGSize(width: 390, height: 844), CGSize(width: 844, height: 390)] {
            let g = FaceRenderer.Geometry(size)
            let r = g.eyeW * 0.15
            let bottom = size.height - g.center.y
            // Start from the lowest a drop can begin (a tall, low, downcast eye).
            let y0 = 1.2 * g.eyeH * 0.6 + g.s * 0.07 + g.eyeH * 0.65 + r * 1.3
            var shown = 0
            for i in 0...400 {
                let d = FaceRenderer.tearDrop(phase: Double(i) / 400, amount: 1, start: y0, radius: r, g)
                #expect(d.opacity >= 0 && d.opacity <= 1)
                if d.opacity > 0.02 {
                    shown += 1
                    #expect(d.y + r * d.scale * d.stretch < bottom - g.s * 0.02, "\(size) phase \(i): drop clipped by the frame")
                }
            }
            #expect(shown > 100, "the tear is visible for a good part of its cycle")
        }
    }

    @Test func aTearIsNotASpeckWhenItIsBorn() {
        let g = FaceRenderer.Geometry(CGSize(width: 390, height: 300))
        for i in 0...40 {
            let d = FaceRenderer.tearDrop(phase: Double(i) / 400, amount: 1, start: 50, radius: 10, g)
            if d.scale < 0.35 { #expect(d.opacity < 0.05, "tiny drop at phase \(i) should be invisible") }
        }
    }

    // MARK: 6. Lids are soft

    @Test func lidSlopeIsLimited() {
        for angle in stride(from: -60.0, through: 60, by: 5) {
            for left in [true, false] {
                let lid = FaceRenderer.upperLidLine(EyeState(upperLid: 0.2, upperAngle: angle), isLeft: left, h: 100)
                #expect(lid != nil)
                #expect(abs(lid!.slope) <= FaceRenderer.maxLidSlope + 1e-9)
            }
        }
        #expect(FaceRenderer.upperLidLine(EyeState(), isLeft: true, h: 100) == nil)
        #expect(FaceRenderer.upperLidLine(EyeState(upperLid: .nan, upperAngle: .nan), isLeft: true, h: 100) == nil)
    }

    @Test func slabUnderALidStaysBelowTheLidAndInsideTheEye() {
        let rect = CGRect(x: -40, y: -50, width: 80, height: 100)
        for angle in [-30.0, -18, 0, 12, 32] {
            for lidAmount in [0.0, 0.1, 0.3, 0.6] {
                guard let lid = FaceRenderer.upperLidLine(EyeState(upperLid: lidAmount, upperAngle: angle), isLeft: true, h: 100) else { continue }
                let path = FaceRenderer.slabPath(rect, radius: 36, lid: lid)
                let box = path.boundingRect
                #expect(rect.insetBy(dx: -0.5, dy: -0.5).contains(box), "angle \(angle) lid \(lidAmount)")
                // Sample the outline: every point is on or under the lid line.
                for x in stride(from: rect.minX + 1, to: rect.maxX, by: 2) {
                    for y in stride(from: rect.minY, to: rect.maxY, by: 2) where path.contains(CGPoint(x: x, y: y)) {
                        #expect(y >= lid.y(x) - 0.5, "angle \(angle) lid \(lidAmount): (\(x), \(y)) above the lid")
                    }
                }
                // And it is not empty while the lid leaves some eye.
                if lidAmount < 0.5 { #expect(box.height > 20) }
            }
        }
        // Fully closed: nothing left.
        let shut = FaceRenderer.LidLine(base: 200, slope: 0)
        #expect(FaceRenderer.slabPath(rect, radius: 20, lid: shut).isEmpty)
    }

    @Test func liddedCornersAreRounded() {
        // The high corner of a slanted lid is a curve, not a spike: just inside the
        // corner where the lid meets the side, the shape is empty.
        let rect = CGRect(x: -40, y: -50, width: 80, height: 100)
        let lid = FaceRenderer.upperLidLine(EyeState(upperLid: 0.3, upperAngle: -24), isLeft: true, h: 100)!
        let path = FaceRenderer.slabPath(rect, radius: 36, lid: lid)
        // Left eye, negative angle: the inner (+x) side is higher.
        let cornerY = lid.y(rect.maxX)
        #expect(!path.contains(CGPoint(x: rect.maxX - 1, y: cornerY + 1)))
        #expect(path.contains(CGPoint(x: 0, y: lid.y(0) + 12)))
    }

    @Test func noTinyLowerLidChips() {
        for e in Emotion.allCases {
            let t = target(e)
            for eye in [t.left, t.right] {
                #expect(eye.lowerLid == 0 || eye.lowerLid >= 0.1, "\(e): a lower lid under 0.1 leaves a chip")
            }
        }
    }

    // MARK: 8. Lens ring vs highlights

    @Test func ringFadesOnGlossyEyes() {
        #expect(FaceRenderer.ringVisibility(gloss: 0.3) == 1)
        #expect(FaceRenderer.ringVisibility(gloss: 0.6) == 1, "listening keeps its ring")
        #expect(FaceRenderer.ringVisibility(gloss: 0.9) == 0)
        for e in [Emotion.sad, .pleading, .lonely, .worried] {
            #expect(target(e).left.iris == 0, "\(e): no staring lens ring on a sad-family eye")
        }
    }

    // MARK: 4, 5, 7, 9–12, 15. Distinct silhouettes

    static func colorDistance(_ a: FaceColor, _ b: FaceColor) -> Double {
        ((a.r - b.r) * (a.r - b.r) + (a.g - b.g) * (a.g - b.g) + (a.b - b.b) * (a.b - b.b)).squareRoot()
    }

    @Test func overwhelmedIsNotGiddy() {
        let o = target(.overwhelmed), g = target(.giddy)
        #expect(Self.colorDistance(o.color, g.color) > 0.25, "pale lavender, not pink")
        #expect(o.left.height / o.left.width > g.left.height / g.left.width + 0.2, "taller, pinched chevrons")
        #expect(o.left.tear > 0.9 && g.left.tear == 0)
        #expect(o.tremble > 0.5 && o.sparkles == 0 && g.sparkles > 0.5)
    }

    @Test func determinedIsNotAngry() {
        let d = target(.determined), a = target(.angry)
        #expect(a.left.upperAngle - d.left.upperAngle > 20, "angry is the slanted one")
        #expect(a.left.tilt > 5 && d.left.tilt == 0)
        #expect(a.left.lowerLid == 0)
    }

    @Test func sadFamilyHasDifferentSilhouettes() {
        let fam: [Emotion] = [.sad, .lonely, .worried, .pleading, .hurt]
        #expect(target(.lonely).left.upperLid == 0 && target(.lonely).left.width < 0.75)
        #expect(target(.pleading).left.upperLid == 0 && target(.pleading).left.gloss == 1)
        #expect(target(.worried).left.dx > 0 && target(.worried).right.dx < 0, "worried eyes draw inward")
        for (i, a) in fam.enumerated() {
            for b in fam[(i + 1)...] {
                #expect(ExpressionTests.distance(target(a), target(b)) > 0.8, "\(a) vs \(b)")
            }
        }
    }

    @Test func shyIsBrightAndPeeking() {
        let s = target(.shy)
        #expect(s.brightness == 1 && s.sparkles > 0.1)
        #expect(s.gazeX >= 0.6 && s.gazeY >= 0.55 && s.headTilt >= 14)
    }

    @Test func asleepAndUnimpressedAreDifferentGlyphs() {
        #expect(target(.asleep).left.dominantGlyph == "line")
        let u = target(.unimpressed)
        #expect(u.left.dominantGlyph == "slab" && u.left.upperLid > 0.45 && u.left.upperAngle == 0)
        #expect(u.left.dy != u.right.dy, "a lopsided deadpan")
        #expect(Self.colorDistance(u.color, target(.bored).color) > 0.15)
    }

    @Test func sleepyBoredAndGrumpyGlowInsteadOfGoingMatte() {
        // Dim colours × brightness kept above a floor so the glow reads.
        for e in [Emotion.sleepy, .bored, .grumpy, .unimpressed] {
            let c = FaceRenderer.eyeRGB(target(e))
            #expect(max(c.r, c.g, c.b) > 0.6, "\(e): \(c)")
        }
        let sleepy = target(.sleepy), bored = target(.bored)
        #expect(sleepy.left.upperAngle < 0 && sleepy.zzz > 0 && bored.zzz == 0)
        #expect(Self.colorDistance(sleepy.color, bored.color) > 0.1)
        #expect(target(.grumpy).left.height >= 0.78)
    }

    @Test func smugLeavesRoomForTheSmile() {
        let s = target(.smug)
        for eye in [s.left, s.right] {
            #expect(eye.height >= 0.72 && (1 - eye.upperLid - eye.lowerLid) * eye.height > 0.25)
        }
    }

    @Test func confusedListeningAndThinkingHaveTheirOwnLook() {
        #expect(Self.colorDistance(target(.confused).color, target(.curious).color) > 0.15)
        #expect(target(.confused).left.tilt <= -10)
        #expect(target(.listening).headTilt != 0 && target(.listening).left.gloss >= 0.6)
        let th = target(.thinking)
        #expect(th.gazeX > 0 && th.right.tilt > 0 && th.right.upperAngle < 0, "the eye toward the gaze tips up")
    }

    // MARK: 13. The `?` follows the mirror

    @Test func questionMarkSitsOverTheBiggerEye() {
        for e in [Emotion.curious, .confused] {
            let t = target(e)
            #expect(FaceRenderer.questionSide(t) == 1, "\(e)")
            #expect(FaceRenderer.questionSide(t.mirrored()) == -1, "\(e) mirrored")
        }
        for seed: UInt64 in 1...20 {
            let v = Expressions.varied(target(.curious), emotion: .curious, seed: seed)
            let bigger: CGFloat = v.right.height * v.right.width >= v.left.height * v.left.width ? 1 : -1
            #expect(FaceRenderer.questionSide(v) == bigger)
        }
    }

    // MARK: 14. Sparkles

    @Test func smallSparklesAreStillVisible() {
        #expect(FaceRenderer.sparkleOpacity(0) == 0)
        #expect(FaceRenderer.sparkleOpacity(0.2) >= 0.35)
        #expect(FaceRenderer.sparkleOpacity(0.5) == 1)
        var last = 0.0
        for i in 0...100 {
            let o = FaceRenderer.sparkleOpacity(Double(i) / 100)
            #expect(o >= last - 1e-12, "monotonic")
            #expect(o - last < 0.1, "no pop at \(i)")
            last = o
        }
        #expect(FaceRenderer.sparkleOpacity(.nan) == 0)
        #expect(target(.proud).sparkles >= 0.6)
    }

    // MARK: Pixels

    /// Renders sad / hurt / overwhelmed through a whole tear cycle and checks the bottom
    /// edge of the frame stays background (no clipped drops).
    @MainActor
    @Test func renderedTearsNeverTouchTheBottomEdge() throws {
        let size = CGSize(width: 220, height: 170)
        for e in [Emotion.sad, .hurt, .overwhelmed] {
            for i in 0..<12 {
                let frame = FaceFrame(state: target(e), blink: 0, time: Double(i) * 0.19, voice: 0, listen: 0, breath: 1)
                let view = Canvas { ctx, sz in FaceRenderer().draw(frame, in: &ctx, size: sz) }.frame(width: size.width, height: size.height)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                let image = try #require(renderer.cgImage)
                let maxBottom = try Self.brightestInBottomRows(image, rows: 8)
                #expect(maxBottom < 0.08, "\(e) t=\(frame.time): something drawn at the bottom edge (\(maxBottom))")
            }
        }
    }

    static func brightestInBottomRows(_ image: CGImage, rows: Int) throws -> Double {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var best = 0.0
        // Memory row 0 is the top of the image.
        for y in (h - rows)..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                best = max(best, Double(max(px[i], px[i + 1], px[i + 2])) / 255)
            }
        }
        return best
    }
}
