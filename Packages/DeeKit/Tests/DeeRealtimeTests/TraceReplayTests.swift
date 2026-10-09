import Foundation
import Testing
@testable import DeeRealtime

@Suite struct TraceRecorderTests {
    @Test func recordsBothDirectionsWithElidedAudio() throws {
        let clock = ManualRealtimeClock(start: 50)
        let rec = try TraceRecorder(fileURL: nil, clock: clock)
        rec.record(.client, text: try ClientEvent.inputAudioAppend(audio: Data(count: 960).base64EncodedString()).jsonText())
        clock.advance(by: 0.25)
        rec.record(.server, text: try S.audio("r", "i", ms: 10).jsonText())
        rec.record(.server, text: try S.speechStarted("u").jsonText())
        let e = rec.entries
        #expect(e.count == 3)
        #expect(e[0].dir == .client && e[0].t == 0)
        #expect(e[0].event["audio"] == "" && e[0].event["audio_bytes"] == 960)
        #expect(e[1].dir == .server && e[1].t == 0.25)
        #expect(e[1].event["delta"] == "" && e[1].event["delta_bytes"] == 480)
        #expect(e[2].event["audio_start_ms"] == 100)
        // Restored audio is silence of the recorded length.
        let restored = TraceRecorder.restore(e[1].event)
        #expect(restored["delta_bytes"] == nil)
        #expect(Data(base64Encoded: restored["delta"]?.stringValue ?? "")?.count == 480)
    }

    @Test func writesAndLoadsJSONL() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dee-trace-\(UUID().uuidString)").appendingPathComponent("t.jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rec = try TraceRecorder(fileURL: url)
        rec.record(.server, text: try S.speechStarted("u").jsonText())
        rec.record(.client, text: "not json")   // skipped
        rec.record(.client, text: try ClientEvent.responseCreate(nil).jsonText())
        rec.flush()
        let loaded = try TraceRecorder.load(url)
        #expect(loaded.map(\.type) == ["input_audio_buffer.speech_started", "response.create"])
        #expect(loaded.map(\.dir) == [.server, .client])
    }
}

/// The real `URLSessionRealtimeSocket` + `RealtimeSession` against a loopback
/// `NWListener` replaying a recorded trace (design §7.3).
@Suite(.serialized) struct TraceReplayTests {
    /// A trace in the recorder's format: one complete turn. The server answers
    /// 400 ms after the commit (200 ms at replay speed 2), leaving the app time to
    /// send its `response.create` even on a loaded test machine.
    static func turnTrace() -> [TraceRecorder.Entry] {
        func e(_ t: Double, _ dir: TraceRecorder.Direction, _ event: ServerEvent) -> TraceRecorder.Entry {
            TraceRecorder.Entry(t: t, dir: dir, event: TraceRecorder.elide(json((try? event.jsonText()) ?? "{}")))
        }
        let session = SessionInfo(raw: ["id": "sess_replay", "object": "realtime.session", "model": "gpt-realtime-2.1-mini"])
        return [
            TraceRecorder.Entry(t: 0.00, dir: .client, event: ["type": "session.update", "session": ["type": "realtime"]]),
            e(0.02, .server, .sessionCreated(.init(eventID: "e1", session: session))),
            e(0.03, .server, .sessionUpdated(.init(eventID: "e2", session: session))),
            e(0.20, .server, S.speechStarted("item_u")),
            e(0.60, .server, S.speechStopped("item_u")),
            e(0.61, .server, S.committed("item_u")),
            e(1.02, .server, S.responseCreated("resp_r")),
            e(1.03, .server, S.messageAdded("resp_r", "item_a")),
            e(1.10, .server, S.transcript("resp_r", "item_a", "Hello there. ")),
            e(1.11, .server, S.audio("resp_r", "item_a", ms: 200)),
            e(1.15, .server, S.audio("resp_r", "item_a", ms: 200)),
            e(1.16, .server, S.transcript("resp_r", "item_a", "Nice day.")),
            e(1.20, .server, S.audioDone("resp_r", "item_a")),
            e(1.20, .server, S.transcriptDone("resp_r", "item_a", "Hello there. Nice day.")),
            e(1.21, .server, S.responseDone("resp_r")),
            e(1.30, .server, S.userTranscript("item_u", "Hi Dee")),
        ]
    }

    @Test func realSocketReplaysATurn() async throws {
        let server = TraceReplayServer(entries: Self.turnTrace(), speed: 2)
        let port = try await server.start()
        defer { server.stop() }
        var config = RealtimeSessionConfig()
        config.endpoint = URL(string: "ws://127.0.0.1:\(port)/v1/realtime")!
        let trace = try TraceRecorder(fileURL: nil)
        let session = RealtimeSession(config: config,
                                      credentials: { _ in .direct("sk-test-replay") },
                                      trace: trace)
        let log = EventLog(session.events)
        try await session.connect()
        #expect(await session.sessionID == "sess_replay")
        #expect(server.requestHeaders["authorization"] == "Bearer sk-test-replay")
        await session.appendAudio(Data(count: 480))

        // The app's side of the turn: answer on commit.
        #expect(await log.wait(timeout: 5) { $0 == .userCommitted(itemID: "item_u", previousItemID: nil) } != nil)
        try await session.requestResponse(cueItem: "<dee_state>calm</dee_state>")
        let done = try #require(await log.wait(timeout: 5) { $0.responseDone != nil }?.responseDone)
        #expect(done.status == "completed")
        #expect(done.audioMs == 400)
        #expect(await log.wait(timeout: 5) { $0 == .userTranscript(itemID: "item_u", text: "Hi Dee") } != nil)
        #expect(log.count(\.isAudio) == 2)
        #expect(log.contains { if case .assistantSentence("item_a", "Hello there.", _) = $0 { true } else { false } })
        // Its share of the complete audio (400) is before "Hello there."'s end (12 × 62): clamped (HeardRule).
        #expect(log.contains { if case .assistantSentence("item_a", "Nice day.", 744) = $0 { true } else { false } })

        // What reached the server, in order.
        let types = server.received.compactMap { json($0)["type"]?.stringValue }
        #expect(types.first == "session.update")
        #expect(types.contains("input_audio_buffer.append"))
        #expect(types.suffix(2) == ["conversation.item.create", "response.create"])
        // And the recorder saw both directions.
        #expect(trace.entries.contains { $0.dir == .server && $0.type == "response.done" })
        #expect(trace.entries.contains { $0.dir == .client && $0.type == "response.create" })
        await session.close()
    }

    @Test func realSocketDropAdvisesFallback() async throws {
        let entries = Array(Self.turnTrace().prefix(3))   // just the handshake
        let server = TraceReplayServer(entries: entries)
        let port = try await server.start()
        defer { server.stop() }
        var config = RealtimeSessionConfig()
        config.endpoint = URL(string: "ws://127.0.0.1:\(port)/v1/realtime")!
        config.autoReconnect = false
        let session = RealtimeSession(config: config, credentials: { _ in .direct("sk-test") })
        let log = EventLog(session.events)
        try await session.connect()
        server.dropConnection()
        #expect(await log.wait(timeout: 5) { if case .socketLost? = $0.fallback { true } else { false } } != nil)
        #expect(await session.state == .idle)
    }

    @Test func connectRefusedIsAFallback() async throws {
        // Nothing listens on this port.
        var config = RealtimeSessionConfig()
        config.endpoint = URL(string: "ws://127.0.0.1:9/v1/realtime")!
        config.connectTimeout = 3
        let session = RealtimeSession(config: config, credentials: { _ in .direct("sk-test") })
        let log = EventLog(session.events)
        await #expect(throws: RealtimeSessionError.self) { try await session.connect() }
        #expect(await log.wait { if case .connectFailed? = $0.fallback { true } else { false } } != nil)
    }
}
