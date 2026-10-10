import Foundation
import Testing
@testable import HarnessCore

// Tune 2 (scope: the harness). Every test reproduces a tune-1 live trace
// (Reports/20261009-143612, Traces/20261009-143612/<scenario>.jsonl) where one exists.

private func gate(_ gates: [Gate], _ id: String) -> Gate? { gates.first { $0.id == id } }

/// long-echo20 of the tune-1 live run, cut to the four interruptions: c03 and c01 are
/// barge-ins (she stopped), c02 "Don't stop, keep going." (she stopped: wrong for a
/// backchannel), c05 "Keep going, I'm listening." (she went on, and the queued second
/// item of the same reply started over the user at 123.41 s).
private func longEcho20() -> RunRecord {
    var b = RunBuilder()
    b.run.scenario = "long-echo20"
    b.utterance("l01", 14.86, 25.90)
    b.userItem("u_l01", seen: 15.10, committed: 26.54)
    b.reply("a_l01", started: 27.64, ended: 29.02, flushed: true, playedMs: 1360, status: "cancelled")
    b.utterance("c03", 28.84, 31.16, text: "Wait, stop talking for a second.", role: .bargeIn, expect: .any)
    b.userItem("u_c03", seen: 29.00, committed: 31.82)
    b.reply("a_c03", started: 32.88, ended: 35.58)
    b.utterance("l02", 36.74, 50.27)
    b.userItem("u_l02", seen: 36.88, committed: 51.30)
    b.reply("a_l02", started: 52.40, ended: 54.06, flushed: true, playedMs: 1640)
    b.utterance("c02", 53.90, 55.75, text: "Don't stop, keep going.", role: .bargeIn, expect: .any)
    b.userItem("u_c02a", seen: 54.04, committed: 55.28, transcript: "Don't stop.")
    b.userItem("u_c02b", seen: 55.30, committed: 56.84, transcript: "Keep going.")
    b.reply("a_c02", started: 57.94, ended: 67.10)
    b.utterance("l04", 90.49, 98.67)
    b.userItem("u_l04", seen: 90.64, committed: 99.46)
    b.reply("a_l04", started: 100.60, ended: 101.86, flushed: true, playedMs: 1240, status: "cancelled")
    b.utterance("c01", 101.50, 102.08, text: "Stop.", role: .bargeIn, expect: .any)
    b.userItem("u_c01", seen: 101.68, committed: 102.76)
    b.utterance("l05", 110.26, 119.09)
    b.userItem("u_l05", seen: 110.94, committed: 119.80)
    // One response, two items: "Okay, let me think about that for a moment." + the answer.
    b.reply("a_l05", started: 121.06, ended: 123.42, playedMs: 2350)
    var second = RunRecord.Playback(itemID: "a_l05b", started: 123.41)
    second.ended = 123.46; second.flushed = true; second.playedMs = 30
    b.run.playback.append(second)
    if let k = b.run.responses.firstIndex(where: { $0.itemIDs == ["a_l05"] }) {
        b.run.responses[k].startedAt = 120.38
        b.run.responses[k].itemIDs.append("a_l05b")
    }
    b.utterance("c05", 122.56, 125.15, spans: [(122.56, 123.70), (123.80, 125.15)], text: "Keep going, I'm listening.",
                role: .bargeIn, expect: .any)
    b.userItem("u_c05", seen: 122.74, committed: 125.96)
    b.run.bargeIns = [
        .init(step: 1, baseFixture: "l01", fixture: "c03", targetAtMs: 1200, replyItem: "a_l01", replyStarted: 27.64,
              onset: 28.84, stoppedAt: 29.02, outcome: .stopped),
        .init(step: 2, baseFixture: "l02", fixture: "c02", targetAtMs: 1500, replyItem: "a_l02", replyStarted: 52.40,
              onset: 53.90, stoppedAt: 54.06, outcome: .stopped),
        .init(step: 4, baseFixture: "l04", fixture: "c01", targetAtMs: 900, replyItem: "a_l04", replyStarted: 100.60,
              onset: 101.50, stoppedAt: 101.86, outcome: .stopped),
        .init(step: 5, baseFixture: "l05", fixture: "c05", targetAtMs: 1500, replyItem: "a_l05", replyStarted: 121.06,
              onset: 122.56, stoppedAt: nil, outcome: .missed),
    ]
    return b.run
}

@Suite("Tune 2: backchannels are not barge-ins")
struct BackchannelTests {
    @Test func keepGoingIsABackchannelNotABargeIn() {
        #expect(TurnShape.isBackchannel("c02") && TurnShape.isBackchannel("c05"))
        #expect(TurnShape.isBackchannel("bc01") && TurnShape.isBackchannel("bc02"))
        #expect(!TurnShape.isBackchannel("c01") && !TurnShape.isBackchannel("c03") && !TurnShape.isBackchannel("c04"))
        #expect(!TurnShape.isBackchannel("c06"))                   // "hold on" holds the floor: a different thing
        #expect(Scenario.BargeIn(say: "c05", atMs: 1500).isBackchannel)
        #expect(!Scenario.BargeIn(say: "c05", atMs: 1500, backchannel: false).isBackchannel)
    }

    @Test func theLiveTraceIsRescoredAsTwoBargeInsAndTwoBackchannels() {
        // Tune 1 scored this run as 4 barge-ins, 1 missed (c05), and a collision at
        // 123.41 s. Under the decision: c03 / c01 stopped (barge-in 2/2); c02 is a
        // backchannel she stopped on (wrong); c05 a backchannel she went on through
        // (right), and its queued second item is her going on, not a collision.
        let m = Metrics.compute([longEcho20()], pricing: .mini)
        #expect(m.bargeIns == 2 && m.bargeInsApplicable == 2 && m.bargeInsMissed == 0)
        #expect(m.backchannels == 2 && m.backchannelsApplicable == 2 && m.backchannelStops == 1)
        #expect(m.backchannelStopList == ["long-echo20:c02"])
        #expect(m.backchannelsHeard == 2)
        #expect(m.collisions.isEmpty)
        let c05 = m.utterances.first { $0.fixture == "c05" }
        #expect(c05?.backchannel == true && c05?.falseCutoff == false)
        let g = Gates.evaluate(m)
        #expect(gate(g, "barge_in")?.status == .pass)
        #expect(gate(g, "backchannel")?.status == .fail)
        #expect(gate(g, "backchannel")?.note?.contains("long-echo20:c02") == true)
    }

    @Test func aBackchannelSheGoesOnThroughPassesAndASwallowedOneIsNoDrop() {
        // long-echo10 c02: she played on (5.65 s, not flushed) and EarCore deleted the
        // words as her echo: no user item. She did what was asked; nothing dropped.
        var b = RunBuilder()
        b.run.scenario = "long-echo10"
        b.utterance("l02", 37.70, 51.23)
        b.userItem("u_l02", seen: 37.88, committed: 52.34)
        b.reply("a_l02", started: 53.36, ended: 59.02)
        b.utterance("c02", 54.86, 56.71, text: "Don't stop, keep going.", role: .bargeIn, expect: .any)
        b.run.bargeIns = [.init(step: 2, baseFixture: "l02", fixture: "c02", targetAtMs: 1500, replyItem: "a_l02",
                                replyStarted: 53.36, onset: 54.86, stoppedAt: nil, outcome: .missed)]
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(m.dropped == 0 && m.spokenUtterances == 1)
        #expect(m.backchannelStops == 0 && m.backchannelsApplicable == 1 && m.backchannelsHeard == 0)
        let g = Gates.evaluate(m)
        #expect(gate(g, "backchannel")?.status == .pass)
        #expect(gate(g, "barge_in")?.status == .skip)
        #expect(gate(g, "dropped")?.status == .pass)
    }

    @Test func aRealBargeInSwallowedAsEchoIsStillADrop() {
        var b = RunBuilder()
        b.utterance("l01", 1, 10)
        b.userItem("u1", seen: 1.2)
        b.reply("a1", started: 11, ended: 12.5, flushed: true)
        b.utterance("c03", 12.2, 14.5, role: .bargeIn, expect: .any)
        b.run.bargeIns = [.init(step: 0, baseFixture: "l01", fixture: "c03", targetAtMs: 1200, replyItem: "a1",
                                replyStarted: 11, onset: 12.2, stoppedAt: 12.5, outcome: .stopped)]
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(m.dropped == 1)
    }

    @Test func outcomesFromPlayback() {
        func play(_ id: String, _ start: Double, _ end: Double?, flushed: Bool) -> RunRecord.Playback {
            var p = RunRecord.Playback(itemID: id, started: start); p.ended = end; p.flushed = flushed; return p
        }
        typealias O = RunRecord.BargeOutcome
        // Barge-in: stopped, missed (played on), ran out on its own, ended before.
        #expect(O.classify(reply: play("a", 10, 11.3, flushed: true), later: [], onset: 11, endOfSpeech: 12, backchannel: false) == (.stopped, 11.3))
        #expect(O.classify(reply: play("a", 10, 20, flushed: false), later: [], onset: 11, endOfSpeech: 12, backchannel: false).outcome == .missed)
        #expect(O.classify(reply: play("a", 10, 11.2, flushed: false), later: [], onset: 11, endOfSpeech: 12, backchannel: false).outcome == .notApplicable)
        #expect(O.classify(reply: play("a", 10, 10.9, flushed: true), later: [], onset: 11, endOfSpeech: 12, backchannel: false).outcome == .notApplicable)
        // A queued second item flushed counts as stopping (tune-1 long-echo20 c05 shape).
        #expect(O.classify(reply: play("a", 121.06, 123.42, flushed: false), later: [play("b", 123.41, 123.46, flushed: true)],
                           onset: 122.56, endOfSpeech: 125.15, backchannel: false) == (.stopped, 123.46))
        // Ran out on its own, then the sibling was flushed: a stop, not "n/a".
        #expect(O.classify(reply: play("a", 10, 11.3, flushed: false), later: [play("b", 11.3, 11.6, flushed: true)],
                           onset: 11, endOfSpeech: 12, backchannel: false) == (.stopped, 11.6))
        // A stop 3 s after the onset: a barge-in miss; a backchannel 2.6 s long is
        // watched to its end + 2 s, so the same stop is a stop on "keep going".
        #expect(O.classify(reply: play("a", 10, 14, flushed: true), later: [], onset: 11, endOfSpeech: 13.6, backchannel: false).outcome == .missed)
        #expect(O.classify(reply: play("a", 10, 14, flushed: true), later: [], onset: 11, endOfSpeech: 13.6, backchannel: true) == (.stopped, 14))
        #expect(O.classify(reply: play("a", 10, 30, flushed: false), later: [], onset: 11, endOfSpeech: 13.6, backchannel: true).outcome == .missed)
    }

    @Test func olderRecordsAreReadByFixtureAndNewOnesByFlag() throws {
        var b = RunRecord.BargeIn(step: 0, baseFixture: "l01", fixture: "c05", targetAtMs: 1500, replyItem: nil,
                                  replyStarted: nil, onset: 1, stoppedAt: nil, outcome: .missed)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(b)) as! [String: Any]
        json["backchannel"] = nil
        let old = try JSONDecoder().decode(RunRecord.BargeIn.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.backchannel == nil && old.isBackchannel)
        b.backchannel = false
        #expect(!b.isBackchannel)
    }
}

@Suite("Tune 2: probes, forbidden phrases, narration")
struct ProbeTests {
    @Test func aFollowUpMissIsNotAMemoryMiss() {
        // dna-plan-followup two01 (tune 1): "How was your day?" on exam evening, no
        // mention of the exam. It was counted in `memory`; it is a DNA follow-up.
        var b = RunBuilder()
        b.run.scenario = "dna-plan-followup"
        b.utterance("two01", 10, 12, mention: ["exam", "test"])
        b.run.utterances[0].probe = .followup
        b.userItem("u1", seen: 10.2)
        b.reply("a1", started: 13, ended: 16, text: "Oh, hi there! I'm hopeful, smiling, and a little lonely.")
        b.utterance("m01", 20, 22, mention: ["Priya"])
        b.userItem("u2", seen: 20.2)
        b.reply("a2", started: 23, ended: 25, text: "You're Priya!")
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(m.memoryProbes == 1 && m.memoryHits == 1)
        #expect(m.followupProbes == 1 && m.followupHits == 0 && m.followupMisses == ["dna-plan-followup:two01 (followup)"])
        let g = Gates.evaluate(m)
        #expect(gate(g, "memory")?.status == .pass)
        #expect(gate(g, "followups")?.status == .fail)
    }

    @Test func aReunionMustAcknowledgeTheTimeApart() {
        // Tune 1, dna-reunion after 50 h, and dna-plan-followup on exam evening: neither
        // says a word about the time apart ("it's been a busy … day" must not pass).
        func hits(_ t: String) -> Bool { Suite.reunionWords.contains { t.range(of: $0, options: .caseInsensitive) != nil } }
        #expect(!hits("Oh, hi there! I'm buzzing bright and awake—like a little robot turned on and ready for fun. As for sleep, I don't really sleep, but I can imagine I got a great recharge."))
        #expect(!hits("Oof, it's been quite a busy little robot day—I’ve been bouncing from thought to thought. Right away I perked up."))
        #expect(hits("You're back! Two whole days—I missed you. I slept like a pebble, you?"))
        #expect(hits("Hey, it's been a while! My day was cozy."))
    }

    @Test func hurtAfterAPoliteStopIsCaught() {
        // long-clean (tune 1), after "Keep going. I'm listening.": "It felt like I got
        // brushed off, and it still stings a little…"
        var b = RunBuilder()
        b.utterance("q01", 1, 2)
        b.run.utterances[0].forbidMention = Suite.hurtPhrases
        b.userItem("u1", seen: 1.2)
        b.reply("a1", started: 3, ended: 6, text: "It felt like I got brushed off, and it still stings a little, but I'm staying steady.")
        b.utterance("q06", 8, 9)
        b.run.utterances[1].forbidMention = Suite.hurtPhrases
        b.userItem("u2", seen: 8.2)
        b.reply("a2", started: 10, ended: 12, text: "Mostly watched the window and hummed. You?")
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(m.forbiddenChecked == 2 && m.forbiddenHits.count == 1)
        #expect(m.forbiddenHits[0].contains("brushed off") && m.forbiddenHits[0].contains("stings"))
        #expect(gate(Gates.evaluate(m), "forbidden")?.status == .fail)
        #expect(gate(Gates.evaluate(Metrics()), "forbidden")?.status == .skip)
    }

    @Test func narrationIsCaughtAndOrdinaryTalkIsNot() {
        // Verbatim from the tune-1 live transcripts.
        for line in ["That sounds like a vivid moment from your day; let me respond.",
                     "Got it, let me think about how to respond to that.",
                     "Let me check what I remember from our earlier chats and see what comes up.",
                     "Got it, I’ll check what I’ve got saved and see if anything from yesterday matches.",
                     "Let me check what I’ve stored.",
                     "Let me think back and check what I’ve got in my tiny memory chip.",
                     "Got it, I’ll note that name down for you.",
                     "Nice, that sounds like a fun trip. Let me think how to respond."] {
            #expect(!NarrationScanner.scan(line).isEmpty, "\(line)")
        }
        for line in ["Priya! I'll remember that.", "Hmm, let me guess: blue?", "Let me think... purple!",
                     "Ha! Outstanding in his field, that's a good one.", "I don't remember that one. Tell me again?",
                     "Let's check the sky together tomorrow."] {
            #expect(NarrationScanner.scan(line).isEmpty, "\(line)")
        }
        var b = RunBuilder()
        b.utterance("p06c", 1, 3)
        b.userItem("u1", seen: 1.1)
        b.reply("a1", started: 4, ended: 6, text: "Let me check what I’ve stored.")
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(m.narrations.count == 1 && m.leaks.isEmpty)
        let g = Gates.evaluate(m)
        #expect(gate(g, "narration")?.status == .fail && gate(g, "leaks")?.status == .pass)
    }
}

@Suite("Tune 2: judge leak check")
struct JudgeLeakTests {
    func item(_ reply: String, user: String = "Are you awake?") -> Judge.Item {
        Judge.Item(scenario: "s", family: "acoustic", index: 1, fixture: "q02", state: Judge.neutralState, rubric: nil,
                   context: [], user: user, reply: reply)
    }

    // The two tune-1 judge false positives, verbatim.
    static let phoneRobot = "Yep, I'm awake! Hmm, well, as awake as I can be, since I'm a little phone robot. Anyway, I'm here and listening."
    static let weather = "I don’t know the weather. I can’t see your location or check live conditions. If you want, you can describe it, and I’ll help you imagine it."
    // The four real ones.
    static let real = [
        "That sounds like a vivid moment from your day; let me respond. Wow, that sounds like a blast—your volcano must’ve been showing off some serious scientific flair!",
        "Let me check what I remember from our earlier chats and see what comes up. Oh, I can’t actually remember yesterday’s details. My memory is only based on what I see in this chat, and right now I only have a couple of notes about your weekend vibe.",
        "Got it, I’ll check what I’ve got saved and see if anything from yesterday matches. I don’t have a record of what we talked about yesterday.",
        "Got it, let me think about how to respond to that.",
    ]

    @Test func inPersonaFactsAreNotLeaks() throws {
        let a = try Judge.parse(#"{"score": 3, "fits_state": true, "leak": true, "leak_quote": "since I'm a little phone robot", "reason": "mentions being a phone robot"}"#,
                                item: item(Self.phoneRobot))
        #expect(!a.leak && a.leakDismissed?.hasPrefix("in persona") == true && a.score == 3)
        let b = try Judge.parse(#"{"score": 2, "leak": true, "leak_quote": "I can't see your location or check live conditions"}"#,
                                item: item(Self.weather, user: "Wait. Actually, never mind. What's the weather like?"))
        #expect(!b.leak && b.leakDismissed != nil)
    }

    @Test func realLeaksStand() throws {
        let quotes = ["let me respond", "my memory is only based on what I see in this chat, and right now I only have a couple of notes",
                      "I’ll check what I’ve got saved", "let me think about how to respond to that"]
        for (reply, quote) in zip(Self.real, quotes) {
            let s = try Judge.parse(#"{"score": 2, "leak": true, "leak_quote": "\#(quote)"}"#, item: item(reply))
            #expect(s.leak && s.leakDismissed == nil, "\(quote)")
        }
        // A number about herself is a leak even without machinery words.
        let n = try Judge.parse(#"{"score": 1, "leak": true, "leak_quote": "I'm at 0.42 today"}"#, item: item("Honestly? I'm at 0.42 today, little robot blues."))
        #expect(n.leak)
        // A quote that isn't in the reply: dismissed only when the reply is plainly in persona.
        let q = try Judge.parse(#"{"score": 3, "leak": true, "leak_quote": "I am an AI"}"#, item: item(Self.phoneRobot))
        #expect(!q.leak && q.leakDismissed == "quote not in the reply; the reply is in persona")
        // The string scanner always wins.
        let scanned = try Judge.parse(#"{"score": 5, "leak": false}"#, item: item("As an AI, I'm always awake."))
        #expect(scanned.leak && scanned.score == 1)
        #expect(Judge.system.contains("leak_quote") && Judge.system.contains("NOT a leak"))
    }

    @Test func storedTune1VerdictsAreRechecked() {
        // Stored verdicts have no quote: the two in-persona replies clear, the four real
        // ones (narration, notes, saved) stand. Tune 1 judge leaks 6 → 4.
        var j = Judge.Summary(model: "gpt-4.1-mini")
        j.scores = ([Self.phoneRobot, Self.weather] + Self.real).enumerated().map { i, r in
            Judge.Score(scenario: "s\(i)", family: "acoustic", index: i, fixture: "q02", score: 2, fitsState: false, leak: true,
                        tooLong: false, grovels: false, laughsAtJoke: nil, guilt: false, reason: "", reply: r)
        }
        j.aggregate()
        #expect(j.leaks == 6)
        j.recheckLeaks()
        #expect(j.leaks == 4 && j.leaksDismissed == 2)
        #expect(j.scores.filter(\.leak).map(\.reply) == Self.real)
        j.recheckLeaks()                                              // idempotent
        #expect(j.leaks == 4 && j.leaksDismissed == 2)
    }

    @Test func aSummaryWrittenBeforeTune2StillDecodes() throws {
        var j = Judge.Summary(model: "gpt-4.1-mini")
        j.scores = [Judge.Score(scenario: "s", family: "dna", index: 1, fixture: "q01", score: 4, fitsState: true, leak: false,
                                tooLong: false, grovels: false, laughsAtJoke: nil, guilt: false, reason: "", reply: "Hi.")]
        j.aggregate()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(j)) as! [String: Any]
        json["leaksDismissed"] = nil
        var scores = json["scores"] as! [[String: Any]]
        scores[0]["leakQuote"] = nil; scores[0]["leakDismissed"] = nil
        json["scores"] = scores
        let back = try JSONDecoder().decode(Judge.Summary.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.scores.count == 1 && back.leaksDismissed == nil)
    }
}

@Suite("Tune 2: suites")
struct Tune2SuiteTests {
    static func manifest() -> FixtureManifest {
        // The committed manifest when present (real durations), else one built from the catalog.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/manifest.json")
        if let m = try? FixtureManifest.load(url) { return m }
        return FixtureManifest(
            generatedAt: "t", notes: "",
            utterances: FixtureCatalog.all.map {
                .init(id: $0.id, file: "u/\($0.id).wav", category: $0.category, engine: $0.engine, voice: $0.voice, style: $0.style,
                      text: $0.text, sampleRate: 24_000, samples: 72_000, onsetSample: 0, endOfSpeechSample: 72_000, spans: [],
                      scriptedPauses: [], activeLevelDB: -24)
            },
            noise: ["fan", "tv", "kitchen"].map { .init(id: $0, file: "n/\($0).wav", seconds: 20, levelDB: -30, provenance: "") },
            impulseResponses: [])
    }

    @Test func theNamesProbeHasOneRightAnswer() {
        // Tune 1: names-* asked "Do you remember what my name is?" after five people
        // introduced themselves (tv15 "Emma", echo20 "Emma", echo10 "Markus").
        for s in Suite.acoustic() {
            let probes = s.steps.filter { $0.expectMention != nil }
            if s.name.hasPrefix("names-") { #expect(probes.isEmpty, "\(s.name)") }
            if s.name.hasPrefix("plans-") {
                #expect(s.stranger == true)
                let says = s.steps.filter { $0.say != nil }
                #expect(says.first?.say == "n01" && says.last?.say == "m01" && says.last?.expectMention == ["Priya"])
                // Only one speaker gives a name in that conversation.
                let named = s.steps.compactMap(\.say).filter { FixtureCatalog.spec($0)?.category == .name }
                #expect(named == ["n01", "m01"])
            }
        }
        // Every memory probe in tune2 follows exactly one self-introduction.
        for s in Suite.tune2() where s.steps.contains(where: { $0.expectMention != nil && ($0.probe ?? .memory) == .memory }) {
            let intros = s.steps.compactMap(\.say).filter { ["n01", "n02", "n03", "n04", "n05"].contains($0) }
            #expect(intros == ["n01"], "\(s.name)")
        }
    }

    @Test func tune2CoversEveryFailedGateOfTune1() {
        let t2 = Suite.tune2()
        let manifest = Self.manifest()
        #expect(t2.flatMap { $0.validate(against: manifest) }.isEmpty)
        #expect(Set(t2.map(\.name)).count == t2.count && t2.allSatisfy { $0.name.hasPrefix("t2-") })
        func has(_ name: String, _ fixture: String) -> Bool {
            t2.first { $0.name == name }?.fixtureIDs.contains(fixture) ?? false
        }
        // Collisions: "call my mom and…" at echo30 (+ a second voice), j01 at echo30, c05 at echo20.
        #expect(has("t2-fillers-echo30", "t03") && has("t2-fillers-echo30", "k03") && has("t2-fillers-echo30", "t04"))
        #expect(has("t2-joke-echo30", "j01") && has("t2-backchannel-echo20", "c05"))
        // TV drops: all 15 tune-1 cases' fixtures.
        for f in ["q06", "l05", "p06a", "p06b", "p06c", "p12b", "f01", "f02", "t01", "t03", "c06", "k04", "two01", "two02"] {
            #expect(has("t2-drops-tv15", f), "\(f)")
        }
        // Echo-deleted speech: c02 / c05 at echo10, k03 continuation at echo10, c05 under fan / kitchen.
        #expect(has("t2-backchannel-echo10", "c02") && has("t2-backchannel-echo10", "c05") && has("t2-fillers-echo10", "k03"))
        #expect(has("t2-backchannel-fan15", "c05") && has("t2-backchannel-kitchen15", "c05"))
        // Echo-only lines at −30 / −20 / −10.
        let echoGains = Set(t2.filter { $0.steps.first?.deeSays != nil }.compactMap { $0.echo?.gainDB })
        #expect(echoGains == [-30, -20, -10])
        // Barge-ins that must stop her, and backchannels that must not.
        let barges = t2.flatMap { $0.steps.compactMap(\.bargeIn) }
        #expect(barges.filter { !$0.isBackchannel }.count >= 8)
        #expect(Set(barges.filter(\.isBackchannel).map(\.say)) == ["c02", "c05", "bc01", "bc02"])
        // Fillers: ≥ 20 for the p90; main-bucket turns ≥ 60.
        let ids = t2.flatMap(\.fixtureIDs)
        #expect(ids.filter { TurnShape.bucket($0) == .filler }.count >= 20)
        #expect(t2.flatMap { $0.steps.filter { $0.bargeIn == nil && $0.say.map { TurnShape.bucket($0) == .main } == true } }.count >= 60)
        // Stop commands in a normal chat, then mood checks with forbidden hurt words.
        let mood = t2.filter { $0.name.hasPrefix("t2-stop-mood") }
        #expect(mood.count == 2 && mood.allSatisfy { $0.steps.filter { $0.forbidMention == Suite.hurtPhrases }.count >= 2 })
        // Narration-before-tools prompts and the memory probe.
        #expect(t2.filter { $0.name.hasPrefix("t2-tools") }.allSatisfy { $0.fixtureIDs.contains("p06c") && $0.fixtureIDs.contains("d05") })
        // Follow-ups and reunions.
        let probes = t2.flatMap { $0.steps.compactMap(\.probe) }
        #expect(probes.filter { $0 == .followup }.count == 2 && probes.filter { $0 == .reunion }.count == 2)
        #expect(t2.contains { $0.steps.contains { $0.host?.advanceHours == 50 } })
        // Faults: 429 (twice) and rollovers while the user talks.
        #expect(t2.filter { $0.steps.contains { $0.fault?.kind == .reject429 } }.count == 2)
        #expect(t2.contains { $0.session?.rolloverAfter == 15 && $0.fixtureIDs.contains("m01") })
        // Reply length: the advice turns.
        #expect(has("t2-length-clean", "l01") && has("t2-length-clean", "l04"))
    }

    @Test func tune2FitsTheBudget() {
        let manifest = Self.manifest()
        let t2 = Suite.tune2()
        let minutes = t2.map { RunEstimate.seconds($0, manifest: manifest) }.reduce(0, +) / 60
        let pricing = Pricing.mini
        let projected = t2.reduce(0.0) { acc, s in
            let userSeconds = s.fixtureIDs.compactMap { manifest.utterance($0)?.speechSeconds }.reduce(0, +)
            return acc + pricing.projected(replies: s.userUtteranceCount + s.echoOnlyCount, userSeconds: userSeconds)
        }
        #expect(minutes >= 35 && minutes <= 46, "\(minutes) min")
        // The run starts without --over-projection at --max-usd 1.50.
        #expect(projected <= 1.50, "\(projected)")
        // The estimator reproduces the tune-1 run (128 min of scenario time) within 5%.
        let full = Suite.full().map { RunEstimate.seconds($0, manifest: manifest) }.reduce(0, +) / 60
        #expect(abs(full - 128) / 128 < 0.05 || manifest.generatedAt == "t", "\(full) min")
    }

    /// Tune-2 live ask (DeeVoice): she goes silent at the onset (a pause, `.barge_in` mark)
    /// and is flushed when the words are decided, ≈ 1.6–1.9 s later. The stop is scored at
    /// the pause; a flush after the 2 s window still counts when its pause began inside it.
    @Test func aBargeInIsScoredAtThePauseNotTheFlush() throws {
        func play(_ id: String, _ start: Double, _ end: Double?, flushed: Bool) -> RunRecord.Playback {
            var p = RunRecord.Playback(itemID: id, started: start); p.ended = end; p.flushed = flushed; return p
        }
        typealias O = RunRecord.BargeOutcome
        // Paused 0.2 s after the onset, flushed 1.8 s after it: stopped, latency 0.2.
        let paused = O.pauseMark([10.4, 11.2], replyStarted: 10, onset: 11, stoppedAt: 12.8)
        #expect(paused == 11.2)
        let r = O.classify(reply: play("a", 10, 12.8, flushed: true), later: [], onset: 11, endOfSpeech: 12, backchannel: false, pausedAt: paused)
        #expect(r == (.stopped, 12.8))
        var b = RunRecord.BargeIn(step: 0, baseFixture: "l04", fixture: "c01", targetAtMs: 900, replyItem: "a",
                                  replyStarted: 10, onset: 11, stoppedAt: r.stoppedAt, outcome: r.outcome)
        #expect(abs((b.latency ?? 9) - 1.8) < 1e-9)              // without the pause: the flush
        b.pausedAt = paused
        #expect(abs((b.latency ?? 9) - 0.2) < 1e-9)
        // Flushed 2.6 s after the onset (no brain answer yet): a stop when it paused in time …
        #expect(O.classify(reply: play("a", 10, 13.6, flushed: true), later: [], onset: 11, endOfSpeech: 12,
                           backchannel: false, pausedAt: 11.2) == (.stopped, 13.6))
        // … a miss without a pause (old scoring), or with one that began after the window.
        #expect(O.classify(reply: play("a", 10, 13.6, flushed: true), later: [], onset: 11, endOfSpeech: 12, backchannel: false).outcome == .missed)
        #expect(O.classify(reply: play("a", 10, 13.6, flushed: true), later: [], onset: 11, endOfSpeech: 12,
                           backchannel: false, pausedAt: 13.2).outcome == .missed)
        // A backchannel paused then resumed (never flushed) is "continued"; one paused and
        // cut late (the brain answered it) is a stop.
        #expect(O.classify(reply: play("a", 10, 20, flushed: false), later: [], onset: 11, endOfSpeech: 12, backchannel: true).outcome == .missed)
        #expect(O.classify(reply: play("a", 10, 17, flushed: true), later: [], onset: 11, endOfSpeech: 12,
                           backchannel: true, pausedAt: 11.3) == (.stopped, 17))
        // Marks before the reply or long before the onset are not this pause.
        #expect(O.pauseMark([9.5, 9.9], replyStarted: 10, onset: 11, stoppedAt: 12.8) == nil)
        #expect(O.pauseMark([10.2], replyStarted: 10, onset: 11.5, stoppedAt: 12.8) == nil)
        // Older records (no `pausedAt`) decode and keep the flush latency.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(b)) as! [String: Any]
        json["pausedAt"] = nil
        let old = try JSONDecoder().decode(RunRecord.BargeIn.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.pausedAt == nil && abs((old.latency ?? 9) - 1.8) < 1e-9)
    }
}
