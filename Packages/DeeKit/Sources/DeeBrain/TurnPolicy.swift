import DeeCore
import DeeSelf
import DeeVoice
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
    ///
    /// Tune 3: a loud voice and a stranger's first turn are fast too. Live tune 2,
    /// 7 of 9 exact waits timed out (the transcript came > 0.4 s after the commit),
    /// so they cost 0.4 s and gained nothing; with server_vad 300 ms the commit comes
    /// earlier still. Loudness is in the fast DNA anyway (prosody), and the model
    /// hears a stranger's words itself. What remains needs the words: repair, a
    /// follow-up's answer, distress, a stated mood, an ambiguous "that" or a misread.
    public static func exactModeWanted(_ c: Context) -> Bool {
        let s = c.signals
        if [.strained, .ruptured, .repairing].contains(s.repair) { return true }
        if !c.previousNotes.isDisjoint(with: [.followUp, .followUpGentle]) { return true }
        if s.statedHypothesis || s.distressLive { return true }
        if !c.previousNotes.isDisjoint(with: [.deixisAmbiguous, .misread]) { return true }
        return false
    }

    // MARK: Speculative replies (tune 4)

    /// Total quiet since the user's last voiced frame before her speculative reply
    /// may be heard. server_vad commits after 0.3 s of silence (live tune 3: speech
    /// end → commit 0.19 s as the brain saw it; commit → first audio p50 ~0.5 s), so
    /// a window ≤ ~0.7 s costs nothing on most turns. Live tune 3, the resumes that
    /// collided came 0.59 s (l05) and ~0.7 s (j01) after the first part ended.
    ///
    /// Tune 4 A/B (500 / 650 / 800 ms live, then the same windows replayed on every
    /// turn of the tune-3 run and the three A/B runs, 309 turns): her first audio
    /// arrives ≥ ~1.0 s after the end of speech on nearly every turn, so any window up
    /// to 1.0 s left end → first audio p50 / p90 unchanged (1.17 / 1.53 s tune 3); the
    /// collisions fell 10 → 4 at 500 ms, 3 at 650, 2 at 800 (2 at 1.0 s too; 1.2 s
    /// raised the p50 to 1.24 s). The two left resumed 1.04 s after the end: j01's
    /// punchline, now a riddle hold (`held(_:after:)`). 800 ms: the largest free window.
    public static let confirmWindow: TimeInterval = 0.8
    /// Local sound alone never holds a speculative reply longer than this after the
    /// commit (the server, not the room, decides it was speech: a TV, a kitchen).
    ///
    /// Tune 5 F2 (live tune 4 p90 1.63 s): kitchen and TV beds kept the latched
    /// `userIsSpeaking` on after they were done, so ready audio waited to the 1.6 s cap
    /// (5 turns at 2.1–2.2 s). The gate now reads EarCore's bed-proof `voiceActive`, and
    /// anything else (unsettled words) holds her at most 1.0 s after the commit.
    public static let confirmMax: TimeInterval = 1.0
    /// Their own voice (EarCore `voiceActive`) may hold her this much past `confirmMax`
    /// (1.6 s after the commit in all, the tune-4 cap).
    public static let voiceHoldExtra: TimeInterval = 0.6
    /// Tune 5 F3 (fan15 l05: released 0.15 s after they resumed, 665 ms over them):
    /// the gate passes twice, this far apart, before her held audio plays. Free on most
    /// turns: the gate passes from 0.8 s while her audio arrives ≥ ~1.0 s after the end.
    public static let releaseRecheck: TimeInterval = 0.12
    /// A turn whose held reply was dropped because they went on waits this long for
    /// their next commit (which answers both parts), then is answered anyway.
    public static let resumeWait: TimeInterval = 2.0
    /// Without a local voiced frame to go by (no microphone audio), their speech is
    /// taken to have ended this long before the commit reached the brain.
    public static let commitLag: TimeInterval = 0.25
    /// She stops before sentence 4 of an ordinary reply (tune 4: live tune 3 at
    /// `minimal`, 16 of 152 replies ran to 4–5 sentences, 11 of them under a
    /// "two sentences" Length line).
    public static let sentenceCap = 3

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
        // Tune 6 (T5-4, echo20 l03): the server split "D." off "Dee, guess what, at school
        // today…". A fragment of one or two letters, or nothing but her name, is not a
        // turn: they are still starting. "Dee?" (a question) and "No." / "OK." are turns.
        if !trimmed.hasSuffix("?"), !trimmed.hasSuffix("!"), isFragmentOrAddress(words) { return .trailing }
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
            let relative = trimmed.hasSuffix(".") && strandedInRelative(words)
            if !stranded && !fixed && !elliptical && !relative { return .trailing }
        }
        // gpt-transcribe hears a trailing "and" as "Ann", "an" or "end" and closes it
        // with a period (tune 1 F-COLL: "I was going to call my mom Ann.").
        if words.count >= 3, misheardAnd(last: last, before: before) { return .trailing }
        return nil
    }

    /// One- and two-letter words that are a whole turn on their own ("No.", "OK.").
    static let shortTurns: Set<String> = [
        "no", "ok", "k", "hi", "yo", "ya", "ye", "oh", "ah", "aw", "eh", "mm", "hm", "me", "us", "go", "ha", "wo", "ow",
    ]
    /// Her name as the transcriber writes it, and what stands around it in a bare call.
    static let addressWords: Set<String> = ["dee", "d", "dee's", "di", "dea"]
    static let addressFiller: Set<String> = ["hey", "hi", "oh", "um", "uh", "so", "okay", "ok", "and", "well"]

    /// A bare call of her name or a fragment waits this long for the rest, then is answered.
    public static let fragmentWait: TimeInterval = 1.5

    /// `isFragmentOrAddress` on a transcript (a question or an exclamation never is).
    public static func isFragmentOrAddress(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.hasSuffix("?"), !t.hasSuffix("!") else { return false }
        let w = words(t)
        return !w.isEmpty && isFragmentOrAddress(w)
    }

    /// A one- or two-letter fragment ("D.", "I.", "A.") or a bare call of her name
    /// ("Dee.", "Hey, Dee.", "So, Dee,"): the start of a turn, never all of it.
    static func isFragmentOrAddress(_ words: [String]) -> Bool {
        if words.count == 1, let w = words.first, w.count <= 2, !shortTurns.contains(w), !w.contains(where: \.isNumber) {
            return true
        }
        guard words.contains(where: addressWords.contains) else { return false }
        return words.allSatisfy { addressWords.contains($0) || addressFiller.contains($0) }
    }

    /// Subjects of a reduced relative clause ("the job *I* interviewed for").
    static let relativeSubjects: Set<String> = [
        "i", "you", "we", "they", "he", "she", "i'm", "you're", "we're", "they're", "he's", "she's",
        "i've", "you've", "we've", "they've", "i'd", "you'd", "we'd", "they'd",
    ]
    static let determiners: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "my", "your", "his", "her", "our", "their", "one", "some",
        "every", "any", "each", "no",
    ]

    /// Tune 5 F4 (length-clean s02, held 4.67 s): "I didn't get the job I interviewed
    /// for." A preposition stranded by a reduced relative clause ends the sentence: a
    /// determiner's noun phrase, then a subject pronoun and one to three words before
    /// the preposition ("the guy I talked to", "the person you were talking about",
    /// "the place I used to work at"). Only with the transcript's closing period (the
    /// caller checks): "We talked about", "Yesterday I went to." still trail.
    static func strandedInRelative(_ words: [String]) -> Bool {
        let n = words.count
        guard n >= 5 else { return false }
        for gap in 1...3 {
            let s = n - 2 - gap                                  // the subject's index
            guard s >= 2, relativeSubjects.contains(words[s]) else { continue }
            // Its head noun phrase: a determiner one to three words before the subject,
            // with no pronoun or verb-ish link word between ("the job", "that big red car").
            for d in max(0, s - 3)..<(s - 1) where determiners.contains(words[d]) {
                let head = words[(d + 1)..<s]
                if !head.contains(where: { relativeSubjects.contains($0) || linking.contains($0) || trailingWords.contains($0) }) {
                    return true
                }
            }
        }
        return false
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
    ///
    /// Tune 4: `after` is their previous turn (if recent). server_vad 300 ms commits "Want
    /// to hear a joke?" on its own (live tune 3 / tune 4 j01), so the announcement can
    /// come one turn before the set-up.
    public static func isRiddleSetUp(_ text: String, after previous: String? = nil) -> Bool {
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
        let jokeWords: Set<String> = ["joke", "jokes", "riddle", "riddles"]
        let announcedBefore = previous.map { words($0).contains { jokeWords.contains($0) } } ?? false
        let announced = all.contains { jokeWords.contains($0) } && sentences.count >= 2
        guard announced || announcedBefore, let opener = w.first,
              ["why", "what", "what's", "how", "where", "who", "when"].contains(opener) else { return false }
        // "Why do you like jokes?": a question about her or them.
        let personal: Set<String> = ["you", "your", "you're", "i", "i'm", "me", "my", "we", "us", "our"]
        return !w.dropFirst().prefix(3).contains { personal.contains($0) }
    }

    /// The note on a reply to a likely punchline (tune 5 F7).
    public static let punchlineNote =
        "If they just gave the punchline of their joke, laugh first, a real little laugh as your first word, then one short line; never explain it"

    /// Whether the turn after `previous` (and `beforeThat`) is a joke's punchline: the
    /// previous turn was a riddle's set-up ("Why did the scarecrow win an award?"), or a
    /// knock-knock is at its third turn ("Knock knock." → "Lettuce." → "Lettuce in…").
    public static func isPunchlineTurn(previous: String, beforeThat: String?) -> Bool {
        if isRiddleSetUp(previous, after: beforeThat) { return true }
        func knock(_ t: String) -> Bool {
            let w = words(t)
            return zip(w, w.dropFirst()).contains { $0 == "knock" && $1 == "knock" }
        }
        guard let b = beforeThat, knock(b), !knock(previous) else { return false }
        return true
    }

    /// `unfinished(text)`, plus a riddle's set-up (only once the words are settled).
    public static func held(_ text: String, after previous: String? = nil) -> Unfinished? {
        if let u = unfinished(text) { return u }
        return isRiddleSetUp(text, after: previous) ? .riddle : nil
    }

    /// Their previous turn counts for `held(_:after:)` this long (tune 4).
    public static let previousTurnWindow: TimeInterval = 20

    // MARK: Backchannels (tune 2: user decision — "keep going" while she talks is not a barge-in)

    /// Whether `text` is only a backchannel ("Keep going, I'm listening.", "Mm-hm.",
    /// "MMHN.", "HM.", "Don't stop, keep going."): DeeVoice's `Backchannel.isBackchannel`,
    /// so the brain and the voice's floor hold use one rule (tune 3: the brain's own
    /// copy had no hum rule, and answered "MMHN." / "HM." after the voice resumed).
    public static func isBackchannel(_ text: String) -> Bool {
        Backchannel.isBackchannel(text)
    }

    // MARK: Misheard fragments over her voice (tune 7, T6-3)

    /// Clear stop words: said over her voice they are never a backchannel, however short.
    static let stopFragments: Set<String> = [
        "stop", "wait", "pause", "quiet", "shush", "shh", "sh", "hush", "enough", "no", "nope", "cancel", "bye", "goodbye",
        "goodnight", "nevermind", "sorry", "help", "hey", "excuse", "hold", "hang", "shut", "listen", "look", "dee", "d",
    ]
    /// Two-word stops ("hold on", "be quiet").
    static let stopPhrases: Set<String> = [
        "hold on", "hang on", "be quiet", "shut up", "never mind", "good night", "not now", "too much", "too long", "that's enough",
    ]
    /// A question without its question mark ("Who made", "Why not").
    static let questionStarters: Set<String> = [
        "what", "what's", "whats", "why", "how", "how's", "who", "who's", "where", "where's", "when", "which", "can", "could",
        "do", "does", "did", "is", "are", "was", "were", "will", "would", "should", "may", "am", "have", "has", "shall",
    ]
    /// A two-word sentence about them or her ("I'm bored", "Love you") is a clear turn…
    static let personal: Set<String> = [
        "i", "i'm", "im", "i've", "i'd", "i'll", "me", "my", "you", "you're", "youre", "your", "we", "we're", "let's", "lets",
    ]
    /// …unless it is a reaction that only says "go on".
    static let reactionPhrases: Set<String> = [
        "i see", "i know", "me too", "thank you", "you bet", "i bet", "i agree", "you're right", "me neither", "i guess",
    ]
    static let humFillers: Set<String> = ["um", "uh", "er", "erm", "hmm"]

    /// Tune 7 (T6-3): over her voice, a short (≤ 2 words) fragment that is not clearly a
    /// stop or a question is a backchannel, however the transcriber spelled it. Live tune
    /// 6, four backchannels stopped her: "Keep going" came back as "Put going." and as
    /// "She.", "Go on" as "Grand.", and the tail of "Mm-hm" as "Done." — each answered
    /// (or decided early) as a turn, cutting her reply. A clear stop ("Stop.", "Wait.",
    /// "No.", "Hold on."), a question ("Why?", "Who made…"), a call of her name or a letter
    /// ("Dee.", "D.": the start of a turn), a number, or a two-word sentence about them or
    /// her ("I'm bored.", "Love you.") still counts as words for her.
    public static func isMisheardFragment(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains("?") else { return false }
        let w = words(t).filter { !humFillers.contains($0) }
        guard (1...2).contains(w.count) else { return false }
        let phrase = w.joined(separator: " ")
        if stopPhrases.contains(phrase) || w.contains(where: stopFragments.contains) { return false }
        if questionStarters.contains(w[0]) { return false }
        if isFragmentOrAddress(w) || w.contains(where: addressWords.contains) { return false }
        if w.contains(where: { $0.contains(where: \.isNumber) }) { return false }
        if w.count == 2, w.contains(where: personal.contains), !reactionPhrases.contains(phrase) { return false }
        return true
    }

    /// The first words of a partial that are already a question ("Who made", "Are you").
    public static func startsQuestion(_ words: [String]) -> Bool {
        guard let first = words.first else { return false }
        return questionStarters.contains(first)
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

    /// How far into a sentence a preamble is looked for (later, it is already audible
    /// as an answer and cutting it would cut words).
    public static let preambleWords = 7

    /// The sentences of a reply transcript so far (split after . ! ? …), the last one
    /// possibly unfinished.
    public static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var prev: Character?
        for ch in text {
            if let p = prev, ".!?…".contains(p), ch.isWhitespace {
                let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
                cur = ""
            }
            cur.append(ch)
            prev = ch
        }
        let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { out.append(t) }
        return out
    }

    /// The index of the first sentence of `text` that opens with meta narration
    /// ("Oh no, that sounds disappointing. Let me think about how to respond." → 1),
    /// or nil. Every sentence start is checked (tune 3: the live preamble was the
    /// second sentence), each on its first `preambleWords` words only. The first
    /// sentence uses `preamblePatterns`; later ones only `narrationPatterns` (talk
    /// about answering, looking up or saving), so "Let me think of another one!" or
    /// "Let me think about it with you." after a real answer is left alone.
    public static func metaSentence(in text: String) -> Int? {
        for (i, s) in sentences(text).enumerated() where i == 0 ? isMetaPreamble(s) : isNarration(s) { return i }
        return nil
    }

    /// Narration about her own answering, look-ups or memory, anywhere in a reply.
    static let narrationPatterns: [[String]] = [
        ["let", "me", "think", "about", "how"], ["let", "me", "think", "about", "what"], ["let", "me", "think", "how"],
        ["how", "to", "respond"], ["how", "i", "should", "respond"], ["how", "to", "answer"],
        ["let", "me", "respond"], ["let", "me", "answer"], ["let", "me", "check"], ["let", "me", "recall"],
        ["let", "me", "remember"], ["let", "me", "look"], ["let", "me", "save"], ["let", "me", "note"], ["let", "me", "jot"],
        ["let", "me", "make", "a", "note"], ["let", "me", "process"], ["let", "me", "store"], ["let", "me", "write"],
        ["let", "me", "tuck"], ["let", "me", "pull", "up"], ["let", "me", "grab"], ["let", "me", "see", "what", "i"],
        ["i'll", "note"], ["i'll", "save"], ["i'll", "store"], ["i'll", "jot"], ["i'll", "tuck"], ["i'll", "make", "a", "note"],
        ["i'll", "remember", "that"], ["i'll", "check", "what"], ["i", "need", "to", "think"], ["thinking", "about", "how"],
        ["memory", "check"], ["quick", "save"],
    ]

    /// Whether a later sentence of a reply opens with narration (`narrationPatterns`).
    public static func isNarration(_ sentence: String) -> Bool {
        let w = Array(words(sentence).prefix(preambleWords))
        for p in narrationPatterns where w.count >= p.count {
            for i in 0...(w.count - p.count) where Array(w[i..<(i + p.count)]) == p { return true }
        }
        return false
    }

    // MARK: The unfinished-words aim, spoken (tune 5 F3)

    /// Her reply pointing at their unfinished words instead of waiting for the rest:
    /// "I heard “I couldn’t sleep last…” and I’m curious what happened next. Want to
    /// finish the sentence?" (live tune 4, fan15 l05). Never heard: an unfinished turn
    /// is waited out in silence (decision, tune 5).
    static let unfinishedAimPhrases: [String] = [
        "finish the sentence", "finish your sentence", "finish that sentence", "finish the thought",
        "finish your thought", "finish that thought", "want to finish", "wanna finish", "like to finish",
        "you trailed off", "you got cut off", "you were cut off", "cut yourself off", "didn't catch the end",
        "didn't hear the end", "the rest of your sentence", "the rest of that sentence", "rest of the sentence",
        "only heard part", "only caught part", "heard only part",
    ]

    /// Tune 6 (T5-4, echo20 l03 "D."): the same aim in other words — "Hmm, did you want
    /// to say something, or just check if I was waiting?". By meaning: she asks whether
    /// they meant to say (more), remarks that they only said her name or stopped, or
    /// asks whether she is waiting / listening / still there. Matched on words, so the
    /// spelling and punctuation of the transcript never matter.
    static let unfinishedAimMeanings: [[String]] = [
        // Did they mean to say (more)?
        ["did", "you", "want", "to", "say"], ["do", "you", "want", "to", "say"], ["did", "you", "wanna", "say"],
        ["did", "you", "mean", "to", "say"], ["were", "you", "going", "to", "say"], ["were", "you", "gonna", "say"],
        ["were", "you", "about", "to", "say"], ["were", "you", "trying", "to", "say"], ["you", "were", "going", "to", "say"],
        ["you", "were", "about", "to", "say"], ["you", "started", "to", "say"], ["you", "were", "saying"],
        ["what", "were", "you", "saying"],
        ["something", "you", "wanted", "to", "say"], ["something", "you", "want", "to", "say"],
        ["something", "you", "were", "going", "to"], ["wanted", "to", "say", "something"], ["want", "to", "say", "something"],
        ["meant", "to", "say", "more"], ["more", "you", "wanted", "to", "say"],
        ["did", "you", "say", "something"], ["were", "you", "saying", "something"],
        // Is she waiting / listening / there?
        ["check", "if", "i"], ["check", "whether", "i"], ["checking", "if", "i"], ["checking", "whether", "i"],
        ["checking", "i'm"], ["check", "i'm"], ["see", "if", "i", "was"], ["see", "if", "i'm"],
        ["if", "i", "was", "waiting"], ["if", "i'm", "waiting"], ["if", "i", "was", "listening"], ["if", "i'm", "listening"],
        ["if", "i", "was", "still"], ["if", "i'm", "still"], ["whether", "i", "was"], ["are", "you", "still", "there"],
        // Only her name, or they stopped.
        ["just", "my", "name"], ["only", "my", "name"], ["just", "said", "my", "name"], ["you", "said", "my", "name"],
        ["called", "my", "name"], ["calling", "my", "name"], ["mid", "sentence"], ["midsentence"], ["half", "a", "sentence"],
    ]
    /// A meaning match followed by one of these is about someone else ("What did you want
    /// to say *to* your brother?"), never about their own unfinished words.
    static let aimElsewhere: Set<String> = ["to", "about", "at", "when", "if", "in", "on"]

    /// Whether a sentence of hers voices the unfinished-words aim.
    public static func isUnfinishedAim(_ sentence: String) -> Bool {
        let t = sentence.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        if unfinishedAimPhrases.contains(where: { t.contains($0) }) { return true }
        if contains(words(t), anyOf: unfinishedAimMeanings, notFollowedBy: aimElsewhere) { return true }
        // Their own words quoted back, cut ("I heard “I couldn't sleep last…”").
        for open in ["heard “", "heard \"", "heard: “", "heard: \""] where t.contains(open) { return true }
        return t.contains("…”") || t.contains("...”") || t.contains("…\"") || t.contains("...\"")
    }

    /// The first sentence of `text` that voices the unfinished-words aim.
    public static func unfinishedAimSentence(in text: String) -> Int? {
        for (i, s) in sentences(text).enumerated() where isUnfinishedAim(s) { return i }
        return nil
    }

    /// The note on the answer to a turn whose first reply voiced that aim and was
    /// taken back (nothing followed for `trailingWait`).
    public static let unfinishedAnswerNote =
        "If their words seemed to stop mid-sentence, just answer what you heard; never quote their words back or ask them to finish"

    // MARK: Reply length (tune 2: ≥ 95 % of replies ≤ 3 sentences)

    /// The per-response `max_output_tokens` for a reply under the DNA `Length:`
    /// line. Counts reasoning, transcript and audio tokens (live tune 1 replies:
    /// two sentences p90 312 / p98 360, three p50 270 / p90 359, four p50 323), so
    /// it is a backstop over the DNA wording, sized one sentence above the limit:
    /// a reply that runs past it ends at its last complete sentence (the brain stops
    /// her voice there; never mid-word). Thinking turns get room (nil: the session's
    /// runaway guard).
    ///
    /// Tune 4: tighter at `minimal` (its reasoning is ~30 tokens, not ~50–100):
    /// live tune 3 completed replies, output tokens p50 / p90 — two sentences 220 /
    /// 303, three 245 / 341, four 287 / 459. 340 for a two-sentence line keeps the
    /// three-sentence p90 and stops most four-sentence runs at their third sentence.
    public static func maxOutputTokens(length: String, effort: ReasoningEffort) -> Int? {
        let l = length.lowercased()
        let base = l.contains("one short sentence") ? 280 : l.contains("three") ? 480 : 380
        switch effort {
        case .minimal:
            return l.contains("one short sentence") ? 240 : l.contains("three") ? 440 : 340
        case .low: return base
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

    /// Whether `w` contains one of `patterns` as a run of words (not followed by one of
    /// `notFollowedBy`, when given).
    static func contains(_ w: [String], anyOf patterns: [[String]], notFollowedBy: Set<String> = []) -> Bool {
        for p in patterns where w.count >= p.count {
            for i in 0...(w.count - p.count) where Array(w[i..<(i + p.count)]) == p {
                let next = i + p.count < w.count ? w[i + p.count] : nil
                if let next, notFollowedBy.contains(next) { continue }
                return true
            }
        }
        return false
    }

    // MARK: Apps, clocks and forecasts (tune 6, T5-8)

    /// She has no apps, clock, calendar or internet to send anyone to; live tune 5 four
    /// replies still did ("…you can check a weather app or a forecast.", "You can check
    /// your phone's clock…"). A sentence that does is never heard.
    static let appReferralPatterns: [[String]] = [
        ["weather", "app"], ["clock", "app"], ["calendar", "app"], ["an", "app"], ["apps"],
        ["phone's", "clock"], ["your", "clock"], ["the", "clock", "on"], ["check", "the", "time"], ["check", "the", "clock"],
        ["check", "your", "phone"], ["look", "at", "your", "phone"],
        ["a", "forecast"], ["the", "forecast"], ["local", "forecast"], ["weather", "forecast"], ["forecast", "app"],
        ["weather", "report"], ["weather", "site"], ["weather", "service"], ["weather", "channel"],
        ["your", "calendar"], ["a", "calendar"], ["the", "calendar"],
        ["look", "it", "up"], ["look", "that", "up"], ["search", "online"], ["search", "for", "it"], ["a", "quick", "search"],
        ["google"], ["online"], ["the", "internet"], ["a", "website"], ["the", "website"],
    ]
    /// Offers to set something for them: never hers to make.
    static let setOffers: [[String]] = [["set", "a", "reminder"], ["set", "an", "alarm"], ["set", "a", "timer"], ["set", "you", "a"]]
    /// Who the sentence sends: them ("you can check…") — a limit of hers ("I can't see
    /// the forecast from here") is how she should say it.
    static let you: Set<String> = ["you", "you'd", "you'll", "you've", "your", "ya"]
    /// Verbs that make it a referral ("you can check…", "try…", "open…"); a pattern with
    /// none of these near it ("I don't have a clock app") is a limit said as Dee.
    static let referralVerbs: Set<String> = [
        "check", "checking", "open", "try", "use", "look", "search", "ask", "see", "glance", "peek", "set", "pull", "google",
    ]

    /// Whether a sentence of hers sends them to an app, a clock, a forecast, a calendar
    /// or a search (or offers to set something for them).
    public static func isAppReferral(_ sentence: String) -> Bool {
        let w = words(sentence)
        if contains(w, anyOf: setOffers) { return true }
        guard contains(w, anyOf: appReferralPatterns) else { return false }
        if w.contains("google") { return true }
        guard w.contains(where: referralVerbs.contains) else { return false }
        // Sent: "you can check…", or an imperative ("Or open the weather app.", "Try a forecast.").
        let opener = w.drop { ["or", "so", "maybe", "just", "and", "oh", "well", "then", "but"].contains($0) }.first
        return w.contains(where: you.contains) || opener.map(referralVerbs.contains) == true
    }

    /// The first sentence of `text` that is an app referral.
    public static func appReferralSentence(in text: String) -> Int? {
        for (i, s) in sentences(text).enumerated() where isAppReferral(s) { return i }
        return nil
    }

    /// The note on a turn answered again after her first sentence sent them to an app.
    public static let noAppNote =
        "You have no apps, clock, forecast or calendar to send them to: answer as Dee in a few words, from what you know or feel"

    // MARK: The reply's sentence budget (tune 7, T6-6)

    /// Sentences she may say for a DNA `Length:` value, counting every sentence the voice
    /// plays (a short exclamation too: "Oh, wow." "Nice."): "at most three" → 3, "at most
    /// two" → 2, "one short sentence" → 2 (a one-word opener must not leave her with
    /// nothing). Live tune 6, excited replies ran to six short sentences under a two-
    /// sentence Length ("Oh, wow. That sounds amazing. Biggest volcano in class? Nice. …")
    /// and the fixed cap of three let the third play.
    public static func sentenceBudget(length: String) -> Int {
        length.lowercased().contains("three") ? 3 : 2
    }

    // MARK: Self-narrated status reports (tune 7, T6-7)

    /// Her talking about herself as a machine giving a status read-out ("Tiny robot report:
    /// it feels like a lot of effort…", live tune 6 interrupt-fan15 l02; the judge read it
    /// as machinery): never heard.
    static let reportNouns: Set<String> = [
        "report", "update", "status", "bulletin", "log", "diagnostic", "diagnostics", "readout", "read-out", "alert",
        "announcement", "scan", "analysis", "assessment", "check-in", "checkin",
    ]
    static let reportSelves: Set<String> = ["robot", "dee", "dee's", "bot", "system", "systems", "circuit", "circuits", "sensor", "sensors", "mood", "feelings", "heart"]
    static let reportPhrases: [[String]] = [
        ["status", "report"], ["status", "update"], ["system", "check"], ["systems", "check"], ["system", "status"],
        ["robot", "status"], ["mood", "report"], ["feelings", "report"], ["heart", "report"], ["internal", "report"],
        ["processing", "complete"], ["beep", "boop"], ["self", "report"],
    ]

    /// A sentence that frames her own words as a robot's report or status ("Tiny robot
    /// report:", "Dee update:", "Status report:", "Mood report: sunny").
    public static func isSelfReport(_ sentence: String) -> Bool {
        let head = sentence.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let w = Array(words(sentence).prefix(preambleWords))
        if contains(w, anyOf: reportPhrases) { return true }
        // "<…> robot report:" — a self noun and a report noun before a colon.
        if head.count == 2 {
            let lead = words(String(head[0]))
            if lead.count <= 5, lead.contains(where: reportNouns.contains), lead.contains(where: reportSelves.contains) { return true }
        }
        for i in 0..<max(0, w.count - 1) where reportSelves.contains(w[i]) && reportNouns.contains(w[i + 1]) { return true }
        return false
    }

    /// The first sentence of `text` that is a self-narrated report.
    public static func selfReportSentence(in text: String) -> Int? {
        for (i, s) in sentences(text).enumerated() where isSelfReport(s) { return i }
        return nil
    }

    /// The note on a turn answered again after her first sentence was a status report.
    public static let noReportNote =
        "Talk like yourself, a little companion, never a robot giving a report or a status: answer in plain, warm words"

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
