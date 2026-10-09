import Foundation

// MARK: - Catalog (what to render)

/// How a fixture segment is voiced.
public enum FixtureEngine: String, Codable, Sendable {
    /// OpenAI `gpt-4o-mini-tts` (`/v1/audio/speech`, `response_format: pcm`, 24 kHz).
    case openai
    /// macOS `say` (`--data-format=LEI16@24000`).
    case say
}

public enum FixtureStyle: String, Codable, Sendable, CaseIterable {
    case neutral, soft, loud, angry, child, fast

    /// `gpt-4o-mini-tts` delivery instructions.
    public var ttsInstructions: String {
        switch self {
        case .neutral: "Speak naturally and casually, like an adult chatting at home with a small robot."
        case .soft: "Speak softly and quietly, a little hesitant and low in energy, close to a murmur."
        case .loud: "Speak loudly and forcefully, projecting across a noisy room."
        case .angry: "Speak angrily and impatiently, sharp and loud, clearly annoyed."
        case .child: "Speak like an excited seven-year-old child: high, bouncy, a bit breathless."
        case .fast: "Speak quickly, rushing through the words, with little pause between them."
        }
    }

    /// Active speech level the segment is normalized to (dBFS): loudness variety on purpose.
    public var levelDB: Double {
        switch self {
        case .neutral, .child, .fast: -24
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
}

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

    public init(_ id: String, _ category: FixtureCategory, _ engine: FixtureEngine, _ voice: String,
                _ style: FixtureStyle = .neutral, _ parts: [FixturePart]) {
        self.id = id; self.category = category; self.engine = engine
        self.voice = voice; self.style = style; self.parts = parts
    }

    /// Ground-truth text: the words in order (pauses dropped).
    public var text: String {
        parts.compactMap { if case .words(let w) = $0 { w } else { nil } }.joined(separator: " ")
    }

    /// The deliberate mid-turn pauses, seconds.
    public var pauses: [Double] { parts.compactMap { if case .pause(let p) = $0 { p } else { nil } } }
}

/// The ~60 user utterances (voice design §7.4 + the harness brief). Dee speaks
/// `marin`; user voices never use `marin` / `cedar`, so her echo and the user stay
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
    ]

    /// The 62 acoustic fixtures (every category but `continuation`).
    public static var core: [FixtureSpec] { all.filter { $0.category != .continuation } }

    /// Fixtures after which the user has not finished: waiting is the right answer
    /// ("hold on", a trailing "and…"). Mid-sentence pauses are inside one fixture and
    /// are scored by their own spans.
    public static let holdsFloor: Set<String> = ["c06", "t01", "t02", "t03"]

    public static func spec(_ id: String) -> FixtureSpec? { all.first { $0.id == id } }
}

/// How a fixture's reply is scored (latency gate semantics).
public enum TurnShape {
    /// Latency buckets: `main` (p50 ≤ 1.1 / p90 ≤ 1.6 s), `filler` ("um", "uh", "er"
    /// turns: p90 ≤ 2.0 s), `none` (waiting is correct: no latency of its own).
    public enum Bucket: String, Codable, Sendable { case main, filler, none }

    /// The user is not done at this fixture's end of speech (answering it early is a
    /// false cut-off; the latency counts from the end of what follows).
    public static func holdsFloor(_ fixture: String) -> Bool { FixtureCatalog.holdsFloor.contains(fixture) }

    public static func bucket(_ fixture: String) -> Bucket {
        if holdsFloor(fixture) { return .none }
        return FixtureCatalog.spec(fixture)?.category == .filler ? .filler : .main
    }
}

// MARK: - Manifest (what was rendered)

public struct FixtureManifest: Codable, Sendable {
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

        public init(id: String, file: String, category: FixtureCategory, engine: FixtureEngine, voice: String,
                    style: FixtureStyle, text: String, sampleRate: Int, samples: Int, onsetSample: Int,
                    endOfSpeechSample: Int, spans: [DSP.Span], scriptedPauses: [Double], activeLevelDB: Double) {
            self.id = id; self.file = file; self.category = category; self.engine = engine; self.voice = voice
            self.style = style; self.text = text; self.sampleRate = sampleRate; self.samples = samples
            self.onsetSample = onsetSample; self.endOfSpeechSample = endOfSpeechSample; self.spans = spans
            self.scriptedPauses = scriptedPauses; self.activeLevelDB = activeLevelDB
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
