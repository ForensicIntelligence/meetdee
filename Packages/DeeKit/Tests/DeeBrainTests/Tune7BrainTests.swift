import DeeCore
import DeeRealtime
import DeeSelf
import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Tune 7 (brain): the tune-6 live findings (scratchpad/tune6-live.md; report
/// Tools/voice-harness/Reports/20261010-035320, traces Traces/20261010-035320), each
/// replayed on the real voice and session (BrainRig) at the live shapes.
@MainActor
@Suite(.serialized) struct Tune7BrainTests {
    typealias T2 = Tune2BrainTests
    typealias T3 = Tune3BrainTests
    typealias T4 = Tune4BrainTests
    typealias T5 = Tune5BrainTests

    static func backchannels(_ rig: BrainRig) -> [String] {
        rig.brain.trace.compactMap { if case .backchannel(let why) = $0 { why } else { nil } }
    }

    /// Her reply is playing (`item_a1`) and `item` is said over it; the voice pauses her
    /// for it (`.paused`) and commits it early, as live.
    static func overHer(_ rig: BrainRig, _ item: String) async {
        await T3.sheIsTalking(rig, "That's a tiny little mental replay loop, isn't it?")
        rig.push(Srv.responseDone("resp_1"))                               // written; still playing
        await T3.over(rig, item)
        rig.brain.injectHold(.paused(itemID: item))
        _ = await rig.until { rig.brain.trace.contains(.committed(plan: "waitForPartial")) }
    }

    /// Nothing of hers was cut and nothing was asked for since her reply.
    static func sheWentOn(_ rig: BrainRig, _ label: String) {
        #expect(rig.responseCreates().count == 1, "\(label): never answered: \(rig.trail()) \(rig.brain.trace)")
        #expect(!rig.trail().contains("truncate:item_a1"), "\(label): her reply is not cut: \(rig.trail())")
        #expect(!rig.brain.trace.contains(.earlyWords), "\(label): \(rig.brain.trace)")
    }

    // MARK: T6-3 — misheard short fragments while she talks are backchannels

    @Test func misheardFragmentsAreBackchannelsButStopsAndQuestionsAreNot() {
        for t in ["Put going.", "Grand.", "She.", "Done.", "MMHN.", "Sheep.", "Going on.", "Thank you.", "I see.", "Oh nice.",
                  "Um, grand."] {
            #expect(TurnPolicy.isMisheardFragment(t) || TurnPolicy.isBackchannel(t), "\(t)")
        }
        for t in ["Stop.", "Wait.", "No.", "Hold on.", "Hang on.", "Be quiet.", "Shut up.", "Why?", "What?", "Really? Why?",
                  "Who made", "Are you", "Dee.", "D.", "Hey, Dee.", "I'm bored.", "Love you.", "5.", "Not now.",
                  "Are you awake?", "Who made you?", "Tell me a story.", "Never mind.", "Goodbye."] {
            #expect(!TurnPolicy.isMisheardFragment(t), "\(t)")
        }
    }

    /// t2-backchannel-echo10 c05 (62.72–65.31): "Keep going, I'm listening." over her came
    /// back as "Put going." + "I'm listening.". Its partial "Put going" decided the turn at
    /// once (`earlyWords` 64.44): the answer was asked for and her reply truncated at
    /// 2345 ms; "I'm listening." then only brought a carry-on. Now she goes on.
    @Test func liveEcho10C05PutGoingDoesNotStopHer() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await Self.overHer(rig, "item_k")
        T2.delta(rig, "item_k", "Put")
        T2.delta(rig, "item_k", " going")
        try? await Task.sleep(for: .milliseconds(80))
        #expect(!rig.brain.trace.contains(.earlyWords), "two words never decide over her: \(rig.brain.trace)")
        T2.delta(rig, "item_k", ".")
        #expect(await rig.until { !Self.backchannels(rig).isEmpty }, "\(rig.brain.trace)")
        rig.push(Srv.userTranscript("item_k", "Put going."))
        #expect(await rig.until { rig.host.heardLog.contains { $0.text == "Put going." } })
        // "I'm listening." follows as its own item.
        await T3.over(rig, "item_l")
        T2.deltas(rig, "item_l", "I'm listening.")
        rig.push(Srv.userTranscript("item_l", "I'm listening."))
        #expect(await rig.until { rig.host.heardLog.contains { $0.text == "I'm listening." } })
        try await T5.live(rig, 0.8)
        Self.sheWentOn(rig, "Put going.")
        rig.shutdown()
    }

    /// t2-backchannel-echo10 bc01 (82.44–83.02): "Go on." came back as "Grand."; its
    /// settled words were taken as a turn: the answer was asked for, her reply cut at
    /// 2005 ms and the answer then cancelled — she just stopped.
    @Test func liveEcho10Bc01GrandDoesNotStopHer() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await Self.overHer(rig, "item_g")
        T2.delta(rig, "item_g", "Grand")
        T2.delta(rig, "item_g", ".")
        #expect(await rig.until { !Self.backchannels(rig).isEmpty }, "\(rig.brain.trace)")
        rig.push(Srv.userTranscript("item_g", "Grand."))
        #expect(await rig.until { rig.host.heardLog.contains { $0.text == "Grand." } })
        try await T5.live(rig, 0.8)
        Self.sheWentOn(rig, "Grand.")
        rig.shutdown()
    }

    /// t2-backchannel-fan15 c05 (49.44–52.03): "Keep going, I'm listening." came back as
    /// "She." (committed 51.12) while the rest was still being said (`speech_started`
    /// 51.44): "She." was held as a turn (`held("speech")`), and the next commit cut her
    /// (52.65) to answer it. Now "She." is a backchannel and she goes on.
    @Test func liveFan15C05SheDoesNotStopHer() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await Self.overHer(rig, "item_s")
        rig.push(Srv.speechStarted("item_l", ms: 3700))                    // they go on
        await rig.settle()
        T2.delta(rig, "item_s", "She")
        T2.delta(rig, "item_s", ".")
        rig.push(Srv.userTranscript("item_s", "She."))
        #expect(await rig.until { rig.host.heardLog.contains { $0.text == "She." } })
        #expect(!rig.brain.trace.contains(.held("speech")), "not a turn held for the rest: \(rig.brain.trace)")
        #expect(!Self.backchannels(rig).isEmpty, "\(rig.brain.trace)")
        rig.push(Srv.speechStopped("item_l", ms: 4400), Srv.committed("item_l"))
        T2.deltas(rig, "item_l", "I'm listening.")
        rig.push(Srv.userTranscript("item_l", "I'm listening."))
        #expect(await rig.until { rig.host.heardLog.contains { $0.text == "I'm listening." } })
        try await T5.live(rig, 0.8)
        Self.sheWentOn(rig, "She.")
        rig.shutdown()
    }

    /// t2-backchannel-fan15 bc02 (99.42–100.31): "Mm-hm." came back as "MMHN." (she went
    /// on: `backchannel("resumed-words")`) and the server's tail of the burst (no speech
    /// start, committed 100.81) as "Done.": answered in exact mode, her reply cut at 2725 ms.
    @Test func liveFan15Bc02TheTailDoneDoesNotStopHer() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await Self.overHer(rig, "item_m")
        T2.deltas(rig, "item_m", "MMHN.")
        rig.push(Srv.userTranscript("item_m", "MMHN."))
        #expect(await rig.until { !Self.backchannels(rig).isEmpty }, "\(rig.brain.trace)")
        rig.push(Srv.speechStopped("item_t", ms: 4100), Srv.committed("item_t"))   // the tail: no start of its own
        #expect(await rig.until { rig.brain.trace.contains(.tailIgnored) }, "\(rig.brain.trace)")
        T2.deltas(rig, "item_t", "Done.")
        rig.push(Srv.userTranscript("item_t", "Done."))
        #expect(await rig.until { rig.host.heardLog.contains { $0.text == "Done." } })
        try await T5.live(rig, 0.8)
        Self.sheWentOn(rig, "Done.")
        rig.shutdown()
    }

    /// The other side: a clear stop or a short question over her is still words for her.
    @Test func aShortQuestionOverHerIsStillAnswered() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await Self.overHer(rig, "item_w")
        T2.delta(rig, "item_w", "Why")
        T2.delta(rig, "item_w", "?")
        rig.push(Srv.userTranscript("item_w", "Why?"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail()) \(rig.brain.trace)")
        #expect(Self.backchannels(rig).isEmpty, "\(rig.brain.trace)")
        rig.shutdown()
    }

    /// A two-word question still decides at its first words (tune 6 T5-3 speed kept).
    @Test func twoWordsThatAskStillDecideAtOnce() async throws {
        let rig = try await BrainRig(tune: { $0.partialSettle = 0.6 })
        try await rig.start()
        await Self.overHer(rig, "item_q")
        T2.delta(rig, "item_q", "Who made")
        #expect(await rig.until(0.4) { rig.brain.trace.contains(.earlyWords) }, "\(rig.brain.trace)")
        rig.shutdown()
    }

    // MARK: T6-1 — the answer belongs to the question, never to an empty tail

    /// t2-interrupt-clean q02 (40.39–41.21): "Are you awake?" committed early by the voice's
    /// hold; the server stopped and committed an unannounced tail (40.55); the brain asked
    /// for the answer after that (40.68), so the session keyed it to the tail; the tail's
    /// transcript came back "" (41.11), the voice dropped it, and the drop cancelled the
    /// answer ("Yes, I"). The brain now names the turn it answers.
    @Test func liveQ02DroppingTheEmptyTailKeepsTheAnswer() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        try await Self.questionWithTail(rig)
        let cancels = rig.count("response.cancel")
        rig.push(Srv.userTranscript("item_tail", ""))                       // nothing in it
        await rig.settle()
        await rig.session.dropUserItem(itemID: "item_tail", resumePreempted: false)   // CloudVoice: "empty tail dropped"
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.count("response.cancel") == cancels, "the answer to the question stays: \(rig.trail())")
        rig.shutdown()
    }

    /// The same burst, with the tail taken for her own echo (or any other drop of it): the
    /// answer is the question's, so it is never touched (keyed to the tail, it was cancelled
    /// and preempted).
    @Test func takingTheTailAwayNeverTouchesTheAnswerToTheQuestion() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        try await Self.questionWithTail(rig)
        let cancels = rig.count("response.cancel")
        await rig.session.rejectEcho(itemID: "item_tail")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.count("response.cancel") == cancels, "\(rig.trail())")
        #expect(!rig.brain.trace.contains { if case .dnaReplaced = $0 { true } else { false } }, "not preempted: \(rig.brain.trace)")
        rig.shutdown()
    }

    /// "Are you awake?" over her, its tail committed before the answer is asked for, the
    /// answer's `response.created` in.
    static func questionWithTail(_ rig: BrainRig) async throws {
        await T3.sheIsTalking(rig, "Sun is a big deal, tomatoes love lots of it.")
        rig.push(Srv.responseDone("resp_1"))
        rig.push(Srv.speechStarted("item_q", ms: 3000))
        await rig.settle()
        rig.brain.injectHold(.paused(itemID: "item_q"))
        rig.push(Srv.committed("item_q"))                                   // the voice's early commit
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "waitForPartial")) })
        rig.push(Srv.speechStopped("item_tail", ms: 3700), Srv.committed("item_tail"))   // no speech_started
        #expect(await rig.until { rig.brain.trace.contains(.tailIgnored) }, "\(rig.brain.trace)")
        T2.deltas(rig, "item_q", "Are you awake?")
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail())")
        rig.push(Srv.responseCreated("resp_2"))
        await rig.settle()
        rig.push(Srv.userTranscript("item_q", "Are you awake?"))
        #expect(await rig.until { rig.host.heardLog.contains { $0.text == "Are you awake?" } })
    }
    // MARK: T6-6 — the reply stops at the turn's own sentence budget

    /// The Length line of the newest DNA on the wire.
    static func lengthLine(_ rig: BrainRig) -> String? {
        guard let id = rig.trail().last(where: { $0.hasPrefix("dna:") })?.dropFirst(4) else { return nil }
        return rig.dnaText(String(id))?.components(separatedBy: "\n").first { $0.hasPrefix("Length: ") }
    }

    /// Her reply `resp_1` / `item_a1` to a plain turn has started (not speculative).
    static func replying(_ rig: BrainRig) async {
        rig.utterance("item_u1")
        _ = await rig.until { rig.responseCreates().count == 1 }
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"))
        _ = await rig.until { rig.brain.trace.contains(.responseStarted(kind: "reply")) }
    }

    /// t2-interrupt-clean l03 (60.34): "Oh, wow. That sounds amazing. Biggest volcano in
    /// class? Nice. I'm a bit jealous, honestly. It's like a mini triumph…" — six short
    /// sentences under a two-sentence Length; the fixed cap of three let "Biggest volcano
    /// in class?" play. She now stops before the sentence past the turn's budget.
    @Test func liveCleanL03StopsAtTheTurnsOwnBudget() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false })
        try await rig.start()
        await Self.replying(rig)
        let length = try #require(Self.lengthLine(rig))
        #expect(length.hasPrefix("Length: at most two sentences"), "\(length)")
        let said = ["Oh, wow.", "That sounds amazing.", "Biggest volcano in class?", "Nice.", "I'm a bit jealous, honestly."]
        for (i, s) in said.enumerated() {
            rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: i, text: s))
            await rig.settle()
            #expect(rig.brain.trace.contains(.sentenceCapStop) == (i >= 2), "sentence \(i + 1): \(rig.brain.trace)")
        }
        rig.shutdown()
    }

    @Test func theBudgetFollowsTheLengthLine() {
        #expect(TurnPolicy.sentenceBudget(length: "at most three short sentences") == 3)
        #expect(TurnPolicy.sentenceBudget(length: "at most two short sentences") == 2)
        #expect(TurnPolicy.sentenceBudget(length: "one short sentence") == 2)
    }

    // MARK: T6-7 — never a robot's status report

    @Test func selfReportsAreRecognised() {
        for s in ["Tiny robot report: it feels like a lot of effort for a system nobody's dancing with right now.",
                  "Robot status: very happy.", "Dee update: I'm bouncing.", "Status report, my circuits are glowing!",
                  "Mood report: sunny with a chance of giggles.", "Beep boop, that's a lot."] {
            #expect(TurnPolicy.isSelfReport(s), "\(s)")
        }
        for s in ["Wow, that sounds like a classic Friday curveball.", "I read your report card story twice in my head!",
                  "My heart does a little hop.", "The weather was lovely.", "That update sounds stressful."] {
            #expect(!TurnPolicy.isSelfReport(s), "\(s)")
        }
    }

    /// t2-interrupt-fan15 l02 (the judge's leak): "Wow, that sounds like a classic Friday
    /// curveball—so understandable to feel that way. Tiny robot report: it feels like a lot
    /// of effort…". A later sentence: she stops before it.
    @Test func liveFan15L02StopsBeforeTheRobotReport() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        let first = "Wow, that sounds like a classic Friday curveball—so understandable to feel that way."
        let report = "Tiny robot report: it feels like a lot of effort for a system nobody's dancing with right now."
        await T3.sheIsTalking(rig, first)
        T2.assistantDelta(rig, "resp_1", "item_a1", first + " " + report)
        #expect(await rig.until { rig.brain.trace.contains(.selfReport(takenBack: false)) }, "\(rig.brain.trace)")
        let truncs = rig.trail().filter { $0.hasPrefix("truncate:") }.count
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 1, text: report))
        #expect(await rig.until { rig.trail().filter { $0.hasPrefix("truncate:") }.count > truncs || rig.count("response.cancel") > 0 },
                "\(rig.trail())")
        rig.shutdown()
    }

    /// In her first sentence: taken back unheard and asked again once, with the note.
    @Test func aRobotReportFirstIsNeverHeard() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        T2.assistantDelta(rig, "resp_1", "item_a1", "Robot status update: feeling sparkly. ")
        #expect(await rig.until { rig.brain.trace.contains(.selfReport(takenBack: true)) }, "\(rig.brain.trace)")
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail())")
        let dnaID = try #require(rig.trail().last { $0.hasPrefix("dna:") }).dropFirst(4)
        #expect(rig.dnaText(String(dnaID))?.contains("never a robot giving a report or a status") == true)
        #expect(rig.host.said.isEmpty)
        rig.shutdown()
    }
}
