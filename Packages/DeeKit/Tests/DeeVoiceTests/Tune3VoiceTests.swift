import AVFAudio
import DeeCore
import DeeRealtime
import Foundation
import Testing
@testable import DeeVoice

// Regression tests for the voice's part of the tune-2 live run
// (scratchpad/tune2-live.md; traces Tools/voice-harness/Traces/20261009-203321),
// rebuilt from the harness's fixtures with `RoomSim` (EarCore) or on the real
// `CloudVoice` with `LoopRig`, at the live trace's timings.

// MARK: - (2) A user line inside an item the room opened is never deleted on the sound

@Suite(.serialized) struct OpenItemAfterHerTests {
    /// t2-drops-tv15 p06a (live: `item_EXILDihKJHgWbQ33dPYP9`). The TV opened a
    /// server item 1.34 s before the end of Dee's reply (speech_started 0.62 s
    /// later); Dee ended; 1.18 s after Dee's end the user said "I was going to say
    /// that the movie was better than the book." inside that same open item. Live,
    /// the item was given up as Dee's echo at the decision timeout (0.18 s before
    /// they spoke) and deleted at its commit; its transcript came 0.4 s later.
    @Test func theUserTalkingIntoAnOpenItemAfterSheStoppedIsKept() throws {
        var sim = RoomSim(seconds: 22)
        sim.tag = "p06a"
        sim.setBed(try HarnessFixture.wav("noise/tv.wav"), snrDB: 15)
        try sim.say("q01", at: 0.5)
        let herStart = RoomSim.sample(4.0)
        RoomSim.place(try herReply(seconds: 8.85), into: &sim.her, at: herStart)
        let herEnd = herStart + RoomSim.sample(8.85)
        let tvOnset = herEnd - RoomSim.sample(1.34)
        let u = try sim.say("p06a", at: RoomSim.time(herEnd) - RoomSim.t0 + 1.18)
        sim.server = [(tvOnset + RoomSim.sample(0.62), .start("item_t", onsetSample: tvOnset)),
                      (u.end + RoomSim.sample(0.87), .stop("item_t", endSample: u.end + RoomSim.sample(0.77)))]
        sim.run()
        #expect(!sim.actions.contains(.rejectEcho(itemID: "item_t")), "the user's line was deleted as echo")
        #expect(sim.actions.contains(.acceptOnset(itemID: "item_t")))
    }

    /// The same open item with nobody talking into it: still never kept for ever —
    /// given up `openItemAfterTail` after Dee's echo left the room, or at its stop.
    @Test func anOpenItemNobodyTalksIntoIsStillGivenUp() throws {
        var sim = RoomSim(seconds: 22)
        sim.setBed(try HarnessFixture.wav("noise/tv.wav"), snrDB: 15)
        try sim.say("q01", at: 0.5)
        let herStart = RoomSim.sample(4.0)
        RoomSim.place(try herReply(seconds: 8.85), into: &sim.her, at: herStart)
        let herEnd = herStart + RoomSim.sample(8.85)
        let tvOnset = herEnd - RoomSim.sample(1.34)
        sim.server = [(tvOnset + RoomSim.sample(0.62), .start("item_t", onsetSample: tvOnset))]
        sim.run()
        // Given up on the sound, or — the TV's voice after Dee's tail is no echo of
        // Dee's — left to its words (CloudVoice deletes it when no words of someone
        // else come: the uplink gate keeps the TV's words from the server). Never
        // taken for the user on the sound. (Tune 10, T9-2: voice after Dee's playback
        // and its tail is judged as words, not strictly as Dee's garbled echo — the
        // same sound was "Are you awake?" live.)
        let decided = try #require(sim.firstTime {
            $0 == .rejectEcho(itemID: "item_t") || $0 == .deferToWords(itemID: "item_t", strict: true)
                || $0 == .deferToWords(itemID: "item_t", strict: false)
        }, "never decided")
        let tailEnd = RoomSim.time(herEnd) + EarCore.echoTail
        #expect(decided >= tailEnd + EarCore.openItemAfterTail - 0.1)
        #expect(decided <= tailEnd + EarCore.openItemAfterTail + 0.3)     // + the player's idle detection
        #expect(!sim.actions.contains(.acceptOnset(itemID: "item_t")))
    }

    /// t2-fallback-rollover-speech q02 (kitchen, 20 dB): an item opened at the very
    /// end of Dee's reply; "Are you awake?" 0.47 s later; speech_stopped 0.75 s after
    /// the words. The words are the user's.
    @Test func aQuestionRightAfterHerInAnItemHerTailOpenedIsKept() throws {
        var sim = RoomSim(seconds: 16)
        sim.setBed(try HarnessFixture.wav("noise/kitchen.wav"), snrDB: 20)
        try sim.say("q01", at: 0.5)
        let herStart = RoomSim.sample(4.0)
        RoomSim.place(try herReply(seconds: 6), into: &sim.her, at: herStart)
        let herEnd = herStart + RoomSim.sample(6)
        let u = try sim.say("q02", at: RoomSim.time(herEnd) - RoomSim.t0 + 0.47)
        sim.server = [(herEnd + RoomSim.sample(0.62), .start("item_q", onsetSample: herEnd)),
                      (u.end + RoomSim.sample(0.75), .stop("item_q", endSample: u.end + RoomSim.sample(0.66)))]
        sim.run()
        #expect(!sim.actions.contains(.rejectEcho(itemID: "item_q")), "the question was deleted as echo")
        #expect(sim.actions.contains(.acceptOnset(itemID: "item_q")))
    }
}

// MARK: - (3) "Stop." inside an item Dee's loud echo holds open (a documented limit)

@Suite(.serialized) struct StopUnderLoudEchoTests {
    /// t2-backchannel-echo10 c01 (live: "Stop." 0.9 s into Dee's reply, Dee's echo at
    /// −10 dB with echo cancellation off; Dee's echo had opened the server item
    /// 0.42 s into the reply and held it open; "Stop." was caught only by its
    /// words when the item stopped, 2.08 s after the onset).
    ///
    /// Offline, with the fixture voices, "Stop." under −10 dB leaves 40 ms of
    /// pitch that isn't Dee's: the sound alone can't tell it from Dee's own echo's
    /// unexplained bands (which come and go all through Dee's reply), so it is
    /// never acted on before its words — the 0 self-trigger gate. It is never
    /// deleted, and its settled words now decide it ~0.2 s before the transcript
    /// (`SettledWordsDecideLoopTests`). At −20 dB the sound stops Dee on the word.
    /// (Echo cancellation is on in the app.)
    @Test(arguments: [-10.0, -20.0])
    func aShortStopInsideHerOpenEchoItemIsNeverLost(gainDB: Double) throws {
        var sim = RoomSim(seconds: 12, aec: false)
        sim.setEcho(gainDB: gainDB, delayMs: 80, ir: try HarnessFixture.wav("ir/room.wav"))
        RoomSim.place(try herReply("l01", seconds: 2.5), into: &sim.her, at: RoomSim.sample(0.3))
        let herStart = RoomSim.sample(4.0)
        RoomSim.place(try herReply("l04", seconds: 7), into: &sim.her, at: herStart)
        let echoOnset = herStart + RoomSim.sample(0.42)
        let u = try sim.say("c01", at: 4.9)
        sim.server = [(echoOnset + RoomSim.sample(0.64), .start("item_x", onsetSample: echoOnset)),
                      (u.end + RoomSim.sample(1.16), .stop("item_x", endSample: u.end + RoomSim.sample(1.06)))]
        sim.run()
        #expect(!sim.actions.contains(.rejectEcho(itemID: "item_x")))
        let stopped = sim.firstTime { if case .bargeIn = $0 { true } else { false } }
        let words = sim.firstTime {
            $0 == .deferToWords(itemID: "item_x", strict: false) || $0 == .deferToWords(itemID: "item_x", strict: true)
        }
        if gainDB <= -20 {
            let at = try #require(stopped, "−20 dB: not stopped on the sound")
            #expect(at <= RoomSim.time(u.end))
        } else {
            #expect(stopped != nil || words != nil, "−10 dB: neither stopped nor left to its words")
        }
    }
}

// MARK: - (1) A backchannel pauses Dee for well under a second

extension LoopRig {
    /// Steps 20 ms at a time (letting events through) until `done`, at most
    /// `limit` s of graph time; returns the graph seconds it took (nil: never).
    func stepUntil(_ limit: Double, _ done: () -> Bool) async throws -> Double? {
        var elapsed = 0.0
        while elapsed < limit + 1e-9 {
            await settle()
            if done() { return elapsed }
            try step()
            elapsed += 0.02
        }
        await settle()
        return done() ? elapsed : nil
    }

    /// The transcription of `item` as the live server sends it after a commit:
    /// a burst of deltas ~0.12 s later.
    func deltas(_ item: String, _ words: [String]) {
        for w in words { push(.inputTranscriptionDelta(.init(itemID: item, delta: w))) }
    }

    /// Dee's reply playing, then the user's onset over it and the server's item for
    /// it: Dee is paused (`floorHold`). `talk` s of their voice in all.
    func pausedBy(_ item: String, talk: Double, replyMs: Int = 6000) async throws {
        try quiet(0.3)
        try await answerWith([("item_a1", replyMs)])
        try quiet(0.6)
        try self.talk(0.15)
        push(Srv.speechStarted(item, ms: uplinkMsNow - 150))
        await settle()
        try self.talk(talk - 0.15)
        try #require(voice.floorHold?.itemID == item, "Dee was not paused")
    }
}

@Suite(.serialized) struct FloorHoldQuickTests {
    /// t2-backchannel-fan15 / kitchen15 bc01 "Go on." and bc02 "Mm-hm." (live: Dee
    /// resumed 1.0–1.4 s after the words — the server's semantic VAD sent
    /// speech_stopped with its commit 0.7 s after them, the deltas came 0.11 s
    /// after that, settled 0.15 s later). Now the voice commits the short burst
    /// itself once they have been quiet `holdCommitSilence`, and Dee goes on
    /// within 0.6 s of their last sound — without the server's speech_stopped.
    @Test(arguments: [("Go on.", ["Go", " on", "."], 0.58), ("Mm-hm.", ["Mm", "-hm", "."], 0.89)])
    func aShortBackchannelResumesHerWithinSixTenthsOfASecond(text: String, words: [String], seconds: Double) async throws {
        let rig = try LoopRig()
        let holds = Collector(rig.voice.holdEvents)
        try await rig.start()
        try await rig.pausedBy("item_u2", talk: seconds)
        let paused = rig.voice.graph.player.playedMs(utterance: "item_a1")
        let commit = try #require(try await rig.stepUntil(0.6) { !rig.sent("input_audio_buffer.commit").isEmpty },
                                  "never committed their words")
        #expect(commit >= CloudVoice.holdCommitSilence - 0.04, "committed \(commit) s after their words: they may not be done")
        // The server: committed at once, the transcript's deltas 0.12 s later.
        rig.push(Srv.committed("item_u2"))
        try rig.quiet(0.12)
        rig.deltas("item_u2", words)
        let resumed = try #require(try await rig.stepUntil(0.6) { rig.voice.floorHold == nil }, "never resumed")
        let pause = commit + 0.12 + resumed
        #expect(pause <= 0.6, "Dee resumed \(pause) s after their words (live: 1.0–1.4 s)")
        let at = rig.output.count
        try rig.quiet(0.3)
        #expect(rig.audibleMs(fromSample: at) > 250)
        rig.push(Srv.userTranscript("item_u2", text))
        await rig.settle()
        try rig.quiet(6.0)
        let played = try #require(rig.itemPlayed("item_a1"))
        #expect(played.ms == 6000 && !played.cut, "\(played) (paused at \(paused))")
        #expect(rig.sent("conversation.item.truncate").isEmpty)
        #expect(rig.sent("response.cancel").isEmpty)
        #expect(!rig.voiceEvents.contains(.bargeIn))
        // For the brain: what Dee went on through.
        #expect(rig.voice.wasBackchannel(itemID: "item_u2"))
        #expect(holds.all.first == .paused(itemID: "item_u2"))
        #expect(holds.all.contains(.resumed(itemIDs: ["item_u2"], text: words.joined(), why: "words")), "\(holds.all)")
        rig.voice.shutdown()
    }

    /// "Stop." is committed as quickly — and is no backchannel: Dee stays paused
    /// and the brain answers it (`holdAfterWords` ends the reply if it doesn't).
    @Test func aShortStopIsCommittedAsQuicklyAndNeverResumes() async throws {
        let rig = try LoopRig()
        let holds = Collector(rig.voice.holdEvents)
        try await rig.start()
        try await rig.pausedBy("item_u2", talk: 0.58)
        #expect(try await rig.stepUntil(0.6) { !rig.sent("input_audio_buffer.commit").isEmpty } != nil)
        rig.push(Srv.committed("item_u2"))
        try rig.quiet(0.12)
        rig.deltas("item_u2", ["Stop", "."])
        // Tune 4: a quick burst's partial words that aren't "go on" decide with its
        // full transcript (live: 0.25 s after the deltas), or `holdFinalWait`.
        try rig.quiet(0.25)
        rig.push(Srv.userTranscript("item_u2", "Stop."))
        try rig.quiet(0.15)
        await rig.settle()
        #expect(rig.voice.floorHold?.wordsAt != nil, "their words were not taken as a real turn")
        try rig.quiet(CloudVoice.holdAfterWords)
        await rig.settle()
        #expect(rig.voice.floorHold == nil)
        #expect(await rig.waitSent("conversation.item.truncate"))
        #expect(!holds.all.contains { if case .resumed = $0 { true } else { false } })
        #expect(holds.all.contains(.ended(itemIDs: ["item_u2"], byVoice: true)), "\(holds.all)")
        #expect(!rig.voice.wasBackchannel(itemID: "item_u2"))
        rig.voice.shutdown()
    }

    /// t2-backchannel c02 "Don't stop, … keep going." (0.77 s, a 0.47 s gap, 0.61 s):
    /// the first burst is committed in the gap and its words ("Don't stop.") come
    /// while they talk on — Dee never resumes over them. The second burst gets its
    /// own item and its own quick commit; Dee goes on within 0.6 s of the end.
    @Test func twoBurstsDecideTogetherAndSheNeverResumesOverThem() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try await rig.pausedBy("item_u2", talk: 0.77)
        let commit1 = try #require(try await rig.stepUntil(0.47) { !rig.sent("input_audio_buffer.commit").isEmpty })
        rig.push(Srv.committed("item_u2"))
        try rig.quiet(max(0, 0.47 - commit1))
        // Burst 2; the first words land while they talk.
        try rig.talk(0.15)
        rig.deltas("item_u2", ["Don't", " stop", "."])
        await rig.settle()
        try rig.talk(0.15)
        rig.push(Srv.speechStarted("item_u3", ms: rig.uplinkMsNow - 300))
        await rig.settle()
        try rig.talk(0.31)
        #expect(rig.voice.floorHold != nil, "Dee resumed while they were talking")
        #expect(rig.voice.floorHold?.items == ["item_u2", "item_u3"])
        let commit2 = try #require(try await rig.stepUntil(0.6) { rig.sent("input_audio_buffer.commit").count >= 2 },
                                   "the second burst was never committed")
        rig.push(Srv.committed("item_u3"))
        try rig.quiet(0.12)
        rig.deltas("item_u3", ["Keep", " going", "."])
        let resumed = try #require(try await rig.stepUntil(0.6) { rig.voice.floorHold == nil }, "never resumed")
        #expect(commit2 + 0.12 + resumed <= 0.6, "resumed \(commit2 + 0.12 + resumed) s after their words (live: 3.0–4.6 s)")
        try rig.quiet(7)
        #expect(rig.itemPlayed("item_a1").map { !$0.cut } == true)
        #expect(rig.voice.wasBackchannel(itemID: "item_u2") && rig.voice.wasBackchannel(itemID: "item_u3"))
        rig.voice.shutdown()
    }

    /// "Mm, … what about the moon?": "Mm." is committed in the pause and its words
    /// say "go on" — but they talked on, and no item holds that yet. Dee waits
    /// for it (`holdUncoveredWait`); its words are a real turn: Dee never resumes.
    @Test func moreWordsAfterAQuickCommitAreWaitedFor() async throws {
        let rig = try LoopRig()
        let holds = Collector(rig.voice.holdEvents)
        try await rig.start()
        try await rig.pausedBy("item_u2", talk: 0.4)
        #expect(try await rig.stepUntil(0.5) { !rig.sent("input_audio_buffer.commit").isEmpty } != nil)
        rig.push(Srv.committed("item_u2"))
        try rig.quiet(0.12)
        try rig.talk(0.9)                                   // "what about the moon?"
        rig.deltas("item_u2", ["Mm", "."])
        await rig.settle()
        try rig.quiet(0.35)
        await rig.settle()
        #expect(rig.voice.floorHold != nil, "Dee resumed over words no item held yet")
        rig.push(Srv.speechStarted("item_u3", ms: rig.uplinkMsNow - 1200))
        await rig.settle()
        try rig.quiet(0.1)
        await rig.settle()
        #expect(rig.voice.floorHold?.items == ["item_u2", "item_u3"])
        // Long speech: the server's own stop and commit.
        rig.push(Srv.speechStopped("item_u3", ms: rig.uplinkMsNow - 300), Srv.committed("item_u3"),
                 Srv.userTranscript("item_u3", "What about the moon?"))
        await rig.settle()
        try rig.quiet(0.2)
        #expect(rig.voice.floorHold?.wordsAt != nil)
        #expect(!holds.all.contains { if case .resumed = $0 { true } else { false } })
        rig.voice.shutdown()
    }
}

// MARK: - (3) Words Dee never said decide an item as soon as they settle

@Suite(.serialized) struct SettledWordsDecideLoopTests {
    /// An item Dee's loud echo opened, left to its words: "Stop." (not Dee's) holds
    /// Dee as soon as its deltas settle — not ~0.2 s later at the transcript.
    /// Dee's own words still wait for the transcript (more may come).
    @Test func settledWordsSheNeverSaidHoldHerBeforeTheTranscript() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 4000)], text: "Okay, so the meeting ran long and nobody wanted it.")
        try rig.quiet(0.5)
        rig.push(Srv.speechStarted("item_x", ms: rig.uplinkMsNow - 200))
        await rig.settle()
        try rig.quiet(0.1)
        rig.voice.deferToWordsForTesting("item_x")
        rig.push(Srv.speechStopped("item_x", ms: rig.uplinkMsNow - 50), Srv.committed("item_x"))
        rig.deltas("item_x", ["Stop", "."])
        await rig.settle()
        try rig.quiet(CloudVoice.holdSettle + 0.06)
        await rig.settle()
        #expect(rig.voice.itemsAwaitingWords.isEmpty, "the settled words did not decide")
        #expect(rig.voice.floorHold?.itemID == "item_x", "Dee kept talking over \"Stop.\"")
        #expect(rig.brainSession { if case .userCommitted("item_x", _) = $0 { true } else { false } }.count == 1)
        rig.voice.shutdown()
    }

    @Test func herOwnSettledWordsWaitForTheTranscript() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 4000)], text: "Okay, so the meeting ran long and nobody wanted it.")
        try rig.quiet(0.5)
        rig.push(Srv.speechStarted("item_x", ms: rig.uplinkMsNow - 200))
        await rig.settle()
        try rig.quiet(0.1)
        rig.voice.deferToWordsForTesting("item_x")
        rig.push(Srv.speechStopped("item_x", ms: rig.uplinkMsNow - 50), Srv.committed("item_x"))
        rig.deltas("item_x", ["The meeting", " ran"])
        await rig.settle()
        try rig.quiet(0.3)
        await rig.settle()
        #expect(rig.voice.itemsAwaitingWords == ["item_x"])
        rig.push(Srv.userTranscript("item_x", "The meeting ran long."))
        await rig.settle()
        try rig.quiet(0.1)
        #expect(await rig.waitSent("conversation.item.delete"))
        #expect(rig.voice.floorHold == nil)
        rig.voice.shutdown()
    }
}

// MARK: - (2b) A stop offset from another timeline never empties the item's window

@Suite struct StaleStopOffsetTests {
    /// t2-fallback-rollover-speech q02 / q05 (live: an item opened at the end of
    /// Dee's reply; "Are you awake?" in it; deleted as echo at its stop during a
    /// rollover). The same scene with the live trace's offsets keeps the words
    /// offline (`aQuestionRightAfterHerInAnItemHerTailOpenedIsKept`); what a
    /// rollover can add is a stop whose offset maps onto the new session's
    /// timeline — before the item's onset. Its window must still hold the words.
    @Test func aStopMappedBeforeItsOnsetStillSeesTheWords() {
        var h = EarHarness()
        h.startPlayback()
        h.echo(0.5)
        h.stopPlayback()
        h.clear()
        let onset = h.t
        h.serverStart("item_q", onset: onset)            // in Dee's echo tail
        h.quiet(EarCore.echoTail + 0.1)
        h.voice(0.18)                                     // a short "Yes." after Dee's tail
        h.quiet(0.3)
        h.serverStop("item_q", end: onset - 8)            // mapped on the wrong timeline
        #expect(!h.decisions.contains(.rejectEcho(itemID: "item_q")), "\(h.decisions)")
        #expect(h.decisions.contains(.acceptOnset(itemID: "item_q"))
                || h.decisions.contains(.deferToWords(itemID: "item_q", strict: true))
                || h.decisions.contains(.deferToWords(itemID: "item_q", strict: false)))
    }
}
