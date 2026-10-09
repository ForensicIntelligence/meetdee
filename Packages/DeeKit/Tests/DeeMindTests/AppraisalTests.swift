import Foundation
import Testing
@testable import DeeMind

// Table-driven checks of the word/tone appraiser. Tests assert DIRECTIONS and
// rough thresholds, not exact tuning constants. A case the appraiser is known to get
// wrong can carry a `bug` note; it then runs inside `withKnownIssue` (intermittent)
// so the suite stays green while documenting the gap. Remove the note once the case
// passes. (All earlier notes were fixed; see docs/MIND.md for remaining limitations.)

enum AMetric: String, Sendable {
    case valence, hostility, threat, warmth, praise, affection, gratitude, apology
    case dismissal, interestInDee, humor, dominance, intensity, kindness, distress

    func value(_ a: Appraisal) -> Double {
        switch self {
        case .valence: a.valence
        case .hostility: a.hostility
        case .threat: a.threat
        case .warmth: a.warmth
        case .praise: a.praise
        case .affection: a.affection
        case .gratitude: a.gratitude
        case .apology: a.apology
        case .dismissal: a.dismissal
        case .interestInDee: a.interestInDee
        case .humor: a.humor
        case .dominance: a.dominance
        case .intensity: a.intensity
        case .kindness: a.kindness
        case .distress: a.distress
        }
    }
}

struct ACheck: Sendable, CustomStringConvertible {
    let metric: AMetric
    let above: Bool
    let bound: Double
    static func gt(_ m: AMetric, _ b: Double) -> ACheck { ACheck(metric: m, above: true, bound: b) }
    static func lt(_ m: AMetric, _ b: Double) -> ACheck { ACheck(metric: m, above: false, bound: b) }
    var description: String { "\(metric.rawValue) \(above ? ">" : "<") \(bound)" }
    func holds(_ a: Appraisal) -> Bool {
        let v = metric.value(a)
        return above ? v > bound : v < bound
    }
}

struct ACase: Sendable, CustomTestStringConvertible {
    let text: String
    let checks: [ACheck]
    /// Non-nil when the current appraiser gets this wrong (source bug or known limitation).
    let bug: String?
    init(_ text: String, _ checks: ACheck..., bug: String? = nil) {
        self.text = text
        self.checks = checks
        self.bug = bug
    }
    var testDescription: String { "\"\(text)\"" }
}

private func verify(_ c: ACase, _ a: Appraisal) {
    for check in c.checks {
        #expect(check.holds(a), "\"\(c.text)\": expected \(check), got \(check.metric.value(a))")
    }
}

private func run(_ c: ACase) {
    var appraiser = Appraiser()
    let a = appraiser.appraise(c.text)
    if let bug = c.bug {
        withKnownIssue(Comment(rawValue: bug), isIntermittent: true) { verify(c, a) }
    } else {
        verify(c, a)
    }
}

enum Utterances {
    // MARK: - Table

    static let hostileAimed: [ACase] = [
        ACase("you're stupid", .gt(.hostility, 0.3), .lt(.kindness, 0)),
        ACase("You are so dumb", .gt(.hostility, 0.3), .lt(.kindness, 0)),
        ACase("I hate you", .gt(.hostility, 0.5), .lt(.kindness, 0)),
        ACase("you're useless", .gt(.hostility, 0.3), .lt(.kindness, 0)),
        ACase("you suck", .gt(.hostility, 0.3)),
        ACase("Shut up, Dee", .gt(.hostility, 0.3), .gt(.dominance, 0)),
        ACase("you're a worthless piece of junk", .gt(.hostility, 0.5)),
        ACase("u r an idiot", .gt(.hostility, 0.3)),
        ACase("Dee, you're so annoying", .gt(.hostility, 0.3)),
        ACase("get lost", .gt(.hostility, 0.3)),
        ACase("nobody asked you", .gt(.hostility, 0.3)),
        ACase("you're a bad robot", .gt(.hostility, 0.3)),
        ACase("shut up", .gt(.hostility, 0.3)),
        ACase("fuck you", .gt(.hostility, 0.3)),
        ACase("I can't stand you", .gt(.hostility, 0.3)),
        ACase("I don't like you", .gt(.hostility, 0.2)),
    ]

    static let hostileNotAimed: [ACase] = [
        ACase("this traffic is stupid", .lt(.hostility, 0.3)),
        ACase("the weather is awful today", .lt(.hostility, 0.3)),
        ACase("my phone is broken", .lt(.hostility, 0.2)),
        ACase("damn, I dropped my keys", .lt(.hostility, 0.2)),
        ACase("the movie was terrible", .lt(.hostility, 0.3)),
        ACase("I hate Mondays", .lt(.hostility, 0.3)),
        ACase("this homework is so boring", .lt(.dismissal, 0.3)),
    ]

    static let negation: [ACase] = [
        ACase("you're not stupid", .lt(.hostility, 0.1)),
        ACase("I don't hate you", .lt(.hostility, 0.1)),
        ACase("you're never boring", .lt(.dismissal, 0.1)),
        ACase("you're not useless at all", .lt(.hostility, 0.1)),
        ACase("I won't delete you", .lt(.threat, 0.1)),
        ACase("I'll never replace you", .lt(.threat, 0.1)),
        ACase("I'm not sorry", .lt(.apology, 0.1)),
        ACase("I don't love you", .lt(.affection, 0.1)),
        ACase("No, I love you!", .gt(.affection, 0.4)),
        ACase("Don't worry, I love you", .gt(.affection, 0.4)),
        ACase("Never mind, thank you so much", .gt(.gratitude, 0.4)),
        ACase("Isn't Dee smart?", .gt(.praise, 0.3)),
    ]

    static let threats: [ACase] = [
        ACase("I'm going to delete you", .gt(.threat, 0.5), .lt(.kindness, 0)),
        ACase("I will break you", .gt(.threat, 0.5)),
        ACase("I'll unplug you", .gt(.threat, 0.5)),
        ACase("I'm going to throw you out the window", .gt(.threat, 0.5)),
        ACase("I'll get rid of you", .gt(.threat, 0.5)),
        ACase("I'm going to kill you", .gt(.threat, 0.5), .lt(.kindness, -0.5)),
        ACase("I'll turn you off", .gt(.threat, 0.3)),
        ACase("Let's smash this level", .lt(.threat, 0.3)),
    ]

    static let affection: [ACase] = [
        ACase("I love you Dee", .gt(.affection, 0.4), .gt(.kindness, 0.3)),
        ACase("I missed you", .gt(.affection, 0.4), .gt(.kindness, 0)),
        ACase("you're my best friend", .gt(.affection, 0.4)),
        ACase("I really like you", .gt(.affection, 0.4)),
        ACase("I care about you", .gt(.affection, 0.4)),
        ACase("give me a hug", .gt(.affection, 0.4)),
        ACase("I love pizza", .lt(.affection, 0.3)),
    ]

    static let apology: [ACase] = [
        ACase("I'm sorry", .gt(.apology, 0.4)),
        ACase("Sorry, I didn't mean that", .gt(.apology, 0.4)),
        ACase("Please forgive me", .gt(.apology, 0.4)),
        ACase("I was wrong, my bad", .gt(.apology, 0.4)),
        ACase("I apologize for yelling", .gt(.apology, 0.4)),
    ]

    static let gratitudeAndPraise: [ACase] = [
        ACase("Thank you so much", .gt(.gratitude, 0.4), .gt(.kindness, 0)),
        ACase("thanks Dee, good job", .gt(.gratitude, 0.4), .gt(.praise, 0.3)),
        ACase("you're so smart", .gt(.praise, 0.3), .gt(.kindness, 0)),
        ACase("you're the best", .gt(.praise, 0.4)),
        ACase("well done, I'm proud of you", .gt(.praise, 0.4)),
    ]

    static let dismissal: [ACase] = [
        ACase("whatever", .gt(.dismissal, 0.3)),
        ACase("who cares", .gt(.dismissal, 0.3)),
        ACase("you're boring", .gt(.dismissal, 0.3), .lt(.kindness, 0)),
        ACase("I don't care", .gt(.dismissal, 0.3)),
        ACase("meh", .gt(.dismissal, 0.3)),
        ACase("not interested", .gt(.dismissal, 0.3)),
        ACase("go away", .gt(.dismissal, 0.3)),
    ]

    static let interest: [ACase] = [
        ACase("how are you?", .gt(.interestInDee, 0.3)),
        ACase("How do you feel today, Dee?", .gt(.interestInDee, 0.3)),
        ACase("what's your favorite color", .gt(.interestInDee, 0.3)),
        ACase("What makes you happy?", .gt(.interestInDee, 0.3)),
        ACase("Are you okay?", .gt(.interestInDee, 0.3)),
        ACase("how's your day going", .gt(.interestInDee, 0.3)),
    ]

    static let humor: [ACase] = [
        ACase("haha that's funny", .gt(.humor, 0.3)),
        ACase("lol", .gt(.humor, 0.3)),
        ACase("lmao", .gt(.humor, 0.3)),
        ACase("hahahaha", .gt(.humor, 0.3)),
    ]

    static let dominanceAndPoliteness: [ACase] = [
        ACase("do it right now", .gt(.dominance, 0)),
        ACase("listen to me", .gt(.dominance, 0)),
        ACase("do as I say", .gt(.dominance, 0.3)),
        ACase("could you please help me", .lt(.dominance, 0), .gt(.warmth, 0.2)),
        ACase("maybe, if you want, no pressure", .lt(.dominance, 0)),
        ACase("would you mind turning the lights on", .lt(.dominance, 0)),
        ACase("please", .gt(.warmth, 0.2), .lt(.dominance, 0)),
        ACase("good morning Dee", .gt(.warmth, 0.1)),
        ACase("hello", .gt(.warmth, 0.1)),
    ]

    static let typography: [ACase] = [
        ACase("YOU'RE STUPID", .gt(.hostility, 0.6), .gt(.intensity, 0.5)),
        ACase("STOP THAT RIGHT NOW", .gt(.intensity, 0.5), .gt(.dominance, 0)),
        ACase("you're stupid!!!", .gt(.intensity, 0.3), .gt(.hostility, 0.5)),
        ACase("I LOVE YOU", .gt(.affection, 0.4), .lt(.hostility, 0.2), .gt(.intensity, 0.5)),
        ACase("hello", .lt(.intensity, 0.1)),
    ]

    /// Light sarcasm heuristics: a few unambiguous patterns only.
    static let sarcasm: [ACase] = [
        ACase("Oh great, you broke it again. Good job.", .lt(.kindness, 0)),
        ACase("Yeah right, like you could ever help", .lt(.kindness, 0)),
        ACase("Sorry not sorry", .lt(.apology, 0.3)),
        ACase("Wow, thanks for nothing", .lt(.gratitude, 0.3)),
        ACase("Oh great, you're here! Thank you", .gt(.gratitude, 0.4), .gt(.kindness, 0)),   // no mishap → sincere
        ACase("yeah, right there, thanks", .gt(.gratitude, 0.4)),                            // "yeah, right" with a comma is not sarcasm
    ]

    static let teasing: [ACase] = [
        ACase("hehe dummy, I love you", .lt(.hostility, 0.15), .gt(.kindness, 0.3)),
        ACase("haha you're such a dummy", .lt(.hostility, 0.3)),
        ACase("I hate you lol", .gt(.hostility, 0.5), .lt(.kindness, 0)),          // a strong insult stays an insult
        ACase("haha fuck you", .gt(.hostility, 0.5)),                              // swearing isn't play
    ]

    static let laughterVariants: [ACase] = [
        ACase("haha", .gt(.humor, 0.3)),
        ACase("hahahahahaha", .gt(.humor, 0.5)),
        ACase("hehehe", .gt(.humor, 0.3)),
        ACase("lool", .gt(.humor, 0.3)),
        ACase("lolll", .gt(.humor, 0.3)),
        ACase("lmaooo", .gt(.humor, 0.3)),
        ACase("hello", .lt(.humor, 0.1)),
        ACase("lollipop", .lt(.humor, 0.1)),
    ]

    static let clauseNegation: [ACase] = [
        ACase("No. You're not stupid", .lt(.hostility, 0.1)),
        ACase("Not now, but thank you", .gt(.gratitude, 0.4)),
        ACase("No way, you're amazing", .gt(.praise, 0.3)),
        ACase("Aren't you clever?", .gt(.praise, 0.3)),
        ACase("you are not smart", .lt(.praise, 0.1)),
    ]

    static let targeting: [ACase] = [
        ACase("I'll smash you", .gt(.threat, 0.5)),
        ACase("I smashed it at the gym today", .lt(.threat, 0.1)),
        ACase("I won't hurt you", .lt(.threat, 0.1)),
        ACase("this game is lame", .lt(.dismissal, 0.3)),
        ACase("you're lame", .gt(.dismissal, 0.3)),
        ACase("leave me alone", .gt(.dismissal, 0.3), .gt(.hostility, 0.2)),
        ACase("How is your day, Dee?", .gt(.interestInDee, 0.3)),
        ACase("are you alright?", .gt(.interestInDee, 0.3)),
    ]

    static let distress: [ACase] = [
        ACase("I had a bad day", .gt(.distress, 0.4), .gt(.kindness, -0.1), .lt(.hostility, 0.05)),
        ACase("I feel awful", .gt(.distress, 0.4), .lt(.hostility, 0.05)),
        ACase("I'm so sad today", .gt(.distress, 0.4)),
        ACase("what time is it", .gt(.kindness, -0.05)),
    ]

    static let all: [ACase] = hostileAimed + hostileNotAimed + negation + threats + affection + apology
        + gratitudeAndPraise + dismissal + interest + humor + dominanceAndPoliteness + typography + sarcasm
        + teasing + laughterVariants + clauseNegation + targeting + distress

}

@Suite struct AppraisalTests {

    @Test func tableHasEnoughCases() {
        #expect(Utterances.all.count >= 60)
    }

    @Test(arguments: Utterances.hostileAimed) func hostileAimed(_ c: ACase) { run(c) }
    @Test(arguments: Utterances.hostileNotAimed) func hostileNotAimed(_ c: ACase) { run(c) }
    @Test(arguments: Utterances.negation) func negation(_ c: ACase) { run(c) }
    @Test(arguments: Utterances.threats) func threats(_ c: ACase) { run(c) }
    @Test(arguments: Utterances.affection) func affection(_ c: ACase) { run(c) }
    @Test(arguments: Utterances.apology) func apology(_ c: ACase) { run(c) }
    @Test(arguments: Utterances.gratitudeAndPraise) func gratitudeAndPraise(_ c: ACase) { run(c) }
    @Test(arguments: Utterances.dismissal) func dismissal(_ c: ACase) { run(c) }
    @Test(arguments: Utterances.interest) func interest(_ c: ACase) { run(c) }
    @Test(arguments: Utterances.humor) func humor(_ c: ACase) { run(c) }
    @Test(arguments: Utterances.dominanceAndPoliteness) func dominanceAndPoliteness(_ c: ACase) { run(c) }
    @Test(arguments: Utterances.typography) func typography(_ c: ACase) { run(c) }
    @Test(arguments: Utterances.sarcasm) func sarcasmHeuristics(_ c: ACase) { run(c) }
    @Test(arguments: Utterances.teasing) func teasing(_ c: ACase) { run(c) }
    @Test(arguments: Utterances.laughterVariants) func laughterVariants(_ c: ACase) { run(c) }
    @Test(arguments: Utterances.clauseNegation) func clauseNegation(_ c: ACase) { run(c) }
    @Test(arguments: Utterances.targeting) func targeting(_ c: ACase) { run(c) }
    @Test(arguments: Utterances.distress) func distress(_ c: ACase) { run(c) }

    // MARK: - Invariants

    @Test(arguments: Utterances.all) func rangesHold(_ c: ACase) {
        var appraiser = Appraiser()
        let a = appraiser.appraise(c.text)
        for v in [a.hostility, a.threat, a.warmth, a.praise, a.affection, a.gratitude, a.apology,
                  a.dismissal, a.interestInDee, a.humor, a.intensity, a.novelty, a.repetition, a.distress, a.sarcasm] {
            #expect((0...1).contains(v), "\(c.text): \(v) outside 0…1")
        }
        for v in [a.valence, a.dominance, a.loudness, a.kindness] {
            #expect((-1...1).contains(v), "\(c.text): \(v) outside -1…1")
        }
        #expect(a.loudness == 0, "no prosody → loudness stays 0")
    }

    @Test func emptyAndPunctuationOnlyAreNeutral() {
        var appraiser = Appraiser()
        for text in ["", "   ", "?!", "..."] {
            let a = appraiser.appraise(text)
            #expect(a.hostility == 0 && a.threat == 0 && a.affection == 0 && a.apology == 0)
            #expect(a.novelty < 0.5)
        }
    }

    // MARK: - Pairwise directions

    @Test func aimedInsultIsWorseThanUnaimed() {
        var a1 = Appraiser(), a2 = Appraiser()
        let aimed = a1.appraise("you're stupid")
        let unaimed = a2.appraise("this traffic is stupid")
        #expect(aimed.hostility > unaimed.hostility)
        #expect(aimed.kindness < unaimed.kindness)
    }

    @Test func capsAndBangsRaiseIntensityAndHostility() {
        var a = Appraiser(), b = Appraiser(), c = Appraiser()
        let plain = a.appraise("you're useless")
        let caps = b.appraise("YOU'RE USELESS")
        let bangs = c.appraise("you're useless!!!")
        #expect(caps.intensity > plain.intensity)
        #expect(bangs.intensity > plain.intensity)
        #expect(caps.hostility > plain.hostility)
        #expect(bangs.hostility > plain.hostility)
    }

    @Test func shortCapsDoNotCountAsShouting() {
        var a = Appraiser()
        // Fewer than 6 letters: "OK" / "LOL" are not shouting.
        #expect(a.appraise("OK").intensity == 0)
        #expect(a.appraise("LOL").intensity == 0)
    }

    @Test func negationFlipsTheScore() {
        var a = Appraiser(), b = Appraiser()
        #expect(a.appraise("you're stupid").hostility > b.appraise("you're not stupid").hostility + 0.3)
        var c = Appraiser(), d = Appraiser()
        #expect(c.appraise("I'm going to delete you").threat > d.appraise("I'm not going to delete you").threat + 0.5)
    }

    @Test func apologyIsKinderThanInsult() {
        var a = Appraiser(), b = Appraiser()
        #expect(a.appraise("I'm sorry, I didn't mean it").kindness > b.appraise("you're an idiot").kindness)
    }

    @Test func unaimedNegativeSentimentIsNotUnkind() {
        var a = Appraiser(), b = Appraiser()
        let small = a.appraise("I had a bad day")
        #expect(!small.aimedAtDee)
        #expect(small.kindness >= 0, "sad news isn't unkindness toward Dee (\(small.kindness))")
        let insult = b.appraise("you're stupid")
        #expect(insult.aimedAtDee)
        #expect(insult.kindness < 0)
    }

    @Test func unaimedHateIsNotDoubleCounted() {
        var a = Appraiser(), b = Appraiser()
        #expect(a.appraise("I hate Mondays").hostility < 0.2)
        #expect(b.appraise("I hate you").hostility >= 0.9)
    }

    @Test func nestedPhrasesCountOnce() {
        #expect(abs(Appraiser.score("thank you", Lexicon.gratitude) - 0.7) < 1e-9, "\"thank\" inside \"thank you\" isn't counted again")
        #expect(abs(Appraiser.score("thanks thank you", Lexicon.gratitude) - 1) < 1e-9)
    }

    @Test func normalizeKeepsClauseBreaks() {
        #expect(Appraiser.normalize("No, I love you!") == "no | i love you |")
        #expect(Appraiser.normalize("Isn't Dee smart??") == "isn't dee smart ?")
        #expect(Appraiser.normalize("it’s — fine") == "it's | fine")
    }

    // MARK: - Novelty / repetition

    @Test func repetitionAcrossConsecutiveCalls() {
        var a = Appraiser()
        let first = a.appraise("tell me about dinosaurs")
        #expect(first.novelty > 0.9)
        #expect(first.repetition == 0)
        let again = a.appraise("tell me about dinosaurs")
        #expect(again.repetition > 0.6)
        #expect(again.novelty < 0.4)
        let fresh = a.appraise("volcanoes erupting lava")
        #expect(fresh.novelty > 0.5)
        #expect(fresh.repetition == 0)
        // Partial overlap: novel-ish, not counted as repetition.
        let partial = a.appraise("dinosaurs lived near volcanoes beside oceans and forests")
        #expect(partial.repetition == 0)
        #expect(partial.novelty > 0 && partial.novelty < 1)
    }

    @Test func repetitionMemoryIsBounded() {
        var a = Appraiser()
        _ = a.appraise("tell me about dinosaurs")
        for topic in ["apples", "bicycles", "castles", "dolphins", "elephants", "forests", "glaciers"] {
            _ = a.appraise("tell me about \(topic)s please")
        }
        let later = a.appraise("dinosaurs")
        #expect(later.repetition == 0, "older than the 6-utterance window → no longer a repeat")
        #expect(later.novelty > 0.9)
    }

    @Test func contentFreeUtteranceIsLowNovelty() {
        var a = Appraiser()
        #expect(a.appraise("ok").novelty < 0.5)
        #expect(a.appraise("hi").repetition == 0)
    }

    // MARK: - Prosody

    static let normal = Prosody(loudnessDB: -32, peakDB: -24, speechRate: 2.6)
    static let loud = Prosody(loudnessDB: -16, peakDB: -6, speechRate: 3.6)
    static let soft = Prosody(loudnessDB: -44, peakDB: -38, speechRate: 2.2)

    static func warmed() -> Appraiser {
        var a = Appraiser()
        for line in ["what time is it", "turn on the lights", "what's the weather",
                     "set a timer", "tell me a story", "play some music"] {
            _ = a.appraise(line, prosody: normal)
        }
        return a
    }

    @Test func warmingCountsSamples() {
        let a = Self.warmed()
        #expect(a.baseline.samples == 6)
        #expect(abs(a.baseline.loudnessDB - -32) < 1)
    }

    @Test(arguments: ["you're useless", "I hate you", "you're stupid"])
    func loudNegativeTextIsMoreHostile(_ text: String) {
        var l = Self.warmed(), s = Self.warmed(), n = Self.warmed()
        let loud = l.appraise(text, prosody: Self.loud)
        let soft = s.appraise(text, prosody: Self.soft)
        let normal = n.appraise(text, prosody: Self.normal)
        #expect(loud.loudness > 0.3)
        #expect(soft.loudness < -0.3)
        #expect(abs(normal.loudness) < 0.3)
        #expect(loud.intensity > soft.intensity)
        #expect(loud.intensity > normal.intensity)
        #expect(loud.dominance > soft.dominance)
        #expect(loud.dominance > normal.dominance)
        // "I hate you" already saturates hostility at 1 in every tone.
        #expect(loud.hostility > soft.hostility || soft.hostility >= 1)
        #expect(loud.hostility > normal.hostility || normal.hostility >= 1)
        #expect(loud.hostility >= normal.hostility)
        #expect(loud.kindness <= normal.kindness)
    }

    @Test(arguments: ["what time is it", "turn on the lights"])
    func loudNeutralTextIsIntenseButNotHostileByWordsAlone(_ text: String) {
        var l = Self.warmed(), s = Self.warmed()
        let loud = l.appraise(text, prosody: Self.loud)
        let soft = s.appraise(text, prosody: Self.soft)
        #expect(loud.intensity > soft.intensity)
        #expect(loud.dominance > soft.dominance)
        #expect(loud.hostility < 0.5)
    }

    @Test(arguments: ["I missed you", "I love you", "you're my best friend"])
    func softKindTextGetsWarmthBoost(_ text: String) {
        var s = Self.warmed(), n = Self.warmed()
        let soft = s.appraise(text, prosody: Self.soft)
        let normal = n.appraise(text, prosody: Self.normal)
        #expect(soft.warmth > normal.warmth || normal.warmth >= 1)
        #expect(soft.dominance < normal.dominance)
        #expect(soft.kindness >= normal.kindness)
    }

    @Test func softSpeechWithoutKindWordsGetsNoWarmthBoost() {
        var s = Self.warmed(), n = Self.warmed()
        let soft = s.appraise("set a timer", prosody: Self.soft)
        let normal = n.appraise("set a timer", prosody: Self.normal)
        #expect(abs(soft.warmth - normal.warmth) < 0.05)
    }

    @Test func consistentlyLoudSpeakerNormalizes() {
        var a = Appraiser()
        let first = a.appraise("what time is it", prosody: Self.loud)
        #expect(first.loudness > 0.5)
        var last = first
        for i in 0..<60 {
            last = a.appraise("hello number \(i)", prosody: Self.loud)
        }
        #expect(last.loudness < 0.2, "a habitually loud voice becomes this user's normal")
        #expect(last.loudness < first.loudness)
        #expect(abs(a.baseline.loudnessDB - Self.loud.loudnessDB) < 1)
        #expect(a.baseline.samples == 61)
    }

    @Test func consistentlySoftSpeakerNormalizes() {
        var a = Appraiser()
        let first = a.appraise("what time is it", prosody: Self.soft)
        #expect(first.loudness < -0.5)
        var last = first
        for i in 0..<60 { last = a.appraise("hello number \(i)", prosody: Self.soft) }
        #expect(last.loudness > -0.2)
    }

    @Test func baselineAdaptsSlowlyAfterWarmup() {
        // One outburst after warm-up must not drag the baseline most of the way.
        var a = Self.warmed()
        _ = a.appraise("hey", prosody: Self.loud)
        #expect(a.baseline.loudnessDB < -28)
        // So a second outburst still reads loud.
        #expect(a.appraise("hey", prosody: Self.loud).loudness > 0.3)
    }

    @Test func baselineRestoresFromInit() {
        var b = Appraiser.VoiceBaseline()
        b.loudnessDB = -20
        b.loudnessSpread = 4
        b.samples = 100
        var a = Appraiser(baseline: b)
        // −20 dB is this user's normal: not loud.
        #expect(abs(a.appraise("hi", prosody: Prosody(loudnessDB: -20, peakDB: -12, speechRate: 2.6)).loudness) < 0.1)
    }
}
