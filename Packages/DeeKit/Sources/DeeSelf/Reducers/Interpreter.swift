import DeeCore
import DeeMemory
import Foundation

/// Sub-reducer 4 — the tentative model of the user (SELF.md §7.4, §7.5).
///
/// Owns: `ongoing.person` (identity gate), `ongoing.hypotheses`, `ongoing.topic`,
/// `ongoing.misreadThisTurn`, deixis, `PlanDetector`, `RepairDetector`, expectation checks.
/// Reads: heard, appraisal, referents.
///
/// Status (0.5.1): basic. `.identified` sets the person only within the DeeMemory
/// match threshold; a non-matching result clears it (nil = unknown, global learning
/// only) only after 3 in a row, so one bad frame can't flap identity mid-conversation.
/// Expired hypotheses are pruned; `misreadThisTurn` is cleared at each new user turn;
/// `misreadThisTurn` and `topic` reset at `conversationStarted`.
///
/// TODO(0.5.3, owner: Interpreter):
/// - full identity gate (distance AND a name confirmation this conversation or ≥ 3
///   consecutive matches);
/// - mood / busy / wantsQuiet / goal hypotheses (confidence (0.35 + 0.1·evidence) ×
///   moodInferenceGain, ≤ 0.7; stated feelings 1.0 for 30 min) and the hypothesis note
///   (confidence ≥ 0.5 × gain);
/// - corrections → confidence 0, gain ×0.85 (floor 0.4), uncertainty 0.8, misread note
///   and `Misread` record;
/// - topic lemmas (NLTagger nouns, ≤ 3) and interest touches;
/// - PlanDetector (future-event patterns + NSDataDetector) → Expectation + follow-up
///   Intention; outcome appraisal of the next turn; unprompted resolution;
/// - RepairDetector patterns (reconciliation bids, user boundaries).
public struct Interpreter: SubReducer {
    public static let name = "Interpreter"

    /// DeeMemory's default face-match threshold.
    public static let identityThreshold: Float = FaceMatching().threshold
    /// Consecutive non-matching identifications before the person becomes unknown.
    public static let missesToForgetIdentity = 3

    /// Consecutive non-matching `.identified` results.
    public private(set) var identityMisses = 0

    public init() {}

    public mutating func reduce(_ p: Percept, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        let now = m.now
        switch p {
        case .identified(let id, let distance):
            if let id, distance.isFinite, distance <= Self.identityThreshold {
                m.ongoing.person = id
                identityMisses = 0
            } else {
                identityMisses += 1
                if identityMisses >= Self.missesToForgetIdentity { m.ongoing.person = nil }
            }
        case .partial:
            if m.momentary.floorEvents.contains(.userStarted) { m.ongoing.misreadThisTurn = nil }
        case .tick:
            m.ongoing.hypotheses.removeAll { now >= $0.expires }
        default:
            break
        }
        if m.ongoing.hypotheses.count > Ongoing.maxHypotheses {
            m.ongoing.hypotheses = Array(m.ongoing.hypotheses.sorted { $0.confidence > $1.confidence }.prefix(Ongoing.maxHypotheses))
        }
        return []
    }

    public mutating func conversationStarted(at d: Date, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        m.ongoing.misreadThisTurn = nil
        m.ongoing.topic = []
        return []
    }

    public static func slice(of m: Moment) -> [String: String] {
        [
            "person": m.ongoing.person.map { String($0.uuidString.prefix(8)) } ?? "-",
            "hypotheses": m.ongoing.hypotheses.map { "\($0.kind.rawValue):\($0.value):\(String(format: "%.2f", $0.confidence))" }.joined(separator: ","),
            "topic": m.ongoing.topic.map(\.text).joined(separator: ","),
        ]
    }
}
