import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// Learner (SELF.md §7.7, §7.9). Owner: Learner. Goldens: `Fixtures/Learner/`.
@Suite struct LearnerTests {
    @Test func reduceIsANoOp() {
        var run = ReducerRun(Learner())
        let before = run.m
        #expect(run.step(Kit.heard("haha"), at: 0).isEmpty)
        var after = run.m
        after.now = before.now
        after.seq = before.seq
        #expect(after == before)
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

    @Test func gagCallbackCountsUses() {
        var run = ReducerRun(Learner())
        let g = Gag(id: UUID(), person: Kit.john, topic: Subject("toast")!, hookTemplate: 1)
        run.m.enduring.gags = [g]
        run.m.now = Kit.t0.addingTimeInterval(3)
        let fx = run.issue(.gagCallback(g.topic, style: .deadpan, gag: g.id))
        #expect(run.m.enduring.gags[0].uses == 1 && run.m.enduring.gags[0].lastUsed == Kit.t0.addingTimeInterval(3))
        #expect(fx.map(\.traceName) == ["persist(gag)"])
    }

    @Test func seedsInterestsAndMisreads() {
        var run = ReducerRun(Learner())
        let i = Interest(subject: Subject("watercolor")!, weight: 0.6, lastTouched: Kit.t0)
        let r = Misread(id: UUID(), person: Kit.john, at: Kit.t0, situation: .moodGuess)
        run.r.seed(from: Carried(interests: [i], misreads: [r]), &run.m)
        #expect(run.m.ongoing.interests == [i] && run.m.ongoing.recentMisreads == [r])
    }
}
