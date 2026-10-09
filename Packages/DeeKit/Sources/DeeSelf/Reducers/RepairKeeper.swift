import DeeCore
import Foundation

/// Sub-reducer 5 — relationship repair and boundaries (SELF.md §7.8).
///
/// Owns: `ongoing.repair`, `ongoing.awkwardness`, boundaries.
/// Reads: appraisal, misreads, floor events.
///
/// Status (0.5.1): basic. Awkwardness decays with a 3 min half-life and rises +0.2 when
/// Dee interrupts; fine ↔ strained at 0.5 / 0.2, with a one-time self-repair note when
/// Dee caused it; an open rupture carried over a relaunch is restored when its person
/// is identified. Time is never a cause of rupture (absence is not a quarrel).
/// When the frozen prompt was rendered for someone else (usually nobody: `persona()`
/// ran before face identification), each user turn of the identified person raises
/// their active user boundaries as a context note, since the prompt lacks the
/// "Don't bring up" line (review finding 10).
///
/// TODO(0.5.5, owner: RepairKeeper):
/// - misread +0.25, awkward silence +0.15, failed joke +0.2;
/// - ruptured (hostility ≥ 0.5, regard −0.4 in 10 min, anger > 0.5) → repairing (bids)
///   → reconciled (note exactly once + contentSquint) → fine after 2 min;
/// - Dee's boundary (once, assertiveness ≥ 0.35) and user boundaries
///   ("don't ask me about X") → `Boundary`, CuriosityDirector.avoid, notes;
/// - together-time bookkeeping for `SelfWrite.openRepair`.
public struct RepairKeeper: SubReducer {
    public static let name = "RepairKeeper"

    public static let awkwardHalfLife: TimeInterval = 180
    public static let strainAt = 0.5
    public static let easeBelow = 0.2
    public static let interruptAwkwardness = 0.2

    /// Open ruptures loaded from the store, applied when the person is identified.
    public internal(set) var carried: [PersonID: RepairPhase] = [:]
    var lastUpdate: Date?
    var deeCausedStrain = false

    public init() {}

    public mutating func reduce(_ p: Percept, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        let now = m.now
        if let last = lastUpdate, now > last {
            m.ongoing.awkwardness *= halfLife(now.timeIntervalSince(last), Self.awkwardHalfLife)
        }
        lastUpdate = now

        if m.momentary.floorEvents.contains(.deeInterrupted) {
            m.ongoing.awkwardness = clamp01(m.ongoing.awkwardness + Self.interruptAwkwardness)
            if m.ongoing.awkwardness >= Self.strainAt { deeCausedStrain = true }
        }
        if case .identified = p, let person = m.ongoing.person, let phase = carried.removeValue(forKey: person) {
            m.ongoing.repair = phase
        }

        switch m.ongoing.repair {
        case .fine where m.ongoing.awkwardness >= Self.strainAt:
            m.ongoing.repair = .strained
        case .strained where m.ongoing.awkwardness < Self.easeBelow:
            m.ongoing.repair = .fine
            if deeCausedStrain { m.ongoing.raise(.awkwardRepair(), by: Self.name) }
            deeCausedStrain = false
        default:
            break
        }
        if case .heard = p { raiseMissingBoundaries(&m) }
        return []
    }

    /// The prompt has no "Don't bring up" line for the identified person: remind per turn.
    func raiseMissingBoundaries(_ m: inout Moment) {
        guard m.ongoing.promptRendered, let person = m.ongoing.person, person != m.ongoing.promptPerson else { return }
        let topics = m.enduring.boundaries
            .filter { $0.person == person && $0.owner == .user && $0.active }
            .sorted { ($0.createdAt, $0.topic.text) > ($1.createdAt, $1.topic.text) }
            .map(\.topic)
        var unique: [Subject] = []
        for t in topics where !unique.contains(t) { unique.append(t) }
        guard !unique.isEmpty else { return }
        m.ongoing.raise(.userBoundaries(Array(unique.prefix(SelfBlock.maxBoundaries))), by: Self.name)
    }

    public mutating func seed(from c: Carried, _ m: inout Moment) { carried = c.openRepair }

    public mutating func forgetPerson(_ id: PersonID, _ m: inout Moment) { carried[id] = nil }

    public mutating func merge(from: PersonID, into: PersonID, _ m: inout Moment) {
        if let phase = carried.removeValue(forKey: from), carried[into] == nil { carried[into] = phase }
    }

    public mutating func forgetAll(_ m: inout Moment) {
        carried = [:]
        deeCausedStrain = false
    }

    public static func slice(of m: Moment) -> [String: String] {
        ["repair": m.ongoing.repair.rawValue, "awkwardness": String(format: "%.3f", m.ongoing.awkwardness)]
    }
}
