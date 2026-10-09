import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// FloorKeeper then Listener, recorded under Listener's name: Listener reads the floor
/// and floor events FloorKeeper writes earlier in the same step (as in Cortex).
struct FloorThenListener: SubReducer {
    static let name = Listener.name
    var floor = FloorKeeper()
    var listener = Listener()

    mutating func reduce(_ p: Percept, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        floor.reduce(p, &m, &rng) + listener.reduce(p, &m, &rng)
    }

    mutating func conversationStarted(at d: Date, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        floor.conversationStarted(at: d, &m, &rng) + listener.conversationStarted(at: d, &m, &rng)
    }

    static func slice(of m: Moment) -> [String: String] {
        var s = Listener.slice(of: m)
        s["floor"] = m.momentary.floor.name
        return s
    }
}

/// Listener (SELF.md §7.2). Owner: Listener. Goldens: `Fixtures/Listener/`.
@Suite struct ListenerTests {
    static let warm = "I love this, it is wonderful and I am so happy"
    static let grim = "this is awful and terrible, I hate it"

    /// A moment in the user's turn: speaking since `since` (s after t0).
    static func speaking(_ run: inout ReducerRun<Listener>, since: Double = 0) {
        run.m.momentary.floor = .userSpeaking(since: Kit.t0.addingTimeInterval(since))
        run.step(.tick, at: since, events: [.userStarted])
    }

    /// A pause percept with the floor FloorKeeper would set.
    @discardableResult
    static func pause(_ run: inout ReducerRun<Listener>, at t: Double, since: Double? = nil, turnEnd: Double, hesitation: Double) -> [Effect] {
        run.m.momentary.floor = .userPaused(since: Kit.t0.addingTimeInterval(since ?? t), turnEnd: turnEnd, hesitation: hesitation)
        return run.step(.pause(turnEnd: turnEnd, hesitation: hesitation), at: t)
    }

    static func mine(_ m: Moment, _ f: FaceField) -> Double? {
        m.momentary.faceRequests.last { $0.owner == Listener.name && $0.field == f }?.value
    }

    static func signals(_ m: Moment, _ name: String) -> [Signal] {
        m.momentary.signals.filter { $0.owner == Listener.name && $0.name == name && $0.seq == m.seq }
    }

    // MARK: Preview

    @Test func clearsPreviewOutsideUserTurn() {
        var run = ReducerRun(Listener())
        run.m.momentary.preview = ListenPreview(valence: 0.3, intensity: 0.3, signSince: Kit.t0)
        run.m.momentary.floor = .userSpeaking(since: Kit.t0)
        run.step(.tick, at: 0)
        #expect(run.m.momentary.preview != nil)
        run.m.momentary.floor = .deeThinking(since: Kit.t0)
        run.step(.tick, at: 1)
        #expect(run.m.momentary.preview == nil)
    }

    @Test func previewFromACopyOfTheAppraiserCappedAtHalf() throws {
        var run = ReducerRun(Listener())
        Self.speaking(&run)
        run.step(.partial(Self.warm), at: 0.5)
        let p = try #require(run.m.momentary.preview)
        #expect(p.valence > 0.05)
        #expect(p.intensity <= Listener.maxPreviewIntensity)
        #expect(p.intensity == min(0.5, abs(p.valence)))
        // The appraiser is a copy: the same text appraises the same way every time.
        var again = ReducerRun(Listener())
        Self.speaking(&again)
        again.step(.partial(Self.warm), at: 0.5)
        #expect(again.m.momentary.preview == p)
    }

    @Test func previewAtMostTwoHertz() throws {
        var run = ReducerRun(Listener())
        Self.speaking(&run)
        run.step(.partial(Self.warm), at: 0.5)
        let first = try #require(run.m.momentary.preview)
        run.step(.partial(Self.grim), at: 0.7)
        #expect(run.m.momentary.preview == first, "a partial 0.2 s later is not appraised")
        #expect(run.r.lastPreviewAt == Kit.t0.addingTimeInterval(0.5))
    }

    @Test func signFlipNeedsSixTenthsOfASecond() throws {
        var run = ReducerRun(Listener())
        Self.speaking(&run)
        run.step(.partial(Self.warm), at: 0.5)
        #expect((run.m.momentary.preview?.valence ?? 0) > 0)
        run.step(.partial(Self.grim), at: 1.0)
        #expect((run.m.momentary.preview?.valence ?? 0) > 0, "flip not yet held")
        run.step(.tick, at: 1.4)
        #expect((run.m.momentary.preview?.valence ?? 0) > 0, "0.4 s is not enough")
        run.step(.partial(Self.grim), at: 1.5)
        #expect((run.m.momentary.preview?.valence ?? 0) > 0, "0.5 s is not enough")
        run.step(.tick, at: 1.6)
        let p = try #require(run.m.momentary.preview)
        #expect(p.valence < 0, "held 0.6 s: the face follows")
        #expect(p.signSince == Kit.t0.addingTimeInterval(1.6))
    }

    @Test func flickerNeverFlips() {
        var run = ReducerRun(Listener())
        Self.speaking(&run)
        var t = 0.5
        for i in 0..<12 {
            run.step(.partial(i % 2 == 0 ? Self.warm : Self.grim), at: t)
            #expect((run.m.momentary.preview?.valence ?? 0) > 0, "one-partial flickers are held off (step \(i))")
            t += 0.5
        }
    }

    // MARK: Backchannels

    @Test func nodsAtAMidTurnPause() {
        var run = ReducerRun(Listener())
        Self.speaking(&run)
        Self.pause(&run, at: 2, turnEnd: 0.2, hesitation: 0.1)
        #expect(run.m.momentary.backchannel == .nod)
        #expect(run.m.momentary.mannerismRequests == [MannerismRequest(.mannerism(.nod), rank: .backchannel, owner: "Listener")])
        #expect(run.m.momentary.lastBackchannel == Kit.t0.addingTimeInterval(2))
        run.step(.tick, at: 2.3)
        #expect(run.m.momentary.backchannel == nil, "once per pause")
    }

    @Test func noBackchannelWhenTheTurnLooksOver() {
        var run = ReducerRun(Listener())
        Self.speaking(&run)
        Self.pause(&run, at: 2, turnEnd: 0.5, hesitation: 0)
        #expect(run.m.momentary.backchannel == nil)
    }

    @Test func noBackchannelBeforeOnePointFiveSecondsOfSpeech() {
        var run = ReducerRun(Listener())
        Self.speaking(&run)
        Self.pause(&run, at: 1.2, turnEnd: 0.1, hesitation: 0)
        #expect(run.m.momentary.backchannel == nil)
    }

    @Test func noBackchannelOutsideThePauseWindow() {
        var run = ReducerRun(Listener())
        Self.speaking(&run)
        // The pause began 0.5 s before this step: 0.2 + 0.5 = 0.7 s > 0.6 s.
        Self.pause(&run, at: 2.5, since: 2, turnEnd: 0.1, hesitation: 0)
        #expect(run.m.momentary.backchannel == nil)
    }

    @Test func backchannelRateZeroDisables() {
        var run = ReducerRun(Listener())
        run.m.ongoing.person = Kit.john
        var profile = SocialProfile()
        profile.backchannelRate = 0
        run.m.enduring.profiles[Kit.john] = profile
        Self.speaking(&run)
        Self.pause(&run, at: 2, turnEnd: 0.1, hesitation: 0)
        #expect(run.m.momentary.backchannel == nil)
    }

    @Test func gapScalesWithExtraversion() {
        let shy = Kit.snap(personality: [.extraversion: 0])
        let outgoing = Kit.snap(personality: [.extraversion: 1])
        let a = Listener.minGap(Kit.moment(mind: shy))
        let b = Listener.minGap(Kit.moment(mind: outgoing))
        #expect(a > b)
        let e0 = EmotionEngine.effective(shy.code.personality, age: shy.age)[.extraversion]
        #expect(abs(a - 3 / (0.5 + e0)) < 1e-9)
        var m = Kit.moment(mind: outgoing)
        m.ongoing.person = Kit.john
        var p = SocialProfile()
        p.backchannelRate = 2
        m.enduring.profiles[Kit.john] = p
        #expect(abs(Listener.minGap(m) - b / 2) < 1e-9, "backchannelRate scales the rate")
    }

    @Test func respectsTheMinimumGap() {
        var run = ReducerRun(Listener(), mind: Kit.snap(personality: [.extraversion: 0.5]))
        Self.speaking(&run)
        Self.pause(&run, at: 2, turnEnd: 0.1, hesitation: 0)
        #expect(run.m.momentary.backchannel == .nod)
        run.m.momentary.floor = .userSpeaking(since: Kit.t0)
        run.step(.partial("and then"), at: 2.4)
        Self.pause(&run, at: 3, turnEnd: 0.1, hesitation: 0)
        #expect(run.m.momentary.backchannel == nil, "1 s later is inside the gap")
        let gap = Listener.minGap(run.m)
        run.m.momentary.floor = .userSpeaking(since: Kit.t0)
        run.step(.partial("and then"), at: 3.4)
        Self.pause(&run, at: 2 + gap + 0.01, turnEnd: 0.1, hesitation: 0)
        #expect(run.m.momentary.backchannel == .nod)
    }

    /// §12.1: 60 s of synthetic speech → ≤ 15 backchannels, none at turnEnd ≥ 0.5.
    @Test func sixtySecondsOfSpeechAtMostFifteenAndNoneNearTurnEnd() {
        var run = ReducerRun(Listener(), mind: Kit.snap(personality: [.extraversion: 1]))
        var rng = Rand(seed: 99)
        Self.speaking(&run)
        var t = 0.0
        var count = 0
        while t < 60 {
            t += 0.4 + rng.unit() * 0.8
            run.m.momentary.floor = .userSpeaking(since: Kit.t0)
            run.step(.partial("blah"), at: t)
            t += 0.25
            let te = rng.unit()
            Self.pause(&run, at: t, turnEnd: te, hesitation: rng.unit() * 0.5)
            if run.m.momentary.backchannel != nil {
                count += 1
                #expect(te < 0.5, "never at turnEnd ≥ 0.5")
            }
            t += 0.2
            run.step(.tick, at: t)
            if run.m.momentary.backchannel != nil { count += 1 }
        }
        #expect(count <= 15)
        #expect(count >= 5, "it does nod (got \(count))")
    }

    @Test func mannerismChoice() {
        // Positive preview → contentSquint.
        var run = ReducerRun(Listener())
        Self.speaking(&run)
        run.m.momentary.preview = ListenPreview(valence: 0.45, intensity: 0.45, signSince: Kit.t0)
        Self.pause(&run, at: 2, turnEnd: 0.1, hesitation: 0)
        #expect(run.m.momentary.backchannel == .contentSquint)

        // Laughter within 1 s → giggle.
        var laugh = ReducerRun(Listener())
        Self.speaking(&laugh)
        laugh.m.momentary.floor = .userSpeaking(since: Kit.t0)
        laugh.step(.sound(label: "laughter", unexpected: false), at: 1.5)
        Self.pause(&laugh, at: 2, turnEnd: 0.1, hesitation: 0)
        #expect(laugh.m.momentary.backchannel == .giggle)

        // Laughter 2 s ago → a plain nod.
        var old = ReducerRun(Listener())
        Self.speaking(&old)
        old.m.momentary.floor = .userSpeaking(since: Kit.t0)
        old.step(.sound(label: "laughter", unexpected: false), at: 0.5)
        Self.pause(&old, at: 2.6, turnEnd: 0.1, hesitation: 0)
        #expect(old.m.momentary.backchannel == .nod)

        // A distress cue → a soft blink (deep, short lid softening), no mannerism.
        var sad = ReducerRun(Listener())
        sad.m.ongoing.hypotheses = [Hypothesis(kind: .mood, value: "sad", confidence: 0.6, expires: Kit.t0.addingTimeInterval(600))]
        Self.speaking(&sad)
        Self.pause(&sad, at: 2, turnEnd: 0.1, hesitation: 0)
        #expect(sad.m.momentary.backchannel == nil)
        #expect(Self.mine(sad.m, .lidSoften) == Listener.softBlinkDepth)
        #expect(sad.m.momentary.lastBackchannel == Kit.t0.addingTimeInterval(2))
        sad.step(.tick, at: 2.5)
        #expect(Self.mine(sad.m, .lidSoften) == nil, "the blink is short")
    }

    // MARK: Hesitation

    @Test func hesitationSoftensLidsHoldsNodsAndNeverSpeaks() {
        var run = ReducerRun(Listener())
        Self.speaking(&run)
        let fx = Self.pause(&run, at: 2, turnEnd: 0.1, hesitation: 0.7)
        #expect(fx.isEmpty, "Dee never speaks into a hesitation")
        #expect(run.m.momentary.beatRequests.map(\.kind) == [.listenHesitant])
        #expect(run.m.momentary.beatRequests.first?.owner == "Listener")
        #expect(Self.mine(run.m, .lidSoften) == Listener.hesitantLids)
        #expect(run.m.momentary.backchannel == nil)
        // The user goes on briefly and pauses again (not hesitant) within 1 s: no nod.
        run.m.momentary.floor = .userSpeaking(since: Kit.t0)
        run.step(.partial("um"), at: 2.3)
        #expect(Self.mine(run.m, .lidSoften) == nil, "speaking again: lids back")
        Self.pause(&run, at: 2.8, turnEnd: 0.1, hesitation: 0.2)
        #expect(run.m.momentary.backchannel == nil, "no nods for 1 s after a hesitation")
    }

    @Test func blinkAndTiltAfterThreeAndAHalfSecondsOfHesitantSilence() {
        var run = ReducerRun(Listener())
        Self.speaking(&run)
        Self.pause(&run, at: 2, turnEnd: 0.1, hesitation: 0.8)
        run.step(.tick, at: 5.0)
        #expect(Self.mine(run.m, .tilt) == nil)
        #expect(Self.mine(run.m, .lidSoften) == Listener.hesitantLids)
        run.step(.tick, at: 5.5)
        #expect(Self.mine(run.m, .tilt) == Listener.hesitantTilt)
        #expect(Self.mine(run.m, .lidSoften) == Listener.softBlinkDepth, "soft blink")
        let fx = run.step(.tick, at: 6.0)
        #expect(Self.mine(run.m, .tilt) == Listener.hesitantTilt, "tilt held")
        #expect(Self.mine(run.m, .lidSoften) == Listener.hesitantLids, "one blink")
        #expect(fx.isEmpty)
        #expect(run.m.momentary.beatRequests.count == 1, "one beat request per hesitant pause")
    }

    @Test func hesitationNoteOncePerHesitantTurn() {
        var run = ReducerRun(Listener())
        Self.speaking(&run)
        Self.pause(&run, at: 2, turnEnd: 0.1, hesitation: 0.7)
        run.m.momentary.floor = .idle
        run.step(Kit.heard("so I was thinking that"), at: 4, events: [.userFinished])
        #expect(run.m.ongoing.noteCandidates.map(\.kind) == [.hesitation])
        #expect(run.m.ongoing.noteCandidates.first?.owner == "Listener")
        run.m.ongoing.noteCandidates = []
        // A fluent turn: no note.
        run.m.momentary.floor = .userSpeaking(since: Kit.t0.addingTimeInterval(6))
        run.step(.partial("hi"), at: 6, events: [.userStarted])
        Self.pause(&run, at: 8, turnEnd: 0.9, hesitation: 0.1)
        run.m.momentary.floor = .idle
        run.step(Kit.heard("fine thanks"), at: 9, events: [.userFinished])
        #expect(run.m.ongoing.noteCandidates.isEmpty)
    }

    @Test func readyFaceWhenClearlyDone() {
        var run = ReducerRun(Listener())
        Self.speaking(&run)
        Self.pause(&run, at: 2, turnEnd: 0.8, hesitation: 0)
        #expect(abs((Self.mine(run.m, .readyFace) ?? 0) - 0.7) < 1e-9)
        #expect(run.m.momentary.faceRequests.first?.priority == .userTurn)
        Self.pause(&run, at: 2.2, since: 2, turnEnd: 0.5, hesitation: 0)
        #expect(Self.mine(run.m, .readyFace) == nil, "not below 0.6")
        Self.pause(&run, at: 2.4, since: 2, turnEnd: 0.9, hesitation: 0.7)
        #expect(Self.mine(run.m, .readyFace) == nil, "a hesitant pause is not a ready face")
    }

    // MARK: Silence after Dee's turn

    /// Dee says `line`, finishes speaking at `t`.
    static func deeLine(_ run: inout ReducerRun<Listener>, _ line: String, at t: Double) {
        run.m.momentary.floor = .deeSpeaking(since: Kit.t0.addingTimeInterval(t - 1))
        run.step(.deeSaid(tag: nil, sentence: line), at: t - 1, events: [.deeSentence])
        run.m.momentary.floor = .idle
        run.step(.speakingFinished, at: t, events: [.deeFinished])
    }

    @Test func pendingQuestionLooksBackAtSixAndLetsGoAtFourteen() {
        var run = ReducerRun(Listener())
        let aim = UUID(uuidString: "00000000-0000-4000-8000-0000000000A1")!
        run.step(.promptSubmitted, at: 0)
        run.issue(Note.intention(nextAction: "Ask about the gig.", intention: aim))
        Self.deeLine(&run, "How did the gig go?", at: 2)
        #expect(Self.signals(run.m, "silence").map(\.label) == ["pendingQuestion"])
        #expect(run.r.silenceClass == .pendingQuestion)
        run.step(.tick, at: 7.5)
        #expect(run.m.momentary.gazeRequests.isEmpty)
        run.step(.tick, at: 8.0)
        #expect(run.m.momentary.gazeRequests == [GazeRequest(.user, hold: 1, priority: .userTurn, owner: "Listener")])
        #expect(Self.mine(run.m, .tilt) == Listener.questionTilt)
        let fx = run.step(.tick, at: 16.0)
        #expect(fx.isEmpty, "no re-ask")
        #expect(Self.signals(run.m, "questionLetGo").map(\.id) == [aim])
        #expect(run.m.momentary.gazeRequests.isEmpty)
        #expect(run.r.silenceClass != .pendingQuestion)
        run.step(.tick, at: 20)
        #expect(Self.signals(run.m, "questionLetGo").isEmpty, "once")
    }

    @Test func comfortableSilence() {
        var run = ReducerRun(Listener(), mind: Kit.snap([.affection: 1, .trust: 1, .gratitude: 0.5]))
        #expect(run.m.ongoing.mind.regard > Listener.comfortableRegard)
        Self.deeLine(&run, "That sounds lovely.", at: 2)
        #expect(run.r.silenceClass == .comfortable)
        let s = Self.signals(run.m, "silence")
        #expect(s.map(\.label) == ["comfortable"])
        #expect(abs((s.first?.value ?? 0) - 1.3) < 1e-9, "curiosity gaps × (1 + silenceComfort)")
        run.step(.tick, at: 3)
        #expect(Self.signals(run.m, "silence").isEmpty, "only on change")
        // Away: no longer comfortable.
        run.step(.presence(arrived: false), at: 4)
        #expect(run.r.silenceClass == .plain)
    }

    @Test func notComfortableWithLowRegardOrAfterHesitation() {
        var cold = ReducerRun(Listener(), mind: Kit.snap([.affection: 0.1, .trust: 0.2]))
        Self.deeLine(&cold, "Okay.", at: 2)
        cold.step(.tick, at: 2.5)
        #expect(cold.r.silenceClass == .plain)

        var hes = ReducerRun(Listener(), mind: Kit.snap([.affection: 1, .trust: 1, .gratitude: 0.5]))
        Self.speaking(&hes)
        Self.pause(&hes, at: 2, turnEnd: 0.1, hesitation: 0.5)
        hes.m.momentary.floor = .idle
        hes.step(Kit.heard("well"), at: 3, events: [.userFinished])
        Self.deeLine(&hes, "Take your time.", at: 6)
        hes.step(.tick, at: 6.5)
        #expect(hes.r.silenceClass == .plain, "last hesitation ≥ 0.3")
    }

    @Test func awkwardSilenceRaisedOnceAndNeverFilled() {
        var run = ReducerRun(Listener())
        Self.deeLine(&run, "I think penguins are underrated.", at: 2)
        run.step(.head(yaw: 40, pitch: 0), at: 3)
        run.step(.tick, at: 5.5)
        #expect(Self.signals(run.m, "awkwardSilence").isEmpty, "only after 4 s without a reply")
        let fx = run.step(.tick, at: 6.0)
        #expect(fx.isEmpty, "the silence is not filled")
        #expect(Self.signals(run.m, "awkwardSilence").map(\.value) == [0.15])
        #expect(run.r.silenceClass == .awkward)
        run.step(.tick, at: 7)
        #expect(Self.signals(run.m, "awkwardSilence").isEmpty)
    }

    @Test func lookingAwayLaterIsNotAwkward() {
        var run = ReducerRun(Listener())
        Self.deeLine(&run, "Penguins.", at: 2)
        run.step(.head(yaw: 40, pitch: 0), at: 4.5)
        run.step(.tick, at: 7)
        #expect(Self.signals(run.m, "awkwardSilence").isEmpty)
    }

    @Test func aReplyEndsTheSilence() {
        var run = ReducerRun(Listener())
        Self.deeLine(&run, "Do you like jazz?", at: 2)
        run.m.momentary.floor = .userSpeaking(since: Kit.t0.addingTimeInterval(4))
        run.step(.partial("yes"), at: 4, events: [.userStarted])
        #expect(run.r.silenceStart == nil)
        run.m.momentary.floor = .idle
        run.step(.tick, at: 20, events: [])
        #expect(Self.signals(run.m, "questionLetGo").isEmpty)
    }

    @Test func silenceComfortLearning() {
        var run = ReducerRun(Listener())
        Self.deeLine(&run, "Nice.", at: 2)
        run.m.momentary.floor = .userSpeaking(since: Kit.t0.addingTimeInterval(14))
        run.step(.partial("so anyway"), at: 14, events: [.userStarted])
        run.m.momentary.floor = .idle
        run.step(Kit.heard("so anyway, about the trip"), at: 16, events: [.userFinished])
        #expect(Self.signals(run.m, "silenceComfort").map(\.value) == [0.05])

        var short = ReducerRun(Listener())
        Self.deeLine(&short, "Nice.", at: 2)
        short.m.momentary.floor = .userSpeaking(since: Kit.t0.addingTimeInterval(5))
        short.step(.partial("so"), at: 5, events: [.userStarted])
        short.m.momentary.floor = .idle
        short.step(Kit.heard("so anyway"), at: 6, events: [.userFinished])
        #expect(Self.signals(short.m, "silenceComfort").isEmpty, "a short silence teaches nothing")

        var hello = ReducerRun(Listener())
        hello.step(Kit.heard("hello?"), at: 30, events: [.userStarted, .userFinished])
        #expect(Self.signals(hello.m, "silenceComfort").map(\.value) == [-0.05])
    }

    @Test func checkingInPatterns() {
        for s in ["hello?", "Hellooo", "are you there?", "Dee, are you there?", "still there?", "hello hello"] {
            #expect(Listener.isCheckingIn(s), "\(s)")
        }
        for s in ["hello, how are you today", "hello", "there is a cat", "I was there yesterday"] {
            #expect(!Listener.isCheckingIn(s), "\(s)")
        }
    }

    @Test func conversationStartedResets() {
        var run = ReducerRun(Listener())
        Self.deeLine(&run, "How was it?", at: 2)
        run.step(.conversationStarted(Kit.t0.addingTimeInterval(3)), at: 3)
        #expect(run.r.silenceStart == nil)
        #expect(run.r.silenceClass == .none)
        #expect(run.r.issuedAim == nil)
        run.step(.tick, at: 20)
        #expect(Self.signals(run.m, "questionLetGo").isEmpty)
    }

    @Test func determinism() {
        func trace() -> [String] {
            var run = ReducerRun(FloorThenListener())
            var out: [String] = []
            for (t, p) in Self.timeline { out.append("\(run.step(p, at: t).map(\.traceName)) \(FloorThenListener.slice(of: run.m).sorted { $0.key < $1.key })") }
            return out
        }
        #expect(trace() == trace())
    }

    // MARK: With the real FloorKeeper (scenario 10, coordinated listening)

    static let timeline: [(Double, Percept)] = [
        (0.0, .partial("so yesterday I went to")), (0.5, .partial("so yesterday I went to the market")),
        (1.0, .partial("so yesterday I went to the market and it was lovely")), (2.0, .pause(turnEnd: 0.2, hesitation: 0.1)),
        (2.5, .partial("so yesterday I went to the market and it was lovely and then")), (3.0, .pause(turnEnd: 0.1, hesitation: 0.7)),
        (3.5, .tick), (4.0, .tick), (6.5, .tick), (7.0, .partial("I found a lamp")), (8.0, .pause(turnEnd: 0.85, hesitation: 0)),
        (8.4, .heard(text: "I found a lamp", durationS: 8, loudnessVsBaseline: 0, appraisal: Appraisal())),
        (8.5, .promptSubmitted), (9.5, .speakingStarted), (9.6, .deeSaid(tag: .curious, sentence: "Ooh, what kind of lamp?")),
        (11.0, .speakingFinished), (13.0, .tick), (17.0, .tick), (17.5, .tick), (25.5, .tick),
    ]

    @Test func hesitantFragmentWithTheRealFloor() {
        var run = ReducerRun(FloorThenListener())
        var effects: [Effect] = []
        var nods: [Double] = []
        var lids: [Double] = []
        var ready: [Double] = []
        for (t, p) in Self.timeline {
            effects += run.step(p, at: t)
            if run.m.momentary.backchannel != nil { nods.append(t) }
            if Self.mine(run.m, .lidSoften) != nil { lids.append(t) }
            if Self.mine(run.m, .readyFace) != nil { ready.append(t) }
            if t == 3.0 { #expect(run.m.momentary.beatRequests.map(\.kind) == [.listenHesitant]) }
        }
        #expect(nods == [2.0], "a nod at the fluent pause only")
        #expect(lids.contains(3.0) && lids.contains(6.5))
        #expect(ready == [8.0])
        #expect(!effects.contains { if case .say = $0 { true } else { false } }, "no speech into the hesitation")
        #expect(run.m.ongoing.noteCandidates.map(\.kind) == [.hesitation])
    }

    @Test func goldenListeningTurn() throws {
        try Golden.verify(Golden.record(FloorThenListener(), name: "listening-turn",
                                        mind: Kit.snap([.affection: 1, .trust: 1, .gratitude: 0.5]),
                                        Self.timeline.map { Cue(t: $0.0, p: $0.1) }))
    }

    @Test func goldenSilences() throws {
        try Golden.verify(Golden.record(FloorThenListener(), name: "silences", [
            Cue(t: 0, p: .promptSubmitted), Cue(t: 1, p: .speakingStarted),
            Cue(t: 1.2, p: .deeSaid(tag: nil, sentence: "Did you finish the painting?")), Cue(t: 2, p: .speakingFinished),
            Cue(t: 4, p: .tick), Cue(t: 8, p: .tick), Cue(t: 12, p: .tick), Cue(t: 16, p: .tick), Cue(t: 16.5, p: .tick),
            Cue(t: 20, p: .promptSubmitted), Cue(t: 21, p: .speakingStarted),
            Cue(t: 21.2, p: .deeSaid(tag: nil, sentence: "Penguins are great.")), Cue(t: 22, p: .speakingFinished),
            Cue(t: 23, p: .head(yaw: 45, pitch: 0)), Cue(t: 25, p: .tick), Cue(t: 26.5, p: .tick),
            Cue(t: 40, p: .partial("hello")), Cue(t: 40.5, p: .heard(text: "hello?", durationS: 0.5, loudnessVsBaseline: 0, appraisal: Appraisal())),
        ]))
    }

    /// Integration: the preview runs the lexicon-only appraiser (no sentiment model per
    /// partial), so everyday tone words carry the preview face.
    @Test func previewToneWords() {
        #expect(Listener.previewTone("and it was lovely") > 0.3)
        #expect(Listener.previewTone("it was awful") < -0.3)
        #expect(Listener.previewTone("it was not good") < 0)
        #expect(Listener.previewTone("I found a lamp") == 0)
        #expect(abs(Listener.previewTone("great great great amazing wonderful")) <= 0.6)
    }
}
