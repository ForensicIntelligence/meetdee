import DeeCore
import DeeRealtime
import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Tune 11 regression review (scratchpad/tune11-review.md). The tune-11 early-words trim
/// (T10-4) let a turn begun just after Dee's voice ended (`commandWindow`, live latency-clean
/// q07: 0.18 s after) decide on its first deltas — and marked its words checked, so its
/// settled words were never looked at and the gate no longer waited for them. At 89d0c0f
/// the settled words decided such a turn: "…call my mom, and." (fillers t03/t04's held
/// shape) was held and never answered. With the early request its reply must still wait
/// for the settled words, which take it back.
@MainActor
@Suite(.serialized) struct Tune11ReviewBrainTests {
    typealias T2 = Tune2BrainTests
    typealias T4 = Tune4BrainTests

    @Test func aHeldTurnJustAfterHerVoiceIsStillHeldByItsSettledWords() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        try rig.quiet(0.6)
        rig.brain.inject(.itemPlayed(itemID: "item_a0", playedMs: 2400, cut: false))   // Dee's voice just ended
        rig.push(Srv.speechStarted("item_u1", ms: 100))
        try rig.talk(1.6)
        try rig.quiet(0.23)
        rig.push(Srv.speechStopped("item_u1", ms: 1700), Srv.committed("item_u1"))
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "waitForPartial")) }, "\(rig.brain.trace)")
        let start = rig.output.count
        // The live burst: the trailing "and" in its last delta; the full transcript is late.
        T2.deltas(rig, "item_u1", "Tomorrow I'm going to call my mom, and.")
        await rig.settle()
        if rig.responseCreates().count == 1 {
            T4.audio(rig, "resp_1", "item_a1", ms: 1200, text: "Oh, that's sweet, tell her hi from me.")
        }
        // Mic and wall clock together, to 1.3 s after their end.
        for _ in 0..<45 {
            try rig.step()
            await rig.settle()
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(rig.brain.trace.contains(.held("trailing")), "\(rig.brain.trace)")
        #expect(T4.released(rig) == nil, "Dee's reply to an unfinished turn was released: \(rig.brain.trace)")
        #expect(T4.peak(rig, from: start) < 0.05, "not a sample of Dee's reply was heard")
        rig.shutdown()
    }
}
