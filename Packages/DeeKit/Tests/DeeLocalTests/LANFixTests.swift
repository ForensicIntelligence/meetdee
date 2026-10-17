import Foundation
import Testing
import Synchronization
import DeeRealtime
@testable import DeeWake
@testable import DeeLocal

// Regressions from the 0.6.0 LAN smoke (modes 2 and 3).

/// Mode 2: the transcription session splits one utterance at 300 ms pauses; the pieces are one turn.
@Suite(.serialized) struct TranscriptionMergeTests {
    func hearing(window: Double = 0.4) -> (OpenAITranscriptionHearing, LocalHearingTests.Sink) {
        let h = OpenAITranscriptionHearing(transport: .failing(), credential: { throw RealtimeAuthError.noKey })
        h.mergeWindow = window
        let sink = LocalHearingTests.Sink()
        h.attach { sink.add($0) }
        return (h, sink)
    }

    func ev(_ o: [String: Any]) -> ServerEvent {
        let data = try! JSONSerialization.data(withJSONObject: o)
        return ServerEvent.parse(String(decoding: data, as: UTF8.self))
    }

    func piece(_ h: OpenAITranscriptionHearing, _ item: String, _ startMs: Int, _ endMs: Int, _ text: String) {
        h.server(ev(["type": "input_audio_buffer.speech_started", "audio_start_ms": startMs, "item_id": item]))
        h.server(ev(["type": "input_audio_buffer.speech_stopped", "audio_end_ms": endMs, "item_id": item]))
        h.server(ev(["type": "input_audio_buffer.committed", "item_id": item, "previous_item_id": NSNull()]))
        h.server(ev(["type": "conversation.item.input_audio_transcription.delta", "item_id": item, "content_index": 0, "delta": text]))
        h.server(ev(["type": "conversation.item.input_audio_transcription.completed", "item_id": item, "content_index": 0,
                     "transcript": text]))
    }

    /// d02 of the smoke: "My sister's wedding is on June 12." / "And I'm giving a speech." was two
    /// turns, and the reply to the first was cancelled by the second. Now: one start, one commit,
    /// one transcript with both halves.
    @Test func piecesWithinTheWindowAreOneTurn() async throws {
        let (h, sink) = hearing()
        piece(h, "item_A", 120, 3_400, "My sister's wedding is on June 12.")
        try await Task.sleep(for: .milliseconds(150))
        #expect(!sink.all.contains(.committed(turn: 1)))   // held for a continuation
        piece(h, "item_B", 3_950, 5_300, "And I'm giving a speech.")
        #expect(await sink.wait { $0.contains { if case .transcriptCompleted = $0 { true } else { false } } })
        try await Task.sleep(for: .milliseconds(100))
        let all = sink.all
        let whole = "My sister's wedding is on June 12. And I'm giving a speech."
        #expect(all.first == .speechStarted(turn: 1, frame: 120 * 24))
        #expect(all.filter { if case .speechStarted = $0 { true } else { false } }.count == 1)
        #expect(all.filter { if case .committed = $0 { true } else { false } } == [.committed(turn: 1)])
        #expect(all.contains(.speechStopped(turn: 1, frame: 5_300 * 24)))
        #expect(!all.contains(.speechStopped(turn: 1, frame: 3_400 * 24)))
        #expect(all.last == .transcriptCompleted(turn: 1, text: whole))
        let deltas = all.compactMap { if case .transcriptDelta(_, let d) = $0 { d } else { nil } }
        #expect(deltas.joined() == whole)
        // committed before every transcript event.
        let ci = all.firstIndex(of: .committed(turn: 1))!
        #expect(all.firstIndex { if case .transcriptDelta = $0 { true } else { false } }! > ci)
    }

    /// A start after the window is a new turn (backchannels and barge-ins keep their own turns).
    @Test func aLaterStartIsANewTurn() async throws {
        let (h, sink) = hearing(window: 0.2)
        piece(h, "item_A", 100, 900, "Is it going to rain tomorrow?")
        #expect(await sink.wait { $0.contains(.transcriptCompleted(turn: 1, text: "Is it going to rain tomorrow?")) })
        h.server(ev(["type": "input_audio_buffer.speech_started", "audio_start_ms": 1_800, "item_id": "item_B"]))
        #expect(await sink.wait { $0.contains(.speechStarted(turn: 2, frame: 1_800 * 24)) })
    }

    /// A piece whose transcript comes late still holds the merged transcript until it arrives.
    @Test func mergedTranscriptWaitsForEveryPiece() async throws {
        let (h, sink) = hearing(window: 0.2)
        piece(h, "item_A", 100, 900, "Don't stop.")
        h.server(ev(["type": "input_audio_buffer.speech_started", "audio_start_ms": 1_000, "item_id": "item_B"]))
        h.server(ev(["type": "input_audio_buffer.speech_stopped", "audio_end_ms": 1_600, "item_id": "item_B"]))
        h.server(ev(["type": "input_audio_buffer.committed", "item_id": "item_B", "previous_item_id": "item_A"]))
        #expect(await sink.wait { $0.contains(.committed(turn: 1)) })
        try await Task.sleep(for: .milliseconds(100))
        #expect(!sink.all.contains { if case .transcriptCompleted = $0 { true } else { false } })
        h.server(ev(["type": "conversation.item.input_audio_transcription.completed", "item_id": "item_B", "content_index": 0,
                     "transcript": "Keep going."]))
        #expect(await sink.wait { $0.contains(.transcriptCompleted(turn: 1, text: "Don't stop. Keep going.")) })
    }
}

/// Mode 2/3 engine: a reply waiting for its transcript never parks the client pump.
@Suite(.serialized) struct CascadePumpTests {
    @Test func cancelAndAudioPassAWaitingReply() async throws {
        let hearing = FakeHearing()
        let client = CompatClient(base: URL(string: "http://127.0.0.1:9")!, key: nil, transport: .live(redirects: .refuse))
        var o = CascadeOptions(model: "m"); o.warmUps = false; o.transcriptWait = 8
        let socket = CascadeSocket(options: o, hearing: hearing, chat: VendorChat(client: client, vendor: .other), voice: FakeVoice())
        let frames = FrameLog()
        let reader = Task { for await e in socket.incoming { if case .text(let t) = e { frames.add(t) } } }
        defer { reader.cancel(); socket.close(code: 1000, reason: nil) }
        try await socket.open()
        hearing.emit(.speechStarted(turn: 1, frame: 0))
        hearing.emit(.speechStopped(turn: 1, frame: 24_000))
        hearing.emit(.committed(turn: 1))   // its transcript never comes
        try await Task.sleep(for: .milliseconds(100))
        socket.send(#"{"type":"response.create"}"#)
        socket.send(#"{"type":"input_audio_buffer.append","audio":"\#(Data(count: 960).base64EncodedString())"}"#)
        socket.send(#"{"type":"response.cancel"}"#)
        let start = Date()
        while Date().timeIntervalSince(start) < 2, frames.first("response.done") == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        // Before the fix the cancel and the audio waited the whole 8 s behind the transcript wait.
        #expect(frames.first("response.done")?.json["response"]?["status"]?.stringValue == "cancelled")
        #expect(hearing.fedFrames == 480)
    }
}

/// Mode 3: turns come from EarCore's voice verdicts; Apple's SpeechDetector gives nothing (smoke: 7/7 dropped).
@Suite(.serialized) struct LocalTurnEvidenceTests {
    @Test func earCoreVoiceDrivesTurnsWithoutTheDetector() async throws {
        let engine = FakeEngine()   // its detector never reports, like Apple's in the analyzer
        engine.onFinalize = { end in SpeechSegment(text: "what's my dog's name?", isFinal: true, startFrame: 9_600, endFrame: end - 7_200) }
        let uplink = UplinkActivity()
        uplink.record(frames: 48_000, voice: false)   // an earlier socket: the feed clocks differ by an origin
        let hearing = LocalHearing(stt: .onDevice, engine: engine, uplink: uplink)
        let sink = LocalHearingTests.Sink()
        try await hearing.start { sink.add($0) }
        // 100 ms chunks: silence, 1 s of voice (chunks 5…14), then silence (the stop + the merge window).
        for i in 0..<35 {
            let voice = (5..<15).contains(i)
            uplink.record(frames: 2_400, voice: voice)
            hearing.feed(Data(count: 2_400 * 2), atFrame: Int64(i) * 2_400)
        }
        #expect(await sink.wait { $0.contains { if case .transcriptCompleted = $0 { true } else { false } } })
        let all = sink.all
        #expect(all.first == .speechStarted(turn: 1, frame: 12_000 - 7_200))
        #expect(all.contains(.speechStopped(turn: 1, frame: 36_000 + 7_200)))
        #expect(all.contains(.committed(turn: 1)))
        #expect(all.contains(.transcriptCompleted(turn: 1, text: "what's my dog's name?")))
        #expect(!all.contains(.failed(.noVoiceEvidence)))
        hearing.stop()
    }

    /// Audio goes in, no voice evidence ever comes back: a problem, not silence.
    @Test func noEvidenceIsAProblem() async throws {
        let engine = FakeEngine()
        let hearing = LocalHearing(stt: .onDevice, engine: engine)
        hearing.noEvidenceAfter = 1
        let sink = LocalHearingTests.Sink()
        try await hearing.start { sink.add($0) }
        for i in 0..<15 { hearing.feed(Data(count: 2_400 * 2), atFrame: Int64(i) * 2_400) }
        #expect(await sink.wait(1) { $0.contains(.failed(.noVoiceEvidence)) })
        #expect(sink.all.filter { $0 == .failed(.noVoiceEvidence) }.count == 1)
        #expect(ProviderIssue.noVoiceEvidence.message.contains("talking"))
        hearing.stop()
    }

    /// With detector results arriving (no uplink), no problem is raised.
    @Test func detectorResultsCountAsEvidence() async throws {
        let engine = FakeEngine()
        let hearing = LocalHearing(stt: .onDevice, engine: engine)
        hearing.noEvidenceAfter = 1
        let sink = LocalHearingTests.Sink()
        try await hearing.start { sink.add($0) }
        engine.activity(false, 0, 2_400)
        try await Task.sleep(for: .milliseconds(50))
        for i in 0..<15 { hearing.feed(Data(count: 2_400 * 2), atFrame: Int64(i) * 2_400) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!sink.all.contains(.failed(.noVoiceEvidence)))
        hearing.stop()
    }
}

@Suite struct UnreachableWordingTests {
    @Test func stoppedServerAsksIfItRuns() {
        let m = ProviderIssue.unreachable(host: "127.0.0.1:11434", vendor: .ollama).message
        #expect(m == "Can't reach the AI server at 127.0.0.1:11434 — is it running?")
        #expect(!m.contains("Expose Ollama"))
        let lan = ProviderIssue.unreachable(host: "192.168.1.196:8000", vendor: .other).message
        #expect(lan == "Can't reach the AI server at 192.168.1.196:8000 — is it running?")
        #expect(!ProviderIssue.timedOut(host: "192.168.1.196:8000", vendor: .ollama).message.contains("Expose"))
    }
}
