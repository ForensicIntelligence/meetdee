import DeeCore
import DeeRealtime
@testable import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Calm round 3 review (scratchpad calm/r3-review-correct.md F2): the own-end continuer rule
/// (a lone «Yeah.» right after Dee's own sentence cap is no turn) looked only at the last sentence
/// they heard. When Dee asked and then said one more sentence before the cap, their «Yeah.» —
/// the answer to Dee's question — was eaten (`backchannel("own-end")`, no reply).
@MainActor
@Suite(.serialized) struct CalmRound3ReviewBrainTests {
    typealias T2 = Tune2BrainTests
    typealias T10 = Tune10BrainTests

    /// Dee asks, says one more sentence, then the cap: «Yeah.» answers Dee's question.
    @Test(arguments: ["Yeah.", "Sure."])
    func aYeahToAnEarlierQuestionOfTheCappedReply(_ reply: String) async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false }, duckOnOnset: true)
        try await rig.start()
        try await T10.pausedBy(rig, "item_m", talk: 0.5)
        rig.brain.inject(.sentenceFinished(itemID: "item_a1", index: 0, text: "Want to hear the rest?", heard: true))
        rig.brain.inject(.sentenceFinished(itemID: "item_a1", index: 1, text: "It gets even better.", heard: true))
        await rig.settle()
        let more = ["It goes on and on.", "Folders inside folders.", "Nobody knows where anything is."]
        for (i, s) in more.enumerated() where !rig.brain.trace.contains(.sentenceCapStop) {
            rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: i + 2, text: s))
            await rig.settle()
        }
        try #require(rig.brain.trace.contains(.sentenceCapStop), "\(rig.brain.trace)")
        rig.push(Srv.speechStopped("item_m", ms: await T10.settledUplinkMs(rig)), Srv.committed("item_m"))
        await rig.settle()
        T2.deltas(rig, "item_m", reply)
        try rig.quiet(0.2)
        rig.push(Srv.userTranscript("item_m", reply))
        for _ in 0..<15 { try rig.quiet(0.1); await rig.settle() }
        #expect(!rig.brain.trace.contains(.backchannel("own-end")), "their answer to Dee's question was eaten: \(rig.brain.trace)")
        #expect(rig.brain.trace.contains(.heard(verdict: "answer")), "\(rig.brain.trace)")
        rig.shutdown()
    }
}
