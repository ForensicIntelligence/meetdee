import Foundation
import Testing
@testable import HarnessCore

// Calm round 2 (harness owner). The user, after 0.6.0: "it's too sensitive to
// interruptions" (background noise / TV, short sounds). Round 1's live check (NOT-SHIP)
// found harness faults too; these tests pin the fixes and the D1 gates:
//  (a) a re-synthesized sound that speaks words is rejected (F0); silent renders are caught;
//  (b) Dee's own sentence / token cap ending a reply over a sound or continuer is not a
//      stop (T3), unless Dee then answered the sound;
//  (c) every run / replay gets its own report folder;
//  (d) yield p90 ≤ 0.4 s, stop-phrase silence p90 ≤ 1.0 s, TV false_barge 0;
//  (e) `Scenarios/calm2.json` = calm + the tune-2 subset.

private func gate(_ gates: [Gate], _ id: String) -> Gate? { gates.first { $0.id == id } }

@Suite("Calm round 2: a sound fixture never speaks words")
struct CalmR2SoundWordTests {
    @Test func round1sSpokenCoughsAreWords() {
        // The live server's transcripts of round 1's TTS "coughs".
        for t in ["Cough, cough.", "Puff, puff.", "Coughing fit.", "Too."] { #expect(SoundWords.hasWords(t), "\(t)") }
    }

    @Test func soundsAndVocalizationsAreNotWords() {
        for t in ["", "Ha ha!", "Hahaha.", "Heh.", "Mm-hm.", "MMHM.", "Uh.", "Hmm?", "[laughter]", "(coughs)", "*cough cough*",
                  "Ahem.", "Uh-huh"] {
            #expect(!SoundWords.hasWords(t), "\(t)")
        }
        #expect(SoundWords.lexicalWords(in: "(laughs) Okay, a cough.") == ["okay", "a", "cough"])
    }

    @Test func resynthKeepsTheSeededSoundUnlessTheCandidateIsBetterAndWordless() {
        // Round 1: cough 0.00 → 0.02, and it said "Cough, cough." — kept then; rejected now.
        #expect(ResynthDecision.decide(current: 0.0, candidate: 0.02, candidateTranscript: "Cough, cough.") != .accept)
        if case .reject(let why) = ResynthDecision.decide(current: 0.0, candidate: 0.9, candidateTranscript: "Coughing fit.") {
            #expect(why.contains("speaks words"))
        } else { Issue.record("a worded candidate was accepted") }
        #expect(ResynthDecision.decide(current: 0.0, candidate: 0.02, candidateTranscript: "") != .accept)    // under the bar
        #expect(ResynthDecision.decide(current: 0.5, candidate: 0.45, candidateTranscript: "") != .accept)    // not better
        #expect(ResynthDecision.decide(current: 0.0, candidate: 0.6, candidateTranscript: nil) != .accept)    // unchecked
        #expect(ResynthDecision.decide(current: 0.0, candidate: 0.6, candidateTranscript: "") == .accept)
        #expect(ResynthDecision.decide(current: 0.1, candidate: 0.6, candidateTranscript: "(coughs)") == .accept)
    }

    @Test func theVoicedCoughsAreLabelledAndTheSeededOnesStay() {
        for id in ["ns12", "ns13", "ns14"] {
            let s = try! #require(FixtureCatalog.spec(id))
            #expect(s.category == .nonspeech && s.engine == .say && s.voice == "Albert" && s.sayRate != nil)
            #expect(FixtureCatalog.expectedSoundLabel[id] == "cough" && !FixtureCatalog.knownUnlabelled.contains(id))
        }
        #expect(FixtureCatalog.spec("ns12")?.soundClass == .short && FixtureCatalog.spec("ns13")?.soundClass == .short)
        #expect(FixtureCatalog.spec("ns14")?.soundClass == .long)
        // The seeded DSP coughs are kept (documented misses), never replaced by TTS.
        for id in ["ns01", "ns02", "ns11"] {
            #expect(FixtureCatalog.spec(id)?.engine == .dsp && FixtureCatalog.knownUnlabelled.contains(id))
        }
        #expect(FixtureCatalog.spec("ns12")?.effectiveSayRate == 185)
        #expect(FixtureCatalog.spec("bc10")?.effectiveSayRate == FixtureStyle.soft.sayRate)
        #expect(FixtureCatalog.spec("bc10")?.engine == .say)          // TTS came back as silence
    }

    @Test func aSilentFixtureFailsValidation() {
        let silent = FixtureManifest.Utterance(id: "bc03", file: "f", category: .backchannel, engine: .openai, voice: "alloy",
                                               style: .neutral, text: "Yeah.", sampleRate: 24_000, samples: 13_200,
                                               onsetSample: 0, endOfSpeechSample: 13_200, spans: [], scriptedPauses: [],
                                               activeLevelDB: -240)
        let l01 = FixtureManifest.Utterance(id: "l01", file: "g", category: .longTurn, engine: .openai, voice: "verse",
                                            style: .neutral, text: "x", sampleRate: 24_000, samples: 48_000, onsetSample: 3600,
                                            endOfSpeechSample: 40_000, spans: [.init(start: 3600, end: 40_000)],
                                            scriptedPauses: [], activeLevelDB: -24)
        let m = FixtureManifest(generatedAt: "t", notes: "", utterances: [silent, l01], noise: [], impulseResponses: [])
        let s = Scenario(name: "x", steps: [Scenario.Step(say: "l01", events: [.init(say: "bc03", atMs: 1500, backchannel: true)])])
        #expect(s.validate(against: m).contains { $0.contains("bc03 is silent") })
    }

    @Test func aSoundTheServerHeardAsWordsIsFlagged() {
        var b = RunBuilder()
        b.longReply()
        b.event("ns02", onset: 12.0, eos: 12.6)
        b.userItem("u_ns", seen: 12.1, committed: 13.0, transcript: "Cough, cough.")
        b.notes([(12.2, "duck u_ns gain=-12 via=onset"), (13.4, "unduck u_ns (resume)")])
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(m.soundsHeardAsWords == ["s:ns02 «Cough, cough.»"])
        #expect(gate(Gates.evaluate(m), "false_pause")?.note?.contains("heard as WORDS") == true)
    }
}

@Suite("Calm round 2: Dee's own cap ending a reply over a sound or continuer")
struct CalmR2OwnCapTests {
    /// A sound (or continuer) over r1; Dee's reply flushed at `stop` with a brain mark.
    func capRun(_ fixture: String = "ns09", onset: Double = 156.14, eos: Double = 156.9, stop: Double = 157.32,
                mark: String = "sentenceCapStop", markAt: Double = 157.30, answerAt: Double? = nil,
                notes extra: [(Double, String)] = [], timed: Bool = true) -> RunRecord {
        var b = RunBuilder()
        b.utterance("l02", 140, 150)
        b.reply("r1", started: 153.74, ended: stop, flushed: true)
        b.event(fixture, onset: onset, eos: eos, replyStarted: 153.74, outcome: .stopped, stoppedAt: stop, pausedAt: markAt)
        if let answerAt { b.reply("r2", started: answerAt, ended: answerAt + 5.9) }
        b.run.brainTrace = [.init(t: markAt, text: mark), .init(t: markAt, text: "bargeInSensed")]
        // Live (202402 calm-sounds-clean ns09): duck, then the cap's stop under the duck.
        if timed {
            b.notes([(156.36, "duck u_ns gain=-12 via=onset")] + extra
                    + [(markAt, "hold u_ns why=brain"), (markAt, "flushed: r1 played_ms=3560"), (markAt, "barge_in: u_ns")])
        }
        return b.run
    }

    @Test func aSentenceCapOverASoundIsNotAStop() {
        let run = capRun()
        #expect(Metrics.ownCapEnd(run, run.bargeIns[0]) == 157.30)
        #expect(Metrics.scoredOutcome(run, run.bargeIns[0]) == .missed)
        let m = Metrics.compute([run], pricing: .mini)
        #expect(m.falsePauseApplicable == 1 && m.falsePauses == 0 && m.falsePauseSoundStops == 0)
        #expect(m.ownCapEnds == ["s:ns09"] && m.answeredAfterOwnCap.isEmpty)
        #expect(m.utterances.first { $0.fixture == "ns09" }?.stopped == false)
    }

    @Test func aTokenLimitStopCountsToo() {
        // Live 193633 calm-bc-tv15 bc02: tokenLimitStop 90.30, flush 90.32, 2.1 s after the onset.
        let run = capRun("bc02", onset: 88.16, eos: 88.6, stop: 90.32, mark: "tokenLimitStop", markAt: 90.30)
        let m = Metrics.compute([run], pricing: .mini)
        #expect(m.backchannelStops == 0 && m.backchannelsApplicable == 1 && m.backchannelCapEnds == ["s:bc02"])
        #expect(m.falsePauses == 0)
        #expect(gate(Gates.evaluate(m), "backchannel")?.status == .pass)
    }

    @Test func answeringTheSoundAfterTheCapIsStillAStop() {
        // Live: the brain then answered the empty-transcript laugh (a 5.9 s reply at 157.68).
        let run = capRun(answerAt: 158.36)
        #expect(Metrics.scoredOutcome(run, run.bargeIns[0]) == .stopped)
        let m = Metrics.compute([run], pricing: .mini)
        #expect(m.answeredAfterOwnCap == ["s:ns09"] && m.ownCapEnds.isEmpty)
        #expect(m.falsePauseSoundStops == 1)
        #expect(m.falsePauseList.contains { $0.contains("answered after Dee's own cap end") })
        #expect(gate(Gates.evaluate(m), "false_pause")?.status == .fail)
    }

    @Test func aPauseBeforeTheCapStillCounts() {
        // The voice paused Dee for the continuer (0.66 s), resumed, then the cap ended the reply.
        let run = capRun("bc02", onset: 88.16, eos: 88.6, stop: 90.32, mark: "tokenLimitStop", markAt: 90.30,
                         notes: [(88.6, "hold u_ns why=sustained"), (89.26, "resumed u_ns (words)")])
        let m = Metrics.compute([run], pricing: .mini)
        #expect(m.falsePauses == 1 && m.falsePauseStops == 0)
        #expect(m.falsePauseList.first?.contains("pause 0.66 s") == true)
    }

    @Test func aCapMarkAwayFromTheFlushOrAnOldRecordIsUnchanged() {
        // The cap fired a second before the flush: something else cut Dee.
        let early = capRun(markAt: 156.30)
        #expect(Metrics.ownCapEnd(early, early.bargeIns[0]) == nil)
        // No timed notes (0.6.0 records): tune 14's stricter rule only.
        let old = capRun(timed: false)
        #expect(Metrics.ownCapEnd(old, old.bargeIns[0]) == nil && Metrics.scoredOutcome(old, old.bargeIns[0]) == .stopped)
        // A real interruption is never re-scored.
        let stop = capRun("c01", onset: 156.14, eos: 156.6)
        #expect(Metrics.ownCapEnd(stop, stop.bargeIns[0]) == nil)
    }
}

@Suite("Calm round 2: D1 gates")
struct CalmR2GateTests {
    func interruption(_ fixture: String, onset: Double = 12.0, eos: Double, spans: [(Double, Double)]? = nil,
                      holdAt: Double?, duckAt: Double = 12.16) -> Metrics {
        var b = RunBuilder()
        b.longReply(end: (holdAt ?? 20) + 0.2, flushed: holdAt != nil)
        b.event(fixture, onset: onset, eos: eos, outcome: holdAt == nil ? .missed : .stopped,
                stoppedAt: holdAt.map { $0 + 0.2 }, pausedAt: holdAt)
        if let spans { b.run.utterances[b.run.utterances.count - 1].spans = spans.map { .init(start: $0.0, end: $0.1) } }
        var notes: [(Double, String)] = [(duckAt, "duck item_x gain=-12 via=onset")]
        if let holdAt { notes += [(holdAt, "hold item_x why=stopword"), (holdAt, "barge_in: item_x")] }
        b.notes(notes)
        return Metrics.compute([b.run], pricing: .mini)
    }

    @Test func yieldIsBoundAtPointFour() {
        #expect(gate(Gates.evaluate(interruption("c01", eos: 12.58, holdAt: 13.2, duckAt: 12.38)), "barge_in")?.status == .pass)
        let slow = interruption("c01", eos: 12.58, holdAt: 13.2, duckAt: 12.45)
        #expect(gate(Gates.evaluate(slow), "barge_in")?.status == .fail)                 // 0.45 > 0.4
        #expect(gate(Gates.evaluate(slow), "barge_in")?.target.hasPrefix("p90 ≤ 0.4 s") == true)
        var t = Gates.Thresholds()
        t.yieldP90 = 0.5
        #expect(gate(Gates.evaluate(slow, thresholds: t), "barge_in")?.status == .pass)
    }

    @Test func aLoneStopWordIsTimedFromItsEnd() {
        // "Stop." ends 12.58; silent at 13.5 → 0.92 s ≤ 1.0 (1.5 s from the onset: no longer bound).
        let ok = interruption("c01", eos: 12.58, holdAt: 13.5)
        #expect(ok.silenceStopWord.count == 1 && abs(ok.silenceStopWord[0] - 0.92) < 1e-9)
        #expect(gate(Gates.evaluate(ok), "silence")?.status == .pass)
        let late = interruption("c01", eos: 12.58, holdAt: 13.7)
        #expect(gate(Gates.evaluate(late), "silence")?.status == .fail)                  // 1.12 > 1.0
        #expect(gate(Gates.evaluate(late), "silence")?.note?.contains("s:c01 (1.12 s)") == true)
    }

    @Test func aStopPhraseThatOpensATurnIsTimedFromThePhrase() {
        // c07 "Hold on, | what time is it?": the first span ends 12.64; silent at 13.5.
        let m = interruption("c07", eos: 13.9, spans: [(12.0, 12.64), (13.0, 13.9)], holdAt: 13.5)
        #expect(abs(m.silenceStopWord[0] - 0.86) < 1e-9)
        #expect(m.silenceMulti.count == 1 && abs(m.silenceMulti[0] - 1.5) < 1e-9)     // reported, not bound
        #expect(gate(Gates.evaluate(m), "silence")?.status == .pass)
        var t = Gates.Thresholds()
        t.silenceFromOnset = true                                                        // round 1's 0.75 s bound
        #expect(gate(Gates.evaluate(m, thresholds: t), "silence")?.status == .fail)
        // c03 "Wait, stop talking…" is one span: "Wait" ends 0.40 s after the onset.
        let c03 = interruption("c03", eos: 14.3, holdAt: 13.3)
        #expect(abs(c03.silenceStopWord[0] - 0.90) < 1e-9)
    }

    @Test func aQuestionHasNoSilenceBound() {
        // q01 over Dee: Dee may stay dipped until the words show a real turn.
        let m = interruption("q01", eos: 13.4, holdAt: 14.2)
        #expect(m.silenceStopWord.isEmpty && m.silenceMulti.count == 1 && abs(m.silenceMulti[0] - 2.2) < 1e-9)
        #expect(gate(Gates.evaluate(m), "silence")?.status == .pass)
    }

    @Test func aStopWordThatNeverSilencesDeeFails() {
        let m = interruption("c08", eos: 12.58, holdAt: nil)
        #expect(m.silenceStopWordList == ["s:c08 (never silent)"])
        #expect(gate(Gates.evaluate(m), "silence")?.status == .fail)
    }

    @Test func aTVRoomAllowsNoFalsePause() {
        var t = Gates.Thresholds()
        #expect(t.isTVCondition("tv15") && t.isTVCondition("tv10") && t.isTVCondition("tvlong10"))
        #expect(!t.isTVCondition("clean") && !t.isTVCondition("fan15") && !t.isTVCondition("echo20"))
        func run(_ bed: String, _ snr: Double, pauses: Int) -> Metrics {
            var b = RunBuilder()
            b.run.noise = .init(bed: bed, snrDb: snr)
            b.utterance("l01", 1, 8)
            b.reply("r1", started: 10, ended: 610)                      // 10 Dee-minutes
            b.notes((0..<pauses).flatMap { i in [(30.0 + Double(i) * 60, "hold - why=localOnly"),
                                                (30.5 + Double(i) * 60, "resumed - (tail)")] })
            return Metrics.compute([b.run], pricing: .mini)
        }
        #expect(gate(Gates.evaluate(run("tv", 15, pauses: 1)), "false_barge")?.status == .fail)      // TV: 0
        #expect(gate(Gates.evaluate(run("tv", 15, pauses: 0)), "false_barge")?.status == .pass)
        #expect(gate(Gates.evaluate(run("fan", 15, pauses: 1)), "false_barge")?.status == .pass)     // ≤ 1 per 10
        #expect(gate(Gates.evaluate(run("fan", 15, pauses: 2)), "false_barge")?.status == .fail)
        t.falseBargeTVPer10 = 2
        #expect(gate(Gates.evaluate(run("tv", 15, pauses: 1), thresholds: t), "false_barge")?.status == .pass)
    }
}

@Suite("Calm round 2: a report folder per run")
struct CalmR2RunIDTests {
    func tmp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("dee-calm2-ids-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test func theSameSecondGetsASuffix() throws {
        let root = tmp().appendingPathComponent("Reports")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        #expect(try RunIDs.claim("replay-20261016-201642", in: root) == "replay-20261016-201642")
        #expect(try RunIDs.claim("replay-20261016-201642", in: root) == "replay-20261016-201642-2")
        #expect(try RunIDs.claim("replay-20261016-201642", in: root) == "replay-20261016-201642-3")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("replay-20261016-201642-3").path))
    }

    @Test func aTakenTracesFolderIsSkipped() throws {
        let base = tmp()
        defer { try? FileManager.default.removeItem(at: base) }
        let reports = base.appendingPathComponent("Reports"), traces = base.appendingPathComponent("Traces")
        try FileManager.default.createDirectory(at: traces.appendingPathComponent("20261016-193633"), withIntermediateDirectories: true)
        #expect(try RunIDs.claim("20261016-193633", in: reports, alsoFree: [traces]) == "20261016-193633-2")
    }

    @Test func concurrentClaimsNeverShareAFolder() async throws {
        let root = tmp().appendingPathComponent("Reports")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let ids = try await withThrowingTaskGroup(of: String.self) { g in
            for _ in 0..<12 { g.addTask { try RunIDs.claim("20261016-202402", in: root) } }
            var out: [String] = []
            for try await id in g { out.append(id) }
            return out
        }
        #expect(Set(ids).count == 12)
    }

    @Test func poolKeepsTwoReportsWithOneIDApart() {
        var b = RunBuilder()
        b.run.scenario = "calm-bc-clean"
        let a = Pool.Source(id: "replay-20261016-201642", model: "gpt-realtime-2.1-mini", runs: [b.run])
        let runs = Pool.runs([a, a])
        #expect(runs.map(\.scenario) == ["replay-20261016-201642/calm-bc-clean", "replay-20261016-201642#2/calm-bc-clean"])
    }
}

@Suite("Calm round 2: the calm2 suite")
struct CalmR2SuiteTests {
    @Test func calm2IsCalmPlusTheTune2Subset() throws {
        let suite = Suite.calm2()
        let names = suite.map(\.name)
        #expect(Array(names.prefix(8)) == Suite.calm().map(\.name))
        #expect(Array(names.dropFirst(8)) == Suite.calm2Tune2Subset)
        #expect(Suite.calm2Tune2Subset.count == 10)
        // The tune-2 scenarios are exactly tune2's (comparable with report 20261016-195702).
        for n in Suite.calm2Tune2Subset { #expect(suite.first { $0.name == n } == Suite.tune2().first { $0.name == n }) }
        func events(_ name: String) -> [Scenario.BargeIn] { suite.first { $0.name == name }!.steps.flatMap(\.bargeIns) }
        for n in ["calm-sounds-clean", "calm-sounds-tv15"] {
            #expect(events(n).count == 16)
            #expect(Set(events(n).map(\.say)).isSuperset(of: ["ns12", "ns13", "ns14"]))
            #expect(events(n).filter { $0.say == "ns12" || $0.say == "ns13" }.allSatisfy { $0.nonspeech == true })
        }
        // Asks are not repeated inside a scenario.
        for s in suite where s.name.hasPrefix("calm-sounds") {
            let asks = s.steps.compactMap(\.say)
            #expect(Set(asks).count == asks.count, "\(s.name) \(asks)")
        }
        let manifestURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/manifest.json")
        if let m = try? FixtureManifest.load(manifestURL), m.utterance("ns12") != nil {
            for s in suite { #expect(s.validate(against: m).isEmpty, "\(s.validate(against: m))") }
            let pricing = Pricing.forModel("gpt-realtime-2.1-mini")
            var usd = 0.0, seconds = 0.0
            for s in suite {
                let userSeconds = s.fixtureIDs.compactMap { m.utterance($0)?.speechSeconds }.reduce(0, +)
                usd += pricing.projected(replies: s.expectedReplyCount, userSeconds: userSeconds)
                seconds += RunEstimate.seconds(s, manifest: m)
            }
            #expect(usd <= 1.20 && seconds / 60 <= 50, "projected $\(usd), \(seconds / 60) min")
        }
    }
}
