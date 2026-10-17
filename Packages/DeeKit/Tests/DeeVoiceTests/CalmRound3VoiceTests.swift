import Foundation
import Testing
@testable import DeeVoice

// Calm round 3 (scratchpad calm/r2-live.md, verdict NOT-SHIP). Round 2 fixed the user's
// complaint after 0.6.0 ("Wow! It works! But it's too sensitive to interruptions": the TV and
// their own short sounds) — false pauses 4.1 %, 0 TV cuts — but real interruptions failed in
// four repeatable ways. Each test here reproduces a live r2 trace first (it fails on the round-2
// code), then pins the fix; the round-2 wins have controls next to them.

// MARK: - C1. The user's own short words in a TV room (live calm-ask-tv15 c03 / q03, both runs)

extension Round2TVLoop {
    /// Fixture `id` (from just before its onset) cut to its first `seconds`, as the user says it
    /// (`gainDB` nil: the fixture's own level) or as the TV says it (`aboveCeiling` dB over the
    /// bed's ceiling).
    func part(_ id: String, seconds: Double? = nil, aboveCeiling: Double? = nil) throws -> [Float] {
        var u = try Round2.audio(id)
        if let a = aboveCeiling {
            let c = try #require(rig.voice.earBed.ceilingDB)
            let g = Float(pow(10, (c + a - Level.rmsDB(u)) / 20))
            u = u.map { $0 * g }
        }
        if let seconds { u = Array(u[..<min(u.count, Int(seconds * LoopRig.rate))]) }
        return u
    }

    /// `audio` over Dee in item `item` (opened 0.16 s in); the server ends and commits it as
    /// the quick commit split it, then its words come as `deltas`.
    func split(_ audio: [Float], item: String, deltas: [String], next: String? = nil, _ w: PlayerWatch) async throws {
        try await rig.over(mixed(audio), item: item, w)
        rig.push(Srv.speechStopped(item, ms: rig.uplinkMsNow - 60), Srv.committed(item))
        await rig.settle()
        // Live: the next item's start came before the first item's words.
        if let next { rig.push(Srv.speechStarted(next, ms: rig.uplinkMsNow - 40)) }
        try feed(0.06, w)
        rig.deltas(item, deltas)
        await rig.settle()
    }
}

@Suite(.serialized) struct Round3TVWordsTests {
    /// Live calm-ask-tv15 c03 (A and B): «Wait.» — the first 0.6 s of "Wait, stop talking for a
    /// second.", split off by the quick commit — had too little voice at the TV bar for a stop
    /// word (0.16 s of the 0.25 s), was marked `ambient … reason=tvItemSustain`, and Dee went
    /// silent only 2.5 s later at the rest's words. Round 3: its near-field peak makes it theirs.
    @Test func theirSplitOffWaitPausesDeeInATVRoom() async throws {
        let tv = try Round2TVLoop(duckOnOnset: true)
        let w = PlayerWatch()
        try await tv.setUp(w)
        try await tv.split(try tv.part("c03", seconds: 0.6), item: "item_w", deltas: ["Wait", "."], w)
        let notes = tv.rig.notes.map(\.text)
        #expect(tv.rig.hasNote("duck item_w gain=-6"), "\(notes)")
        #expect(tv.rig.hasNote("hold item_w why=stopword"), "\(notes)")
        #expect(!tv.rig.hasNote("ambient"), "\(notes)")
        #expect(tv.rig.graph.player.isHeld)
        tv.rig.voice.shutdown()
    }

    /// Control (round 2's win): the TV's own "Wait." / first words of "Wait, stop…" — as loud
    /// as the bed's loud parts, or 2 dB louder — never pause Dee.
    @Test(arguments: [("c08", 0.0), ("c08", 2.0), ("c03", 0.0), ("c03", 2.0), ("c01", 2.0)])
    func theTVsWaitStillNeverPausesDee(id: String, above: Double) async throws {
        let tv = try Round2TVLoop(duckOnOnset: true)
        let w = PlayerWatch()
        try await tv.setUp(w)
        let word = id == "c01" ? "Stop" : "Wait"
        try await tv.split(try tv.part(id, seconds: 0.6, aboveCeiling: above), item: "item_tv", deltas: [word, "."], w)
        try tv.feed(0.4, w)
        await tv.rig.settle()
        let notes = tv.rig.notes.map(\.text)
        #expect(!tv.rig.hasNote("hold item_tv"), "\(id) +\(above): \(notes)")
        #expect(!w.held && tv.rig.truncates == 0, "\(id) +\(above): \(notes)")
        tv.rig.voice.shutdown()
    }

    /// Live calm-ask-tv15 q03 (B): «What?» | «time is it?» split by the quick commit; the
    /// first item's words came while the second was still being said, and all three items (the
    /// tail too) were dropped as the TV at once. Round 3: what looks like the TV so far waits for
    /// the open item (`tvPending`); the utterance is judged once it is all in.
    ///
    /// Round 3 review (regress F1): the end of it is round 2's residual again. Summed over its
    /// items this soft question (q03 at its own level, ~+8–10 dB peaks) is no louder than the TV's
    /// own split phrases (q01 | q07 at +2 dB summed to 0.28 s and cut Dee; the TV's q03 split by
    /// our commit passes the TV bar together too), so the sum counts only with near-field
    /// evidence (`Round3ReviewOwnSplitTests`, `Round3ReviewTVSumTests`). An item of it with a
    /// voice of its own over the TV still makes the whole hold theirs.
    @Test func aSplitQuestionInATVRoomIsNotDroppedMidway() async throws {
        let tv = try Round2TVLoop(duckOnOnset: true)
        let w = PlayerWatch()
        try await tv.setUp(w)
        let q = try tv.part("q03")
        let cut = Int(0.7 * LoopRig.rate)
        try await tv.split(Array(q[..<cut]), item: "item_a", deltas: ["What", "?"], next: "item_b", w)
        tv.rig.push(Srv.userTranscript("item_a", "What?"))
        await tv.rig.settle()
        try tv.rig.feed(tv.mixed(Array(q[cut...])), w)
        await tv.rig.settle()
        #expect(!tv.rig.hasNote("ambient"), "dropped while they still asked: \(tv.rig.notes.map(\.text))")
        #expect(tv.rig.voice.floorHold?.items.contains("item_b") == true, "\(tv.rig.notes.map(\.text))")
        tv.rig.voice.shutdown()
    }

    /// Control: the same split phrase said by the TV (as loud as its loud parts) is still the TV
    /// once all of it is in — dropped, never a pause.
    @Test func aSplitTVPhraseIsStillTheTV() async throws {
        let tv = try Round2TVLoop(duckOnOnset: true)
        let w = PlayerWatch()
        try await tv.setUp(w)
        let q = try tv.part("q03", aboveCeiling: 0)
        let cut = Int(0.7 * LoopRig.rate)
        try await tv.split(Array(q[..<cut]), item: "item_a", deltas: ["What", "?"], next: "item_b", w)
        tv.rig.push(Srv.userTranscript("item_a", "What?"))
        await tv.rig.settle()
        try tv.rig.feed(tv.mixed(Array(q[cut...])), w)
        tv.rig.push(Srv.speechStopped("item_b", ms: tv.rig.uplinkMsNow - 200), Srv.committed("item_b"))
        await tv.rig.settle()
        try tv.feed(0.1, w)
        tv.rig.push(Srv.userTranscript("item_b", "Time is it?"))
        await tv.rig.settle()
        try tv.feed(0.3, w)
        await tv.rig.settle()
        let notes = tv.rig.notes.map(\.text)
        #expect(tv.rig.hasNote("ambient item_a"), "\(notes)")
        #expect(!w.held && tv.rig.truncates == 0 && tv.rig.bargeIns == 0, "\(notes)")
        tv.rig.voice.shutdown()
    }
}

// MARK: - C2. A label released the duck inside a stop phrase (live t2-backchannel-echo20 c03, A)

@Suite(.serialized) struct Round3LabelTests {
    /// Live (A, 141.16–144.04): duck via=detector; 0.12 s later `unduck (label)` in the comma
    /// pause after "Wait," while the server's item stayed open; then a local-only duck with no
    /// item, so the item's «Wait» never reached the stop-word path: silent only at its words
    /// (+2.86 s). Round 3: no label release while the server item is open.
    @Test func aLabelNeverReleasesWhileTheServerItemIsOpen() async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        let t0 = rig.graph.now
        try await rig.over(Calm.voice(0.4), w)
        try #require(rig.voice.floorHold?.phase == .ducked, "\(rig.notes.map(\.text))")
        rig.voice.classifiedForTesting([("cough", 0.8)], window: t0...rig.graph.now)
        try rig.feed(Calm.gap(0.3), w)                    // the comma pause after "Wait,"
        await rig.settle()
        #expect(!rig.hasNote("unduck item_u2 (label)"), "\(rig.notes.map(\.text))")
        #expect(rig.voice.floorHold?.itemID == "item_u2", "\(rig.notes.map(\.text))")
        try rig.feed(Calm.voice(0.3), w)                  // "stop talking…"
        rig.deltas("item_u2", ["Wait", ","])
        await rig.settle()
        #expect(rig.hasNote("hold item_u2 why=stopword"), "\(rig.notes.map(\.text))")
        rig.voice.shutdown()
    }

    /// The other half: a duck released while the item is still open (here as `duckMax` would) and then the
    /// local-only run of the rest of it ducks Dee again — for that open item, so its stop word at
    /// its first delta still pauses Dee (round 2: `duck - … via=localOnly`, no item; the word
    /// came to nothing).
    @Test func aLocalOnlyDuckBelongsToTheOpenItem() async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply(ms: 20_000)
        try await rig.over(Calm.voice(0.4), w)
        try #require(rig.voice.floorHold?.phase == .ducked)
        rig.voice.unduckForTesting(why: "duckMax")
        try #require(rig.hasNote("unduck item_u2 (duckMax)"), "\(rig.notes.map(\.text))")
        try rig.feed(Calm.voice(1.06), w)
        await rig.settle()
        #expect(rig.hasNote("duck item_u2 gain=-12 via=localOnly"), "\(rig.notes.map(\.text))")
        rig.deltas("item_u2", ["Wait", ","])
        await rig.settle()
        #expect(rig.hasNote("hold item_u2 why=stopword"), "\(rig.notes.map(\.text))")
        #expect(!rig.voice.wasBackchannel(itemID: "item_u2"))
        rig.voice.shutdown()
    }

    /// Round 2's release still works once the server has ended the item: a lone cough.
    @Test func aLabelStillReleasesOnceTheItemEnded() async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        let t0 = rig.graph.now
        try await rig.over(Calm.voice(0.08) + Calm.hiss(0.2), w)
        rig.voice.classifiedForTesting([("cough", 0.8)], window: t0...rig.graph.now)
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 100))
        #expect(try await rig.idleUntil(1.0, w) { rig.voice.floorHold == nil } != nil, "\(rig.notes.map(\.text))")
        #expect(rig.hasNote("unduck item_u2 (label)"), "\(rig.notes.map(\.text))")
        #expect(!w.held && rig.truncates == 0)
        rig.voice.shutdown()
    }
}

// MARK: - C3. A known "go on" blocks the sustain pause (live t2-backchannel-echo20 c02, A)

@Suite(.serialized) struct Round3GoOnSustainTests {
    /// Live (A, 30.68–34.10): «Don't stop.» — go-on deferred ×3 while they talked on — then
    /// `sustained all=1.20` paused Dee (`why=sustained`), and the hold cut the reply although the
    /// words said go on. Round 3: no sustain pause over a known go-on; Dee goes on once quiet.
    /// `brain`: the go-on is the brain's (deferred); else only the item's full words say it.
    @Test(arguments: [true, false])
    func aGoOnIsNeverPausedBySustain(brain: Bool) async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(Calm.voice(0.5), w)
        try #require(rig.voice.floorHold?.phase == .ducked)
        rig.push(Srv.committed("item_u2"))
        rig.deltas("item_u2", ["Don't", " stop", "."])
        rig.push(Srv.userTranscript("item_u2", "Don't stop."))
        await rig.settle()
        if brain { #expect(rig.voice.continueAfterBackchannel()) }
        try rig.feed(Calm.voice(1.2), w)                 // more of it, past `sustainVoice`
        await rig.settle()
        let notes = rig.notes.map(\.text)
        #expect(rig.hasNote("sustained ignored: go-on"), "\(notes)")
        #expect(!w.held, "\(notes)")
        #expect(try await rig.idleUntil(1.0, w) { rig.voice.floorHold == nil } != nil, "\(rig.notes.map(\.text))")
        #expect(!w.held && rig.truncates == 0, "\(rig.notes.map(\.text))")
        rig.voice.shutdown()
    }

    /// Control: words that are not "go on" leave the sustain pause as it was.
    @Test func otherWordsStillPauseOnSustain() async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(Calm.voice(1.6), w)
        #expect(rig.voice.floorHold?.phase == .paused && w.held, "\(rig.notes.map(\.text))")
        #expect(!rig.hasNote("sustained ignored"), "\(rig.notes.map(\.text))")
        rig.voice.shutdown()
    }
}
