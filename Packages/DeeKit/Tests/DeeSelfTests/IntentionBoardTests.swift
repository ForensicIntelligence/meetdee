import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// IntentionBoard (SELF.md §7.6). Owner: IntentionBoard. Goldens: `Fixtures/IntentionBoard/`.
@Suite struct IntentionBoardTests {
    static func intention(_ subject: String, status: Intention.Status = .issued, issued: Int = 1, expires: Double = 86_400) -> Intention {
        Intention(id: UUID(), kind: .followUp, subject: Subject(subject)!, person: Kit.john, reason: "they were nervous about it",
                  notBefore: Kit.t0, expires: Kit.t0.addingTimeInterval(expires), priority: 0.8, status: status, issuedCount: issued,
                  source: "plan", created: Kit.t0)
    }

    static func aim(_ i: Intention) -> Note { .followUp(i.subject, framing: .nervous, intention: i.id) }

    @Test func issuedAimIsMarkedAndPersisted() {
        var run = ReducerRun(IntentionBoard())
        let it = Self.intention("job interview", status: .open, issued: 0)
        run.m.ongoing.intentions = [it]
        let fx = run.issue(Self.aim(it))
        #expect(run.m.ongoing.intentions[0].status == .issued && run.m.ongoing.intentions[0].issuedCount == 1)
        #expect(fx == [.persist(.intention(run.m.ongoing.intentions[0]))], "the count survives a relaunch")
        #expect(run.r.aimedThisTurn == [it.id])
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
        run.m.ongoing.expectations = [Expectation(id: UUID(), person: Kit.john, subject: Subject("trip")!, due: Kit.t0,
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
    }

    @Test func subjectMentionMatching() {
        #expect(IntentionBoard.mentions("how did the interview go?", Subject("job interview")!))
        #expect(IntentionBoard.mentions("love your paintings", Subject("painting")!))
        #expect(!IntentionBoard.mentions("nice weather", Subject("job interview")!))
        #expect(!IntentionBoard.mentions("the reinterview", Subject("job interview")!))
    }

    @Test func goldenFollowThrough() throws {
        // Two intentions whose aims were issued this turn (once and twice in total).
        var ib = IntentionBoard()
        var mm = Kit.moment()
        let a = Self.intention("job interview", issued: 0), b = Self.intention("guitar", issued: 1)
        mm.ongoing.intentions = [a, b]
        _ = ib.noteIssued(Self.aim(a), &mm)
        _ = ib.noteIssued(Self.aim(b), &mm)
        var rng = Rand(seed: 7)
        var steps: [TraceStep] = []
        for c in [Cue(t: 1, p: .deeTurnFinished(text: "So how did the interview go?")), Cue(t: 2, p: .tick)] {
            mm.now = Kit.t0.addingTimeInterval(c.t)
            let fx = ib.reduce(c.p, &mm, &rng)
            steps.append(TraceStep(t: c.t, percept: describe(c.p), effects: fx.map(\.traceName), slice: IntentionBoard.slice(of: mm)))
        }
        try Golden.verify(GoldenTrace(reducer: "IntentionBoard", name: "follow-through", steps: steps))
    }
}
