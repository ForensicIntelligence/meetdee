import DeeCore
import DeeRealtime
import DeeSelf
import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Tune 8 (brain): the tune-7 live findings (scratchpad/tune7-live.md; report
/// Tools/voice-harness/Reports/20261010-063215, traces Traces/20261010-063215), each
/// replayed on the real voice and session (BrainRig) at the live shapes.
@MainActor
@Suite(.serialized) struct Tune8BrainTests {
    typealias T2 = Tune2BrainTests
    typealias T3 = Tune3BrainTests
    typealias T5 = Tune5BrainTests
    typealias T7 = Tune7BrainTests

    // MARK: T7-1 — one misheard-fragment rule; a question over Dee is answered

    /// The brain's fragment rule is the voice's (`Backchannel.isMisheardFragment`), word for word.
    @Test func theBrainUsesTheVoicesFragmentRule() {
        for t in ["Too late.", "Big deal.", "Put going.", "Grand.", "She.", "Done.", "Going on.", "Thank you.", "I see.",
                  "Stop.", "Hang on.", "Goodbye.", "Who made", "5.", "Me too.", "Oh nice.", "I'm listen."] {
            #expect(TurnPolicy.isMisheardFragment(t) == Backchannel.isMisheardFragment(t), "\(t)")
        }
        #expect(!TurnPolicy.isMisheardFragment("Too late."))
        #expect(!TurnPolicy.isMisheardFragment("Big deal."))
    }

    /// t2-interrupt-fan15 q08 (19.92–21.61): "Who made you?" said over Dee came back as
    /// "Too late." (quick commit 20.88, partials 20.99, the server's empty tail committed
    /// 21.08). The brain's own fragment rule took it for a backchannel (`continued` +
    /// `resumed-brain` 21.18); the final words (21.35, verdict "answer") were then let go:
    /// no `response.create`, Dee talked on to Dee's sentence cap. Now it is their turn.
    @Test func liveFan15Q08TooLateOverHerIsAnswered() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await T7.overHer(rig, "item_q")
        T2.delta(rig, "item_q", "Too")
        T2.delta(rig, "item_q", " late")
        T2.delta(rig, "item_q", ".")
        rig.push(Srv.speechStopped("item_tail", ms: 4100), Srv.committed("item_tail"))   // no speech start: the tail
        #expect(await rig.until { rig.brain.trace.contains(.tailIgnored) }, "\(rig.brain.trace)")
        #expect(await rig.until { rig.responseCreates().count == 2 }, "answered: \(rig.trail()) \(rig.brain.trace)")
        rig.push(Srv.userTranscript("item_q", "Too late."))
        #expect(await rig.until { rig.host.heardLog.contains { $0.text == "Too late." } })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.responseCreates().count == 2, "exactly one answer: \(rig.trail())")
        #expect(T7.backchannels(rig).isEmpty, "\(rig.brain.trace)")
        rig.shutdown()
    }

    /// The 21.36 half: words first taken for "keep going" (Dee was cut, so a carry-on was
    /// asked for) whose full words are a question. The carry-on answers nothing: before,
    /// the "answer" verdict found the item `requested` and settled it — the question was
    /// never answered. Now the carry-on is taken back unheard and the turn gets one answer.
    @Test func aCarryOnIsNoAnswerWhenTheFullWordsAreAQuestion() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"))
        #expect(await rig.until { rig.brain.trace.contains(.responseStarted(kind: "reply")) })
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 0, text: "So the volcano went whoosh."))
        await rig.settle()
        rig.push(Srv.speechStarted("item_u2", ms: 3000))
        await rig.settle()
        rig.brain.inject(.itemPlayed(itemID: "item_a1", playedMs: 900, cut: true))      // the barge-in
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        rig.push(Srv.speechStopped("item_u2", ms: 4200), Srv.committed("item_u2"))
        T2.delta(rig, "item_u2", "Yeah")
        T2.delta(rig, "item_u2", ".")
        #expect(await rig.until { rig.brain.trace.contains(.backchannel("resumed")) }, "\(rig.brain.trace)")
        #expect(await rig.until { rig.responseCreates().count == 2 })
        rig.push(Srv.responseCreated("resp_2"))                              // the carry-on, no audio yet
        await rig.settle()
        let cancels = rig.count("response.cancel")
        rig.push(Srv.userTranscript("item_u2", "Yeah. Who made you?"))
        #expect(await rig.until { rig.count("response.cancel") > cancels || rig.brain.trace.contains(.speculationDropped("taken back")) },
                "the unheard carry-on is taken back: \(rig.trail()) \(rig.brain.trace)")
        #expect(await rig.until { rig.brain.trace.filter { if case .dnaSent = $0 { true } else { false } }.count == 3 },
                "the answer is asked for: \(rig.brain.trace)")
        rig.push(Srv.responseDone("resp_2", status: "cancelled"))
        #expect(await rig.until { rig.responseCreates().count == 3 }, "the question is answered: \(rig.trail()) \(rig.brain.trace)")
        let dnaID = try #require(rig.trail().last { $0.hasPrefix("dna:") }).dropFirst(4)
        let dna = try #require(rig.dnaText(String(dnaID)))
        #expect(!dna.contains("carry on from where you stopped"), "an answer, not a carry-on")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.responseCreates().count == 3, "exactly one answer")
        rig.shutdown()
    }

    // MARK: T7-2 — continuer endings never decide early; a cut-off continuer is "go on"

    @Test func continuerEndingsAndCutOffContinuers() {
        for t in ["Sheupr and going", "Sheupr and going.", "I'm listen", "Keep it on", "Go right ahead", "Uh mm-hmm"] {
            #expect(TurnPolicy.endsLikeContinuer(t), "\(t)")
        }
        for t in ["Are you awake", "Who made you", "What did you do today", "Is it going?"] {
            #expect(!TurnPolicy.endsLikeContinuer(t), "\(t)")
        }
        // The one rule (the voice's) takes the live misreads as "go on", never a turn.
        for t in ["I'm listen.", "Sheupr and going."] { #expect(TurnPolicy.isMisheardFragment(t), "\(t)") }
        for t in ["Tell me.", "I'm hungry.", "Too late.", "I'm lis?"] { #expect(!TurnPolicy.isMisheardFragment(t), "\(t)") }
    }

    /// Longer than the fragment rule's three words, ending like "keep going": the brain's
    /// own early-words guard waits for the full words.
    @Test func fourWordsEndingLikeAContinuerNeverDecideEarly() async throws {
        let rig = try await BrainRig(tune: { $0.partialSettle = 0.6 })
        try await rig.start()
        await T7.overHer(rig, "item_k")
        T2.delta(rig, "item_k", "Sheep up and going")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!rig.brain.trace.contains(.earlyWords), "\(rig.brain.trace)")
        rig.shutdown()
    }

    /// t2-backchannel-echo20 c05 (58.09–60.42): "Keep going, I'm listening." under loud echo
    /// came back as "Sheupr and going." — three words, so its partial decided at once
    /// (`earlyWords` 60.16): Dee's reply was cut at 2385 ms and an answer asked for. Words
    /// that end the way a continuer does wait for the full words now.
    @Test func liveEcho20C05SheuprAndGoingNeverDecidesEarly() async throws {
        let rig = try await BrainRig(tune: { $0.partialSettle = 0.6 })
        try await rig.start()
        await T7.overHer(rig, "item_k")
        for d in ["She", "u", "pr", " and", " going", "."] { T2.delta(rig, "item_k", d) }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!rig.brain.trace.contains(.earlyWords), "\(rig.brain.trace)")
        #expect(rig.responseCreates().count == 1, "\(rig.trail())")
        #expect(!rig.trail().contains("truncate:item_a1"), "Dee's reply is not cut: \(rig.trail())")
        rig.shutdown()
    }

    /// A real three-word turn over Dee still decides at its first words (tune 6 speed).
    @Test func threeWordsThatAreATurnStillDecideAtOnce() async throws {
        let rig = try await BrainRig(tune: { $0.partialSettle = 0.6 })
        try await rig.start()
        await T7.overHer(rig, "item_q")
        T2.delta(rig, "item_q", "What did you")
        #expect(await rig.until(0.4) { rig.brain.trace.contains(.earlyWords) }, "\(rig.brain.trace)")
        rig.shutdown()
    }

    /// t2-backchannel-fan15 c05 (49.16–52.03): "Keep going, I'm listening." came back as
    /// "Keep going." (Dee went on: `continued`, go-on deferred) and "I'm listen." — quick
    /// committed, resumed, then its full words were answered (`heard(answer)` 51.90): Dee's
    /// reply cut at 2065 ms for "Aww, sleepiness is sneaky…". "I'm listen." is "I'm
    /// listening." cut off: Dee goes on.
    @Test func liveFan15C05ImListenDoesNotStopHer() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await T7.overHer(rig, "item_g")
        T2.deltas(rig, "item_g", "Keep going.")
        #expect(await rig.until { !T7.backchannels(rig).isEmpty }, "\(rig.brain.trace)")
        rig.push(Srv.userTranscript("item_g", "Keep going."))
        #expect(await rig.until { rig.host.heardLog.contains { $0.text == "Keep going." } })
        await T3.over(rig, "item_l")
        T2.delta(rig, "item_l", "I'm")
        T2.delta(rig, "item_l", " listen")
        T2.delta(rig, "item_l", ".")
        rig.push(Srv.userTranscript("item_l", "I'm listen."))
        #expect(await rig.until { rig.host.heardLog.contains { $0.text == "I'm listen." } })
        try await T5.live(rig, 0.8)
        T7.sheWentOn(rig, "I'm listen.")
        rig.shutdown()
    }

    // MARK: T7-3 — the answer to a new turn is never thrown away for a carry-on

    /// t2-interrupt-echo20 q02 (23.64–27.64): a phantom "Yeah." (Dee's echo, AEC off) over Dee's
    /// reply was a backchannel Dee talked on through (`continued`). "Are you awake?" then
    /// decided at its first words (`earlyWords` 26.00) and the answer's cut of Dee's reply
    /// counted as "cut anyway after keep going": a carry-on for "Yeah." was asked for,
    /// refused (`responseInFlight`), and retried when the answer completed (26.90) —
    /// re-arming the gate threw the held 3.9 s answer away ("rearmed"): 0.9 s lost. A cut
    /// for a newer turn brings no carry-on; the held answer is the one Dee plays.
    @Test func liveEcho20Q02TheAnswerIsNotThrownAwayForACarryOn() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await T3.sheIsTalking(rig, "That's a tiny little mental replay loop, isn't it?")
        rig.push(Srv.responseDone("resp_1"))                               // written; still playing
        // The phantom "Yeah." over Dee: Dee talks on.
        await T3.over(rig, "item_y")
        T2.deltas(rig, "item_y", "Yeah.")
        #expect(await rig.until { rig.brain.trace.contains(.backchannel("continued")) }, "\(rig.brain.trace)")
        rig.push(Srv.userTranscript("item_y", "Yeah."))
        #expect(await rig.until { rig.host.heardLog.contains { $0.text == "Yeah." } })
        // "Are you awake?" over Dee: held by the voice, decided at its first words.
        rig.push(Srv.speechStarted("item_q", ms: 5000))
        await rig.settle()
        rig.brain.injectHold(.paused(itemID: "item_q"))
        rig.push(Srv.speechStopped("item_q", ms: 6100), Srv.committed("item_q"))
        T2.deltas(rig, "item_q", "Are you awake?")
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail()) \(rig.brain.trace)")
        rig.brain.inject(.itemPlayed(itemID: "item_a1", playedMs: 2965, cut: true))    // the answer's cut of Dee's reply
        rig.push(Srv.userTranscript("item_q", "Are you awake?"))
        #expect(await rig.until { rig.host.heardLog.contains { $0.text == "Are you awake?" } })
        rig.push(Srv.responseCreated("resp_2"), Srv.messageAdded("resp_2", "item_a2"))
        for _ in 0..<5 { rig.push(Srv.audio("resp_2", "item_a2", Sig.pcm(ms: 100))) }
        rig.push(Srv.audioDone("resp_2", "item_a2"), Srv.responseDone("resp_2"))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(rig.responseCreates().count == 2, "no carry-on, no retry: \(rig.trail()) \(rig.brain.trace)")
        #expect(!rig.brain.trace.contains(.backchannel("resumed")), "\(rig.brain.trace)")
        #expect(!rig.brain.trace.contains { if case .dnaSent(_, "retry", _, _, _, _, _, _, _) = $0 { true } else { false } },
                "\(rig.brain.trace)")
        rig.shutdown()
    }

    // MARK: T7-4 / T7-6 — their question is answered, never said back

    @Test func herSentenceThatOnlySaysTheirQuestionBack() {
        #expect(TurnPolicy.echoesTheirWords("Hi Alex, who made you?", theirs: "Who made you?"))
        #expect(TurnPolicy.echoesTheirWords("Hi Alex, can you hear me okay?", theirs: "Can you hear me okay?"))
        #expect(TurnPolicy.echoesTheirWords("Hi Alex, how was your day?", theirs: "Hi Dee. How was your day?"))
        #expect(TurnPolicy.echoesTheirWords("Who made you?", theirs: "Hey Dee, who made you?"))
        // Not an echo: a real answer, the due follow-up, play-along, a one-word turn.
        #expect(!TurnPolicy.echoesTheirWords("Hi Alex, how did your exam go?", theirs: "Hi Dee. How was your day?"))
        #expect(!TurnPolicy.echoesTheirWords("A team of tinkerers made me.", theirs: "Who made you?"))
        #expect(!TurnPolicy.echoesTheirWords("Who's there?", theirs: "Knock knock."))
        #expect(!TurnPolicy.echoesTheirWords("Lettuce who?", theirs: "Lettuce."))
        #expect(!TurnPolicy.echoesTheirWords("Hi Priya, how are you today?", theirs: "Hi Dee."))
        #expect(!TurnPolicy.echoesTheirWords("I love you too.", theirs: "I love you too."), "not a question")
        #expect(!TurnPolicy.echoesTheirWords("Oh, I love you too!", theirs: "Love you too."))
        #expect(!TurnPolicy.echoesTheirWords("Oh wow, you really asked me who made you, and the answer is a secret?", theirs: "Who made you?"))
        // "I heard you say" is a preamble (first sentence) and narration (later).
        #expect(TurnPolicy.isMetaPreamble("Oh, I heard you say yours isn't."))
        #expect(TurnPolicy.metaSentence(in: "Okay. I heard you say it's late.") == 1)
    }

    /// fallback-429-long q08 "Who made you?" → "Hi Alex, who made you?" (Dee's whole reply,
    /// judge 2). Dee's first sentence only said their question back: taken back unheard and
    /// asked again once, to answer it first.
    @Test func liveFallback429LongQ08TheirQuestionIsNotSaidBack() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.userTranscript("item_u1", "Who made you?"))
        #expect(await rig.until { rig.host.heardLog.contains { $0.text == "Who made you?" } })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        T2.assistantDelta(rig, "resp_1", "item_a1", "Hi Alex, who made you?")
        #expect(await rig.until { rig.brain.trace.contains(.echoedQuestion(takenBack: true)) }, "\(rig.brain.trace)")
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail())")
        let dnaID = try #require(rig.trail().last { $0.hasPrefix("dna:") }).dropFirst(4)
        #expect(rig.dnaText(String(dnaID))?.contains("your very first sentence answers it plainly") == true)
        #expect(rig.host.said.isEmpty)
        rig.shutdown()
    }

    /// The due follow-up is not an echo: "Hi Alex, how did your exam go?" to "Hi Dee. How
    /// was your day?" plays.
    @Test func theFollowUpIsNotTakenForAnEcho() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.userTranscript("item_u1", "Hi Dee. How was your day?"))
        #expect(await rig.until { rig.host.heardLog.count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        T2.assistantDelta(rig, "resp_1", "item_a1", "Hi Alex, how did your exam go? ")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!rig.brain.trace.contains { if case .echoedQuestion = $0 { true } else { false } }, "\(rig.brain.trace)")
        #expect(rig.count("response.cancel") == 0)
        rig.shutdown()
    }

    /// interrupt-kitchen15 q06 "What did you do today?" asked over Dee → "Ooh, I want to
    /// hear what happened with your volcanoes today! As for me, …". The answer to a
    /// question asked over Dee carries the answer-first note.
    @Test func aQuestionOverHerIsAnsweredFirst() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await T7.overHer(rig, "item_q")
        T2.deltas(rig, "item_q", "What did you do today?")
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail())")
        let dnaID = try #require(rig.trail().last { $0.hasPrefix("dna:") }).dropFirst(4)
        #expect(rig.dnaText(String(dnaID))?.contains("your very first sentence answers it plainly") == true)
        rig.shutdown()
    }

    /// A plain turn that is not a question gets no such note.
    @Test func aStatementOverHerGetsNoAnswerFirstNote() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await T7.overHer(rig, "item_s")
        T2.deltas(rig, "item_s", "My dog ate my homework.")
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail())")
        let dnaID = try #require(rig.trail().last { $0.hasPrefix("dna:") }).dropFirst(4)
        #expect(rig.dnaText(String(dnaID))?.contains("your very first sentence answers it plainly") == false)
        rig.shutdown()
    }
}
