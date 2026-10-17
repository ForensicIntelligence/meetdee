import DeeCore
import DeeRealtime
import DeeSelf
@testable import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Tune 13: the tune-12 live findings (scratchpad/tune12-live.md), replayed at the live shape
/// on the real voice and session (BrainRig).
@MainActor
@Suite(.serialized) struct Tune13BrainTests {
    typealias T12 = Tune12BrainTests
    typealias T2 = Tune2BrainTests
    typealias T7 = Tune7BrainTests

    /// T12-2, t2-backchannel-echo20 c05 (Traces/20261010-205810, 59.5–66.3): "Keep going." →
    /// `continued` (61.64), "I'm listening." → the tail of it, Dee went on. 2.58 s after the
    /// go-on Dee's reply reached its sentence cap (`sentenceCapStop`, truncate at 64.21): Dee's own
    /// stop, which the "cut anyway after keep going" rule took for a barge-in and answered with
    /// a carry-on at 64.52 ("Oh, okay, let's keep going…"). Dee's own stop asks for nothing.
    @Test func liveEcho20C05HerOwnSentenceCapStopIsNoCarryOn() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false })
        try await rig.start()
        try await T12.continuerThenMore(rig, second: "I'm listening.", talk: 0.5)
        #expect(rig.brain.trace.contains(.backchannel("continued")), "\(rig.brain.trace)")
        #expect(rig.responseCreates().count == 1, "nothing answered: \(rig.trail())")
        // Dee talks on to Dee's sentence cap, inside 3 s of the go-on.
        let more = ["It goes on and on.", "Folders inside folders.", "Nobody knows where anything is."]
        for (i, s) in more.enumerated() where !rig.brain.trace.contains(.sentenceCapStop) {
            rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: i + 1, text: s))
            await rig.settle()
        }
        #expect(rig.brain.trace.contains(.sentenceCapStop), "\(rig.brain.trace)")
        rig.brain.inject(.itemPlayed(itemID: "item_a1", playedMs: 3565, cut: true))
        await rig.settle()
        try? await Task.sleep(for: .milliseconds(400))
        #expect(rig.responseCreates().count == 1, "no carry-on after Dee's own stop: \(rig.trail()) \(rig.brain.trace)")
        rig.shutdown()
    }
    // The tune-13 named answer-first note (q08) was removed in tune 14: Tune14BrainTests.
}
