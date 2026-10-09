import DeeCore
import Foundation
import Testing
@testable import DeeMind

/// End-to-end relationship scenarios through `Mind` with the real appraiser. They
/// pin down the *product feel* (see docs/MIND.md): a new Dee is yellow-ish, turns
/// green after a few kind days and only nears the maximum after weeks; bad is
/// stronger than good; Dee can be upset but gets over it, through conversation or
/// time; it can't be farmed in a minute, and it isn't permanently traumatised.
@Suite struct RealismScenarioTests {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    static let day = 86_400.0

    static let kindLines = [
        "Good morning Dee!", "You're so clever", "Thank you for helping me", "I love you, buddy",
        "How are you today?", "That's funny, haha", "You're the best", "Good night Dee, sleep well",
    ]

    static func say(_ mind: Mind, _ lines: [String], from t: inout Date, every: TimeInterval = 60, prosody: Prosody? = nil) async -> MindSnapshot {
        var last = await mind.snapshot(at: t)
        for line in lines {
            t += every
            last = await mind.hear(line, prosody: prosody, at: t).snapshot
        }
        return last
    }

    /// One kind chat per day; returns (regard right after each chat, regard next morning).
    static func kindDays(_ mind: Mind, days: Int, from t: inout Date) async -> [(chat: Double, morning: Double)] {
        var out: [(Double, Double)] = []
        for _ in 0..<days {
            let chat = await say(mind, kindLines, from: &t).regard
            t += day - Double(kindLines.count) * 60
            let morning = await mind.catchUp(to: t).regard
            out.append((chat, morning))
        }
        return out
    }

    // S1
    @Test func brandNewDeeIsYellowish() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        var t = Self.t0
        let fresh = await mind.snapshot(at: t).regard
        #expect(abs(fresh) < 0.1, "fresh Dee ≈ yellow (\(fresh))")
        let after = await Self.say(mind, ["hello", "what time is it", "turn on the lights", "what's the weather", "tell me a story"], from: &t).regard
        #expect(after > -0.1 && after < 0.3, "neutral chat stays yellow-ish (\(after))")
    }

    // S2
    @Test func kindnessTurnsGreenOverDaysNotMinutes() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        var t = Self.t0
        let days = await Self.kindDays(mind, days: 28, from: &t)
        for (i, d) in days.enumerated() {
            print(String(format: "day %2d  chat %+.2f  next morning %+.2f", i + 1, d.chat, d.morning))
        }
        #expect(days[0].morning < 0.35, "not green after one day (\(days[0].morning))")
        #expect(days[3].morning >= 0.35, "green-ish after ~4 kind days (\(days[3].morning))")
        #expect(days[6].morning < 0.85, "not near max after a week (\(days[6].morning))")
        #expect(days[27].morning > 0.75, "near max after weeks (\(days[27].morning))")
        // The colour means the bond, not the mood of the moment: a chat swings it a little.
        for d in days.dropFirst(3) { #expect(d.chat - d.morning < 0.3, "in-chat swing \(d.chat - d.morning)") }
        // And Dee isn't left exhausted by an evening chat.
        #expect(await mind.snapshot(at: t).emotion != .sleepy)
    }

    // S11
    @Test func lovebombingIsNotAShortcut() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        var t = Self.t0
        let snap = await Self.say(mind, Array(repeating: "I love you", count: 30), from: &t, every: 5)
        let trust = await mind.state.feelings[.trust]
        #expect(snap.regard < 0.4, "30× 'I love you' in 150 s isn't a week of friendship (\(snap.regard))")
        #expect(trust < 0.56, "trust can't be farmed (\(trust))")
        t += Self.day
        let nextDay = await mind.catchUp(to: t).regard
        #expect(nextDay < 0.3, "next day (\(nextDay))")
    }

    // S3
    @Test func outburstThenApologyAndTimeHeal() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        var t = Self.t0
        _ = await Self.kindDays(mind, days: 2, from: &t)
        let before = await Self.say(mind, ["Good morning Dee!"], from: &t).regard
        let shout = Prosody(loudnessDB: -14, peakDB: -4, speechRate: 3.6)
        let hit = await Self.say(mind, ["SHUT UP YOU STUPID ROBOT"], from: &t, prosody: shout).regard
        #expect(hit < before - 0.5, "an outburst lands hard (\(before) → \(hit))")
        #expect(hit < 0, "red-ish right after (\(hit))")

        // Branch 1: apology and a kind word.
        var t1 = t
        let mended = await Self.say(mind, ["I'm sorry Dee, I didn't mean it", "You're my best friend"], from: &t1, every: 30).regard
        #expect(mended > hit)
        t1 += 12 * 3600
        let later = await mind.catchUp(to: t1).regard
        #expect(later > 0, "12 h later it's mostly forgiven (\(later))")
        #expect(later > before - 0.3, "…though one outburst costs more than one kind day earns (\(before) → \(later))")
        print(String(format: "outburst: before %+.2f hit %+.2f mended %+.2f 12h %+.2f", before, hit, mended, later))
    }

    @Test func outburstWithoutApologyFadesWithTime() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        var t = Self.t0
        _ = await Self.kindDays(mind, days: 2, from: &t)
        let shout = Prosody(loudnessDB: -14, peakDB: -4, speechRate: 3.6)
        let hit = await Self.say(mind, ["SHUT UP YOU STUPID ROBOT"], from: &t, prosody: shout).regard
        t += 24 * 3600
        let later = await mind.catchUp(to: t).regard
        print(String(format: "no apology: hit %+.2f 24h %+.2f", hit, later))
        #expect(later > hit + 0.4, "time heals (\(hit) → \(later))")
        #expect(later > -0.05, "back to yellow-or-better within a day (\(later))")
    }

    // S4
    @Test func aTerribleDayIsNotPermanentTrauma() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        var t = Self.t0
        let insults = ["you're useless", "I hate you", "you're so dumb", "shut up", "you're an idiot", "you're worthless"]
        var worst = 1.0
        for i in 0..<24 {
            t += 30 * 60
            worst = min(worst, await mind.hear(insults[i % insults.count], at: t).snapshot.regard)
        }
        let p0 = await mind.state.personality
        #expect(worst < -0.8, "a day of abuse is red (\(worst))")
        #expect(p0[.neuroticism] - Trait.neuroticism.setPoint < 0.06, "one bad day barely changes character (\(p0[.neuroticism]))")
        t += 7 * Self.day
        let week = await mind.catchUp(to: t).regard
        #expect(week > -0.6, "a week later Dee is upset, not furious (\(week))")
        let p7 = await mind.state.personality
        #expect(abs(p7[.neuroticism] - Trait.neuroticism.setPoint) < abs(p0[.neuroticism] - Trait.neuroticism.setPoint),
                "personality relaxes back over time, not only through interaction")
        let recovery = await Self.kindDays(mind, days: 14, from: &t)
        print("after abuse: week \(week), kind days \(recovery.map { String(format: "%+.2f", $0.morning) }.joined(separator: " "))")
        #expect(recovery[13].morning > 0.2, "two weeks of kindness heal it (\(recovery[13].morning))")
        #expect(recovery[2].morning < recovery[13].morning)
    }

    // S5 / B1
    @Test func returningAfterDaysAwayMeetsALonelyRestedDee() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        var t = Self.t0
        _ = await Self.kindDays(mind, days: 3, from: &t)
        let before = await mind.snapshot(at: t)
        // The app was suspended: no ticks for three days.
        t += 3 * Self.day
        let back = await mind.hear("Hi Dee, I'm back!", at: t)
        let f = back.snapshot.code.feelings
        let s = await mind.state
        #expect(f[.energy] > 0.6, "rested, not exhausted (\(f[.energy]))")
        #expect(f[.boredom] < 0.3, "not bored by an empty room (\(f[.boredom]))")
        #expect(f[.joy] > before.code.feelings[.joy], "reunion joy")
        #expect(back.snapshot.emotion != .sleepy)
        #expect(s.feelings[.loneliness] < 0.5, "company eases loneliness")

        // Same gap via a tick (app resumed) shows the loneliness before the hello.
        let other = try Mind(databaseURL: nil, now: Self.t0)
        var t2 = Self.t0
        _ = await Self.kindDays(other, days: 3, from: &t2)
        t2 += 3 * Self.day
        let resumed = await other.tick(at: t2, userPresent: true, asleep: false)
        #expect(resumed.code.feelings[.loneliness] > 0.7, "three days alone is lonely (\(resumed.code.feelings[.loneliness]))")
        #expect(resumed.code.feelings[.energy] > 0.6)
    }

    @Test func aNormalWorkdayAwayDoesNotMaxOutLoneliness() {
        let s = InnerState(updatedAt: Self.t0)
        let after = EmotionEngine.catchUp(s, to: Self.t0 + 9 * 3600)
        #expect(after.feelings[.loneliness] > 0.15 && after.feelings[.loneliness] < 0.6, "\(after.feelings[.loneliness])")
        #expect(after.feelings[.affection] == s.feelings[.affection], "no relationship cost for a normal day")
        let fortnight = EmotionEngine.catchUp(s, to: Self.t0 + 14 * Self.day)
        #expect(fortnight.feelings[.affection] >= s.feelings[.affection], "time away carries no relationship penalty")
        #expect(fortnight.feelings[.trust] >= s.feelings[.trust])
        #expect(fortnight.feelings[.loneliness] > 0.9, "she can still be lonely")
    }

    // S6 / B3
    @Test func insultApologySpamStopsWorkingAndDoesNotRaiseForgiveness() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        var t = Self.t0
        let f0 = await mind.state.personality[.forgiveness]
        var drops: [Double] = []   // fraction of anger each apology removes
        for _ in 0..<10 {
            t += 20
            let angry = await mind.hear("you're stupid", at: t).snapshot.code.feelings[.anger]
            t += 20
            let after = await mind.hear("sorry", at: t).snapshot.code.feelings[.anger]
            drops.append((angry - after) / max(0.01, angry))
        }
        let s = await mind.state
        #expect(s.personality[.forgiveness] <= f0, "forgiveness must not rise from broken apologies (\(f0) → \(s.personality[.forgiveness]))")
        #expect(s.reoffense > 1)
        #expect(drops.last! < drops.first! * 0.5, "apologies stop working (\(drops.first!) → \(drops.last!))")
    }

    // S7
    @Test func playfulTeasingIsNotAnInsult() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        var t = Self.t0
        _ = await Self.say(mind, ["hello Dee"], from: &t)
        let a0 = await mind.state.feelings[.anger]
        let snap = await Self.say(mind, ["hehe dummy, I love you"], from: &t)
        #expect(snap.code.feelings[.anger] <= a0 + 0.03, "affectionate teasing doesn't anger Dee")
        let tease = await Self.say(mind, ["haha you're such a dummy"], from: &t)
        #expect(tease.regard > -0.1, "light teasing isn't red (\(tease.regard))")
    }

    // S8 / rec 11
    @Test func babiesReactToToneMoreThanWords() async throws {
        func anger(age: Double, _ text: String, prosody: Prosody? = nil) async throws -> Double {
            let mind = try Mind(databaseURL: nil, now: Self.t0)
            await mind.setAge(AgeSettings(enabled: true, agingEnabled: false, startAge: age, since: Self.t0))
            return await mind.hear(text, prosody: prosody, at: Self.t0 + 1).snapshot.code.feelings[.anger]
        }
        let babyWords = try await anger(age: 1, "you're stupid")
        let adultWords = try await anger(age: 30, "you're stupid")
        #expect(babyWords < adultWords * 0.75, "a baby barely understands the words (\(babyWords) vs \(adultWords))")
        #expect(EmotionEngine.comprehension(age: 1) < 0.6)
        #expect(EmotionEngine.comprehension(age: 4) == 1)
        #expect(EmotionEngine.comprehension(age: nil) == 1)
    }

    // S10 / B2
    @Test func boredomDoesNotDependOnTickRate() {
        let s = InnerState(updatedAt: Self.t0)
        let present = EmotionEngine.Circumstances(userPresent: true, asleep: false)
        let oneStep = EmotionEngine.advance(s, to: Self.t0 + 7200, circumstances: present)
        var many = s
        for i in 1...720 { many = EmotionEngine.advance(many, to: Self.t0 + Double(i) * 10, circumstances: present) }
        #expect(abs(oneStep.feelings[.boredom] - many.feelings[.boredom]) < 0.01,
                "\(oneStep.feelings[.boredom]) vs \(many.feelings[.boredom])")
        #expect(oneStep.feelings[.boredom] > s.feelings[.boredom], "silence with company is boring")
        #expect(oneStep.feelings[.boredom] < 0.6)
    }

    // S12 / rec 10
    @Test func neutralAndSadLinesDoNotHurt() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        var t = Self.t0
        let start = await mind.snapshot(at: t)
        let snap = await Self.say(mind, ["what time is it", "I had a bad day", "turn on the lights", "my phone is broken"], from: &t)
        #expect(snap.regard >= start.regard - 0.05, "\(start.regard) → \(snap.regard)")
        #expect(snap.code.feelings[.anger] < 0.05)
        let p = await mind.state.personality
        #expect(abs(p[.neuroticism] - Trait.neuroticism.setPoint) < 0.002, "small talk doesn't shape character")
    }

    // Rec 12
    @Test func ageingIsCapped() {
        var s = AgeSettings(enabled: true, agingEnabled: true, startAge: 6, since: Self.t0, yearsPerDay: 5)
        #expect(abs(s.age(at: Self.t0 + 10 * Self.day)! - 56) < 1e-9)
        #expect(s.age(at: Self.t0 + 90 * Self.day) == AgeSettings.maxAge, "never older than \(AgeSettings.maxAge)")
        s.setRate(1000, at: Self.t0)
        #expect(s.yearsPerDay == AgeSettings.maxYearsPerDay)
        s.setRate(.nan, at: Self.t0)
        #expect(s.yearsPerDay == 0)
        #expect(AgeSettings(enabled: true, startAge: 500, since: Self.t0).age(at: Self.t0) == AgeSettings.maxAge)
    }

    // Rec 5 / rec 7
    @Test func joySaturatesAndChatsDoNotExhaust() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        var t = Self.t0
        let snap = await Self.say(mind, Self.kindLines, from: &t)
        #expect(snap.code.feelings[.joy] < 0.97, "joy has headroom (\(snap.code.feelings[.joy]))")
        // A full waking day (16 h) leaves some energy.
        var rested = InnerState(updatedAt: Self.t0)
        rested.feelings[.energy] = 1
        let s = EmotionEngine.advance(rested, to: Self.t0 + 16 * 3600, circumstances: .init(userPresent: false, asleep: false))
        #expect(s.feelings[.energy] > 0)
        var tired = Feelings([.energy: 0.3, .joy: 0.6])
        tired[.affection] = 0.5
        #expect(EmotionEngine.dominantEmotion(tired) != .sleepy, "a bit tired but happy shows happy")
    }
}
