import Foundation
import Testing
@testable import HarnessCore

/// Calm round 3 review (scratchpad calm/r3-review-correct.md F3): a stop re-scored "stopped" from
/// its later hold reported its silence at the first hold — one Dee resumed from — so the D1
/// silence numbers looked better than they were.
@Suite struct CalmR3ReviewSilenceTests {
    /// hold 17.0 → resumed 17.4 → hold 18.78 → flush 18.80, onset 16.72: silent at 2.06 s.
    @Test func theSilenceOfARescoredStopIsTheLaterHold() {
        var run = CalmR3QuestionStopTests().kitchenQ01()
        run.timeline = [.init(id: 1, start: 0, marks: [:], details: [], events: [
            .init(t: 16.95, text: "duck - gain=-12 via=onset"), .init(t: 17.0, text: "hold - why=sustained"),
            .init(t: 17.4, text: "resumed -"), .init(t: 18.78, text: "hold u_q01 why=answer"),
            .init(t: 18.80, text: "flushed: r1 played_ms=4060")])]
        let m = Metrics.compute([run], pricing: .mini)
        #expect(m.interruptQuestions.first?.stopped == true)
        #expect(m.silenceMulti.count == 1 && abs((m.silenceMulti.first ?? 0) - 2.06) < 1e-9, "\(m.silenceMulti)")
    }

    /// The floor's silence skips a pause Dee resumed from; a run of holds counts from its first.
    @Test func aResumedPauseIsNoSilence() {
        let run = CalmR3QuestionStopTests().kitchenQ01()
        let ev: [FloorEvent] = [.init(t: 1.0, kind: .hold), .init(t: 1.3, kind: .resumed),
                                .init(t: 2.0, kind: .hold), .init(t: 2.2, kind: .hold), .init(t: 2.5, kind: .cut)]
        let f = Metrics.floor(ev, run: run, from: 0, to: 5, firstUntil: 3)
        #expect(f.silenceAt == 2.0)
        let g = Metrics.floor(Array(ev.prefix(2)), run: run, from: 0, to: 5, firstUntil: 3)
        #expect(g.silenceAt == nil)
    }
}
