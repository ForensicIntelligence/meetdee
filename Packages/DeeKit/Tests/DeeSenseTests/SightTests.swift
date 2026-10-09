import Foundation
import Testing
@testable import DeeSense

/// Sight: label picking, novelty memory, pacing and format choice (all pure).
@Suite struct SightTests {
    // MARK: - Labels

    @Test func humanizesIdentifiers() {
        #expect(SightLabels.humanize("golf_ball") == "golf ball")
        #expect(SightLabels.humanize("alligator_crocodile") == "crocodile")
        #expect(SightLabels.humanize("adult_cat") == "cat")
        #expect(SightLabels.humanize("Dog") == "dog")
        #expect(SightLabels.humanize("guitar") == "guitar")
    }

    @Test func dropsBoringLabelsAndPrefersConcreteOnes() {
        let picked = SightLabels().pick([
            ("people", 0.95), ("adult", 0.9), ("indoor", 0.9), ("structure", 0.8), ("wall", 0.8),
            ("musical_instrument", 0.85), ("string_instrument", 0.8), ("guitar", 0.7), ("cord", 0.6),
        ])
        #expect(picked.map(\.label) == ["guitar"])
    }

    @Test func genericLabelsOnlyWhenNothingConcrete() {
        let picked = SightLabels().pick([("people", 0.9), ("animal", 0.8), ("mammal", 0.7), ("wall", 0.6)])
        #expect(picked.map(\.label) == ["animal", "mammal"])
        #expect(SightLabels().pick([("people", 0.9), ("wall", 0.9), ("indoor", 0.9)]).isEmpty)
    }

    @Test func topThingsByConfidenceAboveThreshold() {
        var labels = SightLabels()
        labels.maxThings = 3
        let picked = labels.pick([("banana", 0.4), ("apple", 0.9), ("mug", 0.7), ("plant", 0.95), ("book", 0.5), ("pen", 0.2)])
        #expect(picked.map(\.label) == ["apple", "mug", "book"])
        #expect(picked.first?.confidence == 0.9)
        #expect(!labels.pick([("pen", .nan)]).contains { $0.label == "pen" })
    }

    @Test func animalsMergeAndWin() {
        let picked = SightLabels().pick([("adult_cat", 0.6), ("cat", 0.55), ("sofa", 0.65), ("feline", 0.9)],
                                        animals: [("Cat", 0.62)])
        #expect(picked.map(\.label) == ["cat", "sofa"], "got \(picked)")
        #expect(picked.first?.confidence == 0.62)
        // An animal recogniser hit alone is enough.
        #expect(SightLabels().pick([("people", 0.9)], animals: [("Dog", 0.8)]).map(\.label) == ["dog"])
    }

    // MARK: - Novelty

    @Test func confidentNewThingIsNovelOnceForTwentyMinutes() {
        var m = NoveltyMemory()
        let guitar = SeenThing(label: "guitar", confidence: 0.8)
        do { let v = m.glance([guitar], at: 0); #expect(v == [guitar]) }
        do { let v = m.glance([guitar], at: 3); #expect(v.isEmpty) }
        do { let v = m.glance([guitar], at: 10 * 60); #expect(v.isEmpty) }
        // Still in view all along → never novel again.
        do { let v = m.glance([guitar], at: 25 * 60); #expect(v.isEmpty) }
        // Gone for > 20 min → novel again.
        do { let v = m.glance([guitar], at: 46 * 60); #expect(v == [guitar]) }
    }

    @Test func doubtfulThingNeedsASecondLook() {
        var m = NoveltyMemory()
        let mug = SeenThing(label: "mug", confidence: 0.4)
        do { let v = m.glance([mug], at: 0); #expect(v.isEmpty) }
        do { let v = m.glance([mug], at: 3); #expect(v == [mug]) }
        do { let v = m.glance([mug], at: 6); #expect(v.isEmpty) }
        // A second look too late doesn't confirm.
        let fern = SeenThing(label: "ferns", confidence: 0.4)
        do { let v = m.glance([fern], at: 100); #expect(v.isEmpty) }
        do { let v = m.glance([fern], at: 130); #expect(v.isEmpty) }
        do { let v = m.glance([fern], at: 133); #expect(v == [fern]) }
    }

    @Test func noveltyKeepsGlanceOrderAndMixes() {
        var m = NoveltyMemory()
        _ = m.glance([SeenThing(label: "lamp", confidence: 0.9)], at: 0)
        let g = [SeenThing(label: "lamp", confidence: 0.9), SeenThing(label: "parrot", confidence: 0.7), SeenThing(label: "book", confidence: 0.65)]
        do { let v = m.glance(g, at: 5); #expect(v.map(\.label) == ["parrot", "book"]) }
        #expect(m.wasSeen("parrot", at: 6))
        m.forget()
        #expect(!m.wasSeen("parrot", at: 6))
    }

    @Test func memoryIsBounded() {
        var m = NoveltyMemory()
        m.capacity = 50
        for i in 0..<200 { _ = m.glance([SeenThing(label: "thing\(i)", confidence: 0.9)], at: Double(i)) }
        #expect(m.wasSeen("thing199", at: 200))
        #expect(!m.wasSeen("thing0", at: 200))
    }

    // MARK: - Pacing

    static func glances(_ p: inout SightPacer, _ camera: CameraSide, seconds: Double, fps: Double = 15, t0: Double = 100) -> Int {
        var n = 0
        for i in 0..<Int(seconds * fps) where p.admit(camera, at: t0 + Double(i) / fps) { n += 1 }
        return n
    }

    @Test func pacesFrontAndBackIndependently() {
        var p = SightPacer()
        do { let v = Self.glances(&p, .front, seconds: 30); #expect(v == 10) }
        do { let v = Self.glances(&p, .back, seconds: 32, fps: 5); #expect(v == 8) }
    }

    @Test func constrainedHalvesAndDozingStops() {
        var p = SightPacer()
        p.constrained = true
        do { let v = Self.glances(&p, .front, seconds: 30); #expect(v == 5) }
        var d = SightPacer()
        d.dozing = true
        do { let v = Self.glances(&d, .front, seconds: 30); #expect(v == 0) }
        do { let v = Self.glances(&d, .back, seconds: 30); #expect(v == 0) }
        d.dozing = false
        do { let v = Self.glances(&d, .front, seconds: 3.1, t0: 200); #expect(v == 2) }
    }

    @Test func reportsNoveltyAlwaysOtherwiseAHeartbeat() {
        var p = SightPacer()
        let mug = [SeenThing(label: "mug", confidence: 0.7)]
        do { let v = p.shouldReport(.front, things: mug, novel: mug, at: 0); #expect(v) }
        do { let v = p.shouldReport(.front, things: mug, novel: [], at: 3); #expect(!v) }
        do { let v = p.shouldReport(.front, things: mug, novel: mug, at: 6); #expect(v, "novel always goes out") }
        do { let v = p.shouldReport(.front, things: mug, novel: [], at: 30); #expect(!v) }
        do { let v = p.shouldReport(.front, things: mug, novel: [], at: 36.1); #expect(v) }
        do { let v = p.shouldReport(.front, things: [], novel: [], at: 100); #expect(!v, "empty glances are silent") }
        do { let v = p.shouldReport(.back, things: mug, novel: [], at: 37); #expect(v, "per camera") }
    }

    @Test func resetGlancesSoon() {
        var p = SightPacer()
        do { let v = p.admit(.front, at: 0); #expect(v) }
        do { let v = p.admit(.front, at: 1); #expect(!v) }
        p.reset()
        do { let v = p.admit(.front, at: 1); #expect(v) }
    }

    // MARK: - Format choice

    @Test func picksTheSmallestUsableMultiCamFormat() {
        let f = [
            FormatCandidate(width: 1920, height: 1440, multiCam: true, binned: true, fullRange420: true, maxFrameRate: 30),
            FormatCandidate(width: 640, height: 480, multiCam: false, binned: true, fullRange420: true, maxFrameRate: 30),
            FormatCandidate(width: 1280, height: 960, multiCam: true, binned: false, fullRange420: false, maxFrameRate: 30),
            FormatCandidate(width: 1280, height: 960, multiCam: true, binned: true, fullRange420: true, maxFrameRate: 30),
            FormatCandidate(width: 480, height: 360, multiCam: true, binned: true, fullRange420: true, maxFrameRate: 30),
            FormatCandidate(width: 1024, height: 768, multiCam: true, binned: true, fullRange420: true, maxFrameRate: 10),
        ]
        #expect(FormatChoice.pick(f) == 3)
        #expect(FormatChoice.pick(f, minFrameRate: 5) == 5)
        #expect(FormatChoice.pick([f[1]]) == nil)
        #expect(FormatChoice.pick([f[4]]) == 0, "falls back to the largest below the size")
        #expect(FormatChoice.pick([]) == nil)
    }

    // MARK: - Back camera rate (review #17)

    @Test func backCameraRunsAsSlowlyAsTheFormatAllows() {
        #expect(BackCameraRate.pick(ranges: [(min: 1, max: 30)]) == 1)
        #expect(BackCameraRate.pick(ranges: [(min: 2, max: 30)]) == 2)
        #expect(BackCameraRate.pick(ranges: [(min: 3, max: 30), (min: 2, max: 24)]) == 2, "lowest across ranges")
        #expect(BackCameraRate.pick(ranges: [(min: 0.5, max: 30)]) == 1, "never below the 1 fps floor")
        #expect(BackCameraRate.pick(ranges: [(min: 0.5, max: 0.8)]) == 0.8, "floor capped by what the range reaches")
        #expect(BackCameraRate.pick(ranges: []) == nil)
        #expect(BackCameraRate.pick(ranges: [(min: 0, max: 0)]) == nil)
        // Far below the 5 fps it used to run at.
        #expect((BackCameraRate.pick(ranges: [(min: 1, max: 60)]) ?? 99) < 5)
    }

    // MARK: - CameraSense plumbing

    @Test func lookAroundIsAThreadSafeFlag() async {
        let camera = CameraSense()
        #expect(!camera.lookAround)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<4 {
                group.addTask { for j in 0..<300 { camera.lookAround = (i + j).isMultiple(of: 2) } }
            }
        }
        camera.lookAround = true
        #expect(camera.lookAround)
        #if !os(iOS)
        #expect(!CameraSense.supportsLookAround)
        #endif
        camera.shutdown()
    }

    @Test func sightUpdateIsEquatable() {
        let r = SightReport(camera: .back, things: [SeenThing(label: "dog", confidence: 0.9)], novel: [])
        #expect(SenseUpdate.sight(r) == .sight(r))
        #expect(SenseUpdate.sight(r) != .look(nil))
        #expect(CameraSide(rawValue: "back") == .back)
    }
}
