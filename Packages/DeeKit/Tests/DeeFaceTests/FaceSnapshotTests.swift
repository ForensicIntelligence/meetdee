import DeeCore
import SwiftUI
import Testing
@testable import DeeFace

/// Renders every expression and performance key frame to PNG for visual review, plus
/// labelled contact sheets. Writes to `DEE_SNAPSHOT_DIR` (skipped when unset) — run
/// `DEE_SNAPSHOT_DIR=/tmp/face swift test --filter FaceSnapshot`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEE_SNAPSHOT_DIR"] != nil), .serialized)
struct FaceSnapshotTests {
    static let dir = ProcessInfo.processInfo.environment["DEE_SNAPSHOT_DIR"] ?? "/tmp"

    struct Cell {
        var label: String
        var frame: FaceFrame
    }

    static func animator(seed: UInt64 = 7, variation: Double = 0) -> FaceAnimator {
        var a = FaceAnimator(seed: seed, initial: .neutral)
        a.variationAmount = variation
        a.idleDirectorEnabled = false
        return a
    }

    static func settledFrame(_ inputs: FaceInputs, seconds: Double = 2.0, seed: UInt64 = 7, variation: Double = 0) -> FaceFrame {
        var animator = animator(seed: seed, variation: variation)
        var frame = animator.step(1.0 / 60, inputs: inputs)
        for _ in 0..<Int(seconds * 60) { frame = animator.step(1.0 / 60, inputs: inputs) }
        frame.blink = 0
        return frame
    }

    /// Frames of `performance` over `base`, at the given seconds after it starts.
    static func performanceFrames(_ performance: Performance, base: Emotion = .neutral, at times: [Double]) -> [FaceFrame] {
        var a = animator()
        let calm = FaceInputs(emotion: base)
        for _ in 0..<90 { _ = a.step(1.0 / 60, inputs: calm) }
        var inputs = calm
        inputs.performance = PerformanceRequest(id: 1, performance: performance)
        var out: [FaceFrame] = []
        var elapsed = 0.0
        for t in times.sorted() {
            var f = a.step(1.0 / 60, inputs: inputs)
            elapsed += 1.0 / 60
            while elapsed < t - 1e-9 {
                f = a.step(1.0 / 60, inputs: inputs)
                elapsed += 1.0 / 60
            }
            f.blink = 0
            out.append(f)
        }
        return out
    }

    /// Key frames worth looking at for each performance (seconds after it starts).
    static func keyTimes(_ p: Performance) -> [Double] {
        switch p {
        case .blinkLeft, .blinkRight: [0.04, 0.1, 0.22]
        case .wink: [0.12, 0.35, 0.6]
        case .eyeRoll: [0.2, 0.6, 1.0]
        case .doubleTake: [0.25, 0.55, 0.8]
        case .nod, .bounce: [0.12, 0.23, 0.69]
        case .headShake: [0.1, 0.28, 0.46]
        case .giggle: [0.25, 0.5, 0.9]
        case .lookAround: [0.6, 1.2, 1.8]
        case .startle: [0.06, 0.2, 0.5]
        case .shiver: [0.2, 0.5, 0.8]
        case .yawn, .sigh, .contentSquint, .dizzySpin, .squint: [0.5, 1.1, 1.8]
        }
    }

    static func write(_ frame: FaceFrame, name: String, size: CGSize = CGSize(width: 390, height: 300)) throws {
        let view = Canvas { ctx, sz in FaceRenderer().draw(frame, in: &ctx, size: sz) }
            .frame(width: size.width, height: size.height)
        try save(view, name: name, scale: 2)
    }

    static func save(_ view: some View, name: String, scale: CGFloat) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        let image = try #require(renderer.cgImage)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    /// A labelled grid of cells.
    static func sheet(_ sections: [(String, [Cell])], columns: Int = 7, cell: CGSize = CGSize(width: 220, height: 170)) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                Text(section.0).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.white)
                let rows = stride(from: 0, to: section.1.count, by: columns).map { Array(section.1[$0..<min($0 + columns, section.1.count)]) }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, c in
                            VStack(spacing: 3) {
                                Canvas { ctx, sz in FaceRenderer().draw(c.frame, in: &ctx, size: sz) }
                                    .frame(width: cell.width, height: cell.height)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                Text(c.label).font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(Color(white: 0.85))
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(Color(white: 0.12))
    }

    static var emotionCells: [Cell] {
        Emotion.allCases.map { Cell(label: $0.rawValue, frame: settledFrame(FaceInputs(emotion: $0))) }
    }

    static var activityCells: [Cell] {
        var cells = [("listening", FaceActivity.listening), ("thinking", .thinking), ("sleeping", .sleeping)].map {
            Cell(label: "act:\($0.0)", frame: settledFrame(FaceInputs(activity: $0.1, micLevel: 0.6)))
        }
        cells.append(Cell(label: "think+angry", frame: settledFrame(FaceInputs(emotion: .angry, activity: .thinking))))
        var touch = FaceInputs(emotion: .happy)
        touch.touchPoint = [0.15, 0.85]
        cells.append(Cell(label: "touch↙", frame: settledFrame(touch, seconds: 1)))
        return cells
    }

    static var performanceCells: [Cell] {
        Performance.allCases.flatMap { p in
            performanceFrames(p, at: keyTimes(p)).enumerated().map { Cell(label: "\(p.rawValue) \($0.offset + 1)", frame: $0.element) }
        }
    }

    /// Reflexes above mood: a giggle and a content squint over a bad mood.
    static var reflexCells: [Cell] {
        [(Performance.giggle, Emotion.sad), (.giggle, .angry), (.giggle, .hurt), (.contentSquint, .lonely), (.wink, .grumpy)].map {
            Cell(label: "\($0.0.rawValue)/\($0.1.rawValue)", frame: performanceFrames($0.0, base: $0.1, at: [0.5])[0])
        }
    }

    static var variationCells: [Cell] {
        [Emotion.happy, .curious, .playful, .dizzy, .sad, .skeptical, .love].flatMap { e in
            (1...4).map { seed in Cell(label: "\(e.rawValue) #\(seed)", frame: settledFrame(FaceInputs(emotion: e), seed: UInt64(seed * 101), variation: 1)) }
        }
    }

    @Test func everyEmotion() throws {
        for c in Self.emotionCells { try Self.write(c.frame, name: "emotion-\(c.label)") }
    }

    @Test func activities() throws {
        for (name, activity) in [("listening", FaceActivity.listening), ("thinking", .thinking), ("sleeping", .sleeping)] {
            try Self.write(Self.settledFrame(FaceInputs(activity: activity, micLevel: 0.6)), name: "activity-\(name)")
        }
        var blink = Self.settledFrame(FaceInputs())
        blink.blink = 0.6
        try Self.write(blink, name: "blink-mid")
        var talk = Self.settledFrame(FaceInputs(emotion: .happy, activity: .speaking))
        talk.voice = 1
        try Self.write(talk, name: "speaking-loud")
    }

    /// v0.5 listening preview: plain, then positive and negative at the Listener's cap
    /// (0.5) and at full intensity, with a mid-preview blink-free frame.
    static var listenPreviewCells: [Cell] {
        [("plain", 0.0, 0.0), ("+0.6 @0.25", 0.6, 0.25), ("+0.6 @0.5", 0.6, 0.5), ("+1 @1", 1, 1),
         ("-0.6 @0.25", -0.6, 0.25), ("-0.6 @0.5", -0.6, 0.5), ("-1 @1", -1, 1)].map { label, v, i in
            Cell(label: label, frame: settledFrame(FaceInputs(emotion: .listening, activity: .listening, micLevel: 0.5, listenValence: v, listenIntensity: i)))
        }
    }

    @Test func listenPreview() throws {
        for c in Self.listenPreviewCells { try Self.write(c.frame, name: "listen-\(c.label.replacingOccurrences(of: " ", with: ""))") }
        let examine = Self.settledFrame(FaceInputs(lookAt: FaceGaze.examineBack, lidNarrow: FaceGaze.examineLids))
        let away = Self.settledFrame(FaceInputs(activity: .speaking, lookAt: FaceGaze.away))
        try Self.save(Self.sheet([("Listening preview (valence @ intensity)", Self.listenPreviewCells),
                                  ("Gaze points", [Cell(label: "examineBack", frame: examine), Cell(label: "away", frame: away)])]),
                      name: "sheet-listen", scale: 1)
    }

    @Test func performanceKeyFrames() throws {
        for p in Performance.allCases {
            for (i, f) in Self.performanceFrames(p, at: Self.keyTimes(p)).enumerated() {
                try Self.write(f, name: "perf-\(p.rawValue)-\(i + 1)")
            }
        }
    }

    @Test func contactSheets() throws {
        let emotions = Self.emotionCells, activities = Self.activityCells
        let perf = Self.performanceCells, reflex = Self.reflexCells, variation = Self.variationCells
        try Self.save(Self.sheet([("Emotions (\(emotions.count))", emotions), ("Activities & touch", activities)]), name: "sheet-emotions", scale: 1)
        try Self.save(Self.sheet([("Performances (key frames)", perf)], columns: 6), name: "sheet-performances", scale: 1)
        try Self.save(Self.sheet([("Reflexes over a bad mood", reflex), ("Per-occurrence variation", variation)], columns: 8), name: "sheet-variation", scale: 1)
        try Self.save(Self.sheet([
            ("Emotions (\(emotions.count))", emotions), ("Activities & touch", activities),
            ("Performances (key frames)", perf), ("Reflexes over a bad mood", reflex), ("Per-occurrence variation", variation),
        ], columns: 9), name: "sheet", scale: 1)
    }
}
