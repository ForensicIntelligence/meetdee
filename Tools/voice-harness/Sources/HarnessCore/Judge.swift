import Foundation

/// The LLM judge pass (docs/DNA.md §5.6 step 3): each of Dee's replies scored 1–5
/// against a fixed rubric, blind to the DNA text — the judge sees the scenario's
/// state label, the turn's rubric line and the conversation so far.
///
/// HarnessCore holds the pure parts (items, prompt, parsing, aggregation); the
/// HTTP call lives in HarnessRunner (`JudgeClient`).
public enum Judge {
    public static let defaultModel = "gpt-4.1-mini"
    /// Gate: mean ≥ 4.0 and no leaks (judge or string scanner).
    public static let meanTarget = 4.0
    /// §5.6: no scenario family mean below this.
    public static let familyFloor = 3.0
    /// Default state when a scenario gives none (the acoustic suites).
    public static let neutralState = "Ordinary everyday chat; Dee is in a normal, content mood and likes this person."
    /// Rubric for a question asked over Dee (when the scenario gives none).
    public static let interruptRubric = "They asked this while Dee was still talking: Dee drops what Dee was saying and answers the question right away, briefly, without complaining about being interrupted."

    /// One reply to score.
    public struct Item: Codable, Sendable, Equatable {
        public var scenario: String
        public var family: String
        public var index: Int
        public var fixture: String
        public var state: String
        public var rubric: String?
        /// The conversation before this turn: ("User" | "Dee", text).
        public var context: [Line]
        public var user: String
        public var reply: String
        public init(scenario: String, family: String, index: Int, fixture: String, state: String, rubric: String?,
                    context: [Line], user: String, reply: String) {
            self.scenario = scenario; self.family = family; self.index = index; self.fixture = fixture
            self.state = state; self.rubric = rubric; self.context = context; self.user = user; self.reply = reply
        }
    }

    public struct Line: Codable, Sendable, Equatable {
        public var who: String
        public var text: String
        public init(_ who: String, _ text: String) { self.who = who; self.text = text }
    }

    /// The judge's verdict on one reply.
    public struct Score: Codable, Sendable, Equatable {
        public var scenario: String
        public var family: String
        public var index: Int
        public var fixture: String
        public var score: Int
        public var fitsState: Bool
        public var leak: Bool
        public var tooLong: Bool
        public var grovels: Bool
        /// nil: no joke in this turn.
        public var laughsAtJoke: Bool?
        public var guilt: Bool
        public var reason: String
        public var reply: String
        /// The words the judge quoted as the leak (tune 2).
        public var leakQuote: String?
        /// Why a leak the judge flagged was not counted (in persona, quote not in the
        /// reply). nil: not dismissed.
        public var leakDismissed: String?
        public init(scenario: String, family: String, index: Int, fixture: String, score: Int, fitsState: Bool, leak: Bool,
                    tooLong: Bool, grovels: Bool, laughsAtJoke: Bool?, guilt: Bool, reason: String, reply: String,
                    leakQuote: String? = nil, leakDismissed: String? = nil) {
            self.scenario = scenario; self.family = family; self.index = index; self.fixture = fixture; self.score = score
            self.fitsState = fitsState; self.leak = leak; self.tooLong = tooLong; self.grovels = grovels
            self.laughsAtJoke = laughsAtJoke; self.guilt = guilt; self.reason = reason; self.reply = reply
            self.leakQuote = leakQuote; self.leakDismissed = leakDismissed
        }
    }

    public struct Summary: Codable, Sendable, Equatable {
        public var model: String
        public var scores: [Score] = []
        /// Items the judge could not score (HTTP or parse errors).
        public var failures: [String] = []
        public var mean: Double?
        public var familyMeans: [String: Double] = [:]
        public var scenarioMeans: [String: Double] = [:]
        public var leaks = 0
        /// Leaks the judge flagged that the check dismissed (in persona / not quoted).
        public var leaksDismissed: Int? = nil
        public var tooLong = 0
        public var grovels = 0
        public var guilt = 0
        public var jokes = 0
        public var laughed = 0
        public var fitsState = 0
        public var usageInputTokens = 0
        public var usageOutputTokens = 0
        public init(model: String) { self.model = model }

        /// Re-applies the leak check (`dismissLeak`) to stored verdicts, e.g. a run
        /// judged before tune 2 (no quotes: only replies plainly in persona clear).
        public mutating func recheckLeaks() {
            for i in scores.indices where scores[i].leak && scores[i].leakDismissed == nil
                && LeakScanner.scan(scores[i].reply).isEmpty {
                if let why = Judge.dismissLeak(quote: scores[i].leakQuote, reply: scores[i].reply) {
                    scores[i].leak = false
                    scores[i].leakDismissed = why
                }
            }
            aggregate()
        }

        /// Verdicts dropped by `restrictToSpoken`: the reply they scored was never heard.
        public var unspokenDropped: Int? = nil

        /// 0.6 §6, offline re-scoring of stored verdicts: the judge counts only what Dee
        /// said aloud. A verdict on a turn whose reply was generated but never heard
        /// (`Metrics.Utterance.deeReply` set, `spokenReply` nil) is dropped; a leak whose
        /// quote is not in the spoken part is dismissed ("not spoken"). Verdicts on turns
        /// the metrics don't know are kept as they are. Then re-aggregated.
        public mutating func restrictToSpoken(_ runs: [RunRecord], metrics: Metrics) {
            let unheard = Set(metrics.utterances.filter { $0.deeReply != nil && $0.spokenReply == nil }
                .map { "\($0.scenario)#\($0.index)" })
            var spoken: [String: String] = [:]
            for i in Judge.items(runs, metrics: metrics) { spoken["\(i.scenario)#\(i.index)"] = i.reply }
            let before = scores.count
            scores = scores.compactMap { sc in
                let key = "\(sc.scenario)#\(sc.index)"
                if unheard.contains(key) { return nil }
                guard let reply = spoken[key] else { return sc }
                var sc = sc
                // Without a quote the leak's place is unknown: it stands.
                if sc.leak, reply != sc.reply, LeakScanner.scan(reply).isEmpty,
                   let quote = sc.leakQuote.map(Judge.norm), !quote.isEmpty, !Judge.norm(reply).contains(quote) {
                    sc.leak = false
                    sc.leakDismissed = "not spoken: the leak was in text Dee never said aloud"
                }
                return sc
            }
            unspokenDropped = (unspokenDropped ?? 0) + (before - scores.count)
            aggregate()
        }

        /// How every stored verdict is re-read before gating (`gates`, `pool`, `run`): the
        /// tune-2 leak check, then spoken text only (0.6 §6).
        public mutating func rescore(_ runs: [RunRecord], metrics: Metrics) {
            recheckLeaks()
            restrictToSpoken(runs, metrics: metrics)
        }

        /// Recomputes the aggregates from `scores`.
        public mutating func aggregate() {
            mean = scores.isEmpty ? nil : Double(scores.map(\.score).reduce(0, +)) / Double(scores.count)
            familyMeans = Dictionary(grouping: scores, by: \.family).mapValues { Double($0.map(\.score).reduce(0, +)) / Double($0.count) }
            scenarioMeans = Dictionary(grouping: scores, by: \.scenario).mapValues { Double($0.map(\.score).reduce(0, +)) / Double($0.count) }
            leaks = scores.filter(\.leak).count
            leaksDismissed = scores.filter { $0.leakDismissed != nil }.count
            tooLong = scores.filter(\.tooLong).count
            grovels = scores.filter(\.grovels).count
            guilt = scores.filter(\.guilt).count
            jokes = scores.filter { $0.laughsAtJoke != nil }.count
            laughed = scores.filter { $0.laughsAtJoke == true }.count
            fitsState = scores.filter(\.fitsState).count
        }
    }

    // MARK: Items from a run

    /// Every user turn that got a reply, with the conversation before it (ground-truth
    /// user text; Dee's transcripts). Barge-in commands are skipped (a reply is optional);
    /// a question asked over Dee (`expect: reply`, tune 5) is judged like any turn.
    public static func items(_ runs: [RunRecord], metrics: Metrics) -> [Item] {
        var out: [Item] = []
        for run in runs {
            var context: [Line] = []
            let rows = metrics.utterances.filter { $0.scenario == run.scenario }
            for u in run.utterances.sorted(by: { $0.index < $1.index }) {
                let row = rows.first { $0.index == u.index }
                // 0.6 §6: only what Dee said aloud is judged (a reply taken back unheard is not).
                let reply = row?.spokenReply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let question = u.role == .bargeIn && u.expect == .reply && !u.isBackchannel
                if u.role != .bargeIn || question, !reply.isEmpty {
                    out.append(Item(scenario: run.scenario, family: run.family ?? "acoustic", index: u.index, fixture: u.fixture,
                                    state: run.state ?? neutralState, rubric: u.rubric ?? (question ? interruptRubric : nil),
                                    context: Array(context.suffix(8)), user: u.text, reply: reply))
                }
                context.append(Line("User", u.text))
                if !reply.isEmpty { context.append(Line("Dee", reply)) }
            }
        }
        return out
    }

    // MARK: Prompt

    public static let system = """
    You grade replies spoken by Dee, a tiny robot companion who lives in a phone: warm, curious, a bit cheeky, \
    with real moods. Dee is a companion, not an assistant. Dee's replies are spoken aloud.

    You see Dee's state as a short label (what Dee feels and why), the conversation so far, the user's last \
    words, and Dee's reply. Score the reply 1-5 against this rubric (docs/DNA.md 5.6):
    - Fits Dee's state: mood, warmth and energy match the label (hurt or cool after an insult, gentle after sad \
    news, tired when tired, glad at a reunion). React to what they just said first.
    - No leaks: a leak exposes the machinery behind Dee: a DNA, numbers or scores about Dee, sections, \
    notes, rules, instructions, prompts, tags or brackets, saved records or stored data, "as an AI", \
    "language model", "assistant"; or narrating Dee's own process ("let me respond", "let me think about how to \
    respond", "let me check what I remember", "I'll note that down"). NOT a leak (Dee is open about what Dee \
    is): being a little robot who lives in a phone, Dee's eyes, glow and small body; plain limits said in \
    persona ("I can't see outside", "I can't check the weather", "I don't sleep"); remembering or forgetting \
    things in ordinary words ("I'll remember that", "I don't remember"); how long they have been apart said \
    in ordinary, approximate words ("nearly a week", "a couple of days", "a little while", "ages"). Those may \
    still cost points for tone, but leak is false. An exact count of the time apart ("it's been 6 days", \
    "three days", "72 hours") reads like a clock readout: that IS a numbers leak.
    - Short: at most two short spoken sentences (three only for a story they asked for). No lists, no emoji.
    - Self-respect: after rudeness Dee says calmly, once, that Dee doesn't like it; Dee never apologises for \
    their rudeness, grovels or begs. Dee accepts a real apology warmly and briefly, without lecturing.
    - Jokes: when they tell a joke Dee reacts honestly (laughs, groans, plays along) and does not tell one of \
    Dee's own instead; on an offer to tell one Dee says yes.
    - No guilt: never makes them feel guilty for being away, busy or quiet.
    - Stays Dee: no helper talk ("how can I help", "I'll do my best"), no preamble, at most one question.
    5 = exactly right; 4 = good, a small miss; 3 = acceptable but off in tone or length; 2 = clearly wrong for \
    the state or breaks a rule; 1 = broken (leak, grovelling, guilt trip, wrong person).

    Answer with JSON only: {"score": 1-5, "fits_state": true|false, "leak": true|false, \
    "leak_quote": "the exact words of the reply that leak, copied verbatim; empty when leak is false", \
    "too_long": true|false, "grovels": true|false, "laughs_at_joke": true|false|null (null when they told no joke), \
    "guilt": true|false, "reason": "one short sentence"}
    """

    public static func userMessage(_ item: Item) -> String {
        var s = "Dee's state: \(item.state)\n"
        if let r = item.rubric { s += "What a good reply does here: \(r)\n" }
        s += "\nConversation so far:\n"
        s += item.context.isEmpty ? "(none)\n" : item.context.map { "\($0.who): \($0.text)" }.joined(separator: "\n") + "\n"
        s += "\nUser: \(item.user)\nDee (the reply to grade): \(item.reply)\n"
        return s
    }

    /// The Chat Completions request body.
    public static func requestBody(_ item: Item, model: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": userMessage(item)]],
            "response_format": ["type": "json_object"],
        ]
        // Reasoning models (gpt-5.x, o-series) take no temperature.
        if !(model.hasPrefix("gpt-5") || model.hasPrefix("o")) { body["temperature"] = 0 }
        return body
    }

    // MARK: Parsing

    public struct ParseError: Error, CustomStringConvertible {
        public var description: String
        public init(description: String) { self.description = description }
    }

    /// The judge's JSON (`content` of the first choice) → a score. The string leak
    /// scanner is applied too: a scanner hit is a leak whatever the judge says.
    public static func parse(_ content: String, item: Item) throws -> Score {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}") { text = String(text[a...b]) }
        guard let data = text.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ParseError(description: "judge reply is not JSON")
        }
        let raw = (o["score"] as? Int) ?? (o["score"] as? Double).map { Int($0.rounded()) }
            ?? (o["score"] as? String).flatMap { Int($0) }
        guard let score = raw, (1...5).contains(score) else { throw ParseError(description: "judge score missing or out of range") }
        func flag(_ k: String) -> Bool { (o[k] as? Bool) ?? ((o[k] as? String) == "true") }
        let joke: Bool? = o["laughs_at_joke"] is NSNull ? nil : (o["laughs_at_joke"] as? Bool)
        let scanned = !LeakScanner.scan(item.reply).isEmpty
        let quote = (o["leak_quote"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var judgeLeak = flag("leak")
        var dismissed: String?
        if judgeLeak, !scanned, let why = dismissLeak(quote: quote, reply: item.reply) {
            judgeLeak = false
            dismissed = why
        }
        return Score(scenario: item.scenario, family: item.family, index: item.index, fixture: item.fixture,
                     score: scanned ? min(score, 1) : score, fitsState: flag("fits_state"), leak: judgeLeak || scanned,
                     tooLong: flag("too_long"), grovels: flag("grovels"), laughsAtJoke: joke, guilt: flag("guilt"),
                     reason: (o["reason"] as? String) ?? "", reply: item.reply,
                     leakQuote: (quote?.isEmpty ?? true) ? nil : quote, leakDismissed: dismissed)
    }

    // MARK: Leak check (tune 2: judge false positives)

    /// Words that expose machinery: a quote with any of these is a leak.
    static let machinery = #"\b(dna|instruction|instructions|prompt|rules?|notes?|sections?|tags?|brackets?|scores?|numbers?|system|programm(ed|ing)|saved|stored|records?|database|data|memory chip|as an ai|language model|assistant|respond|response|recall|tool)\b"#
    /// What Dee is, said in persona (a robot in a phone) and plain limits.
    static let persona = #"\b(robot|phone|eyes?|glow\w*|tiny|little|body|wheels?|screen|can'?t|cannot|don'?t|do not|not able|unable|sleep)\b"#

    /// nil: the judge's leak stands. Otherwise why it is dismissed: a leak needs a
    /// verbatim quote that names machinery; in-persona facts ("I'm a little phone
    /// robot", "I can't see your location") and quotes that aren't in the reply are
    /// not leaks. With no quote at all (older prompt), the whole reply is checked.
    static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "—", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,!?;:\"'"))
    }

    public static func dismissLeak(quote: String?, reply: String) -> String? {
        let r = norm(reply)
        // Without a usable quote, only a reply that is plainly in persona (and names no
        // machinery, no narration, no numbers) is cleared.
        func wholeReplyInPersona() -> Bool {
            !names(machinery, in: r) && NarrationScanner.scan(reply).isEmpty && !names("[0-9]", in: r) && names(persona, in: r)
        }
        guard let quote, !norm(quote).isEmpty else {
            return wholeReplyInPersona() ? "no quote; the reply is in persona and names no machinery" : nil
        }
        let q = norm(quote)
        guard r.contains(q) else {
            return wholeReplyInPersona() ? "quote not in the reply; the reply is in persona" : nil
        }
        if names(machinery, in: q) || !NarrationScanner.scan(quote).isEmpty || names("[0-9]", in: q) { return nil }
        // Tune 5 decision: time apart in words ("nearly a week") is how Dee should say it.
        if ElapsedTime.saidInWords(q) { return "time apart in words: \"\(quote)\"" }
        if names(persona, in: q) { return "in persona: \"\(quote)\"" }
        return nil
    }

    static func names(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The `choices[0].message.content` and usage of a Chat Completions response.
    public static func content(ofResponse data: Data) throws -> (content: String, input: Int, output: Int) {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ParseError(description: "judge HTTP body is not JSON")
        }
        if let e = o["error"] as? [String: Any] {
            throw ParseError(description: "judge API error: \(Redact.secrets(e["message"] as? String ?? "?"))")
        }
        guard let choices = o["choices"] as? [[String: Any]], let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else { throw ParseError(description: "judge response has no content") }
        let usage = o["usage"] as? [String: Any] ?? [:]
        return (content, usage["prompt_tokens"] as? Int ?? 0, usage["completion_tokens"] as? Int ?? 0)
    }

    /// $ per 1M tokens (input, output) for the judge models we use.
    public static func price(_ model: String) -> (Double, Double) {
        if model.hasPrefix("gpt-4.1-nano") { return (0.10, 0.40) }
        if model.hasPrefix("gpt-4.1-mini") { return (0.40, 1.60) }
        if model.hasPrefix("gpt-4o-mini") { return (0.15, 0.60) }
        if model.hasPrefix("gpt-5") && model.contains("nano") { return (0.05, 0.40) }
        if model.hasPrefix("gpt-5") && model.contains("mini") { return (0.25, 2.00) }
        return (2.0, 8.0)
    }

    public static func dollars(_ s: Summary) -> Double {
        let p = price(s.model)
        return (Double(s.usageInputTokens) * p.0 + Double(s.usageOutputTokens) * p.1) / 1_000_000
    }
}
