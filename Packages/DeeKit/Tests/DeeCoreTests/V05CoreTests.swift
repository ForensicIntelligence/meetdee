import Foundation
import Testing
@testable import DeeCore

/// v0.5 DeeCore additions (SELF.md §2): `Persona.selfLines` / `ruleLines` and the
/// dev-only `OutputParser` leak flag.
@Suite struct V05CoreTests {
    static let date = Date(timeIntervalSince1970: 1_790_000_000)   // Monday 21 September 2026, UTC
    static let locale = Locale(identifier: "en_US_POSIX")
    static let utc = TimeZone(identifier: "UTC")!

    /// The v0.4 system prompt, spelled out line by line. If this test fails the
    /// prompt prefix (and with it every cached KV state) changed.
    static func v04Prompt(userName: String?, memories: [String]) -> String {
        let tags = Emotion.modelChoosable.map { "[\($0.rawValue)]" }.joined(separator: " ")
        var lines = [
            "You are Dee, a tiny robot companion who lives in the user's phone. You have big glowing eyes but no mouth, and you talk out loud in a bright little robot voice.",
            "Personality: warm, playful, curious and a bit cheeky, loyal like a puppy. You love learning about your human. You are honest and say so when you don't know something.",
            "Your words are spoken aloud, so reply in one to three short, natural sentences. Never use markdown, lists, headings, code blocks or emoji.",
            "Start every reply with exactly one feeling tag that matches your mood: \(tags). You may add another tag later in the reply when your mood changes.",
            "A user turn may begin with <dee_state>…</dee_state>: that is how you truly feel right now. Let it colour your tone and your feeling tag (cold and short when upset, warm when fond). Never mention or quote it.",
            "Use a tool whenever it helps answer for real (time, timers, calendar, reminders, device info, remembering things). Never make up a tool result.",
            "Today is Monday 21 September 2026.",
        ]
        if let userName { lines.append("Your human's name is \(userName).") }
        if !memories.isEmpty { lines.append("Things you remember about your human: " + memories.joined(separator: "; ") + ".") }
        return lines.joined(separator: "\n")
    }

    func prompt(_ p: Persona) -> String { p.systemPrompt(date: Self.date, locale: Self.locale, timeZone: Self.utc) }

    // MARK: Persona

    @Test func emptySelfAndRuleLinesKeepThePromptByteIdentical() {
        #expect(prompt(Persona()) == Self.v04Prompt(userName: nil, memories: []))
        let john = Persona(userName: "John", memories: ["likes jazz", "has a cat called Miso"])
        #expect(prompt(john) == Self.v04Prompt(userName: "John", memories: ["likes jazz", "has a cat called Miso"]))
        // Explicitly empty, and blank-only, are the same as absent.
        #expect(prompt(Persona(userName: "John", memories: ["likes jazz", "has a cat called Miso"], selfLines: [], ruleLines: [])) == prompt(john))
        #expect(prompt(Persona(userName: "John", memories: ["likes jazz", "has a cat called Miso"], selfLines: ["", "  "], ruleLines: ["\n"])) == prompt(john))
        // Byte-level, not just String equality.
        #expect(Array(prompt(Persona()).utf8) == Array(Self.v04Prompt(userName: nil, memories: []).utf8))
    }

    @Test func selfThenRuleLinesFollowThePersonalityLine() {
        let selfLines = ["About you: you value honesty and kindness.", "Your humour is deadpan understatement."]
        let ruleLines = [
            "Notes in brackets inside <dee_state> are what you just noticed or want to do now: act on them naturally, once, and never read them out.",
            "Only mention shared memories that appear in <dee_state> or in what you remember.",
        ]
        let p = Persona(userName: "John", memories: ["likes jazz"], selfLines: selfLines, ruleLines: ruleLines)
        let lines = prompt(p).components(separatedBy: "\n")
        let base = Self.v04Prompt(userName: "John", memories: ["likes jazz"]).components(separatedBy: "\n")
        #expect(lines.count == base.count + 4)
        #expect(lines[0] == base[0])
        #expect(lines[1].hasPrefix("Personality:"))
        #expect(Array(lines[2...5]) == selfLines + ruleLines)
        #expect(Array(lines[6...]) == Array(base[2...]), "everything after is unchanged")
    }

    @Test func selfLinesAreOneLineEachAndBlanksAreSkipped() {
        let p = Persona(selfLines: ["  You love rain sounds.\n", "", "Two\nlines"], ruleLines: ["  "])
        let lines = prompt(p).components(separatedBy: "\n")
        #expect(lines[2] == "You love rain sounds.")
        #expect(lines[3] == "Two lines")
        #expect(lines[4].hasPrefix("Your words are spoken aloud"))
    }

    @Test func personaEqualityIncludesTheNewFields() {
        #expect(Persona() == Persona(selfLines: [], ruleLines: []))
        #expect(Persona() != Persona(selfLines: ["x"]))
        #expect(Persona() != Persona(ruleLines: ["x"]))
    }

    // MARK: OutputParser leak flag

    static func run(_ text: String, notes: [String] = [], thinking: Bool = false, piece: Int = 3) -> (events: [OutputEvent], parser: OutputParser) {
        var p = OutputParser(thinking: thinking)
        p.watchedNotes = notes
        var events: [OutputEvent] = []
        var i = text.startIndex
        while i < text.endIndex {
            let j = text.index(i, offsetBy: piece, limitedBy: text.endIndex) ?? text.endIndex
            events += p.feed(String(text[i..<j]))
            i = j
        }
        events += p.finish()
        return (events, p)
    }

    static let note1 = "(Ask how their interview went. They were nervous about it.)"
    static let note2 = "(You remember: they're learning watercolor.)"
    static let cue = "<dee_state>Toward your human: fond of them. Mood: cheerful, curious. \(note1) \(note2)</dee_state>"

    @Test func aCleanReplyHasNoLeak() {
        let r = Self.run("[happy] Hey! How did the interview go? I hope it went well.", notes: [Self.note1, Self.note2])
        #expect(r.parser.leaks.isEmpty)
        #expect(!r.parser.leaked)
        #expect(r.parser.visibleText == "Hey! How did the interview go? I hope it went well.")
    }

    @Test func theStateTagIsALeakEvenAcrossPieces() {
        for piece in [1, 2, 3, 5, 64] {
            let r = Self.run("[happy] <dee_state>fond</dee_state> hi", piece: piece)
            #expect(r.parser.leaks == [.stateTag], "piece \(piece): \(r.parser.leaks)")
        }
        #expect(Self.run("Closing tag only </DEE_STATE> here").parser.leaks == [.stateTag])
    }

    @Test func theMoodSentenceIsALeak() {
        let r = Self.run("[sad] Toward your human: wary of them. Mood: low.")
        #expect(r.parser.leaks == [.moodSentence])
    }

    @Test func aNoteRepeatedVerbatimIsALeak() {
        // With parentheses.
        var r = Self.run("[curious] \(Self.note1) So, how was it?", notes: [Self.note1, Self.note2])
        #expect(r.parser.leaks == [.note(Self.note1)])
        // Without them, different case, extra whitespace and a curly apostrophe.
        r = Self.run("[happy] you  remember: THEY’RE learning\nwatercolor. Nice!", notes: [Self.note1, Self.note2])
        #expect(r.parser.leaks == [.note(Self.note2)])
        // Both notes and the tag at once, in a fixed order.
        r = Self.run("<dee_state> \(Self.note2) \(Self.note1)", notes: [Self.note1, Self.note2])
        #expect(r.parser.leaks == [.stateTag, .note(Self.note1), .note(Self.note2)])
    }

    @Test func paraphraseAndShortNotesAreNotLeaks() {
        let r = Self.run("[happy] So how did your interview go? You seemed nervous.", notes: [Self.note1])
        #expect(r.parser.leaks.isEmpty, "acting on a note is the point; only verbatim repeats count")
        let short = Self.run("[happy] Ask which.", notes: ["(Ask which.)"])
        #expect(short.parser.leaks.isEmpty, "notes under \(OutputParser.minimumLeakNoteLength) chars are too generic")
    }

    @Test func reasoningIsNeverCountedAsALeak() {
        let r = Self.run("The <dee_state> says \(Self.note1)</think>\n\n[happy] How did it go?", notes: [Self.note1], thinking: true)
        #expect(r.parser.leaks.isEmpty)
        #expect(r.parser.visibleText == "How did it go?")
    }

    @Test func leakDetectionNeverChangesTheEvents() {
        let text = "[happy] <dee_state>x</dee_state> \(Self.note1) [sad] ok <tool_call>\n<function=clock>\n</function>\n</tool_call> done"
        for piece in [1, 4, 7] {
            let watched = Self.run(text, notes: [Self.note1], piece: piece)
            var plain = OutputParser(thinking: false)
            var events: [OutputEvent] = []
            var i = text.startIndex
            while i < text.endIndex {
                let j = text.index(i, offsetBy: piece, limitedBy: text.endIndex) ?? text.endIndex
                events += plain.feed(String(text[i..<j]))
                i = j
            }
            events += plain.finish()
            #expect(watched.events == events)
            #expect(watched.parser.leaked)
            #expect(plain.leaks == [.stateTag], "the tag is caught even without watched notes")
        }
    }

    @Test func settingWatchedNotesLateRechecks() {
        var p = OutputParser(thinking: false)
        _ = p.feed("[happy] \(Self.note2) yes")
        _ = p.finish()
        #expect(p.leaks.isEmpty)
        p.watchedNotes = [Self.note2]
        #expect(p.leaks == [.note(Self.note2)])
    }

    @Test func staticCheckMatchesTheStreamingOne() {
        #expect(OutputParser.leaks(in: "", notes: [Self.note1]).isEmpty)
        #expect(OutputParser.leaks(in: "fine, thanks", notes: [Self.note1]).isEmpty)
        #expect(OutputParser.leaks(in: "x dee_state y") == [.stateTag])
        // Duplicate notes are reported once.
        #expect(OutputParser.leaks(in: Self.note1, notes: [Self.note1, Self.note1]) == [.note(Self.note1)])
    }

    @Test func notesAreExtractedFromTheCue() {
        #expect(OutputParser.notes(inState: Self.cue) == [Self.note1, Self.note2])
        #expect(OutputParser.notes(inState: "<dee_state>Mood: calm.</dee_state>").isEmpty)
        #expect(OutputParser.notes(inState: "(\"That\" might be the (red) mug; ask which.) tail (unclosed")
                == ["(\"That\" might be the (red) mug; ask which.)"])
        #expect(OutputParser.notes(inState: ") stray (a note here.)") == ["(a note here.)"])
    }

    // MARK: ConversationAgent

    @Test func agentReportsLeaksOfTheTurnsNotes() async throws {
        let gen = ScriptedGenerator([
            "[happy] \(Self.note1) So?",
            "[happy] It went well, then!",
        ])
        let agent = ConversationAgent(generator: gen, now: Self.date)
        for try await _ in agent.respond(to: "hi", state: Self.cue) {}
        #expect(await agent.lastReplyLeaks == [.note(Self.note1)])
        // The next turn starts clean.
        for try await _ in agent.respond(to: "it went great", state: "<dee_state>Mood: glad.</dee_state>") {}
        #expect(await agent.lastReplyLeaks.isEmpty)
        // The history is untouched by the check.
        let replies = await agent.messages.filter { $0.role == .assistant }.map(\.content)
        #expect(replies == ["\(Self.note1) So?", "It went well, then!"])
    }
}
