import DeeCore
import Foundation
import Testing
@testable import DeeMind

/// Behavioural tests for DeeMind: the 26-byte MindCode, the emotion dynamics,
/// age, and SQLite persistence. Tests check directions and invariants rather than
/// exact tuning constants.
@Suite struct MindEngineTests {
    static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Helpers

    /// Deterministic pseudo-random generator (SplitMix64).
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A state with every feeling at its baseline (ageless default personality unless given).
    static func restingState(personality: Personality = Personality(), age: AgeSettings = AgeSettings(), at t: Date = t0) -> InnerState {
        InnerState(personality: personality, age: age, updatedAt: t)
    }

    static func distance(_ a: Double, _ b: Double) -> Double { abs(a - b) }

    static let present = EmotionEngine.Circumstances(userPresent: true, asleep: false)
    static let alone = EmotionEngine.Circumstances(userPresent: false, asleep: false)
    static let sleeping = EmotionEngine.Circumstances(userPresent: false, asleep: true)

    static func hostile(_ h: Double = 0.7, intensity: Double = 0.5) -> Appraisal {
        var a = Appraisal()
        a.hostility = h
        a.valence = -0.7
        a.dominance = 0.6
        a.intensity = intensity
        return a
    }

    static func kind() -> Appraisal {
        var a = Appraisal()
        a.warmth = 0.6
        a.praise = 0.5
        a.affection = 0.6
        a.gratitude = 0.3
        a.valence = 0.7
        return a
    }

    static func tempDB() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "MindEngineTests-\(UUID().uuidString).sqlite")
    }

    static func removeDB(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path(percentEncoded: false) + suffix))
        }
    }

    // MARK: - MindCode

    @Test func mindCodeRoundTripIs52HexCharsWithBoundedQuantizationError() throws {
        var rng = SplitMix(state: 42)
        for _ in 0..<200 {
            var p = Personality(), f = Feelings()
            for t in Trait.allCases { p[t] = Double.random(in: 0...1, using: &rng) }
            for fe in Feeling.allCases { f[fe] = Double.random(in: 0...1, using: &rng) }
            let code = MindCode(personality: p, feelings: f)
            #expect(code.hex.count == 52)
            #expect(code.bytes.count == 26)
            #expect(MindCode.parameterCount == 26)
            #expect(code.hex.allSatisfy { $0.isHexDigit && !$0.isLowercase })
            let decoded = try #require(MindCode(hex: code.hex))
            #expect(decoded == code)
            // Lower-case and grouped forms decode to the same thing.
            #expect(MindCode(hex: code.hex.lowercased()) == code)
            #expect(MindCode(hex: code.display.replacingOccurrences(of: "·", with: "-")) == code)
            // Re-encoding the decoded values is stable.
            #expect(MindCode(personality: decoded.personality, feelings: decoded.feelings) == code)
            for t in Trait.allCases { #expect(abs(decoded.personality[t] - p[t]) <= 1.0 / 510 + 1e-12) }
            for fe in Feeling.allCases { #expect(abs(decoded.feelings[fe] - f[fe]) <= 1.0 / 510 + 1e-12) }
        }
    }

    @Test func mindCodeExtremesMapTo00AndFF() {
        var p = Personality(), f = Feelings()
        for t in Trait.allCases { p[t] = 0 }
        for fe in Feeling.allCases { f[fe] = 1 }
        let code = MindCode(personality: p, feelings: f)
        #expect(code.hex == String(repeating: "00", count: 13) + String(repeating: "FF", count: 13))
    }

    @Test func mindCodeRejectsInvalidHex() {
        let good = String(repeating: "7F", count: 26)
        #expect(MindCode(hex: good) != nil)
        #expect(MindCode(hex: "") == nil)
        #expect(MindCode(hex: String(good.dropLast())) == nil)        // 51 chars
        #expect(MindCode(hex: good + "00") == nil)                    // 54 chars
        #expect(MindCode(hex: "ZZ" + String(good.dropFirst(2))) == nil)
        #expect(MindCode(hex: "0G" + String(good.dropFirst(2))) == nil)
        // UInt8(_:radix:) alone would accept a "+" sign; every character must be hex.
        #expect(MindCode(hex: "+1" + String(good.dropFirst(2))) == nil)
        #expect(MindCode(hex: "-1" + String(good.dropFirst(2))) == nil)
        #expect(MindCode(hex: "+" + String(good.dropFirst(1))) == nil)
        #expect(MindCode(hex: "0x" + String(good.dropFirst(2))) == nil)
    }

    @Test func mindCodeOrderingMatchesDocumentedLayout() {
        let traitOrder: [DeeMind.Trait] = [.openness, .conscientiousness, .extraversion, .agreeableness, .neuroticism, .playfulness,
                                   .curiosity, .patience, .confidence, .sensitivity, .humor, .assertiveness, .forgiveness]
        let feelingOrder: [Feeling] = [.joy, .sadness, .anger, .fear, .surprise, .interest, .boredom,
                                       .affection, .trust, .loneliness, .energy, .gratitude, .resentment]
        #expect(Trait.allCases == traitOrder)
        #expect(Feeling.allCases == feelingOrder)

        for (i, t) in traitOrder.enumerated() {
            var p = Personality()
            for x in Trait.allCases { p[x] = 0 }
            p[t] = 1
            let code = MindCode(personality: p, feelings: Feelings())
            #expect(code.bytes[i] == 0xFF, "trait \(t) should be byte \(i)")
            #expect(code.bytes.enumerated().allSatisfy { $0.offset == i || $0.element == 0 })
            #expect(code[t] == 0xFF)
        }
        for (i, fe) in feelingOrder.enumerated() {
            var p = Personality()
            for x in Trait.allCases { p[x] = 0 }
            var f = Feelings()
            f[fe] = 1
            let code = MindCode(personality: p, feelings: f)
            #expect(code.bytes[13 + i] == 0xFF, "feeling \(fe) should be byte \(13 + i)")
            #expect(code.bytes.enumerated().allSatisfy { $0.offset == 13 + i || $0.element == 0 })
            #expect(code[fe] == 0xFF)
            let start = code.hex.index(code.hex.startIndex, offsetBy: (13 + i) * 2)
            #expect(code.hex[start..<code.hex.index(start, offsetBy: 2)] == "FF")
        }
    }

    // MARK: - Decay

    @Test(arguments: Feeling.allCases.filter { $0.baseHalfLife.isFinite })
    func feelingsDecayTowardBaseline(_ feeling: Feeling) {
        let rest = Self.restingState()
        let base = rest.feelings
        for start in [0.0, 1.0] where Self.distance(start, base[feeling]) > 0.1 {
            var s = rest
            s.feelings[feeling] = start
            let h = EmotionEngine.halfLife(feeling, s.personality, age: nil)
            #expect(h > 0 && h.isFinite)
            let d0 = Self.distance(start, base[feeling])

            // Circumstances that add no explicit drive to this feeling: boredom creeps
            // up while someone is present, and affection erodes under long neglect.
            let c = feeling == .boredom ? Self.sleeping : Self.present
            let short = EmotionEngine.advance(s, to: Self.t0 + h / 4, circumstances: c)
            let half = EmotionEngine.advance(s, to: Self.t0 + h, circumstances: c)
            let long = EmotionEngine.advance(s, to: Self.t0 + h * 20, circumstances: c)
            let d1 = Self.distance(short.feelings[feeling], base[feeling])
            let d2 = Self.distance(half.feelings[feeling], base[feeling])
            let d3 = Self.distance(long.feelings[feeling], base[feeling])
            #expect(d1 < d0, "\(feeling) from \(start) should move toward baseline")
            #expect(d2 < d1)
            #expect(abs(d2 - d0 / 2) < 0.02, "\(feeling): one half-life should halve the gap (\(d2) vs \(d0 / 2))")
            #expect(d3 < 0.01, "\(feeling) should settle at baseline")
        }
    }

    @Test func advanceIsNoOpForNonPositiveTime() {
        var s = Self.restingState()
        s.feelings[.anger] = 0.8
        #expect(EmotionEngine.advance(s, to: Self.t0, circumstances: Self.alone) == s)
        #expect(EmotionEngine.advance(s, to: Self.t0 - 100, circumstances: Self.alone) == s)
    }

    @Test func angerDecaysFasterThanResentment() {
        var s = Self.restingState()
        s.feelings[.anger] = 0.8
        s.feelings[.resentment] = 0.8
        let later = EmotionEngine.advance(s, to: Self.t0 + 30 * 60, circumstances: Self.present)
        #expect(later.feelings[.anger] / 0.8 < later.feelings[.resentment] / 0.8)
        #expect(EmotionEngine.halfLife(.anger, s.personality, age: nil) < EmotionEngine.halfLife(.resentment, s.personality, age: nil))
        // Fading anger leaves some residue as resentment.
        var onlyAnger = Self.restingState()
        onlyAnger.feelings[.anger] = 0.9
        let after = EmotionEngine.advance(onlyAnger, to: Self.t0 + 20 * 60, circumstances: Self.present)
        #expect(after.feelings[.resentment] > 0)
    }

    @Test func forgivenessShortensGrudges() {
        var forgiving = Personality(), unforgiving = Personality()
        forgiving[.forgiveness] = 0.95
        unforgiving[.forgiveness] = 0.05
        #expect(EmotionEngine.halfLife(.resentment, forgiving, age: nil) < EmotionEngine.halfLife(.resentment, unforgiving, age: nil))

        var a = Self.restingState(personality: forgiving), b = Self.restingState(personality: unforgiving)
        a.feelings[.resentment] = 0.8
        b.feelings[.resentment] = 0.8
        let a2 = EmotionEngine.advance(a, to: Self.t0 + 6 * 3600, circumstances: Self.present)
        let b2 = EmotionEngine.advance(b, to: Self.t0 + 6 * 3600, circumstances: Self.present)
        #expect(a2.feelings[.resentment] < b2.feelings[.resentment])
    }

    // MARK: - Interactions

    @Test func apologyReducesAngerAndResentment() {
        var s = Self.restingState()
        s.feelings[.anger] = 0.7
        s.feelings[.resentment] = 0.5
        var apology = Appraisal()
        apology.apology = 0.8
        apology.valence = 0.2
        var plain = Appraisal()
        plain.valence = 0

        let t = Self.t0 + 1
        let withApology = EmotionEngine.apply(apology, to: s, at: t)
        let without = EmotionEngine.apply(plain, to: s, at: t)
        #expect(withApology.feelings[.anger] < s.feelings[.anger])
        #expect(withApology.feelings[.resentment] < s.feelings[.resentment])
        #expect(withApology.feelings[.anger] < without.feelings[.anger])
        #expect(withApology.feelings[.resentment] < without.feelings[.resentment])
        #expect(withApology.apologyFatigue > s.apologyFatigue)
    }

    @Test func apologyFatigueDiminishesRepeatedApologies() {
        var s = Self.restingState()
        s.feelings[.anger] = 0.7
        s.feelings[.resentment] = 0.5
        var apology = Appraisal()
        apology.apology = 0.8

        let first = EmotionEngine.apply(apology, to: s, at: Self.t0 + 1)
        let firstDrop = s.feelings[.anger] - first.feelings[.anger]

        // Same grievance again, but Dee has just heard several apologies.
        var tired = first
        for i in 2...4 {
            tired.feelings[.anger] = 0.7
            tired.feelings[.resentment] = 0.5
            tired = EmotionEngine.apply(apology, to: tired, at: Self.t0 + Double(i))
        }
        var again = tired
        again.feelings[.anger] = 0.7
        again.feelings[.resentment] = 0.5
        let later = EmotionEngine.apply(apology, to: again, at: Self.t0 + 5)
        let laterDrop = again.feelings[.anger] - later.feelings[.anger]
        #expect(tired.apologyFatigue > first.apologyFatigue)
        #expect(laterDrop < firstDrop, "repeated apologies should help less (\(laterDrop) vs \(firstDrop))")
        #expect(laterDrop > 0, "an apology should still help a little")

        // Fatigue wears off with time.
        let rested = EmotionEngine.advance(tired, to: Self.t0 + 6 * 3600, circumstances: Self.alone)
        #expect(rested.apologyFatigue < tired.apologyFatigue * 0.1)
    }

    @Test func kindnessRaisesRegardAndCoolsAnger() {
        let s = Self.restingState()
        let after = EmotionEngine.apply(Self.kind(), to: s, at: Self.t0 + 1)
        #expect(EmotionEngine.regard(after.feelings) > EmotionEngine.regard(s.feelings))
        #expect(after.feelings[.affection] > s.feelings[.affection])
        #expect(after.feelings[.joy] > s.feelings[.joy])
        #expect(after.kindInteractions == 1)
        #expect(after.interactions == 1)

        var angry = Self.restingState()
        angry.feelings[.anger] = 0.6
        let soothed = EmotionEngine.apply(Self.kind(), to: angry, at: Self.t0 + 1)
        let neutral = EmotionEngine.apply(Appraisal(), to: angry, at: Self.t0 + 1)
        #expect(soothed.feelings[.anger] < neutral.feelings[.anger])
    }

    @Test func hostilityLowersRegard() {
        let s = Self.restingState()
        let after = EmotionEngine.apply(Self.hostile(), to: s, at: Self.t0 + 1)
        #expect(EmotionEngine.regard(after.feelings) < EmotionEngine.regard(s.feelings))
        #expect(after.feelings[.anger] > s.feelings[.anger])
        #expect(after.hostileInteractions == 1)
        // Higher intensity (shouting) hurts more for the same words.
        let loud = EmotionEngine.apply(Self.hostile(intensity: 1), to: s, at: Self.t0 + 1)
        let quiet = EmotionEngine.apply(Self.hostile(intensity: 0), to: s, at: Self.t0 + 1)
        #expect(EmotionEngine.regard(loud.feelings) < EmotionEngine.regard(quiet.feelings))
    }

    @Test func shoutedHostilityHurtsMoreThanSoftlySpoken() async throws {
        let words = "you're stupid and useless"
        let shout = Prosody(loudnessDB: -14, peakDB: -4, speechRate: 3.6)
        let soft = Prosody(loudnessDB: -40, peakDB: -32, speechRate: 2.4)
        let loudMind = try Mind(databaseURL: nil, now: Self.t0)
        let softMind = try Mind(databaseURL: nil, now: Self.t0)
        let start = await loudMind.snapshot(at: Self.t0)
        let (loudA, loudSnap) = await loudMind.hear(words, prosody: shout, at: Self.t0 + 5)
        let (softA, softSnap) = await softMind.hear(words, prosody: soft, at: Self.t0 + 5)

        #expect(loudA.loudness > 0.3)
        #expect(softA.loudness < -0.3)
        #expect(loudA.intensity > softA.intensity)
        #expect(loudA.hostility >= softA.hostility)
        #expect(loudA.dominance > softA.dominance)
        #expect(softSnap.regard < start.regard, "even soft insults lower regard")
        #expect(loudSnap.regard < softSnap.regard, "shouted insults lower regard more (\(loudSnap.regard) vs \(softSnap.regard))")
        #expect(loudSnap.code.feelings[.anger] + loudSnap.code.feelings[.fear] > softSnap.code.feelings[.anger] + softSnap.code.feelings[.fear])
    }

    @Test func threatRaisesFear() async throws {
        let s = Self.restingState()
        var a = Appraisal()
        a.threat = 0.8
        a.valence = -0.6
        let after = EmotionEngine.apply(a, to: s, at: Self.t0 + 1)
        #expect(after.feelings[.fear] > s.feelings[.fear] + 0.1)
        #expect(after.feelings[.trust] < s.feelings[.trust])

        let mind = try Mind(databaseURL: nil, now: Self.t0)
        let before = await mind.snapshot(at: Self.t0).code.feelings[.fear]
        let (appraisal, snap) = await mind.hear("I'm going to delete you", at: Self.t0 + 1)
        #expect(appraisal.threat > 0)
        #expect(snap.code.feelings[.fear] > before)
    }

    @Test func lowConfidenceTurnsAggressionIntoFear() {
        var timid = Personality(), bold = Personality()
        timid[.confidence] = 0.1
        bold[.confidence] = 0.9
        let a = Self.hostile(0.8, intensity: 0.8)
        let timidAfter = EmotionEngine.apply(a, to: Self.restingState(personality: timid), at: Self.t0 + 1)
        let boldAfter = EmotionEngine.apply(a, to: Self.restingState(personality: bold), at: Self.t0 + 1)
        #expect(timidAfter.feelings[.fear] > boldAfter.feelings[.fear])
        #expect(timidAfter.feelings[.anger] < boldAfter.feelings[.anger])
    }

    // MARK: - Loneliness and energy

    @Test func lonelinessGrowsWhenAloneAndAwakeAndEasesWithCompany() {
        let s = Self.restingState()
        let alone = EmotionEngine.advance(s, to: Self.t0 + 3 * 3600, circumstances: Self.alone)
        #expect(alone.feelings[.loneliness] > s.feelings[.loneliness] + 0.1)
        let longer = EmotionEngine.advance(alone, to: Self.t0 + 6 * 3600, circumstances: Self.alone)
        #expect(longer.feelings[.loneliness] > alone.feelings[.loneliness])
        #expect(longer.feelings[.loneliness] <= 1)

        // Resting doesn't stop Dee missing the user; it only slows it.
        let asleep = EmotionEngine.advance(alone, to: Self.t0 + 6 * 3600, circumstances: Self.sleeping)
        #expect(asleep.feelings[.loneliness] > alone.feelings[.loneliness], "loneliness still grows while resting alone")
        #expect(asleep.feelings[.loneliness] < longer.feelings[.loneliness], "…but slower than awake")
        let restingWithUser = EmotionEngine.advance(alone, to: Self.t0 + 6 * 3600, circumstances: .init(userPresent: true, asleep: true))
        #expect(restingWithUser.feelings[.loneliness] < alone.feelings[.loneliness])

        let company = EmotionEngine.advance(alone, to: Self.t0 + 3 * 3600 + 15 * 60, circumstances: Self.present)
        #expect(company.feelings[.loneliness] < alone.feelings[.loneliness])

        let talked = EmotionEngine.apply(Self.kind(), to: alone, at: Self.t0 + 3 * 3600 + 1)
        #expect(talked.feelings[.loneliness] < alone.feelings[.loneliness])

        // Extraverts get lonely faster.
        var intro = Personality(), extra = Personality()
        intro[.extraversion] = 0.1
        extra[.extraversion] = 0.95
        let i2 = EmotionEngine.advance(Self.restingState(personality: intro), to: Self.t0 + 2 * 3600, circumstances: Self.alone)
        let e2 = EmotionEngine.advance(Self.restingState(personality: extra), to: Self.t0 + 2 * 3600, circumstances: Self.alone)
        #expect(e2.feelings[.loneliness] > i2.feelings[.loneliness])
    }

    @Test func energyDrainsAwakeRefillsAsleepAndRespectsAgeCeiling() {
        let s = Self.restingState()
        let awake = EmotionEngine.advance(s, to: Self.t0 + 4 * 3600, circumstances: Self.alone)
        #expect(awake.feelings[.energy] < s.feelings[.energy])
        let slept = EmotionEngine.advance(awake, to: Self.t0 + 12 * 3600, circumstances: Self.sleeping)
        #expect(slept.feelings[.energy] > awake.feelings[.energy])
        #expect(slept.feelings[.energy] <= 1)

        // Talking costs a little energy.
        let talked = EmotionEngine.apply(Self.kind(), to: s, at: Self.t0 + 0.001)
        #expect(talked.feelings[.energy] < s.feelings[.energy])

        // An elderly Dee can't refill past its age ceiling.
        let oldAge = AgeSettings(enabled: true, agingEnabled: false, startAge: 95, since: Self.t0)
        let ceiling = AgeModel.effect(age: 95).energyCeiling
        #expect(ceiling < 1)
        var old = Self.restingState(age: oldAge)
        #expect(old.feelings[.energy] <= ceiling + 1e-9)
        old.feelings[.energy] = 1.0
        let clamped = EmotionEngine.advance(old, to: Self.t0 + 60, circumstances: Self.alone)
        #expect(clamped.feelings[.energy] <= ceiling + 1e-9)
        old.feelings[.energy] = 0.1
        let oldSlept = EmotionEngine.advance(old, to: Self.t0 + 24 * 3600, circumstances: Self.sleeping)
        #expect(oldSlept.feelings[.energy] > 0.1)
        #expect(oldSlept.feelings[.energy] <= ceiling + 1e-9)
        #expect(oldSlept.feelings[.energy] > ceiling - 0.05, "a full night's sleep should nearly reach the ceiling")
    }

    // MARK: - Personality drift

    @Test func personalityDriftIsSmallAndBounded() {
        var s = Self.restingState()
        var t = Self.t0
        var maxStep = 0.0
        for _ in 0..<1000 {
            t += 30
            let before = s.personality
            s = EmotionEngine.apply(Self.kind(), to: s, at: t)
            for trait in Trait.allCases {
                maxStep = max(maxStep, abs(s.personality[trait] - before[trait]))
            }
        }
        #expect(maxStep < 0.02, "per-interaction drift should be small (max \(maxStep))")
        for trait in Trait.allCases {
            let v = s.personality[trait]
            #expect(v >= 0 && v <= 1, "\(trait) out of range: \(v)")
            #expect(abs(v - trait.setPoint) <= 0.45, "\(trait) ran away: \(v) vs set point \(trait.setPoint)")
            #expect(v.isFinite)
        }
        // Kindness pushes the expected directions.
        #expect(s.personality[.agreeableness] > Trait.agreeableness.setPoint)
        #expect(s.personality[.neuroticism] < Trait.neuroticism.setPoint)
        #expect(s.personality[.confidence] > Trait.confidence.setPoint)
        // Feelings stay valid too.
        for f in Feeling.allCases { #expect(s.feelings[f] >= 0 && s.feelings[f] <= 1) }

        // And hostility pushes the other way, still bounded.
        var h = Self.restingState()
        for i in 0..<1000 { h = EmotionEngine.apply(Self.hostile(0.9, intensity: 1), to: h, at: Self.t0 + Double(i) * 30) }
        for trait in Trait.allCases {
            #expect(h.personality[trait] >= 0 && h.personality[trait] <= 1)
            #expect(abs(h.personality[trait] - trait.setPoint) <= 0.6)
        }
        #expect(h.personality[.agreeableness] < Trait.agreeableness.setPoint)
        #expect(h.personality[.neuroticism] > Trait.neuroticism.setPoint)
    }

    // MARK: - Read-outs

    @Test func regardColorRunsRedYellowGreen() {
        let red = EmotionEngine.regardColor(-1)
        #expect(red.r > red.g + 0.3)
        #expect(red.r > red.b)

        let yellow = EmotionEngine.regardColor(0)
        #expect(abs(yellow.r - yellow.g) < 0.15)
        #expect(yellow.b < min(yellow.r, yellow.g) - 0.4)

        let green = EmotionEngine.regardColor(1)
        #expect(green.g > green.r + 0.3)
        #expect(green.g > green.b)

        // Monotone hue shift: green share rises, red share falls with regard.
        var lastG = -1.0, lastR = 2.0
        for i in stride(from: -1.0, through: 1.0, by: 0.1) {
            let c = EmotionEngine.regardColor(i)
            for v in [c.r, c.g, c.b] { #expect(v >= -1e-9 && v <= 1 + 1e-9) }
            if i <= 0 { #expect(c.g >= lastG - 1e-9) } else { #expect(c.r <= lastR + 1e-9) }
            lastG = c.g; lastR = c.r
        }
        // Clamps out-of-range input.
        #expect(EmotionEngine.regardColor(-5) == EmotionEngine.regardColor(-1))
        #expect(EmotionEngine.regardColor(5) == EmotionEngine.regardColor(1))
    }

    @Test func regardSignMatchesFeelings() {
        var hate = Feelings([.energy: 1, .affection: 0.1, .trust: 0.1])
        hate[.anger] = 0.9
        hate[.resentment] = 0.8
        var love = Feelings([.energy: 1, .affection: 0.95, .trust: 0.9, .joy: 0.8, .gratitude: 0.5])
        love[.anger] = 0
        #expect(EmotionEngine.regard(hate) < -0.5)
        #expect(EmotionEngine.regard(love) > 0.5)
        #expect(EmotionEngine.regard(hate) >= -1 && EmotionEngine.regard(love) <= 1)
        let fresh = Self.restingState().feelings
        #expect(abs(EmotionEngine.regard(fresh)) < 0.4, "a fresh Dee is roughly neutral toward the user")
    }

    @Test func dominantEmotionIsSensible() {
        func f(_ v: [Feeling: Double]) -> Feelings { Feelings(v.merging([.energy: v[.energy] ?? 1]) { a, _ in a }) }
        #expect(EmotionEngine.dominantEmotion(f([.anger: 0.9])) == .angry)
        #expect(EmotionEngine.dominantEmotion(f([.fear: 0.9])) == .scared)
        #expect(EmotionEngine.dominantEmotion(f([.sadness: 0.9])) == .sad)
        #expect(EmotionEngine.dominantEmotion(f([.surprise: 0.95])) == .surprised)
        #expect(EmotionEngine.dominantEmotion(f([.joy: 0.95, .affection: 0.95])) == .love)
        #expect(EmotionEngine.dominantEmotion(f([.joy: 0.9, .affection: 0.4])) == .joy)
        #expect(EmotionEngine.dominantEmotion(f([.joy: 0.6, .affection: 0.4])) == .happy)
        #expect(EmotionEngine.dominantEmotion(f([.interest: 0.9])) == .curious)
        #expect(EmotionEngine.dominantEmotion(f([.energy: 0.02])) == .sleepy)
        #expect(EmotionEngine.dominantEmotion(f([:])) == .neutral)
    }

    // MARK: - Age

    @Test func ageSettingsDisabledFrozenAndAging() {
        let off = AgeSettings(enabled: false, agingEnabled: true, startAge: 10, since: Self.t0, yearsPerDay: 1)
        #expect(off.age(at: Self.t0 + 86_400 * 50) == nil)

        let frozen = AgeSettings(enabled: true, agingEnabled: false, startAge: 10, since: Self.t0, yearsPerDay: 1)
        #expect(frozen.age(at: Self.t0) == 10)
        #expect(frozen.age(at: Self.t0 + 86_400 * 365) == 10)

        let aging = AgeSettings(enabled: true, agingEnabled: true, startAge: 6, since: Self.t0, yearsPerDay: 0.1)
        #expect(abs(aging.age(at: Self.t0)! - 6) < 1e-9)
        #expect(abs(aging.age(at: Self.t0 + 86_400 * 10)! - 7) < 1e-9)
        #expect(abs(aging.age(at: Self.t0 + 86_400 * 0.5)! - 6.05) < 1e-9)
        // Time before `since` never makes Dee younger.
        #expect(aging.age(at: Self.t0 - 86_400 * 10) == 6)

        let realTime = AgeSettings(enabled: true, agingEnabled: true, startAge: 0, since: Self.t0, yearsPerDay: 1.0 / 365)
        #expect(abs(realTime.age(at: Self.t0 + 86_400 * 365)! - 1) < 1e-9)
    }

    @Test func setRateKeepsAgeContinuous() {
        var s = AgeSettings(enabled: true, agingEnabled: true, startAge: 6, since: Self.t0, yearsPerDay: 0.1)
        let switchAt = Self.t0 + 86_400 * 20   // age 8
        let before = s.age(at: switchAt)!
        s.setRate(1.0, at: switchAt)
        #expect(abs(s.age(at: switchAt)! - before) < 1e-9)
        #expect(abs(s.age(at: switchAt + 86_400 * 2)! - (before + 2)) < 1e-9)
        s.setRate(-3, at: switchAt + 86_400 * 2)
        #expect(s.yearsPerDay == 0, "negative rates clamp to zero")
        #expect(abs(s.age(at: switchAt + 86_400 * 100)! - (before + 2)) < 1e-9)

        // Disabled: setRate just updates rate; age stays nil.
        var off = AgeSettings(enabled: false, since: Self.t0)
        off.setRate(0.5, at: Self.t0 + 100)
        #expect(off.age(at: Self.t0 + 1000) == nil)
        #expect(off.yearsPerDay == 0.5)
    }

    @Test func ageModelIsContinuousAcrossKeyAges() {
        #expect(AgeModel.effect(age: nil) == .none)
        var prev = AgeModel.effect(age: 0)
        let step = 0.01
        var a = step
        while a <= 120 {
            let e = AgeModel.effect(age: a)
            #expect(abs(e.halfLifeScale - prev.halfLifeScale) < 0.01, "halfLifeScale jumps at \(a)")
            #expect(abs(e.plasticity - prev.plasticity) < 0.01, "plasticity jumps at \(a)")
            #expect(abs(e.energyCeiling - prev.energyCeiling) < 0.01, "energyCeiling jumps at \(a)")
            for t in Trait.allCases {
                #expect(abs((e.traitOffsets[t] ?? 0) - (prev.traitOffsets[t] ?? 0)) < 0.01, "\(t) offset jumps at \(a)")
            }
            prev = e
            a += step
        }
        // Explicitly straddle each key age.
        for key in [8.0, 16, 30, 70, 100] {
            let lo = AgeModel.effect(age: key - 1e-6), hi = AgeModel.effect(age: key + 1e-6), at = AgeModel.effect(age: key)
            #expect(abs(lo.halfLifeScale - hi.halfLifeScale) < 1e-4)
            #expect(abs(at.halfLifeScale - hi.halfLifeScale) < 1e-4)
            for t in Trait.allCases { #expect(abs((lo.traitOffsets[t] ?? 0) - (hi.traitOffsets[t] ?? 0)) < 1e-4) }
        }
        // Negative ages behave like zero; very old ages plateau.
        #expect(AgeModel.effect(age: -5) == AgeModel.effect(age: 0))
        #expect(AgeModel.effect(age: 150) == AgeModel.effect(age: 100))
    }

    @Test func childFeelingsPassFasterThanElders() {
        let child = AgeModel.effect(age: 5), elder = AgeModel.effect(age: 85)
        #expect(child.halfLifeScale < elder.halfLifeScale)
        #expect(child.plasticity > elder.plasticity)
        #expect(child.energyCeiling >= elder.energyCeiling)
        let p = Personality()
        for f in Feeling.allCases where f.baseHalfLife.isFinite {
            let hc = EmotionEngine.halfLife(f, EmotionEngine.effective(p, age: 5), age: 5)
            let he = EmotionEngine.halfLife(f, EmotionEngine.effective(p, age: 85), age: 85)
            if f != .resentment { #expect(hc < he, "\(f): child \(hc) vs elder \(he)") }
        }
        // Grudges: a child gets over things faster than an elder too.
        var kid = Self.restingState(age: AgeSettings(enabled: true, startAge: 5, since: Self.t0))
        var old = Self.restingState(age: AgeSettings(enabled: true, startAge: 85, since: Self.t0))
        kid.feelings[.anger] = 0.8
        old.feelings[.anger] = 0.8
        let k2 = EmotionEngine.advance(kid, to: Self.t0 + 600, circumstances: Self.present)
        let o2 = EmotionEngine.advance(old, to: Self.t0 + 600, circumstances: Self.present)
        #expect(k2.feelings[.anger] < o2.feelings[.anger])
    }

    @Test func lifeStageBoundaries() {
        #expect(LifeStage(age: 0) == .baby)
        #expect(LifeStage(age: 2.999) == .baby)
        #expect(LifeStage(age: 3) == .child)
        #expect(LifeStage(age: 12.999) == .child)
        #expect(LifeStage(age: 13) == .teen)
        #expect(LifeStage(age: 19.999) == .teen)
        #expect(LifeStage(age: 20) == .adult)
        #expect(LifeStage(age: 59.999) == .adult)
        #expect(LifeStage(age: 60) == .elder)
        #expect(LifeStage(age: 500) == .elder)
        #expect(LifeStage.adult.voiceNote.isEmpty)
        for s in [LifeStage.baby, .child, .teen, .elder] { #expect(!s.voiceNote.isEmpty) }
    }

    // MARK: - Persistence

    @Test func mindPersistsAcrossReopen() async throws {
        let url = Self.tempDB()
        defer { Self.removeDB(url) }
        let ageSettings = AgeSettings(enabled: true, agingEnabled: true, startAge: 9, since: Self.t0, yearsPerDay: 0.25)

        let codeA: MindCode, stateA: InnerState
        do {
            let mind = try Mind(databaseURL: url, now: Self.t0)
            await mind.setAge(ageSettings)
            await mind.hear("Hi Dee, you're so clever, thank you!", at: Self.t0 + 10)
            await mind.hear("you're useless", prosody: Prosody(loudnessDB: -14, peakDB: -4, speechRate: 3.6), at: Self.t0 + 20)
            await mind.hear("sorry, I didn't mean it", at: Self.t0 + 30)
            codeA = await mind.code
            stateA = await mind.state
        }
        #expect(stateA.interactions == 3)

        let reopened = try Mind(databaseURL: url, now: Self.t0 + 999_999)
        let stateB = await reopened.state
        #expect(await reopened.code == codeA)
        #expect(stateB.feelings == stateA.feelings)
        #expect(stateB.personality == stateA.personality)
        #expect(stateB.interactions == stateA.interactions)
        #expect(stateB.kindInteractions == stateA.kindInteractions)
        #expect(stateB.hostileInteractions == stateA.hostileInteractions)
        #expect(abs(stateB.apologyFatigue - stateA.apologyFatigue) < 1e-12)
        #expect(abs(stateB.updatedAt.timeIntervalSince(stateA.updatedAt)) < 1e-3)
        #expect(stateB.age.enabled && stateB.age.agingEnabled)
        #expect(stateB.age.startAge == 9)
        #expect(stateB.age.yearsPerDay == 0.25)
        let probe = Self.t0 + 86_400 * 4
        #expect(abs(stateB.age.age(at: probe)! - ageSettings.age(at: probe)!) < 1e-6)
        let snap = await reopened.snapshot(at: probe)
        #expect(snap.stage == .child)
        #expect(snap.cue.contains("10 robot-years"))
    }

    @Test func restoreAndResetWork() async throws {
        let url = Self.tempDB()
        defer { Self.removeDB(url) }
        let mind = try Mind(databaseURL: url, now: Self.t0)
        let freshCode = await mind.code
        await mind.hear("I love you, buddy", at: Self.t0 + 5)
        await mind.hear("thank you so much", at: Self.t0 + 10)
        #expect(await mind.code != freshCode)
        #expect(await !mind.history().isEmpty)

        let shared = try #require(MindCode(hex: String(repeating: "80", count: 26)))
        await mind.restore(shared, at: Self.t0 + 20)
        #expect(await mind.code == shared)
        #expect(await mind.state.interactions == 2, "restore keeps counters")

        await mind.setAge(AgeSettings(enabled: true, startAge: 40, since: Self.t0))
        await mind.reset(at: Self.t0 + 30)
        let s = await mind.state
        #expect(s.interactions == 0 && s.kindInteractions == 0 && s.hostileInteractions == 0)
        #expect(s.apologyFatigue == 0)
        #expect(s.age.enabled && s.age.startAge == 40, "reset keeps age settings")
        #expect(s.personality == Personality())
        #expect(await mind.code == MindCode(personality: Personality(), feelings: EmotionEngine.baselines(personality: Personality(), age: 40)))
        #expect(await mind.history().isEmpty)

        // The reset is persisted.
        let again = try Mind(databaseURL: url, now: Self.t0 + 40)
        #expect(await again.code == mind.code)
        #expect(await again.state.interactions == 0)
    }

    @Test func historyAggregatesAndStoresNoUtteranceText() async throws {
        let url = Self.tempDB()
        defer { Self.removeDB(url) }
        let secret = "Purple elephants dance quietly beneath Saskatoon bridges"
        let secret2 = "my bank pin is zanzibar"
        let day1 = Self.t0
        let day2 = Self.t0 + 86_400 * 2

        let mind = try Mind(databaseURL: url, now: day1)
        await mind.hear(secret, at: day1 + 1)
        await mind.hear("thank you, you're amazing", at: day1 + 2)
        await mind.hear("you're stupid", at: day1 + 3)
        await mind.hear(secret2, at: day2)

        let history = await mind.history()
        #expect(history.count == 2)
        #expect(history.map(\.interactions) == [3, 1])
        #expect(history[0].day < history[1].day, "history is chronological")
        for h in history {
            #expect(h.regard >= -1 && h.regard <= 1)
            #expect(h.day.count == 10)
        }
        #expect(await mind.history(days: 1).count == 1)
        #expect(await mind.state.interactions == 4)

        // Scan every text value in every table for the spoken sentences.
        let db = try SQLiteStore(path: url.path(percentEncoded: false))
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type = 'table'").compactMap { $0["name"]?.string }
        #expect(Set(tables).isSuperset(of: ["meta", "parameters", "daily"]))
        var scanned = 0
        let needles = [secret, secret2, "elephants", "saskatoon", "zanzibar", "stupid", "amazing"].map { $0.lowercased() }
        for table in tables {
            for row in try db.query("SELECT * FROM \"\(table)\"") {
                for (_, value) in row {
                    guard case .text(let text) = value else { continue }
                    scanned += 1
                    let lower = text.lowercased()
                    for n in needles { #expect(!lower.contains(n), "table \(table) stores utterance text: \(text)") }
                }
            }
        }
        #expect(scanned > 0)

        // Belt and braces: the raw database files never contain the words either.
        for suffix in ["", "-wal"] {
            let path = url.path(percentEncoded: false) + suffix
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            let raw = String(decoding: data, as: UTF8.self).lowercased()
            for n in needles { #expect(!raw.contains(n), "\(suffix.isEmpty ? "db" : suffix) file contains \(n)") }
        }
    }

    @Test func inMemoryMindHasNoHistory() async throws {
        let mind = try Mind(databaseURL: nil, now: Self.t0)
        await mind.hear("hello there", at: Self.t0 + 1)
        #expect(await mind.history().isEmpty)
        #expect(await mind.state.interactions == 1)
    }
}
