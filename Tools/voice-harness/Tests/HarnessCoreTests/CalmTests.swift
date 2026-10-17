import Foundation
import Testing
@testable import HarnessCore

// Calm (spec "calm" §7.3, harness owner): Dee yields to sounds by ducking and stops only
// for real interruptions. The voice writes timed floor notes (contract §6.1); the
// harness turns them into per-event yield / silence / pauses / ducks, the `false_pause`,
// `false_barge` and `silence` gates and the redefined `barge_in` (yield).

private func gate(_ gates: [Gate], _ id: String) -> Gate? { gates.first { $0.id == id } }

extension RunBuilder {
    /// CloudVoice's timed notes, in one timeline turn.
    mutating func notes(_ list: [(Double, String)]) {
        run.timeline = [.init(id: 1, start: 0, marks: [:], details: [], events: list.map { .init(t: $0.0, text: $0.1) })]
    }

    /// An event said over reply `reply` (started `replyStarted`): a backchannel / sound
    /// (Dee goes on, `.missed`) or a barge-in.
    mutating func event(_ fixture: String, onset: Double, eos: Double, reply: String = "r1", replyStarted: Double = 10,
                        outcome: RunRecord.BargeOutcome = .missed, stoppedAt: Double? = nil, pausedAt: Double? = nil,
                        expect: Scenario.Expect = .any) {
        utterance(fixture, onset, eos, text: FixtureCatalog.spec(fixture)?.text ?? "", role: .bargeIn, expect: expect)
        let bc = TurnShape.isBackchannel(fixture) || TurnShape.isNonspeech(fixture)
        run.utterances[run.utterances.count - 1].backchannel = bc
        var b = RunRecord.BargeIn(step: run.utterances.count - 1, baseFixture: "l01", fixture: fixture, targetAtMs: 1500,
                                  replyItem: reply, replyStarted: replyStarted, onset: onset, stoppedAt: stoppedAt,
                                  outcome: outcome, backchannel: bc, nonspeech: TurnShape.isNonspeech(fixture) ? true : nil)
        b.step = run.utterances[run.utterances.count - 1].step
        b.pausedAt = pausedAt
        run.bargeIns.append(b)
    }

    /// A long ask and Dee's reply r1 (10 → `end` s).
    mutating func longReply(end: Double = 22, flushed: Bool = false) {
        utterance("l01", 1, 8)
        userItem("u_l01", seen: 1.2, committed: 8.6)
        reply("r1", started: 10, ended: end, flushed: flushed)
    }
}

@Suite("Calm: floor notes are parsed into events")
struct CalmFloorEventTests {
    @Test func everyContractStringParses() {
        func p(_ s: String) -> FloorEvent? { FloorEvent.parse(.init(t: 1, text: s)) }
        #expect(p("duck item_a gain=-12 via=onset") == .init(t: 1, kind: .duck, item: "item_a", why: "onset"))
        #expect(p("duck - gain=-6 via=detector") == .init(t: 1, kind: .duck, item: nil, why: "detector"))
        #expect(p("sustained item_a all=0.52 pitched=0.31")?.kind == .sustained)
        #expect(p("hold item_a why=sustained") == .init(t: 1, kind: .hold, item: "item_a", why: "sustained"))
        #expect(p("hold item_a")?.why == "legacy")                               // 0.6.0
        #expect(p("hold item_a (words)")?.why == "words")
        #expect(p("hold ended by the voice item_a") == nil)                      // the cut is its own event
        #expect(p("unduck item_a (wordsWait)") == .init(t: 1, kind: .unduck, item: "item_a", why: "wordsWait"))
        #expect(p("resumed item_a (nowords)") == .init(t: 1, kind: .resumed, item: "item_a", why: "nowords"))
        #expect(p("barge_in: item_a") == .init(t: 1, kind: .cut, item: "item_a"))
        #expect(p("barge_in: -") == .init(t: 1, kind: .cut, item: nil))
        #expect(p("ambient item_a reason=tvItemSustain")?.kind == .ambient)
        #expect(p("probe item_b")?.kind == .hold && p("probe over")?.kind == .resumed && p("probe confirmed item_b") == nil)
        #expect(p("words decide item_a") == nil && p("echo rejected item_a") == nil)
    }

    @Test func eventsAreTimeOrderedAcrossTurnsAndOldRecordsHaveNone() {
        var r = RunRecord(scenario: "s", model: "m", brain: "b", started: "t")
        #expect(r.floorEvents == nil)
        r.timeline = [.init(id: 1, start: 0, marks: [:], details: [], events: [.init(t: 5, text: "hold a why=answer")]),
                      .init(id: 2, start: 4, marks: [:], details: [], events: [.init(t: 4.5, text: "duck a gain=-12 via=onset"),
                                                                                  .init(t: 5, text: "barge_in: a")])]
        #expect(r.floorEvents?.map(\.kind) == [.duck, .hold, .cut])
        // A cut is marked at its pause's start (same time): it stays after the hold.
    }
}

@Suite("Calm: per-event yield, silence, pauses, ducks")
struct CalmMetricsTests {
    @Test func aDuckAloneIsNeverAPauseOrAStop() {
        var b = RunBuilder()
        b.longReply()
        b.event("bc02", onset: 12.0, eos: 12.35)
        b.notes([(12.33, "duck - gain=-12 via=onset"), (13.1, "unduck - (resume)")])
        let m = Metrics.compute([b.run], pricing: .mini)
        let u = try! #require(m.utterances.first { $0.fixture == "bc02" })
        #expect(abs((u.yield ?? -1) - 0.33) < 1e-9)
        #expect(u.silence == nil && u.stopped == false && u.audiblePause == false)
        #expect(abs((u.duckedSeconds ?? 0) - 0.77) < 1e-9 && u.pausedSeconds == 0)
        #expect(m.falsePauseApplicable == 1 && m.falsePauses == 0)
        #expect(m.duckTimes.count == 1 && abs(m.duckTimes[0] - 0.77) < 1e-9)
        #expect(m.floorApproximateRuns.isEmpty)
    }

    @Test func yieldIsTheFirstDuckOrHoldAndSilenceTheFirstHold() {
        var b = RunBuilder()
        b.longReply(end: 13.7, flushed: true)
        b.event("c03", onset: 12.0, eos: 13.4, outcome: .stopped, stoppedAt: 13.7, pausedAt: 12.62)
        b.notes([(12.35, "duck item_c gain=-12 via=onset"), (12.62, "sustained item_c all=0.50 pitched=0.40"),
                 (12.62, "hold item_c why=sustained"), (12.62, "barge_in: item_c")])
        let m = Metrics.compute([b.run], pricing: .mini)
        let u = try! #require(m.utterances.first { $0.fixture == "c03" })
        #expect(abs((u.yield ?? -1) - 0.35) < 1e-9 && abs((u.silence ?? -1) - 0.62) < 1e-9 && u.stopped == true)
        #expect(m.yieldLatencies.count == 1 && abs(m.yieldLatencies[0] - 0.35) < 1e-9 && m.yieldMissed == 0)
        #expect(m.silenceMulti.count == 1 && abs(m.silenceMulti[0] - 0.62) < 1e-9)
        #expect(m.stopCommands == 1 && m.stopCommandsEnded == 1)
        let g = Gates.evaluate(m)
        #expect(gate(g, "barge_in")?.status == .pass && gate(g, "silence")?.status == .pass)
    }

    @Test func aPauseIsAudibleFromATenthOfASecond() {
        func run(resumeAfter: Double) -> Metrics.Utterance {
            var b = RunBuilder()
            b.longReply()
            b.event("ns01", onset: 12.0, eos: 12.3)
            b.notes([(12.3, "duck - gain=-12 via=onset"), (12.5, "sustained - all=0.50 pitched=0.30"),
                     (12.5, "hold - why=sustained"), (12.5 + resumeAfter, "resumed - (nowords)")])
            return Metrics.compute([b.run], pricing: .mini).utterances.first { $0.fixture == "ns01" }!
        }
        #expect(run(resumeAfter: 0.10).audiblePause == true)
        #expect(run(resumeAfter: 0.08).audiblePause == false)
        #expect(abs((run(resumeAfter: 0.4).pausedSeconds ?? 0) - 0.4) < 1e-9)
        #expect(run(resumeAfter: 0.4).stopped == false)
    }

    @Test func aHoldThatEndsInACutIsAStopAndALongSoundStopFails() {
        var b = RunBuilder()
        b.longReply(end: 14.0, flushed: true)
        b.event("ns10", onset: 12.0, eos: 13.2, outcome: .stopped, stoppedAt: 14.0, pausedAt: 12.55)
        b.notes([(12.3, "duck - gain=-12 via=onset"), (12.55, "hold - why=sustained"), (12.55, "barge_in: -")])
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(m.longSoundApplicable == 1 && m.longSoundStops == 1 && m.longSoundPauses == 1)
        #expect(m.falsePauseApplicable == 0)                      // long sounds are their own gate
        #expect(m.backchannels == 0)                              // sounds are not word backchannels
        #expect(gate(Gates.evaluate(m), "false_pause_long")?.status == .fail)
        #expect(m.utterances.first { $0.fixture == "ns10" }?.problems.contains("stopped on a sound") == true)
    }

    @Test func aRealInterruptionWithNoYieldWithinTwoSecondsIsMissed() {
        var b = RunBuilder()
        b.longReply()
        b.event("c01", onset: 12.0, eos: 12.4, outcome: .missed)
        b.notes([(14.5, "duck - gain=-12 via=final")])
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(m.yieldApplicable == 1 && m.yieldMissed == 1 && m.yieldLatencies.isEmpty)
        #expect(m.stopCommands == 1 && m.stopCommandsEnded == 0 && m.stopCommandMisses == ["s:c01 (never ended)"])
        let g = Gates.evaluate(m)
        #expect(gate(g, "barge_in")?.status == .fail && gate(g, "silence")?.status == .fail)
    }

    @Test func loneStopWordsHaveTheirOwnBound() {
        var b = RunBuilder()
        b.longReply(end: 13.1, flushed: true)
        b.event("c08", onset: 12.0, eos: 12.35, outcome: .stopped, stoppedAt: 13.1, pausedAt: 12.95)
        b.notes([(12.33, "duck - gain=-12 via=onset"), (12.95, "hold item_w why=stopword"), (12.95, "barge_in: item_w")])
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(m.silenceLone.count == 1 && abs(m.silenceLone[0] - 0.95) < 1e-9 && m.silenceMulti.isEmpty)
        #expect(gate(Gates.evaluate(m), "silence")?.status == .pass)     // round 2: 0.60 s after "Wait." ends ≤ 1.0
        var t = Gates.Thresholds()
        t.silenceFromOnset = true                                         // round 1's bounds, from the onset
        #expect(gate(Gates.evaluate(m, thresholds: t), "silence")?.status == .pass)     // 0.95 ≤ 1.1
        t.silenceLoneP90 = 0.9
        #expect(gate(Gates.evaluate(m, thresholds: t), "silence")?.status == .fail)
    }
}

@Suite("Calm: the false_pause gate")
struct CalmFalsePauseGateTests {
    /// `n` short events over one long reply, `paused` of them with a 0.4 s pause.
    func metrics(n: Int, paused: Int, soundStop: Bool = false) -> Metrics {
        var b = RunBuilder()
        b.utterance("l01", 1, 8)
        b.reply("r1", started: 10, ended: 10 + Double(n) * 3 + 5, flushed: soundStop)
        var notes: [(Double, String)] = []
        let ids = ["bc02", "bc03", "ns01", "ns04", "bc06", "ns07", "bc11", "ns06"]
        for k in 0..<n {
            let onset = 12 + Double(k) * 3
            let id = ids[k % ids.count]
            b.event(id, onset: onset, eos: onset + 0.4)
            notes.append((onset + 0.35, "duck - gain=-12 via=onset"))
            if k < paused {
                notes += [(onset + 0.6, "hold - why=sustained"), (onset + 1.0, "resumed - (nowords)")]
            } else {
                notes.append((onset + 1.1, "unduck - (resume)"))
            }
        }
        if soundStop {
            b.event("ns03", onset: 12 + Double(n) * 3, eos: 12.4 + Double(n) * 3, outcome: .stopped,
                    stoppedAt: 13 + Double(n) * 3, pausedAt: 12.5 + Double(n) * 3)
        }
        b.notes(notes)
        return Metrics.compute([b.run], pricing: .mini)
    }

    @Test func exactlyFivePercentPassesAndAboveFails() {
        let pass = metrics(n: 40, paused: 2)
        #expect(pass.falsePauseApplicable == 40 && pass.falsePauses == 2)
        #expect(gate(Gates.evaluate(pass), "false_pause")?.status == .pass)
        let fail = metrics(n: 40, paused: 3)
        #expect(gate(Gates.evaluate(fail), "false_pause")?.status == .fail)
        #expect(gate(Gates.evaluate(fail), "false_pause")?.note?.contains("pause 0.40 s") == true)
    }

    @Test func underPoweredIsNotAPassAndAnyStopOnASoundFails() {
        let small = metrics(n: 20, paused: 0)
        let g = try! #require(gate(Gates.evaluate(small), "false_pause"))
        #expect(g.status == .skip && g.note?.contains("under-powered") == true)
        let stop = metrics(n: 40, paused: 0, soundStop: true)
        #expect(stop.falsePauseSoundStops == 1)
        #expect(gate(Gates.evaluate(stop), "false_pause")?.status == .fail)
    }

    @Test func pausedEventsAreProblemsForTheRegressionsSection() {
        let m = metrics(n: 4, paused: 1)
        #expect(m.utterances.filter { $0.problems.contains("paused on a continuer") || $0.problems.contains("paused on a sound") }.count == 1)
    }
}

@Suite("Calm: false_barge per Dee-talking minute")
struct CalmFalseBargeTests {
    func tvRun(_ notes: [(Double, String)], condition: (String, Double) = ("tvlong", 10)) -> RunRecord {
        var b = RunBuilder()
        b.run.scenario = "calm-tv-bed"
        b.run.noise = .init(bed: condition.0, snrDb: condition.1)
        b.utterance("l01", 1, 8)
        b.userItem("u_l01", seen: 1.2, committed: 8.6)
        b.reply("r1", started: 10, ended: 40)          // 30 s of Dee
        b.reply("r2", started: 50, ended: 80)          // another 30 s: 1.0 Dee-minute
        b.userItem("u_tv", seen: 20.5, committed: 21.5, transcript: "In tonight's news.")
        b.notes(notes)
        return b.run
    }

    @Test func perDeeMinuteWithTheScriptedAudioExcluded() {
        // 8.2 s: within 0.3 s of the user's end of speech (8.0) — but Dee is not playing
        // then, so it is not counted either way. 20.6 s: a TV pause (counted). 10.1 s:
        // a cut of the l01 item (scripted item: excluded). Ducks are counted apart.
        let run = tvRun([(8.2, "hold - why=localOnly"), (10.1, "hold u_l01 why=brain"), (10.1, "barge_in: u_l01"),
                         (20.5, "duck u_tv gain=-6 via=onset"), (20.6, "hold u_tv why=answer"), (21.6, "resumed u_tv (words)"),
                         (60, "duck - gain=-6 via=detector"), (61, "unduck - (noItem)")])
        let m = Metrics.compute([run], pricing: .mini)
        let fb = try! #require(m.falseBarge["tvlong10"])
        #expect(abs(fb.deeMinutes - 1.0) < 1e-9)
        #expect(fb.pauses == 1 && fb.stops == 0 && fb.ducks == 2)
        #expect(abs((fb.pausesPer10 ?? 0) - 10) < 1e-9)
        #expect(gate(Gates.evaluate(m), "false_barge")?.status == .fail)        // 10 per 10 > 2
    }

    @Test func theMarginIsPointThreeSecondsAroundScriptedAudio() {
        var b = RunBuilder()
        b.run.noise = .init(bed: "tv", snrDb: 15)
        b.utterance("l01", 1, 8)
        b.reply("r1", started: 10, ended: 70)                                     // 1 Dee-minute
        b.event("bc02", onset: 20, eos: 20.4)
        b.notes([(19.75, "hold - why=localOnly"), (19.75, "barge_in: -"), (20.75, "hold - why=localOnly"),
                 (20.8, "resumed - (tail)")])
        let m = Metrics.compute([b.run], pricing: .mini)
        let fb = try! #require(m.falseBarge["tv15"])
        // 19.75 (onset − 0.25) and its cut are excluded; 20.75 (EoS + 0.35) is not.
        #expect(fb.pauses == 1 && fb.stops == 0)
        #expect(gate(Gates.evaluate(m), "false_barge")?.status == .fail)        // 10 per 10 > 1
    }

    @Test func aQuietTVRunPassesAndAnyCutFails() {
        let quiet = Metrics.compute([tvRun([(30, "duck - gain=-6 via=onset"), (30.5, "unduck - (wordsWait)")])], pricing: .mini)
        #expect(gate(Gates.evaluate(quiet), "false_barge")?.status == .pass)
        #expect(gate(Gates.evaluate(quiet), "false_barge")?.value.contains("ducks 1.0/min") == true)
        let cut = Metrics.compute([tvRun([(30, "hold - why=localOnly"), (30, "barge_in: -")])], pricing: .mini)
        #expect(cut.falseBarge["tvlong10"]?.stops == 1)
        #expect(gate(Gates.evaluate(cut), "false_barge")?.status == .fail)
    }

    @Test func conditionsAreReadFromTheRecord() {
        var r = RunRecord(scenario: "x", model: "m", brain: "b", started: "t")
        #expect(Metrics.condition(of: r) == "clean")
        r.noise = .init(bed: "tvlong", snrDb: 10)
        #expect(Metrics.condition(of: r) == "tvlong10")
        r.echo = EchoConfig(gainDB: -20, delayMs: 80)
        #expect(Metrics.condition(of: r) == "echo20")
    }
}

@Suite("Calm: old reports are scored approximately")
struct CalmApproximateTests {
    @Test func aReportWithoutTimedNotesIsApproximateAndNeverCrashes() {
        // 0.6.0: every onset over Dee paused Dee (hold ≈ onset + 0.15 s), no ducks.
        var b = RunBuilder()
        b.longReply(end: 16, flushed: true)
        b.event("bc02", onset: 12.0, eos: 12.35)                                   // continued
        b.event("c01", onset: 14.0, eos: 14.4, outcome: .stopped, stoppedAt: 16, pausedAt: 14.3)
        b.run.timeline = [.init(id: 1, start: 0, marks: ["barge_in": 14.3], details: ["note: hold -"])]
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(m.floorApproximateRuns == ["s"])
        let bc = try! #require(m.utterances.first { $0.fixture == "bc02" })
        #expect(bc.floorApproximate == true && bc.audiblePause == true && abs((bc.yield ?? 0) - 0.15) < 1e-9)
        #expect(m.falsePauses == 1 && m.falseBarge.isEmpty)
        // The redefined barge_in reads the old latency (the pause mark) exactly as before.
        #expect(m.yieldLatencies.count == 1 && abs(m.yieldLatencies[0] - 0.3) < 1e-9)
        let g = Gates.evaluate(m)
        #expect(gate(g, "barge_in")?.note?.contains("approximate") == true)
        #expect(gate(g, "false_pause")?.note?.contains("approximate") == true)
        #expect(gate(g, "false_barge")?.status == .skip)
    }

    @Test func oldJSONDecodes() throws {
        let json = #"{"id":1,"start":0,"marks":{"barge_in":3.2},"details":["note: hold a"]}"#
        let t = try JSONDecoder().decode(RunRecord.TimelineTurn.self, from: Data(json.utf8))
        #expect(t.events == nil)
        let u = #"{"index":1,"step":0,"fixture":"bc02","role":"bargeIn","text":"Mm-hm.","start":1,"onset":1.1,"endOfSpeech":1.5,"spans":[],"expect":"any"}"#
        let utt = try JSONDecoder().decode(RunRecord.Utterance.self, from: Data(u.utf8))
        #expect(utt.nonspeech == nil && utt.isBackchannel && !utt.isNonspeech)
    }

    @Test func theYieldFlagRestoresTheOldBargeInGate() {
        var b = RunBuilder()
        b.longReply(end: 12.8, flushed: true)
        b.event("c03", onset: 12.0, eos: 13.4, outcome: .stopped, stoppedAt: 12.8, pausedAt: 12.7)
        b.notes([(12.3, "duck - gain=-12 via=onset"), (12.7, "hold - why=sustained"), (12.7, "barge_in: -")])
        let m = Metrics.compute([b.run], pricing: .mini)
        var t = Gates.Thresholds()
        #expect(gate(Gates.evaluate(m, thresholds: t), "barge_in")?.value.hasPrefix("p50 0.30 s") == true)
        t.bargeInMeasuresYield = false
        #expect(gate(Gates.evaluate(m, thresholds: t), "barge_in")?.value.hasPrefix("p50 0.70 s") == true)
    }
}

@Suite("Calm: fixtures and the focused suite")
struct CalmSuiteTests {
    @Test func newFixturesAreCatalogedAndNotCore() {
        #expect(FixtureCatalog.core.count == 62)
        let ids = ["ns01", "ns02", "ns03", "ns04", "ns05", "ns06", "ns07", "ns08", "ns09", "ns10", "ns11",
                   "bc03", "bc04", "bc05", "bc06", "bc07", "bc08", "bc09", "bc10", "bc11", "bc12", "c07", "c08"]
        for id in ids { #expect(FixtureCatalog.spec(id) != nil, "\(id)") }
        #expect(Set(FixtureCatalog.all.map(\.id)).count == FixtureCatalog.all.count)      // no id collides
        #expect(ids.filter { TurnShape.isNonspeech($0) }.count == 11)
        #expect(TurnShape.soundClass("ns10") == .long && TurnShape.soundClass("ns11") == .long && TurnShape.soundClass("ns07") == .short)
        for k in 1...12 { #expect(TurnShape.isBackchannel(String(format: "bc%02d", k))) }
        #expect(!TurnShape.isBackchannel("c07") && !TurnShape.isBackchannel("c08"))
        for spec in FixtureCatalog.all where spec.engine == .dsp {
            #expect(Nonspeech.render(spec.voice, sampleRate: 24_000) != nil, "\(spec.id)")
        }
    }

    @Test func soundsAreSeededShortAndLong() {
        for r in Nonspeech.recipes {
            let a = Nonspeech.render(r, sampleRate: 24_000)!, b = Nonspeech.render(r, sampleRate: 24_000)!
            #expect(a == b, "\(r) is not byte-stable")
        }
        for spec in FixtureCatalog.all where spec.engine == .dsp {
            let raw = Nonspeech.render(spec.voice, sampleRate: 24_000)!
            let f = FixtureAssembler.assemble([.audio(raw)], sampleRate: 24_000, levelDB: spec.style.levelDB)
            let voiced = Double(f.endOfSpeech - f.onset) / 24_000
            if spec.soundClass == .short { #expect(voiced <= 0.65, "\(spec.id) \(voiced) s") } else { #expect(voiced >= 0.9, "\(spec.id) \(voiced) s") }
            #expect(abs(DSP.activeLevelDB(f.samples, sampleRate: 24_000) + 24) < 1.5, "\(spec.id)")
        }
    }

    @Test func manifestClassRoundTripsAsClass() throws {
        let u = FixtureManifest.Utterance(id: "ns01", file: "f", category: .nonspeech, engine: .dsp, voice: "cough", style: .neutral,
                                          text: "", sampleRate: 24_000, samples: 10, onsetSample: 0, endOfSpeechSample: 10,
                                          spans: [], scriptedPauses: [], activeLevelDB: -24, soundClass: .short)
        let data = try JSONEncoder().encode(u)
        #expect(String(decoding: data, as: UTF8.self).contains(#""class":"short""#))
        #expect(try JSONDecoder().decode(FixtureManifest.Utterance.self, from: data).soundClass == .short)
    }

    /// The real manifest plus estimated entries for fixtures not rendered yet.
    func manifest() throws -> FixtureManifest {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/manifest.json")
        var m = try FixtureManifest.load(url)
        for spec in FixtureCatalog.all where m.utterance(spec.id) == nil {
            let seconds = spec.engine == .dsp
                ? Double(Nonspeech.render(spec.voice, sampleRate: 24_000)!.count) / 24_000
                : 0.4 + 0.33 * Double(spec.text.split(separator: " ").count)
            let n = Int((seconds + 0.55) * 24_000)
            m.utterances.append(.init(id: spec.id, file: "", category: spec.category, engine: spec.engine, voice: spec.voice,
                                      style: spec.style, text: spec.text, sampleRate: 24_000, samples: n, onsetSample: 3600,
                                      endOfSpeechSample: n - 9600, spans: [], scriptedPauses: [], activeLevelDB: -24,
                                      soundClass: spec.soundClass))
        }
        return m
    }

    @Test func theCalmSuiteIsTheSpecsAndFitsTheBudget() throws {
        let suite = Suite.calm()
        #expect(suite.map(\.name) == ["calm-sounds-clean", "calm-sounds-tv15", "calm-bc-clean", "calm-bc-tv15", "calm-tv-bed",
                                      "calm-ask-clean", "calm-ask-tv15", "calm-bc-echo20"])
        let m = try manifest()
        for s in suite { #expect(s.validate(against: m).isEmpty, "\(s.validate(against: m))") }
        func events(_ name: String) -> [Scenario.BargeIn] { suite.first { $0.name == name }!.steps.flatMap(\.bargeIns) }
        #expect(events("calm-sounds-clean").count == 12 && events("calm-sounds-tv15").count == 12)
        #expect(events("calm-bc-clean").count == 12 && events("calm-bc-tv15").count == 12)
        #expect(Set(events("calm-bc-clean").map(\.say)) == FixtureCatalog.singleClauseContinuers)
        #expect(events("calm-tv-bed").isEmpty && suite.first { $0.name == "calm-tv-bed" }!.noise == .init(bed: "tvlong", snrDb: 10))
        #expect(events("calm-ask-clean").map(\.say) == ["c01", "c03", "c07", "c08", "q01", "q03"])
        #expect(events("calm-ask-clean").filter { $0.expected == .reply }.map(\.say) == ["c07", "q01", "q03"])
        #expect(Set(events("calm-bc-echo20").map(\.say)) == ["bc03", "bc04", "ns01", "ns07"])
        let all = suite.flatMap { s in s.steps.flatMap(\.bargeIns) }
        let short = all.filter { FixtureCatalog.singleClauseContinuers.contains($0.say) || TurnShape.soundClass($0.say) == .short }
        #expect(short.count >= 44)                                                   // false_pause n ≥ 40
        #expect(all.filter { TurnShape.soundClass($0.say) == .long }.count == 4)
        #expect(all.filter { !$0.isBackchannel }.count == 12)
        #expect(all.filter(\.isNonspeech).allSatisfy { $0.nonspeech == true })
        #expect(all.contains { $0.gainDB == Suite.calmLoudGain })
        // Two events per long reply, the second 3.5 s after the first.
        for s in suite where s.name.hasPrefix("calm-sounds") || s.name.hasPrefix("calm-bc") {
            for st in s.steps where st.say != nil && !st.bargeIns.isEmpty {
                #expect(st.bargeIns.count == 2 && st.bargeIns[1].atMs - st.bargeIns[0].atMs == Suite.calmSecondAfter)
            }
        }
        // Budget: ≤ 25 min of real time and ≤ $1.20 projected (`validate`).
        let pricing = Pricing.forModel("gpt-realtime-2.1-mini")
        var usd = 0.0, seconds = 0.0
        for s in suite {
            let userSeconds = s.fixtureIDs.compactMap { m.utterance($0)?.speechSeconds }.reduce(0, +)
            usd += pricing.projected(replies: s.expectedReplyCount, userSeconds: userSeconds)
            seconds += RunEstimate.seconds(s, manifest: m)
        }
        print(String(format: "calm projection: %.1f min, $%.3f (live ≈ $%.3f)", seconds / 60, usd, usd * RunEstimate.liveOverProjection))
        #expect(seconds / 60 <= 25, "projected \(seconds / 60) min")
        #expect(usd <= 1.20, "projected $\(usd)")
    }

    @Test func eventsOverOneReplyValidate() {
        let ok = Scenario(name: "x", steps: [Scenario.Step(say: "l01", events: [.init(say: "bc02", atMs: 1500), .init(say: "c01", atMs: 5000)])])
        #expect(ok.validate(against: try! manifest()).isEmpty)
        #expect(ok.bargeInCount == 2 && ok.fixtureIDs == ["l01", "bc02", "c01"])
        let close = Scenario(name: "y", steps: [Scenario.Step(say: "l01", events: [.init(say: "bc02", atMs: 1500), .init(say: "bc03", atMs: 2500)])])
        #expect(close.validate(against: try! manifest()).contains { $0.contains("≥ 1.5 s apart") })
        let stopFirst = Scenario(name: "z", steps: [Scenario.Step(say: "l01", events: [.init(say: "c01", atMs: 1500), .init(say: "bc03", atMs: 5000)])])
        #expect(stopFirst.validate(against: try! manifest()).contains { $0.contains("only the last event") })
        // A sound is scored like a backchannel; its expect stays `any`.
        #expect(Scenario.BargeIn(say: "ns01", atMs: 1).isBackchannel && Scenario.BargeIn(say: "ns01", atMs: 1).expected == .any)
    }

    @Test func newConditionsAreOutsideTheAcousticMatrix() {
        #expect(Suite.acoustic().count == 56)
        #expect(Suite.extraConditions.map(\.id) == ["tv10", "tvlong10"])
    }
}
