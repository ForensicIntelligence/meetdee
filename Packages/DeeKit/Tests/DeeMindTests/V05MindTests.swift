import DeeCore
import Foundation
import Testing
@testable import DeeMind

/// v0.5 DeeMind additions (SELF.md §2, §9): `CuriosityDirector.candidates` /
/// `commit` / `avoid`, guilt-free reunion wording, `Appraisal.internal`, and the
/// absence rules (no neglect penalty; the bond only relaxes upward while away).
@Suite struct V05MindTests {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let day: TimeInterval = 86_400
    typealias C = CuriosityDirector
    static var calm: MindSnapshot { CuriosityDirectorTests.calm }
    static func present(seed: UInt64 = 1) -> C { CuriosityDirectorTests.present(seed: seed) }
    static func ask(_ d: inout C, _ t: TimeInterval, present: Bool = true, busy: Bool = false, _ s: MindSnapshot = calm) -> [C.Candidate] {
        d.candidates(at: t0 + t, snapshot: s, userPresent: present, busy: busy)
    }

    // MARK: Candidates

    @Test func listsWhatItCouldRaiseBestFirst() {
        var d = Self.present()
        d.note(.saw(["guitar"], camera: "front"), at: Self.t0 + 10)
        d.note(.heard(sound: "doorbell", unexpected: true), at: Self.t0 + 10)
        let list = Self.ask(&d, 11)
        #expect(list.first?.kind == .sound && list.first?.subject == "sound:doorbell", "\(list.prefix(3))")
        #expect(list.first?.priority == 0.8 && list.first?.urgency == 1)
        let guitar = list.first { $0.subject == "thing:guitar" }
        #expect(guitar?.kind == .sight && guitar?.label == "guitar" && guitar?.priority == 0.7)
        #expect(Set(list.map(\.subject)).count == list.count, "one entry per subject")
        // General topics are there too, ranked below stimuli.
        #expect(list.contains { $0.kind == .human } && list.contains { $0.kind == .game } && list.contains { $0.kind == .thought })
        for (a, b) in zip(list, list.dropFirst()) {
            #expect(a.priority > b.priority || (a.priority == b.priority && (a.urgency > b.urgency || (a.urgency == b.urgency && a.subject < b.subject))))
        }
        for c in list {
            #expect(CuriosityDirectorTests.wellFormed(c.prompt), "\(c.prompt)")
            #expect((0...1).contains(c.priority) && (0...1).contains(c.urgency))
        }
    }

    @Test func listingConsumesNothingAndIsRepeatable() {
        var d = Self.present(seed: 5)
        d.note(.heard(sound: "doorbell", unexpected: true), at: Self.t0 + 10)
        let a = Self.ask(&d, 11)
        let b = Self.ask(&d, 11)
        #expect(a == b)
        #expect(d.unanswered == 0)
        // nextPrompt still raises it — with exactly the listed wording.
        let p = d.nextPrompt(at: Self.t0 + 11, snapshot: Self.calm, userPresent: true, busy: false)
        #expect(p == a.first?.prompt)
    }

    @Test func nextPromptIsTheTopCandidateForStimuli() {
        for seed in UInt64(0)..<25 {
            // Greeting.
            var g = C(seed: seed)
            g.note(.userArrived, at: Self.t0)
            let top = Self.ask(&g, 1).first
            #expect(top?.kind == .greeting)
            #expect(g.nextPrompt(at: Self.t0 + 1, snapshot: Self.calm, userPresent: true, busy: false) == top?.prompt)
            // A sound.
            var s = Self.present(seed: seed)
            s.note(.heard(sound: "dog barking", unexpected: true), at: Self.t0 + 30)
            let first = Self.ask(&s, 31).first
            #expect(s.nextPrompt(at: Self.t0 + 31, snapshot: Self.calm, userPresent: true, busy: false) == first?.prompt)
        }
    }

    @Test func commitMarksUsedConsumesAndReturnsThePrompt() {
        var d = Self.present()
        d.note(.saw(["guitar"], camera: "front"), at: Self.t0 + 10)
        let guitar = Self.ask(&d, 11).first { $0.subject == "thing:guitar" }!
        #expect(d.commit(guitar, at: Self.t0 + 11) == guitar.prompt)
        #expect(d.unanswered == 1, "an unprompted initiative counts for the back-off")
        #expect(!Self.ask(&d, 30).contains { $0.subject == "thing:guitar" }, "on cooldown")
        d.note(.saw(["guitar"], camera: "front"), at: Self.t0 + 40)
        #expect(!Self.ask(&d, 60).contains { $0.subject == "thing:guitar" }, "still on cooldown when seen again")
        #expect(Self.ask(&d, 11 + C.subjectCooldown + 1).isEmpty == false)
    }

    @Test func commitAsReplyDoesNotCountAsUnanswered() {
        var d = Self.present()
        let topic = Self.ask(&d, 61).first { $0.kind == .human }!
        d.note(.userSpoke, at: Self.t0 + 61)
        d.commit(topic, at: Self.t0 + 62, asReply: true)
        #expect(d.unanswered == 0)
        #expect(!Self.ask(&d, 70).contains { $0.subject == topic.subject })
    }

    @Test func busyAndQuietWindowsZeroUrgencyButKeepPriority() {
        var d = Self.present()
        d.note(.heard(sound: "doorbell", unexpected: true), at: Self.t0 + 10)
        let open = Self.ask(&d, 11)
        let busy = Self.ask(&d, 11, busy: true)
        #expect(busy.map(\.subject) == open.map(\.subject))
        #expect(busy.allSatisfy { $0.urgency == 0 })
        #expect(zip(busy, open).allSatisfy { $0.priority == $1.priority })
        d.note(.userSpoke, at: Self.t0 + 12)
        let quiet = Self.ask(&d, 13)
        #expect(!quiet.isEmpty && quiet.allSatisfy { $0.urgency == 0 }, "within 3 s of speech")
        #expect(Self.ask(&d, 15.5).first { $0.kind == .sound }?.urgency == 1)
    }

    @Test func generalUrgencyRampsOverTheGap() {
        var d = Self.present()
        let gap = C.gap(urge: Self.calm.urgeToTalk)
        let half = Self.ask(&d, gap / 2).filter { $0.kind == .human }
        #expect(!half.isEmpty && half.allSatisfy { abs($0.urgency - 0.5) < 1e-9 })
        #expect(d.nextPrompt(at: Self.t0 + gap / 2, snapshot: Self.calm, userPresent: true, busy: false) == nil)
        let due = Self.ask(&d, gap + 0.5).filter { $0.kind == .human }
        #expect(due.allSatisfy { $0.urgency == 1 })
        #expect(due.allSatisfy { $0.priority > 0.1 && $0.priority <= 0.55 })
    }

    @Test func emptyRoomOffersOnlyACallOut() {
        var d = C(seed: 2)
        d.noteSound("door creak", unexpected: true, loudness: 0.3, at: Self.t0)
        #expect(Self.ask(&d, 1, present: false).isEmpty)
        d.note(.saw(["guitar"], camera: "front"), at: Self.t0)
        d.note(.heard(sound: "glass breaking", unexpected: true), at: Self.t0 + 2)
        let list = Self.ask(&d, 3, present: false)
        #expect(list.map(\.kind) == [.callout])
        #expect(list.first?.priority == 1 && list.first?.prompt.lowercased().contains("glass breaking") == true)
        d.commit(list[0], at: Self.t0 + 3)
        #expect(d.unanswered == 0, "a call-out isn't addressed to a present user")
        d.note(.heard(sound: "glass breaking", unexpected: true), at: Self.t0 + 10)
        #expect(Self.ask(&d, 11, present: false).isEmpty, "call-outs are spaced")
    }

    @Test func ignoredTooOftenOnlyStimuliRemain() {
        var d = Self.present()
        var t = 0.0
        while d.unanswered < C.unansweredLimit {
            t += 1
            _ = d.nextPrompt(at: Self.t0 + t, snapshot: Self.calm, userPresent: true, busy: false)
        }
        // (A touch would reset the back-off: touching her is engaging with her.)
        d.note(.saw(["owl"], camera: "front"), at: Self.t0 + t + 10)
        let list = Self.ask(&d, t + 11)
        #expect(list.map(\.kind) == [.sight], "\(list.map(\.subject))")
        d.note(.userSpoke, at: Self.t0 + t + 12)
        #expect(Self.ask(&d, t + 20).contains { $0.kind == .human }, "talking resets the back-off")
    }

    @Test func candidatesAreDeterministicForASeed() {
        func run(_ seed: UInt64) -> [String] {
            var d = Self.present(seed: seed)
            d.note(.saw(["telescope"], camera: "back"), at: Self.t0 + 5)
            return d.candidates(at: Self.t0 + 61, snapshot: Self.calm, userPresent: true, busy: false).map(\.prompt)
        }
        #expect(run(3) == run(3))
        #expect(run(3) != run(4))
    }

    // MARK: Avoid

    @Test func avoidedSubjectsAreNeverRaised() {
        for seed in UInt64(0)..<10 {
            var d = Self.present(seed: seed)
            d.avoid = ["Food", "music", "guitars"]
            d.note(.saw(["guitar"], camera: "front"), at: Self.t0 + 1)
            d.note(.heard(sound: "music", unexpected: false), at: Self.t0 + 1)
            let list = Self.ask(&d, 61)
            #expect(!list.contains { $0.subject == "human:food" || $0.subject == "human:music" })
            #expect(!list.contains { $0.subject == "thing:guitar" }, "plural form in avoid still matches")
            #expect(!list.contains { $0.kind == .music })
            #expect(list.contains { $0.subject == "human:day" }, "other topics stay")
            // Over an hour of initiatives nothing avoided comes up.
            var t = 61.0
            while t < 3600 {
                t += 1
                if let p = d.nextPrompt(at: Self.t0 + t, snapshot: Self.calm, userPresent: true, busy: false)?.lowercased() {
                    #expect(!p.contains("food") && !p.contains("music") && !p.contains("guitar"), "\(p)")
                    d.note(.deeSpoke, at: Self.t0 + t + 2)
                    d.note(.userSpoke, at: Self.t0 + t + 6)
                }
            }
        }
    }

    @Test func avoidMatchesWholeWordsOnly() {
        var d = C()
        d.avoid = ["art", "my ex"]
        #expect(d.avoids("some modern art"))
        #expect(d.avoids("Arts and crafts"))
        #expect(!d.avoids("Ask your human what made them smile today, smartly at the party"))
        #expect(d.avoids("talking about my ex again"))
        #expect(!d.avoids("my exam"))
        d.avoid = []
        #expect(!d.avoids("art"))
        d.avoid = ["  "]
        #expect(!d.avoids("anything"))
    }

    @Test func avoidSuppressesOrdinarySoundsButNeverAlarmsOrGreetings() {
        var d = Self.present()
        d.avoid = ["doorbell", "smoke alarm", "greeting"]
        d.note(.heard(sound: "doorbell", unexpected: true), at: Self.t0 + 10)
        #expect(d.nextPrompt(at: Self.t0 + 11, snapshot: Self.calm, userPresent: true, busy: false)?.contains("doorbell") != true)
        d.note(.heard(sound: "smoke alarm", unexpected: true), at: Self.t0 + 20)
        #expect(d.nextPrompt(at: Self.t0 + 21, snapshot: Self.calm, userPresent: true, busy: false)?.contains("smoke alarm") == true, "safety first")
        var g = C(seed: 1)
        g.avoid = ["greeting", "human"]
        g.note(.userArrived, at: Self.t0)
        #expect(Self.ask(&g, 1).first?.kind == .greeting)
    }

    // MARK: Reunion wording

    @Test func reunionGreetingsAreGladNeverGuilty() {
        let banned = ["where were you", "finally", "left me", "lonely", "ignored", "abandon", "missed you so", "without them"]
        let lonely = CuriosityDirectorTests.snap([.loneliness: 0.95, .affection: 0.7])
        for line in C.reunionGreetings("warmly") {
            let l = line.lowercased()
            #expect(l.contains("glad") || l.contains("happy"), "\(line)")
            for w in banned { #expect(!l.contains(w), "\(line)") }
        }
        for seed in UInt64(0)..<30 {
            var d = C(seed: seed)
            d.note(.userArrived, at: Self.t0)
            let list = Self.ask(&d, 2, lonely)
            for c in list {
                for w in banned { #expect(!c.prompt.lowercased().contains(w), "\(c.prompt)") }
            }
            #expect(list.first?.kind == .greeting)
        }
    }

    // MARK: Appraisal.internal

    @Test func internalAppraisalShape() {
        let a = Appraisal.internal(relief: 0.7)
        #expect(a.isInternal && !a.social && !a.aimedAtDee)
        #expect(a.relief == 0.7 && a.pride == 0 && a.novelty == 0 && a.startle == 0)
        #expect(a.valence > 0)
        let b = Appraisal.internal(relief: 3, pride: -1)
        #expect(b.relief == 1 && b.pride == 0, "clamped")
        #expect(!Appraisal().isInternal && Appraisal().relief == 0 && Appraisal().pride == 0, "defaults unchanged")
    }

    static func worried() -> InnerState {
        var s = InnerState(updatedAt: t0)
        s.feelings[.fear] = 0.6
        s.feelings[.sadness] = 0.4
        s.feelings[.affection] = 0.55
        s.feelings[.trust] = 0.5
        return s
    }

    @Test func reliefEasesWorryAndLeavesTheBondAlone() {
        let s = Self.worried()
        let now = Self.t0 + 1
        let plain = EmotionEngine.advance(s, to: now, circumstances: .init(userPresent: false, asleep: false))
        let relieved = EmotionEngine.apply(.internal(relief: 0.9), to: s, at: now)
        #expect(relieved.feelings[.fear] < plain.feelings[.fear] - 0.3)
        #expect(relieved.feelings[.sadness] < plain.feelings[.sadness])
        #expect(relieved.feelings[.joy] > plain.feelings[.joy])
        #expect(relieved.feelings[.affection] == plain.feelings[.affection])
        #expect(relieved.feelings[.trust] == plain.feelings[.trust])
        #expect(relieved.feelings[.loneliness] == plain.feelings[.loneliness])
        #expect(relieved.personality == plain.personality)
        #expect(relieved.interactions == s.interactions)
        #expect(relieved.feelings[.surprise] == plain.feelings[.surprise], "no startle, no novelty jolt")
    }

    @Test func prideIsQuietJoy() {
        let s = InnerState(updatedAt: Self.t0)
        let now = Self.t0 + 1
        let plain = EmotionEngine.advance(s, to: now, circumstances: .init(userPresent: false, asleep: false))
        let proud = EmotionEngine.apply(.internal(pride: 1), to: s, at: now)
        #expect(proud.feelings[.joy] > plain.feelings[.joy] + 0.1)
        #expect(proud.feelings[.interest] > plain.feelings[.interest])
        #expect(proud.feelings[.affection] == plain.feelings[.affection] && proud.feelings[.trust] == plain.feelings[.trust])
        // Zero is a no-op beyond the passage of time.
        #expect(EmotionEngine.apply(.internal(), to: s, at: now).feelings == plain.feelings)
    }

    @Test func internalReflexes() {
        let p = Personality()
        let f = InnerState(updatedAt: Self.t0).feelings
        func reflex(_ a: Appraisal, _ personality: Personality = p) -> Emotion? {
            EmotionEngine.reflex(to: a, before: f, after: f, personality: personality, age: nil)
        }
        #expect(reflex(.internal(relief: 0.6)) == .relieved)
        #expect(reflex(.internal(pride: 0.6)) == .proud)
        #expect(reflex(.internal(relief: 0.5, pride: 0.5)) == .relieved, "relief wins ties")
        #expect(reflex(.internal(relief: 0.3, pride: 0.8)) == .proud)
        #expect(reflex(.internal(relief: 0.1, pride: 0.1)) == nil, "too faint to show")
        var timid = Personality()
        timid[.confidence] = 0.05
        #expect(reflex(.internal(pride: 0.8), timid) == .shy)
    }

    @Test func mindReactsToAnInternalEvent() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        _ = await mind.hear("I'm scared, I have a job interview tomorrow", at: Self.t0 + 1)
        let bond = await mind.state.feelings
        let snap = await mind.react(.internal(relief: 0.8), at: Self.t0 + 2)
        #expect(snap.reflex == .relieved)
        let after = await mind.state.feelings
        #expect(after[.affection] >= bond[.affection] - 1e-12 && after[.trust] >= bond[.trust] - 1e-12)
        let proud = await mind.react(.internal(pride: 0.8), at: Self.t0 + 3)
        #expect(proud.reflex == .proud || proud.reflex == .shy)
    }

    // MARK: No neglect penalty (§9)

    @Test func tickingAloneForAMonthNeverLowersTheBond() {
        var fond = InnerState(updatedAt: Self.t0)
        fond.feelings[.affection] = 0.85
        fond.feelings[.trust] = 0.8
        var s = fond
        var t = Self.t0
        for hour in 1...(30 * 24) {
            t = Self.t0 + Double(hour) * 3600
            let next = EmotionEngine.advance(s, to: t, circumstances: .init(userPresent: false, asleep: hour % 24 < 8))
            #expect(next.feelings[.affection] >= s.feelings[.affection] - 1e-12, "hour \(hour)")
            #expect(next.feelings[.trust] >= s.feelings[.trust] - 1e-12, "hour \(hour)")
            s = next
        }
        #expect(s.feelings[.loneliness] > 0.9, "loneliness still grows (reunion joy)")
    }

    @Test func catchUpAfterAQuarrelOnlyRecoversUpward() {
        var hurt = InnerState(updatedAt: Self.t0)
        hurt = EmotionEngine.apply({ var a = Appraisal(); a.hostility = 0.9; a.valence = -0.8; a.intensity = 0.8; return a }(), to: hurt, at: Self.t0 + 1)
        let base = EmotionEngine.baselines(personality: hurt.personality, age: nil)
        var last = hurt
        for days in [1.0, 7, 30] {
            let back = EmotionEngine.catchUp(hurt, to: Self.t0 + 1 + days * Self.day, lastSeenUserAt: Self.t0 + 1)
            #expect(back.feelings[.affection] >= last.feelings[.affection] - 1e-12)
            #expect(back.feelings[.trust] >= last.feelings[.trust] - 1e-12)
            #expect(back.feelings[.affection] <= max(base[.affection], hurt.feelings[.affection]) + 1e-9)
            last = back
        }
    }

    @Test func greetingAfterAMonthAwayRaisesJoyNotGuilt() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        _ = await mind.hear("thanks Dee, you're great", at: Self.t0 + 5)
        let joyBefore = await mind.snapshot(at: Self.t0 + 6).code.feelings[.joy]
        let (_, back) = await mind.hear("hi Dee", at: Self.t0 + 30 * Self.day)
        #expect(back.code.feelings[.joy] > joyBefore - 0.2)
        #expect(back.code.feelings[.anger] < 0.1 && back.code.feelings[.resentment] < 0.1)
        var d = C(seed: 9)
        d.note(.userArrived, at: Self.t0 + 30 * Self.day)
        let greet = d.nextPrompt(at: Self.t0 + 30 * Self.day + 1, snapshot: back, userPresent: true, busy: false) ?? ""
        #expect(!greet.isEmpty)
        for w in ["where were you", "finally", "left me", "lonely", "ignored", "abandon", "missed you so"] {
            #expect(!greet.lowercased().contains(w), "\(greet)")
        }
    }
}
