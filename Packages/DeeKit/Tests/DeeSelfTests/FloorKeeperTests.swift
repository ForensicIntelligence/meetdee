import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

@Suite struct FloorKeeperTests {
    /// Runs FloorKeeper alone.
    struct Run {
        var fk = FloorKeeper()
        var m: Moment
        var rng = Rand(seed: 1)
        init(mind: MindSnapshot = Kit.snap()) { m = Kit.moment(mind: mind) }
        @discardableResult
        mutating func step(_ p: Percept, at t: Double, mind: MindSnapshot? = nil, reflex: Emotion? = nil) -> [Effect] {
            m.now = Kit.t0.addingTimeInterval(t)
            m.seq += 1
            m.momentary.beginStep(seq: m.seq)
            if let mind { m.ongoing.mind = mind }
            if let reflex { m.momentary.reflex = Timed(reflex, until: m.now.addingTimeInterval(4)) }
            return fk.reduce(p, &m, &rng)
        }
    }

    @Test func fullTurnCycle() {
        var r = Run()
        r.step(.partial("hello"), at: 0)
        #expect(r.m.momentary.floor == .userSpeaking(since: Kit.t0))
        #expect(r.m.momentary.floorEvents == [.userStarted])
        r.step(.pause(turnEnd: 0.3, hesitation: 0.7), at: 1)
        #expect(r.m.momentary.floor == .userPaused(since: Kit.t0.addingTimeInterval(1), turnEnd: 0.3, hesitation: 0.7))
        r.step(.pause(turnEnd: 0.4, hesitation: 0.6), at: 1.2)
        #expect(r.m.momentary.floor == .userPaused(since: Kit.t0.addingTimeInterval(1), turnEnd: 0.4, hesitation: 0.6), "pause start is kept")
        r.step(.partial("hello there"), at: 1.5)
        #expect(r.m.momentary.floor == .userSpeaking(since: Kit.t0), "resuming keeps the turn start")
        r.step(Kit.heard("hello there"), at: 2)
        #expect(r.m.momentary.floor == .idle)
        #expect(r.m.ongoing.turnsThisConversation == 1)
        r.step(.promptSubmitted, at: 2.1)
        #expect(r.m.momentary.floor == .deeThinking(since: Kit.t0.addingTimeInterval(2.1)))
        #expect(r.m.momentary.reaction == .thinking)
        r.step(.speakingStarted, at: 3)
        #expect(r.m.momentary.floor == .deeSpeaking(since: Kit.t0.addingTimeInterval(3)))
        r.step(.deeSaid(tag: .happy, sentence: "Hi!"), at: 3)
        #expect(r.m.momentary.llmTag?.live(at: r.m.now) == .happy)
        r.step(.speakingFinished, at: 5)
        #expect(r.m.momentary.floor == .idle)
        #expect(r.m.momentary.llmTag?.live(at: Kit.t0.addingTimeInterval(6.4)) == .happy, "tag lingers 1.5 s")
        #expect(r.m.momentary.llmTag?.live(at: Kit.t0.addingTimeInterval(6.5)) == nil)
    }

    @Test func heardWithoutPartialsStillCountsTurn() {
        var r = Run()
        r.step(Kit.heard("hi"), at: 0)
        #expect(r.m.momentary.floor == .idle)
        #expect(r.m.momentary.floorEvents == [.userStarted, .userFinished])
    }

    @Test func stalePauseAfterTurnIsIgnored() {
        var r = Run()
        r.step(.pause(turnEnd: 0.9, hesitation: 0), at: 0)
        #expect(r.m.momentary.floor == .idle)
    }

    @Test func bargeInCutsOffAndRaisesNoteOnce() {
        var r = Run()
        r.step(.promptSubmitted, at: 0)
        r.step(.speakingStarted, at: 1)
        r.step(.deeSaid(tag: .happy, sentence: "x"), at: 1)
        let fx = r.step(.bargeIn, at: 4)
        #expect(fx == [.stopSpeaking])
        #expect(r.m.momentary.floor == .yielding(since: Kit.t0.addingTimeInterval(4)))
        #expect(r.m.ongoing.cutOff)
        #expect(r.m.momentary.floorEvents == [.cutOff], "4 s in: not an interruption by Dee")
        #expect(r.m.ongoing.noteCandidates.map(\.kind) == [.cutOff])
        r.step(.bargeIn, at: 4.2)
        #expect(r.m.ongoing.noteCandidates.count == 1)
        r.step(.partial("wait"), at: 4.5)
        #expect(r.m.momentary.floor.isUserTurn)
        r.step(.speakingStarted, at: 9)
        #expect(!r.m.ongoing.cutOff, "cleared when the next reply starts")
    }

    @Test func userResumingWithinOneSecondMeansDeeInterrupted() {
        var r = Run()
        r.step(.promptSubmitted, at: 0)
        r.step(.speakingStarted, at: 1)
        r.step(.partial("and then"), at: 1.6)
        #expect(r.m.momentary.floorEvents.contains(.deeInterrupted))
        var r2 = Run()
        r2.step(.speakingStarted, at: 1)
        r2.step(.bargeIn, at: 1.9)
        #expect(r2.m.momentary.floorEvents == [.deeInterrupted, .cutOff])
        var r3 = Run()
        r3.step(.speakingStarted, at: 1)
        r3.step(.partial("x"), at: 2.5)
        #expect(!r3.m.momentary.floorEvents.contains(.deeInterrupted))
    }

    @Test func failsafeTimeouts() {
        var r = Run()
        r.step(.speakingStarted, at: 0)
        r.step(.bargeIn, at: 1)
        r.step(.tick, at: 2.5)
        #expect(r.m.momentary.floor != .idle)
        r.step(.tick, at: 3.5)
        #expect(r.m.momentary.floor == .idle)
        r.step(.promptSubmitted, at: 10)
        r.step(.tick, at: 50)
        #expect(r.m.momentary.floor != .idle)
        r.step(.tick, at: 56)
        #expect(r.m.momentary.floor == .idle)
    }

    @Test func conversationStartResets() {
        var r = Run()
        r.step(.speakingStarted, at: 0)
        r.step(.deeSaid(tag: .happy, sentence: "x"), at: 0)
        r.step(.conversationStarted(Kit.t0), at: 1)
        #expect(r.m.momentary.floor == .idle)
        #expect(r.m.momentary.llmTag == nil)
    }

    @Test func aversionNeverOnFirstSentenceAndAboutThirtyPercent() {
        var r = Run()
        r.step(.speakingStarted, at: 0)
        r.step(.deeSaid(tag: nil, sentence: "a"), at: 0)
        #expect(r.m.momentary.aversionUntil == nil)
        var averted = 0
        for i in 1...1000 {
            r.m.momentary.aversionUntil = nil
            r.step(.deeSaid(tag: nil, sentence: "b"), at: Double(i))
            if r.m.momentary.aversionUntil != nil { averted += 1 }
        }
        #expect((230...370).contains(averted))
    }

    // MARK: 0.5.1 review fixes (findings 4, 5)

    @Test func bargeInAfterAPartialKeepsTheUsersFloor() {
        var r = Run()
        r.step(.promptSubmitted, at: 0)
        r.step(.speakingStarted, at: 1)
        r.step(.partial("wait"), at: 3)
        #expect(r.m.momentary.floor == .userSpeaking(since: Kit.t0.addingTimeInterval(3)))
        let fx = r.step(.bargeIn, at: 3.1)
        #expect(fx == [.stopSpeaking])
        #expect(r.m.momentary.floor == .userSpeaking(since: Kit.t0.addingTimeInterval(3)), "not .yielding mid-utterance")
        #expect(r.m.ongoing.cutOff && r.m.ongoing.noteCandidates.map(\.kind) == [.cutOff])
        r.step(.tick, at: 6)
        #expect(r.m.momentary.floor.isUserTurn, "no 2 s yielding timeout while they talk")
    }

    @Test func lateSentenceAfterBargeInIsIgnored() {
        var r = Run()
        r.step(.speakingStarted, at: 0)
        r.step(.deeSaid(tag: .happy, sentence: "a"), at: 0)
        r.step(.bargeIn, at: 2)
        r.step(.deeSaid(tag: .excited, sentence: "b"), at: 2.1)
        #expect(r.m.momentary.floor == .yielding(since: Kit.t0.addingTimeInterval(2)))
        #expect(r.m.momentary.llmTag?.value == .happy)
        #expect(r.m.momentary.floorEvents.isEmpty)
    }

    @Test func lostSpeakingFinishedCannotWedgeTheFloorOrTheTag() {
        var r = Run()
        r.step(.speakingStarted, at: 0)
        r.step(.deeSaid(tag: .excited, sentence: "a"), at: 0)
        #expect(r.m.momentary.llmTag?.until == Kit.t0.addingTimeInterval(FloorKeeper.speakingTagCap))
        r.step(.deeSaid(tag: nil, sentence: "b"), at: 10)
        #expect(r.m.momentary.llmTag?.until == Kit.t0.addingTimeInterval(10 + FloorKeeper.speakingTagCap), "refreshed per sentence")
        r.step(.tick, at: 29)
        #expect(r.m.momentary.floor == .deeSpeaking(since: Kit.t0))
        r.step(.tick, at: 30.5)
        #expect(r.m.momentary.floor == .idle, "20 s without a sentence")
        #expect(r.m.momentary.llmTag?.live(at: Kit.t0.addingTimeInterval(32.1)) == nil)
    }

    @Test func lingeringTagIsNotExtendedByTheNextReply() {
        var r = Run()
        r.step(.speakingStarted, at: 0)
        r.step(.deeSaid(tag: .excited, sentence: "a"), at: 0)
        r.step(.speakingFinished, at: 1)
        r.step(.speakingStarted, at: 1.2)
        r.step(.deeSaid(tag: nil, sentence: "b"), at: 1.3)
        #expect(r.m.momentary.llmTag?.until == Kit.t0.addingTimeInterval(2.5))
    }

    @Test func gazeRequestsFollowTheFloor() {
        var r = Run()
        r.step(.tick, at: 0)
        #expect(r.m.momentary.gazeRequests.isEmpty, "idle: nothing to ask")
        r.step(.partial("hi"), at: 1)
        #expect(r.m.momentary.gazeRequests == [GazeRequest(.user, hold: 1, priority: .userTurn, owner: "FloorKeeper")])
        r.step(.promptSubmitted, at: 2)
        #expect(r.m.momentary.gazeRequests == [GazeRequest(.away, hold: 0.6, priority: .deeTurn, owner: "FloorKeeper")])
        r.step(.speakingStarted, at: 3)
        #expect(r.m.momentary.gazeRequests.map(\.target) == [.user])
        r.m.momentary.aversionUntil = Kit.t0.addingTimeInterval(3.6)
        r.step(.tick, at: 3.1)
        #expect(r.m.momentary.gazeRequests.map(\.target) == [.away])
    }

    // MARK: Tag reconciliation (§3.5)

    @Test func moodBandsOfTheFixtures() {
        #expect(EmotionBand(mood: Kit.happyNeutralRegard) == .positive)
        #expect(EmotionBand(mood: Kit.angry) == .negHigh)
        #expect(EmotionBand(mood: Kit.sad) == .negLow)
        #expect(EmotionBand(mood: Kit.fondButCross) == .negHigh)
        #expect(Kit.fondButCross.regard > 0.3)
        #expect(Kit.angry.regard <= 0.3 && Kit.sad.regard <= 0.3)
    }

    @Test func bandDistanceTable() {
        let d: [(EmotionBand, EmotionBand, Int)] = [
            (.positive, .neutral, 1), (.neutral, .negLow, 1), (.negLow, .negHigh, 1),
            (.positive, .negLow, 2), (.positive, .negHigh, 2), (.neutral, .negHigh, 1), (.negHigh, .negHigh, 0),
        ]
        for (a, b, n) in d {
            #expect(a.distance(to: b) == n)
            #expect(b.distance(to: a) == n)
        }
    }

    @Test func everyEmotionHasABand() {
        let bands = Dictionary(grouping: Emotion.allCases, by: EmotionBand.init)
        #expect(bands[.positive]?.count == 15)
        #expect(bands[.negLow]?.count == 6)
        #expect(bands[.negHigh]?.count == 3)
    }

    @Test func substitutionAlwaysLandsInMoodBand() {
        for tag in Emotion.allCases {
            for band in EmotionBand.allCases {
                #expect(EmotionBand(TagReconciler.substitute(tag, into: band)) == band, "\(tag) → \(band)")
            }
        }
        #expect(TagReconciler.substitute(.happy, into: .negHigh) == .unimpressed)
        #expect(TagReconciler.substitute(.love, into: .negLow) == .hurt)
    }

    @Test func happyTagWhileAngryIsSubstituted() {
        let r = TagReconciler.reconcile(.happy, mind: Kit.angry, liveReflex: nil)
        #expect(r.verdict == .substituted)
        #expect(r.emotion == .unimpressed)
    }

    @Test func loveTagWhileSadBecomesHurt() {
        let r = TagReconciler.reconcile(.love, mind: Kit.sad, liveReflex: nil)
        #expect(r == (.hurt, .substituted))
    }

    @Test func laughWhileUpsetIsKept() {
        // A joke made her giggle (positive reflex) while she is angry: the joyful tag stays.
        let r = TagReconciler.reconcile(.joy, mind: Kit.angry, liveReflex: .giddy)
        #expect(r == (.joy, .exemptReflex))
        // A reflex in another band does not exempt.
        #expect(TagReconciler.reconcile(.joy, mind: Kit.angry, liveReflex: .hurt).verdict == .substituted)
    }

    @Test func laughWhileUpsetThroughFloorKeeper() {
        var r = Run(mind: Kit.angry)
        r.step(.speakingStarted, at: 0)
        r.step(.deeSaid(tag: .giddy, sentence: "Ha!"), at: 0.5, reflex: .giddy)
        #expect(r.m.momentary.llmTag?.value == .giddy)
        #expect(r.fk.lastVerdict == .exemptReflex)
        // Reflex expired (> 4 s): the same tag is now substituted.
        r.step(.deeSaid(tag: .giddy, sentence: "Ha!"), at: 30)
        #expect(r.m.momentary.llmTag?.value == .grumpy)
        #expect(r.m.momentary.floorEvents.contains(.tagSubstituted))
    }

    @Test func affectionWithFrustrationIsKept() {
        let r = TagReconciler.reconcile(.love, mind: Kit.fondButCross, liveReflex: nil)
        #expect(r == (.love, .exemptAffection))
        #expect(TagReconciler.reconcile(.happy, mind: Kit.fondButCross, liveReflex: nil).verdict == .exemptAffection)
    }

    @Test func wrySmugWhileAngryIsKept() {
        #expect(TagReconciler.reconcile(.smug, mind: Kit.angry, liveReflex: nil) == (.smug, .exemptWry))
        #expect(TagReconciler.reconcile(.mischievous, mind: Kit.angry, liveReflex: nil) == (.mischievous, .exemptWry))
        // Wry only applies to negHigh moods.
        #expect(TagReconciler.reconcile(.smug, mind: Kit.sad, liveReflex: nil) == (.hurt, .substituted))
    }

    @Test func distanceOneIsNeverSubstituted() {
        #expect(TagReconciler.reconcile(.curious, mind: Kit.angry, liveReflex: nil) == (.curious, .kept))
        #expect(TagReconciler.reconcile(.sad, mind: Kit.angry, liveReflex: nil) == (.sad, .kept))
        #expect(TagReconciler.reconcile(.happy, mind: Kit.snap(), liveReflex: nil).verdict == .kept)
        #expect(TagReconciler.reconcile(.angry, mind: Kit.happyNeutralRegard, liveReflex: nil) == (.mischievous, .substituted))
    }

    @Test func untaggedSentenceKeepsCurrentTag() {
        var r = Run(mind: Kit.happyNeutralRegard)
        r.step(.speakingStarted, at: 0)
        r.step(.deeSaid(tag: .excited, sentence: "a"), at: 0)
        r.step(.deeSaid(tag: nil, sentence: "b"), at: 1)
        #expect(r.m.momentary.llmTag?.live(at: r.m.now) == .excited)
    }

    // MARK: Golden traces

    @Test func goldenTurnCycle() throws {
        try Golden.verify(Golden.record(FloorKeeper(), name: "turn-cycle", mind: Kit.happyNeutralRegard, [
            Cue(t: 0, p: .partial("look")), Cue(t: 0.8, p: .pause(turnEnd: 0.3, hesitation: 0.7)),
            Cue(t: 1.6, p: .partial("look at this")), Cue(t: 2.4, p: .pause(turnEnd: 0.8, hesitation: 0.1)),
            Cue(t: 2.9, p: Kit.heard("look at this")), Cue(t: 3.0, p: .promptSubmitted),
            Cue(t: 4.2, p: .speakingStarted), Cue(t: 4.2, p: .deeSaid(tag: .excited, sentence: "s1")),
            Cue(t: 5.5, p: .deeSaid(tag: nil, sentence: "s2")), Cue(t: 7.0, p: .speakingFinished),
            Cue(t: 7.0, p: .deeTurnFinished(text: "reply")), Cue(t: 8.0, p: .tick), Cue(t: 9.0, p: .tick),
        ]))
    }

    @Test func goldenReconciliation() throws {
        try Golden.verify(Golden.record(FloorKeeper(), name: "reconciliation", mind: Kit.angry, [
            Cue(t: 0, p: .speakingStarted),
            Cue(t: 0.1, p: .deeSaid(tag: .happy, sentence: "a")),                          // substituted → unimpressed
            Cue(t: 1, p: .deeSaid(tag: .smug, sentence: "b")),                             // wry: kept
            Cue(t: 2, p: .deeSaid(tag: .love, sentence: "c"), mind: Kit.fondButCross),     // affection: kept
            Cue(t: 3, p: .deeSaid(tag: .love, sentence: "d"), mind: Kit.sad),              // → hurt
            Cue(t: 4, p: .deeSaid(tag: .curious, sentence: "e"), mind: Kit.angry),         // distance 1: kept
            Cue(t: 5, p: .speakingFinished), Cue(t: 6.4, p: .tick), Cue(t: 6.6, p: .tick),
        ]))
    }

    @Test func goldenBargeIn() throws {
        try Golden.verify(Golden.record(FloorKeeper(), name: "barge-in", [
            Cue(t: 0, p: .promptSubmitted), Cue(t: 1, p: .speakingStarted), Cue(t: 1.5, p: .partial("wait")),
            Cue(t: 1.6, p: .bargeIn), Cue(t: 2.0, p: .partial("wait I meant")), Cue(t: 3, p: Kit.heard("wait I meant")),
            Cue(t: 3.1, p: .promptSubmitted), Cue(t: 4, p: .speakingStarted), Cue(t: 6, p: .bargeIn), Cue(t: 8.5, p: .tick),
        ]))
    }

}
