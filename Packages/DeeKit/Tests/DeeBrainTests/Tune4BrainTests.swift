import DeeCore
import DeeRealtime
import DeeSelf
import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Tune 4 (brain): speculative reply with gated playback, the sentence cap, the token
/// caps at `minimal`, and the greeting kept until a reply was heard. Each test replays
/// the live tune-3 trace it is named after (Traces/20261009-224148), on the real voice
/// and session (BrainRig), in 20 ms microphone steps.
@MainActor
@Suite(.serialized) struct Tune4BrainTests {
    /// Largest output sample since `from` (her audio is a 0.3 tone; silence is 0).
    static func peak(_ rig: BrainRig, from: Int) -> Float {
        rig.output.count > from ? rig.output[from...].map(abs).max() ?? 0 : 0
    }

    /// The first output sample index at or after `from` that carries her audio.
    static func firstAudio(_ rig: BrainRig, from: Int) -> Int? {
        guard rig.output.count > from else { return nil }
        return rig.output[from...].firstIndex { abs($0) > 0.05 }
    }

    static func stepUntil(_ rig: BrainRig, _ seconds: Double, _ condition: () -> Bool) async throws {
        for _ in 0..<Int(seconds / 0.02) where !condition() {
            try rig.step()
            await rig.settle()
        }
    }

    /// The user's turn: onset, `talk` seconds of voice, the end, and the server's
    /// stop + commit `lag` later (live: 0.19 s after the end as the brain saw it).
    static func turn(_ rig: BrainRig, _ item: String, talk: Double, lag: Double = 0.2) async throws {
        rig.push(Srv.speechStarted(item, ms: 100))
        try rig.talk(talk)
        try rig.quiet(lag)
        rig.push(Srv.speechStopped(item, ms: 100 + Int(talk * 1000)), Srv.committed(item))
        #expect(await rig.until { rig.brain.trace.contains(.speculated) || rig.brain.trace.contains(.committed(plan: "waitForWords")) })
    }

    static func audio(_ rig: BrainRig, _ resp: String, _ item: String, ms: Int, text: String) {
        rig.push(Srv.responseCreated(resp), Srv.messageAdded(resp, item), Srv.itemAdded(item, role: "assistant"))
        var left = ms
        while left > 0 {
            let k = min(100, left)
            rig.push(Srv.audio(resp, item, Sig.pcm(ms: Double(k))))
            left -= k
        }
        rig.push(Srv.transcript(resp, item, text), Srv.audioDone(resp, item), Srv.transcriptDone(resp, item, text),
                 Srv.responseDone(resp))
    }

    static func released(_ rig: BrainRig) -> (heldMs: Int, quietMs: Int, overdue: Bool, ready: Bool)? {
        for t in rig.brain.trace.reversed() {
            if case .speculationReleased(let h, let q, let o, let r) = t { return (h, q, o, r) }
        }
        return nil
    }

    // MARK: Collisions (tune3-live §F1)

    /// t2-backchannel-fan15 l05, verbatim timing: "I couldn't sleep last night." ended
    /// 32.50, commit 32.69, her reply ready 33.06–33.22, the user went on at 33.09
    /// ("I kept going over a conversation with my brother…"), the server's
    /// speech_started reached the brain at 33.48. Live she talked over them for 705 ms.
    /// Now her held reply is dropped unheard and the next commit answers the whole turn.
    @Test func liveL05ResumeIsNeverTalkedOver() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        try rig.quiet(0.6)
        try await Self.turn(rig, "item_u1", talk: 1.7, lag: 0.19)
        let start = rig.output.count
        #expect(rig.responseCreates().count == 1, "requested at the commit (speed)")
        try rig.quiet(0.2)                                            // 32.89
        Self.audio(rig, "resp_1", "item_a1", ms: 900, text: "Hmm, that sounds rough. Did something keep you up?")
        try rig.quiet(0.2)                                            // 33.09: they go on
        try rig.talk(0.4)                                             // 33.49
        rig.push(Srv.speechStarted("item_u2", ms: 2500))
        #expect(await rig.until { rig.brain.trace.contains(.speculationDropped("speech")) }, "\(rig.brain.trace)")
        try rig.talk(1.5)
        #expect(Self.peak(rig, from: start) < 0.05, "not a sample of her reply was heard")
        #expect(rig.trail().contains("response.cancel") || rig.trail().contains("truncate:item_a1"), "\(rig.trail())")
        // The rest of the turn: one answer for both parts.
        try rig.quiet(0.2)
        rig.push(Srv.speechStopped("item_u2", ms: 4500), Srv.committed("item_u2"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail())")
        await rig.settle()
        #expect(rig.responseCreates().count == 2, "the first part is not answered on its own")
        #expect(!rig.brain.trace.contains { if case .speculationReleased = $0 { true } else { false } })
        rig.shutdown()
    }

    /// t2-joke-echo30 j01: "Why did the scarecrow win an award?" committed 16.29, her
    /// audio arrived 16.86 while the teller had already gone on ("Because he was
    /// outstanding in his field!", onset ≈ 16.8, speech_started 17.01). Live she said
    /// the punchline over them. The local voice holds her until the server's start drops it.
    @Test func liveJ01PunchlineIsNotStolen() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        try rig.quiet(0.6)
        try await Self.turn(rig, "item_j1", talk: 1.4, lag: 0.18)
        let start = rig.output.count
        try rig.quiet(0.5)                                            // ≈ 0.68 s after the end
        try rig.talk(0.06)                                            // the punchline starts…
        Self.audio(rig, "resp_1", "item_a1", ms: 800, text: "Because he was outstanding in his field!")
        try rig.talk(0.2)                                             // …her audio is ready now
        await rig.settle()
        #expect(Self.peak(rig, from: start) < 0.05, "held while they talk")
        rig.push(Srv.speechStarted("item_j2", ms: 2300))
        #expect(await rig.until { rig.brain.trace.contains(.speculationDropped("speech")) })
        try rig.talk(1.0)
        #expect(Self.peak(rig, from: start) < 0.05)
        rig.shutdown()
    }

    // MARK: Ordinary turns stay fast

    /// The common case (latency-clean): her audio is ready before the window ends; it
    /// plays once `confirmWindow` of quiet has passed since their last voiced frame —
    /// not later — and nothing is cancelled.
    @Test func aFinishedTurnPlaysAtTheEndOfTheWindow() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        try rig.quiet(0.6)
        try await Self.turn(rig, "item_u1", talk: 1.0, lag: 0.2)
        let end = rig.output.count - Int(0.2 * BrainRig.rate)
        Self.audio(rig, "resp_1", "item_a1", ms: 1500, text: "Blue, like a little sky.")
        try await Self.stepUntil(rig, 1.5) { Self.released(rig) != nil }
        try rig.quiet(0.3)
        let first = try #require(Self.firstAudio(rig, from: end), "she answered")
        let after = Double(first - end) / BrainRig.rate
        #expect(after >= TurnPolicy.confirmWindow - 0.06 && after <= TurnPolicy.confirmWindow + 0.2, "first audio \(after) s after the end")
        let r = try #require(Self.released(rig))
        #expect(r.ready && !r.overdue && r.heldMs > 0, "\(r)")
        #expect(rig.count("response.cancel") == 0)
        rig.shutdown()
    }

    /// Audio that comes after the window is confirmed already: it plays as it arrives.
    /// Tune 6: the gate is let go when her first audio is in (never before: a resume
    /// between an early release and her audio was unguarded), at once — the quiet run
    /// has held since long before.
    @Test func lateAudioIsNotHeld() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        try rig.quiet(0.6)
        try await Self.turn(rig, "item_u1", talk: 1.0, lag: 0.2)
        try await Self.stepUntil(rig, 1.2) { false }
        #expect(Self.released(rig) == nil, "nothing to let go of before her audio")
        let at = rig.output.count
        Self.audio(rig, "resp_1", "item_a1", ms: 600, text: "Sure.")
        await rig.settle()
        try rig.quiet(0.15)
        let r = try #require(Self.released(rig))
        #expect(r.ready && !r.overdue && r.heldMs <= 60, "released as it arrived: \(r)")
        #expect(Self.firstAudio(rig, from: at) != nil, "plays at once")
        rig.shutdown()
    }

    /// Settled words that say the turn is not over ("…call my mom and", t2-fillers-clean
    /// t04) take the held reply back: never heard, nothing cut.
    @Test func unfinishedWordsDropTheHeldReply() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        try rig.quiet(0.6)
        try await Self.turn(rig, "item_u1", talk: 1.2, lag: 0.2)
        let start = rig.output.count
        Self.audio(rig, "resp_1", "item_a1", ms: 900, text: "Oh, say hi to her!")
        rig.brain.inject(.session(.userTranscriptDelta(itemID: "item_u1", delta: "Tomorrow I'm going to call my mom and")))
        try await Self.stepUntil(rig, 1.0) { rig.brain.trace.contains(.speculationDropped("taken back")) }
        #expect(rig.brain.trace.contains(.speculationDropped("taken back")), "\(rig.brain.trace)")
        #expect(rig.brain.trace.contains(.held("trailing")))
        try rig.quiet(0.4)
        #expect(Self.peak(rig, from: start) < 0.05)
        rig.shutdown()
    }

    /// A TV or a clattering kitchen (t2-drops-tv15): local sound the server never calls
    /// speech holds her at most `confirmMax` (+ `voiceHoldExtra` while EarCore calls it
    /// a voice, tune 5) after the commit.
    @Test func localSoundAloneHoldsHerAtMostConfirmMax() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        try rig.quiet(0.6)
        try await Self.turn(rig, "item_u1", talk: 1.0, lag: 0.2)
        Self.audio(rig, "resp_1", "item_a1", ms: 900, text: "Sure thing.")
        try rig.quiet(0.2)
        var waited = 0.2
        for _ in 0..<12 where Self.released(rig) == nil {
            try rig.talk(0.2, amplitude: 0.1)                         // the room keeps talking
            waited += 0.2
            await rig.settle()
        }
        let r = try #require(Self.released(rig), "\(rig.brain.trace)")
        #expect(waited <= TurnPolicy.confirmMax + TurnPolicy.voiceHoldExtra + 0.25, "\(waited) s, \(r)")
        rig.shutdown()
    }

    @Test func speculationCanBeTurnedOff() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false })
        try await rig.start()
        try rig.quiet(0.6)
        rig.push(Srv.speechStarted("item_u1", ms: 100))
        try rig.talk(1.0)
        rig.push(Srv.speechStopped("item_u1", ms: 1100), Srv.committed("item_u1"))
        #expect(await rig.until { rig.responseCreates().count == 1 })
        #expect(!rig.brain.trace.contains(.speculated))
        #expect(rig.voice.speculative == nil)
        rig.shutdown()
    }

    // MARK: Length (tune3-live §F4)

    /// kitchen15 l02, verbatim: "That sounds like a classic "meeting energy drain"
    /// situation. Friday at 4:30? Oof. And a filing system nobody was going to use?…"
    /// She stops before the fourth sentence (never mid-word).
    @Test func liveKitchenL02StopsBeforeTheFourthSentence() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false })
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"))
        #expect(await rig.until { rig.brain.trace.contains(.responseStarted(kind: "reply")) })
        let said = ["That sounds like a classic meeting energy drain situation.", "Friday at 4:30?", "Oof.",
                    "And a filing system nobody was going to use?"]
        for (i, s) in said.enumerated() {
            rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: i, text: s))
            await rig.settle()
            #expect(rig.brain.trace.contains(.sentenceCapStop) == (i == 3), "sentence \(i + 1)")
        }
        rig.shutdown()

        // A story was asked for: no cap.
        let story = try await BrainRig(tune: { $0.speculative = false })
        try await story.start()
        story.utterance("item_u1")
        story.push(Srv.userTranscript("item_u1", "Can you tell me a story about a dragon?"))
        #expect(await story.until { story.responseCreates().count == 1 })
        story.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"))
        #expect(await story.until { story.brain.trace.contains(.responseStarted(kind: "reply")) })
        for i in 0..<5 {
            story.brain.inject(.sentenceStarted(itemID: "item_a1", index: i, text: "Once upon a time."))
        }
        await story.settle()
        #expect(!story.brain.trace.contains(.sentenceCapStop))
        story.shutdown()
    }

    @Test func minimalCapsAreTighter() {
        #expect(TurnPolicy.maxOutputTokens(length: "at most two short sentences", effort: .minimal) == 340)
        #expect(TurnPolicy.maxOutputTokens(length: "one short sentence", effort: .minimal) == 240)
        #expect(TurnPolicy.maxOutputTokens(length: "at most three short sentences", effort: .minimal) == 440)
        #expect(TurnPolicy.maxOutputTokens(length: "at most two short sentences", effort: .low) == 380)
    }

    // MARK: The greeting survives an unheard reply (tune3-live §F5, reunion-morning)

    /// Live: "Good morning." / "Did you sleep well?" split; reply 1 was cancelled before
    /// a word was heard, and reply 2's DNA had lost the greeting. The brain counts only
    /// replies of hers that were heard (`TurnContext.heardReplies`).
    @Test func liveReunionMorningOnlyAHeardReplyCounts() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false })
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        #expect(rig.host.dnaRequests.last?.turn.heardReplies == 0)
        // Reply 1: started, cut before its first sentence was heard.
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"))
        #expect(await rig.until { rig.brain.trace.contains(.responseStarted(kind: "reply")) })
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 0, text: "Good morning, it's been two days!"))
        rig.brain.inject(.sentenceFinished(itemID: "item_a1", index: 0, text: "Good morning, it's been two days!", heard: false))
        rig.brain.inject(.itemPlayed(itemID: "item_a1", playedMs: 80, cut: true))
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        await rig.settle()
        rig.push(Srv.speechStarted("item_u2", ms: 2000), Srv.speechStopped("item_u2", ms: 2600), Srv.committed("item_u2"))
        #expect(await rig.until { rig.responseCreates().count == 2 })
        #expect(rig.host.dnaRequests.last?.turn.heardReplies == 0, "nothing of reply 1 was heard")
        // Reply 2 is heard.
        rig.push(Srv.responseCreated("resp_2"), Srv.messageAdded("resp_2", "item_a2"))
        #expect(await rig.until { rig.brain.trace.filter { $0 == .responseStarted(kind: "reply") }.count == 2 })
        rig.brain.inject(.sentenceStarted(itemID: "item_a2", index: 0, text: "Morning! Two days, hi!"))
        rig.brain.inject(.sentenceFinished(itemID: "item_a2", index: 0, text: "Morning! Two days, hi!", heard: true))
        rig.brain.inject(.itemPlayed(itemID: "item_a2", playedMs: 1500, cut: false))
        rig.push(Srv.responseDone("resp_2"))
        await rig.settle()
        rig.push(Srv.speechStarted("item_u3", ms: 5000), Srv.speechStopped("item_u3", ms: 5600), Srv.committed("item_u3"))
        #expect(await rig.until { rig.responseCreates().count == 3 })
        #expect(rig.host.dnaRequests.last?.turn.heardReplies == 1)
        rig.push(Srv.responseCreated("resp_3"), Srv.responseDone("resp_3"))
        await rig.settle()
        // A new conversation starts over.
        await rig.brain.newConversation(persona: Persona(), now: Date())
        rig.push(Srv.speechStarted("item_u4", ms: 8000), Srv.speechStopped("item_u4", ms: 8600), Srv.committed("item_u4"))
        #expect(await rig.until { rig.responseCreates().count == 4 })
        #expect(rig.host.dnaRequests.last?.turn.heardReplies == 0)
        rig.shutdown()
    }
}

@MainActor
@Suite(.serialized) struct Tune4TurnEndTests {
    /// Tune 4 live (kitchen15): the brain's own energy VAD took the kitchen bed for a
    /// voice and held 7 replies to `confirmMax` (filler latency p50 2.13 s). The gate now
    /// asks the voice's ear (`userIsSpeaking`), which hears no one in a room bed:
    /// released at the window, not overdue. (Offline, EarCore over the harness's
    /// kitchen / fan / TV beds at 15 dB SNR: no false "speaking" frame; that check
    /// needs the harness fixtures, so it stays out of the package.)
    @Test func aNoisyRoomDoesNotHoldHer() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        let n = Int(BrainRig.rate * 0.02)
        var seed: UInt64 = 7
        func room(_ seconds: Double) throws {
            for _ in 0..<Int(seconds / 0.02) {
                seed += 1
                try rig.step(Sig.noise(amplitude: 0.01, count: n, seed: seed))
            }
        }
        try room(3)
        rig.push(Srv.speechStarted("item_u1", ms: 3000))
        let voice = Sig.harmonic(hz: 180, amplitude: 0.3, rate: BrainRig.rate, seconds: 1.2)
        for i in stride(from: 0, to: voice.count - n + 1, by: n) {
            seed += 1
            let bed = Sig.noise(amplitude: 0.01, count: n, seed: seed)
            try rig.step(zip(voice[i..<(i + n)], bed).map { $0 + $1 })
        }
        try room(0.2)
        rig.push(Srv.speechStopped("item_u1", ms: 4200), Srv.committed("item_u1"))
        #expect(await rig.until { rig.brain.trace.contains(.speculated) })
        Tune4BrainTests.audio(rig, "resp_1", "item_a1", ms: 900, text: "Smells good in here.")
        for _ in 0..<100 where Tune4BrainTests.released(rig) == nil {
            try room(0.02)
            await rig.settle()
        }
        let r = try #require(Tune4BrainTests.released(rig), "\(rig.brain.trace)")
        #expect(!r.overdue && r.quietMs < Int(TurnPolicy.confirmWindow * 1000) + 300, "\(r)")
        rig.shutdown()
    }

    /// t2-joke-echo30 j01 (tune 3 and tune 4 live): server_vad committed "Want to hear a
    /// joke?" on its own, so "Why did the scarecrow win an award?" was not seen as a
    /// set-up, and she said the punchline over the teller (resumed 1.04 s after the end).
    @Test func liveJ01AnnouncedJokeOneTurnBefore() {
        #expect(TurnPolicy.held("Why did the scarecrow win an award?", after: "Want to hear a joke?") == .riddle)
        #expect(TurnPolicy.held("Why did the scarecrow win an award?") == nil)
        #expect(TurnPolicy.held("Why do you like jokes?", after: "I love jokes.") == nil)
        #expect(TurnPolicy.held("What's the weather like?", after: "Okay.") == nil)
    }

    @Test func liveJ01HeldReplyIsTakenBackForThePunchline() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_j0")
        rig.push(Srv.userTranscript("item_j0", "Want to hear a joke?"))
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_0"), Srv.responseDone("resp_0"))
        try rig.quiet(1.0)
        try await Tune4BrainTests.turn(rig, "item_j1", talk: 1.4, lag: 0.48)
        let start = rig.output.count
        rig.brain.inject(.session(.userTranscriptDelta(itemID: "item_j1", delta: "Why did the scarecrow win an award?")))
        try await Tune4BrainTests.stepUntil(rig, 1.0) { rig.brain.trace.contains(.held("riddle")) }
        #expect(rig.brain.trace.contains(.held("riddle")), "\(rig.brain.trace)")
        #expect(rig.brain.trace.contains(.speculationDropped("taken back")))
        Tune4BrainTests.audio(rig, "resp_1", "item_a1", ms: 800, text: "Because he was outstanding in his field!")
        try rig.quiet(0.4)
        #expect(Tune4BrainTests.peak(rig, from: start) < 0.05, "the punchline is theirs")
        rig.shutdown()
    }
}
