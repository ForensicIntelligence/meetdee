import Foundation

/// Dee's emotional vocabulary. The model is told to open replies with one of these
/// as a `[tag]`; the face renders them. Keep names single, lowercase English words —
/// small models reproduce short common words far more reliably than invented ones.
public enum Emotion: String, CaseIterable, Codable, Sendable {
    case neutral, happy, joy, love, sad, angry, surprised, curious
    case sleepy, asleep, thinking, listening, confused, scared, smug, excited
    // v0.4: a wider range, so Dee rarely looks the same twice.
    case content, playful, mischievous, shy, proud, skeptical, awe, pleading
    case bored, lonely, dizzy, determined
    case worried, grumpy, hurt, giddy, dreamy, relieved, unimpressed, overwhelmed, hopeful

    /// Emotions the model may choose. `asleep`, `thinking` and `listening` are states
    /// the app drives itself, so they are not offered in the prompt.
    public static let modelChoosable: [Emotion] = [
        .neutral, .happy, .joy, .love, .sad, .angry, .surprised, .curious,
        .sleepy, .confused, .scared, .smug, .excited,
        .content, .playful, .mischievous, .shy, .proud, .skeptical, .awe, .pleading,
        .bored, .lonely, .dizzy, .determined,
        .worried, .grumpy, .hurt, .giddy, .dreamy, .relieved, .unimpressed, .overwhelmed, .hopeful,
    ]

    /// Lenient lookup for tags the model writes (`[Happy]`, `[laughing]`, `[shocked]`).
    public init?(tag raw: String) {
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let exact = Emotion(rawValue: key) { self = exact; return }
        let synonyms: [String: Emotion] = [
            "glad": .happy, "cheerful": .happy, "smile": .happy, "smiling": .happy,
            "laugh": .joy, "laughing": .joy, "delighted": .joy, "giggle": .joy,
            "loving": .love, "affectionate": .love, "adoring": .love, "hearts": .love,
            "unhappy": .sad, "sorry": .sad, "disappointed": .sad, "wounded": .hurt, "offended": .hurt,
            "mad": .angry, "annoyed": .grumpy, "irritated": .grumpy,
            "shocked": .surprised, "amazed": .surprised, "wow": .surprised, "astonished": .surprised,
            "intrigued": .curious, "interested": .curious, "wondering": .curious,
            "tired": .sleepy, "drowsy": .sleepy,
            "puzzled": .confused, "unsure": .confused, "uncertain": .confused,
            "afraid": .scared, "nervous": .worried, "anxious": .worried,
            "cheeky": .mischievous,
            "thrilled": .excited, "eager": .excited, "enthusiastic": .excited,
            "calm": .neutral, "normal": .neutral,
            "pensive": .thinking, "pondering": .thinking,
            "relaxed": .content, "peaceful": .content, "cozy": .content, "satisfied": .content,
            "silly": .playful, "goofy": .playful, "teasing": .mischievous, "sneaky": .mischievous,
            "bashful": .shy, "embarrassed": .shy, "blushing": .shy, "timid": .shy,
            "pleased": .proud, "accomplished": .proud,
            "doubtful": .skeptical, "suspicious": .skeptical, "unconvinced": .skeptical,
            "awed": .awe, "wonder": .awe, "starstruck": .awe, "mesmerized": .awe,
            "begging": .pleading, "puppy": .pleading,
            "uninterested": .bored, "meh": .unimpressed, "underwhelmed": .unimpressed, "swamped": .overwhelmed, "flustered": .overwhelmed, "sleepyhead": .dreamy, "daydreaming": .dreamy, "phew": .relieved, "elated": .giddy, "bouncy": .giddy, "optimistic": .hopeful, "lonesome": .lonely, "dazed": .dizzy, "focused": .determined, "resolute": .determined,
        ]
        guard let mapped = synonyms[key] else { return nil }
        self = mapped
    }
}
