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
        return exactModeWanted(c) ? .waitForWords : .respondFast
    }

    /// docs/DNA.md §4.3: the cases where the words change the right answer. Plus one
    /// app rule: an utterance right after (or over) her voice may be a command.
    public static func exactModeWanted(_ c: Context) -> Bool {
        let s = c.signals
        if [.strained, .ruptured, .repairing].contains(s.repair) { return true }
        if let p = c.prosody, p.loudness >= 0.5 || p.intensity >= 0.6 { return true }
        if !c.previousNotes.isDisjoint(with: [.followUp, .followUpGentle]) { return true }
        if s.statedHypothesis || s.distressLive { return true }
        if !c.previousNotes.isDisjoint(with: [.deixisAmbiguous, .misread]) { return true }
        if s.unidentifiedSpeaker && s.turnsThisConversation == 0 { return true }
        if let since = c.sinceHerVoice, since < commandWindow { return true }
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
    }

    /// A trailing turn is answered after this much quiet (they may not go on).
    public static let trailingWait: TimeInterval = 3.0

    /// Whole-utterance requests to wait (after fillers and her name are removed).
    static let holdPhrases: Set<String> = [
        "hold on", "hang on", "wait", "wait a sec", "wait a second", "wait a minute", "wait a moment",
        "one sec", "one second", "one moment", "just a sec", "just a second", "just a moment", "just a minute",
        "give me a sec", "give me a second", "give me a minute", "give me a moment", "gimme a sec", "gimme a second",
        "let me think", "let me see", "let me think about it", "let me think about that", "hmm let me think",
        "hold that thought", "bear with me", "sec",
    ]
    /// Words a finished sentence does not end on.
    static let trailingWords: Set<String> = [
        "and", "but", "or", "because", "cause", "cuz", "um", "uh", "er", "erm", "uhh", "umm", "hmm",
        "the", "a", "an", "with", "my", "your",
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
        return nil
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
