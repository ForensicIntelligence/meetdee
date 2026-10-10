import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// docs/DNA.md §5.5 — golden renders of the eight archetypes, plus the pinned session
/// instructions (§3). Regenerate only with DEE_RECORD_GOLDEN=1 and review the diff.
/// DEE_DNA_SAMPLES=/path/file.md also writes every render into one Markdown file for the
/// live evaluator.
@Suite struct DNAGoldenTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/DNA")
    static var recording: Bool { ProcessInfo.processInfo.environment["DEE_RECORD_GOLDEN"] == "1" }

    static func check(_ text: String, file name: String) throws {
        let url = root.appendingPathComponent(name)
        if recording {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return
        }
        guard let data = try? Data(contentsOf: url) else {
            Issue.record("missing golden DNA/\(name) — run with DEE_RECORD_GOLDEN=1 and review")
            return
        }
        let want = String(decoding: data, as: UTF8.self)
        if want != text {
            let a = want.split(separator: "\n", omittingEmptySubsequences: false)
            let b = text.split(separator: "\n", omittingEmptySubsequences: false)
            var diff = ["golden DNA/\(name) differs:"]
            for i in 0..<max(a.count, b.count) where (i < a.count ? a[i] : "∅") != (i < b.count ? b[i] : "∅") {
                diff.append("  line \(i + 1): \(i < a.count ? a[i] : "∅")\n         → \(i < b.count ? b[i] : "∅")")
            }
            Issue.record(Comment(rawValue: diff.joined(separator: "\n")))
        }
    }

    @Test(arguments: DNAKit.all.map(\.name))
    func archetypeGolden(_ name: String) throws {
        let a = try #require(DNAKit.all.first { $0.name == name })
        let dna = DNAAssembler.assemble(a.inputs)
        let r = DNAPrompt.render(dna)
        try Self.check(r.text + "\n", file: "\(name).dna.txt")
        #expect(dna.guidance.rules == a.rules, "\(name): rules \(dna.guidance.rules.map(\.rawValue))")
        #expect(dna.guidance.voice.hasPrefix(a.voice), "\(name): voice \(dna.guidance.voice)")
        // Typical archetypes fit the target without S7 or any cap step (§5.3; review
        // finding 12), so they keep their History line.
        #expect(r.estimatedTokens <= DNABudget.standard.target, "\(name): \(r.estimatedTokens)")
        #expect(!r.steps.contains { $0 == .s7 || DegradeStep.capSteps.contains($0) || $0 == .minimal }, "\(name): \(r.steps)")
        if case .named = dna.relationship.who { #expect(r.text.contains("\nHistory: "), "\(name): History dropped") }
    }

    @Test func archetypeIntent() {
        let k = Dictionary(uniqueKeysWithValues: DNAKit.all.map { ($0.name, DNAAssembler.assemble($0.inputs)) })
        // 2: orange eyes, ruptured, short.
        #expect(k["insulted-ruptured"]!.relationship.eyeColour == .orange)
        #expect(k["insulted-ruptured"]!.guidance.length == "one short sentence")
        // 5: loneliness not in the blend on the reunion turn; last talked 9 days ago.
        #expect(!k["reunion-9-days"]!.blend.contains("lonely"))
        #expect(DNATables.sinceWords(k["reunion-9-days"]!.relationship.sinceLastTalk ?? 0) == "9 days ago")
        #expect(k["reunion-9-days"]!.guidance.rules.contains(.g5))
        // 6: late night, sleepy voice, one sentence.
        #expect(k["exhausted-late-night"]!.partOfDay == .lateNight)
        #expect(k["exhausted-late-night"]!.guidance.length == "one short sentence")
        // 7: playfulness lots.
        #expect(k["giddy-play"]!.guidance.playfulnessWord == "lots")
        // 8: a child, a placeholder, the held-up ball.
        let child = DNAPrompt.text(k["child-stranger-initiative"]!)
        #expect(child.contains("Age: 6 robot-years, a child"))
        #expect(child.contains("red ball (back camera, they're showing it to you)"))
        #expect(child.contains("Someone you don't know yet"))
        // 4: no playful notes in a sad scene; zero playfulness.
        #expect(k["user-sad"]!.guidance.playfulness == 0)
    }

    @Test func sessionInstructionsArePinned() throws {
        try Self.check(DNASessionInstructions.v1 + "\n", file: "session-instructions.v1.txt")
        try Self.check(DNASessionInstructions.v2 + "\n", file: "session-instructions.v2.txt")
        try Self.check(DNASessionInstructions.v3 + "\n", file: "session-instructions.v3.txt")
        try Self.check(DNASessionInstructions.v4 + "\n", file: "session-instructions.v4.txt")
        try Self.check(DNASessionInstructions.v5 + "\n", file: "session-instructions.v5.txt")
        #expect(DNAPrompt.sessionInstructions() == DNASessionInstructions.v5)
        #expect(DeeDNA.version == "v5")
        for banned in ["Maya", "2026", "October", "/255", "<", ">", "[", "]"] { #expect(!DNASessionInstructions.v5.contains(banned)) }
        // Tune 4: the follow-up is asked first; every sentence counts. Nothing else changed.
        #expect(DNASessionInstructions.v5.contains("An \"Ask now, first\" line is not optional: ask it in your first sentence"))
        #expect(DNASessionInstructions.v5.contains("count every sentence, even a one-word one"))
        let v4Lines = DNASessionInstructions.v4.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(v4Lines.filter { DNASessionInstructions.v5.contains($0) }.count == v4Lines.count - 2, "only the two tune-4 lines changed")
        for banned in ["Maya", "2026", "October", "/255", "<", ">", "[", "]"] { #expect(!DNASessionInstructions.v4.contains(banned)) }
        // Tune 3: "Ask now, first" is asked, a reunion names the time apart lightly, no assistant talk about limits.
        for needed in ["An \"Ask now, first\" line is not optional", "say lightly how long it has been",
                       "\"I don't have access to real-time data\"", "\"I can't see that from here\"",
                       "Never make anyone feel guilty for being away"] {
            #expect(DNASessionInstructions.v4.contains(needed), "v4 lacks: \(needed)")
        }
        // v4 keeps everything v3 asked for.
        let v3Lines = DNASessionInstructions.v3.components(separatedBy: "\n").filter { !$0.isEmpty }
        let kept = v3Lines.filter { DNASessionInstructions.v4.contains($0) }.count
        #expect(kept >= v3Lines.count - 3, "only the three tune-3 lines changed")
        // Live eval R1/R5/R6: the turn block, no helper talk, no preamble, the hard length cap.
        for needed in ["WHAT THE DNA LINES MEAN FOR THIS TURN", "React to what they just said first.", "let the \"Do now\" wait",
                       "\"Careful with them\" lines are private cautions", "let them tell it; don't tell one of your own",
                       "Never offer help", "Never speak a preamble", "The \"Length:\" line is a hard limit"] {
            #expect(DNASessionInstructions.v2.contains(needed), "v2 lacks: \(needed)")
        }
        // Tune 2: silent tools (F-LEAK) and the counted length (F-LEN).
        for needed in ["Tools are silent: the person never hears you announce, plan or narrate one.", "A tool call is never preceded by words about it", "\"let me respond\"",
                       "count your sentences and stop when you reach it", "never a list of tips",
                       "WHAT THE DNA LINES MEAN FOR THIS TURN", "let them tell it; don't tell one of your own", "Never offer help"] {
            #expect(DNASessionInstructions.v3.contains(needed), "v3 lacks: \(needed)")
        }
    }

    /// Writes the live-evaluator samples when DEE_DNA_SAMPLES is set (no-op otherwise).
    @Test func writeSamples() throws {
        guard let path = ProcessInfo.processInfo.environment["DEE_DNA_SAMPLES"] else { return }
        var md = ["# Dee DNA \(DeeDNA.version) — rendered samples", "",
                  "Generated by `DNAGoldenTests.writeSamples` from the §5.5 archetype fixtures (docs/DNA.md). "
                  + "Token sizes use the §2.1 estimate `ceil(utf8 bytes / 3.6)`.", ""]
        md += ["| # | Archetype | Full est. tokens | Sent est. tokens | Sent bytes | Degrade steps | Rules | Voice |", "|---|---|---|---|---|---|---|---|"]
        var bodies: [String] = []
        for (i, a) in DNAKit.all.enumerated() {
            let dna = DNAAssembler.assemble(a.inputs)
            let r = DNAPrompt.render(dna)
            let full = DNAPrompt.estimate(DNAPrompt.join(DNAPrompt.compose(dna, DNAPrompt.Options())))
            md.append("| \(i + 1) | \(a.name) | \(full) | \(r.estimatedTokens) | \(r.text.utf8.count) | \(r.steps.isEmpty ? "none" : r.steps.map(\.rawValue).joined(separator: ", ")) | \(dna.guidance.rules.map(\.rawValue).joined(separator: " ")) | \(dna.guidance.voice) |")
            bodies += ["## \(i + 1). \(a.name)", "", "```text", r.text, "```", ""]
        }
        let maxR = DNAPrompt.render(DNAAssembler.assemble(DNAKit.maxLength()))
        let maxFull = DNAPrompt.estimate(DNAPrompt.join(DNAPrompt.compose(DNAAssembler.assemble(DNAKit.maxLength()), DNAPrompt.Options())))
        md.append("| — | max-length fixture | \(maxFull) | \(maxR.estimatedTokens) | \(maxR.text.utf8.count) | \(maxR.steps.map(\.rawValue).joined(separator: ", ")) | | |")
        md += ["", "Session instructions (`DNASessionInstructions.current`): \(DNAPrompt.estimate(DNASessionInstructions.current)) estimated tokens, "
               + "\(DNASessionInstructions.current.utf8.count) bytes.", ""]
        md += bodies
        md += ["## Max-length fixture (after degradation)", "", "```text", maxR.text, "```", ""]
        md += ["## Session instructions (DNASessionInstructions.current)", "", "```text", DNASessionInstructions.current, "```", ""]
        try Data(md.joined(separator: "\n").utf8).write(to: URL(fileURLWithPath: path))
    }
}
