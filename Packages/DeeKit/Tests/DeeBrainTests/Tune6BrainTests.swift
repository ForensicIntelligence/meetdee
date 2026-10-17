import DeeCore
import DeeRealtime
import DeeSelf
import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Tune 6 (brain): the tune-5 live findings (scratchpad/tune5-live.md; report
/// Tools/voice-harness/Reports/20261010-020243, traces Traces/20261010-020243), each
/// replayed on the real voice and session (BrainRig) at the live shapes.
@MainActor
@Suite(.serialized) struct Tune6BrainTests {
    typealias T2 = Tune2BrainTests
    typealias T3 = Tune3BrainTests
    typealias T4 = Tune4BrainTests
    typealias T5 = Tune5BrainTests

    static func requestFailures(_ rig: BrainRig) -> Int {
        rig.brain.trace.filter { if case .requestFailed = $0 { true } else { false } }.count
    }

    /// A question over Dee's voice that Dee's ear knows is theirs (their voice on the
    /// microphone, so its words reach the brain as they come), held by the voice's floor.
    static func overHerByVoice(_ rig: BrainRig, _ item: String) async throws {
        rig.push(Srv.speechStarted(item, ms: 3000))
        try rig.talk(0.5)
        await rig.settle()
        rig.brain.injectHold(.paused(itemID: item))
        rig.push(Srv.speechStopped(item, ms: 3600), Srv.committed(item))
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "waitForPartial")) }, "\(rig.brain.trace)")
    }

    static func releases(_ rig: BrainRig) -> Int {
        rig.brain.trace.filter { if case .speculationReleased = $0 { true } else { false } }.count
    }

    // MARK: T5-1 — the re-check costs nothing when Dee's audio comes later

    /// t2-latency-clean q01: first audio 4.92, final words 5.00, released 5.14
    /// (`speculationReleased(heldMs: 220)`): the 0.12 s re-check window started only when
    /// audio and words were both in. Their side was quiet from the window on; the
    /// re-check now counts from there, so Dee plays as soon as the words settle.
    @Test func liveQ01ReleasesWhenTheWordsSettleNotARecheckLater() async throws {
        // Deltas 0.1 s of microphone apart must read as still settling however slow the host.
        let rig = try await BrainRig(tune: { $0.partialSettle = 0.6 })
        try await rig.start()
        try rig.quiet(0.6)
        try await T4.turn(rig, "item_u1", talk: 1.0, lag: 0.2)
        let words = ["What", " did", " you", " do", " to", "day", " this", " morning", " and", " after"]
        var elapsed = 0.2                                                // since their end of speech
        var i = 0
        var audioIn = false
        // Deltas keep coming (words settling) until 0.95 s; Dee's audio is in at 0.85 s.
        while elapsed < 0.95 {
            if i < words.count { T2.delta(rig, "item_u1", words[i]); i += 1 }
            for _ in 0..<5 { try rig.step() }
            await rig.settle()
            elapsed += 0.1
            if elapsed >= 0.85, !audioIn {
                T4.audio(rig, "resp_1", "item_a1", ms: 1200, text: "Oh, I watched the rain all day.")
                audioIn = true
                await rig.settle()
            }
        }
        #expect(T4.released(rig) == nil, "held while the words settle: \(rig.brain.trace)")
        rig.push(Srv.userTranscript("item_u1", "What did you do today?"))
        // Frames of microphone from when the brain had the words to the release.
        var steps = 0, sinceWords = 0
        while T4.released(rig) == nil, steps < 40 {
            try rig.step()
            await rig.settle()
            steps += 1
            if rig.brain.trace.contains(.heard(verdict: "answer")) { sinceWords += 1 }
        }
        let r = try #require(T4.released(rig), "\(rig.brain.trace)")
        #expect(Double(sinceWords) * 0.02 < TurnPolicy.releaseRecheck - 0.04, "released \(sinceWords) frames after the words: \(r)")
        #expect(r.ready && !r.overdue)
        rig.shutdown()
    }

    // MARK: T5-2 — an interrupting question always gets exactly one answer

    /// t2-interrupt-clean q02 (40.37–42.3 s): "Are you awake?" over Dee. The voice's hold
    /// committed the burst early (40.44); the server ended "the rest" as a new item with
    /// no speech start (stop + commit 40.60) and its transcript came back empty. The brain
    /// answered the question (41.06) and then the empty tail blind (41.24): refused
    /// `responseInFlight`, retried after the answer, both cancelled at their first audio.
    /// The tail is no turn now: one request, no refusal, no retry.
    @Test func liveQ02TheEmptyTailIsNeverAnswered() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await T3.sheIsTalking(rig, "Sun is a big deal, tomatoes love lots of it.")
        rig.push(Srv.responseDone("resp_1"))
        rig.push(Srv.speechStarted("item_q", ms: 3000))
        await rig.settle()
        rig.brain.injectHold(.paused(itemID: "item_q"))
        rig.push(Srv.committed("item_q"))                                   // the voice's early commit
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "waitForPartial")) })
        rig.push(Srv.speechStopped("item_tail", ms: 3700), Srv.committed("item_tail"))   // no speech_started
        #expect(await rig.until { rig.brain.trace.contains(.tailIgnored) }, "\(rig.brain.trace)")
        T2.deltas(rig, "item_q", "Are you awake?")
        rig.push(Srv.userTranscript("item_q", "Are you awake?"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "the question is answered: \(rig.trail())")
        rig.brain.injectHold(.ended(itemIDs: ["item_q", "item_tail"], byVoice: false))
        rig.push(Srv.userTranscript("item_tail", ""))                      // dropped by the voice live; harmless here
        // Past the overlap wait and the hold limit's tick: the tail is never asked for.
        try? await Task.sleep(for: .milliseconds(900))
        #expect(rig.responseCreates().count == 2, "no second request: \(rig.trail())")
        #expect(Self.requestFailures(rig) == 0, "\(rig.brain.trace)")
        // The answer arrives: nothing of the brain's cancels it, and nothing retries.
        let cancels = rig.count("response.cancel")
        rig.push(Srv.responseCreated("resp_2"), Srv.messageAdded("resp_2", "item_a2"), Srv.itemAdded("item_a2", role: "assistant"))
        for _ in 0..<6 { rig.push(Srv.audio("resp_2", "item_a2", Sig.pcm(ms: 100))) }
        rig.push(Srv.transcript("resp_2", "item_a2", "Nope, I'm right here."), Srv.audioDone("resp_2", "item_a2"),
                 Srv.transcriptDone("resp_2", "item_a2", "Nope, I'm right here."), Srv.responseDone("resp_2"))
        try await T5.live(rig, 1.0)
        #expect(rig.responseCreates().count == 2, "exactly one answer: \(rig.trail())")
        #expect(!rig.brain.trace.contains(.covered) || rig.responseCreates().count == 2)
        // The session's own stale `openSpeech` (DeeRealtime, tune6-voice.md) preempted this
        // answer live; with its fix in, no cancel at all.
        #expect(rig.count("response.cancel") == cancels, "\(rig.trail())")
        rig.shutdown()
    }

    /// The other half: a request refused because the answer is in flight never touches Dee's
    /// voice. Live the brain still believed Dee's cut reply was `playing` (its `itemPlayed`
    /// not in yet) and "cut" it again before the refused request: a stop of nothing that
    /// closes the reply gate and cancels the answer at its first audio.
    @Test func aRefusedRequestNeverCancelsTheAnswerInFlight() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await T3.sheIsTalking(rig)
        rig.push(Srv.responseDone("resp_1"))
        await T3.over(rig, "item_q")
        rig.brain.injectHold(.paused(itemID: "item_q"))
        T2.deltas(rig, "item_q", "Are you awake?")
        rig.push(Srv.userTranscript("item_q", "Are you awake?"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail())")
        rig.push(Srv.responseCreated("resp_2"))                            // the answer: in flight, no audio yet
        await rig.settle()
        // Dee's cut reply's events still racing in: the brain sees it "playing" again.
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 1, text: "And then it rained."))
        await rig.settle()
        let cancels = rig.count("response.cancel")
        // A second turn while the answer is in flight (injected: the voice's own floor
        // handling of a new onset is not under test): refused.
        rig.brain.inject(.session(.userCommitted(itemID: "item_u3", previousItemID: nil)))
        rig.brain.inject(.session(.userTranscript(itemID: "item_u3", text: "Also, I love your eyes.")))
        #expect(await rig.until { Self.requestFailures(rig) >= 1 }, "\(rig.brain.trace)")
        try? await Task.sleep(for: .milliseconds(400))
        #expect(rig.count("response.cancel") == cancels, "the answer in flight is never cancelled: \(rig.trail())")
        rig.shutdown()
    }

    /// A request the session refuses although the brain saw nothing in flight (the
    /// session's own re-request, a tool follow-up): its speculation is disarmed without a
    /// cancel — a discard would cancel the response that is in flight.
    @Test func aRefusedSpeculationNeverCancelsTheResponseInFlight() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        _ = try await rig.session.requestResponse(dna: "DEE DNA v7 · reply")   // not the brain's
        let cancels = rig.count("response.cancel")
        rig.brain.inject(.session(.userCommitted(itemID: "item_u1", previousItemID: nil)))
        #expect(await rig.until { Self.requestFailures(rig) >= 1 }, "\(rig.brain.trace)")
        #expect(rig.brain.trace.contains(.speculated), "armed before the refusal: \(rig.brain.trace)")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(rig.count("response.cancel") == cancels, "\(rig.trail())")
        // Not cancelled either before its `response.created` (the session would have said
        // `.replyPreempted`, re-rendered as a `retry` DNA).
        #expect(!rig.brain.trace.contains { if case .dnaReplaced = $0 { true } else { false } }, "\(rig.brain.trace)")
        #expect(await rig.session.state == .awaitingResponse)
        rig.shutdown()
    }

    /// One answer per turn: a refused turn that the reply in flight was asked for after
    /// (it hears it) is not asked again when that reply is done.
    @Test func aTurnTheLiveAnswerHeardIsNotAskedAgain() async throws {
        let rig = try await BrainRig(exactWords: true)
        try await rig.start()
        rig.brain.inject(.session(.userCommitted(itemID: "item_u1", previousItemID: nil)))
        rig.brain.inject(.session(.userCommitted(itemID: "item_u2", previousItemID: nil)))
        // u1's words come first (its reply is asked for after u2's commit), then u2's.
        rig.brain.inject(.session(.userTranscript(itemID: "item_u1", text: "Hi Dee, I'm back.")))
        rig.brain.inject(.session(.userTranscript(itemID: "item_u2", text: "What's your favorite color?")))
        #expect(await rig.until { rig.host.heardLog.count == 2 })
        await rig.settle()
        try? await Task.sleep(for: .milliseconds(300))
        let first = rig.responseCreates().count
        #expect(first == 1, "\(rig.trail()) \(rig.brain.trace)")
        #expect(rig.brain.trace.contains(.covered), "\(rig.brain.trace)")
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        for _ in 0..<4 { rig.push(Srv.audio("resp_1", "item_a1", Sig.pcm(ms: 100))) }
        rig.push(Srv.audioDone("resp_1", "item_a1"), Srv.responseDone("resp_1"))
        try await T5.live(rig, 0.6)
        #expect(rig.responseCreates().count == 1, "never a second answer: \(rig.trail())")
        rig.shutdown()
    }

    // MARK: T5-3 — the answer to a question over Dee goes out without the 0.3 s guard

    /// Live p50: hold end (Dee's reply flushed) +0.92 s, answer requested +1.20 s — the
    /// `stopGuard` after the cut. A cut of Dee's playing reply only has to reach the session
    /// before the request; the speculative gate covers the rest.
    @Test func theAnswerOverHerGoesOutAsSoonAsTheCutIsIn() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await T3.sheIsTalking(rig)
        rig.push(Srv.responseDone("resp_1"))
        await T3.over(rig, "item_q")
        rig.brain.injectHold(.paused(itemID: "item_q"))
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "waitForPartial")) })
        T2.deltas(rig, "item_q", "What's your favorite color?")
        var cutAt: ContinuousClock.Instant?
        var askedAt: ContinuousClock.Instant?
        let deadline = ContinuousClock.now + .seconds(3)
        while askedAt == nil, ContinuousClock.now < deadline {
            if cutAt == nil, rig.trail().contains("truncate:item_a1") { cutAt = .now }
            if rig.responseCreates().count == 2 { askedAt = .now }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let cut = try #require(cutAt, "Dee's reply is cut: \(rig.trail())")
        let asked = try #require(askedAt, "the answer is asked for: \(rig.trail())")
        #expect(asked - cut < .milliseconds(200), "requested \(asked - cut) after the cut (was 0.3 s)")
        // …and the cut reached the session first: the new answer is not cancelled by it.
        rig.push(Srv.responseCreated("resp_2"), Srv.messageAdded("resp_2", "item_a2"), Srv.itemAdded("item_a2", role: "assistant"))
        await rig.settle()
        let order = rig.trail()
        let trunc = try #require(order.firstIndex(of: "truncate:item_a1"))
        let create = try #require(order.lastIndex(of: "response.create"))
        #expect(trunc < create, "\(order)")
        #expect(rig.count("response.cancel") <= 1, "only Dee's old reply's: \(order)")
        rig.shutdown()
    }

    /// The rest of the 1.75–1.87 s: the answer waited for the words to settle (0.43 s after
    /// the commit). Words that can no longer be "keep going" decide at their first delta;
    /// words that may still be one ("I'm…", "She's not…") wait as before.
    @Test func wordsThatCannotBeABackchannelDecideAtOnce() async throws {
        let rig = try await BrainRig(tune: { $0.partialSettle = 0.6 })   // a settle the early words never wait for
        try await rig.start()
        await T3.sheIsTalking(rig)
        rig.push(Srv.responseDone("resp_1"))
        try await Self.overHerByVoice(rig, "item_q")
        let t0 = ContinuousClock.now
        T2.delta(rig, "item_q", "What's your")
        #expect(await rig.until(0.4) { rig.brain.trace.contains(.earlyWords) }, "\(rig.brain.trace)")
        #expect(ContinuousClock.now - t0 < .milliseconds(400))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail())")
        rig.shutdown()

        for maybe in ["I'm", "Keep", "She's not", "I'm still"] {
            let r = try await BrainRig(tune: { $0.partialSettle = 0.6 })
            try await r.start()
            await T3.sheIsTalking(r)
            r.push(Srv.responseDone("resp_1"))
            try await Self.overHerByVoice(r, "item_q")
            T2.delta(r, "item_q", maybe)
            try? await Task.sleep(for: .milliseconds(300))
            #expect(!r.brain.trace.contains(.earlyWords), "\(maybe): may still be a backchannel")
            #expect(r.responseCreates().count == 1, "\(maybe): \(r.trail())")
            r.shutdown()
        }
    }

    // MARK: T5-4 — "D." is not a turn; nothing is answered over them

    @Test func aFragmentOrABareCallIsNotATurn() {
        for t in ["D.", "D", "Dee.", "Hey, Dee.", "So, Dee,", "I.", "A."] {
            #expect(TurnPolicy.unfinished(t) == .trailing, "\(t)")
        }
        for t in ["Dee?", "D?", "No.", "OK.", "Hi.", "Oh.", "Dee!", "5.", "Me.", "Dee, what's up?", "Hi Dee, how are you."] {
            #expect(TurnPolicy.unfinished(t) == nil, "\(t)")
        }
    }

    /// t2-backchannel-echo20 l03: "Dee, guess what, at school today…" — the server split
    /// "D." off (committed 104.24), their speech went on (`speech_started` 104.44), the
    /// brain answered "D." in exact mode at 104.80 with no gate: Dee played over them at
    /// 105.50. Now "D." waits for the rest, and nothing is asked for while they talk.
    @Test func liveEcho20L03DIsNotAnsweredOverThem() async throws {
        let rig = try await BrainRig(exactWords: true)
        try await rig.start()
        try rig.quiet(0.4)
        rig.utterance("item_d", startMs: 100, endMs: 400)
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "waitForWords")) })
        rig.push(Srv.speechStarted("item_g", ms: 600))                    // they go on
        await rig.settle()
        rig.push(Srv.userTranscript("item_d", "D."))
        #expect(await rig.until { rig.host.heardLog.count == 1 })
        try await T5.live(rig, 0.6, talking: true)
        #expect(rig.responseCreates().isEmpty, "nothing asked for over them: \(rig.trail()) \(rig.brain.trace)")
        rig.push(Srv.speechStopped("item_g", ms: 1800), Srv.committed("item_g"))
        rig.push(Srv.userTranscript("item_g", "Guess what? At school today we made volcanoes."))
        #expect(await rig.until { rig.responseCreates().count == 1 }, "\(rig.trail())")
        try await T5.live(rig, 0.8)
        #expect(rig.responseCreates().count == 1, "one reply for all of it: \(rig.trail())")
        rig.shutdown()
    }

    /// Every reply goes through the release gate, an exact one asked for late too: while
    /// a newer item is being said Dee is never released.
    @Test func aLateExactReplyIsGatedToo() async throws {
        let rig = try await BrainRig(exactWords: true, tune: { $0.exactWait = 2 })
        try await rig.start()
        try rig.quiet(0.4)
        try await T4.turn(rig, "item_u1", talk: 0.8, lag: 0.2)
        try await T5.live(rig, 1.2)                                       // the words come late
        rig.push(Srv.userTranscript("item_u1", "I made pancakes this morning."))
        #expect(await rig.until { rig.responseCreates().count == 1 }, "\(rig.trail())")
        #expect(rig.brain.trace.contains(.speculated), "gated, not skipped as late: \(rig.brain.trace)")
        rig.push(Srv.speechStarted("item_u2", ms: 3000))                  // they go on before Dee's audio
        await rig.settle()
        T4.audio(rig, "resp_1", "item_a1", ms: 800, text: "Ooh, pancakes!")
        let at = rig.output.count
        try await T5.live(rig, 0.6, talking: true)
        #expect(T4.peak(rig, from: at) < 0.05, "never over them: \(rig.brain.trace)")
        #expect(Self.releases(rig) == 0)
        rig.shutdown()
    }

    /// The take-back of the unfinished-words aim, by meaning (the l03 reply).
    @Test func theAimIsCaughtByMeaningNotWording() {
        for aim in ["Hmm, did you want to say something, or just check if I was waiting?",
                    "Were you about to say something?", "You just said my name!", "Were you checking if I'm still here?",
                    "What were you going to say?", "Did you say something?"] {
            #expect(TurnPolicy.isUnfinishedAim(aim), "\(aim)")
        }
        for ok in ["What did you want to say to your brother?", "Tell me the rest of the story!", "Aw, are you checking on me?",
                   "Wow, you stopped smoking? That's huge!", "What were you going to say to her?", "I love my name!",
                   "Did you finish your homework?"] {
            #expect(!TurnPolicy.isUnfinishedAim(ok), "\(ok)")
        }
    }

    // MARK: T5-6 — "I had pasta for dinner." | "And."

    /// t2-drops-tv15 t01: "I had pasta for dinner, and…" committed as "I had pasta for
    /// dinner." (113.94) and "And." (115.06). Its held reply was dropped when "And." started
    /// (114.20), but the full words of the first part (114.38) asked again at once while
    /// "And." was still being said, and that reply was released at 115.48. Now the first
    /// part waits for the second; "And." keeps it all held.
    @Test func livePastaAndIsHeldUntilTheyGoOn() async throws {
        #expect(TurnPolicy.unfinished("I had pasta for dinner. And.") == .trailing)
        #expect(TurnPolicy.unfinished("And.") == .trailing)
        let rig = try await BrainRig(tune: { $0.trailingWait = 0.8 })
        try await rig.start()
        try rig.quiet(0.4)
        try await T4.turn(rig, "item_p", talk: 1.2, lag: 0.2)
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"))
        rig.push(Srv.speechStarted("item_and", ms: 2000))                 // "And." begins
        #expect(await rig.until { rig.brain.trace.contains(.speculationDropped("speech")) })
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        rig.push(Srv.userTranscript("item_p", "I had pasta for dinner."))
        #expect(await rig.until { rig.host.heardLog.count == 1 })
        try await T5.live(rig, 0.4, talking: true)
        #expect(rig.responseCreates().count == 1, "not asked again while they talk: \(rig.trail())")
        #expect(rig.brain.trace.contains(.held("speech")), "\(rig.brain.trace)")
        rig.push(Srv.speechStopped("item_and", ms: 2600), Srv.committed("item_and"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail()) \(rig.brain.trace)")
        rig.push(Srv.userTranscript("item_and", "And."))
        #expect(await rig.until { rig.brain.trace.contains(.held("trailing")) }, "\(rig.brain.trace)")
        let at = rig.output.count
        T4.audio(rig, "resp_2", "item_a2", ms: 800, text: "Nice! Pasta is sneaky good.")
        try await T5.live(rig, 0.5)
        #expect(T4.peak(rig, from: at) < 0.05, "the trailing turn's reply is never heard: \(rig.brain.trace)")
        rig.shutdown()
    }

    // MARK: T5-8 — no apps, clocks or forecasts

    @Test func appReferralsAreRecognised() {
        for s in ["Bring a jacket, and you can check a weather app or a forecast.", "Or open the weather app.",
                  "You can check your phone's clock.", "Maybe you can check a local forecast.", "Want me to set a reminder?",
                  "You could just google it."] {
            #expect(TurnPolicy.isAppReferral(s), "\(s)")
        }
        for s in ["I can't see the forecast from here.", "No clock in this phone of mine.", "I love rainy days.",
                  "It feels like a sunny day to me!", "You look happy today."] {
            #expect(!TurnPolicy.isAppReferral(s), "\(s)")
        }
    }

    /// latency-clean q07 ("Will it rain tomorrow?"): Dee's first sentence sends them to an
    /// app → taken back unheard and asked once more with `noAppNote`.
    @Test func anAppInHerFirstSentenceIsNeverHeard() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        T2.assistantDelta(rig, "resp_1", "item_a1", "You can check a weather app for that. ")
        #expect(await rig.until { rig.brain.trace.contains(.appReferral(takenBack: true)) }, "\(rig.brain.trace)")
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail())")
        let dnaID = try #require(rig.trail().last { $0.hasPrefix("dna:") }).dropFirst(4)
        #expect(rig.dnaText(String(dnaID))?.contains("no apps, clock, forecast or calendar") == true)
        #expect(rig.host.said.isEmpty)
        rig.shutdown()
    }

    /// A later sentence: Dee stops before it (what Dee said stands).
    @Test func anAppInALaterSentenceStopsHerBeforeIt() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await T3.sheIsTalking(rig, "Ooh, rain sounds cozy.")
        T2.assistantDelta(rig, "resp_1", "item_a1", "Ooh, rain sounds cozy. Or open the weather app to be sure.")
        #expect(await rig.until { rig.brain.trace.contains(.appReferral(takenBack: false)) }, "\(rig.brain.trace)")
        let truncs = rig.trail().filter { $0.hasPrefix("truncate:") }.count
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 1, text: "Or open the weather app to be sure."))
        #expect(await rig.until { rig.trail().filter { $0.hasPrefix("truncate:") }.count > truncs || rig.count("response.cancel") > 0 },
                "\(rig.trail())")
        rig.shutdown()
    }
}
