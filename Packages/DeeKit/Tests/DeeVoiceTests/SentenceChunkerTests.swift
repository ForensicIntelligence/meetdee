import Testing
@testable import DeeVoice

@Suite struct SpeechTextTests {
    @Test func stripsEmotionTagsAndAngleTags() {
        #expect(SpeechText.clean("[happy] Hi there!") == "Hi there!")
        #expect(SpeechText.clean("Hello [Excited]friend") == "Hello friend")
        #expect(SpeechText.clean("<think>x</think>Okay.") == "Okay.")   // v0.5: reasoning blocks are never spoken
    }

    @Test func stripsMarkdown() {
        #expect(SpeechText.clean("**Bold** and *italic* and __under__") == "Bold and italic and under")
        #expect(SpeechText.clean("# Title") == "Title")
        #expect(SpeechText.clean("- one\n- two") == "one two")
        #expect(SpeechText.clean("1. first\n2. second") == "first second")
        #expect(SpeechText.clean("See [the docs](https://x.y/z) now") == "See the docs now")
        #expect(SpeechText.clean("Run `ls` please") == "Run ls please")
        #expect(SpeechText.clean("```swift\nlet x = 1\n```\nDone.") == "Done.")
        #expect(SpeechText.clean("> quoted") == "quoted")
        #expect(SpeechText.clean("snake_case_name stays") == "snake_case_name stays")
    }

    @Test func stripsEmoji() {
        #expect(SpeechText.clean("Yay 🎉🎉 you did it 😊") == "Yay you did it")
        #expect(SpeechText.clean("Family 👨‍👩‍👧 time") == "Family time")
        #expect(SpeechText.clean("Thumbs 👍🏽 up") == "Thumbs up")
        #expect(SpeechText.clean("Canada 🇨🇦!") == "Canada!")
        #expect(SpeechText.clean("Love ❤️ you") == "Love you")
        #expect(SpeechText.clean("I have 3 cats and #1 fan") == "I have 3 cats and #1 fan")
    }

    @Test func laughStageDirectionsBecomeALaugh() {
        #expect(SpeechText.clean("*giggles* That's silly!") == "Hehe! That's silly!")
        #expect(SpeechText.clean("*laughs softly* okay") == "Hehe! okay")
        #expect(SpeechText.clean("That's *really* good") == "That's really good")
    }

    @Test func nothingToSay() {
        #expect(SpeechText.clean("[happy]") == "")
        #expect(SpeechText.clean("😊 ✨") == "")
        #expect(SpeechText.clean("...") == "")
        #expect(SpeechText.clean("   ") == "")
    }
}

@Suite struct SentenceChunkerTests {
    func feed(_ parts: [String], flush: Bool = true) -> [String] {
        var c = SentenceChunker()
        var out: [String] = []
        for p in parts { out += c.append(p) }
        if flush { out += c.flush() }
        return out
    }

    @Test func splitsOnSentenceEnds() {
        #expect(feed(["Hello there. How are you? I'm great!"]) == ["Hello there.", "How are you?", "I'm great!"])
    }

    @Test func emitsAsSoonAsASentenceCompletes() {
        var c = SentenceChunker()
        #expect(c.append("Hi") == [])
        #expect(c.append(" there.") == [])          // could still be "there.5"? wait for next char
        #expect(c.append(" How") == ["Hi there."])
        #expect(c.append(" are you?") == [])
        #expect(c.flush() == ["How are you?"])
    }

    @Test func tokensSplitAcrossFragments() {
        #expect(feed(["I l", "ove th", "is. It", "'s gre", "at!"]) == ["I love this.", "It's great!"])
    }

    @Test func abbreviationsDoNotSplit() {
        #expect(feed(["Dr. Smith met Mrs. Jones, e.g. at 5 p.m. today. Bye."])
                == ["Dr. Smith met Mrs. Jones, e.g. at 5 p.m. today.", "Bye."])
        #expect(feed(["J. R. R. Tolkien wrote it. Yes."]) == ["J. R. R. Tolkien wrote it.", "Yes."])
        #expect(feed(["The U.S.A. is big. Ok."]).count == 2)
    }

    @Test func numbersDoNotSplit() {
        #expect(feed(["Pi is 3.14159 roughly. It costs $1,000.50 now."])
                == ["Pi is 3.14159 roughly.", "It costs $1,000.50 now."])
        var c = SentenceChunker()
        #expect(c.append("It is 3.") == [])
        #expect(c.append("5 degrees. ") == ["It is 3.5 degrees."])
    }

    @Test func sentenceEndingInANumberSplits() {
        #expect(feed(["I am 3. You are 4."]) == ["I am 3.", "You are 4."])
    }

    @Test func runsOfPunctuation() {
        #expect(feed(["Wait... what?! Really? \"Yes.\" Ok"]) == ["Wait...", "what?!", "Really?", "\"Yes.\"", "Ok"])
    }

    @Test func newlinesAndLists() {
        #expect(feed(["Things:\n1. Apples\n2. Pears\n\nDone"]) == ["Things:", "Apples", "Pears", "Done"])
    }

    @Test func stripsTagsMarkdownEmojiPerSentence() {
        #expect(feed(["[happy] **Yay!** 🎉 That's *so* fun. [giggle]"]) == ["Yay!", "That's so fun."])
    }

    @Test func tagSplitAcrossFragments() {
        #expect(feed(["[exc", "ited] Hi! [sa", "d] Oh."]) == ["Hi!", "Oh."])
    }

    @Test func longRunsAreCut() {
        let long = String(repeating: "word, ", count: 80)
        var c = SentenceChunker(maxLength: 120)
        let out = c.append(long)
        #expect(!out.isEmpty)
        #expect(out.allSatisfy { $0.count <= 125 })
    }

    @Test func flushEmitsRemainderAndResets() {
        var c = SentenceChunker()
        #expect(c.append("No ending here") == [])
        #expect(c.flush() == ["No ending here"])
        #expect(c.flush() == [])
        #expect(c.pending == "")
        _ = c.append("Half")
        c.reset()
        #expect(c.flush() == [])
    }

    @Test func emptyAndEmojiOnlySentencesVanish() {
        #expect(feed(["😊. ", "🎉! Hello."]) == ["Hello."])
        #expect(feed([""]) == [])
    }
}
