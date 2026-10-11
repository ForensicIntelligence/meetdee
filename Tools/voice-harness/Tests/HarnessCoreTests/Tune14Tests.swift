import Foundation
import Testing
@testable import HarnessCore

// Tune 14 (scope: the harness).
// 1. Backchannel scoring (user decision): her reply ending at its own sentence cap
//    (`sentenceCapStop`) after a backchannel she continued on is "continued", not a
//    stop. Numbers are from the live runs: T13 A `20261010-224809`
//    t2-backchannel-echo20 c05 (59.2–63.1) and T12 B `20261010-205810` echo20 c05.
//    A cut caused by the user's speech still scores stopped (T13 A fan15 c05).
// 2. `pool`: every gate on the pooled counts / percentiles of 2+ reports.

private func gate(_ gates: [Gate], _ id: String) -> Gate? { gates.first { $0.id == id } }

/// One backchannel c05 "Keep going, I'm listening." over reply `r1`, flushed at
/// `stoppedAt`, with the brain trace marks of that window.
private func backchannelRun(scenario: String = "t2-backchannel-echo20", onset: Double, eos: Double, replyStarted: Double,
                            stoppedAt: Double, playedMs: Int, pausedAt: Double? = nil,
                            trace: [(Double, String)]) -> RunRecord {
    var b = RunBuilder()
    b.run.scenario = scenario
    b.utterance("l05", replyStarted - 2.5, replyStarted - 1.0)
    b.reply("r1", started: replyStarted, ended: stoppedAt, flushed: true, playedMs: playedMs)
    b.utterance("c05", onset, eos, text: "Keep going, I'm listening.", role: .bargeIn, expect: .any)
    b.run.utterances[b.run.utterances.count - 1].backchannel = true
    var barge = RunRecord.BargeIn(step: b.run.utterances.last!.step, baseFixture: "l05", fixture: "c05", targetAtMs: 1500,
                                  replyItem: "r1", replyStarted: replyStarted, onset: onset, stoppedAt: stoppedAt,
                                  outcome: .stopped, backchannel: true)
    barge.pausedAt = pausedAt
    b.run.bargeIns.append(barge)
    b.run.truncations.append(.init(itemID: "r1", audioEndMs: playedMs, at: stoppedAt - 0.02))
    b.run.brainTrace = trace.map { RunRecord.Note(t: $0.0, text: $0.1) }
    return b.run
}

/// T13 A echo20 c05: "continued" 61.18, resumed, `sentenceCapStop` 63.06 truncating at
/// 4,225 ms, flush 63.08 (inside the watch window, eos 61.83 + 2 s).
private func t13Echo20(pausedAt: Double? = nil, capAt: Double? = 63.06, continued: Bool = true) -> RunRecord {
    var trace: [(Double, String)] = [(60.82, #"committed(plan: "waitForPartial")"#), (60.94, "tailIgnored")]
    if continued { trace.append((61.18, #"backchannel("continued")"#)) }
    trace += [(61.18, #"backchannel("resumed-brain")"#), (61.26, #"heard(verdict: "answer")"#),
              (62.8, #"backchannel("resumed-after-resume")"#)]
    if let capAt { trace.append((capAt, "sentenceCapStop")) }
    return backchannelRun(onset: 59.24, eos: 61.83, replyStarted: 57.74, stoppedAt: 63.08, playedMs: 4225,
                          pausedAt: pausedAt, trace: trace)
}

/// T12 B echo20 c05: "continued" 61.64, tail, resumed 63.10, `sentenceCapStop` 64.22
/// (3,565 ms), flush 64.24; a carry-on reply followed (64.52).
private func t12bEcho20() -> RunRecord {
    backchannelRun(onset: 59.66, eos: 62.25, replyStarted: 58.16, stoppedAt: 64.24, playedMs: 3565,
                   trace: [(61.26, #"committed(plan: "waitForPartial")"#), (61.64, #"backchannel("continued")"#),
                           (62.74, "tailIgnored"), (63.1, #"backchannel("tail")"#), (63.1, #"backchannel("resumed-brain")"#),
                           (64.22, "sentenceCapStop"), (64.52, "speculated")])
}

/// T13 A fan15 c05: "I'm listening." heard as "When you listen.": continued at 50.10,
/// then `earlyWords` on the user's item and she stopped (flush 50.92) to answer. A real stop.
private func t13Fan15() -> RunRecord {
    backchannelRun(scenario: "t2-backchannel-fan15", onset: 47.98, eos: 50.57, replyStarted: 46.48, stoppedAt: 50.92,
                   playedMs: 1805,
                   trace: [(49.68, #"committed(plan: "waitForPartial")"#), (50.1, #"backchannel("continued")"#),
                           (50.74, #"committed(plan: "waitForPartial")"#), (50.9, "earlyWords"), (50.9, "speculated"),
                           (50.9, #"backchannel("resumed-brain")"#)])
}

@Suite("Tune 14: her own sentence cap after a continued backchannel is not a stop")
struct Tune14BackchannelTests {
    func metrics(_ runs: RunRecord...) -> Metrics { Metrics.compute(runs, pricing: .mini) }

    @Test func t13Echo20SentenceCapScoresContinued() throws {
        let run = t13Echo20()
        #expect(Metrics.endedAtSentenceCap(run, run.bargeIns[0]))
        let m = metrics(run)
        #expect(m.backchannels == 1 && m.backchannelsApplicable == 1)
        #expect(m.backchannelStops == 0 && m.backchannelStopList.isEmpty)
        #expect(m.backchannelCapEnds == ["t2-backchannel-echo20:c05"])
        let g = try #require(gate(Gates.evaluate(m), "backchannel"))
        #expect(g.status == .pass)
        #expect(g.note?.contains("continued, then ended at her sentence cap: t2-backchannel-echo20:c05") == true)
        // Not a per-utterance problem either (the regressions section).
        #expect(!m.utterances.contains { $0.problems.contains("stopped on a backchannel") })
    }

    @Test func t12bEcho20SentenceCapScoresContinuedEvenWithACarryOnAfter() throws {
        let m = metrics(t12bEcho20())
        #expect(m.backchannelStops == 0 && m.backchannelsApplicable == 1)
        #expect(gate(Gates.evaluate(m), "backchannel")?.status == .pass)
    }

    @Test func aCutCausedByTheUsersItemStillScoresStopped() throws {
        let run = t13Fan15()
        #expect(!Metrics.endedAtSentenceCap(run, run.bargeIns[0]))
        let m = metrics(run)
        #expect(m.backchannelStops == 1 && m.backchannelStopList == ["t2-backchannel-fan15:c05"])
        #expect(m.backchannelCapEnds.isEmpty)
        #expect(gate(Gates.evaluate(m), "backchannel")?.status == .fail)
        #expect(m.utterances.contains { $0.problems.contains("stopped on a backchannel") })
    }

    @Test func theVoicePausingHerForTheUserIsAUserCutEvenWithACapMark() {
        // A `.barge_in` pause (pausedAt) means the user's speech cut her.
        let m = metrics(t13Echo20(pausedAt: 59.5))
        #expect(m.backchannelStops == 1 && m.backchannelCapEnds.isEmpty)
    }

    @Test func aCapMarkNotAtTheFlushOrWithoutContinuedIsStillAStop() {
        // The cap fired a second before: something else flushed her at 63.08.
        #expect(metrics(t13Echo20(capAt: 62.0)).backchannelStops == 1)
        // A cap after the flush did not cause it.
        #expect(metrics(t13Echo20(capAt: 63.2)).backchannelStops == 1)
        // The brain never continued on the backchannel.
        #expect(metrics(t13Echo20(continued: false)).backchannelStops == 1)
        // No brain trace at all (minimal brain, older records): raw outcome.
        var run = t13Echo20()
        run.brainTrace = nil
        #expect(metrics(run).backchannelStops == 1)
    }

    @Test func aNonBackchannelBargeInIsNeverReScored() {
        var run = t13Echo20()
        run.bargeIns[0].backchannel = false
        run.utterances[run.utterances.count - 1].backchannel = false
        #expect(!Metrics.endedAtSentenceCap(run, run.bargeIns[0]))
        #expect(Metrics.scoredOutcome(run, run.bargeIns[0]) == .stopped)
    }
}

@Suite("Tune 14: pooled gates over 2+ reports")
struct Tune14PoolTests {
    /// A run of `n` backchannels, `stops` of them stopped (no sentence cap), all applicable.
    func bcRun(_ n: Int, stops: Int) -> RunRecord {
        var b = RunBuilder()
        b.run.scenario = "t2-backchannel-echo20"
        for i in 0..<n {
            let onset = 10.0 * Double(i + 1)
            b.run.bargeIns.append(.init(step: i, baseFixture: "l02", fixture: "c02", targetAtMs: 1500, replyItem: "r\(i)",
                                        replyStarted: onset - 1.5, onset: onset, stoppedAt: i < stops ? onset + 1 : nil,
                                        outcome: i < stops ? .stopped : .missed, backchannel: true))
        }
        return b.run
    }

    func source(_ id: String, _ runs: [RunRecord], judge: Judge.Summary? = nil) -> Pool.Source {
        Pool.Source(id: id, model: "gpt-realtime-2.1-mini", runs: runs, judge: judge)
    }

    @Test func backchannelStopsArePooledOver32() throws {
        // 1/16 alone fails (6.25% ≥ 5%); pooled with 0/16 it is 1/32 = 3.1%: pass.
        let a = source("A", [bcRun(16, stops: 1)]), b = source("B", [bcRun(16, stops: 0)])
        #expect(gate(Gates.evaluate(Metrics.compute(a.runs, pricing: .mini)), "backchannel")?.status == .fail)
        let p = Pool.evaluate([a, b])
        let g = try #require(gate(p.gates, "backchannel"))
        #expect(g.n == 32 && g.status == .pass)
        #expect(g.value.hasPrefix("stopped 1/32"))
        #expect(g.note?.contains("stopped on: A/t2-backchannel-echo20:c02") == true)
    }

    @Test func pooledStopsOverTheTargetStillFail() throws {
        // 1 + 1 of 32 = 6.25%: fail, though neither run is far off alone.
        let p = Pool.evaluate([source("A", [bcRun(16, stops: 1)]), source("B", [bcRun(16, stops: 1)])])
        #expect(gate(p.gates, "backchannel")?.status == .fail)
        #expect(p.failed)
    }

    @Test func percentilesAreOverTheJoinedSamples() throws {
        // A: ten turns at 1.0 s; B: ten at 1.9 s. Alone A passes p90 ≤ 1.6, B fails;
        // pooled the p90 is over all twenty (1.9): fail. Not the mean of two p90s.
        func turns(_ latency: Double) -> RunRecord {
            var b = RunBuilder()
            for i in 0..<10 {
                let eos = 10.0 * Double(i + 1)
                b.utterance("q0\(i % 8 + 1)", eos - 1.4, eos)
                b.userItem("u\(i)", seen: eos - 1.2, committed: eos + 0.5)
                b.reply("a\(i)", started: eos + latency, ended: eos + latency + 2)
            }
            return b.run
        }
        let p = Pool.evaluate([source("A", [turns(1.0)]), source("B", [turns(1.9)])])
        #expect(p.metrics.latencyMain.count == 20)
        #expect(abs((p.metrics.latencyMainP90 ?? 0) - 1.9) < 1e-6)
        #expect(abs((p.metrics.latencyMainP50 ?? 0) - 1.45) < 1e-6)
        #expect(gate(p.gates, "latency")?.status == .fail)
        let q = Pool.evaluate([source("A", [turns(1.0)]), source("B", [turns(1.0)])])
        #expect(gate(q.gates, "latency")?.status == .pass && gate(q.gates, "latency")?.n == 20)
    }

    @Test func theSameScenarioInTwoReportsStaysTwoRuns() {
        let p = Pool.runs([source("A", [bcRun(2, stops: 0)]), source("B", [bcRun(2, stops: 0)])])
        #expect(p.map(\.scenario) == ["A/t2-backchannel-echo20", "B/t2-backchannel-echo20"])
    }

    @Test func judgeVerdictsArePooled() throws {
        func j(_ scores: [Int], leak: Bool = false) -> Judge.Summary {
            var s = Judge.Summary(model: "gpt-4.1-mini")
            s.scores = scores.enumerated().map { i, v in
                Judge.Score(scenario: "s", family: "dna", index: i, fixture: "q01", score: v, fitsState: true, leak: leak && i == 0,
                            tooLong: false, grovels: false, laughsAtJoke: nil, guilt: false, reason: "", reply: "Sure thing, my friend.")
            }
            s.aggregate()
            return s
        }
        let p = Pool.evaluate([source("A", [bcRun(1, stops: 0)], judge: j([5, 5])),
                               source("B", [bcRun(1, stops: 0)], judge: j([3, 3]))])
        #expect(p.judged == 2)
        #expect(p.judge?.scores.count == 4 && abs((p.judge?.mean ?? 0) - 4.0) < 1e-9)
        #expect(Set(p.judge?.scores.map(\.scenario) ?? []) == ["A/s", "B/s"])
        // One judged report of two: its verdicts only, and the count says so.
        let half = Pool.evaluate([source("A", [bcRun(1, stops: 0)], judge: j([5])), source("B", [bcRun(1, stops: 0)])])
        #expect(half.judged == 1 && half.judge?.scores.count == 1)
        #expect(Pool.judge([source("A", []), source("B", [])]) == nil)
    }

    @Test func theCapRuleAppliesInsideThePoolToo() {
        // T13 A echo20 + T12 B echo20 (both her own cap) and the fan15 real stop: 1 stop.
        let p = Pool.evaluate([source("T13A", [t13Echo20(), t13Fan15()]), source("T12B", [t12bEcho20()])])
        #expect(p.metrics.backchannelStops == 1 && p.metrics.backchannelsApplicable == 3)
        #expect(p.metrics.backchannelCapEnds == ["T13A/t2-backchannel-echo20:c05", "T12B/t2-backchannel-echo20:c05"])
    }
}
