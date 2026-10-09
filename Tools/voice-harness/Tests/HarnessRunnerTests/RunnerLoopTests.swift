import DeeRealtime
import DeeVoice
import Foundation
import HarnessCore
import Testing
@testable import HarnessRunner

/// Server events in GA shapes (as in DeeVoiceTests' `Srv`).
enum Srv {
    static func speechStarted(_ item: String, ms: Int) -> ServerEvent {
        .speechStarted(.init(eventID: "ev_ss_\(item)", audioStartMs: ms, itemID: item))
    }
    static func speechStopped(_ item: String, ms: Int) -> ServerEvent {
        .speechStopped(.init(eventID: "ev_sp_\(item)", audioEndMs: ms, itemID: item))
    }
    static func committed(_ item: String) -> ServerEvent {
        .inputAudioCommitted(.init(eventID: "ev_c_\(item)", previousItemID: nil, itemID: item))
    }
    static func userTranscript(_ item: String, _ text: String) -> ServerEvent {
        .inputTranscriptionCompleted(.init(eventID: "ev_t_\(item)", itemID: item, transcript: text))
    }
    static func responseCreated(_ id: String) -> ServerEvent {
        .responseCreated(.init(eventID: "ev_rc_\(id)", response: ResponseObject(
            id: id, object: "realtime.response", status: "in_progress", output: [])))
    }
    static func messageAdded(_ resp: String, _ item: String) -> ServerEvent {
        .outputItemAdded(.init(eventID: "ev_oa_\(item)", responseID: resp, item: RealtimeItem(
            id: item, object: "realtime.item", type: "message", status: "in_progress", role: "assistant", content: [])))
    }
    static func audio(_ resp: String, _ item: String, _ pcm: Data) -> ServerEvent {
        .outputAudioDelta(.init(responseID: resp, itemID: item, delta: pcm.base64EncodedString()))
    }
    static func audioDone(_ resp: String, _ item: String) -> ServerEvent {
        .outputAudioDone(.init(responseID: resp, itemID: item))
    }
    static func transcriptDone(_ resp: String, _ item: String, _ text: String) -> ServerEvent {
        .outputAudioTranscriptDone(.init(responseID: resp, itemID: item, text: text))
    }
    static func responseDone(_ id: String) -> ServerEvent {
        .responseDone(.init(eventID: "ev_rd_\(id)", response: ResponseObject(
            id: id, object: "realtime.response", status: "completed", output: [])))
    }
}

let toolRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func tonePCM(seconds: Double, hz: Double = 220, amplitude: Float = 0.3) -> Data {
    let n = Int(seconds * 24_000)
    return WAV.pcm16((0..<n).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / 24_000)) })
}

@Suite("Runner (offline, scripted server)", .serialized)
struct RunnerLoopTests {
    @Test func parsesTimelineTruncateDetails() {
        #expect(ScenarioRunner.parseTruncate("item_abc audio_end_ms=1520")! == ("item_abc", 1520))
        #expect(ScenarioRunner.parseTruncate("garbage") == nil)
    }

    @Test func keyFileErrorsNeverHoldTheContent() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vh-key-\(UUID().uuidString)")
        try "not-a-key-but-secret-looking-sk".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: KeyFile.Failure.self) { _ = try KeyFile.load(url) }
        do { _ = try KeyFile.load(url) } catch { #expect(!"\(error)".contains("secret-looking")) }
    }

    @Test func aTurnEndToEndThroughTheRealVoiceAndSession() async throws {
        guard FileManager.default.fileExists(atPath: toolRoot.appendingPathComponent("Fixtures/manifest.json").path) else { return }
        let library = try FixtureLibrary(directory: toolRoot.appendingPathComponent("Fixtures"))
        let factory = FakeSocketFactory([]) { FakeSocket(request: $0, sessionID: "sess_harness") }
        let traceDir = FileManager.default.temporaryDirectory.appendingPathComponent("vh-trace-\(UUID().uuidString)")
        var options = RunnerOptions()
        options.classifySounds = false
        options.traceDirectory = traceDir
        options.gapAfter = 0.5
        options.replyTimeout = 4
        let scenario = Scenario(name: "offline", noise: .init(bed: "fan", snrDb: 20),
                                echo: EchoConfig(gainDB: -30, delayMs: 60), leadIn: 0.3,
                                steps: [.init(say: "q02")])
        let runner = ScenarioRunner(scenario: scenario, library: library,
                                    connection: .custom(credentials: { _ in .direct("sk-test-not-a-real-key-000") },
                                                        socketFactory: factory.factory),
                                    brain: MinimalBrain(), spend: SpendGuard(pricing: .mini, maxUSD: 1), options: options)
        let run = Task { await runner.run() }
        let socket = try #require(await factory.waitForSocket(count: 1, timeout: 5))
        // q02 ("Are you awake?") starts ~0.45 s in and ends ~1.26 s in (harness clock).
        try await Task.sleep(for: .milliseconds(700))
        socket.push(Srv.speechStarted("u1", ms: 2_400))
        try await Task.sleep(for: .milliseconds(900))
        socket.push(Srv.speechStopped("u1", ms: 3_300))
        socket.push(Srv.committed("u1"))
        #expect(await socket.waitForSent(type: "response.create", count: 1, timeout: 3))
        // Real server latency (~80 ms): replay is timed, so a 3 ms reply would race
        // the replayed client's own response.create.
        try await Task.sleep(for: .milliseconds(120))
        socket.push(Srv.responseCreated("r1"))
        socket.push(Srv.messageAdded("r1", "a1"))
        socket.push(Srv.audio("r1", "a1", tonePCM(seconds: 0.6)))
        socket.push(Srv.userTranscript("u1", "Are you awake?"))
        socket.push(Srv.audioDone("r1", "a1"))
        socket.push(Srv.transcriptDone("r1", "a1", "Yes, I'm awake."))
        socket.push(Srv.responseDone("r1"))
        let record = await run.value

        #expect(record.aborted == nil)
        #expect(record.connectedAt != nil)
        #expect(record.utterances.count == 1)
        let u = try #require(record.utterances.first)
        #expect(abs(u.onset - 0.45) < 0.1 && abs(u.endOfSpeech - 1.26) < 0.1)
        #expect(record.userItems.map(\.itemID) == ["u1"])
        #expect(record.requests.first?.outcome == "sent")
        let p = try #require(record.playback.first { $0.itemID == "a1" })
        #expect(p.flushed == false && abs((p.playedMs ?? 0) - 600) <= 40)
        #expect((p.started ?? 0) > u.endOfSpeech)
        #expect(record.responses.first?.status == "completed")
        #expect(record.deeTranscripts["a1"] == "Yes, I'm awake.")
        #expect(record.bedLevelDB.map { abs($0 - (-44)) < 0.1 } == true)

        let m = Metrics.compute([record], pricing: .mini)
        #expect(m.dropped == 0)
        #expect(m.latencies.count == 1)
        #expect(m.utterances.first?.transcript == "Are you awake?")
        #expect(m.utterances.first?.werEdits == 0)

        // The mic the server got carried the fixture: the uplink is not silent.
        let appends = socket.sent.filter { $0.contains("input_audio_buffer.append") }
        #expect(appends.count > 10)

        // Layer 2: the trace was recorded, and replays through the real socket code.
        let traceURL = traceDir.appendingPathComponent("offline.jsonl")
        let entries = try TraceRecorder.load(traceURL)
        #expect(entries.contains { $0.type == "response.done" })
        #expect(!entries.contains { $0.event.jsonText.contains("sk-test") })
        let server = TraceReplayServer(entries: entries)
        let port = try await server.start()
        defer { server.stop() }
        let replay = ScenarioRunner(scenario: scenario, library: library,
                                    connection: .local(endpoint: URL(string: "ws://127.0.0.1:\(port)/v1/realtime")!),
                                    brain: MinimalBrain(), spend: SpendGuard(pricing: .mini, maxUSD: 1), options: {
                                        var o = options; o.traceDirectory = nil; return o }())
        let replayed = await replay.run()
        #expect(replayed.aborted == nil)
        #expect(replayed.userItems.map(\.itemID) == ["u1"])
        #expect(replayed.responses.contains { $0.status == "completed" },
                "\(replayed.errors.map(\.text)) trace \(traceURL.path)")
    }
}
