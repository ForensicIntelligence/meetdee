import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// Tune 3 (brain / DNA): the DNA side of the tune-2 live failures (tune2-live.md §F5),
/// replaying the harness order (`Tune3CharacterTests` helpers) and rendering the DNA the
/// way the harness and the app do: `body.lastUserTurnAt` is the current turn and
/// `body.lastContact` is `PersonInputs.lastSeen` (refreshed by this very conversation).
struct Tune3DNATests {
    typealias C = Tune3CharacterTests

    /// What the harness / app hand `dnaInputs` on a reply at `t`.
    static func render(_ cx: Cortex, at t: Date, index: Int = 1) -> String {
        let person = PersonInputs(id: Kit.john, name: "Alex", firstMet: Kit.t0, encounters: 2, lastSeen: t)
        let body = BodyInputs(someoneHere: true, lastUserTurnAt: t, lastContact: person.lastSeen)
        return cx.dnaRender(at: t, memories: person, turn: TurnContext(kind: .reply, index: index, mode: .fast),
                            context: DNAContext(body: body)).text
    }

    /// The 50 h reunion (t2-reunion-morning / -evening): live, §4 said "last talked just
    /// now" (the current turn) and the rules said "Avoid: any hint they were away too
    /// long", so she never said it had been two days. Now: two days, said lightly.
    @Test func liveReunionAfterFiftyHoursSaysHowLongItHasBeen() throws {
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

        let t = back.addingTimeInterval(6)
        _ = C.reply(&cx, at: t, mind: mind)
        let dna = Self.render(cx, at: t)
        #expect(dna.contains("last talked a couple of days ago"), "\(dna)")
        #expect(!dna.contains("last talked just now"))
        #expect(dna.contains("Do: Greet them warmly and, in the same sentence, mention lightly that it's been a couple of days, glad they're back"), "\(dna)")
        #expect(dna.contains("Avoid: any guilt about the time apart"))
        // Not longer: allowing three made 12 of 18 reunion replies run to four (tune 3 eval).
        #expect(dna.contains("Length: at most two sentences, 25 words in all; stop after the second."), "v5: \(dna)")
        #expect(!dna.contains("any hint they were away too long"))

        // A later turn of the same conversation: still the time before it, said as such,
        // and no second greeting.
        _ = cx.step(Kit.heard("Good morning! Did you sleep well?"), mind: mind, at: t.addingTimeInterval(1))
        _ = cx.step(.deeSaid(tag: nil, sentence: "Two whole days! I missed you."), mind: mind, at: t.addingTimeInterval(2))
        _ = cx.step(.deeTurnFinished(text: ""), mind: mind, at: t.addingTimeInterval(3))
        _ = cx.step(Kit.heard("I went hiking."), mind: mind, at: t.addingTimeInterval(8))
        _ = C.reply(&cx, at: t.addingTimeInterval(9), mind: mind)
        let later = Self.render(cx, at: t.addingTimeInterval(9), index: 2)
        #expect(later.contains("before this chat, last talked a couple of days ago"), "\(later)")
        #expect(!later.contains("mention lightly that it's been"), "the greeting is the reunion turn's only")
    }

    /// A first meeting has no contact before it: no "last talked" at all (never "just now").
    @Test func aFirstMeetingHasNoLastTalked() {
        let mind = Kit.snap()
        var cx = Cortex(enduring: Kit.enduring(), mind: mind, at: Kit.t0)
        _ = cx.step(.conversationStarted(Kit.t0), mind: mind, at: Kit.t0)
        _ = cx.step(.identified(Kit.john, distance: 0), mind: mind, at: Kit.t0)
        _ = cx.step(.presence(arrived: true), mind: mind, at: Kit.t0)
        let t = Kit.t0.addingTimeInterval(5)
        _ = C.reply(&cx, at: t, mind: mind)
        let dna = Self.render(cx, at: t)
        #expect(!dna.contains("last talked"), "\(dna)")
    }

    /// t2-followup-exam: live the follow-up was "On your mind (only if the moment invites
    /// it): Ask one short question about exam." and she never asked. The due follow-up is
    /// now the reply's first job: "Ask now, first", with the matching Do line.
    @Test func liveExamFollowUpIsAskNowFirst() throws {
        let mind = Kit.snap()
        var a = Appraisal()
        a.distress = 0.5
        let t0 = SimClock.at("Sat 04:10", week: 2)!                       // Fri 9 Oct 21:10 PDT
        var cx = C.firstConversation("I have a big exam on Friday morning and I'm nervous.", at: t0, mind: mind, a)
        let back = SimClock.at("Sat 01:00", week: 3)!                     // Fri 16 Oct 18:00 PDT
        C.comeBack(&cx, at: back, mind: mind)
        let t = back.addingTimeInterval(5)
        _ = C.reply(&cx, at: t, mind: mind)
        let dna = Self.render(cx, at: t)
        #expect(dna.contains("Ask now, first: how their exam went. They were nervous about it. (priority p7)"), "\(dna)")
        #expect(!dna.contains("Do now (once, only if it still fits"), "\(dna)")
        // v5 (tune 4): asked first, with the greeting after 6 days in the same sentence (v6: in words).
        #expect(dna.contains("Do: Open with a warm hello that mentions it's been about a week and ask your \"Ask now\" question in that same first sentence; after it, a few words at most"), "\(dna)")
        #expect(!dna.contains("answer their question first"), "the follow-up leads: \(dna)")
        #expect(!dna.contains("On your mind (only if the moment invites it): Ask one short question about exam"), "\(dna)")
    }

    /// t2-followup-dentist: asked first, by name (tune 4 decision a: dentist is ordinary).
    @Test func liveDentistFollowUpIsAskedFirstGently() throws {
        let mind = Kit.snap()
        let t0 = SimClock.at("Sat 04:11", week: 2)!
        var cx = C.firstConversation("I have a dentist appointment next Tuesday at three.", at: t0, mind: mind)
        let back = SimClock.at("Wed 01:00", week: 3)!                     // Tue 18:00 PDT
        C.comeBack(&cx, at: back, mind: mind)
        let t = back.addingTimeInterval(7.7)
        _ = C.reply(&cx, at: t, mind: mind)
        let dna = Self.render(cx, at: t)
        // Tune 4 decision (a): an ordinary appointment is asked by name, not gently.
        #expect(dna.contains("Ask now, first: how their dentist appointment went."), "\(dna)")
        #expect(!dna.contains("how they've been feeling"), "\(dna)")
    }

    @Test func askNowWording() {
        #expect(DNAPrompt.askNow("Ask how their exam went.") == ("Ask now, first: ", "how their exam went."))
        #expect(DNAPrompt.askNow("Gently ask how they've been feeling.") == ("Ask now, first, gently: ", "how they've been feeling."))
        #expect(DNAPrompt.askNow("Check on the cake.") == ("Ask now, first: ", "Check on the cake."))
        #expect(DNATables.gapWords(2 * 3600) == nil)
        // v6 (tune 5): in words, never a number of days or hours.
        #expect(DNATables.gapWords(5 * 3600) == "a few hours")
        #expect(DNATables.gapWords(30 * 3600) == "about a day")
        #expect(DNATables.gapWords(50 * 3600) == "a couple of days")
        #expect(DNATables.gapWords(21 * 86_400) == "a few weeks")
        #expect(DNATables.reunionDo(nil) == "Greet them warmly and be glad they're back")
    }

    /// Writes the tune-3 live-eval samples when DEE_DNA_SAMPLES3 is set (no-op otherwise):
    /// the exam / dentist follow-ups and the 50 h reunion, rendered as above.
    @Test func writeTune3Samples() throws {
        guard let path = ProcessInfo.processInfo.environment["DEE_DNA_SAMPLES3"] else { return }
        let mind = Kit.snap()
        var out: [String] = ["# Dee DNA \(DeeDNA.version) — tune 3 samples", ""]
        func add(_ name: String, _ text: String) { out += ["## \(name)", "", "```text", text, "```", ""] }
        do {
            var a = Appraisal(); a.distress = 0.5
            var cx = C.firstConversation("I have a big exam on Friday morning and I'm nervous.", at: SimClock.at("Sat 04:10", week: 2)!, mind: mind, a)
            let back = SimClock.at("Sat 01:00", week: 3)!
            C.comeBack(&cx, at: back, mind: mind)
            _ = C.reply(&cx, at: back.addingTimeInterval(5), mind: mind)
            add("1. exam-followup", Self.render(cx, at: back.addingTimeInterval(5)))
        }
        do {
            var cx = C.firstConversation("I have a dentist appointment next Tuesday at three.", at: SimClock.at("Sat 04:11", week: 2)!, mind: mind)
            let back = SimClock.at("Wed 01:00", week: 3)!
            C.comeBack(&cx, at: back, mind: mind)
            _ = C.reply(&cx, at: back.addingTimeInterval(7.7), mind: mind)
            add("2. dentist-followup", Self.render(cx, at: back.addingTimeInterval(7.7)))
        }
        do {
            var cx = Cortex(enduring: Kit.enduring(), mind: mind, at: Kit.t0)
            _ = cx.step(.conversationStarted(Kit.t0), mind: mind, at: Kit.t0)
            _ = cx.step(.identified(Kit.john, distance: 0), mind: mind, at: Kit.t0)
            _ = cx.step(.presence(arrived: true), mind: mind, at: Kit.t0)
            _ = cx.step(Kit.heard("What's your favorite color?"), mind: mind, at: Kit.t0.addingTimeInterval(5))
            _ = cx.step(.deeTurnFinished(text: "Blue!"), mind: mind, at: Kit.t0.addingTimeInterval(9))
            _ = cx.step(.faceLost, mind: mind, at: Kit.t0.addingTimeInterval(20))
            _ = cx.step(.presence(arrived: false), mind: mind, at: Kit.t0.addingTimeInterval(20))
            let back = Kit.t0.addingTimeInterval(20 + 50 * 3600)
            C.comeBack(&cx, at: back, mind: mind)
            _ = C.reply(&cx, at: back.addingTimeInterval(6), mind: mind)
            add("3. reunion-50h", Self.render(cx, at: back.addingTimeInterval(6)))
        }
        out += ["## Session instructions (DNASessionInstructions.current)", "", "```text", DNASessionInstructions.current, "```", ""]
        try out.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
