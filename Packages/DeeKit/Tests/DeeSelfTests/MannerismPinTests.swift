import DeeCore
import Foundation
import Testing
@testable import DeeSelf

/// `Mannerism` mirrors `DeeFace.Performance` raw values. DeeSelf must not depend on
/// DeeFace, so the list is pinned here as a literal; DeeFace pins the same list in
/// `ListenPreviewTests.performanceRawValuesArePinned`. If either side changes, both
/// tests (and the app's 1:1 Projector mapping) must change together.
@Suite struct MannerismPinTests {
    static let performanceRawValues = [
        "wink", "blinkLeft", "blinkRight", "yawn", "eyeRoll", "doubleTake", "nod", "headShake", "giggle",
        "squint", "lookAround", "startle", "sigh", "bounce", "shiver", "contentSquint", "dizzySpin",
    ]

    @Test func rawValuesArePinned() {
        #expect(Mannerism.allCases.map(\.rawValue) == Self.performanceRawValues)
    }

    @Test func everyRawValueRoundTrips() {
        for raw in Self.performanceRawValues { #expect(Mannerism(rawValue: raw)?.rawValue == raw) }
    }

    /// Review finding 17: `calmForThinking` is a copy of DeeFace's internal
    /// `FaceAnimator.calmForThinking`. DeeSelfTests cannot import DeeFace, so this reads
    /// DeeFace's source and compares the set literally, failing on either side's change.
    @Test func calmForThinkingMatchesDeeFace() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DeeFace/FaceAnimator.swift")
        let text = try String(contentsOf: src, encoding: .utf8)
        guard let line = text.split(separator: "\n").first(where: { $0.contains("calmForThinking: Set<Emotion> = [") }) else {
            Issue.record("FaceAnimator.calmForThinking not found")
            return
        }
        let body = line.split(separator: "[", maxSplits: 1)[1].split(separator: "]")[0]
        let names = Set(body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        #expect(names == Set(calmForThinking.map(\.rawValue)))
        #expect(names.count == 8)
    }
}
