import DeeRealtime
import Foundation
import Testing
@testable import DeeVoice

// Tune 10 (scratchpad/tune9-live.md; reports Tools/voice-harness/Reports/20261010-102105,
// -111224; traces Tools/voice-harness/Traces/<same>):
// (T9-2) "Are you awake?" 0.47 s after Dee's reply ended was deleted as Dee's echo (strict words).
// (T9-3) "Mm-hm." heard as "NNHN." over Dee was a turn (a hum needed an "m").
// (T9-7) Dee's echo heard as "Me." (no echo cancellation) cut Dee 4.8 s into Dee's reply.
// (T9-1) the brain's go-on waited while they talked on, and `holdAfterWords` cut Dee anyway.

// MARK: - T9-2: voice after Dee's playback is never judged as Dee's garbled echo

@Suite(.serialized) struct VoiceAfterHerIsNotStrictTests {
    /// Live t2-fallback-rollover-speech q02 (main run 20261010-102105, 22.94–25.15): Dee's
    /// reply ended at 22.94; "Are you awake?" began 23.41 (server onset 23124 ms, start
    /// event 23.608, stop 24.707 with its end 0.39 s after the words). The voice left the
    /// item to its words *strictly* and deleted it (`dee_del_16`): "you" was in Dee's line
    /// 19 s before, so only two of its words were new. Their voice came after Dee's playback
    /// and its tail — Dee's can't be there — so the words are judged as words.
    @Test(arguments: [false, true])
    func aQuestionRightAfterHerIsJudgedAsWords(aec: Bool) throws {
        var sim = RoomSim(seconds: 16, aec: aec)
        sim.setBed(try HarnessFixture.wav("noise/kitchen.wav"), snrDB: 20)
        if !aec { sim.setEcho(gainDB: -20, delayMs: 80, ir: try HarnessFixture.wav("ir/room.wav")) }
        try sim.say("q01", at: 0.5)
        let herStart = RoomSim.sample(4.0)
        RoomSim.place(try herReply(seconds: 6), into: &sim.her, at: herStart)
        let herEnd = herStart + RoomSim.sample(6)
        // AEC on: a soft voice (the fixture's level leaves it no doubt there).
        let u = try sim.say("q02", at: RoomSim.time(herEnd) - RoomSim.t0 + 0.47, gain: aec ? 0.05 : 1)
        sim.server = [(herEnd + RoomSim.sample(0.67), .start("item_q", onsetSample: herEnd + RoomSim.sample(0.18))),
                      (u.end + RoomSim.sample(0.49), .stop("item_q", endSample: u.end + RoomSim.sample(0.39)))]
        sim.run()
        #expect(!sim.actions.contains(.rejectEcho(itemID: "item_q")), "the question was deleted on its sound")
        #expect(!sim.actions.contains(.deferToWords(itemID: "item_q", strict: true)),
                "voice after Dee's playback was left to Dee-echo words (strict)")
        #expect(sim.actions.contains(.deferToWords(itemID: "item_q", strict: false))
                || sim.actions.contains(.acceptOnset(itemID: "item_q")))

        // Dee's live words before it: the question is theirs by its words.
        var w = HerWords()
        w.add("Hi Priya, nice to meet you. I\u{2019}m Dee, a tiny phone friend with big curiosity.", at: 6.341)
        w.add("I don\u{2019}t really have a favorite color, but I\u{2019}m drawn to bright, playful colors. "
              + "They just make everything feel a bit more fun.", at: 16.173)
        #expect(!w.isHerEcho("Are you awake?", at: 25.146))
    }

    /// Dee's own garbled echo under Dee's playing voice is still judged strictly (tune 2 live:
    /// "Years old." for "Here's a little thought"): nothing changed there.
    @Test func herGarbledEchoUnderHerVoiceStaysStrict() {
        var w = HerWords()
        w.add("Here's a little thought. The kettle sings, the window hums.", at: 10)
        #expect(w.isHerEcho("Years old.", at: 12, strict: true))
    }
}

// MARK: - T9-3: hums without an "m"

@Suite struct HumsWithoutAnMTests {
    /// Live t2-backchannel-kitchen15 bc02 (20261010-102105, 93.4): "Mm-hm." came back as
    /// the partial "NNHN." and the voice ended the hold (truncate at 1945 ms).
    @Test func liveNNHNIsAHum() {
        #expect(Backchannel.isBackchannel("NNHN.", inHold: true, final: false))
        #expect(Backchannel.isBackchannel("NNHN."))
        #expect(Backchannel.isMisheardFragment("NNHN."))
        for h in ["nhn", "hnn", "nn", "hn", "mmhn", "mhm", "nnhnn"] {
            #expect(Backchannel.isHum(h), "\(h)")
        }
        // Not hums: no m or n.
        for w in ["uh", "huh", "hu", "uhh"] {
            #expect(!Backchannel.isHum(w), "\(w)")
        }
    }
}

// MARK: - T9-7: one word of Dee's echo with no echo cancellation never cuts Dee

@Suite(.serialized) struct EchoOneWordNoAECTests {
    /// Dee's reply playing (no echo cancellation), Dee's words known; an onset `at` s into it
    /// pauses Dee; the item's partial words are `words`.
    private func pausedOverHer(_ rig: LoopRig, aec: Bool, words: [String]) async throws {
        _ = rig.graph.setManualFacts(aecActive: aec, outputLatency: 0)
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 8000)],
                                 text: "That\u{2019}s a lot to carry in your head, especially late at night. "
                                     + "Maybe you didn\u{2019}t do anything wrong; you were just being human.")
        try rig.quiet(2.6)
        try rig.talk(0.15)
        rig.push(Srv.speechStarted("item_u2", ms: rig.uplinkMsNow - 150))
        await rig.settle()
        var talked = 0.15
        while rig.voice.floorHold == nil, talked < 0.6 {
            try rig.talk(0.02)
            await rig.settle()
            talked += 0.02
        }
        try #require(rig.voice.floorHold?.itemID == "item_u2", "Dee was not paused")
        try rig.quiet(0.1)
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 100), Srv.committed("item_u2"))
        rig.deltas("item_u2", words)
        await rig.settle()
    }

    /// Live t2-backchannel-echo20 (20261010-102105, 65.14–66.28; AEC off, echo −20 dB): 2.6 s
    /// after Dee went on, Dee's echo opened an item heard as "Me."; the brain answered it and
    /// cut Dee at 4790 ms ("Hi, Alex. I'm listening too…"). The brain asks the voice
    /// (`isMisheardFragment(itemID:text:)`): one word over Dee's voice with no echo
    /// cancellation, that no word or sound says is a person, is Dee's echo — Dee goes on.
    @Test func liveMeOverHerWithNoEchoCancellationGoesOn() async throws {
        let rig = try LoopRig()
        try await pausedOverHer(rig, aec: false, words: ["Me", "."])
        #expect(rig.voice.isMisheardFragment(itemID: "item_u2", text: "Me."))
        // A word a person says alone, or a question, still stops Dee.
        #expect(!rig.voice.isMisheardFragment(itemID: "item_u2", text: "Stop."))
        #expect(!rig.voice.isMisheardFragment(itemID: "item_u2", text: "No."))
        #expect(!rig.voice.isMisheardFragment(itemID: "item_u2", text: "Why?"))
        #expect(!rig.voice.isMisheardFragment(itemID: "item_u2", text: "Tell me more about it."))
        rig.voice.shutdown()
    }

    /// Review (tune 10): a one-word barge-in a person says alone ("Enough.", "Dee.",
    /// "Pause.", "Quiet.", "Nope.") over Dee with no echo cancellation is theirs: it
    /// stops Dee. `Backchannel.notFragments` says so; the echo rule must not override it.
    @Test func aLoneWordBargeInIsNeverHerEcho() async throws {
        let rig = try LoopRig()
        try await pausedOverHer(rig, aec: false, words: ["Enough", "."])
        for w in ["Enough.", "Dee.", "Pause.", "Quiet.", "Nope.", "Hush.", "Actually.", "Hi."] {
            #expect(!rig.voice.isMisheardFragment(itemID: "item_u2", text: w), "\(w)")
        }
        #expect(rig.voice.isMisheardFragment(itemID: "item_u2", text: "Me."))
        rig.voice.shutdown()
    }

    /// With echo cancellation on, "Me." over Dee is theirs (unchanged).
    @Test func withEchoCancellationMeIsATurn() async throws {
        let rig = try LoopRig()
        try await pausedOverHer(rig, aec: true, words: ["Me", "."])
        #expect(!rig.voice.isMisheardFragment(itemID: "item_u2", text: "Me."))
        rig.voice.shutdown()
    }
}

// MARK: - T9-1: the brain's go-on cancels `holdAfterWords`

@Suite(.serialized) struct GoOnCancelsHoldAfterWordsTests {
    /// Live t2-backchannel-echo10 c05 "Keep going, I'm listening." (20261010-102105 and
    /// -111224, 54.4–58.7): the partial "Be sneaking," made the hold's verdict `.answer`
    /// (56.49); the brain said "go on" at 56.52 while they were still talking (deferred);
    /// `holdAfterWords` still cut Dee at 57.49 while "I'm listening." was being said. The
    /// brain's go-on cancels that deadline: Dee goes on once their words are in.
    @Test func aDeferredGoOnIsNotCutByHoldAfterWords() async throws {
        let rig = try LoopRig()
        let holds = Collector(rig.voice.holdEvents)
        try await rig.start()
        try await rig.pausedBy("item_u2", talk: 0.6)
        rig.deltas("item_u2", ["Be", " sneaking", ","])
        await rig.settle()
        try rig.talk(0.2)                                 // settled: not "go on" by its words
        #expect(rig.voice.floorHold?.wordsAt != nil)
        // The brain says "go on" while they are still talking: deferred.
        #expect(rig.voice.continueAfterBackchannel())
        #expect(rig.voice.floorHold != nil)
        // The server ends that item ("Be sneaking, going.") and opens the next for "I'm
        // listening.", still being said — well past `holdAfterWords` from the partial.
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 20), Srv.committed("item_u2"),
                 Srv.speechStarted("item_u3", ms: rig.uplinkMsNow))
        try rig.talk(0.2)
        rig.push(Srv.userTranscript("item_u2", "Be sneaking, going."))
        await rig.settle()
        try rig.talk(0.3)
        rig.deltas("item_u3", ["I'm"])
        await rig.settle()
        try rig.talk(CloudVoice.holdAfterWords - 0.2)
        await rig.settle()
        #expect(rig.voice.floorHold != nil, "the hold ended while the brain's go-on waited")
        #expect(rig.sent("conversation.item.truncate").isEmpty, "Dee's reply was cut")
        #expect(!holds.all.contains { if case .ended = $0 { true } else { false } }, "\(holds.all)")
        // Their words are in: Dee goes on.
        rig.push(Srv.speechStopped("item_u3", ms: rig.uplinkMsNow - 100), Srv.committed("item_u3"))
        rig.deltas("item_u3", [" listening", "."])
        rig.push(Srv.userTranscript("item_u3", "I'm listening."))
        let resumed = try await rig.stepUntil(1.5) { rig.voice.floorHold == nil }
        #expect(resumed != nil, "never went on")
        #expect(rig.sent("conversation.item.truncate").isEmpty)
        #expect(holds.all.contains { if case .resumed = $0 { true } else { false } }, "\(holds.all)")
        rig.voice.shutdown()
    }
}
