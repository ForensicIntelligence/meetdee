import Foundation
import Testing
@testable import HarnessCore

// 0.6 §6 (scope: the harness): narration, the leak scanner and the judge score only
// what she said aloud (`Metrics.spokenText`). Cases from the live tune reports:
// - T14 A `20261011-003412` t2-fallback-rollover-speech: "Let me think about" was
//   generated, then taken back before a sample played (no playback): not counted.
// - T13 A `20261010-224809` t2-fillers-echo10 / t2-drops-tv15: same, never played.
// - T13 A t2-backchannel-kitchen15: "Let me think about how to meet this gently." was
//   played (2,705 ms, both sentences heard) before the flush: still counted.

private func gate(_ gates: [Gate], _ id: String) -> Gate? { gates.first { $0.id == id } }

/// A reply the brain generated but the voice took back: a response and transcript,
/// optionally a playback entry flushed after `playedMs` with nothing heard.
private func takenBack(_ b: inout RunBuilder, item: String, at t: Double, text: String, playback: Bool, playedMs: Int = 0) {
    var r = RunRecord.Response(responseID: "resp_\(item)", kind: "reply")
    r.startedAt = t; r.doneAt = t + 0.4; r.status = "cancelled"; r.itemIDs = [item]; r.transcript = text
    b.run.responses.append(r)
    b.run.deeTranscripts[item] = text
    if playback {
        var p = RunRecord.Playback(itemID: item, started: t + 0.3)
        p.ended = t + 0.3 + Double(playedMs) / 1000; p.flushed = true; p.playedMs = playedMs
        b.run.playback.append(p)
        b.run.truncations.append(.init(itemID: item, audioEndMs: playedMs, at: p.ended!))
    }
}

@Suite("0.6: spoken-only scoring")
struct SpokenTextTests {
    @Test func takenBackNarrationIsNotCountedButKeptAsInformation() {
        var b = RunBuilder()
        b.run.scenario = "t2-fallback-rollover-speech"
        b.utterance("q01", 1, 2)
        b.userItem("u1", seen: 1.2)
        b.reply("a1", started: 3, ended: 5, text: "Sure, I'm here.")
        takenBack(&b, item: "item_EXj3QPjVB3rQRUhPxfMIw", at: 6, text: "Let me think about", playback: false)
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(m.narrations.isEmpty)
        #expect(m.leaksUnspoken.map(\.itemID) == ["item_EXj3QPjVB3rQRUhPxfMIw"])
        #expect(gate(Gates.evaluate(m), "narration")?.status == .pass)
        #expect(gate(Gates.evaluate(m), "narration")?.note?.contains("unspoken (not counted): 1") == true)
    }

    @Test func takenBackWithZeroMillisecondsPlayedIsNotCounted() {
        var b = RunBuilder()
        b.utterance("q01", 1, 2)
        b.userItem("u1", seen: 1.2)
        takenBack(&b, item: "x", at: 3, text: "Let me check what I’ve stored. <dee_state>", playback: true, playedMs: 0)
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(Metrics.spokenText(b.run, item: "x") == "")
        #expect(m.narrations.isEmpty && m.leaks.isEmpty)
        #expect(m.leaksUnspoken.count == 1)
    }

    @Test func aPlayedNarrationStillCounts() {
        // T13 A t2-backchannel-kitchen15 l05, played 2,705 ms then flushed; both sentences heard.
        var b = RunBuilder()
        b.run.scenario = "t2-backchannel-kitchen15"
        b.utterance("l05", 44, 46.9)
        b.userItem("u1", seen: 44.3)
        let item = "item_EXgzRsp1JBqfUvGFT5ko8"
        b.reply(item, started: 47.8, ended: 53.84,
                text: "I’m sorry, that sounds really heavy. Let me think about how to meet this gently.",
                flushed: true, playedMs: 2705)
        b.run.truncations.append(.init(itemID: item, audioEndMs: 2705, at: 53.82))
        b.run.heardSentences[item] = ["I’m sorry, that sounds really heavy.", "Let me think about how to meet this gently."]
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(m.narrations.map(\.itemID) == [item])
        #expect(gate(Gates.evaluate(m), "narration")?.status == .fail)
    }

    @Test func aCutReplyCountsOnlyItsHeardSentences() {
        var b = RunBuilder()
        b.utterance("q01", 1, 2)
        b.userItem("u1", seen: 1.2)
        b.reply("a1", started: 3, ended: 4.5, text: "Oh, nice. Let me check what I remember about that.", flushed: true, playedMs: 1500)
        b.run.heardSentences["a1"] = ["Oh, nice."]
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(Metrics.spokenText(b.run, item: "a1") == "Oh, nice.")
        #expect(m.narrations.isEmpty && m.leaksUnspoken.count == 1)
        #expect(m.utterances[0].spokenReply == "Oh, nice.")
        #expect(m.utterances[0].deeReply == "Oh, nice. Let me check what I remember about that.")
    }

    @Test func playedToTheEndUsesTheWholeTranscriptAndOfflineRecordsStillScore() {
        var b = RunBuilder()
        b.utterance("q01", 1, 2)
        b.userItem("u1", seen: 1.2)
        b.reply("a1", started: 3, ended: 5, text: "Let me respond to that.")
        #expect(Metrics.spokenText(b.run, item: "a1") == "Let me respond to that.")
        #expect(Metrics.compute([b.run], pricing: .mini).narrations.count == 1)
        // No playback data at all (an offline record): the transcript stands.
        var o = RunRecord(scenario: "s", model: "m", brain: "minimal", started: "t")
        o.deeTranscripts["z"] = "Let me respond."
        #expect(Metrics.spokenText(o, item: "z") == "Let me respond.")
        #expect(Metrics.compute([o], pricing: .mini).narrations.count == 1)
    }

    @Test func judgeSeesOnlySpokenTextAndStoredVerdictsAreRestricted() {
        var b = RunBuilder()
        b.utterance("q01", 1, 2, text: "What did we talk about?")
        b.userItem("u1", seen: 1.2)
        b.reply("a1", started: 3, ended: 4, text: "We talked about soup. I saved it in my notes.", flushed: true, playedMs: 900)
        b.run.heardSentences["a1"] = ["We talked about soup."]
        b.utterance("q02", 8, 9, text: "Are you awake?")
        b.userItem("u2", seen: 8.2)
        b.reply("a2", started: 10, ended: 10.2, text: "Let me respond.", flushed: true, playedMs: 0)
        let m = Metrics.compute([b.run], pricing: .mini)
        let items = Judge.items([b.run], metrics: m)
        #expect(items.map(\.reply) == ["We talked about soup."])
        var j = Judge.Summary(model: "gpt-4.1-mini")
        func score(_ i: Int, _ f: String, _ reply: String, leak: Bool, quote: String?) -> Judge.Score {
            .init(scenario: "s", family: "acoustic", index: i, fixture: f, score: leak ? 1 : 5, fitsState: true, leak: leak,
                  tooLong: false, grovels: false, laughsAtJoke: nil, guilt: false, reason: "", reply: reply, leakQuote: quote)
        }
        j.scores = [score(1, "q01", "We talked about soup. I saved it in my notes.", leak: true, quote: "I saved it in my notes"),
                    score(2, "q02", "Let me respond.", leak: true, quote: "Let me respond")]
        j.aggregate()
        #expect(j.leaks == 2)
        j.rescore([b.run], metrics: m)
        #expect(j.scores.count == 1 && j.unspokenDropped == 1)
        #expect(j.leaks == 0 && j.scores[0].leakDismissed?.hasPrefix("not spoken") == true)
    }
}
