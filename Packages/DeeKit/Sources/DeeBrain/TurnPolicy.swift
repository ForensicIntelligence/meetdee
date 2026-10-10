import DeeCore
import DeeSelf
import Foundation

/// The brain's decisions as pure functions (unit-tested without audio or network).
public enum TurnPolicy {
    /// What to do when the server commits a user utterance.
    public enum OnCommit: Sendable, Equatable {
        /// Build the DNA now from state + local prosody and ask (fast mode, §4.3).
        case respondFast
        /// Wait ≤ `exactWait` for the transcript, run the full path, then ask (exact mode).
        case waitForWords
        /// She is asleep or nobody is engaged: wait for the words and let the
        /// "is this for me?" check decide; never answer on the commit (rtvoice notes).
        case waitForAddress
        /// Speech that started over her voice (or overlapped its echo tail): it may
        /// be a backchannel ("keep going", "mm-hm") that must not cut her, or a
        /// command. Waits ≤ `overlapWait` for the first settled words (the
        /// transcription deltas, ~0.25 s after the commit), never for the full
        /// transcript (tune 2).
        case waitForPartial
    }

    /// Exact mode waits this long for the transcript before falling back to fast.
    public static let exactWait: TimeInterval = 0.4
    /// Speech that starts over her voice, or so close after it that it overlapped
    /// her echo tail (a barge-in, "wait, no…", "stop"), waits for its words: the
    /// answer depends on them, and a command must never be answered. The gap is
    /// measured from when the server's `speech_started` reached the brain, which is
    /// already ~0.2–0.3 s after the real onset, so this window only catches
    /// overlap; ordinary turn-taking (a normal 0.2–0.6 s gap) stays fast, and a
    /// command there is still caught by the transcript (it stops the reply). Not in
    /// DNA.md §4.3: an app rule, to be measured on the device harness (B8).
    public static let commandWindow: TimeInterval = 0.35

    /// Inputs for `onCommit`.
    public struct Context: Sendable, Equatable {
        public var answersOnCommit: Bool
        public var signals: CueModeSignals
        public var prosody: ProsodyRead?
        /// Note kinds of the previous response's DNA.
        public var previousNotes: Set<Note.Kind>
        /// Seconds between the end of her voice (or a cut) and this utterance's start
        /// (as the brain saw it); nil when she never spoke, negative when they
        /// talked over her.
        public var sinceHerVoice: TimeInterval?
        public var thinkingRequestedBefore: Bool

        public init(answersOnCommit: Bool = true, signals: CueModeSignals = CueModeSignals(), prosody: ProsodyRead? = nil,
                    previousNotes: Set<Note.Kind> = [], sinceHerVoice: TimeInterval? = nil,
                    thinkingRequestedBefore: Bool = false) {
            self.answersOnCommit = answersOnCommit
            self.signals = signals
            self.prosody = prosody
            self.previousNotes = previousNotes
            self.sinceHerVoice = sinceHerVoice
            self.thinkingRequestedBefore = thinkingRequestedBefore
        }
    }

    public static func onCommit(_ c: Context) -> OnCommit {
        guard c.answersOnCommit else { return .waitForAddress }
        if exactModeWanted(c) { return .waitForWords }
        if let since = c.sinceHerVoice, since < commandWindow { return .waitForPartial }
        return .respondFast
    }

    /// The overlapped turn waits this long for its first settled words, then is
    /// answered fast (what it said reaches the brain later, as for any turn).
    public static let overlapWait: TimeInterval = 0.6
    /// Transcription deltas count as the turn's (provisional) words once none has
    /// come for this long. Live tune 1: the longest gap inside one item's delta
    /// burst was 0.17 s (p99 0.11 s); the burst ends p50 0.25 s after the commit,
    /// 0.22 s before the full transcript, well before her first audio (~0.7 s).
    public static let partialSettle: TimeInterval = 0.15

    /// docs/DNA.md §4.3: the cases where the words change the right answer (only
    /// those: everything else is fast, tune 2). Speech over her voice is not one of
    /// them any more: it waits for its first words (`waitForPartial`), not the
    /// full transcript.
    public static func exactModeWanted(_ c: Context) -> Bool {
        let s = c.signals
        if [.strained, .ruptured, .repairing].contains(s.repair) { return true }
        if let p = c.prosody, p.loudness >= 0.5 || p.intensity >= 0.6 { return true }
        if !c.previousNotes.isDisjoint(with: [.followUp, .followUpGentle]) { return true }
        if s.statedHypothesis || s.distressLive { return true }
        if !c.previousNotes.isDisjoint(with: [.deixisAmbiguous, .misread]) { return true }
        if s.unidentifiedSpeaker && s.turnsThisConversation == 0 { return true }
        return false
    }

    /// The §4.1 `waitBeforeAnswering` delay (an `interruptedThem` lesson): a short
    /// beat before `response.create`; the model is never told to wait.
    public static let waitBeforeAnswering: TimeInterval = 0.7

    /// Whether an initiative may go out now (stage-1 gate 1, plus the brain's own
    /// state: no reply outstanding, no words awaited, no tool still running).
    public static func initiativeAllowed(connected: Bool, userSpeaking: Bool, replyOutstanding: Bool,
                                         awaitingWords: Bool, toolRunning: Bool = false) -> Bool {
        connected && !userSpeaking && !replyOutstanding && !awaitingWords && !toolRunning
    }

    /// A user utterance waiting for the "is this for me?" check (asleep, nobody
    /// engaged) is given up after this if no transcript comes (it never blocks
    /// her initiatives for longer).
    public static let addressWait: TimeInterval = 6

    // MARK: Unfinished turns

    /// A committed turn whose words say the user is not done (tune 1). The server's
    /// turn detection runs at `high` eagerness so plain turns end fast; it may then
    /// commit "Hold on." or "I had pasta, and…" as a turn of its own. The brain
    /// does not answer those: it waits for the rest (the next commit answers both
    /// items, which are both in the conversation).
    public enum Unfinished: String, Sendable, Equatable {
        /// "Hold on", "one sec", "let me think": never answered on its own.
        case holdOn
        /// Trails off ("…, and", "um…", "…"): answered only if nothing follows
        /// within `trailingWait`.
        case trailing
        /// A joke's set-up question ("Why did the scarecrow win an award?"): the
        /// teller usually gives the punchline after a beat. Answered (she guesses
        /// or asks "why?") only if nothing follows within `riddleWait` (tune 2, j01).
        case riddle
    }

    /// A trailing turn is answered after this much quiet (they may not go on).
    public static let trailingWait: TimeInterval = 3.0
    /// A riddle's set-up is answered after this much quiet.
    public static let riddleWait: TimeInterval = 1.5

    /// How long a held turn waits for more.
    public static func holdWait(_ kind: Unfinished) -> TimeInterval {
        kind == .riddle ? riddleWait : trailingWait
    }

    /// Whole-utterance requests to wait (after fillers and her name are removed).
    static let holdPhrases: Set<String> = [
        "hold on", "hang on", "wait", "wait a sec", "wait a second", "wait a minute", "wait a moment",
        "one sec", "one second", "one moment", "just a sec", "just a second", "just a moment", "just a minute",
        "give me a sec", "give me a second", "give me a minute", "give me a moment", "gimme a sec", "gimme a second",
        "let me think", "let me see", "let me think about it", "let me think about that", "hmm let me think",
        "hold that thought", "bear with me", "sec",
        // tune 2 (p20c): gpt-transcribe often returns only "Let me." for "Let me think."
        "let me", "lemme", "lemme think", "lemme see", "let me just", "let me just think", "let's see", "lets see",
        "let me think for a second", "let me think for a sec", "let me think for a moment", "let me check",
        "one minute", "hang on a sec", "hang on a second", "hold on a sec", "hold on a second", "hold on a minute",
    ]
    /// Words a finished sentence does not end on.
    static let trailingWords: Set<String> = [
        "and", "but", "or", "because", "cause", "cuz", "um", "uh", "er", "erm", "uhh", "umm", "hmm",
        "the", "a", "an", "my", "your",
        // tune 2 (server_vad commits at a 0.3 s pause): "…went to the", "…the answer is"
        "than", "very", "gonna", "wanna", "gotta", "whether", "although", "whereas", "unless",
    ]
    /// Prepositions trail ("…a lot of", "We talked about") unless a wh-word earlier
    /// strands them ("That's what I was thinking of.", "What are you looking at.")
    /// or it is "kind of" / "sort of" ("It's kind of.").
    static let prepositions: Set<String> = ["of", "for", "at", "from", "about", "into", "onto", "with", "to"]
    static let whWords: Set<String> = ["what", "what's", "where", "where's", "who", "who's", "whom", "which", "whatever",
                                       "wherever", "whoever", "that's"]
    /// Linking verbs that end a sentence only after a pronoun or wh-word ("That's
    /// what it is.", "Here we are."), never after a noun ("The thing is", "The
    /// answer is", "What I really want to know is").
    static let linking: Set<String> = ["is", "was", "are", "were", "be", "being"]
    static let linkingFinishers: Set<String> = [
        "it", "he", "she", "they", "that", "this", "who", "what", "where", "there", "here", "which", "you", "we", "i",
        "one", "how", "why", "when", "so", "too", "these", "those", "else", "is", "was",
    ]
    /// "to" ends a sentence only as an elliptical "want to", "have to", "used to"…;
    /// "I'm going to", "I went to", "talk to" trail.
    static let toFinishers: Set<String> = [
        "want", "wanted", "wants", "love", "loved", "like", "liked", "have", "has", "had", "need", "needed", "used",
        "ought", "got", "tried", "try", "mean", "meant", "supposed", "able", "allowed", "hope", "plan", "planning", "decided",
        "agree", "forgot", "promise", "promised", "afford", "dare", "pretend", "seem", "seems", "happen", "happened", "how",
        "what", "where", "who", "when", "not", "ready", "glad", "happy", "sorry", "free", "welcome", "nice", "listen",
    ]
    /// Words that may stand around a hold phrase ("oh, hold on, Dee").
    static let holdFiller: Set<String> = ["oh", "okay", "ok", "um", "uh", "er", "hmm", "please", "dee", "d", "yeah", "no", "sorry"]

    /// Whether `text` (a committed turn's transcript) is unfinished, and how.
    public static func unfinished(_ text: String) -> Unfinished? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let words = Self.words(trimmed)
        guard !words.isEmpty else { return nil }
        // "Hold on, hold on." — the whole utterance asks her to wait.
        let core = words.filter { !holdFiller.contains($0) }
        if !core.isEmpty, core.count <= 8, Self.coveredByHoldPhrases(core) { return .holdOn }
        // A trailing ellipsis or dash: they trailed off.
        if trimmed.hasSuffix("…") || trimmed.hasSuffix("...") || trimmed.hasSuffix("-") || trimmed.hasSuffix("—") {
            return .trailing
        }
        // "…and", "…um": a sentence does not end there. A question mark or an
        // exclamation says it did ("Do you like it?" never trails).
        if trimmed.hasSuffix("?") || trimmed.hasSuffix("!") { return nil }
        guard let last = words.last else { return nil }
        let before = words.count >= 2 ? words[words.count - 2] : ""
        if last == "then", ["and", "but", "so"].contains(before) { return .trailing }   // "…and then"
        if trailingWords.contains(last) { return .trailing }
        if words.count >= 2, linking.contains(last), !linkingFinishers.contains(before) { return .trailing }
        if words.count >= 2, prepositions.contains(last) {
            let stranded = words.dropLast().contains { whWords.contains($0) }
            let fixed = last == "of" && ["kind", "sort"].contains(before)
            let elliptical = last == "to" && toFinishers.contains(before)
            if !stranded && !fixed && !elliptical { return .trailing }
        }
        // gpt-transcribe hears a trailing "and" as "Ann", "an" or "end" and closes it
        // with a period (tune 1 F-COLL: "I was going to call my mom Ann.").
        if words.count >= 3, misheardAnd(last: last, before: before) { return .trailing }
        return nil
    }

    /// A last word that is a mis-heard trailing "and": "an" never ends a sentence;
    /// "Ann" after a clause almost never does in what people say to her (a name is
    /// introduced with "is"/"called"/"named"); "end" only after an article ("the end").
    static func misheardAnd(last: String, before: String) -> Bool {
        switch last {
        case "an": return true
        case "ann": return !["is", "called", "named", "it's", "i'm", "and", "aunt", "auntie", "with", "to", "for"].contains(before)
        case "end": return !["the", "an", "a", "this", "that", "no", "dead", "deep", "my", "your", "our", "their", "weekend",
                             "back", "low", "high", "front", "tail", "west", "east", "rear", "far", "other"].contains(before)
        default: return false
        }
    }

    /// Whether the last sentence of `text` is a joke's set-up question that the
    /// teller answers themselves ("Why did the chicken cross the road?"). "Why did
    /// you…" is a question for her, never a riddle; "knock knock" wants "who's there"
    /// at once.
    public static func isRiddleSetUp(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("?") else { return false }
        let sentences = trimmed.split { ".!?".contains($0) }.map { words(String($0)) }.filter { !$0.isEmpty }
        guard let lastSentence = sentences.last else { return false }
        let w = Array(lastSentence.drop { holdFiller.contains($0) || $0 == "so" })
        func starts(_ p: [String]) -> Bool { w.count > p.count && Array(w.prefix(p.count)) == p }
        // Classic set-ups are riddles on their own; any other why/what/how question
        // only when the same utterance announced a joke ("Want to hear a joke? Why
        // did…"): "Why did the dinosaurs die out?" is a real question.
        let classic: [[String]] = [
            ["what", "do", "you", "call", "a"], ["what", "do", "you", "call", "an"], ["what's", "the", "difference", "between"],
            ["what", "is", "the", "difference", "between"], ["what", "did", "the"], ["what", "did", "one"],
        ]
        if classic.contains(where: starts) { return true }
        let all = words(trimmed)
        let announced = all.contains { ["joke", "jokes", "riddle", "riddles"].contains($0) }
        guard announced, sentences.count >= 2, let opener = w.first,
              ["why", "what", "what's", "how", "where", "who", "when"].contains(opener) else { return false }
        // "Why do you like jokes?": a question about her or them.
        let personal: Set<String> = ["you", "your", "you're", "i", "i'm", "me", "my", "we", "us", "our"]
        return !w.dropFirst().prefix(3).contains { personal.contains($0) }
    }

    /// `unfinished(text)`, plus a riddle's set-up (only once the words are settled).
    public static func held(_ text: String) -> Unfinished? {
        if let u = unfinished(text) { return u }
        return isRiddleSetUp(text) ? .riddle : nil
    }

    // MARK: Backchannels (tune 2: user decision — "keep going" while she talks is not a barge-in)

    /// Whole-utterance continuers: said while she talks (or right as she was cut),
    /// they mean "go on", never "stop" or a new turn.
    static let continuers: Set<String> = [
        "keep going", "go on", "go ahead", "carry on", "continue", "don't stop", "do not stop", "please continue",
        "i'm listening", "im listening", "i am listening", "listening", "i'm still listening", "still listening",
        "mm hm", "mm hmm", "mhm", "mmhm", "mmhmm", "mm", "mmm", "uh huh", "uh-huh", "uhhuh", "yeah", "yeah yeah", "yep", "yes",
        "right", "okay", "ok", "sure", "i see", "got it", "cool", "nice", "wow", "oh", "ah", "aha", "really", "interesting",
        "and then", "then what", "what else", "tell me more", "more", "yes go on", "sure go on",
        "keep talking", "you can keep going", "you can go on", "please go on", "i'm here", "go for it",
    ]

    static let backchannelFiller: Set<String> = ["dee", "d", "please", "just", "so", "well", "no", "now"]

    /// Whether `text` is only a backchannel ("Keep going, I'm listening.", "Mm-hm.",
    /// "Don't stop, keep going."): every clause a continuer, at most 8 words, no
    /// question. "Stop", "wait", "no" or anything else make it a real turn.
    public static func isBackchannel(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasSuffix("?") || ["really?", "yeah?", "and?", "and then?", "then what?"]
            .contains(trimmed.lowercased()) else { return false }
        let all = words(trimmed.replacingOccurrences(of: "-", with: " "))
        guard !all.isEmpty, all.count <= 8 else { return false }
        let clauses = trimmed.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "-", with: " ")
            .split { ",.!?;…".contains($0) }
            .map { words(String($0)).filter { !backchannelFiller.contains($0) } }
            .filter { !$0.isEmpty }
        guard !clauses.isEmpty else { return false }
        return clauses.allSatisfy { continuers.contains($0.joined(separator: " ")) }
    }

    /// The note on a turn answered again after a spoken preamble was cut.
    public static let answerStraightNote = "Answer them straight away; if you use a tool, call it without saying anything first"

    /// The retry's own look-up (no tool call left to narrate), and its length cap.
    public static let lookedUpNote = "You already looked up what you know about them, no need to call recall: "
    public static let lookedUpMax = 320

    /// The note that turns a "keep going" after her voice was cut into "carry on".
    public static let carryOnNote = "They want you to go on: carry on from where you stopped, without starting over or repeating yourself"

    // MARK: Spoken preambles (tune 2 F-LEAK: "Got it, let me think about how to respond to that.")

    /// Meta narration at the start of her reply: talking about answering instead of
    /// answering (often spoken before a tool call). Checked on the first words only.
    static let preamblePatterns: [[String]] = [
        ["let", "me", "think"], ["let", "me", "respond"], ["let", "me", "answer"], ["let", "me", "check"],
        ["let", "me", "recall"], ["let", "me", "remember"], ["let", "me", "look"], ["let", "me", "save"],
        ["let", "me", "note"], ["let", "me", "jot"], ["let", "me", "make", "a", "note"], ["let", "me", "see", "what"],
        ["let", "me", "process"], ["let", "me", "figure"], ["let", "me", "store"], ["let", "me", "write"],
        ["i'll", "check"], ["i'll", "think"], ["i'll", "respond"], ["i'll", "answer"], ["i'll", "look"],
        ["i'll", "save"], ["i'll", "note"], ["i'll", "make", "a", "note"], ["i'll", "remember", "that"],
        ["i'll", "store"], ["i'll", "write"], ["i'll", "jot"],
        ["i", "need", "to", "think"], ["thinking", "about", "how"], ["how", "to", "respond"], ["how", "i", "should", "respond"],
        ["let", "me", "tuck"], ["i'll", "tuck"], ["quick", "save"], ["memory", "check"], ["one", "moment"], ["let", "me", "grab"],
        ["i'll", "grab"], ["let", "me", "pull", "up"], ["i'll", "pull", "up"],
    ]

    /// Whether the first words of a reply (`prefix`, its transcript so far) are a
    /// meta preamble. Looks only at the first `preambleWords` words, so a real
    /// answer that says "let me" later is never touched.
    public static func isMetaPreamble(_ prefix: String) -> Bool {
        let w = Array(words(prefix).prefix(preambleWords))
        guard w.count >= 2 else { return false }
        for p in preamblePatterns where w.count >= p.count {
            for i in 0...(w.count - p.count) where Array(w[i..<(i + p.count)]) == p { return true }
        }
        return false
    }

    /// How far into a reply a preamble is looked for (later, it is already audible
    /// as an answer and cutting it would cut words).
    public static let preambleWords = 7

    // MARK: Reply length (tune 2: ≥ 95 % of replies ≤ 3 sentences)

    /// The per-response `max_output_tokens` for a reply under the DNA `Length:`
    /// line. Counts reasoning, transcript and audio tokens (live tune 1 replies:
    /// two sentences p90 312 / p98 360, three p50 270 / p90 359, four p50 323), so
    /// it is a backstop over the DNA wording, sized one sentence above the limit:
    /// a reply that runs past it ends at its last complete sentence (the brain stops
    /// her voice there; never mid-word). Thinking turns get room (nil: the session's
    /// runaway guard).
    public static func maxOutputTokens(length: String, effort: ReasoningEffort) -> Int? {
        let l = length.lowercased()
        let base = l.contains("one short sentence") ? 280 : l.contains("three") ? 480 : 380
        switch effort {
        case .minimal, .low: return base
        case .medium: return base + 300
        case .high, .xhigh: return nil
        }
    }

    /// They asked for a story or an explanation (the session instructions allow a
    /// longer answer then): no per-response cap (exact mode only; fast mode has no words).
    public static func wantsLongAnswer(_ text: String) -> Bool {
        let t = " " + words(text).joined(separator: " ") + " "
        return [" story ", " stories ", " explain ", " in detail ", " tell me more ", " tell me everything ", " walk me through ",
                " step by step ", " the whole thing "].contains { t.contains($0) }
    }

    /// Whether a sentence of her transcript is complete (the last one of a reply
    /// cut by the token limit is not).
    public static func isCompleteSentence(_ text: String) -> Bool {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let c = t.last, "\"'”’)]".contains(c) { t.removeLast() }
        guard let last = t.last else { return false }
        return ".!?…".contains(last)
    }

    /// Whether `words` are nothing but hold phrases, possibly repeated ("hold on hold on").
    static func coveredByHoldPhrases(_ words: [String]) -> Bool {
        let phrases = holdPhrases.map { $0.split(separator: " ").map(String.init) }.sorted { $0.count > $1.count }
        var i = 0
        outer: while i < words.count {
            for p in phrases where i + p.count <= words.count && Array(words[i..<(i + p.count)]) == p {
                i += p.count
                continue outer
            }
            return false
        }
        return true
    }

    /// Lower-case words, curly apostrophes folded, punctuation dropped.
    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }
}
