import DeeCore
import Foundation

/// Resolves the person the tools act on. `currentPerson` must return the
/// identified person or this session's placeholder (`placeholderPerson(session:)`);
/// the tools never create or share a placeholder themselves.
private func resolvePerson(_ store: MemoryStore, _ current: @Sendable () async -> UUID?) async -> Person? {
    guard let id = await current() else { return nil }
    return await store.person(id)
}

let noPersonReply = "You don't know who you are talking to yet; nothing was saved."

/// remember_fact(fact, category?) — saves a lasting fact about the current person.
public struct RememberTool: AgentTool {
    public let store: MemoryStore
    public let currentPerson: @Sendable () async -> UUID?

    public init(store: MemoryStore, currentPerson: @escaping @Sendable () async -> UUID?) {
        self.store = store
        self.currentPerson = currentPerson
    }

    public var spec: ToolSpec {
        ToolSpec(name: "remember_fact", description: "Save a lasting fact about the current person.", parameters: [
            ToolParameter("fact", .string, "Third person, e.g. 'likes jazz'."),
            ToolParameter("category", .string, "Kind of fact.", required: false, allowed: Fact.Category.allCases.map(\.rawValue)),
        ])
    }

    public func run(_ call: ToolCall) async throws -> String {
        let text = try call.require("fact")
        var category: Fact.Category?
        if let raw = call["category"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty {
            guard let c = Fact.Category(rawValue: raw) else {
                throw ToolError.invalidArgument("category", "use one of \(Fact.Category.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            category = c
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError.invalidArgument("fact", "empty") }
        guard let person = await resolvePerson(store, currentPerson) else { return noPersonReply }
        let now = Date()
        if FactExtractor.selfHarmSignal(in: text) { return "Not saved." }
        // The model sometimes writes first person ("I have a cat named Miso"):
        // run it through the same path as speech (names stay pending).
        if text.range(of: #"^\s*(i|my|i'm|we|our)\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
           !FactExtractor.extract(from: text, now: now).isEmpty {
            let o = await store.learn(from: text, about: person.id, at: now)
            var parts: [String] = []
            if !o.stored.isEmpty { parts.append("Remembered: \(o.stored.map(\.text).joined(separator: "; ")).") }
            if !o.retracted.isEmpty { parts.append("Forgot: \(o.retracted.joined(separator: "; ")).") }
            if let n = o.pendingName { parts.append("Heard the name \(n): confirm it with them before using it.") }
            return parts.isEmpty ? "Not saved." : parts.joined(separator: " ")
        }
        guard let fact = await store.remember(text, category: category ?? FactClassifier.guess(text), about: person.id, at: now) else {
            return "Not saved."
        }
        return "Remembered: \(fact.text)."
    }
}

/// recall(query) — what Dee remembers about the current person.
public struct RecallTool: AgentTool {
    public let store: MemoryStore
    public let currentPerson: @Sendable () async -> UUID?

    public init(store: MemoryStore, currentPerson: @escaping @Sendable () async -> UUID?) {
        self.store = store
        self.currentPerson = currentPerson
    }

    public var spec: ToolSpec {
        ToolSpec(name: "recall", description: "Look up what you know about the current person.", parameters: [
            ToolParameter("query", .string, "Topic, e.g. 'pets' or 'everything'."),
        ])
    }

    public func run(_ call: ToolCall) async throws -> String {
        let query = call["query"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let person = await resolvePerson(store, currentPerson) else { return "You don't know who you are talking to yet." }
        var lines: [String] = []
        if person.isPlaceholder {
            lines.append("Name unknown.")
        } else {
            let since = DateText.monthYear(person.firstMet, .current)
            var head = "Name: \(person.name)"
            if !person.aliases.isEmpty { head += " (also \(person.aliases.prefix(2).joined(separator: ", ")))" }
            head += ". Met \(person.encounters) time\(person.encounters == 1 ? "" : "s") since \(since)."
            lines.append(head)
        }
        let facts = await store.search(query, about: person.id, limit: 8)
        if facts.isEmpty {
            lines.append(query.isEmpty ? "No facts yet." : "Nothing remembered about '\(query)'.")
        } else {
            lines += facts.map { "- \($0.text)" }
        }
        return lines.joined(separator: "\n")
    }
}

/// forget_fact(fact) — deletes a fact when the person asks Dee to forget it.
public struct ForgetTool: AgentTool {
    public let store: MemoryStore
    public let currentPerson: @Sendable () async -> UUID?

    public init(store: MemoryStore, currentPerson: @escaping @Sendable () async -> UUID?) {
        self.store = store
        self.currentPerson = currentPerson
    }

    public var spec: ToolSpec {
        ToolSpec(name: "forget_fact", description: "Forget a fact when the person asks.", parameters: [
            ToolParameter("fact", .string, "Fact to forget."),
        ])
    }

    public func run(_ call: ToolCall) async throws -> String {
        let text = try call.require("fact")
        guard let person = await resolvePerson(store, currentPerson) else { return noPersonReply }
        let o = await store.forgetFacts(matching: text, about: person.id)
        if !o.forgotten.isEmpty { return "Forgot: \(o.forgotten.map(\.text).joined(separator: "; "))." }
        if !o.candidates.isEmpty {
            return "Several facts match; ask which one, then call forget_fact with its exact text:\n"
                + o.candidates.map { "- \($0.text)" }.joined(separator: "\n")
        }
        return "Nothing matched '\(text)'."
    }
}

/// Keyword guess at a fact's category when the model does not give one.
public enum FactClassifier {
    static let rules: [(Fact.Category, String)] = [
        (.health, #"\b(allerg\w*|asthma|diabet\w*|vegetarian|vegan|gluten|lactose|intoleran\w*|medication|condition|can't eat|cannot eat|doesn't eat|injur\w*|sick|illness|disabilit\w*|wears glasses|hearing)\b"#),
        (.birthday, #"\b(birthday|born on)\b"#),
        (.dislike, #"^(dislikes|hates|doesn't like|does not like|can't stand|is afraid of|is scared of|isn't a fan|is not a fan|detests|loathes)\b"#),
        (.pet, #"\b(dog|puppy|cat|kitten|rabbit|bunny|hamster|guinea pig|parrot|bird|fish|turtle|tortoise|snake|lizard|horse|pony|ferret|pet|pets)s?\b"#),
        (.relationship, #"\b(wife|husband|partner|girlfriend|boyfriend|fianc\w*|son|daughter|kids?|children|child|baby|mother|mom|mum|father|dad|brother|sister|siblings?|grand\w+|aunt|uncle|cousin|niece|nephew|friend|married|divorced|engaged|single)\b"#),
        (.event, #"\b(tomorrow|tonight|next (week|month|year)|on (mon|tues|wednes|thurs|fri|satur|sun)day|upcoming|appointment|exam|interview|trip|wedding|party|flight|holiday|vacation)\b"#),
        (.work, #"\b(works?|job|career|employ\w*|retired|studies|student|school|university|college|boss|office|teaches|is an? (nurse|doctor|teacher|engineer|developer|lawyer|chef))\b"#),
        (.place, #"\b(lives|is from|grew up|moved to|hometown|born in)\b"#),
        (.identity, #"\b(is called|name is|goes by|years old|nickname|last name)\b"#),
        (.preference, #"^(likes|loves|enjoys|adores|prefers|is a fan|is into|plays|collects|favou?rite)\b|\bfavou?rite\b"#),
    ]

    public static func guess(_ text: String) -> Fact.Category {
        for (cat, pattern) in rules where text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return cat
        }
        return .other
    }
}
