import Foundation

/// The few spoken commands Dee handles herself, without the language model.
///
/// A command is the *whole* utterance (audit C8). Only a name, a greeting word or
/// "please" may come before or after it: "stop", "Dee, stop", "please stop now" are
/// commands; "don't stop", "it's so quiet", "stop it, that tickles", "let's not start
/// over" are conversation and go to the model like anything else. Matching a phrase
/// as a prefix or suffix used to silence her mid-conversation, or wipe the history
/// on "…and then we had a new conversation".
public enum SpokenCommand: Sendable, Equatable {
    /// Hush: stop talking now.
    case stop
    /// Forget this conversation and start a fresh one.
    case newConversation
    /// Go to sleep (closes the conversation window, and her body sleeps).
    case sleep
    /// "Stop listening" / "that's all": close the conversation window now (v0.6; the
    /// body stays awake — only the microphone stops leaving the phone).
    case stopListening
    /// "Change your wake phrase to X" (v0.6). The text is the proposed phrase, in
    /// title case, not yet validated (`WakePhrase(validating:)` does that); she repeats
    /// it and asks to confirm before anything is saved.
    case changeWakePhrase(to: String)

    /// Commands that close the conversation window at once (after her local goodbye).
    public var closesWindow: Bool {
        switch self {
        case .sleep, .stopListening: true
        default: false
        }
    }

    /// The command `utterance` is, or nil.
    /// - Parameter deeIsTalking: Dee is speaking, preparing a reply, or has only just
    ///   stopped. "Stop" and "quiet" only mean "be quiet" then; said to a silent Dee
    ///   they are conversation ("Stop!" after a tickle, "Quiet." describing a room),
    ///   and she answers them instead of ignoring the user.
    /// - Parameter stripLeading: removes the current wake phrase from the front
    ///   (`WakeMatcher.stripLeading`), so "Computer, go to sleep" is `.sleep` with a
    ///   custom phrase. nil: only the built-in name forms ("hey Dee") are stripped.
    public static func match(_ utterance: String, deeIsTalking: Bool,
                             stripLeading: ((String) -> String)? = nil) -> SpokenCommand? {
        let text = stripLeading.map { $0(utterance) } ?? utterance
        if let phrase = wakePhraseChange(text) { return .changeWakePhrase(to: phrase) }
        let c = core(of: text)
        guard !c.isEmpty else { return nil }
        if newConversationPhrases.contains(c) { return .newConversation }
        if sleepPhrases.contains(c) { return .sleep }
        if stopListeningPhrases.contains(c) { return .stopListening }
        if deeIsTalking, stopPhrases.contains(c) { return .stop }
        return nil
    }

    /// A yes / no answer to her confirmation question ("My wake phrase will be …. Is
    /// that right?"), or nil when the utterance is neither.
    public static func confirmation(_ utterance: String) -> Bool? {
        let c = core(of: utterance)
        guard !c.isEmpty else { return nil }
        if yesPhrases.contains(c) { return true }
        if noPhrases.contains(c) { return false }
        // "Yeah, that's right", "no, keep the old one": the first word decides, unless the
        // rest turns it around ("yes, no wait").
        let words = c.split(separator: " ").map(String.init)
        guard let first = words.first, words.count > 1 else { return nil }
        let negators: Set<String> = ["no", "not", "don't", "wait", "nope"]
        if ["yes", "yeah", "yep", "yup", "correct", "sure"].contains(first), !words.dropFirst().contains(where: negators.contains) { return true }
        if ["no", "nope", "nah"].contains(first) { return false }
        return nil
    }

    /// The proposed phrase of "change your wake phrase to X" (and its variants), or nil.
    /// Only openers and "please"/"thanks" are stripped — never a trailing "Dee", which
    /// may be part of the new phrase ("…to Hi Dee").
    static func wakePhraseChange(_ utterance: String) -> String? {
        var words = normalize(utterance).split(separator: " ").map(String.init)
        var changed = true
        while changed, !words.isEmpty {
            changed = false
            for lead in leading + changeOpeners where words.starts(with: lead) {
                words.removeFirst(lead.count)
                changed = true
                break
            }
        }
        while let last = words.last, ["please", "thanks"].contains(last) { words.removeLast() }
        if words.suffix(2) == ["thank", "you"] { words.removeLast(2) }
        // Join "wake up" / "wakeup" / "wake" into one token so the patterns stay small.
        var joined: [String] = []
        var i = 0
        while i < words.count {
            if words[i] == "wake", i + 1 < words.count, words[i + 1] == "up" { joined.append("wake"); i += 2; continue }
            joined.append(words[i] == "wakeup" ? "wake" : words[i])
            i += 1
        }
        let w = joined
        func rest(after prefix: [String]) -> [String]? { w.starts(with: prefix) ? Array(w.dropFirst(prefix.count)) : nil }
        var tail: [String]?
        for verb in ["change", "set", "switch", "make", "turn"] {
            for noun in ["phrase", "word"] {
                for link in [["to"], ["into"], ["be"], []] {
                    if tail == nil, let r = rest(after: [verb, "your", "wake", noun] + link) { tail = r }
                }
            }
        }
        for noun in ["phrase", "word"] where tail == nil {
            for opener in [["your", "wake", noun, "is"], ["your", "new", "wake", noun, "is"], ["your", "wake", noun, "should", "be"],
                           ["the", "wake", noun, "is"], ["new", "wake", noun]] where tail == nil {
                tail = rest(after: opener)
            }
            if tail == nil, w.first == "use", w.suffix(4) == ["as", "your", "wake", noun] { tail = Array(w.dropFirst().dropLast(4)) }
        }
        guard var t = tail else { return nil }
        if t.first == "now" { t.removeFirst() }
        guard !t.isEmpty else { return nil }
        return t.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static let changeOpeners: [[String]] = [
        ["i", "want", "to"], ["i'd", "like", "to"], ["i", "would", "like", "to"], ["let's"], ["let", "me"], ["i", "want", "you", "to"],
        ["please"],
    ].sorted { $0.count > $1.count }

    /// Whether the utterance is spoken *to* Dee by name ("Dee, are you awake?",
    /// "hey Dee"), or asks her to wake up. Used while nobody is in view or she
    /// sleeps, when speech in the room (a TV, people talking to each other) must not
    /// be answered, but her name should still get her attention.
    ///
    /// "Dee" counts anywhere (recognition writes it only for her name). The letter
    /// "D" and the wake phrases count only where they address her: opening the
    /// utterance ("D, come here", "Wake up!", "Hey, are you awake?"), or "D" after a
    /// greeting or set off by a comma at the end ("Thanks, D"). "Vitamin D is good",
    /// "I got a D on my test", "Did he wake up?" are a TV or a conversation, not her
    /// name, and must not open a minute of answering everything the room says.
    public static func addressesDee(_ utterance: String) -> Bool {
        let words = tokens(utterance)
        guard !words.isEmpty else { return false }
        if words.contains(where: { $0.word == "dee" || $0.word == "dee's" }) { return true }
        // Past the greeting words that may open an address ("hey", "okay", "oh").
        var start = 0
        while start < words.count, greetings.contains(words[start].word) { start += 1 }
        for (i, t) in words.enumerated() where t.word == "d" {
            if i == start, i + 1 == words.count || t.pausedAfter { return true }   // "D, come here", "Hey D"
            if i > 0, i == start, greetings.contains(words[i - 1].word) { return true }
            if i == words.count - 1, i > 0, words[i - 1].pausedAfter { return true }   // "Thanks, D"
        }
        let rest = words[start...].map(\.word).joined(separator: " ") + " "
        return wakePhrases.contains { rest.hasPrefix($0 + " ") }
    }

    /// The utterance's words, normalised, each with whether punctuation followed it.
    static func tokens(_ utterance: String) -> [(word: String, pausedAfter: Bool)] {
        let folded = utterance.lowercased().replacingOccurrences(of: "’", with: "'")
        var result: [(word: String, pausedAfter: Bool)] = []
        var current = ""
        for ch in folded {
            if ch.isLetter || ch.isNumber || ch == "'" {
                current.append(ch)
                continue
            }
            if !current.isEmpty { result.append((current, false)); current = "" }
            if !ch.isWhitespace, let last = result.indices.last { result[last].pausedAfter = true }
        }
        if !current.isEmpty { result.append((current, false)) }
        return result
    }

    /// Words that may open an address before her name or a wake phrase.
    static let greetings: Set<String> = ["hey", "hi", "hello", "okay", "ok", "oh", "um", "uh", "yo", "please"]

    // MARK: - Normalising

    /// Lower-case words only, curly apostrophes folded, punctuation dropped.
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "[^a-z0-9' ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The utterance without the address, politeness and fillers around it
    /// ("okay Dee, stop please" → "stop"), and a repeated word said once
    /// ("stop stop stop" → "stop").
    static func core(of utterance: String) -> String {
        var words = normalize(utterance).split(separator: " ").map(String.init)
        var changed = true
        while changed, !words.isEmpty {
            changed = false
            for lead in leading where words.starts(with: lead) {
                words.removeFirst(lead.count)
                changed = true
                break
            }
            for trail in trailing where words.count >= trail.count && Array(words.suffix(trail.count)) == trail {
                words.removeLast(trail.count)
                changed = true
                break
            }
        }
        if let first = words.first, words.count > 1, words.allSatisfy({ $0 == first }) { words = [first] }
        return words.joined(separator: " ")
    }

    /// Longest first, so "hey dee" goes before "hey".
    static let leading: [[String]] = [
        ["hey", "dee"], ["okay", "dee"], ["ok", "dee"], ["oh", "dee"], ["dee"], ["hey"], ["okay"], ["ok"],
        ["alright"], ["all", "right"], ["please"], ["just"], ["um"], ["uh"], ["oh"], ["so"], ["now"],
        // Tune 2: "Wait, stop talking for a second" / "hold on, be quiet" / "can you stop"
        // are the stop command when she is talking (live they went to the model and were
        // appraised as a brush-off). Alone, "wait" / "hold on" stay conversation.
        ["wait"], ["hold", "on"], ["hang", "on"], ["sorry"], ["can", "you"], ["could", "you"], ["would", "you"],
    ].sorted { $0.count > $1.count }
    static let trailing: [[String]] = [
        ["thank", "you"], ["right", "now"], ["dee"], ["please"], ["now"], ["thanks"], ["okay"], ["ok"],
        ["for", "a", "second"], ["for", "a", "sec"], ["for", "a", "moment"], ["for", "a", "minute"], ["for", "a", "bit"],
        ["a", "second"], ["a", "sec"], ["a", "moment"], ["for", "now"],
    ].sorted { $0.count > $1.count }

    static let stopPhrases: Set<String> = [
        "stop", "stop talking", "stop it", "stop that", "be quiet", "quiet", "quiet down", "shush",
        "sh", "shh", "shhh", "hush", "that's enough", "enough",
    ]
    static let newConversationPhrases: Set<String> = [
        "start over", "let's start over", "new conversation", "start a new conversation",
        "let's start a new conversation", "fresh start", "let's start fresh", "start fresh",
    ]
    static let sleepPhrases: Set<String> = [
        "go to sleep", "goodnight", "good night", "time to sleep", "nap time", "time for bed",
        "go to bed", "time for a nap", "sleep time",
    ]

    /// Close the conversation window (v0.6). Whole utterance only: "that's all I have"
    /// is conversation.
    static let stopListeningPhrases: Set<String> = [
        "stop listening", "stop listening to me", "you can stop listening", "that's all", "that is all",
        "that'll be all", "that will be all", "we're done", "we are done", "that's all i need", "that's all i needed",
    ]
    static let yesPhrases: Set<String> = [
        "yes", "yeah", "yep", "yup", "yes it is", "yes please", "sure", "right", "correct", "that's right", "that's correct",
        "exactly", "yes that's right", "yeah that's right", "do it", "go ahead", "please do", "uh huh", "mhm", "absolutely",
        "perfect", "sounds good", "yes exactly",
    ]
    static let noPhrases: Set<String> = [
        "no", "nope", "nah", "no it isn't", "no it's not", "that's wrong", "wrong", "not right", "that's not right", "cancel",
        "never mind", "nevermind", "forget it", "keep it", "keep the old one", "don't", "no don't", "no thanks", "no thank you",
    ]

    /// Must open the utterance (after greetings) to count as waking her.
    static let wakePhrases = ["wake up", "are you awake", "you awake"]
}
