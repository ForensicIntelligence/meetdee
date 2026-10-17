import Foundation
import Testing
@testable import HarnessCore

// Tune 10 (scope: the harness).
// 1. The latency gate: p90 end to end stays; the p50 bound moves from end to end
//    (below the server + model floor at 300 ms) to Dee's own overhead over that floor.
// 2. The `regressions` section: utterances the tune-7 run handled correctly that a
//    later run did not. Numbers are from the live reports: tune 7 `20261010-063215`,
//    tune 9 `20261010-102105`.

private func gate(_ gates: [Gate], _ id: String) -> Gate? { gates.first { $0.id == id } }

private extension RunBuilder {
    /// A complete turn and its reply with the TurnTimeline marks the live runner
    /// records: `committed`, `response_create_sent`, `first_audio_delta` (with its item).
    mutating func timedTurn(_ fixture: String, eos: Double, committed: Double, sent: Double, delta: Double,
                            played: Double, item: String, deltaItem: String? = nil) {
        utterance(fixture, eos - 1.4, eos)
        userItem("u_\(item)", seen: eos - 1.2, committed: committed)
        reply(item, started: played, ended: played + 2)
        run.timeline.append(.init(id: run.timeline.count + 1, start: eos + 0.4,
                                  marks: ["speech_stopped": committed - 0.06, "committed": committed,
                                          "response_create_sent": sent, "first_audio_delta": delta,
                                          "first_audio_played": played],
                                  details: ["committed: u_\(item)", "first_audio_delta: \(deltaItem ?? item)",
                                            "first_audio_played: \(item)"]))
    }

    /// A backchannel ("keep going") said over Dee's reply `replyItem`.
    mutating func backchannel(_ fixture: String, onset: Double, eos: Double, replyItem: String,
                              outcome: RunRecord.BargeOutcome) {
        utterance(fixture, onset, eos, text: "Keep going.", role: .bargeIn, expect: .any)
        run.utterances[run.utterances.count - 1].backchannel = true
        run.bargeIns.append(.init(step: run.utterances.last!.step, baseFixture: "l02", fixture: fixture, targetAtMs: 1500,
                                  replyItem: replyItem, replyStarted: onset - 1.5, onset: onset,
                                  stoppedAt: outcome == .stopped ? onset + 3.5 : nil, outcome: outcome, backchannel: true))
    }
}

@Suite("Tune 10: latency overhead over the server + model floor")
struct Tune10LatencyTests {
    @Test func theFloorIsCommitPlusModelTimeFromTheReplysTimelineTurn() throws {
        // Tune 7 t2-latency-clean q01: EOS 4.56, committed 5.04, response.create 5.06,
        // first delta 5.62, played 5.72 → latency 1.16 = floor 1.04 + overhead 0.12.
        var b = RunBuilder()
        b.timedTurn("q01", eos: 4.56, committed: 5.04, sent: 5.06, delta: 5.62, played: 5.72, item: "a1")
        let m = Metrics.compute([b.run], pricing: .mini)
        let row = try #require(m.utterances.first)
        #expect(abs((row.floor ?? 0) - 1.04) < 1e-9)
        #expect(abs((row.overhead ?? 0) - 0.12) < 1e-9)
        #expect(m.latencyOverhead.count == 1 && m.latencyFloor.count == 1)
    }

    @Test func aTimelineTurnForAnotherItemIsNotThisReplysFloor() {
        // A discarded speculative reply's delta in the turn: not the played reply's floor.
        var b = RunBuilder()
        b.timedTurn("q01", eos: 4.56, committed: 5.04, sent: 5.06, delta: 5.62, played: 5.72, item: "a1", deltaItem: "spec")
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(m.utterances.first?.floor == nil)
        #expect(m.latencyOverhead.isEmpty && m.latencyMain.count == 1)
        // Without a timeline the overhead is unmeasured and the p90 alone decides.
        #expect(gate(Gates.evaluate(m), "latency")?.status == .pass)
        #expect(gate(Gates.evaluate(m), "latency")?.value.contains("overhead not measured") == true)
    }

    /// Ten turns at tune 9's medians: end to end p50 1.22 s (over the old 1.1 s bound),
    /// floor p50 1.16 s, overhead 0.06 s; p90 under 1.6 s.
    func tune9Like(overhead: Double) -> Metrics {
        var b = RunBuilder()
        for i in 0..<10 {
            let eos = 10.0 * Double(i + 1)
            let model = 0.66 + 0.02 * Double(i % 3)
            let committed = eos + 0.51, sent = committed + 0.0, delta = sent + model
            b.timedTurn("q0\(i % 8 + 1)", eos: eos, committed: committed, sent: sent, delta: delta,
                        played: delta + overhead, item: "a\(i)")
        }
        return Metrics.compute([b.run], pricing: .mini)
    }

    @Test func endToEndP50OverTheOldTargetPassesWhenDeesOverheadIsSmall() {
        let m = tune9Like(overhead: 0.06)
        #expect((m.latencyMainP50 ?? 0) > 1.1)                 // the old p50 gate failed this
        #expect((m.latencyMainP90 ?? 9) <= 1.6)
        let g = gate(Gates.evaluate(m), "latency")
        #expect(g?.status == .pass)
        #expect(g?.note?.contains("end-to-end p50 1.2") == true)    // still reported, as information
    }

    @Test func tune7sOverheadOf120msFailsTheOverheadBound() {
        // Tune 7: overhead p50 0.12 s (release gate 0.10 + request 0.00–0.02).
        let g = gate(Gates.evaluate(tune9Like(overhead: 0.12)), "latency")
        #expect(g?.status == .fail)
        #expect(g?.value.contains("overhead p50 0.12") == true)
        // Exactly at the bound passes (0.10, rounding-safe).
        #expect(gate(Gates.evaluate(tune9Like(overhead: 0.10)), "latency")?.status == .pass)
    }

    @Test func theP90EndToEndGateStays() {
        // Tune 9: p90 1.63 s fails however small the overhead.
        var b = RunBuilder()
        for i in 0..<10 {
            let eos = 10.0 * Double(i + 1)
            let model = i >= 8 ? 1.05 : 0.62
            b.timedTurn("q01", eos: eos, committed: eos + 0.51, sent: eos + 0.51, delta: eos + 0.51 + model,
                        played: eos + 0.51 + model + 0.06, item: "a\(i)")
        }
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect((m.latencyMainP90 ?? 0) > 1.6)
        #expect(gate(Gates.evaluate(m), "latency")?.status == .fail)
    }
}

@Suite("Tune 10: regressions against the tune-7 run")
struct Tune10RegressionTests {
    /// t2-backchannel-kitchen15: c02 "Don't stop, keep going." over l02, and bc02 "Mm-hm."
    /// Tune 7 went on through both; tune 9 stopped on both (`stopped` 22.54 / 93.62 s).
    func backchannelRun(stopped: Bool) -> RunRecord {
        var b = RunBuilder()
        b.run.scenario = "t2-backchannel-kitchen15"
        b.utterance("l02", 12.0, 16.5)
        b.userItem("u1", seen: 12.2)
        b.reply("r1", started: 17.48, ended: stopped ? 22.54 : 30.0, flushed: stopped)
        b.backchannel("c02", onset: 18.98, eos: 20.83, replyItem: "r1", outcome: stopped ? .stopped : .missed)
        b.utterance("q01", 40.0, 41.4, text: "What's your favorite color?")
        b.userItem("u2", seen: 40.2)
        b.reply("r2", started: 42.6, ended: 45)
        return b.run
    }

    func metrics(_ r: RunRecord) -> Metrics { Metrics.compute([r], pricing: .mini) }

    @Test func aBackchannelSheNowStopsOnIsARegression() throws {
        let rg = Regressions.compare(current: metrics(backchannelRun(stopped: true)), judge: nil,
                                     baseline: metrics(backchannelRun(stopped: false)), baselineJudge: nil,
                                     baselineID: "20261010-063215")
        #expect(rg.compared == 3 && rg.baselineCorrect == 3)
        let e = try #require(rg.regressions.first)
        #expect(rg.regressions.count == 1)
        #expect(e.scenario == "t2-backchannel-kitchen15" && e.fixture == "c02" && e.occurrence == 1)
        #expect(e.problems == ["stopped on a backchannel"])
        // The other way round it is a fix, not a regression.
        let back = Regressions.compare(current: metrics(backchannelRun(stopped: false)), judge: nil,
                                       baseline: metrics(backchannelRun(stopped: true)), baselineJudge: nil, baselineID: "x")
        #expect(back.regressions.isEmpty && back.fixed == 1)
    }

    @Test func aQuestionOverHerAnsweredLateIsARegression() throws {
        // t2-interrupt-clean q01 "What's your favorite color?" over l01: tune 9 answered
        // 1.64 s after their end of speech (18.44 → 20.08), over the 1.6 s bound.
        func run(answerAt: Double) -> RunRecord {
            var b = RunBuilder()
            b.run.scenario = "t2-interrupt-clean"
            b.utterance("l01", 2.0, 14.5)
            b.userItem("u1", seen: 2.2)
            b.reply("r1", started: 15.04, ended: 19.12, flushed: true)
            b.utterance("q01", 17.04, 18.44, text: "What's your favorite color?", role: .bargeIn, expect: .reply)
            b.userItem("u2", seen: 17.2)
            var bi = RunRecord.BargeIn(step: 1, baseFixture: "l01", fixture: "q01", targetAtMs: 2000, replyItem: "r1",
                                       replyStarted: 15.04, onset: 17.04, stoppedAt: 19.12, outcome: .stopped, backchannel: false)
            bi.pausedAt = 17.2
            b.run.bargeIns.append(bi)
            b.reply("r2", started: answerAt, ended: answerAt + 3)
            return b.run
        }
        let now = metrics(run(answerAt: 20.08))
        let then = metrics(run(answerAt: 19.6))
        #expect(then.utterances.allSatisfy { $0.problems.isEmpty })
        let rg = Regressions.compare(current: now, judge: nil, baseline: then, baselineJudge: nil, baselineID: "t7")
        let e = try #require(rg.regressions.first)
        #expect(e.fixture == "q01" && e.problems.count == 1)
        #expect(e.problems[0].hasPrefix("question not answered: answered late (1.64 s)"))
    }

    @Test func theJudgeCountsOnlyWhenBothRunsWereJudged() {
        let r = backchannelRun(stopped: false)
        var low = Judge.Summary(model: "gpt-4.1-mini")
        low.scores = [Judge.Score(scenario: r.scenario, family: "acoustic", index: 3, fixture: "q01", score: 2, fitsState: false,
                                  leak: false, tooLong: false, grovels: false, laughsAtJoke: nil, guilt: false,
                                  reason: "does not answer the question", reply: "…")]
        var fine = low
        fine.scores[0].score = 5
        // Judged 5 in the baseline, 2 now: a regression.
        let rg = Regressions.compare(current: metrics(r), judge: low, baseline: metrics(r), baselineJudge: fine, baselineID: "t7")
        #expect(rg.regressions.map(\.fixture) == ["q01"])
        #expect(rg.regressions.first?.problems == ["judge 2: does not answer the question"])
        // This run not judged: nothing to compare, no regression.
        let unjudged = Regressions.compare(current: metrics(r), judge: nil, baseline: metrics(r), baselineJudge: fine, baselineID: "t7")
        #expect(unjudged.regressions.isEmpty)
    }

    @Test func repeatedFixturesMatchByOccurrenceAndUnrunOnesAreCounted() {
        var then = RunBuilder()
        then.run.scenario = "s"
        then.utterance("q01", 1, 2); then.userItem("u1", seen: 1.2); then.reply("a1", started: 3, ended: 4)
        then.utterance("q01", 6, 7); then.userItem("u2", seen: 6.2); then.reply("a2", started: 8, ended: 9)
        var now = RunBuilder()
        now.run.scenario = "s"
        now.utterance("q01", 1, 2); now.userItem("u1", seen: 1.2); now.reply("a1", started: 3, ended: 4)
        now.utterance("q01", 6, 7); now.userItem("u2", seen: 6.2)                // second one: no reply now
        var other = RunBuilder()
        other.run.scenario = "gone"
        other.utterance("q02", 1, 2); other.userItem("u9", seen: 1.2); other.reply("a9", started: 3, ended: 4)
        let rg = Regressions.compare(current: metrics(now.run), judge: nil,
                                     baseline: Metrics.compute([then.run, other.run], pricing: .mini),
                                     baselineJudge: nil, baselineID: "t7")
        #expect(rg.regressions.count == 1)
        #expect(rg.regressions.first?.occurrence == 2 && rg.regressions.first?.problems == ["dropped (no reply)"])
        #expect(rg.notRun == 1 && rg.compared == 2)
    }

    @Test func theReportListsRegressions() {
        let now = metrics(backchannelRun(stopped: true))
        let rg = Regressions.compare(current: now, judge: nil, baseline: metrics(backchannelRun(stopped: false)),
                                     baselineJudge: nil, baselineID: "20261010-063215")
        let report = HarnessReport(runID: "r", started: "a", finished: "b", model: "m", brain: "realtime", maxUSD: 2,
                                   aborted: nil, gates: [], metrics: now, runs: [], regressions: rg)
        let md = report.markdown()
        #expect(md.contains("## Regressions vs `20261010-063215`"))
        #expect(md.contains("1 regressed of 3 handled correctly then"))
        #expect(md.contains("| t2-backchannel-kitchen15 | 2 | c02 | **stopped on a backchannel** |"))
    }
}
