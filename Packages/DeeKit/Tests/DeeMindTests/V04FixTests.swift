import DeeCore
import Foundation
import Testing
@testable import DeeMind

/// Fixes from the v0.4 review: initiative back-off, sight pacing, poke totals,
/// touch double-answers, sound categories, unattended call-outs, and "time away
/// carries no relationship penalty".
@Suite struct V04FixTests {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let day: TimeInterval = 86_400
    static let calm = CuriosityDirectorTests.calm

    static func present(seed: UInt64 = 1) -> CuriosityDirector {
        var d = CuriosityDirector(seed: seed)
        _ = d.nextPrompt(at: t0, snapshot: calm, userPresent: true, busy: false)
        return d
    }

    /// Runs the director once a second; returns the times and prompts emitted.
    static func run(_ d: inout CuriosityDirector, from: TimeInterval, to: TimeInterval,
                    every step: TimeInterval = 1, _ each: (inout CuriosityDirector, Date) -> Void = { _, _ in }) -> [(TimeInterval, String)] {
        var out: [(TimeInterval, String)] = []
        var t = from
        while t < to {
            t += step
            each(&d, t0 + t)
            if let p = d.nextPrompt(at: t0 + t, snapshot: calm, userPresent: true, busy: false) {
                out.append((t, p))
                d.note(.deeSpoke, at: t0 + t + 2)
            }
        }
        return out
    }

    // MARK: 8 — back-off when ignored

    @Test func backsOffWhenIgnoredAndRecoversWhenAnswered() {
        #expect(CuriosityDirector.gap(urge: 0.5, unanswered: 0) == 40)
        #expect(CuriosityDirector.gap(urge: 0.5, unanswered: 1) == 80)
        #expect(CuriosityDirector.gap(urge: 0.5, unanswered: 3) == 320)
        #expect(CuriosityDirector.gap(urge: 0, unanswered: 9) == CuriosityDirector.maxBackoffGap, "capped at 10 min")

        var d = Self.present(seed: 7)
        let ignored = Self.run(&d, from: 0, to: 3600)
        #expect(ignored.count <= 4, "ignored for an hour: \(ignored.count) prompts")
        #expect(d.unanswered >= CuriosityDirector.unansweredLimit)
        // Gaps between successive prompts grow.
        let gaps = zip(ignored.dropFirst(), ignored).map { $0.0 - $1.0 }
        for (a, b) in zip(gaps, gaps.dropFirst()) { #expect(b > a, "\(gaps)") }

        // After 3 unanswered prompts, only novel sights and unexpected sounds speak up.
        d.note(.touched("tickle"), at: Self.t0 + 3601)       // a touch resets…
        #expect(d.unanswered == 0)
        var e = Self.present(seed: 7)
        _ = Self.run(&e, from: 0, to: 2000)
        #expect(e.unanswered >= 3)
        let quiet = Self.run(&e, from: 2000, to: 2000 + 700)
        #expect(quiet.isEmpty, "no general chatter after being ignored: \(quiet)")
        e.note(.heard(sound: "doorbell", unexpected: true), at: Self.t0 + 2710)
        #expect(e.nextPrompt(at: Self.t0 + 2711, snapshot: Self.calm, userPresent: true, busy: false)?.contains("doorbell") == true)
        e.note(.saw(["telescope"], camera: "front"), at: Self.t0 + 2730)
        #expect(e.nextPrompt(at: Self.t0 + 2731, snapshot: Self.calm, userPresent: true, busy: false)?.contains("telescope") == true)

        // The user answering resets the back-off.
        e.note(.userSpoke, at: Self.t0 + 2740)
        #expect(e.unanswered == 0)
        let gap = CuriosityDirector.gap(urge: Self.calm.urgeToTalk)
        #expect(e.nextPrompt(at: Self.t0 + 2740 + gap + 1, snapshot: Self.calm, userPresent: true, busy: false) != nil)
    }

    // MARK: 9 — sight pacing

    @Test func newSightsArePacedPerCamera() {
        // Carrying the phone around: a new back-camera label every 4 s for 10 min.
        var d = Self.present()
        let things = (0..<200).map { "object\($0)" }
        var i = 0
        let back = Self.run(&d, from: 0, to: 600) { d, now in
            if Int(now.timeIntervalSince(Self.t0)) % 4 == 0 {
                d.note(.saw([things[i]], camera: "back"), at: now)
                i += 1
            }
            d.note(.userSpoke, at: now - 10)   // the user keeps answering (no back-off)
        }
        let sightPrompts = back.filter { $0.1.contains("object") }
        #expect(sightPrompts.count <= 6, "back camera: \(sightPrompts.count) sight prompts in 10 min")
        for (a, b) in zip(sightPrompts, sightPrompts.dropFirst()) {
            #expect(b.0 - a.0 >= CuriosityDirector.backSightSpacing - 1)
        }

        // Front camera: at least 45 s apart.
        var f = Self.present()
        f.note(.saw(["lamp"], camera: "front"), at: Self.t0 + 5)
        #expect(f.nextPrompt(at: Self.t0 + 6, snapshot: Self.calm, userPresent: true, busy: false)?.contains("lamp") == true)
        f.note(.userSpoke, at: Self.t0 + 10)
        f.note(.saw(["vase"], camera: "front"), at: Self.t0 + 15)
        #expect(f.nextPrompt(at: Self.t0 + 20, snapshot: Self.calm, userPresent: true, busy: false) == nil, "too soon for another sight")
        #expect(f.nextPrompt(at: Self.t0 + 52, snapshot: Self.calm, userPresent: true, busy: false)?.contains("vase") == true)
    }

    @Test func animalsAndAweJumpTheQueue() {
        var d = Self.present()
        d.note(.saw(["lamp"], camera: "back"), at: Self.t0 + 5)
        #expect(d.nextPrompt(at: Self.t0 + 6, snapshot: Self.calm, userPresent: true, busy: false)?.contains("lamp") == true)
        d.note(.userSpoke, at: Self.t0 + 7)
        d.note(.saw(["dog"], camera: "back"), at: Self.t0 + 12)
        #expect(d.nextPrompt(at: Self.t0 + 13, snapshot: Self.calm, userPresent: true, busy: false)?.contains("dog") == true, "animals jump")
        d.note(.userSpoke, at: Self.t0 + 14)
        d.noteSight(["rainbow"], camera: "back", novelty: 0.95, at: Self.t0 + 20)
        #expect(d.nextPrompt(at: Self.t0 + 21, snapshot: Self.calm, userPresent: true, busy: false)?.contains("rainbow") == true, "awe jumps")
        d.note(.userSpoke, at: Self.t0 + 22)
        d.noteSight(["chair"], camera: "back", novelty: 0.5, at: Self.t0 + 26)
        #expect(d.nextPrompt(at: Self.t0 + 27, snapshot: Self.calm, userPresent: true, busy: false) == nil, "ordinary novelty waits")
        #expect(CuriosityDirector.isAnimal("cats"))
        #expect(CuriosityDirector.isAnimal("golden retriever dog"))
        #expect(!CuriosityDirector.isAnimal("computer mouse"))
    }

    // MARK: 10 — poke totals

    @Test func pokeHostilityScalesWithTheBurstTotal() {
        let three = Appraisal.touch(.pokes(count: 3)), six = Appraisal.touch(.pokes(count: 6)), ten = Appraisal.touch(.pokes(count: 10))
        #expect(three.hostility < 0.1 && three.valence >= 0, "a playful triple poke isn't hostile")
        #expect(six.hostility > three.hostility && ten.hostility > six.hostility)
        #expect(ten.valence < six.valence && six.valence < 0)

        // One burst reported at its running totals escalates; three pokes alone don't.
        var s = InnerState(updatedAt: Self.t0)
        let short = EmotionEngine.apply(.touch(.pokes(count: 3)), to: s, at: Self.t0 + 1)
        for (i, total) in [3, 6, 9, 12].enumerated() {
            s = EmotionEngine.apply(.touch(.pokes(count: total)), to: s, at: Self.t0 + 1 + Double(i) * 0.4)
        }
        #expect(short.feelings[.anger] < 0.05, "\(short.feelings[.anger])")
        #expect(s.feelings[.anger] > short.feelings[.anger] + 0.1, "\(s.feelings[.anger])")
    }

    @Test func pokeRemarkOnlyOnceTheyKeepGoing() {
        var d = Self.present()
        d.note(.touched("pokes"), at: Self.t0 + 5)                        // ≈3 pokes
        #expect(d.nextPrompt(at: Self.t0 + 6, snapshot: Self.calm, userPresent: true, busy: false)?.contains("poking") != true)
        d.note(.touched("pokes"), at: Self.t0 + 6.5)
        d.note(.touched("pokes"), at: Self.t0 + 7)                        // ≈9 pokes
        #expect(d.nextPrompt(at: Self.t0 + 8, snapshot: Self.calm, userPresent: true, busy: false)?.contains("poking") == true)
        var e = Self.present()
        e.note(.touched("pokes(count: 7)"), at: Self.t0 + 5)
        #expect(e.nextPrompt(at: Self.t0 + 6, snapshot: Self.calm, userPresent: true, busy: false)?.contains("poking") == true)
    }

    // MARK: 11 — no double answer to a touch

    @Test func deeSpeakingClearsAPendingTouch() {
        var d = Self.present()
        d.note(.touched("pet"), at: Self.t0 + 5)
        d.note(.deeSpoke, at: Self.t0 + 6)
        #expect(d.nextPrompt(at: Self.t0 + 10, snapshot: Self.calm, userPresent: true, busy: false)?.contains("petting") != true)
        // A touch after she spoke still gets its remark.
        d.note(.touched("pet"), at: Self.t0 + 11)
        #expect(d.nextPrompt(at: Self.t0 + 12, snapshot: Self.calm, userPresent: true, busy: false)?.contains("petting") == true)
    }

    // MARK: Sound categories

    @Test func applauseDelightsAndCryingDrawsConcern() {
        #expect(SoundKind("applause") == .applause)
        #expect(SoundKind("cheering") == .applause)
        #expect(SoundKind("crowd cheering") == .applause)
        #expect(SoundKind("clapping") == .applause)
        #expect(SoundKind("baby crying") == .crying)
        #expect(SoundKind("crying, sobbing") == .crying)
        #expect(SoundKind("crystal glass clink") != .crying)
        #expect(SoundKind("screaming") == .alarming)

        let clap = Appraisal.sound(label: "applause", unexpected: false, loudness: 0.5)
        #expect(clap.delight > 0.4 && clap.valence > 0.3 && clap.alarm == 0)
        let cry = Appraisal.sound(label: "baby crying", unexpected: false, loudness: 0.5)
        #expect(cry.alarm == 0 && cry.distress > 0.3)

        let s0 = InnerState(updatedAt: Self.t0)
        let afterCry = EmotionEngine.apply(cry, to: s0, at: Self.t0 + 1)
        let afterSiren = EmotionEngine.apply(.sound(label: "siren", unexpected: false, loudness: 0.5), to: s0, at: Self.t0 + 1)
        #expect(afterCry.feelings[.fear] < afterSiren.feelings[.fear], "crying isn't frightening")
        #expect(afterCry.feelings[.interest] > s0.feelings[.interest] && afterCry.feelings[.sadness] > s0.feelings[.sadness])
        let afterClap = EmotionEngine.apply(clap, to: s0, at: Self.t0 + 1)
        #expect(afterClap.feelings[.joy] > s0.feelings[.joy])

        #expect(ReflexTests.reflex(cry) == .worried)
        #expect([.excited, .happy].contains(ReflexTests.reflex(clap)))
    }

    // MARK: Unattended call-outs

    @Test func unattendedCalloutsOnlyForAlarmingOrLoudSoundsAfterRealSleep() {
        typealias C = CuriosityDirector
        #expect(!C.callsOutUnattended(sound: "door knock", loudness: nil, asleepFor: nil), "unknown loudness, not alarming")
        #expect(!C.callsOutUnattended(sound: "door knock", loudness: 0.3, asleepFor: nil))
        #expect(C.callsOutUnattended(sound: "door knock", loudness: 0.8, asleepFor: nil))
        #expect(C.callsOutUnattended(sound: "door knock", loudness: -15, asleepFor: nil), "dBFS accepted")
        #expect(C.callsOutUnattended(sound: "glass breaking", loudness: nil, asleepFor: nil))
        #expect(!C.callsOutUnattended(sound: "glass breaking", loudness: nil, asleepFor: 60), "dozed off a minute ago")
        #expect(C.callsOutUnattended(sound: "glass breaking", loudness: nil, asleepFor: 4 * 60))

        // A quiet noise in an empty room: no call-out.
        var d = CuriosityDirector(seed: 2)
        d.noteSound("door creak", unexpected: true, loudness: 0.3, at: Self.t0)
        #expect(d.nextPrompt(at: Self.t0 + 1, snapshot: Self.calm, userPresent: false, busy: false) == nil)
        // Asleep for only a minute: still nothing, even when it's alarming —
        // and it stays that way after the noise wakes her.
        d.asleepSince = Self.t0 + 100
        d.note(.heard(sound: "glass breaking", unexpected: true), at: Self.t0 + 160)
        d.asleepSince = nil
        #expect(d.nextPrompt(at: Self.t0 + 161, snapshot: Self.calm, userPresent: false, busy: false) == nil)
        // Asleep for 4 minutes and something alarming: she calls out.
        d.asleepSince = Self.t0 + 100
        d.note(.heard(sound: "glass breaking", unexpected: true), at: Self.t0 + 340)
        let p = d.nextPrompt(at: Self.t0 + 341, snapshot: Self.calm, userPresent: false, busy: false)
        #expect(p?.contains("glass breaking") == true, "\(String(describing: p))")
    }

    // MARK: Time away carries no relationship penalty

    @Test func timeAwayNeverLowersAffectionOrTrust() {
        var fond = InnerState(updatedAt: Self.t0)
        fond.feelings[.affection] = 0.8
        fond.feelings[.trust] = 0.75
        var hurt = InnerState(updatedAt: Self.t0)
        hurt.feelings[.affection] = 0.2
        hurt.feelings[.trust] = 0.2
        for days in [1.0, 7, 30] {
            let f = EmotionEngine.catchUp(fond, to: Self.t0 + days * Self.day)
            #expect(f.feelings[.affection] >= fond.feelings[.affection], "\(days) d: affection")
            #expect(f.feelings[.trust] >= fond.feelings[.trust], "\(days) d: trust")
            #expect(f.feelings[.loneliness] > 0.3, "she can still be lonely")
            let h = EmotionEngine.catchUp(hurt, to: Self.t0 + days * Self.day)
            #expect(h.feelings[.affection] > hurt.feelings[.affection], "recovers upward after a quarrel")
            #expect(h.feelings[.trust] > hurt.feelings[.trust])
            let base = EmotionEngine.baselines(personality: hurt.personality, age: nil)
            #expect(h.feelings[.affection] <= base[.affection] + 1e-9)
        }
        // Awake and alone, too (not only resting).
        let alone = EmotionEngine.advance(fond, to: Self.t0 + 10 * Self.day, circumstances: .init(userPresent: false, asleep: false))
        #expect(alone.feelings[.affection] >= fond.feelings[.affection] && alone.feelings[.trust] >= fond.feelings[.trust])
        // While present, the bond still relaxes as before.
        let together = EmotionEngine.advance(fond, to: Self.t0 + 10 * Self.day, circumstances: .init(userPresent: true, asleep: false))
        #expect(together.feelings[.affection] < fond.feelings[.affection])
    }

    @Test func aMonthAwayPlusAHelloLeavesTheBondIntact() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        _ = await mind.hear("hi Dee, you're lovely", at: Self.t0 + 5)
        let before = await mind.snapshot(at: Self.t0 + 6)
        let bondBefore = await mind.state.feelings
        let (_, after) = await mind.hear("hello", at: Self.t0 + 30 * Self.day)
        let bondAfter = await mind.state.feelings
        #expect(after.regard >= before.regard - 1e-9, "\(after.regard) vs \(before.regard)")
        #expect(bondAfter[.affection] >= bondBefore[.affection] - 1e-9)
        #expect(bondAfter[.trust] >= bondBefore[.trust] - 1e-9)
    }

    @Test func reunionLinesNeverGuilt() {
        let banned = ["where were you", "finally", "left me", "lonely", "ignored", "abandon", "missed you so", "missed them"]
        let lonely = CuriosityDirectorTests.snap([.loneliness: 0.95, .affection: 0.7])
        for seed in UInt64(0)..<40 {
            var d = CuriosityDirector(seed: seed)
            d.note(.userArrived, at: Self.t0)
            let greet = d.nextPrompt(at: Self.t0 + 1, snapshot: lonely, userPresent: true, busy: false)?.lowercased() ?? ""
            #expect(!greet.isEmpty)
            for w in banned { #expect(!greet.contains(w), "\(greet)") }
            // …and general initiatives while she's still lonely.
            var e = Self.present(seed: seed)
            let p = e.nextPrompt(at: Self.t0 + 61, snapshot: lonely, userPresent: true, busy: false)?.lowercased() ?? ""
            for w in banned { #expect(!p.contains(w), "\(p)") }
        }
    }
}
