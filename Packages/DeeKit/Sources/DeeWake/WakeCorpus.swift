import Foundation

/// The wake-tuning corpus (contract §3).
///
/// Positives are real on-device recognitions (every volatile and final segment, both
/// transcribers) of fixture audio for each phrase, replayed through the same
/// `WakeDetector` the ear uses. Negatives are the fixed confusers, every frequent word
/// close to the phrase (bare and in a carrier sentence), everyday sentences, and real
/// recognitions of negative / unaddressed speech and noise beds under each phrase's
/// contextual strings. The recordings live in DeeWakeTests/Fixtures (corpus.json is
/// pinned from MeasureCorpus); this type holds the rules and the text parts.
public enum WakeCorpus {
    public static let phrases = ["Hey Dee", "Computer", "Hey Robo", "Okay Pixel"]

    /// One recognition of one fixture clip under one phrase's contextual strings.
    public struct Recognition: Codable, Sendable, Equatable {
        public var id: String
        public var voice: String
        /// positive | onset | negative | unaddressed | bed | harness-dee
        public var kind: String
        /// The fixture's own phrase (positives), nil otherwise.
        public var phrase: String?
        /// The phrase whose contextual strings the recogniser ran with.
        public var context: String
        public var segments: [SpeechSegment]

        public init(id: String, voice: String, kind: String, phrase: String?, context: String, segments: [SpeechSegment]) {
            self.id = id
            self.voice = voice
            self.kind = kind
            self.phrase = phrase
            self.context = context
            self.segments = segments
        }

        public var isGatedPositive: Bool { kind == "positive" && phrase == context && WakeCorpus.isRealisticVoice(voice) }
        public var isNegative: Bool { ["negative", "unaddressed", "bed"].contains(kind) }
    }

    /// Fixture voices that sound like people: gpt-4o-mini-tts and the neural `say`
    /// voices. The novelty / formant `say` voices (Fred, Kathy, Ralph, Eloquence) are
    /// measured and reported but not gated — their "Dee" isn't intelligible.
    public static let realisticVoices: Set<String> = [
        "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse",
        "Samantha", "Daniel", "Karen", "Moira", "Tessa", "Rishi", "Aman", "Tara",
    ]

    public static func isRealisticVoice(_ v: String) -> Bool { realisticVoices.contains(v) }

    /// Replay a recognition through a fresh `WakeDetector` (no audio: segment timing
    /// only), returning its hits.
    public static func replay(_ r: Recognition, _ matcher: WakeMatcher) -> [WakeHit] {
        var d = WakeDetector(matcher: matcher)
        var hits: [WakeHit] = []
        for s in r.segments {
            if let h = d.segment(s, detectedAt: s.endFrame ?? 0).hit { hits.append(h) }
        }
        return hits
    }

    // MARK: - Text negatives

    /// Fixed confusers for every phrase.
    public static let fixedNegatives: [String] = [
        "he is", "D is", "hey the", "Lady", "had", "hot", "head", "hit", "heat", "hood", "hide", "hate", "her robe",
    ]

    /// Every word of `wordList` whose sound key or letters are within 2 of the phrase's
    /// (joined) — generated per phrase from the 10k frequency list.
    public static func nearWords(for phrase: WakePhrase, in wordList: [String]) -> [String] {
        let joined = phrase.words.joined()
        let key = phrase.key
        let aliases = Set(phrase.aliases.map { $0.replacingOccurrences(of: " ", with: "") })
        return wordList.filter { raw in
            let w = raw.lowercased()
            guard w != joined, !aliases.contains(w) else { return false }
            if abs(w.count - joined.count) <= 2, WakeText.levenshtein(w, joined) <= 2 { return true }
            let k = PhoneticKey(w)
            return !k.value.isEmpty && k.distance(to: key) <= 2 && abs(k.value.count - key.value.count) <= 2
        }
    }

    /// Text negatives for `phrase`: fixed + near words (bare and in a carrier sentence)
    /// + the everyday sentences.
    public static func textNegatives(for phrase: WakePhrase, wordList: [String]) -> [String] {
        let near = nearWords(for: phrase, in: wordList)
        return fixedNegatives + near + near.map { "I think the \($0) is over there" } + sentences
    }

    // MARK: - Tuning

    /// keyDistance −1 = the phonetic tier off.
    public static let keyDistanceGrid = [-1, 0, 1, 2]
    /// The contract's grid was 0.15–0.45; it starts at 0 because "commuter"/"compute"
    /// (1 edit from "computer") and "hey rob" (1 edit from "hey robo") leave no ratio
    /// ≥ 0.15 with zero negatives.
    public static let letterRatioGrid: [Double] = [0, 0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.45]

    public struct Report: Sendable, Equatable {
        public var thresholds: WakeMatcher.Thresholds
        public var recall: [String: Double]
        public var audioFalseHits: [String]
        public var textFalseHits: [String]
        public var qualifies: Bool
    }

    public static func evaluate(_ t: WakeMatcher.Thresholds, recognitions: [Recognition], wordList: [String], minRecall: Double = 0.95) -> Report {
        var recall: [String: Double] = [:]
        var audioFalse: [String] = []
        var textFalse: [String] = []
        for p in phrases {
            let phrase = try! WakePhrase(validating: p)
            let m = WakeMatcher(phrase, t)
            let pos = recognitions.filter { $0.isGatedPositive && $0.context == p }
            let hit = pos.filter { !replay($0, m).isEmpty }.count
            recall[p] = pos.isEmpty ? 0 : Double(hit) / Double(pos.count)
            for r in recognitions where r.isNegative && r.context == p && !replay(r, m).isEmpty { audioFalse.append("\(p): \(r.id)") }
            for s in textNegatives(for: phrase, wordList: wordList) where m.match([s]) != nil { textFalse.append("\(p): \(s)") }
        }
        let ok = recall.values.allSatisfy { $0 >= minRecall } && audioFalse.isEmpty && textFalse.isEmpty
        return Report(thresholds: t, recall: recall, audioFalseHits: audioFalse, textFalseHits: textFalse, qualifies: ok)
    }

    /// Smallest thresholds (keyDistance first, then letterRatio) with recall ≥ 0.95 on
    /// every phrase's gated positives and zero negatives. nil if none qualifies.
    public static func tune(recognitions: [Recognition], wordList: [String], minRecall: Double = 0.95) -> WakeMatcher.Thresholds? {
        for kd in keyDistanceGrid {
            for ratio in letterRatioGrid {
                let t = WakeMatcher.Thresholds(keyDistance: kd, letterRatio: ratio)
                if evaluate(t, recognitions: recognitions, wordList: wordList, minRecall: minRecall).qualifies { return t }
            }
        }
        return nil
    }

    // MARK: - Sentences

    /// 200 everyday sentences (household talk, TV, radio) with no corpus phrase.
    public static let sentences: [String] = [
        "What's your favorite color?", "What time is it?", "Do you like music?", "Can you hear me okay?",
        "What did you do today?", "Is it going to rain tomorrow?", "Who made you?", "Are you awake?",
        "I was going to say that the movie was better than the book.", "My favorite thing about weekends is sleeping in late.",
        "Can you remind me what we talked about yesterday?", "So yesterday I went to the farmers market with my sister.",
        "The thing is I don't really like my job anymore.", "I think the answer is forty two.",
        "What I really want to know is whether robots can dream.", "I'm going to visit my parents next weekend.",
        "Let me think.", "Tell me a fun fact about octopuses.", "So I went to the store, and they were out of milk.",
        "I don't know, maybe we could watch a movie?", "What's the name of that big red planet?",
        "Well, I suppose I could try again tomorrow.", "I had pasta for dinner.", "We went to the beach and then we got ice cream.",
        "I was going to call my mom.", "How was your day?", "Tell me a story about a brave little robot.",
        "Actually, never mind.", "What's the weather like?", "Good morning!", "Did you sleep well?", "Stop.",
        "Don't stop, keep going.", "Wait, stop talking for a second.", "Be quiet, please.", "Keep going, I'm listening.",
        "Hold on, hold on.", "My name is Priya.", "I'm Marcus, and this is my daughter Lily.", "Do you remember my name?",
        "My name is Emma and I'm seven!", "This is my friend Oluwaseun, he's visiting from Lagos.",
        "You never understand anything.", "Ugh, you're useless today.", "I'm sorry I yelled at you earlier.",
        "Sorry, I was in a bad mood.", "Can we start over?", "Why did the scarecrow win an award?",
        "Because he was outstanding in his field!", "Knock knock.", "My cat died this morning.",
        "I didn't get the job I interviewed for.", "My grandpa is in the hospital again.",
        "I have a dentist appointment next Tuesday at three.", "My sister's wedding is on June twelfth.",
        "We're flying to Lisbon on the fourth of March.", "I have a big exam on Friday morning and I'm nervous.",
        "Remind me to ask how my sister's interview went.", "Then I had a huge slice of chocolate cake.",
        "A seagull stole my brother's ice cream right out of his hand!", "Do you think she'll be happy?",
        "What's your favorite animal?", "Lettuce.", "Lettuce in, it's cold out here!", "I really miss her.",
        "Go on.", "Mm-hm.", "He is a good dog.", "D is for dinosaur.", "Lady Gaga is on tonight.", "Hey, the mail is here.",
        "I had a hot head about it.", "We took the commuter train.", "The computing lab is closed.",
        "Hey Rob, pass the salt.", "Hey dad, look at this.", "Hi there, how are you?", "Heat it up for a minute.",
        "The hood of the car is open.", "Okay, pick up your shoes.", "I got a D on my test.", "She hid it under the bed.",
        "They hate waiting in line.", "Hey, Robert is here.", "Can you compute the total?", "That pickle was sour.",
        "I told her the deadline was on Thursday.", "Hey, the delivery guy is at the door.",
        "The lady at the bakery gave us extra bread.", "He is driving to the D C office next week.",
        "Hey there, how have you been lately?", "We watched a show about an old computer museum.",
        "Okay, picture this: a tiny robot on a beach.", "I need to compute the total before dinner.",
        "Had a hot head about it, then I hid the heater.", "Did you see her robe? It was the color of the sea.",
        "Okay, go to sleep.", "That's all for now.", "Pass me the remote, would you?", "The kettle is boiling.",
        "Who left the fridge open again?", "I can't find my keys anywhere.", "Turn the volume down a little.",
        "Dinner will be ready in ten minutes.", "Did anyone feed the cat?", "It's freezing in here.",
        "Let's go for a walk after lunch.", "The game starts at seven thirty.", "Can you grab some milk on the way home?",
        "I think it's going to snow tonight.", "Where did I put my glasses?", "The baby is finally asleep.",
        "Have you seen the new episode yet?", "My phone battery is almost dead.", "We need to buy more coffee.",
        "The traffic was terrible this morning.", "Happy birthday to you!", "Breaking news from the capital tonight.",
        "And now, the weather for the weekend.", "Stay tuned for more after the break.", "The home team scores again!",
        "Call now and get a second one free.", "In other news, the river is rising.", "Scattered showers in the afternoon.",
        "The quarterback throws it deep.", "Our next guest needs no introduction.", "Thanks for watching, see you tomorrow.",
        "Hey, did you see that?", "Hey, wait up!", "Hi, how's it going?", "Hello, is anybody home?", "Okay, let's do this.",
        "Okay, that sounds good to me.", "Hey, can I borrow a pen?", "Hi honey, I'm home.", "Hey buddy, come here.",
        "Okay, everyone, listen up.", "The dog needs a bath.", "I'll be back in five minutes.", "Who wants pancakes?",
        "Let me check my calendar.", "Is the oven still on?", "The plants need watering.", "I'm going to take a shower.",
        "Please close the window.", "It's your turn to do the dishes.", "We should paint the hallway.",
        "My knee has been hurting all week.", "The package arrived this afternoon.", "Can you help me with my homework?",
        "What do you want for dinner?", "I love this song.", "Turn left at the next light.", "We're almost out of bread.",
        "She's coming over on Saturday.", "Grandma called while you were out.", "The internet is really slow today.",
        "Don't forget your umbrella.", "I'm so tired I could sleep for a week.", "That was the best pizza ever.",
        "Let's watch something funny.", "Have you finished your book?", "The neighbors are having a party.",
        "I think I left the lights on.", "Whose shoes are these?", "We need to leave by eight.",
        "Can you believe it's already October?", "The movie starts in an hour.", "I'll make some tea.",
        "My brother just got a new puppy.", "Let's try the new restaurant downtown.", "The bus was late again.",
        "Can you turn on the fan?", "I'm learning to play the guitar.", "The garden looks lovely this year.",
        "What a beautiful sunset.", "Did you lock the door?", "I'm running a little late.", "Is there any cake left?",
        "The heater is making a funny noise.", "We should call the plumber.", "That joke was terrible.",
        "I'll pick the kids up from school.", "Do we have any batteries?", "The meeting got moved to Monday.",
        "The cat is sleeping on my laptop again.", "Let's play a board game tonight.", "I need a haircut.",
        "Did you hear that thunder?", "The soup needs more salt.", "Grab a jacket, it's chilly.",
        "My favorite season is autumn.", "Can you read me a story?", "I can't believe he said that.",
        "The library closes at six.", "We're having fish tonight.", "The printer is out of ink.",
        "Okay, I'm ready when you are.", "Hey, nice haircut!", "Hi, I'm calling about the apartment.",
    ]
}
