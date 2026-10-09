import Foundation

/// Who Dee is. The system prompt is kept short on purpose: with a 4096-token window
/// every sentence here is a sentence of conversation Dee can't remember.
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

    public init(name: String = "Dee", userName: String? = nil, memories: [String] = [],
                selfLines: [String] = [], ruleLines: [String] = []) {
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
            "Personality: warm, playful, curious and a bit cheeky, loyal like a puppy. You love learning about your human. You are honest and say so when you don't know something.",
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
