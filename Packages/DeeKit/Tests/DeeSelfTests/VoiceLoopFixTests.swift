import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// Voice-loop audit (scratchpad voice-audit.md), the Cortex parts of C3: Dee's own
/// speech must never close or steal the user's turn.
/// - the "sorry, go on" line is never said while the user holds the floor or Dee is
///   yielding to them; it waits for an idle floor and is dropped once they talk;
/// - a sound of hers during their turn (a laugh, a canned line) does not end it, so
///   their next words don't read as them interrupting her;
/// - a pause after a barge-in is the user's turn, not a yield that times out to idle
///   while they are still talking.
@Suite struct VoiceLoopFixTests {
    static func say(_ fx: [Effect]) -> [String] { BeatsTests.say(fx) }

    // MARK: FloorKeeper

    @Test func herLaughDuringTheirPauseKeepsTheirTurn() {
        var r = FloorKeeperTests.Run()
        r.step(.partial("so I went to the"), at: 0)
        r.step(.pause(turnEnd: 0.2, hesitation: 0.6), at: 1)
        r.step(.speakingStarted, at: 1.2)   // a giggle at a tickle
        #expect(r.m.momentary.floor.isUserTurn, "her laugh is an interjection, not her turn")
        r.step(.speakingFinished, at: 1.8)
        #expect(r.m.momentary.floor.isUserTurn)
        r.step(.partial("so I went to the store"), at: 2)
        #expect(r.m.momentary.floor == .userSpeaking(since: Kit.t0), "the same turn carries on")
        #expect(!r.m.momentary.floorEvents.contains(.deeInterrupted), "carrying on is not being interrupted by her")
    }

    /// Review M2: words that never reach the Cortex as `.heard` (a spoken "stop") must
    /// not leave the floor theirs for good — that blocked sleep and every aside.
    @Test func aUserTurnWithNoWordsArrivingTimesOut() {
        var r = FloorKeeperTests.Run()
        r.step(.partial("stop"), at: 0)
        #expect(r.m.momentary.floor == .userSpeaking(since: Kit.t0))
        r.step(.tick, at: FloorKeeper.userSpeakingTimeout - 0.5)
        #expect(r.m.momentary.floor.isUserTurn)
        r.step(.tick, at: FloorKeeper.userSpeakingTimeout + 0.5)
        #expect(r.m.momentary.floor == .idle)
        #expect(r.fk.userTurnStarted == nil)

        // A long sentence keeps its floor while partials keep coming.
        var long = FloorKeeperTests.Run()
        for t in stride(from: 0.0, through: 20, by: 0.5) {
            long.step(.partial("and then"), at: t)
            long.step(.tick, at: t + 0.25)
        }
        #expect(long.m.momentary.floor == .userSpeaking(since: Kit.t0))
        // So does a pause estimate.
        long.step(.pause(turnEnd: 0.2, hesitation: 0.8), at: 25)
        long.step(.partial("and then the"), at: 25.5)
        long.step(.tick, at: 25.5 + FloorKeeper.userSpeakingTimeout - 0.5)
        #expect(long.m.momentary.floor.isUserTurn)
    }

    @Test func herReplyStillTakesTheFloor() {
        var r = FloorKeeperTests.Run()
        r.step(Kit.heard("hi"), at: 0)
        r.step(.promptSubmitted, at: 0.1)
        r.step(.speakingStarted, at: 1)
        #expect(r.m.momentary.floor == .deeSpeaking(since: Kit.t0.addingTimeInterval(1)))
        // A reply sentence takes the floor even if it starts while they talk.
        var talking = FloorKeeperTests.Run()
        talking.step(.partial("and"), at: 0)
        talking.step(.deeSaid(tag: .happy, sentence: "Hello!"), at: 0.5)
        #expect(talking.m.momentary.floor == .deeSpeaking(since: Kit.t0.addingTimeInterval(0.5)))
    }

    @Test func aPauseAfterABargeInIsTheUsersTurn() {
        var r = FloorKeeperTests.Run()
        r.step(.promptSubmitted, at: 0)
        r.step(.speakingStarted, at: 1)
        r.step(.deeSaid(tag: nil, sentence: "So I was"), at: 1)
        r.step(.bargeIn, at: 3)
        #expect(r.m.momentary.floor == .yielding(since: Kit.t0.addingTimeInterval(3)))
        // A voice without live partials reports only their pauses.
        r.step(.pause(turnEnd: 0.3, hesitation: 0.4), at: 4)
        #expect(r.m.momentary.floor == .userPaused(since: Kit.t0.addingTimeInterval(4), turnEnd: 0.3, hesitation: 0.4))
        #expect(r.m.momentary.floorEvents.contains(.userStarted))
        #expect(r.fk.userTurnStarted == Kit.t0.addingTimeInterval(4))
        r.step(.tick, at: 5.5)
        #expect(r.m.momentary.floor.isUserTurn, "no 2 s yield timeout while they talk")
        r.step(Kit.heard("wait, what about the dog"), at: 6)
        #expect(r.m.momentary.floor == .idle)
    }

    // MARK: Beats: the sorry line

    @Test func owedSorryIsSaidWhenTheFloorGoesIdle() {
        var run = ReducerRun(Beats())
        run.m.momentary.floor = .yielding(since: Kit.t0)
        #expect(Self.say(run.step(.bargeIn, at: 0.5, events: [.deeInterrupted, .cutOff])).isEmpty)
        #expect(run.r.sorryOwedSince == Kit.t0.addingTimeInterval(0.5))
        #expect(Self.say(run.step(.tick, at: 1)).isEmpty, "still yielding")
        run.m.momentary.floor = .idle
        let fx = run.step(.tick, at: 2.6)
        #expect(Self.say(fx).count == 1)
        #expect(run.r.sorryOwedSince == nil)
        #expect(Self.say(run.step(.tick, at: 3)).isEmpty, "once")
    }

    @Test func owedSorryIsDroppedWhenTheUserTakesTheFloor() {
        var run = ReducerRun(Beats())
        run.m.momentary.floor = .yielding(since: Kit.t0)
        run.step(.bargeIn, at: 0.5, events: [.deeInterrupted, .cutOff])
        run.m.momentary.floor = .userSpeaking(since: Kit.t0.addingTimeInterval(1))
        run.step(.partial("no wait"), at: 1, events: [.userStarted])
        #expect(run.r.sorryOwedSince == nil)
        run.m.momentary.floor = .idle
        #expect(Self.say(run.step(.tick, at: 2)).isEmpty, "they talked: RepairKeeper's note covers it")
        #expect(!run.m.momentary.signals.contains { $0.name == "sorrySaid" })
    }

    @Test func owedSorryExpiresAndGivesWayToHerNextTurn() {
        var late = ReducerRun(Beats())
        late.m.momentary.floor = .yielding(since: Kit.t0)
        late.step(.bargeIn, at: 0, events: [.deeInterrupted, .cutOff])
        late.step(.tick, at: Beats.sorryWait + 0.5)
        #expect(late.r.sorryOwedSince == nil)
        late.m.momentary.floor = .idle
        #expect(Self.say(late.step(.tick, at: Beats.sorryWait + 1)).isEmpty, "too late to apologise out of the blue")

        var replying = ReducerRun(Beats())
        replying.m.momentary.floor = .yielding(since: Kit.t0)
        replying.step(.bargeIn, at: 0, events: [.deeInterrupted, .cutOff])
        replying.m.momentary.floor = .deeThinking(since: Kit.t0.addingTimeInterval(1))
        replying.step(.promptSubmitted, at: 1)
        replying.m.momentary.floor = .idle
        #expect(Self.say(replying.step(.tick, at: 2)).isEmpty, "her reply came first")
    }

    @Test func floorFreeMeansIdleOnly() {
        #expect(Beats.floorFree(.idle))
        #expect(!Beats.floorFree(.yielding(since: Kit.t0)))
        #expect(!Beats.floorFree(.userSpeaking(since: Kit.t0)))
        #expect(!Beats.floorFree(.userPaused(since: Kit.t0, turnEnd: 0.5, hesitation: 0)))
        #expect(!Beats.floorFree(.deeThinking(since: Kit.t0)))
        #expect(!Beats.floorFree(.deeSpeaking(since: Kit.t0)))
    }

    // MARK: Whole Cortex

    /// She starts, they talk over her within a second, she stops: no line over them.
    /// If they then say nothing, the floor idles and she invites them to go on.
    @Test func cortexNeverApologisesOverTheUser() {
        var cx = Kit.cortex()
        let mind = Kit.snap()
        var lines: [String] = []
        func step(_ p: Percept, _ t: Double) { lines += Self.say(cx.step(p, mind: mind, at: Kit.t0.addingTimeInterval(t))) }
        step(Kit.heard("hi"), 0)
        step(.promptSubmitted, 0.2)
        step(.speakingStarted, 1)
        step(.deeSaid(tag: .happy, sentence: "Oh hi! So"), 1)
        step(.bargeIn, 1.4)
        #expect(lines.isEmpty, "yielding: they are talking")
        step(.tick, 2)
        step(.tick, 2.5)
        step(.tick, 3)
        #expect(lines.isEmpty)
        step(.tick, 3.5)   // > 2 s yielding with no words: idle
        #expect(lines.count == 1)

        var talked = Kit.cortex()
        var said: [String] = []
        for (p, t) in [(Kit.heard("hi"), 0.0), (.promptSubmitted, 0.2), (.speakingStarted, 1), (.deeSaid(tag: .happy, sentence: "Oh hi! So"), 1),
                       (.bargeIn, 1.4), (.partial("no listen"), 1.6), (.tick, 2), (.tick, 3), (.tick, 4),
                       (Kit.heard("no listen, I need help"), 4.5), (.tick, 5)] as [(Percept, Double)] {
            said += Self.say(talked.step(p, mind: mind, at: Kit.t0.addingTimeInterval(t)))
        }
        #expect(said.isEmpty, "they had the floor the whole time")
    }
}
