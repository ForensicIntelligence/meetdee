import DeeRealtime
import Foundation
import Testing
@testable import DeeVoice

// Tune 8 (scratchpad/tune7-live.md; report Tools/voice-harness/Reports/20261010-063215,
// traces Tools/voice-harness/Traces/20261010-063215):
// (T7-1/T7-2) `Backchannel.isMisheardFragment` is the one rule voice and brain use for
// short misheard words over her voice. (T7-3) a phantom "Yeah." from her own echo (AEC
// off) resumed as a backchannel armed `resumeGrace`, and "Are you awake?" paused her only
// 1.56 s after its onset.

// MARK: - T7-1 / T7-2: the misheard-fragment rule, from the live strings

@Suite struct Tune8MisheardFragmentTests {
    /// Backchannels over her that came back misheard, live.
    @Test func liveBackchannelMisreadsAreFragments() {
        let live = [
            "Sheupr and going.",        // backchannel-echo20 c05 "Keep going" (tune 7: decided early as 3 words)
            "I'm listen.",              // backchannel-fan15 c05 "I'm listening." cut off (tune 7: answered)
            "Put going.", "Grand.", "She.", "Done.", "MMHN.", "MMHM.",   // tune 6
            "Going on.", "Sheep.", "Um, grand.", "Yeah.",
        ]
        for t in live {
            #expect(Backchannel.isMisheardFragment(t), "\(t)")
            #expect(Backchannel.isBackchannel(t, inHold: true), "\(t): in a hold, its full transcript")
        }
        // The cut-off continuer is safe on partials too (the brain's early-words guard).
        for p in ["Sheupr and going", "I'm listen", "I'm still listen"] {
            #expect(Backchannel.isMisheardFragment(p), "\(p)")
        }
    }

    /// Reactions only say "go on" over her voice (decision: backchannels continue her).
    @Test func reactionsAreFragments() {
        for t in ["I see.", "Me too.", "Thank you.", "Thank you, Dee.", "Thanks.", "I know.", "Me neither.", "Fair enough."] {
            #expect(Backchannel.isMisheardFragment(t), "\(t)")
        }
    }

    /// Stops, questions and turns are never fragments, however short.
    @Test func turnsAreNotFragments() {
        let turns = [
            "Too late.",                // interrupt-fan15 q08 "Who made you?" (tune 7: resumed, never answered)
            "Stop.", "Wait.", "No.", "Nope.", "Hold on.", "Hang on.", "Be quiet.", "Shut up.", "Not now.", "Never mind.",
            "Goodbye.", "Bye.", "Good night.", "Move on.", "Why?", "What?", "Really? Why?", "Who made", "Are you",
            "What's that", "Dee.", "D.", "I.", "Hey, Dee.", "Hello.", "I'm bored.", "Love you.", "I'm going.",
            "I'm still", "Tell me.", "Tell me a story.", "5.", "Call 911.", "That's wrong.", "Listen.", "Look.",
            "Are you awake?", "Who made you?", "Stop talking for a second.", "Is it going", "Time is going on.",
        ]
        for t in turns {
            #expect(!Backchannel.isMisheardFragment(t), "\(t)")
            #expect(!Backchannel.isBackchannel(t, inHold: true), "\(t)")
        }
    }
}

// MARK: - T7-3: an echo-prone hold arms no grace

@Suite(.serialized) struct EchoProneHoldTests {
    /// Her reply playing with no echo cancellation; an onset `at` s into it pauses her
    /// (live: the voice's own evidence on her echo); its words are `words`; the brain
    /// says "go on" (`continueAfterBackchannel`, live `resumed-brain`).
    private func pausedAndResumed(_ rig: LoopRig, at: Double, words: [String], text: String) async throws {
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 8000)])
        try rig.quiet(at)
        try rig.talk(0.15)
        rig.push(Srv.speechStarted("item_u2", ms: rig.uplinkMsNow - 150))
        await rig.settle()
        var talked = 0.15
        while rig.voice.floorHold == nil, talked < 0.6 {
            try rig.talk(0.02)
            await rig.settle()
            talked += 0.02
        }
        try #require(rig.voice.floorHold?.itemID == "item_u2", "she was not paused")
        try rig.quiet(0.1)
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 100), Srv.committed("item_u2"))
        rig.deltas("item_u2", words)
        rig.push(Srv.userTranscript("item_u2", text))
        await rig.settle()
        if rig.voice.floorHold != nil { rig.voice.continueAfterBackchannel() }
        let resumed = try await rig.stepUntil(1.0) { rig.voice.floorHold == nil }
        try #require(resumed != nil, "never went on")
    }

    /// The next onset over her, 0.13 s after she went on (live: 24.04 → 24.168); true
    /// when it paused her on its sound within 0.4 s.
    private func nextOnsetPausesHer(_ rig: LoopRig) async throws -> Bool {
        try rig.quiet(0.12)
        try rig.talk(0.15)
        rig.push(Srv.speechStarted("item_u3", ms: rig.uplinkMsNow - 150))
        await rig.settle()
        for _ in 0..<20 {
            try rig.talk(0.02)
            await rig.settle()
            if rig.voice.floorHold?.itemID == "item_u3" { return true }
        }
        return false
    }

    /// t2-interrupt-echo20 (live 22.64–26.00, AEC off, echo −20 dB): her reply's first
    /// audio 22.64; her echo opened item …NdisD3 at 22.90 (0.26 s in; "Yeah."), which
    /// paused her; the brain resumed (`backchannel("resumed-brain")` 24.04); "Are you
    /// awake?" began at 24.168 and the voice noted "after resume: words decide": she was
    /// paused only by its words at 26.00 (1.56 s). Now the echo-prone "Yeah." arms no grace
    /// and the question's onset pauses her at once.
    @Test func aPhantomYeahEarlyInHerReplyArmsNoGrace() async throws {
        let rig = try LoopRig()
        _ = rig.graph.setManualFacts(aecActive: false, outputLatency: 0)
        let holds = Collector(rig.voice.holdEvents)
        try await pausedAndResumed(rig, at: 0.3, words: ["Yeah", "."], text: "Yeah.")
        // Still a backchannel for the brain (never answered as a turn).
        #expect(rig.voice.wasBackchannel(itemID: "item_u2"))
        #expect(holds.all.contains { if case .resumed(["item_u2"], _, _) = $0 { true } else { false } }, "\(holds.all)")
        let paused = try await nextOnsetPausesHer(rig)
        #expect(paused, "the onset after the phantom resume waited for its words")
        #expect(holds.all.last == .paused(itemID: "item_u3"), "\(holds.all)")
        rig.voice.shutdown()
    }

    /// A real "Keep going." (two words) early in her reply still arms the grace: "I'm
    /// listening." right after never pauses her again (tune 6).
    @Test func twoWordsEarlyStillArmTheGrace() async throws {
        let rig = try LoopRig()
        _ = rig.graph.setManualFacts(aecActive: false, outputLatency: 0)
        try await pausedAndResumed(rig, at: 0.3, words: ["Keep", " going", "."], text: "Keep going.")
        let paused = try await nextOnsetPausesHer(rig)
        #expect(!paused, "the rest of the backchannel paused her again")
        rig.voice.shutdown()
    }

    /// A one-word "Mm-hm." later in her reply (live: real ones began ≥ 1.5 s in) is theirs:
    /// the grace holds.
    @Test func oneWordLaterInHerReplyArmsTheGrace() async throws {
        let rig = try LoopRig()
        _ = rig.graph.setManualFacts(aecActive: false, outputLatency: 0)
        try await pausedAndResumed(rig, at: CloudVoice.echoOnsetWindow + 0.4, words: ["Mm", "-hm", "."], text: "Mm-hm.")
        let paused = try await nextOnsetPausesHer(rig)
        #expect(!paused)
        rig.voice.shutdown()
    }

    /// With echo cancellation on, a "Yeah." early in her reply is theirs: the grace holds.
    @Test func withEchoCancellationAnEarlyYeahArmsTheGrace() async throws {
        let rig = try LoopRig()
        _ = rig.graph.setManualFacts(aecActive: true, outputLatency: 0)
        try await pausedAndResumed(rig, at: 0.3, words: ["Yeah", "."], text: "Yeah.")
        let paused = try await nextOnsetPausesHer(rig)
        #expect(!paused)
        rig.voice.shutdown()
    }
}
