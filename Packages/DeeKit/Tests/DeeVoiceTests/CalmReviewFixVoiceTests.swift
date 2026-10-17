import AVFAudio
import DeeRealtime
import Foundation
import Testing
@testable import DeeVoice

/// Calm review fixes, voice half (scratchpad calm/review-regress.md, review-correct.md).

// MARK: - correct F1: a body-sound label never releases the duck while they talk on

@Suite(.serialized) struct CalmReviewLabelTests {
    /// A cough, then at once "Hold on, what time is it?" (1.2 s of voice); the cough's
    /// `label` comes in 0.3 s into the burst.
    func run(_ label: String) async throws -> (held: Bool, heldAt: Double?, notes: [String]) {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        let t0 = rig.graph.now
        let all = Calm.voice(0.08) + Calm.hiss(0.06) + Calm.voice(1.2)
        let n = Int((0.16 / 0.02).rounded()) * Calm.step
        try rig.feed(Array(all[..<n]), w)
        rig.push(Srv.speechStarted("item_u2", ms: rig.uplinkMsNow - 160))
        await rig.settle()
        var labelled = false
        var heldAt: Double?
        var i = n
        while i + Calm.step <= all.count {
            try rig.step(Array(all[i..<(i + Calm.step)]))
            w.look(rig.graph.player)
            if heldAt == nil, rig.graph.player.isHeld { heldAt = rig.graph.now - t0 }
            i += Calm.step
            if !labelled, rig.graph.now - t0 >= 0.30 {
                labelled = true
                rig.voice.classifiedForTesting([(label, 0.8)], window: t0...(t0 + 0.15))
            }
            await rig.settle()
        }
        let out = (w.held, heldAt, rig.notes.map(\.text))
        rig.voice.shutdown()
        return out
    }

    @Test(arguments: ["cough", "laughter", "music"])
    func aLabelNeverReleasesWhileTheyTalkOn(label: String) async throws {
        let r = try await run(label)
        #expect(r.held, "Dee never paused for 1.2 s of speech after a \(label): \(r.notes)")
        // Round 2 (D2): sustained voice pauses Dee after `CalmTuning.sustainVoice` (1.2 s) of it.
        #expect((r.heldAt ?? 99) <= 1.45, "paused late at \(String(describing: r.heldAt)): \(r.notes)")
        #expect(!r.notes.contains { $0.hasPrefix("unduck item_u2 (label)") }, "\(r.notes)")
    }

    /// The release itself still works once they are quiet: a lone cough, labelled.
    @Test func aLabelStillReleasesOnceTheyAreQuiet() async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        let t0 = rig.graph.now
        try await rig.over(Calm.voice(0.08) + Calm.hiss(0.2), w)
        #expect(rig.voice.floorHold?.phase == .ducked)
        rig.voice.classifiedForTesting([("cough", 0.8)], window: t0...rig.graph.now)
        #expect(try await rig.idleUntil(1.0, w) { rig.voice.floorHold == nil } != nil, "\(rig.notes.map(\.text))")
        #expect(!w.held && rig.truncates == 0)
        rig.voice.shutdown()
    }
}

// MARK: - regress F3: R5 needs the label

@Suite(.serialized) struct CalmReviewNoWordsTests {
    /// 1.2 s of continuous voice: sustained → paused; its transcription fails; no label.
    /// Not a laugh as far as anyone can tell: 0.6.0's end (the reply ends; the brain
    /// answers the audio), never "Dee goes on".
    @Test func anUnlabelledSustainedBurstWithFailedWordsEndsTheReply() async throws {
        let rig = try LoopRig(duckOnOnset: true)
        let w = PlayerWatch()
        try await rig.start()
        try await rig.calmReply()
        try await rig.over(Calm.voice(1.2), w)
        #expect(rig.hasNote("hold item_u2 why=sustained"), "\(rig.notes.map(\.text))")
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 100), Srv.committed("item_u2"))
        await rig.settle()
        try rig.idle(0.15)
        #expect(!rig.voice.holdClaims(itemID: "item_u2"), "the voice claims a question's failed words")
        rig.push(.inputTranscriptionFailed(.init(itemID: "item_u2", error: nil)))
        _ = try await rig.idleUntil(3.0) { rig.voice.floorHold == nil }
        #expect(!rig.hasNote("resumed item_u2 (nowords)"), "\(rig.notes.map(\.text))")
        #expect(rig.hasNote("hold ended by the voice"), "\(rig.notes.map(\.text))")
        rig.voice.shutdown()
    }
}

// MARK: - EarCore: regress F1, correct F3, correct F4

@Suite struct CalmReviewEarTests {
    /// Dee playing, the user's "mm-hm" ducked Dee for `item_m`.
    static func ducked() -> EarHarness {
        var h = EarHarness()
        h.core.duckOnOnset = true
        h.startPlayback()
        h.echo(0.6)
        h.voice(0.2)
        h.serverStart("item_m")
        h.voice(0.3)
        return h
    }

    @Test func aNewItemUnderTheDuckIsJudgedAgainstDeesEcho() {
        var h = Self.ducked()
        #expect(h.log.contains(.duck(itemID: "item_m", via: "detector")) || h.log.contains(.duck(itemID: "item_m", via: "onset")),
                "\(h.decisions)")
        h.echo(0.2)
        h.clear()
        h.serverStart("item_e", onset: h.t - 0.1)    // Dee's echo opens an item
        #expect(h.core.isDeciding("item_e"), "a new item under the duck was taken as the user's")
        #expect(!h.decisions.contains(.acceptOnset(itemID: "item_e")))
        h.echo(0.4)
        h.serverStop("item_e")
        #expect(!h.decisions.contains(.acceptOnset(itemID: "item_e")), "\(h.decisions)")
        // The user talking on in a new item is still theirs.
        h.clear()
        h.serverStart("item_v", onset: h.t - 0.05)
        h.voice(0.5)
        h.serverStop("item_v")
        #expect(h.decisions.contains(.acceptOnset(itemID: "item_v")) || h.decisions.contains(.deferToWords(itemID: "item_v", strict: false)),
                "\(h.decisions)")
    }

    @Test func theItemThatDuckedDeeIsStillTheUsers() {
        var h = Self.ducked()
        h.clear()
        h.serverStart("item_m")                      // a repeat of its own onset: never decided again
        #expect(!h.core.isDeciding("item_m"))
    }

    @Test func aReplyThatPlaysOutUnderTheDuckWasTheUsersFloor() {
        var h = Self.ducked()
        h.stopPlayback()                             // played out, still ducked
        h.clear()
        h.serverStart("item_n")                      // in Dee's echo tail
        #expect(!h.core.isDeciding("item_n"), "the tail of a ducked stretch judged the user as echo")
        // Control: a stretch nobody talked over keeps its echo tail.
        var g = EarHarness()
        g.core.duckOnOnset = true
        g.startPlayback()
        g.echo(0.6)
        g.stopPlayback()
        g.serverStart("item_n")
        #expect(g.core.isDeciding("item_n"))
    }

    /// A TV room: Dee goes on (a resume) while the user talks on. The TV-bar run starts
    /// again, as the room-bar run does: no local-only barge-in from the run before it.
    @Test func aResumeRestartsTheTVRun() {
        var h = EarHarness()
        h.core.duckOnOnset = true
        var bed = RoomBed()
        CalmTVRoomTests.feed(&bed, from: h.t - 8, to: h.t, share: 0.3)
        bed.advance(to: h.t + 0.05)
        h.core.bed = bed
        #expect(h.core.tvRoom)
        h.startPlayback()
        h.echo(0.4)
        h.voice(0.6)
        h.log += h.core.playbackResumed(at: h.t)
        h.clear()
        h.voice(0.6)                                 // 1.2 s in all, 0.6 s since the resume
        #expect(!h.decisions.contains(.bargeIn(itemID: nil)), "\(h.decisions)")
    }
}
