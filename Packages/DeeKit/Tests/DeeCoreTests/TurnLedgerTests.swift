import Foundation
import Testing
@testable import DeeCore

/// Stage-1 review of the voice-loop fixes (scratchpad stage1-review-logic.md): the
/// app's turn bookkeeping, moved out of `DeeModel` into `TurnLedger` / `UserFloor`
/// so it can be tested.
/// - H1: event lines (a wave, a long stroke) give way to the user like initiatives;
/// - M1: "stop" right after a barge-in is still a hush (no carried-over question);
/// - M2/M4: a stale Cortex floor or a TV in an empty room doesn't hold the floor;
/// - L2: asides, silent gaps and a voice that caught up early are not misread;
/// - L4: carried-over words never cross into a new conversation.
@Suite struct TurnLedgerTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    static func t(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    /// A user turn that was sent to the model.
    static func userTurn(_ l: inout TurnLedger, _ words: String = "Tell me a story", at s: Double = 0) -> Int {
        let (id, _) = l.begin(.reply, rate: 0.5, at: t(s))
        l.setUserText(words, for: id)
        l.enteredHistory(id)
        return id
    }

    // MARK: H1 — only answers to the user may end their turn

    @Test func eventsAndInitiativesGiveWayUntilHerVoiceStarts() {
        for kind in [TurnLedger.Kind.event, .initiative] {
            var l = TurnLedger()
            let (id, _) = l.begin(kind, rate: 0.5, at: Self.t0)
            #expect(l.mustGiveWay(userHoldsFloor: true), "\(kind): before the prompt (gate 2)")
            #expect(!l.mustGiveWay(userHoldsFloor: false))
            l.streamed("Oh, hello!", id: id, voiceSpeaking: false, at: Self.t(1))
            #expect(l.mustGiveWay(userHoldsFloor: true), "\(kind): written, not yet said (gate 3, a partial)")
            l.speakingStarted(at: Self.t(2))
            #expect(!l.mustGiveWay(userHoldsFloor: true), "\(kind): once she is speaking, a barge-in handles it")
        }
        var l = TurnLedger()
        _ = Self.userTurn(&l)
        #expect(!l.mustGiveWay(userHoldsFloor: true), "an answer to their words never waits")
        #expect(TurnLedger.Kind.event.givesWay && TurnLedger.Kind.initiative.givesWay && !TurnLedger.Kind.reply.givesWay)
    }

    @Test func aStoppedOrSettledReplyNeverGivesWayAgain() {
        var l = TurnLedger()
        _ = l.begin(.event, rate: 0.5, at: Self.t0)
        #expect(l.stop(hush: false, at: Self.t(1)) == .cancelGeneration)
        #expect(!l.mustGiveWay(userHoldsFloor: true))
        #expect(l.stop(hush: false, at: Self.t(2)) == .nothing, "stopping twice does nothing")
    }

    // MARK: M1 — "stop" after a barge-in

    @Test func stopAfterABargeInIsStillAHush() {
        // While the model is still writing: barge-in, then "stop", then the turn ends.
        var l = TurnLedger()
        var id = Self.userTurn(&l)
        l.streamed("Once upon a time", id: id, voiceSpeaking: false, at: Self.t(1))
        #expect(l.stop(hush: false, at: Self.t(1.2)) == .cancelGeneration)   // the barge-in
        #expect(l.stop(hush: true, at: Self.t(1.8)) == .nothing)             // "Stop!"
        var stopped = l.generationEnded(id, voiceSpeaking: false, at: Self.t(2))
        #expect(stopped != nil)
        if let r = stopped { l.settled(r, withdrawn: true, at: Self.t(2)) }
        #expect(l.takeCarryOver(at: Self.t(20)) == nil, "\"Tell me a story\" must not come back with their next words")

        // Generation over, settling queued: same.
        l = TurnLedger()
        id = Self.userTurn(&l)
        l.streamed("Once upon a time.", id: id, voiceSpeaking: false, at: Self.t(1))
        #expect(l.generationEnded(id, voiceSpeaking: false, at: Self.t(1.5)) == nil)
        guard case .settle(let r) = l.stop(hush: false, at: Self.t(2)) else { Issue.record("expected a settlement"); return }
        _ = l.stop(hush: true, at: Self.t(2.3))
        l.settled(r, withdrawn: true, at: Self.t(3))
        #expect(l.takeCarryOver(at: Self.t(4)) == nil)

        // Without the hush the unanswered words do carry over (C2).
        l = TurnLedger()
        id = Self.userTurn(&l, "Hi Dee.")
        _ = l.stop(hush: false, at: Self.t(1))
        stopped = l.generationEnded(id, voiceSpeaking: false, at: Self.t(1.1))
        if let r = stopped { l.settled(r, withdrawn: true, at: Self.t(1.1)) }
        #expect(l.takeCarryOver(at: Self.t(5)) == "Hi Dee.")
        #expect(l.takeCarryOver(at: Self.t(5)) == nil, "taken once")
    }

    @Test func carriedWordsExpire() {
        var l = TurnLedger()
        let id = Self.userTurn(&l, "Hi Dee.")
        _ = l.stop(hush: false, at: Self.t(1))
        if let r = l.generationEnded(id, voiceSpeaking: false, at: Self.t(1)) { l.settled(r, withdrawn: true, at: Self.t(1)) }
        #expect(l.takeCarryOver(at: Self.t(1 + TurnLedger.carryOverLife)) == nil)
    }

    // MARK: L4 — never into a new conversation

    @Test func carryOverNeverCrossesANewConversation() {
        var l = TurnLedger()
        let id = Self.userTurn(&l, "What was I saying")
        l.streamed("You were", id: id, voiceSpeaking: false, at: Self.t(1))
        _ = l.generationEnded(id, voiceSpeaking: false, at: Self.t(1))
        guard case .settle(let r) = l.stop(hush: false, at: Self.t(2)) else { Issue.record("expected a settlement"); return }
        l.newConversation()                                   // "start over" lands first
        l.settled(r, withdrawn: true, at: Self.t(3))          // the pending settle finishes later
        #expect(l.takeCarryOver(at: Self.t(4)) == nil)
        #expect(l.reply == nil)

        // Carried words already waiting are dropped too.
        var m = TurnLedger()
        let id2 = Self.userTurn(&m, "Hello")
        _ = m.stop(hush: false, at: Self.t(1))
        if let r2 = m.generationEnded(id2, voiceSpeaking: false, at: Self.t(1)) { m.settled(r2, withdrawn: true, at: Self.t(1)) }
        m.newConversation()
        #expect(m.takeCarryOver(at: Self.t(2)) == nil)
    }

    // MARK: L2 — what was actually played

    @Test func anAsideIsNotTheHeldInitiative() {
        // A held initiative; a laugh plays (and makes the voice drop the held speech).
        var l = TurnLedger()
        let (id, _) = l.begin(.initiative, rate: 0.5, at: Self.t0)
        l.enteredHistory(id)
        l.streamed("Did you see that bird?", id: id, voiceSpeaking: false, at: Self.t(1))
        _ = l.generationEnded(id, voiceSpeaking: false, at: Self.t(1.5))
        #expect(l.awaitingVoice)
        l.asideRequested(duration: 1.5, voiceSpeaking: false, at: Self.t(2))
        l.speakingStarted(at: Self.t(2.1))
        l.speakingFinished(at: Self.t(3))
        #expect(l.reply?.audioEverStarted == false, "the laugh was not her initiative")
        #expect(l.reply?.settled == false, "not kept as said")
        #expect(l.awaitingVoice)
        #expect(!l.isSilentTooLong(at: Self.t(1.5 + TurnLedger.silentReplyTimeout - 1)))
        #expect(l.isSilentTooLong(at: Self.t(1.5 + TurnLedger.silentReplyTimeout + 0.1)))
        guard case .settle(let r) = l.stop(hush: false, at: Self.t(12)) else { Issue.record("expected a settlement"); return }
        #expect(l.settlement(of: r, at: Self.t(12)) == .retract)
    }

    @Test func aReplyJoiningAnAsideStartsAfterIt() {
        // The aside is already playing when the reply's first words arrive.
        var l = TurnLedger()
        l.asideRequested(duration: 1.5, voiceSpeaking: false, at: Self.t0)
        let id = Self.userTurn(&l, "Haha, what?", at: 0.05)
        l.speakingStarted(at: Self.t(0.1))                    // the giggle
        #expect(l.reply?.audioEverStarted == false)
        l.streamed("Oh, I love that! We could paint it blue.", id: id, voiceSpeaking: true, at: Self.t(0.5))
        guard case .cancelGeneration = l.stop(hush: false, at: Self.t(1)) else { Issue.record("expected cancel"); return }
        let stopped = l.generationEnded(id, voiceSpeaking: false, at: Self.t(1))
        #expect(stopped.map { l.settlement(of: $0, at: Self.t(1)) } == .retract, "stopped during the giggle: none of the reply was heard")

        // The reply was queued while the aside had not started yet.
        var m = TurnLedger()
        m.asideRequested(duration: 1.5, voiceSpeaking: false, at: Self.t0)
        let id2 = Self.userTurn(&m, "Haha, what?", at: 0)
        m.streamed("Oh, I love that! We could paint it blue.", id: id2, voiceSpeaking: false, at: Self.t(0.05))
        m.speakingStarted(at: Self.t(0.2))                    // the giggle starts
        #expect(m.reply?.audioEverStarted == true)
        _ = m.stop(hush: false, at: Self.t(0.2 + 1.5 + 1.4))  // 1.4 s of the reply proper
        let r2 = m.generationEnded(id2, voiceSpeaking: false, at: Self.t(4))
        #expect(r2.map { m.settlement(of: $0, at: Self.t(4)) } == .truncate("Oh, I love that!"))
    }

    @Test func anAsideThatNeverStartsDoesNotSwallowTheReply() {
        var l = TurnLedger()
        l.asideRequested(duration: 1.5, voiceSpeaking: false, at: Self.t0)   // lost by the voice
        let id = Self.userTurn(&l, at: 5)
        l.streamed("Once upon a time.", id: id, voiceSpeaking: false, at: Self.t(5.5))
        l.speakingStarted(at: Self.t(6))
        #expect(l.reply?.audioEverStarted == true, "a stale aside request is not what started")
    }

    @Test func silencesBetweenSentencesAreNotSpeech() {
        var l = TurnLedger()
        let id = Self.userTurn(&l)
        let text = "Oh, I love that! We could paint the lamp blue. Or green, maybe."
        l.streamed(text, id: id, voiceSpeaking: false, at: Self.t(0.5))
        l.speakingStarted(at: Self.t(1))
        // ~30 Hz levels: 1 s of speech, 3 s waiting for the model, 0.4 s of speech.
        var s = 1.0
        func level(_ v: Double, until end: Double) {
            while s < end - 1e-9 { s += 1.0 / 30; l.speechLevel(v, at: Self.t(s)) }
        }
        level(0.6, until: 2)
        level(0, until: 5)
        level(0.6, until: 5.4)
        _ = l.stop(hush: false, at: Self.t(5.4))
        guard let r = l.generationEnded(id, voiceSpeaking: false, at: Self.t(5.5)) else { Issue.record("expected the stopped reply"); return }
        let played = r.played(at: Self.t(5.5))
        #expect(played > 1.6 && played < 2.0, "\(played): 1.4 s of words plus the gap's first 0.35 s, not 4.4 s of wall time")
        guard case .truncate(let said) = l.settlement(of: r, at: Self.t(5.5)) else { Issue.record("expected a cut"); return }
        #expect(said.hasPrefix("Oh, I love that!") && !said.contains("lamp"), "\(said)")
    }

    @Test func withoutLevelsTheWallClockCounts() {
        var l = TurnLedger()
        let id = Self.userTurn(&l)
        l.streamed("Oh, I love that! We could paint the lamp blue.", id: id, voiceSpeaking: false, at: Self.t(0.5))
        l.speakingStarted(at: Self.t(1))
        _ = l.stop(hush: false, at: Self.t(2.4))
        guard let r = l.generationEnded(id, voiceSpeaking: false, at: Self.t(3)) else { Issue.record("expected the stopped reply"); return }
        #expect(abs(r.played(at: Self.t(3)) - 1.4) < 1e-6)
    }

    @Test func aVoiceThatCaughtUpDuringAToolRoundPlayedEverything() {
        var l = TurnLedger()
        let id = Self.userTurn(&l)
        l.streamed("Let me check.", id: id, voiceSpeaking: false, at: Self.t(0.5))
        l.speakingStarted(at: Self.t(1))
        l.speakingFinished(at: Self.t(2))                     // played out; the model is still in a tool call
        #expect(l.reply?.settled == false)
        #expect(l.generationEnded(id, voiceSpeaking: false, at: Self.t(20)) == nil)
        #expect(l.reply?.settled == true, "nothing left to settle: every streamed word was played")
        #expect(l.reply?.audioFinished == true)
        #expect(l.takeUnsettled() == nil)

        // More was written after her voice went quiet: that part is still to play.
        var m = TurnLedger()
        let id2 = Self.userTurn(&m)
        m.streamed("Let me check.", id: id2, voiceSpeaking: false, at: Self.t(0.5))
        m.speakingStarted(at: Self.t(1))
        m.speakingFinished(at: Self.t(2))
        m.streamed(" It's noon.", id: id2, voiceSpeaking: false, at: Self.t(19))
        _ = m.generationEnded(id2, voiceSpeaking: false, at: Self.t(20))
        #expect(m.reply?.settled == false)
        m.speakingStarted(at: Self.t(20.2))
        m.speakingFinished(at: Self.t(21))
        #expect(m.reply?.audioFinished == true)
    }

    /// The user talks after her voice caught up, while the model is still in a tool
    /// round: all of the streamed text was heard, and only that stays in history.
    @Test func stoppedAfterHerVoiceCaughtUp() {
        var l = TurnLedger()
        let id = Self.userTurn(&l)
        l.streamed("Let me check, one moment.", id: id, voiceSpeaking: false, at: Self.t(0.5))
        l.speakingStarted(at: Self.t(1))
        l.speakingFinished(at: Self.t(1.2))                   // a quick voice: 0.2 s by the clock
        #expect(l.stop(hush: false, at: Self.t(8)) == .cancelGeneration)
        guard let r = l.generationEnded(id, voiceSpeaking: false, at: Self.t(8.2)) else { Issue.record("expected the stopped reply"); return }
        #expect(l.settlement(of: r, at: Self.t(9)) == .truncate("Let me check, one moment."),
                "not cut by the clock estimate; cut to what was streamed (the model wrote on before the cancel)")
    }

    @Test func toolOnlyTurnsAndBookkeeping() {
        var l = TurnLedger()
        let (id, previous) = l.begin(.reply, rate: 0.5, at: Self.t0)
        #expect(previous == nil)
        #expect(l.isLive(id))
        #expect(l.generationEnded(id, voiceSpeaking: false, at: Self.t(1)) == nil)
        #expect(l.reply?.settled == true, "nothing to say: history is what was generated")
        #expect(!l.awaitingVoice)

        // An unsettled previous reply is handed over when the next turn begins.
        var m = TurnLedger()
        let id1 = Self.userTurn(&m)
        m.streamed("Once upon a time.", id: id1, voiceSpeaking: false, at: Self.t(0.5))
        _ = m.generationEnded(id1, voiceSpeaking: false, at: Self.t(1))
        let (id2, prev) = m.begin(.reply, rate: 0.5, at: Self.t(2))
        #expect(prev?.id == id1)
        #expect(prev?.settled == true)
        #expect(id2 == id1 + 1)
        #expect(!m.isLive(id1))
        m.streamed("ignored", id: id1, voiceSpeaking: false, at: Self.t(3))
        #expect(m.reply?.spoken.text == "", "a superseded reply's words go nowhere")
    }

    // MARK: M2 / M4 — who holds the floor

    @Test func userFloor() {
        var f = UserFloor()
        let now = Self.t(100)
        #expect(!f.holds(at: now, voiceActive: false, engaged: true, cortexUserTurn: false, cortexYielding: false))
        #expect(f.holds(at: now, voiceActive: true, engaged: true, cortexUserTurn: false, cortexYielding: false))
        #expect(!f.holds(at: now, voiceActive: true, engaged: false, cortexUserTurn: false, cortexYielding: false),
                "a TV in an empty room does not hold the floor (she may fall asleep)")
        #expect(f.holds(at: now, voiceActive: false, engaged: false, cortexUserTurn: false, cortexYielding: true))

        f.partial(at: Self.t(99))
        #expect(f.holds(at: now, voiceActive: false, engaged: true, cortexUserTurn: false, cortexYielding: false), "mid-sentence")
        #expect(!f.holds(at: Self.t(99 + UserFloor.partialHold), voiceActive: false, engaged: true, cortexUserTurn: false, cortexYielding: false))
        #expect(f.holds(at: Self.t(110), voiceActive: false, engaged: true, cortexUserTurn: true, cortexYielding: false),
                "the Cortex's floor is theirs while their words are still coming")

        // "Stop" arrives as a command: no `.heard` reaches the Cortex, its floor stays theirs.
        f.closed(at: Self.t(101))
        #expect(!f.holds(at: Self.t(101), voiceActive: false, engaged: true, cortexUserTurn: true, cortexYielding: false),
                "a floor left at 'user speaking' after their words arrived is stale")
        f.paused(at: Self.t(105))   // they are talking again (a voice without partials)
        #expect(f.holds(at: Self.t(106), voiceActive: false, engaged: true, cortexUserTurn: true, cortexYielding: false))
    }
}
