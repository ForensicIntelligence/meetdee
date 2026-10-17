import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// Learner (SELF.md §7.7, §7.9). Owner: Learner. Goldens: `Fixtures/Learner/`.
@Suite struct LearnerTests {
    static let day = 86_400.0

    static func run(person: PersonID? = Kit.john, mind: MindSnapshot = Kit.snap(), seed: UInt64 = 1) -> ReducerRun<Learner> {
        var r = ReducerRun(Learner(), mind: mind, seed: seed)
        r.m.ongoing.person = person
        return r
    }

    static func topic(_ words: String...) -> [Subject] { words.compactMap(Subject.init) }

    static func persisted(_ fx: [Effect]) -> [SelfWrite] {
        fx.compactMap { if case .persist(let w) = $0 { w } else { nil } }
    }

    static func appraisal(valence: Double = 0, humor: Double = 0, hostility: Double = 0, novelty: Double = 0.5) -> Appraisal {
        var a = Appraisal()
        a.valence = valence
        a.humor = humor
        a.hostility = hostility
        a.novelty = novelty
        return a
    }

    /// A Dee turn (one sentence + finish) ending at `t`.
    /// Dee's reply: `sentences` sentences tagged `tag` (a reply is a joke at ≥ 2 playful ones).
    static func deeTurn(_ run: inout ReducerRun<Learner>, at t: Double, tag: Emotion? = nil, text: String = "Okay.", sentences: Int = 2) {
        for k in 0..<sentences { run.step(.deeSaid(tag: tag, sentence: text), at: t - 1 + 0.1 * Double(k)) }
        run.step(.deeTurnFinished(text: text), at: t)
    }

    // MARK: - Hooks (0.5.1 behaviour kept)

    @Test func idleReduceChangesNothingLearnt() {
        var run = Self.run(person: nil)
        let before = run.m
        #expect(run.step(.tick, at: 0).isEmpty)
        #expect(run.m.enduring == before.enduring && run.m.ongoing.interests == before.ongoing.interests)
    }

    /// Review finding 1: a reveal stamps `revealedAt` once ever and persists it.
    @Test func tasteRevealStampsTheFacetOnce() {
        var run = ReducerRun(Learner())
        let f = Facet(id: UUID(), kind: .taste, subject: Subject("rain sounds")!, innate: 0.5, evidence: 3, crystallised: true,
                      source: .heuristic, updatedAt: Kit.t0)
        run.m.enduring.facets = [f]
        run.m.now = Kit.t0.addingTimeInterval(9)
        let fx = run.issue(.tasteReveal(f.subject, loves: true, facet: f.id))
        #expect(run.m.ongoing.revealedThisConversation)
        #expect(run.m.enduring.facets[0].revealedAt == Kit.t0.addingTimeInterval(9))
        #expect(fx == [.persist(.facet(run.m.enduring.facets[0]))])
        run.m.now = Kit.t0.addingTimeInterval(99)
        #expect(run.issue(.tasteReveal(f.subject, loves: true, facet: f.id)).isEmpty, "revealed once, ever")
        #expect(run.m.enduring.facets[0].revealedAt == Kit.t0.addingTimeInterval(9))
        run.step(.conversationStarted(Kit.t0), at: 100)
        #expect(!run.m.ongoing.revealedThisConversation)
    }

    @Test func gagCallbackCountsUsesAndRetiresAtSix() {
        var run = ReducerRun(Learner())
        let g = Gag(id: UUID(), person: Kit.john, topic: Subject("toast")!, hookTemplate: 1)
        run.m.enduring.gags = [g]
        run.m.now = Kit.t0.addingTimeInterval(3)
        let fx = run.issue(.gagCallback(g.topic, style: .deadpan, gag: g.id))
        #expect(run.m.enduring.gags[0].uses == 1 && run.m.enduring.gags[0].lastUsed == Kit.t0.addingTimeInterval(3))
        #expect(fx.map(\.traceName) == ["persist(gag)"])
        for _ in 0..<5 { run.issue(.gagCallback(g.topic, style: .deadpan, gag: g.id)) }
        #expect(run.m.enduring.gags[0].uses == 6 && run.m.enduring.gags[0].retired)
    }

    @Test func seedsInterestsAndMisreads() {
        var run = ReducerRun(Learner())
        let i = Interest(subject: Subject("watercolor")!, weight: 0.6, lastTouched: Kit.t0)
        let r = Misread(id: UUID(), person: Kit.john, at: Kit.t0, situation: .moodGuess)
        run.r.seed(from: Carried(interests: [i], misreads: [r]), &run.m)
        #expect(run.m.ongoing.interests == [i] && run.m.ongoing.recentMisreads == [r])
        // A carried misread is not recorded a second time when it shows up again.
        run.m.ongoing.misreadThisTurn = r
        #expect(Self.persisted(run.step(.tick, at: 1)).isEmpty)
    }

    // MARK: - Misreads → lessons (§7.7)

    @Test func misreadIsRecordedOnceWithoutItsGuess() {
        var run = Self.run()
        let r = Misread(id: UUID(), person: Kit.john, at: Kit.t0, situation: .moodGuess, topic: Subject("work"), wrongGuess: "sad")
        run.m.ongoing.misreadThisTurn = r
        let fx = run.step(.tick, at: 1)
        var stored = r
        stored.wrongGuess = nil
        #expect(Self.persisted(fx).contains(.misread(stored)))
        #expect(run.m.ongoing.recentMisreads == [stored])
        #expect(run.m.enduring.profiles[Kit.john]?.moodInferenceGain == 0.85)
        #expect(Self.persisted(run.step(.tick, at: 2)).isEmpty, "same misread, still in misreadThisTurn: once")
        #expect(run.m.enduring.lessons.isEmpty, "one misread is not a lesson")
    }

    @Test func twoMisreadsWithinFourteenDaysMintALesson() {
        var run = Self.run()
        run.m.ongoing.misreadThisTurn = Misread(id: UUID(), person: Kit.john, at: Kit.t0, situation: .moodGuess)
        run.step(.tick, at: 0)
        run.m.ongoing.misreadThisTurn = Misread(id: UUID(), person: Kit.john, at: Kit.t0.addingTimeInterval(3 * Self.day), situation: .moodGuess)
        let fx = run.step(.tick, at: 3 * Self.day)
        #expect(run.m.enduring.lessons.count == 1)
        let l = run.m.enduring.lessons[0]
        #expect(l.situation == .moodGuess && l.person == Kit.john && l.evidence == 2 && l.doInstead == Lesson.Situation.moodGuess.doInstead)
        #expect(Self.persisted(fx).contains(.lesson(l)))
        #expect(abs((run.m.enduring.profiles[Kit.john]?.moodInferenceGain ?? 0) - 0.7225) < 1e-9)
        #expect(Learner.hypothesisNoteFactor(run.m) == 0.6, "D6: the note gate moves before any words do")
        // A further hit adds evidence.
        run.m.ongoing.misreadThisTurn = Misread(id: UUID(), person: Kit.john, at: Kit.t0.addingTimeInterval(4 * Self.day), situation: .moodGuess)
        run.step(.tick, at: 4 * Self.day)
        #expect(run.m.enduring.lessons[0].evidence == 3)
    }

    @Test func noLessonAcrossSituationsPeopleOrBeyondFourteenDays() {
        var run = Self.run()
        run.m.ongoing.misreadThisTurn = Misread(id: UUID(), person: Kit.john, at: Kit.t0, situation: .moodGuess)
        run.step(.tick, at: 0)
        run.m.ongoing.misreadThisTurn = Misread(id: UUID(), person: Kit.john, at: Kit.t0.addingTimeInterval(60), situation: .tookLiterally)
        run.step(.tick, at: 60)
        run.m.ongoing.person = Kit.ann
        run.m.ongoing.misreadThisTurn = Misread(id: UUID(), person: Kit.ann, at: Kit.t0.addingTimeInterval(120), situation: .moodGuess)
        run.step(.tick, at: 120)
        #expect(run.m.enduring.lessons.isEmpty)
        run.m.ongoing.person = Kit.john
        run.m.ongoing.misreadThisTurn = Misread(id: UUID(), person: Kit.john, at: Kit.t0.addingTimeInterval(15 * Self.day), situation: .moodGuess)
        run.step(.tick, at: 15 * Self.day)
        #expect(run.m.enduring.lessons.isEmpty, "the first one is older than 14 days")
        #expect(run.m.ongoing.recentMisreads.allSatisfy { Kit.t0.addingTimeInterval(15 * Self.day).timeIntervalSince($0.at) <= Learner.misreadWindow })
    }

    @Test func unknownPeopleNeverLearn() {
        var run = Self.run(person: nil)
        for d in 0..<3 {
            run.m.ongoing.misreadThisTurn = Misread(id: UUID(), person: nil, at: Kit.t0.addingTimeInterval(Double(d) * Self.day), situation: .moodGuess)
            run.step(.tick, at: Double(d) * Self.day)
        }
        run.step(Kit.heard("hi", Self.appraisal(valence: 0.8)), at: 3 * Self.day)
        #expect(run.m.enduring.lessons.isEmpty && run.m.enduring.profiles.isEmpty)
        #expect(run.m.ongoing.recentMisreads.count == 3, "still recorded (global), just not learnt per person")
    }

    @Test func misreadSignalFromAnotherReducer() {
        var run = Self.run()
        // Raised by a reducer later in the pipeline on the previous step (an earlier one is seen the same step).
        run.m.signal("misread", subject: Subject("guitar"), id: UUID(), label: "wrongReferent", by: Learner.name)
        let fx = run.step(.tick, at: 1)
        #expect(run.m.ongoing.recentMisreads.map(\.situation) == [.wrongReferent])
        #expect(run.m.ongoing.recentMisreads.first?.topic == Subject("guitar"))
        #expect(fx.map(\.traceName).filter { $0 == "persist(misread)" }.count == 1)
    }

    @Test func deeInterruptingRaisesPauseScaleAndMintsInterruptedThem() {
        var run = Self.run()
        let fx = run.step(.partial("so"), at: 1, events: [.deeInterrupted])
        #expect(fx.contains(.setPauseScale(1.1)))
        #expect(run.m.enduring.profiles[Kit.john]?.pauseScale == 1.1)
        #expect(run.m.ongoing.recentMisreads.map(\.situation) == [.interruptedThem])
        run.step(.partial("um"), at: 10, events: [.deeInterrupted])
        #expect(run.m.ongoing.recentMisreads.count == 1, "within 30 s: the same misunderstanding")
        run.step(.partial("and"), at: 100, events: [.deeInterrupted])
        #expect(run.m.enduring.lessons.map(\.situation) == [.interruptedThem])
        #expect(abs((run.m.enduring.profiles[Kit.john]?.pauseScale ?? 0) - 1.2) < 1e-9)
    }

    @Test func playfulReplyAnsweredFlatIsAJokeFlop() {
        var run = Self.run()
        Self.deeTurn(&run, at: 10, tag: .playful)
        let fx = run.step(Kit.heard("ugh, no", Self.appraisal(valence: -0.4)), at: 14)
        #expect(run.m.ongoing.recentMisreads.map(\.situation) == [.jokeFlopped])
        #expect(abs((run.m.enduring.profiles[Kit.john]?.humorReceptiveness ?? 0) - 0.425) < 1e-9)
        #expect(Self.persisted(fx).contains { $0.name == "misread" })
        // A laughing answer to the next playful reply moves the EWMA up.
        Self.deeTurn(&run, at: 40, tag: .mischievous)
        run.step(Kit.heard("haha", Self.appraisal(valence: 0.5, humor: 0.8)), at: 42)
        #expect(abs((run.m.enduring.profiles[Kit.john]?.humorReceptiveness ?? 0) - (0.85 * 0.425 + 0.15)) < 1e-9)
        #expect(run.m.ongoing.recentMisreads.count == 1)
        // A non-playful reply never counts.
        Self.deeTurn(&run, at: 80, tag: .neutral)
        run.step(Kit.heard("ok", Self.appraisal(valence: -0.4)), at: 82)
        #expect(run.m.ongoing.recentMisreads.count == 1)
    }

    /// Review finding 2: a neutral answer to a joke is no evidence (no misread, no EWMA
    /// step), and one playful sentence does not make a reply a joke.
    @Test func neutralReplyToAJokeIsNoEvidence() {
        var run = Self.run()
        Self.deeTurn(&run, at: 10, tag: .playful)
        run.step(Kit.heard("yeah so anyway", Self.appraisal(valence: 0)), at: 14)
        #expect(run.m.ongoing.recentMisreads.isEmpty)
        #expect(run.m.enduring.profiles[Kit.john]?.humorReceptiveness ?? 0.5 == 0.5)
        Self.deeTurn(&run, at: 40, tag: .playful, sentences: 1)
        run.step(Kit.heard("ugh, no", Self.appraisal(valence: -0.5)), at: 44)
        #expect(run.m.ongoing.recentMisreads.isEmpty, "one playful sentence is not a joke")
        Self.deeTurn(&run, at: 80, tag: .playful)
        run.step(Kit.heard("that's not funny"), at: 84)
        #expect(run.m.ongoing.recentMisreads.map(\.situation) == [.jokeFlopped], "\"not funny\" is clear")
    }

    @Test func busyAfterHerQuestionIsAskedTooMuch() {
        var run = Self.run()
        Self.deeTurn(&run, at: 10, text: "What are you working on?")
        run.m.ongoing.hypotheses = [Hypothesis(kind: .busy, value: "busy", confidence: 0.6, expires: Kit.t0.addingTimeInterval(600))]
        run.step(.tick, at: 20)
        #expect(run.m.ongoing.recentMisreads.map(\.situation) == [.askedTooMuch])
        // Without a question first, busy is just busy.
        var quiet = Self.run()
        Self.deeTurn(&quiet, at: 10, text: "Nice.")
        quiet.m.ongoing.hypotheses = [Hypothesis(kind: .busy, value: "busy", confidence: 0.6, expires: Kit.t0.addingTimeInterval(600))]
        quiet.step(.tick, at: 20)
        #expect(quiet.m.ongoing.recentMisreads.isEmpty)
    }

    @Test func confirmedMoodGuessRaisesTheGain() {
        var run = Self.run()
        run.m.enduring.profiles[Kit.john] = { var p = SocialProfile(); p.moodInferenceGain = 0.7; return p }()
        run.m.ongoing.hypotheses = [Hypothesis(kind: .mood, value: "tired", confidence: 0.5, expires: Kit.t0.addingTimeInterval(1200))]
        run.step(.tick, at: 1)
        run.m.ongoing.hypotheses = [Hypothesis(kind: .mood, value: "tired", confidence: 1, stated: true, expires: Kit.t0.addingTimeInterval(1800))]
        run.step(.tick, at: 2)
        #expect(abs((run.m.enduring.profiles[Kit.john]?.moodInferenceGain ?? 0) - 0.72) < 1e-9)
        // Capped at 1.
        run.m.enduring.profiles[Kit.john]?.moodInferenceGain = 0.99
        run.m.signal("moodConfirmed", by: Learner.name)
        run.step(.tick, at: 3)
        #expect(run.m.enduring.profiles[Kit.john]?.moodInferenceGain == 1)
    }

    @Test func gainHasAFloor() {
        var run = Self.run()
        for i in 0..<12 {
            run.m.ongoing.misreadThisTurn = Misread(id: UUID(), person: Kit.john, at: Kit.t0.addingTimeInterval(Double(i) * 100), situation: .moodGuess)
            run.step(.tick, at: Double(i) * 100)
        }
        #expect(run.m.enduring.profiles[Kit.john]?.moodInferenceGain == Learner.gainFloor)
    }

    // MARK: - Lesson notes and published parameters

    static func withLesson(_ s: Lesson.Situation, person: PersonID? = Kit.john) -> ReducerRun<Learner> {
        var run = Self.run(person: person)
        run.m.enduring.lessons = [Lesson(id: UUID(), person: Kit.john, situation: s, createdAt: Kit.t0)]
        return run
    }

    @Test func moodGuessLessonNoteWhenAGuessRecursOncePerConversation() {
        var run = Self.withLesson(.moodGuess)
        run.m.ongoing.hypotheses = [Hypothesis(kind: .mood, value: "sad", confidence: 0.45, expires: Kit.t0.addingTimeInterval(1200))]
        run.step(.tick, at: 1)
        #expect(run.m.ongoing.noteCandidates == [Note(.lesson, slots: [Lesson.Situation.moodGuess.doInstead], owner: Learner.name)])
        #expect(run.m.ongoing.noteCandidates[0].text == "(Careful: ask how they feel, not guess.)")
        let fx = run.issue(run.m.ongoing.noteCandidates[0])
        #expect(run.m.enduring.lessons[0].lastApplied == run.m.now)
        #expect(fx == [.persist(.lesson(run.m.enduring.lessons[0]))])
        run.m.ongoing.noteCandidates = []
        run.m.ongoing.hypotheses = [Hypothesis(kind: .mood, value: "tired", confidence: 0.45, expires: Kit.t0.addingTimeInterval(1200))]
        run.step(.tick, at: 2)
        #expect(run.m.ongoing.noteCandidates.isEmpty, "once per conversation")
        run.step(.conversationStarted(Kit.t0.addingTimeInterval(3)), at: 3)
        run.m.ongoing.hypotheses = [Hypothesis(kind: .mood, value: "stressed", confidence: 0.45, expires: Kit.t0.addingTimeInterval(1200))]
        run.step(.tick, at: 4)
        #expect(run.m.ongoing.noteCandidates.map(\.kind) == [.lesson])
    }

    @Test func noLessonNoteForSomeoneElse() {
        var run = Self.withLesson(.moodGuess, person: Kit.ann)
        run.m.ongoing.hypotheses = [Hypothesis(kind: .mood, value: "sad", confidence: 0.45, expires: Kit.t0.addingTimeInterval(1200))]
        run.step(.tick, at: 1)
        #expect(run.m.ongoing.noteCandidates.isEmpty)
        #expect(Learner.hypothesisNoteFactor(run.m) == 0.5)
    }

    @Test func tookLiterallyNoteOnATease() {
        var run = Self.withLesson(.tookLiterally)
        run.step(Kit.heard("you're useless lol", Self.appraisal(valence: -0.2, humor: 0.5, hostility: 0.4)), at: 1)
        #expect(run.m.ongoing.noteCandidates.first?.text == "(Careful: check if they're joking.)")
        #expect(Learner.hostilitySoftening(run.m) == 0.5)
    }

    @Test func wrongReferentNoteFollowsADeixisNote() {
        var run = Self.withLesson(.wrongReferent)
        run.m.ongoing.raise(.deixisAmbiguous(Subject("cup")!, Subject("mug")!), by: Attention.name)
        run.step(.tick, at: 1)
        #expect(run.m.ongoing.noteCandidates.map(\.kind) == [.deixisAmbiguous, .lesson])
        #expect(Learner.deixisResolvedThreshold(run.m) == 0.65)
    }

    @Test func jokeFloppedLessonKeepsItLowKeyAndRaisesTheGate() {
        var run = Self.withLesson(.jokeFlopped)
        run.step(Kit.heard("hey", Self.appraisal(valence: 0.3)), at: 1, mind: Kit.snap().with(seq: 1, reflex: .playful))
        #expect(run.m.ongoing.noteCandidates.first?.text == "(Careful: keep jokes low-key.)")
        #expect(Learner.playGateThreshold(run.m) == 0.4)
    }

    @Test func lowReceptivenessWithHighPlayfulnessKeepsItLowKeyWithoutALesson() {
        var run = Self.run(mind: Kit.snap(personality: [.playfulness: 0.95]))
        run.m.enduring.profiles[Kit.john] = { var p = SocialProfile(); p.humorReceptiveness = 0.2; return p }()
        run.step(Kit.heard("hey"), at: 1, mind: Kit.snap(personality: [.playfulness: 0.95]).with(seq: 1, reflex: .giddy))
        #expect(run.m.ongoing.noteCandidates.map(\.slots) == [["keep jokes low-key"]])
    }

    @Test func askedTooMuchPublishesThresholdsOnly() {
        let run = Self.withLesson(.askedTooMuch)
        #expect(Learner.initiativeThresholdBoost(run.m) == 0.1 && Learner.curiosityGapScale(run.m) == 1.3)
        let none = Self.run()
        #expect(Learner.initiativeThresholdBoost(none.m) == 0 && Learner.curiosityGapScale(none.m) == 1)
    }

    @Test func quietLessonsDecayEveryFiveConversationsAndRetire() {
        var run = Self.withLesson(.tookLiterally)
        let id = run.m.enduring.lessons[0].id
        var deleted = false
        for c in 1...10 {
            let fx = run.step(.conversationStarted(Kit.t0.addingTimeInterval(Double(c) * 3600)), at: Double(c) * 3600)
            if c == 5 { #expect(run.m.enduring.lessons.first?.evidence == 1) }
            if Self.persisted(fx).contains(.deleteLesson(id)) { deleted = true }
            run.step(.identified(Kit.john, distance: 0.2), at: Double(c) * 3600 + 1)
        }
        #expect(deleted && run.m.enduring.lessons.isEmpty)
    }

    @Test func aRecurringLessonDoesNotDecay() {
        var run = Self.withLesson(.tookLiterally)
        for c in 1...6 {
            run.step(Kit.heard("lol", Self.appraisal(hostility: 0.3)), at: Double(c) * 3600 - 10)
            run.step(.conversationStarted(Kit.t0.addingTimeInterval(Double(c) * 3600)), at: Double(c) * 3600)
        }
        #expect(run.m.enduring.lessons.first?.evidence == 2)
    }

    // MARK: - Profiles

    @Test func pauseObservationsShrinkTowardOne() {
        var p = SocialProfile()
        p = Learner.observePause(p, median: 1.0)          // x = 1.6 (clamped 2.0)
        #expect(p.pauseN == 1 && abs(p.pauseScale - (1.6 + 10) / 11) < 1e-9)
        for _ in 0..<200 { p = Learner.observePause(p, median: 0.75) }   // x = 1.5
        #expect(p.pauseScale > 1.45 && p.pauseScale <= 1.5)
        var q = SocialProfile()
        for _ in 0..<200 { q = Learner.observePause(q, median: 0.1) }
        #expect(q.pauseScale >= Learner.pauseRange.lowerBound && q.pauseScale < 0.75)
    }

    @Test func withinTurnPausesUpdateThePauseScale() {
        var run = Self.run()
        run.step(.partial("so"), at: 0)
        run.step(.pause(turnEnd: 0.2, hesitation: 0.4), at: 1)
        run.step(.partial("so I was"), at: 2)            // 1 s within-turn pause
        let fx = run.step(Kit.heard("so I was thinking"), at: 3)
        let s = run.m.enduring.profiles[Kit.john]?.pauseScale ?? 0
        #expect(abs(s - (1.6 + 10) / 11) < 1e-9)
        #expect(fx.contains(.setPauseScale(s)))
    }

    @Test func pauseScaleIsPushedWhenThePersonChanges() {
        var run = Self.run(person: nil)
        run.m.enduring.profiles[Kit.ann] = { var p = SocialProfile(); p.pauseScale = 1.3; return p }()
        run.m.ongoing.person = Kit.ann
        #expect(run.step(.identified(Kit.ann, distance: 0.2), at: 1).contains(.setPauseScale(1.3)))
        #expect(!run.step(.tick, at: 2).contains { if case .setPauseScale = $0 { true } else { false } })
        run.m.ongoing.person = nil
        #expect(run.step(.tick, at: 3).contains(.setPauseScale(1.0)))
    }

    @Test func silenceComfortLearnsFromWhoBreaksTheSilence() {
        var run = Self.run()
        Self.deeTurn(&run, at: 10)
        run.step(Kit.heard("anyway, about dinner", Self.appraisal(novelty: 0.8)), at: 23.5)   // started at 22: 12 s later
        #expect(abs((run.m.enduring.profiles[Kit.john]?.silenceComfort ?? 0) - 0.35) < 1e-9)
        Self.deeTurn(&run, at: 40)
        run.step(Kit.heard("Hello?"), at: 47.5)
        #expect(abs((run.m.enduring.profiles[Kit.john]?.silenceComfort ?? 0) - 0.30) < 1e-9)
        run.step(Kit.heard("and another thing", Self.appraisal(novelty: 0.9)), at: 90)
        #expect(abs((run.m.enduring.profiles[Kit.john]?.silenceComfort ?? 0) - 0.30) < 1e-9, "the user's own pauses don't count")
        #expect(Learner.tasteSubject("laughter") == nil && Learner.tasteSubject("giggling") == nil, "never a taste")
    }

    @Test func kindnessIsAnEWMAOfTurnValence() {
        var run = Self.run()
        run.step(Kit.heard("great", Self.appraisal(valence: 1)), at: 1)
        run.step(Kit.heard("great", Self.appraisal(valence: 1)), at: 2)
        #expect(abs((run.m.enduring.profiles[Kit.john]?.kindnessEMA ?? 0) - 0.19) < 1e-9)
    }

    @Test func profileWritesAreThrottledAndFlushed() {
        var run = Self.run()
        let a = run.step(Kit.heard("a", Self.appraisal(valence: 0.5)), at: 1)
        #expect(Self.persisted(a).map(\.name).contains("profile"))
        let b = run.step(Kit.heard("b", Self.appraisal(valence: 0.5)), at: 30)
        #expect(Self.persisted(b).isEmpty, "at most every 60 s")
        let c = run.step(.tick, at: 62)
        #expect(Self.persisted(c) == [.profile(Kit.john, run.m.enduring.profiles[Kit.john]!)])
        run.step(Kit.heard("c", Self.appraisal(valence: 0.5)), at: 70)
        let f = run.r.flush(&run.m)
        #expect(f == [.persist(.profile(Kit.john, run.m.enduring.profiles[Kit.john]!))])
        #expect(run.r.flush(&run.m).isEmpty)
    }

    // MARK: - Interests

    @Test func interestsGrowPerConversationAndHalveInAWeek() {
        var run = Self.run()
        let curiosity = run.m.ongoing.mind.mood.curiosity
        run.m.ongoing.topic = Self.topic("guitar")
        let fx = run.step(Kit.heard("I play guitar"), at: 1)
        #expect(run.m.ongoing.interests.count == 1)
        #expect(abs(run.m.ongoing.interests[0].weight - 0.2 * curiosity) < 1e-9)
        #expect(Self.persisted(fx).contains(.interest(run.m.ongoing.interests[0])))
        run.step(Kit.heard("guitar again"), at: 2)
        #expect(abs(run.m.ongoing.interests[0].weight - 0.2 * curiosity) < 1e-9, "once per conversation")
        let i = run.m.ongoing.interests[0]
        #expect(abs(Learner.interestWeight(i, at: i.lastTouched.addingTimeInterval(7 * Self.day)) - i.weight / 2) < 1e-9)
        run.step(.conversationStarted(Kit.t0.addingTimeInterval(7 * Self.day)), at: 7 * Self.day)
        run.m.ongoing.topic = Self.topic("guitar")
        run.step(Kit.heard("guitar"), at: 7 * Self.day + 1)
        #expect(abs(run.m.ongoing.interests[0].weight - (i.weight * pow(0.5, (7 * Self.day + 1 - 1) / (7 * Self.day)) + 0.2 * curiosity)) < 1e-6)
    }

    @Test func interestsAreCappedAtTwenty() {
        var run = Self.run()
        for k in 0..<25 {
            run.m.ongoing.topic = [Subject("thing\(k)")!]
            run.step(Kit.heard("x"), at: Double(k))
        }
        #expect(run.m.ongoing.interests.count == Ongoing.maxInterests)
        #expect(!run.m.ongoing.interests.contains { $0.subject.text == "thing0" }, "the weakest (oldest) goes")
    }

    // MARK: - Tastes (§7.9)

    static func facet(innate: Double) -> Facet {
        Facet(id: UUID(), kind: .taste, subject: Subject("rain")!, innate: innate, source: .heuristic, updatedAt: Kit.t0)
    }

    @Test func tastesCrystalliseAtThreeStrongExposures() {
        var f = Self.facet(innate: 0.6)
        f = Learner.applyExposure(f, valence: 0.8)
        f = Learner.applyExposure(f, valence: 0.8)
        #expect(!f.crystallised && f.evidence == 2)
        f = Learner.applyExposure(f, valence: 0.8)
        #expect(f.crystallised && f.evidence == 3 && f.polarity >= 0.35)
        #expect(f.reason == "no idea why, you just do")
        var weak = Self.facet(innate: 0)
        for _ in 0..<3 { weak = Learner.applyExposure(weak, valence: 0.25) }
        #expect(!weak.crystallised, "|polarity| < 0.35")
        var learnt = Self.facet(innate: 0)
        for _ in 0..<8 { learnt = Learner.applyExposure(learnt, valence: -1) }
        #expect(learnt.crystallised && learnt.polarity < -0.35 && learnt.reason == "it has gone badly before")
    }

    @Test func aCrystallisedTasteFlipsOnlyAfterThreeContraryExposures() {
        var f = Self.facet(innate: 0.1)
        for _ in 0..<4 { f = Learner.applyExposure(f, valence: 0.9) }
        #expect(f.crystallised && f.polarity > 0)
        f.revealedAt = Kit.t0
        var flips = 0
        for k in 1...12 {
            let before = f.polarity
            f = Learner.applyExposure(f, valence: -0.9)
            if (before >= 0) != (f.polarity >= 0) {
                flips += 1
                #expect(k >= 3, "never before the third contrary exposure")
                #expect(f.revealedAt == nil, "a change of heart is latent until Dee says so")
            }
        }
        #expect(flips == 1 && f.polarity < 0)
    }

    /// A subject this Dee is innately mildly fond of (so three warm conversations crystallise it).
    static func warmSubject(_ m: Moment) -> Subject {
        let options = ["rain", "music", "flowers", "birds", "stars", "ocean", "piano", "trees", "snow", "kitten"].compactMap(Subject.init)
        return options.first { SelfSeeder.innateTaste($0, seed: m.enduring.seed, personality: m.ongoing.mind.code.personality) >= 0.15 }!
    }

    @Test func conversationsTeachTastesAndRevealThemGradually() {
        var run = Self.run()
        let warm = Self.warmSubject(run.m)
        for c in 0..<3 {
            let t = Double(c) * Self.day
            run.step(.conversationStarted(Kit.t0.addingTimeInterval(t)), at: t)
            run.m.ongoing.topic = [warm]
            run.step(Kit.heard("I love the rain", Self.appraisal(valence: 0.9)), at: t + 1)
            run.step(Kit.heard("so calm", Self.appraisal(valence: 0.7)), at: t + 2)
        }
        #expect(run.m.enduring.facets.first { $0.subject == warm }?.evidence == 2, "the third conversation is still open")
        let fx = run.step(.conversationStarted(Kit.t0.addingTimeInterval(3 * Self.day)), at: 3 * Self.day)
        let rain = run.m.enduring.facets.first { $0.kind == .taste && $0.subject == warm }!
        #expect(rain.evidence == 3 && rain.crystallised && rain.revealedAt == nil)
        #expect(Self.persisted(fx).contains(.facet(rain)))
        #expect(rain.innate == SelfSeeder.innateTaste(warm, seed: run.m.enduring.seed, personality: run.m.ongoing.mind.code.personality))
        // Not raised off-topic; raised once the topic matches.
        run.m.ongoing.topic = []
        run.step(Kit.heard("hello"), at: 3 * Self.day + 1)
        #expect(!run.m.ongoing.noteCandidates.contains { $0.kind == .tasteReveal })
        run.m.ongoing.topic = [warm]
        run.step(Kit.heard("rain today"), at: 3 * Self.day + 2)
        let note = run.m.ongoing.noteCandidates.first { $0.kind == .tasteReveal }
        #expect(note?.facet == rain.id && note?.text == "(You happen to love \(warm.text).)")
        run.issue(note!)
        run.m.ongoing.noteCandidates = []
        run.step(Kit.heard("more rain"), at: 3 * Self.day + 3)
        #expect(!run.m.ongoing.noteCandidates.contains { $0.kind == .tasteReveal }, "revealed: never again")
    }

    @Test func onlyOneRevealPerConversation() {
        var run = Self.run()
        let a = Facet(id: UUID(), kind: .taste, subject: Subject("rain")!, innate: 0.6, evidence: 3, crystallised: true, source: .heuristic, updatedAt: Kit.t0)
        let b = Facet(id: UUID(), kind: .taste, subject: Subject("thunder")!, innate: -0.7, evidence: 4, crystallised: true, source: .heuristic, updatedAt: Kit.t0)
        run.m.enduring.facets = [a, b]
        run.m.ongoing.topic = Self.topic("rain", "thunder")
        run.step(Kit.heard("storm"), at: 1)
        let notes = run.m.ongoing.noteCandidates.filter { $0.kind == .tasteReveal }
        #expect(notes.count == 1 && notes[0].facet == b.id && notes[0].text == "(You happen to find thunder a bit odd.)", "strongest first")
        run.issue(notes[0])
        run.m.ongoing.noteCandidates = []
        run.step(Kit.heard("storm"), at: 2)
        #expect(run.m.ongoing.noteCandidates.isEmpty)
        run.step(.conversationStarted(Kit.t0.addingTimeInterval(10)), at: 10)
        run.m.ongoing.topic = Self.topic("rain", "thunder")
        run.step(Kit.heard("storm"), at: 11)
        #expect(run.m.ongoing.noteCandidates.map(\.facet) == [a.id])
    }

    @Test func sightsAndSoundsBorrowTheValenceOfNearbyTurns() {
        var run = Self.run()
        run.step(.sight(camera: .back, things: ["dog", "person"], novel: ["dog"]), at: 1)
        run.step(Kit.heard("isn't he cute", Self.appraisal(valence: 0.8)), at: 5)
        run.step(.sound(label: "vacuum", unexpected: true), at: 100)
        run.step(Kit.heard("ugh, so loud", Self.appraisal(valence: -0.6)), at: 103)
        run.step(Kit.heard("whatever", Self.appraisal(valence: 0.1)), at: 400)   // out of the window: no effect
        run.step(.conversationStarted(Kit.t0.addingTimeInterval(500)), at: 500)
        let tastes = run.m.enduring.facets.filter { $0.kind == .taste }
        #expect(tastes.map(\.subject.text).sorted() == ["dog", "vacuum"], "people are never a taste")
        #expect(tastes.first { $0.subject.text == "dog" }!.learned > 0 && tastes.first { $0.subject.text == "vacuum" }!.learned < 0)
    }

    @Test func episodeSignalSetsTheExposure() {
        var run = Self.run()
        run.m.ongoing.topic = Self.topic("chess")
        run.step(Kit.heard("chess", Self.appraisal(valence: -0.9)), at: 1)
        run.m.signal("episode", subject: Subject("chess"), value: 0.6, by: Learner.name)
        run.step(.tick, at: 2)
        run.step(.conversationStarted(Kit.t0.addingTimeInterval(10)), at: 10)
        #expect(abs((run.m.enduring.facets.first { $0.subject.text == "chess" }?.learned ?? 0) - 0.18) < 1e-9)
    }

    // MARK: - Gags

    static func laughAfterTurn(_ run: inout ReducerRun<Learner>, topic: String, at t: Double, laughAfter: Double = 3) -> [Effect] {
        run.m.ongoing.topic = Self.topic(topic)
        Self.deeTurn(&run, at: t, tag: .playful, text: "Toast is just warm bread.")
        return run.step(.sound(label: "laughter", unexpected: false), at: t + laughAfter)
    }

    @Test func laughterAfterHerTurnBirthsAGag() {
        var run = Self.run()
        let fx = Self.laughAfterTurn(&run, topic: "toast", at: 10)
        #expect(run.m.enduring.gags.count == 1)
        let g = run.m.enduring.gags[0]
        #expect(g.topic == Subject("toast") && g.person == Kit.john && g.laughs == 1 && !g.retired)
        #expect((0..<(Learner.hookTable[run.m.enduring.humour]!.count)).contains(g.hookTemplate))
        #expect(g.hookTemplate == Int(StableHash.of("toast", seed: run.m.enduring.seed) % UInt64(Learner.hookTable[run.m.enduring.humour]!.count)))
        #expect(Self.persisted(fx) == [.gag(g)])
        #expect(run.m.momentary.signals.contains { $0.name == "gagBorn" && $0.id == g.id })
        var late = Self.run()
        _ = Self.laughAfterTurn(&late, topic: "toast", at: 10, laughAfter: 20)
        #expect(late.m.enduring.gags.isEmpty, "laughter more than 15 s later is not about Dee")
    }

    @Test func everyStyleHasHooksAndRitualPhrases() {
        for s in HumourStyle.allCases {
            #expect((Learner.hookTable[s]?.count ?? 0) >= 4)
            for t in Ritual.Trigger.allCases { #expect((Learner.ritualPhrases[t]?[s]?.count ?? 0) >= 4) }
        }
    }

    /// The callback note is gated by playGate and a seeded 0.4 × playfulness draw from Learner's stream.
    @Test func callbackRateFollowsTheSeededDraw() {
        var raised = 0
        let n = 400
        var playfulness = 0.0
        for seed in 0..<UInt64(n) {
            var run = Self.run(seed: seed)
            run.m.enduring.profiles[Kit.john] = { var p = SocialProfile(); p.humorReceptiveness = 0.9; return p }()
            run.m.enduring.gags = [Gag(id: UUID(), person: Kit.john, topic: Subject("toast")!, hookTemplate: 0, laughs: 1)]
            run.m.ongoing.topic = Self.topic("toast")
            run.step(Kit.heard("toast"), at: 1)
            playfulness = Learner.playfulness(run.m)
            if run.m.ongoing.noteCandidates.contains(where: { $0.kind == .gagCallback }) { raised += 1 }
        }
        let expected = 0.4 * playfulness * Double(n)
        #expect(abs(Double(raised) - expected) < 0.25 * expected, "raised \(raised), expected ≈ \(expected)")
    }

    @Test func noCallbackWithoutPlayGateOrInItsOwnConversationOrTooSoon() {
        func attempts(_ setup: (inout ReducerRun<Learner>) -> Void) -> Int {
            var raised = 0
            for seed in 0..<UInt64(60) {
                var run = Self.run(seed: seed)
                run.m.enduring.profiles[Kit.john] = { var p = SocialProfile(); p.humorReceptiveness = 0.9; return p }()
                run.m.enduring.gags = [Gag(id: UUID(), person: Kit.john, topic: Subject("toast")!, hookTemplate: 0, laughs: 1)]
                setup(&run)
                run.m.ongoing.topic = Self.topic("toast")
                run.step(Kit.heard("toast"), at: 1000)
                if run.m.ongoing.noteCandidates.contains(where: { $0.kind == .gagCallback }) { raised += 1 }
            }
            return raised
        }
        #expect(attempts { _ in } > 0)
        #expect(attempts { $0.m.ongoing.repair = .strained } == 0, "playGate needs repair == fine")
        #expect(attempts { $0.m.enduring.profiles[Kit.john]?.humorReceptiveness = 0.3 } == 0, "playfulness·receptiveness ≤ 0.3")
        #expect(attempts { $0.m.enduring.gags[0].lastUsed = Kit.t0 } == 0, "within 2 days")
        #expect(attempts { $0.m.enduring.gags[0].retired = true } == 0)
        #expect(attempts { $0.m.enduring.gags[0].person = Kit.ann } == 0, "someone else's joke")
        #expect(attempts { $0.m.enduring.lessons = [Lesson(id: UUID(), person: Kit.john, situation: .jokeFlopped, createdAt: Kit.t0)]
                           $0.m.enduring.profiles[Kit.john]?.humorReceptiveness = 0.45 } == 0,
                "after a jokeFlopped lesson the gate is 0.4 (0.8·0.45 = 0.36)")
        // Born this conversation: no callback until the next one.
        var run = Self.run()
        run.m.enduring.profiles[Kit.john] = { var p = SocialProfile(); p.humorReceptiveness = 0.9; return p }()
        for k in 0..<30 {
            _ = Self.laughAfterTurn(&run, topic: "toast", at: Double(k) * 100 + 10)
            run.step(Kit.heard("toast"), at: Double(k) * 100 + 20)
        }
        #expect(!run.m.ongoing.noteCandidates.contains { $0.kind == .gagCallback })
    }

    @Test func twoFlatCallbacksRetireAGag() {
        var run = Self.run()
        let g = Gag(id: UUID(), person: Kit.john, topic: Subject("toast")!, hookTemplate: 0, laughs: 1)
        run.m.enduring.gags = [g]
        for k in 0..<2 {
            let t = Double(k) * 100
            run.m.now = Kit.t0.addingTimeInterval(t)
            run.issue(.gagCallback(g.topic, style: .deadpan, gag: g.id))
            Self.deeTurn(&run, at: t + 10, text: "Remember the toast?")
            run.step(Kit.heard("no", Self.appraisal(valence: -0.1)), at: t + 13)
        }
        #expect(run.m.enduring.gags[0].flatStreak == 2 && run.m.enduring.gags[0].retired)
        #expect(run.m.ongoing.recentMisreads.isEmpty, "a mildly flat answer retires the gag but is no misread (finding 2)")
    }

    @Test func aLaughResetsTheFlatStreak() {
        var run = Self.run()
        let g = Gag(id: UUID(), person: Kit.john, topic: Subject("toast")!, hookTemplate: 0, laughs: 1, flatStreak: 1)
        run.m.enduring.gags = [g]
        run.issue(.gagCallback(g.topic, style: .deadpan, gag: g.id))
        Self.deeTurn(&run, at: 10, text: "Toast!")
        let fx = run.step(Kit.heard("hahaha", Self.appraisal(valence: 0.6, humor: 0.9)), at: 12)
        #expect(run.m.enduring.gags[0].laughs == 2 && run.m.enduring.gags[0].flatStreak == 0 && !run.m.enduring.gags[0].retired)
        #expect(Self.persisted(fx).contains(.gag(run.m.enduring.gags[0])))
        #expect(run.m.enduring.gags.count == 1, "a laugh at a callback is not a new gag")
    }

    // MARK: - Rituals

    static func morning(_ day: Int, hour: Double = 8) -> Double { Double(day) * Self.day + hour * 3600 }

    /// The person arrives at `t` (identified the first time the run sees them that day).
    static func arrive(_ run: inout ReducerRun<Learner>, at t: Double) -> [Effect] {
        run.m.ongoing.person = nil
        run.step(.presence(arrived: false), at: t - 1)
        run.m.ongoing.person = Kit.john
        return run.step(.identified(Kit.john, distance: 0.2), at: t)
    }

    @Test func firstSightOfDayBecomesARitualOnTheThirdMorning() {
        var run = Self.run(person: nil)
        #expect(Self.persisted(Self.arrive(&run, at: Self.morning(0))).map(\.name) == ["ritual"])
        #expect(run.m.enduring.rituals.first?.streak == 1 && run.m.enduring.rituals.first?.count == 0)
        _ = Self.arrive(&run, at: Self.morning(1))
        #expect(!run.m.enduring.rituals.contains(where: Learner.isBorn))
        let fx = Self.arrive(&run, at: Self.morning(2))
        let r = run.m.enduring.rituals[0]
        #expect(r.streak == 3 && r.count == 1 && Learner.isBorn(r))
        #expect(run.m.enduring.signature.repertoire[.greeting]!.map(\.mannerism).contains(r.mannerism))
        #expect(fx.contains(.say(Learner.phrase(r, humour: run.m.enduring.humour)!)))
        #expect(run.m.momentary.mannerismRequests.contains { $0.what == .mannerism(r.mannerism) && $0.owner == Learner.name })
        // Once a day only.
        #expect(Self.persisted(Self.arrive(&run, at: Self.morning(2, hour: 9))).isEmpty)
    }

    @Test func afternoonFirstSightingIsNotAMorningRitual() {
        var run = Self.run(person: nil)
        for d in 0..<4 { _ = Self.arrive(&run, at: Self.morning(d, hour: 14)) }
        #expect(run.m.enduring.rituals.isEmpty)
    }

    @Test func aBrokenStreakResetsSilentlyAndTheRitualStays() {
        var run = Self.run(person: nil)
        for d in 0..<3 { _ = Self.arrive(&run, at: Self.morning(d)) }
        let fx = Self.arrive(&run, at: Self.morning(5))
        let r = run.m.enduring.rituals[0]
        #expect(r.streak == 1 && r.count == 2 && Learner.isBorn(r))
        #expect(fx.contains { if case .say = $0 { true } else { false } }, "the habit stays; nothing is said about the gap")
        let variant = r.variant
        _ = Self.arrive(&run, at: Self.morning(6))
        #expect(run.m.enduring.rituals[0].variant == variant, "the phrase is coined once")
    }

    @Test func ritualIsSkippedWhileUpsetButStillCounted() {
        var run = Self.run(person: nil)
        for d in 0..<2 { _ = Self.arrive(&run, at: Self.morning(d)) }
        run.m.ongoing.repair = .strained
        let fx = Self.arrive(&run, at: Self.morning(2))
        #expect(!fx.contains { if case .say = $0 { true } else { false } })
        #expect(run.m.momentary.mannerismRequests.isEmpty)
        #expect(Learner.isBorn(run.m.enduring.rituals[0]))
    }

    @Test func goodnightAndReturnHome() {
        var run = Self.run()
        for d in 0..<3 { run.step(Kit.heard("good night Dee"), at: Self.morning(d, hour: 23)) }
        #expect(run.m.enduring.rituals.first { $0.trigger == .goodnight }.map(Learner.isBorn) == true)
        var home = Self.run(person: nil)
        var said = false
        for d in 0..<3 {
            _ = Self.arrive(&home, at: Self.morning(d, hour: 12))
            home.step(.presence(arrived: false), at: Self.morning(d, hour: 12.5))
            home.step(.tick, at: Self.morning(d, hour: 15))
            let fx = home.step(.presence(arrived: true), at: Self.morning(d, hour: 18))
            said = fx.contains { if case .say = $0 { true } else { false } }
        }
        let r = home.m.enduring.rituals.first { $0.trigger == .returnHome }
        #expect(r.map(Learner.isBorn) == true && said)
        #expect(Learner.ritualPhrases[.returnHome]![home.m.enduring.humour]!.contains(Learner.phrase(r!, humour: home.m.enduring.humour)!))
    }

    @Test func localDaysFollowTheOffset() {
        var run = ReducerRun(Learner(utcOffset: -4 * 3600))
        // 13:00 UTC = 09:00 at UTC−4: still a morning.
        run.m.ongoing.person = Kit.john
        run.step(.identified(Kit.john, distance: 0.2), at: 13 * 3600)
        #expect(run.m.enduring.rituals.map(\.trigger) == [.firstSightOfDay])
    }

    // MARK: - Privacy hooks

    @Test func forgetPersonAndMergeRepointPrivateState() {
        var run = Self.run()
        run.step(Kit.heard("a", Self.appraisal(valence: 0.5)), at: 1)
        run.step(Kit.heard("b", Self.appraisal(valence: 0.5)), at: 2)      // dirty, throttled
        var merged = run
        merged.m.merge(from: Kit.john, into: Kit.ann)
        merged.r.merge(from: Kit.john, into: Kit.ann, &merged.m)
        #expect(merged.r.flush(&merged.m) == [.persist(.profile(Kit.ann, merged.m.enduring.profiles[Kit.ann]!))])
        run.m.forget(person: Kit.john)
        run.r.forgetPerson(Kit.john, &run.m)
        #expect(run.r.flush(&run.m).isEmpty, "nothing of a forgotten person is re-persisted")
    }

    @Test func forgetSubjectDropsPendingExposures() {
        var run = Self.run()
        run.m.ongoing.topic = Self.topic("rain")
        run.step(Kit.heard("rain", Self.appraisal(valence: 0.9)), at: 1)
        run.m.forget(subject: Subject("rain")!)
        run.r.forget(subject: Subject("rain")!, &run.m)
        run.step(.conversationStarted(Kit.t0.addingTimeInterval(10)), at: 10)
        #expect(run.m.enduring.facets.allSatisfy { $0.kind != .taste })
    }

    @Test func forgetAllResetsPrivateState() {
        var run = Self.run()
        run.m.ongoing.topic = Self.topic("rain")
        run.step(Kit.heard("rain", Self.appraisal(valence: 0.9)), at: 1)
        run.m.forgetAll()
        run.r.forgetAll(&run.m)
        #expect(run.r.flush(&run.m).isEmpty)
        run.step(.conversationStarted(Kit.t0.addingTimeInterval(10)), at: 10)
        #expect(run.m.enduring.facets.allSatisfy { $0.kind != .taste })
    }

    // MARK: - Policy

    @Test func persistedWritesNeverCarryUserText() {
        var run = Self.run()
        let secret = "zanzibar marmalade quokka"
        run.m.ongoing.topic = Self.topic("toast")
        var fx = run.step(.partial(secret), at: 0)
        run.m.ongoing.misreadThisTurn = Misread(id: UUID(), person: Kit.john, at: Kit.t0, situation: .moodGuess, wrongGuess: "sad")
        fx += run.step(Kit.heard(secret + " good night", Self.appraisal(valence: 0.9, humor: 0.9)), at: 1)
        Self.deeTurn(&run, at: 5, tag: .playful, text: secret)
        fx += run.step(Kit.heard(secret, Self.appraisal(humor: 0.9)), at: 7)
        fx += run.step(.conversationStarted(Kit.t0.addingTimeInterval(20)), at: 20)
        fx += run.r.flush(&run.m)
        #expect(!Self.persisted(fx).isEmpty)
        for w in Self.persisted(fx) { #expect(!String(describing: w).contains("zanzibar"), "\(w.name)") }
        #expect(!Self.persisted(fx).contains { String(describing: $0).contains("sad") })
    }

    @Test func deterministicReplay() {
        func once() -> [String] {
            var run = Self.run(seed: 9)
            var out: [String] = []
            for k in 0..<40 {
                let t = Double(k) * 20
                run.m.ongoing.topic = Self.topic(["toast", "rain", "chess"][k % 3])
                out += Self.laughAfterTurn(&run, topic: ["toast", "rain", "chess"][k % 3], at: t + 10).map(\.traceName)
                out += run.step(Kit.heard("x", Self.appraisal(valence: 0.5, humor: 0.5)), at: t + 15).map(\.traceName)
                if k % 10 == 9 { out += run.step(.conversationStarted(Kit.t0.addingTimeInterval(t + 19)), at: t + 19).map(\.traceName) }
                out.append(Learner.slice(of: run.m).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";"))
            }
            return out
        }
        #expect(once() == once())
    }

    @Test func runsInsideCortex() {
        var cx = Kit.cortex()
        var fx = cx.step(.identified(Kit.john, distance: 0.2), mind: Kit.snap(), at: Kit.t0.addingTimeInterval(1))
        if cx.moment.ongoing.person == Kit.john { #expect(fx.contains(.setPauseScale(1.0))) }
        fx = cx.step(Kit.heard("great", Self.appraisal(valence: 0.8)), mind: Kit.snap(), at: Kit.t0.addingTimeInterval(2))
        if cx.moment.ongoing.person == Kit.john {
            #expect(cx.moment.enduring.profiles[Kit.john] != nil)
            #expect(fx.contains { $0.traceName == "persist(profile)" })
        }
    }

    // MARK: - Golden traces

    /// Records Learner alone through `ReducerRun` (exactly as Cortex steps it), letting a
    /// scenario set the fields earlier reducers own (person, topic, misreadThisTurn…).
    struct Trace {
        var run: ReducerRun<Learner>
        var steps: [TraceStep] = []

        mutating func step(_ p: Percept, at t: Double, events: [FloorEvent] = [], mind: MindSnapshot? = nil,
                           _ prepare: (inout Moment) -> Void = { _ in }) {
            prepare(&run.m)
            let fx = run.step(p, at: t, events: events, mind: mind)
            steps.append(TraceStep(t: t, percept: describe(p), effects: fx.map(\.traceName), slice: Learner.slice(of: run.m)))
        }

        mutating func issue(_ n: Note, at t: Double) {
            run.m.now = Kit.t0.addingTimeInterval(t)
            let fx = run.issue(n)
            run.m.ongoing.noteCandidates = []
            steps.append(TraceStep(t: t, percept: "issue(\(n.kind.rawValue))", effects: fx.map(\.traceName), slice: Learner.slice(of: run.m)))
        }

        mutating func flush(at t: Double) {
            run.m.now = Kit.t0.addingTimeInterval(t)
            let fx = run.r.flush(&run.m)
            steps.append(TraceStep(t: t, percept: "flush", effects: fx.map(\.traceName), slice: Learner.slice(of: run.m)))
        }

        func verify(_ name: String) throws { try Golden.verify(GoldenTrace(reducer: Learner.name, name: name, steps: steps)) }
    }

    static func misread(_ s: Lesson.Situation, at t: Double, _ k: UInt8) -> (inout Moment) -> Void {
        { m in
            m.ongoing.misreadThisTurn = Misread(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, k)),
                                                person: Kit.john, at: Kit.t0.addingTimeInterval(t), situation: s, wrongGuess: "sad")
        }
    }

    /// Scenario 3's Learner side: corrected twice → lesson, gain, then the note when a guess recurs.
    @Test func goldenMisreadToLesson() throws {
        var tr = Trace(run: Self.run(seed: 3))
        let day = Self.day
        tr.step(.conversationStarted(Kit.t0), at: 0)
        tr.step(.identified(Kit.john, distance: 0.2), at: 1)
        tr.step(Kit.heard("I'm fine, just tired", Self.appraisal(valence: 0.1)), at: 10, Self.misread(.moodGuess, at: 10, 1))
        tr.step(.conversationStarted(Kit.t0.addingTimeInterval(3 * day)), at: 3 * day) { $0.ongoing.misreadThisTurn = nil }
        tr.step(Kit.heard("no, I'm fine", Self.appraisal(valence: 0)), at: 3 * day + 10, Self.misread(.moodGuess, at: 3 * day + 10, 2))
        tr.step(.conversationStarted(Kit.t0.addingTimeInterval(6 * day)), at: 6 * day) { $0.ongoing.misreadThisTurn = nil }
        tr.step(.tick, at: 6 * day + 5) {
            $0.ongoing.hypotheses = [Hypothesis(kind: .mood, value: "sad", confidence: 0.5, expires: Kit.t0.addingTimeInterval(6 * day + 1200))]
        }
        tr.issue(tr.run.m.ongoing.noteCandidates.first { $0.kind == .lesson } ?? Note(.lesson, owner: "missing"), at: 6 * day + 6)
        tr.step(.partial("so"), at: 6 * day + 20, events: [.deeInterrupted])
        tr.flush(at: 6 * day + 30)
        try tr.verify("misread-to-lesson")
    }

    /// Humour: a laugh births a gag; a later callback lands, then two flop and retire it.
    @Test func goldenHumourAndGags() throws {
        var tr = Trace(run: Self.run(seed: 5))
        tr.run.m.enduring.profiles[Kit.john] = { var p = SocialProfile(); p.humorReceptiveness = 0.8; return p }()
        tr.step(.conversationStarted(Kit.t0), at: 0)
        tr.step(.deeSaid(tag: .playful, sentence: "a"), at: 9) { $0.ongoing.topic = Self.topic("toast") }
        tr.step(.deeTurnFinished(text: "a"), at: 10)
        tr.step(.sound(label: "laughter", unexpected: false), at: 12)
        tr.step(Kit.heard("haha", Self.appraisal(valence: 0.6, humor: 0.9)), at: 14)
        tr.step(.conversationStarted(Kit.t0.addingTimeInterval(Self.day)), at: Self.day)
        var callback: Note?
        for k in 0..<20 where callback == nil {
            tr.step(Kit.heard("toast", Self.appraisal(valence: 0.3)), at: Self.day + Double(k) * 30 + 10) { $0.ongoing.topic = Self.topic("toast") }
            callback = tr.run.m.ongoing.noteCandidates.first { $0.kind == .gagCallback }
        }
        let gag = try #require(callback)
        tr.issue(gag, at: Self.day + 700)
        tr.step(.deeTurnFinished(text: "a"), at: Self.day + 710)
        tr.step(Kit.heard("hahaha", Self.appraisal(valence: 0.7, humor: 0.9)), at: Self.day + 712)
        for d in [4.0, 7.0] {
            tr.issue(gag, at: d * Self.day)
            tr.step(.deeTurnFinished(text: "a"), at: d * Self.day + 10)
            tr.step(Kit.heard("ok", Self.appraisal(valence: 0)), at: d * Self.day + 13)
        }
        try tr.verify("humour-and-gags")
    }

    /// Tastes: three warm conversations crystallise "rain"; the reveal follows the topic.
    @Test func goldenTasteReveal() throws {
        var tr = Trace(run: Self.run(seed: 2))
        let warm = Self.warmSubject(tr.run.m)
        for c in 0..<3 {
            let t = Double(c) * Self.day
            tr.step(.conversationStarted(Kit.t0.addingTimeInterval(t)), at: t)
            tr.step(Kit.heard("rain", Self.appraisal(valence: 0.8)), at: t + 5) { $0.ongoing.topic = [warm] }
            tr.step(.sound(label: "vacuum", unexpected: true), at: t + 30) { $0.ongoing.topic = [] }
            tr.step(Kit.heard("loud", Self.appraisal(valence: -0.7)), at: t + 33)
        }
        tr.step(.conversationStarted(Kit.t0.addingTimeInterval(3 * Self.day)), at: 3 * Self.day)
        tr.step(Kit.heard("rain", Self.appraisal(valence: 0.4)), at: 3 * Self.day + 5) { $0.ongoing.topic = [warm] }
        tr.issue(tr.run.m.ongoing.noteCandidates.first { $0.kind == .tasteReveal } ?? Note(.tasteReveal, owner: "missing"), at: 3 * Self.day + 6)
        tr.step(Kit.heard("rain", Self.appraisal(valence: 0.4)), at: 3 * Self.day + 20)
        try tr.verify("taste-reveal")
    }

    /// Rituals: three mornings → born; a skipped day resets the streak silently.
    @Test func goldenRituals() throws {
        var tr = Trace(run: Self.run(person: nil, seed: 4))
        for d in [0, 1, 2, 4] {
            let t = Self.morning(d)
            tr.step(.presence(arrived: true), at: t) { $0.ongoing.person = Kit.john }
            tr.step(Kit.heard("good night", Self.appraisal(valence: 0.5)), at: Self.morning(d, hour: 23))
            tr.step(.presence(arrived: false), at: Self.morning(d, hour: 23.5)) { $0.ongoing.person = nil }
        }
        try tr.verify("rituals")
    }
}
