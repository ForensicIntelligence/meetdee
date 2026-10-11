import DeeCore
import DeeRealtime
import DeeSelf
@testable import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Tune 14: the tune-13 live findings (scratchpad/tune13-live.md, report 20261010-224809),
/// replayed at the live shape on the real voice and session (BrainRig).
@MainActor
@Suite(.serialized) struct Tune14BrainTests {
    typealias T2 = Tune2BrainTests
    typealias T7 = Tune7BrainTests
    typealias T9 = Tune9BrainTests

    // MARK: (1) Thinking aloud in its "let's" form (T13-5)

    /// The "let's" form is thinking aloud in any sentence position; invitations and advice
    /// with the same words are not.
    @Test func letsThinkThisThroughIsThinkingAloud() {
        // Live fillers-echo10 k08 (A 96.42): her first sentence, before "Let me think about what".
        #expect(TurnPolicy.isMetaPreamble("Okay, let's think this through."))
        #expect(TurnPolicy.metaSentence(in: "Okay, let\u{2019}s think this through. Let me think about what") == 0)
        #expect(TurnPolicy.metaSentence(in: "That's a big one. Let's think about how to make it easier.") == 1)
        #expect(TurnPolicy.metaSentence(in: "Soup is cozy. Let us think it over.") == 1)
        // Not: an invitation, a plan together, advice to them (live 20261010-035320 length-clean).
        #expect(!TurnPolicy.isMetaPreamble("Ooh, let's go!"))
        #expect(TurnPolicy.metaSentence(in: "Let's think of a name together! Maybe Biscuit?") == nil)
        #expect(TurnPolicy.metaSentence(in: "It's fair to you and to the pup to pause and think this through. Maybe a small dog?") == nil)
    }

    /// fillers-echo10 k08 "…What should I make with it?" → "Okay, let's think this through." as
    /// her whole first sentence: unheard, it is taken back and the turn asked again once (live, a
    /// second sentence of narration happened to catch it; alone, it was heard).
    @Test func liveFillersEcho10K08LetsThinkFirstIsTakenBack() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.userTranscript("item_u1", "Tomorrow I'm going to call my mom and ask her for her soup recipe. What should I make with it?"))
        #expect(await rig.until { rig.host.heardLog.count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        T2.assistantDelta(rig, "resp_1", "item_a1", "Okay, let\u{2019}s think this through. ")
        #expect(await rig.until { rig.brain.trace.contains(.preamble(cut: true)) }, "\(rig.brain.trace)")
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "answered again: \(rig.trail())")
        rig.shutdown()
    }

    /// After a laugh (no question, the joke-k05 shape), the "let's" form in a later sentence
    /// is stopped before; what she said stands and nothing is asked again.
    @Test func letsThinkLaterIsStoppedBefore() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.userTranscript("item_u1", "Lettuce."))
        #expect(await rig.until { rig.host.heardLog.count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        T2.assistantDelta(rig, "resp_1", "item_a1", "Lettuce? Heh, that's good. Let's think about what comes next.")
        #expect(await rig.until { rig.brain.trace.contains(.narrationStop) }, "\(rig.brain.trace)")
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 0, text: "Lettuce?"))
        await rig.settle()
        #expect(rig.count("response.cancel") == 0 && !rig.brain.trace.contains(.preamble(cut: true)))
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 2, text: "Let's think about what comes next."))
        #expect(await rig.until { rig.brain.trace.contains(.preamble(cut: true)) }, "stopped before it: \(rig.brain.trace)")
        rig.push(Srv.responseDone("resp_1"))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.responseCreates().count == 1, "no retry: she had answered")
        rig.shutdown()
    }

    // MARK: (2) The answer-first note never carries their words

    /// interrupt-echo20 q08 "Who made you?" over her (solo 20261010-214811 54.07: all four deltas
    /// in before the request). The tune-13 note named it ("in words like “Who made you?”"), but
    /// on the early-words path it named nothing live (0 of 39) and, made reachable without the
    /// "?", it would name a cut-off prefix 18 times in 44 ("Do you like", "Who made"). The note
    /// is the plain one, and none of their words are in it.
    @Test func liveEcho20Q08TheAnswerFirstNoteIsPlain() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await T7.overHer(rig, "item_q")
        T2.delta(rig, "item_q", "Who made you?")
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail())")
        let dna = try #require(T9.lastDNA(rig))
        #expect(dna.contains("Keep in mind: " + TurnPolicy.answerFirstNote), "\(dna)")
        #expect(!dna.contains("Who made you") && !dna.contains("in words like \u{201C}"), "\(dna)")
        rig.shutdown()
    }
}
