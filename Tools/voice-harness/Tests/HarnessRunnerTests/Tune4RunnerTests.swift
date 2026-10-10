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
    /// barge-in the brain answered never reached the Cortex. It must be sensed.
    /// Tune 5 F1 (live 20261010-011423: 0/3 questions asked over her answered): the app
    /// now senses `.bargeInAnswered`, which keeps the floor bookkeeping (cut off) but asks
    /// for no `.stopSpeaking`, so the answer the brain just started is not cancelled.
    @Test @MainActor func aBargeInTheBrainAnsweredIsSensedAndDoesNotStopItsAnswer() async throws {
        let host = try await HarnessHost(mind: try Mind(databaseURL: nil), memory: try MemoryStore(databaseURL: nil),
                                         selfStore: try SelfStore(url: nil), person: PersonID(), clock: HarnessClock())
        var stops = 0
        host.stopSpeaking = { stops += 1 }
        var notes: [String] = []
        host.onNote = { notes.append($0) }
        host.bargedIn()
        #expect(host.bargeInsSensed == 1)
        #expect(host.cortex.moment.ongoing.cutOff)
        #expect(stops == 0)
        #expect(host.stopsExecuted == 0)
        #expect(notes.contains("brain bargedIn") && !notes.contains("cortex stopSpeaking"))
    }

    /// The other path is unchanged: a plain `.bargeIn` (voice's own barge-in) still stops her.
    @Test @MainActor func aPlainBargeInStillStops() async throws {
        let host = try await HarnessHost(mind: try Mind(databaseURL: nil), memory: try MemoryStore(databaseURL: nil),
                                         selfStore: try SelfStore(url: nil), person: PersonID(), clock: HarnessClock())
        var stops = 0
        host.stopSpeaking = { stops += 1 }
        host.sense(.bargeIn)
        #expect(stops == 1)
    }
}
