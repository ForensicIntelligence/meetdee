import DeeCore
import Foundation

/// Sub-reducer 2 — coordinated listening (SELF.md §7.2).
///
/// Owns: `momentary.preview`, `momentary.backchannel`, `momentary.lastBackchannel`,
/// hesitation response, silence classification.
/// Requests (when it lands): backchannels via `requestMannerism(_:rank: .backchannel)`,
/// `readyFace` / `lidSoften` / `tilt` via `requestFace` (`.userTurn`), the
/// `listenHesitant` beat via `requestBeat`, the hesitation note via `Ongoing.raise`,
/// and signals such as "awkwardSilence" for RepairKeeper.
/// Reads: partials, `.pause`, the social profile.
///
/// Status (0.5.1): basic. The preview is cleared whenever the floor is not the user's,
/// so it can never leak into Dee's own turn.
///
/// TODO(0.5.2, owner: Listener):
/// - preview appraisal on a *copy* of the Appraiser at ≤ 2 Hz, intensity ≤ 0.5,
///   sign flips held 0.6 s;
/// - visual backchannels (≥ 1.5 s spoken, 200–600 ms pause with turnEnd < 0.5, rate
///   3 s/(0.5 + extraversion), ≤ 15/min, backchannelRate > 0, no hesitation hold):
///   nod / contentSquint / soft blink / giggle → `momentary.backchannel`;
/// - hesitation response (`listenHesitant` beat request, no nods for 1 s, soft blink
///   and tilt after 3.5 s; never speaks) and the hesitation note;
/// - silence model after Dee's turn (pendingQuestion 6 s / 14 s, comfortable, awkward)
///   and `silenceComfort` learning.
public struct Listener: SubReducer {
    public static let name = "Listener"

    public init() {}

    public mutating func reduce(_ p: Percept, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        if !m.momentary.floor.isUserTurn { m.momentary.preview = nil }
        return []
    }

    public static func slice(of m: Moment) -> [String: String] {
        [
            "preview": m.momentary.preview.map { String(format: "%.2f/%.2f", $0.valence, $0.intensity) } ?? "-",
            "backchannel": m.momentary.backchannel?.rawValue ?? "-",
        ]
    }
}
