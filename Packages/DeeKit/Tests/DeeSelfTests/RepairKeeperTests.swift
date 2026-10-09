import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// RepairKeeper (SELF.md §7.8). Owner: RepairKeeper. Goldens: `Fixtures/RepairKeeper/`
/// and the whole-pipeline `Fixtures/Cortex/dee-interrupts-three-times.json`.
@Suite struct RepairKeeperTests {
    @Test func awkwardnessStrainAndSelfRepairOnce() {
        var run = ReducerRun(RepairKeeper())
        run.step(.tick, at: 0, events: [.deeInterrupted])
        run.step(.tick, at: 0.1, events: [.deeInterrupted])
        #expect(run.m.ongoing.repair == .fine)
        run.step(.tick, at: 0.2, events: [.deeInterrupted])
        #expect(run.m.ongoing.awkwardness >= 0.5)
        #expect(run.m.ongoing.repair == .strained)
        run.step(.tick, at: 60)
        #expect(run.m.ongoing.repair == .strained)
        run.step(.tick, at: 600)
        #expect(run.m.ongoing.repair == .fine)
        #expect(run.m.ongoing.noteCandidates.map(\.kind) == [.awkwardRepair])
        #expect(run.m.ongoing.noteCandidates[0].owner == "RepairKeeper")
        run.step(.tick, at: 700)
        #expect(run.m.ongoing.noteCandidates.count == 1)
    }

    @Test func absenceNeverRuptures() {
        var run = ReducerRun(RepairKeeper())
        run.step(.tick, at: 0)
        run.step(.presence(arrived: false), at: 1)
        run.step(.tick, at: 30 * 86_400)
        run.step(.presence(arrived: true), at: 30 * 86_400 + 1)
        #expect(run.m.ongoing.repair == .fine)
        #expect(run.m.ongoing.awkwardness == 0)
    }

    @Test func carriedRuptureRestoredForItsPerson() {
        var run = ReducerRun(RepairKeeper())
        run.r.seed(from: Carried(openRepair: [Kit.john: .ruptured]), &run.m)
        run.m.ongoing.person = Kit.ann
        run.step(.identified(Kit.ann, distance: 0.2), at: 0)
        #expect(run.m.ongoing.repair == .fine)
        run.m.ongoing.person = Kit.john
        run.step(.identified(Kit.john, distance: 0.2), at: 1)
        #expect(run.m.ongoing.repair == .ruptured)
    }

    @Test func carriedRupturesFollowMergesAndForgets() {
        var rk = RepairKeeper()
        var m = Kit.moment()
        rk.seed(from: Carried(openRepair: [Kit.john: .ruptured]), &m)
        rk.merge(from: Kit.john, into: Kit.ann, &m)
        #expect(rk.carried == [Kit.ann: .ruptured])
        rk.forgetPerson(Kit.ann, &m)
        #expect(rk.carried.isEmpty)
    }

    /// Review finding 10: the prompt was rendered before identification, so it lacks
    /// "Don't bring up"; each user turn of the identified person raises it as context.
    @Test func boundariesRemindedWhenThePromptLacksThem() {
        var run = ReducerRun(RepairKeeper())
        run.m.enduring.boundaries = [Boundary(id: UUID(), person: Kit.john, topic: Subject("job")!, owner: .user, createdAt: Kit.t0),
                                     Boundary(id: UUID(), person: Kit.john, topic: Subject("money")!, owner: .user,
                                              createdAt: Kit.t0.addingTimeInterval(1))]
        run.step(Kit.heard("hi"), at: 0)
        #expect(run.m.ongoing.noteCandidates.isEmpty, "no prompt rendered yet")
        run.m.ongoing.promptRendered = true
        run.m.ongoing.person = Kit.john
        run.step(Kit.heard("hi"), at: 1)
        #expect(run.m.ongoing.noteCandidates.map(\.text) == ["(Don't bring up money, job.)"])
        run.m.ongoing.noteCandidates = []
        run.m.ongoing.promptPerson = Kit.john
        run.step(Kit.heard("hi"), at: 2)
        #expect(run.m.ongoing.noteCandidates.isEmpty, "the prompt already has the line")
    }

    @Test func goldenDeeInterruptsThreeTimes() throws {
        // Floor events come from FloorKeeper; run the pair through a full Cortex.
        try Golden.verify(Golden.recordCortex(name: "dee-interrupts-three-times", [
            Cue(t: 0, p: .speakingStarted), Cue(t: 0.5, p: .bargeIn),
            Cue(t: 2, p: .speakingStarted), Cue(t: 2.4, p: .bargeIn),
            Cue(t: 4, p: .speakingStarted), Cue(t: 4.3, p: .bargeIn),
            Cue(t: 60, p: .tick), Cue(t: 400, p: .tick), Cue(t: 401, p: .tick),
        ]))
    }
}
