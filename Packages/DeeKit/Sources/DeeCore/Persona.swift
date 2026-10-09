import Foundation

/// Who Dee is. The system prompt is kept short on purpose: with a 4096-token window
/// every sentence here is a sentence of conversation Dee can't remember.
public struct Persona: Sendable, Equatable {
    public var name: String
    public var userName: String?
    /// Durable facts about the user ("likes jazz", "has a cat called Miso").
    public var memories: [String]

    public init(name: String = "Dee", userName: String? = nil, memories: [String] = []) {
        self.name = name
        self.userName = userName
        self.memories = memories
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
            "Your words are spoken aloud, so reply in one to three short, natural sentences. Never use markdown, lists, headings, code blocks or emoji.",
            "Start every reply with exactly one feeling tag that matches your mood: \(tags). You may add another tag later in the reply when your mood changes.",
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
