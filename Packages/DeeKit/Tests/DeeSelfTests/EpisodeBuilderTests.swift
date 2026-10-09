import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// EpisodeBuilder (SELF.md §7.10, step 0.5.3). Owner: EpisodeBuilder. Goldens: `Fixtures/EpisodeBuilder/`.
@Suite struct EpisodeBuilderTests {
    static func a(valence: Double = 0, warmth: Double = 0, humor: Double = 0, distress: Double = 0, hostility: Double = 0) -> Appraisal {
        var x = Appraisal()
        x.valence = valence
        x.warmth = warmth
        x.humor = humor
        x.distress = distress
        x.hostility = hostility
        return x
    }

    static let warm = a(valence: 0.6, warmth: 0.5)
    static let flat = Appraisal()
    static func s(_ t: String) -> Subject { Subject(t)! }
    static func heard(_ x: Appraisal = flat) -> Percept { Kit.heard("blah", x) }

    /// Persisted episodes in `fx`.
    static func episodes(_ fx: [Effect]) -> [Episode] {
        fx.compactMap { if case .persist(.episode(let e)) = $0 { e } else { nil } }
    }

    static func digests(_ fx: [Effect]) -> [(Int, Int)] {
        fx.compactMap { if case .persist(.digest(_, _, let c, let l)) = $0 { (c, l) } else { nil } }
    }

    /// A run in a conversation with John, started at t = 0.
    static func johnRun(mind: MindSnapshot = Kit.snap()) -> ReducerRun<EpisodeBuilder> {
        var run = ReducerRun(EpisodeBuilder(), mind: mind)
        run.m.ongoing.person = Kit.john
        run.step(.conversationStarted(Kit.t0), at: 0)
        return run
    }

    // MARK: Accumulator, salience, persistence

    @Test func accumulatorHoldsNoTextAndCountsTurns() {
        var run = Self.johnRun()
        #expect(run.step(Kit.heard("I showed you my painting"), at: 1).isEmpty)
        #expect(run.r.userTurns == 1 && run.r.totalTurns == 1)
        #expect(run.r.conversationMindBefore == Kit.snap().code)
        let seg = try! #require(run.r.segment)
        #expect(seg.turns == 1 && seg.person == Kit.john)
        #expect(!String(describing: seg).contains("painting"), "the segment never holds the user's words")
    }

    @Test func salienceFormula() {
        let before = Kit.snap()
        let after = Kit.snap([.affection: 0.9, .trust: 0.8])
        var seg = EpisodeBuilder.Segment(start: Kit.t0, person: Kit.john, mind: before)
        seg.turns = 2
        seg.kindnessSum = 0.6
        seg.surprise = 0.3
        seg.topics = [Self.s("guitar")]
        let base = EpisodeBuilder.episode(from: seg, after: after, index: [], id: UUID())
        let dRegard = abs(after.regard - before.regard) * 2
        #expect(abs(base.salience - (dRegard + 0.3 + EpisodeBuilder.noveltyWeight)) < 1e-9)
        #expect(abs(base.valence - 0.3) < 1e-9, "mean kindness")
        // A topic the index already has is not novel.
        let known = EpisodeKey(id: UUID(), person: nil, end: Kit.t0, topics: [Self.s("guitars")], salience: 1, recalled: 0)
        #expect(abs(EpisodeBuilder.episode(from: seg, after: after, index: [known], id: UUID()).salience - (dRegard + 0.3)) < 1e-9)
        var all = seg
        all.distress = true
        all.laughs = 1
        all.misread = Misread(id: UUID(), person: Kit.john, at: Kit.t0, situation: .tookLiterally)
        all.followUps = [Expectation(id: UUID(), person: Kit.john, subject: Self.s("exam"), due: Kit.t0, expires: Kit.t0,
                                     framing: .nervous, status: .resolved, outcomeValence: 0.8)]
        let full = EpisodeBuilder.episode(from: all, after: after, index: [known], id: UUID())
        let novelExam = EpisodeBuilder.noveltyWeight * 0.5   // "exam" new, "guitar" known
        #expect(abs(full.salience - (dRegard + 0.3 + novelExam + 0.5 + 0.5 + 1 + 1)) < 1e-9)
    }

    @Test func surpriseIsPredictionErrorAgainstKindnessEMA() {
        var run = Self.johnRun()
        var prof = SocialProfile()
        prof.kindnessEMA = 0.5
        run.m.enduring.profiles[Kit.john] = prof
        run.step(Self.heard(Self.a(valence: -0.5, hostility: 0.6)), at: 1)
        let k = Self.a(valence: -0.5, hostility: 0.6).kindness
        #expect(abs(run.r.segment!.surprise - abs(0.5 - k)) < 1e-9)
    }

    @Test func lowSalienceGoesToTheDigestOnly() {
        var run = Self.johnRun()
        run.step(Self.heard(), at: 1)
        let fx = run.step(.conversationStarted(Kit.t0.addingTimeInterval(600)), at: 600)
        #expect(Self.episodes(fx).isEmpty)
        #expect(Self.digests(fx).map { [$0.0, $0.1] } == [[0, 1], [1, 0]], "one low-salience segment, one conversation")
        #expect(run.r.lastEpisode?.salience ?? 1 < EpisodeBuilder.persistThreshold)
        #expect(run.m.enduring.episodeIndex.isEmpty)
    }

    @Test func salientEpisodeIsPersistedAndIndexed() {
        var run = Self.johnRun()
        run.m.ongoing.topic = [Self.s("guitar")]
        run.step(Self.heard(Self.warm), at: 1, mind: Kit.snap([.joy: 0.9]))
        let fx = run.step(.conversationStarted(Kit.t0.addingTimeInterval(600)), at: 600)
        let e = try! #require(Self.episodes(fx).first)
        #expect(e.person == Kit.john && e.topics == [Self.s("guitar")] && e.kind == .conversation)
        #expect(e.gist == "we talked about guitar")
        #expect(e.why == "it made me happy")
        #expect(e.mindBefore == Kit.snap().code && e.mindAfter == Kit.snap([.joy: 0.9]).code)
        #expect(e.salience >= EpisodeBuilder.persistThreshold)
        #expect(run.m.enduring.episodeIndex.map(\.id) == [e.id])
        #expect(run.r.gists[e.id] == e.gist)
        #expect(fx.map(\.traceName) == ["persist(episode)", "persist(digest)"])
        let closed = run.m.momentary.signals.filter { $0.name == "episodeClosed" }
        #expect(closed.map(\.subject) == [Self.s("guitar")] && closed.first?.id == e.id && closed.first?.label == "conversation")
    }

    // MARK: Segmenting

    @Test func topicChangeClosesTheSegment() {
        var run = Self.johnRun()
        run.m.ongoing.topic = [Self.s("guitar")]
        run.step(Self.heard(Self.warm), at: 1)
        run.m.ongoing.topic = [Self.s("guitar"), Self.s("chords")]
        #expect(run.step(Self.heard(), at: 5).isEmpty, "overlapping topics: same segment")
        run.m.ongoing.topic = [Self.s("painting")]
        let fx = run.step(Self.heard(Self.warm), at: 9)
        #expect(!fx.isEmpty, "a disjoint topic closes the open segment")
        #expect(run.r.lastEpisode?.topics == [Self.s("guitar"), Self.s("chords")])
        #expect(run.r.segment?.topics == [Self.s("painting")] && run.r.segment?.turns == 1)
    }

    @Test func speakerChangeClosesTheSegment() {
        var run = Self.johnRun()
        run.step(Self.heard(Self.warm), at: 1)
        run.m.ongoing.person = Kit.ann
        let fx = run.step(Self.heard(), at: 5)
        #expect(!fx.isEmpty)
        #expect(run.r.lastEpisode?.person == Kit.john && run.r.segment?.person == Kit.ann)
    }

    @Test func showBeatChainCompletionClosesTheSegment() {
        var run = Self.johnRun()
        run.step(.sight(camera: .back, things: ["painting"], novel: ["painting"]), at: 1)
        run.step(Self.heard(Self.warm), at: 2)
        run.m.momentary.beat = Beat(kind: .examine, steps: [BeatStep(gaze: .down, duration: 1)], started: Kit.t0.addingTimeInterval(2))
        #expect(run.step(.tick, at: 2.5).isEmpty)
        run.m.momentary.beat = Beat(kind: .brighten, steps: [BeatStep(gaze: .user, duration: 1)], started: Kit.t0.addingTimeInterval(3))
        #expect(run.step(.tick, at: 3.2).isEmpty, "the chain continues")
        let fx = run.step(.tick, at: 4.5)
        #expect(Self.episodes(fx).first?.gist == "they showed me a painting")
        #expect(run.r.segment == nil)
    }

    @Test func segmentWithoutAUserTurnIsDropped() {
        var run = Self.johnRun()
        run.step(.sight(camera: .front, things: ["lamp"], novel: ["lamp"]), at: 1)
        #expect(run.r.segment != nil)
        let fx = run.step(.conversationStarted(Kit.t0.addingTimeInterval(60)), at: 60)
        #expect(fx.isEmpty, "nobody talked: no episode, no conversation")
    }

    @Test func atMostThreeEpisodesPerConversation() {
        var run = Self.johnRun()
        var fx: [Effect] = []
        for (i, t) in ["guitar", "painting", "dogs", "chess", "rain"].enumerated() {
            run.m.ongoing.topic = [Self.s(t)]
            // Rising salience: each turn is a bigger surprise than the last.
            fx += run.step(Self.heard(Self.a(valence: -0.2 * Double(i + 1), hostility: 0.2 * Double(i + 1))), at: Double(10 * i + 1))
        }
        fx += run.step(.conversationStarted(Kit.t0.addingTimeInterval(600)), at: 600)
        let stored = Self.episodes(fx).map(\.id)
        let deleted = fx.compactMap { if case .persist(.deleteEpisode(let id)) = $0 { id } else { nil } }
        let alive = stored.filter { !deleted.contains($0) }
        #expect(alive.count == 3)
        #expect(Set(run.m.enduring.episodeIndex.map(\.id)) == Set(alive))
        #expect(deleted.count == 2, "the two weakest were replaced")
    }

    // MARK: Conversation end, sleep, reflection scheduling

    @Test func conversationEndReflectsAfterFourTurns() {
        var run = Self.johnRun()
        for i in 1...3 { run.step(Self.heard(), at: Double(i)) }
        #expect(!run.step(.conversationStarted(Kit.t0.addingTimeInterval(100)), at: 100).contains(.reflect))
        for i in 1...4 { run.step(Self.heard(), at: 100 + Double(i)) }
        #expect(run.step(.conversationStarted(Kit.t0.addingTimeInterval(200)), at: 200).contains(.reflect))
    }

    @Test func sleepOf300SecondsEndsTheConversationAndReflectsOnce() {
        var run = Self.johnRun()
        run.m.ongoing.topic = [Self.s("guitar")]
        run.step(Self.heard(Self.warm), at: 1, mind: Kit.snap([.joy: 0.9]))
        #expect(run.step(.asleep(true), at: 10).isEmpty)
        #expect(run.step(.tick, at: 200).isEmpty)
        let fx = run.step(.tick, at: 311)
        #expect(fx.map(\.traceName) == ["persist(episode)", "persist(digest)", "reflect"])
        #expect(run.step(.tick, at: 900).isEmpty, "once per sleep")
        run.step(.asleep(false), at: 1000)
        #expect(!run.step(.conversationStarted(Kit.t0.addingTimeInterval(1001)), at: 1001).contains { $0.traceName.hasPrefix("persist") },
                "already closed by the sleep")
    }

    @Test func reflectOncePerSixHoursAwake() {
        var run = Self.johnRun()
        var reflects = 0
        var t = 0.0
        while t < 13 * 3600 {
            t += 120
            reflects += run.step(.tick, at: t).filter { $0 == .reflect }.count
        }
        #expect(reflects == 2)
        // A long gap (app backgrounded) counts only 5 minutes.
        var gap = Self.johnRun()
        gap.step(.tick, at: 1)
        #expect(gap.step(.tick, at: 7 * 3600).isEmpty)
        #expect(gap.r.awake <= EpisodeBuilder.maxAwakeStep + 1)
    }

    // MARK: Gist templates, why / expected / changed

    @Test func followUpEpisode() {
        var run = Self.johnRun()
        let x = Expectation(id: UUID(), person: Kit.john, subject: Self.s("job interview"), due: Kit.t0, expires: Kit.t0.addingTimeInterval(7 * 86_400),
                            framing: .nervous, status: .asked)
        run.m.ongoing.expectations = [x]
        run.step(.tick, at: 1)
        var done = x
        done.status = .resolved
        done.outcomeValence = 0.8
        run.m.ongoing.expectations = [done]
        run.step(Self.heard(Self.warm), at: 2, mind: Kit.snap([.joy: 0.9]))
        let fx = run.step(.conversationStarted(Kit.t0.addingTimeInterval(60)), at: 60)
        let e = try! #require(Self.episodes(fx).first)
        #expect(e.kind == .followUp)
        #expect(e.gist == "they told me how their job interview went")
        #expect(e.expected == "nervous")
        #expect(e.changed == "it went well for them")
        #expect(e.topics.first == Self.s("job interview"))
    }

    @Test func followUpFromSignal() {
        var run = Self.johnRun()
        // Raised by Interpreter (earlier in the pipeline) in the step about to run.
        run.m.momentary.signals.append(Signal("expectationResolved", subject: Self.s("exam"), value: -0.6, id: UUID(),
                                              owner: Interpreter.name, seq: run.m.seq + 1))
        run.step(Self.heard(), at: 1)
        #expect(run.r.segment?.followUps.map(\.subject) == [Self.s("exam")])
        run.step(.conversationStarted(Kit.t0.addingTimeInterval(60)), at: 60)
        #expect(run.r.lastEpisode?.changed == "it didn't go well for them")
    }

    @Test func misreadEpisodeStoresOnlyLexiconLabels() {
        var run = Self.johnRun()
        run.m.ongoing.misreadThisTurn = Misread(id: UUID(), person: Kit.john, at: Kit.t0, situation: .moodGuess, wrongGuess: "sad")
        run.step(Self.heard(), at: 1)
        run.step(.conversationStarted(Kit.t0.addingTimeInterval(60)), at: 60)
        let e = try! #require(run.r.lastEpisode)
        #expect(e.kind == .misread && e.gist == "I misread them: thought they were sad")
        #expect(e.expected == "I thought they were sad" && e.changed == "now I ask how they feel")

        var odd = Self.johnRun()
        odd.m.ongoing.misreadThisTurn = Misread(id: UUID(), person: Kit.john, at: Kit.t0, situation: .moodGuess, wrongGuess: "kind of off today")
        odd.step(Self.heard(), at: 1)
        odd.step(.conversationStarted(Kit.t0.addingTimeInterval(60)), at: 60)
        #expect(odd.r.lastEpisode?.gist == "I misread how they were feeling", "a non-lexicon guess is never stored")
        #expect(odd.r.lastEpisode?.expected == "I thought I understood them")
    }

    @Test func planEpisodeLinksTheOpenLoop() {
        var run = Self.johnRun()
        let x = Expectation(id: UUID(), person: Kit.john, subject: Self.s("exam"), due: Kit.t0.addingTimeInterval(86_400),
                            expires: Kit.t0.addingTimeInterval(8 * 86_400), framing: .nervous)
        let it = Intention(id: UUID(), kind: .followUp, subject: Self.s("exam"), person: Kit.john, reason: "they were nervous about it",
                           notBefore: Kit.t0.addingTimeInterval(93_600), expires: Kit.t0.addingTimeInterval(8 * 86_400), priority: 0.8,
                           source: "plan", created: Kit.t0)
        run.m.ongoing.expectations = [x]
        run.m.ongoing.intentions = [it]
        run.step(Self.heard(Self.a(valence: -0.3, distress: 0.6)), at: 1)
        run.step(.conversationStarted(Kit.t0.addingTimeInterval(60)), at: 60)
        let e = try! #require(run.r.lastEpisode)
        #expect(e.gist == "they told me about their upcoming exam", "no time words: recalled later, 'tomorrow' would be wrong")
        #expect(e.openLoop == it.id)
        #expect(e.salience >= EpisodeBuilder.persistThreshold, "distress + surprise")
    }

    @Test func templatesPerKind() {
        func ep(_ edit: (inout EpisodeBuilder.Segment) -> Void, person: PersonID? = Kit.john) -> Episode {
            var seg = EpisodeBuilder.Segment(start: Kit.t0, person: person, mind: Kit.snap())
            seg.turns = 1
            edit(&seg)
            return EpisodeBuilder.episode(from: seg, after: Kit.snap(), index: [], id: UUID())
        }
        #expect(ep { $0.reconciled = true; $0.topics = [Self.s("dishes")] }.gist == "we made up after talking about dishes")
        #expect(ep { $0.reconciled = true }.kind == .repair)
        #expect(ep { $0.ruptured = true }.gist == "things got tense between us")
        #expect(ep { $0.laughs = 2; $0.topics = [Self.s("cats")] }.gist == "we talked about cats; they laughed a lot")
        #expect(ep { $0.laughs = 2 }.kind == .play)
        #expect(ep { $0.gagTopic = Self.s("toaster") }.gist == "we started a running joke about toaster")
        #expect(ep { $0.seen = [Self.s("owl")] }.gist == "I saw an owl for the first time")
        #expect(ep { $0.seen = [Self.s("owl")] }.kind == .discovery)
        #expect(ep { $0.topics = [Self.s("rain"), Self.s("tea"), Self.s("books")] }.gist == "we talked about rain, tea and books")
        #expect(ep { _ in }.gist == "we chatted for a while")
        #expect(ep({ $0.shown = [Self.s("drawing")] }, person: nil).gist == "someone showed me a drawing", "no name, no person")
        for situation in Lesson.Situation.allCases {
            let e = ep { $0.misread = Misread(id: UUID(), person: Kit.john, at: Kit.t0, situation: situation) }
            #expect(e.kind == .misread && e.gist.count <= Episode.maxGist)
            for p in [e.expected, e.changed].compactMap({ $0 }) {
                #expect(p.split(separator: " ").count <= 8 && p.count <= 60, "\(p)")
            }
        }
        let long = ep { $0.topics = [Self.s("very long topic name"), Self.s("another long topic name"), Self.s("third quite long topic")] }
        #expect(long.gist.count <= Episode.maxGist)
    }

    @Test func whyFromTheLargestFeelingDelta() {
        func why(_ after: MindSnapshot, _ edit: (inout EpisodeBuilder.Segment) -> Void = { _ in }) -> String? {
            var seg = EpisodeBuilder.Segment(start: Kit.t0, person: Kit.john, mind: Kit.snap())
            seg.turns = 1
            edit(&seg)
            return EpisodeBuilder.episode(from: seg, after: after, index: [], id: UUID()).why
        }
        #expect(why(Kit.snap([.joy: 0.9])) == "it made me happy")
        #expect(why(Kit.snap([.joy: 0.9])) { $0.laughs = 1 } == "they made me laugh")
        #expect(why(Kit.snap([.sadness: 0.5])) { $0.distress = true } == "I was worried for them")
        #expect(why(Kit.snap([.sadness: 0.5])) == "it made me a little sad")
        #expect(why(Kit.snap([.anger: 0.6, .joy: 0.45])) == "it made me cross")
        #expect(why(Kit.snap([.affection: 0.55])) == "I felt closer to them", "slow feelings weigh more")
        #expect(why(Kit.snap([.interest: 0.9, .joy: 0.55])) == "I found it really interesting")
        #expect(why(Kit.snap()) == nil, "no change, no reason")
        #expect(why(Kit.snap([.joy: 0.9])) { $0.shown = [Self.s("painting")]; $0.kindnessSum = 0.5 } == "they seemed proud")
    }

    // MARK: Recall

    /// One stored episode about the painting, a conversation ago, gist known.
    static func recallRun(person: PersonID? = Kit.john, salience: Double = 0.9, endedDaysAgo: Double = 1,
                          keyPerson: PersonID? = Kit.john) -> (ReducerRun<EpisodeBuilder>, Episode) {
        var run = ReducerRun(EpisodeBuilder())
        let now = Kit.t0.addingTimeInterval(endedDaysAgo * 86_400)
        var ep = SelfStoreTests.episode(keyPerson, topics: ["painting"], gist: "they showed me a painting")
        ep.salience = salience
        ep.end = Kit.t0
        run.r.prefetch([ep], &run.m)
        run.m.ongoing.person = person
        run.m.ongoing.conversationStarted = now
        run.step(.conversationStarted(now), at: endedDaysAgo * 86_400)
        return (run, ep)
    }

    @Test func recallRaisesNoteBeatAndSignal() {
        var (run, ep) = Self.recallRun()
        let t = 86_400.0 + 5
        run.m.ongoing.topic = [Self.s("painting")]
        run.step(Self.heard(Self.warm), at: t)
        #expect(run.m.ongoing.noteCandidates == [Note(.recall, slots: ["they showed me a painting"], episode: ep.id, owner: EpisodeBuilder.name)])
        // Review finding 6: the face waits for the words (beat and signal at issue).
        #expect(run.m.momentary.beatRequests.isEmpty && !run.m.momentary.signals.contains { $0.name == "recallHit" })
        // Issued: counted, persisted, and on cooldown for 4 turns / 2 days.
        let fx = run.issue(run.m.ongoing.noteCandidates[0])
        #expect(run.m.momentary.beatRequests.map(\.kind) == [.recognize])
        let hit = run.m.momentary.signals.first { $0.name == "recallHit" }
        #expect(hit?.id == ep.id && hit?.subject == Self.s("painting"))
        #expect(abs((hit?.value ?? 0) - EpisodeBuilder.recallScore(ep.key, query: [Self.s("painting")], at: Kit.t0.addingTimeInterval(t))) < 1e-12)
        #expect(fx == [.persist(.recalled(episode: ep.id, at: run.m.now))])
        #expect(run.m.enduring.episodeIndex[0].recalled == 1)
        run.m.ongoing.noteCandidates = []
        run.m.momentary.beatRequests = []
        for i in 1...5 { run.step(Self.heard(), at: t + Double(i)) }
        #expect(run.m.ongoing.noteCandidates.isEmpty, "same episode within 2 days")
        run.m.ongoing.conversationStarted = Kit.t0.addingTimeInterval(4 * 86_400)
        run.step(.conversationStarted(run.m.ongoing.conversationStarted), at: 4 * 86_400)
        run.step(Self.heard(), at: 4 * 86_400 + 1)
        #expect(run.m.ongoing.noteCandidates.map(\.kind) == [.recall], "after the cooldown")
        run.issue(run.m.ongoing.noteCandidates[0])
        #expect(run.m.momentary.beatRequests.map(\.kind) == [.recognize], "a new conversation may recognise it again")
    }

    @Test func recallSpacingOfFourTurns() {
        var (run, ep) = Self.recallRun()
        var other = ep
        other.id = UUID()
        other.gist = "we talked about painting"
        run.r.prefetch([other], &run.m)
        run.m.ongoing.topic = [Self.s("painting")]
        run.step(Self.heard(), at: 86_401)
        run.issue(run.m.ongoing.noteCandidates[0])
        var raised: [Int] = []
        for i in 1...6 {
            run.m.ongoing.noteCandidates = []
            run.step(Self.heard(), at: 86_401 + Double(i))
            if !run.m.ongoing.noteCandidates.isEmpty { raised.append(i) }
        }
        #expect(raised.first == 4, "the other episode only after 4 more turns")
    }

    @Test func recallGates() {
        // Another person's episode is not recalled; nor one of nobody in particular to an
        // identified person (review finding 12), only while nobody is identified.
        var (ann, _) = Self.recallRun(person: Kit.ann)
        ann.m.ongoing.topic = [Self.s("painting")]
        ann.step(Self.heard(), at: 86_401)
        #expect(ann.m.ongoing.noteCandidates.isEmpty)
        var (global, _) = Self.recallRun(person: Kit.ann, keyPerson: nil)
        global.m.ongoing.topic = [Self.s("painting")]
        global.step(Self.heard(), at: 86_401)
        #expect(global.m.ongoing.noteCandidates.isEmpty)
        var (anon, _) = Self.recallRun(person: nil, keyPerson: nil)
        anon.m.ongoing.topic = [Self.s("painting")]
        anon.step(Self.heard(), at: 86_401)
        #expect(anon.m.ongoing.noteCandidates.count == 1)
        // Below the threshold: weak or old.
        var (weak, _) = Self.recallRun(salience: 0.3)
        weak.m.ongoing.topic = [Self.s("painting")]
        weak.step(Self.heard(), at: 86_401)
        #expect(weak.m.ongoing.noteCandidates.isEmpty)
        var (old, _) = Self.recallRun(endedDaysAgo: 60)
        old.m.ongoing.topic = [Self.s("painting")]
        old.step(Self.heard(), at: 60 * 86_400 + 1)
        #expect(old.m.ongoing.noteCandidates.isEmpty, "0.9 × e^−2 < 0.35")
        // Unrelated topic.
        var (off, _) = Self.recallRun()
        off.m.ongoing.topic = [Self.s("cooking")]
        off.step(Self.heard(), at: 86_401)
        #expect(off.m.ongoing.noteCandidates.isEmpty)
    }

    @Test func recallByWhatIsShown() {
        var (run, ep) = Self.recallRun()
        run.step(.sight(camera: .back, things: ["painting"], novel: ["painting"]), at: 86_401)
        #expect(run.m.ongoing.noteCandidates.first?.episode == ep.id, "shown a painting: recognise before anyone speaks")
        run.issue(run.m.ongoing.noteCandidates[0])
        #expect(run.m.momentary.beatRequests.map(\.kind) == [.recognize])
    }

    /// Review finding 12: quarrels, misreads and sad memories are never recall material.
    @Test func quarrelsMisreadsAndSadMemoriesAreNotRecalled() {
        for (kind, valence) in [(Episode.Kind.repair, 0.0), (.misread, 0.0), (.conversation, -0.5)] {
            var run = ReducerRun(EpisodeBuilder())
            var ep = SelfStoreTests.episode(Kit.john, topics: ["money"], gist: "things got tense between us about money")
            ep.kind = kind
            ep.valence = valence
            ep.salience = 0.9
            ep.end = Kit.t0
            run.r.prefetch([ep], &run.m)
            run.m.ongoing.person = Kit.john
            run.m.ongoing.topic = [Self.s("money")]
            run.step(Self.heard(), at: 86_401)
            #expect(run.m.ongoing.noteCandidates.isEmpty, "\(kind) \(valence)")
        }
    }

    @Test func thisConversationsEpisodesAreNotRecalled() {
        var run = Self.johnRun()
        run.m.ongoing.topic = [Self.s("guitar")]
        run.step(Self.heard(Self.warm), at: 1, mind: Kit.snap([.joy: 0.9]))
        run.m.ongoing.topic = [Self.s("painting")]
        run.step(Self.heard(Self.warm), at: 2)
        #expect(run.m.enduring.episodeIndex.count == 1)
        run.m.ongoing.topic = [Self.s("guitar")]
        run.m.ongoing.noteCandidates = []
        run.step(Self.heard(), at: 3)
        #expect(!run.m.ongoing.noteCandidates.contains { $0.kind == .recall })
    }

    @Test func recallScoreFormula() {
        let k = EpisodeKey(id: UUID(), person: nil, end: Kit.t0, topics: [Self.s("job interview"), Self.s("nerves")], salience: 0.8, recalled: 0)
        let now = Kit.t0.addingTimeInterval(3 * 86_400)
        let s = EpisodeBuilder.recallScore(k, query: [Self.s("interview")], at: now)
        #expect(abs(s - 0.5 * 0.8 * exp(-3.0 / 30)) < 1e-12, "jaccard 1/2 (plural- and word-tolerant match)")
        var worn = k
        worn.recalled = 3
        #expect(abs(EpisodeBuilder.recallScore(worn, query: [Self.s("interview")], at: now) - s / 2) < 1e-12)
        #expect(EpisodeBuilder.recallScore(k, query: [Self.s("dog")], at: now) == 0)
    }

    // MARK: Hooks and privacy

    @Test func issuedRecallIsCountedAndPersisted() {
        var run = ReducerRun(EpisodeBuilder())
        let ep = SelfStoreTests.episode(nil)
        run.m.enduring.episodeIndex = [ep.key]
        run.m.now = Kit.t0.addingTimeInterval(5)
        let fx = run.issue(.recall(gist: "x", episode: ep.id))
        #expect(run.m.enduring.episodeIndex[0].recalled == 1)
        #expect(fx == [.persist(.recalled(episode: ep.id, at: Kit.t0.addingTimeInterval(5)))])
        #expect(run.issue(.reunion()).isEmpty)
    }

    @Test func forgetSubjectScrubsTheSegmentAndGists() {
        var run = Self.johnRun()
        run.m.ongoing.topic = [Self.s("guitar")]
        run.step(Self.heard(Self.warm), at: 1, mind: Kit.snap([.joy: 0.9]))
        run.m.ongoing.topic = [Self.s("job interview")]
        run.step(Self.heard(Self.warm), at: 2)
        let guitarEpisode = run.m.enduring.episodeIndex[0].id
        run.m.forget(subject: Self.s("interview"))
        run.r.forget(subject: Self.s("interview"), &run.m)
        #expect(run.r.segment?.topics == [])
        run.m.forget(subject: Self.s("guitar"))
        run.r.forget(subject: Self.s("guitar"), &run.m)
        #expect(run.r.gists[guitarEpisode] == nil)
        #expect(run.r.lastEpisode == nil)
    }

    @Test func forgetPersonMergeAndForgetAll() {
        var run = Self.johnRun()
        run.step(Self.heard(Self.warm), at: 1)
        run.r.merge(from: Kit.john, into: Kit.ann, &run.m)
        #expect(run.r.segment?.person == Kit.ann)
        run.r.forgetPerson(Kit.ann, &run.m)
        #expect(run.r.segment == nil)
        run.m.ongoing.person = Kit.john
        run.m.ongoing.topic = [Self.s("guitar")]
        run.step(Self.heard(Self.warm), at: 2, mind: Kit.snap([.joy: 0.9]))
        run.step(.conversationStarted(Kit.t0.addingTimeInterval(60)), at: 60)
        #expect(!run.r.gists.isEmpty)
        run.m.forgetAll()
        run.r.forgetAll(&run.m)
        #expect(run.r.gists.isEmpty && run.r.segment == nil && run.r.lastEpisode == nil && run.r.recalledAt.isEmpty)
    }

    @Test func noUserTextReachesAnyPersistedEffect() {
        var rng = Rand(seed: 99)
        let words = ["purple", "elephant", "quantum", "banjo", "lighthouse", "marmalade", "zeppelin", "origami", "nebula", "walrus"]
        var run = Self.johnRun()
        var fx: [Effect] = []
        var said: [String] = []
        for i in 0..<200 {
            let text = (0..<8).map { _ in words[rng.index(words.count)] }.joined(separator: " ")
            said.append(text)
            run.m.ongoing.topic = [Self.s(words[i % words.count])]
            fx += run.step(Kit.heard(text, Self.a(valence: rng.double(in: -1...1), humor: rng.unit(), distress: rng.unit())), at: Double(i * 10 + 1),
                           mind: Kit.snap([.joy: rng.unit(), .affection: rng.unit()]))
            if i % 37 == 0 { fx += run.step(.conversationStarted(Kit.t0.addingTimeInterval(Double(i * 10 + 5))), at: Double(i * 10 + 5)) }
        }
        let stored = fx.compactMap { e -> String? in if case .persist(let w) = e { String(describing: w) } else { nil } }.joined(separator: "\n")
        for text in said {
            for gram in PolicyTests.windows(text) { #expect(!stored.contains(gram)) }
        }
        #expect(!stored.isEmpty)
    }

    @Test func dayStringsAreUTCCalendarDays() {
        #expect(EpisodeBuilder.day(Kit.t0) == "2026-09-21")
        #expect(EpisodeBuilder.day(Kit.t0.addingTimeInterval(86_399)) == "2026-09-21")
        #expect(EpisodeBuilder.day(Kit.t0.addingTimeInterval(86_400 * 102)) == "2027-01-01")
        #expect(EpisodeBuilder.day(Date(timeIntervalSince1970: 951_782_400)) == "2000-02-29")
        #expect(Reflector.dayNumber("2026-09-21").map { Double($0) * 86_400 } == Kit.t0.timeIntervalSince1970)
    }

    @Test func deterministicReplay() {
        func run() -> [String] {
            var r = Self.johnRun()
            var out: [String] = []
            for (i, t) in ["guitar", "painting", "guitar"].enumerated() {
                r.m.ongoing.topic = [Self.s(t)]
                out += r.step(Self.heard(Self.warm), at: Double(i + 1), mind: Kit.snap([.joy: 0.5 + 0.1 * Double(i)])).map { String(describing: $0) }
            }
            out += r.step(.conversationStarted(Kit.t0.addingTimeInterval(99)), at: 99).map { String(describing: $0) }
            return out
        }
        #expect(run() == run())
    }

    // MARK: Whole pipeline

    @Test func cortexPersistsAnEpisodeAtConversationEnd() {
        var cx = Kit.cortex()
        let joyful = Kit.snap([.joy: 0.9])
        var fx = cx.step(.conversationStarted(Kit.t0), mind: Kit.snap(), at: Kit.t0)
        fx += cx.step(.sight(camera: .back, things: ["painting"], novel: ["painting"]), mind: Kit.snap(), at: Kit.t0.addingTimeInterval(1))
        fx += cx.step(Kit.heard("look what I made", Self.warm), mind: joyful, at: Kit.t0.addingTimeInterval(2))
        for t in stride(from: 2.5, to: 30, by: 0.5) { fx += cx.step(.tick, mind: joyful, at: Kit.t0.addingTimeInterval(t)) }
        fx += cx.step(.conversationStarted(Kit.t0.addingTimeInterval(900)), mind: joyful, at: Kit.t0.addingTimeInterval(900))
        let e = try! #require(Self.episodes(fx).first)
        #expect(e.gist == "someone showed me a painting" && e.kind == .shared && e.why == "they seemed proud")
        #expect(cx.moment.enduring.episodeIndex.contains { $0.id == e.id })
    }

    // MARK: Goldens

    @Test func goldenShownACreation() throws {
        let joyful = Kit.snap([.joy: 0.9, .interest: 0.8])
        try Golden.verify(Golden.record(EpisodeBuilder(), name: "shown-a-creation", [
            Cue(t: 0, p: .conversationStarted(Kit.t0)),
            Cue(t: 1, p: .sight(camera: .back, things: ["painting"], novel: ["painting"])),
            Cue(t: 2, p: Kit.heard("look what I made", Self.warm), mind: joyful),
            Cue(t: 3, p: .sound(label: "laughter", unexpected: false)),
            Cue(t: 4, p: Kit.heard("thanks!", Self.warm)),
            Cue(t: 600, p: .conversationStarted(Kit.t0.addingTimeInterval(600))),
            Cue(t: 601, p: .sight(camera: .back, things: ["painting"], novel: ["painting"])),
        ]))
    }

    @Test func goldenSleepAndReflect() throws {
        let fond = Kit.snap([.joy: 0.8, .affection: 0.6])
        try Golden.verify(Golden.record(EpisodeBuilder(), name: "sleep-reflect", [
            Cue(t: 0, p: .conversationStarted(Kit.t0)),
            Cue(t: 1, p: Kit.heard("hi", Self.warm)),
            Cue(t: 5, p: .touch(kind: "pet", gentle: true, at: nil), mind: fond),
            Cue(t: 6, p: Kit.heard("good robot", Self.a(valence: 0.8, warmth: 0.8))),
            Cue(t: 7, p: Kit.heard("bye", Self.flat)),
            Cue(t: 8, p: Kit.heard("night", Self.flat)),
            Cue(t: 20, p: .asleep(true)),
            Cue(t: 200, p: .tick),
            Cue(t: 330, p: .tick),
            Cue(t: 1000, p: .tick),
            Cue(t: 1200, p: .asleep(false)),
            Cue(t: 1201, p: .conversationStarted(Kit.t0.addingTimeInterval(1201))),
        ]))
    }
}
