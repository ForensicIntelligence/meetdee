import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// Listener (SELF.md §7.2). Owner: Listener. Goldens: `Fixtures/Listener/`.
@Suite struct ListenerTests {
    @Test func clearsPreviewOutsideUserTurn() {
        var run = ReducerRun(Listener())
        run.m.momentary.preview = ListenPreview(valence: 0.3, intensity: 0.3, signSince: Kit.t0)
        run.m.momentary.floor = .userSpeaking(since: Kit.t0)
        run.step(.tick, at: 0)
        #expect(run.m.momentary.preview != nil)
        run.m.momentary.floor = .deeThinking(since: Kit.t0)
        run.step(.tick, at: 1)
        #expect(run.m.momentary.preview == nil)
    }
}
