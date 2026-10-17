import DeeCore
import Foundation

/// A persona preset's temperament as DeeMind values: the stored traits (target minus the
/// age offset, so the *effective* traits equal the design targets), the set points, the
/// resting feelings and the 26-byte `MindCode` (persona spec §3 "Storage").
extension PersonaPreset {
    /// The effective trait targets as a `Personality`.
    public var targets: Personality {
        var p = Personality()
        for (i, t) in Trait.allCases.enumerated() where i < traitTargets.count { p[t] = traitTargets[i] }
        return p
    }

    /// Stored traits at `age` (default: the preset's own age): target − `AgeModel` offset,
    /// rounded to 3 decimals. Classic (ageless) stores its targets unchanged.
    public func storedTraits(age: Double? = nil) -> Personality {
        let a = age ?? self.age.map(Double.init)
        let fx = AgeModel.effect(age: a)
        let t = targets
        var p = Personality()
        for trait in Trait.allCases {
            p[trait] = ((t[trait] - (fx.traitOffsets[trait] ?? 0)) * 1000).rounded() / 1000
        }
        return p
    }

    /// The set points (stored traits, as the Mind holds them: quantised).
    public var setPoints: Personality { code.personality }

    /// The preset's age settings: age on at `age`, ageing off (real-time rate if the user
    /// turns it on). nil for Classic (its age settings are left as they are).
    public func ageSettings(at now: Date) -> AgeSettings? {
        guard let age else { return nil }
        return AgeSettings(enabled: true, agingEnabled: false, startAge: Double(age), since: now,
                           yearsPerDay: AgeSettings.adultYearsPerDay)
    }

    /// The preset's state as a code: stored traits, resting feelings at its age.
    public var code: MindCode {
        let a = age.map(Double.init)
        let stored = MindCode(personality: storedTraits(), feelings: Feelings()).personality
        return MindCode(personality: storedTraits(), feelings: EmotionEngine.baselines(personality: stored, age: a))
    }
}
