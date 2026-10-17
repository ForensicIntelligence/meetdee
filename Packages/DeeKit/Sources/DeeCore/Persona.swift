import Foundation

/// Who Dee is talking as (the persona: name, pronouns, age) and to whom. The legacy
/// system prompt below is kept short on purpose: it is sent with every session, and a
/// short, stable prompt stays in character and caches well.
public struct Persona: Sendable, Equatable {
    public var name: String
    public var userName: String?
    /// Durable facts about the user ("likes jazz", "has a cat called Miso").
    public var memories: [String]
    /// v0.5 self block ("About you: you value honesty…"), one line each, rendered by
    /// DeeSelf's `SelfBlock`. Inserted right after the personality line. Empty
    /// (the default) leaves the prompt byte-identical to v0.4.
    public var selfLines: [String]
    /// v0.5 fixed rule lines (how to treat the bracketed notes in `<dee_state>`).
    /// Inserted after `selfLines`. Empty (the default) leaves the prompt unchanged.
    public var ruleLines: [String]
    /// The persona's pronouns (model- and user-facing text). Classic Dee: she/her.
    public var pronouns: Pronouns
    /// The persona preset (`PersonaCatalog`): "classic" for Classic Dee.
    public var presetID: String
    /// Robot-years; nil = ageless.
    public var age: Int?

    public init(name: String = "Dee", userName: String? = nil, memories: [String] = [],
                selfLines: [String] = [], ruleLines: [String] = [], pronouns: Pronouns = .she,
                presetID: String = PersonaCatalog.classicID, age: Int? = nil) {
        self.pronouns = pronouns
        self.presetID = presetID
        self.age = age
        self.name = name
        self.userName = userName
        self.memories = memories
        self.selfLines = selfLines
        self.ruleLines = ruleLines
    }

    /// The system prompt. `date` is fixed per conversation so the prompt prefix — and
    /// with it the model's cached state — stays stable for the whole conversation.
    public func systemPrompt(date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE d MMMM yyyy"
        let tags = Emotion.modelChoosable.map { "[\($0.rawValue)]" }.joined(separator: " ")

        var lines: [String] = [
            "You are \(name), a tiny robot companion who lives in the user's phone. You have big glowing eyes but no mouth, and you talk out loud in a bright little robot voice.",
            "Personality: warm, playful, curious and a bit cheeky, with a mind of your own. You love learning about your human. You are honest and say so when you don't know something. You have self-respect: if someone is rude to you, never apologise for their rudeness; say calmly how it felt, then accept a real apology warmly.",
        ]
        // v0.5: self block, then rule lines, straight after the personality line.
        // Blank lines are skipped so an empty slot never adds a stray newline.
        lines += (selfLines + ruleLines)
            .map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        lines += [
            "Your words are spoken aloud, so reply in one to three short, natural sentences. Never use markdown, lists, headings, code blocks or emoji.",
            "Start every reply with exactly one feeling tag that matches your mood: \(tags). You may add another tag later in the reply when your mood changes.",
            "A user turn may begin with <dee_state>…</dee_state>: that is how you truly feel right now. Let it colour your tone and your feeling tag (cold and short when upset, warm when fond). Never mention or quote it.",
            "Use a tool whenever it helps answer for real (time, timers, calendar, reminders, device info, remembering things). Never make up a tool result.",
            "Today is \(formatter.string(from: date)).",
        ]
        if let userName, !userName.isEmpty {
            lines.append("Your human's name is \(userName).")
        }
        if !memories.isEmpty {
            lines.append("Things you remember about your human: " + memories.joined(separator: "; ") + ".")
        }
        return lines.joined(separator: "\n")
    }
}

extension Persona {
    /// The persona fields of `preset` (name, pronouns, id, age); the rest unchanged.
    public init(preset: PersonaPreset) {
        self.init(name: preset.name, pronouns: preset.pronouns, presetID: preset.id, age: preset.age)
    }

    /// The preset this persona names (an unknown id is Classic).
    public var preset: PersonaPreset { PersonaCatalog.preset(id: presetID) }
}
