import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// Tune 4 (brain / DNA v5): the DNA side of the tune-3 live failures (tune3-live.md
/// §F4 / §F5), replayed in the harness order.
struct Tune4DNATests {
    typealias C = Tune3CharacterTests

    /// What the harness / app hand `dnaInputs` on a reply at `t` (as `Tune3DNATests`),
    /// with the brain's count of Dee's replies heard so far.
    static func render(_ cx: Cortex, at t: Date, index: Int, heardReplies: Int?) -> String {
        let person = PersonInputs(id: Kit.john, name: "Alex", firstMet: Kit.t0, encounters: 2, lastSeen: t)
        let body = BodyInputs(someoneHere: true, lastUserTurnAt: t, lastContact: person.lastSeen)
        return cx.dnaRender(at: t, memories: person, turn: TurnContext(kind: .reply, index: index, mode: .fast, heardReplies: heardReplies),
                            context: DNAContext(body: body)).text
    }

    /// t2-reunion-morning, live tune 3: the server split "Good morning." / "Did you sleep
    /// well?"; reply 1 (with the greeting) was cancelled before a word of it was heard,
    /// and reply 2's DNA had lost the Do line: "I don't sleep like you do…", no hello, no
    /// "two days". The greeting now stays until a reply of Dee's was actually heard.
    @Test func liveReunionMorningSplitKeepsTheGreetingUntilHeard() throws {
        let mind = Kit.snap()
        let t0 = Kit.t0
        var cx = Cortex(enduring: Kit.enduring(), mind: mind, at: t0)
        _ = cx.step(.conversationStarted(t0), mind: mind, at: t0)
        _ = cx.step(.identified(Kit.john, distance: 0), mind: mind, at: t0)
        _ = cx.step(.presence(arrived: true), mind: mind, at: t0)
        _ = cx.step(Kit.heard("What's your favorite color?"), mind: mind, at: t0.addingTimeInterval(5))
        _ = cx.step(.deeTurnFinished(text: "Blue!"), mind: mind, at: t0.addingTimeInterval(9))
        let left = t0.addingTimeInterval(20)
        _ = cx.step(.faceLost, mind: mind, at: left)
        _ = cx.step(.presence(arrived: false), mind: mind, at: left)
        let back = left.addingTimeInterval(50 * 3600)
        C.comeBack(&cx, at: back, mind: mind)

        // Reply 1, to "Good morning." (live 23.28): the greeting is in it.
        let t1 = back.addingTimeInterval(3)
        _ = cx.step(Kit.heard("Good morning."), mind: mind, at: t1)
        _ = C.reply(&cx, at: t1, mind: mind)
        let first = Self.render(cx, at: t1, index: 1, heardReplies: 0)
        #expect(first.contains("mention lightly that it's been a couple of days"), "\(first)")
        // Cancelled before any audio (they went on): nothing of it was said.
        _ = cx.step(.deeTurnFinished(text: ""), mind: mind, at: t1.addingTimeInterval(0.4))
        // Reply 2, to "Did you sleep well?" (live 24.86): still the greeting.
        let t2 = t1.addingTimeInterval(1.6)
        _ = cx.step(Kit.heard("Did you sleep well?"), mind: mind, at: t2)
        _ = C.reply(&cx, at: t2, mind: mind)
        let second = Self.render(cx, at: t2, index: 2, heardReplies: 0)
        #expect(second.contains("Greet them warmly and, in the same sentence, mention lightly that it's been a couple of days"), "\(second)")
        #expect(second.contains("Avoid: any guilt about the time apart"))
    }

    /// The rule itself: after a day apart, the greeting holds while no reply was heard,
    /// whatever the turn count; once one was heard it is used up. Without the brain's
    /// count the turn count decides, as in v4.
    @Test func theGreetingIsUsedUpOnlyByAHeardReply() {
        var a = DNAKit.reunion9Days().inputs
        a.moment.ongoing.reunionTurn = false
        a.moment.ongoing.turnsThisConversation = 2
        a.turn.heardReplies = 0
        #expect(DNAAssembler.assemble(a).guidance.rules.contains(.g5), "two turns, nothing of Dee's heard")
        a.turn.heardReplies = 1
        #expect(!DNAAssembler.assemble(a).guidance.rules.contains(.g5), "a reply was heard")
        a.turn.heardReplies = nil
        #expect(!DNAAssembler.assemble(a).guidance.rules.contains(.g5), "v4 fallback: not the first turn")
        a.moment.ongoing.turnsThisConversation = 0
        #expect(DNAAssembler.assemble(a).guidance.rules.contains(.g5), "v4 fallback: the first turn")
        // The reunion turn itself always greets.
        var r = DNAKit.reunion9Days().inputs
        r.turn.heardReplies = 3
        #expect(DNAAssembler.assemble(r).guidance.rules.contains(.g5))
    }

    /// t2-followup-exam, live tune 3: "…It's been about six days… That exam day made my
    /// little circuits curious. My day's been bright and busy… Oh, and how did your exam
    /// go?" — the follow-up was the fifth sentence. Now it leads, with the hello.
    @Test func liveExamFollowUpIsAskedInTheFirstSentence() throws {
        let mind = Kit.snap()
        var a = Appraisal()
        a.distress = 0.5
        let t0 = SimClock.at("Sat 04:10", week: 2)!
        var cx = C.firstConversation("I have a big exam on Friday morning and I'm nervous.", at: t0, mind: mind, a)
        let back = SimClock.at("Sat 01:00", week: 3)!
        C.comeBack(&cx, at: back, mind: mind)
        let t = back.addingTimeInterval(5)
        _ = C.reply(&cx, at: t, mind: mind)
        let dna = Self.render(cx, at: t, index: 1, heardReplies: 0)
        #expect(dna.contains("Ask now, first: how their exam went."), "\(dna)")
        let doLine = try #require(dna.components(separatedBy: "\n").first { $0.hasPrefix("Do: ") })
        // v8 (tune 7): the opening words spelled out, the time apart only after the question.
        #expect(doLine.hasPrefix("Do: Your very first sentence is \"Hi ") && doLine.contains("and your \"Ask now\" question, all in one; nothing before it; that it's been about a week only after it; then a few words at most"), "\(doLine)")
        #expect(!doLine.contains("Greet them warmly"), "the greeting is in the first line: \(doLine)")
        #expect(!doLine.contains("answer their question first"), "\(doLine)")
        #expect(dna.contains("Avoid: any guilt about the time apart"))
    }

    @Test func askFirstWording() {
        // v7 (tune 6): the question is the very first sentence; a hello never stands before it.
        // v8 (tune 7): the opening words spelled out ("Hi Alex," and the question, all in one).
        #expect(DNATables.askFirstDo(greeting: false, since: nil)
                == "Your first sentence is your \"Ask now\" question; after it, a few words at most")
        #expect(DNATables.askFirstDo(greeting: true, since: nil)
                == "Your very first sentence is a hello and your \"Ask now\" question, all in one; nothing before it; then a few words at most")
        #expect(DNATables.askFirstDo(greeting: true, since: nil, name: "Alex")
                == "Your very first sentence is \"Hi Alex,\" and your \"Ask now\" question, all in one; nothing before it; then a few words at most")
        #expect(DNATables.askFirstDo(greeting: true, since: 3 * 86_400).contains("; that it's been a few days only after it;"))
    }

    /// Live tune 3 at `minimal`: 14 of 141 replies ran past three sentences, 11 of them
    /// under "at most two short sentences, 25 words; stop." ("Friday at 4:30? Oof.").
    @Test func theLengthLineCountsEverySentence() {
        #expect(DNAPrompt.lengthLine("at most two short sentences") == "Length: at most two sentences, 25 words in all; stop after the second.")
        #expect(DNAPrompt.lengthLine("at most three short sentences") == "Length: at most three sentences, 35 words in all; stop after the third.")
        #expect(DNAPrompt.lengthLine("one short sentence") == "Length: one short sentence, 12 words; stop.")
        let text = DNAPrompt.render(DNAAssembler.assemble(DNAKit.fondMorning().inputs)).text
        #expect(text.contains("\nLength: at most two sentences, 25 words in all; stop after the second.\n"))
        #expect(DNASessionInstructions.current.contains("count every sentence, even a one-word one"))
    }
}
