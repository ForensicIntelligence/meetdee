import DeeCore
import DeeMind
import Foundation

/// Sub-reducer 8 — episodes built without text (SELF.md §7.10).
///
/// Owns: the per-conversation accumulator and `SelfWrite.episode` at boundaries.
/// Reads: mind before/after, topics, events (never text).
///
/// Status (0.5.1): basic. Tracks the mood code at the start of each conversation and
/// counts user turns; writes no episodes yet. When a recall note is issued it bumps the
/// episode key's `recalled` and persists `SelfWrite.recalled`.
///
/// TODO(0.5.3, owner: EpisodeBuilder):
/// - accumulator per user turn (appraisal, mindBefore, mindAfter, topics ≤ 3, events);
/// - segmenting at topic change, conversation end (newConversation, sleep ≥ 300 s) and
///   beat completion; 0–3 episodes per conversation;
/// - salience |Δregard|·2 + surprise + novelty + 0.5·[distress] + 0.5·[laughter] +
///   [followUp] + [misread]; persist at ≥ 0.4, else the daily digest counter;
/// - gist templates (slots only), why / expected / changed;
/// - recall scoring and the recall note / recognize beat; `.reflect` scheduling.
public struct EpisodeBuilder: SubReducer {
    public static let name = "EpisodeBuilder"

    public private(set) var conversationMindBefore: MindCode?
    public private(set) var userTurns = 0

    public init() {}

    public mutating func reduce(_ p: Percept, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        switch p {
        case .conversationStarted:
            conversationMindBefore = m.ongoing.mind.code
            userTurns = 0
        case .heard:
            if conversationMindBefore == nil { conversationMindBefore = m.ongoing.mind.code }
            userTurns += 1
        default:
            break
        }
        return []
    }

    public mutating func noteIssued(_ n: Note, _ m: inout Moment) -> [Effect] {
        guard n.kind == .recall, let id = n.episode else { return [] }
        if let i = m.enduring.episodeIndex.firstIndex(where: { $0.id == id }) { m.enduring.episodeIndex[i].recalled += 1 }
        return [.persist(.recalled(episode: id, at: m.now))]
    }

    public mutating func forgetAll(_ m: inout Moment) {
        conversationMindBefore = nil
        userTurns = 0
    }

    public static func slice(of m: Moment) -> [String: String] { [:] }
}
