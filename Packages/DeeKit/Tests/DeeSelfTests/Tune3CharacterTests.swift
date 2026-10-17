import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// Tune 3 (character): regressions from the tune-2 live run (tune2-live.md §F5), each
/// replaying the harness's percept order (Tools/voice-harness DeeBrainAdapter: arrive =
/// presence then a confirmed identity; every reply senses `.promptSubmitted` and picks
/// its notes; fast mode picks them at the server's commit, before `.heard`; a finished
/// reply is `.deeTurnFinished(text: "")` after one `.deeSaid` per heard sentence).
struct Tune3CharacterTests {
    static let pdt: TimeInterval = -7 * 3600
    static let gentle = "Gently ask how they've been feeling."
    static let named = "Ask how their dentist appointment went."

    /// The live first conversation: one reply in fast mode, then a plan, then they leave.
    static func firstConversation(_ text: String, at t0: Date, mind: MindSnapshot, _ a: Appraisal = Appraisal()) -> Cortex {
        var cx = Cortex(enduring: Kit.enduring(), mind: mind, at: t0, utcOffset: pdt)
        _ = cx.step(.conversationStarted(t0), mind: mind, at: t0)
        _ = cx.step(.identified(Kit.john, distance: 0), mind: mind, at: t0)
        _ = cx.step(.presence(arrived: true), mind: mind, at: t0)
        _ = cx.step(.promptSubmitted, mind: mind, at: t0.addingTimeInterval(7))
        _ = cx.cue(at: t0.addingTimeInterval(7))
        _ = cx.step(Kit.heard(text, a), mind: mind, at: t0.addingTimeInterval(8))
        _ = cx.step(.deeSaid(tag: nil, sentence: "Nice, good luck with it."), mind: mind, at: t0.addingTimeInterval(9))
        _ = cx.step(.deeTurnFinished(text: ""), mind: mind, at: t0.addingTimeInterval(10))
        _ = cx.step(.faceLost, mind: mind, at: t0.addingTimeInterval(17))
        _ = cx.step(.presence(arrived: false), mind: mind, at: t0.addingTimeInterval(17))
        return cx
    }

    /// The harness's `advanceToWeekday` + newConversation + arrive.
    static func comeBack(_ cx: inout Cortex, at back: Date, mind: MindSnapshot) {
        _ = cx.flush(at: back)
        _ = cx.step(.tick, mind: mind, at: back)
        _ = cx.step(.conversationStarted(back), mind: mind, at: back)
        _ = cx.step(.presence(arrived: true), mind: mind, at: back)
        _ = cx.step(.identified(Kit.john, distance: 0), mind: mind, at: back)
    }

    /// A reply's notes as the harness picks them (`.promptSubmitted`, then `cue`).
    static func reply(_ cx: inout Cortex, at t: Date, mind: MindSnapshot) -> String {
        _ = cx.step(.promptSubmitted, mind: mind, at: t)
        return cx.cue(at: t).cue
    }

    // MARK: (1) dentist

    /// t2-followup-dentist, verbatim: said Friday 9 Oct 21:11 PDT; back Tuesday 18:00.
    /// Live: "at three" was not read as a time, so the plan was due at the 17:00 day
    /// default and the follow-up waited until 19:00: no aim in any DNA. Then the server
    /// split "Hi, Dee." / "How was your day?", the brain cancelled reply 1, and reply 2
    /// had lost the reunion note too (reply 1 had consumed both).
    @Test func liveDentistAtThreeIsAskedThatEvening() throws {
        let mind = Kit.snap()
        let t0 = SimClock.at("Sat 04:11", week: 2)!                       // Fri 9 Oct 21:11 PDT
        var cx = Self.firstConversation("I have a dentist appointment next Tuesday at three.", at: t0, mind: mind)
        let x = try #require(cx.moment.ongoing.expectations.first)
        #expect(x.subject.text == "dentist appointment")
        #expect(x.due == SimClock.at("Tue 22:00", week: 3), "Tuesday 13 Oct 15:00 PDT")
        let f = try #require(cx.moment.ongoing.intentions.first { $0.kind == .followUp })
        #expect(f.notBefore == SimClock.at("Wed 00:00", week: 3), "17:00 PDT, two hours after")
        #expect(f.expires == x.expires && f.priority == IntentionBoard.followUpPriority)

        let back = SimClock.at("Wed 01:00", week: 3)!                     // Tue 18:00 PDT
        Self.comeBack(&cx, at: back, mind: mind)
        // Reply 1 (fast: notes picked at the commit, before their words).
        let r1 = Self.reply(&cx, at: back.addingTimeInterval(7.7), mind: mind)
        // Tune 4 decision (a): an ordinary appointment is asked by name.
        #expect(r1.contains(Self.named), "\(r1)")
        #expect(!r1.contains(Self.gentle), "\(r1)")
        #expect(r1.contains("They're back"), "\(r1)")
        #expect(cx.stance.notes.contains { $0.role == .aim && $0.kind == .followUp }, "the reply's aim (Do now)")
        // The brain cancels it: nothing of it is heard.
        _ = cx.step(.deeTurnFinished(text: ""), mind: mind, at: back.addingTimeInterval(7.8))
        _ = cx.step(Kit.heard("Hi, Dee."), mind: mind, at: back.addingTimeInterval(8.1))
        // Reply 2 still carries both.
        let r2 = Self.reply(&cx, at: back.addingTimeInterval(9.2), mind: mind)
        #expect(r2.contains(Self.named), "\(r2)")
        #expect(r2.contains("They're back"), "\(r2)")
        // Dee asks; the next turn is the outcome.
        _ = cx.step(.deeSaid(tag: nil, sentence: "Hi Alex! How did the dentist go?"), mind: mind, at: back.addingTimeInterval(10))
        _ = cx.step(.deeTurnFinished(text: ""), mind: mind, at: back.addingTimeInterval(10.5))
        #expect(cx.moment.ongoing.expectations.first?.status == .asked)
        #expect(cx.intentionBoard.awaitingOutcome == x.id)
        // Spent: the next reply carries neither.
        _ = cx.step(Kit.heard("Not bad, no cavities."), mind: mind, at: back.addingTimeInterval(14))
        let r3 = Self.reply(&cx, at: back.addingTimeInterval(14.5), mind: mind)
        #expect(!r3.contains(Self.named) && !r3.contains(Self.gentle) && !r3.contains("They're back"), "\(r3)")
    }

    /// Conservative: before the follow-up time (15:00 + 2 h) there is no aim, only the
    /// reunion; a stray "at three" is not a plan.
    @Test func noDentistAimBeforeItIsDueAndNoFalsePlans() {
        let mind = Kit.snap()
        var cx = Self.firstConversation("I have a dentist appointment next Tuesday at three.", at: SimClock.at("Sat 04:11", week: 2)!, mind: mind)
        let early = SimClock.at("Tue 23:30", week: 3)!                    // Tue 16:30 PDT
        Self.comeBack(&cx, at: early, mind: mind)
        let r = Self.reply(&cx, at: early.addingTimeInterval(7), mind: mind)
        #expect(!r.contains("Gently ask") && !r.contains("Ask how"), "\(r)")
        #expect(r.contains("They're back"))

        for line in ["We got there at three and left at five.", "I was at one point thinking of it.", "At three of them I laughed.",
                     "I have three cats.", "Three of my friends are coming."] {
            let c = Self.firstConversation(line, at: SimClock.at("Sat 04:11", week: 2)!, mind: mind)
            #expect(c.moment.ongoing.expectations.isEmpty, "\(line)")
        }
    }

    @Test func spokenClockTimes() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = SimClock.at("Mon 09:00")!
        func due(_ s: String) -> Date? { Interpreter.PlanDetector.detect(s, appraisal: Appraisal(), now: now, calendar: cal)?.due }
        #expect(due("I have a dentist appointment next Tuesday at three.") == SimClock.at("Tue 15:00"))
        #expect(due("my interview is on thursday at ten") == SimClock.at("Thu 10:00"))
        #expect(due("my interview is thursday at three thirty") == SimClock.at("Thu 15:30"))
        #expect(due("my exam is friday at nine am") == SimClock.at("Fri 09:00"))
        #expect(due("my meeting is wednesday at eleven o'clock") == SimClock.at("Wed 11:00"))
        #expect(due("my meeting is wednesday at half past two") == SimClock.at("Wed 14:30"))
        #expect(due("my meeting is wednesday at 3") == SimClock.at("Wed 15:00"), "digits unchanged")
        #expect(due("my interview is on thursday") == SimClock.at("Thu 17:00"), "a day alone keeps the 17:00 default")
    }

    // MARK: (2) exam: the aim rides on the first (fast) reply

    /// t2-followup-exam: live the fast reply's notes were picked before "Hi Dee. How was
    /// your day?" arrived, when no turn had been heard, so the follow-up was only a weak
    /// "On your mind" line and there was no later cue. It is now the reply's aim.
    @Test func liveExamFollowUpIsTheFirstFastReplysAim() throws {
        let mind = Kit.snap()
        var a = Appraisal()
        a.distress = 0.5
        let t0 = SimClock.at("Sat 04:10", week: 2)!                       // Fri 9 Oct 21:10 PDT
        var cx = Self.firstConversation("I have a big exam on Friday morning and I'm nervous.", at: t0, mind: mind, a)
        let back = SimClock.at("Sat 01:00", week: 3)!                     // Fri 16 Oct 18:00 PDT
        Self.comeBack(&cx, at: back, mind: mind)
        let r1 = Self.reply(&cx, at: back.addingTimeInterval(5), mind: mind)
        #expect(r1.contains("Ask how their exam went. They were nervous about it."), "\(r1)")
        #expect(r1.contains("They're back"))
        let aim = try #require(cx.stance.notes.first { $0.role == .aim })
        #expect(aim.kind == .followUp, "the reply's aim (Do now)")
        _ = cx.step(Kit.heard("Hi Dee. How was your day?"), mind: mind, at: back.addingTimeInterval(5.6))
        _ = cx.step(.deeSaid(tag: nil, sentence: "Lovely! How did your exam go?"), mind: mind, at: back.addingTimeInterval(6.5))
        _ = cx.step(.deeTurnFinished(text: ""), mind: mind, at: back.addingTimeInterval(7))
        #expect(cx.moment.ongoing.expectations.first?.status == .asked, "follow-through reads Dee's heard sentences")
    }

    /// The pre-raised aim never outlives the reply it was raised for: a `.promptSubmitted`
    /// with no cue (a Cortex initiative's DNA) leaves nothing behind for Dee's initiative.
    @Test func aPreRaisedFollowUpIsWithdrawnWithoutACue() {
        let mind = Kit.snap()
        var a = Appraisal()
        a.distress = 0.5
        var cx = Self.firstConversation("I have a big exam on Friday morning and I'm nervous.", at: SimClock.at("Sat 04:10", week: 2)!, mind: mind, a)
        let back = SimClock.at("Sat 01:00", week: 3)!
        Self.comeBack(&cx, at: back, mind: mind)
        _ = cx.step(.promptSubmitted, mind: mind, at: back.addingTimeInterval(2))
        #expect(cx.moment.ongoing.noteCandidates.contains { $0.kind == .followUp })
        _ = cx.step(.tick, mind: mind, at: back.addingTimeInterval(2.5))
        #expect(!cx.moment.ongoing.noteCandidates.contains { $0.kind == .followUp })
        #expect(cx.moment.ongoing.intentions.first { $0.kind == .followUp }?.status == .open)
    }

    /// A stranger (no identity) gets no follow-up on a reply.
    @Test func noFollowUpForSomeoneElse() {
        let mind = Kit.snap()
        var a = Appraisal()
        a.distress = 0.5
        var cx = Self.firstConversation("I have a big exam on Friday morning and I'm nervous.", at: SimClock.at("Sat 04:10", week: 2)!, mind: mind, a)
        let back = SimClock.at("Sat 01:00", week: 3)!
        _ = cx.flush(at: back)
        _ = cx.step(.conversationStarted(back), mind: mind, at: back)
        _ = cx.step(.presence(arrived: true), mind: mind, at: back)
        _ = cx.step(.identified(Kit.ann, distance: 0), mind: mind, at: back)
        let r = Self.reply(&cx, at: back.addingTimeInterval(5), mind: mind)
        #expect(!r.contains("exam"), "\(r)")
    }

    // MARK: (3) reunion: last contact before this conversation

    /// t2-reunion-*: 50 h apart. The DNA said "last talked just now" because it used the
    /// current turn. The Cortex keeps the contact from before this conversation, and it
    /// does not move while they talk.
    @Test func lastContactBeforeThisConversationAfterFiftyHours() {
        let mind = Kit.snap()
        let t0 = Kit.t0
        var cx = Cortex(enduring: Kit.enduring(), mind: mind, at: t0)
        _ = cx.step(.conversationStarted(t0), mind: mind, at: t0)
        _ = cx.step(.identified(Kit.john, distance: 0), mind: mind, at: t0)
        _ = cx.step(.presence(arrived: true), mind: mind, at: t0)
        #expect(cx.lastContactBeforeConversation() == nil, "a first meeting has none")
        _ = cx.step(Kit.heard("What's your favorite color?"), mind: mind, at: t0.addingTimeInterval(5))
        _ = cx.step(.deeTurnFinished(text: "Blue!"), mind: mind, at: t0.addingTimeInterval(9))
        let left = t0.addingTimeInterval(20)
        _ = cx.step(.faceLost, mind: mind, at: left)
        _ = cx.step(.presence(arrived: false), mind: mind, at: left)
        let back = left.addingTimeInterval(50 * 3600)
        Self.comeBack(&cx, at: back, mind: mind)
        #expect(cx.lastContactBeforeConversation() == left)
        _ = cx.step(Kit.heard("Good morning! Did you sleep well?"), mind: mind, at: back.addingTimeInterval(6))
        #expect(cx.lastContactBeforeConversation() == left, "not refreshed by this conversation")
        #expect(cx.lastContactBeforeConversation(Kit.john) == left)
        #expect(cx.lastContactBeforeConversation(Kit.ann) == nil)
    }

    /// After a relaunch the stored contact is the answer (`Carried.lastContact`), and a
    /// forgotten person's contact is gone.
    @Test func lastContactFromTheStoreAndForgetting() {
        let mind = Kit.snap()
        let before = Kit.t0.addingTimeInterval(-3 * 86_400)
        var cx = Cortex(enduring: Kit.enduring(), mind: mind, at: Kit.t0, carried: Carried(lastContact: [Kit.john: before]))
        _ = cx.step(.conversationStarted(Kit.t0), mind: mind, at: Kit.t0)
        _ = cx.step(.identified(Kit.john, distance: 0), mind: mind, at: Kit.t0)
        #expect(cx.lastContactBeforeConversation() == before)
        cx.forgetPerson(Kit.john)
        #expect(cx.lastContactBeforeConversation(Kit.john) == nil)
    }

    /// A reply Dee actually said spends the reunion note (no "they're back" on turn 2).
    @Test func aDeliveredReplySpendsTheReunion() {
        let mind = Kit.snap()
        var cx = Self.firstConversation("What's your favorite color?", at: Kit.t0, mind: mind)
        let back = Kit.t0.addingTimeInterval(50 * 3600)
        Self.comeBack(&cx, at: back, mind: mind)
        let r1 = Self.reply(&cx, at: back.addingTimeInterval(5), mind: mind)
        #expect(r1.contains("They're back"))
        _ = cx.step(Kit.heard("Hi Dee."), mind: mind, at: back.addingTimeInterval(5.5))
        _ = cx.step(.deeSaid(tag: nil, sentence: "Hi! I missed you."), mind: mind, at: back.addingTimeInterval(6))
        _ = cx.step(.deeTurnFinished(text: ""), mind: mind, at: back.addingTimeInterval(7))
        _ = cx.step(Kit.heard("What's new?"), mind: mind, at: back.addingTimeInterval(9))
        let r2 = Self.reply(&cx, at: back.addingTimeInterval(9.5), mind: mind)
        #expect(!r2.contains("They're back"), "\(r2)")
    }
}
