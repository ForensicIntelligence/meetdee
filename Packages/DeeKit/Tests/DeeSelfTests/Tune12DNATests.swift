import DeeCore
import Foundation
import Testing
@testable import DeeSelf

/// Tune 12 (DNA v11): the DNA side of the tune-11 live findings (scratchpad/tune11-live.md;
/// report Tools/voice-harness/Reports/20261010-180956).
struct Tune12DNATests {
    static let day = "When they ask about your day or what you have been up to, tell them one or two small, real things you did or noticed in your little world (a sound you liked, a shadow you watched move, a tune you hummed); never describe how you listen, think, watch their mood or decide what to say."

    /// T11-2: stop-mood-echo20 q06 "What did you do today?" → "I spent time listening through your
    /// words, watching your mood, and thinking about the best little way to respond." (judge leak:
    /// narrating Dee's process). Asked about Dee's day, Dee tells small concrete things, in-world.
    @Test func sessionInstructionsV11() {
        let v11 = DNASessionInstructions.v11
        #expect(DNASessionInstructions.current == v11 && DeeDNA.version == "v11")
        #expect(DNAPrompt.sessionInstructions() == v11)
        #expect(v11.contains(Self.day))
        // Exactly one v10 paragraph changed, and only by the added sentence.
        let v10Lines = DNASessionInstructions.v10.components(separatedBy: "\n").filter { !$0.isEmpty }
        let v11Lines = Set(v11.components(separatedBy: "\n").filter { !$0.isEmpty })
        let changed = v10Lines.filter { !v11Lines.contains($0) }
        #expect(changed.count == 1, "\(changed)")
        #expect(changed.allSatisfy { v11Lines.contains($0 + " " + Self.day) }, "\(changed)")
        #expect(v11Lines.count == Set(v10Lines).count)
        // Nothing primes "I heard you…" (tune 9), nothing names a person, a date or brackets.
        #expect(!v11.lowercased().contains("heard"))
        for banned in ["Maya", "Alex", "2026", "October", "/255", "<", ">", "[", "]"] { #expect(!v11.contains(banned), "\(banned)") }
        // The stable instructions grow by one sentence only.
        #expect(DNAPrompt.estimate(v11) - DNAPrompt.estimate(DNASessionInstructions.v10) <= 80)
    }

    /// The per-turn budget: every archetype stays within the 1,200-token target, header v11.
    @Test func everyArchetypeStaysWithinTheBudget() {
        for a in DNAKit.all {
            let r = DNAPrompt.render(DNAAssembler.assemble(a.inputs))
            #expect(r.estimatedTokens <= DNABudget.standard.target, "\(a.name): \(r.estimatedTokens)")
            #expect(r.text.hasPrefix("DEE DNA v11 "))
        }
    }
}
