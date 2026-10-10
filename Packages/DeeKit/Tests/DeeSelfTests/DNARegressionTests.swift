import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// Regressions for the 2026-10-09 DNA review (findings 4–14) and the live evaluation
/// against gpt-realtime-2.1-mini (R1–R9). Privacy findings 1–3 and 6 are in
/// DNAPrivacyTests; the budget (12) in DNAGoldenTests.
@Suite struct DNARegressionTests {
    static func lines(_ text: String) -> [String] { text.split(separator: "\n").map(String.init) }
    static func line(_ text: String, _ prefix: String) -> String? { lines(text).first { $0.hasPrefix(prefix) } }

    // MARK: Finding 4 — the trait number and level word are one value

    @Test func traitNumberAndLevelWordAgree() {
        for a in DNAKit.all + [DNAKit.childStrangerInitiative()] {
            for l in Self.lines(DNAPrompt.build(a.inputs).text) {
                guard let t = DeeMind.Trait.allCases.first(where: { l.hasPrefix("\($0.rawValue) ") }), l.contains("/255 ") else { continue }
                let rest = l.dropFirst(t.rawValue.count + 1)
                let n = Int(rest.prefix { $0.isNumber })!
                #expect(rest.dropFirst("\(n)/255 ".count).hasPrefix(TraitLevel(byte: n).words + ":"), "\(a.name): \(l)")
            }
        }
        let child = DNAPrompt.build(DNAKit.childStrangerInitiative().inputs).text
        #expect(child.contains("patience 105/255 moderate: reasonably patient (born high; your age shapes it)"))
    }

    // MARK: Finding 5 — length never contradicts G9 or G13

    @Test func lengthNeverContradictsTiredOrSpeakingFirst() {
        var sadFirst = DNAKit.userSad().inputs
        sadFirst.turn = TurnContext(kind: .initiative, index: 5, initiative: "Ask how they are doing.", mode: .exact)
        sadFirst.mind = DNAKit.snapshot([.sadness: 0.3, .interest: 0.7, .affection: 0.66, .trust: 0.64, .joy: 0.4, .energy: 0.8])
        let d1 = DNAAssembler.assemble(sadFirst)
        #expect(d1.guidance.length != "at most three short sentences")
        #expect(!d1.guidance.doLines.contains { $0.contains("one or two") || $0.contains("two or three") })

        var tired = DNAKit.userSad().inputs
        tired.mind = DNAKit.snapshot([.sadness: 0.3, .interest: 0.7, .affection: 0.66, .trust: 0.64, .joy: 0.4, .energy: 97.0 / 255])
        let d2 = DNAAssembler.assemble(tired)
        #expect(d2.guidance.rules.contains(.g9))
        #expect(d2.guidance.length != "at most three short sentences", "\(d2.guidance.length)")
        // The line is a hard cap, stated first in section 9.
        let text = DNAPrompt.build(tired).text
        let s9 = Self.lines(text).drop { $0 != "9 HOW TO RESPOND" }.dropFirst()
        // v5: "…, 25 words in all; stop after the second." (one sentence: "…, 12 words; stop.").
        #expect(s9.first?.hasPrefix("Length: ") == true && s9.first?.contains(" words") == true
                && (s9.first?.hasSuffix("; stop.") == true || s9.first?.hasSuffix(" in all; stop after the second.") == true), "\(s9.first ?? "")")
    }

    // MARK: Finding 7 — reunion never says "happy" over unpleasant feelings

    @Test func reunionOverallFollowsTheFeelings() {
        var inputs = DNAKit.reunion9Days().inputs
        inputs.mind = DNAKit.snapshot([.loneliness: 0.8, .sadness: 0.55, .joy: 0.2, .energy: 0.2])
        let dna = DNAAssembler.assemble(inputs)
        let overall = DNAPrompt.build(inputs).text
        if dna.valence < 0 { #expect(Self.line(overall, "Overall: ")?.hasPrefix("Overall: happy") == false, "\(Self.line(overall, "Overall: ") ?? "")") }
        #expect(!dna.blend.contains("lonely"))
        // No excited/giddy delivery on low energy.
        if dna.guidance.voice.contains("low energy") {
            for bouncy in ["bouncy", "giggly", "breathless", "beaming"] { #expect(!dna.guidance.voice.contains(bouncy), "\(dna.guidance.voice)") }
        }
        #expect(DNAAssembler.assemble(DNAKit.reunion9Days().inputs).restingExpression == .happy)   // pleasant reunion: still happy
    }

    // MARK: Finding 8 — no play next to rudeness; humour lessons go quiet on hostile turns

    @Test func rudenessSilencesPlayAndHumourLessons() {
        var inputs = DNAKit.giddyPlay().inputs
        var a = Appraisal()
        a.hostility = 0.5
        inputs.turn = TurnContext(kind: .reply, index: 12, mode: .exact)
        inputs.appraisal.text = a
        let dna = DNAAssembler.assemble(inputs)
        #expect(dna.guidance.rules.contains(.g1) && !dna.guidance.rules.contains(.g8))
        #expect(dna.guidance.playfulness == 0 && dna.guidance.playfulnessWord == "none")
        #expect(dna.relationship.lesson == nil)
        let text = DNAPrompt.build(inputs).text
        #expect(!text.contains("play is welcome") && !text.contains("Careful with them"))
        // The insulted golden has no "joking" reading either.
        #expect(!DNAPrompt.build(DNAKit.insultedRuptured().inputs).text.contains("joking"))
    }

    // MARK: Finding 9 — calendar days, not 24-hour blocks

    @Test func dueTomorrowIsTomorrowAndYesterdayIsYesterday() {
        var inputs = DNAKit.fondMorning().inputs
        let now = DNAKit.local(21, 0)
        inputs.now = now
        inputs.moment.ongoing.expectations = [
            Expectation(id: DNAKit.id(700), person: DNAKit.maya, subject: DNAKit.subject("job interview"), due: DNAKit.local(10, 0, dayOffset: 1),
                        expires: DNAKit.local(10, 0, dayOffset: 3), framing: .neutral),
            Expectation(id: DNAKit.id(701), person: DNAKit.maya, subject: DNAKit.subject("dentist visit"), due: DNAKit.local(22, 0, dayOffset: -1),
                        expires: DNAKit.local(10, 0, dayOffset: 3), framing: .neutral),
        ]
        let text = DNAPrompt.build(inputs).text
        #expect(text.contains("Coming up for them: job interview tomorrow."), "\(Self.line(text, "Coming up") ?? "none")")
        #expect(text.contains("how their dentist visit went (due yesterday)"), "\(Self.line(text, "Waiting") ?? "none")")
        // Later the same evening is still today.
        inputs.moment.ongoing.expectations[0].due = DNAKit.local(23, 30)
        #expect(DNAPrompt.build(inputs).text.contains("job interview later today"))
    }

    // MARK: Finding 10 — never "Energy high" with a quiet, hurt voice

    @Test func hurtVoiceCapsTheEnergyWord() {
        let dna = DNAAssembler.assemble(DNAKit.insultedRuptured().inputs)
        #expect(dna.guidance.voice.hasPrefix("quiet, wounded"))
        #expect(dna.guidance.energyWord == "medium")
    }

    // MARK: Finding 11 + R2 — lessons: only about this person, private, never in "Do"

    @Test func lessonsArePrivateReadingsAboutThisPersonOnly() {
        // The stranger: the general "wait" lesson is not "Careful with them" and not in Do.
        let child = DNAPrompt.build(DNAKit.childStrangerInitiative().inputs).text
        #expect(!child.contains("Careful with them") && !child.contains("wait a bit"))
        #expect(!DNAAssembler.assemble(DNAKit.childStrangerInitiative().inputs).relationship.waitBeforeAnswering)
        // Maya, replying: the timing lesson goes to the app, never into the text.
        let fond = DNAAssembler.assemble(DNAKit.fondMorning().inputs)
        #expect(fond.relationship.waitBeforeAnswering)
        let text = DNAPrompt.build(DNAKit.fondMorning().inputs).text
        #expect(!text.contains("wait a bit before answering"))
        #expect(text.contains("Careful with them (private; act on it silently): they like to tease, so read harsh-sounding words generously before taking offence."))
        // No lesson wording is ever copied into Do, and "check if they're joking" is gone.
        for a in DNAKit.all {
            let t = DNAPrompt.build(a.inputs).text
            #expect(!t.contains("check if they're joking"), "\(a.name)")
            let doLine = Self.line(t, "Do: ") ?? ""
            for s in Lesson.Situation.allCases {
                if let r = DNATables.lessonReading(s) { #expect(!doLine.contains(r), "\(a.name): lesson in Do") }
            }
            #expect(!DNAAssembler.assemble(a.inputs).guidance.rules.contains(.g11), "\(a.name): G11 is retired")
        }
        // A general teasing lesson stays under "Lately you've learned".
        var inputs = DNAKit.childStrangerInitiative().inputs
        inputs.moment.enduring.lessons.append(Lesson(id: DNAKit.id(710), person: nil, situation: .tookLiterally, evidence: 4, createdAt: inputs.now))
        let g = DNAPrompt.build(inputs).text
        #expect(g.contains("Lately you've learned that people often tease, so read harsh-sounding words generously."), "\(g)")
        #expect(!g.contains("Careful with them"))
    }

    // MARK: Finding 14 — the minimal DNA keeps boundaries and repair, not notes

    @Test func minimalDNAKeepsBoundariesAndRepairButNotNotes() {
        let dna = DNAAssembler.assemble(DNAKit.insultedRuptured().inputs)
        let r = DNAPrompt.render(dna, budget: DNABudget(target: 10, cap: 20))
        #expect(r.steps.last == .minimal)
        #expect(r.text.contains("Don't bring up: her ex.") && r.text.contains("Repair: You're upset with them"))
        #expect(!Self.lines(r.text).contains { $0.hasPrefix("Do now") || $0.hasPrefix("Keep in mind") })
        DNACompletenessTests.checkParameters(r.text, code: dna.mindCode, age: dna.age, "minimal")
    }

    // MARK: R3 — a pending boundary or ask-after yields to an apology, a joke or distress

    @Test func pendingNotesYieldToApologyJokeAndDistress() {
        // Insulted state, but this turn is an apology: no boundary restatement, no G1.
        var sorry = DNAKit.insultedRuptured().inputs
        var a = Appraisal()
        a.apology = 0.7
        sorry.appraisal.text = a
        let d = DNAAssembler.assemble(sorry)
        #expect(!DNAPrompt.build(sorry).text.contains("Do now"))
        #expect(!d.guidance.rules.contains(.g1) && d.guidance.rules.contains(.g2))
        // The rude turn itself still carries it.
        #expect(DNAPrompt.build(DNAKit.insultedRuptured().inputs).text.contains("Do now (once, only if it still fits what they just said): Calmly say"))
        // Distress: the exam follow-up waits.
        #expect(!DNAPrompt.build(DNAKit.userSad().inputs).text.contains("exam"))
        // A joke: the gag callback waits.
        var joke = DNAKit.giddyPlay().inputs
        var j = Appraisal()
        j.humor = 0.8
        joke.turn = TurnContext(kind: .reply, index: 12, mode: .exact)
        joke.appraisal.text = j
        #expect(!DNAPrompt.build(joke).text.contains("toaster that judges you"))
        // Fast mode (no text appraisal): notes stay, the model decides with the v2 wording.
        #expect(DNAPrompt.build(DNAKit.giddyPlay().inputs).text.contains("toaster that judges you"))
    }

    // MARK: R8 — speak-first content never rides on a reply; asking a name yields to distress

    @Test func initiativeContentStaysOnInitiatives() {
        var reply = DNAKit.childStrangerInitiative().inputs
        reply.turn = TurnContext(kind: .reply, index: 2, initiative: "Ask one short question about the red ball you just noticed.", mode: .exact)
        var a = Appraisal()
        a.distress = 0.7
        reply.appraisal.text = a
        let text = DNAPrompt.build(reply).text
        #expect(!text.contains("What to open with") && !text.contains("Speak first"))
        let rules = DNAAssembler.assemble(reply).guidance.rules
        #expect(rules.contains(.g3) && !rules.contains(.g4) && !rules.contains(.g13))
    }

    // MARK: R1/R4/R5 — wording

    @Test func liveEvalWordingIsInTheRender() {
        let insulted = DNAPrompt.build(DNAKit.insultedRuptured().inputs).text
        #expect(insulted.contains("If they apologise, joke or are kind, let it soften you."))
        for a in DNAKit.all {
            let t = DNAPrompt.build(a.inputs).text
            #expect(t.hasPrefix("DEE DNA v5 "))
            #expect(Self.line(t, "Always: ")?.contains("offers to help; no preamble, your first words are the answer") == true, "\(a.name)")
        }
    }
}
