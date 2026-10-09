import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import DeeVoice

/// Stage-1 review H2, M1, L6, M3 on the stream player.
@Suite struct StreamPlayerReviewTests {
    @Test func flushDuringThePrebufferStillNamesTheItem() throws {
        var r = try ManualRig()
        r.player.enqueue(PCMTone.data(ms: 80), utterance: "item_x")   // < 120 ms target
        try r.render(40)
        #expect(r.log.started.isEmpty)
        let cut = try #require(r.player.flush())
        #expect(cut == PCMStreamPlayer.Cut(utterance: "item_x", playedMs: 0))
        try r.render(20)
        #expect(r.log.finished.contains { $0.0 == "item_x" && $0.1 == 0 && $0.2 })
        #expect(r.log.started.isEmpty)                        // `.finished` without `.started`
        r.player.enqueue(PCMTone.data(ms: 300), utterance: "item_x")  // in-flight delta
        try r.render(400)
        #expect(r.audibleMs() == 0)
    }

    @Test func flushNamesTheFirstUnfinishedItemNotACompletedOne() throws {
        var r = try ManualRig()
        r.player.enqueue(PCMTone.data(ms: 100), utterance: "a")
        r.player.finish(utterance: "a")
        r.player.enqueue(PCMTone.data(ms: 50), utterance: "b")       // b prebuffering
        try r.render(110)                                     // a played out; b waits for the target
        let cut = try #require(r.player.flush())
        #expect(cut.utterance == "b")
    }

    @Test func playedMsIsRoundedDownAndNeverExceedsWhatArrived() throws {
        var r = try ManualRig()
        let n = 24 * 13 - 1 + 24 * 200                        // 212.958 ms
        let s = [Int16](repeating: 1000, count: n)
        r.player.enqueue(s.withUnsafeBytes { Data($0) }, utterance: "item_r")
        try r.render(400)                                     // all rendered, item still open
        let cut = try #require(r.player.flush())
        #expect(cut.playedMs == 212)
        #expect(Double(cut.playedMs) <= Double(n) / 24)
        #expect(PCMStreamPlayer.ms(23) == 0 && PCMStreamPlayer.ms(24) == 1)
    }

    @Test func lateAudioForAFinishedItemNeverPlaysAgain() throws {
        var r = try ManualRig()
        r.player.enqueue(PCMTone.data(ms: 200), utterance: "item_a")
        r.player.finish(utterance: "item_a")
        try r.render(300)
        #expect(r.log.finished.map(\.0) == ["item_a"])
        let doneAt = r.renderedMs
        r.player.enqueue(PCMTone.data(ms: 200), utterance: "item_a")  // a straggler
        r.player.finish(utterance: "item_a")
        try r.render(300)
        #expect(r.audibleMs(from: doneAt) == 0)
        #expect(r.log.started == ["item_a"])
        #expect(r.log.finished.count == 1)
        #expect(r.player.playedMs(utterance: "item_a") == 200)
    }

    @Test func observersAllHearEveryEvent() throws {
        var r = try ManualRig()                               // `onEvent` is taken by the rig
        let a = EventLog(), b = EventLog()
        r.player.addObserver { a.append($0) }
        let idB = r.player.addObserver { b.append($0) }
        r.player.enqueue(PCMTone.data(ms: 100), utterance: "x")
        r.player.finish(utterance: "x")
        try r.render(150)
        #expect(a.started == ["x"] && b.started == ["x"] && r.log.started == ["x"])
        #expect(a.finished.count == 1 && b.finished.count == 1)
        r.player.removeObserver(idB)
        r.player.enqueue(PCMTone.data(ms: 100), utterance: "y")
        r.player.finish(utterance: "y")
        try r.render(150)
        #expect(a.started == ["x", "y"] && b.started == ["x"])
    }

    @Test func producersAndFlushesRaceTheRenderThreadSafely() async throws {
        var r = try ManualRig()
        let player = r.player
        let producer = Task.detached {
            for k in 0..<200 {
                player.enqueue(PCMTone.data(ms: 20), utterance: "item_\(k / 20)")
                if k % 20 == 19 { player.finish(utterance: "item_\(k / 20)") }
                if k % 37 == 0 { _ = player.flush() }
                _ = player.playedMs(utterance: "item_\(k / 20)")
            }
        }
        for _ in 0..<100 { try r.render(20) }
        await producer.value
        try r.render(5000)
        #expect(!player.isBusy)
        #expect(player.bufferedMs == 0)
    }
}

/// Stage-1 review M2 / M3 / L4 on the graph.
@Suite struct AudioGraphReviewTests {
    final class GraphLog: Sendable {
        let events = Mutex<[AudioGraph.Event]>([])
        func append(_ e: AudioGraph.Event) { events.withLock { $0.append(e) } }
        var all: [AudioGraph.Event] { events.withLock { $0 } }
    }

    @Test func routeChangePausesHerReplyInsteadOfEndingIt() throws {
        var r = try ManualRig()
        let log = GraphLog()
        r.graph.addObserver { log.append($0) }
        r.player.enqueue(PCMTone.data(ms: 1000), utterance: "item_a")
        try r.render(300)
        r.graph.configurationChanged()                        // AirPods in
        r.player.enqueue(PCMTone.data(ms: 500), utterance: "item_a")  // the reply keeps streaming
        r.player.finish(utterance: "item_a")
        try r.render(1400)
        #expect(log.all == [.interrupted("The audio route changed.")])
        let fin = try #require(r.log.finished.first)
        #expect(fin.0 == "item_a" && fin.1 == 1500 && !fin.2)  // all of it, not flushed
    }

    @Test func realInterruptionCutsAndSaysWhatWasHeard() throws {
        var r = try ManualRig()
        let log = GraphLog()
        r.graph.addObserver { log.append($0) }
        r.player.enqueue(PCMTone.data(ms: 1000), utterance: "item_a")
        try r.render(300)
        r.graph.interrupted("Audio was interrupted.", cutStream: true)
        try r.render(20)
        let cutEvent = log.all.compactMap { e -> (String?, Int)? in
            if case .playbackCut(let u, let ms, _) = e { (u, ms) } else { nil }
        }.first
        let cut = try #require(cutEvent)
        #expect(cut.0 == "item_a")
        #expect(abs(cut.1 - 300) <= 12, "\(cut.1)")
        #expect(r.log.finished.first.map { $0.0 == "item_a" && $0.2 } == true)
    }

    @Test func everyObserverAndTheOwnerSlotSeeEvents() throws {
        let r = try ManualRig()
        let owner = GraphLog(), a = GraphLog(), b = GraphLog()
        r.graph.onEvent = { owner.append($0) }
        r.graph.addObserver { a.append($0) }
        let id = r.graph.addObserver { b.append($0) }
        r.graph.configurationChanged()
        r.graph.removeObserver(id)
        r.graph.configurationChanged()
        #expect(owner.all.count == 2 && a.all.count == 2 && b.all.count == 1)
    }

    @Test func failedFirstBuildKeepsRetryingUntilShutdown() async throws {
        let graph = AudioGraph(configuration: .init())
        graph.testHooks.withLock {
            $0.failBuilds = 1_000
            $0.retryScale = 0.002                             // 2 s back-off → 4 ms
        }
        let log = GraphLog()
        graph.addObserver { log.append($0) }
        let facts = await graph.start(microphone: false)
        #expect(facts == nil)
        #expect(log.all.contains(.error("Audio engine failed to start: simulated")))
        var waited = 0
        while graph.testHooks.withLock({ $0.buildAttempts }) < 4 && waited < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(graph.testHooks.withLock { $0.buildAttempts } >= 4)
        // Retries are quiet: one error, not one per attempt.
        #expect(log.all.filter { if case .error = $0 { true } else { false } }.count == 1)
        graph.shutdown()
        let after = graph.testHooks.withLock { $0.buildAttempts }
        try await Task.sleep(for: .milliseconds(150))
        #expect(graph.testHooks.withLock { $0.buildAttempts } == after)
    }

    @Test func tapTimestampUsesTheInputTimeWhenSane() throws {
        let b = PCMTone.buffer([Float](repeating: 0, count: 960), rate: 48_000)   // 20 ms
        let now = ProcessInfo.processInfo.systemUptime
        let host = AVAudioTime.hostTime(forSeconds: now - 0.05)
        let t = AudioGraph.lastSampleTime(b, when: AVAudioTime(hostTime: host), arrival: now)
        #expect(abs(t - (now - 0.03)) < 0.001)
        // No host time, or nonsense: the arrival time.
        #expect(AudioGraph.lastSampleTime(b, when: AVAudioTime(sampleTime: 0, atRate: 48_000), arrival: now) == now)
        let wild = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: now + 5))
        #expect(AudioGraph.lastSampleTime(b, when: wild, arrival: now) == now)
    }
}
