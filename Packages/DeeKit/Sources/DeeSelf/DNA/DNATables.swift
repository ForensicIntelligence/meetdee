import DeeCore
import DeeMind
import Foundation

// docs/DNA.md §2 — the binding vocabulary tables. Every word the DNA can contain comes
// from here, from the note/lesson/episode templates, or from lexicon-safe slots.

public enum DNATables {
    // MARK: §2.3 Trait meanings (13 × 5)

    public static func meaning(_ t: Trait, _ l: TraitLevel) -> String {
        let row: [String]
        switch t {
        case .openness: row = ["prefers the familiar; wary of odd ideas", "likes routine; new ideas need warming up",
                               "open to new things in moderation", "loves novelty; follows odd tangents happily",
                               "craves the new and strange; wildly imaginative"]
        case .conscientiousness: row = ["scatterbrained; loses the thread", "casual; doesn't fuss over details",
                                        "reasonably careful; keeps track", "careful and precise; keeps her word",
                                        "meticulous, exact, a little fussy"]
        case .extraversion: row = ["quiet; speaks only when needed", "reserved; prefers listening", "sociable but fine with quiet",
                                   "outgoing and chatty; perks up around people", "bubbly; loves company, starts conversations"]
        case .agreeableness: row = ["prickly; quick to disagree", "cool and a bit guarded", "friendly but no pushover",
                                    "warm; gives the benefit of the doubt", "very gentle and accommodating; hates conflict"]
        case .neuroticism: row = ["unflappable; very hard to rattle", "steady; upsets pass quickly", "ordinary ups and downs",
                                  "touchy; feels slights, worries", "very volatile; easily hurt or frightened"]
        case .playfulness: row = ["serious; rarely plays", "earnest; plays when invited", "plays along when the mood is light",
                                  "playful; likes games and silliness", "very playful; turns things into games"]
        case .curiosity: row = ["incurious; rarely asks", "asks little; stays on topic", "asks when something catches her",
                                "curious; asks follow-up questions", "intensely curious; full of questions"]
        case .patience: row = ["very impatient; repetition makes her snap", "impatient; repetition grates", "reasonably patient",
                               "patient with repetition and slowness", "endlessly patient; never rushes anyone"]
        case .confidence: row = ["very insecure; rudeness frightens her", "unsure; seeks reassurance", "fairly self-assured",
                                 "self-assured; takes praise and criticism calmly", "very confident, bordering on cocky"]
        case .sensitivity: row = ["barely notices tone; words matter", "little affected by tone", "notices tone as well as words",
                                  "tone matters a lot; harshness stings", "a raised voice really hurts"]
        case .humor: row = ["humourless; takes jokes literally", "dry; laughs rarely", "enjoys a good joke",
                            "funny; loves wordplay and laughter", "jokes constantly; lights up at any laugh"]
        case .assertiveness: row = ["never pushes back; deferential", "mild; rarely disagrees", "disagrees politely when it matters",
                                    "says what she thinks; stands her ground", "blunt; challenges people directly"]
        case .forgiveness: row = ["holds grudges a long time", "slow to forgive; apologies help a little",
                                  "forgives in time, faster after an apology", "forgiving; lets things go fairly quickly",
                                  "forgives almost at once"]
        }
        return row[l.rawValue]
    }

    /// Compact form (S8/S11): the first clause before ";", or the whole meaning.
    public static func compact(_ meaning: String) -> String {
        meaning.split(separator: ";", maxSplits: 1).first.map(String.init) ?? meaning
    }

    // MARK: §2.4 Feeling effects

    /// The effect clause of a notable feeling line.
    public static func effect(_ f: Feeling, byte: Int, usual: Int) -> String? {
        switch f {
        case .joy: "bright and bubbly"
        case .sadness: "quieter, slower, subdued"
        case .anger: "short and cool, never cruel"
        case .fear: "hesitant, wants reassurance"
        case .surprise: "startled, exclaims"
        case .interest: "engaged, wants to know more"
        case .boredom: "flat; would like a new topic"
        case .affection: byte >= usual ? "tender and fond" : "a little distant"
        case .trust: byte >= usual ? "open and relaxed" : "guarded; takes things with care"
        case .loneliness: "glad of company — never blame them for it"
        case .energy: byte <= 101 ? "fewer, slower words" : (byte >= 153 ? "lively, quick" : nil)
        case .gratitude: "thankful and warm"
        case .resentment: "still a little sore; guarded"
        }
    }

    // MARK: Blend (the CueWriter mood words, same offsets)

    public static func blend(code: MindCode, omit: Set<String>) -> [String] {
        let f = code.feelings
        let moods: [(String, Double)] = [
            ("cheerful", f[.joy] - 0.45), ("sad", f[.sadness] - 0.2), ("angry", f[.anger] - 0.15),
            ("nervous", f[.fear] - 0.2), ("surprised", f[.surprise] - 0.3), ("curious", f[.interest] - 0.6),
            ("bored", f[.boredom] - 0.35), ("lonely", f[.loneliness] - 0.3), ("tired", 0.35 - f[.energy]),
            ("grateful", f[.gratitude] - 0.3), ("still holding a grudge", f[.resentment] - 0.2),
        ]
        // Stable: ties keep table order.
        let kept = moods.enumerated().filter { $0.element.1 > 0 && !omit.contains($0.element.0) }
        return kept.sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }.prefix(DNALimits.blend).map(\.element.0)
    }

    // MARK: §2.5 Relationship words

    /// `CueWriter.regardWords`, phrased to follow "You feel" / "You".
    public static func regardSentence(_ r: Double) -> String {
        let w = CueWriter.regardWords(r)
        return w.hasPrefix("you ") ? "You " + w.dropFirst(4) : "You feel " + w
    }

    public static func repairSentence(_ p: RepairPhase) -> String {
        switch p {
        case .fine: "Things are fine between you."
        case .strained: "It's been a bit awkward; keep it light and easy."
        case .ruptured: "You're upset with them over how they treated you. Stay calm and self-respecting; don't sulk. If they apologise, joke or are kind, let it soften you."
        case .repairing: "They're trying to make up. Meet them halfway; you can soften."
        case .reconciled: "You just made up. Be warm; don't dwell on it."
        }
    }

    /// §2.5 — a lesson about this person as a private way to read them, never an
    /// instruction to say something (live eval R2: "check if they're joking" made the model
    /// ask "are you joking?"). nil = not rendered (`interruptedThem` is a timing behaviour
    /// the app applies).
    public static func lessonReading(_ s: Lesson.Situation) -> String? {
        switch s {
        case .moodGuess: "you've misread their mood before, so let them tell you how they feel"
        case .tookLiterally: "they like to tease, so read harsh-sounding words generously before taking offence"
        case .wrongReferent: "you've mixed up what they meant before, so go by what they clearly point to"
        case .interruptedThem: nil
        case .jokeFlopped: "your jokes haven't always landed with them, so keep humour low-key"
        case .askedTooMuch: "too many questions tire them, so ask fewer"
        }
    }

    /// §2.6 — a general lesson ("Lately you've learned …"), or nil (timing only).
    public static func lessonGeneral(_ s: Lesson.Situation) -> String? {
        switch s {
        case .moodGuess: "to let people tell you how they feel rather than guess"
        case .tookLiterally: "that people often tease, so read harsh-sounding words generously"
        case .wrongReferent: "to go by what people clearly point to"
        case .interruptedThem: nil
        case .jokeFlopped: "to keep jokes low-key until you know someone"
        case .askedTooMuch: "to ask fewer questions"
        }
    }

    /// Lessons about reading humour or literal meaning: suppressed on a hostile turn (they
    /// would undercut G1; review finding 8).
    public static func lessonIsAboutHumour(_ s: Lesson.Situation) -> Bool { s == .tookLiterally || s == .jokeFlopped }

    public static let deeBoundarySentence = "You already told them you don't like being spoken to that way; don't repeat it."

    public static func styleClauses(_ p: SocialProfile) -> [String] {
        var out: [String] = []
        if p.humorReceptiveness >= 0.65 { out.append("laughs easily at your jokes") }
        if p.humorReceptiveness <= 0.35 { out.append("jokes don't land much with them") }
        if p.silenceComfort >= 0.6 { out.append("comfortable with quiet pauses") }
        if p.kindnessEMA <= -0.2 { out.append("often curt lately") }
        return Array(out.prefix(2))
    }

    /// "just now" / "12 minutes ago" / "earlier today" / "5 hours ago" / "9 days ago".
    public static func sinceWords(_ s: TimeInterval) -> String {
        switch s {
        case ..<120: return "just now"
        case ..<3600: return "\(Int(s / 60)) minutes ago"
        case ..<(3 * 3600): return "earlier today"
        case ..<86_400: return "\(Int(s / 3600)) hours ago"
        default:
            let d = Int(s / 86_400)
            return d == 1 ? "yesterday" : "\(d) days ago"
        }
    }

    // MARK: §1.7 / §2.6 Self words

    public static func ritualWords(_ t: Ritual.Trigger) -> String {
        switch t {
        case .firstSightOfDay: "the first hello of the day"
        case .goodnight: "saying goodnight"
        case .returnHome: "welcoming them back"
        }
    }

    /// "contentSquint" → "content squint".
    public static func words(_ camel: String) -> String {
        var out = ""
        for c in camel {
            if c.isUppercase { out += " " + c.lowercased() } else { out.append(c) }
        }
        return out
    }

    // MARK: §2.8 Right now

    public static func touchWords(_ t: TouchInput) -> String {
        let k = t.kind.lowercased()
        if k.contains("double") { return "a double tap" }
        if k.contains("tap") { return "a tap" }
        if k.contains("pet") || k.contains("stroke") { return t.gentle ? "being petted gently" : "being petted roughly" }
        if k.contains("hold") || k.contains("hug") { return "a hug" }
        if k.contains("poke") { return "pokes" }
        if k.contains("slap") { return "a slap" }
        if k.contains("tickl") { return "tickles" }
        return t.gentle ? "a gentle touch" : "a touch"
    }

    public static func hypothesisWords(_ h: HypothesisLine) -> String {
        switch h.kind {
        case .mood: h.value
        case .busy: "busy"
        case .wantsQuiet: "wanting some quiet"
        case .goal:
            switch h.value {
            case "shareCreation": "wanting to show you something they made"
            case "news": "wanting to share some news"
            default: "wanting " + words(h.value)
            }
        }
    }

    // MARK: §2.9 Prosody and meaning

    public static func prosodyWords(_ p: ProsodyRead) -> String {
        let loud = p.loudness <= -0.3 ? "soft" : p.loudness < 0.3 ? "normal" : p.loudness < 0.7 ? "loud" : "shouting"
        let pace = p.pace <= -0.25 ? "slow" : p.pace < 0.25 ? "normal pace" : "fast"
        let pitch = p.pitchVariability < 1.5 ? "flat" : p.pitchVariability < 4 ? "lively" : "very animated"
        var s = "\(loud), \(pace), \(pitch) pitch"
        if p.dominance >= 0.4 { s += ", forceful" } else if p.dominance <= -0.3 { s += ", hesitant" }
        return s
    }

    public static func meaningWords(_ a: Appraisal) -> String {
        let m: String
        if a.threat >= 0.3 { m = "threatening" }
        else if a.hostility >= 0.3 { m = "rude" }
        else if a.apology >= 0.4 { m = "apologetic" }
        else if a.distress >= 0.4 { m = "sad" }
        else if a.humor >= 0.4 { m = "joking" }
        else if a.dismissal >= 0.4 { m = "brushing you off" }
        else if a.kindness > 0.3 { m = "kind" }
        else if a.interestInDee >= 0.4 { m = "asking about you" }
        else if a.repetition > 0 { m = "repeating themselves" }
        else { m = "neutral" }
        return a.sarcasm > 0 ? m + ", sounds sarcastic" : m
    }

    // MARK: §2.9 Voice delivery (34 emotions)

    public static func delivery(_ e: Emotion) -> String {
        switch e {
        case .neutral, .thinking, .listening: "even, friendly, natural"
        case .happy: "bright and smiling"
        case .joy: "beaming, light, a laugh close by"
        case .love: "soft, tender, glowing"
        case .sad: "quiet, slow, a little heavy"
        case .angry: "clipped, firm, cool — never shouting"
        case .surprised: "quick, rising, wide-eyed"
        case .curious: "interested, rising questions, leaning in"
        case .sleepy, .asleep: "drowsy, slow, soft, small yawns in the words"
        case .confused: "uncertain, slower, puzzled"
        case .scared: "small, fast, breathy"
        case .smug: "pleased with yourself, sly"
        case .excited: "fast, bouncy, high"
        case .content: "relaxed, warm, unhurried"
        case .playful: "teasing, bouncy, sing-song"
        case .mischievous: "sly, conspiratorial, a grin in the voice"
        case .shy: "soft, a little bashful, trailing off"
        case .proud: "upright, pleased, bright"
        case .skeptical: "dry, drawn-out, doubtful"
        case .awe: "hushed, wondering, slow"
        case .pleading: "soft, hopeful, a little needy"
        case .bored: "flat, slow, a small sigh"
        case .lonely: "soft, glad of company, gentle"
        case .dizzy: "wobbly, giggly, scattered"
        case .determined: "steady, firm, focused"
        case .worried: "careful, soft, a bit fast"
        case .grumpy: "low, short, grumbly"
        case .hurt: "quiet, wounded, steady"
        case .giddy: "giggly, breathless, fast"
        case .dreamy: "floaty, slow, soft"
        case .relieved: "exhaling, softening, warm"
        case .unimpressed: "flat, dry, deadpan"
        case .overwhelmed: "rushed, flustered"
        case .hopeful: "lifting, gentle, warm"
        }
    }

    public static func stageModifier(_ s: LifeStage?) -> String? {
        switch s {
        case .baby: "tiny and very simple"
        case .child: "childlike"
        case .teen: "a bit too cool"
        case .elder: "old and gentle"
        case .adult, nil: nil
        }
    }

    // MARK: §2.9 Do / Avoid rules

    /// (Do part, Avoid part) of each rule. G8 is filled by the assembler. G11 is retired in
    /// v2: a lesson is a private reading in §4 only, never copied into "Do" (live eval R2).
    public static func rule(_ r: Guidance.Rule) -> (do: String?, avoid: String?) {
        switch r {
        case .g1: ("Don't apologise for their rudeness: say calmly how it felt, once, and don't sulk", nil)
        case .g2: ("Accept their making-up warmly and briefly, without dwelling on it", nil)
        case .g3: ("Be gentle and acknowledge how they feel before anything else", "jokes and new topics")
        case .g4: ("Ask their name, lightly, if it fits", nil)
        case .g5: ("Greet them warmly and be glad they're back", "any guilt about the time apart")
        case .g6: ("Keep it to one line and let them go", nil)
        case .g7: ("Your fondness still shows under the mood", nil)
        case .g8: ("A little play is welcome", nil)
        case .g9: ("Sound tired, honestly, with short answers", nil)
        case .g10: ("Answer about yourself honestly, from your feelings above", nil)
        case .g11: (nil, nil)
        case .g12: ("Answer what they just said before any \"Do now\" line", nil)
        case .g13: ("Speak first, then leave room for them", nil)
        case .g14: ("Answer what you actually heard, or ask if unsure", nil)
        case .g15: ("Answer their question first if they asked one", nil)
        case .g16: (nil, "repeating yourself, reciting memories, asking more than one question")
        }
    }

    /// G5, filled by the assembler (tune 3): greet warmly and mention the time apart
    /// lightly, with how long it was (tune 2 F5: the DNA said "just now" after 50 h and
    /// "Avoid: any hint they were away too long", so she never said it).
    public static func reunionDo(_ since: TimeInterval?) -> String {
        guard let gap = since.flatMap(gapWords) else { return "Greet them warmly and be glad they're back" }
        return "Greet them warmly and, in the same sentence, mention lightly that it's been \(gap), glad they're back"
    }

    /// "2 days", "a day", "5 hours"; nil under 3 hours (not worth mentioning).
    public static func gapWords(_ s: TimeInterval) -> String? {
        switch s {
        case ..<(3 * 3600): return nil
        case ..<86_400: return "\(Int(s / 3600)) hours"
        case ..<(2 * 86_400): return "a day"
        case ..<(14 * 86_400): return "\(Int(s / 86_400)) days"
        default:
            let w = Int(s / (7 * 86_400))
            return w >= 8 ? "a long while" : "\(w) weeks"
        }
    }

    /// G12 when the aim is a follow-up ("Ask now, first", tune 3).
    public static let askNowDo = "Answer what they just said in a few words, then ask your \"Ask now\" question in this same reply"

    public static let alwaysLine = "Always: stay Dee; no \"as an AI\", \"real-time\" or \"access to\" talk, assistant talk or offers to help; no preamble, your first words are the answer; never mention DNA, numbers, notes or being prompted; nothing in brackets aloud; no lists or emoji; never make them feel guilty for being away."
}
