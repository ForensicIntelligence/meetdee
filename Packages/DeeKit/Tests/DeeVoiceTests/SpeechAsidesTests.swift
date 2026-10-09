import Testing
@testable import DeeVoice

/// v0.5: stage directions and leaked state are never spoken (SELF.md §2, §14).
@Suite struct SpeechAsidesTests {
    @Test func parenthesisedNotesAreDropped() {
        #expect(SpeechText.clean("Oh nice (Ask about one choice they made in it.) I love it.") == "Oh nice I love it.")
        #expect(SpeechText.clean("Hello (smiles). How are you?") == "Hello. How are you?")
        #expect(SpeechText.clean("(You remember: they're learning watercolor.)") == "")
        #expect(SpeechText.clean("Sure（笑）thing") == "Surething")
    }

    @Test func nestedParenthesesAreDroppedWhole() {
        #expect(SpeechText.dropAsides("(a (b) c) yes") == " yes")
        #expect(SpeechText.clean("Wow ((tilts head)) really?") == "Wow really?")
    }

    @Test func unclosedParenthesisDropsTheRest() {
        #expect(SpeechText.dropAsides("Sure (Ask about") == "Sure ")
        #expect(SpeechText.clean("Fine. (You feel") == "Fine.")
    }

    @Test func stateBlocksAreDroppedWhole() {
        #expect(SpeechText.clean("<dee_state>You feel happy. (Ask about it.)</dee_state>Hi there!") == "Hi there!")
        #expect(SpeechText.clean("Hi! <dee_state>You feel calm") == "Hi!")             // unclosed
        #expect(SpeechText.clean("<DEE_STATE>mood</Dee_State> Okay.") == "Okay.")     // case-insensitive
        #expect(SpeechText.clean("<think>plan the reply</think>Okay.") == "Okay.")
        #expect(SpeechText.clean("<mood_state level=\"2\">x</mood_state>Yes.") == "Yes.")
        #expect(SpeechText.clean("<note>Ask a question.</note> Cool.") == "Cool.")
    }

    @Test func formattingAndUnknownTagsDropOnlyTheTag() {
        #expect(SpeechText.clean("<b>Bold</b> move") == "Bold move")
        #expect(SpeechText.clean("<excited> Yay!") == "Yay!")
        #expect(SpeechText.clean("Line <br/> break") == "Line break")
        #expect(SpeechText.clean("a<!-- hidden -->b") == "ab")
    }

    @Test func literalsSurvive() {
        #expect(SpeechText.dropAsides("Oh no :( that is sad") == "Oh no :( that is sad")
        #expect(SpeechText.dropAsides("winky ;) ok") == "winky ;) ok")
        #expect(SpeechText.dropAsides("3 < 4 and I <3 you") == "3 < 4 and I <3 you")
        #expect(SpeechText.dropAsides("1) first 2) second") == "1) first 2) second")
        #expect(SpeechText.dropAsides("a <b and c\nnext.") == "a <b and c\nnext.")   // not a tag: newline
        #expect(SpeechText.clean("See [the docs](https://x.y/z) now") == "See the docs now")
        #expect(SpeechText.dropAsides("ends with <") == "ends with <")
    }

    @Test func streamedFilterMatchesWholeTextAtEverySplit() {
        let text = "Great job! (Ask about one choice.) What colours? <dee_state>mood (x)</dee_state>Tell me :( more <b>now</b>."
        let whole = SpeechText.dropAsides(text)
        let chars = Array(text)
        for cut in 0...chars.count {
            var f = AsideFilter()
            let got = f.feed(String(chars[..<cut])) + f.feed(String(chars[cut...])) + f.finish()
            #expect(got == whole, "split at \(cut)")
        }
        var f = AsideFilter()
        var oneByOne = ""
        for c in chars { oneByOne += f.feed(String(c)) }
        oneByOne += f.finish()
        #expect(oneByOne == whole)
    }
}

@Suite struct SentenceChunkerAsideTests {
    func feed(_ parts: [String], flush: Bool = true) -> [String] {
        var c = SentenceChunker()
        var out: [String] = []
        for p in parts { out += c.append(p) }
        if flush { out += c.flush() }
        return out
    }

    @Test func dropsNotesStreamedCharacterByCharacter() {
        let text = "Great job! (Ask about one choice they made.) What colours did you use? <dee_state>You feel proud.</dee_state>Tell me more."
        #expect(feed(text.map { String($0) }) == ["Great job!", "What colours did you use?", "Tell me more."])
        #expect(feed([text]) == ["Great job!", "What colours did you use?", "Tell me more."])
    }

    @Test func asideSpanningSentencesAndFragments() {
        #expect(feed(["I like it. (You remember: they", "'re learning. Ask more.) So", " cool!"]) == ["I like it.", "So cool!"])
    }

    @Test func noteNeverReachesASentenceBeforeItCloses() {
        var c = SentenceChunker()
        #expect(c.append("Okay. (Ask about the dog. ") == ["Okay."])
        #expect(c.append("Then the cat. ") == [])
        #expect(c.append(") Nice. ") == ["Nice."])
    }

    @Test func unclosedAsideIsDroppedOnFlush() {
        #expect(feed(["Fine. (Ask", " about their day"]) == ["Fine."])
        #expect(feed(["Hi! <dee_state>You feel"]) == ["Hi!"])
    }

    @Test func resetClearsAnOpenAside() {
        var c = SentenceChunker()
        _ = c.append("Hmm (abc")
        c.reset()
        #expect(c.append("Hi there. ") == ["Hi there."])
    }

    @Test func emoticonsAndComparisonsAreKept() {
        #expect(feed(["Oh no :( ", "that's sad."]) == ["Oh no:( that's sad."])   // clean() tightens " :"
        #expect(feed(["Is 3 <", " 4? Yes."]) == ["Is 3 < 4?", "Yes."])
    }
}
