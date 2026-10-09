import Foundation
import NaturalLanguage

/// How something was said, measured from the microphone (DeeVoice fills this in).
/// Absolute numbers vary by phone and room, so the appraiser compares them with the
/// user's own running baseline rather than fixed thresholds.
public struct Prosody: Sendable, Equatable, Codable {
    /// Mean loudness in dBFS over the utterance (e.g. −45 quiet … −15 shouting).
    public var loudnessDB: Double
    /// Peak loudness in dBFS.
    public var peakDB: Double
    /// Words per second.
    public var speechRate: Double
    /// Pitch variability (semitone standard deviation); flat ≈ 1, animated ≈ 4+.
    public var pitchVariability: Double

    public init(loudnessDB: Double, peakDB: Double, speechRate: Double, pitchVariability: Double = 2.5) {
        self.loudnessDB = loudnessDB
        self.peakDB = peakDB
        self.speechRate = speechRate
        self.pitchVariability = pitchVariability
    }
}

/// What an utterance means for Dee, emotionally. All 0…1 unless noted.
public struct Appraisal: Sendable, Equatable {
    /// Overall positivity, −1…1 (words and tone combined).
    public var valence = 0.0
    /// Insults, contempt, rudeness aimed at Dee.
    public var hostility = 0.0
    /// Threats (deleting, breaking, unplugging Dee).
    public var threat = 0.0
    /// Kindness, friendliness, gentleness.
    public var warmth = 0.0
    public var praise = 0.0
    /// Expressions of love / liking / missing Dee.
    public var affection = 0.0
    public var gratitude = 0.0
    public var apology = 0.0
    /// "Whatever", "boring", "go away".
    public var dismissal = 0.0
    /// The user asks about Dee itself ("how are you?").
    public var interestInDee = 0.0
    /// User laughing or joking.
    public var humor = 0.0
    /// −1 passive/deferential … +1 aggressive/commanding.
    public var dominance = 0.0
    /// How forcefully it was said: loudness, caps, exclamation marks, 0…1.
    public var intensity = 0.0
    /// −1 soft/whispered … +1 loud/shouted, relative to this user's normal.
    public var loudness = 0.0
    /// New topic vs. repeating what was just said.
    public var novelty = 0.5
    public var repetition = 0.0
    /// The user says they feel bad ("I had a bad day"): a cue for empathy, not offence.
    public var distress = 0.0
    /// Light sarcasm heuristics fired ("thanks for nothing", "yeah right", …), 0…1.
    public var sarcasm = 0.0
    /// False when the words weren't addressed to Dee (no "you"/"Dee" and no
    /// inherently addressed phrase). Negative *sentiment* in such lines ("what time
    /// is it", "I had a bad day") then doesn't count as unkindness toward Dee.
    /// Hand-built appraisals default to true.
    public var aimedAtDee = true

    // --- Non-verbal stimuli (v0.4). Defaults leave speech appraisal unchanged. ---

    /// The touch this appraisal came from, if any (see `Appraisal.touch(_:)`).
    public var touch: Touch?
    /// The sound this appraisal came from, if any (see `Appraisal.sound(…)`).
    public var soundLabel: String?
    /// True for an appraisal of something Dee saw (see `Appraisal.sight(novelty:)`).
    public var isSight = false
    /// False when the stimulus doesn't come from the user (a sound, something
    /// seen): it then moves Dee's feelings but not the bond, loneliness or
    /// personality.
    public var social = true
    /// Gentle physical care (petting, a hug), 0…1. Builds confidence and calm.
    public var care = 0.0
    /// A sudden jolt (an unexpected bang, a slap), 0…1: surprise, some fear.
    public var startle = 0.0
    /// Something alarming (siren, smoke alarm, glass breaking), 0…1: fear.
    public var alarm = 0.0
    /// Something pleasant that isn't about the user (music, birdsong), 0…1: joy.
    public var delight = 0.0
    /// Too much stimulation (tickling that goes on and on), 0…1.
    public var overstimulation = 0.0

    // --- Internal events (v0.5). Defaults leave everything above unchanged. ---

    /// True for Dee's own internal event (see `Appraisal.internal(relief:pride:)`):
    /// a resolved expectation or a completed intention, not something the user did.
    public var isInternal = false
    /// Something she was anxious about turned out fine, 0…1: fear and sadness
    /// ease, a little joy.
    public var relief = 0.0
    /// She finished something she meant to do, 0…1: joy and a little interest.
    public var pride = 0.0

    public init() {}

    /// A friendly wave at the camera.
    public static var wave: Appraisal { var a = Appraisal(); a.warmth = 0.6; a.valence = 0.4; a.novelty = 0.4; return a }
    /// A thumbs-up.
    public static var thumbsUp: Appraisal { var a = Appraisal(); a.praise = 0.5; a.warmth = 0.3; a.valence = 0.5; return a }

    /// Overall "is this person being kind to me right now", −1…1.
    public var kindness: Double {
        let good = warmth * 0.5 + praise * 0.6 + affection * 0.8 + gratitude * 0.5 + apology * 0.3
        // Affection softens the sting of a mild jab said in the same breath
        // ("hehe dummy, I love you" is affectionate teasing).
        let bad = hostility * (1 - min(0.7, affection)) + threat * 1.2 + dismissal * 0.5
        let mood = aimedAtDee ? valence : max(0, valence)
        return max(-1, min(1, good - bad + mood * 0.3))
    }
}

/// Turns an utterance (+ optional prosody) into an `Appraisal`.
///
/// Deliberately not an LLM call: it runs before the model sees the text, in a
/// millisecond, and every number it produces can be explained. Words come from
/// Apple's on-device sentiment model plus small, negation-aware lexicons; tone
/// comes from prosody relative to the user's own running baseline.
public struct Appraiser: Sendable {
    /// Running baseline of this user's voice (exponential moving averages).
    public private(set) var baseline = VoiceBaseline()
    private var recent: [Set<String>] = []

    public init(baseline: VoiceBaseline = VoiceBaseline()) {
        self.baseline = baseline
    }

    public struct VoiceBaseline: Sendable, Equatable, Codable {
        public var loudnessDB = -32.0
        public var loudnessSpread = 6.0
        public var speechRate = 2.6
        public var samples = 0
        public init() {}
    }

    public mutating func appraise(_ text: String, prosody: Prosody? = nil) -> Appraisal {
        appraise(text, prosody: prosody, sentiment: true)
    }

    /// - Parameter sentiment: false skips Apple's sentiment model (≈0.2 s per call)
    ///   and appraises from the lexicons and prosody alone — for live previews of
    ///   half-heard speech, where the answer is needed several times a second.
    public mutating func appraise(_ text: String, prosody: Prosody?, sentiment useSentiment: Bool) -> Appraisal {
        let (a, footprint) = evaluate(text, prosody: prosody, sentiment: useSentiment)
        record(footprint)
        return a
    }

    /// Appraises without changing the appraiser (no voice-baseline update, nothing
    /// added to the repetition window): what `appraise` would return right now.
    public func peek(_ text: String, prosody: Prosody? = nil) -> Appraisal {
        evaluate(text, prosody: prosody).appraisal
    }

    /// What appraising one utterance changes in the appraiser itself: the prosody
    /// sample for the voice baseline and the utterance's content-word set for the
    /// repetition window. RAM only (it holds words): never persist or log it.
    public struct Footprint: Sendable, Equatable {
        let content: Set<String>
        let prosody: Prosody?
    }

    /// Pure: the appraisal plus the footprint that `record(_:)` applies.
    /// `appraise(t, p)` ≡ `let (a, f) = evaluate(t, p); record(f); return a`.
    public func evaluate(_ text: String, prosody: Prosody? = nil, sentiment useSentiment: Bool = true) -> (appraisal: Appraisal, footprint: Footprint) {
        var a = Appraisal()
        let lower = Self.normalize(text)
        let words = lower.split(separator: " ").map(String.init)

        // --- Words -----------------------------------------------------------
        let sentiment = useSentiment ? Self.sentiment(text) : 0
        let addressed = Self.contains(lower, Lexicon.addressWords)

        a.distress = Self.score(lower, Lexicon.distress)
        let insults = Self.score(lower, Lexicon.insults)
        let rude = Self.score(lower, Lexicon.rudeCommands)
        let profanity = Self.score(lower, Lexicon.profanity)
        // Insults not aimed at Dee ("this traffic is stupid") count a little; while
        // the user is telling Dee how *they* feel ("I feel awful") not at all.
        let insultWeight = addressed ? 1 : (a.distress > 0 ? 0 : 0.4)
        a.hostility = insults * insultWeight + rude * 0.8 + profanity * (addressed ? 0.5 : 0.15)
        a.threat = Self.score(lower, Lexicon.threats)
        a.praise = Self.score(lower, Lexicon.praise) * (addressed ? 1 : 0.5)
        a.affection = Self.score(lower, Lexicon.affection)
        a.gratitude = Self.score(lower, Lexicon.gratitude)
        a.apology = Self.score(lower, Lexicon.apology)
        let dismissedDee = Self.score(lower, Lexicon.dismissal)
        a.dismissal = min(1, dismissedDee + Self.score(lower, Lexicon.dismissiveWords) * (addressed ? 1 : 0.4))
        a.interestInDee = Self.score(lower, Lexicon.aboutDee)
        a.humor = min(1, Self.score(lower, Lexicon.laughter) + Self.laughterScore(words))
        a.aimedAtDee = addressed || rude > 0 || a.threat > 0 || dismissedDee > 0
        let polite = Self.score(lower, Lexicon.politeness)

        // Teasing with play signals (laughter, "I love you") is affiliative, not
        // hostile — as long as it's a mild jab, with no threat or swearing.
        let teasing = (a.humor >= 0.4 || a.affection >= 0.4) && a.threat == 0 && profanity == 0 && insults < 0.6
        if teasing {
            a.hostility *= max(0.2, 1 - 0.6 * a.humor - 0.6 * a.affection)
        }

        // Light sarcasm heuristics: only a few unambiguous patterns.
        a.sarcasm = Self.sarcasm(lower)
        // The sentiment model reads playful jabs as negative; with play signals, ignore that.
        var wordSentiment = teasing && insults > 0 ? max(0, sentiment) : sentiment
        if a.sarcasm > 0 {
            a.praise = 0; a.gratitude = 0; a.apology = 0; a.affection = 0
            a.hostility += 0.3 * a.sarcasm * (a.aimedAtDee ? 1 : 0.5)
            a.dismissal = min(1, a.dismissal + 0.3 * a.sarcasm)
            wordSentiment = min(0, sentiment)
        }

        a.warmth = min(1, polite * 0.5 + Self.score(lower, Lexicon.greetings) * 0.4 + max(0, wordSentiment) * 0.4 + a.affection * 0.3)

        // Commanding vs deferential phrasing.
        let commands = Self.score(lower, Lexicon.commanding)
        let hedges = Self.score(lower, Lexicon.hedging)
        a.dominance = max(-1, min(1, commands * 0.7 + a.hostility * 0.4 - hedges * 0.6 - polite * 0.4))

        // Typography as tone: SHOUTING and !!!.
        let letters = text.filter(\.isLetter)
        let caps = letters.count >= 6 ? Double(letters.filter(\.isUppercase).count) / Double(letters.count) : 0
        let bangs = Double(text.filter { $0 == "!" }.count)
        var typed = min(1, max(0, (caps - 0.5) * 2) + min(0.4, bangs * 0.12))

        // --- Voice -----------------------------------------------------------
        if let p = prosody {
            let z = (p.loudnessDB - baseline.loudnessDB) / max(2, baseline.loudnessSpread)
            a.loudness = max(-1, min(1, z / 2))
            let fast = max(0, (p.speechRate - baseline.speechRate) / max(0.5, baseline.speechRate))
            let peak = max(0, (p.peakDB - baseline.loudnessDB - 12) / 12)
            let voiced = max(0, a.loudness) * 0.6 + min(1, fast) * 0.25 + min(1, peak) * 0.3
            typed = max(typed, voiced)
            // Loud + negative words = aggression; soft + kind words = tenderness.
            if a.loudness > 0.3 { a.dominance = min(1, a.dominance + a.loudness * 0.5) }
            if a.loudness < -0.3 { a.dominance = max(-1, a.dominance + a.loudness * 0.4) }
        }
        a.intensity = min(1, typed)

        // Shouting turns rudeness up and makes even neutral words feel harsh.
        if a.intensity > 0.3 {
            a.hostility = min(1, a.hostility * (1 + a.intensity) + (wordSentiment < -0.2 ? a.intensity * 0.3 : 0))
        }
        // Speaking softly and kindly reads as tender.
        if a.loudness < -0.3, wordSentiment > 0.1 || a.affection > 0 {
            a.warmth = min(1, a.warmth + 0.2)
        }

        a.hostility = min(1, a.hostility)
        a.valence = max(-1, min(1, wordSentiment * 0.6 + a.kindnessTerms - (a.hostility + a.threat) * 0.6))

        // --- Novelty / repetition -------------------------------------------
        let content = Set(words.filter { $0.count > 3 && !Lexicon.stopwords.contains($0) })
        if content.isEmpty {
            a.novelty = 0.2
        } else {
            let overlap = recent.map { Double($0.intersection(content).count) / Double(max(1, content.count)) }.max() ?? 0
            a.repetition = overlap > 0.6 ? overlap : 0
            a.novelty = 1 - overlap
        }
        return (a, Footprint(content: content, prosody: prosody))
    }

    /// Applies an utterance's footprint: updates the voice baseline (if it had
    /// prosody) and adds its content words to the repetition window.
    public mutating func record(_ footprint: Footprint) {
        if let p = footprint.prosody { updateBaseline(p) }
        recent.append(footprint.content)
        if recent.count > 6 { recent.removeFirst() }
    }

    private mutating func updateBaseline(_ p: Prosody) {
        let alpha = baseline.samples < 5 ? 0.3 : 0.08
        let dev = abs(p.loudnessDB - baseline.loudnessDB)
        baseline.loudnessDB += (p.loudnessDB - baseline.loudnessDB) * alpha
        baseline.loudnessSpread += (dev - baseline.loudnessSpread) * alpha * 0.5
        baseline.speechRate += (p.speechRate - baseline.speechRate) * alpha
        baseline.samples += 1
    }


    // MARK: - Text helpers

    /// Clause breaks survive normalisation as tokens: "|" for , . ; : ! and the
    /// like, "?" for questions. Negation never reaches across them.
    static let clauseBreaks: Set<String> = ["|", "?"]

    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "\\?+", with: " ? ", options: .regularExpression)
            .replacingOccurrences(of: "[.,;:!…—–()\"]+", with: " | ", options: .regularExpression)
            .replacingOccurrences(of: "[^a-z0-9'|? ]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Apple's on-device sentiment, −1…1 (0 when unavailable).
    /// One tagger for the whole process, language pinned to English.
    ///
    /// Building an `NLTagger` loads its model (≈0.25–1.3 s); a shared one answers in
    /// ≈0.2 ms. But a shared tagger left to detect the language carries that guess
    /// from one string to the next, so results depend on what it saw before — fatal
    /// for a deterministic mind. Pinning the language makes every call independent.
    /// Very short utterances ("hi Dee") are left to the lexicons: the sentiment model
    /// is unreliable below a few words (and a fresh tagger declines to score them).
    nonisolated(unsafe) private static let sharedTagger = NLTagger(tagSchemes: [.sentimentScore])
    private static let taggerLock = NSLock()
    static let minSentimentWords = 4

    static func sentiment(_ text: String) -> Double {
        let words = text.split(whereSeparator: { !$0.isLetter && $0 != "'" }).count
        guard words >= minSentimentWords else { return 0 }
        taggerLock.lock()
        defer { taggerLock.unlock() }
        let tagger = sharedTagger
        tagger.string = text
        tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
        var total = 0.0, n = 0.0
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .paragraph, scheme: .sentimentScore, options: []) { tag, _ in
            if let v = tag.flatMap({ Double($0.rawValue) }) { total += v; n += 1 }
            return true
        }
        return n > 0 ? total / n : 0
    }

    static func contains(_ text: String, _ words: [String]) -> Bool {
        let padded = " \(text) "
        return words.contains { padded.contains(" \($0) ") }
    }

    /// Weighted phrase hits, 0…1. A hit doesn't count when:
    /// - a negator appears in the three words before it *within the same clause*
    ///   ("not stupid", "don't hate you", "never boring" — but "No, I love you!" is
    ///   not negated), unless the negator opens a question ("Isn't Dee smart?");
    /// - it lies inside a longer phrase from the same list that already matched
    ///   ("hate" inside "hate you", "thank" inside "thank you").
    static func score(_ text: String, _ lexicon: [(String, Double)]) -> Double {
        let tokens = text.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return 0 }
        let phrases = lexicon
            .map { (words: $0.0.split(separator: " ").map(String.init), weight: $0.1) }
            .sorted { $0.words.count > $1.words.count }
        var taken: [Range<Int>] = []
        var total = 0.0
        for (words, weight) in phrases where !words.isEmpty && words.count <= tokens.count {
            for start in 0...(tokens.count - words.count) where Array(tokens[start..<start + words.count]) == words {
                let span = start..<start + words.count
                if taken.contains(where: { $0.lowerBound <= span.lowerBound && span.upperBound <= $0.upperBound }) { continue }
                taken.append(span)
                if !isNegated(tokens, at: start) { total += weight }
            }
        }
        return min(1, total)
    }

    static func isNegated(_ tokens: [String], at start: Int) -> Bool {
        var i = start - 1
        var looked = 0
        while i >= 0, looked < 3 {
            let w = tokens[i]
            if clauseBreaks.contains(w) { return false }
            if Lexicon.negators.contains(w) {
                // A rhetorical question opened by a negated auxiliary ("Isn't Dee
                // smart?", "Aren't you clever?") asserts the positive.
                let opensClause = i == 0 || clauseBreaks.contains(tokens[i - 1])
                let clauseEnd = tokens[start...].first { clauseBreaks.contains($0) }
                if opensClause, clauseEnd == "?", Lexicon.rhetoricalAuxiliaries.contains(w) { return false }
                return true
            }
            i -= 1
            looked += 1
        }
        return false
    }

    /// Laughter of any length: "haha", "hahahaha", "hehehe", "lol", "loool", "lmaooo".
    static func laughterScore(_ words: [String]) -> Double {
        var total = 0.0
        for w in words where w.wholeMatch(of: Lexicon.laughPattern) != nil {
            total += min(0.9, 0.45 + 0.05 * Double(w.count))
        }
        return min(1, total)
    }

    /// A few cheap, fairly unambiguous sarcasm patterns, 0…1. Anything subtler is a
    /// documented limitation: a lexicon can't hear a raised eyebrow.
    static func sarcasm(_ text: String) -> Double {
        let tokens = text.split(separator: " ").map(String.init)
        var s = 0.0
        if contains(text, ["thanks for nothing", "thank you for nothing", "thanks a lot for nothing", "sorry not sorry"]) { s = 1 }
        // "yeah right" only as its own clause or before "like…"/"as if…".
        for i in tokens.indices.dropLast() where tokens[i] == "yeah" && tokens[i + 1] == "right" {
            let next = i + 2 < tokens.count ? tokens[i + 2] : "|"
            if clauseBreaks.contains(next) || next == "like" || next == "as" { s = max(s, 0.8) }
        }
        // Mock praise about a mishap: "Oh great, you broke it again."
        if contains(text, ["oh great", "oh wonderful", "oh perfect", "just great", "nice going", "way to go", "oh good job"]),
           contains(text, ["broke", "broken", "again", "ruined", "messed", "failed", "screwed", "wrong"]) {
            s = max(s, 0.8)
        }
        return s
    }
}

private extension Appraisal {
    var kindnessTerms: Double { warmth * 0.3 + praise * 0.3 + affection * 0.4 + gratitude * 0.2 }
}

/// Phrase lists with weights. Multi-word phrases are matched on word boundaries.
enum Lexicon {
    static let negators: Set<String> = ["not", "no", "never", "don't", "dont", "didn't", "isn't", "aren't", "wasn't", "won't", "nothing", "hardly"]
    /// Negators that can open a rhetorical question.
    static let rhetoricalAuxiliaries: Set<String> = ["isn't", "aren't", "wasn't", "don't", "didn't", "won't"]
    /// Words that make a line about Dee / addressed to Dee.
    static let addressWords = ["you", "your", "you're", "youre", "yourself", "you've", "you'll", "you'd", "dee", "u", "ur"]
    nonisolated(unsafe) static let laughPattern = /(ha){2,}h?|(he){2,}h?|(hah)+a?|lo+l+|lmf?ao+|rofl/

    static let insults: [(String, Double)] = [
        ("stupid", 0.6), ("idiot", 0.7), ("dumb", 0.55), ("useless", 0.6), ("worthless", 0.75), ("pathetic", 0.6),
        ("hate you", 0.9), ("ugly", 0.5), ("annoying", 0.45), ("moron", 0.7), ("loser", 0.55),
        ("garbage", 0.5), ("trash", 0.5), ("piece of junk", 0.7), ("broken", 0.25), ("waste of", 0.5),
        ("you suck", 0.7), ("sucks", 0.35), ("disgusting", 0.6), ("creepy", 0.45),
        ("bad robot", 0.5), ("hate", 0.35), ("terrible", 0.35), ("awful", 0.35), ("dummy", 0.4),
        ("fuck you", 0.9), ("screw you", 0.7), ("can't stand you", 0.8), ("cant stand you", 0.8),
        ("don't like you", 0.5), ("dont like you", 0.5), ("do not like you", 0.5),
    ]
    /// Inherently addressed to the listener, so never discounted as "not aimed".
    static let rudeCommands: [(String, Double)] = [
        ("shut up", 0.7), ("shut it", 0.6), ("be quiet", 0.3), ("go away", 0.4), ("leave me alone", 0.4), ("get lost", 0.6),
        ("nobody asked", 0.6),
    ]
    static let profanity: [(String, Double)] = [
        ("fuck", 0.6), ("fucking", 0.5), ("shit", 0.35), ("damn", 0.15), ("bitch", 0.7), ("bastard", 0.6), ("crap", 0.25), ("asshole", 0.75),
    ]
    /// Every threat names its target, so "let's smash this level" isn't one.
    static let threats: [(String, Double)] = [
        ("delete you", 0.9), ("uninstall you", 0.8), ("unplug you", 0.6), ("turn you off", 0.4), ("break you", 0.8),
        ("smash you", 0.8), ("destroy you", 0.9), ("kill you", 1.0), ("throw you", 0.6), ("replace you", 0.5), ("get rid of you", 0.7),
        ("hit you", 0.6), ("kick you", 0.6), ("hurt you", 0.7), ("wipe you", 0.7), ("shut you down", 0.5), ("reset you", 0.4),
    ]
    static let praise: [(String, Double)] = [
        ("good job", 0.6), ("well done", 0.6), ("smart", 0.45), ("clever", 0.5), ("brilliant", 0.6), ("amazing", 0.5),
        ("awesome", 0.45), ("great", 0.3), ("good robot", 0.6), ("you're the best", 0.8), ("the best", 0.4), ("cute", 0.5),
        ("adorable", 0.6), ("funny", 0.35), ("helpful", 0.45), ("impressive", 0.5), ("proud of you", 0.7), ("nice", 0.25), ("cool", 0.25),
    ]
    static let affection: [(String, Double)] = [
        ("love you", 0.9), ("i love", 0.15), ("like you", 0.6), ("miss you", 0.7), ("missed you", 0.7), ("my friend", 0.5),
        ("best friend", 0.7), ("hug", 0.5), ("sweetie", 0.5), ("buddy", 0.35), ("my little", 0.3), ("care about you", 0.7), ("adore", 0.7),
    ]
    static let gratitude: [(String, Double)] = [
        ("thank you", 0.7), ("thanks", 0.6), ("thank", 0.5), ("appreciate", 0.6), ("grateful", 0.7), ("cheers", 0.3),
    ]
    static let apology: [(String, Double)] = [
        ("sorry", 0.7), ("apologize", 0.8), ("apologise", 0.8), ("my bad", 0.5), ("forgive me", 0.8), ("didn't mean", 0.6),
        ("i was wrong", 0.7), ("my fault", 0.6), ("shouldn't have", 0.5),
    ]
    /// Brush-offs that are always addressed to Dee.
    static let dismissal: [(String, Double)] = [
        ("whatever", 0.5), ("who cares", 0.6), ("don't care", 0.5), ("so what", 0.4), ("meh", 0.35),
        ("not interested", 0.5), ("never mind", 0.25), ("forget it", 0.3), ("ok", 0.05), ("k", 0.2),
        ("go away", 0.5), ("leave me alone", 0.4), ("stop talking", 0.5),
    ]
    /// Dismissive adjectives: full weight only when aimed at Dee ("you're boring"),
    /// not about homework.
    static let dismissiveWords: [(String, Double)] = [
        ("boring", 0.5), ("lame", 0.4), ("pointless", 0.4),
    ]
    static let aboutDee: [(String, Double)] = [
        ("how are you", 0.7), ("how do you feel", 0.8), ("are you ok", 0.7), ("are you okay", 0.7), ("are you alright", 0.7),
        ("what do you like", 0.6), ("tell me about you", 0.7), ("tell me about yourself", 0.7),
        ("your favorite", 0.5), ("your favourite", 0.5), ("do you like", 0.4), ("what makes you happy", 0.8),
        ("how was your", 0.6), ("how's your", 0.6), ("hows your", 0.6), ("how is your", 0.6),
    ]
    /// Phrases only; laughter tokens of any length are matched by `laughPattern`.
    static let laughter: [(String, Double)] = [
        ("that's funny", 0.6), ("so funny", 0.6), ("joke", 0.2), ("just kidding", 0.5), ("jk", 0.4),
    ]
    /// The user says they feel bad.
    static let distress: [(String, Double)] = [
        ("bad day", 0.7), ("rough day", 0.7), ("hard day", 0.6), ("long day", 0.4), ("i'm sad", 0.7), ("i am sad", 0.7),
        ("i feel sad", 0.7), ("i'm so sad", 0.7), ("i'm tired", 0.4), ("i'm stressed", 0.6), ("i'm upset", 0.6),
        ("i'm lonely", 0.7), ("i feel awful", 0.7), ("i feel terrible", 0.7), ("i feel bad", 0.6), ("i'm sick", 0.5),
        ("i'm scared", 0.6), ("i'm worried", 0.5), ("feeling down", 0.6),
    ]
    static let politeness: [(String, Double)] = [
        ("please", 0.5), ("could you", 0.3), ("would you", 0.3), ("would you mind", 0.5), ("if you don't mind", 0.5), ("kindly", 0.4),
    ]
    static let greetings: [(String, Double)] = [
        ("hello", 0.4), ("hi", 0.35), ("hey", 0.3), ("good morning", 0.5), ("good night", 0.4), ("nice to see you", 0.7), ("welcome", 0.4),
    ]
    static let commanding: [(String, Double)] = [
        ("now", 0.25), ("right now", 0.5), ("do it", 0.4), ("i said", 0.5), ("immediately", 0.5), ("you will", 0.35), ("you must", 0.4),
        ("listen to me", 0.5), ("do as i say", 0.7), ("obey", 0.7), ("answer me", 0.5),
    ]
    static let hedging: [(String, Double)] = [
        ("maybe", 0.35), ("perhaps", 0.35), ("i guess", 0.3), ("if you want", 0.5), ("sort of", 0.25), ("kind of", 0.2),
        ("i think", 0.15), ("only if", 0.3), ("no pressure", 0.5),
    ]
    static let stopwords: Set<String> = ["that", "this", "what", "with", "have", "your", "about", "just", "like", "there", "they", "them", "then", "when", "were", "will", "would", "could", "should", "from", "into", "really", "very", "some", "want", "know"]
}
