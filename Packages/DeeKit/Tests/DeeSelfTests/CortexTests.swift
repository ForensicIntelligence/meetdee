import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

@Suite struct CortexTests {
    @Test func pipelineOrderIsFixed() {
        #expect(Cortex.pipeline == ["FloorKeeper", "Listener", "Attention", "Interpreter", "RepairKeeper",
                                    "IntentionBoard", "Beats", "EpisodeBuilder", "Learner"])
    }

    @Test func olderSnapshotsAreIgnored() {
        var cx = Kit.cortex(mind: Kit.snap(seq: 5))
        _ = cx.step(.tick, mind: Kit.angry.with(seq: 7), at: Kit.t0.addingTimeInterval(1))
        #expect(cx.moment.ongoing.mind == Kit.angry)
        _ = cx.step(.tick, mind: Kit.happyNeutralRegard.with(seq: 6), at: Kit.t0.addingTimeInterval(2))
        #expect(cx.moment.ongoing.mind == Kit.angry, "seq 6 < 7")
        _ = cx.step(.tick, mind: Kit.happyNeutralRegard.with(seq: 8), at: Kit.t0.addingTimeInterval(3))
        #expect(cx.moment.ongoing.mind == Kit.happyNeutralRegard)
        #expect(cx.moment.seq == 3)
    }

    @Test func clockNeverRunsBackward() {
        var cx = Kit.cortex()
        _ = cx.step(.tick, mind: Kit.snap(), at: Kit.t0.addingTimeInterval(10))
        _ = cx.step(.tick, mind: Kit.snap(), at: Kit.t0.addingTimeInterval(5))
        #expect(cx.moment.now == Kit.t0.addingTimeInterval(10))
    }

    @Test func reflexShowsForFourSecondsAndAsksForASignatureReaction() {
        var cx = Kit.cortex()
        let joke = Kit.angry.with(seq: 1, reflex: .giddy)
        _ = cx.step(Kit.heard("haha"), mind: joke, at: Kit.t0)
        #expect(cx.stance.expression == .giddy)
        let amused = cx.moment.enduring.signature.repertoire[.amused]!.map(\.mannerism)
        #expect(cx.stance.mannerism.map(amused.contains) == true)
        _ = cx.step(.tick, mind: joke.with(seq: 2), at: Kit.t0.addingTimeInterval(2))
        #expect(cx.stance.expression == .giddy)
        #expect(cx.stance.mannerism == nil, "a carried reflex does not re-fire the reaction")
        _ = cx.step(.tick, mind: joke.with(seq: 3), at: Kit.t0.addingTimeInterval(4.1))
        #expect(cx.stance.expression == Kit.angry.emotion, "reflex over after 4 s even if a snapshot still carries it")
        _ = cx.step(.tick, mind: Kit.angry.with(seq: 4), at: Kit.t0.addingTimeInterval(5))
        #expect(cx.moment.momentary.reflex == nil)
    }

    @Test func promptSubmittedPlaysAThinkingMannerism() {
        var cx = Kit.cortex()
        _ = cx.step(.promptSubmitted, mind: Kit.snap(), at: Kit.t0)
        let thinking = cx.moment.enduring.signature.repertoire[.thinking]!.map(\.mannerism)
        #expect(cx.stance.mannerism.map(thinking.contains) == true)
        #expect(cx.stance.expression == .thinking)
        #expect(cx.stance.gaze.target == .away)
        _ = cx.step(.tick, mind: Kit.snap(), at: Kit.t0.addingTimeInterval(0.5))
        #expect(cx.stance.mannerism == nil, "fires once")
    }

    @Test func transcriptTagIsTheReconciledTag() {
        var cx = Kit.cortex(mind: Kit.angry)
        _ = cx.step(.speakingStarted, mind: Kit.angry, at: Kit.t0)
        _ = cx.step(.deeSaid(tag: .happy, sentence: "Hi"), mind: Kit.angry, at: Kit.t0)
        #expect(cx.reconciledTag == .unimpressed)
        #expect(cx.stance.expression == .unimpressed)
        #expect(Projection.voice(cx.stance).emotion == .unimpressed)
    }

    @Test func cueWithoutNotesEqualsTheSnapshotCue() {
        var cx = Kit.cortex()
        let s = Kit.happyNeutralRegard.with(seq: 1)
        _ = cx.step(Kit.heard("hi"), mind: s, at: Kit.t0)
        #expect(cx.cueText(at: Kit.t0) == s.cue)
    }

    @Test func cueConsumesNotesAndMarksIntentionsIssued() {
        let it = Intention(id: UUID(), kind: .followUp, subject: Subject("job interview")!, person: Kit.john, reason: "nervous",
                           notBefore: Kit.t0, expires: Kit.t0.addingTimeInterval(86_400), priority: 0.8, source: "plan", created: Kit.t0)
        var cx = Kit.cortex(carried: Carried(intentions: [it]))
        _ = cx.step(.speakingStarted, mind: Kit.snap(), at: Kit.t0)
        _ = cx.step(.bargeIn, mind: Kit.snap(), at: Kit.t0.addingTimeInterval(3))
        var m = cx.moment
        m.ongoing.noteCandidates.append(.followUp(it.subject, framing: .nervous, intention: it.id))
        cx = Cortex.restoring(cx, moment: m)
        let (cue, fx) = cx.cue(at: Kit.t0.addingTimeInterval(4))
        #expect(cue.contains("(Ask how their job interview went. They were nervous about it.)"))
        #expect(fx == [.persist(.intention(cx.moment.ongoing.intentions[0]))], "IntentionBoard's bookkeeping, persisted")
        #expect(cue.contains("cut off") || cue.contains("cut in"))
        #expect(cx.stance.notes.count == 2)
        #expect(cx.moment.ongoing.noteCandidates.isEmpty)
        #expect(cx.moment.ongoing.intentions[0].status == .issued)
        #expect(cx.moment.ongoing.intentions[0].issuedCount == 1)
        #expect(cx.cue(at: Kit.t0.addingTimeInterval(5)).cue == Kit.snap().cue, "one-shot")
        #expect(cx.stance.notes.isEmpty)
    }

    @Test func conversationStartResetsConversationScope() {
        var cx = Kit.cortex()
        _ = cx.step(Kit.heard("a"), mind: Kit.snap(), at: Kit.t0)
        _ = cx.step(.speakingStarted, mind: Kit.snap(), at: Kit.t0.addingTimeInterval(1))
        _ = cx.step(.bargeIn, mind: Kit.snap(), at: Kit.t0.addingTimeInterval(3))
        #expect(cx.moment.ongoing.turnsThisConversation == 1 && cx.moment.ongoing.cutOff)
        let d = Kit.t0.addingTimeInterval(600)
        _ = cx.step(.conversationStarted(d), mind: Kit.snap(), at: d)
        #expect(cx.moment.ongoing.turnsThisConversation == 0)
        #expect(!cx.moment.ongoing.cutOff)
        #expect(cx.moment.ongoing.noteCandidates.isEmpty)
        #expect(cx.moment.ongoing.conversationStarted == d)
    }

    static func timeline(_ seed: UInt64) -> [(Percept, MindSnapshot, Double)] {
        var rng = Rand(seed: seed)
        var out: [(Percept, MindSnapshot, Double)] = []
        var t = 0.0
        for i in 0..<300 {
            t += rng.double(in: 0.1...2)
            out.append((AgreementPropertyTests.randomPercept(&rng), AgreementPropertyTests.pool[rng.index(AgreementPropertyTests.pool.count)].with(seq: UInt64(i + 1)), t))
        }
        return out
    }

    static func run(seed: UInt64, cortexSeed: UInt64) -> [String] {
        var cx = Kit.cortex(seed: cortexSeed)
        var trace: [String] = []
        for (p, mind, t) in timeline(seed) {
            let fx = cx.step(p, mind: mind, at: Kit.t0.addingTimeInterval(t))
            trace.append("\(cx.stance.expression.rawValue)|\(cx.stance.gaze.target.name)|\(cx.stance.mannerism?.rawValue ?? "-")|\(fx.map(\.traceName))")
            if case .promptSubmitted = p { trace.append(cx.cueText(at: Kit.t0.addingTimeInterval(t))) }
        }
        return trace
    }

    @Test func deterministicReplay() {
        #expect(Self.run(seed: 1, cortexSeed: 7) == Self.run(seed: 1, cortexSeed: 7))
        #expect(Self.run(seed: 1, cortexSeed: 7) != Self.run(seed: 1, cortexSeed: 8), "a different seed changes her")
    }

    // MARK: Random streams (review findings 2e, 16)

    @Test func everyReducerHasItsOwnStream() {
        let cx = Kit.cortex()
        let base = Cortex.baseSeed(cx.moment.enduring.seed, session: 0)
        #expect(cx.streams == Cortex.pipeline.map { Cortex.stream($0, base: base) })
        #expect(Set(cx.streams.map(\.state)).count == Cortex.pipeline.count)
        #expect(!cx.streams.contains(cx.stanceRNG) && !cx.streams.contains(cx.pickerRNG) && cx.stanceRNG != cx.pickerRNG)
        // FloorKeeper draws (thinking aversion) touch only its own stream.
        var c2 = cx
        _ = c2.step(.speakingStarted, mind: Kit.snap(), at: Kit.t0)
        for i in 0..<20 { _ = c2.step(.deeSaid(tag: nil, sentence: "s"), mind: Kit.snap(), at: Kit.t0.addingTimeInterval(Double(i))) }
        #expect(c2.streams[0] != cx.streams[0])
        #expect(Array(c2.streams.dropFirst()) == Array(cx.streams.dropFirst()))
        #expect(c2.stanceRNG == cx.stanceRNG)
    }

    @Test func eachLaunchSessionIsADifferentSequence() {
        let a = Cortex(enduring: Kit.enduring(), mind: Kit.snap(), at: Kit.t0, session: 1)
        let b = Cortex(enduring: Kit.enduring(), mind: Kit.snap(), at: Kit.t0, session: 2)
        #expect(a.streams != b.streams && a.stanceRNG != b.stanceRNG)
        #expect(Cortex(enduring: Kit.enduring(), mind: Kit.snap(), at: Kit.t0, session: 1).streams == a.streams)
    }

    // MARK: Cue effects (finding 1)

    @Test func cueTextQueuesItsEffectsForTheNextStep() {
        let it = IntentionBoardTests.intention("job interview", status: .open, issued: 0)
        var cx = Kit.cortex(carried: Carried(intentions: [it]))
        var m = cx.moment
        m.ongoing.raise(IntentionBoardTests.aim(it), by: "IntentionBoard")
        cx = Cortex.restoring(cx, moment: m)
        let text = cx.cueText(at: Kit.t0)
        #expect(text.contains("job interview"))
        #expect(cx.queuedEffects.map(\.traceName) == ["persist(intention)"])
        let fx = cx.step(.tick, mind: Kit.snap(), at: Kit.t0.addingTimeInterval(1))
        #expect(fx.first?.traceName == "persist(intention)")
        #expect(cx.queuedEffects.isEmpty)
    }

    @Test func aimIsNeverIssuedAThirdTimeAcrossARelaunch() async throws {
        let store = try SelfStore(url: nil)
        let it = IntentionBoardTests.intention("job interview", status: .open, issued: 0)
        try await store.apply(.intention(it))
        for launch in 0..<3 {
            var cx = Cortex(enduring: Kit.enduring(), mind: Kit.snap(), at: Kit.t0, carried: try await store.loadCarried())
            guard let live = cx.moment.ongoing.intentions.first else {
                #expect(launch == 2, "dropped after two issues")
                break
            }
            var m = cx.moment
            if live.issuedCount < Intention.maxIssues { m.ongoing.raise(IntentionBoardTests.aim(live), by: "IntentionBoard") }
            cx = Cortex.restoring(cx, moment: m)
            var writes: [SelfWrite] = []
            for e in cx.cue(at: Kit.t0).effects { if case .persist(let w) = e { writes.append(w) } }
            for e in cx.step(.deeTurnFinished(text: "nice weather"), mind: Kit.snap(), at: Kit.t0.addingTimeInterval(1)) {
                if case .persist(let w) = e { writes.append(w) }
            }
            try await store.apply(writes)
        }
        let stored = try await store.intentions()
        #expect(stored.count == 1 && stored[0].issuedCount == 2 && stored[0].status == .dropped)
    }

    // MARK: Initiative (finding 2a)

    @Test func initiativeRequestBecomesAnInitiativeEffectOnlyWhileIdle() {
        var cx = Kit.cortex()
        var m = cx.moment
        m.momentary.requestInitiative(score: 0.7, aim: .intention(nextAction: "Ask about the guitar.", intention: UUID()), by: "IntentionBoard")
        m.momentary.requestInitiative(score: 0.5, aim: nil, by: "Other")
        #expect(m.momentary.initiative?.owner == "IntentionBoard", "the best score wins")
        cx = Cortex.restoring(cx, moment: m)
        let fx = cx.takeInitiative()
        guard case .initiative(let cue) = fx.first else { Issue.record("no initiative: \(fx)"); return }
        #expect(cue.contains("(Ask about the guitar.)") && cue.hasPrefix(CueWriter.open + CueWriter.mood(Kit.snap())))
        #expect(cx.stance.notes.map(\.kind) == [.intention])
        var busy = Kit.cortex()
        m = busy.moment
        m.momentary.floor = .userSpeaking(since: Kit.t0)
        m.momentary.requestInitiative(score: 0.9, aim: nil, by: "IntentionBoard")
        busy = Cortex.restoring(busy, moment: m)
        #expect(busy.takeInitiative().isEmpty, "never over the user")
        var sad = Kit.cortex()
        m = sad.moment
        m.ongoing.hypotheses = [Hypothesis(kind: .mood, value: "sad", confidence: 0.6, expires: Kit.t0.addingTimeInterval(600))]
        m.momentary.requestInitiative(score: 0.9, aim: .intention(nextAction: "Ask.", intention: UUID()), by: "IntentionBoard")
        sad = Cortex.restoring(sad, moment: m)
        #expect(sad.takeInitiative().isEmpty, "an aim NotePicker would drop is not spoken")
    }

    // MARK: Reflexes (finding 11)

    @Test func sameReflexTwiceRestartsWithAStamp() {
        var cx = Kit.cortex()
        let first = Kit.angry.with(seq: 1, reflex: .giddy, at: Kit.t0)
        _ = cx.step(Kit.heard("haha"), mind: first, at: Kit.t0)
        #expect(cx.moment.momentary.reaction == .amused)
        _ = cx.step(.tick, mind: first.with(seq: 2, reflex: .giddy, at: Kit.t0), at: Kit.t0.addingTimeInterval(1))
        #expect(cx.moment.momentary.reaction == nil, "the same stamp is the same reflex")
        _ = cx.step(Kit.heard("haha again"), mind: first.with(seq: 3, reflex: .giddy, at: Kit.t0.addingTimeInterval(3)),
                    at: Kit.t0.addingTimeInterval(3))
        #expect(cx.moment.momentary.reaction == .amused, "a second joke: a new reaction")
        #expect(cx.moment.momentary.reflex?.until == Kit.t0.addingTimeInterval(3 + Mind.reflexDuration), "and a new 4 s")
        _ = cx.step(.tick, mind: first.with(seq: 4, reflex: .giddy, at: Kit.t0.addingTimeInterval(3)), at: Kit.t0.addingTimeInterval(6.5))
        #expect(cx.stance.expression == .giddy, "still inside the second reflex's 4 s")
        #expect(cx.moment.momentary.reaction == nil)
    }

    // MARK: Hooks and channels

    @Test func conversationStartedHooksResetEachOwnersFields() {
        var cx = Kit.cortex()
        var m = cx.moment
        m.ongoing.followUpsThisConversation = 1
        m.ongoing.revealedThisConversation = true
        m.ongoing.topic = [Subject("guitar")!]
        cx = Cortex.restoring(cx, moment: m)
        _ = cx.step(Kit.heard("a"), mind: Kit.snap(), at: Kit.t0)
        let d = Kit.t0.addingTimeInterval(600)
        _ = cx.step(.conversationStarted(d), mind: Kit.snap(), at: d)
        let o = cx.moment.ongoing
        #expect(o.followUpsThisConversation == 0 && !o.revealedThisConversation && o.topic.isEmpty && o.turnsThisConversation == 0)
        #expect(cx.frozenEnduring == cx.moment.enduring, "frozen after the pipeline")
    }

    @Test func personaRecordsWhoThePromptIsFor() {
        var cx = Kit.cortex()
        #expect(!cx.moment.ongoing.promptRendered)
        _ = cx.persona(Persona(userName: "John"), person: nil, at: Kit.t0)
        #expect(cx.moment.ongoing.promptRendered && cx.moment.ongoing.promptPerson == nil)
        _ = cx.step(.conversationStarted(Kit.t0), mind: Kit.snap(), at: Kit.t0)
        #expect(!cx.moment.ongoing.promptRendered)
    }

    @Test func signalsAreDeliveredExactlyOncePerReader() {
        var m = Kit.moment()
        m.seq = 5
        m.signal("laughter", by: "Interpreter")
        #expect(m.inbox(for: "Learner").map(\.name) == ["laughter"], "later in the pipeline: same step")
        #expect(m.inbox(for: "Listener").isEmpty && m.inbox(for: "Interpreter").isEmpty, "earlier or itself: next step")
        m.seq = 6
        m.momentary.beginStep(seq: 6)
        #expect(m.inbox(for: "Listener").map(\.name) == ["laughter"] && m.inbox(for: "Interpreter").map(\.name) == ["laughter"])
        #expect(m.inbox(for: "Learner").isEmpty, "already delivered")
        m.seq = 7
        m.momentary.beginStep(seq: 7)
        #expect(m.momentary.signals.isEmpty)
    }

    // MARK: Privacy and people (findings 3, 6)

    @Test func forgetSubjectScrubsRAMSoNothingRepersists() {
        let it = IntentionBoardTests.intention("job interview", status: .open, issued: 0, expires: 10)
        let x = Expectation(id: UUID(), person: Kit.john, subject: Subject("job interview")!, due: Kit.t0,
                            expires: Kit.t0.addingTimeInterval(10), framing: .nervous)
        var cx = Kit.cortex(carried: Carried(intentions: [it], expectations: [x], interests: [Interest(subject: Subject("interview")!, weight: 0.5, lastTouched: Kit.t0)]))
        var m = cx.moment
        m.ongoing.raise(.followUp(it.subject, framing: .nervous, intention: it.id), by: "IntentionBoard")
        m.enduring.episodeIndex = [SelfStoreTests.episode(Kit.john, topics: ["job interview"]).key, SelfStoreTests.episode(Kit.john, topics: ["rain"]).key]
        cx = Cortex.restoring(cx, moment: m)
        cx.forget(subject: Subject("interview")!)
        let o = cx.moment.ongoing
        #expect(o.intentions.isEmpty && o.expectations.isEmpty && o.interests.isEmpty && o.noteCandidates.isEmpty)
        #expect(cx.moment.enduring.episodeIndex.map(\.topics) == [[Subject("rain")!]])
        let fx = cx.step(.tick, mind: Kit.snap(), at: Kit.t0.addingTimeInterval(20))
        #expect(fx.isEmpty, "expiry can no longer re-create the forgotten rows")
    }

    @Test func forgetAllKeepsTheSeededSelf() {
        var cx = Kit.cortex(carried: Carried(intentions: [IntentionBoardTests.intention("trip")]))
        var m = cx.moment
        m.enduring.lessons = [Lesson(id: UUID(), person: Kit.john, situation: .moodGuess, createdAt: Kit.t0)]
        m.enduring.profiles[Kit.john] = SocialProfile()
        cx = Cortex.restoring(cx, moment: m)
        cx.forgetAll()
        #expect(cx.moment.enduring == Kit.enduring().keepingSeeded())
        #expect(cx.moment.ongoing.intentions.isEmpty)
        #expect(cx.frozenEnduring == cx.moment.enduring)
    }

    @Test func mergeRepointsAndResolvesClashes() {
        var cx = Kit.cortex(carried: Carried(intentions: [IntentionBoardTests.intention("trip")], openRepair: [Kit.ann: .ruptured]))
        var m = cx.moment
        m.ongoing.person = Kit.ann
        m.enduring.lessons = [Lesson(id: UUID(), person: Kit.ann, situation: .moodGuess, evidence: 2, createdAt: Kit.t0),
                              Lesson(id: UUID(), person: Kit.john, situation: .moodGuess, evidence: 3, createdAt: Kit.t0.addingTimeInterval(9))]
        m.enduring.boundaries = [Boundary(id: UUID(), person: Kit.ann, topic: Subject("job")!, owner: .user, createdAt: Kit.t0)]
        cx = Cortex.restoring(cx, moment: m)
        cx.merge(from: Kit.ann, into: Kit.john)
        #expect(cx.moment.ongoing.person == Kit.john)
        #expect(cx.moment.enduring.lessons.count == 1 && cx.moment.enduring.lessons[0].evidence == 5 && cx.moment.enduring.lessons[0].createdAt == Kit.t0)
        #expect(cx.moment.enduring.boundaries.map(\.person) == [Kit.john])
        #expect(cx.repairKeeper.carried == [Kit.john: .ruptured])
        #expect(SelfBlock.boundaryLine(cx.frozenEnduring, person: Kit.john) == "Don't bring up: job.")
        cx.forgetPerson(Kit.john)
        #expect(cx.moment.ongoing.person == nil && cx.moment.enduring.lessons.isEmpty && cx.moment.enduring.boundaries.isEmpty)
        #expect(cx.moment.ongoing.intentions.isEmpty && cx.repairKeeper.carried.isEmpty)
    }
}

extension MindSnapshot {
    /// Same content, new sequence (and optionally a reflex). Cheap: no re-derivation.
    func with(seq: UInt64, reflex: Emotion? = nil, at: Date? = nil) -> MindSnapshot {
        var s = self
        s.sequence = seq
        if let reflex { s.reflex = reflex }
        if let at { s.reflexAt = at }
        return s
    }
}

extension Cortex {
    /// Test hook: the same Cortex with an edited moment (simulates a later sub-reducer
    /// raising a note).
    static func restoring(_ cx: Cortex, moment: Moment) -> Cortex {
        var c = cx
        c.moment = moment
        return c
    }
}
