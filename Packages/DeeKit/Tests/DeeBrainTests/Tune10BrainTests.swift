import DeeCore
import DeeRealtime
import DeeSelf
@testable import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Tune 10 (brain): the tune-9 live findings (scratchpad/tune9-live.md; reports
/// Tools/voice-harness/Reports/20261010-102105, -111224 solo; traces Traces/<same>), each
/// replayed at the live shape on the real voice and session (BrainRig).
@MainActor
@Suite(.serialized) struct Tune10BrainTests {
    typealias T2 = Tune2BrainTests
    typealias T3 = Tune3BrainTests
    typealias T7 = Tune7BrainTests
    typealias T9 = Tune9BrainTests

    /// The microphone audio the server has received, as 24 kHz samples.
    static func uplink(_ rig: BrainRig) -> [Int16] {
        rig.socket.sent.filter { $0.hasPrefix(#"{"type":"input_audio_buffer.append""#) }.flatMap { text -> [Int16] in
            let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
            guard let d = (o?["audio"] as? String).flatMap({ Data(base64Encoded: $0) }) else { return [] }
            return d.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        }
    }

    /// Ms of microphone audio the server has received (its `audio_start_ms` clock), once
    /// everything the microphone took has gone out (the voice streams it asynchronously).
    static func settledUplinkMs(_ rig: BrainRig) async -> Int {
        var last = -1
        for _ in 0..<200 {
            await rig.settle()
            let now = uplink(rig).count / 24
            if now == last { return now }
            last = now
        }
        return last
    }

    /// Their voice, 20 ms at a time, letting the voice's uplink pump keep up after each
    /// frame (it streams from a pre-roll taken when it runs: a pump starved under a loaded
    /// test run would miss the start of their voice).
    static func talk(_ rig: BrainRig, _ seconds: Double) async throws {
        let x = Sig.harmonic(hz: 180, amplitude: 0.3, rate: BrainRig.rate, seconds: seconds)
        let size = Int(BrainRig.rate * 0.02)
        for i in stride(from: 0, to: x.count - size + 1, by: size) {
            try rig.step(Array(x[i..<(i + size)]))
            await rig.settle()
        }
    }

    /// 20 ms of a kitchen-like bed at the microphone: sound, never a voice.
    static func bed(_ rig: BrainRig, _ seconds: Double, seed: UInt64) throws {
        let n = Int(BrainRig.rate * 0.02)
        for i in 0..<Int((seconds / 0.02).rounded()) {
            try rig.step(Sig.noise(amplitude: 0.08, count: n, seed: seed &+ UInt64(i)))
        }
    }

    /// Her reply `item_a1` playing (non-speculative, so it plays at once), and the voice
    /// paused for `item` said over it: a real floor hold.
    static func pausedBy(_ rig: BrainRig, _ item: String, talk: Double = 0.45) async throws {
        try rig.quiet(0.3)
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        for _ in 0..<80 { rig.push(Srv.audio("resp_1", "item_a1", Sig.pcm(ms: 100))) }
        rig.push(Srv.transcript("resp_1", "item_a1", "So the filing system is a mystery puzzle. It goes on and on."),
                 Srv.audioDone("resp_1", "item_a1"), Srv.responseDone("resp_1"))
        try rig.quiet(0.6)
        await rig.settle()
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 0, text: "So the filing system is a mystery puzzle."))
        try await Self.talk(rig, 0.15)
        rig.push(Srv.speechStarted(item, ms: max(0, await settledUplinkMs(rig) - 150)))
        await rig.settle()
        try await Self.talk(rig, talk - 0.15)
        try #require(rig.voice.floorHold?.items.contains(item) == true, "she was not paused")
    }

    // MARK: T9-1 — every "go on" decision continues her

    /// t2-backchannel-kitchen15 c02 (18.9–23.3, reproduced solo): "Don't stop, keep going."
    /// over her. "Don't stop." → `continued` (20.46; the voice deferred the go-on while they
    /// talked on). The server's tail of the burst "Keep going." (21.75) took the tune-9 tail
    /// path (`backchannel("tail")`): dropped, and returned without continuing her. The kitchen
    /// bed kept the voice's own quiet check false, so it waited out its deadline: "hold ended
    /// by the voice" 22.51, her reply cut at 1645 ms, a carry-on in its place. A tail dropped
    /// as "go on" continues her.
    @Test func liveKitchen15C02ATailDroppedAsGoOnContinuesHer() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false })
        try await rig.start()
        try await Self.pausedBy(rig, "item_d")
        // Our quick commit of "Don't stop." while "keep going" is still being said.
        rig.push(Srv.committed("item_d"))
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "waitForPartial")) }, "\(rig.brain.trace)")
        try await Self.talk(rig, 0.1)
        T2.deltas(rig, "item_d", "Don't stop.")
        try await Self.talk(rig, 0.32)
        #expect(rig.brain.trace.contains(.backchannel("continued")), "\(rig.brain.trace)")
        #expect(rig.voice.floorHold != nil, "the go-on waits while they talk")
        rig.push(Srv.userTranscript("item_d", "Don't stop."))
        await rig.settle()
        // They stop; the kitchen goes on. The server ends the burst's tail under a new id.
        try Self.bed(rig, 0.2, seed: 7)
        rig.push(Srv.speechStopped("item_t", ms: await Self.settledUplinkMs(rig)), Srv.committed("item_t"))
        #expect(await rig.until { rig.brain.trace.contains(.tailIgnored) }, "\(rig.brain.trace)")
        T2.deltas(rig, "item_t", "Keep going.")
        rig.push(Srv.userTranscript("item_t", "Keep going."))
        #expect(await rig.until { rig.brain.trace.contains(.backchannel("tail")) }, "\(rig.brain.trace)")
        for _ in 0..<15 { try Self.bed(rig, 0.2, seed: 100); await rig.settle() }
        #expect(rig.voice.floorHold == nil, "she went on")
        #expect(rig.brain.trace.contains(.backchannel("resumed-brain")), "\(rig.brain.trace)")
        #expect(!rig.trail().contains("truncate:item_a1"), "her reply is not cut: \(rig.trail())")
        #expect(rig.responseCreates().count == 1, "no carry-on in place of her reply: \(rig.trail()) \(rig.brain.trace)")
        rig.shutdown()
    }

    /// The same shape without the server's split (audit of every "go on" path): the
    /// provisional "Don't stop" → `continued` (deferred while they talk), the full words
    /// "Don't stop, keep going." say "go on" again — the go-on is renewed once they stop,
    /// never left to the voice's deadline in a kitchen bed.
    @Test func kitchen15C02TheFullGoOnWordsContinueHer() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false })
        try await rig.start()
        try await Self.pausedBy(rig, "item_d")
        rig.push(Srv.committed("item_d"))
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "waitForPartial")) }, "\(rig.brain.trace)")
        try await Self.talk(rig, 0.1)
        T2.deltas(rig, "item_d", "Don't stop,")
        try await Self.talk(rig, 0.32)
        #expect(rig.brain.trace.contains(.backchannel("continued")), "\(rig.brain.trace)")
        try Self.bed(rig, 0.2, seed: 7)
        rig.push(Srv.userTranscript("item_d", "Don't stop, keep going."))
        for _ in 0..<15 { try Self.bed(rig, 0.2, seed: 100); await rig.settle() }
        #expect(rig.voice.floorHold == nil, "she went on")
        #expect(!rig.trail().contains("truncate:item_a1"), "her reply is not cut: \(rig.trail())")
        #expect(rig.responseCreates().count == 1, "\(rig.trail()) \(rig.brain.trace)")
        rig.shutdown()
    }

    /// t2-backchannel-echo10 c05 (54.4–58.7, reproduced solo): "Keep going, I'm listening."
    /// over her came back as "Be sneaking, going." (its partial set the hold's verdict to
    /// "answer": `wordsAt` 56.49) and "I'm listening." (a new item, still being said). The
    /// brain said "go on" at 56.52 (`continued`, deferred while they talked); the voice's
    /// `holdAfterWords` still fired at 57.49 — "hold ended by the voice", her reply cut at
    /// 2345 ms, a carry-on in its place. Once the brain said "go on", it never cuts her (the
    /// voice half: tune-10 voice, `continueAfterBackchannel` clears `wordsAt`).
    @Test func liveEcho10C05TheBrainsGoOnOverridesHoldAfterWords() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false })
        try await rig.start()
        try await Self.pausedBy(rig, "item_c", talk: 1.3)
        let end = await Self.settledUplinkMs(rig)
        rig.push(Srv.speechStopped("item_c", ms: end), Srv.committed("item_c"))
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "waitForPartial")) }, "\(rig.brain.trace)")
        T2.deltas(rig, "item_c", "Be sneaking, going.")
        rig.push(Srv.speechStarted("item_l", ms: end + 20))
        try await Self.talk(rig, 0.32)
        #expect(rig.brain.trace.contains(.backchannel("continued")), "\(rig.brain.trace)")
        rig.push(Srv.userTranscript("item_c", "Be sneaking, going."))
        // "I'm listening." is still being said, past `holdAfterWords`.
        try await Self.talk(rig, 1.2)
        #expect(rig.voice.floorHold != nil, "never cut over them")
        #expect(!rig.trail().contains("truncate:item_a1"), "\(rig.trail())")
        try rig.quiet(0.1)
        rig.push(Srv.speechStopped("item_l", ms: await Self.settledUplinkMs(rig)), Srv.committed("item_l"))
        T2.deltas(rig, "item_l", "I'm listening.")
        rig.push(Srv.userTranscript("item_l", "I'm listening."))
        for _ in 0..<10 { try rig.quiet(0.1); await rig.settle() }
        #expect(rig.voice.floorHold == nil, "she went on")
        #expect(!rig.trail().contains("truncate:item_a1"), "her reply is not cut: \(rig.trail())")
        #expect(rig.responseCreates().count == 1, "no carry-on in her place: \(rig.trail()) \(rig.brain.trace)")
        rig.shutdown()
    }

    // MARK: T9-1 (5) — early words use the voice's sound-aware fragment rule

    /// The early-words guard used the words-only fragment rule, where a word the words don't
    /// know is never a fragment: "Um, uh, bread." over her — a short, flat, backchannel-like
    /// sound — decided the turn at its first words and cut her. The voice's rule
    /// (`isMisheardFragment(itemID:text:)`, as in `goOnWords`) hears it as "go on": its
    /// settled words decide, and she goes on.
    @Test func earlyWordsNeverDecideOnAFragmentThatSoundedLikeABackchannel() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false })
        try await rig.start()
        try await Self.pausedBy(rig, "item_b", talk: 0.3)
        // Our quick commit of the short burst (the server's stop comes later).
        rig.push(Srv.committed("item_b"))
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "waitForPartial")) }, "\(rig.brain.trace)")
        let sound = try #require(rig.voice.itemSound(itemID: "item_b"))
        try #require(sound.backchannelLike, "\(sound)")
        T2.delta(rig, "item_b", "Um, uh, bread")
        for _ in 0..<10 { try rig.quiet(0.04); await rig.settle() }
        #expect(!rig.brain.trace.contains(.earlyWords), "\(rig.brain.trace)")
        #expect(rig.responseCreates().count == 1, "never answered: \(rig.trail()) \(rig.brain.trace)")
        #expect(!rig.trail().contains("truncate:item_a1"), "\(rig.trail())")
        rig.shutdown()
    }

    // MARK: T9-2 — a turn survives a rollover

    /// Solo t2-fallback-rollover-speech q08 (45.1–47.7): "Who made you?" → "I heard you ask,"
    /// taken back (47.18). The rollover switched as that response ended (seed 47.379); the
    /// retry went out on the new session (47.477, behind a fresh DNA), and the brain's
    /// handling of `.rolledOver` then discarded it: cancelled 1 ms after `response.created`,
    /// never asked again, the turn lost. A reply asked for on the new session is kept.
    @Test func liveRolloverQ08TheRetryOnTheNewSessionIsKept() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_q")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        T2.assistantDelta(rig, "resp_1", "item_a1", "I heard you ask, ")
        #expect(await rig.until { rig.brain.trace.contains(.heardYou(takenBack: true)) }, "\(rig.brain.trace)")
        rig.push(Srv.userTranscript("item_q", "Who made you?"))
        #expect(await rig.until { rig.host.heardLog.contains { $0.text == "Who made you?" } })
        let cancels = rig.count("response.cancel")
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "the retry: \(rig.trail()) \(rig.brain.trace)")
        // The rollover's switch, reported to the brain after the retry went out.
        rig.brain.inject(.session(.rolledOver(sessionID: "sess_new")))
        await rig.settle()
        rig.push(Srv.responseCreated("resp_2"), Srv.messageAdded("resp_2", "item_a2"), Srv.itemAdded("item_a2", role: "assistant"))
        for _ in 0..<3 { rig.push(Srv.audio("resp_2", "item_a2", Sig.pcm(ms: 100))) }
        #expect(await rig.until { rig.brain.trace.filter { $0 == .responseStarted(kind: "reply") }.count == 2 },
                "the retry answers: \(rig.trail()) \(rig.brain.trace)")
        try? await Task.sleep(for: .milliseconds(150))
        #expect(rig.count("response.cancel") == cancels, "never cancelled: \(rig.trail())")
        rig.shutdown()
    }

    // MARK: T9-6 / T9-8 — thinking aloud and "I heard …"

    @Test func thinkingAloudAnywhereInASentenceAndHeardOpeners() {
        // l06: "let me think" at words 7–9 of her first sentence.
        let l06 = "Oh wow, that's a cozy memory\u{2014}let me think about how that recipe feels now."
        #expect(TurnPolicy.metaSentence(in: l06) == 0)
        #expect(TurnPolicy.metaSentence(in: "That's lovely. It reminds me of soup, and let me think about it more.") == 1)
        // A real answer is untouched.
        #expect(TurnPolicy.metaSentence(in: "Mars, the big red planet. It's kinda like a dusty ball.") == nil)
        #expect(TurnPolicy.metaSentence(in: "Let me tell you about my day. It was bright.") == nil)
        // s02: "I heard <anything>" opening her reply.
        #expect(TurnPolicy.heardYouSentence(in: "I heard that tough moment, Alex. I'm sorry.", theirs: "I didn't get the job.") == 0)
        #expect(TurnPolicy.heardYouSentence(in: "Oh, I hear that little hum.", theirs: "Mm.") == 0)
        // Not when they asked whether she can hear them; not a fact later in a reply.
        #expect(TurnPolicy.heardYouSentence(in: "I hear you just fine.", theirs: "Can you hear me okay?") == nil)
        #expect(TurnPolicy.heardYouSentence(in: "Fun fact time. I heard octopuses have three hearts.", theirs: "Tell me a fact.") == nil)
    }

    /// t2-length-clean s02 "I didn't get the job I interviewed for." → "I heard that tough
    /// moment, Alex. I'm sorry it didn't work out…" played (the rule knew "I heard you…" only).
    /// Unheard, it is taken back and asked again once.
    @Test func liveLengthCleanS02IHeardThatIsAskedAgain() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.userTranscript("item_u1", "I didn't get the job I interviewed for."))
        #expect(await rig.until { rig.host.heardLog.count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        T2.assistantDelta(rig, "resp_1", "item_a1", "I heard that tough moment, Alex. ")
        #expect(await rig.until { rig.brain.trace.contains(.heardYou(takenBack: true)) }, "\(rig.brain.trace)")
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail())")
        #expect(T9.lastDNA(rig)?.contains("never tell them you were listening") == true)
        rig.shutdown()
    }

    /// Tune 5's unfinished-words aim streamed as live (a few words per delta) still takes the
    /// aim's path (the turn waited out in silence), never the widened "I heard…" retry.
    @Test func theUnfinishedAimStreamedIsStillTheAim() async throws {
        #expect(TurnPolicy.heardYouSentence(in: "I heard \u{201C}I couldn\u{2019}t", theirs: "I couldn't sleep last") == nil)
        let rig = try await BrainRig(tune: { $0.trailingWait = 0.4 })
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        for d in ["I", " heard", " \u{201C}I", " couldn\u{2019}t", " sleep", " last\u{2026}\u{201D}", " and", " I\u{2019}m", " curious",
                  " what", " happened", " next."] {
            T2.assistantDelta(rig, "resp_1", "item_a1", d)
        }
        #expect(await rig.until { rig.brain.trace.contains(.unfinishedAim(takenBack: true)) }, "\(rig.brain.trace)")
        #expect(!rig.brain.trace.contains { if case .heardYou = $0 { true } else { false } }, "\(rig.brain.trace)")
        rig.shutdown()
    }

    /// t2-backchannel-kitchen15 l06 (a statement about her grandmother's recipe), 71.36: "Oh
    /// wow, that's a cozy memory—let me think about how that recipe feels now." played (the
    /// first-sentence check looked at 7 words; later-sentence take-backs were for questions
    /// only). Thinking aloud anywhere in her first sentence is a preamble: taken back, asked
    /// again once.
    @Test func liveKitchen15L06ThinkingAloudInHerFirstSentenceIsAskedAgain() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.userTranscript("item_u1", "My grandmother used to make this soup every winter, and I finally found her recipe card."))
        #expect(await rig.until { rig.host.heardLog.count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        T2.assistantDelta(rig, "resp_1", "item_a1", "Oh wow, that's a cozy memory\u{2014}let me think about")
        #expect(await rig.until { rig.brain.trace.contains(.preamble(cut: true)) }, "\(rig.brain.trace)")
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail())")
        // Tune 11 review: its trace mark may land a beat after the create under load.
        #expect(await rig.until { T9.dnaKinds(rig).last == "retry" }, "\(rig.brain.trace)")
        rig.shutdown()
    }
}
