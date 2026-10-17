import DeeRealtime
import DeeVoice
import Foundation
import HarnessCore
import Testing
@testable import HarnessRunner

// Calm (spec "calm" §7.3.4, harness owner): the runner keeps every CloudVoice note with
// its time; several events are spoken over one reply; an old report (no timed notes) is
// re-scored without a crash and labelled approximate.

@Suite("Calm: the runner", .serialized)
struct CalmRunnerTests {
    @Test func everyNoteIsKeptWithItsTime() {
        let tl = TurnTimeline(keep: 16)
        tl.beginTurn(.speechStopped, at: 0.4)
        tl.mark(.speakingStarted, at: 0.5)                                   // no detail: not an event
        tl.mark(.firstAudioDelta, at: 0.45, detail: "item_d")
        tl.mark(.note, at: 1.0, detail: "duck - gain=-12 via=onset")
        tl.mark(.note, at: 1.6, detail: "hold - why=sustained")
        tl.mark(.bargeIn, at: 1.6)                                           // a cut with no item
        tl.mark(.note, at: 2.1, detail: "unduck item_x (resume)")
        let turns = ScenarioRunner.timelineTurns(tl.turns())
        #expect(turns.count == 1)
        let ev = turns[0].events ?? []
        #expect(ev.map(\.text) == ["first_audio_delta: item_d", "duck - gain=-12 via=onset", "hold - why=sustained",
                                   "barge_in: -", "unduck item_x (resume)"])
        #expect(ev.map(\.t) == [0.45, 1.0, 1.6, 1.6, 2.1])
        #expect(turns[0].marks["speaking_started"] == 0.5)                  // today's marks unchanged
        #expect(turns[0].details.contains("note: duck - gain=-12 via=onset"))
        var r = RunRecord(scenario: "s", model: "m", brain: "b", started: "t")
        r.timeline = turns
        #expect(r.floorEvents?.map(\.kind) == [.duck, .hold, .cut, .unduck])
    }

    @Test func anOldReportIsReScoredApproximately() throws {
        // A 0.6.0 report on disk when there is one (tune 14 run), else a minimal old record.
        let reports = toolRoot.appendingPathComponent("Reports")
        let candidates = ["20261011-012049", "20261011-003412"].map { reports.appendingPathComponent("\($0)/report.json") }
        var runs: [RunRecord] = []
        if let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            struct Stored: Decodable { var runs: [RunRecord] }
            let d = JSONDecoder()
            d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            runs = try d.decode(Stored.self, from: Data(contentsOf: url)).runs
        } else {
            let json = #"""
            {"scenario":"old","model":"gpt-realtime-2.1-mini","brain":"realtime","started":"t","duration":20,
             "utterances":[{"index":1,"step":0,"fixture":"l01","role":"turn","text":"x","start":0.9,"onset":1,"endOfSpeech":8,"spans":[],"expect":"reply"},
                           {"index":2,"step":0,"fixture":"bc02","role":"bargeIn","text":"Mm-hm.","start":11.9,"onset":12,"endOfSpeech":12.4,"spans":[],"expect":"any"}],
             "playback":[{"itemID":"r1","started":10,"ended":18,"playedMs":8000,"flushed":false}],
             "userItems":[],"responses":[],"requests":[],"truncations":[],
             "bargeIns":[{"step":0,"baseFixture":"l01","fixture":"bc02","targetAtMs":2000,"replyItem":"r1","replyStarted":10,"onset":12,"outcome":"missed"}],
             "echoSegments":[],"deeTranscripts":{},"heardSentences":{},"history":[],
             "timeline":[{"id":1,"start":8.6,"marks":{"speech_stopped":8.6},"details":[]}],
             "voiceBargeIns":[],"errors":[],"notes":[],"uplinkSeconds":20}
            """#
            runs = [try JSONDecoder().decode(RunRecord.self, from: Data(json.utf8))]
        }
        #expect(runs.allSatisfy { $0.floorEvents == nil })
        let m = Metrics.compute(runs, pricing: .mini)
        #expect(!m.floorApproximateRuns.isEmpty)
        let gates = Gates.evaluate(m)
        let fp = try #require(gates.first { $0.id == "false_pause" })
        #expect(fp.note?.contains("approximate") == true)
        // 0.6.0 paused Dee on every continuer it went on through: ≈ 100 % false pauses.
        if m.falsePauseApplicable > 0 { #expect(Double(m.falsePauses) / Double(m.falsePauseApplicable) > 0.9) }
        #expect(gates.first { $0.id == "false_barge" }?.status == .skip)
    }

    @Test func twoEventsOverOneReplyAreSpokenAndScored() async throws {
        let manifestURL = toolRoot.appendingPathComponent("Fixtures/manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }
        let library = try FixtureLibrary(directory: toolRoot.appendingPathComponent("Fixtures"))
        guard library.manifest.utterance("ns07") != nil, library.manifest.utterance("bc04") != nil else { return }
        let factory = FakeSocketFactory([]) { FakeSocket(request: $0, sessionID: "sess_calm") }
        var options = RunnerOptions()
        options.classifySounds = false
        options.gapAfter = 0.5
        options.replyTimeout = 4
        // q02 as the ask; over Dee's 6.5 s reply a laugh (loud) at 1.0 s, "Uh-huh." at 3.0 s.
        let scenario = Scenario(name: "calm-offline", leadIn: 0.3, steps: [
            Scenario.Step(say: "q02", events: [.init(say: "ns07", atMs: 1000, nonspeech: true, gainDB: 7),
                                               .init(say: "bc04", atMs: 3000, backchannel: true)]),
        ])
        #expect(scenario.validate(against: library.manifest).isEmpty)
        let runner = ScenarioRunner(scenario: scenario, library: library,
                                    connection: .custom(credentials: { _ in .direct("sk-test-not-a-real-key-000") },
                                                        socketFactory: factory.factory),
                                    brain: MinimalBrain(), spend: SpendGuard(pricing: .mini, maxUSD: 1), options: options)
        let run = Task { await runner.run() }
        let socket = try #require(await factory.waitForSocket(count: 1, timeout: 5))
        try await Task.sleep(for: .milliseconds(700))
        socket.push(Srv.speechStarted("u1", ms: 2_400))
        try await Task.sleep(for: .milliseconds(900))
        socket.push(Srv.speechStopped("u1", ms: 3_300))
        socket.push(Srv.committed("u1"))
        #expect(await socket.waitForSent(type: "response.create", count: 1, timeout: 3))
        try await Task.sleep(for: .milliseconds(120))
        socket.push(Srv.responseCreated("r1"))
        socket.push(Srv.messageAdded("r1", "a1"))
        socket.push(Srv.audio("r1", "a1", tonePCM(seconds: 6.5, amplitude: 0.2)))
        socket.push(Srv.userTranscript("u1", "Are you awake?"))
        socket.push(Srv.audioDone("r1", "a1"))
        socket.push(Srv.transcriptDone("r1", "a1", "Yes, I'm awake, and I was just thinking about clouds."))
        socket.push(Srv.responseDone("r1"))
        let record = await run.value

        #expect(record.aborted == nil)
        let events = record.utterances.filter { $0.role == .bargeIn }
        #expect(events.map(\.fixture) == ["ns07", "bc04"])
        #expect(events.first?.nonspeech == true && events.allSatisfy { $0.backchannel == true })
        let reply = try #require(record.playback.first { $0.itemID == "a1" })
        let started = try #require(reply.started)
        // Each event's first voiced sample lands `atMs` after Dee's first audio.
        #expect(abs(events[0].onset - (started + 1.0)) < 0.05 && abs(events[1].onset - (started + 3.0)) < 0.05)
        #expect(record.bargeIns.map(\.fixture) == ["ns07", "bc04"])
        #expect(record.bargeIns.first?.nonspeech == true)
        #expect(record.bargeIns.allSatisfy { $0.outcome != .notApplicable })
        // Timed notes were kept (possibly none for a fake server): never approximate.
        #expect(record.floorEvents != nil)
        let m = Metrics.compute([record], pricing: .mini)
        #expect(m.floorApproximateRuns.isEmpty && m.falsePauseEvents == 2)
    }
}
