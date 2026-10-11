import DeeCore
import DeeRealtime
import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Tune 11 (brain): the tune-10 live findings (scratchpad/tune10-live.md; reports
/// Tools/voice-harness/Reports/20261010-130349, -134832 solo; traces Traces/<same>),
/// each replayed at the live shape on the real voice and session (BrainRig).
@MainActor
@Suite(.serialized) struct Tune11BrainTests {
    typealias T2 = Tune2BrainTests
    typealias T4 = Tune4BrainTests

    // MARK: T10-1 — held turns: the ASR variants of a trailing "and"

    /// Every way the server's ASR wrote "…call my mom and" (t03 / t04) in the tune 7–10
    /// main runs, solos and A/B (20261010-063215 … -134832): "Ann", "Anne" (echo30 t03,
    /// tune 10), "and", ", and", ", then" (echo30 t04 tune 10, kitchen15 t04 tune 8),
    /// ", man" (clean t04, A/B). A finished sentence ending in a name or a wrap-up
    /// "then" / "man" is still finished.
    @Test func everyLiveVariantOfTheTrailingAndIsHeld() {
        for t in ["I was going to call my mom Anne.", "I was going to call my mom Ann.", "Was going to call my mom Ann.",
                  "To call my mom Ann.", "I was going to call my mom and.", "Tomorrow I'm going to call my mom, and.",
                  "Tomorrow I'm going to call my mom, then.", "Tomorrow I'm going to call my mom then.",
                  "Tomorrow I'm going to call my mom, man."] {
            #expect(TurnPolicy.unfinished(t) == .trailing, "\(t)")
        }
        for t in ["My aunt is Anne.", "I'm going with Anne.", "Her name is Anne.", "See you then.", "I'll call her then.",
                  "Okay, I'll ask my mom then.", "Fine, I guess I'll ask my dad then.", "Thanks, man.", "That was my plan then.",
                  "Tomorrow I'm going to call my mom.", "Bye then, see you later."] {
            #expect(TurnPolicy.unfinished(t) == nil, "\(t)")
        }
    }

    /// fillers-echo30 t03 (72.20–72.94): the deltas said "…call my mom Anne." at 72.52;
    /// `heard(verdict: "answer")` 72.74 and her reply was released 72.94. Now the unheard
    /// fast reply is taken back from the deltas and the continuation answers both.
    @Test func liveEcho30T03AnneIsHeldFromTheDeltas() async throws {
        let rig = try await BrainRig(tune: { $0.trailingWait = 1.0 })
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"))
        T2.deltas(rig, "item_u1", "I was going to call my mom Anne.")
        #expect(await rig.until { rig.brain.trace.contains(.held("trailing")) }, "\(rig.brain.trace)")
        #expect(await rig.until { rig.count("response.cancel") >= 1 }, "taken back before it was heard")
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        rig.push(Srv.userTranscript("item_u1", "I was going to call my mom Anne."))
        await rig.settle()
        rig.utterance("item_u2", startMs: 2500, endMs: 3500)
        #expect(await rig.until { rig.responseCreates().count == 2 }, "the continuation is answered")
        rig.push(Srv.responseCreated("resp_2"), Srv.responseDone("resp_2"))
        try? await Task.sleep(for: .milliseconds(1300))
        #expect(rig.responseCreates().count == 2, "the held turn was answered with the rest")
        rig.shutdown()
    }

    // MARK: T10-1 — the quiet release never races the words

    /// fillers-echo10 t03 (`Traces/20261010-130349/t2-fillers-echo10.jsonl` 70.2–71.3):
    /// commit 70.30, her audio in 70.88, `speculationReleased(quietMs: 930)` at 71.000 —
    /// and the first delta of "Was going to call my mom Ann." at 71.008 (transcription lag
    /// 0.70 s against 0.23–0.40 s typical). Live she answered across the continuation.
    /// With no words yet the release waits for them (bounded), and the deltas take it back.
    @Test func liveEcho10T03TheReleaseWaitsForLateWords() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        try rig.quiet(0.6)
        try await T4.turn(rig, "item_u1", talk: 1.6, lag: 0.23)
        let start = rig.output.count
        #expect(await rig.until { rig.responseCreates().count == 1 })
        try rig.quiet(0.35)                                                   // 70.88: her audio is in
        T4.audio(rig, "resp_1", "item_a1", ms: 1200, text: "Oh, that sounds like a lovely plan.")
        await rig.settle()
        // To 0.98 s after their end: the window and its re-check have passed (live 0.93).
        for _ in 0..<20 where T4.released(rig) == nil {
            try rig.step()
            await rig.settle()
        }
        #expect(T4.released(rig) == nil, "released before any words: \(rig.brain.trace)")
        // 8 ms later: the words, as the live burst sent them; the microphone clock waits
        // while they settle (the brain's settle runs on the wall clock).
        T2.deltas(rig, "item_u1", "Was going to call my mom Ann.")
        #expect(await rig.until { rig.brain.trace.contains(.held("trailing")) }, "\(rig.brain.trace)")
        #expect(await rig.until { rig.brain.trace.contains(.speculationDropped("taken back")) }, "\(rig.brain.trace)")
        try rig.quiet(0.6)
        await rig.settle()
        #expect(T4.peak(rig, from: start) < 0.05, "not a sample of her reply was heard")
        #expect(T4.released(rig) == nil)
        rig.shutdown()
    }

    /// The wait is bounded: a turn whose words never come (a failed transcription) plays
    /// at most `wordsWait` after the gate would have let it go, never at the 1.0 s cap.
    @Test func aTurnWithNoWordsWaitsAtMostTheWordsWait() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        try rig.quiet(0.6)
        try await T4.turn(rig, "item_u1", talk: 1.0, lag: 0.23)
        try rig.quiet(0.35)
        T4.audio(rig, "resp_1", "item_a1", ms: 1200, text: "Blue, like a little sky.")
        try await T4.stepUntil(rig, 1.5) { T4.released(rig) != nil }
        let r = try #require(T4.released(rig), "\(rig.brain.trace)")
        let window = Int((TurnPolicy.confirmWindow + TurnPolicy.releaseRecheck) * 1000)
        #expect(!r.overdue && r.quietMs >= window + 200 && r.quietMs <= window + Int(TurnPolicy.wordsWait * 1000) + 60, "\(r)")
        #expect(TurnPolicy.wordsWait == 0.25)
        rig.shutdown()
    }

    /// The same race one step later: the words came, and settle in the very tick the gate
    /// passes. Their check runs first: an unfinished turn's reply is taken back, never
    /// released and kept (released first, it is no longer "unheard").
    @Test func wordsThatSettleInTheReleaseTickAreCheckedFirst() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        try rig.quiet(0.6)
        try await T4.turn(rig, "item_u1", talk: 1.6, lag: 0.23)
        let start = rig.output.count
        #expect(await rig.until { rig.responseCreates().count == 1 })
        try rig.quiet(0.35)
        T4.audio(rig, "resp_1", "item_a1", ms: 1200, text: "Oh, that sounds like a lovely plan.")
        await rig.settle()
        try rig.quiet(0.26)                                                   // 0.84 s after their end
        T2.deltas(rig, "item_u1", "Was going to call my mom Ann.")
        try rig.quiet(0.14)                                                   // 0.98: only the settle holds her
        #expect(T4.released(rig) == nil, "\(rig.brain.trace)")
        #expect(await rig.until { rig.brain.trace.contains(.held("trailing")) }, "\(rig.brain.trace)")
        try rig.quiet(0.6)
        await rig.settle()
        #expect(rig.brain.trace.contains(.speculationDropped("taken back")), "\(rig.brain.trace)")
        #expect(T4.released(rig) == nil, "\(rig.brain.trace)")
        #expect(T4.peak(rig, from: start) < 0.05, "not a sample of her reply was heard")
        rig.shutdown()
    }

    // MARK: T10-4 — latency: a turn begun just after her voice

    /// latency-clean q07 (`Traces/20261010-130349/t2-latency-clean.jsonl` 62.7–65.9): they
    /// began 0.18 s after her voice ended (inside `commandWindow`: `waitForPartial`), the
    /// deltas "Is it going to rain tomorrow?" came 65.55–65.57 and the reply was asked
    /// for only once they settled (65.74; overhead 0.42 s). Six turns of the run had this
    /// shape. Her voice is silent: the first words that cannot be a backchannel decide at
    /// once, as over her voice (the reply is gated like any).
    @Test func liveLatencyCleanQ07ATurnJustAfterHerVoiceDecidesOnItsEarlyWords() async throws {
        let rig = try await BrainRig(tune: { $0.partialSettle = 3 })
        try await rig.start()
        rig.brain.inject(.itemPlayed(itemID: "item_a0", playedMs: 2400, cut: false))   // her voice just ended
        rig.utterance("item_u1")
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "waitForPartial")) }, "\(rig.brain.trace)")
        T2.deltas(rig, "item_u1", "Is it going to rain tomorrow?")
        #expect(await rig.until(0.5) { rig.brain.trace.contains(.earlyWords) }, "\(rig.brain.trace)")
        #expect(await rig.until { rig.responseCreates().count == 1 }, "\(rig.trail())")
        rig.shutdown()
    }

    /// A backchannel just after her voice still never decides early (its settled words do).
    @Test func aBackchannelJustAfterHerVoiceIsNotDecidedEarly() async throws {
        let rig = try await BrainRig(tune: { $0.partialSettle = 3 })
        try await rig.start()
        rig.brain.inject(.itemPlayed(itemID: "item_a0", playedMs: 2400, cut: false))
        rig.utterance("item_u1")
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "waitForPartial")) }, "\(rig.brain.trace)")
        T2.deltas(rig, "item_u1", "Keep going, I'm listening.")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!rig.brain.trace.contains(.earlyWords), "\(rig.brain.trace)")
        #expect(rig.responseCreates().isEmpty)
        rig.shutdown()
    }
}
