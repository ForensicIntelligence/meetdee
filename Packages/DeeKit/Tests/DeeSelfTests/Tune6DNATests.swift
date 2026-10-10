import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// Tune 6 (DNA v7): the DNA side of the tune-5 live findings (scratchpad/tune5-live.md;
/// report Tools/voice-harness/Reports/20261010-020243).
struct Tune6DNATests {
    typealias C = Tune3CharacterTests

    // MARK: T5-8 — no apps, clocks or forecasts: a hard limit of hers

    /// latency-clean q07 / two03 / q03, length-clean q07: "…you can check a weather app or a
    /// forecast.", "Or open the weather app…", "You can check your phone's clock…". The
    /// limit is now in who she is (the identity line, never trimmed) and in the Always line.
    @Test func everyDNASaysSheHasNoAppsOrClock() {
        for a in DNAKit.all {
            let t = DNAPrompt.build(a.inputs).text
            let identity = t.components(separatedBy: "\n").first { $0.hasPrefix("You are Dee, a tiny robot") }
            #expect(identity?.contains("with no apps, clock or internet") == true, "\(a.name): \(identity ?? "-")")
            let always = t.components(separatedBy: "\n").first { $0.hasPrefix("Always: ") }
            #expect(always?.contains("never send them to an app, clock or forecast") == true, "\(a.name)")
            // Still within the budget, with nothing trimmed for it (the goldens pin the rest).
            let r = DNAPrompt.render(DNAAssembler.assemble(a.inputs))
            #expect(r.estimatedTokens <= DNABudget.standard.target, "\(a.name): \(r.estimatedTokens)")
        }
    }

    // MARK: T5-8 — the due follow-up is the very first sentence

    /// followup-exam two01: "Hi there! It's been about a week, and I'm thrilled you're back.
    /// How did your big exam go?" — the hello stood alone and the question came third. The
    /// Do line now makes the question itself the first sentence, the hello folded into it.
    @Test func liveExamFollowUpIsTheVeryFirstSentence() throws {
        let mind = Kit.snap()
        var a = Appraisal()
        a.distress = 0.5
        var cx = C.firstConversation("I have a big exam on Friday morning and I'm nervous.", at: SimClock.at("Sat 04:10", week: 2)!, mind: mind, a)
        let back = SimClock.at("Sat 01:00", week: 3)!
        C.comeBack(&cx, at: back, mind: mind)
        let t = back.addingTimeInterval(5)
        _ = C.reply(&cx, at: t, mind: mind)
        let dna = Tune4DNATests.render(cx, at: t, index: 1, heardReplies: 0)
        let doLine = try #require(dna.components(separatedBy: "\n").first { $0.hasPrefix("Do: ") })
        // v8 (tune 7) spells the opening words out (Tune7DNATests).
        #expect(doLine.hasPrefix("Do: Your very first sentence is \"Hi "), "\(doLine)")
        #expect(!doLine.contains("Open with a warm hello"), "\(doLine)")
        #expect(dna.contains("Ask now, first: how their exam went."), "\(dna)")
        #expect(dna.hasPrefix("DEE DNA \(DeeDNA.version) "))
    }

    // MARK: T5-5 — the name as a sentence

    /// fallback-rollover-speech m01: the DNA said "4 TOWARD THIS PERSON / Priya." and she
    /// said she hadn't learned their name. A known name now reads as a sentence.
    @Test func aKnownNameIsASentence() {
        let t = DNAPrompt.build(DNAKit.reunion9Days().inputs).text
        #expect(t.contains("\n4 TOWARD THIS PERSON\nTheir name is Maya (also May).\n"), "\(t)")
    }

    // MARK: Session instructions v7

    @Test func sessionInstructionsV7() {
        let v7 = DNASessionInstructions.v7
        // v8 is current since tune 7 (Tune7DNATests); v7 stays pinned as it was.
        #expect(DNASessionInstructions.current != v7 && DeeDNA.version == "v10")
        // T5-8: the question is the first sentence, the hello inside it.
        #expect(v7.contains("the question is your very first sentence, before anything else, even before answering their own question"))
        #expect(v7.contains("a hello goes inside that sentence, never on its own before it"))
        // T5-8: no apps, even as a tip; T5-5: never "I'll remember / store it".
        #expect(v7.contains("Never send them to an app, a clock, a forecast, a calendar or a search, not even as a tip after your answer"))
        #expect(v7.contains("never say you will remember, store or save something; you just know it"))
        // T5-4: a bare name or a word or two is not a turn; never "did you want to say something?".
        #expect(v7.contains("or they only said your name or a word or two, they are not done: wait for the rest"))
        #expect(v7.contains("ask whether they meant to say something"))
        // Everything else v6 said is still there, word for word.
        let changed = ["An \"Ask now, first\" line", "Never offer help", "If their words stop mid-sentence"]
        let v6Lines = DNASessionInstructions.v6.components(separatedBy: "\n").filter { line in !line.isEmpty && !changed.contains { line.contains($0) } }
        for line in v6Lines { #expect(v7.contains(line), "\(line)") }
        for banned in ["Maya", "2026", "/255", "<", ">", "[", "]"] { #expect(!v7.contains(banned)) }
    }
}
