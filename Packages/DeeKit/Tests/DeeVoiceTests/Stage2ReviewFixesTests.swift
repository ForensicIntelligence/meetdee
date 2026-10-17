import DeeRealtime
import Foundation
import Testing
@testable import DeeVoice

// Regression tests for the stage-2 review of CloudVoice / EarCore / ClipCache
// (findings numbered as in the review).

/// 1. A quick, short answer right after Dee stops is the user, not Dee's echo.
@Suite struct QuickAnswerAfterHerTests {
    @Test(arguments: [(0.3, 0.22), (0.02, 0.4), (0.05, 0.3)])
    func quickShortAnswerAfterHerQuestionIsTheUser(_ amplitude: Double, _ seconds: Double) {
        var h = EarHarness()
        h.startPlayback()
        h.echo(1.0)                                   // "Want a story?"
        h.stopPlayback()
        h.quiet(0.12)
        h.clear()
        let onset = h.t
        h.voice(seconds, amplitude: amplitude)        // "Yes!"
        h.serverStart("item_yes", onset: onset)
        h.quiet(0.3)
        h.serverStop("item_yes", end: onset + seconds)
        #expect(h.decisions == [.acceptOnset(itemID: "item_yes")], "\(h.decisions)")
        #expect(!h.core.isRejected("item_yes"))
        // And it is heard, with the user's own prosody.
        h.clear()
        h.log += h.core.serverTranscript(itemID: "item_yes", text: "Yes!", at: h.t)
        #expect(h.events.contains { if case .heard = $0 { true } else { false } })
    }

    @Test func aLouderEchoTailIsStillHerEcho() {
        var h = EarHarness()
        h.startPlayback()
        h.voice(1.0, amplitude: 0.03, hz: 300)        // Dee's echo, −38 dBFS: under the bar while Dee plays
        h.stopPlayback()
        h.clear()
        h.serverStart("item_e")
        h.voice(0.35, amplitude: 0.03, hz: 300)       // the room tail of Dee's last words
        h.quiet(0.2)
        h.serverStop("item_e")
        #expect(h.decisions == [.rejectEcho(itemID: "item_e")])
    }

    @Test func anAnswerWellAfterHerDirectSoundButInsideTheTailCounts() {
        var h = EarHarness()
        h.startPlayback()
        h.echo(0.8)
        h.stopPlayback()
        h.serverStart("item_u")                      // the server's onset (with its padding) lands in Dee's tail
        h.quiet(0.15)
        h.clear()
        h.voice(0.15)
        #expect(h.decisions == [.acceptOnset(itemID: "item_u")])
        #expect(h.core.serverOpen == "item_u")
    }
}

/// 2. Local-only barge-in: long, continuous, pitched voice only; stale evidence expires.
@Suite struct LocalOnlyBargeInTests {
    @Test func staleEvidenceNeverBargesInOnASingleFrame() {
        var h = EarHarness()
        h.startPlayback()
        h.echo(0.4)
        h.voice(0.3)                                  // a cough / "mm" while Dee talks
        h.quiet(1.5)
        h.clear()
        h.voice(0.04)                                 // one frame above the bar
        #expect(h.decisions.isEmpty)
        h.quiet(0.4)
        #expect(h.decisions.isEmpty)
    }

    @Test func evidenceKeptFreshByAShortPauseStillCountsForTheServer() {
        var h = EarHarness()
        h.startPlayback()
        h.echo(0.4)
        h.voice(0.32)
        h.quiet(0.5)                                  // under the lookback: still them
        h.clear()
        h.serverStart("item_u")
        #expect(h.decisions == [.bargeIn(itemID: "item_u")])
    }

    @Test func aLaughAtHerJokeDoesNotCutHerOff() {
        var h = EarHarness()
        h.startPlayback()
        h.echo(0.4)
        h.clear()
        h.voice(0.7)                                  // "hahaha" with no server onset
        h.quiet(0.3)
        #expect(h.decisions.isEmpty)
    }

    @Test func aClassifiedLaughSuppressesTheLocalOnlyPath() {
        var h = EarHarness()
        h.startPlayback()
        h.echo(0.4)
        h.voice(0.5)
        _ = h.core.classified([("laughter", 0.8)], at: h.t)
        h.clear()
        h.voice(1.0)                                  // a long laugh: still not a barge-in by itself
        #expect(h.decisions.isEmpty)
        // The server's onset with evidence is still the user cutting in.
        h.serverStart("item_u")
        #expect(h.decisions == [.bargeIn(itemID: "item_u")])
    }

    @Test func clappingIsNotSpeech() {
        var h = EarHarness()
        h.startPlayback()
        h.echo(0.4)
        h.clear()
        h.signal(Signal.noise(amplitude: 0.3, count: Int(h.rate * 1.6), seed: 7))
        #expect(!h.decisions.contains(.bargeIn(itemID: nil)))
    }

    @Test func aBrokenRunStartsOver() {
        var h = EarHarness()
        h.startPlayback()
        h.echo(0.4)
        h.clear()
        for _ in 0..<4 { h.voice(0.4); h.quiet(0.2) }  // talking in bursts, gaps > runGap
        #expect(h.decisions.isEmpty)
    }
}

/// 9. Dee's echo being decided is not "the user talking".
@Suite struct EchoDecisionFloorTests {
    @Test func userIsNotSpeakingWhileHerEchoIsDecided() {
        var h = EarHarness()
        h.startPlayback()
        h.echo(0.3)
        h.serverStart("item_e")
        h.echo(0.5)
        #expect(h.core.isDeciding("item_e"))
        #expect(!h.core.userIsSpeaking(at: h.t))
        #expect(h.core.herVoiceInRoom(at: h.t))
        h.stopPlayback()
        h.quiet(EarCore.echoTail + 0.05)
        #expect(!h.core.herVoiceInRoom(at: h.t))
    }
}

/// 8. The gate on Dee's audio after a stop.
@Suite struct ReplyGateTests {
    @Test func aStopBeforeTheResponseWasSeenKeepsThatResponseSilent() {
        var g = ReplyGate()
        g.closeBeforeAudio(at: 10)
        // Its `.responseStarted` was still in the pump.
        let keptClosed = g.responseStarted(at: 10.01)
        let first = g.audio(), second = g.audio()
        #expect(keptClosed)
        #expect(first == .dropAndTellServer)
        #expect(second == .drop)
        // The next request opens it again.
        g.requested()
        let closedAgain = g.responseStarted(at: 10.05)
        let next = g.audio()
        #expect(!closedAgain)
        #expect(next == .play)
    }

    @Test func aResponseLongAfterTheStopPlays() {
        var g = ReplyGate()
        g.closeBeforeAudio(at: 10)
        let closed = g.responseStarted(at: 10 + ReplyGate.stopGuard + 0.01)   // e.g. a tool follow-up
        let admit = g.audio()
        #expect(!closed)
        #expect(admit == .play)
    }

    @Test func aCutResponsesLateAudioIsDroppedQuietly() {
        var g = ReplyGate()
        g.closeAfterCut()
        let late = g.audio()
        let closed = g.responseStarted(at: 0)
        let next = g.audio()
        #expect(late == .drop)
        #expect(!closed)
        #expect(next == .play)
    }
}

/// 11. The uplink map stops mapping once the session may have dropped audio.
@Suite struct UplinkMapReliabilityTests {
    @Test func congestionInvalidatesUntilTheNextSession() {
        var m = UplinkMap()
        m.sent(startFrame: 0, frames: 24_000)
        #expect(m.captureFrame(serverMs: 500) == 12_000)
        m.invalidate()
        #expect(m.captureFrame(serverMs: 500) == nil)
        m.sent(startFrame: 24_000, frames: 2400)
        #expect(m.captureEnd == 26_400)              // gap fill still knows where sending stopped
        m.reset()
        m.sent(startFrame: 26_400, frames: 2400)
        #expect(m.captureFrame(serverMs: 50) == 27_600)
    }
}

/// 10. ClipCache: no server text in reports, no disk reads per call for a missing clip.
@Suite struct ClipCacheReviewFixesTests {
    func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dee-clips-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func anErrorBodyNeverReachesTheReport() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = #"{"error":{"message":"Incorrect API key provided: sk-test-****6789. You can find your API key at https://platform.openai.com/account/api-keys.","type":"invalid_request_error","param":null,"code":"invalid_api_key"}}"#
        let server = FakeSpeechServer(status: 401) { _ in Data(body.utf8) }
        var c = ClipCache.Configuration(directory: dir)
        c.clips = [.giggle]
        let r = await ClipCache(configuration: c, key: { "sk-test-key-0123456789" }, fetch: server.fetch).prepare()
        #expect(r.stopped == "HTTP 401 (invalid_api_key)")
        #expect(r.stopped?.contains("6789") == false)
        #expect(r.stopped?.contains("sk-") == false)
        #expect(ClipCache.errorCode(Data(#"{"error":{"code":"sk-abc"}}"#.utf8)) == nil)
        #expect(ClipCache.errorCode(Data("<html>".utf8)) == nil)
    }

    @Test func aMissingClipIsLookedForOnceUntilPrepare() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = FakeSpeechServer()
        var c = ClipCache.Configuration(directory: dir)
        c.clips = [.giggle]
        let cache = ClipCache(configuration: c, key: { "sk-test-key-0123456789" }, fetch: server.fetch)
        #expect(cache.pcm(.giggle) == nil)
        // A file appearing behind its back is not read on the next call (no disk
        // read per `laugh()` while clips are missing)…
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try PCMTone.data(ms: 300, hz: 500, amplitude: 0.4).write(to: cache.fileURL(.giggle))
        #expect(cache.pcm(.giggle) == nil)
        // …but `prepare()` looks again and finds it without a request.
        let r = await cache.prepare()
        #expect(r.alreadyThere == [.giggle])
        #expect(server.all.isEmpty)
        #expect(cache.pcm(.giggle) != nil)
    }
}
