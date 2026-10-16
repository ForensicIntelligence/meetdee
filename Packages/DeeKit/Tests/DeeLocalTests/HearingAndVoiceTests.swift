import Foundation
import Testing
import Synchronization
import DeeRealtime
import DeeVoice
@testable import DeeWake
@testable import DeeLocal
import DeeMockServer

@Suite struct TurnDetectorTests {
    @Test func startsWithPrefixAndCommitsAfterSilence() {
        var d = TurnDetectorCore()
        var events: [TurnDetectorCore.Event] = []
        // 50 ms of voice: not yet a turn (min 100 ms).
        events += d.evidence(start: 24_000, end: 25_200, voice: true)
        #expect(events.isEmpty)
        events += d.evidence(start: 25_200, end: 26_400, voice: true)
        #expect(events == [.started(turn: 1, frame: 24_000 - 7_200)])
        // 200 ms silence: still open.
        events += d.evidence(start: 26_400, end: 31_200, voice: false)
        #expect(events.count == 1)
        // 300 ms silence: stopped + committed at last voice + 300 ms.
        events += d.evidence(start: 31_200, end: 33_600, voice: false)
        #expect(events.suffix(2) == [.stopped(turn: 1, frame: 26_400 + 7_200),
                                     .committed(turn: 1, startFrame: 16_800, endFrame: 33_600)])
        // The next turn's prefix never reaches back into the last one.
        events += d.evidence(start: 33_600, end: 36_000, voice: true)
        #expect(events.last == .started(turn: 2, frame: 33_600))
    }

    @Test func clientCommit() {
        var d = TurnDetectorCore()
        #expect(d.commitNow(at: 12_000) == [.committed(turn: 1, startFrame: 0, endFrame: 12_000)])
        _ = d.evidence(start: 12_000, end: 16_000, voice: true)
        #expect(d.commitNow(at: 18_000) == [.stopped(turn: 2, frame: 18_000), .committed(turn: 2, startFrame: 12_000, endFrame: 18_000)])
        #expect(d.commitNow(at: 18_000).isEmpty)
    }

    @Test func shortBlipsNeverOpenATurn() {
        var d = TurnDetectorCore()
        var events: [TurnDetectorCore.Event] = []
        for i in 0..<20 {
            let s = Int64(i) * 4_800
            events += d.evidence(start: s, end: s + 960, voice: true)       // 40 ms click
            events += d.evidence(start: s + 960, end: s + 4_800, voice: false)
        }
        #expect(events.isEmpty)
    }
}

@Suite struct NameRewriteTests {
    @Test(arguments: [
        ("Heidi, what's up?", "Dee, what's up?"),
        ("KD, are you awake?", "Dee, are you awake?"),
        ("Hey D what time is it", "Hey Dee what time is it"),
        ("hi kd how are you", "hi Dee how are you"),
        ("What's the weather, Heidi?", "What's the weather, Dee?"),
        ("Heidi Klum was on TV", "Heidi Klum was on TV"),
        ("I said it to D and E", "I said it to D and E"),
        ("Haidee what time is it", "Hi Dee, what time is it"),
    ])
    func rewrite(_ input: String, _ expected: String) {
        #expect(NameRewrite.rewrite(input) == expected)
    }
}

@Suite(.serialized) struct LocalHearingTests {
    final class Sink: @unchecked Sendable {
        let events = Mutex<[HearingEvent]>([])
        func add(_ e: HearingEvent) { events.withLock { $0.append(e) } }
        var all: [HearingEvent] { events.withLock { $0 } }
        func wait(_ timeout: Double = 3, _ p: ([HearingEvent]) -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end { if p(all) { return true }; try? await Task.sleep(for: .milliseconds(10)) }
            return p(all)
        }
    }

    @Test func onDeviceDeltasAppendOnlyAndFastFinal() async throws {
        let engine = FakeEngine()
        engine.onFinalize = { end in
            SpeechSegment(text: "what's my dog's name?", isFinal: true, startFrame: 4_800, endFrame: end - 7_000)
        }
        let hearing = LocalHearing(stt: .onDevice, engine: engine)
        let sink = Sink()
        try await hearing.start { sink.add($0) }
        hearing.setKeywords(["Hey Dee"])
        hearing.feed(Data(count: 24_000 * 2), atFrame: 0)
        #expect(engine.fed > 15_000)   // downsampled to 16 kHz
        engine.activity(true, 2_400, 4_800)
        engine.activity(true, 4_800, 12_000)
        engine.segment(SpeechSegment(text: "what's my", isFinal: false, startFrame: 4_800))
        engine.segment(SpeechSegment(text: "what's my dog", isFinal: false, startFrame: 4_800))
        engine.segment(SpeechSegment(text: "what's my dark", isFinal: false, startFrame: 4_800))   // revised: no delta
        let start = Date()
        engine.activity(false, 12_000, 20_000)
        #expect(await sink.wait { $0.contains { if case .transcriptCompleted = $0 { true } else { false } } })
        #expect(Date().timeIntervalSince(start) < 0.5)   // gate: commit → completed ≤ 0.5 s
        let all = sink.all
        let deltas = all.compactMap { if case .transcriptDelta(_, let d) = $0 { d } else { nil } }
        // Append-only: the revised volatile ("dark") never went out; the deltas spell the final text.
        #expect(deltas.joined() == "what's my dog's name?")
        #expect(!deltas.joined().contains("dark"))
        #expect(all.contains(.transcriptCompleted(turn: 1, text: "what's my dog's name?")))
        // committed precedes completed; finalize ran through the commit frame.
        let ci = all.firstIndex(of: .committed(turn: 1))!
        let ti = all.firstIndex(where: { if case .transcriptCompleted = $0 { true } else { false } })!
        #expect(ci < ti)
        #expect(engine.finalized == [12_000 + 7_200])
        hearing.stop()
    }

    @Test func earCoreVetoesABed() async throws {
        let engine = FakeEngine()
        let uplink = UplinkActivity()
        let hearing = LocalHearing(stt: .onDevice, engine: engine, uplink: uplink)
        let sink = Sink()
        try await hearing.start { sink.add($0) }
        // The detector calls a TV bed speech; EarCore says no voice.
        uplink.record(frames: 48_000, voice: false)
        hearing.feed(Data(count: 48_000 * 2), atFrame: 0)
        engine.activity(true, 0, 36_000)
        engine.activity(false, 36_000, 48_000)
        try await Task.sleep(for: .milliseconds(200))
        #expect(sink.all.isEmpty)
        hearing.stop()
    }

    @Test func lanSTTSendsTheCommittedSpan() async throws {
        let server = try await DeeMockServer.start(cases: [.transcriptions], models: ["whisper-1"])
        defer { server.stop() }
        server.setTranscribe { _ in "  heidi, what's up  " }
        let client = CompatClient(base: server.baseURL, key: nil, transport: .live(redirects: .refuse))
        let engine = FakeEngine()
        let hearing = LocalHearing(stt: .lan(client, model: "whisper-1"), engine: engine)
        let sink = Sink()
        try await hearing.start { sink.add($0) }
        hearing.feed(Data(count: 48_000 * 2), atFrame: 0)
        engine.activity(true, 12_000, 24_000)
        engine.activity(false, 24_000, 36_000)
        #expect(await sink.wait { $0.contains { if case .transcriptCompleted = $0 { true } else { false } } })
        #expect(sink.all.contains(.transcriptCompleted(turn: 1, text: "Dee, what's up")))
        #expect(!sink.all.contains { if case .transcriptDelta = $0 { true } else { false } })   // no deltas from REST
        let req = try #require(server.requests(path: "/v1/audio/transcriptions").first)
        // WAV of [12000 − 7200, 24000 + 7200) = 26 400 frames.
        let riff = req.body.range(of: Data("RIFF".utf8))!
        let size = req.body[riff.lowerBound + 40..<riff.lowerBound + 44].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(Int(size) == 26_400 * 2)
        #expect(String(decoding: req.body, as: UTF8.self).contains("whisper-1"))
        hearing.stop()
    }
}

@Suite(.serialized) struct OpenAITranscriptionHearingTests {
    @Test func mapsTranscriptionSessionEvents() async throws {
        let server = try await DeeMockServer.start(cases: [.realtimeWS])
        defer { server.stop() }
        server.setRealtimeGreeting([["type": "session.created", "session": ["id": "sess_t", "type": "transcription"]]])
        let sent = Mutex(0)
        server.setRealtime { event in
            guard event["type"] as? String == "input_audio_buffer.append" else { return [] }
            let n = sent.withLock { $0 += 1; return $0 }
            guard n == 2 else { return [] }
            return [
                ["type": "input_audio_buffer.speech_started", "audio_start_ms": 120, "item_id": "item_A"],
                ["type": "input_audio_buffer.speech_stopped", "audio_end_ms": 900, "item_id": "item_A"],
                ["type": "input_audio_buffer.committed", "item_id": "item_A", "previous_item_id": NSNull()],
                ["type": "conversation.item.input_audio_transcription.delta", "item_id": "item_A", "content_index": 0, "delta": "hello "],
                ["type": "conversation.item.input_audio_transcription.completed", "item_id": "item_A", "content_index": 0, "transcript": "hello there"],
            ]
        }
        var ws = URLComponents(url: server.baseURL, resolvingAgainstBaseURL: false)!
        ws.scheme = "ws"; ws.path = "/v1/realtime"; ws.query = "intent=transcription"
        let recorder = TransportRecorder()
        let hearing = OpenAITranscriptionHearing(transport: .live(redirects: .sameHost, recorder: recorder),
                                                 credential: { .ephemeral("ek_fake", expiresAt: Date().addingTimeInterval(60)) },
                                                 url: ws.url!)
        let sink = LocalHearingTests.Sink()
        // Audio fed before the socket is ready is queued, then sent in order.
        hearing.feed(Data(count: 960), atFrame: 0)
        try await hearing.start { sink.add($0) }
        hearing.feed(Data(count: 960), atFrame: 480)
        #expect(await sink.wait { $0.contains { if case .transcriptCompleted = $0 { true } else { false } } })
        let expected: [HearingEvent] = [
            .speechStarted(turn: 1, frame: 2_880), .speechStopped(turn: 1, frame: 21_600), .committed(turn: 1),
            .transcriptDelta(turn: 1, delta: "hello "), .transcriptCompleted(turn: 1, text: "hello there"),
        ]
        let got = sink.all
        #expect(got == expected)
        #expect(server.realtimeMessages.filter { $0.contains("input_audio_buffer.append") }.count == 2)
        #expect(recorder.records.map(\.kind) == [.webSocket])
        #expect(recorder.records.first?.purpose == "stt")
        hearing.stop()
    }

    /// A refused transcription mint is a hard problem: no direct key, no other hearing.
    @Test func refusedMintIsHard() async {
        let recorder = TransportRecorder()
        let hearing = OpenAITranscriptionHearing(transport: .failing(recorder: recorder),
                                                 credential: { throw RealtimeAuthError.transcriptionUnavailable(status: 404) })
        await #expect(throws: ProviderIssue.transcriptionUnavailable) { try await hearing.start { _ in } }
        #expect(recorder.count == 0)
        let noKey = OpenAITranscriptionHearing(transport: .failing(), credential: { throw RealtimeAuthError.noKey })
        await #expect(throws: ProviderIssue.noOpenAIKey) { try await noKey.start { _ in } }
    }
}

@Suite(.serialized) struct VoiceBackendTests {
    @Test func openAIStreamingSpeechSendsStyle() async throws {
        let server = try await DeeMockServer.start(cases: [.speech])
        defer { server.stop() }
        let client = CompatClient(base: server.baseURL, key: "fake-key", transport: .live(redirects: .refuse))
        let voice = StreamingSpeechVoice(client: client, model: "gpt-4o-mini-tts", voice: "cedar")
        var pcm = Data()
        var chunks = 0
        for try await c in voice.synthesize("Hello there.", delivery: SpeechDelivery(instructions: "Bright. Voice: bubbly.", speed: 1)) {
            pcm.append(c); chunks += 1
            #expect(c.count % 2 == 0)
        }
        #expect(pcm.count == 12 * 1_440 * 2)   // 60 ms per char at 24 kHz
        #expect(chunks > 1)                    // streamed
        let body = try #require(server.requests(path: "/v1/audio/speech").first?.jsonObject)
        #expect(body["voice"] as? String == "cedar")
        #expect(body["response_format"] as? String == "pcm")
        #expect(body["instructions"] as? String == "Bright. Voice: bubbly.")
    }

    @Test func lanSpeechWAVIsResampledTo24k() async throws {
        let server = try await DeeMockServer.start(cases: [.speech])
        defer { server.stop() }
        server.setSpeechRate(22_050)
        let client = CompatClient(base: server.baseURL, key: nil, transport: .live(redirects: .refuse))
        let voice = LANSpeechVoice(client: client, model: "kokoro", voice: "af_heart")
        var pcm = Data()
        for try await c in voice.synthesize("Hi there.", delivery: SpeechDelivery()) { pcm.append(c) }
        let frames = pcm.count / 2
        let source: Int = 9 * 22_050 * 60 / 1000
        let expected: Int = source * 24_000 / 22_050
        #expect(abs(frames - expected) < 200)
        let body = try #require(server.requests(path: "/v1/audio/speech").first?.jsonObject)
        #expect(body["instructions"] == nil)
        #expect(body["response_format"] as? String == "wav")
    }

    @Test func onDeviceVoiceRendersLocally() async throws {
        guard OnDeviceVoice.available() else { return }   // a machine without any English voice
        let voice = OnDeviceVoice()
        var pcm = Data()
        for try await c in voice.synthesize("Hello.", delivery: SpeechDelivery(instructions: "Voice: sad, quiet.")) { pcm.append(c) }
        #expect(pcm.count > 24_000)   // > 0.5 s at 24 kHz
        let sad = OnDeviceVoice.shape(SpeechDelivery(instructions: "Voice: sad, quiet."))
        let happy = OnDeviceVoice.shape(SpeechDelivery(instructions: "Voice: bright and bubbly."))
        #expect(sad.pitch < happy.pitch && sad.rate < happy.rate)
    }
}
