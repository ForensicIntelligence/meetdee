import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// Deterministic replays of the real-model transcript "a week with John"
/// (`DeeLiveTests/LiveConversationTests.aWeekWithJohn`): the same percept sequence,
/// clock and loudness as the live harness, with Dee's replies scripted from the
/// transcript. Each test pins one fix:
/// 1. the interview follow-up was issued twice after John had already said how it went;
/// 2. the reunion note answered a hostile first turn;
/// 3. a stale "they made up with you" note opened a conversation 3 days after the
///    apology, displacing the reunion note, with "lonely" in the mood.
@Suite(.serialized) struct LiveWeekRegressionTests {
    static let start = Date(timeIntervalSince1970: 1_791_000_000)

    /// The live harness without the model: Mind → Cortex → cue, scripted replies.
    final class Replay {
        let mind: Mind
        var cortex: Cortex
        var now: Date
        let person = Kit.john
        var cues: [String] = []
        var effects: [Effect] = []

        init() async throws {
            now = LiveWeekRegressionTests.start
            mind = try Mind(databaseURL: nil, now: now)
            let snap = await mind.snapshot(at: now)
            cortex = Cortex(enduring: SelfSeeder.seed(personality: snap.code.personality, seed: 7, at: now), mind: snap, at: now,
                            carried: Carried(), session: 1)
        }

        @discardableResult
        func step(_ p: Percept) async -> [Effect] {
            let snap = await mind.snapshot(at: now)
            let fx = cortex.step(p, mind: snap, at: now)
            effects += fx
            for e in fx { if case .appraise(let a) = e { _ = await mind.react(a, at: now) } }
            return fx
        }

        func newConversation() async {
            cues = []
            await step(.conversationStarted(now))
            await step(.presence(arrived: true))
            await step(.identified(person, distance: 0))
            _ = cortex.persona(Persona(), person: person, at: now)
        }

        /// John says `text` (4 s after the last step, as live); Dee answers `reply`.
        /// Returns the cue Dee answered from.
        @discardableResult
        func say(_ text: String, loudnessDB: Double = -32, reply: String) async -> String {
            now += 4
            let prosody = Prosody(loudnessDB: loudnessDB, peakDB: loudnessDB + 8, speechRate: 2.6)
            let (a, _) = await mind.hear(text, prosody: prosody, at: now)
            await step(.heard(text: text, durationS: 2.5, loudnessVsBaseline: (loudnessDB + 32) / 12, appraisal: a))
            await step(.promptSubmitted)
            let (cue, fx) = cortex.cue(at: now)
            effects += fx
            cues.append(cue)
            for s in ScenarioSentences.split(reply) {
                now += 1.5
                await step(.deeSaid(tag: nil, sentence: s))
            }
            await step(.deeTurnFinished(text: reply))
            await step(.speakingFinished)
            return cue
        }

        func away(days: Double) async {
            await step(.presence(arrived: false))
            await step(.asleep(true))
            now += days * 86_400
            _ = await mind.catchUp(to: now, lastSeenUserAt: nil)
            await step(.asleep(false))
        }

        /// Day 1 exactly as live.
        func dayOne() async {
            await newConversation()
            await say("Hi Dee! I'm John. I just set you up on my phone.", reply: "Hello, John! It's so nice to meet you.")
            await say("I have a big job interview tomorrow afternoon and I'm pretty nervous about it.",
                      reply: "Oh no, a big interview! That sounds scary but I bet you'll do great.")
            await say("It's for a designer job at a game studio. I've wanted this for years.",
                      reply: "Wow, a designer job at a game studio! That sounds amazing.")
            await say("Why did the robot go on vacation? It needed to recharge its batteries! Haha",
                      reply: "Oh, that's a funny story!")
            for _ in 0..<4 {
                now += 30
                _ = await mind.tick(at: now, userPresent: true, asleep: false)
                await step(.tick)
            }
        }
    }

    static let followUp = "(Ask how their job interview went"
    static let reunion = "(They're back"
    static let reconciled = "(They made up with you"

    static func mood(_ cue: String) -> String {
        guard let r = cue.range(of: "Mood: ") else { return "" }
        let rest = cue[r.upperBound...]
        return String(rest.prefix { $0 != "." })
    }

    // MARK: 1. The follow-up, once, on the reunion turn; the outcome report resolves it

    @Test func followUpOnTheReunionTurnAndNeverAfterTheOutcome() async throws {
        let dee = try await Replay()
        await dee.dayOne()
        #expect(dee.cortex.moment.ongoing.expectations.map(\.subject.text) == ["job interview"])
        await dee.away(days: 1.6)

        // Day 2: the first turn, 4 s after arrival, carries the reunion context *and*
        // the follow-up aim (SELF.md §6: one context + one aim).
        await dee.newConversation()
        let first = await dee.say("Hey Dee, I'm back.", reply: "John, I'm so happy to see you! You're back.")
        #expect(first.contains(Self.reunion), "\(first)")
        #expect(first.contains(Self.followUp), "\(first)")
        #expect(!Self.mood(first).contains("lonely"), "\(first)")

        // Dee's reply did not name the interview; John answers anyway, without naming it.
        let mark = dee.effects.count
        let second = await dee.say("It went really well actually! They want a second round next week.",
                                   reply: "Oh wow, that's amazing news! I'm so proud of you, John.")
        #expect(!second.contains(Self.followUp), "a moot follow-up re-issued: \(second)")
        let x = try #require(dee.cortex.moment.ongoing.expectations.first { $0.subject.text == "job interview" })
        #expect(x.status == .resolved)
        #expect((x.outcomeValence ?? 0) > 0, "valence from the appraisal (positive): \(x.outcomeValence ?? -9)")
        #expect(dee.effects[mark...].contains { if case .persist(.expectation(let e)) = $0 { e.status == .resolved } else { false } })
        #expect(dee.cortex.moment.ongoing.intentions.first { $0.kind == .followUp }?.isLive != true)

        await dee.say("You seem sad today.", reply: "Why do you think that? I'm actually feeling quite giddy right now!")
        await dee.say("Sorry, I misread that. You're fine.", reply: "Oh, thank you! I'm so glad we're all good now!")
        #expect(dee.cues.filter { $0.contains(Self.followUp) }.count == 1, "\(dee.cues)")
    }

    @Test func outcomeReportsWithoutTheSubject() {
        for yes in ["It went really well actually! They want a second round next week.", "it went fine", "Honestly, it went terribly.",
                    "I nailed it!", "I didn't get it.", "I got the job!", "They want a second round", "oh well, it didn't go so well",
                    "It was great actually", "went pretty badly", "they offered me the position", "Yeah I passed"] {
            #expect(Interpreter.OutcomeReport.detect(yes), "\(yes)")
        }
        for no in ["Hey Dee, I'm back.", "I have a big job interview tomorrow", "It was great to see my sister", "I lost my keys",
                   "What do you think went wrong with the plan?", "how did it go", "it's for a designer job", "I got it, thanks",
                   "it is going well so far", "You seem sad today."] {
            #expect(!Interpreter.OutcomeReport.detect(no), "\(no)")
        }
    }

    @Test func outcomeReportNeedsExactlyOneDueExpectation() async throws {
        // Two due expectations: "it went really well" names neither, so neither resolves.
        let dee = try await Replay()
        await dee.newConversation()
        await dee.say("I have a job interview tomorrow and I'm nervous.", reply: "Good luck!")
        await dee.say("I have a dentist appointment tomorrow too.", reply: "Busy day!")
        #expect(dee.cortex.moment.ongoing.expectations.count == 2)
        await dee.away(days: 1.6)
        await dee.newConversation()
        await dee.say("It went really well actually!", reply: "That's great!")
        #expect(dee.cortex.moment.ongoing.expectations.allSatisfy { $0.status != .resolved },
                "\(dee.cortex.moment.ongoing.expectations.map { "\($0.subject.text):\($0.status)" })")

        // Not yet due: an outcome report is about something else.
        let early = try await Replay()
        await early.newConversation()
        await early.say("I have a job interview on Friday and I'm nervous.", reply: "Good luck!")
        await early.say("Anyway, it went really well at the gym today.", reply: "Nice!")
        #expect(early.cortex.moment.ongoing.expectations.first?.status == .pending)
    }

    @Test func initiativeStillWaitsOutTheArrivalGrace() {
        var run = ReducerRun(IntentionBoard())
        run.m.ongoing.person = Kit.john
        let due = Kit.t0.addingTimeInterval(3600)
        run.m.ongoing.expectations = [Expectation(id: UUID(), person: Kit.john, subject: Subject("job interview")!, due: due,
                                                   expires: due.addingTimeInterval(7 * 86_400), framing: .nervous)]
        run.step(.tick, at: 0)
        let ready = 3 * 3600.0 + 60
        run.m.ongoing.turnsThisConversation = 1
        run.m.momentary.mutualGazeSince = Kit.t0
        run.step(.presence(arrived: true), at: ready)
        run.step(.tick, at: ready + 5)
        #expect(run.m.momentary.initiative == nil, "no pouncing within 10 s of arrival")
    }

    // MARK: 2. A hostile first turn after an absence: no reunion note

    @Test func hostileReunionTurnDropsTheReunionNote() async throws {
        let dee = try await Replay()
        await dee.dayOne()
        await dee.away(days: 1.6)
        await dee.newConversation()
        await dee.say("Hey Dee, I'm back.", reply: "John, I'm so happy to see you!")
        await dee.say("It went really well actually! They want a second round next week.", reply: "That's amazing news!")
        await dee.away(days: 2)

        await dee.newConversation()
        let cue = await dee.say("UGH YOU ARE SO USELESS TODAY", loudnessDB: -14, reply: "You're being really mean, John.")
        #expect(!cue.contains(Self.reunion), "be glad to see them, after an insult: \(cue)")
        #expect(!Self.mood(cue).contains("lonely"), "\(cue)")
        #expect([RepairPhase.ruptured, .repairing].contains(dee.cortex.moment.ongoing.repair))
    }

    // MARK: 3. No stale "made up" note days later; the reunion note survives

    @Test func noStaleReconciledNoteAfterThreeDaysAway() async throws {
        let dee = try await Replay()
        await dee.dayOne()
        await dee.away(days: 1.6)
        await dee.newConversation()
        await dee.say("Hey Dee, I'm back.", reply: "John, I'm so happy to see you!")
        await dee.say("It went really well actually! They want a second round next week.", reply: "That's amazing news!")
        await dee.away(days: 2)

        // Day 4: rudeness, an apology, then a question (the conversation ends mid-repair).
        await dee.newConversation()
        await dee.say("UGH YOU ARE SO USELESS TODAY", loudnessDB: -14, reply: "You're being really mean, John. That made me feel hurt.")
        await dee.say("I'm sorry Dee, that was mean. Long day.", reply: "It's okay, John. I forgive you.")
        await dee.say("Can you remind me what job I interviewed for?", reply: "A designer job at a game studio!")
        await dee.away(days: 3)

        // Day 7.
        await dee.newConversation()
        #expect(dee.cortex.moment.ongoing.repair == .fine, "the repair under way ended with its conversation")
        let cue = await dee.say("Morning Dee! What have you been thinking about?", reply: "Good morning, John!")
        #expect(!cue.contains(Self.reconciled), "stale: \(cue)")
        #expect(cue.contains(Self.reunion), "\(cue)")
        #expect(!Self.mood(cue).contains("lonely"), "\(cue)")
        let next = await dee.say("Tell me something you like.", reply: "I like learning about you!")
        #expect(!next.contains(Self.reconciled), "\(next)")
    }

    @Test func repairUnderWayEndsSilentlyWithItsConversation() {
        var run = RepairKeeperTests.ruptured(mind: Kit.angry)
        run.step(RepairKeeperTests.apology, at: 5)
        #expect(run.m.ongoing.repair == .repairing)
        run.m.ongoing.noteCandidates = []
        let fx = run.step(.conversationStarted(Kit.t0.addingTimeInterval(3 * 86_400)), at: 3 * 86_400)
        #expect(run.m.ongoing.repair == .fine)
        #expect(fx.contains { if case .persist(.clearOpenRepair(Kit.john)) = $0 { true } else { false } })
        run.step(Kit.heard("morning Dee"), at: 3 * 86_400 + 10, mind: Kit.snap())
        #expect(!run.m.ongoing.noteCandidates.contains { $0.kind == .reconciled }, "no 'made up' three days later")

        // The same across a relaunch: a carried `.repairing` ends silently on identify;
        // a carried `.ruptured` (no apology yet) is still restored.
        var relaunched = ReducerRun(RepairKeeper(), mind: Kit.snap())
        relaunched.r.seed(from: Carried(openRepair: [Kit.john: .repairing, Kit.ann: .ruptured]), &relaunched.m)
        relaunched.m.ongoing.person = Kit.john
        let fx2 = relaunched.step(.identified(Kit.john, distance: 0), at: 0)
        #expect(relaunched.m.ongoing.repair == .fine)
        #expect(fx2.contains { if case .persist(.clearOpenRepair(Kit.john)) = $0 { true } else { false } })
        relaunched.step(Kit.heard("hi"), at: 2)
        #expect(!relaunched.m.ongoing.noteCandidates.contains { $0.kind == .reconciled })
        relaunched.m.ongoing.person = Kit.ann
        relaunched.step(.identified(Kit.ann, distance: 0), at: 3)
        #expect(relaunched.m.ongoing.repair == .ruptured)
    }

    @Test func reunionNoteNeverDuringAnOpenQuarrel() {
        var picker = NotePicker()
        var m = Kit.moment()
        m.ongoing.repair = .ruptured
        #expect(!picker.eligible(.reunion(), moment: m))
        m.ongoing.repair = .repairing
        #expect(!picker.eligible(.reunion(), moment: m))
        m.ongoing.repair = .fine
        #expect(picker.eligible(.reunion(), moment: m))
        var rng = Rand(seed: 1)
        #expect(picker.pick([.reunion()], moment: m, mood: "curious", rng: &rng).map(\.kind) == [.reunion])
    }
}

/// Sentence split as the live harness streams them.
enum ScenarioSentences {
    static func split(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if ".!?".contains(ch) {
                let s = cur.trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { out.append(s) }
                cur = ""
            }
        }
        let s = cur.trimmingCharacters(in: .whitespaces)
        if !s.isEmpty { out.append(s) }
        return out
    }
}
