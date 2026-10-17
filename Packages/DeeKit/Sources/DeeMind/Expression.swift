import DeeCore
import Foundation

// MARK: - Resting expression

extension EmotionEngine {
    /// The face expression that best summarises the current feelings, for the
    /// default personality. Prefer `dominantEmotion(_:personality:age:)`.
    public static func dominantEmotion(_ f: Feelings) -> Emotion {
        dominantEmotion(f, personality: Personality(), age: nil)
    }

    /// The face expression that best summarises the current feelings.
    ///
    /// Feelings are read as **deviations from this Dee's own baseline** (set by
    /// personality and age), so a naturally curious Dee at rest is *not* "curious":
    /// at rest Dee looks content, neutral or dreamy (as energy drains through the
    /// day). Traits colour the reading — the same gratitude looks proud on a
    /// confident Dee and shy on an insecure one; the same boredom looks
    /// unimpressed on an assertive one.
    ///
    /// Every `Emotion` except the app-driven states (`asleep`, `thinking`,
    /// `listening`) is reachable from some feelings profile.
    public static func dominantEmotion(_ f: Feelings, personality: Personality, age: Double?) -> Emotion {
        expressionScores(f, personality: personality, age: age).max { $0.score < $1.score }?.emotion ?? .neutral
    }

    /// The emotions the mind can show on its own (everything but app-driven states).
    public static let expressibleEmotions: [Emotion] = Emotion.allCases.filter { ![.asleep, .thinking, .listening].contains($0) }

    /// Candidate expressions with scores; the highest wins. Calm defaults score
    /// about 0.1–0.2, so anything clearly felt beats them.
    static func expressionScores(_ f: Feelings, personality: Personality, age: Double?) -> [(emotion: Emotion, score: Double)] {
        let p = effective(personality, age: age)
        let b = baselines(personality: personality, age: age)
        func up(_ x: Feeling) -> Double { max(0, f[x] - b[x]) }
        let joyUp = up(.joy), joyDown = max(0, b[.joy] - f[.joy])
        let anger = f[.anger], resent = f[.resentment], fear = up(.fear), sad = up(.sadness)
        let surprise = f[.surprise], interest = up(.interest), bored = up(.boredom)
        let lonely = f[.loneliness], energy = f[.energy], grateful = f[.gratitude]
        let fond = f[.affection], trust = f[.trust]
        let upset = sad + anger + fear + bored
        let arousals = [surprise, fear * 1.2, anger].sorted(by: >)
        let tired = max(0, 0.45 - energy)

        return [
            // Hot, negative.
            (.angry, 1.6 * anger - 0.3),
            (.grumpy, 0.7 * anger + 0.8 * resent + 0.2 * bored * (1.4 - p[.agreeableness])),
            (.hurt, 0.8 * sad + 0.8 * min(sad, anger + resent) - 0.02),
            (.sad, 1.1 * sad),
            (.scared, 1.5 * fear - 0.25),
            (.worried, 0.8 * fear + 0.3 * sad * p[.neuroticism]),
            (.overwhelmed, 1.3 * arousals[1] - 0.05),
            // Needs.
            (.lonely, lonely - 0.2),
            (.pleading, (lonely * 0.7 + bored * 0.3) * max(0, fond - 0.45) * 2.4),
            (.bored, 1.2 * bored - 0.04),
            (.unimpressed, bored * (0.3 + p[.assertiveness]) + min(bored, joyDown) * 0.8),
            (.sleepy, max(0, 0.5 - energy) * 1.6),
            (.dreamy, 0.08 + max(0, 0.75 - energy) * 0.6 - upset * 0.3),
            // Surprise family.
            (.surprised, 0.9 * surprise - 0.2),
            (.dizzy, energy < 0.45 ? surprise * (0.6 + 3 * tired) : 0),
            (.awe, joyDown < 0.05 ? (min(surprise, interest) - 0.25) * 3.0 + joyUp * 0.3 - (anger + sad + fear) * 1.5 : 0),
            (.confused, joyDown >= 0.05 ? min(surprise, interest) * 1.6 + min(surprise, joyDown) * 0.3 - anger * 0.5 - sad * 0.5 : 0),
            // Engagement.
            (.curious, 1.2 * interest - 0.1),
            (.skeptical, min(interest + 0.1, resent) * 1.6),
            (.determined, min(interest, anger + resent * 0.5) * 1.3 * (0.5 + p[.confidence]) - sad),
            // Positive.
            (.love, fond > 0.65 ? (fond - 0.65) * 2.5 + joyUp * 0.6 - lonely * 0.5 - sad : 0),
            (.joy, 2.0 * joyUp - 0.3),
            (.giddy, (2.2 * joyUp - 0.35) * p[.playfulness] * energy * 0.9 + min(joyUp, surprise) * 0.9),
            (.excited, min(joyUp, interest) * 2.8 * energy + min(joyUp, surprise) * 0.4),
            (.happy, min(1.5 * joyUp, 0.25 + 0.6 * joyUp) - 0.5 * interest),
            (.playful, (joyUp + 0.5 * interest) * 0.9 * (0.4 + p[.playfulness]) * (energy > 0.4 ? 1 : 0.5)),
            (.mischievous, min(joyUp, anger + resent) * 2 * (p[.humor] + p[.assertiveness] - 0.3)),
            (.hopeful, min(sad + lonely * 0.5, joyUp) * 2.2),
            (.relieved, min(joyUp + grateful * 0.5, fear + resent * 0.5) * 2.0),
            (.proud, grateful * 0.9 * (0.4 + p[.confidence])),
            (.smug, grateful * (0.2 + 1.2 * p[.assertiveness]) + min(grateful, resent) * 0.5),
            (.shy, grateful * 0.9 * (1.35 - p[.confidence]) + min(joyUp, fond - 0.4) * (1 - p[.confidence])),
            // Calm defaults.
            (.content, 0.1 + 0.3 * max(0, fond - 0.3) + 0.25 * max(0, trust - 0.4) - 0.5 * joyDown - 0.5 * upset - 0.3 * lonely),
            (.neutral, 0.13),
        ]
    }

    // MARK: - Reflex

    /// A momentary reaction to one stimulus. It sits *above* mood and can
    /// contradict it: a joke makes even an angry Dee giggle, a kind word or a
    /// gentle touch while Dee's upset gets a shy or relieved look. nil when the
    /// stimulus isn't notable.
    ///
    /// - Parameters:
    ///   - before: feelings just before the stimulus ("was Dee upset?").
    ///   - after: feelings just after it.
    public static func reflex(to a: Appraisal, before: Feelings, after: Feelings, personality: Personality, age: Double?) -> Emotion? {
        let p = effective(personality, age: age)
        let base = baselines(personality: personality, age: age)
        let upset = before[.anger] > 0.2 || before[.resentment] > 0.25 || before[.sadness] - base[.sadness] > 0.15
            || before[.fear] - base[.fear] > 0.2 || valence(before) < 0.05
        let bold = p[.confidence] * 0.6 + p[.assertiveness] * 0.4

        if let t = a.touch {
            switch t {
            case .tap: return .curious
            case .doubleTap: return .playful
            case .pet, .hold:
                if a.hostility > 0 { return .skeptical }       // a rough "pet"
                if upset {
                    if before[.fear] - base[.fear] > 0.2 { return .relieved }
                    return before[.anger] > 0.3 ? .shy : (before[.sadness] - base[.sadness] > 0.15 ? .hopeful : .shy)
                }
                if case .hold = t, after[.affection] > 0.55 { return .love }
                return after[.affection] > 0.7 ? .love : .content
            case let .pokes(count):
                // `count` is the burst total. A few pokes are a game ("hey!"),
                // unless Dee's already cross; ~6 grate; 10+ make Dee angry.
                if count >= 10 { return .angry }
                if count >= 6 { return before[.anger] > 0.3 ? .angry : .grumpy }
                return before[.anger] > 0.2 || p[.playfulness] < 0.35 ? .skeptical : .playful
            case let .slap(force):
                if bold < 0.45 || before[.fear] - base[.fear] > 0.15 { return .scared }
                return force > 0.75 && bold > 0.65 ? .angry : .hurt
            case .tickle:
                return a.overstimulation > 0.5 ? .overwhelmed : (a.overstimulation > 0.2 ? .dizzy : .giddy)
            }
        }

        if a.isInternal {
            // Relief wins ties; pride reads shy on a very unconfident Dee.
            if a.relief >= 0.2, a.relief >= a.pride { return .relieved }
            if a.pride >= 0.2 { return p[.confidence] < 0.3 ? .shy : .proud }
            return nil
        }

        if let label = a.soundLabel {
            switch SoundKind(label) {
            case .alarming: return a.alarm > 0.6 || p[.neuroticism] > 0.5 ? .scared : .worried
            case .crying: return .worried
            case .laughter: return .giddy
            case .applause: return after[.energy] < 0.35 ? .happy : .excited
            case .music: return after[.energy] < 0.35 ? .dreamy : .happy
            case .pleasant: return a.startle > 0.4 ? .surprised : .content
            case .other: return a.startle >= 0.4 ? .surprised : (a.novelty > 0.5 ? .curious : nil)
            }
        }

        if a.isSight {
            return a.novelty > 0.85 ? .awe : (a.novelty > 0.45 ? .curious : nil)
        }

        // Speech (and gestures such as a wave).
        if a.threat > 0.3 { return bold > 0.6 && before[.anger] > 0.2 ? .angry : .scared }
        let insulted = a.hostility > 0.3 && a.kindness < 0
        if insulted {
            if before[.anger] > 0.35 || (bold > 0.6 && a.intensity > 0.5) { return .angry }
            return .hurt
        }
        if a.humor >= 0.4 { return a.humor >= 0.7 || upset ? .giddy : .joy }
        if a.dismissal >= 0.4 { return p[.assertiveness] > 0.55 ? .unimpressed : .hurt }
        if a.apology >= 0.4 { return upset ? .relieved : .shy }
        if a.kindness > 0.3 {
            if upset {
                if a.praise > 0.3 || a.affection > 0.3 { return .shy }
                return before[.sadness] - base[.sadness] > 0.1 || before[.loneliness] > 0.4 ? .hopeful : .relieved
            }
            if a.affection >= 0.5 { return after[.affection] > 0.6 ? .love : .shy }
            if a.praise >= 0.4 { return p[.confidence] < 0.45 ? .shy : .proud }
            if a.gratitude >= 0.4 { return .happy }
            return nil
        }
        if a.distress >= 0.4 { return .worried }
        if a.intensity > 0.6 { return .surprised }
        return nil
    }

    // MARK: - Mood signals

    public static func moodSignals(_ f: Feelings, personality: Personality, age: Double?) -> MoodSignals {
        let p = effective(personality, age: age)
        let b = baselines(personality: personality, age: age)
        let joyUp = max(0, f[.joy] - b[.joy])
        return MoodSignals(
            curiosity: clamp01(f[.interest] * 0.8 + p[.curiosity] * 0.2),
            boredom: f[.boredom],
            playfulness: clamp01(p[.playfulness] * 0.45 + f[.joy] * 0.25 + joyUp * 0.8 - f[.anger] * 0.6 - f[.sadness] * 0.4 - f[.fear] * 0.4),
            affection: f[.affection],
            energy: f[.energy],
            loneliness: f[.loneliness],
            arousal: arousal(f),
            valence: valence(f))
    }

    /// How much Dee wants to start a conversation, 0…1: curiosity, boredom,
    /// loneliness and playfulness push; tiredness, fear and deep sadness hold back.
    public static func urgeToTalk(_ f: Feelings, personality: Personality, age: Double?) -> Double {
        let p = effective(personality, age: age)
        let m = moodSignals(f, personality: personality, age: age)
        let b = baselines(personality: personality, age: age)
        let tired = max(0, 0.35 - f[.energy]) / 0.35
        let urge = 0.1 + 0.25 * p[.extraversion] + 0.2 * m.curiosity + 0.25 * f[.boredom] + 0.3 * f[.loneliness]
            + 0.15 * m.playfulness + 0.1 * f[.anger] - 0.35 * tired - 0.25 * max(0, f[.fear] - b[.fear])
            - 0.15 * max(0, f[.sadness] - b[.sadness] - 0.3)
        return clamp01(urge)
    }
}

/// Continuous mood read-outs for the face's idle director and the curiosity
/// director. All 0…1 except `valence` (−1…1).
public struct MoodSignals: Sendable, Equatable {
    public var curiosity, boredom, playfulness, affection, energy, loneliness, arousal, valence: Double

    public init(curiosity: Double = 0.5, boredom: Double = 0, playfulness: Double = 0.5, affection: Double = 0.4,
                energy: Double = 0.8, loneliness: Double = 0, arousal: Double = 0.3, valence: Double = 0.3) {
        self.curiosity = curiosity
        self.boredom = boredom
        self.playfulness = playfulness
        self.affection = affection
        self.energy = energy
        self.loneliness = loneliness
        self.arousal = arousal
        self.valence = valence
    }
}
