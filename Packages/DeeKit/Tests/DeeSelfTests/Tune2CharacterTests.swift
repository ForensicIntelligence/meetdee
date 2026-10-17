import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// Tune 2 (character): regressions from the tune-1 live run (tune1-live.md §F-DNA, §F-MEM),
/// each replaying the live trace's percept order (Tools/voice-harness DeeBrainAdapter).
struct Tune2CharacterTests {
    static let hour: TimeInterval = 3600

    /// dna-reunion: a turn, leave (faceLost, presence false), +50 h (flush, tick),
    /// newConversation, arrive (presence true, identified). The first reply's notes are
    /// picked before its words arrive (fast mode), so the reunion must already be there.
    ///
    /// Live the note never fired because the harness identified Alex with
    /// `.identified(id, distance: 0.6)` once: one face sighting is not an identity
    /// (Interpreter needs 3, or distance 0 = confirmed, which is what DeeModel sends), so
    /// the Cortex had no person all scenario. With the app's confirmed identity it fires.
    @Test func liveReunionAfterFiftyHours() {
        let mind = Kit.snap([.loneliness: 0.1])
        let t0 = Kit.t0
        var cx = Cortex(enduring: Kit.enduring(), mind: mind, at: t0)
        _ = cx.step(.conversationStarted(t0), mind: mind, at: t0)
        _ = cx.step(.identified(Kit.john, distance: 0), mind: mind, at: t0)
        _ = cx.step(.presence(arrived: true), mind: mind, at: t0)
        _ = cx.step(.promptSubmitted, mind: mind, at: t0.addingTimeInterval(5))
        _ = cx.cue(at: t0.addingTimeInterval(5))
        _ = cx.step(Kit.heard("What's your favorite color?"), mind: mind, at: t0.addingTimeInterval(5))
        _ = cx.step(.deeTurnFinished(text: "Blue!"), mind: mind, at: t0.addingTimeInterval(9))
        _ = cx.step(.faceLost, mind: mind, at: t0.addingTimeInterval(20))
        _ = cx.step(.presence(arrived: false), mind: mind, at: t0.addingTimeInterval(20))
        let back = t0.addingTimeInterval(20 + 50 * Self.hour)
        let lonely = Kit.snap([.loneliness: 0.88])
        _ = cx.flush(at: back)
        _ = cx.step(.tick, mind: lonely, at: back)
        _ = cx.step(.conversationStarted(back), mind: lonely, at: back)
        _ = cx.step(.presence(arrived: true), mind: lonely, at: back)
        _ = cx.step(.identified(Kit.john, distance: 0), mind: lonely, at: back)
        #expect(cx.moment.ongoing.reunionTurn)
        #expect(cx.moment.ongoing.noteCandidates.contains { $0.kind == .reunion })
        _ = cx.step(.promptSubmitted, mind: lonely, at: back.addingTimeInterval(4))
        let (cue, _) = cx.cue(at: back.addingTimeInterval(4))
        #expect(cue.contains("They're back"), "\(cue)")
        #expect(!cue.lowercased().contains("lonely"))
    }

    /// Back after 50 h and Dee sees them (face, mutual gaze, nobody speaks): Dee's own
    /// greeting initiative carries the reunion ("be glad"), never "lonely".
    @Test func reunionGreetingInitiativeWhenSheSeesThem() {
        let lonely = Kit.snap([.loneliness: 0.88, .joy: 0.5])
        let t0 = Kit.t0
        var cx = Cortex(enduring: Kit.enduring(), mind: lonely, at: t0,
                        carried: Carried(lastContact: [Kit.john: t0.addingTimeInterval(-50 * Self.hour)]))
        _ = cx.step(.conversationStarted(t0), mind: lonely, at: t0)
        _ = cx.step(.presence(arrived: true), mind: lonely, at: t0)
        _ = cx.step(.identified(Kit.john, distance: 0), mind: lonely, at: t0)
        var cue: String?
        var t = 0.5
        while t <= 20, cue == nil {
            _ = cx.step(.head(yaw: 0, pitch: 0), mind: lonely, at: t0.addingTimeInterval(t))
            for e in cx.step(.tick, mind: lonely, at: t0.addingTimeInterval(t)) {
                if case .initiative(let c) = e { cue = c }
            }
            t += 0.5
        }
        let c = try? #require(cue, "Dee greets them first")
        #expect(c?.contains("They're back") == true, "\(c ?? "-")")
        #expect(c?.lowercased().contains("lonely") == false)
    }

    /// The harness's single unconfirmed sighting is not an identity (documents the live
    /// cause; the harness must send distance 0 like DeeModel).
    @Test func oneUnconfirmedSightingIsNotAnIdentity() {
        var cx = Cortex(enduring: Kit.enduring(), mind: Kit.snap(), at: Kit.t0)
        _ = cx.step(.identified(Kit.john, distance: 0.6), mind: Kit.snap(), at: Kit.t0)
        #expect(cx.moment.ongoing.person == nil)
        _ = cx.step(.identified(Kit.john, distance: 0), mind: Kit.snap(), at: Kit.t0)
        #expect(cx.moment.ongoing.person == Kit.john)
    }

    /// dna-plan-followup: "big exam on Friday morning" said on a Friday afternoon (so next
    /// Friday), back that Friday at 18:00 local in a new conversation. Live the plan was
    /// due at the 17:00 day default ("morning" after a weekday was ignored), so the
    /// follow-up waited until 19:00 on the exam day.
    @Test func liveExamFollowUpOnTheDay() throws {
        let offset: TimeInterval = -7 * 3600                // PDT, as the live run
        let mind = Kit.snap()
        let t0 = SimClock.at("Fri 23:36")!                 // Friday 16:36 local
        var cx = Cortex(enduring: Kit.enduring(), mind: mind, at: t0, utcOffset: offset)
        _ = cx.step(.conversationStarted(t0), mind: mind, at: t0)
        _ = cx.step(.identified(Kit.john, distance: 0), mind: mind, at: t0)
        _ = cx.step(.presence(arrived: true), mind: mind, at: t0)
        _ = cx.step(.promptSubmitted, mind: mind, at: t0.addingTimeInterval(7))
        _ = cx.cue(at: t0.addingTimeInterval(7))
        var a = Appraisal()
        a.distress = 0.5
        _ = cx.step(Kit.heard("I have a big exam on Friday morning and I'm nervous.", a), mind: mind, at: t0.addingTimeInterval(7))
        let exam = try #require(cx.moment.ongoing.expectations.first)
        #expect(exam.due == SimClock.at("Fri 16:00", week: 1), "Friday 09:00 local, a week later")
        _ = cx.step(.deeTurnFinished(text: "Oh, ouch."), mind: mind, at: t0.addingTimeInterval(12))
        _ = cx.step(.faceLost, mind: mind, at: t0.addingTimeInterval(20))
        _ = cx.step(.presence(arrived: false), mind: mind, at: t0.addingTimeInterval(20))
        let back = SimClock.at("Sat 01:00", week: 1)!       // Friday 18:00 local, the exam day
        _ = cx.flush(at: back)
        _ = cx.step(.tick, mind: mind, at: back)
        _ = cx.step(.conversationStarted(back), mind: mind, at: back)
        _ = cx.step(.presence(arrived: true), mind: mind, at: back)
        _ = cx.step(.identified(Kit.john, distance: 0), mind: mind, at: back)
        _ = cx.step(.promptSubmitted, mind: mind, at: back.addingTimeInterval(4))
        let (first, _) = cx.cue(at: back.addingTimeInterval(4))
        #expect(first.contains("They're back"), "a week apart: reunion on the first reply")
        // Tune 3: the follow-up now rides on that first (fast) reply too, with the
        // reunion (Tune3CharacterTests.liveExamFollowUpIsTheFirstFastReplysAim).
        #expect(first.contains("Ask how their exam went. They were nervous about it."), "\(first)")
    }

    @Test func partOfDayAfterAWeekdayOrInThe() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = SimClock.at("Mon 18:00")!
        func due(_ s: String) -> Date? { Interpreter.PlanDetector.detect(s, appraisal: Appraisal(), now: now, calendar: cal)?.due }
        #expect(due("I have a big exam on Friday morning") == SimClock.at("Fri 09:00"))
        #expect(due("my interview is thursday afternoon") == SimClock.at("Thu 15:00"))
        #expect(due("we have a concert friday night") == SimClock.at("Fri 20:00"))
        #expect(due("I have an exam in the morning") == SimClock.at("Tue 09:00"), "said in the evening: the next morning")
        #expect(due("my interview is on thursday") == SimClock.at("Thu 17:00"), "a day alone keeps the 17:00 default")
        #expect(due("I have my driving test tomorrow morning") == SimClock.at("Tue 09:00"))
    }

    /// The live long-clean lines through the real appraiser: no cause label of rudeness,
    /// brush-off or shouting (CauseLabel feeds "Feelings … from being brushed off").
    @Test func liveStopLinesCarryNoHostileCause() {
        var ap = Appraiser()
        let normal = Prosody(loudnessDB: -24, peakDB: -14, speechRate: 2.8, pitchVariability: 4)
        let loud = Prosody(loudnessDB: -17, peakDB: -6, speechRate: 3.0, pitchVariability: 4)
        let first = ap.appraise("So I've been thinking about getting a dog, but my apartment is pretty small. And I work long hours, so I'm not sure it would be fair to the dog. What do you think I should do?", prosody: normal)
        #expect(![CauseLabel.rudeness, .shoutedAt, .brushedOff].contains(CauseLabel.classify(first)))
        for (text, p) in [("Wait, stop talking for a second.", normal), ("Stop.", loud), ("Be quiet for a sec.", normal),
                          ("Hold on, hold on.", loud)] {
            let a = ap.appraise(text, prosody: p)
            let label = CauseLabel.classify(a)
            #expect(![CauseLabel.rudeness, .shoutedAt, .brushedOff].contains(label), "\(text) → \(label?.rawValue ?? "-")")
            #expect(a.kindness > -0.25, "\(text) would count as a hostile interaction")
        }
        #expect(CauseLabel.classify(ap.appraise("Shut up, you stupid robot.")) == .rudeness, "real rudeness still counts")
    }
}
