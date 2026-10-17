import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// IntentionBoard (SELF.md §7.5, §7.6). Owner: IntentionBoard. Goldens: `Fixtures/IntentionBoard/`.
@Suite struct IntentionBoardTests {
    // MARK: Builders (`intention` and `aim` are also used by CortexTests)

    static func intention(_ subject: String, status: Intention.Status = .issued, issued: Int = 1, expires: Double = 86_400) -> Intention {
        Intention(id: UUID(), kind: .followUp, subject: Subject(subject)!, person: Kit.john, reason: "they were nervous about it",
                  notBefore: Kit.t0, expires: Kit.t0.addingTimeInterval(expires), priority: 0.8, status: status, issuedCount: issued,
                  source: "plan", created: Kit.t0)
    }

    static func aim(_ i: Intention) -> Note { .followUp(i.subject, framing: .nervous, intention: i.id) }

    static func ask(_ subject: String, kind: Intention.Kind = .ask, priority: Double = 0.9, person: PersonID? = Kit.john,
                    notBefore: Double = 0, expires: Double = 86_400, steps: Int = 1) -> Intention {
        Intention(id: UUID(), kind: kind, subject: Subject(subject)!, person: person, reason: "I wondered about it",
                  notBefore: Kit.t0.addingTimeInterval(notBefore), expires: Kit.t0.addingTimeInterval(expires), priority: priority,
                  stepsNeeded: steps, source: "curiosity", created: Kit.t0)
    }

    static func expectation(_ subject: String, due: Double = 0, framing: DeeSelf.Expectation.Framing = .nervous,
                            person: PersonID = Kit.john) -> DeeSelf.Expectation {
        let d = Kit.t0.addingTimeInterval(due)
        return DeeSelf.Expectation(id: UUID(), person: person, subject: Subject(subject)!, due: d,
                           expires: d.addingTimeInterval(IntentionBoard.followUpLifetime), framing: framing)
    }

    static func appraisal(valence: Double) -> Appraisal {
        var a = Appraisal()
        a.valence = valence
        return a
    }

    static let hour = 3600.0
    static let day = 86_400.0
    /// urgeToTalk ≈ 0.82 (the default snapshot is ≈ 0.47).
    static let chatty = Kit.snap([.joy: 0.9, .interest: 0.9, .energy: 1.0, .loneliness: 0.6], personality: [.extraversion: 0.9])

    /// The board's note candidates (Cortex clears them at each cue; ReducerRun does not).
    static func aims(_ run: ReducerRun<IntentionBoard>) -> [Note] {
        run.m.ongoing.noteCandidates.filter { $0.owner == IntentionBoard.name }
    }

    /// A signal raised "during" the next step by `owner` (Interpreter is earlier in the
    /// pipeline, so it arrives in the same step; Learner is later, so it arrives next step).
    static func inject(_ run: inout ReducerRun<IntentionBoard>, _ name: String, subject: String? = nil, value: Double = 0,
                       id: UUID? = nil, label: String? = nil, owner: String = "Interpreter") {
        let early = (Cortex.pipeline.firstIndex(of: owner) ?? 0) < (Cortex.pipeline.firstIndex(of: IntentionBoard.name) ?? 0)
        run.m.momentary.signals.append(Signal(name, subject: subject.flatMap(Subject.init), value: value, id: id, label: label,
                                              owner: owner, seq: early ? run.m.seq + 1 : run.m.seq))
    }

    /// A board with one nervous "job interview" expectation (due at t0) and its follow-up,
    /// John identified and one user turn in.
    static func interviewBoard(mind: MindSnapshot = Kit.snap()) -> ReducerRun<IntentionBoard> {
        var run = ReducerRun(IntentionBoard(), mind: mind)
        run.m.ongoing.expectations = [Self.expectation("job interview")]
        run.step(.tick, at: 1)
        run.m.ongoing.person = Kit.john
        run.m.ongoing.turnsThisConversation = 1
        return run
    }

    // MARK: Issued-aim bookkeeping (0.5.1)

    @Test func issuedAimIsMarkedAndPersisted() {
        var run = ReducerRun(IntentionBoard())
        let it = Self.intention("job interview", status: .open, issued: 0)
        run.m.ongoing.intentions = [it]
        let fx = run.issue(Self.aim(it))
        #expect(run.m.ongoing.intentions[0].status == .issued && run.m.ongoing.intentions[0].issuedCount == 1)
        #expect(fx == [.persist(.intention(run.m.ongoing.intentions[0]))], "the count survives a relaunch")
        #expect(run.r.aimedThisTurn == [it.id])
        #expect(run.m.ongoing.followUpsThisConversation == 1)
        #expect(run.issue(.cutOff()).isEmpty, "not the board's note")
    }

    @Test func followThroughDoneDroppedOrWaiting() {
        var run = ReducerRun(IntentionBoard())
        let its = [Self.intention("job interview", issued: 0), Self.intention("painting", issued: 1),
                   Self.intention("guitar", issued: 0), Self.intention("dog", status: .open, issued: 0)]
        run.m.ongoing.intentions = its
        for i in its.prefix(3) { run.issue(Self.aim(i)) }
        let fx = run.step(.deeTurnFinished(text: "[curious] How did the interview go?"), at: 1)
        let st = run.m.ongoing.intentions.map(\.status)
        #expect(st == [.done, .dropped, .issued, .open])
        #expect(fx.map(\.traceName) == ["persist(intention)", "persist(intention)"])
        #expect(run.r.aimedThisTurn.isEmpty)
        run.step(.tick, at: 2)
        #expect(run.m.ongoing.intentions.map(\.subject.text) == ["guitar", "dog"], "finished ones leave the board")
    }

    /// Review finding 14: only intentions aimed this turn are checked against the reply.
    @Test func onlyThisTurnsAimsAreChecked() {
        var run = ReducerRun(IntentionBoard())
        run.m.ongoing.intentions = [Self.intention("job interview", issued: 1), Self.intention("guitar", issued: 2)]
        let fx = run.step(.deeTurnFinished(text: "The interview? And your guitar?"), at: 1)
        #expect(fx.isEmpty, "issued earlier, not aimed now: a later mention is not follow-through")
        #expect(run.m.ongoing.intentions.map(\.status) == [.issued, .issued])
    }

    @Test func silentExpiry() {
        var run = ReducerRun(IntentionBoard())
        run.m.ongoing.intentions = [Self.intention("trip", expires: 10)]
        run.m.ongoing.expectations = [DeeSelf.Expectation(id: UUID(), person: Kit.john, subject: Subject("trip")!, due: Kit.t0,
                                                  expires: Kit.t0.addingTimeInterval(10), framing: .excited)]
        #expect(run.step(.tick, at: 5).isEmpty)
        let fx = run.step(.tick, at: 11)
        #expect(fx.map(\.traceName) == ["persist(intention)", "persist(expectation)"])
        #expect(run.m.ongoing.intentions.isEmpty && run.m.ongoing.expectations.isEmpty)
        #expect(run.m.ongoing.noteCandidates.isEmpty, "absence never generates a note")
    }

    @Test func seedsFromCarriedAndResetsPerConversation() {
        var run = ReducerRun(IntentionBoard())
        let it = Self.intention("trip")
        run.r.seed(from: Carried(intentions: [it]), &run.m)
        #expect(run.m.ongoing.intentions == [it])
        run.m.ongoing.followUpsThisConversation = 1
        run.step(.conversationStarted(Kit.t0), at: 0)
        #expect(run.m.ongoing.followUpsThisConversation == 0)
        #expect(run.r.followedUpThisConversation.isEmpty)
    }

    @Test func subjectMentionMatching() {
        #expect(IntentionBoard.mentions("how did the interview go?", Subject("job interview")!))
        #expect(IntentionBoard.mentions("love your paintings", Subject("painting")!))
        #expect(IntentionBoard.mentions("How Did The Interview Go?", Subject("job interview")!), "case-insensitive")
        #expect(!IntentionBoard.mentions("nice weather", Subject("job interview")!))
        #expect(!IntentionBoard.mentions("the reinterview", Subject("job interview")!))
    }

    // MARK: Anticipation: expectations → follow-ups (§7.5)

    @Test func everyPendingExpectationGetsOneFollowUp() {
        var run = ReducerRun(IntentionBoard())
        let x = Self.expectation("job interview", due: Self.day)
        run.m.ongoing.expectations = [x]
        let fx = run.step(.tick, at: 1)
        #expect(fx.map(\.traceName) == ["persist(intention)"])
        let it = run.m.ongoing.intentions[0]
        #expect(it.kind == .followUp && it.subject == x.subject && it.person == Kit.john && it.priority == 0.8)
        #expect(it.notBefore == x.due.addingTimeInterval(2 * Self.hour) && it.expires == x.expires)
        #expect(it.reason == "they were nervous about it" && it.source == "plan")
        #expect(run.step(.tick, at: 2).isEmpty, "never twice")
        #expect(run.m.ongoing.intentions.count == 1)
    }

    @Test func planSignalCreatesTheExpectation() {
        var run = ReducerRun(IntentionBoard())
        let due = Kit.t0.addingTimeInterval(3 * Self.day)
        Self.inject(&run, "plan", subject: "job interview", value: due.timeIntervalSinceReferenceDate, label: "excited")
        #expect(run.step(.tick, at: 1).isEmpty, "nobody identified: whose plan?")
        #expect(run.m.ongoing.expectations.isEmpty)

        run.m.ongoing.person = Kit.john
        Self.inject(&run, "plan", subject: "job interview", value: due.timeIntervalSinceReferenceDate, label: "excited")
        let fx = run.step(.tick, at: 2)
        #expect(fx.map(\.traceName) == ["persist(expectation)", "persist(intention)"])
        let x = run.m.ongoing.expectations[0]
        #expect(x.subject.text == "job interview" && x.person == Kit.john && x.framing == .excited && x.status == .pending)
        #expect(x.due == due && x.expires == due.addingTimeInterval(7 * Self.day))
        #expect(run.m.ongoing.intentions[0].reason == "they were excited about it")

        Self.inject(&run, "plan", subject: "interview", value: due.timeIntervalSinceReferenceDate, label: "nervous")
        #expect(run.step(.tick, at: 3).isEmpty, "the same plan again is not a second expectation")

        Self.inject(&run, "plan", subject: "eye test", value: due.timeIntervalSinceReferenceDate, label: "nervous+health")
        run.step(.tick, at: 4)
        #expect(run.m.ongoing.expectations.contains { $0.subject.text == "eye test" })
        #expect(run.m.ongoing.intentions.last?.reason == IntentionBoard.healthReason, "Interpreter's health flag is kept")
        Self.inject(&run, "plan", subject: "party", value: due.timeIntervalSinceReferenceDate, label: "bogus")
        #expect(run.step(.tick, at: 5).isEmpty, "an undecodable plan is ignored")
    }

    @Test func followUpFiresOnlyWhenEveryRuleHolds() {
        var run = Self.interviewBoard()
        let ready = 2 * Self.hour + 60
        run.step(Kit.heard("hi"), at: Self.hour)
        #expect(Self.aims(run).isEmpty, "before due + 2 h")

        run.m.ongoing.person = nil
        run.step(Kit.heard("hi"), at: ready)
        #expect(Self.aims(run).isEmpty, "nobody identified")
        run.m.ongoing.person = Kit.ann
        run.step(Kit.heard("hi"), at: ready + 1)
        #expect(Self.aims(run).isEmpty, "someone else")

        run.m.ongoing.person = Kit.john
        run.m.ongoing.turnsThisConversation = 0
        run.step(Kit.heard("hi"), at: ready + 2)
        #expect(Self.aims(run).isEmpty, "no user turn yet")

        run.m.ongoing.turnsThisConversation = 1
        run.step(.presence(arrived: true), at: ready + 3)
        // Their first turn, even within 10 s of arrival: the arrival grace only holds
        // back initiative (live transcript: the reunion turn is where Dee asks).
        run.step(Kit.heard("hi"), at: ready + 8)
        let n = Self.aims(run)
        #expect(n.count == 1)
        #expect(n.first?.text == "(Ask how their job interview went. They were nervous about it.)")
        #expect(n.first?.intention == run.m.ongoing.intentions[0].id)
    }

    @Test func oneFollowUpPerConversation() {
        var run = Self.interviewBoard()
        run.m.ongoing.expectations.append(Self.expectation("driving test", due: 2 * Self.hour, framing: .excited))
        run.step(.tick, at: 2)
        #expect(run.m.ongoing.intentions.count == 2)
        let t = 3 * Self.hour
        run.step(Kit.heard("hi"), at: t)
        let first = Self.aims(run)
        #expect(first.map(\.slots.first) == ["job interview"], "the driving test is not due yet")
        run.issue(first[0])
        run.m.ongoing.noteCandidates = []
        run.step(.deeTurnFinished(text: "So how did the interview go?"), at: t + 5)
        for k in 1...4 { run.step(Kit.heard("ok"), at: t + 10 * Double(k)) }
        run.step(Kit.heard("ok"), at: 4 * Self.hour + 10)
        #expect(Self.aims(run).isEmpty, "the other follow-up waits for another conversation")
        run.step(.conversationStarted(Kit.t0.addingTimeInterval(5 * Self.hour)), at: 5 * Self.hour)
        run.step(Kit.heard("hey"), at: 5 * Self.hour + 20)
        #expect(Self.aims(run).map(\.slots.first) == ["driving test"])
    }

    @Test func healthSubjectsGetTheGentleVariant() {
        var run = ReducerRun(IntentionBoard())
        run.m.ongoing.expectations = [Self.expectation("knee surgery")]
        run.step(.tick, at: 1)
        run.m.ongoing.person = Kit.john
        run.m.ongoing.turnsThisConversation = 1
        run.step(Kit.heard("hi"), at: 3 * Self.hour)
        #expect(Self.aims(run).map(\.kind) == [.followUpGentle])
        #expect(Self.aims(run).first?.text == "(Gently ask how they've been feeling.)")
        // Review finding 11: the gentle note never names its subject, so any question in
        // the reply asked it; the next turn is the outcome.
        run.issue(Self.aims(run)[0])
        run.step(.deeTurnFinished(text: "Hey you. How are you feeling these days?"), at: 3 * Self.hour + 5)
        #expect(run.m.ongoing.expectations.first?.status == .asked)
        #expect(run.m.ongoing.intentions.first?.status == .done)
        run.step(Kit.heard("much better, thanks", Self.appraisal(valence: 0.5)), at: 3 * Self.hour + 20)
        #expect(run.m.ongoing.expectations.first?.status == .resolved)
    }

    @Test func askedThenOutcomeResolvesWithRelief() {
        var run = Self.interviewBoard()
        let t = 3 * Self.hour
        run.step(Kit.heard("hi Dee"), at: t)
        run.issue(Self.aims(run)[0])
        run.m.ongoing.noteCandidates = []
        var fx = run.step(.deeTurnFinished(text: "[curious] How did the interview go?"), at: t + 5)
        #expect(fx.map(\.traceName) == ["persist(intention)", "persist(expectation)"])
        #expect(run.m.ongoing.intentions[0].status == .done)
        #expect(run.m.ongoing.expectations[0].status == .asked)
        #expect(run.m.momentary.signals.contains { $0.name == "intentionDone" && $0.label == "followUp" })

        fx = run.step(Kit.heard("it went great actually!", Self.appraisal(valence: 0.7)), at: t + 12)
        #expect(fx.contains { $0.traceName.hasPrefix("remember") }, "the outcome goes to long-term memory")
        #expect(fx.filter { !$0.traceName.hasPrefix("remember") } == [.persist(.expectation(run.m.ongoing.expectations[0])), .appraise(.internal(relief: 0.3 + 0.5 * 0.7))])
        #expect(run.m.ongoing.expectations[0].status == .resolved && run.m.ongoing.expectations[0].outcomeValence == 0.7)
        let s = run.m.momentary.signals.first { $0.name == "followUpResolved" }
        #expect(s?.subject?.text == "job interview" && s?.value == 0.7 && s?.label == "nervous" && s?.id == run.m.ongoing.expectations[0].id)
        #expect(Self.aims(run).isEmpty)
        run.step(.tick, at: t + 13)
        #expect(run.m.ongoing.intentions.isEmpty && run.m.ongoing.expectations.isEmpty)
    }

    @Test func interpretersOutcomeSignalWins() {
        var run = Self.interviewBoard()
        let t = 3 * Self.hour
        run.step(Kit.heard("hi"), at: t)
        run.issue(Self.aims(run)[0])
        run.step(.deeTurnFinished(text: "How did the interview go?"), at: t + 5)
        let x = run.m.ongoing.expectations[0]
        Self.inject(&run, "expectationOutcome", subject: "job interview", value: 0.4, id: x.id, label: "asked")
        let fx = run.step(Kit.heard("great!", Self.appraisal(valence: 0.9)), at: t + 12)
        #expect(fx.filter { !$0.traceName.hasPrefix("remember") } == [.persist(.expectation(run.m.ongoing.expectations[0])), .appraise(.internal(relief: 0.3 + 0.5 * 0.4))],
                "resolved once, with Interpreter's outcome (valence − ½ distress)")
        #expect(run.m.ongoing.expectations[0].outcomeValence == 0.4)
    }

    @Test func interpretersUnpromptedOutcomeClosesTheFollowUp() {
        var run = Self.interviewBoard()
        let x = run.m.ongoing.expectations[0]
        Self.inject(&run, "expectationOutcome", subject: "job interview", value: -0.5, id: x.id, label: "unprompted")
        let fx = run.step(Kit.heard("the interview was awful"), at: Self.hour)
        #expect(fx.map(\.traceName) == ["persist(intention)", "persist(expectation)", "remember(event)"])
        #expect(run.m.ongoing.intentions[0].status == .done && run.m.ongoing.expectations[0].status == .resolved)
    }

    @Test func badNewsResolvesWithoutRelief() {
        var run = Self.interviewBoard()
        let t = 3 * Self.hour
        run.step(Kit.heard("hi"), at: t)
        run.issue(Self.aims(run)[0])
        run.step(.deeTurnFinished(text: "How was the interview?"), at: t + 5)
        let fx = run.step(Kit.heard("it went badly", Self.appraisal(valence: -0.6)), at: t + 12)
        #expect(fx.map(\.traceName) == ["persist(expectation)", "remember(event)"], "sympathy comes from Mind's own appraisal of their words")
        #expect(run.m.ongoing.expectations[0].status == .resolved && run.m.ongoing.expectations[0].outcomeValence == -0.6)
    }

    @Test func userBringingItUpFirstResolvesIt() {
        var run = ReducerRun(IntentionBoard())
        run.m.ongoing.expectations = [Self.expectation("job interview", due: Self.day)]
        run.step(.tick, at: 1)
        run.m.ongoing.person = Kit.john
        run.m.ongoing.turnsThisConversation = 1
        var fx = run.step(Kit.heard("my interview is tomorrow", Self.appraisal(valence: 0.5)), at: 12 * Self.hour)
        #expect(fx.isEmpty, "not happened yet")
        fx = run.step(Kit.heard("the interview went really well!", Self.appraisal(valence: 0.8)), at: Self.day + Self.hour)
        #expect(fx.map(\.traceName) == ["persist(intention)", "persist(expectation)", "appraise", "remember(event)"])
        #expect(run.m.ongoing.intentions[0].status == .done && run.m.ongoing.expectations[0].status == .resolved)
        #expect(Self.aims(run).isEmpty, "nothing left to ask")
    }

    /// Scenario 1b: ignored aim → re-issued once after ≥ 2 turns → dropped silently; no third cue.
    @Test func ignoredAimIsReissuedOnceThenDroppedSilently() {
        var run = Self.interviewBoard()
        let t = 3 * Self.hour
        run.step(Kit.heard("hi"), at: t)
        run.issue(Self.aims(run)[0])
        run.m.ongoing.noteCandidates = []
        #expect(run.step(.deeTurnFinished(text: "Nice weather today."), at: t + 5).isEmpty)
        #expect(run.m.ongoing.intentions[0].status == .issued && run.m.ongoing.intentions[0].issuedCount == 1)
        run.step(Kit.heard("yeah"), at: t + 10)
        #expect(Self.aims(run).isEmpty, "only one turn since")
        run.step(Kit.heard("so anyway"), at: t + 20)
        #expect(Self.aims(run).count == 1, "re-eligible after 2 turns")
        run.issue(Self.aims(run)[0])
        run.m.ongoing.noteCandidates = []
        let fx = run.step(.deeTurnFinished(text: "Sure."), at: t + 25)
        #expect(fx.map(\.traceName) == ["persist(intention)", "persist(expectation)"])
        #expect(run.m.ongoing.intentions[0].status == .dropped && run.m.ongoing.intentions[0].issuedCount == 2)
        #expect(run.m.ongoing.expectations[0].status == .expired, "never asked again, not even after a relaunch")
        for k in 1...4 { run.step(Kit.heard("hm"), at: t + 30 + Double(k)) }
        #expect(Self.aims(run).isEmpty, "no third cue")
        #expect(run.m.ongoing.noteCandidates.allSatisfy { !$0.text.contains("interview") })
    }

    /// Scenario 2 / D5: something that expired while the user was away is never mentioned.
    @Test func expiredWhileAwayIsNeverMentioned() {
        var run = ReducerRun(IntentionBoard())
        let x = Self.expectation("job interview")
        var board = IntentionBoard()
        var it = Self.intention("job interview", status: .open, issued: 0, expires: 7 * Self.day)
        it.notBefore = Kit.t0.addingTimeInterval(2 * Self.hour)
        board.seed(from: Carried(intentions: [it], expectations: [x]), &run.m)
        run.r = board
        run.m.ongoing.person = Kit.john
        run.m.ongoing.turnsThisConversation = 1
        let fx = run.step(Kit.heard("hi Dee, I'm back", Self.appraisal(valence: 0.6)), at: 12 * Self.day)
        #expect(fx.map(\.traceName) == ["persist(intention)", "persist(expectation)"])
        #expect(run.m.ongoing.intentions[0].status == .dropped && run.m.ongoing.expectations[0].status == .expired)
        #expect(run.m.ongoing.noteCandidates.isEmpty)
        #expect(!fx.contains { if case .appraise = $0 { true } else { false } }, "no outcome for something never asked")
        run.step(.tick, at: 12 * Self.day + 1)
        #expect(run.m.ongoing.intentions.isEmpty && run.m.ongoing.expectations.isEmpty)
    }

    @Test func expectationsAndIntentionsAreCapped() {
        var run = ReducerRun(IntentionBoard())
        run.m.ongoing.expectations = (0..<10).map { Self.expectation("plan \($0)", due: Self.day + Double($0)) }
        run.step(.tick, at: 1)
        #expect(run.m.ongoing.intentions.filter(\.isLive).count == 10)
        run.m.ongoing.person = Kit.john
        Self.inject(&run, "plan", subject: "exam", value: Kit.t0.timeIntervalSinceReferenceDate + Self.day, label: "nervous")
        run.step(.tick, at: 2)
        #expect(run.m.ongoing.expectations.filter { $0.status == .pending }.count == Ongoing.maxPendingExpectations)
        #expect(run.m.ongoing.intentions.filter(\.isLive).count == Ongoing.maxPendingExpectations, "their follow-ups go too")
        #expect(Set(run.m.ongoing.expectations.map(\.subject.text)).isDisjoint(with: ["plan 7", "plan 8", "plan 9"]),
                "none is past due: the furthest in the future go (silently, then off the board)")
        run.m.ongoing.intentions += (0..<12).map { Self.ask("topic \($0)", priority: 0.1 + 0.01 * Double($0)) }
        Self.inject(&run, "plan", subject: "recital", value: Kit.t0.timeIntervalSinceReferenceDate + Self.day, label: "excited")
        run.step(.tick, at: 3)
        #expect(run.m.ongoing.intentions.filter(\.isLive).count == Ongoing.maxOpenIntentions)
        #expect(!run.m.ongoing.intentions.contains { $0.isLive && $0.subject.text == "topic 0" }, "the least important goes")
    }

    // MARK: Scoring (§7.6)

    @Test func scoreFormula() {
        #expect(abs(IntentionBoard.score(priority: 0.8, relevance: 0.6, timing: 1, urge: 0.5) - 0.48) < 1e-9)
        #expect(IntentionBoard.score(priority: 0.8, relevance: 1, timing: 0, urge: 1) == 0)
        #expect(abs(IntentionBoard.score(priority: 1, relevance: 1, timing: 1, urge: 1) - 1.5) < 1e-9)
        #expect(abs(IntentionBoard.score(priority: 2, relevance: 1, timing: 1, urge: -1) - 0.5) < 1e-9, "inputs clamped")
    }

    @Test func relevanceAndTheAimThreshold() {
        var run = ReducerRun(IntentionBoard())
        run.m.ongoing.person = Kit.john
        let urge = run.m.ongoing.mind.urgeToTalk
        let it = Self.ask("guitar", priority: 0.5)
        run.m.ongoing.intentions = [it]
        #expect(IntentionBoard.score(priority: 0.5, relevance: 0.6, timing: 1, urge: urge) < IntentionBoard.aimThreshold)
        run.step(Kit.heard("hello"), at: 1)
        #expect(Self.aims(run).isEmpty, "person match only: p ≈ 0.29")
        run.m.ongoing.topic = [Subject("guitar")!]
        run.step(Kit.heard("I've been playing a lot"), at: 2)
        #expect(Self.aims(run).map(\.text) == ["(Ask one short question about guitar.)"], "subject match: p ≈ 0.48")
        run.m.ongoing.noteCandidates = []
        run.m.ongoing.topic = []
        run.m.momentary.focus = .referent(Subject("guitar")!, .back)
        run.step(Kit.heard("look"), at: 3)
        #expect(Self.aims(run).count == 1, "the focus counts as a subject match")
    }

    @Test func atMostOneAimPerUserTurnBestFirst() {
        var run = ReducerRun(IntentionBoard())
        run.m.ongoing.person = Kit.john
        run.m.ongoing.topic = [Subject("guitar")!, Subject("garden")!]
        run.m.ongoing.intentions = [Self.ask("garden", priority: 0.6), Self.ask("guitar", priority: 0.9)]
        run.step(Kit.heard("hi"), at: 1)
        #expect(Self.aims(run).map(\.slots) == [["Ask one short question about guitar."]])
    }

    @Test func notBeforeAndPersonGates() {
        var run = ReducerRun(IntentionBoard())
        run.m.ongoing.topic = [Subject("guitar")!]
        run.m.ongoing.intentions = [Self.ask("guitar", notBefore: 100)]
        run.m.ongoing.person = Kit.john
        run.step(Kit.heard("hi"), at: 50)
        #expect(Self.aims(run).isEmpty)
        run.m.ongoing.person = Kit.ann
        run.step(Kit.heard("hi"), at: 150)
        #expect(Self.aims(run).isEmpty, "John's intention is not for Ann")
        run.m.ongoing.person = Kit.john
        run.step(Kit.heard("hi"), at: 151)
        #expect(Self.aims(run).count == 1)
    }

    // MARK: Repair and boundaries

    @Test func repairsJumpTheQueueAndAnOpenRuptureSilencesTheRest() {
        var run = Self.interviewBoard()
        var repair = Self.ask("last night", kind: .repair, priority: 0.5)
        repair.person = Kit.john
        run.m.ongoing.intentions.append(repair)
        run.m.ongoing.repair = .ruptured
        run.step(Kit.heard("hi"), at: 3 * Self.hour)
        #expect(Self.aims(run).map(\.text) == ["(Make things right with them, briefly and warmly.)"])
        run.m.ongoing.intentions.removeAll { $0.kind == .repair }
        run.m.ongoing.noteCandidates = []
        run.step(Kit.heard("hm"), at: 3 * Self.hour + 10)
        #expect(Self.aims(run).isEmpty, "no follow-up while ruptured")
        run.m.ongoing.repair = .strained
        run.step(Kit.heard("ok"), at: 3 * Self.hour + 20)
        #expect(Self.aims(run).map(\.kind) == [.followUp])
    }

    @Test func userBoundaryDropsAndAvoidsTheTopic() {
        var run = Self.interviewBoard()
        run.m.ongoing.intentions.append(Self.ask("job", priority: 0.9))
        run.m.enduring.boundaries = [Boundary(id: UUID(), person: Kit.john, topic: Subject("job")!, owner: .user, createdAt: Kit.t0)]
        let fx = run.step(.tick, at: 5)
        #expect(fx.map(\.traceName) == ["persist(intention)", "persist(expectation)", "persist(intention)"],
                "both dropped silently ('job interview' overlaps 'job'); the expectation is never asked")
        #expect(!run.m.ongoing.intentions.contains { $0.isLive && $0.subject.text == "job" })
        Self.inject(&run, "plan", subject: "new job", value: Kit.t0.timeIntervalSinceReferenceDate + Self.day, label: "nervous")
        run.step(.tick, at: 6)
        #expect(!run.m.ongoing.expectations.contains { $0.subject.text == "new job" }, "no plan on a forbidden topic")
        run.step(.sight(camera: .back, things: ["job board"], novel: ["job board"]), at: 7)
        run.step(Kit.heard("hey"), at: 3 * Self.hour)
        #expect(!Self.aims(run).contains { $0.text.contains("job") })
    }

    // MARK: Curiosity candidates

    @Test func curiositySightBecomesAnAimAndIsCommittedOnIssue() {
        var run = ReducerRun(IntentionBoard())
        run.m.ongoing.person = Kit.john
        run.step(.sight(camera: .back, things: ["guitar"], novel: ["guitar"]), at: 1)
        run.step(Kit.heard("hey"), at: 5)
        let n = Self.aims(run)
        #expect(n.count == 1 && n[0].kind == .intention && n[0].text.contains("guitar") && n[0].intention != nil)
        #expect(n[0].text.count <= 90 && CueWriter.estimateTokens(n[0].text) <= CueWriter.maxNoteTokens)
        run.issue(n[0])
        run.m.ongoing.noteCandidates = []
        #expect(run.m.ongoing.intentions.isEmpty, "curiosity is never an Intention row")
        run.step(Kit.heard("yes"), at: 10)
        #expect(Self.aims(run).isEmpty, "committed: the director's 20 min cooldown")
    }

    @Test func generalTopicsAreNeverAimsOnAUserTurn() {
        var run = ReducerRun(IntentionBoard(), mind: Self.chatty)
        run.m.ongoing.person = Kit.john
        run.m.momentary.focus = .person(Kit.john)
        run.step(.head(yaw: 0, pitch: 0), at: 0)
        for t in stride(from: 10.0, through: 300, by: 10) { run.step(Kit.heard("so yeah"), at: t) }
        #expect(Self.aims(run).isEmpty, "Dee answers what was said")
    }

    // MARK: Initiative

    static func idleRun(mind: MindSnapshot = Kit.snap()) -> ReducerRun<IntentionBoard> {
        var run = ReducerRun(IntentionBoard(), mind: mind)
        run.m.ongoing.person = Kit.john
        run.m.momentary.mutualGazeSince = Kit.t0
        run.step(.head(yaw: 0, pitch: 0), at: 0)
        return run
    }

    @Test func initiativeWhenIdleWithMutualGaze() {
        var run = Self.idleRun()
        let it = Self.ask("guitar", priority: 0.7)
        run.m.ongoing.intentions = [it]
        run.m.ongoing.topic = [Subject("guitar")!]
        run.step(.tick, at: 5)
        let req = run.m.momentary.initiative
        #expect(req?.owner == IntentionBoard.name)
        #expect(req?.aim?.text == "(Ask one short question about guitar.)" && req?.aim?.intention == it.id)
        #expect(abs((req?.score ?? 0) - 0.7 * (0.5 + run.m.ongoing.mind.urgeToTalk)) < 1e-9)
        #expect(Self.aims(run).isEmpty, "an initiative is a request, not a note candidate")
    }

    @Test func initiativeGates() {
        func check(_ name: String, expect want: Bool, _ tweak: (inout ReducerRun<IntentionBoard>) -> Void) {
            var run = Self.idleRun()
            run.m.ongoing.intentions = [Self.ask("guitar", priority: 0.7)]   // p ≈ 0.68
            run.m.ongoing.topic = [Subject("guitar")!]
            tweak(&run)
            run.step(.tick, at: 5)
            #expect((run.m.momentary.initiative != nil) == want, Comment(rawValue: name))
        }
        check("baseline", expect: true) { _ in }
        check("the user is speaking", expect: false) { $0.m.momentary.floor = .userSpeaking(since: Kit.t0) }
        check("Dee is speaking", expect: false) { $0.m.momentary.floor = .deeSpeaking(since: Kit.t0) }
        check("no mutual gaze", expect: false) { $0.m.momentary.mutualGazeSince = nil }
        check("busy: needs > 0.85", expect: false) {
            $0.m.ongoing.hypotheses = [Hypothesis(kind: .busy, value: "busy", confidence: 0.6, expires: Kit.t0.addingTimeInterval(600))]
        }
        check("an expired busy hypothesis", expect: true) {
            $0.m.ongoing.hypotheses = [Hypothesis(kind: .busy, value: "busy", confidence: 0.6, expires: Kit.t0.addingTimeInterval(1))]
        }
        check("wants quiet", expect: false) {
            $0.m.ongoing.hypotheses = [Hypothesis(kind: .wantsQuiet, value: "quiet", confidence: 0.6, expires: Kit.t0.addingTimeInterval(600))]
        }
        check("askedTooMuch lesson: +0.1", expect: false) {
            $0.m.enduring.lessons = [Lesson(id: UUID(), person: Kit.john, situation: .askedTooMuch, createdAt: Kit.t0)]
        }
        check("asleep", expect: false) { $0.step(.asleep(true), at: 1) }
        check("they just spoke", expect: false) { $0.step(Kit.heard("hm"), at: 4) }
        check("they left", expect: false) { $0.step(.presence(arrived: false), at: 1) }
    }

    @Test func busyHypothesisStillAllowsAPressingInitiative() {
        var run = Self.idleRun(mind: Self.chatty)
        run.m.ongoing.intentions = [Self.ask("guitar", priority: 0.9)]
        run.m.ongoing.topic = [Subject("guitar")!]
        run.m.ongoing.hypotheses = [Hypothesis(kind: .busy, value: "busy", confidence: 0.6, expires: Kit.t0.addingTimeInterval(600))]
        run.step(.tick, at: 5)
        #expect((run.m.momentary.initiative?.score ?? 0) > IntentionBoard.busyInitiativeThreshold)
    }

    /// Very interactive, never spammy: 20 s between initiatives, doubled per unanswered
    /// one, none after 3 unanswered until the user engages again.
    @Test func initiativePacingBacksOffAndResets() {
        var run = Self.idleRun(mind: Self.chatty)
        run.m.ongoing.intentions = ["guitar", "piano", "garden", "cooking", "chess"].map { Self.ask($0, priority: 1) }
        func speak(at t: Double) -> Bool {
            run.step(.tick, at: t)
            guard let aim = run.m.momentary.initiative?.aim else { return false }
            run.issue(aim)   // Cortex took it: the note is issued
            return true
        }
        #expect(speak(at: 10))
        #expect(run.r.unansweredInitiatives == 1)
        #expect(!speak(at: 29))
        #expect(speak(at: 31), "20 s later")
        #expect(!speak(at: 70))
        #expect(speak(at: 72), "then 40 s")
        #expect(run.r.unansweredInitiatives == 3)
        #expect(!speak(at: 72 + 1_000), "3 unanswered: Dee waits for them")
        run.step(Kit.heard("sorry, what?"), at: 1_100)
        #expect(run.r.unansweredInitiatives == 0)
        #expect(!speak(at: 1_101), "quiet right after they speak")
        #expect(speak(at: 1_104))
    }

    @Test func curiosityInitiativeAboutWhatSheIsLookingAt() {
        var run = Self.idleRun()
        run.step(.sight(camera: .back, things: ["dog"], novel: ["dog"]), at: 1)
        run.m.momentary.focus = .referent(Subject("dog")!, .back)
        run.step(.tick, at: 2)
        let aim = run.m.momentary.initiative?.aim
        #expect(aim?.text.contains("dog") == true)
        run.issue(aim!)
        run.step(.tick, at: 30)
        #expect(run.m.momentary.initiative?.aim?.text.contains("dog") != true, "raised once (director cooldown)")
    }

    @Test func generalTopicsFillALullWhenSheIsLookedAt() {
        var run = Self.idleRun(mind: Self.chatty)
        run.m.momentary.focus = .person(Kit.john)
        var spoke: [String] = []
        for t in stride(from: 1.0, through: 240, by: 1) {
            run.step(.tick, at: t)
            if let aim = run.m.momentary.initiative?.aim {
                spoke.append(aim.text)
                run.issue(aim)
            }
        }
        #expect(!spoke.isEmpty, "Dee starts talking when you look at Dee for a while")
        #expect(spoke.count <= 3, "but backs off when ignored: \(spoke)")
        for s in spoke {
            #expect(CueWriter.estimateTokens(s) <= CueWriter.maxNoteTokens)
            #expect(!CueWriter.reproachWords.contains { s.lowercased().contains($0) })
        }
    }

    // MARK: Self-motivated intentions

    @Test func learnIntentionIsBornFromAStrongInterestSheKnowsLittleAbout() {
        var run = ReducerRun(IntentionBoard())
        run.m.ongoing.interests = [Interest(subject: Subject("astronomy")!, weight: 0.8, lastTouched: Kit.t0),
                                   Interest(subject: Subject("chess")!, weight: 0.65, lastTouched: Kit.t0),
                                   Interest(subject: Subject("knitting")!, weight: 0.5, lastTouched: Kit.t0)]
        let fx = run.step(.tick, at: 1)
        #expect(fx.map(\.traceName) == ["persist(intention)"])
        let it = run.m.ongoing.intentions[0]
        #expect(it.kind == .learn && it.subject.text == "astronomy" && it.person == nil && it.stepsNeeded == 2 && it.source == "interest")
        #expect(run.step(.tick, at: 2).isEmpty, "one birth per day")
        run.step(.tick, at: Self.day + 2)
        #expect(run.m.ongoing.intentions.map(\.subject.text) == ["astronomy", "chess"])
        run.step(.tick, at: 3 * Self.day)
        #expect(run.m.ongoing.intentions.count == 2, "knitting is not interesting enough (≤ 0.6)")
    }

    @Test func noLearnIntentionWhenSheAlreadyKnows() {
        var run = ReducerRun(IntentionBoard())
        run.m.ongoing.interests = [Interest(subject: Subject("astronomy")!, weight: 0.8, lastTouched: Kit.t0),
                                   Interest(subject: Subject("chess")!, weight: 0.8, lastTouched: Kit.t0)]
        let ep = EpisodeKey(id: UUID(), person: Kit.john, end: Kit.t0, topics: [Subject("astronomy")!], salience: 0.5, recalled: 0)
        var ep2 = ep
        ep2.id = UUID()
        run.m.enduring.episodeIndex = [ep, ep2]
        Self.inject(&run, "facts", subject: "chess", value: 3)
        #expect(run.step(.tick, at: 1).isEmpty)
        #expect(run.m.ongoing.intentions.isEmpty)
    }

    @Test func atMostThreeSelfMotivated() {
        var run = ReducerRun(IntentionBoard())
        run.m.ongoing.interests = ["a1 topic", "b2 topic", "c3 topic", "d4 topic"].map {
            Interest(subject: Subject($0)!, weight: 0.9, lastTouched: Kit.t0)
        }
        for d in 0..<6 { run.step(.tick, at: Double(d) * Self.day + 1) }
        #expect(run.m.ongoing.intentions.filter(\.isSelfMotivated).count == Ongoing.maxSelfMotivated)
    }

    @Test func learnStepsThenPrideAndAShareLater() {
        var run = ReducerRun(IntentionBoard())
        run.m.ongoing.person = Kit.john
        run.m.ongoing.topic = [Subject("astronomy")!]
        let it = Self.ask("astronomy", kind: .learn, priority: 0.55, person: nil, expires: 14 * Self.day, steps: 2)
        run.m.ongoing.intentions = [it]
        run.step(Kit.heard("I love stars"), at: 1)
        #expect(Self.aims(run).map(\.text) == ["(Ask one short question to learn more about astronomy.)"])
        run.issue(Self.aims(run)[0])
        run.m.ongoing.noteCandidates = []
        var fx = run.step(.deeTurnFinished(text: "What got you into astronomy?"), at: 5)
        #expect(fx.map(\.traceName) == ["persist(intention)"])
        let mid = run.m.ongoing.intentions[0]
        #expect(mid.status == .open && mid.stepsDone == 1 && mid.issuedCount == 0 && mid.notBefore == Kit.t0.addingTimeInterval(5 + 600))
        run.step(Kit.heard("my dad"), at: 60)
        #expect(Self.aims(run).isEmpty, "a rest between steps")
        run.step(Kit.heard("we had a telescope"), at: 700)
        run.issue(Self.aims(run)[0])
        fx = run.step(.deeTurnFinished(text: "Which planet do you like best in astronomy?"), at: 705)
        #expect(fx == [.persist(.intention(run.m.ongoing.intentions[0])), .appraise(.internal(pride: IntentionBoard.learnPride))])
        #expect(run.m.ongoing.intentions[0].status == .done && run.m.ongoing.intentions[0].stepsDone == 2)
        #expect(run.r.shareQueue == [Subject("astronomy")!])
        run.step(.tick, at: 710)
        let share = run.m.ongoing.intentions.first { $0.kind == .share }
        #expect(share?.subject.text == "astronomy", "learning becomes something to contribute")
        #expect(IntentionBoard.action(for: share!) == "Share one small thought you've had about astronomy.")
    }

    @Test func skillIsBornFromRepeatedMisreadsAndDoneAfterFiveCleanConversations() {
        var run = ReducerRun(IntentionBoard())
        let d = Self.day
        run.m.ongoing.recentMisreads = [Misread(id: UUID(), person: Kit.john, at: Kit.t0, situation: .moodGuess),
                                        Misread(id: UUID(), person: Kit.john, at: Kit.t0.addingTimeInterval(2 * d), situation: .moodGuess)]
        run.step(.tick, at: 3 * d)
        let skill = run.m.ongoing.intentions.first
        #expect(skill?.kind == .skill && skill?.subject.text == "reading their mood" && skill?.person == Kit.john && skill?.stepsNeeded == 5)

        var t = 3 * d + 10
        run.m.ongoing.conversationStarted = Kit.t0.addingTimeInterval(t)
        func conversation(misread: Bool) -> [Effect] {
            run.m.ongoing.person = Kit.john
            run.m.ongoing.turnsThisConversation = 1
            run.m.ongoing.misreadThisTurn = misread ? Misread(id: UUID(), person: Kit.john, at: Kit.t0.addingTimeInterval(t), situation: .moodGuess) : nil
            run.step(Kit.heard("hi"), at: t)
            #expect(!Self.aims(run).contains { $0.text.contains("mood") }, "practice is behavioural: never an aim")
            run.m.ongoing.misreadThisTurn = nil
            t += 600
            let fx = run.step(.conversationStarted(Kit.t0.addingTimeInterval(t)), at: t)
            run.m.ongoing.conversationStarted = Kit.t0.addingTimeInterval(t)
            t += 600
            return fx
        }
        for k in 1...4 {
            #expect(conversation(misread: false).map(\.traceName) == ["persist(intention)"])
            #expect(run.m.ongoing.intentions[0].stepsDone == k)
        }
        #expect(conversation(misread: true).isEmpty, "slipped again: not a clean one")
        let fx = conversation(misread: false)
        #expect(fx.contains(.appraise(.internal(pride: IntentionBoard.skillPride))))
        #expect(fx.contains { if case .persist(.intention(let i)) = $0 { i.kind == .skill && i.status == .done && i.stepsDone == 5 } else { false } })
        #expect(run.m.ongoing.intentions.isEmpty, "done, persisted, off the board")
    }

    @Test func misreadsTooFarApartAreNotASkill() {
        var run = ReducerRun(IntentionBoard())
        run.m.ongoing.recentMisreads = [Misread(id: UUID(), person: Kit.john, at: Kit.t0, situation: .moodGuess),
                                        Misread(id: UUID(), person: Kit.john, at: Kit.t0.addingTimeInterval(9 * Self.day), situation: .moodGuess),
                                        Misread(id: UUID(), person: Kit.ann, at: Kit.t0.addingTimeInterval(9 * Self.day), situation: .tookLiterally)]
        run.step(.tick, at: 9 * Self.day + 1)
        #expect(run.m.ongoing.intentions.isEmpty)
    }

    /// Review finding 15: Learner raises the goodnight aim on the same step, so the board
    /// no longer turns the signal into a (late) intention.
    @Test func ritualSignalsAreLearnersToPerform() {
        var run = ReducerRun(IntentionBoard())
        run.m.ongoing.person = Kit.john
        Self.inject(&run, "ritual", label: "goodnight", owner: "Learner")
        #expect(run.step(.tick, at: 1).isEmpty)
        #expect(run.m.ongoing.intentions.isEmpty)
        run.step(Kit.heard("night Dee"), at: 3)
        #expect(Self.aims(run).isEmpty, "no second goodnight a turn later")
        Self.inject(&run, "ritual", label: "firstSightOfDay", owner: "Learner")
        #expect(run.step(.tick, at: 4).isEmpty, "Learner performs the morning hello itself")
    }

    // MARK: Privacy and people

    @Test func forgetScrubsPrivateState() {
        var run = Self.interviewBoard()
        let s = Subject("interview")!
        run.m.forget(subject: s)
        run.r.forget(subject: s, &run.m)
        #expect(run.m.ongoing.intentions.isEmpty && run.m.ongoing.expectations.isEmpty)
        Self.inject(&run, "plan", subject: "job interview", value: Kit.t0.timeIntervalSinceReferenceDate + Self.day, label: "nervous")
        run.step(.tick, at: 5)
        #expect(run.m.ongoing.expectations.isEmpty, "a forgotten subject is not re-learnt this session")
        run.step(.sight(camera: .back, things: ["interview suit"], novel: ["interview suit"]), at: 6)
        run.step(Kit.heard("hi"), at: 7)
        #expect(Self.aims(run).isEmpty)
    }

    @Test func forgetAllAndMerge() {
        var run = Self.interviewBoard()
        run.step(Kit.heard("hi"), at: 3 * Self.hour)
        run.issue(Self.aims(run)[0])
        run.r.merge(from: Kit.john, into: Kit.ann, &run.m)
        #expect(run.r.peopleThisConversation == [Kit.ann])
        run.m.forgetAll()
        run.r.forgetAll(&run.m)
        #expect(run.r.aimedThisTurn.isEmpty && run.r.followedUpThisConversation.isEmpty && run.r.turn == 0)
        #expect(run.r.shareQueue.isEmpty && run.r.lastBirth == nil)
    }

    // MARK: Wording

    @Test func everyActionFitsItsNote() {
        let long = String(repeating: "x", count: 9) + " " + String(repeating: "y", count: 9) + " " + String(repeating: "z", count: 9)
            + " " + String(repeating: "w", count: 9)
        for kind in Intention.Kind.allCases {
            var it = Self.ask(long, kind: kind)
            it.subject = Subject(long)!
            let a = IntentionBoard.action(for: it)
            #expect(a.count <= IntentionBoard.maxAction, Comment(rawValue: "\(kind): \(a.count)"))
            #expect(CueWriter.estimateTokens(Note.intention(nextAction: a, intention: it.id).text) <= CueWriter.maxNoteTokens)
        }
        // Every candidate the director can produce, in every mood.
        let moods: [MindSnapshot] = [Kit.snap(), Kit.angry, Kit.sad, Self.chatty,
                                     Kit.snap([.boredom: 0.9, .interest: 0.1]), Kit.snap([.energy: 0.1])]
        var seen = 0
        for (i, mind) in moods.enumerated() {
            var d = CuriosityDirector(seed: UInt64(i))
            let t = Kit.t0
            d.note(.userArrived, at: t)
            d.noteSight(["guitar", "dog", "a very long label for a thing nobody names"], camera: "back", novelty: 0.9, at: t)
            d.noteSound("doorbell", unexpected: true, loudness: 0.8, at: t)
            d.noteSound("music", unexpected: false, loudness: nil, at: t)
            d.note(.touched("pet"), at: t)
            for c in [5.0, 120].flatMap({ d.candidates(at: t.addingTimeInterval($0), snapshot: mind, userPresent: true, busy: false) }) {
                let a = IntentionBoard.action(for: c)
                seen += 1
                #expect(a.count <= IntentionBoard.maxAction && !a.isEmpty)
                #expect(!CueWriter.reproachWords.contains { a.lowercased().contains($0) }, Comment(rawValue: a))
                #expect(!a.hasPrefix("(") && !a.hasSuffix(")"))
            }
        }
        #expect(seen > 20)
    }

    @Test func healthWordsAreDetected() {
        #expect(IntentionBoard.isHealth(Subject("knee surgery")!))
        // Tune 4 decision (a): ordinary appointments are asked by name, not gently.
        #expect(!IntentionBoard.isHealth(Subject("doctor's appointment")!))
        #expect(IntentionBoard.isOrdinaryAppointment(Subject("doctor's appointment")!))
        #expect(!IntentionBoard.isHealth(Subject("dentist appointment")!))
        #expect(IntentionBoard.isHealth(Subject("biopsy results")!))
        #expect(!IntentionBoard.isHealth(Subject("job interview")!))
    }

    // MARK: Determinism and the whole pipeline

    static func script(_ run: inout ReducerRun<IntentionBoard>) -> [String] {
        var log: [String] = []
        let timeline: [(Double, Percept)] = [
            (0, .head(yaw: 0, pitch: 0)), (1, .sight(camera: .back, things: ["cat"], novel: ["cat"])), (2, .tick),
            (5, Kit.heard("hi")), (10, .tick), (40, .tick), (80, .tick), (3 * hour, Kit.heard("hey")), (3 * hour + 5, .tick),
        ]
        run.m.ongoing.expectations = [Self.expectation("exam", framing: .excited)]
        run.m.ongoing.person = Kit.john
        run.m.ongoing.turnsThisConversation = 1
        run.m.momentary.mutualGazeSince = Kit.t0
        run.m.ongoing.interests = [Interest(subject: Subject("rockets")!, weight: 0.9, lastTouched: Kit.t0)]
        for (t, p) in timeline {
            let fx = run.step(p, at: t)
            if let aim = run.m.momentary.initiative?.aim { run.issue(aim) }
            for n in Self.aims(run) { run.issue(n) }
            log.append("\(t) \(fx.map(\.traceName)) \(IntentionBoard.slice(of: run.m).sorted { $0.key < $1.key })")
            run.m.ongoing.noteCandidates = []
        }
        return log
    }

    @Test func deterministicReplay() {
        var a = ReducerRun(IntentionBoard(), seed: 9)
        var b = ReducerRun(IntentionBoard(), seed: 9)
        #expect(Self.script(&a) == Self.script(&b))
    }

    @Test func throughCortexTheInterviewIsFollowedUp() {
        let x = Self.expectation("job interview")
        var it = Self.intention("job interview", status: .open, issued: 0, expires: 7 * Self.day)
        it.notBefore = x.due.addingTimeInterval(2 * Self.hour)
        var cx = Kit.cortex(carried: Carried(intentions: [it], expectations: [x]))
        let t = Kit.t0.addingTimeInterval(Self.day)
        _ = cx.step(.identified(Kit.john, distance: 0), mind: Kit.snap(), at: t)   // name-confirmed: identified at once
        _ = cx.step(Kit.heard("hi Dee"), mind: Kit.snap(), at: t.addingTimeInterval(20))
        _ = cx.step(.promptSubmitted, mind: Kit.snap(), at: t.addingTimeInterval(21))
        let (cue, fx) = cx.cue(at: t.addingTimeInterval(21))
        #expect(cue.contains("(Ask how their job interview went. They were nervous about it.)"))
        #expect(fx.map(\.traceName) == ["persist(intention)"])
        _ = cx.step(.deeTurnFinished(text: "[curious] How did the interview go?"), mind: Kit.snap(), at: t.addingTimeInterval(25))
        #expect(cx.moment.ongoing.intentions.first?.status == .done)
        let out = cx.step(Kit.heard("it went great actually!", Self.appraisal(valence: 0.8)), mind: Kit.snap(), at: t.addingTimeInterval(30))
        #expect(out.contains(.appraise(.internal(relief: 0.3 + 0.5 * 0.8))))
        _ = cx.step(.promptSubmitted, mind: Kit.snap(), at: t.addingTimeInterval(31))
        #expect(!cx.cue(at: t.addingTimeInterval(31)).cue.contains("interview"), "exactly once")
    }

    // MARK: Goldens

    /// Records a trace with ReducerRun; `nil` percept = the board's pending aim (or
    /// initiative) is issued at that time. Candidates are cleared after each step, as a cue would.
    static func record(_ name: String, _ run: inout ReducerRun<IntentionBoard>, _ timeline: [(Double, Percept?)]) -> GoldenTrace {
        var steps: [TraceStep] = []
        var pending: [Note] = []
        for (t, p) in timeline {
            var fx: [Effect]
            let label: String
            if let p {
                fx = run.step(p, at: t)
                label = describe(p)
                pending = Self.aims(run) + [run.m.momentary.initiative?.aim].compactMap { $0 }
            } else {
                run.m.now = Kit.t0.addingTimeInterval(t)
                fx = pending.flatMap { run.issue($0) }
                label = "issue(" + pending.map(\.kind.rawValue).joined(separator: ",") + ")"
                pending = []
            }
            steps.append(TraceStep(t: t, percept: label, effects: fx.map(\.traceName), slice: IntentionBoard.slice(of: run.m)))
            run.m.ongoing.noteCandidates = []
        }
        return GoldenTrace(reducer: IntentionBoard.name, name: name, steps: steps)
    }

    @Test func goldenFollowThrough() throws {
        // Two intentions whose aims were issued this turn (once and twice in total).
        var run = ReducerRun(IntentionBoard(), seed: 7)
        let a = Self.intention("job interview", issued: 0), b = Self.intention("guitar", issued: 1)
        run.m.ongoing.intentions = [a, b]
        run.issue(Self.aim(a))
        run.issue(Self.aim(b))
        try Golden.verify(Self.record("follow-through", &run, [(1, .deeTurnFinished(text: "So how did the interview go?")), (2, .tick)]))
    }

    @Test func goldenInterviewArc() throws {
        var run = ReducerRun(IntentionBoard(), seed: 7)
        run.m.ongoing.person = Kit.john
        run.m.ongoing.turnsThisConversation = 1
        Self.inject(&run, "plan", subject: "job interview", value: Kit.t0.addingTimeInterval(Self.day).timeIntervalSinceReferenceDate, label: "nervous")
        let d = Self.day
        try Golden.verify(Self.record("interview-arc", &run, [
            (1, .tick),
            (d + 3600, Kit.heard("hey")),                                  // before due + 2 h: nothing
            (d + 3 * 3600, Kit.heard("hi Dee")),                           // the follow-up aim
            (d + 3 * 3600 + 1, nil),
            (d + 3 * 3600 + 5, .deeTurnFinished(text: "How did the interview go?")),
            (d + 3 * 3600 + 12, Kit.heard("it went great!", Self.appraisal(valence: 0.7))),
            (d + 3 * 3600 + 13, .tick),
            (2 * d, Kit.heard("morning")),                                 // exactly once
        ]))
    }

    @Test func goldenIgnoredAim() throws {
        var run = Self.interviewBoard()
        let t = 3 * Self.hour
        try Golden.verify(Self.record("ignored-aim", &run, [
            (t, Kit.heard("hi")), (t + 1, nil), (t + 5, .deeTurnFinished(text: "Nice weather.")),
            (t + 10, Kit.heard("yeah")), (t + 20, Kit.heard("anyway")), (t + 21, nil), (t + 25, .deeTurnFinished(text: "Sure.")),
            (t + 30, Kit.heard("ok")), (t + 31, .tick),
        ]))
    }

    @Test func goldenInitiativePacing() throws {
        var run = Self.idleRun(mind: Self.chatty)
        run.m.ongoing.intentions = ["guitar", "piano", "garden", "cooking"].map { Self.ask($0, priority: 1) }
        var timeline: [(Double, Percept?)] = []
        for t in [10.0, 11, 29, 31, 32, 70, 72, 73, 500] { timeline.append((t, .tick)); timeline.append((t + 0.1, nil)) }
        timeline.append((600, Kit.heard("sorry, what?")))
        timeline.append((604, .tick))
        try Golden.verify(Self.record("initiative-pacing", &run, timeline))
    }
}
