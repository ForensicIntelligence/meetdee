import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// Interpreter (SELF.md §7.4, §7.5). Owner: Interpreter. Goldens: `Fixtures/Interpreter/`.
@Suite struct InterpreterTests {
    @Test func identityGateHysteresisAndExpiry() {
        var run = ReducerRun(Interpreter())
        run.step(.identified(Kit.john, distance: 0.3), at: 0)
        #expect(run.m.ongoing.person == Kit.john)
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
        run.step(.identified(Kit.ann, distance: 0.2), at: 5)
        #expect(run.m.ongoing.person == Kit.ann, "a confident match switches at once")
        run.m.ongoing.hypotheses = [Hypothesis(kind: .busy, value: "busy", confidence: 0.6, expires: Kit.t0.addingTimeInterval(10))]
        run.step(.tick, at: 6)
        #expect(run.m.ongoing.hypotheses.count == 1)
        run.step(.tick, at: 10)
        #expect(run.m.ongoing.hypotheses.isEmpty)
    }

    @Test func conversationStartResetsTopicAndMisread() {
        var run = ReducerRun(Interpreter())
        run.m.ongoing.topic = [Subject("guitar")!]
        run.m.ongoing.misreadThisTurn = Misread(id: UUID(), person: nil, at: Kit.t0, situation: .moodGuess)
        run.step(.conversationStarted(Kit.t0), at: 0)
        #expect(run.m.ongoing.topic.isEmpty && run.m.ongoing.misreadThisTurn == nil)
    }

    @Test func hypothesisConfidenceCaps() {
        #expect(Hypothesis(kind: .mood, value: "sad", confidence: 0.95, expires: Kit.t0).confidence == 0.7)
        #expect(Hypothesis(kind: .mood, value: "tired", confidence: 0.2, stated: true, expires: Kit.t0).confidence == 1)
    }
}
