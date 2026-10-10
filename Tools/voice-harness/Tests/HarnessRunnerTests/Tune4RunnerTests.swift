import DeeBrain
import DeeMemory
import DeeMind
import DeeSelf
import Foundation
import HarnessCore
import Testing
@testable import HarnessRunner

@Suite("Tune 4: app parity of the harness host (offline)", .serialized)
struct Tune4RunnerTests {
    /// Tune-3 live note: `HarnessHost` used the protocol's no-op `bargedIn()`, so a
    /// barge-in the brain answered never reached the Cortex. The app (DeeModel.bargedIn)
    /// senses `.bargeIn`, and runs the Cortex's effects: FloorKeeper asks for
    /// `.stopSpeaking`, which DeeModel executes as `stop()`. The harness now does both.
    @Test @MainActor func aBargeInTheBrainAnsweredIsSensedAndItsStopRunsLikeTheApp() async throws {
        let host = try await HarnessHost(mind: try Mind(databaseURL: nil), memory: try MemoryStore(databaseURL: nil),
                                         selfStore: try SelfStore(url: nil), person: PersonID(), clock: HarnessClock())
        var stops = 0
        host.stopSpeaking = { stops += 1 }
        var notes: [String] = []
        host.onNote = { notes.append($0) }
        host.bargedIn()
        #expect(host.bargeInsSensed == 1)
        #expect(host.cortex.moment.ongoing.cutOff)
        #expect(stops == 1)
        #expect(host.stopsExecuted == 1)
        #expect(notes.contains("brain bargedIn") && notes.contains("cortex stopSpeaking"))
    }
}
