import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// Tune 4 (character): the tune-3 live run (tune3-live.md §F5), replayed in the
/// harness's percept order (`Tune3CharacterTests` helpers).
struct Tune4CharacterTests {
    typealias C = Tune3CharacterTests

    // MARK: (a) ordinary appointments are followed up by name

    /// t2-followup-dentist, live tune 3: "Hi Alex! … How have you been feeling?" — the
    /// gentle health aim never named the dentist and the probe failed. Decision (a): an
    /// ordinary appointment is asked by name; the DNA says "how their dentist appointment
    /// went", and "How did the dentist go?" counts as asked.
    @Test func liveDentistIsAskedByName() throws {
        let mind = Kit.snap()
        var cx = C.firstConversation("I have a dentist appointment next Tuesday at three.", at: SimClock.at("Sat 04:11", week: 2)!, mind: mind)
        let x = try #require(cx.moment.ongoing.expectations.first)
        let f = try #require(cx.moment.ongoing.intentions.first { $0.kind == .followUp })
        #expect(f.reason != IntentionBoard.healthReason, "\(f.reason)")
        let back = SimClock.at("Wed 01:00", week: 3)!                     // Tue 18:00 PDT
        C.comeBack(&cx, at: back, mind: mind)
        let r1 = C.reply(&cx, at: back.addingTimeInterval(7.7), mind: mind)
        #expect(r1.contains("Ask how their dentist appointment went."), "\(r1)")
        #expect(!r1.contains("Gently ask"), "\(r1)")
        let aim = try #require(cx.stance.notes.first { $0.role == .aim })
        #expect(aim.kind == .followUp)
        let dna = Tune3DNATests.render(cx, at: back.addingTimeInterval(7.7))
        #expect(dna.contains("Ask now, first: how their dentist appointment went."), "\(dna)")
        // The live split + cancel, then the reply they heard asks it by name.
        _ = cx.step(Kit.heard("Hi, Dee."), mind: mind, at: back.addingTimeInterval(8.1))
        _ = cx.step(.deeTurnFinished(text: ""), mind: mind, at: back.addingTimeInterval(8.2))
        let r2 = C.reply(&cx, at: back.addingTimeInterval(9.2), mind: mind)
        #expect(r2.contains("Ask how their dentist appointment went."), "\(r2)")
        _ = cx.step(.deeSaid(tag: nil, sentence: "Hi Alex, glad you're back! How did the dentist go?"), mind: mind, at: back.addingTimeInterval(10))
        _ = cx.step(.deeTurnFinished(text: ""), mind: mind, at: back.addingTimeInterval(10.5))
        #expect(cx.moment.ongoing.expectations.first?.status == .asked, "\"How did the dentist go?\" asked it")
        #expect(cx.intentionBoard.awaitingOutcome == x.id)
    }

    /// Serious health stays gentle (decision a): surgery, diagnosis, hospital, results, therapy.
    @Test func seriousHealthStaysGentle() throws {
        let mind = Kit.snap()
        for line in ["I have surgery next Tuesday at three.", "My biopsy results come next Tuesday at three.",
                     "I have a hospital appointment next Tuesday at three.", "I have therapy next Tuesday at three."] {
            var cx = C.firstConversation(line, at: SimClock.at("Sat 04:11", week: 2)!, mind: mind)
            guard let f = cx.moment.ongoing.intentions.first(where: { $0.kind == .followUp }) else {
                Issue.record("no follow-up: \(line)"); continue
            }
            #expect(f.reason == IntentionBoard.healthReason, "\(line)")
            let back = SimClock.at("Wed 01:00", week: 3)!
            C.comeBack(&cx, at: back, mind: mind)
            let r = C.reply(&cx, at: back.addingTimeInterval(7.7), mind: mind)
            #expect(r.contains(C.gentle), "\(line): \(r)")
            #expect(!r.contains("Ask how their"), "\(line): \(r)")
        }
    }

    /// Ordinary appointments by name; a follow-up persisted gently by an older build is
    /// re-read by its subject (dentist → named), a serious one stays gentle.
    @Test func ordinaryAppointmentsAndPersistedHealthReasons() {
        for s in ["dentist appointment", "check-up", "doctor's appointment", "vet", "haircut", "flu jab"] {
            #expect(!IntentionBoard.isHealth(Subject(s)!), "\(s)")
        }
        for s in ["surgery", "diagnosis", "hospital appointment", "test results", "therapy", "funeral", "court hearing"] {
            #expect(IntentionBoard.isHealth(Subject(s)!), "\(s)")
        }
        func it(_ s: String) -> Intention {
            Intention(id: UUID(), kind: .followUp, subject: Subject(s)!, person: Kit.john, reason: IntentionBoard.healthReason,
                      notBefore: Kit.t0, expires: Kit.t0, priority: 0.8, source: "plan", created: Kit.t0)
        }
        #expect(!IntentionBoard.isGentle(it("dentist appointment")))
        #expect(IntentionBoard.isGentle(it("knee surgery")))
        #expect(IntentionBoard.isGentle(it("mammogram")), "flagged health by the Interpreter, no ordinary word")
        #expect(!IntentionBoard.isGentle(it("eye test")), "an eye test is ordinary")
        #expect(IntentionBoard.mentionsAnyWord("How did the dentist go?", Subject("dentist appointment")!))
        #expect(!IntentionBoard.mentionsAnyWord("How was your appointment?", Subject("dentist appointment")!), "filler alone")
    }

    // MARK: reunion greeting survives an unheard reply

    /// t2-reunion-morning, live tune 3: the server split "Good morning." / "Did you sleep
    /// well?"; reply 1 (with "Do: Greet them warmly and … it's been 2 days") was cancelled
    /// unheard, and its `.deeTurnFinished` ended the reunion turn, so reply 2's DNA had no
    /// greeting Do line and she said "I don't sleep like you do…". Both live orders of the
    /// transcript and the cancel are replayed.
    @Test(arguments: [true, false])
    func liveReunionMorningGreetingSurvivesACancelledReply(transcriptFirst: Bool) throws {
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
        let greet = "mention lightly that it's been a couple of days"

        // Reply 1 at the commit of "Good morning." (23.28 live).
        let t1 = back.addingTimeInterval(21)
        _ = C.reply(&cx, at: t1, mind: mind)
        let dna1 = Tune3DNATests.render(cx, at: t1)
        #expect(dna1.contains(greet), "\(dna1)")
        // The user goes on (23.60): reply 1 is cancelled with nothing heard.
        if transcriptFirst {
            _ = cx.step(Kit.heard("Good morning."), mind: mind, at: t1.addingTimeInterval(0.37))
            _ = cx.step(.deeTurnFinished(text: ""), mind: mind, at: t1.addingTimeInterval(0.45))
        } else {
            _ = cx.step(.deeTurnFinished(text: ""), mind: mind, at: t1.addingTimeInterval(0.32))
            _ = cx.step(Kit.heard("Good morning."), mind: mind, at: t1.addingTimeInterval(0.37))
        }
        #expect(cx.moment.ongoing.reunionTurn, "an unheard reply does not end the reunion turn")

        // Reply 2 at the commit of "Did you sleep well?" (24.86 live).
        let t2 = t1.addingTimeInterval(1.58)
        _ = C.reply(&cx, at: t2, mind: mind)
        let dna2 = Tune3DNATests.render(cx, at: t2, index: 2)
        #expect(dna2.contains(greet), "\(dna2)")
        _ = cx.step(Kit.heard("Did you sleep well?"), mind: mind, at: t2.addingTimeInterval(0.38))
        #expect(cx.moment.ongoing.reunionTurn, "their second fragment is still the reunion turn")
        _ = cx.step(.deeSaid(tag: nil, sentence: "Good morning, it's been two days, I'm so glad you're back!"), mind: mind, at: t2.addingTimeInterval(0.9))
        _ = cx.step(.deeTurnFinished(text: ""), mind: mind, at: t2.addingTimeInterval(1.0))
        #expect(!cx.moment.ongoing.reunionTurn, "a heard reply ends it")

        // The next reply is ordinary.
        _ = cx.step(Kit.heard("Nice. What are you up to?"), mind: mind, at: t2.addingTimeInterval(5))
        let t3 = t2.addingTimeInterval(5.5)
        _ = C.reply(&cx, at: t3, mind: mind)
        let dna3 = Tune3DNATests.render(cx, at: t3, index: 3)
        #expect(!dna3.contains(greet), "\(dna3)")
    }
}
