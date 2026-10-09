import DeeCore
import Foundation

/// Sub-reducer 6 — intentions, follow-through and initiative (SELF.md §7.6).
///
/// Owns: `ongoing.intentions`, `ongoing.expectations` (status), follow-through,
/// initiative (`.initiative(cue:)`).
/// Reads: curiosity candidates, expectations, interests, lessons.
///
/// Status (0.5.1): basic. Live intentions and pending expectations past `expires`
/// expire silently (no note, ever). When an aim note is issued (`noteIssued`) its
/// intention becomes `issued` (`issuedCount += 1`, persisted) and is remembered as
/// aimed this turn; on `.deeTurnFinished` only those are checked: `done` when the
/// reply mentions the subject, `dropped` silently once issued twice, otherwise left
/// `issued`. Status changes are persisted. Seeds intentions and expectations from
/// `Carried`; resets `followUpsThisConversation` per conversation.
///
/// TODO(0.5.3, owner: IntentionBoard):
/// - sources: CuriosityDirector.candidates, follow-ups, repairs (jump the queue),
///   learn (interest > 0.6 with < 2 facts), skill (≥ 2 misreads in 7 days), rituals;
///   ≤ 3 self-motivated open, ≤ 1 born per day;
/// - score p = priority × relevance × timing × (0.5 + urgeToTalk); aim note at
///   p > 0.35 on a user turn; initiative at p > 0.6 with mutual gaze (> 0.85 while busy);
/// - re-eligibility after ≥ 2 turns; follow-up firing rules (§7.5); pride on completion;
/// - user-boundary drops.
public struct IntentionBoard: SubReducer {
    public static let name = "IntentionBoard"

    /// Intentions whose aim note was issued since the last `.deeTurnFinished`.
    public private(set) var aimedThisTurn: [UUID] = []

    public init() {}

    public mutating func reduce(_ p: Percept, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        let now = m.now
        var effects: [Effect] = []
        switch p {
        case .tick, .conversationStarted:
            for i in m.ongoing.intentions.indices where m.ongoing.intentions[i].isLive && now >= m.ongoing.intentions[i].expires {
                m.ongoing.intentions[i].status = .dropped
                m.ongoing.intentions[i].updated = now
                effects.append(.persist(.intention(m.ongoing.intentions[i])))
            }
            for i in m.ongoing.expectations.indices where (m.ongoing.expectations[i].status == .pending || m.ongoing.expectations[i].status == .asked) && now >= m.ongoing.expectations[i].expires {
                m.ongoing.expectations[i].status = .expired
                effects.append(.persist(.expectation(m.ongoing.expectations[i])))
            }
            m.ongoing.intentions.removeAll { !$0.isLive }
            m.ongoing.expectations.removeAll { $0.status == .expired || $0.status == .resolved }
        case .deeTurnFinished(let text):
            let reply = text.lowercased()
            let aimed = aimedThisTurn
            aimedThisTurn = []
            for i in m.ongoing.intentions.indices where m.ongoing.intentions[i].status == .issued && aimed.contains(m.ongoing.intentions[i].id) {
                if Self.mentions(reply, m.ongoing.intentions[i].subject) {
                    m.ongoing.intentions[i].status = .done
                    m.ongoing.intentions[i].stepsDone += 1
                } else if m.ongoing.intentions[i].issuedCount >= Intention.maxIssues {
                    m.ongoing.intentions[i].status = .dropped
                } else {
                    continue
                }
                m.ongoing.intentions[i].updated = now
                effects.append(.persist(.intention(m.ongoing.intentions[i])))
            }
        default:
            break
        }
        return effects
    }

    public mutating func seed(from c: Carried, _ m: inout Moment) {
        m.ongoing.intentions = c.intentions
        m.ongoing.expectations = c.expectations
    }

    public mutating func conversationStarted(at d: Date, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        m.ongoing.followUpsThisConversation = 0
        return []
    }

    /// An aim note serving one of the board's intentions was issued.
    public mutating func noteIssued(_ n: Note, _ m: inout Moment) -> [Effect] {
        guard let id = n.intention, let i = m.ongoing.intentions.firstIndex(where: { $0.id == id }) else { return [] }
        m.ongoing.intentions[i].status = .issued
        m.ongoing.intentions[i].issuedCount += 1
        m.ongoing.intentions[i].updated = m.now
        if !aimedThisTurn.contains(id) { aimedThisTurn.append(id) }
        return [.persist(.intention(m.ongoing.intentions[i]))]
    }

    public mutating func forget(subject: Subject, _ m: inout Moment) {
        aimedThisTurn.removeAll { id in !m.ongoing.intentions.contains { $0.id == id } }
    }

    public mutating func forgetPerson(_ id: PersonID, _ m: inout Moment) {
        aimedThisTurn.removeAll { a in !m.ongoing.intentions.contains { $0.id == a } }
    }

    public mutating func forgetAll(_ m: inout Moment) { aimedThisTurn = [] }

    /// The reply mentions the subject: every word of it, or its last word (the head
    /// noun: "job interview" → "interview"), as whole words, plural tolerated.
    public static func mentions(_ reply: String, _ subject: Subject) -> Bool {
        let words = Set(reply.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map { String($0) })
        func has(_ w: String) -> Bool { words.contains(w) || words.contains(w + "s") || words.contains(w + "es") }
        let sw = subject.words
        if sw.allSatisfy(has) { return true }
        if let head = sw.last, head.count >= 3 { return has(head) }
        return false
    }

    public static func slice(of m: Moment) -> [String: String] {
        [
            "intentions": m.ongoing.intentions.map { "\($0.kind.rawValue):\($0.subject.text):\($0.status.rawValue):\($0.issuedCount)" }.joined(separator: ","),
            "expectations": m.ongoing.expectations.map { "\($0.subject.text):\($0.status.rawValue)" }.joined(separator: ","),
        ]
    }
}
