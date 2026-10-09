import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// Beats (SELF.md §1, §7.2, §7.3). Owner: Beats. Goldens: `Fixtures/Beats/`.
@Suite struct BeatsTests {
    @Test func clearWhenFinished() {
        var run = ReducerRun(Beats())
        run.m.momentary.beat = StanceTests.beat()
        run.step(.tick, at: 1.5)
        #expect(run.m.momentary.beat != nil)
        run.step(.tick, at: 2)
        #expect(run.m.momentary.beat == nil)
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
        run.step(.tick, at: 0)
        #expect(run.m.momentary.beatRequests.isEmpty)
    }
}
