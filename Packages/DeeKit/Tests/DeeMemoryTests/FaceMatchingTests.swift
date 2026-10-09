import CoreGraphics
import Foundation
import Testing
@testable import DeeMemory

/// Deterministic pseudo-random unit vectors (the shape of Vision revision-2 prints: 768 floats).
struct LCG {
    var state: UInt64
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: state >> 11) % 2_000_001 - 1_000_000) / 1_000_000
    }
    mutating func vector(_ n: Int = 768) -> [Float] { (0..<n).map { _ in next() } }
}

func unit(_ v: [Float]) -> FacePrint { FacePrint(vector: v).normalized }

/// A print at roughly distance `d` from `base` (both unit length).
func jitter(_ base: FacePrint, toward noise: [Float], distance d: Float) -> FacePrint {
    // For unit a, b orthogonal-ish: |a - (a cosθ + b sinθ)| = 2 sin(θ/2).
    let theta = 2 * asin(d / 2)
    let b = unit(noise).vector
    let dot = zip(base.vector, b).map(*).reduce(0, +)
    let orth = unit(zip(b, base.vector).map { $0 - dot * $1 }).vector
    return FacePrint(vector: zip(base.vector, orth).map { cos(theta) * $0 + sin(theta) * $1 })
}

/// Three enrolment prints of one face (different "frames"): the base and two
/// captures `spread` away from it.
func enrolment(_ base: FacePrint, _ r: inout LCG, spread: Float = 0.15) -> [FacePrint] {
    [base.normalized, jitter(base.normalized, toward: r.vector(base.vector.count), distance: spread),
     jitter(base.normalized, toward: r.vector(base.vector.count), distance: spread)]
}

@Suite("Face matching")
struct FaceMatchingTests {
    @Test func distanceBasics() {
        let a = FacePrint(vector: [1, 0, 0]), b = FacePrint(vector: [0, 1, 0]), c = FacePrint(vector: [-1, 0, 0])
        #expect(a.distance(to: a) == 0)
        #expect(abs(a.distance(to: b) - 2.0.squareRoot().floatValue) < 1e-5)
        #expect(abs(a.distance(to: c) - 2) < 1e-5)
        #expect(FacePrint(vector: [2, 0, 0]).distance(to: a) < 1e-6, "scale-invariant")
        #expect(a.distance(to: FacePrint(vector: [1, 0])) == .greatestFiniteMagnitude)
        #expect(FacePrint(vector: [0, 0, 0]).distance(to: a) == .greatestFiniteMagnitude)
        #expect(a.distance(to: b) == b.distance(to: a))
    }

    @Test func jitterHelperHitsRequestedDistance() {
        var r = LCG(state: 1)
        let base = unit(r.vector())
        let j = jitter(base, toward: r.vector(), distance: 0.3)
        #expect(abs(base.distance(to: j) - 0.3) < 1e-3)
    }

    @Test func identifiesNearestUnderThreshold() {
        var r = LCG(state: 42)
        let alice = unit(r.vector()), bob = unit(r.vector())
        let ida = UUID(), idb = UUID()
        let gallery = [ida: [alice], idb: [bob]]
        let probe = jitter(alice, toward: r.vector(), distance: 0.35)
        let m = FaceMatcher.best(probe, among: gallery)
        #expect(m?.id == ida)
        #expect(abs((m?.distance ?? 9) - 0.35) < 1e-3)
    }

    @Test func strangerIsNil() {
        var r = LCG(state: 7)
        let gallery = [UUID(): [unit(r.vector())], UUID(): [unit(r.vector())]]
        // Random 768-d unit vectors sit near √2 from everything.
        #expect(FaceMatcher.best(unit(r.vector()), among: gallery) == nil)
        #expect(FaceMatcher.best(unit(r.vector()), among: [:]) == nil)
    }

    @Test func thresholdIsTunable() {
        var r = LCG(state: 9)
        let a = unit(r.vector()), id = UUID()
        let probe = jitter(a, toward: r.vector(), distance: 0.7)
        #expect(FaceMatcher.best(probe, among: [id: [a]]) == nil)
        var loose = FaceMatching()
        loose.threshold = 0.8
        #expect(FaceMatcher.best(probe, among: [id: [a]], tuning: loose)?.id == id)
    }

    @Test func scoresOnMeanOfClosestPrints() {
        var r = LCG(state: 3)
        let face = unit(r.vector())
        let id = UUID()
        let set = enrolment(face, &r)
        let probe = jitter(face, toward: r.vector(), distance: 0.2)
        let m = FaceMatcher.best(probe, among: [id: set])
        #expect(m?.id == id)
        // The score is the mean of the 2 closest prints, not the single closest.
        let d = set.map { probe.distance(to: $0) }.sorted()
        #expect(abs((m?.distance ?? 9) - (d[0] + d[1]) / 2) < 1e-4)
        // One lucky close print among unrelated ones does not make a match.
        let stranger = unit(r.vector())
        #expect(FaceMatcher.best(probe, among: [id: [jitter(probe, toward: r.vector(), distance: 0.1), stranger, unit(r.vector())]]) == nil)
    }

    @Test func ambiguousMatchIsNil() {
        var r = LCG(state: 11)
        let base = unit(r.vector())
        let twinA = jitter(base, toward: r.vector(), distance: 0.2)
        let twinB = jitter(base, toward: r.vector(), distance: 0.2)
        let probe = base
        #expect(FaceMatcher.best(probe, among: [UUID(): [twinA], UUID(): [twinB]]) == nil)
    }

    @Test func pruningKeepsDiverseAndRecent() {
        var r = LCG(state: 5)
        let a = unit(r.vector()), b = unit(r.vector()), c = unit(r.vector())
        let aDup = jitter(a, toward: r.vector(), distance: 0.05)
        // Oldest first: a, b, aDup, c — the closest pair is (a, aDup) → drop the older, a.
        #expect(FaceMatcher.indicesToDrop([a, b, aDup, c], keeping: 3) == [0])
        #expect(FaceMatcher.indicesToDrop([a, b], keeping: 3).isEmpty)
        #expect(FaceMatcher.indicesToDrop([a, b, c], keeping: 0) == [0, 1, 2])
    }

    @Test func novelty() {
        var r = LCG(state: 8)
        let a = unit(r.vector())
        #expect(!FaceMatcher.isNovel(jitter(a, toward: r.vector(), distance: 0.05), comparedTo: [a]))
        #expect(FaceMatcher.isNovel(jitter(a, toward: r.vector(), distance: 0.3), comparedTo: [a]))
        #expect(FaceMatcher.isNovel(a, comparedTo: []))
    }

    @Test func storeLearnsConfidentNovelPrintsAndCapsSet() async throws {
        let s = try memStore()
        var r = LCG(state: 21)
        let face = unit(r.vector())
        let p = try #require(await s.enroll(name: "John", facePrints: enrolment(face, &r), at: t0))
        #expect(await s.facePrintCount(of: p.id) == 3)
        // A confident, novel angle is learnt only on the 3rd consecutive agreeing frame.
        let newAngle = jitter(face, toward: r.vector(), distance: 0.3)
        #expect(await s.identify(newAngle)?.person.id == p.id)
        #expect(await s.identify(newAngle)?.person.id == p.id)
        #expect(await s.facePrintCount(of: p.id) == 3)
        #expect(await s.identify(newAngle)?.person.id == p.id)
        #expect(await s.facePrintCount(of: p.id) == 4)
        // Near-duplicate: matched, not learnt.
        #expect(await s.identify(jitter(newAngle, toward: r.vector(), distance: 0.05))?.person.id == p.id)
        #expect(await s.facePrintCount(of: p.id) == 4)
        // Matched but not within learnThreshold of an anchor: not learnt.
        let far = jitter(face, toward: r.vector(), distance: 0.52)
        for _ in 0..<4 { #expect(await s.identify(far)?.person.id == p.id) }
        #expect(await s.facePrintCount(of: p.id) == 4)
        // learn: false never learns.
        for _ in 0..<4 { _ = await s.identify(jitter(face, toward: r.vector(), distance: 0.3), learn: false) }
        #expect(await s.facePrintCount(of: p.id) == 4)
        // The rolling set never exceeds maxPrintsPerPerson, and anchors survive.
        for _ in 0..<30 { await s.addFacePrints([jitter(face, toward: r.vector(), distance: 0.4)], to: p.id) }
        #expect(await s.facePrintCount(of: p.id) == FaceMatching().maxPrintsPerPerson)
        #expect(await s.anchorCount(of: p.id) == 3)
        #expect(await s.identify(face, learn: false)?.person.id == p.id)
    }

    @Test func storeIdentifiesAmongSeveralPeople() async throws {
        let s = try memStore()
        var r = LCG(state: 99)
        var ids: [UUID: FacePrint] = [:]
        for name in ["Ann", "Ben", "Cat", "Dan", "Eve"] {
            let f = unit(r.vector())
            ids[try #require(await s.enroll(name: name, facePrints: enrolment(f, &r), at: t0)).id] = f
        }
        for (id, f) in ids {
            #expect(await s.identify(jitter(f, toward: r.vector(), distance: 0.35), learn: false)?.person.id == id)
        }
        #expect(await s.identify(unit(r.vector())) == nil)
    }

    @Test func cropRectExpandsSquaresAndClamps() {
        let size = CGSize(width: 1000, height: 500)
        let r = try! #require(FaceEmbedder.cropRect(faceBox: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.2), imageSize: size))
        // Box is 100×100 px centred at (450, 150): side 125.
        #expect(abs(r.width - 125) <= 1 && abs(r.height - 125) <= 1)
        #expect(abs(r.midX - 450) <= 1 && abs(r.midY - 250) <= 1)
        #expect(!FaceEmbedder.isClipped(faceBox: CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.2), imageSize: size))
        // Finding 11: at the edge the square is NOT clamped (it is padded later), so
        // the face keeps its proportions instead of being stretched.
        let edgeBox = CGRect(x: 0.95, y: 0.9, width: 0.1, height: 0.2)
        let edge = try! #require(FaceEmbedder.cropRect(faceBox: edgeBox, imageSize: size))
        #expect(abs(edge.width - edge.height) <= 1)
        #expect(abs(edge.width - 125) <= 1)
        #expect(edge.maxX > 1000)
        #expect(FaceEmbedder.isClipped(faceBox: edgeBox, imageSize: size))
        #expect(FaceEmbedder.cropRect(faceBox: CGRect(x: 2, y: 2, width: 0.1, height: 0.1), imageSize: size) == nil)
        #expect(FaceEmbedder.cropRect(faceBox: .zero, imageSize: size) == nil)
    }

    static func syntheticImage(seed: UInt8) -> CGImage {
        let w = 256, h = 256
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                px[i] = UInt8((x &+ Int(seed)) & 0xFF)
                px[i + 1] = UInt8((y &* 2) & 0xFF)
                px[i + 2] = UInt8(((x ^ y) &+ Int(seed) &* 3) & 0xFF)
                px[i + 3] = 255
            }
        }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.9, green: 0.7, blue: 0.6, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 80, y: 70, width: 96, height: 120))
        return ctx.makeImage()!
    }

    @Test func embedderReturnsUnitVectorOnSyntheticImages() async throws {
        let box = CGRect(x: 0.3, y: 0.27, width: 0.375, height: 0.47)
        let a: FacePrint
        do {
            a = try await FaceEmbedder.print(of: Self.syntheticImage(seed: 0), faceBox: box)
        } catch {
            // Vision models can be missing in some headless/CI environments; the
            // contract is "throws when unavailable", which is what happened.
            withKnownIssue("Vision feature print unavailable here: \(error)") { Issue.record(error) }
            return
        }
        #expect(a.vector.count > 100)
        let norm = a.vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(norm - 1) < 1e-3)
        let b = try await FaceEmbedder.print(of: Self.syntheticImage(seed: 0), faceBox: box)
        #expect(a.distance(to: b) < 0.01, "deterministic")
        let rotated = try await FaceEmbedder.print(of: Self.syntheticImage(seed: 0), faceBox: box, orientation: .right)
        #expect(!rotated.vector.isEmpty)
    }

    @Test func embedderRejectsBoxOutsideImage() async {
        await #expect(throws: FaceEmbedderError.self) {
            try await FaceEmbedder.print(of: Self.syntheticImage(seed: 1), faceBox: CGRect(x: 3, y: 3, width: 0.1, height: 0.1))
        }
    }
}

private extension Double { var floatValue: Float { Float(self) } }
