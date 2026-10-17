import Foundation

/// Whether the words someone said over Dee's voice are a backchannel — "keep
/// going", "go on", "mm-hm", "yeah" — that means *go on*, never a turn of their
/// own and never a reason to stop.
///
/// `CloudVoice` uses it to settle a held barge-in (`FloorHold`): a backchannel
/// lets Dee go on from exactly where Dee paused; anything else ("stop", "wait",
/// a question) ends Dee's reply there. The brain's floor logic uses the same
/// classification (one rule for both, so Dee never resumes for words the brain
/// then answers, nor stops for words the brain lets pass).
///
/// The rule: every clause is a continuer (fillers like "Dee", "please", "just",
/// "so", "well", "no", "now" aside), at most 8 words, and no question — except
/// the continuers "really?", "yeah?", "and?", "and then?", "then what?".
public enum Backchannel {
    /// Whole-clause continuers.
    public static let continuers: Set<String> = [
        "keep going", "go on", "go ahead", "carry on", "continue", "don't stop", "do not stop", "please continue",
        "i'm listening", "im listening", "i am listening", "listening", "i'm still listening", "still listening",
        "mm hm", "mm hmm", "mhm", "mmhm", "mmhmm", "mm", "mmm", "uh huh", "uh-huh", "uhhuh", "yeah", "yeah yeah", "yep", "yes",
        "right", "okay", "ok", "sure", "i see", "got it", "cool", "nice", "wow", "oh", "ah", "aha", "really", "interesting",
        "and then", "then what", "what else", "tell me more", "more", "yes go on", "sure go on",
        "keep talking", "you can keep going", "you can go on", "please go on", "i'm here", "go for it",
        "keep on going", "keep it going",
        // How "keep going" comes back from transcription when said softly (tune 2 live: "Cheap, going.").
        "cheap going", "cheap", "going", "keep go",
        // How a soft "go on" comes back (tune 3 live, echo20 bc01: "Jeron.").
        "jeron", "jerron", "geron", "gerron", "jaron", "goan", "gowan", "go one", "goon",
        // How "keep going" comes back over a kitchen / Dee's echo (tune 4 live, kitchen15 c05: "Sheep going.").
        "sheep going", "she's going", "shes going", "she going", "keeps going", "keep goin", "key going",
        "keep it up", "keeping going",
    ]

    /// Continuers only inside a hold, in a short burst (`CloudVoice.isHoldBackchannel`):
    /// "Keep going" misheard as a sentence that would be a turn of its own
    /// anywhere else (tune 4 live, echo20 c05: "She's not going.").
    public static let holdOnlyContinuers: Set<String> = [
        "she's not going", "shes not going", "she is not going", "she's not", "sheep not going",
    ]

    /// Words that don't change what a clause means here.
    public static let fillers: Set<String> = ["dee", "d", "please", "just", "so", "well", "no", "now", "a", "an", "uh", "um"]

    static let questionContinuers: Set<String> = ["really?", "yeah?", "and?", "and then?", "then what?"]

    /// `text` is only a backchannel ("Keep going, I'm listening.", "Mm-hm.",
    /// "Don't stop, keep going."). "Stop", "wait", "no", a question or anything
    /// else make it a real turn.
    public static func isBackchannel(_ text: String) -> Bool {
        isBackchannel(text, inHold: false)
    }

    /// `inHold`: said in a hold, in a short burst — the hold-only continuers count too,
    /// and (tune 7), in its full transcript (`final`), a misheard fragment
    /// (`isMisheardFragment`; a settled partial "I'm" may still become a turn).
    ///
    /// `sound` (tune 9): what the item sounded like (`EarCore.itemSound`), when known. A
    /// one-word fragment the words don't know ("Movie.") is a backchannel only when it
    /// sounded like one (`isMisheardFragment(_:sound:)`).
    public static func isBackchannel(_ text: String, inHold: Bool, final: Bool = true, sound: FragmentSound? = nil) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if inHold, final, isMisheardFragment(trimmed, sound: sound) { return true }
        guard !trimmed.isEmpty, !trimmed.hasSuffix("?") || questionContinuers.contains(trimmed.lowercased()) else { return false }
        let all = words(trimmed.replacingOccurrences(of: "-", with: " "))
        guard !all.isEmpty, all.count <= 8 else { return false }
        let clauses = trimmed.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "-", with: " ")
            .split { ",.!?;…".contains($0) }
            .map { words(String($0)) }
            .filter { !$0.filter { !fillers.contains($0) }.isEmpty }
        guard !clauses.isEmpty else { return false }
        return clauses.allSatisfy { raw in
            let kept = raw.filter { !fillers.contains($0) }
            return isContinuer(raw, inHold: inHold) || isContinuer(kept, inHold: inHold) || kept.allSatisfy(isHum)
                || segments(kept, inHold: inHold)
        }
    }

    /// Words that are never a misheard "go on": they stop Dee, call Dee, ask, or
    /// make a sentence about them or Dee.
    static let notFragments: Set<String> = aloneWords.union([
        "i", "i'm", "im", "i've", "i'd", "i'll", "me", "my", "you", "you're", "youre", "your", "we", "we're", "us",
        "let's", "lets", "it", "that", "this",
    ])

    /// The `notFragments` a person says alone — they stop Dee, call Dee or ask (a lone
    /// "Me." or "It." over Dee is no sentence: it may be Dee's echo, tune 10 T9-7).
    static let aloneWords: Set<String> = [
        "stop", "wait", "hold", "hang", "pause", "quiet", "shush", "shh", "sh", "hush", "enough", "halt", "cancel", "never",
        "nevermind", "no", "nope", "not", "don't", "dont", "shut", "bye", "goodbye", "goodnight", "later", "move", "skip",
        "hey", "hello", "hi", "dee", "d", "excuse", "sorry", "help", "listen", "look",
        "what", "what's", "whats", "why", "how", "how's", "who", "who's", "where", "where's", "when", "which", "whose",
        "can", "could", "will", "would", "should", "may", "shall", "have", "has", "do", "does", "did", "is", "are", "am",
        "was", "were", "tell", "say", "repeat", "again", "but", "actually",
    ]

    /// Tune 8: reactions that, said over Dee's voice, only mean "go on" (the decision:
    /// backchannels continue Dee). "Thank you" over Dee's reply thanks Dee for what Dee
    /// is saying; a goodbye or a stop is never one of these.
    public static let reactionPhrases: Set<String> = [
        "i see", "i know", "me too", "me neither", "thank you", "thanks", "you bet", "i bet", "i agree", "you're right",
        "youre right", "i guess", "fair enough",
    ]

    /// One-letter or two-letter words that are a whole "go on" (any other — "I.",
    /// "K." — is the start of a turn).
    static let shortFragments: Set<String> = ["oh", "ah", "aw", "ok", "go", "ya", "ye", "yo", "eh", "hm", "mm"]

    /// Tune 9 (T8-1): single words that are a whole "go on" over Dee's voice, or what one
    /// came back as live ("Grand." for "Go on.", "She."/"Sheep." for "Keep going", "Done."
    /// for the tail of "Mm-hm"). Any other single word ("Movie.", "Music.", "Weather.") is
    /// a backchannel only if it also *sounds* like one (`FragmentSound.backchannelLike`).
    public static let fragmentWords: Set<String> = [
        "yeah", "yea", "yeh", "yep", "yup", "yes", "yah", "right", "alright", "okay", "okey", "ok", "sure", "cool",
        "nice", "wow", "aha", "really", "interesting", "more", "continue", "listening", "following", "going", "goin",
        "ahead", "keep", "keeps", "cheap", "sheep", "jeron", "jerron", "geron", "gerron", "jaron", "goan", "gowan",
        "goon", "grand", "she", "done", "fine", "good", "great", "true", "totally", "exactly", "absolutely",
        "definitely", "indeed", "gotcha", "neat", "awesome", "perfect", "amazing", "lovely", "thanks",
    ]

    /// The `fragmentWords` a misspelling may stand for (`isKnownFragmentWord`): the long,
    /// distinctive ones — never "right" ("eight", "night"), "fine" ("nine", "mine"), "done"
    /// ("none"), "yeah" ("year").
    static let fuzzyFragmentWords: Set<String> = [
        "listening", "following", "going", "cheap", "sheep", "grand", "really", "interesting", "continue",
        "absolutely", "definitely", "exactly", "totally", "awesome", "perfect", "amazing", "lovely", "alright",
        "gotcha", "jeron", "jerron", "geron", "gerron", "jaron", "gowan", "ahead",
    ]

    /// `word` (lowercased) is a known one-word "go on" (`fragmentWords`, a hum, a short
    /// "oh"/"ok"/"mm"), or — `fuzzy` — a misspelling of a distinctive one
    /// (`fuzzyFragmentWords`): one letter off, two off one of eight letters or more
    /// ("listenin", "absolutly"). Exact matches only when `fuzzy` is false.
    public static func isKnownFragmentWord(_ word: String, fuzzy: Bool = true) -> Bool {
        let w = word.lowercased()
        if fragmentWords.contains(w) || isHum(w) || shortFragments.contains(w) { return true }
        guard fuzzy, w.count >= 5, !w.contains(where: \.isNumber) else { return false }
        return fuzzyFragmentWords.contains { k in
            let limit = k.count >= 8 ? 2 : 1
            return abs(k.count - w.count) <= limit && editDistance(w, k, limit: limit) <= limit
        }
    }

    /// Levenshtein distance, stopping early once every path is over `limit` (then `limit + 1`).
    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > limit { return limit + 1 }
        if x.isEmpty || y.isEmpty { return max(x.count, y.count) }
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + [Int](repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            if cur.min()! > limit { return limit + 1 }
            prev = cur
        }
        return prev[y.count]
    }

    /// Tune 7/8: the single rule (voice and brain) for a backchannel over Dee's voice
    /// that came back from transcription as a fragment that means nothing on its own.
    /// The caller decides it was said over Dee's voice (the voice: in a hold, a short
    /// burst, its full transcript; the brain: `duringHerSpeech`). Safe on a partial: a
    /// partial that is still such a fragment never decides a turn early.
    ///
    /// Live misreads it takes: "Put going.", "Sheupr and going." ("Keep going", tune 7
    /// echo20 c05), "Grand." ("Go on."), "She.", "Done." (the tail of "Mm-hm"), "I'm
    /// listen." (fan15 c05, cut off), "Yeah.", hums. It also takes reactions
    /// (`reactionPhrases`: "I see", "Me too", "Thank you"). Never: a "?", a number, a
    /// stop, call or question word (`notFragments`), a sentence about them ("I'm
    /// bored.", "Love you."), a lone letter ("I.", "D."), "Too late." (live fan15 q08
    /// "Who made you?" — its second word ends no continuer), "Tell me.".
    ///
    /// Shapes (fillers aside): 1 known word (tune 9; see above); 2 or 3 words whose last ends a continuer
    /// (going/goin/on/listening/ahead) or is a hum; a continuer cut off inside its last
    /// word ("I'm listen", "I'm still listen").
    ///
    /// Tune 9 (T8-1): one word is a fragment only when the words know it
    /// (`isKnownFragmentWord`; a misspelling of one only when its sound, if known, is not
    /// question-like); live "Movie." ("Who made you?") is not — without its sound it is a
    /// turn (decision: a missed question is worse than a brief pause). The voice and the
    /// brain call `isMisheardFragment(_:sound:)` with the item's sound
    /// (`CloudVoice.isMisheardFragment(itemID:text:)`).
    public static func isMisheardFragment(_ text: String) -> Bool {
        isMisheardFragment(text, sound: nil)
    }

    /// `isMisheardFragment`, deciding a single word the words don't know by what it
    /// sounded like: short (≤ `FragmentSound.backchannelMaxVoiced` of voice), at most two
    /// syllables, not rising (`FragmentSound.backchannelLike`). No sound: not a fragment.
    public static func isMisheardFragment(_ text: String, sound: FragmentSound?) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("?") else { return false }
        let kept = words(trimmed.replacingOccurrences(of: "-", with: " ")).filter { !fillers.contains($0) || $0 == "no" }
        guard (1...3).contains(kept.count) else { return false }
        if kept.contains(where: { $0.contains(where: \.isNumber) }) { return false }
        if kept.count == 1, kept[0].count <= 2, !shortFragments.contains(kept[0]), !isHum(kept[0]) { return false }
        if reactionPhrases.contains(kept.joined(separator: " ")) { return true }
        if kept.count >= 2, isCutOffContinuer(kept) { return true }
        if kept.contains(where: notFragments.contains) { return false }
        // One word; or two or three where only the end of a continuer survived
        // ("Put going.", "Sheupr and going."): "I'm hungry." / "Too late." are turns.
        guard kept.count > 1 else {
            let w = kept[0]
            if isKnownFragmentWord(w, fuzzy: false) { return true }
            // A misspelling of one: the words say "go on", unless it sounded like a question.
            if isKnownFragmentWord(w) { return sound?.questionLike != true }
            // Tune 9 (T8-1): a word the words don't know is "go on" only by its sound.
            return sound?.backchannelLike == true
        }
        return fragmentEnds.contains(kept[kept.count - 1]) || (kept.count == 2 && isHum(kept[1]))
    }

    /// Tune 12 (live fan15 c05: "Keep going, I'm listening." came back as "Keep going." |
    /// "I'm with some."): the second half of a backchannel the server split off. Decision:
    /// a short item — at most `continuerTailMaxVoiced` of their voice, at most
    /// `continuerTailMaxWords` words (fillers aside), no "?", no stop, call or question word
    /// (`aloneWords`), a pitch that does not rise — said right after a recognised continuer in
    /// the same hold (`CloudVoice.FloorHold.followsContinuer`) is the rest of it. The
    /// syllable count is not used: "I'm listening" itself has four. No sound: not a tail.
    /// The voice's hold verdict and the brain (`CloudVoice.isHoldBackchannel`) share it.
    public static func isContinuerTail(_ text: String, sound: FragmentSound?) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("?"), let sound,
              sound.voiced <= continuerTailMaxVoiced + 1e-9, sound.pitchEnd != .rising else { return false }
        let all = words(trimmed.replacingOccurrences(of: "-", with: " "))
        guard !all.contains(where: { aloneWords.contains($0) || $0.contains(where: \.isNumber) }) else { return false }
        return (1...continuerTailMaxWords).contains(all.filter { !fillers.contains($0) }.count)
    }

    /// Tune 12: the most voice a continuer's split-off tail has ("I'm listening" ~0.8 s).
    public static let continuerTailMaxVoiced = 1.2
    /// Tune 12: the most words (fillers aside) a continuer's split-off tail has.
    public static let continuerTailMaxWords = 3
    /// Tune 12: the tail begins at most this long after the continuer's speech ended.
    public static let continuerTailGap = 0.8

    /// The last word a misheard continuer keeps.
    static let fragmentEnds: Set<String> = ["going", "goin", "on", "listening", "ahead"]

    /// `kept` is a continuer of two words or more whose last word was cut off ("i'm
    /// listen" for "I'm listening", "go ahe"): every word but the last matches, the
    /// last is a strict start (3 letters or more) of the continuer's word.
    static func isCutOffContinuer(_ kept: [String]) -> Bool {
        guard let last = kept.last, last.count >= 3 else { return false }
        return continuers.contains { c in
            let cw = c.split(separator: " ").map(String.init)
            guard cw.count >= kept.count else { return false }
            for i in 0..<(kept.count - 1) where cw[i] != kept[i] { return false }
            let w = cw[kept.count - 1]
            return w != last && w.hasPrefix(last)
        }
    }

    /// Tune 6: partial words that are, or may still become, a backchannel ("I'm",
    /// "Keep", "I'm listen"): every clause but the last is one, and the last is the
    /// start of a continuer (its last word may be cut off). Empty: true.
    public static func mayBecomeBackchannel(_ partial: String) -> Bool {
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || isBackchannel(trimmed) { return true }
        if trimmed.hasSuffix("?") { return false }
        let clauses = trimmed.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "-", with: " ")
            .split(omittingEmptySubsequences: false) { ",.!;…".contains($0) }
            .map { words(String($0)) }
        guard let last = clauses.last(where: { !$0.isEmpty }) else { return true }
        let earlier = clauses.prefix(through: clauses.lastIndex(where: { !$0.isEmpty })!).dropLast()
            .filter { !$0.filter { !fillers.contains($0) }.isEmpty }
        guard earlier.allSatisfy({ isBackchannel($0.joined(separator: " ")) }) else { return false }
        let kept = last.filter { !fillers.contains($0) }
        guard !kept.isEmpty else { return true }
        if kept.allSatisfy(isHum) { return true }
        return continuers.contains { c in
            let cw = c.split(separator: " ").map(String.init)
            guard kept.count <= cw.count else { return false }
            for (i, w) in kept.enumerated() {
                if i == kept.count - 1 { if !cw[i].hasPrefix(w) { return false } } else if cw[i] != w { return false }
            }
            return true
        }
    }

    static func isContinuer(_ words: [String], inHold: Bool) -> Bool {
        let w = words.joined(separator: " ")
        return continuers.contains(w) || (inHold && holdOnlyContinuers.contains(w))
    }

    /// The clause is continuers run together without a comma ("keep going I'm
    /// listening", "go on go on", "mm-hm yeah").
    static func segments(_ words: [String], inHold: Bool) -> Bool {
        guard words.count >= 2 else { return false }
        var ok = [Bool](repeating: false, count: words.count + 1)
        ok[0] = true
        for end in 1...words.count {
            for start in max(0, end - 4)..<end where ok[start] {
                let part = Array(words[start..<end])
                if isContinuer(part, inHold: inHold) || part.allSatisfy(isHum) { ok[end] = true; break }
            }
        }
        return ok[words.count]
    }

    /// A hum however it is spelled: "mm-hm", "mhm", "hmm", "mmhn" (tune 2 live:
    /// "Mm-hm." came back as "MMHN."), "nnhn" (tune 9 live, kitchen15 bc02) — only
    /// m, n, h and u, with an m or an n ("uh", "huh" are not hums). Tune 11 (review
    /// risk 7): one without an m has no u either — "Unh.", "Uhn.", "Un." mean "no".
    static func isHum(_ w: String) -> Bool {
        w.count >= 2 && w.count <= 6 && w.allSatisfy { "mhnu".contains($0) } && w.contains { "mn".contains($0) }
            && (w.contains("m") || !w.contains("u"))
    }

    // MARK: Calm (spec §4.1): sounds that mean "go on" inside a hold

    /// Laughs as transcription writes them.
    public static let laughTokens: Set<String> = ["ha", "hah", "haha", "hahaha", "heh", "hehe", "lol"]
    /// Filler-only clauses ("Uh.", "Hm.") — a cough or a throat clear often comes back so.
    public static let fillerTokens: Set<String> = ["uh", "um", "er", "huh", "hm", "hmm", "ah", "ahem", "oh"]
    /// What a bracketed, parenthesized or asterisked sound tag must mention.
    static let soundTagWords = ["laugh", "chuckl", "cough", "sneez", "breath", "sigh", "sniff", "clears throat",
                                "clearing throat", "throat clear"]

    /// Calm: `text`, said **inside a hold** (either phase) in a short burst
    /// (`CalmTuning.tokenBurstMax`, the caller's test), is a sound that means "go on": laugh
    /// tokens ("Ha ha.", "Heh.", "lol"), sound tags ("(coughs)", "[laughter]", "*sighs*") or
    /// filler-only words ("Uh.", "Um."); with continuer clauses ("Haha, yeah."). Laugh tokens
    /// and tags skip the syllable rule (a laugh has three or more: `questionLike`). Never with a
    /// "?" ("Huh?", "Haha, what?"), nor a filler whose pitch rises at the end (`sound`).
    /// Outside a hold nothing changes: `isBackchannel` never calls this.
    public static func isHoldSoundToken(_ text: String, sound: FragmentSound?) -> Bool {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty, !t.contains("?") else { return false }
        var saw = false
        // Sound tags: every one must be a body sound ("[music]" is not).
        if let tags = try? NSRegularExpression(pattern: #"[\[\(\*][^\]\)\*]{1,40}[\]\)\*]"#) {
            let ns = t as NSString
            for m in tags.matches(in: t, range: NSRange(location: 0, length: ns.length)).reversed() {
                let inner = ns.substring(with: m.range)
                guard soundTagWords.contains(where: inner.contains) else { return false }
                saw = true
                t = (t as NSString).replacingCharacters(in: m.range, with: ",")
            }
        }
        let clauses = t.replacingOccurrences(of: "\u{2019}", with: "'").replacingOccurrences(of: "-", with: " ")
            .split { ",.!;…".contains($0) }
            .map { words(String($0)) }
            .filter { !$0.isEmpty }
        for w in clauses {
            let joined = w.joined(separator: " ")
            if w.allSatisfy(laughTokens.contains) || joined == "he he" || joined == "he he he" {
                saw = true
            } else if w.allSatisfy(fillerTokens.contains) {
                guard sound?.pitchEnd != .rising else { return false }
                saw = true
            } else if !isBackchannel(joined, inHold: true, final: false) {
                return false
            }
        }
        return saw
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }
}
