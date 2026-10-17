import Foundation
import Testing
@testable import DeeVoice

// Calm round 3 review (scratchpad calm/r3-review-regress.md, r3-review-correct.md). The user
// found Dee 0.6.0 "too sensitive to interruptions" (the TV, their own short sounds); round 2 fixed
// that, round 3 went after real interruptions. Two reviewers found round 3 broke a round-2 win
// (TV phrases the server split now added up to "theirs" and cut Dee) and D2's sustain pause (a
// real question right after «Okay.» / «Keep going.» never paused Dee and was filed as a
// backchannel). Each test here failed on the round-3 code.

// MARK: - regress F1: the TV's phrases the server split never add up to the user's voice

@Suite(.serialized) struct Round3ReviewTVSumTests {
    /// The TV says two phrases (q07 | q06, q01 | q07) as two server items of one hold, at +0 /
    /// +2 dB over the bed's ceiling: each alone is the TV; together they were summed over the TV
    /// bar (q01 | q07 +2: `voice 0.20` → `0.28`) and Dee was paused and cut (`hold item_b
    /// why=answer`). (q06 | q04 at +2 dB is left out: it pauses Dee on round 2 as well — TV louder
    /// than its own loud parts, the known residual.)
    @Test(arguments: [("q07", "q06", 0.0), ("q07", "q06", 2.0), ("q01", "q07", 2.0), ("q01", "q07", 0.0)])
    func theTVsSplitPhrasesNeverAddUp(a: String, b: String, above: Double) async throws {
        let tv = try Round2TVLoop(duckOnOnset: true)
        let w = PlayerWatch()
        try await tv.setUp(w)
        let first = try tv.part(a, aboveCeiling: above)
        let second = try tv.part(b, aboveCeiling: above)
        try await tv.split(first, item: "item_a", deltas: ["I", " did", " the", " beginning", "."], next: "item_b", w)
        tv.rig.push(Srv.userTranscript("item_a", "I did the beginning."))
        await tv.rig.settle()
        try tv.rig.feed(tv.mixed(second), w)
        await tv.rig.settle()
        tv.rig.push(Srv.speechStopped("item_b", ms: tv.rig.uplinkMsNow - 200), Srv.committed("item_b"))
        await tv.rig.settle()
        try tv.feed(0.1, w)
        tv.rig.deltas("item_b", ["In", " tonight's", " news", "."])
        tv.rig.push(Srv.userTranscript("item_b", "In tonight's news."))
        await tv.rig.settle()
        try tv.feed(0.4, w)
        await tv.rig.settle()
        let notes = tv.rig.notes.map(\.text)
        #expect(!notes.contains { $0.hasPrefix("hold item_") }, "\(a)+\(b) +\(above): \(notes)")
        #expect(!w.held && tv.rig.truncates == 0, "\(a)+\(b) +\(above): \(notes)")
        tv.rig.voice.shutdown()
    }

    /// The grouping itself: items join only across our own quick commit (and soon after it).
    @Test func onlyOurOwnSplitJoinsItems() {
        var h = CloudVoice.FloorHold(itemID: "a", since: 0)
        h.add("b")
        h.add("c")
        h.closedAt = ["a": 1.0, "b": 2.0]
        h.starts = ["a": 0.2, "b": 1.3, "c": 2.1]
        #expect(h.utterances == [["a"], ["b"], ["c"]])           // the server split them
        h.ownSplit = ["a"]
        #expect(h.utterances == [["a", "b"], ["c"]])             // we split a | b
        h.ownSplit = ["a", "b"]
        h.starts["c"] = 2.0 + CalmTuning.splitJoinGap + 0.2
        #expect(h.utterances == [["a", "b"], ["c"]])             // c began long after our commit
    }
}

// MARK: - regress F2 / correct F1: a go-on covers only what was said, never what comes next

@Suite(.serialized) struct Round3ReviewGoOnSustainTests {
    /// «Okay.» (its words in), then at once a long question in a new server item: round 3 noted
    /// `sustained ignored: go-on item_u3` and Dee was never paused; D2's ~1.2 s sustain pauses.
    @Test func aQuestionAfterAContinuerPausesOnSustain() async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(Calm.voice(0.4), w)
        try #require(rig.voice.floorHold?.phase == .ducked)
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 20), Srv.committed("item_u2"))
        rig.deltas("item_u2", ["Okay", "."])
        rig.push(Srv.userTranscript("item_u2", "Okay."))
        await rig.settle()
        rig.push(Srv.speechStarted("item_u3", ms: rig.uplinkMsNow))
        let t0 = rig.graph.now
        var heldAt: Double?
        for _ in 0..<25 {
            try rig.feed(Calm.voice(0.1), w)
            await rig.settle()
            if heldAt == nil, w.held { heldAt = rig.graph.now - t0 }
        }
        let notes = rig.notes.map(\.text)
        #expect(heldAt != nil, "a 2.5 s question after «Okay.» never paused Dee: \(notes)")
        #expect((heldAt ?? 9) <= 1.6, "paused only at \(heldAt ?? -1) s: \(notes)")
        #expect(notes.contains { $0.hasPrefix("hold item_u3 why=sustained") }, "\(notes)")
        #expect(!rig.hasNote("(duckMax)"), "\(notes)")
        rig.voice.shutdown()
    }

    /// «Keep going.» (words in; with and without the brain's deferred go-on), then at once a 2.2 s
    /// question in `item_u3`: round 3 ignored the sustain, undecked at `duckMax` while they still
    /// asked, and filed the question as a backchannel (the brain released it unanswered).
    @Test(arguments: [false, true])
    func keepGoingThenAQuestionIsTheirs(brain: Bool) async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply(ms: 30_000)
        try await rig.over(Calm.voice(0.6), w)
        try #require(rig.voice.floorHold?.phase == .ducked, "\(rig.notes.map(\.text))")
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 20), Srv.committed("item_u2"))
        rig.deltas("item_u2", ["Keep", " going", "."])
        rig.push(Srv.userTranscript("item_u2", "Keep going."))
        await rig.settle()
        try rig.feed(Calm.gap(0.1), w)
        await rig.settle()
        if brain { _ = rig.voice.continueAfterBackchannel() }
        try await rig.over(Calm.voice(2.2, hz: 210), item: "item_u3", w)
        try rig.feed(Calm.gap(0.5), w)
        rig.push(Srv.speechStopped("item_u3", ms: rig.uplinkMsNow - 480))
        await rig.settle()
        try rig.feed(Calm.gap(0.3), w)
        await rig.settle()
        rig.push(Srv.committed("item_u3"))
        await rig.settle()
        try rig.feed(Calm.gap(0.15), w)
        rig.deltas("item_u3", ["But", " why", " is", " the", " sky", " blue", "?"])
        rig.push(Srv.userTranscript("item_u3", "But why is the sky blue?"))
        await rig.settle()
        try rig.feed(Calm.gap(0.6), w)
        await rig.settle()
        let notes = rig.notes.map(\.text)
        #expect(w.held || rig.truncates > 0, "Dee talked on over the question: \(notes)")
        #expect(!rig.voice.wasBackchannel(itemID: "item_u3"), "question released as a backchannel: \(notes)")
        rig.voice.shutdown()
    }

    /// The brain's go-on for «Keep going.», deferred while a short question (under the 1.2 s
    /// sustain) is said in a later item of the same hold: round 3 never paused Dee for its words
    /// (`.answer` cannot escalate under the brain's go-on) and filed it as a backchannel. The go-on
    /// is for the items the brain saw; the question's words pause Dee.
    @Test func aShortQuestionAfterTheBrainsGoOnPausesAtItsWords() async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply(ms: 30_000)
        try await rig.over(Calm.voice(0.6), w)
        try #require(rig.voice.floorHold?.phase == .ducked, "\(rig.notes.map(\.text))")
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 20), Srv.committed("item_u2"))
        rig.deltas("item_u2", ["Keep", " going", "."])
        rig.push(Srv.userTranscript("item_u2", "Keep going."))
        await rig.settle()
        try rig.feed(Calm.gap(0.15), w)                          // they go on at once: same hold
        await rig.settle()
        try await rig.over(Calm.voice(0.2, hz: 210), item: "item_u3", w)
        // The brain's go-on for «Keep going.» comes while the question is being said: deferred.
        #expect(rig.voice.continueAfterBackchannel())
        try #require(rig.hasNote("go-on deferred item_u3"), "\(rig.notes.map(\.text))")
        try rig.feed(Calm.voice(0.2, hz: 210), w)
        try rig.feed(Calm.gap(0.3), w)
        rig.push(Srv.speechStopped("item_u3", ms: rig.uplinkMsNow - 280), Srv.committed("item_u3"))
        await rig.settle()
        rig.deltas("item_u3", ["Why", " though", "?"])
        rig.push(Srv.userTranscript("item_u3", "Why though?"))
        await rig.settle()
        try rig.feed(Calm.gap(0.4), w)
        await rig.settle()
        let notes = rig.notes.map(\.text)
        #expect(rig.hasNote("hold item_u3 why=answer"), "\(notes)")
        #expect(!rig.voice.wasBackchannel(itemID: "item_u3"), "\(notes)")
        rig.voice.shutdown()
    }

    /// The same in a pause: paused by the sustain test, «Keep going.», the brain's go-on deferred
    /// while a later item is said, then its words are a question. Round 3 left the hold to
    /// `holdWordsWait` (2.5 s after its end: the brain's go-on kept `holdAfterWords` off); now the
    /// question's words start `holdAfterWords` as without the go-on.
    @Test func aQuestionAfterTheBrainsGoOnInAPauseIsAnswerWords() async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply(ms: 30_000)
        try await rig.over(Calm.voice(1.6), w)
        try #require(rig.voice.floorHold?.phase == .paused, "\(rig.notes.map(\.text))")
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 20), Srv.committed("item_u2"))
        rig.deltas("item_u2", ["Keep", " going", "."])
        rig.push(Srv.userTranscript("item_u2", "Keep going."))
        await rig.settle()
        try await rig.over(Calm.voice(0.2, hz: 210), item: "item_u3", w)
        #expect(rig.voice.continueAfterBackchannel())
        try #require(rig.hasNote("go-on deferred item_u3"), "\(rig.notes.map(\.text))")
        try rig.feed(Calm.voice(0.3, hz: 210), w)
        try rig.feed(Calm.gap(0.3), w)
        rig.push(Srv.speechStopped("item_u3", ms: rig.uplinkMsNow - 280), Srv.committed("item_u3"))
        await rig.settle()
        rig.deltas("item_u3", ["Why", " though", "?"])
        rig.push(Srv.userTranscript("item_u3", "Why though?"))
        await rig.settle()
        let end = try await rig.idleUntil(2.0, w) { rig.hasNote("hold ended by the voice") }
        #expect(end != nil && (end ?? 9) <= CloudVoice.holdAfterWords + 0.3, "after \(end ?? -1) s: \(rig.notes.map(\.text))")
        #expect(!rig.voice.wasBackchannel(itemID: "item_u3"))
        rig.voice.shutdown()
    }

    /// `goOnKnown` covers what was said, not what comes next.
    @Test func goOnKnownIsOnlyForWhatWasSaid() {
        var h = CloudVoice.FloorHold(itemID: "a", since: 0)
        h.committed = true
        h.final["a"] = "Keep going."
        #expect(h.goOnKnown)
        h.add("b")                                               // a new item, no words yet
        #expect(!h.goOnKnown)
        h.partial["b"] = "But why"                               // still being said, not "go on"
        #expect(!h.goOnKnown)
        h.partial["b"] = "I'm listening"                        // still being said, "go on"
        #expect(h.goOnKnown)
        var g = CloudVoice.FloorHold(itemID: "a", since: 0)
        g.committed = true
        g.final["a"] = "Keep going."
        g.goOn = true
        g.goOnItems = ["a"]
        #expect(g.goOnKnown && !g.answerAfterGoOn)
        g.add("b")
        g.committed = true
        g.final["b"] = "Why though?"
        #expect(!g.goOnKnown && g.answerAfterGoOn)
    }
}

// MARK: - regress F1, the other half: one utterance our quick commit split still adds up

extension Round2TVLoop {
    /// `q` said over Dee as live calm-ask-tv15 q03 (B) went: onset, the duck, our quick commit
    /// 0.46 s into it (`quick commit (hold)` 10.66 for the onset at 10.20) while they talk on; the
    /// server acks it and opens `next` for the rest at once (10.66); the first item's words come
    /// 0.4 s later (11.08), while the rest is still being said.
    func ownSplit(_ q: [Float], item: String, words: String, next: String, _ w: PlayerWatch) async throws {
        let cut = Int(0.46 * LoopRig.rate), early = min(q.count, cut + Int(0.4 * LoopRig.rate))
        try await rig.over(mixed(Array(q[..<cut])), item: item, w)
        rig.voice.quickCommitForTesting()
        try #require(rig.hasNote("quick commit (hold) \(item)"), "\(rig.notes.map(\.text))")
        rig.push(Srv.committed(item), Srv.speechStarted(next, ms: rig.uplinkMsNow))
        await rig.settle()
        try rig.feed(mixed(Array(q[cut..<early])), w)
        await rig.settle()
        rig.deltas(item, [words])
        rig.push(Srv.userTranscript(item, words))
        await rig.settle()
        try rig.feed(mixed(Array(q[early...])), w)
        await rig.settle()
    }
}

@Suite(.serialized) struct Round3ReviewOwnSplitTests {
    /// The user's «What?» | «time is it?» (q03 at its own level), split by our quick commit as
    /// live: one utterance — never dropped as the TV while it is being said.
    @Test func aQuestionWeSplitInATVRoomIsNotDroppedMidway() async throws {
        let tv = try Round2TVLoop(duckOnOnset: true)
        let w = PlayerWatch()
        try await tv.setUp(w)
        try await tv.ownSplit(try tv.part("q03"), item: "item_a", words: "What?", next: "item_b", w)
        #expect(!tv.rig.hasNote("ambient"), "dropped while they still asked: \(tv.rig.notes.map(\.text))")
        tv.rig.voice.shutdown()
    }

    /// Control: the TV saying the same phrase (as loud as its loud parts), split the same way by
    /// our quick commit, is still the TV once all of it is in.
    @Test func aTVPhraseWeSplitIsStillTheTV() async throws {
        let tv = try Round2TVLoop(duckOnOnset: true)
        let w = PlayerWatch()
        try await tv.setUp(w)
        try await tv.ownSplit(try tv.part("q03", aboveCeiling: 0), item: "item_a", words: "What?", next: "item_b", w)
        tv.rig.push(Srv.speechStopped("item_b", ms: tv.rig.uplinkMsNow - 200), Srv.committed("item_b"))
        await tv.rig.settle()
        try tv.feed(0.1, w)
        tv.rig.push(Srv.userTranscript("item_b", "Time is it?"))
        await tv.rig.settle()
        try tv.feed(0.3, w)
        await tv.rig.settle()
        let notes = tv.rig.notes.map(\.text)
        #expect(tv.rig.hasNote("ambient item_a"), "\(notes)")
        #expect(!w.held && tv.rig.truncates == 0, "\(notes)")
        tv.rig.voice.shutdown()
    }
}
