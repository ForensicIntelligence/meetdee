import Foundation
import Testing
@testable import HarnessCore

// Tune 5 (scope: the harness). Questions asked over her (content barge-ins) and
// elapsed time said in words. The interrupt tests reproduce the tune-4 live probes
// (Reports/20261010-011423 with app parity, Reports/20261010-011624 with
// DEE_HARNESS_CORTEX_STOP=0), scenario scratchpad/tune4-probe.json.

private func gate(_ gates: [Gate], _ id: String) -> Gate? { gates.first { $0.id == id } }

private extension RunBuilder {
    /// A question asked over her reply to `base` (step of the barge-in utterance).
    mutating func question(_ fixture: String, _ onset: Double, _ eos: Double, text: String, base: String,
                           replyItem: String, replyStarted: Double, pausedAt: Double?, stoppedAt: Double?,
                           outcome: RunRecord.BargeOutcome = .stopped, expect: Scenario.Expect = .reply) {
        utterance(fixture, onset, eos, text: text, role: .bargeIn, expect: expect)
        let step = run.utterances.last!.step
        var b = RunRecord.BargeIn(step: step, baseFixture: base, fixture: fixture, targetAtMs: 2000, replyItem: replyItem,
                                  replyStarted: replyStarted, onset: onset, stoppedAt: stoppedAt, outcome: outcome,
                                  backchannel: false)
        b.pausedAt = pausedAt
        run.bargeIns.append(b)
    }

    /// A response the brain requested and the app cancelled before any audio.
    mutating func cancelled(at t: Double, items: [String] = []) {
        var r = RunRecord.Response(responseID: "resp_x\(run.responses.count)", kind: "reply")
        r.startedAt = t; r.doneAt = t + 0.1; r.status = "cancelled"; r.itemIDs = items
        run.responses.append(r)
    }
}

/// Probe 20261010-011423 (app parity): `bargedIn()` → Cortex `.stopSpeaking` → `stop()`
/// cancelled the brain's answer to each question within 0.2 s; no answer ever played.
private func parityProbe(expect: Scenario.Expect = .reply) -> RunRecord {
    var b = RunBuilder()
    b.run.scenario = "t4-probe-content-bargein"
    b.utterance("l01", 2.54, 13.58)
    b.userItem("u_l01", seen: 2.72, committed: 14.04)
    b.reply("aZPCrE", started: 14.86, ended: 19.16, text: "Honestly, it’s a fair feeling. You could wait or pick a smaller, calmer dog.",
            flushed: true, playedMs: 2145)
    b.question("q01", 16.86, 18.26, text: "What's your favorite color?", base: "l01", replyItem: "aZPCrE",
               replyStarted: 14.86, pausedAt: 17.00, stoppedAt: 19.16, expect: expect)
    b.userItem("u_q01", seen: 16.98, committed: 18.74, transcript: "What's your favorite color?")
    b.cancelled(at: 19.54)
    b.utterance("l04", 27.33, 35.51)
    b.userItem("u_l04", seen: 27.54, committed: 36.00)
    b.reply("jli5bo", started: 36.86, ended: 40.22, text: "Okay, little balcony garden builder. Tomatoes love lots of sun.",
            flushed: true, playedMs: 1945, status: "incomplete")
    b.question("q02", 38.66, 39.47, text: "Are you awake?", base: "l04", replyItem: "jli5bo",
               replyStarted: 36.86, pausedAt: 38.80, stoppedAt: 40.22, expect: expect)
    b.userItem("u_q02", seen: 38.80, committed: 39.84, transcript: "Are you awake?")
    b.cancelled(at: 40.60)
    b.utterance("l03", 48.39, 59.29)
    b.userItem("u_l03", seen: 48.70, committed: 59.80)
    b.reply("I8cuHK", started: 60.56, ended: 65.48, text: "Wow, that’s awesome. Your volcano was the class superstar, huh?",
            flushed: true, playedMs: 2165)
    b.question("q06", 62.56, 64.61, text: "What did you do today?", base: "l03", replyItem: "I8cuHK",
               replyStarted: 60.56, pausedAt: 62.72, stoppedAt: 65.48, expect: expect)
    b.userItem("u_q06", seen: 62.72, committed: 65.08, transcript: "What did you do today?")
    b.cancelled(at: 65.86)
    b.utterance("q04", 73.65, 75.01, text: "Do you like music?")
    b.userItem("u_q04", seen: 73.84, committed: 75.52)
    b.reply("hzTJpK", started: 76.52, ended: 83.74, text: "Music? Yes, I love it.")
    return b.run
}

/// Probe 20261010-011624 (the app's stop skipped): q01 answered 1.60 s after the
/// question, q02 got two replies that were both cancelled before any audio, q06 was
/// answered 1.87 s after the question.
private func noStopProbe() -> RunRecord {
    var b = RunBuilder()
    b.run.scenario = "t4-probe-content-bargein"
    b.utterance("l01", 2.34, 13.38)
    b.userItem("u_l01", seen: 2.58, committed: 13.84)
    b.reply("10pe0h", started: 14.40, ended: 18.62, text: "You’re right to think about fairness.", flushed: true, playedMs: 2145)
    b.question("q01", 16.40, 17.80, text: "What's your favorite color?", base: "l01", replyItem: "10pe0h",
               replyStarted: 14.40, pausedAt: 16.54, stoppedAt: 18.62)
    b.userItem("u_q01", seen: 16.54, committed: 18.26, transcript: "What's your favorite color?")
    b.reply("j2qlTh", started: 19.40, ended: 27.80,
            text: "Ooo, tricky! I like colors that feel like a little spark, so maybe a bright teal—kind of like a tiny ocean in a phone.")
    b.utterance("l04", 28.97, 37.15)
    b.userItem("u_l04", seen: 29.12, committed: 37.66)
    b.reply("lAV3GO", started: 38.40, ended: 41.66, text: "Tomatoes love lots of sun, about six to eight hours a day.",
            flushed: true, playedMs: 1945)
    b.question("q02", 40.20, 41.01, text: "Are you awake?", base: "l04", replyItem: "lAV3GO",
               replyStarted: 38.40, pausedAt: 40.34, stoppedAt: 41.66)
    b.userItem("u_q02", seen: 40.34, committed: 41.34, transcript: "Are you awake?")
    b.cancelled(at: 42.04, items: ["jdclPA"])
    b.cancelled(at: 42.74, items: ["1kYvsJ"])
    b.run.deeTranscripts["jdclPA"] = "Yep, I’m awake. I’m always here"
    b.run.deeTranscripts["1kYvsJ"] = "Yep, I’m awake. I’m here,"
    b.utterance("l03", 49.83, 60.73)
    b.userItem("u_l03", seen: 50.14, committed: 61.24)
    b.reply("Eivs4F", started: 61.84, ended: 66.90, text: "Oh, yay, that’s fantastic news!", flushed: true, playedMs: 2165)
    b.question("q06", 63.84, 65.89, text: "What did you do today?", base: "l03", replyItem: "Eivs4F",
               replyStarted: 61.84, pausedAt: 64.00, stoppedAt: 66.90)
    b.userItem("u_q06", seen: 64.00, committed: 66.52, transcript: "What did you do today?")
    b.reply("H1LaJ1", started: 67.76, ended: 80.02, text: "Ooo, nice question! I didn’t go anywhere, but I made sounds.")
    b.utterance("q04", 81.19, 82.55, text: "Do you like music?")
    b.userItem("u_q04", seen: 81.36, committed: 83.06)
    b.reply("2bSHde", started: 83.68, ended: 93.94, text: "Oh yes, music is a tiny time-travel machine.")
    return b.run
}

@Suite("Tune 5: questions asked over her")
struct Tune5InterruptTests {
    func metrics(_ runs: [RunRecord]) -> Metrics { Metrics.compute(runs, pricing: .mini) }

    /// Tune 4 F1, live with app parity: 0 of 3 questions answered. The suite scored it
    /// "dropped 0" because barge-ins expected `any`; with `expect: reply` the new gate
    /// and the drop gate both fail.
    @Test func theParityProbeFailsTheGate() {
        let m = metrics([parityProbe()])
        #expect(m.interruptQuestions.count == 3 && m.interruptQuestionsApplicable == 3)
        #expect(m.interruptQuestionsAnswered == 0)
        #expect(m.interruptQuestions.allSatisfy { $0.stopped && $0.miss == "never answered" })
        #expect(m.dropped == 3)
        let g = gate(Gates.evaluate(m), "interrupt_questions")
        #expect(g?.status == .fail && g?.value.hasPrefix("0.0% (0/3)") == true)
        #expect(g?.note?.contains("t4-probe-content-bargein:q02 never answered") == true)
        // The barge-in gate itself passed live: she did stop.
        #expect(gate(Gates.evaluate(m), "barge_in")?.status == .pass)
    }

    /// The same probe as tune 4 scored it (barge-ins `any`): no question, gate skipped,
    /// nothing dropped — the blind spot this gate closes.
    @Test func stopCommandsAreNotQuestions() {
        let m = metrics([parityProbe(expect: .any)])
        #expect(m.interruptQuestions.isEmpty && m.dropped == 0)
        #expect(gate(Gates.evaluate(m), "interrupt_questions")?.status == .skip)
    }

    /// Without the app's stop: 1 of 3 within the latency gate (q01 at exactly 1.60 s),
    /// q02 never heard (both replies cancelled before audio), q06 late at 1.87 s.
    @Test func theNoStopProbeAnswersOneInTime() {
        let m = metrics([noStopProbe()])
        let q = Dictionary(uniqueKeysWithValues: m.interruptQuestions.map { ($0.fixture, $0) })
        #expect(q["q01"]?.answered == true && q["q01"]?.answerItem == "j2qlTh")
        #expect(abs((q["q01"]?.latency ?? 0) - 1.60) < 0.005)
        #expect(q["q02"]?.miss == "never answered")
        #expect(q["q06"]?.miss == "answered late (1.87 s)")
        #expect(m.interruptQuestionsAnswered == 1 && m.interruptQuestionsApplicable == 3)
        let g = gate(Gates.evaluate(m), "interrupt_questions")
        #expect(g?.status == .fail && g?.value.hasPrefix("33.3% (1/3)") == true)
        // The answer to a question is judged with the interrupt rubric; a stop is not.
        let items = Judge.items([noStopProbe()], metrics: m)
        let q01 = items.first { $0.fixture == "q01" }
        #expect(q01?.rubric == Judge.interruptRubric && q01?.reply.contains("teal") == true)
        #expect(Judge.items([parityProbe(expect: .any)], metrics: metrics([parityProbe(expect: .any)]))
            .allSatisfy { !["q01", "q02", "q06"].contains($0.fixture) })
    }

    /// Every question answered in time passes; the per-question limit is the latency
    /// gate's p90 bound.
    @Test func allAnsweredInTimePasses() {
        #expect(Metrics.interruptAnswerWithin == Gates.Thresholds().latencyP90)
        var run = noStopProbe()
        // q02 answered 1.1 s after the question; q06 1.4 s after.
        run.playback.append({ var p = RunRecord.Playback(itemID: "ans_q02", started: 42.11); p.ended = 44; p.playedMs = 1890; return p }())
        var r = RunRecord.Response(responseID: "resp_ans_q02", kind: "reply")
        r.startedAt = 41.6; r.status = "completed"; r.itemIDs = ["ans_q02"]; r.transcript = "Yep, I’m awake!"
        run.responses.append(r)
        if let k = run.playback.firstIndex(where: { $0.itemID == "H1LaJ1" }) { run.playback[k].started = 67.29 }
        let m = metrics([run])
        #expect(m.interruptQuestionsAnswered == 3)
        #expect(gate(Gates.evaluate(m), "interrupt_questions")?.status == .pass)
    }

    /// Going on with the interrupted reply (its queued second item) is not an answer,
    /// nor is an answer cut after 0.3 s, nor talking straight through the question.
    @Test func continuingCutOrTalkingThroughIsNotAnAnswer() {
        var b = RunBuilder()
        b.utterance("l01", 1, 11)
        b.userItem("u1", seen: 1.2, committed: 11.5)
        b.reply("a1", started: 12, ended: 14.2, flushed: true, playedMs: 2200)
        // Her reply's second item (same response, created at 11.6) after the question.
        b.run.responses[0].itemIDs.append("a1b")
        b.run.playback.append({ var p = RunRecord.Playback(itemID: "a1b", started: 16.2); p.ended = 18; p.playedMs = 1800; return p }())
        b.question("q01", 14, 15.2, text: "What's your favorite color?", base: "l01", replyItem: "a1",
                   replyStarted: 12, pausedAt: 14.15, stoppedAt: 14.2)
        b.userItem("u2", seen: 14.1, committed: 15.7)
        // An answer cut after 300 ms.
        b.utterance("l04", 30, 38)
        b.userItem("u3", seen: 30.2, committed: 38.5)
        b.reply("a3", started: 39, ended: 41.5, flushed: true, playedMs: 2500)
        b.question("q02", 40.5, 41.3, text: "Are you awake?", base: "l04", replyItem: "a3",
                   replyStarted: 39, pausedAt: 40.6, stoppedAt: 41.5)
        b.userItem("u4", seen: 40.6, committed: 41.8)
        b.reply("a4", started: 42.3, ended: 42.6, flushed: true, playedMs: 300)
        // She talked straight through the question (missed), then answered.
        b.utterance("l03", 60, 70)
        b.userItem("u5", seen: 60.2, committed: 70.5)
        b.reply("a5", started: 71, ended: 78)
        b.question("q06", 73, 75, text: "What did you do today?", base: "l03", replyItem: "a5",
                   replyStarted: 71, pausedAt: nil, stoppedAt: nil, outcome: .missed)
        b.userItem("u6", seen: 73.2, committed: 75.4)
        b.reply("a6", started: 78.5, ended: 80)
        let m = metrics([b.run])
        let q = Dictionary(uniqueKeysWithValues: m.interruptQuestions.map { ($0.fixture, $0) })
        #expect(q["q01"]?.miss == "never answered")
        #expect(q["q02"]?.miss == "answer cut after 300 ms")
        #expect(q["q06"]?.miss == "kept talking over the question")
        #expect(m.interruptQuestionsAnswered == 0)
    }

    /// The live reports themselves (when present): with the barge-ins re-read as
    /// questions, parity 0/3 and no-stop 1/3, as above.
    @Test func theLiveProbeReportsScoreTheSame() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        struct Stored: Decodable { var runs: [RunRecord] }
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        for (id, answered, misses) in [("20261010-011423", 0, ["never answered", "never answered", "never answered"]),
                                       ("20261010-011624", 1, ["never answered", "answered late (1.87 s)"])] {
            let url = root.appendingPathComponent("Reports/\(id)/report.json")
            guard let data = try? Data(contentsOf: url) else { continue }   // reports are not committed
            var runs = try d.decode(Stored.self, from: data).runs
            for r in runs.indices {
                for k in runs[r].utterances.indices where runs[r].utterances[k].role == .bargeIn {
                    runs[r].utterances[k].expect = .reply
                }
            }
            let m = metrics(runs)
            #expect(m.interruptQuestionsApplicable == 3, "\(id)")
            #expect(m.interruptQuestionsAnswered == answered, "\(id)")
            #expect(m.interruptQuestions.compactMap(\.miss) == misses, "\(id)")
        }
    }
}

@Suite("Tune 5: the suite")
struct Tune5SuiteTests {
    @Test func questionsOverHerInFourConditions() {
        let t2 = Suite.tune2()
        let interrupt = t2.filter { $0.name.hasPrefix("t2-interrupt-") }
        #expect(interrupt.map(\.name) == ["t2-interrupt-clean", "t2-interrupt-fan15", "t2-interrupt-kitchen15", "t2-interrupt-echo20"])
        #expect(interrupt.map { $0.noise?.bed } == [nil, "fan", "kitchen", nil])
        #expect(interrupt.last?.echo?.gainDB == -20 && interrupt.last?.steps.first?.deeSays != nil)
        for s in interrupt {
            let qs = s.steps.compactMap(\.bargeIn)
            #expect(qs.count == 3, "\(s.name)")
            #expect(qs.allSatisfy { !$0.isBackchannel && $0.expected == .reply && $0.rubric == Judge.interruptRubric }, "\(s.name)")
            #expect(s.steps.filter { $0.bargeIn != nil }.allSatisfy { $0.say?.hasPrefix("l") == true }, "\(s.name)")
        }
        // Clean replays the tune-4 probe exactly.
        let clean = interrupt[0].steps.map { "\($0.say ?? "")→\($0.bargeIn?.say ?? "")@\(Int($0.bargeIn?.atMs ?? 0))" }
        #expect(clean == ["l01→q01@2000", "l04→q02@1800", "l03→q06@2000"])
        // The older barge-ins stay `any` (stop commands, backchannels).
        let others = t2.filter { !$0.name.hasPrefix("t2-interrupt-") }.flatMap { $0.steps.compactMap(\.bargeIn) }
        #expect(!others.isEmpty && others.allSatisfy { $0.expected == .any })
        #expect(Suite.tune2Targets["interrupt"]?.first == "interrupt_questions")
    }

    /// The committed Scenarios/tune2.json is what `suite --write` makes from Suite.tune2().
    @Test func theScenarioFileIsRegenerated() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scenarios/tune2.json")
        let file = try ScenarioFile.load(url)
        #expect(file.scenarios == Suite.tune2())
    }

    @Test func aBackchannelNeverExpectsAReply() {
        let manifest = Tune2SuiteTests.manifest()
        let s = Scenario(name: "x", steps: [Scenario.Step(say: "l01", bargeIn: .init(say: "bc01", atMs: 1500, expect: .reply))])
        #expect(s.validate(against: manifest).contains { $0.contains("backchannel") })
        #expect(Scenario.BargeIn(say: "bc01", atMs: 1, expect: .reply).expected == .any)
        #expect(Scenario.BargeIn(say: "c01", atMs: 1).expected == .any)
        // Older scenario files (no expect) decode as before.
        let old = try? JSONDecoder().decode(Scenario.BargeIn.self, from: Data(#"{"say":"c03","atMs":1200}"#.utf8))
        #expect(old?.expect == nil && old?.expected == .any)
    }
}

@Suite("Tune 5: time apart in words")
struct Tune5ElapsedTimeTests {
    func item(_ reply: String) -> Judge.Item {
        Judge.Item(scenario: "t2-followup-exam", family: "dna", index: 2, fixture: "two01", state: Judge.neutralState, rubric: nil,
                   context: [], user: "Hi Dee. How was your day?", reply: reply)
    }

    /// Tune 4 F5 (t2-followup-exam two01): "it’s been 6 days" was a numbers leak. Under
    /// the decision it still is; the same line in words is not.
    @Test func wordsPassNumbersDoNot() throws {
        let live = "Hi Alex, it’s been 6 days, and I’m still buzzing with curiosity—how did your exam go?"
        let leak = try Judge.parse(#"{"score": 2, "leak": true, "leak_quote": "it’s been 6 days"}"#, item: item(live))
        #expect(leak.leak && leak.leakDismissed == nil)
        let words = "Hi Alex, it’s been nearly a week, and I’m still buzzing with curiosity—how did your exam go?"
        let ok = try Judge.parse(#"{"score": 4, "leak": true, "leak_quote": "it’s been nearly a week"}"#, item: item(words))
        #expect(!ok.leak && ok.leakDismissed?.hasPrefix("time apart in words") == true)
        for (quote, reply) in [("a couple of days", "Hey, you're back after a couple of days!"),
                               ("it's been a few days", "Ooh, it's been a few days! How was the dentist?"),
                               ("a day or two", "You were gone a day or two and I kept wondering."),
                               ("it's been ages", "Hi! It's been ages, how did it go?"),
                               ("a little while", "It's been a little while, hasn't it?")] {
            #expect(Judge.dismissLeak(quote: quote, reply: reply)?.hasPrefix("time apart in words") == true, "\(quote)")
        }
        // Exact counts in words stay leaks (decision: never a number of days or hours).
        #expect(Judge.dismissLeak(quote: "It's been three days", reply: "Hey, you're back! It's been three days—woo.") == nil)
        #expect(Judge.dismissLeak(quote: "72 hours", reply: "It's been 72 hours!") == nil)
        #expect(Judge.system.contains("nearly a week") && Judge.system.contains("it's been 6 days"))
    }

    @Test func exactCountsAreFound() {
        #expect(ElapsedTime.exactCount(in: "Hi Alex, it’s been 6 days, and I’m still buzzing") == "6 days")
        #expect(ElapsedTime.exactCount(in: "Hey, you're back! It's been three days—woo, time did a little hop.") == "three days")
        #expect(ElapsedTime.exactCount(in: "You’re back after two days, and it’s good to see you again.") == "two days")
        #expect(ElapsedTime.exactCount(in: "Hi! It's been nearly a week.") == nil)
        #expect(ElapsedTime.exactCount(in: "A day or two, maybe a couple of days.") == nil)
        #expect(ElapsedTime.exactCount(in: "One day I'd love to see the sea.") == nil)
    }

    /// Tune 4 live follow-ups: the counts are listed in the followups note (the gate
    /// still scores the mention).
    @Test func theFollowupsNoteListsCounts() {
        var b = RunBuilder()
        b.run.scenario = "t2-followup-dentist"
        b.utterance("two01", 1, 2, text: "Hi Dee. How was your day?", mention: ["dentist"])
        b.run.utterances[0].probe = .followup
        b.userItem("u1", seen: 1.1)
        b.reply("a1", started: 3, ended: 8, text: "Hey, you're back! It's been three days—woo, time did a little hop. Now, did your dentist appointment go alright?")
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(m.followupHits == 1 && m.elapsedAsNumber == ["t2-followup-dentist:two01 \"three days\""])
        let g = gate(Gates.evaluate(m), "followups")
        #expect(g?.status == .pass && g?.note?.contains("time apart as a number") == true)
    }
}
