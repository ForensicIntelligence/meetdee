import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// SELF.md §12.2 — golden traces in `Fixtures/<reducer>/*.json`: the percept timeline,
/// the expected effects and the reducer's state slice per step. Each reducer's goldens
/// live in its own `<Name>Tests.swift`; this file holds the harness check and the
/// core-owned whole-pipeline traces. Regenerate only with `DEE_UPDATE_GOLDENS=1` and
/// review the diff in the commit.
@Suite struct GoldenTraceTests {
    @Test func cortexShownSomethingWhileUpset() throws {
        try Golden.verify(Golden.recordCortex(name: "laugh-while-upset", mind: Kit.angry, [
            Cue(t: 0, p: .presence(arrived: true)), Cue(t: 0.5, p: .identified(Kit.john, distance: 0.3)),
            Cue(t: 1, p: .partial("haha")), Cue(t: 2, p: Kit.heard("haha"), mind: Kit.angry.with(seq: 1, reflex: .giddy)),
            Cue(t: 2.1, p: .promptSubmitted), Cue(t: 3, p: .speakingStarted),
            Cue(t: 3, p: .deeSaid(tag: .joy, sentence: "a")), Cue(t: 5, p: .deeSaid(tag: .happy, sentence: "b")),
            Cue(t: 7, p: .deeSaid(tag: .happy, sentence: "c"), mind: Kit.angry.with(seq: 2)), Cue(t: 8, p: .speakingFinished),
            Cue(t: 9, p: .tick), Cue(t: 10, p: .tick),
        ]))
    }

    @Test func goldenDiffIsReadable() throws {
        let g = GoldenTrace(reducer: "X", name: "y", steps: [TraceStep(t: 0, percept: "tick", effects: [], slice: ["a": "1"])])
        let data = try Golden.encode(g)
        #expect(try JSONDecoder().decode(GoldenTrace.self, from: data) == g)
        #expect(String(decoding: data, as: UTF8.self).contains("\"percept\" : \"tick\""))
    }
}
