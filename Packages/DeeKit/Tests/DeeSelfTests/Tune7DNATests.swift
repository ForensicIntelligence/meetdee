import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// Tune 7 (DNA v8): the DNA side of the tune-6 live findings (scratchpad/tune6-live.md;
/// report Tools/voice-harness/Reports/20261010-035320).
struct Tune7DNATests {
    typealias C = Tune3CharacterTests

    // MARK: T6-8 — the due follow-up: their name and the question, nothing before it

    /// followup-exam two01: "Hi Alex! Lovely to see you again; it's been about a week,
    /// hasn't it? How did your exam go? …" — the v7 line ("with a warm hello and that it's
    /// been about a week folded into it") was read as two things to say first, and the
    /// question came third. v8 spells the opening words out with their name, and the time
    /// apart comes only after the question.
    @Test func liveExamFollowUpOpensWithTheirNameAndTheQuestion() throws {
        let mind = Kit.snap()
        var a = Appraisal()
        a.distress = 0.5
        var cx = C.firstConversation("I have a big exam on Friday morning and I'm nervous.", at: SimClock.at("Sat 04:10", week: 2)!, mind: mind, a)
        let back = SimClock.at("Sat 01:00", week: 3)!
        C.comeBack(&cx, at: back, mind: mind)
        let t = back.addingTimeInterval(5)
        _ = C.reply(&cx, at: t, mind: mind)
        let dna = Tune4DNATests.render(cx, at: t, index: 2, heardReplies: 0)
        let lines = dna.components(separatedBy: "\n")
        let who = try #require(lines.first { $0.hasPrefix("Their name is ") })
        let name = String(who.dropFirst("Their name is ".count).prefix { $0 != "." && $0 != " " })
        let doLine = try #require(lines.first { $0.hasPrefix("Do: ") })
        #expect(doLine.hasPrefix("Do: Your very first sentence is \"Hi \(name),\" and your \"Ask now\" question, all in one; nothing before it; that it's been about a week only after it; then a few words at most"), "\(doLine)")
        #expect(!doLine.contains("folded into it"), "\(doLine)")
        #expect(dna.contains("Ask now, first: how their exam went."), "\(dna)")
        #expect(dna.hasPrefix("DEE DNA v10 "))
    }

    /// The budget: every archetype stays within the target with nothing trimmed for v8.
    @Test func everyArchetypeStaysWithinTheBudget() {
        for a in DNAKit.all {
            let r = DNAPrompt.render(DNAAssembler.assemble(a.inputs))
            #expect(r.estimatedTokens <= DNABudget.standard.target, "\(a.name): \(r.estimatedTokens)")
        }
    }

    // MARK: Session instructions v8

    @Test func sessionInstructionsV8() {
        let v8 = DNASessionInstructions.v8
        // v9 is current since tune 8 (Tune8DNATests); v8 stays pinned as it was.
        #expect(DNASessionInstructions.current != v8 && DeeDNA.version == "v10")
        // T6-8: their name and the question in one sentence, the thing named, nothing before it.
        #expect(v8.contains("their name and the question in one sentence, like \"Hi Sam, how did your exam go?\", naming the thing itself (the exam, the dentist appointment)"))
        #expect(v8.contains("never a hello, a \"lovely to see you\" or the time apart before it, and about their health, ask gently"))
        // T6-6: a short exclamation is a sentence, excited or not.
        #expect(v8.contains("count every sentence, even a one-word one or a short exclamation like \"Nice.\" or \"Oh, wow.\", and stop when you reach it, however excited you are"))
        // T6-7 / T6-8: never a robot's report or status; never "I heard you say".
        #expect(v8.contains("Never talk about yourself as a machine giving a report, a status or an update (\"robot report:\", \"status update\", \"system check\")"))
        #expect(v8.contains("never quote them back (\"I heard you say\")"))
        // Everything else v7 said is still there, word for word.
        let changed = ["An \"Ask now, first\" line", "Never speak a preamble", "The \"Length:\" line is a hard limit"]
        let v7Lines = DNASessionInstructions.v7.components(separatedBy: "\n").filter { line in !line.isEmpty && !changed.contains { line.contains($0) } }
        for line in v7Lines { #expect(v8.contains(line), "\(line)") }
        for banned in ["Maya", "2026", "/255", "<", ">", "[", "]"] { #expect(!v8.contains(banned)) }
    }
}
