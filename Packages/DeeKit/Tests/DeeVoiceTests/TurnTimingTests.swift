import Foundation
import Testing
@testable import DeeVoice

extension CoreHarness {
    mutating func glide(_ seconds: Double, from: Double, to: Double, amplitude: Double = 0.3) {
        for f in Signal.frames(Signal.glide(from: from, to: to, amplitude: amplitude, seconds: seconds), size: frameSize) { push(f) }
    }

    var pauses: [(turnEnd: Double, hesitation: Double)] {
        events.compactMap { if case .pause(let te, let h) = $0 { (te, h) } else { nil } }
    }

    /// Quiet until `.heard` arrives (or `limit` seconds); returns how long it took.
    mutating func quietUntilHeard(limit: Double = 4) -> Double? {
        let start = t
        while t - start < limit {
            quiet(0.04)
            if !heard().isEmpty { return t - start }
        }
        return nil
    }
}

/// `TurnPredictor` wired into `ListeningCore` with real (synthetic) audio.
@Suite struct TurnTimingTests {
    func primed() -> CoreHarness {
        var h = CoreHarness()
        h.ready()
        h.quiet(1)
        h.clear()
        return h
    }

    @Test func pauseEventsCarryProbabilities() {
        var h = primed()
        h.voice(1.0)
        h.say("I went to the store and", final: false)
        h.voice(0.4)
        h.quiet(0.5)
        let p = h.pauses
        #expect(!p.isEmpty)
        #expect(p.allSatisfy { (0...1).contains($0.turnEnd) && (0...1).contains($0.hesitation) })
        #expect(p.first!.turnEnd < 0.2)                    // trailing "and"
        #expect(h.heard().isEmpty)
    }

    @Test func onePauseEventPerPauseUnlessTheEstimateMoves() throws {
        var h = primed()
        h.voice(1.0)
        h.say("I went to the store.")
        h.glide(0.4, from: 220, to: 150)
        h.quiet(0.7)                                  // evaluated at 0.15 s and again at 0.6 s: same values
        #expect(h.pauses.count == 1)
        var t = primed()
        t.voice(1.0)
        t.say("I went to the store and")
        t.voice(0.4)
        t.quiet(0.7)                                  // at 0.6 s hesitation rises to 0.7: re-sent
        #expect(t.pauses.count == 2)
        #expect(t.pauses.last!.hesitation == 0.7)
    }

    @Test func confidentEndAnswersFasterThanTrailingConjunction() throws {
        var done = primed()
        done.voice(1.0)
        done.say("I went to the store.")
        done.glide(0.4, from: 220, to: 150)
        let fastTook = done.quietUntilHeard()
        let fast = try #require(fastTook)

        var trailing = primed()
        trailing.voice(1.0)
        trailing.say("I went to the store and", final: true)
        trailing.voice(0.4)
        let slowTook = trailing.quietUntilHeard()
        let slow = try #require(slowTook)

        #expect(fast < 0.95)                       // v0.4 fixed: 0.8 s hold + VAD hangover ≈ 1.0 s
        #expect(slow > 1.8)                        // hesitation hold after 0.6 s with a trailing word
        #expect(fast + 0.8 < slow)
        #expect(done.heard().first?.text == "I went to the store.")
        #expect(trailing.heard().first?.text == "I went to the store and")
    }

    @Test func fillersHoldAtLeast1Point8Seconds() throws {
        var h = primed()
        h.voice(1.2)
        h.say("well um I was uh", final: true)
        h.voice(0.4)
        h.quiet(0.4)
        #expect(h.core.quietInterval >= 1.8)
        #expect(h.pauses.contains { $0.hesitation >= 0.6 })
        h.quiet(1.2)
        #expect(h.heard().isEmpty)                 // still waiting through "uh"
        let restTook = h.quietUntilHeard()
        let rest = try #require(restTook)
        #expect(rest < 1.0)
    }

    @Test func userResumingAfterAPauseKeepsOneUtterance() {
        var h = primed()
        h.voice(1.0)
        h.say("so I was thinking", final: false)
        h.voice(0.4)
        h.quiet(0.6)
        h.voice(0.8)
        h.say("so I was thinking we could go out tonight.", final: true)
        h.glide(0.4, from: 220, to: 150)
        _ = h.quietUntilHeard()
        #expect(h.heard().map(\.text) == ["so I was thinking we could go out tonight."])
    }

    @Test func pauseScaleScalesTheDefaultHoldAndIsClamped() {
        var h = primed()
        #expect(h.core.pauseScale == 1)
        #expect(h.core.quietInterval == 0.8)
        h.core.pauseScale = 1.5
        #expect(h.core.pauseScale == 1.5)
        #expect(abs(h.core.quietInterval - 1.2) < 1e-12)
        h.core.pauseScale = 9
        #expect(h.core.pauseScale == 1.6)
        h.core.pauseScale = 0.2
        #expect(h.core.pauseScale == 0.7)
        #expect(abs(h.core.quietInterval - 0.56) < 1e-12)
    }

    @Test func slowSpeakerScaleLengthensPredictedHold() throws {
        func hold(scale: Double) throws -> Double {
            var h = primed()
            h.core.pauseScale = scale
            h.voice(1.0)
            h.say("I went to the store")
            h.voice(0.4)
            h.quiet(0.4)
            return try #require(h.core.turnEstimate).hold
        }
        let typical = try hold(scale: 1), slow = try hold(scale: 1.5)
        #expect(abs(slow - min(typical * 1.5, 2.5)) < 1e-9)
    }

    @Test func pauseScaleLearnsFromWithinTurnPauses() {
        var h = primed()
        for _ in 0..<3 {
            h.voice(0.8)
            h.say("I went", final: false)
            h.voice(0.3)
            h.quiet(1.1)                           // a long thinking pause; trailing-free text, hold ≥ 1.1?
            h.voice(0.8)
            h.say("I went to the store yesterday.", final: true)
            h.glide(0.4, from: 220, to: 150)
            _ = h.quietUntilHeard()
            h.clear()
            h.quiet(0.5)
        }
        #expect(h.core.pauseScale > 1.1)
    }

    @Test func disabledPredictionIsTheV04Behaviour() throws {
        var h = primed()
        h.core.turnPredictionEnabled = false
        h.voice(1.0)
        h.say("I went to the store and")
        h.voice(0.4)
        let tookOpt = h.quietUntilHeard()
        let took = try #require(tookOpt)
        #expect(h.pauses.isEmpty)
        #expect(h.core.quietInterval == 0.8)
        #expect(took > 0.9 && took < 1.15)
    }

    @Test func holdResetsForTheNextUtterance() throws {
        var h = primed()
        h.voice(1.0)
        h.say("well um I was uh")
        h.voice(0.4)
        let took = h.quietUntilHeard()
        #expect(took != nil)
        #expect(h.core.quietInterval == 0.8)
        #expect(h.core.turnEstimate == nil)
    }

    @Test func noPauseEventsWhileNotListening() {
        var h = CoreHarness()
        h.quiet(0.5)
        h.voice(1)
        h.quiet(1)
        #expect(h.pauses.isEmpty)
        var s = CoreHarness()
        s.ready(aec: false)                         // half-duplex: deaf while she speaks
        s.quiet(1)
        s.log += s.core.speechRequested(at: s.t)
        s.voice(1)
        s.quiet(1)
        #expect(s.pauses.isEmpty)
    }
}

@Suite struct VoiceServiceTimingPassthroughTests {
    @Test func pauseScaleAndPredictionPassThrough() {
        let v = VoiceService()
        #expect(v.pauseScale == 1)
        v.pauseScale = 1.4
        #expect(v.pauseScale == 1.4)
        v.pauseScale = 3
        #expect(v.pauseScale == 1.6)
        #expect(v.turnPredictionEnabled)
        v.turnPredictionEnabled = false
        #expect(!v.turnPredictionEnabled)
        v.shutdown()
    }
}
