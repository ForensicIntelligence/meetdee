import Foundation
import Testing
@testable import DeeVoice

/// Drives `ListeningCore` with synthetic audio on a virtual clock.
struct CoreHarness {
    var core = ListeningCore()
    var t = 0.0
    var log: [ListeningCore.Action] = []
    let sr = 16_000.0
    let frameSize = 640   // 40 ms

    var events: [VoiceEvent] {
        log.compactMap { if case .emit(let e) = $0 { e } else { nil } }
    }

    mutating func ready(aec: Bool = true) {
        core.aecActive = aec
        core.recognizerReady = true
        log += core.tick(at: t)
    }

    mutating func quiet(_ seconds: Double) {
        for f in Signal.frames(Signal.noise(amplitude: 0.001, count: Int(sr * seconds)), size: frameSize) { push(f) }
    }

    mutating func voice(_ seconds: Double, hz: Double = 200, amplitude: Double = 0.3) {
        for f in Signal.frames(Signal.harmonic(hz: hz, amplitude: amplitude, seconds: seconds), size: frameSize) { push(f) }
    }

    mutating func push(_ f: [Float]) {
        t += Double(f.count) / sr
        log += core.frame(f, sampleRate: sr, at: t)
    }

    mutating func say(_ text: String, final: Bool = true) {
        log += core.transcript(text, isFinal: final, at: t)
    }

    mutating func clear() { log.removeAll() }

    func heard() -> [HeardUtterance] {
        events.compactMap { if case .heard(let h) = $0 { h } else { nil } }
    }
}

@Suite struct ListeningCoreTests {
    @Test func listensOnlyWhenRecognizerReady() {
        var h = CoreHarness()
        h.quiet(0.5)
        #expect(h.events.contains(.listening(false)))
        #expect(!h.events.contains(.listening(true)))
        #expect(!h.events.contains { if case .micLevel = $0 { true } else { false } })
        h.clear()
        h.ready()
        #expect(h.log.contains(.recognitionOpened(bargeIn: false)))
        #expect(h.events == [.listening(true)])
    }

    @Test func micLevelAtAbout20Hz() {
        var h = CoreHarness()
        h.ready()
        h.clear()
        h.quiet(1)
        h.voice(1)
        let levels = h.events.compactMap { if case .micLevel(let l) = $0 { l } else { nil } }
        #expect(levels.count >= 18 && levels.count <= 50)    // 25 frames/s, throttled to ≤ 20 Hz
        #expect(levels.allSatisfy { (0...1).contains($0) })
        #expect(levels.last! > levels.first!)
    }

    @Test func partialsThenHeardWithProsody() throws {
        var h = CoreHarness()
        h.ready()
        h.quiet(1)
        h.clear()
        h.voice(0.5)
        h.say("tell me", final: false)
        h.voice(0.5)
        h.say("Tell me a joke.")
        #expect(h.events.contains(.partial("tell me")))
        #expect(h.events.contains(.partial("Tell me a joke.")))
        #expect(h.heard().isEmpty)
        h.quiet(0.5)
        #expect(h.heard().isEmpty)              // not quiet long enough yet
        h.quiet(0.6)
        let u = try #require(h.heard().first)
        #expect(u.text == "Tell me a joke.")
        #expect(u.duration > 0.8 && u.duration < 1.6)
        #expect(u.prosody.meanPitchHz > 180 && u.prosody.meanPitchHz < 220)
        #expect(u.prosody.loudnessDB > -20)
        #expect(u.prosody.speechRate > 2 && u.prosody.speechRate < 5)
        #expect(h.heard().count == 1)
    }

    @Test func louderSpeechHasHigherLoudness() throws {
        func utterance(_ amp: Double) throws -> HeardUtterance {
            var h = CoreHarness()
            h.ready()
            h.quiet(1)
            h.voice(1, amplitude: amp)
            h.say("hey")
            h.quiet(2)       // v0.5: a lone word is a weak turn end, so the hold is longer than 0.8 s
            return try #require(h.heard().first)
        }
        let soft = try utterance(0.05), loud = try utterance(0.6)
        #expect(loud.prosody.loudnessDB > soft.prosody.loudnessDB + 15)
        #expect(loud.prosody.peakDB > soft.prosody.peakDB + 15)
    }

    @Test func halfDuplexPausesAndResumesAfterDelay() {
        var h = CoreHarness()
        h.ready(aec: false)
        h.quiet(0.2)
        h.clear()
        h.log += h.core.speechRequested(at: h.t)
        #expect(h.events.contains(.listening(false)))
        h.log += h.core.speakingStarted()
        h.voice(0.5)
        h.say("echo of Dee herself")
        #expect(!h.events.contains { if case .partial = $0 { true } else { false } })
        h.log += h.core.speakingFinished(at: h.t, started: true)
        #expect(h.events.contains(.speakingFinished))
        #expect(h.events.contains(.speechLevel(0)))
        h.clear()
        h.quiet(0.2)
        #expect(!h.events.contains(.listening(true)))
        h.quiet(0.3)
        #expect(h.events.contains(.listening(true)))
        #expect(h.log.contains(.recognitionOpened(bargeIn: false)))
    }

    @Test func speechLevelIsThrottledAndOnlyWhileSpeaking() {
        var h = CoreHarness()
        #expect(h.core.speechLevel(0.5, at: 0).isEmpty)
        _ = h.core.speechRequested(at: 0)
        var count = 0
        for i in 0..<100 { count += h.core.speechLevel(0.5, at: Double(i) * 0.01).count }   // 100 Hz in
        #expect(count >= 30 && count <= 35)
    }

    @Test func bargeInWithEchoCancellation() {
        var h = CoreHarness()
        h.ready(aec: true)
        h.quiet(1)
        h.log += h.core.speechRequested(at: h.t)
        h.clear()
        h.voice(0.6, amplitude: 0.4)
        #expect(h.events.contains(.bargeIn))
        #expect(h.log.contains(.recognitionOpened(bargeIn: true)))
        #expect(h.core.isListening(at: h.t))
        #expect(h.events.filter { $0 == .bargeIn }.count == 1)
        // The user's words now count even though Dee hasn't stopped yet.
        h.say("wait wait")
        #expect(h.events.contains(.partial("wait wait")))
    }

    @Test func noBargeInWithoutEchoCancellation() {
        var h = CoreHarness()
        h.ready(aec: false)
        h.quiet(1)
        h.log += h.core.speechRequested(at: h.t)
        h.voice(1, amplitude: 0.5)
        #expect(!h.events.contains(.bargeIn))
        #expect(!h.core.isListening(at: h.t))
    }

    @Test func listeningGateFromApp() {
        var h = CoreHarness()
        h.ready()
        h.quiet(0.2)
        h.clear()
        h.core.listeningEnabled = false
        h.log += h.core.tick(at: h.t)
        #expect(h.events.contains(.listening(false)))
        h.voice(0.5)
        h.say("hello?")
        #expect(!h.events.contains(.partial("hello?")))
        h.core.listeningEnabled = true
        h.log += h.core.tick(at: h.t)
        #expect(h.events.contains(.listening(true)))
    }

    /// Unexpected sounds and laughter still arrive while Dee sleeps (listening off).
    @Test func soundsFlowWhileNotListeningButNotWhileSpeaking() throws {
        var h = CoreHarness()
        h.core.listeningEnabled = false
        h.quiet(1)
        h.voice(0.3, amplitude: 0.5)
        h.clear()
        h.log += h.core.classified([("speech", 0.9), ("door_bell", 0.8)], at: h.t)
        let bell = try #require(h.events.first)
        guard case .sound(let s) = bell else { Issue.record("expected sound"); return }
        #expect(s.identifier == "door_bell" && s.isUnexpected)
        #expect(s.loudnessDB > -15)

        h.clear()
        _ = h.core.speechRequested(at: h.t)
        h.log += h.core.classified([("laughter", 0.9)], at: h.t)
        #expect(h.events.isEmpty)                                  // her own voice
        _ = h.core.speakingFinished(at: h.t, started: true)
        let end = h.t
        h.log += h.core.classified([("laughter", 0.9)], at: end + 0.3)
        #expect(h.events.isEmpty)                                  // tail of her own voice
        h.log += h.core.classified([("laughter", 0.9)], at: end + 1)
        #expect(h.events.isEmpty)                                  // window unknown: 1.9 s tail
        h.quiet(ListeningCore.ownVoiceTail - 0.2)
        h.voice(0.3, amplitude: 0.5)
        h.log += h.core.classified([("laughter", 0.9)], at: h.t)
        #expect(h.events.contains { if case .sound(let s) = $0 { s.kind == .laughter && !s.isUnexpected } else { false } })
    }

    @Test func strayNoiseBeforeSpeechIsNotCountedAsDuration() throws {
        var h = CoreHarness()
        h.ready()
        h.quiet(1)
        h.voice(0.3)     // a cough
        h.quiet(2)
        h.voice(1)
        h.say("Hi Dee.")
        h.quiet(2)       // v0.5: predicted hold (two words, flat pitch) is ~1.1 s
        let u = try #require(h.heard().first)
        #expect(u.duration < 1.3)
    }

    @Test func forcedFinalizeIsRequested() {
        var h = CoreHarness()
        h.ready()
        h.quiet(0.5)
        h.voice(0.5)
        h.say("so anyway", final: false)
        h.quiet(1.6)
        #expect(h.log.contains(.finalizeVolatile))
        h.quiet(1.5)
        #expect(h.heard().first?.text == "so anyway")
    }
}
