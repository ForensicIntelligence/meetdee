import DeeCore
import DeeRealtime
import DeeSelf
import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Tune 5 (brain): the tune-4 live findings (scratchpad/tune4-live.md; traces
/// Tools/voice-harness/Traces/20261010-003257, probes Reports/20261010-011423 / -011624),
/// each replayed on the real voice and session (BrainRig) with a real Cortex
/// (StandaloneHost, which does what DeeModel does with the Cortex's effects).
@MainActor
@Suite(.serialized) struct Tune5BrainTests {
    typealias T2 = Tune2BrainTests
    typealias T3 = Tune3BrainTests
    typealias T4 = Tune4BrainTests

    /// `seconds` of microphone in 20 ms frames (their voice if `talking`), the brain's
    /// loop running between frames (the gate is checked as it would be live).
    static func live(_ rig: BrainRig, _ seconds: Double, talking: Bool = false) async throws {
        let frames = Int((seconds / 0.02).rounded())
        let voice = Sig.harmonic(hz: 180, amplitude: 0.3, rate: BrainRig.rate, seconds: Double(frames) * 0.02)
        let n = Int(BrainRig.rate * 0.02)
        for k in 0..<frames {
            try rig.step(talking ? Array(voice[(k * n)..<((k + 1) * n)]) : nil)
            await rig.settle()
        }
    }

    // MARK: F1 — a question asked over her is answered

    /// Probe t4-probe-content-bargein q01 (app parity, 20261010-011423): "What's your
    /// favorite color?" over her dog reply. The brain asked for the answer at 19.44 and
    /// the hold ended with it (`bargedIn`); the app sensed `.bargeIn`, the Cortex said
    /// `.stopSpeaking`, `stop()` cancelled the answer at 19.62: silence (0 of 3 answered).
    /// Now the app senses `.bargeInAnswered`: the floor bookkeeping, no stop.
    @Test func aQuestionAskedOverHerIsAnswered() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await T3.sheIsTalking(rig, "So the dog ran all the way to the beach.")
        rig.push(Srv.responseDone("resp_1"))                              // written; still playing
        await T3.over(rig, "item_u2")
        rig.brain.injectHold(.paused(itemID: "item_u2"))
        T2.deltas(rig, "item_u2", "What's your favorite color?")
        rig.push(Srv.userTranscript("item_u2", "What's your favorite color?"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "the brain answers it: \(rig.trail())")
        let cancelsBefore = rig.count("response.cancel")
        // Its answer ends the voice's hold (19.44 live): the host is told.
        rig.brain.injectHold(.ended(itemIDs: ["item_u2"], byVoice: false))
        #expect(await rig.until { rig.host.bargeIns == 1 })
        try? await Task.sleep(for: .milliseconds(250))                    // past 19.62
        #expect(rig.host.stops == 0, "nothing stops her answer")
        #expect(rig.count("response.cancel") == cancelsBefore, "the answer is not cancelled: \(rig.trail())")
        #expect(rig.host.cortex.moment.ongoing.cutOff, "the barge-in is still sensed (cut off)")
        // The answer arrives and is hers to say.
        rig.reply("resp_2", "item_a2", ms: 600, text: "Ooh, a bright teal.")
        #expect(await rig.until { rig.host.replies.count == 2 }, "her answer reached the host")
        #expect(rig.count("response.cancel") == cancelsBefore)
        rig.shutdown()
    }

    /// The tune-4 app path, reproduced (the mutation the fix removes): sensing `.bargeIn`
    /// at that moment makes the Cortex stop her, and the stop cancels the answer.
    @Test func theOldBargeInPerceptCancelledTheAnswer() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await T3.sheIsTalking(rig)
        rig.push(Srv.responseDone("resp_1"))
        await T3.over(rig, "item_u2")
        rig.brain.injectHold(.paused(itemID: "item_u2"))
        rig.push(Srv.userTranscript("item_u2", "Are you awake?"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail())")
        rig.push(Srv.responseCreated("resp_2"))
        let cancelsBefore = rig.count("response.cancel")
        let fx = rig.host.sense(.bargeIn)
        #expect(fx.contains(.stopSpeaking), "`.bargeIn` still stops her (the voice's own barge-in)")
        for e in fx where e == .stopSpeaking { rig.host.stopSpeaking(hush: false) }
        #expect(await rig.until { rig.count("response.cancel") > cancelsBefore }, "the stop cancels the answer: \(rig.trail())")
        // And the answered percept never asks for that stop.
        #expect(!rig.host.sense(.bargeInAnswered).contains(.stopSpeaking))
        rig.shutdown()
    }

    /// A pure "Stop." over her still stops her, and nothing answers it.
    @Test func stopOverHerIsSilent() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await T3.sheIsTalking(rig)
        await T3.over(rig, "item_u2")
        rig.push(Srv.userTranscript("item_u2", "Stop."))
        #expect(await rig.until { rig.host.commands == [.stop] }, "\(rig.host.heardLog.map(\.text))")
        #expect(rig.host.stops == 1, "stopped as the app's stop(hush: true)")
        #expect(await rig.until { rig.count("response.cancel") >= 1 || rig.trail().contains("truncate:item_a1") }, "\(rig.trail())")
        try? await Task.sleep(for: .milliseconds(400))
        #expect(rig.responseCreates().count == 1, "nothing answers a stop: \(rig.trail())")
        #expect(rig.host.bargeIns == 0)
        rig.shutdown()
    }

    // MARK: F4 — "…the job I interviewed for." is complete

    /// t2-length-clean s02: held as "trailing" at 70.28 because it ends on "for", and
    /// answered only at 73.34 (4.67 s). A preposition stranded by a relative clause,
    /// closed with a period, ends the sentence.
    @Test func aStrandedPrepositionWithAPeriodIsComplete() {
        for t in ["I didn't get the job I interviewed for.", "That's the guy I talked to.", "It's the place I used to work at.",
                  "She's the person you were talking about.", "We found the house we looked at."] {
            #expect(TurnPolicy.unfinished(t) == nil, "\(t)")
        }
        // Still trailing: no relative clause, or no closing period.
        for t in ["We talked about", "We talked about.", "Yesterday I went to.", "I'm going to.", "So yesterday I went to the.",
                  "I didn't get the job I interviewed for", "It was a lot of"] {
            #expect(TurnPolicy.unfinished(t) != nil, "\(t)")
        }
    }

    /// The live replay: its settled words never take the held reply back.
    @Test func liveS02IsAnsweredAtTheWindow() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        try rig.quiet(0.6)
        try await T4.turn(rig, "item_u1", talk: 1.6, lag: 0.08)
        let end = rig.output.count - Int(0.08 * BrainRig.rate)
        T2.deltas(rig, "item_u1", "I didn't get the job I interviewed for.")
        T4.audio(rig, "resp_1", "item_a1", ms: 1200, text: "Ah, that really stings.")
        try await T4.stepUntil(rig, 1.6) { T4.released(rig) != nil }
        try rig.quiet(0.3)
        #expect(!rig.brain.trace.contains(.held("trailing")), "\(rig.brain.trace)")
        #expect(!rig.brain.trace.contains(.speculationDropped("taken back")))
        let first = try #require(T4.firstAudio(rig, from: end), "she answered")
        #expect(Double(first - end) / BrainRig.rate < 1.3, "not 4.67 s")
        rig.shutdown()
    }

    // MARK: F3 — never released just after they resumed

    /// t2-backchannel-fan15 l05 (tune 4 live): "I couldn't sleep last night." ended 37.08,
    /// commit 37.24, they went on at 37.67 ("I kept going over…"), the gate released at
    /// 37.82 (quiet 830 ms, the latched flag still false), the server's speech_started
    /// came at 38.00: 665 ms over them. Now EarCore's fast last voice time restarts the
    /// window and the release is re-checked `releaseRecheck` later: she never plays.
    /// `resume`: 0.59 s after the end (live), and 0.76 s — the onset lands just after the
    /// window's edge, where only the re-check can catch it.
    @Test(arguments: [0.59, 0.76])
    func liveL05ResumeJustBeforeTheReleaseHoldsHer(resume: Double) async throws {
        let rig = try await BrainRig()
        try await rig.start()
        try rig.quiet(0.6)
        try await T4.turn(rig, "item_u1", talk: 1.7, lag: 0.16)          // end 37.08, commit 37.24
        let start = rig.output.count
        T4.audio(rig, "resp_1", "item_a1", ms: 1500, text: "Oh no, what kept you up?")
        rig.push(Srv.userTranscript("item_u1", "I couldn't sleep last night."))
        try await Self.live(rig, resume - 0.16)                          // the gate runs each frame
        try await Self.live(rig, 1.0 - resume, talking: true)            // they go on, to 38.00
        rig.push(Srv.speechStarted("item_u2", ms: 2700))
        #expect(await rig.until { rig.brain.trace.contains(.speculationDropped("speech")) }, "\(rig.brain.trace)")
        try rig.talk(1.0)
        #expect(T4.peak(rig, from: start) < 0.05, "not a sample of her reply over them")
        #expect(!rig.brain.trace.contains { if case .speculationReleased = $0 { true } else { false } })
        rig.shutdown()
    }

    /// The re-check itself: a gate that passed once does not release until it passes
    /// again `releaseRecheck` later; a voice in between restarts it.
    @Test func theReleaseIsRecheckedOnce() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        try rig.quiet(0.6)
        try await T4.turn(rig, "item_u1", talk: 1.0, lag: 0.2)
        T4.audio(rig, "resp_1", "item_a1", ms: 900, text: "Sure.")
        // To just past the window: passed once, not released yet.
        try await T4.stepUntil(rig, 0.7) { false }
        #expect(T4.released(rig) == nil, "\(rig.brain.trace)")
        try await T4.stepUntil(rig, 0.5) { T4.released(rig) != nil }
        #expect(T4.released(rig) != nil)
        rig.shutdown()
    }

    // MARK: F2 — the release gate is not held by the room

    /// kitchen15 p20c / k08, tv15 p06c / k04 (tune 4 live: held 860–1,260 ms, end → audio
    /// 2.1–2.2 s): words that keep settling (a noisy transcript) no longer hold her to the
    /// old 1.6 s cap; at most `confirmMax` (1.0 s) after the commit.
    @Test func unsettledWordsHoldHerAtMostOneSecond() async throws {
        #expect(TurnPolicy.confirmMax <= 1.0)
        let rig = try await BrainRig()
        try await rig.start()
        try rig.quiet(0.6)
        try await T4.turn(rig, "item_u1", talk: 1.0, lag: 0.2)
        T4.audio(rig, "resp_1", "item_a1", ms: 900, text: "Sure.")
        var waited = 0.0
        let words = ["Could", " you", " tell", " me", " a", " little", " more", " about", " the", " moon", " tonight"]
        var i = 0
        while T4.released(rig) == nil, waited < 2.0 {
            if i < words.count { T2.delta(rig, "item_u1", words[i]); i += 1 }
            try rig.step(); try rig.step(); try rig.step(); try rig.step(); try rig.step()
            await rig.settle()
            waited += 0.1
        }
        let r = try #require(T4.released(rig), "\(rig.brain.trace)")
        #expect(waited <= TurnPolicy.confirmMax + TurnPolicy.releaseRecheck + 0.2, "\(waited) s after the commit; \(r)")
        #expect(waited < 1.6 - 0.15, "under the tune-4 cap")
        rig.shutdown()
    }

    /// The commit and the final, complete words agree: a stray delta still settling never
    /// holds her past the window.
    @Test func finalCompleteWordsReleaseAtTheWindow() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        try rig.quiet(0.6)
        try await T4.turn(rig, "item_u1", talk: 1.0, lag: 0.2)
        T4.audio(rig, "resp_1", "item_a1", ms: 900, text: "Blue.")
        rig.push(Srv.userTranscript("item_u1", "What's your favorite color?"))
        var waited = 0.0
        while T4.released(rig) == nil, waited < 2.0 {
            T2.delta(rig, "item_u1", " x")                                 // a late, stray delta
            try rig.step(); try rig.step(); try rig.step(); try rig.step(); try rig.step()
            await rig.settle()
            waited += 0.1
        }
        let r = try #require(T4.released(rig))
        #expect(!r.overdue && waited <= TurnPolicy.confirmWindow + TurnPolicy.releaseRecheck + 0.2, "\(waited) s; \(r)")
        rig.shutdown()
    }

    // MARK: Unfinished-words aim (DNA ask; fan15 l05's reply)

    /// l05's released reply: "I heard “I couldn’t sleep last…” and I’m curious what
    /// happened next. Want to finish the sentence?" — never heard now: taken back, and
    /// the turn waited out in silence (decision); nothing follows → answered with a note.
    @Test func theUnfinishedWordsAimIsNeverSpoken() async throws {
        #expect(TurnPolicy.isUnfinishedAim("I heard “I couldn’t sleep last…” and I’m curious what happened next."))
        #expect(TurnPolicy.isUnfinishedAim("Want to finish the sentence?"))
        for ok in ["Oh no, what kept you up?", "I heard that!", "So what happened next?", "Sounds like a long night…"] {
            #expect(!TurnPolicy.isUnfinishedAim(ok), "\(ok)")
        }
        let rig = try await BrainRig(tune: { $0.trailingWait = 0.4 })
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        T2.assistantDelta(rig, "resp_1", "item_a1", "I heard “I couldn’t sleep last…” and I’m curious")
        #expect(await rig.until { rig.brain.trace.contains(.unfinishedAim(takenBack: true)) }, "\(rig.brain.trace)")
        #expect(await rig.until { rig.count("response.cancel") >= 1 }, "\(rig.trail())")
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        #expect(rig.host.said.isEmpty)
        // Nothing follows: answered once, told not to point it out.
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail())")
        let dnaID = try #require(rig.trail().last { $0.hasPrefix("dna:") }).dropFirst(4)
        #expect(rig.dnaText(String(dnaID))?.contains("never quote their words back or ask them to finish") == true)
        // The same aim again: taken back, and she stays quiet.
        rig.push(Srv.responseCreated("resp_2"), Srv.messageAdded("resp_2", "item_a2"), Srv.itemAdded("item_a2", role: "assistant"))
        T2.assistantDelta(rig, "resp_2", "item_a2", "Want to finish the sentence?")
        #expect(await rig.until { rig.brain.trace.filter { $0 == .unfinishedAim(takenBack: true) }.count == 2 })
        rig.push(Srv.responseDone("resp_2", status: "cancelled"))
        try? await Task.sleep(for: .milliseconds(700))
        #expect(rig.responseCreates().count == 2, "silence: \(rig.trail())")
        rig.shutdown()
    }

    // MARK: F6 — continuers over her

    /// kitchen15 c05 / echo20 c05: "Keep going, I'm listening." split by server_vad and
    /// misheard "Sheep going." / "She's not going."; the brain answered it (the hold
    /// ended, she was flushed) and then answered "I'm listening." as a turn.
    @Test(arguments: ["Sheep going.", "I'm listening."])
    func aMisheardContinuerOverHerIsNotAnswered(_ words: String) async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await T3.sheIsTalking(rig)
        await T3.over(rig, "item_u2")
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "waitForPartial")) })
        T2.deltas(rig, "item_u2", words)
        rig.push(Srv.userTranscript("item_u2", words))
        #expect(await rig.until { rig.host.heardLog.count == 1 })
        try? await Task.sleep(for: .milliseconds(300))
        #expect(rig.responseCreates().count == 1, "\(words): not answered: \(rig.trail())")
        #expect(rig.count("response.cancel") == 0, "her voice goes on: \(rig.trail()) \(rig.brain.trace)")
        rig.shutdown()
    }

    // MARK: Jokes (F7)

    /// j01 / k06: the reply after a riddle's set-up or a knock-knock's name carries
    /// "laugh first".
    @Test func thePunchlineTurnIsMarked() {
        #expect(TurnPolicy.isPunchlineTurn(previous: "Why did the scarecrow win an award?", beforeThat: "Want to hear a joke?"))
        #expect(TurnPolicy.isPunchlineTurn(previous: "Lettuce.", beforeThat: "Knock knock."))
        #expect(!TurnPolicy.isPunchlineTurn(previous: "Knock knock.", beforeThat: nil))
        #expect(!TurnPolicy.isPunchlineTurn(previous: "Why did the dinosaurs die out?", beforeThat: nil))
        #expect(!TurnPolicy.isPunchlineTurn(previous: "I had pasta.", beforeThat: "How was lunch?"))
    }

    @Test func aKnockKnockPunchlineGetsTheLaughNote() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        for (i, line) in ["Knock knock.", "Lettuce."].enumerated() {
            rig.utterance("item_k\(i)")
            #expect(await rig.until { rig.responseCreates().count == i + 1 })
            rig.push(Srv.userTranscript("item_k\(i)", line))
            #expect(await rig.until { rig.host.heardLog.count == i + 1 })
            rig.reply("resp_k\(i)", "item_ak\(i)", ms: 200, text: i == 0 ? "Who's there?" : "Lettuce who?")
            try rig.quiet(0.8)
            await rig.settle()
        }
        rig.utterance("item_k2")
        #expect(await rig.until { rig.responseCreates().count == 3 })
        let dnaID = try #require(rig.trail().last { $0.hasPrefix("dna:") }).dropFirst(4)
        #expect(rig.dnaText(String(dnaID))?.contains("laugh first") == true)
        rig.shutdown()
    }
}
