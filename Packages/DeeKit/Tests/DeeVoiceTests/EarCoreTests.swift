import Foundation
import Testing
@testable import DeeVoice

/// Drives `EarCore` with synthetic microphone frames on a virtual clock.
///
/// Levels (16 kHz, 40 ms frames): room noise ≈ −65 dBFS; the user's voice
/// (harmonic, amplitude 0.3) ≈ −18 dBFS; her residual echo after voice
/// processing (amplitude 0.01) ≈ −47 dBFS; a soft user (0.02) ≈ −41 dBFS — voiced,
/// but under the barge-in bar (−40 dBFS + 8 dB × her level).
struct EarHarness {
    var core = EarCore()
    var t = 100.0
    var log: [EarCore.Action] = []
    let rate = 16_000.0
    let frameSize = 640
    /// Her playback level fed with every frame while `playing`.
    var playing = false
    var level = 0.7
    private var phase = 0

    init(aec: Bool = true, connected: Bool = true) {
        core.aecActive = aec
        if connected { log += core.setConnected(true, at: t) }
        quiet(1.0)
    }

    var events: [VoiceEvent] { log.compactMap { if case .emit(let e) = $0 { e } else { nil } } }
    var decisions: [EarCore.Action] {
        log.filter {
            switch $0 {
            case .emit, .uplink, .localSpeech: false
            default: true
            }
        }
    }

    mutating func clear() { log.removeAll() }

    mutating func push(_ f: [Float]) {
        t += Double(f.count) / rate
        if playing { core.playbackLevel(level, at: t) }
        log += core.frame(f, sampleRate: rate, at: t)
        log += core.tick(at: t)
    }

    mutating func signal(_ x: [Float]) {
        for f in Signal.frames(x, size: frameSize) { push(f) }
    }

    mutating func quiet(_ seconds: Double) {
        phase += 1
        signal(Signal.noise(amplitude: 0.001, count: Int(rate * seconds), seed: UInt64(phase)))
    }

    mutating func voice(_ seconds: Double, amplitude: Double = 0.3, hz: Double = 180) {
        signal(Signal.harmonic(hz: hz, amplitude: amplitude, sampleRate: rate, seconds: seconds))
    }

    mutating func echo(_ seconds: Double) { voice(seconds, amplitude: 0.01, hz: 300) }

    mutating func startPlayback(aside: Bool = false) {
        playing = true
        core.playbackLevel(level, at: t)
        log += core.playbackStarted(at: t, aside: aside)
    }

    mutating func stopPlayback() {
        playing = false
        log += core.playbackFinished(at: t)
    }

    mutating func serverStart(_ item: String, onset: Double? = nil) {
        log += core.serverSpeechStarted(itemID: item, onset: onset, at: t)
    }

    mutating func serverStop(_ item: String, end: Double? = nil) {
        log += core.serverSpeechStopped(itemID: item, end: end, at: t)
    }
}

@Suite struct EarCoreBargeInTests {
    @Test func userOverHerReplyIsABargeIn() {
        var h = EarHarness()
        h.startPlayback()
        h.echo(0.6)
        h.clear()
        h.voice(0.2)
        h.serverStart("item_u")                      // the server heard them first: wait for evidence
        #expect(h.decisions.isEmpty)
        h.voice(0.3)
        #expect(h.decisions == [.bargeIn(itemID: "item_u")])
        #expect(h.events.contains(.bargeIn))
        // The action comes before the event: she is already quiet when the app hears of it.
        let i = h.log.firstIndex(of: .bargeIn(itemID: "item_u"))!
        let j = h.log.firstIndex(of: .emit(.bargeIn))!
        #expect(i < j)
        #expect(h.core.userIsSpeaking(at: h.t))
    }

    @Test func evidenceBeforeTheServerBargesInOnArrival() {
        var h = EarHarness()
        h.startPlayback()
        h.echo(0.4)
        h.voice(0.32)                                 // detector fired; server not yet
        h.clear()
        h.serverStart("item_u")
        #expect(h.decisions == [.bargeIn(itemID: "item_u")])
    }

    @Test func strongLocalEvidenceBargesInWithoutTheServer() {
        var h = EarHarness()
        h.startPlayback()
        h.echo(0.4)
        h.clear()
        h.voice(EarCore.localOnlyRun - 0.1)
        #expect(h.decisions.isEmpty)                  // not yet: the server's onset is the usual path
        h.voice(0.2)
        #expect(h.decisions == [.bargeIn(itemID: nil)])
        #expect(h.events.filter { $0 == .bargeIn }.count == 1)
        // The server's onset for the same speech then arrives: accepted, not decided twice.
        h.stopPlayback()
        h.clear()
        h.serverStart("item_u")
        #expect(h.decisions.isEmpty)
        #expect(h.core.serverOpen == "item_u")
    }

    @Test func theServersOnsetForSpeechThatAlreadyCutHerIsTheUser() {
        var h = EarHarness()
        h.startPlayback()
        h.voice(EarCore.localOnlyRun + 0.1)           // local-only barge-in
        #expect(h.decisions == [.bargeIn(itemID: nil)])
        h.clear()
        h.serverStart("item_u")                      // before the player reported the flush
        h.voice(0.2)
        h.stopPlayback()
        h.serverStop("item_u")
        #expect(h.decisions.isEmpty)
        #expect(!h.core.isRejected("item_u"))
    }

    @Test func theServersOnsetAfterTheUserStoppedHerLaughIsTheUser() {
        var h = EarHarness()
        h.startPlayback(aside: true)
        h.voice(0.4)
        #expect(h.decisions == [.yieldAside(itemID: nil)])
        h.clear()
        h.serverStart("item_u")
        h.serverStop("item_u")
        #expect(!h.core.isRejected("item_u"))
        #expect(!h.decisions.contains(.rejectEcho(itemID: "item_u")))
    }

    @Test func herEchoIsRejectedWhenTheServerSpeechStops() {
        var h = EarHarness()
        h.startPlayback()
        h.echo(0.3)
        h.clear()
        h.serverStart("item_e")
        h.echo(0.8)
        #expect(h.decisions.isEmpty)
        #expect(h.core.isDeciding("item_e"))
        h.serverStop("item_e")
        #expect(h.decisions == [.rejectEcho(itemID: "item_e")])
        #expect(!h.events.contains(.bargeIn))
        #expect(h.core.isRejected("item_e"))
        // Her echo is never "the user talking".
        #expect(!h.core.userIsSpeaking(at: h.t))
        // Nothing of it is heard later either.
        #expect(h.core.serverTranscript(itemID: "item_e", text: "my own words", at: h.t).isEmpty)
    }

    /// An echo item the server keeps open while she plays is never given up on
    /// at the timeout (the user may yet talk inside it: tune-1 live, long-echo10
    /// c02); it is decided when it stops — or once she stops, at the timeout.
    @Test func echoThatStaysOpenIsDecidedWhenItStops() {
        var h = EarHarness()
        h.startPlayback()
        h.clear()
        h.serverStart("item_e")
        h.echo(EarCore.decisionTimeout + 1.0)
        #expect(h.decisions.isEmpty)
        h.serverStop("item_e")
        #expect(h.decisions == [.rejectEcho(itemID: "item_e")])
    }

    @Test func echoThatNeverStopsIsRejectedOnceSheStops() {
        var h = EarHarness()
        h.startPlayback()
        h.clear()
        h.serverStart("item_e")
        h.echo(EarCore.decisionTimeout + 0.2)
        #expect(h.decisions.isEmpty)
        h.stopPlayback()
        h.quiet(EarCore.echoTail + EarCore.userAfterTail * 2 + 0.3)
        #expect(h.decisions == [.rejectEcho(itemID: "item_e")])
    }

    @Test func userCarryingOnAfterHerAudioIsAccepted() {
        var h = EarHarness()
        h.startPlayback()
        h.echo(0.5)
        h.stopPlayback()
        h.clear()
        h.serverStart("item_u")                      // inside her echo tail
        #expect(h.core.isDeciding("item_u"))
        h.voice(1.2, amplitude: 0.02)                 // soft: never over the bar, but clearly them
        #expect(h.decisions == [.acceptOnset(itemID: "item_u")])
        #expect(!h.events.contains(.bargeIn))
        #expect(h.core.serverOpen == "item_u")
    }

    @Test func tailEchoWithNothingAfterIsRejected() {
        var h = EarHarness()
        h.startPlayback()
        h.echo(0.5)
        h.stopPlayback()
        h.clear()
        h.serverStart("item_e")
        h.echo(0.2)
        h.quiet(0.2)
        h.serverStop("item_e")
        #expect(h.decisions == [.rejectEcho(itemID: "item_e")])
    }

    @Test func onsetLongAfterHerAudioIsPlainUserSpeech() {
        var h = EarHarness()
        h.startPlayback()
        h.echo(0.3)
        h.stopPlayback()
        h.quiet(1.5)
        h.clear()
        h.serverStart("item_u")
        #expect(!h.core.deciding)
        #expect(h.core.serverOpen == "item_u")
        #expect(h.decisions.isEmpty)
    }

    @Test func withoutEchoCancellationHerLoudVoiceIsNotTheUser() {
        var h = EarHarness(aec: false)
        h.level = 0.8
        h.startPlayback()
        h.clear()
        h.serverStart("item_e")
        h.voice(1.0, amplitude: 0.1, hz: 300)         // her un-cancelled voice, −26 dBFS
        h.serverStop("item_e")
        #expect(h.decisions == [.rejectEcho(itemID: "item_e")])
        // A user shouting over her still gets through.
        h.clear()
        h.serverStart("item_u")
        h.voice(0.5, amplitude: 0.6)
        #expect(h.decisions.first == .bargeIn(itemID: "item_u"))
    }
}

@Suite struct EarCoreAsideTests {
    @Test func talkingOverHerLaughStopsItQuietly() {
        var h = EarHarness()
        h.startPlayback(aside: true)
        h.clear()
        h.voice(0.4)
        #expect(h.decisions == [.yieldAside(itemID: nil)])
        #expect(!h.events.contains(.bargeIn))
    }

    @Test func aLaughNeverDeletesTheWordsOfSomeoneHoldingTheFloor() {
        var h = EarHarness()
        h.voice(0.6, amplitude: 0.02)                 // soft talker, mid-turn
        h.startPlayback(aside: true)                  // she laughs along
        h.clear()
        h.serverStart("item_u")
        #expect(h.decisions == [.acceptOnset(itemID: "item_u")])
    }

    @Test func replyJoiningTheAsideIsNoLongerAnAside() {
        var h = EarHarness()
        h.startPlayback(aside: true)
        h.log += h.core.playbackStarted(at: h.t, aside: false)
        #expect(!h.core.asideOnly)
        h.clear()
        h.serverStart("item_u")
        h.voice(0.5)
        #expect(h.decisions == [.bargeIn(itemID: "item_u")])
    }
}

@Suite struct EarCoreFloorTests {
    @Test func userBeatingAnInitiativeCancelsIt() {
        var h = EarHarness()
        h.core.initiativePending = true
        h.clear()
        h.voice(0.1)
        #expect(h.decisions.isEmpty)
        h.voice(0.12)
        #expect(h.decisions == [.cancelInitiative])
        h.voice(0.5)
        #expect(h.decisions == [.cancelInitiative])     // once
        #expect(!h.core.initiativePending)
    }

    @Test func noiseBlipDoesNotCancelAnInitiative() {
        var h = EarHarness()
        h.core.initiativePending = true
        h.clear()
        for _ in 0..<5 { h.voice(0.04); h.quiet(0.12) }
        #expect(h.decisions.isEmpty)
    }

    @Test func herFirstAudioSettlesTheInitiative() {
        var h = EarHarness()
        h.core.initiativePending = true
        h.startPlayback()
        #expect(!h.core.initiativePending)
    }

    @Test func userIsSpeakingFollowsVoiceAndOpenServerSpeech() {
        var h = EarHarness()
        #expect(!h.core.userIsSpeaking(at: h.t))
        h.voice(0.3)
        #expect(h.core.userIsSpeaking(at: h.t))
        h.quiet(EarCore.userSpeechHold + 0.1)          // + the VAD's 0.2 s hangover
        #expect(h.core.userIsSpeaking(at: h.t))
        h.quiet(0.2)
        #expect(!h.core.userIsSpeaking(at: h.t))
        h.serverStart("item_u")
        #expect(h.core.userIsSpeaking(at: h.t))
        h.serverStop("item_u")
        #expect(!h.core.userIsSpeaking(at: h.t))
    }
}

@Suite struct EarCoreFaceTests {
    @Test func speechLevelIsSteadyThirtyHertzIncludingGaps() {
        var h = EarHarness()
        h.startPlayback()
        h.clear()
        // 1 s of playback; the player's level stops arriving half way (an underrun).
        var levels: [Double] = []
        for k in 0..<100 {
            h.t += 0.01
            if k < 50 { h.core.playbackLevel(0.6, at: h.t) }
            for a in h.core.tick(at: h.t) { if case .emit(.speechLevel(let l)) = a { levels.append(l) } }
        }
        #expect((29...31).contains(levels.count), "\(levels.count)")
        #expect(levels.prefix(10).allSatisfy { $0 == 0.6 })
        #expect(levels.suffix(10).allSatisfy { $0 == 0 })
        h.clear()
        h.stopPlayback()
        #expect(h.events == [.speechLevel(0), .speakingFinished])
        #expect(h.core.tick(at: h.t + 0.1).isEmpty)
    }

    @Test func speakingStartedOncePerStretch() {
        var h = EarHarness()
        h.clear()
        h.startPlayback(aside: true)
        h.log += h.core.playbackStarted(at: h.t, aside: false)
        #expect(h.events == [.speakingStarted])
        h.clear()
        h.stopPlayback()
        h.stopPlayback()
        #expect(h.events == [.speechLevel(0), .speakingFinished])
    }

    @Test func pausesInTheUsersTurnReachTheFace() {
        var h = EarHarness()
        h.serverStart("item_u")
        h.clear()
        h.voice(1.0)
        h.quiet(0.4)
        let pauses = h.events.filter { if case .pause = $0 { true } else { false } }
        #expect(!pauses.isEmpty)
        #expect(h.events.contains { if case .micLevel = $0 { true } else { false } })
    }

    @Test func listeningFollowsConnectionAndTheAppGate() {
        var h = EarHarness(connected: false)
        h.clear()
        h.log += h.core.setConnected(true, at: h.t)
        #expect(h.events == [.listening(true)])
        #expect(h.log.contains(.uplink(true)))
        h.clear()
        h.log += h.core.setConnected(false, at: h.t)
        #expect(h.events == [.micLevel(0), .listening(false)])
        #expect(h.log.contains(.uplink(false)))
    }
}

@Suite struct EarCoreHeardTests {
    @Test func heardCarriesProsodyFromTheServersWindow() throws {
        var h = EarHarness()
        let onset = h.t
        h.voice(1.0, amplitude: 0.3, hz: 180)
        let end = h.t
        h.quiet(0.5)
        h.serverStart("item_u", onset: onset)
        h.serverStop("item_u", end: end)
        h.clear()
        h.log += h.core.serverTranscript(itemID: "item_u", text: "  I went to the park today.  ", at: h.t)
        guard case .heard(let u)? = h.events.first else { Issue.record("no heard"); return }
        #expect(u.text == "I went to the park today.")
        #expect(abs(u.duration - 1.0) < 0.25, "\(u.duration)")
        #expect(abs(u.prosody.meanPitchHz - 180) < 15, "\(u.prosody.meanPitchHz)")
        #expect(u.prosody.loudnessDB > -22 && u.prosody.loudnessDB < -14, "\(u.prosody.loudnessDB)")
        #expect(u.prosody.speechRate > 3 && u.prosody.speechRate < 8)
    }

    @Test func herEchoFramesAreLeftOutOfTheUsersProsody() {
        var h = EarHarness()
        h.startPlayback()
        let onset = h.t
        h.echo(0.6)                                   // her, under the bar
        h.serverStart("item_u", onset: onset)
        h.voice(0.6)                                  // then the user, loud
        h.stopPlayback()
        let end = h.t
        h.serverStop("item_u", end: end)
        h.clear()
        h.log += h.core.serverTranscript(itemID: "item_u", text: "wait wait", at: h.t)
        guard case .heard(let u)? = h.events.first else { Issue.record("no heard"); return }
        #expect(u.duration < 0.75, "\(u.duration)")   // the user's 0.6 s, not her 0.6 s too
        #expect(u.prosody.loudnessDB > -22)
    }

    @Test func emptyTranscriptIsNotHeard() {
        var h = EarHarness()
        h.serverStart("item_u")
        h.serverStop("item_u")
        #expect(h.core.serverTranscript(itemID: "item_u", text: "  ", at: h.t).isEmpty)
    }
}

@Suite struct EarCoreUplinkTests {
    @Test func listeningOffClosesTheUplinkAndVoiceWakesIt() {
        var h = EarHarness()
        h.clear()
        h.log += h.core.setListeningEnabled(false, at: h.t)
        #expect(h.log.contains(.uplink(false)))
        h.clear()
        h.voice(0.2)
        #expect(!h.log.contains(.uplink(true)))
        h.voice(0.3)
        #expect(h.log.contains(.uplink(true)))
        h.clear()
        h.quiet(EarCore.wakeHold - 0.5)
        #expect(!h.log.contains(.uplink(false)))
        h.quiet(1.0)
        #expect(h.log.contains(.uplink(false)))
    }

    @Test func noWakeWhenDisabled() {
        var h = EarHarness()
        h.core.wakeOnVoice = false
        h.log += h.core.setListeningEnabled(false, at: h.t)
        h.clear()
        h.voice(1.0)
        #expect(!h.log.contains(.uplink(true)))
    }
}

/// Her own voice is never reported as a sound (ported from the v0.4 fixes).
@Suite struct EarCoreSoundTests {
    func afterSpeaking() -> EarHarness {
        var h = EarHarness()
        h.startPlayback()
        h.echo(1.0)
        h.stopPlayback()
        return h
    }

    @Test func windowOverlappingHerAudioIsDropped() {
        var h = afterSpeaking()
        let w = (h.t - 1.2)...(h.t + 0.3)
        #expect(h.core.classified([("dog_bark", 0.9)], window: w, at: h.t + 0.4).isEmpty)
    }

    @Test func windowAfterHerAudioCounts() {
        var h = afterSpeaking()
        h.voice(1.5, amplitude: 0.3, hz: 600)        // a loud sound in the room
        let w = (h.t - 1.0)...(h.t)
        let a = h.core.classified([("dog_bark", 0.9)], window: w, at: h.t)
        #expect(a.count == 1)
    }

    @Test func withoutAWindowHerTailIsCovered() {
        var h = afterSpeaking()
        #expect(h.core.classified([("dog_bark", 0.9)], at: h.t + 1.0).isEmpty)
    }

    @Test func userLaughOverHerVoiceGetsThroughWithEchoCancellation() {
        var h = EarHarness()
        h.startPlayback()
        h.voice(0.5, amplitude: 0.3)
        let a = h.core.classified([("laughter", 0.8)], at: h.t)
        #expect(a.count == 1)
        // Her faint echo "laughing" does not.
        var g = EarHarness()
        g.startPlayback()
        g.echo(0.5)
        #expect(g.core.classified([("laughter", 0.8)], at: g.t).isEmpty)
        // Other sounds stay blocked while she talks.
        #expect(h.core.classified([("dog_bark", 0.9)], at: h.t + 0.1).isEmpty)
    }
}
