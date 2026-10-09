import DeeMind
import Foundation

/// SELF.md §6 — the single writer of `<dee_state>`.
///
/// `<dee_state>{mood sentence} {note1} {note2}</dee_state>`. The mood sentence is a
/// byte-identical port of `MindSnapshot.cue` (golden-tested), so with no notes the
/// cue equals `snapshot.cue` exactly. At most two notes, at most one aim; hard cap
/// 120 tokens (context note dropped first, then the aim; the mood always stays).
public enum CueWriter {
    public static let maxTokens = 120
    public static let maxNoteTokens = 30
    public static let open = "<dee_state>"
    public static let close = "</dee_state>"

    /// Worst-case token estimate used by tests and as the default budget counter:
    /// `ceil(chars / 3)`. At runtime `SelfBudget` may pass the real tokenizer count.
    public static func estimateTokens(_ s: String) -> Int { (s.count + 2) / 3 }

    // MARK: Mood sentence (port of MindSnapshot.cue)

    /// The mood sentence body (without the `<dee_state>` wrapper).
    public static func mood(_ snapshot: MindSnapshot) -> String {
        mood(code: snapshot.code, age: snapshot.age)
    }

    public static func regardWords(_ r: Double) -> String {
        switch r {
        case ..<(-0.6): "very upset with them"
        case ..<(-0.3): "upset with them"
        case ..<(-0.1): "a bit annoyed with them"
        case ..<0.15: "no strong feelings about them yet"
        case ..<0.4: "friendly toward them"
        case ..<0.7: "fond of them"
        default: "you adore them"
        }
    }

    /// `omit`: mood words left out (the reunion turn drops "lonely"; §9, review finding 3).
    public static func mood(code: MindCode, age: Double?, omit: Set<String> = []) -> String {
        let f = code.feelings
        let regard = EmotionEngine.regard(f)
        let stage = age.map(LifeStage.init(age:))
        let p = EmotionEngine.effective(code.personality, age: age)
        var moods: [(String, Double)] = [
            ("cheerful", f[.joy] - 0.45), ("sad", f[.sadness] - 0.2), ("angry", f[.anger] - 0.15),
            ("nervous", f[.fear] - 0.2), ("surprised", f[.surprise] - 0.3), ("curious", f[.interest] - 0.6),
            ("bored", f[.boredom] - 0.35), ("lonely", f[.loneliness] - 0.3), ("tired", 0.35 - f[.energy]),
            ("grateful", f[.gratitude] - 0.3), ("still holding a grudge", f[.resentment] - 0.2),
        ]
        moods = moods.filter { $0.1 > 0 && !omit.contains($0.0) }.sorted { $0.1 > $1.1 }
        let moodText = moods.prefix(3).map(\.0).joined(separator: ", ")

        var traits: [String] = []
        if p[.playfulness] > 0.8 { traits.append("very playful") }
        if p[.patience] < 0.35 { traits.append("impatient") }
        if p[.confidence] < 0.3 { traits.append("insecure") }
        if p[.confidence] > 0.8 { traits.append("self-assured") }
        if p[.assertiveness] > 0.7 { traits.append("blunt") }
        if p[.agreeableness] < 0.4 { traits.append("prickly") }
        if p[.neuroticism] > 0.7 { traits.append("touchy") }

        var parts = ["Toward your human: \(regardWords(regard))."]
        if !moodText.isEmpty { parts.append("Mood: \(moodText).") }
        if !traits.isEmpty { parts.append("Lately you've become \(traits.prefix(2).joined(separator: " and ")).") }
        if let age, let stage {
            parts.append("You are \(Int(age)) robot-years old.")
            if !stage.voiceNote.isEmpty { parts.append(stage.voiceNote) }
        }
        return parts.joined(separator: " ")
    }

    // MARK: The cue

    /// Assembles the cue. `notes` must already be picked and fitted (see `fit`).
    public static func cue(mood: String, notes: [Note]) -> String {
        open + ([mood] + notes.map(\.text)).joined(separator: " ") + close
    }

    public static func cue(mind: MindSnapshot, notes: [Note]) -> String {
        cue(mood: mood(mind), notes: fit(mood: mood(mind), notes: notes))
    }

    /// Channel function (§5): reads only `stance.notes` plus the mood of the same snapshot.
    public static func cue(stance: Stance, mind: MindSnapshot) -> String { cue(mind: mind, notes: stance.notes) }

    /// Orders notes (context first, then the aim, as in the §6.1 example), enforces ≤ 2 and ≤ 1 aim, drops any
    /// note over 30 tokens, then fits the whole cue to `budget`: the context note is
    /// dropped first, then the aim. The mood sentence always stays.
    public static func fit(mood: String, notes: [Note], budget: Int = maxTokens,
                           count: (String) -> Int = estimateTokens) -> [Note] {
        let aim = notes.filter { $0.role == .aim }.min { $0.priority < $1.priority }
        let ctx = notes.filter { $0.role == .context }.min { $0.priority < $1.priority }
        var chosen = [ctx, aim].compactMap { $0 }.filter { count($0.text) <= maxNoteTokens }
        while !chosen.isEmpty, count(cue(mood: mood, notes: chosen)) > budget {
            if let i = chosen.lastIndex(where: { $0.role == .context }) { chosen.remove(at: i) } else { chosen.removeLast() }
        }
        return chosen
    }

    /// Words a cue, note or canned line must never contain (§9: no reproach for absence).
    public static let reproachWords = ["where were you", "finally", "left me", "lonely", "ignored", "abandon", "missed you so"]

    /// The notes part of a cue (everything after the mood sentence), for reproach checks.
    /// (The mood sentence may honestly say "lonely" about her own feeling.)
    public static func notesPart(of cue: String, mood: String) -> String {
        var s = cue
        if s.hasPrefix(open) { s.removeFirst(open.count) }
        if s.hasSuffix(close) { s.removeLast(close.count) }
        if s.hasPrefix(mood) { s.removeFirst(mood.count) }
        return s
    }
}

/// SELF.md §6.3 — chooses ≤ 2 notes (≤ 1 aim) from the candidates sub-reducers
/// raised, applies the generic rules only — the §6.3 cooldowns, the distress drop,
/// "context must not contradict the aim" (incl. no gag unless repair is fine) — then
/// the §6.2 priority order and the budget, and remembers what it issued. Runs only
/// inside `Cortex.cue(at:)`.
///
/// Gates that belong to one reducer are applied by that reducer *before* it raises the
/// note (`Ongoing.raise(_:by:)`): hypothesis confidence ≥ 0.5 × gain (Interpreter),
/// deixis thresholds (Attention), gag playGate and the 0.4 × playfulness draw (Learner),
/// follow-up firing rules (IntentionBoard). Bookkeeping after issue (intention issued,
/// facet revealed, recall count, gag uses) is the owner's `noteIssued` hook.
public struct NotePicker: Sendable, Equatable {
    /// Cues written so far (one per LLM turn).
    public private(set) var turn = 0
    public private(set) var lastRecallTurn: Int?
    public private(set) var recalledEpisodes: [UUID: Date] = [:]
    public private(set) var lastTasteRevealConversation: Date?
    public private(set) var gagUses: [UUID: Date] = [:]
    public private(set) var lastHypothesisTurn: Int?
    public private(set) var lastVariant: [Note.Kind: Int] = [:]

    public static let recallEveryTurns = 4
    public static let recallSameEpisodeCooldown: TimeInterval = 2 * 86_400
    public static let gagCooldown: TimeInterval = 2 * 86_400
    public static let hypothesisEveryTurns = 3
    /// Context-bound notes older than this are not spoken: a recall or taste reveal
    /// raised by a sight at 10:00 must not surface at a cue hours later (finding 18).
    public static let staleAfter: TimeInterval = 30
    public static let staleKinds: Set<Note.Kind> = [.recall, .tasteReveal, .deixisResolved, .deixisAmbiguous, .deixisUnknown, .gagCallback]

    public init() {}

    /// Step 1: cooldowns and the distress / repair gates.
    public func eligible(_ n: Note, moment m: Moment) -> Bool {
        let now = m.now
        if m.ongoing.distressLive(at: now), n.kind.playfulOrTopical { return false }
        if Self.staleKinds.contains(n.kind), let at = n.raisedAt, now.timeIntervalSince(at) > Self.staleAfter { return false }
        // A safety net over every raiser: nothing that names a topic the speaker asked
        // her not to bring up (their active user boundaries; §7.8).
        if n.kind != .userBoundary, let person = m.ongoing.person,
           m.enduring.boundaries.contains(where: { $0.person == person && $0.owner == .user && $0.active && n.mentions($0.topic) }) {
            return false
        }
        switch n.kind {
        case .recall:
            if let last = lastRecallTurn, turn - last < Self.recallEveryTurns { return false }
            if let e = n.episode, let at = recalledEpisodes[e], now.timeIntervalSince(at) < Self.recallSameEpisodeCooldown { return false }
        case .tasteReveal:
            if m.ongoing.revealedThisConversation || lastTasteRevealConversation == m.ongoing.conversationStarted { return false }
        case .gagCallback:
            // The seeded 0.4 × playfulness draw and playGate are the raiser's gates (Learner).
            if m.ongoing.repair != .fine { return false }
            if let g = n.gag, let at = gagUses[g], now.timeIntervalSince(at) < Self.gagCooldown { return false }
        case .hypothesis:
            if let last = lastHypothesisTurn, turn - last < Self.hypothesisEveryTurns { return false }
        case .reunion:
            // "Be glad to see them" while they are hostile or the quarrel is open: repair wins.
            if m.ongoing.repair == .ruptured || m.ongoing.repair == .repairing { return false }
        default: break
        }
        return true
    }

    /// Step 2: a context note must not contradict the aim.
    static func compatible(context c: Note, aim: Note?) -> Bool {
        guard let aim else { return true }
        switch aim.kind {
        case .deeBoundary, .misread, .reconciled, .awkwardRepair:
            return ![.tasteReveal, .gagCallback, .reunion].contains(c.kind)
        default:
            return true
        }
    }

    /// Picks, fits and marks. `mood` is the mood sentence of the same snapshot.
    public mutating func pick(_ candidates: [Note], moment m: Moment, mood: String, rng: inout Rand,
                              budget: Int = CueWriter.maxTokens, count: (String) -> Int = CueWriter.estimateTokens) -> [Note] {
        var pool = candidates.filter { eligible($0, moment: m) }
        pool.sort { ($0.priority, $0.kind.rawValue) < ($1.priority, $1.kind.rawValue) }
        let aim = pool.first { $0.role == .aim }
        let context = pool.first { $0.role == .context && Self.compatible(context: $0, aim: aim) }
        var chosen = [aim, context].compactMap { $0 }
        // Seeded wording variant, never the same variant twice in a row for a kind.
        for i in chosen.indices {
            let k = chosen[i].kind
            let n = NoteTemplates.variants(k)
            guard n > 1 else { continue }
            var v = rng.index(n)
            if v == lastVariant[k] { v = (v + 1) % n }
            chosen[i].variant = v
        }
        chosen = CueWriter.fit(mood: mood, notes: chosen, budget: budget, count: count)
        mark(chosen, moment: m)
        turn += 1
        return chosen
    }

    mutating func mark(_ notes: [Note], moment m: Moment) {
        for n in notes {
            lastVariant[n.kind] = n.variant
            switch n.kind {
            case .recall:
                lastRecallTurn = turn
                if let e = n.episode { recalledEpisodes[e] = m.now }
            case .tasteReveal: lastTasteRevealConversation = m.ongoing.conversationStarted
            case .gagCallback: if let g = n.gag { gagUses[g] = m.now }
            case .hypothesis: lastHypothesisTurn = turn
            default: break
            }
        }
    }
}
