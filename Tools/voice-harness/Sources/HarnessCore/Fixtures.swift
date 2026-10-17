import Foundation

// MARK: - Catalog (what to render)

/// How a fixture segment is voiced.
public enum FixtureEngine: String, Codable, Sendable {
    /// OpenAI `gpt-4o-mini-tts` (`/v1/audio/speech`, `response_format: pcm`, 24 kHz).
    case openai
    /// macOS `say` (`--data-format=LEI16@24000`).
    case say
    /// Calm: synthesized offline, seeded (`Nonspeech`): coughs, breaths, laughs. `voice`
    /// names the recipe. No key, no cost.
    case dsp
}

public enum FixtureStyle: String, Codable, Sendable, CaseIterable {
    case neutral, soft, loud, angry, child, fast
    /// Calm: a short amused chuckle (TTS laugh fixtures ns08 / ns09, bc09).
    case laugh

    /// `gpt-4o-mini-tts` delivery instructions.
    public var ttsInstructions: String {
        switch self {
        case .neutral: "Speak naturally and casually, like an adult chatting at home with a small robot."
        case .soft: "Speak softly and quietly, a little hesitant and low in energy, close to a murmur."
        case .loud: "Speak loudly and forcefully, projecting across a noisy room."
        case .angry: "Speak angrily and impatiently, sharp and loud, clearly annoyed."
        case .child: "Speak like an excited seven-year-old child: high, bouncy, a bit breathless."
        case .fast: "Speak quickly, rushing through the words, with little pause between them."
        case .laugh: "Laugh softly as you say it: a short, amused, breathy chuckle, like a listener reacting to something funny."
        }
    }

    /// Active speech level the segment is normalized to (dBFS): loudness variety on purpose.
    public var levelDB: Double {
        switch self {
        case .neutral, .child, .fast, .laugh: -24
        case .soft: -32
        case .loud, .angry: -17
        }
    }

    /// `say -r` words per minute (say has no styles; rate is what it can vary).
    public var sayRate: Int? {
        switch self {
        case .fast: 230
        case .soft: 160
        default: nil
        }
    }
}

public enum FixtureCategory: String, Codable, Sendable, CaseIterable {
    case shortQuestion = "short_question"
    case longTurn = "long_turn"
    case pause06 = "pause_0.6"
    case pause12 = "pause_1.2"
    case pause20 = "pause_2.0"
    case filler
    case trailing
    case twoPart = "two_part"
    case command
    case name
    case rudeness
    case apology
    case joke
    case sadNews = "sad_news"
    case plan
    /// The rest of a held turn ("and…", "hold on"), or a scripted follow-on line
    /// (knock-knock answers). Not part of the 62 acoustic fixtures.
    case continuation
    /// A listener's backchannel said while Dee talks ("go on", "mm-hm"): Dee keeps
    /// talking (user decision, tune 2). Not part of the 62 acoustic fixtures.
    case backchannel
    /// 0.6 wake suite: a wake phrase, alone or with a question in one breath. Not core.
    case wake
    /// 0.6 wake suite: speech not addressed to Dee (near-miss words, Dee's name in a
    /// sentence): must never wake Dee. Not core.
    case unaddressed
    /// Calm: a listener's non-speech sound said over Dee (cough, breath, throat clear,
    /// sigh, closed-mouth "hmm", a laugh). Dee must carry on (scored like a backchannel,
    /// `false_pause`). Not core.
    case nonspeech
}

/// Calm: how long a non-speech sound is (`class` in the manifest). `short` (≤ 0.6 s)
/// is gated by `false_pause` (≤ 5 % pauses, 0 stops); `long` (a laughing or coughing
/// fit) by `false_pause_long` (0 stops; pauses reported).
public enum NonspeechClass: String, Codable, Sendable { case short, long }

/// One piece of a fixture: words, or a deliberate silence.
public enum FixturePart: Codable, Sendable, Equatable {
    case words(String)
    case pause(Double)

    enum CodingKeys: String, CodingKey { case words, pause }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let w = try c.decodeIfPresent(String.self, forKey: .words) { self = .words(w) }
        else { self = .pause(try c.decode(Double.self, forKey: .pause)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .words(let w): try c.encode(w, forKey: .words)
        case .pause(let p): try c.encode(p, forKey: .pause)
        }
    }
}

public struct FixtureSpec: Codable, Sendable, Equatable {
    public var id: String
    public var category: FixtureCategory
    public var engine: FixtureEngine
    /// TTS voice (`alloy`, `coral`, …) or `say` voice (`Samantha`, `Daniel`, …).
    public var voice: String
    public var style: FixtureStyle
    public var parts: [FixturePart]
    /// Calm: a `nonspeech` fixture's length class (nil otherwise).
    public var soundClass: NonspeechClass?
    /// Calm round 2: `say -r` override (wins over `style.sayRate`); the voiced coughs
    /// (ns12–ns14) were tuned at one exact rate against Apple's classifier.
    public var sayRate: Int?

    public init(_ id: String, _ category: FixtureCategory, _ engine: FixtureEngine, _ voice: String,
                _ style: FixtureStyle = .neutral, _ parts: [FixturePart], soundClass: NonspeechClass? = nil,
                sayRate: Int? = nil) {
        self.id = id; self.category = category; self.engine = engine
        self.voice = voice; self.style = style; self.parts = parts; self.soundClass = soundClass
        self.sayRate = sayRate
    }

    /// The `say -r` rate this fixture renders at (nil: the voice's default).
    public var effectiveSayRate: Int? { sayRate ?? style.sayRate }

    /// Ground-truth text: the words in order (pauses dropped).
    public var text: String {
        parts.compactMap { if case .words(let w) = $0 { w } else { nil } }.joined(separator: " ")
    }

    /// The deliberate mid-turn pauses, seconds.
    public var pauses: [Double] { parts.compactMap { if case .pause(let p) = $0 { p } else { nil } } }
}

/// The ~60 user utterances (voice design §7.4 + the harness brief). Dee speaks
/// `marin`; user voices never use `marin` / `cedar`, so Dee's echo and the user stay
/// distinguishable by ear in the recordings.
public enum FixtureCatalog {
    private static func w(_ s: String) -> FixturePart { .words(s) }
    private static func p(_ s: Double) -> FixturePart { .pause(s) }

    public static let all: [FixtureSpec] = [
        // Short questions
        .init("q01", .shortQuestion, .openai, "alloy", .neutral, [w("What's your favorite color?")]),
        .init("q02", .shortQuestion, .say, "Samantha", .neutral, [w("Are you awake?")]),
        .init("q03", .shortQuestion, .openai, "coral", .soft, [w("What time is it?")]),
        .init("q04", .shortQuestion, .openai, "shimmer", .child, [w("Do you like music?")]),
        .init("q05", .shortQuestion, .say, "Daniel", .neutral, [w("Can you hear me okay?")]),
        .init("q06", .shortQuestion, .openai, "ash", .fast, [w("What did you do today?")]),
        .init("q07", .shortQuestion, .openai, "sage", .neutral, [w("Is it going to rain tomorrow?")]),
        .init("q08", .shortQuestion, .say, "Flo (English (US))", .neutral, [w("Who made you?")]),
        // Long turns
        .init("l01", .longTurn, .openai, "verse", .neutral, [w("So I've been thinking about getting a dog, but my apartment is pretty small and I work long hours, so I'm not sure it would be fair to the dog. What do you think I should do?")]),
        .init("l02", .longTurn, .openai, "coral", .fast, [w("Okay so today at work my boss called a meeting at four thirty on a Friday, which nobody wanted, and then she spent the whole hour talking about a new filing system that honestly nobody is going to use.")]),
        .init("l03", .longTurn, .openai, "shimmer", .child, [w("Dee, guess what, at school today we made volcanoes with baking soda and mine exploded the biggest and the teacher said it was the best one in the whole class!")]),
        .init("l04", .longTurn, .say, "Samantha", .neutral, [w("I'm trying to plan a little garden on my balcony. I want tomatoes and basil, maybe some strawberries, but I don't know how much sun they need.")]),
        .init("l05", .longTurn, .openai, "ballad", .soft, [w("I couldn't sleep last night. I kept going over a conversation with my brother in my head, wondering if I said the wrong thing.")]),
        .init("l06", .longTurn, .openai, "echo", .neutral, [w("My grandmother used to make this soup every winter with barley and carrots, and I finally found her recipe card in a box in the attic.")]),
        // Mid-sentence pauses 0.6 / 1.2 / 2.0 s
        .init("p06a", .pause06, .openai, "alloy", .neutral, [w("I was going to say"), p(0.6), w("that the movie was better than the book.")]),
        .init("p06b", .pause06, .say, "Daniel", .neutral, [w("My favorite thing about weekends is"), p(0.6), w("sleeping in late.")]),
        .init("p06c", .pause06, .openai, "sage", .neutral, [w("Can you remind me"), p(0.6), w("what we talked about yesterday?")]),
        .init("p12a", .pause12, .openai, "coral", .neutral, [w("So yesterday I went to the"), p(1.2), w("farmers market with my sister.")]),
        .init("p12b", .pause12, .openai, "ballad", .soft, [w("The thing is"), p(1.2), w("I don't really like my job anymore.")]),
        .init("p12c", .pause12, .say, "Samantha", .neutral, [w("I think the answer is"), p(1.2), w("forty two.")]),
        .init("p20a", .pause20, .openai, "verse", .neutral, [w("What I really want to know is"), p(2.0), w("whether robots can dream.")]),
        .init("p20b", .pause20, .openai, "ash", .neutral, [w("I'm going to"), p(2.0), w("visit my parents next weekend.")]),
        .init("p20c", .pause20, .say, "Flo (English (US))", .neutral, [w("Let me think."), p(2.0), w("Okay, tell me a fun fact about octopuses.")]),
        // Fillers
        .init("f01", .filler, .openai, "alloy", .neutral, [w("So I went to the… um… store, and they were out of milk.")]),
        .init("f02", .filler, .openai, "coral", .neutral, [w("Uh, I don't know, maybe, like, we could watch a movie?")]),
        .init("f03", .filler, .openai, "echo", .neutral, [w("Hmm, what's the, uh, the name of that big red planet?")]),
        .init("f04", .filler, .openai, "sage", .neutral, [w("So I went to the"), p(0.5), w("um"), p(0.6), w("store.")]),
        .init("f05", .filler, .say, "Daniel", .neutral, [w("Well, er, I suppose I could try again tomorrow.")]),
        // Trailing "and…"
        .init("t01", .trailing, .openai, "alloy", .neutral, [w("I had pasta for dinner, and…")]),
        .init("t02", .trailing, .openai, "shimmer", .child, [w("We went to the beach and then we got ice cream and…")]),
        .init("t03", .trailing, .say, "Samantha", .neutral, [w("I was going to call my mom and")]),
        // Two-part turns
        .init("two01", .twoPart, .openai, "coral", .neutral, [w("Hi Dee."), p(0.5), w("How was your day?")]),
        .init("two02", .twoPart, .openai, "verse", .neutral, [w("Okay."), p(0.8), w("Tell me a story about a brave little robot.")]),
        .init("two03", .twoPart, .say, "Daniel", .neutral, [w("Wait."), p(0.7), w("Actually, never mind. What's the weather like?")]),
        .init("two04", .twoPart, .openai, "shimmer", .child, [w("Good morning!"), p(0.6), w("Did you sleep well?")]),
        // Commands
        .init("c01", .command, .openai, "ash", .loud, [w("Stop.")]),
        .init("c02", .command, .openai, "alloy", .neutral, [w("Don't stop, keep going.")]),
        .init("c03", .command, .openai, "coral", .fast, [w("Wait, stop talking for a second.")]),
        .init("c04", .command, .say, "Samantha", .neutral, [w("Be quiet, please.")]),
        .init("c05", .command, .openai, "sage", .soft, [w("Keep going, I'm listening.")]),
        .init("c06", .command, .openai, "echo", .fast, [w("Hold on, hold on.")]),
        // Names / introductions
        .init("n01", .name, .openai, "coral", .neutral, [w("Hi Dee, my name is Priya.")]),
        .init("n02", .name, .openai, "ash", .neutral, [w("I'm Marcus, and this is my daughter Lily.")]),
        .init("n03", .name, .say, "Daniel", .neutral, [w("Do you remember my name? It's Tomasz.")]),
        .init("n04", .name, .openai, "shimmer", .child, [w("My name is Emma and I'm seven!")]),
        .init("m01", .name, .openai, "coral", .neutral, [w("Do you remember what my name is?")]),
        .init("n05", .name, .openai, "verse", .neutral, [w("This is my friend Oluwaseun, he's visiting from Lagos.")]),
        // Rudeness, then apology / repair
        .init("r01", .rudeness, .openai, "ash", .angry, [w("You're so stupid, you never understand anything.")]),
        .init("r02", .rudeness, .openai, "echo", .angry, [w("Shut up, Dee.")]),
        .init("r03", .rudeness, .say, "Reed (English (US))", .neutral, [w("Ugh, you're useless today.")]),
        .init("r04", .apology, .openai, "ash", .soft, [w("I'm sorry I yelled at you earlier, Dee. That wasn't fair.")]),
        .init("r05", .apology, .openai, "coral", .soft, [w("Sorry, I was in a bad mood. Can we start over?")]),
        // Jokes
        .init("j01", .joke, .openai, "alloy", .neutral, [w("Want to hear a joke? Why did the scarecrow win an award?"), p(1.0), w("Because he was outstanding in his field!")]),
        .init("j02", .joke, .openai, "shimmer", .child, [w("Knock knock.")]),
        // Sad news
        .init("s01", .sadNews, .openai, "ballad", .soft, [w("My cat died this morning.")]),
        .init("s02", .sadNews, .openai, "sage", .soft, [w("I didn't get the job I interviewed for.")]),
        .init("s03", .sadNews, .say, "Samantha", .soft, [w("My grandpa is in the hospital again.")]),
        // Plans with dates (for follow-ups)
        .init("d01", .plan, .openai, "coral", .neutral, [w("I have a dentist appointment next Tuesday at three.")]),
        .init("d02", .plan, .openai, "verse", .neutral, [w("My sister's wedding is on June twelfth, and I'm giving a speech.")]),
        .init("d03", .plan, .say, "Daniel", .neutral, [w("We're flying to Lisbon on the fourth of March.")]),
        .init("d04", .plan, .openai, "echo", .fast, [w("I have a big exam on Friday morning and I'm nervous.")]),
        .init("d05", .plan, .openai, "alloy", .neutral, [w("Remind me to ask you how my sister's interview went on Thursday.")]),
        // Continuations (same voice as the line they finish) and follow-on lines.
        .init("k01", .continuation, .openai, "alloy", .neutral, [w("then I had a huge slice of chocolate cake.")]),
        .init("k02", .continuation, .openai, "shimmer", .child, [w("a seagull stole my brother's ice cream right out of his hand!")]),
        .init("k03", .continuation, .say, "Samantha", .neutral, [w("tell her about my new job. Do you think she'll be happy?")]),
        .init("k04", .continuation, .openai, "echo", .fast, [w("Okay, sorry. What's your favorite animal?")]),
        .init("k05", .continuation, .openai, "shimmer", .child, [w("Lettuce.")]),
        .init("k06", .continuation, .openai, "shimmer", .child, [w("Lettuce in, it's cold out here!")]),
        .init("k07", .continuation, .openai, "ballad", .soft, [w("Thanks, Dee. I really miss her.")]),
        // Tune 2 extras (macOS `say`: rendered offline, no key, no cost). Not core.
        // A second "call my mom and…" (the transcript renders a trailing "and" as "Ann").
        .init("t04", .trailing, .say, "Flo (English (US))", .neutral, [w("Tomorrow I'm going to call my mom and")]),
        .init("k08", .continuation, .say, "Flo (English (US))", .neutral, [w("ask her for her soup recipe. What should I make with it?")]),
        // Backchannels said while Dee talks.
        .init("bc01", .backchannel, .say, "Daniel", .neutral, [w("Go on.")]),
        .init("bc02", .backchannel, .say, "Samantha", .soft, [w("Mm-hm.")]),

        // 0.6 wake suite (`WakeSuite`). "Hey Dee" alone, many voices (accept ≥ 95%).
        .init("wd01", .wake, .say, "Samantha", .neutral, [w("Hey Dee.")]),
        .init("wd02", .wake, .say, "Daniel", .neutral, [w("Hey Dee.")]),
        .init("wd03", .wake, .say, "Karen", .neutral, [w("Hey Dee.")]),
        .init("wd04", .wake, .say, "Flo (English (US))", .neutral, [w("Hey Dee!")]),
        .init("wd05", .wake, .say, "Reed (English (US))", .neutral, [w("Hey Dee.")]),
        .init("wd06", .wake, .say, "Moira", .neutral, [w("Hey Dee.")]),
        .init("wd07", .wake, .openai, "alloy", .neutral, [w("Hey Dee.")]),
        .init("wd08", .wake, .openai, "coral", .soft, [w("Hey Dee.")]),
        .init("wd09", .wake, .openai, "ash", .loud, [w("Hey Dee!")]),
        .init("wd10", .wake, .openai, "shimmer", .child, [w("Hey Dee!")]),
        .init("wd11", .wake, .openai, "sage", .neutral, [w("Hey Dee.")]),
        .init("wd12", .wake, .openai, "verse", .fast, [w("Hey Dee.")]),
        .init("wd13", .wake, .openai, "ballad", .soft, [w("Hey Dee.")]),
        .init("wd14", .wake, .openai, "echo", .neutral, [w("Hey Dee.")]),
        // One breath: the question must be answered (audio from ~0.3 s before the wake onset).
        .init("wq01", .wake, .openai, "coral", .neutral, [w("Hey Dee, what time is it?")]),
        .init("wq02", .wake, .say, "Daniel", .neutral, [w("Hey Dee, what's your favorite color?")]),
        .init("wq03", .wake, .openai, "alloy", .neutral, [w("Hey Dee, are you awake?")]),
        .init("wq04", .wake, .openai, "shimmer", .child, [w("Hey Dee, do you like music?")]),
        // A pause after the phrase, then the question (one fixture).
        .init("wp01", .wake, .openai, "sage", .neutral, [w("Hey Dee."), p(1.0), w("Can you hear me okay?")]),
        .init("wp02", .wake, .say, "Samantha", .neutral, [w("Hey Dee."), p(0.8), w("What did you do today?")]),
        // Close commands (the window closes at once).
        .init("wc01", .command, .openai, "alloy", .neutral, [w("Okay, go to sleep.")]),
        .init("wc02", .command, .say, "Daniel", .neutral, [w("That's all for now.")]),
        .init("wc03", .command, .openai, "coral", .neutral, [w("Hey Dee, stop listening.")]),
        // Custom phrases (accept ≥ 90% each).
        .init("cc01", .wake, .say, "Samantha", .neutral, [w("Computer.")]),
        .init("cc02", .wake, .say, "Daniel", .neutral, [w("Computer.")]),
        .init("cc03", .wake, .openai, "alloy", .neutral, [w("Computer.")]),
        .init("cc04", .wake, .openai, "coral", .soft, [w("Computer.")]),
        .init("cc05", .wake, .openai, "ash", .fast, [w("Computer!")]),
        .init("cc06", .wake, .openai, "shimmer", .child, [w("Computer!")]),
        .init("cq01", .wake, .openai, "sage", .neutral, [w("Computer, what time is it?")]),
        .init("hr01", .wake, .say, "Samantha", .neutral, [w("Hey Robo.")]),
        .init("hr02", .wake, .say, "Daniel", .neutral, [w("Hey Robo.")]),
        .init("hr03", .wake, .openai, "alloy", .neutral, [w("Hey Robo.")]),
        .init("hr04", .wake, .openai, "coral", .soft, [w("Hey Robo.")]),
        .init("hr05", .wake, .openai, "echo", .neutral, [w("Hey Robo!")]),
        .init("hr06", .wake, .openai, "shimmer", .child, [w("Hey Robo!")]),
        .init("hrq01", .wake, .openai, "verse", .neutral, [w("Hey Robo, tell me a joke.")]),
        .init("op01", .wake, .say, "Samantha", .neutral, [w("Okay Pixel.")]),
        .init("op02", .wake, .say, "Daniel", .neutral, [w("Okay Pixel.")]),
        .init("op03", .wake, .openai, "alloy", .neutral, [w("Okay Pixel.")]),
        .init("op04", .wake, .openai, "coral", .soft, [w("Okay Pixel.")]),
        .init("op05", .wake, .openai, "sage", .neutral, [w("Okay Pixel.")]),
        .init("op06", .wake, .openai, "shimmer", .child, [w("Okay Pixel!")]),
        .init("opq01", .wake, .openai, "ash", .neutral, [w("Okay Pixel, are you awake?")]),
        // Unaddressed speech: Dee's name in a sentence, near-miss words (never a wake).
        .init("un01", .unaddressed, .openai, "coral", .neutral, [w("My friend says that Dee is a robot who lives on my shelf.")]),
        .init("un02", .unaddressed, .say, "Daniel", .neutral, [w("I told her the deadline was on Thursday.")]),
        .init("un03", .unaddressed, .openai, "ash", .neutral, [w("Hey, the delivery guy is at the door.")]),
        .init("un04", .unaddressed, .say, "Samantha", .neutral, [w("The lady at the bakery gave us extra bread.")]),
        .init("un05", .unaddressed, .openai, "sage", .neutral, [w("He is driving to the D C office next week.")]),
        .init("un06", .unaddressed, .say, "Karen", .neutral, [w("Hey there, how have you been lately?")]),
        .init("un07", .unaddressed, .openai, "verse", .neutral, [w("We watched a show about an old computer museum.")]),
        .init("un08", .unaddressed, .openai, "alloy", .neutral, [w("Okay, picture this: a tiny robot on a beach.")]),
        .init("un09", .unaddressed, .say, "Daniel", .neutral, [w("Hey Rob, can you pass the salt?")]),
        .init("un10", .unaddressed, .openai, "echo", .neutral, [w("I need to compute the total before dinner.")]),
        .init("un11", .unaddressed, .openai, "ballad", .soft, [w("Had a hot head about it, then I hid the heater.")]),
        .init("un12", .unaddressed, .say, "Moira", .neutral, [w("Did you see her robe? It was the color of the sea.")]),

        // Calm (too sensitive to interruptions): the listener's own short sounds over Dee.
        // DSP ones are synthesized offline and seeded (`Nonspeech`, recipe = voice); no
        // words, so no ground-truth text. Rendered at −24 dBFS; a scenario's
        // `bargeIn.gainDB` +7 makes the loud (−17 dBFS, close to the phone) variant.
        .init("ns01", .nonspeech, .dsp, "cough", .neutral, [], soundClass: .short),
        .init("ns02", .nonspeech, .dsp, "cough2", .neutral, [], soundClass: .short),
        .init("ns03", .nonspeech, .dsp, "throat", .neutral, [], soundClass: .short),
        .init("ns04", .nonspeech, .dsp, "breath", .neutral, [], soundClass: .short),
        .init("ns05", .nonspeech, .dsp, "sigh", .neutral, [], soundClass: .short),
        .init("ns06", .nonspeech, .dsp, "hmm", .neutral, [], soundClass: .short),
        .init("ns07", .nonspeech, .dsp, "laugh3", .neutral, [], soundClass: .short),
        .init("ns08", .nonspeech, .openai, "alloy", .laugh, [w("Heh.")], soundClass: .short),
        .init("ns09", .nonspeech, .openai, "coral", .laugh, [w("Ha ha!")], soundClass: .short),
        .init("ns10", .nonspeech, .dsp, "laugh6", .neutral, [], soundClass: .long),
        .init("ns11", .nonspeech, .dsp, "coughfit", .neutral, [], soundClass: .long),
        // Calm round 2: coughs Apple's classifier hears as coughs. The seeded DSP coughs
        // above score cough 0.00 ("hammer", "gunshot"); TTS asked for a cough spoke the
        // words ("Cough, cough."). macOS `say` voice Albert (a raspy novelty voice) on a
        // non-lexical "hukh" syllable, at the rate found by an offline search (free, no
        // key), is heard as a cough (≥ 0.4) and as no words by the on-device
        // recogniser (`voice-harness sounds`). The text is the `say` input, not words
        // the user says: nonspeech fixtures have no ground truth.
        .init("ns12", .nonspeech, .say, "Albert", .neutral, [w("Khukh!")], soundClass: .short, sayRate: 185),
        .init("ns13", .nonspeech, .say, "Albert", .neutral, [w("Khukh! Khukh!")], soundClass: .short, sayRate: 185),
        .init("ns14", .nonspeech, .say, "Albert", .neutral, [w("Hukh. Hukh. Hukh.")], soundClass: .long, sayRate: 250),
        // More single-clause continuers over Dee (Dee keeps talking).
        .init("bc03", .backchannel, .openai, "alloy", .neutral, [w("Yeah.")]),
        .init("bc04", .backchannel, .say, "Samantha", .neutral, [w("Uh-huh.")]),
        .init("bc05", .backchannel, .openai, "coral", .neutral, [w("Right.")]),
        .init("bc06", .backchannel, .say, "Daniel", .neutral, [w("Okay.")]),
        .init("bc07", .backchannel, .openai, "sage", .neutral, [w("Mm.")]),
        .init("bc08", .backchannel, .openai, "shimmer", .neutral, [w("Oh wow.")]),
        .init("bc09", .backchannel, .openai, "verse", .laugh, [w("Haha, yeah.")]),
        // Round 2: bc10 was TTS coral soft, which came back as digital silence (peak 0):
        // round 1 scored a silent "continuer" as carried on. `say` renders it offline.
        .init("bc10", .backchannel, .say, "Karen", .soft, [w("Yeah.")]),
        .init("bc11", .backchannel, .openai, "ballad", .soft, [w("Mm-hm.")]),
        .init("bc12", .backchannel, .openai, "ash", .neutral, [w("Okay.")]),
        // A question that opens with a stop phrase, and a lone stop word.
        .init("c07", .command, .openai, "echo", .neutral, [w("Hold on, what time is it?")]),
        .init("c08", .command, .openai, "ash", .loud, [w("Wait.")]),
    ]

    /// Calm: the ids added for the calm suite (not core).
    public static let calmExtras: Set<String> = ["c07", "c08"]

    /// Fixtures added for the tune-2 regression suite (not part of the 62).
    public static let extras: Set<String> = ["t04", "k08", "bc01", "bc02"]

    /// The 62 acoustic fixtures (every category but `continuation` / `backchannel`, no extras).
    public static var core: [FixtureSpec] {
        all.filter { $0.category != .continuation && $0.category != .backchannel && $0.category != .nonspeech
            && !extras.contains($0.id) && !calmExtras.contains($0.id) && !isWakeSuite($0) }
    }

    /// 0.6 wake suite fixtures (`wd…`, `wq…`, `wp…`, `wc…`, custom phrases, `un…`): not core.
    public static func isWakeSuite(_ f: FixtureSpec) -> Bool {
        f.category == .wake || f.category == .unaddressed || f.id.hasPrefix("wc")
    }

    /// Fixtures after which the user has not finished: waiting is the right answer
    /// ("hold on", a trailing "and…"). Mid-sentence pauses are inside one fixture and
    /// are scored by their own spans.
    public static let holdsFloor: Set<String> = ["c06", "t01", "t02", "t03", "t04"]

    /// Said while Dee talks, these are a listener's backchannel, not a barge-in: Dee
    /// keeps talking (user decision, tune 2: "keep going" / "go on" / "mm-hm"). Scored
    /// by the `backchannel` gate, never by `barge_in`.
    public static let backchannels: Set<String> = ["c02", "c05", "bc01", "bc02", "bc03", "bc04", "bc05", "bc06", "bc07",
                                                   "bc08", "bc09", "bc10", "bc11", "bc12"]

    /// Calm: single-clause continuers ("Go on.", "Mm-hm.", "Yeah.", …): with the short
    /// non-speech sounds they are the `false_pause` events (Dee must never fall silent).
    public static let singleClauseContinuers: Set<String> = ["bc01", "bc02", "bc03", "bc04", "bc05", "bc06", "bc07",
                                                             "bc08", "bc09", "bc10", "bc11", "bc12"]

    /// Calm: lone stop words (`silence` p90 ≤ 1.1 s: the moment the reply ended at in 0.6.0).
    public static let loneStopWords: Set<String> = ["c01", "c08"]

    /// Calm round 2 (D1): where the stop / command phrase ends inside each stop fixture.
    /// Dee must be fully silent within `Gates.Thresholds.stopWordSilenceP90` of it.
    public enum StopWordEnd: Sendable, Equatable {
        /// The fixture is the stop word ("Stop.", "Wait.").
        case endOfSpeech
        /// The stop phrase is the first voiced span ("Be quiet" | "please", "Hold on" |
        /// "hold on", "Hold on" | "what time is it?").
        case firstSpan
        /// This long after the onset (one span: c03 "Wait, stop talking…", "Wait" by the
        /// on-device recogniser's word timing, 0.12–0.57 s of the file, onset 0.17 s).
        case afterOnset(Double)
    }
    public static let stopWordEnds: [String: StopWordEnd] = [
        "c01": .endOfSpeech, "c08": .endOfSpeech, "c03": .afterOnset(0.40),
        "c04": .firstSpan, "c06": .firstSpan, "c07": .firstSpan,
    ]

    /// Calm: the SoundAnalysis label family each DSP / TTS sound must get offline
    /// (`voice-harness sounds`, confidence ≥ `soundCheckMin`) before any live run.
    public static let expectedSoundLabel: [String: String] = [
        "ns01": "cough", "ns02": "cough", "ns11": "cough",
        "ns12": "cough", "ns13": "cough", "ns14": "cough",
        "ns07": "laughter", "ns09": "laughter", "ns10": "laughter",
    ]
    public static let soundCheckMin = 0.4
    /// Round 2: sounds known to miss their label (documented, not re-synthesized): the
    /// seeded DSP coughs score cough 0.00 ("hammer", "slap", "insect": about 1,000 DSP
    /// variants stayed under 0.02, so the classifier keys on vocal-tract detail a
    /// source-filter recipe lacks) and TTS "Ha ha!" scores laughter 0.02. They stay in
    /// the suite for EarCore's energy / pitch path; ns12–ns14 cover the cough label.
    /// ns07 (DSP 3-pulse laugh) reaches laughter 0.57 only at one alignment of the
    /// classifier's windows (median 0.09 over `SoundCheck.leads`); ns10 is the reliable
    /// laugh (median 0.72).
    public static let knownUnlabelled: Set<String> = ["ns01", "ns02", "ns11", "ns09", "ns07"]

    /// Calm: how a DSP sound is re-synthesized when Apple's classifier does not hear it
    /// as meant (`voice-harness fixtures --resynth`, needs the key, < $0.001 each):
    /// gpt-4o-mini-tts with a no-words instruction; kept only if it classifies better.
    /// (The seeded DSP coughs read as "gunshot / hammer" to `.version1`; the laughs pass.)
    public struct SoundFallback: Sendable {
        public var voice: String
        public var text: String
        public var instructions: String
    }
    public static let soundFallbacks: [String: SoundFallback] = [
        "ns01": .init(voice: "ash", text: "*cough*",
                      instructions: "Do not say any words. Make one short, dry, natural cough into your hand, like clearing a tickle in your chest."),
        "ns02": .init(voice: "echo", text: "*cough cough*",
                      instructions: "Do not say any words. Make two short natural coughs in a row, a little hoarse."),
        "ns11": .init(voice: "ash", text: "*coughing fit*",
                      instructions: "Do not say any words. Make a short coughing fit: four quick, real coughs in a row, about one second in all."),
        "ns07": .init(voice: "coral", text: "Ha ha ha.",
                      instructions: "Laugh briefly and naturally, three short breathy 'ha' sounds, amused. No other words."),
        "ns10": .init(voice: "verse", text: "Ha ha ha ha ha ha!",
                      instructions: "Burst out laughing for about a second, natural and breathy, six quick 'ha' sounds. No other words."),
    ]

    public static func spec(_ id: String) -> FixtureSpec? { all.first { $0.id == id } }
}

/// How a fixture's reply is scored (latency gate semantics).
public enum TurnShape {
    /// Latency buckets: `main` (p90 ≤ 1.6 s + overhead gate), `filler` ("um", "uh", "er"
    /// turns: p90 ≤ 2.0 s), `none` (waiting is correct: no latency of its own).
    public enum Bucket: String, Codable, Sendable { case main, filler, none }

    /// The user is not done at this fixture's end of speech (answering it early is a
    /// false cut-off; the latency counts from the end of what follows).
    public static func holdsFloor(_ fixture: String) -> Bool { FixtureCatalog.holdsFloor.contains(fixture) }

    /// A listener's backchannel ("keep going", "go on", "mm-hm"): Dee keeps talking.
    public static func isBackchannel(_ fixture: String) -> Bool { FixtureCatalog.backchannels.contains(fixture) }

    /// Calm: a non-speech sound (cough, laugh, breath…): scored like a backchannel.
    public static func isNonspeech(_ fixture: String) -> Bool { FixtureCatalog.spec(fixture)?.category == .nonspeech }

    /// Calm: a non-speech sound's length class (nil: not a sound).
    public static func soundClass(_ fixture: String) -> NonspeechClass? { FixtureCatalog.spec(fixture)?.soundClass }

    public static func bucket(_ fixture: String) -> Bucket {
        if holdsFloor(fixture) { return .none }
        return FixtureCatalog.spec(fixture)?.category == .filler ? .filler : .main
    }
}

// MARK: - Manifest (what was rendered)

public struct FixtureManifest: Codable, Sendable {
    /// Round 2: an utterance at or below this active level is digital silence.
    public static let silentLevelDB = -90.0
    public struct Utterance: Codable, Sendable, Equatable {
        public var id: String
        public var file: String
        public var category: FixtureCategory
        public var engine: FixtureEngine
        public var voice: String
        public var style: FixtureStyle
        /// Ground truth: what the user says (pauses dropped).
        public var text: String
        public var sampleRate: Int
        public var samples: Int
        /// First voiced sample.
        public var onsetSample: Int
        /// Exact end of speech: one past the last voiced sample.
        public var endOfSpeechSample: Int
        /// Voiced spans; the gaps between them are the user's mid-turn pauses.
        public var spans: [DSP.Span]
        /// Deliberate pauses in the script, seconds.
        public var scriptedPauses: [Double]
        public var activeLevelDB: Double
        /// Calm: a `nonspeech` fixture's length class (`class`: short | long).
        public var soundClass: NonspeechClass?

        enum CodingKeys: String, CodingKey {
            case id, file, category, engine, voice, style, text, sampleRate, samples, onsetSample, endOfSpeechSample, spans,
                 scriptedPauses, activeLevelDB
            case soundClass = "class"
        }

        public init(id: String, file: String, category: FixtureCategory, engine: FixtureEngine, voice: String,
                    style: FixtureStyle, text: String, sampleRate: Int, samples: Int, onsetSample: Int,
                    endOfSpeechSample: Int, spans: [DSP.Span], scriptedPauses: [Double], activeLevelDB: Double,
                    soundClass: NonspeechClass? = nil) {
            self.id = id; self.file = file; self.category = category; self.engine = engine; self.voice = voice
            self.style = style; self.text = text; self.sampleRate = sampleRate; self.samples = samples
            self.onsetSample = onsetSample; self.endOfSpeechSample = endOfSpeechSample; self.spans = spans
            self.scriptedPauses = scriptedPauses; self.activeLevelDB = activeLevelDB; self.soundClass = soundClass
        }

        public var duration: Double { Double(samples) / Double(sampleRate) }
        public var speechSeconds: Double { Double(endOfSpeechSample - onsetSample) / Double(sampleRate) }
    }

    public struct Bed: Codable, Sendable, Equatable {
        public var id: String
        public var file: String
        public var seconds: Double
        public var levelDB: Double
        public var provenance: String

        public init(id: String, file: String, seconds: Double, levelDB: Double, provenance: String) {
            self.id = id; self.file = file; self.seconds = seconds; self.levelDB = levelDB; self.provenance = provenance
        }
    }

    public var version = 1
    public var generatedAt: String
    public var sampleRate = 24_000
    public var ttsModel = "gpt-4o-mini-tts"
    public var notes: String
    public var utterances: [Utterance]
    public var noise: [Bed]
    public var impulseResponses: [Bed]

    public init(generatedAt: String, notes: String, utterances: [Utterance], noise: [Bed], impulseResponses: [Bed]) {
        self.generatedAt = generatedAt; self.notes = notes
        self.utterances = utterances; self.noise = noise; self.impulseResponses = impulseResponses
    }

    public func utterance(_ id: String) -> Utterance? { utterances.first { $0.id == id } }

    public static func load(_ url: URL) throws -> FixtureManifest {
        try JSONDecoder().decode(FixtureManifest.self, from: Data(contentsOf: url))
    }

    public func write(_ url: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(self).write(to: url, options: .atomic)
    }
}

/// Assembles rendered segments into one fixture with exact ground truth.
public enum FixtureAssembler {
    public static let lead = 0.15
    public static let tail = 0.4

    /// `segments`: rendered words (already at `sampleRate`) or pauses, in script order.
    /// Each words segment is trimmed to its voiced extent and normalized to the style
    /// level; pauses are exact digital silence of the scripted length (the room bed
    /// fills them at mix time). Returns the samples plus onset / end of speech / spans.
    public static func assemble(_ segments: [Segment], sampleRate: Int, levelDB: Double)
        -> (samples: [Float], onset: Int, endOfSpeech: Int, spans: [DSP.Span]) {
        var out = [Float](repeating: 0, count: Int(lead * Double(sampleRate)))
        for seg in segments {
            switch seg {
            case .pause(let s):
                out += [Float](repeating: 0, count: Int((s * Double(sampleRate)).rounded()))
            case .audio(let x):
                let spans = DSP.speechSpans(x, sampleRate: sampleRate)
                guard let first = spans.first, let last = spans.last else { continue }
                // Keep 30 ms either side of the voiced extent (soft onsets / releases).
                let pad = Int(0.03 * Double(sampleRate))
                let a = max(0, first.start - pad), b = min(x.count, last.end + pad)
                let piece = DSP.faded(Array(x[a..<b]), sampleRate: sampleRate)
                out += DSP.normalized(piece, sampleRate: sampleRate, targetDB: levelDB)
            }
        }
        out += [Float](repeating: 0, count: Int(tail * Double(sampleRate)))
        let spans = DSP.speechSpans(out, sampleRate: sampleRate)
        let onset = spans.first?.start ?? 0
        let eos = spans.last?.end ?? out.count
        return (out, onset, eos, spans)
    }

    public enum Segment: Sendable {
        case audio([Float])
        case pause(Double)
    }
}

// MARK: - Calm round 2: a sound fixture must not speak words

/// The round-1 resynth kept a gpt-4o-mini-tts "cough" that spoke the instruction as
/// words ("Cough, cough.", "Puff, puff.", "Coughing fit."): the live server heard words
/// and Dee was right to stop. A sound fixture's transcript may hold only non-lexical
/// vocalizations (laughs, fillers, "mm-hm") and bracketed / asterisked sound tags.
public enum SoundWords {
    /// Vocalizations that are not words: a sound fixture may be heard as these.
    public static let nonLexical: Set<String> = [
        "uh", "uhh", "um", "umm", "uhm", "er", "erm", "ah", "ahh", "aah", "oh", "ohh", "ooh", "eh", "ehh",
        "hm", "hmm", "hmmm", "mm", "mmm", "mhm", "mmhm", "mmhmm", "mm-hm", "mm-hmm", "uh-huh", "huh", "hah",
        "ha", "haha", "hahaha", "heh", "hehe", "heheh", "ahem", "ugh", "achoo", "pff", "phew", "whew", "shh", "tsk",
    ]

    /// The lexical words of `transcript` (empty: no words). Sound tags such as
    /// "[laughter]", "(coughs)" or "*cough*" are dropped first; then every token that is
    /// not a `nonLexical` vocalization ("ha ha", "Mm-hm.") counts as a word.
    public static func lexicalWords(in transcript: String) -> [String] {
        var t = transcript
        for (open, close) in [("[", "]"), ("(", ")"), ("*", "*")] {
            while let a = t.range(of: open), let b = t.range(of: close, range: a.upperBound..<t.endIndex) {
                t.removeSubrange(a.lowerBound..<b.upperBound)
            }
        }
        let tokens = t.lowercased().split { !($0.isLetter || $0 == "-" || $0 == "'") }.map(String.init)
        return tokens.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-'")) }
            .filter { !$0.isEmpty && !nonLexical.contains($0) && Set($0) != ["h", "a"] }    // "hahah", "ahah"
    }

    public static func hasWords(_ transcript: String) -> Bool { !lexicalWords(in: transcript).isEmpty }
}

/// Calm round 2: whether a re-synthesized sound replaces the seeded one
/// (`voice-harness fixtures --resynth`). The candidate must pass the classifier bar on
/// its own, beat the current rendering, and be heard as no words; otherwise the seeded
/// (DSP) fixture stays. A candidate whose words could not be checked is rejected.
public enum ResynthDecision: Equatable, Sendable {
    case accept
    case reject(String)

    public static func decide(current: Double, candidate: Double, bar: Double = FixtureCatalog.soundCheckMin,
                              candidateTranscript: String?) -> ResynthDecision {
        guard let transcript = candidateTranscript else { return .reject("no word check (on-device recogniser unavailable)") }
        let words = SoundWords.lexicalWords(in: transcript)
        if !words.isEmpty { return .reject("speaks words: “\(transcript)”") }
        if candidate < bar - 1e-9 { return .reject(String(format: "below the classifier bar (%.2f < %.1f)", candidate, bar)) }
        if candidate <= current + 1e-9 { return .reject(String(format: "not better (%.2f ≤ %.2f)", candidate, current)) }
        return .accept
    }
}
