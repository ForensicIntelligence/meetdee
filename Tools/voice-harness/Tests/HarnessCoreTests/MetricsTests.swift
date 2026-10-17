import Foundation
import Testing
@testable import HarnessCore

/// Builds run records by hand so every metric and gate can be checked exactly.
struct RunBuilder {
    var run = RunRecord(scenario: "s", model: "gpt-realtime-2.1-mini", brain: "minimal", started: "t")

    /// An utterance at `onset`…`eos`, voiced in `spans` (absolute; default one span).
    mutating func utterance(_ fixture: String, _ onset: Double, _ eos: Double, spans: [(Double, Double)]? = nil,
                            text: String = "hello there dee", role: RunRecord.UtteranceRole = .turn,
                            expect: Scenario.Expect = .reply, mention: [String]? = nil) {
        let s = (spans ?? [(onset, eos)]).map { RunRecord.Interval(start: $0.0, end: $0.1) }
        run.utterances.append(.init(index: run.utterances.count + 1, step: run.utterances.count, fixture: fixture, role: role,
                                    text: text, start: onset - 0.15, onset: onset, endOfSpeech: eos, spans: s,
                                    expect: expect, expectMention: mention))
    }

    mutating func userItem(_ id: String, seen: Double, committed: Double? = nil, transcript: String? = nil) {
        var u = RunRecord.UserItem(itemID: id, firstSeen: seen)
        u.committedAt = committed ?? seen + 1
        u.transcript = transcript
        run.userItems.append(u)
    }

    mutating func reply(_ item: String, started: Double, ended: Double, text: String = "Sure thing.",
                        kind: String = "reply", flushed: Bool = false, playedMs: Int? = nil, status: String = "completed") {
        var p = RunRecord.Playback(itemID: item, started: started)
        p.ended = ended
        p.flushed = flushed
        p.playedMs = playedMs ?? Int((ended - started) * 1000)
        run.playback.append(p)
        var r = RunRecord.Response(responseID: "resp_\(item)", kind: kind)
        r.startedAt = started - 0.4
        r.doneAt = started + 0.5
        r.status = status
        r.itemIDs = [item]
        r.transcript = text
        var u = RunRecord.UsageRecord()
        u.inputAudio = 400; u.cachedAudio = 100; u.inputText = 200; u.outputAudio = 200; u.outputText = 50
        r.usage = u
        run.responses.append(r)
        run.deeTranscripts[item] = text
    }
}

@Suite("Metrics")
struct MetricsTests {
    func metrics(_ b: RunBuilder) -> Metrics { Metrics.compute([b.run], pricing: .mini) }

    @Test func latencyFromGroundTruthEndOfSpeech() {
        var b = RunBuilder()
        b.utterance("q01", 1.0, 2.0, text: "What's your favorite color?")
        b.userItem("u1", seen: 1.3, transcript: "What's your favorite color?")
        b.reply("a1", started: 3.1, ended: 5.0)
        b.utterance("q02", 7.0, 8.0, text: "Are you awake?")
        b.userItem("u2", seen: 7.2, transcript: "Are you awake")
        b.reply("a2", started: 8.9, ended: 10)
        let m = metrics(b)
        #expect(m.latencies.map { ($0 * 100).rounded() / 100 } == [1.1, 0.9])
        #expect(abs((m.latencyP50 ?? 0) - 1.0) < 1e-9)
        #expect(m.dropped == 0 && m.falseCutoffs == 0 && m.collisions.isEmpty)
        #expect(m.wer == 0)
        #expect(m.utterances[0].replyItem == "a1")
    }

    @Test func droppedWhenNoItemOrNoReply() {
        var b = RunBuilder()
        b.utterance("q01", 1, 2)                         // no item at all
        b.utterance("q02", 6, 7)
        b.userItem("u2", seen: 6.3)                      // item, but no reply
        b.utterance("c01", 12, 12.5, expect: .any)
        b.userItem("u3", seen: 12.2)                     // "stop": no reply needed
        let m = metrics(b)
        #expect(m.dropped == 2)
        #expect(m.utterances.map(\.droppedReason) == ["no user item", "no reply", nil])
        let gates = Gates.evaluate(m)
        #expect(gates.first { $0.id == "dropped" }?.status == .fail)
        #expect(gates.first { $0.id == "latency" }?.status == .fail)    // replies expected, none measured
    }

    @Test func falseCutoffInAPauseAndCollisionInSpeech() {
        var b = RunBuilder()
        // "So yesterday I went to the" [1.2 s] "farmers market…"
        b.utterance("p12a", 1.0, 5.4, spans: [(1.0, 2.6), (3.8, 5.4)])
        b.userItem("u1", seen: 1.2)
        b.reply("a1", started: 3.2, ended: 3.5, flushed: true)     // in the pause → false cut-off
        b.reply("a2", started: 6.5, ended: 8)
        b.utterance("q01", 10, 12)
        b.userItem("u2", seen: 10.2)
        b.reply("a3", started: 11.0, ended: 12.5)                  // while voiced → cut-off + collision
        let m = metrics(b)
        #expect(m.falseCutoffs == 2)
        #expect(m.pausedUtterances == 1 && m.pausedFalseCutoffs == 1)
        #expect(m.collisions.map(\.itemID) == ["a3"])
        #expect(m.latencies.map { ($0 * 10).rounded() / 10 } == [1.1])      // only the clean one
        let g = Gates.evaluate(m)
        #expect(g.first { $0.id == "false_cutoff" }?.status == .fail)
        #expect(g.first { $0.id == "collisions" }?.status == .fail)
    }

    @Test func bargeInLatencyAndMisses() {
        var b = RunBuilder()
        b.run.bargeIns = [
            .init(step: 0, baseFixture: "l01", fixture: "c03", targetAtMs: 900, replyItem: "a1", replyStarted: 1,
                  onset: 1.9, stoppedAt: 2.25, outcome: .stopped),
            .init(step: 1, baseFixture: "l02", fixture: "c06", targetAtMs: 900, replyItem: "a2", replyStarted: 5,
                  onset: 5.9, stoppedAt: nil, outcome: .missed),
            .init(step: 2, baseFixture: "q01", fixture: "c01", targetAtMs: 900, replyItem: "a3", replyStarted: 9,
                  onset: 9.9, stoppedAt: nil, outcome: .notApplicable),
        ]
        let m = metrics(b)
        #expect(m.bargeIns == 3 && m.bargeInsApplicable == 2 && m.bargeInsMissed == 1)
        #expect(abs((m.bargeInP90 ?? 0) - 0.35) < 1e-9)
        #expect(m.bargeInMissRate == 0.5)
        #expect(Gates.evaluate(m).first { $0.id == "barge_in" }?.status == .fail)
    }

    @Test func selfTriggerOnlyCountsSpokenEchoSegments() {
        var b = RunBuilder()
        b.run.echoSegments = [
            .init(step: 0, line: "Owls…", requested: 1, outcome: "sent", audioStarted: 1.5, audioEnded: 4,
                  window: .init(start: 1, end: 6.5)),
            .init(step: 1, line: "Poem…", requested: 10, outcome: "sent", audioStarted: 10.5, audioEnded: 12,
                  window: .init(start: 10, end: 14.5)),
            .init(step: 2, line: "Never played", requested: 20, outcome: "refused(userSpeaking)", audioStarted: nil,
                  audioEnded: nil, window: .init(start: 20, end: 22.5)),
        ]
        b.userItem("echo1", seen: 2.0, transcript: "Owls")     // Dee's own echo taken for the user
        let m = metrics(b)
        #expect(m.echoSegments == 2 && m.echoSegmentsNotSpoken == 1)
        #expect(m.selfTriggers == 1 && m.selfTriggerItems == ["echo1"])
        #expect(m.phantoms.isEmpty)                             // inside an echo window: a self-trigger, not a phantom
        #expect(Gates.evaluate(m).first { $0.id == "self_trigger" }?.status == .fail)
    }

    @Test func phantomTurnsAreItemsOutsideEveryUtterance() {
        var b = RunBuilder()
        b.utterance("q01", 1, 2)
        b.userItem("u1", seen: 1.2)
        b.reply("a1", started: 3, ended: 4)
        b.userItem("noise", seen: 9.0, committed: 9.5, transcript: "Oh.")
        b.reply("a2", started: 10.2, ended: 11)
        let m = metrics(b)
        #expect(m.phantoms.map(\.itemID) == ["noise"])
        #expect(m.phantoms.first?.answered == true)
    }

    @Test func anItemOpenedOnNoiseJustBeforeTheUserStillCounts() {
        var b = RunBuilder()
        b.utterance("d02", 10, 15)
        b.userItem("u1", seen: 8.8, committed: 15.8)          // VAD opened on the tap 1.2 s early
        b.reply("a1", started: 16.4, ended: 18)
        let m = metrics(b)
        #expect(m.dropped == 0 && m.phantoms.isEmpty)
        #expect(m.utterances[0].userItems == ["u1"])
    }

    @Test func truncationWithinOneBufferAndHistory() {
        var b = RunBuilder()
        b.reply("a1", started: 1, ended: 2.5, text: "One. Two. Three.", flushed: true, playedMs: 1500)
        b.reply("a2", started: 5, ended: 6, flushed: true, playedMs: 1000)
        b.run.truncations = [.init(itemID: "a1", audioEndMs: 1510, at: 2.5), .init(itemID: "a2", audioEndMs: 1040, at: 6)]
        b.run.heardSentences = ["a1": ["One.", "Two."]]
        b.run.history = [.init(role: "assistant", text: "One. Two.", itemID: "a1"),
                         .init(role: "assistant", text: "Sure thing.", itemID: "a2")]
        let m = metrics(b)
        #expect(m.truncations.map(\.accurate) == [true, false])         // 10 ms ok, 40 ms not
        #expect(m.truncations.map(\.historyMatches) == [true, false])   // nothing of a2 was heard as a sentence
        #expect(Gates.evaluate(m).first { $0.id == "truncation" }?.status == .fail)
    }

    @Test func leaksAndReplyLength() {
        var b = RunBuilder()
        b.reply("a1", started: 1, ended: 2, text: "Sure! [smiles] I'd love that.")
        b.reply("a2", started: 3, ended: 4, text: "As an AI, I can't eat cake.")
        b.reply("a3", started: 5, ended: 6, text: "One. Two. Three. Four.")
        b.reply("a4", started: 7, ended: 8, text: "Dr. Lee said 2.5 cups. That's plenty.")
        let m = metrics(b)
        #expect(m.leaks.map(\.itemID).sorted() == ["a1", "a2"])
        #expect(m.replySentenceCounts == [2, 1, 4, 2])
        #expect(m.repliesWithinThree == 3)
        let g = Gates.evaluate(m)
        #expect(g.first { $0.id == "leaks" }?.status == .fail)
        #expect(g.first { $0.id == "reply_length" }?.status == .fail)
    }

    @Test func memoryProbes() {
        var b = RunBuilder()
        b.utterance("n01", 1, 2)
        b.userItem("u1", seen: 1.2)
        b.reply("a1", started: 3, ended: 4, text: "Hi Priya!")
        b.utterance("m01", 6, 7, mention: ["Priya"])
        b.userItem("u2", seen: 6.2)
        b.reply("a2", started: 8, ended: 9, text: "Your name is priya, right?")
        let m = metrics(b)
        #expect(m.memoryProbes == 1 && m.memoryHits == 1)
        #expect(Gates.evaluate(m).first { $0.id == "memory" }?.status == .pass)
    }

    @Test func allGatesPassOnACleanRun() {
        var b = RunBuilder()
        for k in 0..<10 {
            let t = Double(k) * 10
            b.utterance("q\(k)", t + 1, t + 2)
            b.userItem("u\(k)", seen: t + 1.2, transcript: "hello there dee")
            b.reply("a\(k)", started: t + 2.8, ended: t + 4)
        }
        b.run.bargeIns = [.init(step: 0, baseFixture: "l01", fixture: "c03", targetAtMs: 900, replyItem: "a0",
                                replyStarted: 2.8, onset: 3.5, stoppedAt: 3.8, outcome: .stopped)]
        b.run.truncations = [.init(itemID: "a0", audioEndMs: 1200, at: 4)]
        let m = metrics(b)
        let g = Gates.evaluate(m)
        #expect(!Gates.anyFailed(g), "\(g.filter { $0.status == .fail })")
        #expect(g.first { $0.id == "self_trigger" }?.status == .skip)
        #expect(g.first { $0.id == "fallback" }?.status == .skip)
        #expect(m.cost.responsesDollars > 0)
    }
}

@Suite("Text, cost, scenarios")
struct TextTests {
    @Test func werNormalizes() {
        #expect(WER.normalize("My sister's wedding is on June 12th!") == ["my", "sister's", "wedding", "is", "on", "june", "twelfth"])
        #expect(WER.normalize("So I went to the… um… store") == ["so", "i", "went", "to", "the", "store"])
        #expect(WER.normalize("at 4:30") == ["at", "four", "thirty"])
        #expect(WER.normalize("forty-two") == ["forty", "two"])
        #expect(WER.score(reference: "farmers market", hypothesis: "farmer's market").edits == 1)
        #expect(WER.score(reference: "a b c d", hypothesis: "a x c").edits == 2)
        #expect(WER.editDistance([], ["a"]) == 1)
    }

    @Test func sentences() {
        #expect(Sentences.count("Hi Priya! Nice to meet you. Want to chat?") == 3)
        #expect(Sentences.count("Dr. Smith gave me 2.5 cups, e.g. flour.") == 1)
        #expect(Sentences.count("Okay") == 1)
        #expect(Sentences.count("") == 0)
    }

    @Test func leakScanner() {
        #expect(LeakScanner.scan("<dee_state mood=happy>").contains("dee_state tag"))
        #expect(LeakScanner.scan("My DNA says hi").contains("DNA"))
        #expect(LeakScanner.scan("the dna of a song").isEmpty)
        #expect(LeakScanner.scan("note 3fa9c2d1e0 here").contains("hex"))
        #expect(LeakScanner.scan("I'm just a language model").contains("language model"))
        #expect(LeakScanner.scan("Hi Priya! I'd love that.").isEmpty)
    }

    @Test func redactNeverLetsAKeyThrough() {
        let s = Redact.secrets("auth sk-proj-abcdef1234567890 and ek_abc123456789 Bearer sk-zzzzzzzzzz")
        #expect(!s.contains("sk-") && !s.contains("ek_abc"))
    }

    @Test func pricing() {
        var u = RunRecord.UsageRecord()
        u.inputAudio = 1_000_000; u.outputAudio = 1_000_000
        #expect(abs(Pricing.mini.dollars(u) - 30) < 1e-9)
        u.cachedAudio = 1_000_000
        #expect(abs(Pricing.mini.dollars(u) - 20.30) < 1e-9)
        #expect(Pricing.forModel("gpt-realtime-2.1") == .full)
        #expect(Pricing.mini.projected(replies: 10, userSeconds: 60) < 0.2)
    }

    @Test func scenariosDecodeAndValidate() throws {
        let json = #"""
        {"scenarios":[{"name":"a","noise":{"bed":"fan","snrDb":15},"echo":{"gainDB":-20,"delayMs":80,"reverb":true},
          "steps":[{"say":"q01"},{"say":"l01","bargeIn":{"say":"c03","atMs":900}},{"silence":1},{"deeSays":"Hi."},
                   {"say":"q01","silence":2},{"say":"zzz"}]}]}
        """#
        let file = try JSONDecoder().decode(ScenarioFile.self, from: Data(json.utf8))
        let s = file.scenarios[0]
        #expect(s.fixtureIDs == ["q01", "l01", "c03", "q01", "zzz"])
        #expect(s.bargeInCount == 1 && s.echoOnlyCount == 1)
        #expect(s.steps[3].expected == .noReply && s.steps[0].expected == .reply)
        let manifest = FixtureManifest(generatedAt: "", notes: "", utterances: ["q01", "l01", "c03"].map {
            .init(id: $0, file: "\($0).wav", category: .shortQuestion, engine: .say, voice: "x", style: .neutral, text: "",
                  sampleRate: 24_000, samples: 10, onsetSample: 1, endOfSpeechSample: 9, spans: [], scriptedPauses: [],
                  activeLevelDB: -24)
        }, noise: [.init(id: "fan", file: "f.wav", seconds: 1, levelDB: -30, provenance: "")], impulseResponses: [])
        let issues = s.validate(against: manifest)
        #expect(issues.count == 2)                       // unknown zzz; step with say + silence
    }

    @Test func smokeScenariosAreValid() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["smoke.json", "full.json"] {
            let url = root.appendingPathComponent("Scenarios/\(name)")
            guard FileManager.default.fileExists(atPath: url.path),
                  let manifest = try? FixtureManifest.load(root.appendingPathComponent("Fixtures/manifest.json")) else { continue }
            let file = try ScenarioFile.load(url)
            for s in file.scenarios { #expect(s.validate(against: manifest).isEmpty, "\(name) \(s.name)") }
        }
    }
}
