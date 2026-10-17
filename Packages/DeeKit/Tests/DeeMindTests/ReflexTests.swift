import DeeCore
import Foundation
import Testing
@testable import DeeMind

/// Reflexes: momentary reactions that sit above mood ("Dee should feel alive").
@Suite struct ReflexTests {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    static func reflex(_ a: Appraisal, from f: Feelings? = nil, personality: Personality = Personality()) -> Emotion? {
        let before = f ?? EmotionEngine.baselines(personality: personality, age: nil)
        var s = InnerState(feelings: before, personality: personality, updatedAt: t0)
        s = EmotionEngine.apply(a, to: s, at: t0 + 1)
        return EmotionEngine.reflex(to: a, before: before, after: s.feelings, personality: personality, age: nil)
    }

    static var angry: Feelings {
        var f = EmotionEngine.baselines(personality: Personality(), age: nil)
        f[.anger] = 0.7
        f[.resentment] = 0.3
        f[.joy] = 0.1
        return f
    }

    static var sad: Feelings {
        var f = EmotionEngine.baselines(personality: Personality(), age: nil)
        f[.sadness] = 0.6
        f[.joy] = 0.1
        return f
    }

    @Test func touchReflexes() {
        #expect(Self.reflex(.touch(.tickle(seconds: 2))) == .giddy)
        #expect(Self.reflex(.touch(.tickle(seconds: 2)), from: Self.angry) == .giddy, "tickles get a giggle even when cross")
        #expect(Self.reflex(.touch(.tickle(seconds: 14))) == .overwhelmed)
        #expect(Self.reflex(.touch(.doubleTap)) == .playful)
        #expect(Self.reflex(.touch(.tap)) == .curious)
        #expect([.content, .love].contains(Self.reflex(.touch(.pet(gentleness: 0.9, seconds: 4)))))
        #expect([.shy, .relieved, .hopeful].contains(Self.reflex(.touch(.pet(gentleness: 0.9, seconds: 4)), from: Self.angry)))
        #expect([.shy, .relieved, .hopeful].contains(Self.reflex(.touch(.hold(seconds: 5)), from: Self.sad)))
        // `count` is the burst total: a few pokes are a game, ~6 grate, 10+ anger.
        #expect([.playful, .skeptical].contains(Self.reflex(.touch(.pokes(count: 3)))))
        #expect([.playful, .skeptical].contains(Self.reflex(.touch(.pokes(count: 5)))))
        #expect(Self.reflex(.touch(.pokes(count: 6))) == .grumpy)
        #expect(Self.reflex(.touch(.pokes(count: 10))) == .angry)
        #expect(Self.reflex(.touch(.pokes(count: 3)), from: Self.angry) == .skeptical, "no game when Dee's already cross")
        let meek = Personality([.confidence: 0.1, .assertiveness: 0.1])
        #expect(Self.reflex(.touch(.slap(force: 0.7)), personality: meek) == .scared)
        #expect([.hurt, .angry].contains(Self.reflex(.touch(.slap(force: 0.7)))))
    }

    @Test func speechReflexesContradictMood() {
        var appraiser = Appraiser()
        let joke = appraiser.appraise("hahaha that's so funny")
        #expect([.giddy, .joy].contains(Self.reflex(joke, from: Self.angry)), "a joke lands even when angry")
        let kind = appraiser.appraise("I'm sorry, I really care about you")
        #expect([.shy, .relieved, .hopeful].contains(Self.reflex(kind, from: Self.angry)))
        let compliment = appraiser.appraise("you're so clever, good job")
        #expect([.shy, .relieved, .hopeful].contains(Self.reflex(compliment, from: Self.sad)))
        #expect([.proud, .shy].contains(Self.reflex(compliment)))
        let insult = appraiser.appraise("you are stupid and useless")
        #expect([.hurt, .angry].contains(Self.reflex(insult)))
        #expect(Self.reflex(insult, from: Self.angry) == .angry)
        let threat = appraiser.appraise("I'm going to smash you")
        #expect([.scared, .angry].contains(Self.reflex(threat)))
        let plain = appraiser.appraise("what time is it")
        #expect(Self.reflex(plain) == nil, "nothing notable, no reflex")
    }

    @Test func soundAndSightReflexes() {
        #expect(Self.reflex(.sound(label: "door knock", unexpected: true, loudness: 0.8)) == .surprised)
        #expect([.scared, .worried].contains(Self.reflex(.sound(label: "siren", unexpected: true, loudness: 0.9))))
        #expect(Self.reflex(.sound(label: "laughing", unexpected: false, loudness: 0.5)) == .giddy)
        #expect(Self.reflex(.sound(label: "piano", unexpected: false, loudness: 0.4)) == .happy)
        #expect(Self.reflex(.sound(label: "hum", unexpected: false, loudness: 0.1)) == nil)
        #expect(Self.reflex(.sight(novelty: 1)) == .awe)
        #expect(Self.reflex(.sight(novelty: 0.6)) == .curious)
        #expect(Self.reflex(.sight(novelty: 0.1)) == nil)
    }

    @Test func mindCarriesReflexOverMoodThenLetsGo() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        var t = Self.t0
        for line in ["you are stupid", "you're useless, I hate you", "shut up you idiot"] {
            t += 5
            await mind.hear(line, at: t)
        }
        let cross = await mind.snapshot(at: t)
        #expect([.angry, .grumpy, .hurt].contains(cross.emotion), "mood is bad: \(cross.emotion) \(ExpressionTests.top(cross.code.feelings, cross.code.personality))")
        t += 5
        let laugh = await mind.hear("hahahaha just kidding, that was a joke", at: t).snapshot
        #expect([.giddy, .joy].contains(laugh.reflex), "Dee laughs anyway: \(String(describing: laugh.reflex))")
        #expect(laugh.code.feelings[.anger] < cross.code.feelings[.anger], "and it softens Dee a little")
        // The reflex is momentary.
        let later = await mind.tick(at: t + Mind.reflexDuration + 1, userPresent: true, asleep: false)
        #expect(later.reflex == nil)
        let during = await mind.snapshot(at: t + 1)
        #expect(during.reflex != nil)
        // A neutral remark clears it.
        let plain = await mind.hear("what time is it", at: t + 2).snapshot
        #expect(plain.reflex == nil)
    }

    @Test func mindReflexFromTouchAndSound() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        let tickled = await mind.react(.touch(.tickle(seconds: 2)), at: Self.t0 + 1)
        #expect(tickled.reflex == .giddy)
        let bang = await mind.react(.sound(label: "bang", unexpected: true, loudness: 0.9), at: Self.t0 + 10)
        #expect([.surprised, .scared, .worried].contains(bang.reflex))
        await mind.reset(at: Self.t0 + 11)
        #expect(await mind.snapshot(at: Self.t0 + 11).reflex == nil)
    }
}
