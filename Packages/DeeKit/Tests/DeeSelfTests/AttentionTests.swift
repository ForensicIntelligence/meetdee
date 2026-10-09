import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// Attention (SELF.md §7.3). Owner: Attention. Goldens: `Fixtures/Attention/`.
@Suite struct AttentionTests {
    @Test func headPoseAndMutualGaze() {
        var run = ReducerRun(Attention())
        run.step(.head(yaw: 5, pitch: 0), at: 0)
        #expect(run.m.momentary.mutualGazeSince == Kit.t0)
        run.step(.head(yaw: 8, pitch: -2), at: 1)
        #expect(run.m.momentary.mutualGazeSince == Kit.t0, "held")
        run.step(.head(yaw: 40, pitch: 0), at: 2)
        #expect(run.m.momentary.mutualGazeSince == nil)
        run.step(.head(yaw: 0, pitch: -20), at: 3)
        #expect(run.m.momentary.mutualGazeSince == nil, "looking down")
        run.step(.faceLost, at: 4)
        #expect(run.m.momentary.headYaw == nil)
    }

    @Test func focusBasics() {
        var run = ReducerRun(Attention())
        run.m.ongoing.person = Kit.john
        run.step(.presence(arrived: true), at: 0)
        #expect(run.m.momentary.focus == .person(Kit.john))
        #expect(run.m.momentary.reaction == .greeting)
        #expect(run.m.momentary.mannerismRequests == [MannerismRequest(.signature(.greeting), rank: .reaction, owner: "Attention")])
        run.step(.sound(label: "doorbell", unexpected: true), at: 1)
        #expect(run.m.momentary.focus == .sound(Subject("doorbell")!))
        #expect(run.m.momentary.reaction == nil, "requests are per step")
        run.step(.tick, at: 3)
        #expect(run.m.momentary.focus == .sound(Subject("doorbell")!))
        run.step(.tick, at: 4.5)
        #expect(run.m.momentary.focus == .none, "sound focus lapses after 3 s")
        run.step(.touch(kind: "tap", gentle: true, at: SIMD2(0.1, 0.2)), at: 5)
        #expect(run.m.momentary.focus == .touch(SIMD2(0.1, 0.2)))
        run.step(.sound(label: "dog", unexpected: true), at: 5.2)
        #expect(run.m.momentary.focus == .touch(SIMD2(0.1, 0.2)), "a live touch keeps focus")
        run.step(.tick, at: 6.5)
        #expect(run.m.momentary.focus == .none)
        run.m.momentary.floor = .userSpeaking(since: Kit.t0)
        run.step(.sound(label: "dog", unexpected: true), at: 7)
        #expect(run.m.momentary.focus == .none, "not while the user talks")
        run.step(.partial("hey"), at: 7.5)
        #expect(run.m.momentary.focus == .person(Kit.john))
    }

    @Test func gazeRequestsForTouchSoundAndBackReferent() {
        var run = ReducerRun(Attention())
        run.step(.sound(label: "doorbell", unexpected: true), at: 0)
        #expect(run.m.momentary.gazeRequests == [GazeRequest(.side(Stance.soundSide(Subject("doorbell")!)), hold: 1.2, priority: .focus, owner: "Attention")])
        run.step(.touch(kind: "pet", gentle: true, at: SIMD2(0.4, 0.6)), at: 1)
        #expect(run.m.momentary.gazeRequests.map(\.priority) == [.touch])
        #expect(Stance.gaze(run.m.momentary.gazeRequests).target == .point(SIMD2(0.4, 0.6)))
        run.step(.tick, at: 2.5)
        #expect(run.m.momentary.gazeRequests.isEmpty, "touch over, focus none")
        run.m.momentary.focus = .referent(Subject("guitar")!, .back)
        run.step(.tick, at: 3)
        #expect(run.m.momentary.gazeRequests.map(\.target) == [.examineBack])
    }

    @Test func referentsBumpDecayAndCap() {
        var run = ReducerRun(Attention())
        run.step(.sight(camera: .back, things: ["guitar", "lamp"], novel: ["guitar"]), at: 0)
        #expect(run.m.momentary.referents.map(\.subject.text) == ["guitar", "lamp"])
        #expect(run.m.momentary.referents[0].salience == 0.5)
        #expect(run.m.momentary.referents[1].salience == 0.15)
        run.step(.tick, at: 20)
        #expect(abs(run.m.momentary.referents[0].salience - 0.25) < 1e-9, "20 s half-life")
        for i in 0..<20 { run.step(.sight(camera: .front, things: ["thing\(i)x"], novel: ["thing\(i)x"]), at: 21 + Double(i) * 0.01) }
        #expect(run.m.momentary.referents.count == Attention.maxReferents)
        #expect(run.m.momentary.referents.last?.subject.text == "thing19x")
    }

    @Test func goldenBasics() throws {
        try Golden.verify(Golden.record(Attention(), name: "basics", [
            Cue(t: 0, p: .presence(arrived: true)), Cue(t: 0.5, p: .head(yaw: 4, pitch: -3)),
            Cue(t: 1, p: .sight(camera: .back, things: ["guitar", "lamp"], novel: ["guitar"])),
            Cue(t: 2, p: .sound(label: "doorbell", unexpected: true)), Cue(t: 5.5, p: .tick),
            Cue(t: 6, p: .touch(kind: "pet", gentle: true, at: SIMD2(0.4, 0.6))), Cue(t: 7.5, p: .tick),
            Cue(t: 26, p: .tick), Cue(t: 27, p: .faceLost),
        ]))
    }
}
