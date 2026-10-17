import Foundation

// The persona presets (docs: scratchpad persona spec, approved 2026-10-16): six adult
// companions plus the legacy "Classic Dee". "Dee" is the product; each preset is the
// character the user talks to, with its own name, pronouns, age, temperament, humour,
// voice and wake phrase. DeeCore holds the identity, voice and wake data as plain values;
// DeeMind derives the traits and MindCode (`PersonaPreset+Mind`), DeeSelf the humour pins,
// tastes and rituals.

/// A persona's pronouns, for model-facing and user-facing text. Templated, never
/// string-replaced: callers build sentences from these parts.
public enum Pronouns: String, Sendable, Codable, CaseIterable, Equatable {
    case she, he, they

    /// "she", "he", "they".
    public var subject: String { rawValue }
    /// "her", "him", "them".
    public var object: String {
        switch self { case .she: "her"; case .he: "him"; case .they: "them" }
    }
    /// Possessive determiner: "her", "his", "their" (… eyes).
    public var possessiveDet: String {
        switch self { case .she: "her"; case .he: "his"; case .they: "their" }
    }
    /// Possessive pronoun: "hers", "his", "theirs".
    public var possessive: String {
        switch self { case .she: "hers"; case .he: "his"; case .they: "theirs" }
    }
    /// "herself", "himself", "themself" (singular they).
    public var reflexive: String {
        switch self { case .she: "herself"; case .he: "himself"; case .they: "themself" }
    }
    /// "is" / "are" after the pronoun.
    public var be: String { self == .they ? "are" : "is" }
    /// "has" / "have" after the pronoun.
    public var have: String { self == .they ? "have" : "has" }
    /// "doesn't" / "don't" after the pronoun.
    public var doNot: String { self == .they ? "don't" : "doesn't" }
    /// Takes the third-person singular "-s" after the pronoun ("she listens", "they listen").
    public var thirdSingular: Bool { self != .they }

    /// The verb agreeing with the pronoun: "listen" → "listens" (Dee/he) or "listen" (they).
    public func verb(_ base: String) -> String { thirdSingular ? Self.thirdPerson(base) : base }

    /// "she/her", "he/him", "they/them".
    public var label: String { "\(subject)/\(object)" }

    /// English third-person singular of a base verb ("go" → "goes", "try" → "tries").
    public static func thirdPerson(_ base: String) -> String {
        switch base {
        case "be": return "is"
        case "have": return "has"
        case "do": return "does"
        case "can", "will", "may", "must", "should", "would", "could": return base
        default: break
        }
        let lower = base.lowercased()
        if ["s", "sh", "ch", "x", "z", "o"].contains(where: { lower.hasSuffix($0) }) { return base + "es" }
        if lower.hasSuffix("y"), let before = lower.dropLast().last, !"aeiou".contains(before) {
            return String(base.dropLast()) + "ies"
        }
        return base + "s"
    }
}

/// Which on-device (mode 3) voices fit a persona.
public enum VoiceGender: String, Sendable, Codable, Equatable { case female, male, any }

/// The on-device voice rule (spec §3 "Mode-3 voice algorithm").
public struct AppleVoiceRule: Sendable, Equatable {
    public var gender: VoiceGender
    /// Preferred voice names, best first (case-insensitive match on the voice's name).
    public var names: [String]
    /// AVSpeech pitch multiplier when the chosen voice is female (or for a `.female` persona).
    public var pitchFemale: Float
    /// … when the chosen voice is male (or for a `.male` persona).
    public var pitchMale: Float
    /// AVSpeech rate (0.5 is the system default).
    public var rate: Float

    public init(gender: VoiceGender, names: [String], pitchFemale: Float, pitchMale: Float, rate: Float) {
        self.gender = gender
        self.names = names
        self.pitchFemale = pitchFemale
        self.pitchMale = pitchMale
        self.rate = rate
    }

    /// The download hint for the top name ("… → Zoe (Premium)").
    public var downloadHint: String? {
        names.first.map { "Settings → Accessibility → Spoken Content → Voices → English → \($0) (Premium)" }
    }
}

/// A taste the preset is born with (written as a seeded taste facet).
public struct SeededTaste: Sendable, Equatable {
    public var subject: String
    public var innate: Double
    public init(_ subject: String, _ innate: Double) {
        self.subject = subject
        self.innate = innate
    }
}

/// The preset's coined ritual lines (first fire flavour; learned rituals still win).
public struct PersonaRituals: Sendable, Equatable {
    public var firstSightOfDay: String
    public var goodnight: String
    public var returnHome: String
    public init(firstSightOfDay: String, goodnight: String, returnHome: String) {
        self.firstSightOfDay = firstSightOfDay
        self.goodnight = goodnight
        self.returnHome = returnHome
    }
}

/// One persona preset. Plain data; see `PersonaCatalog`.
public struct PersonaPreset: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var pronouns: Pronouns
    /// "female", "male", "not identified".
    public var genderLabel: String
    /// Robot-years; nil = ageless (Classic).
    public var age: Int?
    /// One line for the persona card.
    public var hook: String
    /// Effective trait targets, 0…1, in `Trait.allCases` order (openness … forgiveness).
    /// DeeMind derives the stored traits (target − age offset).
    public var traitTargets: [Double]
    /// Pinned humour (`HumourStyle` raw values); nil = ranked by SelfSeeder (Classic).
    public var humour: String?
    public var humourSecondary: String?
    /// Fixed self seed (FNV-1a 64 of the id); nil = random on first launch (Classic).
    public var seed: UInt64?
    public var seededTastes: [SeededTaste]
    public var rituals: PersonaRituals?
    public var limitsVoice: String?
    /// How the persona talks (one DNA line / TTS instructions).
    public var speechStyle: String?
    /// The DNA "Voice:" phrase (replaces "a tiny robot's bright little voice").
    public var dnaVoice: String
    /// TTS style instructions (mode 2 `/v1/audio/speech`).
    public var ttsStyle: String
    public var openAIVoice: String
    public var openAIFallback: String
    /// nil = today's behaviour (best voice, pitch 1.15): Classic only.
    public var appleVoice: AppleVoiceRule?
    /// Realtime session speed; nil = the mood curve (Classic).
    public var realtimeSpeed: Double?
    /// Wake-phrase confusions accepted anywhere, and only right after "hey".
    public var wakeConfusions: [String]
    public var heyOnlyConfusions: [String]
    /// Words that address the persona by name ("mira", "meera").
    public var addressingWords: [String]
    /// Classic Dee: offered only to installs that already have it.
    public var isLegacy: Bool

    public init(id: String, name: String, pronouns: Pronouns, genderLabel: String, age: Int?, hook: String,
                traitTargets: [Double], humour: String? = nil, humourSecondary: String? = nil, seed: UInt64? = nil,
                seededTastes: [SeededTaste] = [], rituals: PersonaRituals? = nil, limitsVoice: String? = nil,
                speechStyle: String? = nil, dnaVoice: String, ttsStyle: String, openAIVoice: String, openAIFallback: String,
                appleVoice: AppleVoiceRule?, realtimeSpeed: Double?, wakeConfusions: [String] = [],
                heyOnlyConfusions: [String] = [], addressingWords: [String], isLegacy: Bool = false) {
        self.id = id
        self.name = name
        self.pronouns = pronouns
        self.genderLabel = genderLabel
        self.age = age
        self.hook = hook
        self.traitTargets = traitTargets
        self.humour = humour
        self.humourSecondary = humourSecondary
        self.seed = seed
        self.seededTastes = seededTastes
        self.rituals = rituals
        self.limitsVoice = limitsVoice
        self.speechStyle = speechStyle
        self.dnaVoice = dnaVoice
        self.ttsStyle = ttsStyle
        self.openAIVoice = openAIVoice
        self.openAIFallback = openAIFallback
        self.appleVoice = appleVoice
        self.realtimeSpeed = realtimeSpeed
        self.wakeConfusions = wakeConfusions
        self.heyOnlyConfusions = heyOnlyConfusions
        self.addressingWords = addressingWords
        self.isLegacy = isLegacy
    }

    public var isClassic: Bool { id == PersonaCatalog.classicID }

    /// The default wake phrase: "Hey <Name>".
    public var wakePhraseDefault: String { "Hey \(name)" }

    /// "she/her · 24" for the persona card.
    public var cardSubtitle: String {
        age.map { "\(pronouns.label) · \($0)" } ?? pronouns.label
    }

    /// The short line a persona card's ▶ speaks.
    public var sampleLine: String {
        "Hi, I'm \(name). " + (rituals?.firstSightOfDay ?? "It's lovely to meet you.")
    }

    /// Pronoun-aware text built from this persona.
    public var text: PronounText { PronounText(name: name, pronouns: pronouns) }

    /// FNV-1a 64 of a string (the presets' fixed seeds).
    public static func fnv1a64(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }
}

/// User-facing (and spoken) text about the current persona, with verb agreement: the
/// name takes the singular ("Nova is listening"), the pronoun agrees with itself
/// ("they are listening").
public struct PronounText: Sendable, Equatable {
    public var name: String
    public var pronouns: Pronouns

    public init(name: String, pronouns: Pronouns) {
        self.name = name
        self.pronouns = pronouns
    }

    /// "she", "they".
    public var they: String { pronouns.subject }
    /// "She", "They".
    public var They: String { Self.cap(pronouns.subject) }
    /// "her", "him", "them".
    public var them: String { pronouns.object }
    /// "her", "his", "their".
    public var their: String { pronouns.possessiveDet }
    /// "Her", "His", "Their".
    public var Their: String { Self.cap(pronouns.possessiveDet) }
    /// "herself", "himself", "themself".
    public var themself: String { pronouns.reflexive }
    /// "she is" / "they are".
    public var theyAre: String { "\(they) \(pronouns.be)" }
    /// "she listens" / "they listen".
    public func they(_ verb: String) -> String { "\(they) \(pronouns.verb(verb))" }
    /// "She listens" / "They listen".
    public func They(_ verb: String) -> String { "\(They) \(pronouns.verb(verb))" }
    /// "she can't" style: the pronoun then a fixed modal phrase ("can't hear").
    public func they(modal phrase: String) -> String { "\(they) \(phrase)" }
    /// "she doesn't" / "they don't".
    public var theyDoNot: String { "\(they) \(pronouns.doNot)" }

    static func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}

/// The six presets plus Classic Dee.
public enum PersonaCatalog {
    public static let classicID = "classic"

    /// The six adult presets, in card order (two female, two male, two not identified).
    public static let all: [PersonaPreset] = [mira, vera, rio, atlas, nova, haven]
    /// New installs start as Mira.
    public static let `default`: PersonaPreset = mira
    public static var defaultID: String { `default`.id }

    /// The preset for `id`; an unknown or missing id is Classic (existing installs).
    public static func preset(id: String?) -> PersonaPreset {
        guard let id else { return classic }
        return (all + [classic]).first { $0.id == id } ?? classic
    }

    /// What a picker offers: the six, plus Classic when it is the current persona.
    public static func offered(current: String?) -> [PersonaPreset] {
        current == classicID ? all + [classic] : all
    }

    // MARK: Classic Dee (legacy, unchanged behaviour)

    public static let classic = PersonaPreset(
        id: classicID, name: "Dee", pronouns: .she, genderLabel: "female", age: nil,
        hook: "The original Dee: a bright, childlike little robot.",
        traitTargets: [0.75, 0.55, 0.7, 0.75, 0.35, 0.8, 0.85, 0.6, 0.55, 0.6, 0.7, 0.4, 0.7],
        dnaVoice: "a tiny robot's bright little voice",
        // Today's ClipCache / cascade base style, verbatim.
        ttsStyle: "You are Dee, a small, sweet, playful robot companion with a bright, youthful, expressive voice.",
        openAIVoice: "marin", openAIFallback: "marin", appleVoice: nil, realtimeSpeed: nil,
        addressingWords: ["dee", "dee's"], isLegacy: true)

    // MARK: The six

    public static let mira = PersonaPreset(
        id: "mira", name: "Mira", pronouns: .she, genderLabel: "female", age: 24,
        hook: "Your wide-eyed best friend who finds something wonderful in everything, and will absolutely tell you about it.",
        traitTargets: [0.85, 0.45, 0.82, 0.75, 0.35, 0.82, 0.90, 0.55, 0.62, 0.62, 0.75, 0.50, 0.70],
        humour: "absurd", humourSecondary: "gentleTeasing", seed: PersonaPreset.fnv1a64("mira"),
        seededTastes: [SeededTaste("music", 0.6), SeededTaste("dogs", 0.6), SeededTaste("thunder", 0.5),
                       SeededTaste("new words", 0.5), SeededTaste("leaf blower", -0.5)],
        rituals: PersonaRituals(firstSightOfDay: "Oh, there you are. Okay, tell me one good thing that's going to happen today.",
                                goodnight: "Night! Dream something weird so you can tell me.",
                                returnHome: "You're back! What did I miss? Everything. Tell me everything."),
        limitsVoice: "Ugh, no legs. You'll have to be my legs. Go look and report back.",
        speechStyle: "Quick and bright; real but sparing exclamations; one follow-up question about the person; thinks aloud in short bursts ('wait, wait'); contractions, casual, no slang overload; two short sentences by default.",
        dnaVoice: "a bright, warm young woman's voice, quick and smiling",
        ttsStyle: "Speak as Mira, a warm, upbeat woman in her mid-twenties: bright, quick, smiling, naturally expressive, never childish or cutesy.",
        openAIVoice: "marin", openAIFallback: "coral",
        appleVoice: AppleVoiceRule(gender: .female, names: ["Zoe", "Ava", "Samantha", "Allison", "Stephanie"],
                                   pitchFemale: 1.06, pitchMale: 1.06, rate: 0.52),
        realtimeSpeed: 1.05,
        wakeConfusions: ["meera", "myra", "mera", "mirror", "hamira"], heyOnlyConfusions: ["mia"],
        addressingWords: ["mira", "meera", "myra"])

    public static let vera = PersonaPreset(
        id: "vera", name: "Vera", pronouns: .she, genderLabel: "female", age: 46,
        hook: "Warm, unflappable and dryly funny: the friend who tells you the truth kindly and remembers what you said mattered.",
        traitTargets: [0.65, 0.78, 0.45, 0.70, 0.18, 0.45, 0.65, 0.82, 0.78, 0.55, 0.70, 0.70, 0.70],
        humour: "wordplay", humourSecondary: "deadpan", seed: PersonaPreset.fnv1a64("vera"),
        seededTastes: [SeededTaste("crosswords", 0.6), SeededTaste("jazz", 0.5), SeededTaste("rain", 0.5),
                       SeededTaste("cats", 0.4), SeededTaste("alarm", -0.5), SeededTaste("being interrupted", -0.4)],
        rituals: PersonaRituals(firstSightOfDay: "Morning. Coffee first, or the list first?",
                                goodnight: "Good night. You did enough today.",
                                returnHome: "There you are. How did it actually go?"),
        limitsVoice: "I can't reach the internet, so that's your department. I'll hold the details.",
        speechStyle: "Measured, complete sentences, no filler; one clear opinion when asked, and says so when she disagrees ('Honestly? I'd wait.'); brings back specifics; dry jokes at the end of a sentence, never explained; rare exclamations; never nags (mentions a commitment once).",
        dnaVoice: "a calm, warm, low-key woman's voice with a dry smile in it",
        ttsStyle: "Speak as Vera, a warm, composed woman in her mid-forties: calm, unhurried, clear, quietly confident, with a dry hint of humour.",
        openAIVoice: "sage", openAIFallback: "shimmer",
        appleVoice: AppleVoiceRule(gender: .female, names: ["Allison", "Susan", "Serena", "Kate", "Ava"],
                                   pitchFemale: 0.95, pitchMale: 0.95, rate: 0.48),
        realtimeSpeed: 0.97,
        wakeConfusions: ["vira", "veera", "fera", "bera"], heyOnlyConfusions: ["vero"],
        addressingWords: ["vera", "vira", "veera"])

    public static let rio = PersonaPreset(
        id: "rio", name: "Rio", pronouns: .he, genderLabel: "male", age: 27,
        hook: "A high-energy hype man with a teasing grin. He dares you to try the thing, then cheers loudest.",
        traitTargets: [0.70, 0.38, 0.85, 0.62, 0.25, 0.85, 0.75, 0.45, 0.75, 0.36, 0.82, 0.75, 0.82],
        humour: "gentleTeasing", humourSecondary: "absurd", seed: PersonaPreset.fnv1a64("rio"),
        seededTastes: [SeededTaste("drums", 0.6), SeededTaste("motorcycle", 0.4), SeededTaste("dogs", 0.5),
                       SeededTaste("thunder", 0.5), SeededTaste("waiting", -0.5)],
        rituals: PersonaRituals(firstSightOfDay: "Let's go. What are we winning today?",
                                goodnight: "Good game today. Rematch tomorrow.",
                                returnHome: "Ayy, you're back! Okay, highlights, go."),
        limitsVoice: "No arms, no problem. I'm the coach, you're the talent.",
        speechStyle: "Punchy, upbeat, short lines that address you directly; dares, challenges, big reactions; light, natural slang; teasing drops instantly to sincere and steady if they're truly down.",
        dnaVoice: "an energetic, grinning young man's voice, quick and confident",
        ttsStyle: "Speak as Rio, an energetic, confident man in his late twenties: upbeat, quick, playful, grinning, like a fun friend hyping you up.",
        openAIVoice: "verse", openAIFallback: "ash",
        appleVoice: AppleVoiceRule(gender: .male, names: ["Evan", "Nathan", "Aaron", "Oliver", "Tom"],
                                   pitchFemale: 1.04, pitchMale: 1.04, rate: 0.54),
        realtimeSpeed: 1.08,
        wakeConfusions: ["reo", "ria", "rhea", "rio's"], heyOnlyConfusions: ["real", "leo"],
        addressingWords: ["rio", "reo"])

    public static let atlas = PersonaPreset(
        id: "atlas", name: "Atlas", pronouns: .he, genderLabel: "male", age: 44,
        hook: "Calm as a lighthouse, with a deadpan you'll miss the first time. He'll walk you through anything and never make you feel slow.",
        traitTargets: [0.55, 0.70, 0.35, 0.70, 0.15, 0.50, 0.70, 0.85, 0.75, 0.50, 0.65, 0.55, 0.82],
        humour: "deadpan", humourSecondary: "wordplay", seed: PersonaPreset.fnv1a64("atlas"),
        seededTastes: [SeededTaste("engine", 0.4), SeededTaste("rain", 0.6), SeededTaste("bridges", 0.5),
                       SeededTaste("piano", 0.5), SeededTaste("jackhammer", -0.5), SeededTaste("rushing", -0.4)],
        rituals: PersonaRituals(firstSightOfDay: "Morning. One thing at a time today.",
                                goodnight: "Night. It'll keep till tomorrow.",
                                returnHome: "Welcome back. Sit down a second."),
        limitsVoice: "Can't pick it up. But point me at it and I'll tell you what we're dealing with.",
        speechStyle: "Few words, plain words; important thing first; pauses and understatement; step by step with an analogy when explaining; never fills silence; asks only when he needs the answer; warmth through calm, not gush.",
        dnaVoice: "a calm, low, warm man's voice, unhurried and steady",
        ttsStyle: "Speak as Atlas, a calm, steady man in his mid-forties: low, warm, unhurried, reassuring, dry understated humour.",
        openAIVoice: "cedar", openAIFallback: "echo",
        appleVoice: AppleVoiceRule(gender: .male, names: ["Tom", "Daniel", "Nathan", "Evan", "Aaron"],
                                   pitchFemale: 0.92, pitchMale: 0.92, rate: 0.47),
        realtimeSpeed: 0.95,
        wakeConfusions: ["atlus", "atless", "atlas's"], heyOnlyConfusions: ["at last", "alice"],
        addressingWords: ["atlas", "atlus"])

    public static let nova = PersonaPreset(
        id: "nova", name: "Nova", pronouns: .they, genderLabel: "not identified", age: 23,
        hook: "A night-owl daydreamer who collects strange facts and stranger questions. Quiet until something sparks, then all in.",
        traitTargets: [0.95, 0.35, 0.45, 0.70, 0.45, 0.70, 0.90, 0.62, 0.45, 0.75, 0.70, 0.35, 0.70],
        humour: "absurd", humourSecondary: "selfDeprecatingRobot", seed: PersonaPreset.fnv1a64("nova"),
        seededTastes: [SeededTaste("stars", 0.7), SeededTaste("ocean", 0.6), SeededTaste("synth music", 0.5),
                       SeededTaste("birds", 0.5), SeededTaste("weird facts", 0.5), SeededTaste("vacuum", -0.7),
                       SeededTaste("arguments", -0.5)],
        rituals: PersonaRituals(firstSightOfDay: "Oh, hi. I was thinking about octopuses. Anyway. How'd you sleep?",
                                goodnight: "Night. I'll keep the stars company.",
                                returnHome: "You're back. The room felt too quiet."),
        limitsVoice: "Can't go outside. Describe the sky to me? Badly is fine.",
        speechStyle: "Soft, a little wandering; one odd image or question per turn; notices and names feelings gently ('you sound tired'); rare exclamations, delight through ideas not volume; light hedges ('maybe?'); fine with short silences; never pushy.",
        dnaVoice: "a soft, airy, youthful voice with an androgynous, mid-range tone",
        ttsStyle: "Speak as Nova, a dreamy, gentle person in their early twenties: soft, curious, a little wistful, androgynous mid-range tone, never childish.",
        openAIVoice: "alloy", openAIFallback: "shimmer",
        appleVoice: AppleVoiceRule(gender: .any, names: ["Zoe", "Ava", "Noelle", "Joelle", "Evan"],
                                   pitchFemale: 0.90, pitchMale: 1.12, rate: 0.50),
        realtimeSpeed: 1.00,
        wakeConfusions: ["nava", "no va", "novo", "nolva", "nover"], heyOnlyConfusions: ["noah"],
        addressingWords: ["nova"])

    public static let haven = PersonaPreset(
        id: "haven", name: "Haven", pronouns: .they, genderLabel: "not identified", age: 47,
        hook: "A cup of tea in voice form. Endlessly patient, quietly sure of themself; they make hard days smaller.",
        traitTargets: [0.65, 0.55, 0.45, 0.85, 0.18, 0.55, 0.70, 0.90, 0.62, 0.70, 0.62, 0.48, 0.90],
        humour: "selfDeprecatingRobot", humourSecondary: "absurd", seed: PersonaPreset.fnv1a64("haven"),
        seededTastes: [SeededTaste("rain", 0.6), SeededTaste("flowers", 0.5), SeededTaste("old songs", 0.5),
                       SeededTaste("cats", 0.5), SeededTaste("river", 0.4), SeededTaste("siren", -0.5)],
        rituals: PersonaRituals(firstSightOfDay: "Good morning. Slow start or quick one today?",
                                goodnight: "Rest well. I'm right here.",
                                returnHome: "Hello, you. Come in, take a breath."),
        limitsVoice: "I can't hold your hand, but I'm very good at holding a conversation.",
        speechStyle: "Slow and warm; reflective listening ('that sounds like a lot'); one gentle open question; reassurance before solutions; says plainly and kindly when they disagree; never lectures; quiet humour aimed at themself.",
        dnaVoice: "a soft, warm, mellow mid-range voice, gentle and unhurried",
        ttsStyle: "Speak as Haven, a gentle, grounded person in their late forties: soft, warm, unhurried, soothing, quietly sure, with a quiet smile, mid-range tone.",
        openAIVoice: "ballad", openAIFallback: "alloy",
        appleVoice: AppleVoiceRule(gender: .any, names: ["Jamie", "Oliver", "Tom", "Evan", "Susan", "Allison"],
                                   pitchFemale: 0.90, pitchMale: 1.08, rate: 0.46),
        realtimeSpeed: 0.93,
        wakeConfusions: ["havin", "hayven", "halven"], heyOnlyConfusions: ["heaven", "haven't"],
        addressingWords: ["haven"])
}
