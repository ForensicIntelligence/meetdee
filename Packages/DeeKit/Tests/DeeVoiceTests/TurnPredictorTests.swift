import Foundation
import Testing
@testable import DeeVoice

/// Feeds `TurnPredictor` synthetic pitch / energy tracks on a 40 ms grid.
struct PredictorHarness {
    var p = TurnPredictor()
    var t = 0.0
    let dt = 0.04

    /// `seconds` of sounding speech; pitch glides linearly `fromHz → toHz`, level
    /// `fromDB → toDB`.
    mutating func speak(_ seconds: Double, fromHz: Double = 200, toHz: Double? = nil,
                        fromDB: Double = -20, toDB: Double? = nil) {
        let n = Int((seconds / dt).rounded())
        for i in 0..<n {
            let x = n > 1 ? Double(i) / Double(n - 1) : 0
            let hz = fromHz + ((toHz ?? fromHz) - fromHz) * x
            let db = fromDB + ((toDB ?? fromDB) - fromDB) * x
            t += dt
            p.frame(sounding: true, db: db, f0Hz: hz, duration: dt, at: t)
        }
    }

    /// Silence for `seconds`; returns the estimates the predictor produced.
    mutating func pause(_ seconds: Double, scale: Double = 1) -> [TurnPredictor.Estimate] {
        var out: [TurnPredictor.Estimate] = []
        let n = Int((seconds / dt).rounded())
        for _ in 0..<n {
            t += dt
            p.frame(sounding: false, db: -70, f0Hz: nil, duration: dt, at: t)
            if let e = p.update(at: t, pauseScale: scale) { out.append(e) }
        }
        return out
    }

    /// Text that is already stable when the pause starts.
    mutating func text(_ s: String) { p.partial(s, at: t - 1) }
}

@Suite struct TurnPredictorFeatureTests {
    @Test func lexicalFeatures() {
        let done = TurnPredictor.lexical("I went to the store")
        #expect(done.lexComplete == 1 && done.lexTrailing == 0 && done.filler == 0 && done.short == 0)
        let and = TurnPredictor.lexical("I went to the store and")
        #expect(and.lexComplete == 0 && and.lexTrailing == 1)
        let um = TurnPredictor.lexical("I was thinking, ummm")
        #expect(um.filler == 1 && um.lexComplete == 0)
        #expect(TurnPredictor.lexical("Well, hmmm...").filler == 1)
        let one = TurnPredictor.lexical("so")
        #expect(one.short == 1 && one.lexTrailing == 1 && one.lexComplete == 0)
        #expect(TurnPredictor.lexical("").short == 1)
        #expect(TurnPredictor.lexical("Two words").lexComplete == 0)       // needs ≥ 3
        #expect(TurnPredictor.lexical("Because, like,").lexTrailing == 1)   // punctuation stripped
    }

    @Test func questionNeedsWordsNotJustPunctuation() {
        #expect(TurnPredictor.lexical("are you okay?").lexQuestion == 1)
        #expect(TurnPredictor.lexical("?").lexQuestion == 0)
        #expect(TurnPredictor.lexical("um?").lexQuestion == 0)
        #expect(TurnPredictor.lexical("is it the?").lexQuestion == 0)       // trailing word
        #expect(TurnPredictor.lexical("are you okay").lexQuestion == 0)
    }

    @Test func hesitationScores() {
        #expect(TurnPredictor.hesitation(text: "well um I was uh", pause: 0.2, speechRate: nil, baselineRate: nil) == 0.8)
        #expect(TurnPredictor.hesitation(text: "um", pause: 0.2, speechRate: nil, baselineRate: nil) == 1)
        #expect(TurnPredictor.hesitation(text: "I I want the", pause: 0.2, speechRate: nil, baselineRate: nil) == 0.5)
        #expect(TurnPredictor.hesitation(text: "I wa- want it", pause: 0.2, speechRate: nil, baselineRate: nil) == 0.5)
        #expect(TurnPredictor.hesitation(text: "I went there and", pause: 0.5, speechRate: nil, baselineRate: nil) == 0)
        #expect(TurnPredictor.hesitation(text: "I went there and", pause: 0.7, speechRate: nil, baselineRate: nil) == 0.7)
        #expect(TurnPredictor.hesitation(text: "I went there", pause: 0.3, speechRate: 1.0, baselineRate: 2.5) == 0.4)
        #expect(TurnPredictor.hesitation(text: "I went there", pause: 0.3, speechRate: 2.0, baselineRate: 2.5) == 0)
        #expect(TurnPredictor.hesitation(text: "I went there", pause: 0.3, speechRate: 1.0, baselineRate: nil) == 0)
        #expect(TurnPredictor.hesitation(text: "", pause: 3, speechRate: nil, baselineRate: nil) == 0)
    }

    @Test func turnEndIsTheLogisticOfTheWeightedSum() {
        #expect(abs(TurnPredictor.turnEnd(.init()) - 1 / (1 + exp(0.2))) < 1e-12)
        let f = TurnPredictor.Features(lexComplete: 1, f0Fall: 1, energyDrop: 1)
        #expect(abs(TurnPredictor.turnEnd(f) - 1 / (1 + exp(-(-0.2 + 1.2 + 0.9 + 0.5)))) < 1e-12)
        #expect(f.vector.count == 9)
    }

    @Test func holdFormulaAndBounds() {
        #expect(abs(TurnPredictor.hold(turnEnd: 1, hesitation: 0, pauseScale: 1) - 0.45) < 1e-12)
        #expect(abs(TurnPredictor.hold(turnEnd: 0, hesitation: 0, pauseScale: 1) - 1.4) < 1e-12)
        #expect(abs(TurnPredictor.hold(turnEnd: 0.5, hesitation: 0, pauseScale: 1) - 0.925) < 1e-12)
        #expect(abs(TurnPredictor.hold(turnEnd: 0, hesitation: 0, pauseScale: 1.6) - 2.24) < 1e-12)
        #expect(TurnPredictor.hold(turnEnd: 1, hesitation: 0, pauseScale: 0.7) == 0.35)       // 0.315 clamped
        #expect(TurnPredictor.hold(turnEnd: 0, hesitation: 0, pauseScale: 3) == 2.5)
        #expect(TurnPredictor.hold(turnEnd: .nan, hesitation: 0, pauseScale: .nan) == 1.4)
        for te in stride(from: 0.0, through: 1.0, by: 0.05) {
            for hes in stride(from: 0.0, through: 1.0, by: 0.1) {
                for scale in [0.1, 0.7, 1, 1.3, 1.6, 4] {
                    let h = TurnPredictor.hold(turnEnd: te, hesitation: hes, pauseScale: scale)
                    #expect(TurnPredictor.holdRange.contains(h))
                    if hes >= 0.6 { #expect(h >= 1.8) }
                }
            }
        }
        // Monotone: more confident → shorter hold.
        let holds = stride(from: 0.0, through: 1.0, by: 0.1).map { TurnPredictor.hold(turnEnd: $0, hesitation: 0, pauseScale: 1) }
        #expect(zip(holds, holds.dropFirst()).allSatisfy { $0 > $1 })
    }

    @Test func fillerCollapsing() {
        for w in ["um", "umm", "ummmm", "uh", "uhhh", "er", "erm", "hmm", "hmmmm", "mm", "mmm"] {
            #expect(TurnPredictor.isFiller(w), "\(w)")
        }
        for w in ["summer", "her", "mum", "and", "hum"] { #expect(!TurnPredictor.isFiller(w), "\(w)") }
    }
}

@Suite struct TurnPredictorProsodyTests {
    @Test func fallingPitchAndEnergyDecay() throws {
        var h = PredictorHarness()
        h.speak(1.0, fromHz: 200)
        h.speak(0.4, fromHz: 220, toHz: 150, fromDB: -20, toDB: -36)
        h.text("I went to the store")
        let e = try #require(h.pause(0.2).first)
        #expect(e.features.f0Fall == 1 && e.features.f0Rise == 0 && e.features.f0Flat == 0)
        #expect(e.features.energyDrop == 1)
        #expect(e.features.lexComplete == 1)
        #expect(e.turnEnd > 0.85)
        #expect(e.hold < 0.6)
        #expect((0...1).contains(e.turnEnd) && (0...1).contains(e.hesitation))
    }

    @Test func risingPitchIsAQuestionCue() throws {
        var h = PredictorHarness()
        h.speak(1.0, fromHz: 200)
        h.speak(0.4, fromHz: 190, toHz: 260)
        h.text("you like it")
        let e = try #require(h.pause(0.2).first)
        #expect(e.features.f0Rise == 1 && e.features.f0Fall == 0)
    }

    @Test func flatHighPitchHoldsTheFloor() throws {
        var h = PredictorHarness()
        h.speak(3.0, fromHz: 180)
        h.speak(0.8, fromHz: 210)          // level, above the speaker's mean
        h.text("I went to the store")
        let e = try #require(h.pause(0.2).first)
        #expect(e.features.f0Flat == 1)
        var low = PredictorHarness()
        low.speak(3.0, fromHz: 220)
        low.speak(0.8, fromHz: 180)        // level but below the mean: not a flat-high continuation
        low.text("I went to the store")
        #expect(try #require(low.pause(0.2).first).features.f0Flat == 0)
    }

    @Test func octaveErrorsDoNotFakeAFall() throws {
        var h = PredictorHarness()
        h.speak(1.0, fromHz: 200)
        h.speak(0.36, fromHz: 200)
        h.p.frame(sounding: true, db: -20, f0Hz: 100, duration: 0.04, at: h.t + 0.04)   // one octave-down blip
        h.t += 0.04
        h.text("I went to the store")
        let e = try #require(h.pause(0.2).first)
        #expect(e.features.f0Fall == 0)
    }

    /// SELF.md §12.1: trailing "and" < plain clause < falling clause.
    @Test func monotonicity() throws {
        func turnEnd(_ text: String, falling: Bool) throws -> Double {
            var h = PredictorHarness()
            h.speak(1.2, fromHz: 200)
            if falling { h.speak(0.4, fromHz: 220, toHz: 150) } else { h.speak(0.4, fromHz: 196, toHz: 204) }
            h.text(text)
            return try #require(h.pause(0.2).first).turnEnd
        }
        let trailing = try turnEnd("I went to the store and", falling: false)
        let plain = try turnEnd("I went to the store", falling: false)
        let fall = try turnEnd("I went to the store", falling: true)
        #expect(trailing < plain)
        #expect(plain < fall)
        #expect(trailing < 0.2)
        #expect(fall > 0.7)
    }
}

@Suite struct TurnPredictorStreamingTests {
    @Test func lexicalFeaturesUseOnlyStableText() {
        var p = TurnPredictor()
        p.partial("I went", at: 0)
        p.partial("I went to the store and", at: 1.0)
        #expect(p.stableText(at: 1.1) == "I went")
        #expect(p.stableText(at: 1.3) == "I went to the store and")
        p.partial("I went to the store and then", at: 1.35)
        #expect(p.stableText(at: 1.4) == "I went to the store and")
        // A flicker shorter than 300 ms never becomes stable.
        p.partial("I went to the store and then we", at: 1.5)
        #expect(p.stableText(at: 1.6) == "I went to the store and")
    }

    @Test func estimatesAtPauseStartOnTextChangeAndAtLongPause() {
        var h = PredictorHarness()
        h.speak(1.0)
        #expect(h.pause(0.08).isEmpty)                       // < 150 ms: not a pause yet
        let first = h.pause(0.12)                            // 0.12, 0.16 s
        #expect(first.count == 1)
        #expect(first[0].pause >= 0.15 && first[0].pause < 0.2)
        h.p.partial("I went to the store and", at: h.t)     // at 0.20 s
        #expect(h.pause(0.24).isEmpty)                       // 0.24…0.44 s: not stable yet (< 300 ms)
        let changed = h.pause(0.08)                          // 0.48, 0.52 s: stable from 0.50
        #expect(changed.count == 1 && changed[0].features.lexTrailing == 1)
        #expect(changed[0].hesitation == 0)
        // Crossing 0.6 s with a trailing word: hesitation 0.7 → hold ≥ 1.8.
        let late = h.pause(0.2)                              // 0.56…0.72 s
        #expect(late.count == 1)
        #expect(late[0].hesitation == 0.7 && late[0].hold >= 1.8)
        #expect(h.pause(1).isEmpty)
    }

    @Test func noEstimateWithoutSpeech() {
        var h = PredictorHarness()
        #expect(h.pause(1).isEmpty)
        h.speak(0.12)                                        // a click
        #expect(h.pause(1).isEmpty)
    }

    @Test func withinTurnPausesAreMeasured() {
        var h = PredictorHarness()
        h.speak(1)
        _ = h.pause(0.4)
        h.speak(1)
        _ = h.pause(0.08)                                     // too short to count
        h.speak(1)
        _ = h.pause(0.8)
        h.speak(0.5)
        let pauses = h.p.withinTurnPauses
        #expect(pauses.count == 2)
        #expect(abs(pauses[0] - 0.4) < 0.05 && abs(pauses[1] - 0.8) < 0.05)
        let returned = h.p.endTurn(text: "one two three four five six")
        #expect(returned == pauses)
        #expect(h.p.withinTurnPauses.isEmpty)
        #expect(h.p.baselineRate != nil)
    }

    @Test func slowSpeechAgainstBaselineIsHesitant() throws {
        var h = PredictorHarness()
        h.speak(2)
        _ = h.p.endTurn(text: "one two three four five six")    // 3 words/s
        h.speak(3)
        h.text("one two three")                                   // 1 word/s
        let e = try #require(h.pause(0.2).first)
        #expect(e.hesitation == 0.4)
    }

    @Test func resetSpeakerForgetsBaselines() {
        var h = PredictorHarness()
        h.speak(2)
        _ = h.p.endTurn(text: "one two three four")
        #expect(h.p.personMeanSemitones != nil && h.p.baselineRate != nil)
        h.p.resetSpeaker()
        #expect(h.p.personMeanSemitones == nil && h.p.baselineRate == nil)
    }
}

@Suite struct PauseScaleLearnerTests {
    @Test func startsAtPriorAndShrinks() {
        var l = PauseScaleLearner()
        #expect(l.scale == 1)
        l.observe(pauses: [1.0])                         // obs 2.0
        #expect(abs(l.scale - 12.0 / 11.0) < 1e-12)       // (10·1 + 1·2) / 11
        #expect(l.observations == 1)
    }

    @Test func medianOfTheTurn() {
        var l = PauseScaleLearner()
        l.observe(pauses: [0.2, 1.0, 0.4])               // median 0.4 → 0.8
        #expect(abs(l.ewma! - 0.8) < 1e-12)
        var even = PauseScaleLearner()
        even.observe(pauses: [0.3, 0.5])                 // median 0.4
        #expect(abs(even.ewma! - 0.8) < 1e-12)
    }

    @Test func turnsWithoutPausesTeachNothing() {
        var l = PauseScaleLearner()
        l.observe(pauses: [])
        l.observe(pauses: [.nan, -1])
        #expect(l.observations == 0 && l.scale == 1)
    }

    @Test func convergesToTheSpeakerAndStaysClamped() {
        var slow = PauseScaleLearner()
        for _ in 0..<200 { slow.observe(pauses: [0.65]) }  // 1.3
        #expect(abs(slow.scale - 1.3) < 0.03)
        var verySlow = PauseScaleLearner()
        for _ in 0..<200 { verySlow.observe(pauses: [2.0]) }
        #expect(verySlow.scale == 1.6)
        var fast = PauseScaleLearner()
        for _ in 0..<200 { fast.observe(pauses: [0.1]) }
        #expect(fast.scale == 0.7)
        // Shrinkage: early observations move it less than later ones.
        var a = PauseScaleLearner()
        a.observe(pauses: [0.65])
        let step1 = a.scale - 1
        for _ in 0..<20 { a.observe(pauses: [0.65]) }
        #expect(step1 > 0 && step1 < 0.3 / 10 + 1e-9)
        #expect(a.scale - 1 > step1)
    }

    @Test func setReplacesAndClamps() {
        var l = PauseScaleLearner()
        for _ in 0..<5 { l.observe(pauses: [1]) }
        l.set(1.3)
        #expect(l.scale == 1.3 && l.observations == 0)
        l.set(5)
        #expect(l.scale == 1.6)
        l.set(0.1)
        #expect(l.scale == 0.7)
        l.set(.nan)
        #expect(l.scale == 1)
    }
}

@Suite struct QuietIntervalTests {
    @Test func setQuietIntervalClamps() {
        var e = EndpointDetector()
        #expect(e.quietInterval == 0.8)
        e.setQuietInterval(0.1)
        #expect(e.quietInterval == 0.35)
        e.setQuietInterval(9)
        #expect(e.quietInterval == 2.5)
        e.setQuietInterval(1.2)
        #expect(e.quietInterval == 1.2)
        e.setQuietInterval(.nan)
        #expect(e.quietInterval == 1.2)
        e.setQuietInterval(.infinity)
        #expect(e.quietInterval == 1.2)
    }

    @Test func longerHoldWaitsLonger() {
        var e = EndpointDetector()
        e.setQuietInterval(1.8)
        e.final("I was um", at: 0)
        e.voice(true, at: 0)
        #expect(e.check(at: 1.0) == .wait)
        #expect(e.check(at: 1.79) == .wait)
        #expect(e.check(at: 1.81) == .endUtterance("I was um"))
    }
}
