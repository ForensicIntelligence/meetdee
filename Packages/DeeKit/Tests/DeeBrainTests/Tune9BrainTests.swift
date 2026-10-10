import DeeCore
import DeeRealtime
import DeeSelf
import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Tune 9 (brain): the tune-8 live findings (scratchpad/tune8-live.md; report
/// Tools/voice-harness/Reports/20261010-080526, traces Traces/20261010-080526), each
/// replayed on the real voice and session (BrainRig) at the live shapes.
@MainActor
@Suite(.serialized) struct Tune9BrainTests {
    typealias T2 = Tune2BrainTests
    typealias T3 = Tune3BrainTests
    typealias T4 = Tune4BrainTests
    typealias T7 = Tune7BrainTests

    static func dnaKinds(_ rig: BrainRig) -> [String] {
        rig.brain.trace.compactMap { if case .dnaSent(_, let kind, _, _, _, _, _, _, _) = $0 { kind } else { nil } }
    }

    static func lastDNA(_ rig: BrainRig) -> String? {
        guard let id = rig.trail().last(where: { $0.hasPrefix("dna:") })?.dropFirst(4) else { return nil }
        return rig.dnaText(String(id))
    }

    // MARK: T8-1 — a question over her, taken for "go on" at first, gets exactly one answer

    /// t2-interrupt-echo20 q08 (50.04–51.76): "Who made you?" over her (AEC off, 20 % echo)
    /// came back as "Movie." — quick commit 51.09, the server's empty tail committed 51.28
    /// (`tailIgnored`), partial "Movie." 51.29, `backchannel("continued")` 51.50, final
    /// "Movie." 51.54 (`heard(answer)`) and no `response.create`: she talked on. One word
    /// the words don't know (and no sound saying "mm-hm") is a turn now: answered, once.
    @Test func liveEcho20Q08MovieOverHerIsAnswered() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await T7.overHer(rig, "item_q")
        rig.push(Srv.speechStopped("item_tail", ms: 4100), Srv.committed("item_tail"))   // the tail, no start
        #expect(await rig.until { rig.brain.trace.contains(.tailIgnored) }, "\(rig.brain.trace)")
        T2.delta(rig, "item_q", "Movie")
        T2.delta(rig, "item_q", ".")
        #expect(await rig.until { rig.responseCreates().count == 2 }, "answered: \(rig.trail()) \(rig.brain.trace)")
        rig.push(Srv.userTranscript("item_q", "Movie."))
        #expect(await rig.until { rig.host.heardLog.contains { $0.text == "Movie." } })
        rig.push(Srv.userTranscript("item_tail", ""))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(rig.responseCreates().count == 2, "exactly one answer: \(rig.trail())")
        #expect(T7.backchannels(rig).isEmpty, "never a backchannel: \(rig.brain.trace)")
        rig.shutdown()
    }

    /// The brain half (T7-1's second ask): words first taken for "go on" while she talked on
    /// (`continued`) whose full words ask. The answer is asked for and its own cut of her
    /// voice is no "cut anyway after keep going": before, that asked for a carry-on for the
    /// same item, refused while the answer ran and sent after it — a second reply to one turn.
    @Test func aContinuedBackchannelWhoseFullWordsAskGetsOneAnswer() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await T7.overHer(rig, "item_y")
        T2.deltas(rig, "item_y", "Yeah.")
        #expect(await rig.until { rig.brain.trace.contains(.backchannel("continued")) }, "\(rig.brain.trace)")
        rig.push(Srv.userTranscript("item_y", "Yeah, who made you?"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "the question is answered: \(rig.trail()) \(rig.brain.trace)")
        // The answer's cut of her reply (the voice reports it), then the answer runs.
        rig.brain.inject(.itemPlayed(itemID: "item_a1", playedMs: 1800, cut: true))
        await rig.settle()
        rig.push(Srv.responseCreated("resp_2"), Srv.messageAdded("resp_2", "item_a2"))
        for _ in 0..<3 { rig.push(Srv.audio("resp_2", "item_a2", Sig.pcm(ms: 100))) }
        rig.push(Srv.audioDone("resp_2", "item_a2"), Srv.responseDone("resp_2"))
        try? await Task.sleep(for: .milliseconds(400))
        #expect(rig.responseCreates().count == 2, "one answer, no carry-on after it: \(rig.trail()) \(rig.brain.trace)")
        #expect(!rig.brain.trace.contains(.backchannel("resumed")), "\(rig.brain.trace)")
        #expect(!Self.dnaKinds(rig).contains("retry"), "\(rig.brain.trace)")
        rig.shutdown()
    }

    // MARK: T8-2 — a server stall never throws a late answer away

    /// t2-fillers-echo10 f01 (17.1–23.3): `response.create` 19.409, the session gave up at
    /// 21.92 ("no response in time", 2.5 s), `response.created` came at 22.968 (3.56 s) and
    /// was cancelled at once: the turn was lost. It is accepted now and plays.
    @Test func liveFillersEcho10F01ALateAnswerPlays() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.userTranscript("item_u1", "So I went to the store, and they were out of milk."))
        #expect(await rig.until { rig.host.heardLog.count == 1 })
        await rig.settle()
        rig.clock.advance(by: 3.56)                                     // the stall
        await rig.settle()
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        for _ in 0..<3 { rig.push(Srv.audio("resp_1", "item_a1", Sig.pcm(ms: 100))) }
        #expect(await rig.until { rig.brain.trace.contains(.responseStarted(kind: "reply")) }, "\(rig.brain.trace)")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.count("response.cancel") == 0, "the late answer is kept: \(rig.trail())")
        #expect(!rig.brain.trace.contains { if case .speculationDropped = $0 { true } else { false } }, "\(rig.brain.trace)")
        rig.shutdown()
    }

    /// t2-interrupt-clean q01 (22.97–32.56): the answer to "What's your favorite color?"
    /// started 9.59 s after it was asked for. Past `stallRetryAfter` with nothing started,
    /// the stalled request is cancelled and the turn asked for once more — exactly once.
    @Test func liveInterruptCleanQ01AStallIsAskedForOnceMore() async throws {
        // stallRetryAfter well past slowAfter: under parallel load one late housekeeping
        // tick can pass both at once (0.15/0.4 flaked: straight to the stall, no slow note).
        let rig = try await BrainRig(tune: { $0.slowAfter = 0.15; $0.stallRetryAfter = 1.0 })
        try await rig.start()
        rig.utterance("item_q")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.userTranscript("item_q", "What's your favorite color?"))
        #expect(await rig.until { rig.brain.trace.contains(.slowResponse(clip: false)) }, "\(rig.brain.trace)")
        #expect(await rig.until { rig.brain.trace.contains(.stalled(retried: true)) }, "\(rig.brain.trace)")
        // The stalled one finally starts: cancelled (never heard), then the turn is asked again.
        rig.push(Srv.responseCreated("resp_1"))
        #expect(await rig.until { rig.count("response.cancel") >= 1 }, "\(rig.trail())")
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "asked again: \(rig.trail()) \(rig.brain.trace)")
        #expect(await rig.until { Self.dnaKinds(rig).last == "retry" }, "\(rig.brain.trace)")
        // The second stalls too: let go, never a third request.
        #expect(await rig.until { rig.brain.trace.contains(.stalled(retried: false)) }, "\(rig.brain.trace)")
        rig.push(Srv.responseCreated("resp_2"))
        rig.push(Srv.responseDone("resp_2", status: "cancelled"))
        try? await Task.sleep(for: .milliseconds(500))
        #expect(rig.responseCreates().count == 2, "once: \(rig.trail())")
        rig.shutdown()
    }

    /// The same stall while they went on to a new turn: the stalled request is cancelled
    /// (the session preempts an unspoken reply when they speak), never retried by the
    /// brain, and the new turn gets its one answer after it.
    @Test func aStallWhileTheyGoOnAnswersTheNewTurnOnce() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false; $0.slowAfter = 0.15; $0.stallRetryAfter = 0.6 })
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        try? await Task.sleep(for: .milliseconds(250))
        rig.utterance("item_u2", startMs: 3000, endMs: 3900)             // a new turn while the first stalls
        #expect(await rig.until { rig.brain.trace.contains { if case .dnaSent(2, _, _, _, _, _, _, _, true) = $0 { true } else { false } } },
                "queued behind the stalled one: \(rig.brain.trace)")
        rig.push(Srv.responseCreated("resp_1"))
        #expect(await rig.until { rig.count("response.cancel") >= 1 }, "\(rig.trail())")
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "the new turn is answered: \(rig.trail())")
        rig.push(Srv.responseCreated("resp_2"), Srv.messageAdded("resp_2", "item_a2"))
        for _ in 0..<3 { rig.push(Srv.audio("resp_2", "item_a2", Sig.pcm(ms: 100))) }
        rig.push(Srv.audioDone("resp_2", "item_a2"), Srv.responseDone("resp_2"))
        try? await Task.sleep(for: .milliseconds(800))
        #expect(rig.responseCreates().count == 2, "no stall retry for the old turn: \(rig.trail()) \(rig.brain.trace)")
        #expect(!rig.brain.trace.contains(.stalled(retried: true)), "\(rig.brain.trace)")
        rig.shutdown()
    }

    // MARK: T8-3 — the tail of a backchannel never stops her; one carry-on per hold

    /// t2-backchannel-fan15 bc02 (102.38–104.90): "Mm-hm." came back as "MMHN." (she went
    /// on), the server's tail of the burst committed 103.76 (`tailIgnored`) and its words
    /// "10." (fan noise) at 104.18 were answered: her reply cut at 2665 ms for a new reply.
    /// The rest of a backchannel that is only a number or noise is no turn.
    @Test func liveFan15Bc02NoiseTailAfterABackchannelNeverStopsHer() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await T7.overHer(rig, "item_b")
        T2.deltas(rig, "item_b", "MMHN.")
        #expect(await rig.until { !T7.backchannels(rig).isEmpty }, "\(rig.brain.trace)")
        rig.push(Srv.userTranscript("item_b", "MMHN."))
        #expect(await rig.until { rig.host.heardLog.contains { $0.text == "MMHN." } })
        rig.push(Srv.speechStopped("item_t", ms: 3700), Srv.committed("item_t"))      // its tail
        #expect(await rig.until { rig.brain.trace.contains(.tailIgnored) }, "\(rig.brain.trace)")
        T2.deltas(rig, "item_t", "10.")
        rig.push(Srv.userTranscript("item_t", "10."))
        #expect(await rig.until { rig.brain.trace.contains(.backchannel("tail")) }, "\(rig.brain.trace)")
        try? await Task.sleep(for: .milliseconds(200))
        T7.sheWentOn(rig, "10.")
        #expect(rig.trail().contains("delete:item_t"), "out of the conversation: \(rig.trail())")
        rig.shutdown()
    }

    /// A tail that asks is still a turn ("Mm-hm." | "Why?").
    @Test func aTailThatAsksIsStillATurn() {
        for t in ["10.", "D.", "", "5 6.", "Yeah."] { #expect(TurnPolicy.isNoiseTail(t), "\(t)") }
        for t in ["Why?", "Stop.", "Movie.", "But why though", "Wait."] { #expect(!TurnPolicy.isNoiseTail(t), "\(t)") }
    }

    /// t2-backchannel-echo10 c02 (30.00–34.74): "Don't stop, keep going." (AEC off) came back
    /// as "That's like a, you know, stop." (held while "Keep going." was being said) and
    /// "Keep going." (her reply was cut: a carry-on, which took the held words over). The
    /// held words were then restored, refused while the carry-on ran, and sent after it: the
    /// retry cut the carry-on at 840 ms and a second carry-on played. One carry-on per hold.
    @Test func liveEcho10C02OneCarryOnPerHold() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        await T3.sheIsTalking(rig, "So the filing system is a mystery puzzle.")
        rig.push(Srv.responseDone("resp_1"))
        await T3.over(rig, "item_u")                                         // "That's like a, you know, stop."
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "waitForPartial")) })
        rig.push(Srv.speechStarted("item_j", ms: 4000))                      // "Keep going." starts
        await rig.settle()
        rig.brain.stopVoice()                                                 // her reply was cut
        try rig.quiet(0.1)
        rig.brain.inject(.itemPlayed(itemID: "item_a1", playedMs: 1945, cut: true))
        try? await Task.sleep(for: .milliseconds(350))
        rig.push(Srv.userTranscript("item_u", "That's like a, you know, stop."))
        #expect(await rig.until { rig.brain.trace.contains(.held("speech")) }, "\(rig.brain.trace)")
        rig.push(Srv.speechStopped("item_j", ms: 4900), Srv.committed("item_j"))
        T2.deltas(rig, "item_j", "Keep going.")
        #expect(await rig.until { rig.brain.trace.contains(.backchannel("resumed")) }, "\(rig.brain.trace)")
        #expect(await rig.until { rig.responseCreates().count == 2 }, "the carry-on: \(rig.trail())")
        rig.push(Srv.userTranscript("item_j", "Keep going."))
        #expect(await rig.until { rig.host.heardLog.contains { $0.text == "Keep going." } })
        try? await Task.sleep(for: .milliseconds(150))
        #expect(!rig.brain.trace.contains(.held("restored")), "\(rig.brain.trace)")
        rig.push(Srv.responseCreated("resp_2"), Srv.messageAdded("resp_2", "item_a2"))
        for _ in 0..<3 { rig.push(Srv.audio("resp_2", "item_a2", Sig.pcm(ms: 100))) }
        rig.push(Srv.audioDone("resp_2", "item_a2"), Srv.responseDone("resp_2"))
        try? await Task.sleep(for: .milliseconds(400))
        #expect(rig.responseCreates().count == 2, "one carry-on, no retry after it: \(rig.trail()) \(rig.brain.trace)")
        #expect(!Self.dnaKinds(rig).contains("retry"), "\(rig.brain.trace)")
        rig.shutdown()
    }

    /// The same c02: early words decided on the partial "That's like a," (3 words) and cut
    /// her at 1945 ms. A partial that breaks off on a comma or an article waits to settle.
    @Test func liveEcho10C02EarlyWordsWaitOnAPartialThatBreaksOff() async throws {
        let rig = try await BrainRig(tune: { $0.partialSettle = 0.6 })
        try await rig.start()
        await T7.overHer(rig, "item_u")
        for d in ["That's", " like", " a", ","] { T2.delta(rig, "item_u", d) }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!rig.brain.trace.contains(.earlyWords), "\(rig.brain.trace)")
        #expect(rig.responseCreates().count == 1, "\(rig.trail())")
        rig.shutdown()
    }

    @Test func partialsThatBreakOff() {
        for t in ["That's like a,", "That's like a", "I went to the", "Well, and", "So I was,"] {
            #expect(TurnPolicy.breaksOff(t), "\(t)")
        }
        for t in ["What's your favorite", "Are you awake", "Who made you", "Can you tell me,", "I love the rain"] {
            #expect(!TurnPolicy.breaksOff(t), "\(t)")
        }
    }

    // MARK: T8-4 / T8-5 — no thinking aloud, no "I heard you…", one message per response

    @Test func thinkingAloudAnywhereAndHeardYouOpeners() {
        // Live tune 8 (narration gate + judge leaks).
        #expect(TurnPolicy.metaSentence(in: "Ah, that sounds like a fun bit of stargazing. Let me think this through with you.") == 1)
        #expect(TurnPolicy.metaSentence(in: "Lettuce? Heh, okay, okay, that's good. Let me think about the next one.") != nil)
        #expect(TurnPolicy.metaSentence(in: "Hi Alex, your voice comes through clear and bright. Let me take a moment to settle in.") == 1)
        #expect(TurnPolicy.isMetaPreamble("Hmm, let me see, that's Mars."))
        #expect(TurnPolicy.isMetaPreamble("Give me a second."))
        #expect(TurnPolicy.metaSentence(in: "Mars is red because of rust. Want another one?") == nil)
        #expect(!TurnPolicy.isMetaPreamble("Let me guess, pizza?"))
        // "I heard you…" (5 live openers).
        let theirs = "I keep thinking about getting a dog, but I'm not sure it's fair."
        for s in ["I heard you thinking about a dog.", "I heard you're thinking about a dog and wondering if it's fair.",
                  "I heard you.", "Oh, I hear you, that's a big one.", "I heard your name, so I'm saying hi."] {
            #expect(TurnPolicy.opensOnHearingThem(s, theirs: theirs), "\(s)")
        }
        #expect(TurnPolicy.heardYouSentence(in: "Today was quiet but nice. I heard you better today.", theirs: "How was your day?") == 1)
        #expect(TurnPolicy.heardYouSentence(in: "Hi, Priya! I heard your name, so I'm saying hi.", theirs: "My name is Priya.") == 1)
        // Not: an answer about hearing them, or hearing something else.
        #expect(!TurnPolicy.opensOnHearingThem("Yes, I can hear you clearly.", theirs: "Can you hear me okay?"))
        #expect(!TurnPolicy.opensOnHearingThem("I heard a rumour about octopuses once.", theirs: theirs))
        #expect(!TurnPolicy.opensOnHearingThem("Dogs are lovely, and you'd be a kind owner, I hear you.", theirs: theirs))
    }

    /// t2-fillers-echo30 f03 (~46.5–47.9): "…what's the name of that big red planet?" →
    /// "Ah, that sounds like a fun bit of stargazing. Let me think this through with you."
    /// (then a second message "Oh, that's Mars…"; judge 2, leak). Her answer had not come
    /// before she thought aloud, nothing was heard yet: taken back and asked again once, to
    /// answer first (stopped before it, she would have said only the lead-in).
    @Test func liveFillersEcho30F03ThinkingAloudBeforeTheAnswerIsAskedAgain() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.userTranscript("item_u1", "Hmm, what's the, uh, the name of that big red planet?"))
        #expect(await rig.until { rig.host.heardLog.count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        T2.assistantDelta(rig, "resp_1", "item_a1", "Ah, that sounds like a fun bit of stargazing. ")
        T2.assistantDelta(rig, "resp_1", "item_a1", "Let me think this through with you. ")
        #expect(await rig.until { rig.brain.trace.contains(.thinkingAloud(takenBack: true)) }, "\(rig.brain.trace)")
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail())")
        #expect(Self.lastDNA(rig)?.contains("your very first sentence answers it plainly") == true)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.responseCreates().count == 2)
        rig.shutdown()
    }

    /// joke-echo30 k05 "Lettuce." → "…that's good. Let me think about the next one." (judge 3,
    /// leak): no question to answer, so what she said stands; she stops before it.
    @Test func liveJokeK05ThinkingAloudAfterTheLaughIsNeverHeard() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.userTranscript("item_u1", "Lettuce."))
        #expect(await rig.until { rig.host.heardLog.count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        T2.assistantDelta(rig, "resp_1", "item_a1", "Lettuce? Heh, okay, okay, that's good. Let me think about the next one.")
        #expect(await rig.until { rig.brain.trace.contains(.narrationStop) }, "\(rig.brain.trace)")
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 0, text: "Lettuce?"))
        await rig.settle()
        #expect(rig.count("response.cancel") == 0 && !rig.brain.trace.contains(.preamble(cut: true)))
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 3, text: "Let me think about the next one."))
        #expect(await rig.until { rig.brain.trace.contains(.preamble(cut: true)) }, "stopped before it: \(rig.brain.trace)")
        rig.shutdown()
    }

    /// t2-backchannel-echo10 l01 → "I heard you're thinking about a dog and wondering if it's
    /// fair. This is a thoughtful moment…" (DNA v9's "to show you heard"). Unheard: taken back
    /// and asked again once.
    @Test func liveEcho10L01HeardYouIsAskedAgain() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.userTranscript("item_u1", "I keep thinking about getting a dog, but I'm not sure it's fair."))
        #expect(await rig.until { rig.host.heardLog.count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        T2.assistantDelta(rig, "resp_1", "item_a1", "I heard you're thinking about a dog and wondering if it's fair. ")
        #expect(await rig.until { rig.brain.trace.contains(.heardYou(takenBack: true)) }, "\(rig.brain.trace)")
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "\(rig.trail())")
        #expect(Self.lastDNA(rig)?.contains("never tell them you were listening") == true)
        rig.shutdown()
    }

    /// "Can you hear me okay?" → "Yes, I can hear you clearly." is the answer, not a leak.
    @Test func hearingThemIsAnAnswerWhenTheyAskIt() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.userTranscript("item_u1", "Can you hear me okay?"))
        #expect(await rig.until { rig.host.heardLog.count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        T2.assistantDelta(rig, "resp_1", "item_a1", "Yes, I can hear you clearly. ")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!rig.brain.trace.contains { if case .heardYou = $0 { true } else { false } }, "\(rig.brain.trace)")
        #expect(rig.count("response.cancel") == 0)
        rig.shutdown()
    }

    /// t2-fallback-429 34.47: "I hear you, loud and clear. Now I'm all ears…" + a second
    /// message "Yes, I can hear you well…" in the same response (4 sentences, a double
    /// answer). She says the first; she stops before the second.
    @Test func liveFallback429TwoMessagesSheSaysOne() async throws {
        let rig = try await BrainRig(tune: { $0.speculative = false })
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.userTranscript("item_u1", "Can you hear me okay?"))
        #expect(await rig.until { rig.host.heardLog.count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        for _ in 0..<3 { rig.push(Srv.audio("resp_1", "item_a1", Sig.pcm(ms: 100))) }
        T2.assistantDelta(rig, "resp_1", "item_a1", "I hear you, loud and clear. ")
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 0, text: "I hear you, loud and clear."))
        rig.push(Srv.messageAdded("resp_1", "item_a2"), Srv.itemAdded("item_a2", role: "assistant"))
        T2.assistantDelta(rig, "resp_1", "item_a2", "Yes, I can hear you well. ")
        #expect(await rig.until { rig.brain.trace.contains(.secondMessage) }, "\(rig.brain.trace)")
        rig.brain.inject(.itemPlayed(itemID: "item_a1", playedMs: 1200, cut: false))
        rig.brain.inject(.sentenceStarted(itemID: "item_a2", index: 0, text: "Yes, I can hear you well."))
        #expect(await rig.until { rig.brain.trace.contains(.secondMessageStop) }, "\(rig.brain.trace)")
        rig.shutdown()
    }

    // MARK: Latency — the release is not quantised by the housekeeping tick

    /// Live tune 8: ready audio was held p50 80 ms (quiet at release p50 0.99 s against a
    /// window + re-check of 0.92 s): the quiet run began at the first 50 ms tick that saw it,
    /// and the release waited for another tick past the re-check. The run now counts from
    /// when it actually began. Pinned with no tick at all: her audio arriving 1.2 s after
    /// their end (window and re-check long passed) plays the moment it is in — before, the
    /// run began at that moment and she waited a re-check (here: forever).
    @Test func liveHeldAudioPlaysTheMomentTheGatePasses() async throws {
        let rig = try await BrainRig(tune: { $0.tick = 100 })
        try await rig.start()
        try rig.quiet(0.6)
        try await T4.turn(rig, "item_u1", talk: 1.0, lag: 0.51)
        try rig.quiet(0.7)                                                   // 1.21 s after their end
        T4.audio(rig, "resp_1", "item_a1", ms: 1200, text: "Blue, like a little sky.")
        try await T4.stepUntil(rig, 0.3) { T4.released(rig) != nil }
        let r = try #require(T4.released(rig), "\(rig.brain.trace)")
        #expect(r.ready && !r.overdue && r.heldMs <= 20, "released as it arrived: \(r)")
        #expect(RealtimeBrain.Options().tick == 0.02 && TurnPolicy.commitLag == 0.25)
        rig.shutdown()
    }

    /// A voice of theirs inside the re-check still holds her (the run is judged on the
    /// voice's own last voiced frame at release time, tune 5 F3).
    @Test func aVoiceInsideTheRecheckStillHoldsHer() async throws {
        let rig = try await BrainRig(tune: { $0.tick = 100 })
        try await rig.start()
        try rig.quiet(0.6)
        try await T4.turn(rig, "item_u1", talk: 1.0, lag: 0.51)
        try rig.quiet(0.3)
        try rig.talk(0.2)                                                    // they go on
        T4.audio(rig, "resp_1", "item_a1", ms: 1200, text: "Blue, like a little sky.")
        await rig.settle()
        #expect(T4.released(rig) == nil, "\(rig.brain.trace)")
        rig.shutdown()
    }

    /// The live operator's A/B knob: `DEE_VAD_SILENCE_MS=250` (the harness builds its
    /// session with `CloudSettings(voice:model:)`); the default stays 300.
    @Test func theSilenceIsASetting() {
        #expect(CloudSettings.defaultSilenceMs == 300)
        #expect(CloudSettings.silenceOverride([:]) == nil)
        #expect(CloudSettings.silenceOverride(["DEE_VAD_SILENCE_MS": "250"]) == 250)
        #expect(CloudSettings.silenceOverride(["DEE_VAD_SILENCE_MS": "50"]) == nil)
        #expect(CloudSettings.silenceOverride(["DEE_VAD_SILENCE_MS": "fast"]) == nil)
        var s = CloudSettings()
        if CloudSettings.silenceOverride() == nil { #expect(s.vadSilenceMs == 300) }
        s.vadSilenceMs = 250
        #expect(s.sessionConfig().turnDetection?.silenceDurationMs == 250)
        #expect(s.sessionConfig().turnDetection?.type == "server_vad")
        #expect(CloudSettings.turnDetection.silenceDurationMs == 300)
    }
}
