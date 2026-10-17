import Testing
@testable import DeeVoice

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
        // -40 dBFS clears the bar when Dee is quiet but not when Dee's at full volume.
        #expect(run(&d, db: -39, frames: 20, level: 1) == false)
        d.reset()
        #expect(run(&d, db: -39, frames: 20, level: 0))
    }
}
