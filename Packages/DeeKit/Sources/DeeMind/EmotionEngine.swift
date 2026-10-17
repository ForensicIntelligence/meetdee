import DeeCore
import Foundation

/// Dee's whole inner state. Pure value type; `Mind` persists it.
public struct InnerState: Equatable, Sendable, Codable {
    public var feelings: Feelings
    public var personality: Personality
    public var age: AgeSettings
    /// When `feelings` were last brought up to date.
    public var updatedAt: Date
    /// Relationship counters (aggregate only — no content is stored).
    public var interactions = 0
    public var kindInteractions = 0
    public var hostileInteractions = 0
    /// Recent apologies, decaying (30 min half-life) — apologising every other
    /// sentence stops working.
    public var apologyFatigue = 0.0
    /// Recent kindness, decaying (6 h half-life). Habituation: the 10th "I love
    /// you" in a minute means less than the first.
    public var kindRecent = 0.0
    /// Hostility that followed an apology within 24 h, decaying (24 h half-life).
    /// Makes later apologies count for less and stops "insult, sorry, insult,
    /// sorry" from making Dee *more* forgiving.
    public var reoffense = 0.0
    /// When Dee last heard an apology.
    public var lastApologyAt: Date?
    /// Recent hostility, decaying (6 h half-life). Diminishing sensitivity: the
    /// 20th insult of a terrible day dents the long-term bond less than the first
    /// (anger still flares every time).
    public var hostileRecent = 0.0
    /// Trust gained recently; leaks away at `EmotionEngine.trustGainPerDay` per day.
    /// Trust can't be rebuilt faster than that, however nice the user is.
    public var trustGainRecent = 0.0
    /// The persona's "genetic" traits: personality relaxes toward these (over time and
    /// per interaction) and a reset rebuilds from them. Classic Dee: `Trait.setPoint`.
    public var setPoints = Personality()
    /// Which persona preset this state belongs to (`PersonaCatalog`); "classic" for
    /// installs from before the presets.
    public var personaID = PersonaCatalog.classicID

    public init(feelings: Feelings? = nil, personality: Personality = Personality(), age: AgeSettings = AgeSettings(), updatedAt: Date = Date()) {
        self.personality = personality
        self.age = age
        self.updatedAt = updatedAt
        self.feelings = feelings ?? EmotionEngine.baselines(personality: personality, age: age.age(at: updatedAt))
    }

    /// Clears the short-term memory of recent treatment (apology fatigue,
    /// habituation, re-offence) while keeping feelings, personality and counters.
    public mutating func clearRecentHistory() {
        apologyFatigue = 0
        kindRecent = 0
        hostileRecent = 0
        reoffense = 0
        lastApologyAt = nil
        trustGainRecent = 0
    }
}

/// The emotional dynamics. Every function is pure and deterministic.
///
/// Model, in one paragraph: each feeling relaxes exponentially toward a baseline
/// set by personality (an extravert's resting joy is higher; a neurotic Dee's
/// resting sadness is higher) with its own half-life, scaled by age and traits
/// (neuroticism makes bad feelings linger; forgiveness shortens grudges). Each
/// utterance is appraised and applied as impulses whose size depends on traits
/// (sensitivity scales tone; agreeableness damps anger; low confidence turns
/// aggression into fear). Anger is hot and brief; part of it settles into
/// resentment, which is what makes "getting over it" take time — or a sincere
/// apology. Bad is stronger than good: one insult costs more affection and trust
/// than one compliment earns, and kindness habituates and saturates, so the bond
/// is built over days and weeks rather than in a minute. Personality itself drifts
/// very slowly toward the kind of treatment Dee receives, with a pull back to its
/// set points (per interaction and over time) so it never runs away.
public enum EmotionEngine {
    // MARK: Tuning constants

    /// Gaps longer than this between updates are treated as "the app was not
    /// running, so nobody was talking to Dee" rather than as present silence.
    public static let maxPresentGap: TimeInterval = 10 * 60
    /// After the user leaves, Dee stays awake this long before resting.
    public static let restAfterAbsence: TimeInterval = 5 * 60
    /// Most trust Dee can (re)gain per day.
    public static let trustGainPerDay = 0.03
    /// Loneliness grows this much slower while Dee rests.
    static let restingLonelinessRate = 0.35
    /// Personality relaxes back toward its set points with this half-life.
    static let traitRelaxHalfLife: TimeInterval = 30 * 86_400

    // MARK: Effective personality

    /// Personality as felt right now: stored traits plus age offsets.
    public static func effective(_ p: Personality, age: Double?) -> Personality {
        let fx = AgeModel.effect(age: age)
        var out = p
        for t in Trait.allCases { out[t] = p[t] + (fx.traitOffsets[t] ?? 0) }
        return out
    }

    // MARK: Baselines and half-lives

    public static func baselines(personality raw: Personality, age: Double?) -> Feelings {
        let p = effective(raw, age: age)
        let fx = AgeModel.effect(age: age)
        var b = Feelings()
        b[.joy] = 0.3 + 0.2 * p[.extraversion] + 0.1 * p[.playfulness] - 0.15 * p[.neuroticism]
        b[.sadness] = 0.03 + 0.12 * p[.neuroticism]
        b[.anger] = 0
        b[.fear] = 0.02 + 0.06 * p[.neuroticism] * (1 - p[.confidence])
        b[.surprise] = 0
        b[.interest] = 0.25 + 0.35 * p[.curiosity]
        b[.boredom] = 0.08
        b[.affection] = 0.4
        b[.trust] = 0.45 + 0.1 * p[.agreeableness]
        b[.loneliness] = 0
        b[.energy] = 0.8 * fx.energyCeiling
        b[.gratitude] = 0
        b[.resentment] = 0
        return b
    }

    static func halfLife(_ f: Feeling, _ p: Personality, age: Double?) -> Double {
        let fx = AgeModel.effect(age: age)
        var h = f.baseHalfLife * fx.halfLifeScale
        switch f {
        case .sadness, .fear:
            h *= 0.6 + 0.9 * p[.neuroticism]
        case .anger:
            h *= (0.6 + 0.8 * p[.neuroticism]) * (1.4 - 0.6 * p[.patience])
        case .resentment:
            // forgiveness 1.0: ~7 h; default 0.7: ~17 h; 0.0: ~40 h (adult).
            h *= 2.2 - 1.8 * p[.forgiveness]
        case .joy:
            h *= 0.8 + 0.4 * p[.extraversion]
        default: break
        }
        return h
    }

    /// Hours for loneliness to close half the gap to 1 while alone and awake.
    static func lonelinessHalfTime(_ p: Personality) -> Double { 10 - 6 * p[.extraversion] }

    // MARK: Time

    /// What happens to feelings when time passes with nothing said.
    public struct Circumstances: Sendable, Equatable {
        /// The user is with Dee (seen by the camera / the app is in use).
        public var userPresent: Bool
        /// Dee is *resting* (dozing with nobody around, or at night). Energy
        /// refills; loneliness still grows while the user is away, only slower.
        public var asleep: Bool
        public init(userPresent: Bool, asleep: Bool) {
            self.userPresent = userPresent
            self.asleep = asleep
        }
    }

    public static func advance(_ state: InnerState, to now: Date, circumstances c: Circumstances) -> InnerState {
        var s = state
        let dt = now.timeIntervalSince(state.updatedAt)
        guard dt > 0 else { return s }
        let age = s.age.age(at: now)
        let p = effective(s.personality, age: age)
        let base = baselines(personality: s.personality, age: age)
        let fx = AgeModel.effect(age: age)
        let hours = dt / 3600
        let awakeWithUser = c.userPresent && !c.asleep

        for f in Feeling.allCases where f.baseHalfLife.isFinite {
            let h = halfLife(f, p, age: age)
            if !c.userPresent, f == .affection || f == .trust {
                // Time away carries no relationship penalty: while the user is
                // away the bond may only recover upward toward baseline (after a
                // quarrel), never decay downward.
                let relaxed = base[f] + (s.feelings[f] - base[f]) * pow(0.5, dt / h)
                s.feelings[f] = max(s.feelings[f], relaxed)
            } else if f == .boredom, awakeWithUser {
                // Boredom relaxes toward baseline *and* creeps up while someone is
                // around but nothing happens. Solved as one linear ODE so the result
                // doesn't depend on how often the app ticks:
                //   db/dt = kd·(base − b) + kg·(1 − b)
                let kd = log(2) / h
                let kg = log(2) / (1800 * (0.5 + p[.patience]))
                let target = (kd * base[f] + kg) / (kd + kg)
                s.feelings[f] = target + (s.feelings[f] - target) * exp(-(kd + kg) * dt)
            } else {
                s.feelings[f] = base[f] + (s.feelings[f] - base[f]) * pow(0.5, dt / h)
            }
        }

        // Fading anger leaves a little residue as resentment (only while angry).
        let angerDrop = max(0, state.feelings[.anger] - s.feelings[.anger])
        s.feelings[.resentment] += angerDrop * 0.15 * (1.2 - p[.forgiveness])

        // Loneliness: grows while the user is away (faster for extraverts, slower
        // while Dee rests), eases with company. It feeds reunion joy and the urge
        // to talk only — it never costs affection or trust.
        if c.userPresent {
            s.feelings[.loneliness] *= pow(0.5, dt / 600)
        } else {
            let tau = lonelinessHalfTime(p) / (c.asleep ? restingLonelinessRate : 1)
            let l0 = state.feelings[.loneliness]
            s.feelings[.loneliness] = 1 - (1 - l0) * pow(0.5, hours / tau)
        }

        // Energy: drains awake (~20 h to empty), refills while resting (~6 h to full).
        if c.asleep {
            s.feelings[.energy] += (fx.energyCeiling - s.feelings[.energy]) * (1 - pow(0.5, hours / 1.5))
        } else {
            s.feelings[.energy] -= hours / 20
        }
        s.feelings[.energy] = min(s.feelings[.energy], fx.energyCeiling)

        // Personality relaxes toward its set points over time, not only per
        // interaction, so a bad week isn't carved in stone.
        let relax = 1 - pow(0.5, dt / traitRelaxHalfLife)
        for t in Trait.allCases { s.personality[t] += (s.setPoints[t] - s.personality[t]) * relax }

        s.apologyFatigue *= pow(0.5, dt / 1800)
        s.kindRecent *= pow(0.5, dt / (6 * 3600))
        s.hostileRecent *= pow(0.5, dt / (6 * 3600))
        s.reoffense *= pow(0.5, dt / 86_400)
        s.trustGainRecent = max(0, s.trustGainRecent - trustGainPerDay * dt / 86_400)
        s.updatedAt = now
        return s
    }

    /// Brings the state up to `now` across a gap in which nobody was talking to
    /// Dee (the app was suspended or closed). Up to `lastSeenUserAt` the user is
    /// treated as present; after that Dee is alone, awake for `restAfterAbsence`
    /// and then resting — so loneliness grows (slowly), energy recovers, and
    /// boredom does not pile up.
    public static func catchUp(_ state: InnerState, to now: Date, lastSeenUserAt: Date? = nil) -> InnerState {
        var s = state
        guard now > s.updatedAt else { return s }
        if let seen = lastSeenUserAt, seen > s.updatedAt {
            s = advance(s, to: min(seen, now), circumstances: .init(userPresent: true, asleep: false))
        }
        let awakeUntil = min(now, s.updatedAt + restAfterAbsence)
        s = advance(s, to: awakeUntil, circumstances: .init(userPresent: false, asleep: false))
        s = advance(s, to: now, circumstances: .init(userPresent: false, asleep: true))
        return s
    }

    // MARK: Interactions

    /// How much of the *words* a Dee of this age understands (tone always lands).
    /// Babies react to how things are said, not what (Fernald 1989).
    public static func comprehension(age: Double?) -> Double {
        guard let age else { return 1 }
        return min(1, 0.3 + max(0, age) / 4)
    }

    public static func apply(_ appraisal: Appraisal, to state: InnerState, at now: Date) -> InnerState {
        if !appraisal.social { return applySensory(appraisal, to: state, at: now) }
        // A long gap since the last update means nobody was here: model it as
        // absence first, so a returning user meets a lonely, rested Dee.
        var s = now.timeIntervalSince(state.updatedAt) > maxPresentGap
            ? catchUp(state, to: now)
            : advance(state, to: now, circumstances: .init(userPresent: true, asleep: false))
        let age = s.age.age(at: now)
        let p = effective(s.personality, age: age)
        let f = s.feelings
        var n = f

        // Words only land as far as Dee understands them.
        var a = appraisal
        let understood = comprehension(age: age)
        a.hostility *= understood
        a.threat *= understood
        a.praise *= understood
        a.dismissal *= understood

        let tone = 0.5 + p[.sensitivity]                       // 0.5…1.5: how much delivery matters
        let volatility = 0.6 + 0.8 * p[.neuroticism]          // 0.6…1.4
        let forceful = 1 + a.intensity * 0.8 * tone           // shouting amplifies
        let aggression = max(0, a.dominance) * a.intensity
        let kind = max(0, a.kindness)

        // Re-offending soon after an apology makes the next apology worth less.
        let hostile = a.hostility + a.threat > 0.2 && a.kindness < 0
        if hostile, let said = s.lastApologyAt, now.timeIntervalSince(said) < 86_400 {
            s.reoffense = min(3, s.reoffense + 1)
        }

        // Hostility: anger (or fear, for an unconfident Dee), hurt, lost trust and
        // affection. Bad is stronger than good: these losses outweigh what one kind
        // sentence earns.
        // Affection said in the same breath softens a mild jab; grumbling about
        // something else ("my phone is broken") is felt only a little.
        let jab = a.hostility * (1 - min(0.7, a.affection)) * (a.aimedAtDee ? 1 : 0.5)
        let hurt = (jab + a.threat * 0.5) * forceful
        let bondDamage = 1 / (1 + 0.5 * s.hostileRecent)
        let fightOrFlight = p[.confidence] * 0.6 + p[.assertiveness] * 0.4
        n[.anger] += hurt * 0.55 * volatility * (1.25 - 0.6 * p[.agreeableness]) * (0.5 + fightOrFlight)
        n[.fear] += (a.threat * 0.7 + hurt * 0.25 * (1 - fightOrFlight) + aggression * 0.2) * (0.5 + p[.neuroticism])
        n[.sadness] += hurt * 0.3 * tone + a.dismissal * 0.18 * tone
        n[.joy] -= hurt * 0.35 + a.dismissal * 0.1
        n[.resentment] += hurt * 0.12 * (1.3 - p[.forgiveness])
        n[.trust] -= (jab * 0.05 + a.threat * 0.12) * (1.1 - p[.agreeableness] * 0.4) * bondDamage
        n[.affection] -= (jab * 0.06 + a.dismissal * 0.01) * bondDamage
        s.hostileRecent += jab + a.threat

        // Kindness: joy, warmth toward the user, and it cools anger ("getting over
        // it through conversation"). Joy saturates (hedonic adaptation); affection
        // and trust saturate and habituate, so the bond grows over days and weeks.
        let habituation = 1 / (1 + s.kindRecent)
        let joyLift = (a.warmth * 0.18 + a.praise * 0.25 + a.affection * 0.3 + a.gratitude * 0.15 + a.humor * 0.15 * p[.humor]) * (0.7 + 0.3 * tone)
        n[.joy] += joyLift * (1 - f[.joy])
        let affectionGain = (a.affection * 0.07 + a.praise * 0.028 + a.warmth * 0.02 + a.gratitude * 0.02 + a.interestInDee * 0.02)
            * max(0, 1.1 - f[.affection]) * (1 - a.repetition) * habituation
        n[.affection] += affectionGain
        var trustGain = kind * 0.025 * habituation
        // Thanks habituate too: the tenth "thank you" in a minute means less than the first.
        n[.gratitude] += (a.gratitude * 0.5 + a.praise * 0.15) * (1 - f[.gratitude]) * habituation
        n[.anger] -= kind * 0.25 * (0.5 + p[.forgiveness]) * f[.anger]
        n[.resentment] -= kind * 0.03 * p[.forgiveness]
        // Dee can laugh even when upset: a joke or laughter (not a jab) genuinely
        // takes some of the heat out of anger and lifts a little sadness.
        let mirth = a.humor * (0.5 + p[.humor]) * (a.hostility > 0.4 ? 0.3 : 1)
        n[.anger] -= mirth * 0.3 * f[.anger]
        n[.sadness] -= mirth * 0.08 * f[.sadness]
        n[.resentment] -= mirth * 0.01
        // Gentle physical care calms: less fear and sadness, a little joy on top.
        n[.fear] -= a.care * 0.3 * f[.fear]
        n[.sadness] -= a.care * 0.12 * f[.sadness]
        n[.joy] += a.care * 0.08 * (1 - f[.joy])
        if a.loudness < -0.3, kind > 0 { n[.affection] += 0.005 * (1 - f[.affection]) * habituation }   // tender, quiet words
        if kind > 0.1 { s.kindRecent += kind }

        // Apologies: big help, unless they've become a habit or keep being broken.
        let sincerity = a.apology * max(0.15, 1 - s.apologyFatigue) / (1 + s.reoffense)
        if sincerity > 0 {
            n[.anger] *= 1 - 0.65 * sincerity * (0.4 + 0.6 * p[.forgiveness])
            n[.resentment] *= 1 - 0.5 * sincerity * p[.forgiveness]
            n[.sadness] -= 0.12 * sincerity
            trustGain += 0.01 * sincerity * max(0, 1 - s.reoffense)
            s.apologyFatigue = min(1, s.apologyFatigue + a.apology * 0.35)
            s.lastApologyAt = now
        }

        // Trust is rebuilt slowly: at most `trustGainPerDay` per day.
        trustGain = min(trustGain, max(0, trustGainPerDay - s.trustGainRecent))
        n[.trust] += trustGain
        s.trustGainRecent += trustGain

        // The user shares that they feel bad: empathy, not offence.
        n[.interest] += a.distress * 0.2
        n[.sadness] += a.distress * 0.06 * tone

        // Interest and boredom.
        n[.interest] += a.novelty * 0.2 * p[.curiosity] + a.interestInDee * 0.2 - a.repetition * 0.15
        n[.boredom] += a.repetition * 0.25 * (1.2 - p[.patience]) - a.novelty * 0.25 - a.humor * 0.1
        n[.boredom] = min(n[.boredom], f[.boredom] + 0.3)
        n[.joy] += a.interestInDee * 0.1 * (1 - f[.joy])

        // Reunion: a lonely Dee is glad to see you again (more so if Dee likes you),
        // much less so if the first thing you do is be rude.
        let lonelyBefore = f[.loneliness]
        if lonelyBefore > 0.05 {
            let welcome = a.kindness >= 0 ? 1.0 : 0.3
            n[.joy] += 0.3 * lonelyBefore * (f[.affection] / 0.6) * welcome * (1 - f[.joy])
            n[.surprise] += 0.2 * lonelyBefore * welcome
        }

        // Surprise: how far this utterance's tone is from Dee's current mood.
        let expected = valence(f)
        // Surprise is a jolt, not a tally: a run of ordinary lines mustn't add up
        // to astonishment, so a new jolt mostly *replaces* what's left of the last.
        let jolt = min(1, abs(a.valence - expected) * 0.45 + a.intensity * 0.25 + a.startle * 0.5)
        n[.surprise] = max(n[.surprise], jolt) + 0.15 * jolt
        n[.fear] += a.startle * 0.15 * (0.4 + p[.neuroticism]) * (1.2 - p[.confidence])

        // Tickling that goes on too long: overwhelmed (surprise, a little fear,
        // tiring), and the fun drains out of it.
        if a.overstimulation > 0 {
            n[.surprise] += a.overstimulation * 0.35
            n[.fear] += a.overstimulation * 0.15
            n[.joy] -= a.overstimulation * 0.1
            n[.energy] -= a.overstimulation * 0.01
        }

        // Company eases loneliness (hostile company less so); talking costs a
        // little energy, but a lively, friendly exchange perks Dee up.
        n[.loneliness] *= 1 - 0.6 * max(0.25, 1 - a.hostility)
        n[.energy] -= 0.004 + a.intensity * 0.006
        if a.kindness > 0 { n[.energy] += 0.01 * a.intensity }

        s.feelings = Feelings(n.values) // clamps
        s.interactions += 1
        if a.kindness > 0.25 { s.kindInteractions += 1 }
        if a.kindness < -0.25 { s.hostileInteractions += 1 }

        // Touch comes in streams (many strokes in a minute), so its effect on
        // character habituates like affection does: petting is no shortcut.
        let driftWeight = a.touch == nil ? 1 : habituation
        s.personality = drift(s.personality, toward: a, reoffense: s.reoffense, age: age, weight: driftWeight, setPoints: s.setPoints)
        return s
    }

    /// Something Dee heard or saw that isn't the user talking to Dee: it moves
    /// interest, surprise, fear and joy, but not the bond, loneliness, the
    /// relationship counters or personality.
    static func applySensory(_ a: Appraisal, to state: InnerState, at now: Date) -> InnerState {
        var s = now.timeIntervalSince(state.updatedAt) > maxPresentGap
            ? catchUp(state, to: now)
            : advance(state, to: now, circumstances: .init(userPresent: false, asleep: false))
        let p = effective(s.personality, age: s.age.age(at: now))
        let f = s.feelings
        var n = f
        let jumpy = 0.4 + p[.neuroticism]                    // 0.4…1.4
        let jolt = min(1, a.startle * 0.8 + a.novelty * 0.12)
        n[.surprise] = max(n[.surprise], jolt) + 0.15 * jolt
        n[.fear] += (a.alarm * 0.55 + a.startle * 0.12) * jumpy * (1.2 - p[.confidence])
        n[.interest] += (a.novelty * 0.3 + a.startle * 0.15 + a.delight * 0.1) * (0.4 + p[.curiosity]) * (1 - f[.interest] * 0.5)
        n[.boredom] -= a.novelty * 0.2 + a.delight * 0.15 + a.startle * 0.1
        n[.joy] += (a.delight * 0.18 + a.humor * 0.1 * p[.humor]) * (1 - f[.joy])
        n[.joy] -= a.alarm * 0.08
        n[.anger] -= a.humor * 0.15 * f[.anger]           // laughter in the room is catching
        // Someone crying nearby: concern — attention and a little sadness, no fear.
        n[.interest] += a.distress * 0.25 * (1 - f[.interest])
        n[.sadness] += a.distress * 0.12 * (0.5 + p[.sensitivity])
        n[.joy] -= a.distress * 0.06
        n[.energy] -= a.startle * 0.003
        // Internal events (v0.5): relief lets go of worry; pride is quiet joy.
        if a.relief > 0 {
            n[.fear] -= a.relief * 0.7 * f[.fear]
            n[.sadness] -= a.relief * 0.3 * f[.sadness]
            n[.joy] += a.relief * 0.2 * (1 - f[.joy])
        }
        if a.pride > 0 {
            n[.joy] += a.pride * 0.25 * (1 - f[.joy])
            n[.interest] += a.pride * 0.1 * (1 - f[.interest])
            n[.boredom] -= a.pride * 0.1
        }
        s.feelings = Feelings(n.values)
        return s
    }

    /// Very slow personality change from how Dee is treated, pulled back toward
    /// set points so it can't run away. Young Dees are more malleable.
    static func drift(_ p: Personality, toward a: Appraisal, reoffense: Double = 0, age: Double?, weight: Double = 1,
                      setPoints: Personality = Personality()) -> Personality {
        let rate = 0.0015 * AgeModel.effect(age: age).plasticity * max(0, weight)
        var out = p
        // Deadband: lukewarm lines (most small talk) don't shape character.
        let k = abs(a.kindness) < 0.15 ? 0 : a.kindness
        let kind = max(0, k), mean = max(0, -k)
        out[.agreeableness] += rate * (kind - mean * 1.2)
        out[.neuroticism] += rate * (mean * 1.5 - kind * 0.5)
        out[.confidence] += rate * (a.praise * 1.5 - (a.hostility + a.dismissal) * 1.2)
        out[.openness] += rate * (a.novelty - 0.5) * 0.6
        out[.curiosity] += rate * (a.interestInDee + a.novelty - 0.6) * 0.4
        out[.playfulness] += rate * (a.humor - mean * 0.5)
        out[.humor] += rate * a.humor * 0.8
        out[.patience] += rate * (a.repetition > 0 ? -0.3 : 0.1) - rate * a.dominance * a.intensity * 0.5
        out[.assertiveness] += rate * (a.dominance > 0.3 ? 0.4 * a.dominance : 0) - rate * kind * 0.1
        out[.sensitivity] += rate * a.intensity * 0.3 - rate * 0.05
        out[.forgiveness] += rate * (a.apology * 0.8 - a.threat - reoffense * 0.5)
        out[.extraversion] += rate * (a.warmth + a.interestInDee - a.dismissal) * 0.4
        // Physical care: a cared-for Dee grows calmer, more confident and trusting
        // of touch; rough handling (slaps, endless pokes) does the opposite.
        let rough = a.touch == nil ? 0 : max(0, a.hostility) * max(0, a.dominance)
        out[.confidence] += rate * (a.care * 0.6 - rough * 0.8)
        out[.neuroticism] += rate * (rough * 0.8 - a.care * 0.4)
        out[.agreeableness] += rate * (a.care * 0.3 - rough * 0.4)
        // Elastic pull back toward set points (1% of the gap per interaction).
        for t in Trait.allCases { out[t] = out[t] + (setPoints[t] - out[t]) * 0.01 }
        return out
    }

    // MARK: Read-outs

    /// Pleasure dimension of the PAD model, −1…1.
    public static func valence(_ f: Feelings) -> Double {
        let v = f[.joy] * 0.9 + f[.gratitude] * 0.3 + f[.interest] * 0.2 - f[.sadness] * 0.8 - f[.anger] * 0.8 - f[.fear] * 0.6 - f[.boredom] * 0.3 - f[.loneliness] * 0.3 - f[.resentment] * 0.4
        return max(-1, min(1, v))
    }

    /// Arousal dimension, 0…1.
    public static func arousal(_ f: Feelings) -> Double {
        min(1, f[.anger] * 0.8 + f[.fear] * 0.7 + f[.surprise] * 0.8 + f[.joy] * 0.3 + f[.interest] * 0.3 + f[.energy] * 0.2 - f[.boredom] * 0.2)
    }

    /// How Dee feels about the user, −1 (upset/hostile) … 0 (indifferent) … +1 (loves you).
    /// This is what the eye colour shows: mostly the long-term bond (affection and,
    /// more than before, trust), nudged by the moment — anger and grudges much more
    /// than passing cheerfulness. `tanh` keeps headroom at both ends.
    public static func regard(_ f: Feelings) -> Double {
        let bond = (f[.affection] - 0.4) * 1.1 + (f[.trust] - 0.5) * 0.9   // long-term
        let now = f[.joy] * 0.15 + f[.gratitude] * 0.1 - f[.anger] * 0.9 - f[.resentment] * 0.6 - f[.sadness] * 0.1
        return tanh(1.3 * (bond + now - 0.08))
    }

    /// Red (−1) → yellow (0) → green (+1), as RGB 0…1.
    public static func regardColor(_ r: Double) -> (r: Double, g: Double, b: Double) {
        let x = max(-1, min(1, r))
        // Hue 0° red … 55° yellow … 130° green, kept bright and slightly pastel so
        // it still glows like an eye rather than a traffic light.
        let hue = x < 0 ? 55 * (1 + x) : 55 + 75 * x
        return hsv(hue, 0.72, 1.0)
    }

    static func hsv(_ h: Double, _ s: Double, _ v: Double) -> (r: Double, g: Double, b: Double) {
        let c = v * s
        let hp = (h.truncatingRemainder(dividingBy: 360)) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double) = switch hp {
        case ..<1: (c, x, 0)
        case ..<2: (x, c, 0)
        case ..<3: (0, c, x)
        case ..<4: (0, x, c)
        case ..<5: (x, 0, c)
        default: (c, 0, x)
        }
        let m = v - c
        return (r1 + m, g1 + m, b1 + m)
    }
}
