import DeeCore
import Foundation
import Testing
@testable import DeeMind

/// Touch, sound and sight appraisals, and what they do to feelings and personality.
@Suite struct StimulusTests {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    static func fresh() -> InnerState { InnerState(updatedAt: t0) }

    /// Applies `a` `n` times, `spacing` seconds apart.
    static func repeated(_ a: Appraisal, _ n: Int, spacing: TimeInterval, from s0: InnerState = fresh()) -> InnerState {
        var s = s0
        var t = s0.updatedAt
        for _ in 0..<n {
            t += spacing
            s = EmotionEngine.apply(a, to: s, at: t)
        }
        return s
    }

    // MARK: Touch appraisals

    @Test func gentleTouchIsKindAndScalesWithGentlenessAndDuration() {
        let brief = Appraisal.touch(.pet(gentleness: 0.9, seconds: 0.5))
        let long = Appraisal.touch(.pet(gentleness: 0.9, seconds: 6))
        let rough = Appraisal.touch(.pet(gentleness: 0.1, seconds: 6))
        #expect(long.kindness > brief.kindness)
        #expect(long.warmth > rough.warmth)
        #expect(rough.kindness < long.kindness * 0.5)
        #expect(long.care > 0.8 && long.affection > 0.3 && long.valence > 0.3)
        let hug = Appraisal.touch(.hold(seconds: 8))
        #expect(hug.kindness > 0.5 && hug.affection > 0.4 && hug.care > 0.5)
        #expect(Appraisal.touch(.tap).interestInDee > 0 && Appraisal.touch(.tap).hostility == 0)
        #expect(Appraisal.touch(.doubleTap).humor > 0.2)
        #expect(long.touch == .pet(gentleness: 0.9, seconds: 6))
    }

    @Test func pokesAndSlapsAreRoughScaledByCountAndForce() {
        let two = Appraisal.touch(.pokes(count: 2)), six = Appraisal.touch(.pokes(count: 6)), twelve = Appraisal.touch(.pokes(count: 12))
        #expect(two.hostility < 0.3, "a couple of pokes is mild")
        #expect(six.hostility > two.hostility && twelve.hostility > six.hostility)
        #expect(twelve.hostility <= 0.65, "pokes stay moderate")
        #expect(twelve.dominance > two.dominance)
        let soft = Appraisal.touch(.slap(force: 0.2)), hard = Appraisal.touch(.slap(force: 1))
        #expect(hard.hostility > soft.hostility && hard.intensity > soft.intensity)
        #expect(hard.kindness < -0.5)
        #expect(hard.startle > 0.8)
    }

    @Test func tickleIsFunUntilItIsTooMuch() {
        let short = Appraisal.touch(.tickle(seconds: 2))
        let long = Appraisal.touch(.tickle(seconds: 12))
        #expect(short.humor > 0.6 && short.valence > 0.3 && short.overstimulation == 0)
        #expect(long.overstimulation > 0.9 && long.valence < 0 && long.humor < 0.2)
    }

    // MARK: Touch dynamics

    @Test func pettingRaisesPositiveFeelingsAndTrust() {
        let s0 = Self.fresh()
        let s = EmotionEngine.apply(.touch(.pet(gentleness: 0.9, seconds: 5)), to: s0, at: Self.t0 + 1)
        #expect(s.feelings[.joy] > s0.feelings[.joy])
        #expect(s.feelings[.affection] > s0.feelings[.affection])
        #expect(s.feelings[.trust] > s0.feelings[.trust])
        #expect(s.feelings[.anger] == 0)
        #expect(EmotionEngine.regard(s.feelings) > EmotionEngine.regard(s0.feelings))
    }

    @Test func gentleCareCalmsFearAndCoolsAnger() {
        var upset = Self.fresh()
        upset.feelings[.fear] = 0.6
        upset.feelings[.anger] = 0.6
        let petted = EmotionEngine.apply(.touch(.hold(seconds: 6)), to: upset, at: Self.t0 + 1)
        let ignored = EmotionEngine.advance(upset, to: Self.t0 + 1, circumstances: .init(userPresent: true, asleep: false))
        #expect(petted.feelings[.fear] < ignored.feelings[.fear] - 0.1)
        #expect(petted.feelings[.anger] < ignored.feelings[.anger] - 0.05)
    }

    @Test func kindTouchDriftsPersonalityPositivelyAndRoughTouchTheOpposite() {
        // One pet a day for 60 days vs. one slap a day.
        let kind = Self.repeated(.touch(.pet(gentleness: 0.95, seconds: 6)), 60, spacing: 86_400)
        let rough = Self.repeated(.touch(.slap(force: 0.8)), 60, spacing: 86_400)
        let control = EmotionEngine.advance(Self.fresh(), to: Self.t0 + 60 * 86_400, circumstances: .init(userPresent: false, asleep: true))
        for t in [Trait.agreeableness, .confidence] {
            #expect(kind.personality[t] > control.personality[t], "\(t) up with care")
            #expect(rough.personality[t] < control.personality[t], "\(t) down with slaps")
        }
        #expect(kind.personality[.neuroticism] < control.personality[.neuroticism])
        #expect(rough.personality[.neuroticism] > control.personality[.neuroticism])
        #expect(kind.feelings[.trust] > control.feelings[.trust])
        #expect(rough.feelings[.trust] < control.feelings[.trust])
    }

    @Test func pettingHabituatesSoItIsNoShortcut() {
        // 100 strokes in ~3 minutes vs. the first stroke alone.
        let pet = Appraisal.touch(.pet(gentleness: 1, seconds: 3))
        let one = EmotionEngine.apply(pet, to: Self.fresh(), at: Self.t0 + 2)
        let many = Self.repeated(pet, 100, spacing: 2)
        let firstGain = one.feelings[.affection] - Self.fresh().feelings[.affection]
        let spamGain = many.feelings[.affection] - Self.fresh().feelings[.affection]
        #expect(spamGain < firstGain * 25, "100 strokes are worth far less than 100× one (\(spamGain) vs \(firstGain))")
        #expect(many.feelings[.trust] - Self.fresh().feelings[.trust] <= EmotionEngine.trustGainPerDay + 0.001)
        let firstDrift = one.personality[.agreeableness] - Self.fresh().personality[.agreeableness]
        let spamDrift = many.personality[.agreeableness] - Self.fresh().personality[.agreeableness]
        #expect(spamDrift < firstDrift * 25, "character drift habituates too")
    }

    @Test func slapFrightensAnUnconfidentDeeAndAngersABoldOne() {
        var meek = Self.fresh()
        meek.personality[.confidence] = 0.1
        meek.personality[.assertiveness] = 0.1
        var bold = Self.fresh()
        bold.personality[.confidence] = 0.95
        bold.personality[.assertiveness] = 0.9
        let slap = Appraisal.touch(.slap(force: 0.9))
        let m = EmotionEngine.apply(slap, to: meek, at: Self.t0 + 1)
        let b = EmotionEngine.apply(slap, to: bold, at: Self.t0 + 1)
        #expect(m.feelings[.fear] > b.feelings[.fear])
        #expect(b.feelings[.anger] > m.feelings[.anger])
        #expect(m.feelings[.joy] < meek.feelings[.joy])
    }

    @Test func manyPokesIrritateMoreThanAFew() {
        let few = EmotionEngine.apply(.touch(.pokes(count: 2)), to: Self.fresh(), at: Self.t0 + 1)
        let lots = EmotionEngine.apply(.touch(.pokes(count: 10)), to: Self.fresh(), at: Self.t0 + 1)
        #expect(lots.feelings[.anger] > few.feelings[.anger])
        #expect(few.feelings[.anger] < 0.15, "a couple of pokes is only mildly annoying")
    }

    @Test func longTickleOverwhelms() {
        let fun = EmotionEngine.apply(.touch(.tickle(seconds: 2)), to: Self.fresh(), at: Self.t0 + 1)
        let much = EmotionEngine.apply(.touch(.tickle(seconds: 14)), to: Self.fresh(), at: Self.t0 + 1)
        #expect(fun.feelings[.joy] > much.feelings[.joy])
        #expect(much.feelings[.surprise] > fun.feelings[.surprise])
        #expect(much.feelings[.fear] > fun.feelings[.fear])
    }

    // MARK: Sounds and sights

    @Test func soundCategories() {
        #expect(SoundKind("Siren") == .alarming)
        #expect(SoundKind("smoke detector beeping") == .alarming)
        #expect(SoundKind("glass breaking") == .alarming)
        #expect(SoundKind("doorbell") == .other)
        #expect(SoundKind("dog barking") == .other)
        #expect(SoundKind("laughing") == .laughter)
        #expect(SoundKind("guitar") == .music)
        #expect(SoundKind("singing") == .music)
        #expect(SoundKind("train") == .other, "\"rain\" must not match \"train\"")
        #expect(SoundKind("bird chirping") == .pleasant)
    }

    @Test func unexpectedLoudSoundStartles() {
        let s0 = Self.fresh()
        let quiet = EmotionEngine.apply(.sound(label: "door knock", unexpected: false, loudness: 0.2), to: s0, at: Self.t0 + 1)
        let bang = EmotionEngine.apply(.sound(label: "door knock", unexpected: true, loudness: 0.9), to: s0, at: Self.t0 + 1)
        #expect(bang.feelings[.surprise] > quiet.feelings[.surprise] + 0.3)
        #expect(bang.feelings[.interest] > quiet.feelings[.interest])
        #expect(bang.feelings[.fear] > quiet.feelings[.fear])
        // dBFS works too.
        let db = Appraisal.sound(label: "door knock", unexpected: true, loudness: -15)
        #expect(db.startle > Appraisal.sound(label: "door knock", unexpected: true, loudness: -55).startle)
    }

    @Test func musicAndLaughterDelightAlarmsFrighten() {
        let s0 = Self.fresh()
        let music = EmotionEngine.apply(.sound(label: "piano music", unexpected: false, loudness: 0.5), to: s0, at: Self.t0 + 1)
        let laugh = EmotionEngine.apply(.sound(label: "laughter", unexpected: false, loudness: 0.5), to: s0, at: Self.t0 + 1)
        let alarm = EmotionEngine.apply(.sound(label: "smoke alarm", unexpected: true, loudness: 0.8), to: s0, at: Self.t0 + 1)
        let knock = EmotionEngine.apply(.sound(label: "knock", unexpected: true, loudness: 0.8), to: s0, at: Self.t0 + 1)
        #expect(music.feelings[.joy] > s0.feelings[.joy])
        #expect(music.feelings[.interest] > s0.feelings[.interest])
        #expect(laugh.feelings[.joy] > s0.feelings[.joy])
        #expect(music.feelings[.fear] <= s0.feelings[.fear] + 0.01)
        #expect(alarm.feelings[.fear] > knock.feelings[.fear] + 0.1)
        #expect(alarm.feelings[.joy] < s0.feelings[.joy])
    }

    @Test func soundsAndSightsDoNotTouchTheBond() {
        var s0 = Self.fresh()
        s0.feelings[.loneliness] = 0.6
        for a in [Appraisal.sound(label: "music", unexpected: false, loudness: 0.6), .sound(label: "siren", unexpected: true, loudness: 1), .sight(novelty: 1)] {
            let s = EmotionEngine.apply(a, to: s0, at: Self.t0 + 1)
            #expect(abs(s.feelings[.affection] - s0.feelings[.affection]) < 1e-9)
            #expect(abs(s.feelings[.trust] - s0.feelings[.trust]) < 1e-9)
            #expect(s.feelings[.loneliness] >= s0.feelings[.loneliness] - 1e-9, "a noise is not company")
            #expect(s.personality == s0.personality)
            #expect(s.interactions == s0.interactions)
        }
    }

    @Test func novelSightsRaiseInterestAndSurprise() {
        let s0 = Self.fresh()
        let old = EmotionEngine.apply(.sight(novelty: 0.1), to: s0, at: Self.t0 + 1)
        let new = EmotionEngine.apply(.sight(novelty: 1), to: s0, at: Self.t0 + 1)
        #expect(new.feelings[.interest] > old.feelings[.interest] + 0.1)
        #expect(new.feelings[.surprise] > old.feelings[.surprise])
        #expect(new.feelings[.boredom] < s0.feelings[.boredom])
    }

    // MARK: She can laugh when upset

    @Test func humorSoftensAnger() {
        var angry = Self.fresh()
        angry.feelings[.anger] = 0.7
        var joke = Appraisal()
        joke.humor = 0.8
        joke.valence = 0.4
        let plain = Appraisal()
        let laughed = EmotionEngine.apply(joke, to: angry, at: Self.t0 + 1)
        let not = EmotionEngine.apply(plain, to: angry, at: Self.t0 + 1)
        #expect(laughed.feelings[.anger] < not.feelings[.anger] - 0.08)
        #expect(laughed.feelings[.joy] > not.feelings[.joy])
        #expect(laughed.feelings[.anger] > 0.2, "softened, not erased")
    }
}
