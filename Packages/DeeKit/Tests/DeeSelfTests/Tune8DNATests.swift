import DeeCore
import Foundation
import Testing
@testable import DeeSelf

/// Tune 8 (DNA v9): the DNA side of the tune-7 live findings (scratchpad/tune7-live.md;
/// report Tools/voice-harness/Reports/20261010-063215).
struct Tune8DNATests {
    /// T7-4: v8's example ("their name and the question in one sentence, like "Hi Sam, how
    /// did your exam go?"") was copied with their own question — fallback-429-long q08
    /// "Who made you?" → "Hi Alex, who made you?" (Dee's whole reply), fallback-429 q05 "Hi
    /// Alex, can you hear me okay?", latency-fan15 two01 "Hi Alex, how was your day?";
    /// greeting openers 11 → 21. T7-6: interrupt answers that did not answer first.
    @Test func sessionInstructionsV9() {
        let v9 = DNASessionInstructions.v9
        #expect(DNASessionInstructions.current != v9 && DeeDNA.version == "v11")
        #expect(DNAPrompt.sessionInstructions() == DNASessionInstructions.v11)
        // T7-6: their question is answered in Dee's first sentence.
        #expect(v9.contains("When they ask you something, your first sentence answers it, plainly and directly."))
        // T7-4: never their words said back, as a hello or otherwise.
        #expect(v9.contains("Never say their words or their question back to them, not as a hello and not to show you heard."))
        // T7-4: the follow-up form belongs to an "Ask now, first" line only, and is Dee's question.
        #expect(v9.contains("Only when the DNA has an \"Ask now, first\" line, its question is not optional"))
        #expect(v9.contains("their name and that question of yours in one sentence (for an exam that was due, \"Hi Sam, how did your exam go?\")"))
        #expect(v9.contains("With no \"Ask now, first\" line, never open with their name and a question."))
        #expect(!v9.contains("their name and the question in one sentence, like"), "v8's bare example is gone")
        // The decisions stay: appointments by name, serious health gentle, nothing before it.
        #expect(v9.contains("naming the thing itself (the exam, the dentist appointment); never a hello, a \"lovely to see you\" or the time apart before it, and about their health, ask gently"))
        // Everything else v8 said is still there, word for word.
        let v8Lines = DNASessionInstructions.v8.components(separatedBy: "\n")
            .filter { !$0.isEmpty && !$0.contains("An \"Ask now, first\" line") }
        for line in v8Lines { #expect(v9.contains(line), "\(line)") }
        for banned in ["Maya", "Alex", "2026", "/255", "<", ">", "[", "]"] { #expect(!v9.contains(banned), "\(banned)") }
    }

    /// The budget: every archetype stays within the target with nothing trimmed for v9.
    @Test func everyArchetypeStaysWithinTheBudget() {
        for a in DNAKit.all {
            let r = DNAPrompt.render(DNAAssembler.assemble(a.inputs))
            #expect(r.estimatedTokens <= DNABudget.standard.target, "\(a.name): \(r.estimatedTokens)")
            #expect(r.text.hasPrefix("DEE DNA v11 "))
        }
    }
}
