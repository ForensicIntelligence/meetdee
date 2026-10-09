import AVFAudio
import Foundation
import Testing
@testable import DeeVoice

@Suite struct SoundClassifierBacklogTests {
    @Test func backlogSlotsAreAlwaysReturned() {
        let c = SoundClassifier()
        for _ in 0..<SoundClassifier.maxBacklog { #expect(c.reserve()) }
        #expect(!c.reserve())                                 // saturated
        for _ in 0..<SoundClassifier.maxBacklog { c.release() }
        #expect(c.pendingCount == 0)
        c.release()                                           // never goes negative
        #expect(c.pendingCount == 0)
        #expect(c.reserve())
        c.release()
        c.stop()
        #expect(!c.reserve())
    }

    @Test func analyzedBuffersDrainTheBacklog() async throws {
        let c = SoundClassifier()
        let f = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        for _ in 0..<20 {
            let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: 1600)!
            b.frameLength = 1600
            c.analyze(b, hostTime: 1)
        }
        for _ in 0..<100 where c.pendingCount > 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(c.pendingCount == 0)
        c.stop()
    }

    @Test func resultWindowMapsToHostTime() throws {
        let w = try #require(SoundClassifier.hostWindow(origin: 100, start: 3, duration: 1.5))
        #expect(w.lowerBound == 103 && w.upperBound == 104.5)
        #expect(SoundClassifier.hostWindow(origin: nil, start: 3, duration: 1.5) == nil)
        #expect(SoundClassifier.hostWindow(origin: 100, start: .nan, duration: 1.5) == nil)
    }
}
