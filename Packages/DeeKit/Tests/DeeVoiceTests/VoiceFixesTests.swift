import AVFAudio
import Foundation
import Testing
@testable import DeeVoice

/// Regression tests for the v0.4 review fixes (#5, #6, #7, #15, Low items).
@Suite struct UserIsSpeakingTests {
    @Test func trueWhileVoicedAndForAMomentAfter() {
        var h = CoreHarness()
        h.ready()
        h.quiet(1)
        #expect(!h.core.userIsSpeaking(at: h.t))
        h.voice(0.4)
        #expect(h.core.userIsSpeaking(at: h.t))
        h.quiet(0.4)
        #expect(h.core.userIsSpeaking(at: h.t))               // within the 0.6 s hold
        h.quiet(0.4)
        #expect(!h.core.userIsSpeaking(at: h.t))
    }

    @Test func trueWhileWordsAreHeldEvenIfQuiet() {
        var h = CoreHarness()
        h.ready()
        h.quiet(1)
        h.voice(0.3)
        h.say("so I was", final: false)
        h.quiet(0.7)
        #expect(h.core.userIsSpeaking(at: h.t))               // endpoint holds text
        h.quiet(2.5)
        #expect(!h.heard().isEmpty)
        #expect(!h.core.userIsSpeaking(at: h.t))
    }

    @Test func herOwnVoiceIsNotTheUser() {
        var h = CoreHarness()
        h.ready(aec: false)
        h.quiet(1)
        h.log += h.core.speechRequested(at: h.t)
        h.voice(1, amplitude: 0.5)                            // her voice leaking into the mic
        #expect(!h.core.userIsSpeaking(at: h.t))
        h.log += h.core.speakingFinished(at: h.t, started: true)
        h.voice(0.2, amplitude: 0.5)                          // tail inside resumeDelay
        #expect(!h.core.userIsSpeaking(at: h.t))
        h.quiet(0.4)
        h.voice(0.2)                                          // now the user
        #expect(h.core.userIsSpeaking(at: h.t))
    }

    @Test func serviceFlagIsFalseWhenIdle() {
        let v = VoiceService()
        #expect(!v.userIsSpeaking)
        v.shutdown()
    }
}

@Suite struct SpeechRequestedKeepsWordsTests {
    @Test func partialTextIsDeliveredAsHeardNotDeleted() throws {
        var h = CoreHarness()
        h.ready()
        h.quiet(1)
        h.voice(0.6)
        h.say("what do you think", final: false)
        h.clear()
        h.log += h.core.speechRequested(at: h.t)
        let u = try #require(h.heard().first)
        #expect(u.text == "what do you think")
        #expect(u.duration > 0.3)
        #expect(h.log.contains(.finalizeVolatile))            // nothing straddles the pause
        #expect(h.events.contains(.listening(false)))
        #expect(!h.core.userIsSpeaking(at: h.t + 1))
        // Nothing is delivered twice later.
        h.log += h.core.speakingFinished(at: h.t, started: true)
        h.quiet(3)
        #expect(h.heard().count == 1)
    }

    @Test func nothingHeardWhenNothingWasSaid() {
        var h = CoreHarness()
        h.ready()
        h.quiet(1)
        h.clear()
        h.log += h.core.speechRequested(at: h.t)
        #expect(h.heard().isEmpty)
        #expect(h.log.contains(.finalizeVolatile))
    }

    @Test func noFinalizeWhenRecognizerWasClosed() {
        var h = CoreHarness()
        h.quiet(0.5)                                          // recognizer not ready
        h.clear()
        h.log += h.core.speechRequested(at: h.t)
        #expect(!h.log.contains(.finalizeVolatile))
    }
}

@Suite struct OwnVoiceSoundTests {
    func spoke(_ h: inout CoreHarness, aec: Bool, seconds: Double = 1) -> (start: Double, end: Double) {
        h.ready(aec: aec)
        h.quiet(1)
        let start = h.t
        h.log += h.core.speechRequested(at: h.t)
        h.quiet(seconds)
        h.log += h.core.speakingFinished(at: h.t, started: true)
        h.clear()
        return (start, h.t)
    }

    @Test func windowOverlappingHerLaughIsDropped() {
        var h = CoreHarness()
        let s = spoke(&h, aec: false)
        h.quiet(1)
        h.voice(0.3, amplitude: 0.5)
        // A 1.5 s window arriving 1.3 s after she stopped still contains her "Hahaha!".
        h.log += h.core.classified([("laughter", 0.9)], window: (s.end - 0.2)...(s.end + 1.3), at: s.end + 1.3)
        #expect(!h.events.contains { if case .sound = $0 { true } else { false } })
        // Within the 0.3 s guard after her speech: still hers.
        h.log += h.core.classified([("laughter", 0.9)], window: (s.end + 0.2)...(s.end + 1.7), at: s.end + 1.7)
        #expect(!h.events.contains { if case .sound = $0 { true } else { false } })
    }

    @Test func windowAfterHerSpeechCounts() {
        var h = CoreHarness()
        let s = spoke(&h, aec: false)
        h.quiet(0.6)
        h.voice(0.4, amplitude: 0.5)
        h.log += h.core.classified([("laughter", 0.9)], window: (s.end + 0.35)...(s.end + 0.95), at: h.t)
        #expect(h.events.contains { if case .sound(let x) = $0 { x.kind == .laughter } else { false } })
    }

    @Test func windowBeforeSheSpokeCounts() {
        var h = CoreHarness()
        let s = spoke(&h, aec: false)
        h.quiet(0.1)
        h.voice(0.3, amplitude: 0.5)
        h.log += h.core.classified([("door_bell", 0.9)], window: (s.start - 2)...(s.start - 0.5), at: h.t)
        #expect(h.events.contains { if case .sound(let x) = $0 { x.identifier == "door_bell" } else { false } })
    }

    @Test func fallbackTailCoversAWholeWindow() {
        #expect(ListeningCore.ownVoiceTail >= 1.5 + 0.35)
    }
}

@Suite struct LaughOverHerSpeechTests {
    func speaking(aec: Bool) -> CoreHarness {
        var h = CoreHarness()
        h.ready(aec: aec)
        h.quiet(1)
        h.log += h.core.speechRequested(at: h.t)
        h.log += h.core.speakingStarted()
        _ = h.core.speechLevel(0.5, at: h.t)
        h.clear()
        return h
    }

    @Test func loudLaughWhileSheTalksGetsThroughWithEchoCancellation() {
        var h = speaking(aec: true)
        h.voice(0.25, amplitude: 0.6)                         // short: below barge-in sustain
        h.log += h.core.classified([("laughter", 0.9)], at: h.t)
        #expect(h.events.contains { if case .sound(let s) = $0 { s.kind == .laughter && !s.isUnexpected } else { false } })
    }

    @Test func applauseToo() {
        var h = speaking(aec: true)
        h.voice(0.25, amplitude: 0.6)
        h.log += h.core.classified([("speech", 0.9), ("applause", 0.8)], at: h.t)
        #expect(h.events.contains { if case .sound(let s) = $0 { s.kind == .applause } else { false } })
    }

    @Test func faintLaughIsTreatedAsHerEcho() {
        var h = speaking(aec: true)
        h.voice(0.25, amplitude: 0.004)
        h.log += h.core.classified([("laughter", 0.9)], at: h.t)
        #expect(h.events.allSatisfy { if case .sound = $0 { false } else { true } })
    }

    @Test func otherSoundsStayBlockedWhileSheTalks() {
        var h = speaking(aec: true)
        h.voice(0.25, amplitude: 0.6)
        h.log += h.core.classified([("door_bell", 0.95)], at: h.t)
        #expect(h.events.allSatisfy { if case .sound = $0 { false } else { true } })
    }

    @Test func nothingWithoutEchoCancellation() {
        var h = speaking(aec: false)
        h.voice(0.25, amplitude: 0.6)
        h.log += h.core.classified([("laughter", 0.9)], at: h.t)
        #expect(h.events.allSatisfy { if case .sound = $0 { false } else { true } })
    }

    @Test func barMatchesBargeInDetector() {
        let b = BargeInDetector()
        #expect(b.bar(floorDB: -70, ownSpeechLevel: 0) == -40)
        #expect(b.bar(floorDB: -40, ownSpeechLevel: 1) == -40 + 16 + 8)
    }
}

@Suite struct PlaybackRecoveryTests {
    @Test func stallIsDetectedWhenQueuedAudioNeverPlays() {
        var w = PlaybackWatchdog()
        #expect(!w.isStalled(at: 100))
        w.scheduled(at: 0)
        w.scheduled(at: 0.1)
        #expect(!w.isStalled(at: 2.9))
        #expect(w.isStalled(at: 3.0))
        w.reset()
        #expect(w.pending == 0 && !w.isStalled(at: 10))
    }

    @Test func steadyPlaybackIsNotAStall() {
        var w = PlaybackWatchdog()
        var t = 0.0
        for _ in 0..<20 { w.scheduled(at: t) }
        for _ in 0..<19 { t += 0.5; w.played(at: t); #expect(!w.isStalled(at: t + 0.5)) }
        t += 0.5; w.played(at: t)
        #expect(w.pending == 0)
        #expect(!w.isStalled(at: t + 100))
    }

    @Test func holdReleasesWhenQuietAndDropsAfterMaxWait() {
        let h = SpeakHold(since: 10)
        #expect(h.check(userSpeaking: true, at: 11) == .wait)
        #expect(h.check(userSpeaking: false, at: 11) == .release)
        #expect(h.check(userSpeaking: true, at: 10 + SpeakHold.maxWait) == .drop)
    }

    @Test func retryBacksOff() {
        #expect(VoiceService.retryDelay(attempt: 0) == 2)
        #expect(VoiceService.retryDelay(attempt: 1) == 4)
        #expect(VoiceService.retryDelay(attempt: 2) == 8)
        #expect(VoiceService.retryDelay(attempt: 3) == 30)
        #expect(VoiceService.retryDelay(attempt: 50) == 30)
        #expect(VoiceService.retryDelay(attempt: -1) == 2)
    }

    @Test func permanentRecognizerFailuresAreNotRetried() {
        #expect(SpeechInput.Failure.unavailable.isPermanent)
        #expect(SpeechInput.Failure.unsupportedLocale.isPermanent)
        #expect(!SpeechInput.Failure.noAudioFormat.isPermanent)
    }

    @Test func deferredSpeechBeforeStartIsHarmless() async {
        let v = VoiceService()
        v.say("Hey, look at that!", style: .standard, deferWhileUserSpeaks: true)
        v.stream("Did you hear ", style: .standard, deferWhileUserSpeaks: true)
        v.stream("that? ", style: .standard, deferWhileUserSpeaks: true)
        v.endStream()
        try? await Task.sleep(for: .milliseconds(300))
        v.shutdown()
        var events: [VoiceEvent] = []
        for await e in v.events { events.append(e) }
        #expect(!events.contains(.speakingStarted))
    }
}

@Suite struct SpeechInputLifecycleTests {
    func buffer() -> AVAudioPCMBuffer {
        let f = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: 960)!
        b.frameLength = 960
        return b
    }

    @Test func stopIsIdempotentAndFeedAfterStopIsANoOp() {
        let s = SpeechInput()
        s.stop()
        s.stop()
        #expect(!s.isRunning)
        s.feed(buffer())
        #expect(s.fedSeconds == 0)
    }

    @Test func concurrentFeedsAndStopsDontCrash() async {
        let s = SpeechInput()
        let b = UncheckedBox(buffer())
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<8 {
                g.addTask {
                    for _ in 0..<200 {
                        if i == 0 { s.stop() } else { s.feed(b.value); s.discardResultsBeforeNow() }
                    }
                }
            }
        }
        #expect(!s.isRunning)
    }
}

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
