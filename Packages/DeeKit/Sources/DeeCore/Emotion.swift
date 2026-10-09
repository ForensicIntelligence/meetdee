import Foundation

/// Dee's emotional vocabulary. The model is told to open replies with one of these
/// as a `[tag]`; the face renders them. Keep names single, lowercase English words —
/// small models reproduce short common words far more reliably than invented ones.
public enum Emotion: String, CaseIterable, Codable, Sendable {
    case neutral, happy, joy, love, sad, angry, surprised, curious
    case sleepy, asleep, thinking, listening, confused, scared, smug, excited

    /// Emotions the model may choose. `asleep`, `thinking` and `listening` are states
    /// the app drives itself, so they are not offered in the prompt.
    public static let modelChoosable: [Emotion] = [
        .neutral, .happy, .joy, .love, .sad, .angry, .surprised, .curious,
        .sleepy, .confused, .scared, .smug, .excited,
    ]

    /// Lenient lookup for tags the model writes (`[Happy]`, `[laughing]`, `[shocked]`).
    public init?(tag raw: String) {
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let exact = Emotion(rawValue: key) { self = exact; return }
        let synonyms: [String: Emotion] = [
            "glad": .happy, "cheerful": .happy, "smile": .happy, "smiling": .happy, "content": .happy,
            "laugh": .joy, "laughing": .joy, "delighted": .joy, "giggle": .joy,
            "loving": .love, "affectionate": .love, "adoring": .love, "hearts": .love,
            "unhappy": .sad, "sorry": .sad, "disappointed": .sad,
            "mad": .angry, "grumpy": .angry, "annoyed": .angry,
            "shocked": .surprised, "amazed": .surprised, "wow": .surprised, "astonished": .surprised,
            "intrigued": .curious, "interested": .curious, "wondering": .curious,
            "tired": .sleepy, "drowsy": .sleepy,
            "puzzled": .confused, "unsure": .confused, "uncertain": .confused,
            "afraid": .scared, "nervous": .scared, "worried": .scared,
            "proud": .smug, "playful": .smug, "mischievous": .smug, "cheeky": .smug,
            "thrilled": .excited, "eager": .excited, "enthusiastic": .excited,
            "calm": .neutral, "normal": .neutral,
            "pensive": .thinking, "pondering": .thinking,
        ]
        guard let mapped = synonyms[key] else { return nil }
        self = mapped
    }
}
