import DeeCore
import Foundation
import Testing
@testable import DeeSelf

/// Tune 9 (DNA v10): the DNA side of the tune-8 live findings (scratchpad/tune8-live.md;
/// report Tools/voice-harness/Reports/20261010-080526).
struct Tune9DNATests {
    /// T8-5: v9's "not to show you heard" primed "I heard you…" openers (1 → 5: latency-fan15
    /// two01 "…I heard you better", backchannel-echo20 l01 "I heard you thinking about a dog…",
    /// interrupt-fan15 l05 "I heard you. I think it's normal…", tools-echo20 n01 "I heard your
    /// name"). T8-4: thinking aloud ("Let me think this through with you.", "Let me think about
    /// the next one.", "Let me take a moment to settle in.") and two-message replies.
    @Test func sessionInstructionsV10() {
        let v10 = DNASessionInstructions.v10
        #expect(DNASessionInstructions.current != v10 && DeeDNA.version == "v11")
        #expect(DNAPrompt.sessionInstructions() == DNASessionInstructions.v11)
        // T8-5: nothing in the stable instructions names hearing them.
        #expect(!v10.lowercased().contains("heard"), "the word that primed \"I heard you…\"")
        #expect(!v10.contains("to show you"))
        #expect(v10.contains("Never repeat their words or their question back to them, not even as a hello."))
        #expect(v10.contains("never tell them what they said"))
        // T8-4: thinking aloud is named, before and after the answer; one reply.
        #expect(v10.contains("think aloud"))
        for lead in ["\"let me think\"", "\"let me see\"", "\"let me take a moment\"", "\"give me a second\""] {
            #expect(v10.contains(lead), "\(lead)")
        }
        #expect(v10.contains("not before your answer and not after it"))
        #expect(v10.contains("Give one reply, never a lead-in or a hello followed by a second reply."))
        // v9's answer-first and follow-up lines stay; the decisions stay.
        #expect(v10.contains("When they ask you something, your first sentence answers it, plainly and directly."))
        #expect(v10.contains("naming the thing itself (the exam, the dentist appointment); never a hello, a \"lovely to see you\" or the time apart before it, and about their health, ask gently"))
        #expect(v10.contains("in words like \"a couple of days\" or \"nearly a week\", never as a number of days or hours"))
        // Exactly the two paragraphs changed; every other v9 line is kept word for word.
        let v9Lines = DNASessionInstructions.v9.components(separatedBy: "\n").filter { !$0.isEmpty }
        let changed = v9Lines.filter { !v10.contains($0) }
        #expect(changed.count == 2, "\(changed)")
        for banned in ["Maya", "Alex", "2026", "/255", "<", ">", "[", "]"] { #expect(!v10.contains(banned), "\(banned)") }
    }

    /// The budget: every archetype stays within the target, header v11.
    @Test func everyArchetypeStaysWithinTheBudget() {
        for a in DNAKit.all {
            let r = DNAPrompt.render(DNAAssembler.assemble(a.inputs))
            #expect(r.estimatedTokens <= DNABudget.standard.target, "\(a.name): \(r.estimatedTokens)")
            #expect(r.text.hasPrefix("DEE DNA v11 "))
        }
    }
}
