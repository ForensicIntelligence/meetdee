import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// Regressions for the adversarial review of the eight reducers (report B, 2026-10-09).
/// Each test names its finding; the behaviour it pins is described in the reducer's
/// header (Sources/DeeSelf/Reducers/*).
@Suite struct ReviewFixTests {
    static let day: TimeInterval = 86_400
    static func s(_ t: String) -> Subject { Subject(t)! }
    static func ap(_ f: (inout Appraisal) -> Void) -> Appraisal {
        var a = Appraisal()
        f(&a)
        return a
    }
    static func taste(_ subject: String, polarity: Double = 0.7) -> Facet {
        Facet(id: UUID(), kind: .taste, subject: s(subject), innate: polarity, learned: polarity, polarity: polarity, evidence: 3,
              crystallised: true, source: .heuristic, updatedAt: Kit.t0)
    }
    static func at(_ t: Double) -> Date { Kit.t0.addingTimeInterval(t) }

    // MARK: 1 / 21. Tastes and self-motivated aims stay off sensitive subjects

    @Test func tasteableSubjects() {
        #expect(Learner.tasteable(Self.s("cat"), sensed: false), "an animal topic")
        #expect(Learner.tasteable(Self.s("rain"), sensed: false))
        #expect(!Learner.tasteable(Self.s("job"), sensed: false), "a topic outside the taste categories")
        #expect(Learner.tasteable(Self.s("lamp"), sensed: true), "something she saw")
        for w in ["sister", "funeral", "boss", "ex", "chemo", "sarah", "mum's surgery", "grandma"] {
            #expect(!Learner.tasteable(Self.s(w), sensed: false), "\(w)")
        }
        for w in ["funeral", "hospital", "people"] { #expect(!Learner.tasteable(Self.s(w), sensed: true), "\(w)") }
        #expect(SensitiveSubjects.contains(Self.s("dad's funeral")) && SensitiveSubjects.contains(Self.s("sisters")))
        #expect(!SensitiveSubjects.contains(Self.s("guitar")))
    }

    /// Three warm conversations about a topic: a taste only for a tasteable one, and
    /// never from a distress turn (their grief is not her dislike).
    @Test func tastesNeverFromPeopleGriefOrDistress() {
        func conversations(_ topic: String, _ a: Appraisal) -> ReducerRun<Learner> {
            var run = ReducerRun(Learner())
            for c in 0..<3 {
                let t = Double(c) * Self.day
                run.step(.conversationStarted(Self.at(t)), at: t)
                run.m.ongoing.topic = [Self.s(topic)]
                run.step(Kit.heard("so", a), at: t + 10)
                run.step(Kit.heard("yes", a), at: t + 20)
            }
            run.step(.conversationStarted(Self.at(3 * Self.day)), at: 3 * Self.day)
            return run
        }
        let warm = Self.ap { $0.valence = 0.8 }
        #expect(conversations("cat", warm).m.enduring.facets.contains { $0.kind == .taste && $0.subject.text == "cat" })
        for topic in ["sister", "funeral", "sarah", "job"] {
            #expect(!conversations(topic, warm).m.enduring.facets.contains { $0.kind == .taste }, "\(topic)")
        }
        let grief = Self.ap { $0.valence = -0.7; $0.distress = 0.7 }
        #expect(!conversations("dog", grief).m.enduring.facets.contains { $0.kind == .taste }, "distress lends no valence")
    }

    @Test func sensitiveTastesAreNeverRevealedOrInTheSelfBlock() {
        var e = Kit.enduring()
        var revealed = Self.taste("funeral")
        revealed.revealedAt = Kit.t0
        e.facets.append(revealed)
        #expect(!SelfBlock.render(e, person: nil).joined().contains("funeral"))
        var run = ReducerRun(Learner())
        run.m.enduring.facets.append(Self.taste("hospital"))
        run.m.ongoing.topic = [Self.s("hospital")]
        run.step(Kit.heard("so"), at: 1)
        #expect(!run.m.ongoing.noteCandidates.contains { $0.kind == .tasteReveal })
    }

    @Test func forgetThatDropsLearntTastesButNotTheSeededSelf() async throws {
        var m = Kit.moment()
        let seeded = m.enduring.facets.count
        m.enduring.facets.append(Self.taste("cat"))
        m.forget(subject: Self.s("cats"))
        #expect(!m.enduring.facets.contains { $0.kind == .taste })
        m.forget(subject: Self.s("two cameras"))
        #expect(m.enduring.facets.count == seeded, "seeded facets stay")

        let store = try SelfStore(url: nil)
        _ = try await store.loadEnduring(personality: Personality(), seed: 7, at: Kit.t0)
        try await store.apply(.facet(Self.taste("cat")))
        try await store.apply(.facet(Self.taste("rain")))
        _ = try await store.forget(subject: Self.s("cat"))
        let facets = try await store.facets()
        #expect(!facets.contains { $0.subject.text == "cat" } && facets.contains { $0.subject.text == "rain" })
        #expect(facets.filter { $0.source == .seed }.count == seeded)
    }

    @Test func noLearnIntentionsAboutSensitiveSubjects() {
        for (subject, born) in [("chemo", false), ("sister", false), ("guitar", true)] {
            var run = ReducerRun(IntentionBoard())
            run.m.ongoing.interests = [Interest(subject: Self.s(subject), weight: 0.9, lastTouched: Kit.t0)]
            run.step(.tick, at: 1)
            #expect(run.m.ongoing.intentions.contains { $0.kind == .learn } == born, "\(subject)")
        }
    }

    // MARK: 2. A neutral reply is not a failed joke (RepairKeeper side; Learner in LearnerTests)

    @Test func neutralReplyToAJokeLeavesNoAwkwardness() {
        var run = ReducerRun(RepairKeeper())
        run.step(.deeSaid(tag: .playful, sentence: "x"), at: 0)
        run.step(.deeSaid(tag: .playful, sentence: "y"), at: 0.5)
        run.step(Kit.heard("yeah so anyway", Self.ap { $0.valence = 0 }), at: 3)
        #expect(run.m.ongoing.awkwardness == 0)
        run.step(.tick, at: 400)
        #expect(!run.m.ongoing.noteCandidates.contains { $0.kind == .awkwardRepair })
    }

    // MARK: 3. Reunion

    static let lonely = Kit.snap([.loneliness: 0.9, .joy: 0.3])

    @Test func reunionAfterMoreThanADayAndNoLonelinessInTheCue() {
        #expect(CueWriter.mood(Self.lonely).contains("lonely"), "the test needs a lonely mood")
        let now = Self.at(3 * Self.day)
        var cx = Cortex(enduring: Kit.enduring(), mind: Self.lonely, at: now,
                        carried: Carried(lastContact: [Kit.john: Kit.t0]))
        _ = cx.step(.identified(Kit.john, distance: 0), mind: Self.lonely, at: now)
        #expect(cx.moment.ongoing.noteCandidates.contains { $0.kind == .reunion })
        #expect(cx.moment.momentary.signals.contains { $0.name == "reunion" })
        _ = cx.step(.tick, mind: Self.lonely, at: now.addingTimeInterval(0.5))
        #expect(cx.moment.momentary.beat?.kind == .reunion, "Beats' glad bounce")
        _ = cx.step(Kit.heard("hi Dee"), mind: Self.lonely, at: now.addingTimeInterval(2))
        let (cue, _) = cx.cue(at: now.addingTimeInterval(3))
        #expect(cue.contains("Never guilt them for being away."))
        #expect(!cue.lowercased().contains("lonely"))
        #expect(!CueWriter.reproachWords.contains { cue.lowercased().contains($0) })
        _ = cx.step(Kit.heard("so anyway"), mind: Self.lonely, at: now.addingTimeInterval(10))
        #expect(cx.cue(at: now.addingTimeInterval(11)).cue.contains("lonely"), "first turn only")
    }

    @Test func noReunionWithinADayOrForAStranger() {
        let now = Self.at(Self.day)
        var recent = Cortex(enduring: Kit.enduring(), mind: Self.lonely, at: now,
                            carried: Carried(lastContact: [Kit.john: now.addingTimeInterval(-3 * 3600)]))
        _ = recent.step(.identified(Kit.john, distance: 0), mind: Self.lonely, at: now)
        #expect(!recent.moment.ongoing.noteCandidates.contains { $0.kind == .reunion })
        var stranger = Cortex(enduring: Kit.enduring(), mind: Self.lonely, at: now)
        _ = stranger.step(.identified(Kit.ann, distance: 0), mind: Self.lonely, at: now)
        #expect(!stranger.moment.ongoing.noteCandidates.contains { $0.kind == .reunion }, "never met: nothing to reunite")
    }

    @Test func lastContactComesFromTheStore() async throws {
        let store = try SelfStore(url: nil)
        _ = try await store.loadEnduring(personality: Personality(), seed: 7, at: Kit.t0)
        try await store.apply(.digest(day: EpisodeBuilder.day(Kit.t0), person: Kit.john, conversations: 1, lowSalience: 0))
        try await store.apply(.digest(day: EpisodeBuilder.day(Self.at(5 * Self.day)), person: Kit.ann, conversations: 0, lowSalience: 1))
        let carried = try await store.loadCarried(at: Self.at(6 * Self.day))
        let john = try #require(carried.lastContact[Kit.john])
        #expect(john >= Kit.t0 && john <= Kit.t0.addingTimeInterval(2 * Self.day), "the digest day, never overstated")
        #expect(carried.lastContact[Kit.ann] == nil, "a low-salience row alone is not a conversation")
    }

    // MARK: 4. The user's time zone

    @Test func utcOffsetReachesEveryDayCalculation() {
        let toronto: TimeInterval = -4 * 3600
        var cx = Cortex(enduring: Kit.enduring(), mind: Kit.snap(), at: Kit.t0, utcOffset: toronto)
        #expect(cx.interpreter.utcOffset == toronto && cx.learner.utcOffset == toronto && cx.episodeBuilder.utcOffset == toronto)
        cx.setUTCOffset(3600)
        #expect(cx.utcOffset == 3600 && cx.learner.utcOffset == 3600 && cx.episodeBuilder.utcOffset == 3600)
        let lateEvening = SimClock.at("Tue 01:00")!          // Monday 21:00 in Toronto
        #expect(EpisodeBuilder.day(lateEvening, utcOffset: toronto) == EpisodeBuilder.day(SimClock.at("Mon 12:00")!))
        #expect(Learner(utcOffset: toronto).localHour(lateEvening) == 21, "not a morning: no 'Rise and shine'")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: Int(toronto))!
        let plan = Interpreter.PlanDetector.detect("I have an interview tomorrow", appraisal: Appraisal(), now: lateEvening, calendar: cal)
        #expect(plan?.due == SimClock.at("Tue 21:00"), "Tuesday 17:00 in Toronto")
    }

    // MARK: 5. The first sad turn already gates play and topical notes

    @Test func firstSadTurnDropsTasteRevealsAndCheerfulFollowUps() {
        var e = Kit.enduring()
        e.facets.append(Self.taste("dog"))
        var cx = Cortex(enduring: e, mind: Kit.snap(), at: Kit.t0)
        _ = cx.step(.identified(Kit.john, distance: 0), mind: Kit.snap(), at: Kit.t0)
        _ = cx.step(Kit.heard("my dog died", Self.ap { $0.distress = 0.6; $0.valence = -0.7 }), mind: Kit.snap(), at: Self.at(2))
        #expect(cx.moment.ongoing.topic.map(\.text) == ["dog"], "an irregular past ends the phrase")
        #expect(cx.moment.ongoing.noteCandidates.contains { $0.kind == .tasteReveal }, "raised…")
        #expect(cx.moment.ongoing.distressLive(at: cx.moment.now), "…but one sad turn is enough")
        let cue = cx.cue(at: Self.at(3)).cue
        #expect(!cue.contains("You happen to"))
        #expect(!cx.picker.eligible(.followUp(Self.s("party"), framing: .excited), moment: cx.moment))
        #expect(cx.picker.eligible(.followUp(Self.s("surgery"), framing: .nervous, gentle: true), moment: cx.moment))
        _ = cx.step(Kit.heard("anyway, the weather is nice", Self.ap { $0.valence = 0.3 }), mind: Kit.snap(), at: Self.at(30))
        #expect(cx.moment.ongoing.turnDistress == nil, "their next turn decides again")
    }

    // MARK: 6. Recall face only with recall words (EpisodeBuilder side in EpisodeBuilderTests)

    @Test func recallThatIsNeverSpokenNeverShowsOnTheFace() {
        var e = Kit.enduring()
        let ep = Episode(id: UUID(), person: Kit.john, start: Kit.t0, end: Kit.t0, kind: .shared, topics: [Self.s("painting")],
                         gist: "they showed me a painting", valence: 0.5, salience: 0.9, mindBefore: Kit.snap().code, mindAfter: Kit.snap().code)
        e.episodeIndex = [ep.key]
        var cx = Cortex(enduring: e, mind: Kit.snap(), at: Self.at(Self.day))
        cx.prefetch(episodes: [ep])
        _ = cx.step(.identified(Kit.john, distance: 0), mind: Kit.snap(), at: Self.at(Self.day))
        _ = cx.step(Kit.heard("I finished my painting", Self.ap { $0.distress = 0.7 }), mind: Kit.snap(), at: Self.at(Self.day + 2))
        #expect(cx.moment.ongoing.noteCandidates.contains { $0.kind == .recall })
        _ = cx.cue(at: Self.at(Self.day + 3))                        // dropped: they are upset
        for k in 0..<4 { _ = cx.step(.tick, mind: Kit.snap(), at: Self.at(Self.day + 3.5 + Double(k) * 0.5)) }
        #expect(cx.moment.momentary.beat?.kind != .recognize && cx.moment.momentary.beat?.kind != .brighten)
    }

    // MARK: 7. Boundaries land on the right topic; "don't mention it" is politeness

    @Test func pronounBoundaryIsTheNewestRecentTopic() {
        var run = ReducerRun(Interpreter())
        func boundary() -> [String] {
            run.m.momentary.signals.filter { $0.name == "userBoundary" && $0.seq == run.m.seq }.compactMap { $0.subject?.text }
        }
        run.step(Kit.heard("my sister called"), at: 1)
        run.step(Kit.heard("my cat is asleep"), at: 2)
        run.step(Kit.heard("don't ask me about it"), at: 3)
        #expect(boundary() == ["cat"], "the newest topic, not the oldest")
        run.step(Kit.heard("my boss is awful. don't ask me about it"), at: 4)
        #expect(boundary() == ["boss"], "this turn's own topic first")
        for (i, w) in ["ok", "yeah", "sure"].enumerated() { run.step(Kit.heard(w), at: 5 + Double(i)) }
        run.step(Kit.heard("don't ask me about it"), at: 9)
        #expect(boundary().isEmpty, "no topic in the last two turns: nothing to resolve")
        run.step(Kit.heard("my garden is lovely"), at: 10)
        run.step(Kit.heard("thanks! don't mention it"), at: 11)
        #expect(boundary().isEmpty)
        run.step(Kit.heard("please don't mention my job"), at: 12)
        #expect(boundary() == ["job"])
        #expect(RepairKeeper.boundaryRequest(in: "don't mention it", topic: Self.s("dog")) == nil)
        #expect(RepairKeeper.boundaryRequest(in: "don't ask me about it", topic: Self.s("dog"))?.topic == Self.s("dog"))
    }

    @Test func oneBoundaryThroughThePipeline() {
        var cx = Kit.cortex()
        _ = cx.step(.identified(Kit.john, distance: 0), mind: Kit.snap(), at: Kit.t0)
        _ = cx.step(Kit.heard("my sister called"), mind: Kit.snap(), at: Self.at(1))
        _ = cx.step(Kit.heard("my cat is asleep"), mind: Kit.snap(), at: Self.at(2))
        _ = cx.step(Kit.heard("don't ask me about it"), mind: Kit.snap(), at: Self.at(3))
        #expect(cx.moment.enduring.boundaries.filter(\.active).map(\.topic.text) == ["cat"])
        _ = cx.step(Kit.heard("you're welcome, don't mention it"), mind: Kit.snap(), at: Self.at(4))
        #expect(cx.moment.enduring.boundaries.filter(\.active).map(\.topic.text) == ["cat"])
    }

    // MARK: 9. Gags: the newest topic, a known person, the hook in the note

    @Test func gagsAreFiledUnderTheJokeTheyLaughedAt() throws {
        func laughAt(person: PersonID?) -> ReducerRun<Learner> {
            var run = ReducerRun(Learner())
            run.m.ongoing.person = person
            run.m.ongoing.topic = [Self.s("dentist"), Self.s("cat")]
            run.step(.deeSaid(tag: .playful, sentence: "x"), at: 9)
            run.step(.deeSaid(tag: .playful, sentence: "y"), at: 9.5)
            run.step(.deeTurnFinished(text: "x y"), at: 10)
            run.step(.sound(label: "belly_laugh", unexpected: false), at: 12)
            return run
        }
        let known = laughAt(person: Kit.john)
        #expect(known.m.enduring.gags.map(\.topic.text) == ["cat"])
        #expect(laughAt(person: nil).m.enduring.gags.isEmpty, "nobody to share the joke with")
        let g = try #require(known.m.enduring.gags.first)
        let hook = try #require(Learner.hook(g, humour: .deadpan))
        #expect(hook.contains("cat"))
        let note = Note.gagCallback(g.topic, style: .deadpan, hook: hook, gag: g.id)
        #expect(note.text == "(Maybe a quick callback to your running joke: \(hook).)")
        #expect(CueWriter.estimateTokens(note.text) <= CueWriter.maxNoteTokens)
    }

    // MARK: 10. Undated plans wait to be brought up

    @Test func undatedPlanGetsADormantFollowUp() {
        var run = ReducerRun(IntentionBoard())
        run.m.ongoing.person = Kit.john
        run.m.ongoing.turnsThisConversation = 1
        let id = UUID()
        IntentionBoardTests.inject(&run, "plan", subject: "exam", value: Self.at(Self.day).timeIntervalSinceReferenceDate, id: id,
                                   label: "neutral+undated")
        run.step(.tick, at: 1)
        let x = run.m.ongoing.expectations.first
        let f = run.m.ongoing.intentions.first
        #expect(x?.id == id && f?.kind == .followUp && f?.notBefore == x?.expires, "dormant: never eligible")
        run.step(Kit.heard("hi"), at: 3 * Self.day)
        #expect(!run.m.ongoing.noteCandidates.contains { $0.kind == .followUp }, "no 'how did it go?' before an exam weeks away")
        run.step(Kit.heard("the exam went great", Self.ap { $0.valence = 0.7 }), at: 3 * Self.day + 20)
        #expect(run.m.ongoing.expectations.first?.status == .resolved, "resolved when they bring it up")
    }

    // MARK: 13. A falsely detected rupture ends quietly; softened hostility counts

    @Test func calmRuptureEndsSilentlyAfterTenMinutesTogether() {
        var run = RepairKeeperTests.ruptured()
        var t = 1.0
        while t < 1 + RepairKeeper.calmExit - 40 {
            t += 20
            run.step(.head(yaw: 0, pitch: 0), at: t)
        }
        #expect(run.m.ongoing.repair == .ruptured, "not yet")
        for _ in 0..<4 {
            t += 20
            run.step(.head(yaw: 0, pitch: 0), at: t)
        }
        #expect(run.m.ongoing.repair == .fine)
        #expect(!run.m.ongoing.noteCandidates.contains { $0.kind == .reconciled }, "nobody made up: no 'they made up with you'")
        // Alone in the room the clock does not run.
        var alone = RepairKeeperTests.ruptured()
        alone.step(.tick, at: 2000)
        alone.step(.tick, at: 4000)
        #expect(alone.m.ongoing.repair == .ruptured)
        // Still cross: no exit.
        var cross = RepairKeeperTests.ruptured(mind: Kit.snap([.anger: 0.6, .resentment: 0.5]))
        for k in 1...40 { cross.step(.head(yaw: 0, pitch: 0), at: 1 + Double(k) * 20) }
        #expect(cross.m.ongoing.repair == .ruptured)
    }

    @Test func softenedHostilityIsWhatRupturesNotTheRawOne() {
        var run = ReducerRun(RepairKeeper())
        run.m.ongoing.person = Kit.john
        run.step(.tick, at: 0)
        run.m.momentary.signals.append(Signal("hostility", value: 0.3, label: "teasing", owner: Interpreter.name, seq: run.m.seq + 1))
        run.step(Kit.heard("you're useless lol", Self.ap { $0.hostility = 0.6; $0.humor = 0.4 }), at: 1)
        #expect(run.m.ongoing.repair == .fine)
        run.step(Kit.heard("you're useless", Self.ap { $0.hostility = 0.6 }), at: 2)
        #expect(run.m.ongoing.repair == .ruptured, "no signal: the raw value")
    }

    // MARK: 14. The interruption apology is not owed twice

    @Test func saidSorryMeansNoAwkwardRepairForTheInterruption() {
        var run = ReducerRun(RepairKeeper())
        for k in 0..<3 { run.step(.partial("so"), at: Double(k), events: [.deeInterrupted]) }
        run.m.momentary.signals.append(Signal("sorrySaid", owner: Beats.name, seq: run.m.seq))
        run.step(.tick, at: 3)
        #expect(run.m.ongoing.repair == .strained)
        run.step(.tick, at: 600)
        #expect(run.m.ongoing.repair == .fine)
        #expect(!run.m.ongoing.noteCandidates.contains { $0.kind == .awkwardRepair }, "she already said sorry")

        var unsaid = ReducerRun(RepairKeeper())
        for k in 0..<3 { unsaid.step(.partial("so"), at: Double(k), events: [.deeInterrupted]) }
        unsaid.step(.tick, at: 600)
        #expect(unsaid.m.ongoing.noteCandidates.contains { $0.kind == .awkwardRepair })
    }

    // MARK: 15. Goodnight on the same step

    @Test func goodnightAimIsRaisedWithTheReply() {
        var run = ReducerRun(Learner())
        run.m.ongoing.person = Kit.john
        run.m.enduring.rituals = [Ritual(id: UUID(), person: Kit.john, trigger: .goodnight, variant: 0, mannerism: .nod, count: 1,
                                         streak: 3, lastDone: Self.at(-Self.day))]
        run.step(Kit.heard("good night Dee"), at: 22 * 3600)
        let aims = run.m.ongoing.noteCandidates.filter { $0.kind == .intention }
        #expect(aims.map(\.text) == ["(\(Learner.goodnightAction))"])
        #expect(run.m.momentary.signals.contains { $0.name == "ritual" && $0.label == "goodnight" })
    }

    // MARK: 16. Presence flapping

    @Test func flappingPresenceKeepsTheBackOffAndTheGreetingQuiet() {
        var board = ReducerRun(IntentionBoard())
        board.r.unansweredInitiatives = 3
        board.step(.presence(arrived: false), at: 0)
        board.step(.presence(arrived: true), at: 5)
        #expect(board.r.unansweredInitiatives == 3, "a 5 s blip is not an absence")
        board.step(.presence(arrived: false), at: 10)
        board.step(.presence(arrived: true), at: 100)
        #expect(board.r.unansweredInitiatives == 0)

        var att = ReducerRun(Attention())
        func greeted() -> Bool { att.m.momentary.mannerismRequests.contains { $0.what == .signature(.greeting) } }
        att.step(.presence(arrived: true), at: 0)
        #expect(greeted())
        att.step(.presence(arrived: false), at: 5)
        att.step(.presence(arrived: true), at: 10)
        #expect(!greeted(), "10 min cooldown")
        att.step(.presence(arrived: true), at: 700)
        #expect(greeted())
        att.m.ongoing.repair = .ruptured
        att.step(.presence(arrived: true), at: 1400)
        #expect(!greeted(), "not while a rupture is open")
    }

    // MARK: 17. "Not now" means not now

    @Test func statedBusyStopsInitiative() {
        let board = IntentionBoard()
        var m = Kit.moment()
        m.ongoing.hypotheses = [Hypothesis(kind: .busy, value: "busy", confidence: 1, stated: true, expires: Self.at(600))]
        #expect(board.initiativeThreshold(m) == nil)
        m.ongoing.hypotheses = [Hypothesis(kind: .busy, value: "busy", confidence: 0.6, expires: Self.at(600))]
        #expect(board.initiativeThreshold(m) == IntentionBoard.busyInitiativeThreshold)
    }

    // MARK: 18. Stale context notes

    @Test func contextNotesGoStale() {
        var cx = Kit.cortex()
        let recall = Note(.recall, slots: ["they showed me a painting"], episode: UUID(), owner: EpisodeBuilder.name)
        var m = cx.moment
        m.ongoing.noteCandidates = [recall]
        cx = Cortex.restoring(cx, moment: m)
        _ = cx.step(.sight(camera: .front, things: [], novel: []), mind: Kit.snap(), at: Self.at(1))
        #expect(cx.moment.ongoing.noteCandidates.first?.raisedAt == Self.at(1), "Cortex stamps what was raised")
        var fresh = cx.moment
        fresh.now = Self.at(20)
        #expect(cx.picker.eligible(cx.moment.ongoing.noteCandidates[0], moment: fresh))
        fresh.now = Self.at(1 + NotePicker.staleAfter + 1)
        #expect(!cx.picker.eligible(cx.moment.ongoing.noteCandidates[0], moment: fresh))
        #expect(!cx.cue(at: Self.at(3600)).cue.contains("You remember"), "hours later, on another topic")
        var boundary = Note.userBoundary(Self.s("job"))
        boundary.raisedAt = Kit.t0
        #expect(cx.picker.eligible(boundary, moment: fresh), "safety notes never go stale")
    }

    // MARK: 19. One laughter test

    @Test func everyLaughterLabelCounts() {
        for l in ["laughter", "Laughter", "belly_laugh", "chuckle_chortle", "snicker", "giggling", "baby_laughter", "Chuckle"] {
            #expect(Laughter.isLaughter(l), "\(l)")
            #expect(RepairKeeper.isLaughter(.sound(label: l, unexpected: false)), "\(l)")
            #expect(Learner.isLaughter(l) && Interpreter.isLaughter(l), "\(l)")
        }
        #expect(!Laughter.isLaughter("speech") && !Laughter.isLaughter("dog_bark"))
    }

    @Test func questionLetGoDropsTheAim() {
        var run = ReducerRun(IntentionBoard())
        let it = Intention(id: UUID(), kind: .learn, subject: Self.s("guitar"), person: nil, reason: "curious", notBefore: Kit.t0,
                           expires: Self.at(Self.day), priority: 0.5, status: .issued, issuedCount: 1, source: "interest", created: Kit.t0)
        run.m.ongoing.intentions = [it]
        IntentionBoardTests.inject(&run, "questionLetGo", id: it.id, owner: Listener.name)
        run.step(.tick, at: 20)
        #expect(run.m.ongoing.intentions.first?.status == .dropped || run.m.ongoing.intentions.isEmpty, "never re-asked")
    }

    // MARK: 20. Odd hypothesis notes

    @Test func noHappyNoteAndYesNoAnswersAreNotBusy() {
        var happy = ReducerRun(Interpreter())
        for k in 0..<3 { happy.step(Kit.heard("that is brilliant news", Self.ap { $0.valence = 0.7 }), at: Double(k)) }
        #expect(happy.m.ongoing.hypotheses.contains { $0.value == "happy" && $0.confidence >= 0.5 })
        #expect(!happy.m.ongoing.noteCandidates.contains { $0.kind == .hypothesis }, "no '(Maybe they're happy…)'")

        var yesNo = ReducerRun(Interpreter())
        for k in 0..<3 {
            let t = Double(k) * 10
            yesNo.step(.deeTurnFinished(text: "Fun! Do you want to hear another one?"), at: t)
            yesNo.step(Kit.heard("yeah"), at: t + 2)
        }
        #expect(!yesNo.m.ongoing.hypotheses.contains { $0.kind == .busy }, "answers to her yes/no questions")
        var curt = ReducerRun(Interpreter())
        for k in 0..<3 {
            let t = Double(k) * 10
            curt.step(.deeTurnFinished(text: "What did you do today?"), at: t)
            curt.step(Kit.heard("stuff"), at: t + 2)
        }
        #expect(curt.m.ongoing.hypotheses.contains { $0.kind == .busy })
        #expect(Interpreter.endsWithYesNoQuestion("Ha. Are you okay?") && !Interpreter.endsWithYesNoQuestion("Okay. What now?"))
        #expect(Interpreter.endsWithYesNoQuestion("Isn't it lovely?") && !Interpreter.endsWithYesNoQuestion("Nice."))
    }

    // MARK: 24. Ritual wording

    @Test func ritualLinesCarryNoReproachOrClockAssumptions() {
        let all = Learner.ritualPhrases.values.flatMap(\.values).flatMap { $0 }
        #expect(all.count >= 60)
        for line in all {
            let l = line.lowercased()
            #expect(!CueWriter.reproachWords.contains(where: l.contains), "\(line)")
            #expect(!l.contains("at last") && !l.contains("sleepyhead"), "\(line)")
        }
    }
}
