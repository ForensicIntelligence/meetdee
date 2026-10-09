import AVFAudio
import Foundation
import Testing
@testable import DeeVoice

@Suite struct TurnTimelineTests {
    @Test func marksLandInTheCurrentTurn() throws {
        let tl = TurnTimeline()
        let id = tl.beginTurn(.speechStopped, at: 10)
        tl.mark(.responseCreateSent, at: 10.1)
        tl.mark(.firstAudioDelta, at: 10.5)
        tl.mark(.firstAudioDelta, at: 10.6)                   // once per turn
        tl.mark(.firstAudioPlayed, at: 10.7, detail: "item_1")
        let turn = try #require(tl.currentTurn)
        #expect(turn.id == id)
        #expect(turn.marks.map(\.stage) == [.speechStopped, .responseCreateSent, .firstAudioDelta, .firstAudioPlayed])
        #expect(abs(turn.elapsed(from: .speechStopped, to: .firstAudioPlayed)! - 0.7) < 1e-9)
        #expect(abs(turn.marks[2].ms - 500) < 1e-6)
        let next = tl.beginTurn(at: 20)
        tl.mark(.firstAudioDelta, at: 20.4)
        #expect(next == id + 1)
        #expect(tl.turns().count == 2)
        #expect(tl.currentTurn?.marks.count == 2)
    }

    @Test func markWithoutATurnStartsOne() {
        let tl = TurnTimeline()
        tl.mark(.note, at: 1, detail: "x")
        #expect(tl.turns().count == 1)
    }

    @Test func keepsOnlyRecentTurns() {
        let tl = TurnTimeline(keep: 3)
        for i in 0..<10 { tl.beginTurn(at: Double(i)) }
        #expect(tl.turns().map(\.start) == [7, 8, 9])
    }

    @Test func writesJSONLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dee-timeline-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let tl = TurnTimeline(fileURL: url)
        tl.beginTurn(.speechStopped, at: 1)
        tl.mark(.heard, at: 1.25, detail: "hi")
        tl.flush()
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let m = try JSONDecoder().decode(TurnTimeline.Mark.self, from: Data(lines[1].utf8))
        #expect(m.stage == .heard && m.ms == 250 && m.detail == "hi" && m.turn == 1)
        #expect(lines[0].contains("\"stage\":\"speech_stopped\""))
    }

    @Test func fileSinkOnlyWhenAsked() {
        #expect(TurnTimeline.defaultFileURL(environment: ["DEE_TIMELINE": "0"]) == nil)
        #expect(TurnTimeline.defaultFileURL(environment: ["DEE_TIMELINE": "/tmp/t.jsonl"])?.path == "/tmp/t.jsonl")
        #expect(TurnTimeline.defaultFileURL(environment: ["DEE_TIMELINE": "1"]) != nil)
        #if os(macOS)
        #expect(TurnTimeline.defaultFileURL(environment: [:]) == nil)
        #endif
    }
}

@Suite struct AudioInjectorTests {
    func writeWAV(_ samples: [Float], rate: Double, to url: URL) throws {
        let f = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: f.settings)
        try file.write(from: PCMTone.buffer(samples, rate: rate))
    }

    @Test func manifestBuildsTheScriptWithGaps() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dee-inject-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeWAV(Signal.sine(hz: 300, sampleRate: 48_000, seconds: 0.5), rate: 48_000, to: dir.appendingPathComponent("a.wav"))
        try writeWAV(Signal.sine(hz: 300, sampleRate: 16_000, seconds: 0.25), rate: 16_000, to: dir.appendingPathComponent("b.wav"))
        let manifest = #"{"leadIn": 0.5, "items": [{"file": "a.wav", "gap": 0.25}, {"file": "b.wav"}]}"#
        let m = dir.appendingPathComponent("fixtures.json")
        try Data(manifest.utf8).write(to: m)
        let inj = try AudioInjector(url: m)
        let seconds = Double(inj.script.count) / AudioInjector.sampleRate
        #expect(abs(seconds - (0.5 + 0.25 + 0.5 + 1.0 + 0.25)) < 0.005, "\(seconds)")
        // Lead-in is silent, the first file is loud.
        #expect(inj.samples(from: 0, count: 1000).allSatisfy { $0 == 0 })
        #expect(Level.rmsDB(inj.samples(from: Int64(0.85 * 24_000), count: 2400)) > -12)
        // After the script: silence forever.
        #expect(inj.samples(from: Int64(inj.script.count) + 10, count: 500).allSatisfy { $0 == 0 })
    }

    @Test func badManifestFailsWithAReason() throws {
        let m = FileManager.default.temporaryDirectory.appendingPathComponent("dee-bad-\(UUID().uuidString).json")
        try Data("{".utf8).write(to: m)
        defer { try? FileManager.default.removeItem(at: m) }
        #expect(throws: AudioInjector.Failure.self) { _ = try AudioInjector(url: m) }
        #expect(throws: AudioInjector.Failure.self) { _ = try AudioInjector(url: URL(fileURLWithPath: "/nonexistent.wav")) }
    }

    @Test func loopsWhenAsked() {
        let inj = AudioInjector(script: [1, 2, 3], loop: true)
        #expect(inj.samples(from: 2, count: 4) == [3, 1, 2, 3])
        let once = AudioInjector(script: [1, 2, 3], loop: false)
        #expect(once.samples(from: 2, count: 4) == [3, 0, 0, 0])
    }

    @Test func feedsInRealTimeWithoutDrift() async throws {
        let inj = AudioInjector(script: Signal.sine(hz: 300, sampleRate: 24_000, seconds: 1), loop: false)
        let frames = FrameCounter()
        let t0 = ProcessInfo.processInfo.systemUptime
        inj.start { buf, _ in frames.add(Int(buf.frameLength)) }
        try await Task.sleep(for: .milliseconds(400))
        inj.stop()
        let elapsed = ProcessInfo.processInfo.systemUptime - t0
        let seconds = Double(frames.value) / AudioInjector.sampleRate
        // Never ahead of the clock, never more than a couple of chunks behind it.
        #expect(seconds <= elapsed + 0.001 && seconds >= elapsed - 0.08, "\(seconds) of \(elapsed)")
    }
}

final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add(_ k: Int) { lock.lock(); n += k; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
