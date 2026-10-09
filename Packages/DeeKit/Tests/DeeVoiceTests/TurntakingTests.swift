import Testing
@testable import DeeVoice

@Suite struct EndpointDetectorTests {
    @Test func finalPlusQuietEndsUtterance() {
        var e = EndpointDetector()
        e.volatile("hello", at: 0.5)
        e.final("Hello there.", at: 1.0)
        e.voice(true, at: 1.0)
        #expect(e.check(at: 1.5) == .wait)
        #expect(e.check(at: 1.81) == .endUtterance("Hello there."))
        #expect(e.isEmpty)
        #expect(e.check(at: 5) == .wait)
    }

    @Test func voiceActivityHoldsTheTurnOpen() {
        var e = EndpointDetector()
        e.final("I was thinking", at: 1.0)
        for t in stride(from: 1.0, through: 2.0, by: 0.04) { e.voice(true, at: t) }
        #expect(e.check(at: 2.5) == .wait)          // still talking (no text yet)
        e.final("about robots", at: 2.4)
        #expect(e.check(at: 3.3) == .endUtterance("I was thinking about robots"))
    }

    @Test func volatileTextGetsFinalizedThenAccepted() {
        var e = EndpointDetector()
        e.volatile("maybe tomorrow", at: 1.0)
        #expect(e.check(at: 2.0) == .wait)
        #expect(e.check(at: 2.5) == .finalizeVolatile)
        #expect(e.check(at: 2.6) == .wait)          // asked once only
        #expect(e.check(at: 3.7) == .endUtterance("maybe tomorrow"))
    }

    @Test func finalAfterFinalizeRequestEndsNormally() {
        var e = EndpointDetector()
        e.volatile("good night", at: 1.0)
        #expect(e.check(at: 2.5) == .finalizeVolatile)
        e.final("Good night.", at: 2.6)
        #expect(e.check(at: 3.0) == .wait)
        #expect(e.check(at: 3.5) == .endUtterance("Good night."))
    }

    @Test func steadyNoiseCannotHoldItOpenForever() {
        var e = EndpointDetector()
        e.final("Turn it down", at: 1.0)
        var decision = EndpointDetector.Decision.wait
        var t = 1.0
        while t < 6, decision == .wait {
            e.voice(true, at: t)   // the TV keeps the VAD busy
            decision = e.check(at: t)
            t += 0.04
        }
        #expect(decision == .endUtterance("Turn it down"))
        #expect(t < 4.2)
    }

    @Test func partialTextJoinsFinalAndVolatile() {
        var e = EndpointDetector()
        e.final("  one   two ", at: 0)
        e.volatile("three", at: 0.1)
        #expect(e.text == "one two three")
        e.reset()
        #expect(e.text == "" && e.check(at: 10) == .wait)
    }
}

@Suite struct BargeInDetectorTests {
    func run(_ d: inout BargeInDetector, db: Double, frames: Int, level: Double = 0, aec: Bool = true) -> Bool {
        var fired = false
        for _ in 0..<frames {
            if d.update(frameDB: db, voiced: true, floorDB: -60, ownSpeechLevel: level, aecActive: aec,
                        speaking: true, frameDuration: 0.04) { fired = true }
        }
        return fired
    }

    @Test func loudSustainedSpeechFiresOnce() {
        var d = BargeInDetector()
        #expect(run(&d, db: -25, frames: 10))
        #expect(d.hasFired)
        #expect(run(&d, db: -25, frames: 10) == false)
        d.reset()
        #expect(run(&d, db: -25, frames: 10))
    }

    @Test func shortSpikesAndQuietTalkDoNot() {
        var d = BargeInDetector()
        #expect(run(&d, db: -25, frames: 3) == false)
        #expect(run(&d, db: -55, frames: 50) == false)
    }

    @Test func neverWithoutEchoCancellationOrWhenSilent() {
        var d = BargeInDetector()
        #expect(run(&d, db: -10, frames: 50, aec: false) == false)
        var e = BargeInDetector()
        var fired = false
        for _ in 0..<50 {
            fired = fired || e.update(frameDB: -10, voiced: true, floorDB: -60, ownSpeechLevel: 0,
                                      aecActive: true, speaking: false, frameDuration: 0.04)
        }
        #expect(!fired)
    }

    @Test func echoMarginRaisesTheBarWhileDeeIsLoud() {
        var d = BargeInDetector()
        // -40 dBFS clears the bar when Dee is quiet but not when she's at full volume.
        #expect(run(&d, db: -39, frames: 20, level: 1) == false)
        d.reset()
        #expect(run(&d, db: -39, frames: 20, level: 0))
    }
}

@Suite struct DuplexGateTests {
    @Test func halfDuplexWithResumeDelay() {
        var g = DuplexGate()
        #expect(g.isOpen(at: 0))
        g.speechRequested()
        #expect(!g.isOpen(at: 1))
        g.speechFinished(at: 2)
        #expect(!g.isOpen(at: 2.2))
        #expect(g.isOpen(at: 2.41))
    }

    @Test func bargeInOpensImmediately() {
        var g = DuplexGate()
        g.speechRequested()
        g.bargeIn()
        #expect(g.isOpen(at: 1))
        g.speechFinished(at: 1.5)
        #expect(g.isOpen(at: 1.5))
        g.bargeIn()                       // not speaking: ignored
        #expect(!g.bargedIn)
    }
}
