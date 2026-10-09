import DeeCore
import Foundation
import Testing
@testable import DeeMind

@Suite struct CuriosityDirectorTests {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    static func snap(_ v: [Feeling: Double] = [:]) -> MindSnapshot {
        MindSnapshot(code: MindCode(personality: Personality(), feelings: ExpressionTests.profile(v)), age: nil)
    }
    static let calm = snap()
    static let eager = snap([.loneliness: 0.9, .boredom: 0.8, .interest: 0.9])
    static let tired = snap([.energy: 0.05])

    /// Starts a director with the user present since `t0`.
    static func present(seed: UInt64 = 1) -> CuriosityDirector {
        var d = CuriosityDirector(seed: seed)
        _ = d.nextPrompt(at: t0, snapshot: calm, userPresent: true, busy: false)
        return d
    }

    static func wellFormed(_ p: String?) -> Bool {
        guard let p else { return false }
        return p.hasPrefix("(") && p.hasSuffix(")") && p.count < 260
    }

    @Test func gapScalesInverselyWithUrge() {
        #expect(CuriosityDirector.gap(urge: 1) == 20)
        #expect(CuriosityDirector.gap(urge: 0) == 60)
        #expect(CuriosityDirector.gap(urge: 0.5) == 40)
        #expect(Self.eager.urgeToTalk > Self.calm.urgeToTalk)
        #expect(Self.tired.urgeToTalk < Self.calm.urgeToTalk)
    }

    @Test func initiatesAfterTheGapWhilePresent() {
        var d = Self.present()
        let gap = CuriosityDirector.gap(urge: Self.calm.urgeToTalk)
        #expect(d.nextPrompt(at: Self.t0 + gap - 1, snapshot: Self.calm, userPresent: true, busy: false) == nil)
        let p = d.nextPrompt(at: Self.t0 + gap + 0.5, snapshot: Self.calm, userPresent: true, busy: false)
        #expect(Self.wellFormed(p), "\(String(describing: p))")
        // An eager Dee speaks up sooner.
        var e = CuriosityDirector(seed: 1)
        _ = e.nextPrompt(at: Self.t0, snapshot: Self.eager, userPresent: true, busy: false)
        #expect(e.nextPrompt(at: Self.t0 + 25, snapshot: Self.eager, userPresent: true, busy: false) != nil)
    }

    @Test func staysQuietWhileBusyOrJustAfterSpeech() {
        var d = Self.present()
        d.note(.heard(sound: "doorbell", unexpected: true), at: Self.t0 + 10)
        #expect(d.nextPrompt(at: Self.t0 + 11, snapshot: Self.calm, userPresent: true, busy: true) == nil)
        d.note(.userSpoke, at: Self.t0 + 11)
        #expect(d.nextPrompt(at: Self.t0 + 13, snapshot: Self.calm, userPresent: true, busy: false) == nil, "< 3 s after speech")
        let p = d.nextPrompt(at: Self.t0 + 14.5, snapshot: Self.calm, userPresent: true, busy: false)
        #expect(p?.contains("doorbell") == true, "\(String(describing: p))")
    }

    @Test func greetsOnArrival() {
        var d = CuriosityDirector(seed: 3)
        d.note(.userArrived, at: Self.t0)
        let p = d.nextPrompt(at: Self.t0 + 0.5, snapshot: Self.calm, userPresent: true, busy: false)
        #expect(Self.wellFormed(p))
        let lower = p?.lowercased() ?? ""
        #expect(lower.contains("greet") || lower.contains("hello") || lower.contains("welcome"), "\(lower)")
        // Not again on a quick re-arrival.
        d.note(.userArrived, at: Self.t0 + 60)
        let again = d.nextPrompt(at: Self.t0 + 61, snapshot: Self.calm, userPresent: true, busy: false) ?? ""
        #expect(!again.lowercased().contains("greet"))
        // If the user opens the conversation, Dee doesn't greet over them.
        var e = CuriosityDirector(seed: 3)
        e.note(.userArrived, at: Self.t0)
        e.note(.userSpoke, at: Self.t0 + 1)
        let after = e.nextPrompt(at: Self.t0 + 5, snapshot: Self.calm, userPresent: true, busy: false)
        #expect(after == nil)
    }

    @Test func callsOutToAnEmptyRoomOnAnUnexpectedSound() {
        var d = CuriosityDirector(seed: 4)
        #expect(d.nextPrompt(at: Self.t0, snapshot: Self.calm, userPresent: false, busy: false) == nil, "nobody there, nothing heard")
        d.noteSound("door knock", unexpected: true, loudness: 0.85, at: Self.t0 + 1)
        let p = d.nextPrompt(at: Self.t0 + 1.5, snapshot: Self.calm, userPresent: false, busy: false)
        #expect(Self.wellFormed(p))
        #expect(p?.contains("door knock") == true)
        let lower = p?.lowercased() ?? ""
        #expect(lower.contains("someone") || lower.contains("somebody") || lower.contains("who's there"), "\(lower)")
        // Not every few seconds.
        d.note(.heard(sound: "bang", unexpected: true), at: Self.t0 + 30)
        #expect(d.nextPrompt(at: Self.t0 + 31, snapshot: Self.calm, userPresent: false, busy: false) == nil)
        // Expected sounds don't wake an empty room.
        var e = CuriosityDirector(seed: 4)
        e.note(.heard(sound: "music", unexpected: false), at: Self.t0)
        #expect(e.nextPrompt(at: Self.t0 + 5, snapshot: Self.calm, userPresent: false, busy: false) == nil)
    }

    @Test func asksAboutNovelSightsAndNeverRepeatsASubjectWithin20Minutes() {
        var d = Self.present()
        d.note(.saw(["guitar", "person"], camera: "front"), at: Self.t0 + 5)
        let p = d.nextPrompt(at: Self.t0 + 5.5, snapshot: Self.calm, userPresent: true, busy: false)
        #expect(p?.contains("guitar") == true, "\(String(describing: p))")
        #expect(p?.contains("person") == false, "people aren't novel things")
        d.note(.deeSpoke, at: Self.t0 + 6)
        // Seen again 5 minutes later: not raised again.
        d.note(.saw(["guitar"], camera: "back"), at: Self.t0 + 300)
        let q = d.nextPrompt(at: Self.t0 + 304, snapshot: Self.calm, userPresent: true, busy: false)
        #expect(q?.contains("guitar") != true)
        // 21 minutes on, it's fair game again.
        d.note(.saw(["guitar"], camera: "back"), at: Self.t0 + 21 * 60)
        let r = d.nextPrompt(at: Self.t0 + 21 * 60 + 1, snapshot: Self.calm, userPresent: true, busy: false)
        #expect(r?.contains("guitar") == true, "\(String(describing: r))")
    }

    @Test func veryInteractiveButVariedOverAnHour() {
        var d = Self.present(seed: 7)
        var prompts: [(Date, String)] = []
        var t = Self.t0
        while t < Self.t0 + 3600 {
            t += 1
            if let p = d.nextPrompt(at: t, snapshot: Self.calm, userPresent: true, busy: false) {
                #expect(Self.wellFormed(p), "\(p)")
                prompts.append((t, p))
                d.note(.deeSpoke, at: t + 2)
                d.note(.userSpoke, at: t + 6)
            }
        }
        #expect(prompts.count >= 30, "very interactive: \(prompts.count) initiatives in an hour")
        // No identical prompt within 20 minutes.
        for (i, a) in prompts.enumerated() {
            for b in prompts[(i + 1)...] where b.0.timeIntervalSince(a.0) < 20 * 60 {
                #expect(a.1 != b.1, "repeated within 20 min: \(a.1)")
            }
        }
        let kinds = Set(prompts.map { p -> String in
            if p.1.contains("Ask your human") { return "human" }
            if p.1.contains("Suggest playing") { return "game" }
            return "thought"
        })
        #expect(kinds.count == 3, "asks about the human, suggests games and shares thoughts")
    }

    @Test func moodColoursThePhrasing() {
        let grumpy = Self.snap([.anger: 0.5, .resentment: 0.3])
        let sleepy = Self.snap([.energy: 0.1])
        for seed in UInt64(0)..<6 {
            var d = CuriosityDirector(seed: seed)
            d.note(.heard(sound: "doorbell", unexpected: true), at: Self.t0)
            let p = d.nextPrompt(at: Self.t0 + 1, snapshot: grumpy, userPresent: true, busy: false)?.lowercased() ?? ""
            #expect(p.contains("grump") || p.contains("gruff") || p.contains("grudging"), "\(p)")
            var s = CuriosityDirector(seed: seed)
            s.note(.heard(sound: "doorbell", unexpected: true), at: Self.t0)
            let q = s.nextPrompt(at: Self.t0 + 1, snapshot: sleepy, userPresent: true, busy: false)?.lowercased() ?? ""
            #expect(q.contains("sleep") || q.contains("drows"), "\(q)")
        }
    }

    @Test func boredDeeLeansTowardGamesAndLonelyDeeTowardThePerson() {
        var games = 0, personal = 0
        let bored = Self.snap([.boredom: 0.9, .joy: 0.7])
        let lonely = Self.snap([.loneliness: 0.9, .affection: 0.8])
        for seed in UInt64(0)..<60 {
            var d = Self.present(seed: seed)
            if d.nextPrompt(at: Self.t0 + 61, snapshot: bored, userPresent: true, busy: false)?.contains("Suggest playing") == true { games += 1 }
            var e = Self.present(seed: seed)
            let p = e.nextPrompt(at: Self.t0 + 61, snapshot: lonely, userPresent: true, busy: false) ?? ""
            if p.contains("Ask your human") || p.contains("glad of their company") { personal += 1 }
        }
        #expect(games >= 25, "bored → games \(games)/60")
        #expect(personal >= 35, "lonely → the human \(personal)/60")
    }

    @Test func prefersNovelThingsSeenRecently() {
        var hits = 0
        for seed in UInt64(0)..<30 {
            var d = Self.present(seed: seed)
            d.note(.saw(["telescope"], camera: "back"), at: Self.t0 - 200)   // seen a while ago, never asked
            if d.nextPrompt(at: Self.t0 + 61, snapshot: Self.calm, userPresent: true, busy: false)?.contains("telescope") == true { hits += 1 }
        }
        #expect(hits >= 8, "novel things are favoured (\(hits)/30)")
    }

    @Test func touchesGetARemarkButNotEveryTime() {
        var d = Self.present()
        d.note(.touched("tickle"), at: Self.t0 + 5)
        let p = d.nextPrompt(at: Self.t0 + 5.5, snapshot: Self.calm, userPresent: true, busy: false)
        #expect(p?.contains("tickling") == true)
        d.note(.touched("tickle"), at: Self.t0 + 40)
        let q = d.nextPrompt(at: Self.t0 + 41, snapshot: Self.calm, userPresent: true, busy: false)
        #expect(q?.contains("tickling") != true)
        d.note(.touched("tap"), at: Self.t0 + 60)
        let r = d.nextPrompt(at: Self.t0 + 61, snapshot: Self.calm, userPresent: true, busy: false)
        #expect(r?.contains("tap") != true, "a tap alone isn't worth a remark")
        #expect(CuriosityDirector.touchLine("pet(duration: 2.0, gentleness: 0.9)") != nil)
        #expect(CuriosityDirector.touchLine(Touch.hold(seconds: 3).word) != nil)
        #expect(CuriosityDirector.touchLine("Double Tap") != nil)
    }

    @Test func deterministicForASeed() {
        func run(_ seed: UInt64) -> [String] {
            var d = Self.present(seed: seed)
            var out: [String] = []
            for i in 1...600 {
                if let p = d.nextPrompt(at: Self.t0 + Double(i), snapshot: Self.calm, userPresent: true, busy: false) {
                    out.append(p)
                    d.note(.deeSpoke, at: Self.t0 + Double(i))
                }
            }
            return out
        }
        #expect(run(11) == run(11))
        #expect(run(11) != run(12))
    }

    @Test func articles() {
        #expect(CuriosityDirector.article("guitar") == "a guitar")
        #expect(CuriosityDirector.article("owl") == "an owl")
        #expect(CuriosityDirector.article("glasses") == "glasses")
        #expect(CuriosityDirector.article("the moon") == "the moon")
        #expect(CuriosityDirector.article("dog barking") == "dog barking")
    }
}
