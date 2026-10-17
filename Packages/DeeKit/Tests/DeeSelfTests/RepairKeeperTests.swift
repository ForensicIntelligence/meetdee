import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// RepairKeeper (SELF.md §7.8). Owner: RepairKeeper. Goldens: `Fixtures/RepairKeeper/`
/// and the whole-pipeline `Fixtures/Cortex/dee-interrupts-three-times.json`,
/// `Fixtures/Cortex/repair-insult-apology.json`, `Fixtures/Cortex/repair-user-boundary.json`.
@Suite struct RepairKeeperTests {
    // MARK: Builders

    static func appraisal(hostility: Double = 0, apology: Double = 0, humor: Double = 0, valence: Double = 0,
                          threat: Double = 0) -> Appraisal {
        var a = Appraisal()
        a.hostility = hostility
        a.apology = apology
        a.humor = humor
        a.valence = valence
        a.threat = threat
        return a
    }

    static let insult = Kit.heard("you are useless", appraisal(hostility: 0.8, valence: -0.6))
    static let apology = Kit.heard("sorry", appraisal(apology: 0.7, valence: 0.3))
    static let neutral = Kit.heard("so anyway", appraisal(valence: 0.05))
    static let pet = Percept.touch(kind: "pet", gentle: true, at: nil)

    /// Cross after an insult: anger and resentment up.
    static var cross: MindSnapshot { Kit.snap([.anger: 0.4, .resentment: 0.5]) }
    static var calm: MindSnapshot { Kit.snap() }
    static var timid: MindSnapshot { Kit.snap(personality: [.assertiveness: 0.2]) }

    /// A signal as if raised this step by `owner` (an earlier reducer).
    static func inject(_ run: inout ReducerRun<RepairKeeper>, _ name: String, subject: Subject? = nil, id: UUID? = nil,
                       owner: String = "Interpreter") {
        run.m.momentary.signals.append(Signal(name, subject: subject, id: id, owner: owner, seq: run.m.seq + 1))
    }

    static func notes(_ m: Moment) -> [Note.Kind] { m.ongoing.noteCandidates.filter { $0.owner == RepairKeeper.name }.map(\.kind) }

    static func persisted(_ fx: [Effect]) -> [SelfWrite] {
        fx.compactMap { if case .persist(let w) = $0 { w } else { nil } }
    }

    static func signals(_ m: Moment, _ name: String) -> [Signal] {
        m.momentary.signals.filter { $0.owner == RepairKeeper.name && $0.name == name && $0.seq == m.seq }
    }

    static func ruptured(person: PersonID? = Kit.john, mind: MindSnapshot = calm) -> ReducerRun<RepairKeeper> {
        var run = ReducerRun(RepairKeeper(), mind: mind)
        run.m.ongoing.person = person
        run.step(.tick, at: 0)
        run.step(insult, at: 1)
        #expect(run.m.ongoing.repair == .ruptured)
        return run
    }

    // MARK: Awkwardness

    @Test func awkwardnessStrainAndSelfRepairOnce() {
        var run = ReducerRun(RepairKeeper())
        run.step(.tick, at: 0, events: [.deeInterrupted])
        run.step(.tick, at: 0.1, events: [.deeInterrupted])
        #expect(run.m.ongoing.repair == .fine)
        run.step(.tick, at: 0.2, events: [.deeInterrupted])
        #expect(run.m.ongoing.awkwardness >= 0.5)
        #expect(run.m.ongoing.repair == .strained)
        run.step(.tick, at: 60)
        #expect(run.m.ongoing.repair == .strained)
        run.step(.tick, at: 600)
        #expect(run.m.ongoing.repair == .fine)
        #expect(run.m.ongoing.noteCandidates.map(\.kind) == [.awkwardRepair])
        #expect(run.m.ongoing.noteCandidates[0].owner == "RepairKeeper")
        run.step(.tick, at: 700)
        #expect(run.m.ongoing.noteCandidates.count == 1)
        run.issue(run.m.ongoing.noteCandidates[0])
        run.m.ongoing.noteCandidates = []
        run.step(.tick, at: 701)
        #expect(run.m.ongoing.noteCandidates.isEmpty, "issued once, never again")
    }

    @Test func awkwardnessHalvesEveryThreeMinutes() {
        var run = ReducerRun(RepairKeeper())
        run.step(.tick, at: 0, events: [.deeInterrupted])
        run.step(.tick, at: 180)
        #expect(abs(run.m.ongoing.awkwardness - 0.1) < 1e-9)
        run.step(.tick, at: 360)
        #expect(abs(run.m.ongoing.awkwardness - 0.05) < 1e-9)
    }

    @Test func passedOverSelfRepairNoteIsReraisedUntilStale() {
        var run = ReducerRun(RepairKeeper())
        for i in 0..<3 { run.step(.tick, at: Double(i) * 0.1, events: [.deeInterrupted]) }
        run.step(.tick, at: 600)
        #expect(Self.notes(run.m) == [.awkwardRepair])
        run.m.ongoing.noteCandidates = []          // a cue passed it over (a higher aim won)
        run.step(.tick, at: 601)
        #expect(Self.notes(run.m) == [.awkwardRepair])
        run.m.ongoing.noteCandidates = []
        run.step(.tick, at: 600 + RepairKeeper.awkwardNoteLife + 1)
        #expect(Self.notes(run.m).isEmpty, "stale after 5 min")
    }

    @Test func misreadAddsOncePerMisread() {
        var run = ReducerRun(RepairKeeper())
        let mr = Misread(id: UUID(), person: nil, at: Kit.t0, situation: .moodGuess)
        run.m.ongoing.misreadThisTurn = mr
        run.step(.tick, at: 0)
        #expect(abs(run.m.ongoing.awkwardness - 0.25) < 1e-9)
        run.step(.tick, at: 0)                     // still set: not counted twice
        #expect(abs(run.m.ongoing.awkwardness - 0.25) < 1e-9)
        Self.inject(&run, "misread", id: mr.id)      // the same misread as a signal: deduplicated
        run.step(.tick, at: 0)
        #expect(abs(run.m.ongoing.awkwardness - 0.25) < 1e-9)
        Self.inject(&run, "misread", id: UUID())
        run.step(.tick, at: 0)
        #expect(run.m.ongoing.awkwardness >= 0.5)
        #expect(run.m.ongoing.repair == .strained)
    }

    @Test func awkwardSilenceIsNotDeesFault() {
        var run = ReducerRun(RepairKeeper())
        for _ in 0..<4 {
            Self.inject(&run, "awkwardSilence", owner: "Listener")
            run.step(.tick, at: 0)
        }
        #expect(abs(run.m.ongoing.awkwardness - 0.6) < 1e-9)
        #expect(run.m.ongoing.repair == .strained)
        run.step(.tick, at: 900)
        #expect(run.m.ongoing.repair == .fine)
        #expect(Self.notes(run.m).isEmpty, "no self-repair note when Dee didn't cause it")
    }

    static func joke(_ run: inout ReducerRun<RepairKeeper>, _ tag: Emotion = .playful, at t: Double) {
        run.step(.deeSaid(tag: tag, sentence: "x"), at: t)
        run.step(.deeSaid(tag: tag, sentence: "y"), at: t + 0.5)
    }

    @Test func failedJokes() {
        // A clearly negative reply after a joke (two playful sentences).
        var run = ReducerRun(RepairKeeper())
        Self.joke(&run, at: 0)
        run.step(Kit.heard("ugh", Self.appraisal(valence: -0.4)), at: 3)
        #expect(abs(run.m.ongoing.awkwardness - 0.2) < 1e-9)
        #expect(Self.signals(run.m, "jokeFlopped").count == 1)
        run.step(Kit.heard("ugh", Self.appraisal(valence: -0.4)), at: 4)              // judged once
        #expect(abs(run.m.ongoing.awkwardness - 0.2) < 0.01)

        // Review finding 2: a neutral reply is no evidence, and one playful sentence is no joke.
        var flat = ReducerRun(RepairKeeper())
        Self.joke(&flat, at: 0)
        flat.step(Self.neutral, at: 3)
        #expect(flat.m.ongoing.awkwardness == 0 && Self.signals(flat.m, "jokeFlopped").isEmpty)
        var single = ReducerRun(RepairKeeper())
        single.step(.deeSaid(tag: .playful, sentence: "x"), at: 0)
        single.step(Kit.heard("ugh", Self.appraisal(valence: -0.4)), at: 3)
        #expect(single.m.ongoing.awkwardness == 0)

        // "Not funny" even when the appraiser smelled humour (and even after a one-liner).
        var b = ReducerRun(RepairKeeper())
        b.step(.deeSaid(tag: .mischievous, sentence: "x"), at: 0)
        b.step(Kit.heard("that's not funny", Self.appraisal(humor: 0.4, valence: 0.2)), at: 2)
        #expect(abs(b.m.ongoing.awkwardness - 0.2) < 1e-9)

        // A laugh lands it.
        var c = ReducerRun(RepairKeeper())
        c.step(.deeSaid(tag: .giddy, sentence: "x"), at: 0)
        c.step(Kit.heard("haha", Self.appraisal(humor: 0.8, valence: 0.6)), at: 2)
        #expect(c.m.ongoing.awkwardness == 0)
        var d = ReducerRun(RepairKeeper())
        Self.joke(&d, at: 0)
        d.step(.sound(label: "laughter", unexpected: false), at: 1)
        d.step(Self.neutral, at: 2)
        #expect(d.m.ongoing.awkwardness == 0)

        // Not playful, or too late: no judgement.
        var e = ReducerRun(RepairKeeper())
        e.step(.deeSaid(tag: .curious, sentence: "x"), at: 0)
        e.step(Self.neutral, at: 2)
        e.step(.deeSaid(tag: .playful, sentence: "x"), at: 10)
        e.step(Self.neutral, at: 10 + RepairKeeper.jokeWindow + 1)
        #expect(e.m.ongoing.awkwardness == 0)
    }

    @Test func reconciledTagDecidesWhetherItWasAJoke() {
        // FloorKeeper substituted the playful tag (e.g. while upset): not a joke.
        var run = ReducerRun(RepairKeeper())
        run.m.momentary.llmTag = Timed(.worried, until: Kit.t0.addingTimeInterval(10))
        run.step(.deeSaid(tag: .playful, sentence: "x"), at: 0)
        run.step(Self.neutral, at: 3)
        #expect(run.m.ongoing.awkwardness == 0)
    }

    // MARK: Transitions (table)

    @Test func ruptureTriggers() {
        // Hostility and threats.
        for a in [Self.appraisal(hostility: 0.5), Self.appraisal(threat: 0.7)] {
            var run = ReducerRun(RepairKeeper())
            run.step(Kit.heard("x", a), at: 0)
            #expect(run.m.ongoing.repair == .ruptured)
        }
        // Mild rudeness is not a rupture.
        var mild = ReducerRun(RepairKeeper())
        mild.step(Kit.heard("x", Self.appraisal(hostility: 0.3)), at: 0)
        #expect(mild.m.ongoing.repair == .fine)

        // Anger rising past 0.5 on a user step (a slap).
        var slap = ReducerRun(RepairKeeper())
        slap.step(.tick, at: 0)
        slap.step(.touch(kind: "slap", gentle: false, at: nil), at: 1, mind: Kit.snap([.anger: 0.7]))
        #expect(slap.m.ongoing.repair == .ruptured)

        // Regard ≥ 0.4 below its 10-minute high.
        var regard = ReducerRun(RepairKeeper())
        regard.step(.tick, at: 0)
        regard.step(Self.neutral, at: 60, mind: Kit.snap([.affection: 0.1, .resentment: 0.9]))
        #expect(regard.m.ongoing.repair == .ruptured)
        // One drop ruptures once: a bid on the next step still counts.
        regard.step(Self.apology, at: 61)
        #expect(regard.m.ongoing.repair == .repairing)
    }

    @Test func noRuptureWithoutAUserCause() {
        // Already cross at launch: no rise, no rupture.
        var run = ReducerRun(RepairKeeper(), mind: Kit.angry)
        run.step(.tick, at: 0)
        run.step(Kit.heard("haha", Self.appraisal(humor: 0.6, valence: 0.5)), at: 1)
        #expect(run.m.ongoing.repair == .fine)
        // Anger rising on a tick (no user step) is not a rupture either.
        var tick = ReducerRun(RepairKeeper())
        tick.step(.tick, at: 0)
        tick.step(.tick, at: 1, mind: Kit.snap([.anger: 0.9]))
        tick.step(.tick, at: 2)
        #expect(tick.m.ongoing.repair == .fine)
        // A regard drop spread over more than 10 minutes is drift, not a rupture.
        var drift = ReducerRun(RepairKeeper())
        drift.step(Self.neutral, at: 0)
        drift.step(Self.neutral, at: 700, mind: Kit.snap([.affection: 0.1, .resentment: 0.9]))
        #expect(drift.m.ongoing.repair == .fine)
    }

    @Test func everyBidKindStartsRepair() {
        let bids: [Percept] = [
            Self.apology, Self.pet, .touch(kind: "hug", gentle: true, at: nil), .touch(kind: "hold", gentle: true, at: nil),
            .sound(label: "laughter", unexpected: false), .gesture("thumbsUp"),
            Kit.heard("hey, are we ok?"), Kit.heard("friends?"), Kit.heard("I didn’t mean it"),
            Kit.heard("hehe", Self.appraisal(humor: 0.7, valence: 0.4)),
        ]
        for b in bids {
            var run = Self.ruptured(mind: Self.cross)
            run.step(.deeTurnFinished(text: "Hm."), at: 4)   // laughter answers Dee only
            run.step(b, at: 5)
            #expect(run.m.ongoing.repair == .repairing, "\(describe(b))")
            #expect(run.r.bids == 1)
        }
        // Review finding 13: laughter long after Dee spoke (a TV) is not a bid.
        var tv = Self.ruptured(mind: Self.cross)
        tv.step(.sound(label: "laughter", unexpected: false), at: 300)
        #expect(tv.m.ongoing.repair == .ruptured && tv.r.bids == 0)
        let notBids: [Percept] = [.touch(kind: "pet", gentle: false, at: nil), .touch(kind: "poke", gentle: true, at: nil),
                                  .gesture("palm"), Self.neutral, .tick, Kit.heard("sorry you're so dumb", Self.appraisal(hostility: 0.7, apology: 0.5))]
        for b in notBids {
            var run = Self.ruptured(mind: Self.cross)
            run.step(b, at: 5)
            #expect(run.m.ongoing.repair == .ruptured, "\(describe(b))")
        }
    }

    @Test func twoBidsReconcileWithTheNoteOnceAndASquint() {
        var run = Self.ruptured(mind: Self.cross)
        run.step(Self.apology, at: 10)
        #expect(run.m.ongoing.repair == .repairing)
        run.step(Self.pet, at: 12)
        #expect(run.m.ongoing.repair == .reconciled)
        #expect(run.m.momentary.mannerismRequests == [MannerismRequest(.mannerism(.contentSquint), rank: .reaction, owner: "RepairKeeper")])
        #expect(Self.notes(run.m) == [.reconciled])
        #expect(Self.signals(run.m, "repairPhase").map(\.label) == ["reconciled"])
        run.step(.tick, at: 13)
        #expect(Self.notes(run.m) == [.reconciled], "not duplicated")
        run.issue(run.m.ongoing.noteCandidates[0])
        run.m.ongoing.noteCandidates = []
        run.step(Self.pet, at: 20)
        run.step(.tick, at: 30)
        #expect(Self.notes(run.m).isEmpty, "the reconciled note is issued exactly once")
        run.step(.tick, at: 12 + RepairKeeper.reconciledHold)
        #expect(run.m.ongoing.repair == .fine)
    }

    @Test func calmMoodReconcilesAtTheNextUserStep() {
        var run = Self.ruptured(mind: Self.cross)
        run.step(Self.apology, at: 10)
        #expect(run.m.ongoing.repair == .repairing)
        run.step(.tick, at: 400, mind: Self.calm)    // calm, but nobody did anything yet
        #expect(run.m.ongoing.repair == .repairing)
        run.step(Self.neutral, at: 401)
        #expect(run.m.ongoing.repair == .reconciled)
        // Still cross: no reconciliation from mood alone.
        var cross = Self.ruptured(mind: Self.cross)
        cross.step(Self.apology, at: 10)
        cross.step(Self.neutral, at: 20)
        #expect(cross.m.ongoing.repair == .repairing)
    }

    @Test func reInsultRestartsTheRupture() {
        var run = Self.ruptured(mind: Self.cross)
        run.step(Self.apology, at: 10)
        run.step(Self.insult, at: 900)
        #expect(run.m.ongoing.repair == .ruptured)
        #expect(run.r.bids == 0)
        run.step(Self.apology, at: 901)
        #expect(run.m.ongoing.repair == .repairing, "one bid is not two after a fresh insult")
    }

    @Test func absenceNeverRuptures() {
        var run = ReducerRun(RepairKeeper())
        run.step(.tick, at: 0)
        run.step(.presence(arrived: false), at: 1)
        run.step(.tick, at: 30 * 86_400)
        run.step(.presence(arrived: true), at: 30 * 86_400 + 1)
        run.step(Kit.heard("hi", Self.appraisal(valence: 0.3)), at: 30 * 86_400 + 2)
        #expect(run.m.ongoing.repair == .fine)
        #expect(run.m.ongoing.awkwardness == 0)
    }

    // MARK: Dee's boundary

    @Test func deeBoundaryOnceOnASecondInsult() {
        var run = Self.ruptured(mind: Self.cross)
        #expect(Self.notes(run.m).isEmpty, "one insult: no boundary yet")
        let fx = run.step(Self.insult, at: 120)
        #expect(Self.notes(run.m) == [.deeBoundary])
        let b = Self.persisted(fx).compactMap { if case .boundary(let b) = $0 { b } else { nil } }
        #expect(b.count == 1 && b[0].owner == .dee && b[0].person == Kit.john && b[0].active)
        #expect(Self.signals(run.m, "deeBoundary").first?.id == b.first?.id)
        run.issue(run.m.ongoing.noteCandidates.first { $0.kind == .deeBoundary }!)
        run.m.ongoing.noteCandidates = []
        run.step(Self.insult, at: 180)
        run.step(Self.insult, at: 900)
        #expect(Self.notes(run.m).isEmpty, "once per rupture")

        // After reconciliation it is not raised again, and Dee's boundary is put away.
        run.step(Self.apology, at: 901)
        let fx2 = run.step(Self.pet, at: 902)
        #expect(run.m.ongoing.repair == .reconciled)
        #expect(Self.persisted(fx2).contains { if case .boundary(let x) = $0 { x.owner == .dee && !x.active } else { false } })
        #expect(!Self.notes(run.m).contains(.deeBoundary))
    }

    @Test func deeBoundaryGates() {
        // Not assertive.
        var timid = Self.ruptured(mind: Self.timid)
        timid.step(Self.insult, at: 60)
        #expect(Self.notes(timid.m).isEmpty)
        // Insults more than 10 minutes apart.
        var slow = Self.ruptured(mind: Self.cross)
        slow.step(Self.insult, at: 1 + RepairKeeper.deeBoundaryWindow + 1)
        #expect(Self.notes(slow.m).isEmpty)
        // Unknown speaker: the note, but nothing stored.
        var anon = Self.ruptured(person: nil, mind: Self.cross)
        let fx = anon.step(Self.insult, at: 60)
        #expect(Self.notes(anon.m) == [.deeBoundary])
        #expect(Self.persisted(fx).isEmpty)
        // Stated within the last 10 minutes (a new rupture after making up): not again yet.
        var again = Self.ruptured(mind: Self.cross)
        again.step(Self.insult, at: 60)
        again.issue(Note.deeBoundary(owner: RepairKeeper.name))
        again.m.ongoing.noteCandidates = []
        again.step(Self.apology, at: 70)
        again.step(Self.pet, at: 71)
        again.step(Self.insult, at: 200)
        again.step(Self.insult, at: 210)
        #expect(Self.notes(again.m).isEmpty)
        again.step(Self.insult, at: 700)
        #expect(Self.notes(again.m) == [.deeBoundary], "10 min later a new rupture may state it again")
    }

    // MARK: User boundaries

    @Test func boundaryPhrases() {
        let job = Subject("job")!
        let cases: [(String, String?, Bool)] = [
            ("Don't ask me about my job", "job", false),
            ("please don’t ask me about my job, okay?", "job", false),
            ("I don't want to talk about my ex anymore", "ex", false),
            ("stop asking about work stuff", "work stuff", false),
            ("I'd rather not talk about the stuff that happened", "job", false),   // "stuff" → current topic
            ("don't ask me about the purple elephant under my bed", "purple elephant", false),
            ("don't bring up my brother's wedding again", "brother's wedding", false),
            ("You can ask me about my job again", "job", true),
            ("it's okay to ask about money now", "money", true),
            ("I don't want to talk about it", "job", false),          // pronoun → current topic
            ("you can ask me about anything", nil, false),              // an invitation, not a lift
            ("what do you want to talk about", nil, false),
            ("tell me about your day", nil, false),
        ]
        for (text, want, lift) in cases {
            let r = RepairKeeper.boundaryRequest(in: text, topic: job)
            #expect(r?.topic.text == want, "\(text) → \(r?.topic.text ?? "nil")")
            if want != nil { #expect(r?.lift == lift, "\(text)") }
        }
        #expect(RepairKeeper.boundaryRequest(in: "I don't want to talk about it") == nil, "no topic to stand for")
    }

    @Test func userBoundarySetAndLifted() {
        var run = ReducerRun(RepairKeeper())
        run.m.ongoing.person = Kit.john
        let fx = run.step(Kit.heard("don't ask me about my job"), at: 0)
        let b = run.m.enduring.boundaries
        #expect(b.count == 1 && b[0].owner == .user && b[0].topic.text == "job" && b[0].person == Kit.john && b[0].active)
        #expect(Self.persisted(fx) == [.boundary(b[0])])
        #expect(run.r.avoid == ["job"])
        #expect(run.m.ongoing.noteCandidates.map(\.text) == ["(Don't bring up job.)"])
        #expect(Self.signals(run.m, "userBoundary").map(\.subject) == [Subject("job")])

        // Said again: the same row, no duplicate.
        run.m.ongoing.noteCandidates = []
        run.step(Kit.heard("seriously, stop asking about my job"), at: 5)
        #expect(run.m.enduring.boundaries.count == 1)

        let lifted = run.step(Kit.heard("you can ask me about my job again"), at: 60)
        #expect(run.m.enduring.boundaries.count == 1 && !run.m.enduring.boundaries[0].active)
        #expect(Self.persisted(lifted).count == 1)
        #expect(run.r.avoid.isEmpty)
        #expect(Self.signals(run.m, "userBoundaryLifted").count == 1)
        #expect(!run.m.ongoing.noteCandidates.contains { $0.kind == .userBoundary })

        // Set again later: the same row reactivated.
        run.step(Kit.heard("actually don't ask me about my job"), at: 120)
        #expect(run.m.enduring.boundaries.count == 1 && run.m.enduring.boundaries[0].active)
        #expect(run.m.enduring.boundaries[0].id == b[0].id)
    }

    @Test func boundarySignalsFromInterpreterAreDeduplicated() {
        var run = ReducerRun(RepairKeeper(), mind: Self.cross)
        run.m.ongoing.person = Kit.john
        Self.inject(&run, "userBoundary", subject: Subject("job"))
        Self.inject(&run, "userBoundary", subject: Subject("money"))
        run.step(Kit.heard("don't ask me about my job or money"), at: 0)
        #expect(run.m.enduring.boundaries.map(\.topic.text).sorted() == ["job", "money"])
        #expect(run.r.avoid == ["job", "money"])
        #expect(run.m.ongoing.noteCandidates.filter { $0.kind == .userBoundary }.count == 1)
        Self.inject(&run, "reconciliationBid")
        run.step(Self.insult, at: 1)
        Self.inject(&run, "reconciliationBid")
        run.step(Self.apology, at: 2)
        #expect(run.r.bids == 1, "the signal and its own detection are one bid")
    }

    @Test func unknownSpeakerBoundaryIsStoredOnceIdentified() {
        var run = ReducerRun(RepairKeeper())
        let fx = run.step(Kit.heard("don't ask me about my job"), at: 0)
        #expect(Self.persisted(fx).isEmpty && run.m.enduring.boundaries.isEmpty)
        #expect(run.r.sessionBoundaries == [Subject("job")!])
        #expect(run.r.avoid == ["job"])
        run.m.ongoing.noteCandidates = []
        run.step(Kit.heard("hm"), at: 5)
        #expect(run.m.ongoing.noteCandidates.map(\.text) == ["(Don't bring up job.)"], "reminded: no prompt line for it")
        run.m.ongoing.person = Kit.john
        let stored = run.step(.identified(Kit.john, distance: 0.2), at: 6)
        #expect(Self.persisted(stored).count == 1)
        #expect(run.m.enduring.boundaries.map(\.person) == [Kit.john])
        #expect(run.r.sessionBoundaries.isEmpty && run.r.avoid == ["job"])
    }

    @Test func avoidFollowsTheSpeaker() {
        var run = ReducerRun(RepairKeeper())
        run.m.enduring.boundaries = [Boundary(id: UUID(), person: Kit.john, topic: Subject("job")!, owner: .user, createdAt: Kit.t0),
                                     Boundary(id: UUID(), person: Kit.john, topic: Subject("tone")!, owner: .dee, createdAt: Kit.t0),
                                     Boundary(id: UUID(), person: Kit.ann, topic: Subject("money")!, owner: .user, createdAt: Kit.t0)]
        run.m.ongoing.person = Kit.john
        run.step(.tick, at: 0)
        #expect(run.r.avoid == ["job"])
        run.m.ongoing.person = Kit.ann
        run.step(.tick, at: 1)
        #expect(run.r.avoid == ["money"])
    }

    /// Review finding 10: the prompt was rendered before identification, so it lacks
    /// "Don't bring up"; each user turn of the identified person raises it as context.
    @Test func boundariesRemindedWhenThePromptLacksThem() {
        var run = ReducerRun(RepairKeeper())
        run.m.enduring.boundaries = [Boundary(id: UUID(), person: Kit.john, topic: Subject("job")!, owner: .user, createdAt: Kit.t0),
                                     Boundary(id: UUID(), person: Kit.john, topic: Subject("money")!, owner: .user,
                                              createdAt: Kit.t0.addingTimeInterval(1))]
        run.step(Kit.heard("hi"), at: 0)
        #expect(run.m.ongoing.noteCandidates.isEmpty, "no prompt rendered yet")
        run.m.ongoing.promptRendered = true
        run.m.ongoing.person = Kit.john
        run.step(Kit.heard("hi"), at: 1)
        #expect(run.m.ongoing.noteCandidates.map(\.text) == ["(Don't bring up money, job.)"])
        run.m.ongoing.noteCandidates = []
        run.m.ongoing.promptPerson = Kit.john
        run.step(Kit.heard("hi"), at: 2)
        #expect(run.m.ongoing.noteCandidates.isEmpty, "the prompt already has the line")
        run.step(Kit.heard("don't ask me about my car"), at: 3)
        #expect(run.m.ongoing.noteCandidates.map(\.text) == ["(Don't bring up car.)"], "that turn's note")
    }

    /// SELF.md §12.4 scenario 8 through the whole Cortex.
    @Test func scenarioUserBoundaryReachesTheNextPrompt() {
        var cx = Kit.cortex()
        let mind = Kit.snap()
        var t = Kit.t0
        func step(_ p: Percept) -> [Effect] {
            t += 1
            return cx.step(p, mind: mind, at: t)
        }
        _ = step(.identified(Kit.john, distance: 0))   // name-confirmed (§10.3 gate: one face match is not enough)
        _ = cx.persona(Persona(), person: Kit.john, at: t)
        let fx = step(Kit.heard("don't ask me about my job"))
        #expect(fx.contains { if case .persist(.boundary(let b)) = $0 { b.topic.text == "job" } else { false } })
        #expect(cx.repairKeeper.avoid == ["job"])
        #expect(cx.cue(at: t).cue.contains("(Don't bring up job.)"))
        #expect(SelfBlock.boundaryLine(cx.frozenEnduring, person: Kit.john) == nil, "frozen for this conversation")
        _ = step(.conversationStarted(t))
        #expect(cx.persona(Persona(), person: Kit.john, at: t).selfLines.contains("Don't bring up: job."))
        _ = step(Kit.heard("you can ask me about my job again"))
        #expect(cx.repairKeeper.avoid.isEmpty)
        _ = step(.conversationStarted(t))
        #expect(!cx.persona(Persona(), person: Kit.john, at: t).selfLines.contains { $0.contains("Don't bring up") })
    }

    // MARK: The open rupture across relaunches

    @Test func openRupturePersistedAndCleared() {
        var run = ReducerRun(RepairKeeper(), mind: Self.cross)
        run.m.ongoing.person = Kit.john
        run.step(.tick, at: 0)
        let fx = run.step(Self.insult, at: 1)
        #expect(Self.persisted(fx) == [.openRepair(Kit.john, .ruptured, togetherSecondsLeft: RepairKeeper.openTogether)])
        let fx2 = run.step(Self.apology, at: 2)
        #expect(Self.persisted(fx2) == [.openRepair(Kit.john, .repairing, togetherSecondsLeft: RepairKeeper.openTogether - 1)])
        #expect(run.r.flush(&run.m) == [.persist(.openRepair(Kit.john, .repairing, togetherSecondsLeft: RepairKeeper.openTogether - 1))])
        let fx3 = run.step(Self.pet, at: 3)
        #expect(Self.persisted(fx3) == [.clearOpenRepair(Kit.john)])
        #expect(run.r.flush(&run.m).isEmpty)
    }

    @Test func ruptureEndsAfterSixHoursTogetherNotWallTime() {
        var run = Self.ruptured(mind: Self.cross)
        // A day away: no together time used.
        run.step(.presence(arrived: false), at: 2)
        run.step(.tick, at: 86_400)
        #expect(run.m.ongoing.repair == .ruptured)
        #expect(run.r.togetherLeft == RepairKeeper.openTogether)
        // Back together, with contact every 20 s: re-persisted every 5 min, done at 6 h.
        var t = 86_400.0
        var writes: [SelfWrite] = []
        while run.m.ongoing.repair == .ruptured && t < 86_400 + 8 * 3600 {
            t += 20
            writes += Self.persisted(run.step(.head(yaw: 0, pitch: 0), at: t))
        }
        #expect(run.m.ongoing.repair == .fine)
        #expect(abs(t - 86_400 - RepairKeeper.openTogether) <= 20)
        #expect(writes.last == .clearOpenRepair(Kit.john))
        #expect(writes.filter { if case .openRepair = $0 { true } else { false } }.count == Int(RepairKeeper.openTogether / RepairKeeper.persistEvery) - 1)
        #expect(Self.notes(run.m).isEmpty, "ends silently")
    }

    @Test func carriedRuptureRestoredForItsPerson() {
        var run = ReducerRun(RepairKeeper(), mind: Self.cross)
        run.r.seed(from: Carried(openRepair: [Kit.john: .ruptured]), &run.m)
        run.m.ongoing.person = Kit.ann
        run.step(.identified(Kit.ann, distance: 0.2), at: 0)
        #expect(run.m.ongoing.repair == .fine)
        run.m.ongoing.person = Kit.john
        run.step(.identified(Kit.john, distance: 0.2), at: 1)
        #expect(run.m.ongoing.repair == .ruptured)
        #expect(run.r.ruptureOwner == Kit.john)
        #expect(Self.notes(run.m).isEmpty, "no sulking on return")
        run.step(Self.apology, at: 2)
        run.step(Self.pet, at: 3)
        #expect(run.m.ongoing.repair == .reconciled)
    }

    @Test func ruptureParkedWhileSomeoneElseTalks() {
        var run = Self.ruptured(mind: Self.cross)
        run.m.ongoing.person = Kit.ann
        let fx = run.step(.identified(Kit.ann, distance: 0.2), at: 100)
        #expect(run.m.ongoing.repair == .fine)
        #expect(run.r.carried == [Kit.john: .ruptured])
        #expect(Self.persisted(fx).count == 1)
        run.step(Kit.heard("hello", Self.appraisal(valence: 0.4)), at: 110)
        #expect(run.m.ongoing.repair == .fine)
        run.m.ongoing.person = Kit.john
        run.step(.identified(Kit.john, distance: 0.2), at: 200)
        #expect(run.m.ongoing.repair == .ruptured)
        #expect(run.r.carried.isEmpty)
    }

    @Test func unknownSpeakersRuptureIsStoredOnceIdentified() {
        var run = Self.ruptured(person: nil, mind: Self.cross)
        run.m.ongoing.person = Kit.john
        let fx = run.step(.identified(Kit.john, distance: 0.2), at: 5)
        #expect(Self.persisted(fx).count == 1)
        #expect(run.r.ruptureOwner == Kit.john)
    }

    @Test func carriedRupturesFollowMergesAndForgets() {
        var rk = RepairKeeper()
        var m = Kit.moment()
        rk.seed(from: Carried(openRepair: [Kit.john: .ruptured]), &m)
        rk.merge(from: Kit.john, into: Kit.ann, &m)
        #expect(rk.carried == [Kit.ann: .ruptured])
        rk.forgetPerson(Kit.ann, &m)
        #expect(rk.carried.isEmpty)
    }

    @Test func activeRuptureFollowsMergeAndForget() {
        var run = Self.ruptured(mind: Self.cross)
        run.r.merge(from: Kit.john, into: Kit.ann, &run.m)
        #expect(run.r.ruptureOwner == Kit.ann)
        run.r.forgetPerson(Kit.ann, &run.m)
        #expect(run.r.ruptureOwner == nil && run.m.ongoing.repair == .fine)
        var all = Self.ruptured(mind: Self.cross)
        all.step(Kit.heard("don't ask me about my job"), at: 3)
        all.m.forgetAll()
        all.r.forgetAll(&all.m)
        #expect(all.r.carried.isEmpty && all.r.bids == 0 && all.r.ruptureOwner == nil)
        all.step(.tick, at: 4)
        #expect(all.r.avoid.isEmpty && all.m.ongoing.repair == .fine)
    }

    // MARK: Conversations

    @Test func newConversationStartsFineButKeepsAnOpenRupture() {
        var run = ReducerRun(RepairKeeper())
        for i in 0..<3 { run.step(.tick, at: Double(i) * 0.1, events: [.deeInterrupted]) }
        #expect(run.m.ongoing.repair == .strained)
        run.step(.conversationStarted(Kit.t0.addingTimeInterval(10)), at: 10)
        #expect(run.m.ongoing.repair == .fine && run.m.ongoing.awkwardness == 0)
        run.step(.tick, at: 1000)
        #expect(Self.notes(run.m).isEmpty)

        var rec = Self.ruptured(mind: Self.cross)
        rec.step(Self.apology, at: 5)
        rec.step(Self.pet, at: 6)
        #expect(rec.m.ongoing.repair == .reconciled)
        rec.m.ongoing.noteCandidates = []          // Cortex clears them before the pipeline
        rec.step(.conversationStarted(Kit.t0.addingTimeInterval(30)), at: 30)
        #expect(rec.m.ongoing.repair == .fine)
        rec.step(.tick, at: 31)
        #expect(Self.notes(rec.m).isEmpty, "the next session is fine, no mention")

        var open = Self.ruptured(mind: Self.cross)
        open.step(.conversationStarted(Kit.t0.addingTimeInterval(30)), at: 30)
        #expect(open.m.ongoing.repair == .ruptured)
    }

    @Test func noTextIsEverStored() {
        var run = ReducerRun(RepairKeeper(), mind: Self.cross)
        run.m.ongoing.person = Kit.john
        var writes: [SelfWrite] = []
        for (i, p) in [Self.insult, Self.insult, Kit.heard("don't ask me about the purple elephant under my bed please"),
                       Self.apology, Self.pet].enumerated() {
            writes += Self.persisted(run.step(p, at: Double(i)))
        }
        for w in writes {
            if case .boundary(let b) = w { #expect(b.topic.words.count <= Subject.maxWords) }
        }
        #expect(run.m.enduring.boundaries.contains { $0.topic.text == "purple elephant" })
    }

    // MARK: Goldens

    @Test func goldenInsultApologyReconcile() throws {
        try Golden.verify(Golden.record(RepairKeeper(), name: "insult-apology-reconcile", mind: Self.cross, [
            Cue(t: 0, p: .identified(Kit.john, distance: 0.2)), Cue(t: 1, p: Self.insult),
            Cue(t: 30, p: .tick), Cue(t: 60, p: Self.apology), Cue(t: 61, p: Self.pet),
            Cue(t: 120, p: .tick), Cue(t: 181, p: .tick), Cue(t: 182, p: .tick),
        ]))
    }

    @Test func goldenSecondInsultBoundary() throws {
        try Golden.verify(Golden.record(RepairKeeper(), name: "second-insult-boundary", mind: Self.cross, [
            Cue(t: 0, p: .tick), Cue(t: 1, p: Self.insult), Cue(t: 60, p: Self.insult), Cue(t: 120, p: Self.insult),
            Cue(t: 200, p: .gesture("thumbsUp")), Cue(t: 400, p: Self.neutral, mind: Self.calm), Cue(t: 600, p: .tick),
        ]))
    }

    @Test func goldenAwkwardness() throws {
        try Golden.verify(Golden.record(RepairKeeper(), name: "awkwardness", [
            Cue(t: 0, p: .deeSaid(tag: .playful, sentence: "x")), Cue(t: 0.5, p: .deeSaid(tag: .playful, sentence: "y")),
            Cue(t: 2, p: Self.neutral),
            Cue(t: 3, p: .deeSaid(tag: .mischievous, sentence: "x")), Cue(t: 5, p: Kit.heard("not funny")),
            Cue(t: 6, p: .deeSaid(tag: .giddy, sentence: "x")), Cue(t: 6.5, p: .deeSaid(tag: .giddy, sentence: "y")),
            Cue(t: 8, p: Kit.heard("hm", Self.appraisal(valence: -0.3))),
            Cue(t: 60, p: .tick), Cue(t: 300, p: .tick), Cue(t: 600, p: .tick),
        ]))
    }

    @Test func goldenDeeInterruptsThreeTimes() throws {
        // Floor events come from FloorKeeper; run the pair through a full Cortex.
        try Golden.verify(Golden.recordCortex(name: "dee-interrupts-three-times", [
            Cue(t: 0, p: .speakingStarted), Cue(t: 0.5, p: .bargeIn),
            Cue(t: 2, p: .speakingStarted), Cue(t: 2.4, p: .bargeIn),
            Cue(t: 4, p: .speakingStarted), Cue(t: 4.3, p: .bargeIn),
            Cue(t: 60, p: .tick), Cue(t: 400, p: .tick), Cue(t: 401, p: .tick),
        ]))
    }

    /// SELF.md §12.4 scenario 7 through the whole Cortex (only the repair slice + stance).
    @Test func goldenCortexInsultApology() throws {
        try Golden.verify(Golden.recordCortex(name: "repair-insult-apology", mind: Self.calm,
                                              reducers: [("repair", RepairKeeper.traceSlice(of:))], [
            Cue(t: 0, p: .presence(arrived: true)), Cue(t: 0.5, p: .identified(Kit.john, distance: 0)),
            Cue(t: 2, p: Self.insult, mind: Self.cross.with(seq: 1)),
            Cue(t: 30, p: Self.insult, mind: Self.cross.with(seq: 2)),
            Cue(t: 60, p: Self.apology), Cue(t: 61, p: Self.pet),
            Cue(t: 62, p: .tick), Cue(t: 190, p: .tick),
        ]))
    }

    @Test func goldenCortexUserBoundary() throws {
        try Golden.verify(Golden.recordCortex(name: "repair-user-boundary", reducers: [("repair", RepairKeeper.traceSlice(of:))], [
            Cue(t: 0, p: .identified(Kit.john, distance: 0)),
            Cue(t: 1, p: Kit.heard("I don't want to talk about my job")),
            Cue(t: 5, p: Kit.heard("you can ask me about my job again")),
            Cue(t: 9, p: Kit.heard("stop asking about money")),
        ]))
    }
}

private extension Note {
    static func deeBoundary(owner: String) -> Note {
        var n = Note.deeBoundary()
        n.owner = owner
        return n
    }
}
