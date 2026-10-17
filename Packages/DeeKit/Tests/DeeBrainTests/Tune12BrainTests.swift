import DeeCore
import DeeRealtime
import DeeSelf
@testable import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Tune 12 (brain + voice, one rule): the tune-11 live finding T11-1 (scratchpad/tune11-live.md;
/// report Tools/voice-harness/Reports/20261010-180956, trace
/// Traces/20261010-180956/t2-backchannel-fan15.jsonl 47.5–52.5), replayed at the live shape on
/// the real voice and session (BrainRig).
///
/// Decision: a short item (≤ ~1.2 s of voice, no "?", no stop / call / question word, a pitch
/// that does not rise) that follows a recognised continuer in the same hold within ~0.8 s is
/// the rest of that backchannel. Anything else stays "unsure → stop and answer".
@MainActor
@Suite(.serialized) struct Tune12BrainTests {
    typealias T2 = Tune2BrainTests
    typealias T10 = Tune10BrainTests

    /// "Keep going," over Dee (a hold), the server ending it (`speech_stopped` + commit) while
    /// they go straight on with the second half under a new item (its start 12 ms before the
    /// first one's end, as live: 49620 vs 49632). Its words come back while they talk.
    static func continuerThenMore(_ rig: BrainRig, second: String, talk: Double) async throws {
        try await T10.pausedBy(rig, "item_k", talk: 0.6)
        let end = await T10.settledUplinkMs(rig)
        rig.push(Srv.speechStopped("item_k", ms: end), Srv.committed("item_k"),
                 Srv.speechStarted("item_s", ms: end - 12))
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "waitForPartial")) }, "\(rig.brain.trace)")
        T2.deltas(rig, "item_k", "Keep going.")
        try await T10.talk(rig, 0.2)
        rig.push(Srv.userTranscript("item_k", "Keep going."))
        try await T10.talk(rig, talk - 0.2)
        // Live: our quick commit of the short second burst (50.684), its words all at once
        // ~0.3 s later (50.98, 4 deltas in 13 ms) while Dee is still held, the full words 0.2 s
        // after. A long burst is left to the server (its speech_stopped and commit).
        for _ in 0..<8 { try rig.quiet(0.05); await rig.settle() }
        if rig.voice.floorHold?.commitAt == nil {
            rig.push(Srv.speechStopped("item_s", ms: await T10.settledUplinkMs(rig)))
        }
        rig.push(Srv.committed("item_s"))
        await rig.settle()
        for _ in 0..<5 { try rig.quiet(0.05); await rig.settle() }
        T2.deltas(rig, "item_s", second)
        await rig.settle()
        for _ in 0..<4 { try rig.quiet(0.05); await rig.settle() }
        rig.push(Srv.userTranscript("item_s", second))
        for _ in 0..<15 { try rig.quiet(0.1); await rig.settle() }
    }

    /// Live c05: "Keep going, I'm listening." → "Keep going." (`continued`, deferred while they
    /// talked) | "I'm with some." (3 words the words don't know as a continuer) → `earlyWords`,
    /// Dee's reply flushed at 51.00 and the misheard words answered ("Oh, thanks! I'm glad you're
    /// with me."). The second half is the rest of the backchannel: Dee goes on, nothing is asked.
    @Test func liveFan15C05TheSplitOffRestOfKeepGoingContinuesHer() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false })
        try await rig.start()
        // ~0.5 s of their voice (the rig's server-ms → mic mapping can put the item's onset up
        // to ~0.5 s early, inside "Keep going": measured 0.84–1.04 s, under the 1.2 s bound).
        try await Self.continuerThenMore(rig, second: "I'm with some.", talk: 0.5)
        #expect(!rig.brain.trace.contains(.earlyWords), "\(rig.brain.trace)")
        #expect(rig.voice.floorHold == nil, "Dee went on")
        #expect(!rig.trail().contains("truncate:item_a1"), "Dee's reply is not cut: \(rig.trail())")
        #expect(rig.responseCreates().count == 1, "nothing answered: \(rig.trail()) \(rig.brain.trace)")
        rig.shutdown()
    }

    /// A real question after a continuer is still stopped for and answered.
    @Test func aQuestionAfterKeepGoingIsStillAnswered() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false })
        try await rig.start()
        try await Self.continuerThenMore(rig, second: "Wait, who made you?", talk: 0.5)
        #expect(rig.responseCreates().count == 2, "answered: \(rig.trail()) \(rig.brain.trace)")
        #expect(rig.trail().contains("truncate:item_a1"), "Dee's reply ends where Dee paused: \(rig.trail())")
        rig.shutdown()
    }

    /// A long statement after a continuer (far more than ~1.2 s of voice) is still a turn.
    @Test func aLongStatementAfterKeepGoingIsStillATurn() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false })
        try await rig.start()
        try await Self.continuerThenMore(rig, second: "I had the strangest dream about a purple whale.", talk: 2.6)
        #expect(rig.responseCreates().count == 2, "answered: \(rig.trail()) \(rig.brain.trace)")
        #expect(rig.trail().contains("truncate:item_a1"), "\(rig.trail())")
        rig.shutdown()
    }
}
