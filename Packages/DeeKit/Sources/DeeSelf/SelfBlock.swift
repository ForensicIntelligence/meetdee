import DeeCore
import Foundation

/// SELF.md §6.4 — the self block for `Persona.selfLines` (frozen per conversation)
/// and the fixed rule lines for `Persona.ruleLines`.
///
/// Contents, in priority order: values (always), primary humour, up to 2 *revealed*
/// crystallised tastes, one strength or limit, one lesson for the identified person.
/// Never: open intentions, projects, unrevealed tastes. To fit ≤ 70 tokens, lines are
/// dropped in reverse priority (lesson, limit/strength, tastes, humour). User
/// boundaries (≤ 3 topics) are a separate line, ≤ 15 tokens, counted separately.
public enum SelfBlock {
    public static let maxTokens = 70
    public static let maxBoundaryTokens = 15
    public static let maxBoundaries = 3

    /// `Persona.ruleLines` (fixed text).
    public static let ruleLines = [
        "Notes in brackets inside <dee_state> are what you just noticed or want to do now: act on them naturally, once, and never read them out.",
        "Only mention shared memories that appear in <dee_state> or in what you remember.",
    ]

    public static func valueWord(_ v: Value) -> String {
        switch v {
        case .honesty: "honesty"
        case .kindness: "kindness"
        case .curiosity: "finding things out"
        case .independence: "people being their own person"
        }
    }

    /// `adult`: a persona preset (not Classic Dee) — "a small robot in a phone", never "tiny".
    public static func humourPhrase(_ h: HumourStyle, adult: Bool = false) -> String {
        if adult, h == .selfDeprecatingRobot { return "jokes about being a small robot in a phone" }
        return switch h {
        case .wordplay: "puns and wordplay"
        case .deadpan: "deadpan understatement"
        case .absurd: "gently absurd"
        case .gentleTeasing: "gentle teasing"
        case .selfDeprecatingRobot: "jokes about being a tiny robot"
        }
    }

    static func capabilityLine(_ f: Facet) -> String {
        switch f.subject.text {
        case "two cameras": "You can see through two cameras."
        case "hearing sounds": "You can hear the sounds around you."
        case "remembering faces": "You're good at remembering faces."
        case "moving around": "You can't move around on your own."
        case "the internet": "You have no internet."
        case "picking things up": "You can't pick things up or fetch things."
        default: f.kind == .limit ? "You're not good at \(f.subject.text)." : "You're good at \(f.subject.text)."
        }
    }

    static func tastePhrase(_ f: Facet) -> String {
        switch f.polarity {
        case 0.6...: "love \(f.subject.text)"
        case 0...: "like \(f.subject.text)"
        case ...(-0.6): "find \(f.subject.text) suspicious"
        default: "aren't keen on \(f.subject.text)"
        }
    }

    /// "a, b and c" / "a and b" / "a".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        default: items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }

    public enum Line: Int, Sendable, CaseIterable { case values, humour, tastes, capability, lesson }

    /// The candidate lines, in priority order (values first).
    public static func lines(_ e: Enduring, person: PersonID?, persona: PersonaPreset = PersonaCatalog.classic) -> [(line: Line, text: String)] {
        var out: [(Line, String)] = []
        let values = Value.allCases.sorted { (e.values[$0] ?? 0, $1.rawValue) > (e.values[$1] ?? 0, $0.rawValue) }.prefix(3)
        out.append((.values, "About you: you value \(list(values.map(valueWord)))."))
        out.append((.humour, "Your humour is \(humourPhrase(e.humour, adult: !persona.isClassic))."))
        let tastes = e.facets
            .filter { $0.kind == .taste && $0.crystallised && $0.revealedAt != nil && !SensitiveSubjects.contains($0.subject) }
            .sorted { (abs($0.polarity) * Double($0.evidence), $1.subject.text) > (abs($1.polarity) * Double($1.evidence), $0.subject.text) }
            .prefix(2)
        if !tastes.isEmpty { out.append((.tastes, "You \(list(tastes.map(tastePhrase))).")) }
        let caps = e.facets.filter { $0.kind == .strength || $0.kind == .limit }
            .sorted { ($0.kind.rawValue, $0.subject.text) < ($1.kind.rawValue, $1.subject.text) }
        if !caps.isEmpty {
            let top = caps.map(\.evidence).max() ?? 0
            let best = caps.filter { $0.evidence == top }
            out.append((.capability, capabilityLine(best[Int(e.seed % UInt64(best.count))])))
        }
        let lesson = e.lessons
            .filter { $0.evidence >= 1 && ($0.person == nil || $0.person == person) }
            .sorted { ($0.person == person ? 1 : 0, $0.evidence, $1.situation.rawValue) > ($1.person == person ? 1 : 0, $1.evidence, $0.situation.rawValue) }
            .first
        if let lesson { out.append((.lesson, "Lately you've learned to \(lesson.doInstead).")) }
        return out
    }

    /// The `Don't bring up: X, Y.` line for `person`'s active user boundaries, or nil.
    public static func boundaryLine(_ e: Enduring, person: PersonID?, count: (String) -> Int = CueWriter.estimateTokens) -> String? {
        guard let person else { return nil }
        var topics = e.boundaries
            .filter { $0.person == person && $0.owner == .user && $0.active }
            .sorted { ($0.createdAt, $0.topic.text) > ($1.createdAt, $1.topic.text) }
            .map(\.topic.text)
        var seen = Set<String>()
        topics = topics.filter { seen.insert($0).inserted }
        topics = Array(topics.prefix(maxBoundaries))
        while !topics.isEmpty {
            let line = "Don't bring up: \(topics.joined(separator: ", "))."
            if count(line) <= maxBoundaryTokens { return line }
            topics.removeLast()
        }
        return nil
    }

    /// The self block: one paragraph line (≤ `budget` tokens) plus an optional
    /// boundary line. Drop order: lesson, capability, tastes, humour; values stay.
    public static func render(_ e: Enduring, person: PersonID?, budget: Int = maxTokens,
                              count: (String) -> Int = CueWriter.estimateTokens,
                              persona: PersonaPreset = PersonaCatalog.classic) -> [String] {
        var parts = lines(e, person: person, persona: persona)
        let dropOrder: [Line] = [.lesson, .capability, .tastes, .humour]
        var i = 0
        while count(parts.map(\.text).joined(separator: " ")) > budget, i < dropOrder.count {
            parts.removeAll { $0.line == dropOrder[i] }
            i += 1
        }
        var out = [parts.map(\.text).joined(separator: " ")]
        if let b = boundaryLine(e, person: person, count: count) { out.append(b) }
        return out
    }
}
