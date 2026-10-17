import DeeCore
import DeeRealtime
@testable import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Calm round 2, the review's findings, brain half (scratchpad calm/r2-review-regress.md F3,
/// r2-review-correct.md F3): a turn is still answered when its words failed after a labelled
/// sound, and when its words came in an item the voice had rejected as Dee's echo.
@MainActor
@Suite(.serialized) struct CalmRound2ReviewBrainTests {
    typealias T2 = Tune2BrainTests
    typealias T10 = Tune10BrainTests

    /// regress F3: the user coughs (a label over the burst), then asks over Dee; Dee's own
    /// sentence cap ends the reply while ducked; the transcription fails. Round 2's
    /// `holdClaims` claimed it (`o.sound`), `wordsFailed` recorded `.holdClaimed`, nothing
    /// answered. Now failed words are answered from the audio, labelled or not (as in 0.6.0);
    /// an empty transcript after the label is still no turn.
    @Test(arguments: [true, false])
    func aQuestionAfterACoughAndHerOwnCapIsAnswered(failed: Bool) async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false }, duckOnOnset: true)
        try await rig.start()
        try await T10.pausedBy(rig, "item_q", talk: 0.6)
        try #require(rig.voice.floorHold?.phase == .ducked, "\(String(describing: rig.voice.floorHold))")
        let now = rig.voice.graph.now
        rig.voice.classifiedForTesting([("cough", 0.8)], window: (now - 0.6)...(now - 0.4))
        let more = ["It goes on and on.", "Folders inside folders.", "Nobody knows where anything is."]
        for (i, s) in more.enumerated() where !rig.brain.trace.contains(.sentenceCapStop) {
            rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: i + 1, text: s))
            await rig.settle()
        }
        try #require(rig.brain.trace.contains(.sentenceCapStop), "\(rig.brain.trace)")
        await rig.settle()
        rig.push(Srv.speechStopped("item_q", ms: await T10.settledUplinkMs(rig)), Srv.committed("item_q"))
        await rig.settle()
        rig.push(failed ? Srv.transcriptFailed("item_q") : Srv.userTranscript("item_q", ""))
        if failed {
            #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail()) \(rig.brain.trace)")
            #expect(!rig.brain.trace.contains(.holdClaimed), "\(rig.brain.trace)")
        } else {
            for _ in 0..<15 { try rig.quiet(0.1); await rig.settle() }
            #expect(rig.responseCreates().count == 1, "an empty burst was answered: \(rig.trail()) \(rig.brain.trace)")
        }
        rig.shutdown()
    }

    /// correct F3: "Wait, what did you say about the moon?" under heavy echo — the voice rejected
    /// the item as Dee's echo (deleted from the conversation), its "Wait" paused Dee, and its
    /// full words went nowhere: the reply was cut 2 s later and the question lost. Now the voice
    /// hands the words over (`HoldEvent.rescued`): they go in as a user item and are answered
    /// (one answer), which ends Dee's reply.
    @Test func aRescuedQuestionIsAnsweredOnce() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false }, duckOnOnset: true)
        try await rig.start()
        // Dee talking (the c03 replay: the echo items were rejected; nothing of theirs is open).
        try rig.quiet(0.3)
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        for _ in 0..<80 { rig.push(Srv.audio("resp_1", "item_a1", Sig.pcm(ms: 100))) }
        rig.push(Srv.transcript("resp_1", "item_a1", "So the filing system is a mystery puzzle. It goes on and on."),
                 Srv.audioDone("resp_1", "item_a1"), Srv.responseDone("resp_1"))
        try rig.quiet(0.6)
        await rig.settle()
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 0, text: "So the filing system is a mystery puzzle."))
        try rig.quiet(0.4)
        await rig.settle()
        let text = "Wait, what did you say about the moon?"
        rig.brain.injectHold(.rescued(itemID: "item_e3", text: text))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail()) \(rig.brain.trace)")
        #expect(rig.brain.trace.contains(.rescued), "\(rig.brain.trace)")
        #expect(rig.trail().contains("user:\(text)"), "\(rig.trail())")
        #expect(rig.trail().contains("truncate:item_a1"), "the answer ends Dee's reply: \(rig.trail())")
        for _ in 0..<10 { try rig.quiet(0.1); await rig.settle() }
        #expect(rig.responseCreates().count == 2, "one answer: \(rig.trail())")
        rig.shutdown()
    }
}
