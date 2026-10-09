import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// Attention (SELF.md §7.3, step 0.5.4). Owner: Attention. Goldens: `Fixtures/Attention/`.
@Suite struct AttentionTests {
    static let guitar = Subject("guitar")!
    static let lamp = Subject("lamp")!
    static let mug = Subject("mug")!

    static func notes(_ run: ReducerRun<Attention>) -> [Note.Kind] { run.m.ongoing.noteCandidates.map(\.kind) }

    static func referent(_ s: Subject, _ run: ReducerRun<Attention>) -> Referent? {
        run.m.momentary.referents.first { $0.subject == s }
    }

    // MARK: Head pose, mutual gaze, engagement

    @Test func headPoseAndMutualGaze() {
        var run = ReducerRun(Attention())
        run.step(.head(yaw: 5, pitch: 0), at: 0)
        #expect(run.m.momentary.mutualGazeSince == Kit.t0)
        #expect(!Attention.mutualGaze(run.m), "not held 1 s yet")
        run.step(.head(yaw: 8, pitch: -2), at: 1)
        #expect(run.m.momentary.mutualGazeSince == Kit.t0, "held")
        #expect(Attention.mutualGaze(run.m))
        run.step(.head(yaw: 40, pitch: 0), at: 2)
        #expect(run.m.momentary.mutualGazeSince == nil)
        run.step(.head(yaw: 0, pitch: -20), at: 3)
        #expect(run.m.momentary.mutualGazeSince == nil, "looking down")
        run.step(.faceLost, at: 4)
        #expect(run.m.momentary.headYaw == nil)
        #expect(!Attention.mutualGaze(run.m))
    }

    @Test func engagementSignalIsEdgeTriggered() {
        var run = ReducerRun(Attention())
        func engaged() -> [Double] { run.m.momentary.signals.filter { $0.name == "engaged" && $0.seq == run.m.seq }.map(\.value) }
        run.step(.head(yaw: 0, pitch: 0), at: 0)
        #expect(engaged().isEmpty, "mutual gaze not held yet")
        run.step(.tick, at: 1.1)
        #expect(engaged() == [1])
        run.step(.tick, at: 1.6)
        #expect(engaged().isEmpty, "only on change")
        run.step(.head(yaw: 50, pitch: 0), at: 2)
        #expect(engaged() == [0])
        // Speech within 10 s engages even without gaze.
        run.step(.partial("hey"), at: 3)
        #expect(engaged() == [1])
        run.step(.head(yaw: 50, pitch: 0), at: 12)
        #expect(engaged().isEmpty)
        run.step(.head(yaw: 50, pitch: 0), at: 13.5)
        #expect(engaged() == [0], "10 s after speech, looking away")
    }

    @Test func facePresenceSubstitutesWhenNoYaw() {
        var run = ReducerRun(Attention())
        run.step(.presence(arrived: true), at: 0)
        let e = run.m.momentary.signals.filter { $0.name == "engaged" }.map(\.value)
        #expect(e == [1], "no head pose has arrived: presence substitutes")
        run.step(.faceLost, at: 1)
        run.step(.tick, at: 3.5)
        #expect(run.m.momentary.signals.filter { $0.name == "engaged" && $0.seq == run.m.seq }.map(\.value) == [0], "3 s after the face")
    }

    // MARK: Focus

    @Test func focusBasics() {
        var run = ReducerRun(Attention())
        run.m.ongoing.person = Kit.john
        run.step(.presence(arrived: true), at: 0)
        #expect(run.m.momentary.focus == .person(Kit.john))
        #expect(run.m.momentary.reaction == .greeting)
        #expect(run.m.momentary.mannerismRequests == [MannerismRequest(.signature(.greeting), rank: .reaction, owner: "Attention")])
        run.step(.sound(label: "doorbell", unexpected: true), at: 1)
        #expect(run.m.momentary.focus == .person(Kit.john), "incumbent younger than 1.5 s: no switch")
        run.step(.sound(label: "doorbell", unexpected: true), at: 2)
        #expect(run.m.momentary.focus == .sound(Subject("doorbell")!), "0.8 beats the decayed face (0.31 + 0.3 + 0.15)")
        #expect(run.m.momentary.reaction == nil, "requests are per step")
        run.step(.tick, at: 4)
        #expect(run.m.momentary.focus == .sound(Subject("doorbell")!))
        run.step(.tick, at: 5.5)
        #expect(run.m.momentary.focus == .none, "sound focus lapses after 3 s")
        run.step(.touch(kind: "tap", gentle: true, at: SIMD2(0.1, 0.2)), at: 5.6)
        #expect(run.m.momentary.focus == .touch(SIMD2(0.1, 0.2)), "touch preempts at once")
        run.step(.sound(label: "dog", unexpected: true), at: 5.8)
        #expect(run.m.momentary.focus == .touch(SIMD2(0.1, 0.2)), "a live touch keeps focus")
        run.step(.tick, at: 7)
        #expect(run.m.momentary.focus == .none)
        run.m.momentary.floor = .userSpeaking(since: Kit.t0)
        run.step(.sound(label: "dog", unexpected: true), at: 9)
        #expect(run.m.momentary.focus == .none, "not while the user talks")
        run.step(.partial("hey"), at: 9.1)
        #expect(run.m.momentary.focus == .person(Kit.john), "speech preempts at once")
    }

    @Test func speechPreemptsAFreshReferent() {
        var run = ReducerRun(Attention())
        run.step(.sight(camera: .back, things: ["guitar"], novel: ["guitar"]), at: 0)
        #expect(run.m.momentary.focus == .referent(Self.guitar, .back), "from none a novel sight takes focus")
        run.step(.partial("so"), at: 0.2)
        #expect(run.m.momentary.focus == .person(nil))
    }

    @Test func challengerNeedsTheMarginAndAge() {
        var run = ReducerRun(Attention())
        run.step(.sight(camera: .back, things: ["guitar"], novel: ["guitar"]), at: 0)
        #expect(run.m.momentary.focus == .referent(Self.guitar, .back))
        // An equally novel lamp 2 s later: 0.6 vs guitar 0.6·(2·0.47)+0.3+0.15 — no switch.
        run.step(.sight(camera: .back, things: ["lamp"], novel: ["lamp"]), at: 2)
        #expect(run.m.momentary.focus == .referent(Self.guitar, .back), "hysteresis: same-strength challenger loses")
        // A strong interest makes the lamp worth ×2: 1.2 > 0.56 + 0.45.
        run.m.ongoing.interests = [Interest(subject: Self.mug, weight: 1, lastTouched: Kit.t0)]
        run.step(.sight(camera: .front, things: ["mug"], novel: ["mug"]), at: 2.5)
        #expect(run.m.momentary.focus == .referent(Self.mug, .front))
        // …but not twice within 1.5 s, however strong.
        run.m.ongoing.interests.append(Interest(subject: Self.lamp, weight: 1, lastTouched: Kit.t0))
        run.step(.sight(camera: .back, things: ["lamp"], novel: ["lamp"]), at: 3)
        #expect(run.m.momentary.focus == .referent(Self.mug, .front), "incumbent < 1.5 s old")
    }

    /// §12.1: random sight noise at 2 Hz → at most one focus change per 1.5 s.
    @Test func hysteresisUnderRandomSightNoise() {
        for seed in UInt64(1)...40 {
            var rng = Rand(seed: seed)
            var run = ReducerRun(Attention(), seed: seed)
            var changes: [Double] = []
            var last = run.m.momentary.focus
            let labels = ["guitar", "lamp", "cat", "mug", "plant", "book"]
            for i in 0..<600 {
                let t = Double(i) * 0.5
                let p: Percept
                if rng.chance(0.8) {
                    let things = labels.filter { _ in rng.chance(0.4) }
                    p = .sight(camera: rng.chance(0.5) ? .front : .back, things: things, novel: things.filter { _ in rng.chance(0.5) })
                } else {
                    p = .tick
                }
                run.step(p, at: t)
                if run.m.momentary.focus != last {
                    changes.append(t)
                    last = run.m.momentary.focus
                }
            }
            #expect(changes.count > 3, "seed \(seed): the noise does move focus sometimes")
            for (a, b) in zip(changes, changes.dropFirst()) {
                #expect(b - a >= Attention.minFocusAge, "seed \(seed): focus changed at \(a) and \(b)")
            }
        }
    }

    @Test func referentFocusLapsesAsSalienceFades() {
        var run = ReducerRun(Attention())
        run.step(.sight(camera: .back, things: ["guitar"], novel: ["guitar"]), at: 0)
        run.step(.tick, at: 30)
        #expect(run.m.momentary.focus == .referent(Self.guitar, .back), "0.5 → 0.18")
        run.step(.tick, at: 50)
        #expect(run.m.momentary.focus == .none, "below 0.1")
    }

    // MARK: Gaze

    @Test func gazeRequestsForTouchSoundAndBackReferent() {
        var run = ReducerRun(Attention())
        run.step(.sound(label: "doorbell", unexpected: true), at: 0)
        #expect(run.m.momentary.gazeRequests == [GazeRequest(.side(Stance.soundSide(Subject("doorbell")!)), hold: 1.2, priority: .focus, owner: "Attention")])
        run.step(.touch(kind: "pet", gentle: true, at: SIMD2(0.4, 0.6)), at: 1)
        #expect(run.m.momentary.gazeRequests.map(\.priority) == [.touch])
        #expect(Stance.gaze(run.m.momentary.gazeRequests).target == .point(SIMD2(0.4, 0.6)))
        run.step(.tick, at: 2.5)
        #expect(run.m.momentary.gazeRequests.isEmpty, "touch over, focus none")
        run.m.momentary.focus = .referent(Self.guitar, .back)
        run.m.momentary.referents = [Referent(subject: Self.guitar, camera: .back, sources: [.sawBack], salience: 0.9, lastSeen: Kit.t0)]
        run.step(.tick, at: 3)
        #expect(run.m.momentary.gazeRequests.map(\.target) == [.examineBack])
    }

    @Test func triadicJointAttentionAfterAMention() {
        var run = ReducerRun(Attention())
        run.step(.sight(camera: .back, things: ["guitar"], novel: ["guitar"]), at: 0)
        run.step(Kit.heard("I just tuned my guitar"), at: 1)
        func joint() -> GazeIntent.Target? {
            run.m.momentary.gazeRequests.last { $0.priority == .jointAttention }?.target
        }
        #expect(joint() == .user, "0–0.3 s: the user")
        run.step(.tick, at: 1.5)
        #expect(joint() == .examineBack, "0.3–1.5 s: the referent")
        #expect(Stance.gaze(run.m.momentary.gazeRequests).target == .examineBack)
        run.step(.tick, at: 2.7)
        #expect(joint() == .user, "then back to the user and hold")
        run.step(.tick, at: 4.1)
        #expect(joint() == nil, "the triad is over")
    }

    @Test func triadNeverLooksAwayMidTurnAndYieldsToSound() {
        var run = ReducerRun(Attention())
        run.step(.sight(camera: .back, things: ["guitar"], novel: ["guitar"]), at: 0)
        run.step(Kit.heard("my guitar"), at: 1)
        run.m.momentary.floor = .userSpeaking(since: Kit.t0)
        run.step(.tick, at: 1.5)
        #expect(!run.m.momentary.gazeRequests.contains { $0.priority == .jointAttention }, "no referent glance while the user speaks")
        run.m.momentary.floor = .idle
        run.step(Kit.heard("the guitar"), at: 10)
        run.step(.sound(label: "siren", unexpected: true), at: 12)
        if case .sound = run.m.momentary.focus {
            #expect(!run.m.momentary.gazeRequests.contains { $0.priority == .jointAttention }, "a sound focus ends the triad")
        }
    }

    @Test func frontReferentTriadLooksStraightAhead() {
        var run = ReducerRun(Attention())
        run.step(.presence(arrived: true), at: 0)
        run.step(.faceLost, at: 1)
        run.step(.sight(camera: .front, things: ["mug"], novel: ["mug"]), at: 1.5)
        run.step(.tick, at: 2)
        #expect(run.m.momentary.gazeRequests.contains { $0.priority == .jointAttention && $0.target == .point(Attention.frontReferentPoint) })
    }

    // MARK: Referents and common ground

    @Test func referentsBumpDecayAndCap() {
        var run = ReducerRun(Attention())
        run.step(.sight(camera: .back, things: ["guitar", "lamp"], novel: ["guitar"]), at: 0)
        #expect(run.m.momentary.referents.map(\.subject.text) == ["guitar", "lamp"])
        #expect(run.m.momentary.referents[0].salience == 0.5)
        #expect(run.m.momentary.referents[1].salience == 0.15)
        run.step(.tick, at: 20)
        #expect(abs(run.m.momentary.referents[0].salience - 0.25) < 1e-9, "20 s half-life")
        for i in 0..<20 { run.step(.sight(camera: .front, things: ["thing\(i)x"], novel: ["thing\(i)x"]), at: 21 + Double(i) * 0.01) }
        #expect(run.m.momentary.referents.count == Attention.maxReferents)
        #expect(run.m.momentary.referents.last?.subject.text == "thing19x")
    }

    @Test func mentionBumpsAndSharesPluralTolerant() {
        var run = ReducerRun(Attention())
        run.step(.sight(camera: .back, things: ["guitar", "lamp"], novel: []), at: 0)
        #expect(Self.referent(Self.guitar, run)?.sharedWithUser == false)
        #expect(Attention.phrase(Self.guitar, in: run.m) == "a guitar", "news")
        run.step(Kit.heard("I love guitars"), at: 1)
        let g = Self.referent(Self.guitar, run)!
        #expect(abs(g.salience - (0.15 * pow(0.5, 1.0 / 20) + 0.6)) < 1e-9)
        #expect(g.sources.contains(.mentioned))
        #expect(g.sharedWithUser)
        #expect(Attention.isShared(Self.guitar, in: run.m))
        #expect(Attention.phrase(Self.guitar, in: run.m) == "that guitar", "common ground")
        #expect(Attention.phrase(Subject("owl")!, in: run.m) == "an owl")
        #expect(Self.referent(Self.lamp, run)?.sharedWithUser == false)
        run.step(Kit.heard("do you know about pianos"), at: 2)
        #expect(Self.referent(Subject("piano")!, run) == nil, "a mention never invents a referent")
    }

    @Test func deeNamingThenAReplyMakesCommonGround() {
        var run = ReducerRun(Attention())
        run.step(.sight(camera: .back, things: ["lamp"], novel: ["lamp"]), at: 0)
        run.step(.deeSaid(tag: nil, sentence: "Ooh, is that a lamp?"), at: 1)
        let l = Self.referent(Self.lamp, run)!
        #expect(l.sources.contains(.deeMentioned))
        #expect(!l.sharedWithUser, "not until they reply")
        run.step(Kit.heard("yes it is"), at: 3)
        #expect(Self.referent(Self.lamp, run)!.sharedWithUser)
    }

    @Test func heldUpToTheFrontCamera() {
        var run = ReducerRun(Attention())
        run.step(.presence(arrived: true), at: 0)
        run.step(.sight(camera: .front, things: ["book"], novel: ["book"]), at: 0.5)
        #expect(!Self.referent(Subject("book")!, run)!.sources.contains(.heldUp), "face still there, no hand")
        run.step(.faceLost, at: 3)
        run.step(.sight(camera: .front, things: ["book", "mug"], novel: ["mug"]), at: 4)
        let mug = Self.referent(Self.mug, run)!
        #expect(mug.sources.contains(.heldUp))
        #expect(mug.sharedWithUser)
        #expect(abs(mug.salience - 1.0) < 1e-9, "novel 0.5 + held up 0.5")
        #expect(run.m.momentary.signals.contains { $0.name == "heldUp" && $0.subject == Self.mug })
        run.step(.sight(camera: .front, things: ["cup"], novel: ["cup"]), at: 7)
        #expect(!Self.referent(Subject("cup")!, run)!.sources.contains(.heldUp), "face lost ≥ 2 s ago")
        run.step(.gesture("wave"), at: 8)
        run.step(.sight(camera: .front, things: ["pen"], novel: []), at: 8.5)
        #expect(Self.referent(Subject("pen")!, run)!.sources.contains(.heldUp), "a hand is present")
    }

    @Test func lookingDownWhileFrontLabelsChange() {
        var run = ReducerRun(Attention())
        run.step(.head(yaw: 0, pitch: -25), at: 0)
        run.step(.sight(camera: .front, things: ["book"], novel: []), at: 0.5)
        #expect(abs(Self.referent(Subject("book")!, run)!.salience - 0.15) < 1e-9, "not down for 1 s yet")
        run.step(.head(yaw: 0, pitch: -25), at: 1)
        run.step(.sight(camera: .front, things: ["book", "mug"], novel: []), at: 1.6)
        #expect(abs(Self.referent(Self.mug, run)!.salience - 0.35) < 1e-9, "repeat 0.15 + looked-down 0.2")
    }

    @Test func pointingIsAWeakBump() {
        var run = ReducerRun(Attention())
        run.step(.sight(camera: .back, things: ["lamp"], novel: []), at: 0)
        run.step(.sight(camera: .back, things: ["guitar"], novel: []), at: 5)
        run.step(.gesture("point"), at: 5.5)
        #expect(abs(Self.referent(Self.guitar, run)!.salience - (0.15 * pow(0.5, 0.5 / 20) + 0.2)) < 1e-9)
        #expect(Self.referent(Self.lamp, run)!.salience < 0.15, "seen > 2 s ago: not bumped")
    }

    // MARK: Look requests and the glance wait

    @Test func lookRequestGlancesOncePerTurn() {
        var run = ReducerRun(Attention())
        var fx = run.step(.partial("look at"), at: 0)
        #expect(fx == [.glanceNow(.back)])
        #expect(run.m.momentary.pendingGlance == Timed(.back, until: Kit.t0.addingTimeInterval(1.2)))
        fx = run.step(.partial("look at this"), at: 0.5)
        #expect(fx.isEmpty, "once per turn")
        run.step(.sight(camera: .back, things: ["guitar"], novel: ["guitar"]), at: 0.8)
        #expect(run.m.momentary.pendingGlance == nil, "the glance came back")
        run.step(.gesture("palm"), at: 5)
        fx = run.step(Kit.heard("can you see"), at: 5.5, events: [.userStarted])
        #expect(fx == [.glanceNow(.back), .glanceNow(.front)], "a new turn, and a hand is present")
        run.step(.tick, at: 7)
        #expect(run.m.momentary.pendingGlance == nil, "expires after 1.2 s")
        for s in ["check this out", "what's this?", "what is that", "see this?", "look!"] {
            #expect(Attention.isLookRequest(Attention.tokens(s)), "\(s)")
        }
        for s in ["you look tired", "I see", "what is the time"] {
            #expect(!Attention.isLookRequest(Attention.tokens(s)), "\(s)")
        }
    }

    @Test func deixisWaitsForTheGlance() {
        var run = ReducerRun(Attention())
        let fx = run.step(Kit.heard("what's this?"), at: 0)
        #expect(fx == [.glanceNow(.back)])
        #expect(Self.notes(run).isEmpty, "waits ≤ 1.2 s for the glance")
        run.step(.sight(camera: .back, things: ["guitar"], novel: ["guitar"]), at: 0.6)
        #expect(Self.notes(run) == [.deixisResolved])
        #expect(run.m.ongoing.noteCandidates.first?.slots == ["guitar"])
        #expect(run.m.momentary.focus == .referent(Self.guitar, .back))
        #expect(abs(Self.referent(Self.guitar, run)!.salience - 0.7) < 1e-9, "novel 0.5 + found by the glance 0.2")
    }

    @Test func glanceFoundThingStillResolvesAfterTheTurnEnds() {
        var run = ReducerRun(Attention())
        run.step(.sight(camera: .back, things: ["lamp"], novel: []), at: 0)
        run.step(.partial("what's this"), at: 1)
        run.step(.sight(camera: .back, things: ["guitar", "lamp"], novel: ["guitar"]), at: 1.5)
        run.step(Kit.heard("what's this"), at: 2.5)
        #expect(Self.notes(run) == [.deixisResolved], "the glance's find doesn't decay below 0.5 in a second")
    }

    @Test func deixisGlanceTimeout() {
        var run = ReducerRun(Attention())
        run.step(Kit.heard("what's this?"), at: 0)
        run.step(.tick, at: 0.5)
        #expect(Self.notes(run).isEmpty)
        run.step(.tick, at: 1.3)
        #expect(Self.notes(run) == [.deixisUnknown], "nothing came back")
        #expect(run.m.momentary.uncertainty == Attention.unknownUncertainty)
    }

    @Test func deixisAfterThePromptWentOutRaisesNoStaleNote() {
        var run = ReducerRun(Attention())
        run.step(Kit.heard("what's this?"), at: 0)
        run.step(.promptSubmitted, at: 0.1)
        run.step(.sight(camera: .back, things: ["guitar"], novel: ["guitar"]), at: 0.7)
        #expect(Self.notes(run).isEmpty, "the cue was already built")
        #expect(run.m.momentary.focus == .referent(Self.guitar, .back), "but she still looks at it")
    }

    @Test func deixisResolvesAtOnceWhenAlreadyClear() {
        var run = ReducerRun(Attention())
        run.step(.sight(camera: .back, things: ["guitar"], novel: ["guitar"]), at: 0)
        run.step(.sight(camera: .back, things: ["guitar"], novel: []), at: 0.5)
        let fx = run.step(Kit.heard("what's this?"), at: 1)
        #expect(fx == [.glanceNow(.back)], "the glance still goes out")
        #expect(Self.notes(run) == [.deixisResolved], "no wait: s₁ already resolves")
    }

    // MARK: Deixis outcomes

    static func seeded(_ pairs: [(Subject, Double)], lessons: [Lesson] = []) -> ReducerRun<Attention> {
        var run = ReducerRun(Attention())
        run.m.enduring.lessons = lessons
        run.m.momentary.referents = pairs.map { Referent(subject: $0.0, camera: .back, sources: [.sawBack], salience: $0.1, lastSeen: Kit.t0) }
        return run
    }

    @Test func deixisResolved() {
        var run = Self.seeded([(Self.guitar, 0.7), (Self.lamp, 0.4)])
        run.step(Kit.heard("do you like this one"), at: 0)
        #expect(Self.notes(run) == [.deixisResolved])
        #expect(run.m.ongoing.noteCandidates[0].owner == "Attention")
        #expect(run.m.ongoing.noteCandidates[0].text == "(\"That\" is probably the guitar.)")
        #expect(run.m.momentary.focus == .referent(Self.guitar, .back), "focus becomes the referent")
        #expect(Self.referent(Self.guitar, run)!.sharedWithUser)
        #expect(run.m.momentary.uncertainty == 0)
        #expect(run.m.momentary.signals.contains { $0.name == "deixis" && $0.label == "resolved" && $0.subject == Self.guitar })
    }

    @Test func deixisAmbiguous() {
        var run = Self.seeded([(Self.guitar, 0.6), (Self.lamp, 0.45)])
        run.step(Kit.heard("what's that?"), at: 0)
        run.step(.tick, at: 1.3)
        #expect(Self.notes(run) == [.deixisAmbiguous])
        #expect(run.m.ongoing.noteCandidates[0].slots == ["guitar", "lamp"])
        #expect(run.m.momentary.uncertainty == Attention.ambiguousUncertainty)
        run.step(.tick, at: 3)
        #expect(run.m.momentary.uncertainty == Attention.ambiguousUncertainty, "held")
        // The answer: "the lamp" → focus, uncertainty cleared.
        run.step(Kit.heard("the lamp"), at: 5, events: [.userStarted])
        #expect(run.m.momentary.focus == .referent(Self.lamp, .back))
        #expect(run.m.momentary.uncertainty == 0)
    }

    @Test func deixisUnknownSquints() {
        var run = Self.seeded([(Self.guitar, 0.25)])
        run.step(Kit.heard("look at this"), at: 0)
        run.step(.tick, at: 1.3)
        #expect(Self.notes(run) == [.deixisUnknown])
        #expect(run.m.momentary.mannerismRequests == [MannerismRequest(.mannerism(.squint), rank: .reaction, owner: "Attention")])
        #expect(run.m.momentary.uncertainty == Attention.unknownUncertainty)
        run.step(.tick, at: 8)
        #expect(run.m.momentary.uncertainty == 0, "held ≤ 6 s")
    }

    @Test func gapRuleAndThresholds() {
        var run = Self.seeded([(Self.guitar, 0.55), (Self.lamp, 0.2)])
        run.step(Kit.heard("this one"), at: 0)
        #expect(Self.notes(run) == [.deixisResolved], "0.55 ≥ 0.5 and gap 0.35")
        run = Self.seeded([(Self.guitar, 0.55), (Self.lamp, 0.4)])
        run.step(Kit.heard("this one"), at: 0)
        #expect(Self.notes(run) == [.deixisAmbiguous], "gap 0.15 < 0.2, both ≥ 0.3")
        run = Self.seeded([(Self.guitar, 0.45), (Self.lamp, 0.1)])
        run.step(Kit.heard("this one"), at: 0)
        #expect(Self.notes(run) == [.deixisUnknown], "below 0.5, only one ≥ 0.3")
    }

    @Test func wrongReferentLessonRaisesTheThreshold() {
        let lesson = Lesson(id: UUID(uuidString: "00000000-0000-4000-8000-0000000000C1")!, person: Kit.john, situation: .wrongReferent,
                            doInstead: Lesson.Situation.wrongReferent.doInstead, evidence: 2, createdAt: Kit.t0)
        var run = Self.seeded([(Self.guitar, 0.6), (Self.lamp, 0.1)], lessons: [lesson])
        run.m.ongoing.person = Kit.ann
        run.step(Kit.heard("this one"), at: 0)
        #expect(Self.notes(run) == [.deixisResolved], "Ann: John's lesson doesn't apply")
        run = Self.seeded([(Self.guitar, 0.6), (Self.lamp, 0.1)], lessons: [lesson])
        run.m.ongoing.person = Kit.john
        run.step(Kit.heard("this one"), at: 0)
        #expect(Self.notes(run) == [.deixisUnknown], "0.6 < 0.65 after the lesson")
        run = Self.seeded([(Self.guitar, 0.7), (Self.lamp, 0.1)], lessons: [lesson])
        run.m.ongoing.person = Kit.john
        run.step(Kit.heard("this one"), at: 0)
        #expect(Self.notes(run) == [.deixisResolved])
    }

    @Test func correctionDemotesAndCountsAsMisread() {
        var run = Self.seeded([(Self.guitar, 0.8), (Self.lamp, 0.4)])
        run.m.ongoing.person = Kit.john
        run.step(Kit.heard("what about this one"), at: 0)
        #expect(run.m.momentary.focus == .referent(Self.guitar, .back))
        run.m.ongoing.noteCandidates = []
        let before = Self.referent(Self.guitar, run)!.salience
        run.step(Kit.heard("no, the other one"), at: 3)
        #expect(abs(Self.referent(Self.guitar, run)!.salience - before * pow(0.5, 3.0 / 20) * 0.3) < 1e-9, "× 0.3")
        #expect(Self.notes(run) == [.misread, .deixisResolved])
        #expect(run.m.ongoing.noteCandidates[0].slots == ["guitar"])
        #expect(run.m.ongoing.noteCandidates[1].slots == ["lamp"], "the next candidate is used")
        #expect(run.m.momentary.focus == .referent(Self.lamp, .back))
        let mis = run.m.momentary.signals.filter { $0.name == "misread" }
        #expect(mis.count == 1)
        #expect(mis.first?.label == "wrongReferent")
        #expect(mis.first?.subject == Self.guitar)
        #expect(mis.first?.id != nil)
        // A correction long after the last resolution is just words.
        run.m.ongoing.noteCandidates = []
        run.step(Kit.heard("the other one"), at: 100)
        #expect(Self.notes(run).isEmpty)
    }

    @Test func correctionWithNoOtherCandidateAsks() {
        var run = Self.seeded([(Self.guitar, 0.8)])
        run.step(Kit.heard("this one"), at: 0)
        run.m.ongoing.noteCandidates = []
        run.step(Kit.heard("not that one"), at: 2)
        #expect(Self.notes(run) == [.misread, .deixisUnknown])
    }

    @Test func discourseThatDoesNotTrigger() {
        var run = Self.seeded([(Self.guitar, 0.8)])
        for s in ["that's great", "I think that we should go", "it went fine", "is that a lamp", "this guitar is old"] {
            run.step(Kit.heard(s), at: 0)
            #expect(Self.notes(run).isEmpty, "\(s)")
        }
        // A bare "that"/"it" needs a look frame; "this" needs visual context.
        run = ReducerRun(Attention())
        run.step(Kit.heard("this is nice"), at: 0)
        #expect(Self.notes(run).isEmpty, "no referent, no frame")
        run = Self.seeded([(Self.guitar, 0.8)])
        run.step(Kit.heard("do you like it"), at: 0)
        #expect(Self.notes(run) == [.deixisResolved])
    }

    @Test func triggerLexicon() {
        func t(_ s: String) -> String? { Attention.deixisTrigger(Attention.tokens(s))?.word }
        #expect(t("what's this") == "this")
        #expect(t("look over there") == "over there")
        #expect(t("that one") == "that one")
        #expect(t("those are mine") == "those")
        #expect(t("that guitar") == nil)
        #expect(t("I know that") == nil)
        #expect(t("what is it") == "it")
        #expect(Attention.deixisTrigger(Attention.tokens("what is it"))?.strong == false)
        #expect(Attention.isCorrection(Attention.tokens("No, the other one!")))
        #expect(Attention.isCorrection(Attention.tokens("wrong one")))
        #expect(!Attention.isCorrection(Attention.tokens("one more")))
    }

    // MARK: Hooks

    @Test func conversationStartResetsDeixisState() {
        var run = Self.seeded([(Self.guitar, 0.6), (Self.lamp, 0.45)])
        run.step(Kit.heard("this one"), at: 0)
        #expect(run.m.momentary.uncertainty > 0)
        run.step(.conversationStarted(Kit.t0.addingTimeInterval(1)), at: 1)
        #expect(run.m.momentary.uncertainty == 0)
        #expect(run.r.lastResolved == nil)
        #expect(run.r.askedUntil == nil)
    }

    @Test func forgetSubjectScrubsPrivateState() {
        var run = Self.seeded([(Self.guitar, 0.8), (Self.lamp, 0.3)])
        run.step(Kit.heard("my guitar"), at: 0)
        run.step(.deeSaid(tag: nil, sentence: "a lamp!"), at: 1)
        #expect(run.r.triad?.subject == Self.guitar)
        run.m.forget(subject: Self.guitar)
        run.r.forget(subject: Self.guitar, &run.m)
        #expect(run.r.triad == nil)
        #expect(run.r.userBumped["guitar"] == nil)
        run.m.forget(subject: Self.lamp)
        run.r.forget(subject: Self.lamp, &run.m)
        #expect(run.r.deeNamed.isEmpty)
        run.r.forgetAll(&run.m)
        #expect(run.r.userBumped.isEmpty)
    }

    @Test func deterministicReplay() {
        func trace() -> [String] {
            var run = ReducerRun(Attention(), seed: 9)
            var out: [String] = []
            let ps: [Percept] = [.sight(camera: .back, things: ["guitar", "lamp"], novel: ["guitar", "lamp"]), Kit.heard("this one"),
                                 Kit.heard("no the other one"), .tick, .head(yaw: 1, pitch: 0), .tick]
            for (i, p) in ps.enumerated() {
                run.step(p, at: Double(i))
                out.append("\(Attention.slice(of: run.m).sorted { $0.key < $1.key }) \(run.m.momentary.signals.map { "\($0.name):\($0.id?.uuidString ?? "")" })")
            }
            return out
        }
        #expect(trace() == trace())
    }

    // MARK: Goldens

    @Test func goldenBasics() throws {
        try Golden.verify(Golden.record(Attention(), name: "basics", [
            Cue(t: 0, p: .presence(arrived: true)), Cue(t: 0.5, p: .head(yaw: 4, pitch: -3)),
            Cue(t: 1, p: .sight(camera: .back, things: ["guitar", "lamp"], novel: ["guitar"])),
            Cue(t: 2, p: .sound(label: "doorbell", unexpected: true)), Cue(t: 5.5, p: .tick),
            Cue(t: 6, p: .touch(kind: "pet", gentle: true, at: SIMD2(0.4, 0.6))), Cue(t: 7.5, p: .tick),
            Cue(t: 26, p: .tick), Cue(t: 27, p: .faceLost),
        ]))
    }

    /// "What's this?" → glance → resolved; "no, the other one" → corrected (misread).
    @Test func goldenDeixis() throws {
        try Golden.verify(Golden.record(Attention(), name: "deixis", [
            Cue(t: 0, p: .presence(arrived: true)), Cue(t: 0.5, p: .head(yaw: 2, pitch: 0)),
            Cue(t: 1, p: .sight(camera: .back, things: ["lamp"], novel: [])),
            Cue(t: 3, p: .partial("what's")), Cue(t: 3.5, p: .partial("what's this")),
            Cue(t: 4, p: .sight(camera: .back, things: ["guitar", "lamp"], novel: ["guitar"])),
            Cue(t: 4.5, p: Kit.heard("what's this")), Cue(t: 4.6, p: .promptSubmitted), Cue(t: 5, p: .tick),
            Cue(t: 6, p: .tick), Cue(t: 8, p: Kit.heard("no the other one")), Cue(t: 9, p: .tick),
        ]))
    }

    /// Held up to the front camera → triad; ambiguity → "which?" → answered by a mention.
    @Test func goldenSharedAttention() throws {
        try Golden.verify(Golden.record(Attention(), name: "shared-attention", [
            Cue(t: 0, p: .presence(arrived: true)), Cue(t: 1, p: .faceLost),
            Cue(t: 1.5, p: .sight(camera: .front, things: ["mug"], novel: ["mug"])), Cue(t: 2, p: .tick), Cue(t: 3, p: .tick),
            Cue(t: 4, p: .presence(arrived: true)), Cue(t: 40, p: .tick),
            Cue(t: 41, p: .sight(camera: .back, things: ["guitar", "lamp"], novel: ["guitar", "lamp"])),
            Cue(t: 44, p: Kit.heard("what about those")), Cue(t: 44.5, p: .tick), Cue(t: 46, p: .tick),
            Cue(t: 48, p: Kit.heard("the lamp")), Cue(t: 49, p: .tick),
        ]))
    }
}
