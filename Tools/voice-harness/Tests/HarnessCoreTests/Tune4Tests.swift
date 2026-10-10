import Foundation
import Testing
@testable import HarnessCore

/// Tune 4: the speculative-reply gate and the brain's sentence cap.
struct Tune4Tests {
    /// A held (speculative) reply the brain discarded: the server completed it, but the
    /// player never started it (a discard leaves no `.started`). Nobody heard it, so it
    /// is not a reply for the length gate.
    @Test func aDiscardedSpeculativeReplyHasNoLength() {
        var b = RunBuilder()
        b.reply("a1", started: 1, ended: 2, text: "Sure thing.")
        var r = RunRecord.Response(responseID: "resp_held", kind: "reply")
        r.startedAt = 3; r.doneAt = 4; r.status = "completed"; r.itemIDs = ["held"]
        r.transcript = "One. Two. Three. Four. Five."
        b.run.responses.append(r)
        b.run.deeTranscripts["held"] = r.transcript
        b.run.playback.append(.init(itemID: "held"))       // `.itemPlayed` can still create the record
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(m.replies == 1 && m.repliesWithinThree == 1)
        #expect(m.repliesUnplayed == 1)
        #expect(Gates.evaluate(m).first { $0.id == "reply_length" }?.status == .pass)
    }

    /// Brain live A/B 20261009-235323 t2-latency-clean: 4 sentences generated, the
    /// sentence cap stopped her before the 4th, 3 heard. The gate keeps counting the
    /// generated text; the heard count is reported beside it.
    @Test func theSentenceCapIsReportedAsHeard() {
        var b = RunBuilder()
        let text = "Sleep? Not really. I don’t do the sleeping thing. But I’m cozy and energized, and I’m happy to be chatting with you."
        b.reply("item_EXLHCmljWkNnJ1oyZKLko", started: 116.12, ended: 119.06, text: text, flushed: true, playedMs: 2920)
        b.run.heardSentences["item_EXLHCmljWkNnJ1oyZKLko"] = ["Sleep?", "Not really.", "I don’t do the sleeping thing."]
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(m.replySentenceCounts == [4])
        #expect(m.repliesWithinThree == 0)
        #expect(m.repliesHeard == 1 && m.repliesHeardWithinThree == 1)
        let g = Gates.evaluate(m).first { $0.id == "reply_length" }
        #expect(g?.status == .fail)
        #expect(g?.note?.contains("heard ≤ 3: 1/1") == true)
    }
}
