import Testing
@testable import DeeCore

/// Product rule: thinking is OFF by default. Explicit requests to deliberate
/// ("think about it", "take your time", ...) ENABLE it; explicit requests to be
/// quick ("stop thinking", "don't overthink", ...) DISABLE it; every ordinary
/// use of "think" (opinions, "I think ...", narration) is `.none`.
///
/// Decisions documented here:
/// - "rethink" (and "unthinkable", "thinker") -> `.none`: the user is talking
///   about *their* plans, not asking Dee to deliberate.
/// - "Can you think of a name ..." / "think of a number" -> `.none`:
///   "think of" means brainstorm/recall, which needs no reasoning trace.
/// - "I'll think about it" / "Let me think about it" -> `.none`: the speaker
///   is the one thinking.
/// - "give me step by step instructions ..." -> `.none`: a request for a
///   formatted answer, not for deliberation ("think step by step" still enables).
@Suite("ThinkingIntent classification")
struct ThinkingIntentTests {

    struct Case: Sendable, CustomTestStringConvertible {
        let utterance: String
        let expected: ThinkingIntent
        /// Non-nil when the current detector disagrees with the product rule.
        let knownBug: String?

        init(_ utterance: String, _ expected: ThinkingIntent, bug: String? = nil) {
            self.utterance = utterance
            self.expected = expected
            self.knownBug = bug
        }

        var testDescription: String { "\"\(utterance)\" -> \(expected)" }
    }

    static let cases: [Case] = [
        // MARK: enable
        Case("think about it", .enable),
        Case("Think about it.", .enable),
        Case("THINK ABOUT IT", .enable),
        Case("Can you think about it?", .enable),
        Case("Think about it, Dee!", .enable),
        Case("think it over", .enable),
        Case("Please think it over before replying", .enable),
        Case("think hard", .enable),
        Case("Think hard about this one", .enable),
        Case("think harder", .enable),
        Case("think carefully", .enable),
        Case("think it through", .enable),
        Case("Hmm, could you think this through for me?", .enable),
        Case("think deeply about life", .enable),
        Case("take your time", .enable),
        Case("Take your time with this.", .enable),
        Case("I'm not sure. What do you think about it? Take your time.", .enable),
        Case("think step by step", .enable),
        Case("Let's think step by step.", .enable),
        Case("reason it through", .enable),
        Case("Reason this through carefully", .enable),
        Case("work it out", .enable),
        Case("put your thinking cap on", .enable),
        Case("Put on your thinking cap", .enable),
        Case("mull it over", .enable),
        Case("ponder this", .enable),
        Case("have a think", .enable),
        Case("give it some thought", .enable),
        Case("use your brain", .enable),
        Case("think before you answer", .enable),
        Case("turn on thinking mode", .enable),
        Case("sleep on it", .enable),
        Case("Stop and think about it", .enable),
        Case("turn on thinking", .enable),

        // MARK: disable
        Case("stop thinking", .disable),
        Case("Stop thinking so much", .disable),
        Case("turn off thinking", .disable),
        Case("Turn thinking off", .disable),
        Case("switch off thinking mode", .disable),
        Case("don't overthink", .disable),
        Case("Don't overthink it.", .disable),
        Case("Don\u{2019}t overthink it", .disable),
        Case("just answer quickly", .disable),
        Case("answer fast", .disable),
        Case("Answer immediately", .disable),
        Case("don't think about it", .disable),
        Case("Do not think about it", .disable),
        Case("dont think about it", .disable),
        Case("no need to think about it", .disable),
        Case("You don't need to think about it", .disable),
        Case("Could you please not think about it", .disable),
        Case("Don't ponder this, just answer", .disable),
        Case("no more thinking", .disable),
        Case("quit overthinking", .disable),
        Case("don't think too hard", .disable),

        // MARK: none
        Case("what do you think about cats?", .none),
        Case("I think it's raining", .none),
        Case("do you think I should go?", .none),
        Case("I thought about you", .none),
        Case("what do you think of my plan", .none),
        Case("thanks", .none),
        Case("Let me rethink my plans", .none),
        Case("rethink", .none),
        Case("Can you think of a name for my dog?", .none),
        Case("Think of a number", .none),
        Case("hello", .none),
        Case("", .none),
        Case("   ", .none),
        Case("!!!", .none),
        Case("I'm thinking of pizza for dinner", .none),
        Case("What are you thinking?", .none),
        Case("Do you ever think about the stars?", .none),
        Case("What do you really think about it?", .none),
        Case("How do you think about risk?", .none),
        Case("We thought about moving", .none),
        Case("They think on their feet", .none),
        Case("Thinking of you", .none),
        Case("What should I think about pizza?", .none),
        Case("I think about you every day", .none),
        Case("I never think about it", .none),
        Case("That's unthinkable", .none),
        Case("The Thinker is a statue", .none),
        Case("Who do you think will win?", .none),
        Case("what do you think", .none),
        Case("I think so", .none),
        Case("Tell me a joke", .none),
        Case("What's the time?", .none),
        Case("She thinks about it a lot", .none),
        Case("Do you think about it often?", .none),
        Case("I'll think about it", .none),
        Case("Let me think about it", .none),
        Case("I have a thought", .none),
        Case("Give me step by step instructions for baking bread", .none),
        Case("I can't stop thinking about you", .none),
    ]

    @Test("utterance classification", arguments: cases)
    func classify(_ c: Case) {
        let actual = ThinkingIntent.detect(in: c.utterance)
        if let bug = c.knownBug {
            withKnownIssue("SOURCE BUG: \(bug)") {
                #expect(actual == c.expected, "\"\(c.utterance)\"")
            }
        } else {
            #expect(actual == c.expected, "\"\(c.utterance)\"")
        }
    }

    @Test func tableIsLargeEnough() {
        #expect(Self.cases.count >= 60)
        #expect(Set(Self.cases.map(\.utterance)).count == Self.cases.count, "duplicate utterances")
    }

    @Test func defaultIsOffForEmptyAndPlainChat() {
        #expect(ThinkingIntent.detect(in: "") == .none)
        #expect(ThinkingIntent.detect(in: "Good morning, Dee") == .none)
    }

    @Test func normalizeFoldsCurlyApostrophesAndPunctuation() {
        #expect(ThinkingIntent.normalize("  Don\u{2019}t   OVER-think!! ") == "don't over think")
    }
}
