import DeeCore
import DeeRealtime
@testable import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Calm round 3, brain half (scratchpad calm/r2-live.md C4 / C5). After 0.6.0 the user found Dee
/// "too sensitive to interruptions"; round 2 fixed that live, but two brain paths still answered
/// what was no turn: a lone continuer right after Dee's own sentence cap (bc09 «Yeah.», bc11
/// «Mm-hmm.», run B), and the server's tail of a question the quick commit split (fan15 q05 «Okay.»
/// after «Can you hear me okay?», run A: the answer was re-created, 2.05 s).
@MainActor
@Suite(.serialized) struct CalmRound3BrainTests {
    typealias T2 = Tune2BrainTests
    typealias T10 = Tune10BrainTests
    typealias R2 = CalmRound2BrainTests

    /// Live calm-bc-tv15 bc11 (B, 10.20–15.72): «Mm-hmm.» ducked Dee; Dee's own cap ended the reply
    /// (`unduck (stopped)`); its words came after, and Dee spoke again 3 s later — a reply to a
    /// continuer. Round 3: no turn; nothing is asked for.
    @Test func aContinuerOverDeesOwnCapIsNoTurn() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false }, duckOnOnset: true)
        try await R2().cappedOver(rig, "item_m", talk: 0.5)
        rig.push(Srv.speechStopped("item_m", ms: await T10.settledUplinkMs(rig)), Srv.committed("item_m"))
        await rig.settle()
        T2.deltas(rig, "item_m", "Mm-hmm.")
        try rig.quiet(0.2)
        rig.push(Srv.userTranscript("item_m", "Mm-hmm."))
        for _ in 0..<40 { try rig.quiet(0.1); await rig.settle() }
        #expect(rig.responseCreates().count == 1, "a continuer was answered: \(rig.trail()) \(rig.brain.trace)")
        #expect(rig.brain.trace.contains(.backchannel("own-end")), "\(rig.brain.trace)")
        rig.shutdown()
    }

    /// Live calm-bc-clean bc09 (B, 93.86–97.52): "Haha, yeah." — the laugh over Dee, Dee's own cap,
    /// then «Yeah.» in an item of its own 1.1 s after the cap: committed, answered as a turn.
    @Test func aContinuerJustAfterDeesOwnCapIsNoTurn() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false }, duckOnOnset: true)
        try await R2().cappedOver(rig, "item_x", talk: 0.3)
        rig.push(Srv.speechStopped("item_x", ms: await T10.settledUplinkMs(rig)), Srv.committed("item_x"))
        await rig.settle()
        rig.push(Srv.userTranscript("item_x", ""))
        try rig.quiet(0.8)
        await rig.settle()
        try await T10.talk(rig, 0.1)
        rig.push(Srv.speechStarted("item_y", ms: max(0, await T10.settledUplinkMs(rig) - 100)))
        try await T10.talk(rig, 0.3)
        rig.push(Srv.speechStopped("item_y", ms: await T10.settledUplinkMs(rig)), Srv.committed("item_y"))
        await rig.settle()
        T2.deltas(rig, "item_y", "Yeah.")
        try rig.quiet(0.2)
        rig.push(Srv.userTranscript("item_y", "Yeah."))
        #expect(await rig.until(4) { rig.brain.trace.contains(.backchannel("own-end")) }, "\(rig.trail()) \(rig.brain.trace)")
        // (A fast reply asked for at its commit, before its words, is taken back unheard.)
        let creates = rig.responseCreates().count
        for _ in 0..<30 { try rig.quiet(0.1); await rig.settle() }
        #expect(rig.responseCreates().count == creates, "«Yeah.» was answered: \(rig.trail()) \(rig.brain.trace)")
        #expect(!rig.brain.trace.contains(.heard(verdict: "answer")) || rig.brain.trace.last(where: {
            if case .backchannel = $0 { true } else { false }
        }) == .backchannel("own-end"), "\(rig.brain.trace)")
        rig.shutdown()
    }

    /// Control: when the last sentence they heard asked them something, «Yeah.» answers it — the
    /// own-end rule leaves it to the brain's usual words rule (unchanged from round 2).
    @Test func aYeahToDeesQuestionIsNoOwnEndContinuer() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false }, duckOnOnset: true)
        try await rig.start()
        try await T10.pausedBy(rig, "item_m", talk: 0.5)
        rig.brain.inject(.sentenceFinished(itemID: "item_a1", index: 0, text: "Want to hear the rest?", heard: true))
        await rig.settle()
        let more = ["It goes on and on.", "Folders inside folders.", "Nobody knows where anything is."]
        for (i, s) in more.enumerated() where !rig.brain.trace.contains(.sentenceCapStop) {
            rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: i + 1, text: s))
            await rig.settle()
        }
        try #require(rig.brain.trace.contains(.sentenceCapStop), "\(rig.brain.trace)")
        rig.push(Srv.speechStopped("item_m", ms: await T10.settledUplinkMs(rig)), Srv.committed("item_m"))
        await rig.settle()
        T2.deltas(rig, "item_m", "Yeah.")
        try rig.quiet(0.2)
        rig.push(Srv.userTranscript("item_m", "Yeah."))
        for _ in 0..<15 { try rig.quiet(0.1); await rig.settle() }
        #expect(rig.brain.trace.contains(.heard(verdict: "answer")), "\(rig.brain.trace)")
        #expect(!rig.brain.trace.contains(.backchannel("own-end")), "\(rig.brain.trace)")
        rig.shutdown()
    }

    /// Control: a question after Dee's own cap is still answered (round 2's rule, unchanged).
    @Test func aQuestionJustAfterDeesOwnCapIsAnswered() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false }, duckOnOnset: true)
        try await R2().cappedOver(rig, "item_q", talk: 0.6)
        rig.push(Srv.speechStopped("item_q", ms: await T10.settledUplinkMs(rig)), Srv.committed("item_q"))
        await rig.settle()
        T2.deltas(rig, "item_q", "Yeah, who made you?")
        rig.push(Srv.userTranscript("item_q", "Yeah, who made you?"))
        #expect(await rig.until(4) { rig.responseCreates().count == 2 }, "\(rig.trail()) \(rig.brain.trace)")
        rig.shutdown()
    }

    /// Live t2-interrupt-fan15 q05 (A, 59.60–62.72): the quick commit split «Can you hear me okay?»;
    /// the server's tail of it said «Okay.» while the answer was on its way. Round 3: the tail
    /// repeats the end of the question being answered — merged, never a second request.
    @Test func theTailOfAnAnsweredQuestionIsMerged() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false }, duckOnOnset: true)
        try await rig.start()
        try await T10.pausedBy(rig, "item_q", talk: 0.9)
        rig.push(Srv.committed("item_q"))
        await rig.settle()
        T2.deltas(rig, "item_q", "Can you hear me okay?")
        rig.push(Srv.userTranscript("item_q", "Can you hear me okay?"))
        #expect(await rig.until(4) { rig.responseCreates().count == 2 }, "\(rig.trail()) \(rig.brain.trace)")
        // The tail: a stop with no start of its own, right after the commit.
        rig.push(Srv.speechStopped("item_t", ms: await T10.settledUplinkMs(rig)), Srv.committed("item_t"))
        await rig.settle()
        try #require(rig.brain.trace.contains(.tailIgnored), "\(rig.brain.trace)")
        rig.push(Srv.userTranscript("item_t", "Okay."))
        for _ in 0..<20 { try rig.quiet(0.1); await rig.settle() }
        #expect(rig.brain.trace.contains(.covered), "\(rig.brain.trace)")
        #expect(rig.responseCreates().count == 2, "the tail was answered: \(rig.trail()) \(rig.brain.trace)")
        #expect(!rig.trail().contains("response.cancel"), "the answer was taken back: \(rig.trail())")
        rig.shutdown()
    }

    @Test func repeatsEnd() {
        #expect(RealtimeBrain.repeatsEnd("Okay.", of: "Can you hear me okay?"))
        #expect(RealtimeBrain.repeatsEnd("me okay", of: "Can you hear me okay?"))
        #expect(!RealtimeBrain.repeatsEnd("And the moon?", of: "Can you hear me okay?"))
        #expect(!RealtimeBrain.repeatsEnd("Okay.", of: nil))
        #expect(RealtimeBrain.isAcknowledgement("Mm-hmm."))
        #expect(RealtimeBrain.isAcknowledgement("Yeah."))
        #expect(!RealtimeBrain.isAcknowledgement("Keep going."))
        #expect(!RealtimeBrain.isAcknowledgement("Yeah?"))
        #expect(!RealtimeBrain.isAcknowledgement("Who made you?"))
    }
}
