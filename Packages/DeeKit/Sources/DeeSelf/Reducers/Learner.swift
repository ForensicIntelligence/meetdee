import DeeCore
import Foundation

/// Sub-reducer 9 — learning (SELF.md §7.7, §7.9).
///
/// Owns: tastes (online evidence), interests, social-profile EWMAs, lessons (minting).
/// Reads: episodes in progress, misreads, laughter.
///
/// Status (0.5.1): `reduce` is a no-op. (Seeded traits, values, humour and signature
/// come from `SelfSeeder`; nothing is learnt online yet.) Hooks: seeds interests and
/// recent misreads from `Carried`; resets `revealedThisConversation` per conversation;
/// bookkeeping when its notes are issued — a taste reveal stamps `Facet.revealedAt`
/// (once ever, persisted) and sets `revealedThisConversation`; a gag callback bumps
/// `uses` / `lastUsed` (persisted).
///
/// Gates it must apply *before* raising (NotePicker no longer does): gag callbacks only
/// when `m.playGate` and the seeded 0.4 × playfulness draw from
/// its own stream; a taste reveal only for a crystallised facet with `revealedAt == nil`.
///
/// TODO(0.5.3 / 0.5.6, owner: Learner):
/// - lessons: two misreads of the same situation with the same person within 14 days
///   mint a `Lesson`; parameter effects per situation (D6) before any note;
/// - profiles: pauseScale (EWMA + shrinkage), humorReceptiveness (α 0.15),
///   moodInferenceGain (×0.85 per correction, floor 0.4, +0.02 per confirmation),
///   silenceComfort, kindnessEMA; writes at most every 60 s;
/// - tastes: learned EMA (α 0.3, |valence| > 0.2), polarity, crystallise at evidence ≥ 3
///   and |polarity| ≥ 0.35, flip only after 3 contrary exposures; reveal once;
/// - interests (+0.2·curiosity per touch, 7 d half-life, cap 20); gags; rituals.
public struct Learner: SubReducer {
    public static let name = "Learner"

    public init() {}

    public mutating func reduce(_ p: Percept, _ m: inout Moment, _ rng: inout Rand) -> [Effect] { [] }

    public mutating func seed(from c: Carried, _ m: inout Moment) {
        m.ongoing.interests = c.interests
        m.ongoing.recentMisreads = c.misreads
    }

    public mutating func conversationStarted(at d: Date, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        m.ongoing.revealedThisConversation = false
        return []
    }

    public mutating func noteIssued(_ n: Note, _ m: inout Moment) -> [Effect] {
        switch n.kind {
        case .tasteReveal:
            m.ongoing.revealedThisConversation = true
            guard let id = n.facet, let i = m.enduring.facets.firstIndex(where: { $0.id == id }),
                  m.enduring.facets[i].revealedAt == nil else { return [] }
            m.enduring.facets[i].revealedAt = m.now
            m.enduring.facets[i].updatedAt = m.now
            return [.persist(.facet(m.enduring.facets[i]))]
        case .gagCallback:
            guard let id = n.gag, let i = m.enduring.gags.firstIndex(where: { $0.id == id }) else { return [] }
            m.enduring.gags[i].uses += 1
            m.enduring.gags[i].lastUsed = m.now
            return [.persist(.gag(m.enduring.gags[i]))]
        default:
            return []
        }
    }
}
