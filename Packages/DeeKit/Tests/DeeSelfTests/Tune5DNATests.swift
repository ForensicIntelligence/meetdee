import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// Tune 5 (brain / DNA v6): the Cortex and DNA side of the tune-4 live findings
/// (scratchpad/tune4-live.md; traces Tools/voice-harness/Traces/20261010-003257).
struct Tune5DNATests {
    typealias C = Tune3CharacterTests

    // MARK: F1 — a barge-in the brain is answering never stops her

    /// Probe t4-probe-content-bargein (20261010-011423): the brain's answer ended the hold,
    /// the app sensed `.bargeIn`, FloorKeeper said `.stopSpeaking`, and the app's stop
    /// cancelled the answer. `.bargeInAnswered`: the same floor bookkeeping, no stop.
    @Test func anAnsweredBargeInKeepsTheBookkeepingWithoutAStop() {
        var r = FloorKeeperTests.Run()
        r.step(.promptSubmitted, at: 0)
        r.step(.speakingStarted, at: 1)
        r.step(.deeSaid(tag: .happy, sentence: "So the dog ran."), at: 1)
        let fx = r.step(.bargeInAnswered, at: 4)
        #expect(fx.isEmpty, "\(fx)")
        #expect(r.m.momentary.floor == .yielding(since: Kit.t0.addingTimeInterval(4)))
        #expect(r.m.ongoing.cutOff)
        #expect(r.m.momentary.floorEvents == [.cutOff])
        #expect(r.m.ongoing.noteCandidates.map(\.kind) == [.cutOff])
        // Within a second of her start it is still "Dee interrupted them".
        var q = FloorKeeperTests.Run()
        q.step(.speakingStarted, at: 1)
        #expect(q.step(.bargeInAnswered, at: 1.6).isEmpty)
        #expect(q.m.momentary.floorEvents == [.deeInterrupted, .cutOff])
        // The voice's own barge-in still stops her.
        var s = FloorKeeperTests.Run()
        s.step(.speakingStarted, at: 1)
        #expect(s.step(.bargeIn, at: 3) == [.stopSpeaking])
    }

    /// Through the whole Cortex (every reducer, as DeeModel steps it): no `.stopSpeaking`.
    @Test func theCortexNeverStopsAnAnsweredBargeIn() {
        let mind = Kit.snap()
        var cx = Cortex(enduring: Kit.enduring(), mind: mind, at: Kit.t0)
        _ = cx.step(.conversationStarted(Kit.t0), mind: mind, at: Kit.t0)
        _ = cx.step(.identified(Kit.john, distance: 0), mind: mind, at: Kit.t0)
        _ = cx.step(.presence(arrived: true), mind: mind, at: Kit.t0)
        _ = cx.step(Kit.heard("Tell me about your dog."), mind: mind, at: Kit.t0.addingTimeInterval(1))
        _ = cx.step(.promptSubmitted, mind: mind, at: Kit.t0.addingTimeInterval(1.2))
        _ = cx.step(.speakingStarted, mind: mind, at: Kit.t0.addingTimeInterval(2))
        _ = cx.step(.deeSaid(tag: nil, sentence: "So the dog ran all the way to the beach."), mind: mind, at: Kit.t0.addingTimeInterval(3))
        let fx = cx.step(.bargeInAnswered, mind: mind, at: Kit.t0.addingTimeInterval(5))
        #expect(!fx.contains(.stopSpeaking), "\(fx)")
        #expect(cx.moment.ongoing.cutOff)
        #expect(Percept.bargeInAnswered.name == "bargeInAnswered")
    }

    // MARK: F7 — the dentist follow-up is asked first

    /// t2-followup-dentist (tune 4 live): reply 1 to "Hi, Dee." ("Hi Alex! It's been three
    /// days—how") was taken back unheard, and its turn finished only after reply 2's
    /// notes were picked; reply 2's DNA had the follow-up as "On your mind", and she
    /// asked it fourth. The superseded reply's aims now go back at the newer prompt.
    @Test func liveDentistFollowUpSurvivesASupersededReply() throws {
        let mind = Kit.snap()
        let t0 = SimClock.at("Sat 04:11", week: 2)!
        var cx = C.firstConversation("I have a dentist appointment next Tuesday at three.", at: t0, mind: mind)
        let x = try #require(cx.moment.ongoing.expectations.first)
        let back = SimClock.at("Wed 01:00", week: 3)!
        C.comeBack(&cx, at: back, mind: mind)
        let r1 = C.reply(&cx, at: back.addingTimeInterval(7.0), mind: mind)          // 26.09 live
        #expect(r1.contains(C.named), "\(r1)")
        _ = cx.step(Kit.heard("Hi, Dee."), mind: mind, at: back.addingTimeInterval(7.4))
        // Reply 2's notes are picked (28.00) before reply 1's turn has finished.
        let r2 = C.reply(&cx, at: back.addingTimeInterval(9.0), mind: mind)
        #expect(r2.contains(C.named), "still \"Ask now, first\": \(r2)")
        #expect(r2.contains("They're back"), "\(r2)")
        // Reply 1's late finish (nothing of it heard) does not give back reply 2's aims.
        _ = cx.step(.deeTurnFinished(text: ""), mind: mind, at: back.addingTimeInterval(9.3))
        _ = cx.step(Kit.heard("How was your day?"), mind: mind, at: back.addingTimeInterval(9.4))
        _ = cx.step(.deeSaid(tag: nil, sentence: "Hey, you're back! How did the dentist go?"), mind: mind, at: back.addingTimeInterval(10))
        _ = cx.step(.deeTurnFinished(text: ""), mind: mind, at: back.addingTimeInterval(11))
        #expect(cx.moment.ongoing.expectations.first?.status == .asked)
        #expect(cx.intentionBoard.awaitingOutcome == x.id)
        // Spent: the next reply does not ask again.
        _ = cx.step(Kit.heard("Fine, no cavities."), mind: mind, at: back.addingTimeInterval(15))
        let r3 = C.reply(&cx, at: back.addingTimeInterval(15.5), mind: mind)
        #expect(!r3.contains(C.named) && !r3.contains(C.gentle), "\(r3)")
    }

    /// The tune-3 order (the cancelled reply finishes first) is unchanged.
    @Test func aCancelledReplyThatFinishesFirstStillGivesItsAimBack() throws {
        let mind = Kit.snap()
        var cx = C.firstConversation("I have a dentist appointment next Tuesday at three.", at: SimClock.at("Sat 04:11", week: 2)!, mind: mind)
        let back = SimClock.at("Wed 01:00", week: 3)!
        C.comeBack(&cx, at: back, mind: mind)
        _ = C.reply(&cx, at: back.addingTimeInterval(7), mind: mind)
        _ = cx.step(.deeTurnFinished(text: ""), mind: mind, at: back.addingTimeInterval(7.2))
        let r2 = C.reply(&cx, at: back.addingTimeInterval(9), mind: mind)
        #expect(r2.contains(C.named), "\(r2)")
        #expect(cx.intentionBoard.staleFinishes == 0)
    }

    // MARK: F5 — time apart in words

    @Test func timeApartIsSaidInWords() {
        #expect(DNATables.apartWords(2 * 3600) == nil)
        #expect(DNATables.apartWords(5 * 3600) == "a few hours")
        #expect(DNATables.apartWords(12 * 3600) == "half a day")
        #expect(DNATables.apartWords(26 * 3600) == "about a day")
        #expect(DNATables.apartWords(50 * 3600) == "a couple of days")             // reunion-morning / -evening
        #expect(DNATables.apartWords(88.9 * 3600) == "a few days")                 // followup-dentist
        #expect(DNATables.apartWords(6 * 86_400) == "nearly a week")               // followup-exam ("it's been 6 days")
        #expect(DNATables.apartWords(9 * 86_400) == "about a week")
        #expect(DNATables.apartWords(14 * 86_400) == "a couple of weeks")
        #expect(DNATables.apartWords(21 * 86_400) == "a few weeks")
        #expect(DNATables.apartWords(45 * 86_400) == "over a month")
        #expect(DNATables.apartWords(90 * 86_400) == "a long while")
        #expect(DNATables.sinceWords(300) == "a few minutes ago")
        #expect(DNATables.sinceWords(6 * 86_400) == "nearly a week ago")
        #expect(DNATables.daysAgoWords(0) == "today" && DNATables.daysAgoWords(1) == "yesterday")
        #expect(DNATables.daysAgoWords(3) == "a few days ago")
        // Never a number of days or hours, in any length of time apart.
        let digits = try! NSRegularExpression(pattern: #"\d"#)
        for h in stride(from: 3.0, through: 24 * 120, by: 1.5) {
            for w in [DNATables.apartWords(h * 3600), DNATables.sinceWords(h * 3600), DNATables.daysAgoWords(Int(h / 24))].compactMap({ $0 }) {
                #expect(digits.firstMatch(in: w, range: NSRange(w.startIndex..., in: w)) == nil, "\(w)")
            }
        }
    }

    /// The live exam replay: "it's been 6 days" (judge: a numbers leak) is now words (6 d 21 h here: "about a week").
    @Test func liveExamReunionSaysItInWords() {
        let mind = Kit.snap()
        var a = Appraisal()
        a.distress = 0.5
        var cx = C.firstConversation("I have a big exam on Friday morning and I'm nervous.", at: SimClock.at("Sat 04:10", week: 2)!, mind: mind, a)
        let back = SimClock.at("Sat 01:00", week: 3)!
        C.comeBack(&cx, at: back, mind: mind)
        let t = back.addingTimeInterval(5)
        _ = C.reply(&cx, at: t, mind: mind)
        let dna = Tune4DNATests.render(cx, at: t, index: 1, heardReplies: 0)
        #expect(dna.contains("that it's been about a week"), "6 days 21 h: \(dna)")
        #expect(!dna.contains("6 days") && !dna.contains("days ago"), "\(dna)")
    }

    // MARK: Session instructions v6

    @Test func sessionInstructionsV6() {
        let v6 = DNASessionInstructions.v6
        // v7 is current since tune 6 (Tune6DNATests); v6 stays pinned as it was.
        #expect(DNASessionInstructions.current != v6 && DeeDNA.version != "v6")
        // F7 dentist: first, even before answering their own question.
        #expect(v6.contains("ask it in your first sentence, before anything else, even before answering their own question"))
        // F7 jokes: laugh first, never explain.
        #expect(v6.contains("laugh first, a real little laugh as your very first word") && v6.contains("never explain the joke"))
        // F7 assistant tails ("check your clock app", "I can't set reminders").
        #expect(v6.contains("Never send them to an app, a clock or a calendar") && v6.contains("never offer to set, save or note anything"))
        // F5: words, not numbers.
        #expect(v6.contains("never as a number of days or hours"))
        // F3: the unfinished-words aim is never voiced.
        #expect(v6.contains("never point it out, quote their words back or ask them to finish"))
        #expect(DNATables.rule(.g14).do == "Answer what you actually heard")
        // Everything v5 pinned is still there.
        for kept in ["The \"Length:\" line is a hard limit", "Tools are silent", "Never invent shared history"] { #expect(v6.contains(kept)) }
    }
}
