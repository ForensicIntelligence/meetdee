import DeeCore
import Testing
@testable import DeeVoice

@Suite struct VoiceStyleTests {
    func style(_ e: Emotion, age: Double? = nil, energy: Double = 0.6) -> VoiceStyle {
        VoiceStyle.forMood(emotion: e, age: age, energy: energy)
    }

    @Test func neutralIsCuteBase() {
        let s = style(.neutral)
        #expect(abs(s.pitch - 1.35) < 0.001)
        #expect(s.rate > 0.5 && s.rate < 0.55)
        #expect(s.volume == 1)
    }

    @Test func excitedAndGiddyAreFasterAndHigher() {
        let n = style(.neutral)
        for e in [Emotion.excited, .giddy, .joy] {
            let s = style(e)
            #expect(s.pitch > n.pitch, "\(e)")
            #expect(s.rate > n.rate, "\(e)")
        }
    }

    @Test func sadHurtLonelyAreSlowerAndLower() {
        let n = style(.neutral)
        for e in [Emotion.sad, .hurt, .lonely] {
            let s = style(e)
            #expect(s.pitch < n.pitch, "\(e)")
            #expect(s.rate < n.rate, "\(e)")
        }
    }

    @Test func sleepyIsSlowAndQuiet() {
        let s = style(.sleepy)
        #expect(s.rate < style(.sad).rate + 0.001)
        #expect(s.volume < 1)
    }

    @Test func ageShapesVoice() {
        let adult = style(.neutral, age: 30)
        let baby = style(.neutral, age: 1)
        let child = style(.neutral, age: 8)
        let elder = style(.neutral, age: 85)
        #expect(baby.pitch > child.pitch)
        #expect(child.pitch > adult.pitch)
        #expect(elder.pitch < adult.pitch)
        #expect(elder.rate < adult.rate)
        #expect(style(.neutral, age: nil) == style(.neutral, age: 40))
    }

    @Test func ageCurveIsContinuous() {
        var previous = style(.neutral, age: 0).pitch
        for a in stride(from: 0.5, through: 120, by: 0.5) {
            let p = style(.neutral, age: a).pitch
            #expect(abs(p - previous) < 0.02, "jump at age \(a)")
            previous = p
        }
    }

    @Test func lowEnergySlowsHer() {
        let rested = style(.neutral, energy: 0.6)
        let tired = style(.neutral, energy: 0.05)
        #expect(tired.rate < rested.rate)
        #expect(tired.pitch < rested.pitch)
        #expect(tired.volume < rested.volume)
    }

    /// Reflexes sit above mood: even exhausted, a laugh is still brighter and quicker
    /// than her neutral voice when rested.
    @Test func brightReflexSurvivesLowEnergy() {
        let laughingWhileTired = style(.giddy, energy: 0.0)
        let neutralRested = style(.neutral, energy: 0.6)
        #expect(laughingWhileTired.pitch > neutralRested.pitch)
        #expect(laughingWhileTired.rate > neutralRested.rate)
        // And low energy drags a bright feeling less than a dull one.
        let brightDrop = style(.giddy, energy: 0.6).rate - style(.giddy, energy: 0).rate
        let dullDrop = style(.bored, energy: 0.6).rate - style(.bored, energy: 0).rate
        #expect(brightDrop < dullDrop)
    }

    @Test func everyEmotionStaysInRange() {
        for e in Emotion.allCases {
            for age in [nil, 0, 2, 15, 45, 70, 120, -5, 500] as [Double?] {
                for energy in [-1, 0, 0.3, 0.6, 1, 2, Double.nan] {
                    let s = VoiceStyle.forMood(emotion: e, age: age, energy: energy)
                    #expect((0.5...2).contains(s.pitch))
                    #expect((0.3...0.7).contains(s.rate))
                    #expect((0.4...1).contains(s.volume))
                }
            }
        }
    }

    @Test func distinctEmotionsSoundDistinct() {
        let styles = Set(Emotion.allCases.map { e -> String in
            let s = style(e)
            return "\(s.pitch)-\(s.rate)-\(s.volume)"
        })
        #expect(styles.count >= 30)
    }

    @Test func laughterPhrasesVaryAndScale() {
        let soft = Set((0..<6).map { Laughter.phrase(intensity: 0.1, variant: $0) })
        let big = Set((0..<6).map { Laughter.phrase(intensity: 0.9, variant: $0) })
        #expect(soft.count >= 2)
        #expect(big.count >= 2)
        #expect(soft.isDisjoint(with: big))
        #expect(!Laughter.phrase(intensity: .nan, variant: -7).isEmpty)
        let laugh = Laughter.style(intensity: 1, age: nil, energy: 0)
        #expect(laugh.pitch > VoiceStyle.forMood(emotion: .neutral, age: nil, energy: 0.6).pitch)
        #expect(laugh.pitch >= VoiceStyle.forMood(emotion: .giddy, age: nil, energy: 0.5).pitch)
    }
}
