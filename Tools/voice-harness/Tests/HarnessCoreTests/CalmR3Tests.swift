import Foundation
import Testing
@testable import HarnessCore

// Calm round 3 (harness owner, C3). Round 2 scored a real interruption "stopped" only
// when Dee went silent within onset + 2.0 s (`Metrics.bargeMissAfter`). D2 lets a
// question pause Dee only from its words, and gpt-transcribe sends no delta before the
// commit, so a question longer than ~1.4 s pauses Dee at ~2.0–2.1 s and was scored
// "kept talking over the question" even when answered in time. Now:
//  - a question stopped Dee when Dee went silent before the answer's first audio;
//  - a stop / command fixture when Dee went silent within D1's 1.5 s of its stop phrase;
//  - a late silence is reported at its real time, not "never silent" (99 s);
//  - "Dee answered the TV while idle" is an information line (INFO), never a failure.

private func gate(_ gates: [Gate], _ id: String) -> Gate? { gates.first { $0.id == id } }

@Suite("Calm round 3: a question stops Dee when Dee is silent before the answer")
struct CalmR3QuestionStopTests {
    /// Live 20261016-232252 t2-interrupt-kitchen15 q01: onset 16.72, the voice paused at
    /// 18.78 (onset + 2.06) from the question's words, the reply was flushed at 18.80,
    /// and the answer's first audio played at 19.56.
    func kitchenQ01(answerAt: Double = 19.56, holdAt: Double = 18.78, flushAt: Double = 18.80,
                    timed: Bool = true) -> RunRecord {
        var b = RunBuilder()
        b.utterance("l01", 1, 8)
        b.userItem("u_l01", seen: 1.2, committed: 8.6)
        b.reply("r1", started: 14.72, ended: flushAt, flushed: true)
        // The runner's raw outcome: no flush by onset + 2.0 s → missed.
        b.event("q01", onset: 16.72, eos: 18.12, replyStarted: 14.72, outcome: .missed, expect: .reply)
        b.userItem("u_q01", seen: 16.9, committed: 18.6, transcript: "What's your favorite color?")
        b.reply("a1", started: answerAt, ended: answerAt + 5.9)
        if timed {
            b.notes([(16.95, "duck - gain=-12 via=onset"), (holdAt, "hold u_q01 why=answer"),
                     (flushAt, "flushed: r1 played_ms=4060"), (flushAt, "barge_in: u_q01")])
        }
        return b.run
    }

    @Test func aQuestionPausedFromItsWordsAfterTwoSecondsIsAStop() {
        let run = kitchenQ01()
        let b = Metrics.rescoreStop(run, run.bargeIns[0], events: run.floorEvents!)
        #expect(b.outcome == .stopped && b.stoppedAt == 18.80 && b.pausedAt == 18.78)
        #expect(abs(Metrics.stopDeadline(run, run.bargeIns[0], utterance: run.utterances[1]) - 19.56) < 1e-9)
        let m = Metrics.compute([run], pricing: .mini)
        #expect(m.interruptQuestionsApplicable == 1 && m.interruptQuestionsAnswered == 1)
        #expect(m.interruptQuestions.first?.stopped == true && m.interruptQuestions.first?.miss == nil)
        #expect(m.silenceMissList.isEmpty && m.silenceMulti.count == 1 && abs(m.silenceMulti[0] - 2.06) < 1e-9)
        #expect(gate(Gates.evaluate(m), "interrupt_questions")?.status == .pass)
    }

    @Test func dipStillCountsForTheYieldGate() {
        // The dip at onset + 0.23 s is the yield (D1), unchanged by the stop rescoring.
        let m = Metrics.compute([kitchenQ01()], pricing: .mini)
        #expect(m.yieldApplicable == 1 && m.yieldMissed == 0 && abs(m.yieldLatencies[0] - 0.23) < 1e-9)
    }

    @Test func talkingOverTheStartOfTheAnswerIsStillAMiss() {
        // The answer started (19.10) before Dee went silent (19.30): Dee talked over it.
        let run = kitchenQ01(answerAt: 19.10, holdAt: 19.30, flushAt: 19.32)
        let m = Metrics.compute([run], pricing: .mini)
        #expect(m.interruptQuestions.first?.stopped == false)
        #expect(m.interruptQuestions.first?.miss == "kept talking over the question")
    }

    @Test func withNoAnswerTheBoundIsTheLatencyGateFromTheirEnd() {
        // No answer at all: silent by EoS + 1.6 s (19.72) counts as stopped (then "never answered").
        var run = kitchenQ01()
        run.playback.removeAll { $0.itemID == "a1" }
        run.responses.removeAll { $0.itemIDs == ["a1"] }
        #expect(abs(Metrics.stopDeadline(run, run.bargeIns[0], utterance: run.utterances[1]) - 19.72) < 1e-9)
        let m = Metrics.compute([run], pricing: .mini)
        #expect(m.interruptQuestions.first?.stopped == true && m.interruptQuestions.first?.miss == "never answered")
    }

    @Test func aPauseDeeResumedFromIsNotTheSilence() {
        // An early pause (17.0) that Dee resumed from; the real silence is the later hold.
        var run = kitchenQ01()
        run.timeline = [.init(id: 1, start: 0, marks: [:], details: [], events: [
            .init(t: 16.95, text: "duck - gain=-12 via=onset"), .init(t: 17.0, text: "hold - why=sustained"),
            .init(t: 17.4, text: "resumed -"), .init(t: 18.78, text: "hold u_q01 why=answer"),
            .init(t: 18.80, text: "flushed: r1 played_ms=4060")])]
        let b = Metrics.rescoreStop(run, run.bargeIns[0], events: run.floorEvents!)
        #expect(b.outcome == .stopped && b.pausedAt == 18.78)
    }

    @Test func aRecordWithoutTimedNotesKeepsTheRunnersOutcome() {
        let run = kitchenQ01(timed: false)
        #expect(Metrics.rescoredStops(run) == run)
        let m = Metrics.compute([run], pricing: .mini)
        #expect(m.interruptQuestions.first?.miss == "kept talking over the question")
    }

    @Test func backchannelsAreNeverRescored() {
        var b = RunBuilder()
        b.longReply(end: 14.6, flushed: true)
        b.event("bc01", onset: 12.0, eos: 12.4, outcome: .missed)
        b.notes([(12.2, "duck - gain=-12 via=onset"), (14.58, "hold - why=sustained")])
        let r = Metrics.rescoredStops(b.run)
        #expect(r.bargeIns[0].outcome == .missed && r.bargeIns[0].stoppedAt == nil)
    }
}

@Suite("Calm round 3: stop phrases are bound by D1, from the stop phrase")
struct CalmR3StopPhraseTests {
    /// c04 "Be quiet, please." (first span ends 12.6): Dee silent at `holdAt`.
    func c04(holdAt: Double, flushAt: Double) -> RunRecord {
        var b = RunBuilder()
        b.longReply(end: flushAt, flushed: true)
        b.utterance("c04", 12.0, 13.2, spans: [(12.0, 12.6), (12.8, 13.2)], text: "Be quiet, please.", role: .bargeIn, expect: .any)
        let bi = RunRecord.BargeIn(step: b.run.utterances.last!.step, baseFixture: "l01", fixture: "c04", targetAtMs: 2000,
                                   replyItem: "r1", replyStarted: 10, onset: 12.0, stoppedAt: nil, outcome: .missed,
                                   backchannel: false)
        b.run.bargeIns.append(bi)
        b.notes([(12.2, "duck - gain=-12 via=onset"), (holdAt, "hold u_c04 why=stopword"), (flushAt, "flushed: r1 played_ms=1")])
        return b.run
    }

    @Test func silentWithinOneAndAHalfSecondsOfTheStopPhraseIsAStop() {
        // 14.05 = onset + 2.05 (round 2: missed) but 1.45 s after "Be quiet" ends.
        let m = Metrics.compute([c04(holdAt: 14.05, flushAt: 14.07)], pricing: .mini)
        #expect(m.stopCommands == 1 && m.stopCommandsEnded == 1 && m.stopCommandMisses.isEmpty)
        #expect(m.silenceStopWord.count == 1 && abs(m.silenceStopWord[0] - 1.45) < 1e-9)
    }

    @Test func aLateSilenceIsReportedAtItsRealTimeNotNinetyNine() {
        // Live 20261017-000256 t2-stop-mood-clean c04: silent 1.57 s after the stop phrase.
        let m = Metrics.compute([c04(holdAt: 14.17, flushAt: 14.20)], pricing: .mini)
        #expect(m.stopCommandsEnded == 0 && m.stopCommandMisses == ["s:c04 (silent after 2.17 s)"])
        #expect(m.silenceStopWord.count == 1 && abs(m.silenceStopWord[0] - 1.57) < 1e-9)
        #expect(m.silenceStopWordList == ["s:c04 (1.57 s)"])
        let g = gate(Gates.evaluate(m), "silence")
        #expect(g?.status == .fail && g?.value.contains("p90 1.57 s") == true)
    }

    @Test func neverFlushedIsStillNeverSilent() {
        var b = RunBuilder()
        b.longReply()
        b.event("c01", onset: 12.0, eos: 12.4, outcome: .missed)
        b.notes([(12.2, "duck - gain=-12 via=onset"), (12.9, "unduck - (resume)")])
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(m.stopCommandMisses == ["s:c01 (never ended)"] && m.silenceStopWordList == ["s:c01 (never silent)"])
    }
}

@Suite("Calm round 3: Dee answered the TV while idle (information)")
struct CalmR3IdleTVTests {
    func run(bed: String = "tv", snr: Double = 15) -> RunRecord {
        var b = RunBuilder()
        b.run.scenario = "calm-sounds-tv15"
        b.run.noise = .init(bed: bed, snrDb: snr)
        b.run.duration = 90
        b.utterance("l01", 1, 8)
        b.userItem("u_l01", seen: 1.2, committed: 8.6)
        b.reply("r1", started: 10, ended: 40)
        // The TV over Dee (not idle) and with Dee idle at 45 s: answered at 46.6.
        b.userItem("u_tv1", seen: 20.5, committed: 21.5, transcript: "Okay.")
        b.reply("r_tv1", started: 22.0, ended: 25.0)
        b.userItem("u_tv2", seen: 45.0, committed: 46.0, transcript: "In tonight's news.")
        b.reply("r_tv2", started: 46.6, ended: 49.0)
        b.notes([(20.6, "duck u_tv1 gain=-6 via=onset"), (21.6, "ambient u_tv1 (tvItemSustain)")])
        return b.run
    }

    @Test func anIdleAnswerInATVRoomIsCountedAndNeverFails() {
        let m = Metrics.compute([run()], pricing: .mini)
        #expect(m.idleAnswers.map(\.transcript) == ["In tonight's news."])
        #expect(m.idleAnswers.first?.condition == "tv15")
        let g = gate(Gates.evaluate(m), "idle_tv_answers")
        #expect(g?.status == .info && g?.n == 1 && g?.note?.contains("In tonight's news.") == true)
        #expect(Gates.anyFailed([g!]) == false)
    }

    @Test func anIdleAnswerOutsideATVRoomIsListedApart() {
        let m = Metrics.compute([run(bed: "fan")], pricing: .mini)
        let g = gate(Gates.evaluate(m), "idle_tv_answers")
        #expect(g?.n == 0 && g?.value.contains("all rooms 1 (fan15 1)") == true)
    }

    @Test func infoDecodesAndOldStatusesStill() throws {
        let d = try JSONDecoder().decode([Gate.Status].self, from: Data(#"["PASS","FAIL","SKIP","INFO"]"#.utf8))
        #expect(d == [.pass, .fail, .skip, .info])
    }
}
