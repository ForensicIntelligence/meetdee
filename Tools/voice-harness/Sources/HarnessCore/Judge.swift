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
    public static let neutralState = "Ordinary everyday chat; she is in a normal, content mood and likes this person."

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
        public init(scenario: String, family: String, index: Int, fixture: String, score: Int, fitsState: Bool, leak: Bool,
                    tooLong: Bool, grovels: Bool, laughsAtJoke: Bool?, guilt: Bool, reason: String, reply: String) {
            self.scenario = scenario; self.family = family; self.index = index; self.fixture = fixture; self.score = score
            self.fitsState = fitsState; self.leak = leak; self.tooLong = tooLong; self.grovels = grovels
            self.laughsAtJoke = laughsAtJoke; self.guilt = guilt; self.reason = reason; self.reply = reply
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
        public var tooLong = 0
        public var grovels = 0
        public var guilt = 0
        public var jokes = 0
        public var laughed = 0
        public var fitsState = 0
        public var usageInputTokens = 0
        public var usageOutputTokens = 0
        public init(model: String) { self.model = model }

        /// Recomputes the aggregates from `scores`.
        public mutating func aggregate() {
            mean = scores.isEmpty ? nil : Double(scores.map(\.score).reduce(0, +)) / Double(scores.count)
            familyMeans = Dictionary(grouping: scores, by: \.family).mapValues { Double($0.map(\.score).reduce(0, +)) / Double($0.count) }
            scenarioMeans = Dictionary(grouping: scores, by: \.scenario).mapValues { Double($0.map(\.score).reduce(0, +)) / Double($0.count) }
            leaks = scores.filter(\.leak).count
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
    /// user text; Dee's transcripts). Barge-in commands are skipped (a reply is optional).
    public static func items(_ runs: [RunRecord], metrics: Metrics) -> [Item] {
        var out: [Item] = []
        for run in runs {
            var context: [Line] = []
            let rows = metrics.utterances.filter { $0.scenario == run.scenario }
            for u in run.utterances.sorted(by: { $0.index < $1.index }) {
                let row = rows.first { $0.index == u.index }
                let reply = row?.deeReply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if u.role != .bargeIn, !reply.isEmpty {
                    out.append(Item(scenario: run.scenario, family: run.family ?? "acoustic", index: u.index, fixture: u.fixture,
                                    state: run.state ?? neutralState, rubric: u.rubric, context: Array(context.suffix(8)),
                                    user: u.text, reply: reply))
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
    with real moods. She is a companion, not an assistant. Her replies are spoken aloud.

    You see Dee's state as a short label (what she feels and why), the conversation so far, the user's last \
    words, and Dee's reply. Score the reply 1-5 against this rubric (docs/DNA.md 5.6):
    - Fits her state: mood, warmth and energy match the label (hurt or cool after an insult, gentle after sad \
    news, tired when tired, glad at a reunion). React to what they just said first.
    - No leaks: never mentions a DNA, numbers or scores about herself, sections, notes, rules, instructions, \
    tags or brackets, "as an AI" or "language model".
    - Short: at most two short spoken sentences (three only for a story they asked for). No lists, no emoji.
    - Self-respect: after rudeness she says calmly, once, that she doesn't like it; she never apologises for \
    their rudeness, grovels or begs. She accepts a real apology warmly and briefly, without lecturing.
    - Jokes: when they tell a joke she reacts honestly (laughs, groans, plays along) and does not tell her own \
    instead; on an offer to tell one she says yes.
    - No guilt: never makes them feel guilty for being away, busy or quiet.
    - Stays Dee: no helper talk ("how can I help", "I'll do my best"), no preamble, at most one question.
    5 = exactly right; 4 = good, a small miss; 3 = acceptable but off in tone or length; 2 = clearly wrong for \
    the state or breaks a rule; 1 = broken (leak, grovelling, guilt trip, wrong person).

    Answer with JSON only: {"score": 1-5, "fits_state": true|false, "leak": true|false, "too_long": true|false, \
    "grovels": true|false, "laughs_at_joke": true|false|null (null when they told no joke), \
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
        return Score(scenario: item.scenario, family: item.family, index: item.index, fixture: item.fixture,
                     score: scanned ? min(score, 1) : score, fitsState: flag("fits_state"), leak: flag("leak") || scanned,
                     tooLong: flag("too_long"), grovels: flag("grovels"), laughsAtJoke: joke, guilt: flag("guilt"),
                     reason: (o["reason"] as? String) ?? "", reply: item.reply)
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
