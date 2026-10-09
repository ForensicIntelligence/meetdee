import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// EpisodeBuilder (SELF.md §7.10). Owner: EpisodeBuilder. Goldens: `Fixtures/EpisodeBuilder/`.
@Suite struct EpisodeBuilderTests {
    @Test func writesNothingYet() {
        var run = ReducerRun(EpisodeBuilder())
        #expect(run.step(.conversationStarted(Kit.t0), at: 0).isEmpty)
        #expect(run.step(Kit.heard("I showed you my painting"), at: 1).isEmpty)
        #expect(run.r.userTurns == 1)
        #expect(run.r.conversationMindBefore == Kit.snap().code)
    }

    @Test func issuedRecallIsCountedAndPersisted() {
        var run = ReducerRun(EpisodeBuilder())
        let ep = SelfStoreTests.episode(nil)
        run.m.enduring.episodeIndex = [ep.key]
        run.m.now = Kit.t0.addingTimeInterval(5)
        let fx = run.issue(.recall(gist: "x", episode: ep.id))
        #expect(run.m.enduring.episodeIndex[0].recalled == 1)
        #expect(fx == [.persist(.recalled(episode: ep.id, at: Kit.t0.addingTimeInterval(5)))])
        #expect(run.issue(.reunion()).isEmpty)
    }
}
