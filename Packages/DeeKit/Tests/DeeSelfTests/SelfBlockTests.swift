import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

@Suite struct SelfBlockTests {
    static func taste(_ s: String, _ polarity: Double, evidence: Int = 4, revealed: Bool = true, crystallised: Bool = true) -> Facet {
        Facet(id: UUID(), kind: .taste, subject: Subject(s)!, innate: polarity, learned: polarity, polarity: polarity, evidence: evidence,
              crystallised: crystallised, revealedAt: revealed ? Kit.t0 : nil, source: .heuristic, updatedAt: Kit.t0)
    }

    static var rich: Enduring {
        var e = Kit.enduring()
        e.facets += [taste("rain sounds", 0.8), taste("vacuum cleaners", -0.7), taste("secret thing", 0.9, revealed: false),
                     taste("latent", 0.9, crystallised: false)]
        e.lessons = [Lesson(id: UUID(), person: Kit.john, situation: .tookLiterally, createdAt: Kit.t0)]
        e.boundaries = [Boundary(id: UUID(), person: Kit.john, topic: Subject("job")!, owner: .user, createdAt: Kit.t0)]
        return e
    }

    @Test func fitsBudgetAndAlwaysHasValues() {
        for seed: UInt64 in 0..<30 {
            var e = Self.rich
            e.seed = seed
            let lines = SelfBlock.render(e, person: Kit.john)
            #expect(CueWriter.estimateTokens(lines[0]) <= SelfBlock.maxTokens, "\(lines[0])")
            #expect(lines[0].hasPrefix("About you: you value "))
            #expect(lines.count == 2 && lines[1] == "Don't bring up: job.")
            #expect(CueWriter.estimateTokens(lines[1]) <= SelfBlock.maxBoundaryTokens)
        }
    }

    @Test func dropOrderWithARealisticCounter() {
        let e = Self.rich
        let all = SelfBlock.lines(e, person: Kit.john).map(\.line)
        #expect(all == [.values, .humour, .tastes, .capability, .lesson])
        let roomy = SelfBlock.render(e, person: Kit.john, budget: 1000)[0]
        #expect(roomy.contains("Lately you've learned to check if they're joking."))
        #expect(roomy.contains("You love rain sounds and find vacuum cleaners suspicious."))
        func without(_ dropped: Set<SelfBlock.Line>) -> String {
            SelfBlock.lines(e, person: Kit.john).filter { !dropped.contains($0.line) }.map(\.text).joined(separator: " ")
        }
        let count = CueWriter.estimateTokens
        #expect(SelfBlock.render(e, person: Kit.john, budget: count(without([.lesson])))[0] == without([.lesson]))
        #expect(SelfBlock.render(e, person: Kit.john, budget: count(without([.lesson, .capability])))[0] == without([.lesson, .capability]))
        #expect(SelfBlock.render(e, person: Kit.john, budget: count(without([.lesson, .capability, .tastes])))[0] == without([.lesson, .capability, .tastes]))
        #expect(SelfBlock.render(e, person: Kit.john, budget: 1)[0] == without([.lesson, .capability, .tastes, .humour]), "values always stay")
    }

    @Test func neverUnrevealedTastesOrIntentions() {
        let lines = SelfBlock.render(Self.rich, person: Kit.john, budget: 10_000).joined(separator: "\n")
        #expect(!lines.contains("secret thing"))
        #expect(!lines.contains("latent"))
        // Intentions are not even an input: Enduring has none, and Ongoing is never read.
    }

    @Test func lessonsAndBoundariesArePerPerson() {
        let forAnn = SelfBlock.render(Self.rich, person: Kit.ann, budget: 10_000)
        #expect(forAnn.count == 1)
        #expect(!forAnn[0].contains("Lately"))
        let unknown = SelfBlock.render(Self.rich, person: nil, budget: 10_000)
        #expect(unknown.count == 1)
    }

    @Test func boundaryLineCapsAtThreeAndFifteenTokens() {
        var e = Kit.enduring()
        for (i, t) in ["job", "my ex", "money", "school"].enumerated() {
            e.boundaries.append(Boundary(id: UUID(), person: Kit.john, topic: Subject(t)!, owner: .user, createdAt: Kit.t0.addingTimeInterval(Double(i))))
        }
        e.boundaries.append(Boundary(id: UUID(), person: Kit.john, topic: Subject("rudeness")!, owner: .dee, createdAt: Kit.t0))
        let line = SelfBlock.boundaryLine(e, person: Kit.john)!
        #expect(line == "Don't bring up: school, money, my ex.")
        #expect(CueWriter.estimateTokens(line) <= 15)
        e.boundaries = e.boundaries.map { var b = $0; b.active = false; return b }
        #expect(SelfBlock.boundaryLine(e, person: Kit.john) == nil)
    }

    @Test func ruleLinesAreFixed() {
        #expect(SelfBlock.ruleLines.count == 2)
        #expect(Cortex.ruleLines == SelfBlock.ruleLines)
        #expect(SelfBlock.ruleLines.map(CueWriter.estimateTokens).reduce(0, +) <= 75)
    }

    // MARK: Frozen per conversation

    @Test func selfLinesFrozenUntilNextConversation() {
        var cx = Kit.cortex()
        let before = cx.selfLines(person: Kit.john, at: Kit.t0)
        var e = Self.rich
        e.seed = cx.moment.enduring.seed
        cx.setEnduring(e)
        _ = cx.step(.tick, mind: Kit.snap(), at: Kit.t0.addingTimeInterval(1))
        #expect(cx.selfLines(person: Kit.john, at: Kit.t0.addingTimeInterval(2)) == before, "mid-conversation changes wait")
        _ = cx.step(.conversationStarted(Kit.t0.addingTimeInterval(3)), mind: Kit.snap(), at: Kit.t0.addingTimeInterval(3))
        let after = cx.selfLines(person: Kit.john, at: Kit.t0.addingTimeInterval(4))
        #expect(after != before)
        #expect(after.contains("Don't bring up: job."))
    }

    /// The system prompt (the session instructions) is byte-identical on every turn
    /// of a conversation, while the per-turn cue changes; a new Persona is applied
    /// only at a new conversation.
    @Test func systemPromptByteIdenticalAcrossTurns() async throws {
        var cx = Kit.cortex()
        let start = Kit.t0
        let persona = cx.persona(Persona(userName: "John"), person: Kit.john, at: start)
        #expect(persona.ruleLines == SelfBlock.ruleLines)
        let system = persona.systemPrompt(date: start)
        #expect(system.contains("About you: you value"))
        var cues: [String] = []
        var mind = Kit.snap()
        for turn in 0..<4 {
            let t = start.addingTimeInterval(Double(turn) * 30)
            mind = Kit.snap([.joy: 0.3 + 0.15 * Double(turn), .interest: 0.9 - 0.1 * Double(turn)], seq: UInt64(turn + 1))
            _ = cx.step(Kit.heard("hello"), mind: mind, at: t)
            // Enduring changes mid-conversation must not reach the prompt.
            var e = Self.rich
            e.seed = UInt64(turn)
            cx.setEnduring(e)
            _ = cx.step(.promptSubmitted, mind: mind, at: t)
            cues.append(cx.cueText(at: t))
            let now = cx.persona(Persona(userName: "John"), person: Kit.john, at: t)
            #expect(now == persona, "turn \(turn): frozen for the conversation")
            #expect(now.systemPrompt(date: start) == system)
            #expect(!system.contains(cues.last!), "the cue goes with the turn, never into the prompt")
        }
        #expect(Set(cues).count > 1, "the cue does change per turn")
        #expect(cx.persona(Persona(userName: "John"), person: Kit.john, at: start) == persona, "still frozen")
    }
}
