import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import DeeVoice

/// Collects `PCMStreamPlayer` events delivered by manual renders.
final class EventLog: Sendable {
    private let events = Mutex<[PCMStreamPlayer.Event]>([])
    func append(_ e: PCMStreamPlayer.Event) { events.withLock { $0.append(e) } }
    var all: [PCMStreamPlayer.Event] { events.withLock { $0 } }
    func clear() { events.withLock { $0.removeAll() } }

    var started: [String] { all.compactMap { if case .started(let u, _) = $0 { u } else { nil } } }
    var finished: [(String, Int, Bool)] { all.compactMap { if case .finished(let u, let ms, let f) = $0 { (u, ms, f) } else { nil } } }
    var underruns: [String] { all.compactMap { if case .underrun(let u) = $0 { u } else { nil } } }
    var levels: [Double] { all.compactMap { if case .level(let l) = $0 { l } else { nil } } }
}

/// The player path of `AudioGraph` in offline manual-rendering mode: real
/// AVAudioEngine, no hardware, faster than real time.
struct ManualRig {
    let graph: AudioGraph
    let log = EventLog()
    let rate = 48_000.0
    var renderedMs = 0.0
    /// Output samples (channel 0) of everything rendered.
    var output: [Float] = []

    init() throws {
        graph = try AudioGraph.manual(sampleRate: 48_000, channels: 1)
        let log = self.log
        graph.player.onEvent = { log.append($0) }
    }

    var player: PCMStreamPlayer { graph.player }

    /// Renders `ms` of output in 10 ms cycles (like a 480-frame IO buffer).
    mutating func render(_ ms: Double) throws {
        var left = Int((ms / 1000 * rate).rounded())
        while left > 0 {
            let n = min(480, left)
            let b = try graph.render(frames: AVAudioFrameCount(n))
            output += b.firstChannelSamples()
            left -= n
            renderedMs += Double(n) / rate * 1000
        }
    }

    /// Milliseconds from the first to the last output sample with signal
    /// (|x| > threshold) at or after `startMs`.
    func audibleMs(from startMs: Double = 0, threshold: Float = 0.01) -> Double {
        let start = Int(startMs / 1000 * rate)
        guard start < output.count,
              let first = output[start...].firstIndex(where: { abs($0) > threshold }),
              let last = output[start...].lastIndex(where: { abs($0) > threshold }) else { return 0 }
        return Double(last - first + 1) / rate * 1000
    }

    /// First output time (ms) with signal.
    func firstAudibleMs(threshold: Float = 0.01) -> Double? {
        output.firstIndex { abs($0) > threshold }.map { Double($0) / rate * 1000 }
    }
}

enum PCMTone {
    /// `ms` of a 24 kHz Int16 LE sine (amplitude 0.5).
    static func data(ms: Double, hz: Double = 440, amplitude: Double = 0.5) -> Data {
        let n = Int(ms / 1000 * 24_000)
        let s: [Int16] = (0..<n).map { Int16((amplitude * sin(2 * .pi * hz * Double($0) / 24_000) * 32767).rounded()) }
        return s.withUnsafeBytes { Data($0) }
    }

    static func buffer(_ samples: [Float], rate: Double) -> AVAudioPCMBuffer {
        let f = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        b.frameLength = AVAudioFrameCount(samples.count)
        for (i, v) in samples.enumerated() { b.floatChannelData![0][i] = v }
        return b
    }
}

@Suite struct StreamPlayerTests {
    @Test func playedMillisecondsAreExactAndFinishReportsTheWhole() throws {
        var r = try ManualRig()
        r.player.enqueue(PCMTone.data(ms: 1000), utterance: "item_a")
        r.player.finish(utterance: "item_a")
        try r.render(400)
        let mid = r.player.playedMs(utterance: "item_a")
        // Complete utterance: no prebuffer wait. The source runs ~one render cycle
        // ahead of the mixer's output (resampler lookahead), never more.
        #expect(mid >= 395 && mid <= 412, "\(mid)")
        try r.render(800)
        #expect(r.player.playedMs(utterance: "item_a") == 1000)
        #expect(r.log.started == ["item_a"])
        let fin = try #require(r.log.finished.first)
        #expect(fin.0 == "item_a" && fin.1 == 1000 && !fin.2)
        // Exactly one second of signal came out.
        #expect(abs(r.audibleMs() - 1000) < 6, "\(r.audibleMs())")
        #expect(!r.player.isBusy)
    }

    @Test func jitterBufferWaitsForTargetBeforeStarting() throws {
        var r = try ManualRig()
        #expect(r.player.targetMs == PCMStreamPlayer.minTargetMs)
        r.player.enqueue(PCMTone.data(ms: 60), utterance: "item_a")
        try r.render(200)
        #expect(r.log.started.isEmpty)                       // 60 < 120 ms: still buffering
        #expect(r.player.playedMs(utterance: "item_a") == 0)
        #expect(r.audibleMs() == 0)
        r.player.enqueue(PCMTone.data(ms: 80), utterance: "item_a")   // 140 ms buffered
        try r.render(20)
        #expect(r.log.started == ["item_a"])
        #expect(r.player.playedMs(utterance: "item_a") > 0)
    }

    @Test func shortCompleteUtterancePlaysWithoutWaiting() throws {
        var r = try ManualRig()
        r.player.enqueue(PCMTone.data(ms: 50), utterance: "hm")
        r.player.finish(utterance: "hm")
        try r.render(100)
        #expect(r.log.started == ["hm"])
        #expect(r.log.finished.first.map { $0.1 } == 50)
    }

    @Test func underrunRebuffersAndRaisesTheTarget() throws {
        var r = try ManualRig()
        r.player.enqueue(PCMTone.data(ms: 200), utterance: "item_a")
        try r.render(300)                                    // network fell behind
        #expect(r.log.underruns == ["item_a"])
        #expect(r.player.targetMs == PCMStreamPlayer.minTargetMs + PCMStreamPlayer.underrunStepMs)
        #expect(r.player.playedMs(utterance: "item_a") == 200)
        // More audio: waits for the new, larger target before resuming.
        r.player.enqueue(PCMTone.data(ms: 100), utterance: "item_a")
        try r.render(50)
        #expect(r.player.playedMs(utterance: "item_a") == 200)
        r.player.enqueue(PCMTone.data(ms: 100), utterance: "item_a")
        r.player.finish(utterance: "item_a")
        try r.render(300)
        #expect(r.player.playedMs(utterance: "item_a") == 400)
        #expect(r.log.underruns.count == 1)
    }

    @Test func targetIsCappedAndRecoversAfterCleanUtterances() throws {
        var r = try ManualRig()
        for _ in 0..<8 {                                     // 8 underruns: 120 + 240 → capped at 250
            r.player.enqueue(PCMTone.data(ms: 300), utterance: "item_a")
            try r.render(400)
        }
        #expect(r.player.targetMs == PCMStreamPlayer.maxTargetMs)
        r.player.finish(utterance: "item_a")
        try r.render(50)
        r.player.enqueue(PCMTone.data(ms: 1200), utterance: "item_b")
        r.player.finish(utterance: "item_b")
        try r.render(1400)
        #expect(r.player.targetMs == PCMStreamPlayer.maxTargetMs - PCMStreamPlayer.cleanStepMs)
    }

    @Test func flushStopsAtOnceAndReportsWhatWasPlayed() throws {
        var r = try ManualRig()
        r.player.enqueue(PCMTone.data(ms: 2000), utterance: "item_a")
        try r.render(500)
        let cut = try #require(r.player.flush())
        #expect(cut.utterance == "item_a")
        let audibleBefore = r.audibleMs()
        // What we report as played is what came out (± one render cycle of lookahead).
        #expect(abs(Double(cut.playedMs) - audibleBefore) <= 12, "\(cut.playedMs) vs \(audibleBefore)")
        let flushAt = r.renderedMs
        try r.render(300)
        // Only the 5 ms fade (plus resampler tail) after the flush.
        #expect(r.audibleMs(from: flushAt) < 10, "\(r.audibleMs(from: flushAt))")
        let fin = try #require(r.log.finished.first)
        #expect(fin.0 == "item_a" && fin.1 == cut.playedMs && fin.2)
        #expect(r.player.playedMs(utterance: "item_a") == cut.playedMs)
        // Deltas still in flight for the cut item never play.
        r.player.enqueue(PCMTone.data(ms: 500), utterance: "item_a")
        try r.render(300)
        #expect(r.audibleMs(from: flushAt) < 10)
        #expect(!r.player.isBusy)
        // The next item plays normally.
        r.player.enqueue(PCMTone.data(ms: 200), utterance: "item_b")
        r.player.finish(utterance: "item_b")
        try r.render(300)
        #expect(r.log.finished.contains { $0.0 == "item_b" && $0.1 == 200 && !$0.2 })
    }

    @Test func flushWhenIdleReturnsNil() throws {
        let r = try ManualRig()
        #expect(r.player.flush() == nil)
    }

    @Test func flushDropsQueuedUtterancesWithZeroPlayed() throws {
        var r = try ManualRig()
        r.player.enqueue(PCMTone.data(ms: 300), utterance: "a")
        r.player.enqueue(PCMTone.data(ms: 300), utterance: "b")
        try r.render(150)
        let cut = try #require(r.player.flush())
        #expect(cut.utterance == "a")
        try r.render(20)
        let fin = r.log.finished
        #expect(fin.contains { $0.0 == "a" && $0.2 })
        #expect(fin.contains { $0.0 == "b" && $0.1 == 0 && $0.2 })
        #expect(!r.log.started.contains("b"))
    }

    @Test func utterancesPlayBackToBackInOrder() throws {
        var r = try ManualRig()
        r.player.enqueue(PCMTone.data(ms: 300), utterance: "a")
        r.player.enqueue(PCMTone.data(ms: 400), utterance: "b")   // closes "a"
        r.player.finish(utterance: "b")
        try r.render(900)
        #expect(r.log.started == ["a", "b"])
        #expect(r.log.finished.map(\.0) == ["a", "b"])
        #expect(r.log.finished.map(\.1) == [300, 400])
        #expect(r.player.playedMs(utterance: "a") == 300)
        #expect(r.player.playedMs(utterance: "b") == 400)
    }

    @Test func levelComesFromPlayedAudioAndReturnsToZero() throws {
        var r = try ManualRig()
        r.player.enqueue(PCMTone.data(ms: 300, amplitude: 0.5), utterance: "loud")
        r.player.finish(utterance: "loud")
        try r.render(200)
        let playing = r.log.levels
        #expect(!playing.isEmpty)
        #expect(playing.allSatisfy { $0 > 0.6 })          // -9 dBFS sine ≈ 1.0 on the -50…-12 meter
        try r.render(200)
        #expect(r.log.levels.last == 0)
        r.log.clear()
        r.player.enqueue(PCMTone.data(ms: 300, amplitude: 0.01), utterance: "soft")
        r.player.finish(utterance: "soft")
        try r.render(200)
        #expect(r.log.levels.allSatisfy { $0 < 0.3 })
    }

    @Test func startedTimeIncludesOutputLatency() throws {
        var r = try ManualRig()
        r.player.outputLatency = 0.25
        r.player.enqueue(PCMTone.data(ms: 100), utterance: "a")
        r.player.finish(utterance: "a")
        try r.render(20)
        let at = r.log.all.compactMap { if case .started(_, let at) = $0 { at } else { nil } }.first
        let t = try #require(at)
        #expect(t >= 0.25 && t < 0.3)                      // manual clock (≈ 0.02 s) + 0.25
    }
}

@Suite struct TapPointTests {
    @Test func injectedAudioReachesEveryConsumerInOrder() throws {
        let graph = try AudioGraph.manual()
        let a = Mutex<[Int]>([]), b = Mutex<[Int]>([])
        graph.addMicConsumer { buf, _ in a.withLock { $0.append(Int(buf.frameLength)) } }
        let idB = graph.addMicConsumer { buf, _ in b.withLock { $0.append(Int(buf.frameLength)) } }
        for n in [480, 960, 240] { graph.inject(PCMTone.buffer([Float](repeating: 0.1, count: n), rate: 48_000)) }
        #expect(a.withLock { $0 } == [480, 960, 240])
        #expect(b.withLock { $0 } == [480, 960, 240])
        graph.removeMicConsumer(idB)
        graph.inject(PCMTone.buffer([Float](repeating: 0.1, count: 100), rate: 48_000))
        #expect(a.withLock { $0.count } == 4)
        #expect(b.withLock { $0.count } == 3)
    }

    @Test func captureIsOffUntilEnabled() throws {
        let graph = try AudioGraph.manual()
        graph.inject(PCMTone.buffer(Signal.sine(hz: 300, sampleRate: 48_000, seconds: 0.5), rate: 48_000))
        #expect(graph.capture.capturedFrames == 0)
        #expect(graph.capture.preroll().data.isEmpty)
    }

    @Test func captureConvertsTo24kPCM16() throws {
        let graph = try AudioGraph.manual()
        graph.capture.isEnabled = true
        for _ in 0..<10 {
            graph.inject(PCMTone.buffer(Signal.sine(hz: 300, amplitude: 0.5, sampleRate: 48_000, seconds: 0.1), rate: 48_000))
        }
        let frames = graph.capture.capturedFrames
        #expect(abs(Double(frames) - 24_000) < 300, "\(frames)")    // the resampler holds ~8 ms
        let pre = graph.capture.preroll(seconds: 0.5)
        #expect(pre.frames == 12_000)
        let samples = PCM16.samples(pre.data).map { Float($0) / 32768 }
        #expect(abs(Level.rmsDB(samples) - Level.rmsDB(Signal.sine(hz: 300, amplitude: 0.5, seconds: 0.5))) < 0.5)
        #expect(pre.startFrame == frames - 12_000)
    }

    @Test func openDeliversPrerollThenLiveWithoutGapOrOverlap() async throws {
        let graph = try AudioGraph.manual()
        graph.capture.isEnabled = true
        let tone = { PCMTone.buffer(Signal.sine(hz: 300, sampleRate: 48_000, seconds: 0.1), rate: 48_000) }
        for _ in 0..<30 { graph.inject(tone()) }                   // 3 s spoken before the socket is up
        let stream = graph.capture.open(preroll: 2)
        for _ in 0..<5 { graph.inject(tone()) }
        graph.capture.close()
        var chunks: [PCM16Capture.Chunk] = []
        for await c in stream { chunks.append(c) }
        let first = try #require(chunks.first)
        #expect(first.frames == 48_000)                            // the full 2 s pre-roll
        for (x, y) in zip(chunks, chunks.dropFirst()) {
            #expect(x.startFrame + Int64(x.frames) == y.startFrame) // contiguous
        }
        let total = chunks.reduce(0) { $0 + $1.frames }
        #expect(abs(total - (48_000 + 12_000)) < 300, "\(total)")
    }

    @Test func disablingCaptureEndsTheStream() async throws {
        let graph = try AudioGraph.manual()
        graph.capture.isEnabled = true
        let stream = graph.capture.open(preroll: 0)
        graph.inject(PCMTone.buffer(Signal.sine(hz: 300, sampleRate: 48_000, seconds: 0.1), rate: 48_000))
        graph.capture.isEnabled = false
        var n = 0
        for await _ in stream { n += 1 }
        #expect(n == 1)
        #expect(graph.capture.capturedFrames == 0)
    }

    @Test func renderOutsideManualModeThrows() {
        let graph = AudioGraph(configuration: .init())
        #expect(throws: (any Error).self) { _ = try graph.render(frames: 480) }
    }

    @Test func configurationReadsInjectionFromEnvironment() {
        let c = AudioGraph.Configuration.fromEnvironment(["DEE_VOICE_INJECT": "/tmp/fixtures.json", "DEE_VOICE_INJECT_AEC": "0"])
        #expect(c.injection?.path == "/tmp/fixtures.json")
        #expect(!c.injectionEchoFree)
        #expect(AudioGraph.Configuration.fromEnvironment([:]).injection == nil)
    }
}

@Suite struct ConverterEndOfStreamTests {
    /// C13: each sentence's tail used to stay in the resampler and leak into the next.
    @Test func finishDrainsTheTailAndTheNextStreamStartsClean() throws {
        let src = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
        let dst = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let conv = BufferConverter(target: dst)
        var outA: [Float] = []
        let loud = Signal.sine(hz: 500, amplitude: 0.8, sampleRate: 22_050, seconds: 0.5)
        for chunk in Signal.frames(loud, size: 2205) {
            let b = PCMTone.buffer(chunk, rate: 22_050)
            #expect(b.format == src)
            if let o = conv.convert(b) { outA += o.firstChannelSamples() }
        }
        let tail = conv.finish()
        #expect(tail != nil)
        outA += tail?.firstChannelSamples() ?? []
        let expected = Double(loud.count) * 24_000 / 22_050
        #expect(abs(Double(outA.count) - expected) <= 2, "\(outA.count) vs \(expected)")
        // Sentence B is silence: none of A may come out at its start.
        let silent = PCMTone.buffer([Float](repeating: 0, count: 2205), rate: 22_050)
        let outB = try #require(conv.convert(silent)).firstChannelSamples()
        #expect(outB.allSatisfy { abs($0) < 1e-4 }, "max \(outB.map(abs).max() ?? 0)")
    }

    @Test func finishWithoutInputIsNil() {
        let conv = BufferConverter(target: AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!)
        #expect(conv.finish() == nil)
    }

    @Test func pcm16RoundTrips() {
        let data = PCMTone.data(ms: 10)
        let s = PCM16.samples(data)
        #expect(s.count == 240)
        let f = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: 240)!
        b.frameLength = 240
        for (i, v) in s.enumerated() { b.int16ChannelData![0][i] = v }
        #expect(PCM16.data(from: b) == data)
        #expect(PCM16.int16(1.5) == 32767 && PCM16.int16(-2) == -32768 && PCM16.int16(.nan) == 0)
    }
}
