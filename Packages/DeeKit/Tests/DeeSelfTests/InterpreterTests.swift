import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// Interpreter (SELF.md §7.4, §7.5, §7.8 detection, §10.3 identity gate). Owner:
/// Interpreter. Goldens: `Fixtures/Interpreter/`.
@Suite struct InterpreterTests {
    // MARK: Helpers

    static func ap(_ f: (inout Appraisal) -> Void) -> Appraisal {
        var a = Appraisal()
        f(&a)
        return a
    }

    static let distress = ap { $0.distress = 0.5; $0.valence = -0.4 }
    static let loudDistress = ap { $0.distress = 0.6; $0.intensity = 0.7; $0.valence = -0.5 }

    /// A run with John identified (three consecutive matches).
    static func identified(_ person: PersonID = Kit.john) -> ReducerRun<Interpreter> {
        var run = ReducerRun(Interpreter())
        for i in 0..<3 { run.step(.identified(person, distance: 0.3), at: Double(i) * 0.1) }
        return run
    }

    static func signals(_ run: ReducerRun<Interpreter>, _ name: String) -> [Signal] {
        run.m.momentary.signals.filter { $0.owner == Interpreter.name && $0.seq == run.m.seq && $0.name == name }
    }

    static func notes(_ run: ReducerRun<Interpreter>) -> [String] {
        run.m.ongoing.noteCandidates.filter { $0.owner == Interpreter.name }.map(\.text)
    }

    static func mood(_ run: ReducerRun<Interpreter>) -> Hypothesis? { run.m.ongoing.hypotheses.first { $0.kind == .mood } }

    // MARK: Identity gate (§10.3)

    @Test func identityNeedsThreeMatchesOrANameConfirmation() {
        var run = ReducerRun(Interpreter())
        run.step(.identified(Kit.john, distance: 0.3), at: 0)
        run.step(.identified(Kit.john, distance: 0.3), at: 0.5)
        #expect(run.m.ongoing.person == nil, "two matches are not enough")
        run.step(.identified(Kit.john, distance: 0.3), at: 1)
        #expect(run.m.ongoing.person == Kit.john, "three consecutive matches")

        var named = ReducerRun(Interpreter())
        named.step(.identified(Kit.ann, distance: Interpreter.nameConfirmedDistance), at: 0)
        #expect(named.m.ongoing.person == Kit.ann, "confirmed by name: at once")
        named.step(.conversationStarted(Kit.t0.addingTimeInterval(10)), at: 10)
        named.step(.identified(nil, distance: 0), at: 11)
        named.step(.identified(nil, distance: 0), at: 12)
        named.step(.identified(nil, distance: 0), at: 13)
        #expect(named.m.ongoing.person == nil)
        named.step(.identified(Kit.ann, distance: 0.2), at: 14)
        #expect(named.m.ongoing.person == nil, "the name confirmation was for the last conversation")
    }

    @Test func identityHysteresisAndTakeover() {
        var run = Self.identified()
        run.step(.identified(Kit.john, distance: 0.9), at: 1)
        #expect(run.m.ongoing.person == Kit.john, "one bad frame does not flap identity")
        run.step(.identified(nil, distance: 0), at: 2)
        #expect(run.m.ongoing.person == Kit.john)
        run.step(.identified(Kit.john, distance: 0.2), at: 2.5)
        run.step(.identified(nil, distance: 0), at: 3)
        run.step(.identified(Kit.john, distance: .infinity), at: 3.5)
        #expect(run.m.ongoing.person == Kit.john, "a match resets the miss count")
        run.step(.identified(nil, distance: 0), at: 4)
        #expect(run.m.ongoing.person == nil, "three misses in a row: unknown")

        var take = Self.identified()
        take.step(Kit.heard("I had a rough day", Self.distress), at: 1)
        #expect(Self.mood(take) != nil)
        take.step(.identified(Kit.ann, distance: 0.2), at: 2)
        take.step(.identified(Kit.ann, distance: 0.2), at: 3)
        #expect(take.m.ongoing.person == Kit.john, "Ann needs the same three-match gate")
        take.step(.identified(Kit.ann, distance: 0.2), at: 4)
        #expect(take.m.ongoing.person == Kit.ann)
        #expect(take.m.ongoing.hypotheses.isEmpty, "what was read about John does not carry over to Ann")
    }

    // MARK: Hypotheses (§7.4)

    @Test func hypothesisConfidenceCapsAndFormula() {
        #expect(Hypothesis(kind: .mood, value: "sad", confidence: 0.95, expires: Kit.t0).confidence == 0.7)
        #expect(Hypothesis(kind: .mood, value: "tired", confidence: 0.2, stated: true, expires: Kit.t0).confidence == 1)
        #expect(abs(Interpreter.inferredConfidence(evidence: 1, gain: 1) - 0.45) < 1e-9)
        #expect(abs(Interpreter.inferredConfidence(evidence: 2, gain: 0.85) - 0.4675) < 1e-9)
        #expect(Interpreter.inferredConfidence(evidence: 9, gain: 1) == 0.7, "inferred never above 0.7")
        #expect(Interpreter.noteThreshold(gain: 1, moodLesson: false) == 0.5)
        #expect(abs(Interpreter.noteThreshold(gain: 0.85, moodLesson: false) - 0.425) < 1e-9)
        #expect(Interpreter.noteThreshold(gain: 0.85, moodLesson: true) == 0.6, "after a moodGuess lesson")
    }

    @Test func moodIsInferredWithEvidenceAndExpires() {
        var run = Self.identified()
        run.step(Kit.heard("I had a rough day", Self.distress), at: 1)
        #expect(Self.mood(run)?.value == "sad")
        #expect(abs((Self.mood(run)?.confidence ?? 0) - 0.45) < 1e-9)
        #expect(Self.notes(run).isEmpty, "0.45 is below the 0.5 note gate")
        run.step(Kit.heard("everything went wrong", Self.distress), at: 5)
        #expect(Self.mood(run)?.evidence == 2)
        #expect(abs((Self.mood(run)?.confidence ?? 0) - 0.55) < 1e-9)
        #expect(Self.notes(run) == ["(Maybe they're sad; don't assume.)"])
        run.step(.tick, at: 5 + Interpreter.moodExpiry - 1)
        #expect(Self.mood(run) != nil)
        run.step(.tick, at: 5 + Interpreter.moodExpiry)
        #expect(Self.mood(run) == nil, "inferred mood lasts 20 min after its last evidence")

        var loud = Self.identified()
        loud.step(Kit.heard("I can't take this anymore", Self.loudDistress), at: 1)
        #expect(Self.mood(loud)?.value == "stressed")
        var tired = Self.identified()
        tired.step(.heard(text: "yeah it was a long one", durationS: 5, loudnessVsBaseline: -0.6, appraisal: Appraisal()), at: 1)
        #expect(Self.mood(tired)?.value == "tired", "quiet and slow")
        var happy = Self.identified()
        happy.step(Kit.heard("haha that is brilliant", Self.ap { $0.humor = 0.6; $0.valence = 0.6 }), at: 1)
        #expect(Self.mood(happy)?.value == "happy")
    }

    @Test func moodInferenceGainScalesConfidenceAndTheNoteGate() {
        var run = Self.identified()
        var profile = SocialProfile()
        profile.moodInferenceGain = 0.85
        run.m.enduring.profiles[Kit.john] = profile
        run.step(Kit.heard("it was a really rough day", Self.distress), at: 1)
        run.step(Kit.heard("it was so rough today honestly", Self.distress), at: 2)
        #expect(abs((Self.mood(run)?.confidence ?? 0) - 0.4675) < 1e-9)
        #expect(Self.notes(run).count == 1, "0.4675 ≥ 0.5 × 0.85")

        var lesson = Self.identified()
        lesson.m.enduring.profiles[Kit.john] = profile
        lesson.m.enduring.lessons = [Lesson(id: UUID(), person: Kit.john, situation: .moodGuess, createdAt: Kit.t0)]
        for i in 1...3 { lesson.step(Kit.heard("it was a really rough day", Self.distress), at: Double(i)) }
        #expect(abs((Self.mood(lesson)?.confidence ?? 0) - 0.5525) < 1e-9)
        #expect(Self.notes(lesson).isEmpty, "a moodGuess lesson: 0.55 stays silent (scenario 3)")
        lesson.step(Kit.heard("it was a really rough day", Self.distress), at: 4)
        #expect(Self.notes(lesson) == ["(Maybe they're sad; don't assume.)"], "0.6375 ≥ 0.6")
    }

    @Test func hypothesisNoteOncePerConversationAfterIssue() {
        var run = Self.identified()
        run.step(Kit.heard("it was a really rough day", Self.distress), at: 1)
        run.step(Kit.heard("it was a really rough day", Self.distress), at: 2)
        run.step(Kit.heard("it was a really rough day", Self.distress), at: 3)
        #expect(Self.notes(run).count == 1, "re-evaluated each turn until issued")
        let note = run.m.ongoing.noteCandidates.last!
        #expect(run.issue(note).isEmpty)
        run.m.ongoing.noteCandidates = []
        run.step(Kit.heard("it was a really rough day", Self.distress), at: 4)
        #expect(Self.notes(run).isEmpty, "issued: not again this conversation")
        run.step(.conversationStarted(Kit.t0.addingTimeInterval(5)), at: 5)
        run.step(Kit.heard("it was a really rough day", Self.distress), at: 6)
        #expect(Self.notes(run).count == 1, "a new conversation may say it again")
        var other = run
        other.m.ongoing.noteCandidates = []
        #expect(other.issue(Note.hypothesis("sad")).isEmpty)
        #expect(other.r.issuedHypotheses.isEmpty, "a note raised by someone else is not ours")
    }

    @Test func statedFeelingsOverrideForThirtyMinutes() {
        var run = Self.identified()
        run.step(Kit.heard("I'm so tired today"), at: 1)
        #expect(Self.mood(run) == Hypothesis(kind: .mood, value: "tired", confidence: 1, stated: true,
                                             expires: Kit.t0.addingTimeInterval(1 + Interpreter.statedMoodExpiry)))
        run.step(Kit.heard("it was a really rough day", Self.distress), at: 2)
        #expect(Self.mood(run)?.value == "tired", "a stated feeling overrides inference")
        run.step(Kit.heard("it was a really rough day", Self.distress), at: 2 + Interpreter.statedMoodExpiry)
        #expect(Self.mood(run)?.value == "sad" && Self.mood(run)?.stated == false, "after 30 min inference resumes")

        for (text, value) in [("I feel a bit down", "sad"), ("honestly I'm pretty stressed", "stressed"), ("feeling great", "happy"),
                              ("I'm kind of nervous", "anxious"), ("I am exhausted", "tired")] {
            var r = Self.identified()
            r.step(Kit.heard(text), at: 1)
            #expect(Self.mood(r)?.value == value && Self.mood(r)?.stated == true, "\(text)")
        }
        for text in ["I'm good at chess", "I'm sick of waiting", "I'm going to the shop", "I feel like pizza", "I'm fine with that"] {
            var r = Self.identified()
            r.step(Kit.heard(text), at: 1)
            #expect(Self.mood(r) == nil, "\(text)")
        }
    }

    // MARK: Corrections (§7.4)

    @Test func fineJustTiredCorrectsTheGuess() {
        var run = Self.identified()
        run.step(Kit.heard("it was a really rough day", Self.distress), at: 1)
        run.step(Kit.heard("it was so rough today honestly", Self.distress), at: 2)
        run.issue(run.m.ongoing.noteCandidates.last!)   // "(Maybe they're sad…)" was voiced
        run.m.ongoing.noteCandidates = []
        let fx = run.step(Kit.heard("I'm fine, just tired"), at: 3)
        #expect(fx.isEmpty, "Learner records and persists the misread")
        let mr = run.m.ongoing.misreadThisTurn
        #expect(mr?.situation == .moodGuess && mr?.wrongGuess == "sad" && mr?.person == Kit.john)
        #expect(Self.notes(run) == ["(You misread them: not sad. Own it in a few words, then check what they meant.)"])
        #expect(Self.mood(run)?.value == "tired" && Self.mood(run)?.stated == true)
        #expect(run.m.momentary.uncertainty == 0.8)
        #expect(Self.signals(run, "correction").map(\.label) == ["mood"])
        run.step(.tick, at: 4)
        #expect(run.m.momentary.uncertainty == 0.8, "held until Dee has owned it")
        run.step(.deeTurnFinished(text: "Oh, sorry, I misread that."), at: 6)
        run.step(.tick, at: 6.5)
        #expect(run.m.momentary.uncertainty == 0)
        run.step(.partial("well"), at: 7, events: [.userStarted])
        #expect(run.m.ongoing.misreadThisTurn == nil, "a new user turn")
        run.m.ongoing.hypotheses = []
        run.step(Kit.heard("it was rough again today", Self.distress), at: 8)
        #expect(Self.mood(run) == nil, "a corrected value is not guessed again for 20 min")
        run.step(Kit.heard("it was rough again today", Self.distress), at: 8 + Interpreter.correctedHold)
        #expect(Self.mood(run)?.value == "sad")
    }

    @Test func negatedJokingAndGenericCorrections() {
        var neg = Self.identified()
        neg.step(Kit.heard("it was a really rough day", Self.distress), at: 1)
        neg.issue(Self.voicedGuess("sad"))
        neg.step(Kit.heard("I'm not sad"), at: 2)
        #expect(Self.mood(neg)?.confidence == 0, "the matching hypothesis goes to confidence 0")
        #expect(neg.m.ongoing.misreadThisTurn?.situation == .moodGuess)
        var upset = Self.identified()
        upset.step(Kit.heard("it was a really rough day", Self.loudDistress), at: 1)
        upset.issue(Self.voicedGuess("stressed"))
        upset.step(Kit.heard("I'm not upset"), at: 2)
        #expect(upset.m.ongoing.misreadThisTurn?.wrongGuess == "stressed", "distress words correct each other")

        var joke = Self.identified()
        joke.step(Kit.heard("you're useless lol", Self.ap { $0.hostility = 0.6 }), at: 1)
        joke.step(Kit.heard("I was joking!"), at: 2)
        #expect(joke.m.ongoing.misreadThisTurn?.situation == .tookLiterally)
        #expect(Self.notes(joke) == ["(You misread them: not serious. Own it in a few words, then check what they meant.)"])
        #expect(Self.signals(joke, "correction").map(\.label) == ["joking"])

        var goal = Self.identified()
        goal.step(Kit.heard("guess what"), at: 1)
        #expect(goal.m.ongoing.hypotheses.first?.value == "news")
        goal.step(Kit.heard("no, you misunderstood"), at: 2)
        #expect(goal.m.ongoing.hypotheses.first?.confidence == 0)
        #expect(goal.m.ongoing.misreadThisTurn == nil, "not a mood guess: no misread record")
        #expect(goal.m.momentary.uncertainty == 0.8)
        #expect(Self.signals(goal, "correction").map(\.label) == ["goal"])

        var meant = Self.identified()
        meant.step(Kit.heard("it was a really rough day", Self.distress), at: 1)
        meant.issue(Self.voicedGuess("sad"))
        meant.step(Kit.heard("no, I meant the other thing"), at: 2)
        #expect(meant.m.ongoing.misreadThisTurn?.situation == .moodGuess)
        var notCorrection = Self.identified()
        notCorrection.step(Kit.heard("I meant to tell you something"), at: 1)
        #expect(Self.signals(notCorrection, "correction").isEmpty)
    }

    static func voicedGuess(_ value: String) -> Note { Note(.hypothesis, slots: [value], owner: Interpreter.name) }

    /// Review finding 8: a guess Dee never voiced is zeroed silently (uncertainty, no
    /// misread note, no misread record); a generic correction owns only a guess voiced in
    /// Dee's last reply.
    @Test func unvoicedGuessesAreCorrectedWithoutAnApology() {
        var neg = Self.identified()
        neg.step(Kit.heard("it was a really rough day", Self.distress), at: 1)
        neg.step(Kit.heard("I'm not sad, just thinking"), at: 2)
        #expect(Self.mood(neg)?.confidence == 0)
        #expect(neg.m.ongoing.misreadThisTurn == nil && Self.notes(neg).isEmpty)
        #expect(neg.m.momentary.uncertainty == 0.8 && Self.signals(neg, "correction").map(\.label) == ["mood"])

        var fine = Self.identified()
        fine.step(Kit.heard("it was a really rough day", Self.distress), at: 1)
        fine.step(Kit.heard("I'm fine"), at: 2)
        #expect(fine.m.ongoing.misreadThisTurn == nil && Self.notes(fine).isEmpty)
        fine.step(Kit.heard("it was rough again", Self.distress), at: 3)
        #expect(Self.mood(fine)?.value != "sad", "still not guessed again for a while")

        var meant = Self.identified()
        meant.step(Kit.heard("it was a really rough day", Self.distress), at: 1)
        meant.step(Kit.heard("no, I meant the other movie"), at: 2)
        #expect(meant.m.ongoing.misreadThisTurn == nil, "the guess was never voiced")
        #expect(Self.mood(meant)?.confidence == 0)

        var stale = Self.identified()
        stale.step(Kit.heard("it was a really rough day", Self.distress), at: 1)
        stale.issue(Self.voicedGuess("sad"))
        stale.step(Kit.heard("anyway, the weather was nice"), at: 2)
        stale.step(Kit.heard("no, I meant the other movie"), at: 3)
        #expect(stale.m.ongoing.misreadThisTurn == nil, "voiced two replies ago: not what they are correcting")
    }

    @Test func differingStatedMoodIsAMisreadOnlyWhenVoiced() {
        var silent = Self.identified()
        silent.step(Kit.heard("it was a really rough day", Self.distress), at: 1)
        silent.step(Kit.heard("I'm just bored"), at: 2)
        #expect(silent.m.ongoing.misreadThisTurn == nil, "the guess never surfaced")
        #expect(Self.mood(silent)?.value == "bored")

        var voiced = Self.identified()
        voiced.step(Kit.heard("it was a really rough day", Self.distress), at: 1)
        voiced.step(Kit.heard("it was a really rough day", Self.distress), at: 2)
        voiced.issue(voiced.m.ongoing.noteCandidates.last!)
        voiced.step(Kit.heard("I'm just bored"), at: 3)
        #expect(voiced.m.ongoing.misreadThisTurn?.wrongGuess == "sad")

        var confirm = Self.identified()
        confirm.step(Kit.heard("it was a really rough day", Self.distress), at: 1)
        confirm.step(Kit.heard("yeah I'm sad"), at: 2)
        #expect(confirm.m.ongoing.misreadThisTurn == nil, "a confirmation, not a misread")
        #expect(Self.mood(confirm)?.stated == true && Self.mood(confirm)?.value == "sad")
    }

    @Test func repeatedQuestionAfterDeeAnsweredIsACorrection() {
        var run = Self.identified()
        run.step(Kit.heard("what time is it?"), at: 1)
        run.step(.deeTurnFinished(text: "It's sunny!"), at: 3)
        run.step(Kit.heard("what time is it?"), at: 10)
        #expect(Self.signals(run, "correction").map(\.label) == ["generic"])
        #expect(run.m.momentary.uncertainty == 0.8)

        var noReply = Self.identified()
        noReply.step(Kit.heard("what time is it?"), at: 1)
        noReply.step(Kit.heard("what time is it?"), at: 5)
        #expect(Self.signals(noReply, "correction").isEmpty, "Dee had not answered yet")

        var late = Self.identified()
        late.step(Kit.heard("what time is it?"), at: 1)
        late.step(.deeTurnFinished(text: "x"), at: 3)
        late.step(Kit.heard("what time is it?"), at: 62)
        #expect(Self.signals(late, "correction").isEmpty, "outside 60 s")
    }

    @Test func attentionWrongReferentIsRecordedAsThisTurnsMisread() {
        var run = Self.identified()
        let id = UUID(uuidString: "00000000-0000-4000-8000-0000000000F1")!
        run.m.momentary.signals.append(Signal("misread", subject: Subject("cup"), value: 1, id: id, label: "wrongReferent",
                                              owner: Attention.name, seq: run.m.seq + 1))
        run.step(Kit.heard("no, I meant the other one"), at: 1)
        #expect(run.m.ongoing.misreadThisTurn?.id == id && run.m.ongoing.misreadThisTurn?.situation == .wrongReferent)
        #expect(Self.notes(run).isEmpty, "Attention raised its own note")
        #expect(Self.signals(run, "correction").isEmpty, "not double-counted as a generic correction")
    }

    // MARK: Busy / wantsQuiet / goal

    @Test func busyAndQuietHypotheses() {
        var run = Self.identified()
        for (i, t) in ["ok", "sure", "mm"].enumerated() { run.step(Kit.heard(t), at: Double(i + 1)) }
        let busy = run.m.ongoing.hypotheses.first { $0.kind == .busy }
        #expect(busy?.value == "busy" && abs((busy?.confidence ?? 0) - 0.65) < 1e-9 && busy?.stated == false)
        #expect(Self.notes(run) == ["(Maybe they're busy; don't assume.)"])
        run.step(Kit.heard("actually I wanted to tell you about my weekend trip"), at: 5)
        #expect(!run.m.ongoing.hypotheses.contains { $0.kind == .busy }, "engagement clears the inferred busy")

        var stated = Self.identified()
        stated.step(Kit.heard("not now Dee"), at: 1)
        let b = stated.m.ongoing.hypotheses.first { $0.kind == .busy }
        #expect(b?.stated == true && b?.confidence == 1 && b?.expires == Kit.t0.addingTimeInterval(1 + Interpreter.busyExpiry))
        stated.step(Kit.heard("I'm not busy anymore"), at: 2)
        #expect(!stated.m.ongoing.hypotheses.contains { $0.kind == .busy })

        var palm = Self.identified()
        palm.step(.gesture("palm"), at: 1)
        let q = palm.m.ongoing.hypotheses.first { $0.kind == .wantsQuiet }
        #expect(q?.value == "quiet" && abs((q?.confidence ?? 0) - 0.65) < 1e-9)
        var shh = Self.identified()
        shh.step(Kit.heard("shh"), at: 1)
        #expect(shh.m.ongoing.hypotheses.first { $0.kind == .wantsQuiet }?.stated == true)

        var away = Self.identified()
        for turn in 0..<2 {
            let t = Double(turn * 10)
            away.m.momentary.floor = .deeSpeaking(since: Kit.t0.addingTimeInterval(t))
            away.step(.head(yaw: 45, pitch: 0), at: t + 1)
            away.m.momentary.floor = .idle
            away.step(.speakingFinished, at: t + 2, events: [.deeFinished])
            #expect(away.m.ongoing.hypotheses.contains { $0.kind == .wantsQuiet } == (turn == 1), "two Dee turns looked away")
        }
    }

    @Test func goalPatterns() {
        let cases: [(String, String?)] = [
            ("look what I made!", "shareCreation"), ("check this out", "shareCreation"), ("I painted this today", "shareCreation"),
            ("can you set a timer", "task"), ("could you remind me later", "task"), ("guess what happened", "news"),
            ("you won't believe this", "news"), ("the weather is nice", nil),
        ]
        for (text, goal) in cases {
            var run = Self.identified()
            run.step(Kit.heard(text), at: 1)
            #expect(run.m.ongoing.hypotheses.first { $0.kind == .goal }?.value == goal, "\(text)")
        }
        var run = Self.identified()
        run.step(Kit.heard("look at this"), at: 1)
        #expect(run.m.ongoing.hypotheses.first?.confidence == Interpreter.goalConfidence)
        #expect(Self.notes(run).isEmpty, "goals never become notes")
        run.step(.tick, at: 1 + Interpreter.goalExpiry)
        #expect(run.m.ongoing.hypotheses.isEmpty, "goals last 5 min")
        run.step(Kit.heard("look at this"), at: 400)
        run.step(.conversationStarted(Kit.t0.addingTimeInterval(401)), at: 401)
        #expect(run.m.ongoing.hypotheses.isEmpty, "and end with the conversation")
    }

    // MARK: Topic

    @Test func topicLemmasAreLexicalAndCapped() {
        var run = Self.identified()
        run.step(Kit.heard("I've been practising my guitar chords"), at: 1)
        #expect(run.m.ongoing.topic.map(\.text) == ["guitar chord"])
        run.step(Kit.heard("we talked about paintings and the stories"), at: 2)
        #expect(run.m.ongoing.topic.map(\.text) == ["guitar chord", "painting", "story"])
        run.step(Kit.heard("my dog is funny"), at: 3)
        #expect(run.m.ongoing.topic.map(\.text) == ["painting", "story", "dog"], "≤ 3, newest last")
        run.m.momentary.referents = [Referent(subject: Subject("watercolor")!, camera: .back, sources: [.sawBack], salience: 0.8,
                                              lastSeen: Kit.t0, sharedWithUser: false)]
        run.step(Kit.heard("do you like this watercolor"), at: 4)
        #expect(run.m.ongoing.topic.last?.text == "watercolor", "a mentioned referent label")
        run.step(Kit.heard("it was a lot of fun really"), at: 5)
        #expect(run.m.ongoing.topic.last?.text == "watercolor", "no content words, no topic")

        #expect(Interpreter.Topics.lemma("classes") == "class")
        #expect(Interpreter.Topics.lemma("glasses") == "glass")
        #expect(Interpreter.Topics.lemma("stories") == "story")
        #expect(Interpreter.Topics.lemma("bus") == "bus")
        #expect(Interpreter.Topics.lemma("tennis") == "tennis")
        #expect(Interpreter.Topics.looksPastTense("knocked") && !Interpreter.Topics.looksPastTense("speed")
                && !Interpreter.Topics.looksPastTense("bed"), "a verb never ends a topic phrase (integration)")
        run.step(.conversationStarted(Kit.t0.addingTimeInterval(9)), at: 9)
        #expect(run.m.ongoing.topic.isEmpty)
    }

    // MARK: PlanDetector (§7.5)

    struct PlanCase {
        var text: String
        var subject: String?
        var due: String = ""
        var framing: DeeSelf.Expectation.Framing = .neutral
        var health = false
        var finishing = false
        var appraisal = Appraisal()
    }

    static let planCases: [PlanCase] = [
        PlanCase(text: "I've got a job interview Thursday, I'm really nervous", subject: "job interview", due: "Thu 17:00", framing: .nervous),
        PlanCase(text: "I have a dentist appointment tomorrow at 3pm", subject: "dentist appointment", due: "Tue 15:00"),
        PlanCase(text: "my math exam is on friday and I can't wait", subject: "math exam", due: "Fri 17:00", framing: .excited),
        PlanCase(text: "I'm going to a party tonight", subject: "party", due: "Mon 20:00"),
        PlanCase(text: "I have surgery next week, I'm scared", subject: "surgery", due: "Mon 17:00+1", framing: .nervous, health: true),
        PlanCase(text: "we have a big game on saturday", subject: "game", due: "Sat 17:00"),
        PlanCase(text: "I'm going to finish the painting tomorrow", subject: "painting", due: "Tue 17:00", finishing: true),
        PlanCase(text: "I've got a presentation in two days", subject: "presentation", due: "Wed 17:00"),
        PlanCase(text: "I have my driving test tomorrow morning", subject: "driving test", due: "Tue 09:00"),
        PlanCase(text: "I have a doctor's appointment on Wednesday at 10:30", subject: "doctor's appointment", due: "Wed 10:30"),
        PlanCase(text: "I'm going on a trip on friday, so excited!", subject: "trip", due: "Fri 17:00", framing: .excited),
        PlanCase(text: "I've got an exam at 9 tomorrow", subject: "exam", due: "Tue 09:00"),
        PlanCase(text: "I've got a football match this weekend", subject: "football match", due: "Sat 17:00"),
        PlanCase(text: "I'm having a party in a week", subject: "party", due: "Mon 17:00+1",
                 framing: .excited, appraisal: ap { $0.valence = 0.5 }),
        PlanCase(text: "I have an interview", subject: "interview", due: "Tue 18:00"),
        PlanCase(text: "I've got a recital on sunday and I'm a bit worried", subject: "recital", due: "Sun 17:00", framing: .nervous),
        PlanCase(text: "I have a meeting at 4", subject: "meeting", due: "Tue 16:00"),
        PlanCase(text: "I'm going to finish my quilt next week", subject: "quilt", due: "Mon 17:00+1", finishing: true),
        PlanCase(text: "I'm taking my exam the day after tomorrow", subject: "exam", due: "Wed 17:00"),
        PlanCase(text: "I have finals on tuesday", subject: "final", due: "Tue 17:00", framing: .nervous, appraisal: ap { $0.distress = 0.4 }),
        // Not plans.
        PlanCase(text: "my exam went really well"), PlanCase(text: "I had an interview yesterday"),
        PlanCase(text: "I don't have an exam tomorrow"), PlanCase(text: "how was your interview?"),
        PlanCase(text: "I've had a test today"), PlanCase(text: "I have a cat"),
        PlanCase(text: "my interview yesterday went great"),
        // Review finding 10: negated or cancelled events are not plans.
        PlanCase(text: "I have no meeting tomorrow"), PlanCase(text: "my exam tomorrow got cancelled"),
        PlanCase(text: "we're not going to the party on friday"),
    ]

    static func date(_ spec: String) -> Date {
        let parts = spec.split(separator: "+")
        return SimClock.at(String(parts[0]), week: parts.count > 1 ? Int(parts[1])! : 0)!
    }

    @Test func planDetectorFixtures() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = SimClock.at("Mon 18:00")!
        for c in Self.planCases {
            let plan = Interpreter.PlanDetector.detect(c.text, appraisal: c.appraisal, now: now, calendar: cal)
            guard let subject = c.subject else {
                #expect(plan == nil, "not a plan: \(c.text)")
                continue
            }
            #expect(plan?.subject.text == subject, "\(c.text)")
            #expect(plan?.due == Self.date(c.due), "\(c.text): due \(String(describing: plan?.due))")
            #expect(plan?.framing == c.framing, "\(c.text)")
            #expect(plan?.health == c.health, "\(c.text)")
            #expect(plan?.finishing == c.finishing, "\(c.text)")
        }
        #expect(Self.planCases.filter { $0.subject != nil }.count >= 20)
    }

    /// Review finding 10: a day without a time is due at 17:00 (the follow-up waits until
    /// 19:00, never asks before a 4 pm interview); an undated plan says so in its label;
    /// the possessor stays in the subject.
    @Test func dayOnlyUndatedAndPossessivePlans() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = SimClock.at("Mon 18:00")!
        let interview = try #require(Interpreter.PlanDetector.detect("my interview is on thursday", appraisal: Appraisal(), now: now, calendar: cal))
        #expect(interview.dated && interview.due == SimClock.at("Thu 17:00"))
        #expect(interview.followUp(id: UUID(), person: Kit.john, now: now).notBefore == SimClock.at("Thu 19:00"))
        let exam = try #require(Interpreter.PlanDetector.detect("I have an exam", appraisal: Appraisal(), now: now, calendar: cal))
        #expect(!exam.dated && exam.label == "neutral+undated")
        let s = Signal("plan", subject: exam.subject, value: exam.due.timeIntervalSinceReferenceDate, label: exam.label,
                       owner: Interpreter.name, seq: 0)
        #expect(Interpreter.plan(from: s)?.dated == false)
        let recital = try #require(Interpreter.PlanDetector.detect("I have my daughter's recital tomorrow", appraisal: Appraisal(), now: now, calendar: cal))
        #expect(recital.subject.text == "daughter's recital")
        for gentle in ["I have the funeral on friday", "my court hearing is tomorrow", "I have a biopsy tomorrow"] {
            #expect(Interpreter.PlanDetector.detect(gentle, appraisal: Appraisal(), now: now, calendar: cal)?.health == true, "\(gentle)")
        }
        // Tune 4 decision (a): ordinary appointments are not gentle (asked by name).
        for named in ["I'm taking the cat to the vet tomorrow", "I have a dentist appointment tomorrow"] {
            #expect(Interpreter.PlanDetector.detect(named, appraisal: Appraisal(), now: now, calendar: cal)?.health == false, "\(named)")
        }
    }

    @Test func dateParserLocalOffset() {
        // 23:30 UTC on Monday is already Tuesday 01:30 two hours east: "tomorrow" is Wednesday there.
        let run = Interpreter(utcOffset: 2 * 3600)
        let now = SimClock.at("Mon 23:30")!
        let p = Interpreter.PlanDetector.detect("I have an exam tomorrow", appraisal: Appraisal(), now: now, calendar: run.calendar)
        #expect(p?.due == SimClock.at("Wed 15:00"), "17:00 local = 15:00 UTC")
    }

    @Test func planSignalForAnIdentifiedPersonOnly() throws {
        var anon = ReducerRun(Interpreter())
        anon.step(Kit.heard("I've got a job interview Thursday"), at: 18 * 3600)
        #expect(Self.signals(anon, "plan").isEmpty, "an expectation needs a person")
        #expect(anon.m.ongoing.topic.map(\.text) == ["job interview"])

        var run = Self.identified()
        let a = Self.ap { $0.distress = 0.5 }
        run.step(Kit.heard("I've got a job interview Thursday", a), at: 18 * 3600)
        let s = try #require(Self.signals(run, "plan").first)
        #expect(s.subject?.text == "job interview" && s.label == "nervous" && s.id != nil)
        let plan = try #require(Interpreter.plan(from: s))
        #expect(plan.due == SimClock.at("Thu 17:00"))
        let e = plan.expectation(id: s.id!, person: Kit.john)
        #expect(e.expires == SimClock.at("Thu 17:00", week: 1) && e.status == .pending && e.framing == .nervous)
        let f = plan.followUp(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000F2")!, person: Kit.john, now: run.m.now)
        #expect(f.notBefore == SimClock.at("Thu 19:00") && f.expires == e.expires && f.priority == 0.8 && f.kind == .followUp)
        #expect(f.reason == "they were nervous about it" && f.source == "plan")
        #expect(Interpreter.plan(from: Signal("plan", subject: Subject("x"), label: "nervous", owner: "Other", seq: 0)) == nil)

        run.m.ongoing.expectations = [e]
        run.step(Kit.heard("did I tell you I've got a job interview on Thursday"), at: 18 * 3600 + 60)
        #expect(Self.signals(run, "plan").isEmpty, "already pending: no duplicate")
        var health = Self.identified()
        health.step(Kit.heard("I have surgery on friday"), at: 1)
        #expect(Self.signals(health, "plan").first?.label == "neutral+health")
    }

    @Test func expectationOutcomes() {
        let e = DeeSelf.Expectation(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000E1")!, person: Kit.john,
                            subject: Subject("job interview")!, due: Kit.t0.addingTimeInterval(1000),
                            expires: Kit.t0.addingTimeInterval(1000 + 7 * 86_400), framing: .nervous)
        var early = Self.identified()
        early.m.ongoing.expectations = [e]
        early.step(Kit.heard("the interview is soon"), at: 500)
        #expect(Self.signals(early, "expectationOutcome").isEmpty, "before it is due")

        var unprompted = Self.identified()
        unprompted.m.ongoing.expectations = [e]
        unprompted.step(Kit.heard("the interview went great!", Self.ap { $0.valence = 0.8 }), at: 2000)
        let s = Self.signals(unprompted, "expectationOutcome")
        #expect(s.map(\.label) == ["unprompted"] && s.first?.id == e.id && s.first?.value == 0.8)
        unprompted.step(Kit.heard("the interview was fun"), at: 2010)
        #expect(Self.signals(unprompted, "expectationOutcome").isEmpty, "once per expectation")

        var asked = Self.identified()
        var ea = e
        ea.status = .asked
        asked.m.ongoing.expectations = [ea]
        asked.step(Kit.heard("ugh not well", Self.ap { $0.valence = -0.3; $0.distress = 0.4 }), at: 2000)
        let o = Self.signals(asked, "expectationOutcome").first
        #expect(o?.label == "asked" && abs((o?.value ?? 0) + 0.5) < 1e-9)

        var someoneElse = Self.identified(Kit.ann)
        someoneElse.m.ongoing.expectations = [ea]
        someoneElse.step(Kit.heard("hello"), at: 2000)
        #expect(Self.signals(someoneElse, "expectationOutcome").isEmpty, "only the person's own")
    }

    // MARK: RepairDetector and the adjust hook (§7.8, §7.7)

    @Test func repairDetectorSignals() {
        let cases: [(String, Appraisal, [Interpreter.RepairDetector.Finding])] = [
            ("are we ok?", Appraisal(), [.bid("areWeOk")]),
            ("friends?", Appraisal(), [.bid("friends")]),
            ("I didn't mean it", Appraisal(), [.bid("didntMeanIt")]),
            ("I'm sorry", Self.ap { $0.apology = 0.6 }, [.bid("apology")]),
            ("sorry, you idiot", Self.ap { $0.apology = 0.6; $0.hostility = 0.7 }, []),
            ("don't ask me about my job", Appraisal(), [.userBoundary(Subject("job")!)]),
            ("I don't want to talk about money anymore", Appraisal(), [.userBoundary(Subject("money")!)]),
            ("you can ask me about my job again", Appraisal(), [.boundaryLifted(Subject("job")!)]),
            ("the weather is nice", Appraisal(), []),
        ]
        for (text, a, want) in cases {
            #expect(Interpreter.RepairDetector.read(text, appraisal: a, topic: nil) == want, "\(text)")
        }
        var run = Self.identified()
        run.step(Kit.heard("are we ok?"), at: 1)
        #expect(Self.signals(run, "reconciliationBid").map(\.label) == ["areWeOk"])
        run.step(Kit.heard("stop asking me about school"), at: 2)
        #expect(Self.signals(run, "userBoundary").map(\.subject?.text) == ["school"])
        run.step(Kit.heard("you can talk about school again"), at: 3)
        #expect(Self.signals(run, "userBoundaryLifted").map(\.subject?.text) == ["school"])
    }

    @Test func tookLiterallyLessonSoftensTeasingHostility() {
        let tease = Self.ap { $0.hostility = 0.6; $0.humor = 0.3 }
        let straight = Self.ap { $0.hostility = 0.6 }
        var run = Self.identified()
        var a = tease
        run.r.adjust(&a, run.m)
        #expect(a.hostility == 0.6, "no lesson: unchanged")

        run.m.enduring.lessons = [Lesson(id: UUID(), person: Kit.john, situation: .tookLiterally, createdAt: Kit.t0)]
        a = tease
        run.r.adjust(&a, run.m)
        #expect(a.hostility == 0.3, "a humorous tease is halved")
        a = straight
        run.r.adjust(&a, run.m)
        #expect(a.hostility == 0.6, "a flat insult with no play cue is not")
        run.step(.sound(label: "laughter", unexpected: false), at: 1)
        a = straight
        run.r.adjust(&a, run.m)
        #expect(a.hostility == 0.3, "after laughter within 30 s")
        run.step(.tick, at: 32)
        a = straight
        run.r.adjust(&a, run.m)
        #expect(a.hostility == 0.6, "the play cue has passed")
        run.step(.deeSaid(tag: .playful, sentence: "x"), at: 40)
        run.step(Kit.heard("you're useless", straight), at: 41)
        #expect(Self.signals(run, "hostility").map(\.label) == ["teasing"])
        #expect(Self.signals(run, "hostility").first?.value == 0.3)

        var ann = Self.identified(Kit.ann)
        ann.m.enduring.lessons = run.m.enduring.lessons
        a = tease
        ann.r.adjust(&a, ann.m)
        #expect(a.hostility == 0.6, "John's lesson is about John's teasing")
    }

    // MARK: Hooks and privacy

    @Test func hooksResetAndRepoint() {
        var run = Self.identified()
        run.step(Kit.heard("it was a really rough day", Self.distress), at: 1)
        run.step(Kit.heard("it was a really rough day", Self.distress), at: 2)
        run.issue(run.m.ongoing.noteCandidates.last!)
        run.step(Kit.heard("look at my painting"), at: 3)
        run.m.ongoing.misreadThisTurn = Misread(id: UUID(), person: nil, at: Kit.t0, situation: .moodGuess)
        run.step(.conversationStarted(Kit.t0.addingTimeInterval(4)), at: 4)
        #expect(run.m.ongoing.topic.isEmpty && run.m.ongoing.misreadThisTurn == nil)
        #expect(!run.m.ongoing.hypotheses.contains { $0.kind == .goal })
        #expect(run.m.ongoing.hypotheses.contains { $0.kind == .mood }, "a mood outlives a quick new conversation")
        #expect(run.r.issuedHypotheses.isEmpty)

        var merge = ReducerRun(Interpreter())
        merge.step(.identified(Kit.ann, distance: 0), at: 0)
        merge.r.merge(from: Kit.ann, into: Kit.john, &merge.m)
        #expect(merge.r.nameConfirmed == [Kit.john] && merge.r.candidate == Kit.john)
        merge.r.forgetPerson(Kit.john, &merge.m)
        #expect(merge.r.nameConfirmed.isEmpty && merge.r.candidate == nil)

        var all = Self.identified()
        all.step(Kit.heard("it was a really rough day", Self.distress), at: 1)
        all.issue(Note(.hypothesis, slots: ["sad"], owner: Interpreter.name))
        all.r.forgetAll(&all.m)
        #expect(all.r.issuedHypotheses.isEmpty)
        #expect(all.r.candidate == Kit.john && all.r.candidateStreak == 3, "identity tracking is not learnt state")
    }

    /// Nothing the Interpreter raises carries user text: signal subjects are ≤ 4 words,
    /// labels and note texts come from fixed vocabularies.
    @Test func noUserTextInSignalsOrNotes() {
        var rng = Rand(seed: 0x1A7E)
        let words = ["purple", "elephant", "my", "interview", "tomorrow", "nervous", "the", "guitar", "I'm", "sad", "not",
                     "about", "don't", "ask", "me", "joking", "I", "have", "a", "exam", "friday", "look", "can", "you", "fine"]
        var run = Self.identified()
        var labels = Set<String>()
        for i in 0..<400 {
            let text = (0..<(4 + rng.index(10))).map { _ in words[rng.index(words.count)] }.joined(separator: " ")
            var a = Appraisal()
            a.distress = rng.unit() < 0.3 ? 0.5 : 0
            a.hostility = rng.unit() < 0.2 ? 0.6 : 0
            run.step(Kit.heard(text, a), at: Double(i) * 5)
            for s in run.m.momentary.signals where s.owner == Interpreter.name && s.seq == run.m.seq {
                #expect((s.subject?.words.count ?? 0) <= Subject.maxWords)
                if let l = s.label { labels.insert(l) }
            }
            for n in run.m.ongoing.noteCandidates where n.owner == Interpreter.name {
                #expect(n.slots.allSatisfy { $0.split(separator: " ").count <= 4 }, "\(n.slots)")
            }
            run.m.ongoing.noteCandidates = []
        }
        let vocabulary: Set<String> = ["mood", "goal", "busy", "wantsQuiet", "generic", "joking", "teasing", "hostile", "apology", "areWeOk",
                                       "friends", "didntMeanIt", "phrase", "asked", "unprompted", "nervous", "excited", "neutral",
                                       "nervous+health", "excited+health", "neutral+health", "nervous+finish", "excited+finish",
                                       "neutral+finish"]
        #expect(labels.isSubset(of: vocabulary), "\(labels.subtracting(vocabulary))")
    }

    // MARK: Goldens

    @Test func goldenMoodCorrection() throws {
        try Golden.verify(Golden.record(Interpreter(), name: "mood-correction", [
            Cue(t: 0, p: .identified(Kit.john, distance: 0.3)), Cue(t: 0.5, p: .identified(Kit.john, distance: 0.3)),
            Cue(t: 1, p: .identified(Kit.john, distance: 0.3)),
            Cue(t: 2, p: Kit.heard("it was a really rough day", Self.distress)), Cue(t: 10, p: Kit.heard("it was so rough today honestly", Self.distress)),
            Cue(t: 20, p: Kit.heard("I'm fine, just tired")), Cue(t: 21, p: .tick),
            Cue(t: 25, p: .deeTurnFinished(text: "Sorry, I misread you.")), Cue(t: 26, p: .tick),
            Cue(t: 30, p: Kit.heard("it was a really rough day", Self.distress)), Cue(t: 20 + 1800, p: .tick),
        ]))
    }

    @Test func goldenPlansTopicsAndBusy() throws {
        try Golden.verify(Golden.record(Interpreter(), name: "plans-topics-busy", [
            Cue(t: 0, p: .identified(Kit.ann, distance: 0)),
            Cue(t: 18 * 3600, p: Kit.heard("I've got a job interview Thursday, I'm really nervous")),
            Cue(t: 18 * 3600 + 10, p: Kit.heard("look at my new watercolor painting")),
            Cue(t: 18 * 3600 + 20, p: Kit.heard("I'm going to finish the quilt tomorrow")),
            Cue(t: 18 * 3600 + 30, p: Kit.heard("ok")), Cue(t: 18 * 3600 + 35, p: Kit.heard("yeah")),
            Cue(t: 18 * 3600 + 40, p: Kit.heard("mm")), Cue(t: 18 * 3600 + 45, p: .gesture("palm")),
            Cue(t: 18 * 3600 + 700, p: .tick),
        ]))
    }

    @Test func goldenRepairSignals() throws {
        try Golden.verify(Golden.record(Interpreter(), name: "repair-signals", [
            Cue(t: 0, p: .identified(Kit.john, distance: 0)),
            Cue(t: 1, p: Kit.heard("you're useless", Self.ap { $0.hostility = 0.7 })),
            Cue(t: 5, p: Kit.heard("I was joking!")),
            Cue(t: 9, p: Kit.heard("are we ok?")), Cue(t: 12, p: Kit.heard("I'm sorry", Self.ap { $0.apology = 0.6 })),
            Cue(t: 20, p: Kit.heard("don't ask me about my job")),
            Cue(t: 30, p: Kit.heard("you can ask me about my job again")),
        ]))
    }
}
