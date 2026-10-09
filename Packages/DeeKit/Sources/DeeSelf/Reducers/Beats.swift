import DeeCore
import Foundation

/// Sub-reducer 7 — beats: short scripted sequences of gaze / overlay / mannerism
/// (SELF.md §1 walk-through, §7.2, §7.3).
///
/// Owns: `momentary.beat`, `momentary.beatStepShown`, `momentary.beatRequests` (consumer).
/// Requests: the active step's gaze (`.beat`) and its mannerism (rank `.beat`, once per
/// step). `Stance.resolve` reads the active step's overlay and boost itself (§3.5).
/// Reads: focus changes, recall hits, floor, beat requests from other reducers.
///
/// Status (0.5.1): basic. A finished beat is cleared; the active step's gaze and
/// mannerism are requested. Beat requests are not acted on yet (they are cleared).
///
/// TODO(0.5.2, owner: Beats):
/// - examine → recognize → brighten (shown a creation; runs during prefill),
///   listenHesitant, sorryGoOn (clipped-speaker recovery + seeded canned line),
///   reunion; beat step tables per kind; who may preempt whom.
public struct Beats: SubReducer {
    public static let name = "Beats"

    public init() {}

    public mutating func reduce(_ p: Percept, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        if let b = m.momentary.beat, m.now.timeIntervalSince(b.started) >= b.totalDuration {
            m.momentary.beat = nil
        }
        if case .conversationStarted = p { m.momentary.beat = nil }
        // TODO(0.5.2): start / preempt beats from `beatRequests` (consumed here only).
        m.momentary.beatRequests = []
        requestActiveStep(&m)
        return []
    }

    /// The active step's gaze (priority 2) and, once per step, its mannerism.
    func requestActiveStep(_ m: inout Moment) {
        guard let active = m.momentary.beat?.step(at: m.now) else {
            m.momentary.beatStepShown = nil
            return
        }
        let s = active.step
        if active.index != m.momentary.beatStepShown, let man = s.mannerism {
            m.momentary.requestMannerism(man, rank: .beat, by: Self.name)
        }
        m.momentary.beatStepShown = active.index
        switch s.gaze {
        case .user: m.momentary.requestGaze(.user, hold: s.duration, priority: .beat, by: Self.name)
        case .down: m.momentary.requestGaze(.examineBack, hold: s.duration, priority: .beat, by: Self.name)
        case .away: m.momentary.requestGaze(.away, hold: s.duration, priority: .beat, by: Self.name)
        case .referent:
            if case .referent(_, .back) = m.momentary.focus {
                m.momentary.requestGaze(.examineBack, hold: s.duration, priority: .beat, by: Self.name)
            } else {
                m.momentary.requestGaze(.user, hold: s.duration, priority: .beat, by: Self.name)
            }
        case .keep: break
        }
    }

    public static func slice(of m: Moment) -> [String: String] {
        ["beat": m.momentary.beat.map { "\($0.kind.rawValue)#\($0.step(at: m.now)?.index ?? -1)" } ?? "-"]
    }
}
