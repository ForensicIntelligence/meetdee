import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// A scripted stage for Beats' goldens, recorded under Beats' name: the real FloorKeeper,
/// then a stand-in for what Attention and EpisodeBuilder tell Beats (a back-camera sight
/// moves focus to that referent; `.gesture("recall")` / `.gesture("reunion")` raise the
/// signals), then Beats. The stand-ins raise their signals as "Attention" (earlier in the
/// pipeline), so Beats reads them in the same step.
struct BeatsStage: SubReducer {
    static let name = Beats.name
    var floor = FloorKeeper()
    var beats = Beats()

    mutating func reduce(_ p: Percept, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        var fx = floor.reduce(p, &m, &rng)
        switch p {
        case .sight(let camera, _, let novel):
            if let s = novel.first.flatMap(Subject.init) { m.momentary.focus = .referent(s, camera) }
        case .gesture("recall"):
            m.signal("recallHit", value: 0.6, label: "episode", by: "Attention")
        case .gesture("reunion"):
            m.signal("reunion", by: "Attention")
        default:
            break
        }
        fx += beats.reduce(p, &m, &rng)
        return fx
    }

    static func slice(of m: Moment) -> [String: String] {
        var s = Beats.slice(of: m)
        s["floor"] = m.momentary.floor.name
        return s
    }
}

/// Beats (SELF.md §1, §7.1, §7.2, §7.3). Owner: Beats. Goldens: `Fixtures/Beats/`.
@Suite struct BeatsTests {
    static let painting = Subject("painting")!

    static func kind(_ m: Moment) -> Beat.Kind? { m.momentary.beat?.kind }
    static func say(_ fx: [Effect]) -> [String] { fx.compactMap { if case .say(let s) = $0 { s } else { nil } } }

    @Test func clearWhenFinished() {
        var run = ReducerRun(Beats())
        run.m.momentary.beat = StanceTests.beat()
        run.step(.tick, at: 1.5)
        #expect(run.m.momentary.beat != nil)
        run.step(.tick, at: 2)
        #expect(run.m.momentary.beat == nil)
        #expect(run.m.momentary.signals.map(\.name) == ["beatFinished"])
        #expect(run.m.momentary.signals.first?.label == "examine")
    }

    @Test func activeStepRequestsGazeAndMannerismOncePerStep() {
        var run = ReducerRun(Beats())
        run.m.momentary.beat = StanceTests.beat(gaze: .down, mannerism: .doubleTake)
        run.step(.tick, at: 0.1)
        #expect(run.m.momentary.gazeRequests == [GazeRequest(.examineBack, hold: 1, priority: .beat, owner: "Beats")])
        #expect(run.m.momentary.mannerismRequests == [MannerismRequest(.mannerism(.doubleTake), rank: .beat, owner: "Beats")])
        run.step(.tick, at: 0.6)
        #expect(run.m.momentary.mannerismRequests.isEmpty, "the step's mannerism fires once")
        #expect(run.m.momentary.gazeRequests.count == 1, "gaze is held the whole step")
        run.step(.tick, at: 1.2)
        #expect(run.m.momentary.mannerismRequests.map(\.what) == [.mannerism(.nod)], "next step, its own mannerism")
        #expect(run.m.momentary.gazeRequests.map(\.target) == [.user])
    }

    @Test func consumesBeatRequests() {
        var run = ReducerRun(Beats())
        run.m.momentary.requestBeat(.listenHesitant, priority: 0.5, at: Kit.t0, by: "Listener")
        run.m.momentary.floor = .userPaused(since: Kit.t0, turnEnd: 0.1, hesitation: 0.7)
        run.step(.tick, at: 0)
        #expect(run.m.momentary.beatRequests.isEmpty)
        #expect(Self.kind(run.m) == .listenHesitant)
    }

    // MARK: Examine (shown a creation)

    @Test func examineWhenFocusMovesToABackCameraReferent() throws {
        var run = ReducerRun(Beats())
        run.m.momentary.focus = .referent(Self.painting, .back)
        run.step(.tick, at: 1)
        let b = try #require(run.m.momentary.beat)
        #expect(b.kind == .examine)
        #expect(b.steps.first?.overlay == .curious)
        let thinking = run.m.enduring.signature.repertoire[.thinking]?.map(\.mannerism) ?? []
        #expect(b.steps.first?.mannerism.map { thinking.contains($0) } == true, "her own thinking glance")
        #expect(run.m.momentary.gazeRequests.map(\.target) == [.examineBack], "eyes drop toward the back camera")
        #expect(run.m.momentary.mannerismRequests.map(\.rank) == [.beat])
    }

    @Test func frontReferentNeedsAShareCreationGoal() {
        var run = ReducerRun(Beats())
        run.m.momentary.focus = .referent(Self.painting, .front)
        run.step(.tick, at: 1)
        #expect(run.m.momentary.beat == nil)

        var shown = ReducerRun(Beats())
        shown.m.ongoing.hypotheses = [Hypothesis(kind: .goal, value: "shareCreation", confidence: 0.6, expires: Kit.t0.addingTimeInterval(600))]
        shown.m.momentary.focus = .referent(Self.painting, .front)
        shown.step(.tick, at: 1)
        #expect(Self.kind(shown.m) == .examine)
        #expect(shown.m.momentary.gazeRequests.map(\.target) == [.user], "a front referent: look at what they hold up")
    }

    @Test func notTheSameReferentTwiceWithinThirtySeconds() {
        var run = ReducerRun(Beats())
        run.m.momentary.focus = .referent(Self.painting, .back)
        run.step(.tick, at: 1)
        run.m.momentary.focus = .person(nil)
        run.step(.tick, at: 5)
        run.m.momentary.focus = .referent(Self.painting, .back)
        run.step(.tick, at: 10)
        #expect(run.m.momentary.beat == nil)
        run.m.momentary.focus = .person(nil)
        run.step(.tick, at: 35)
        run.m.momentary.focus = .referent(Self.painting, .back)
        run.step(.tick, at: 40)
        #expect(Self.kind(run.m) == .examine)
    }

    @Test func examineIsHeldThroughThePrefill() {
        var run = ReducerRun(Beats())
        run.m.momentary.focus = .referent(Self.painting, .back)
        run.step(.tick, at: 0)
        #expect(run.m.momentary.beat?.totalDuration == 2.2)
        run.m.momentary.floor = .deeThinking(since: Kit.t0.addingTimeInterval(1))
        var t = 0.5
        while t <= 12 {
            run.step(.tick, at: t)
            if t <= 7.5 { #expect(Self.kind(run.m) == .examine, "still examining while she prepares a reply (t=\(t))") }
            t += 0.5
        }
        #expect(run.m.momentary.beat == nil, "held at most \(Beats.maxHeld) s")
    }

    @Test func examineIsNotHeldOnceSheSpeaks() {
        var run = ReducerRun(Beats())
        run.m.momentary.focus = .referent(Self.painting, .back)
        run.step(.tick, at: 0)
        run.m.momentary.floor = .deeSpeaking(since: Kit.t0.addingTimeInterval(1))
        run.step(.tick, at: 1.5)
        run.step(.tick, at: 2.2)
        #expect(run.m.momentary.beat == nil)
    }

    // MARK: Recognize → brighten

    @Test func examineRecognizeBrighten() throws {
        var run = ReducerRun(Beats())
        run.m.momentary.focus = .referent(Self.painting, .back)
        run.step(.tick, at: 0)
        #expect(Self.kind(run.m) == .examine)
        // EpisodeBuilder (later in the pipeline) found the episode last step.
        run.m.signal("recallHit", value: 0.6, by: "EpisodeBuilder")
        run.step(.tick, at: 1)
        #expect(Self.kind(run.m) == .recognize)
        #expect(run.m.momentary.mannerismRequests.map(\.what) == [.mannerism(.doubleTake)])
        #expect(run.r.queue == [.brighten])
        run.step(.tick, at: 1.8)
        let b = try #require(run.m.momentary.beat)
        #expect(b.kind == .brighten)
        #expect(b.steps.first?.overlay == .excited)
        #expect(b.steps.first?.intensityBoost == 0.2)
        #expect(run.m.momentary.signals.filter { $0.owner == "Beats" }.map(\.label) == ["recognize"])
    }

    @Test func recallHitShortlyAfterExamineStillBrightens() {
        var run = ReducerRun(Beats())
        run.m.momentary.focus = .referent(Self.painting, .back)
        run.step(.tick, at: 0)
        run.step(.tick, at: 2.5)
        #expect(run.m.momentary.beat == nil)
        run.m.signal("recallHit", value: 0, by: "EpisodeBuilder")
        run.step(.tick, at: 4)
        #expect(Self.kind(run.m) == .recognize)
        #expect(run.r.queue == [.brighten], "within 4 s of the examine")
    }

    @Test func recallHitOutOfTheBlueBrightensOnlyIfWarm() {
        var cool = ReducerRun(Beats())
        cool.m.signal("recallHit", value: 0.1, by: "EpisodeBuilder")
        cool.step(.tick, at: 1)
        #expect(Self.kind(cool.m) == .recognize)
        #expect(cool.r.queue.isEmpty)

        var warm = ReducerRun(Beats())
        warm.m.signal("recallHit", value: 0.5, by: "EpisodeBuilder")
        warm.step(.tick, at: 1)
        #expect(warm.r.queue == [.brighten])
    }

    // MARK: Hesitant listening

    @Test func listenHesitantSoftensLidsAndEndsWhenTheyCarryOn() {
        var run = ReducerRun(Beats())
        run.m.momentary.floor = .userPaused(since: Kit.t0, turnEnd: 0.1, hesitation: 0.7)
        run.m.momentary.requestBeat(.listenHesitant, priority: 0.4, at: Kit.t0, by: "Listener")
        run.step(.tick, at: 0)
        #expect(Self.kind(run.m) == .listenHesitant)
        #expect(run.m.momentary.faceRequests == [FaceRequest(.lidSoften, Beats.hesitantLids, priority: .beat, owner: "Beats")])
        #expect(run.m.momentary.beat?.steps.first?.overlay == nil, "the listening face stays")
        run.m.momentary.floor = .userSpeaking(since: Kit.t0)
        run.step(.partial("and"), at: 0.6)
        #expect(run.m.momentary.beat == nil)
        #expect(run.m.momentary.faceRequests.isEmpty)
    }

    // MARK: Sorry, go on (clipped speaker)

    @Test func sorryGoOnWhenDeeInterrupts() throws {
        var run = ReducerRun(Beats())
        let fx = run.step(.partial("I was"), at: 1, events: [.deeInterrupted, .userStarted])
        #expect(Self.kind(run.m) == .sorryGoOn)
        let lines = Self.say(fx)
        #expect(lines.count == 1)
        #expect(Beats.sorryLines(run.m.enduring.humour).contains(lines[0]))
        #expect(run.m.momentary.beat?.steps.first?.overlay == .shy)
        // The barge-in that follows also flags the interruption: one apology only.
        let again = run.step(.bargeIn, at: 1.1, events: [.deeInterrupted, .cutOff])
        #expect(Self.say(again).isEmpty)
        run.step(.tick, at: 1.9)
        #expect(run.m.momentary.mannerismRequests.map(\.what) == [.mannerism(.nod)], "a go-on nod")
    }

    /// Review finding 14: while the user already has the floor she does not talk over them
    /// again to apologise: the sheepish look and the nod only. Idle floor: the line, and
    /// `"sorrySaid"` so RepairKeeper does not ask for a second apology later. Audit C3:
    /// `.yielding` is not free — she yields *because* they are talking — so the line waits
    /// for the floor to go idle (see VoiceLoopFixTests for the waiting rules).
    @Test func sorryLineOnlyWhenTheFloorIsFree() {
        var talking = ReducerRun(Beats())
        talking.m.momentary.floor = .userSpeaking(since: Kit.t0)
        let fx = talking.step(.partial("I was"), at: 1, events: [.deeInterrupted, .userStarted])
        #expect(Self.kind(talking.m) == .sorryGoOn && Self.say(fx).isEmpty)
        #expect(!talking.m.momentary.signals.contains { $0.name == "sorrySaid" })
        var yielding = ReducerRun(Beats())
        yielding.m.momentary.floor = .yielding(since: Kit.t0)
        let held = yielding.step(.bargeIn, at: 1, events: [.deeInterrupted, .cutOff])
        #expect(Self.kind(yielding.m) == .sorryGoOn && Self.say(held).isEmpty, "not over the user who just barged in")
        #expect(!yielding.m.momentary.signals.contains { $0.name == "sorrySaid" })
        yielding.m.momentary.floor = .idle
        let said = yielding.step(.tick, at: 3)
        #expect(Self.say(said).count == 1)
        #expect(yielding.m.momentary.signals.contains { $0.name == "sorrySaid" && $0.owner == Beats.name })
    }

    /// Review finding 6: no lighting up while they are upset.
    @Test func noBrightenWhileTheyAreUpset() {
        var run = ReducerRun(Beats())
        run.m.ongoing.turnDistress = Timed(0.6, until: Kit.t0.addingTimeInterval(600))
        run.m.signal("recallHit", value: 0.9, by: "EpisodeBuilder")
        run.step(.tick, at: 1)
        #expect(Self.kind(run.m) == .recognize && run.r.queue.isEmpty)
    }

    @Test func sorryLinesVaryAndNeverRepeatBackToBack() {
        var run = ReducerRun(Beats(), seed: 3)
        var said: [String] = []
        for i in 0..<20 {
            let fx = run.step(.partial("x"), at: Double(i) * 5, events: [.deeInterrupted])
            said += Self.say(fx)
        }
        #expect(said.count == 20)
        for (a, b) in zip(said, said.dropFirst()) { #expect(a != b) }
        #expect(Set(said).count >= 3)
    }

    @Test func sorryLineTables() {
        for style in HumourStyle.allCases {
            let lines = Beats.sorryLines(style)
            #expect(lines.count >= 4, "≥ 4 variants for \(style)")
            #expect(Set(lines).count == lines.count)
            for l in lines {
                #expect(l.count <= 48)
                for w in CueWriter.reproachWords { #expect(!l.lowercased().contains(w)) }
            }
        }
    }

    @Test func sorryLineIsSeeded() {
        func lines(_ seed: UInt64) -> [String] {
            var run = ReducerRun(Beats(), seed: seed)
            return (0..<6).flatMap { i in Self.say(run.step(.partial("x"), at: Double(i) * 5, events: [.deeInterrupted])) }
        }
        #expect(lines(5) == lines(5))
        #expect(lines(5) != lines(6) || lines(5) != lines(7))
    }

    // MARK: Who preempts whom

    @Test func preemption() {
        var run = ReducerRun(Beats())
        run.m.momentary.focus = .referent(Self.painting, .back)
        run.step(.tick, at: 0)
        #expect(Self.kind(run.m) == .examine)
        // A hesitant-listening request (0.4) does not interrupt an examine (0.5).
        run.m.momentary.floor = .userPaused(since: Kit.t0, turnEnd: 0.1, hesitation: 0.7)
        run.m.momentary.requestBeat(.listenHesitant, priority: Listener.hesitantBeatPriority, at: Kit.t0, by: "Listener")
        run.step(.tick, at: 0.5)
        #expect(Self.kind(run.m) == .examine)
        // Interrupting the user (0.9) preempts it, and the new beat's first mannerism fires.
        run.step(.partial("x"), at: 0.8, events: [.deeInterrupted])
        #expect(Self.kind(run.m) == .sorryGoOn)
        // The same kind never restarts itself; a lower one waits.
        let started = run.m.momentary.beat?.started
        run.m.momentary.requestBeat(.sorryGoOn, priority: 1, at: Kit.t0, by: "Test")
        run.step(.tick, at: 1.0)
        #expect(run.m.momentary.beat?.started == started)
        run.m.momentary.requestBeat(.reunion, priority: 0.7, at: Kit.t0, by: "Test")
        run.step(.tick, at: 1.2)
        #expect(Self.kind(run.m) == .sorryGoOn)
    }

    @Test func aNewBeatShowsItsFirstMannerism() {
        var run = ReducerRun(Beats())
        run.m.momentary.beat = StanceTests.beat(mannerism: .doubleTake)
        run.step(.tick, at: 0.1)
        #expect(run.m.momentary.mannerismRequests.count == 1)
        // Reunion preempts at step 0: its bounce must still play.
        run.m.momentary.requestBeat(.reunion, priority: 0.7, at: Kit.t0, by: "Test")
        run.step(.tick, at: 0.3)
        #expect(Self.kind(run.m) == .reunion)
        #expect(run.m.momentary.mannerismRequests.map(\.what) == [.mannerism(.bounce)])
    }

    @Test func reunionFromASignal() throws {
        var run = ReducerRun(Beats())
        run.m.signal("reunion", by: "Learner")   // a later reducer: delivered on the next step
        run.step(.tick, at: 1)
        let b = try #require(run.m.momentary.beat)
        #expect(b.kind == .reunion)
        #expect(b.steps.map(\.overlay) == [.excited, .happy])
        #expect(run.m.momentary.mannerismRequests.map(\.what) == [.mannerism(.bounce)])
    }

    @Test func conversationStartedClears() {
        var run = ReducerRun(Beats())
        run.m.momentary.focus = .referent(Self.painting, .back)
        run.step(.tick, at: 0)
        run.step(.conversationStarted(Kit.t0.addingTimeInterval(1)), at: 1)
        #expect(run.m.momentary.beat == nil)
        #expect(run.r.queue.isEmpty)
    }

    @Test func forgetSubjectAllowsReexamining() {
        var run = ReducerRun(Beats())
        run.m.momentary.focus = .referent(Self.painting, .back)
        run.step(.tick, at: 0)
        run.m.momentary.focus = .none
        run.step(.tick, at: 3)
        run.r.forget(subject: Self.painting, &run.m)
        run.m.momentary.focus = .referent(Self.painting, .back)
        run.step(.tick, at: 5)
        #expect(Self.kind(run.m) == .examine)
    }

    // MARK: Whole pipeline: the beat reaches the stance

    @Test func beatOverlayAndGazeReachTheStance() {
        var cx = Kit.cortex()
        let snap = Kit.snap()
        _ = cx.step(.partial("look at this"), mind: snap, at: Kit.t0)
        cx.moment.momentary.requestBeat(.recognize, priority: 0.6, at: Kit.t0, by: "Test")
        _ = cx.step(.tick, mind: snap, at: Kit.t0.addingTimeInterval(0.5))
        #expect(cx.stance.beatStep?.mannerism == .doubleTake)
        #expect(cx.stance.mannerism == .doubleTake)
        #expect(cx.stance.expression == .surprised)
        #expect(cx.stance.gaze.target == .user)
    }

    // MARK: Goldens

    @Test func goldenShownACreation() throws {
        try Golden.verify(Golden.record(BeatsStage(), name: "shown-a-creation", [
            Cue(t: 0, p: .partial("look what I made")),
            Cue(t: 0.5, p: .sight(camera: .back, things: ["painting"], novel: ["painting"])),
            Cue(t: 1.0, p: .tick),
            Cue(t: 1.3, p: .gesture("recall")),
            Cue(t: 1.6, p: .heard(text: "look what I made", durationS: 1.6, loudnessVsBaseline: 0, appraisal: Appraisal())),
            Cue(t: 1.7, p: .promptSubmitted),
            Cue(t: 2.0, p: .tick), Cue(t: 2.5, p: .tick), Cue(t: 3.0, p: .tick), Cue(t: 3.5, p: .tick), Cue(t: 4.0, p: .tick),
            Cue(t: 4.5, p: .speakingStarted),
            Cue(t: 4.6, p: .deeSaid(tag: .curious, sentence: "Oh, is this the watercolour?")),
            Cue(t: 5.0, p: .tick), Cue(t: 5.5, p: .tick),
        ]))
    }

    @Test func goldenSorryGoOn() throws {
        try Golden.verify(Golden.record(BeatsStage(), name: "sorry-go-on", [
            Cue(t: 0, p: .promptSubmitted),
            Cue(t: 1, p: .speakingStarted),
            Cue(t: 1.1, p: .deeSaid(tag: .happy, sentence: "So I was")),
            Cue(t: 1.5, p: .partial("and")),
            Cue(t: 1.6, p: .bargeIn),
            Cue(t: 2.0, p: .tick), Cue(t: 2.5, p: .tick), Cue(t: 3.0, p: .tick),
            Cue(t: 3.2, p: .gesture("reunion")), Cue(t: 4.0, p: .tick), Cue(t: 5.0, p: .tick), Cue(t: 6.0, p: .tick),
        ]))
    }
}
