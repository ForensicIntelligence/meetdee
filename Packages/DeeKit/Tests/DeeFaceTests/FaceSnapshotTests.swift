import DeeCore
import SwiftUI
import Testing
@testable import DeeFace

/// Renders every expression to PNG for visual review. Writes to `DEE_SNAPSHOT_DIR`
/// (skipped when unset) — run `DEE_SNAPSHOT_DIR=/tmp/face scripts/test.sh --filter FaceSnapshot`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DEE_SNAPSHOT_DIR"] != nil))
struct FaceSnapshotTests {
    static let dir = ProcessInfo.processInfo.environment["DEE_SNAPSHOT_DIR"] ?? "/tmp"

    static func settledFrame(_ inputs: FaceInputs, seconds: Double = 2.0) -> FaceFrame {
        var animator = FaceAnimator(seed: 7, initial: .neutral)
        var frame = animator.step(1.0 / 60, inputs: inputs)
        for _ in 0..<Int(seconds * 60) { frame = animator.step(1.0 / 60, inputs: inputs) }
        frame.blink = 0
        return frame
    }

    static func write(_ frame: FaceFrame, name: String, size: CGSize = CGSize(width: 390, height: 300)) throws {
        let view = Canvas { ctx, sz in FaceRenderer().draw(frame, in: &ctx, size: sz) }
            .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test func everyEmotion() throws {
        for emotion in Emotion.allCases {
            try Self.write(Self.settledFrame(FaceInputs(emotion: emotion)), name: "emotion-\(emotion.rawValue)")
        }
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
}
