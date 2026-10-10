import DeeBrain
import DeeMemory
import DeeMind
import DeeRealtime
import DeeSelf
import DeeVoice
import Foundation
import HarnessCore
import Testing
@testable import HarnessRunner

@Suite("Socket tap, real brain, faults (offline)", .serialized)
struct TuneRunnerTests {
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [SocketTap.Event] = []
        func add(_ e: SocketTap.Event) { lock.lock(); list.append(e); lock.unlock() }
        var all: [SocketTap.Event] { lock.lock(); defer { lock.unlock() }; return list }
    }

    @Test func theTapSeesFramesAndInjectsDropsAndRefusals() async throws {
        let events = Events()
        let tap = SocketTap { events.add($0) }
        let fake = FakeSocketFactory([]) { FakeSocket(request: $0, sessionID: "sess_tap") }
        let factory = tap.wrap(fake.factory)
        let request = URLRequest(url: URL(string: "wss://example.invalid/v1/realtime")!)

        let s1 = factory(request)
        try await s1.open()
        s1.send(#"{"type":"session.update"}"#)
        var it = s1.incoming.makeAsyncIterator()
        // FakeSocket's auto handshake answers with session.created.
        if case .text(let t)? = await it.next() { #expect(t.contains("session.created")) } else { Issue.record("no frame") }
        try await Task.sleep(for: .milliseconds(50))          // let session.updated through too
        #expect(tap.dropNewest() == 1)
        var close: SocketEvent?
        while let e = await it.next() { if case .closed = e { close = e } }   // then the stream ends
        if case .closed(let code, _, let failure)? = close {
            #expect(code == 1006 && failure != nil)
        } else { Issue.record("no close after the drop") }
        #expect(fake.made.first?.closedByClient != nil)        // the real socket was closed underneath

        tap.failNextOpen(.unauthorized(status: 401))
        let s2 = factory(request)
        await #expect(throws: SocketFailure.unauthorized(status: 401)) { try await s2.open() }
        #expect(fake.made.count == 2)                           // made, never opened
        let s3 = factory(request)
        try await s3.open()                                     // only the next open fails

        let all = events.all
        #expect(all.contains { if case .frame(1, true, let t) = $0 { t.contains("session.update") } else { false } })
        #expect(all.contains { if case .closed(1, 1006, _, true) = $0 { true } else { false } })
        #expect(all.contains { if case .refused(2, let r) = $0 { r.contains("401") } else { false } })
        #expect(all.contains { if case .opened(3) = $0 { true } else { false } })
        #expect(tap.connections == 3)
    }

    @Test func theRealBrainAnswersWithADNAAndTheWireBuildsTheRecord() async throws {
        guard FileManager.default.fileExists(atPath: toolRoot.appendingPathComponent("Fixtures/manifest.json").path) else { return }
        let library = try FixtureLibrary(directory: toolRoot.appendingPathComponent("Fixtures"))
        let factory = FakeSocketFactory([]) { FakeSocket(request: $0, sessionID: "sess_brain_\(Int.random(in: 100...999))") }
        var options = RunnerOptions()
        options.classifySounds = false
        options.gapAfter = 0.5
        options.replyTimeout = 4
        let scenario = Scenario(name: "offline-brain", noise: .init(bed: "fan", snrDb: 20), leadIn: 0.3,
                                steps: [.init(say: "q02"), .init(fault: .init(kind: .drop)), .init(silence: 1.5)],
                                family: "dna", state: "Calm.")
        let stateRoot = FileManager.default.temporaryDirectory.appendingPathComponent("vh-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stateRoot) }
        let brain = try BrainRegistry.make("realtime", scenario: scenario, stateRoot: stateRoot)
        #expect(brain.ownsBrainEvents)
        let runner = ScenarioRunner(scenario: scenario, library: library,
                                    connection: .custom(credentials: { _ in .direct("sk-test-not-a-real-key-000") },
                                                        socketFactory: factory.factory),
                                    brain: brain, spend: SpendGuard(pricing: .mini, maxUSD: 1), options: options)
        let run = Task { await runner.run() }
        let socket = try #require(await factory.waitForSocket(count: 1, timeout: 5))
        // The session is configured with Dee's stable instructions and tools.
        #expect(await socket.waitForSent(timeout: 3) { $0.contains { $0.contains("session.update") && $0.contains("HOW YOU KNOW YOURSELF") } })
        try await Task.sleep(for: .milliseconds(700))
        socket.push(Srv.speechStarted("u1", ms: 2_400))
        try await Task.sleep(for: .milliseconds(900))
        socket.push(Srv.speechStopped("u1", ms: 3_300))
        socket.push(Srv.committed("u1"))
        socket.push(Srv.userTranscript("u1", "Are you awake?"))
        #expect(await socket.waitForSent(type: "response.create", count: 1, timeout: 4))
        // DNA first, then the request (DNAWire: create → delete previous → response.create).
        let sent = socket.sent
        let dnaAt = try #require(sent.firstIndex { $0.contains("conversation.item.create") && $0.contains("DEE DNA") })
        let createAt = try #require(sent.firstIndex { $0.contains("\"response.create\"") })
        #expect(dnaAt < createAt)
        let token = try #require(sent[createAt].range(of: #""dee_turn":"(\d+)""#, options: .regularExpression)
            .map { String(sent[createAt][$0]).filter(\.isNumber) })
        try await Task.sleep(for: .milliseconds(100))
        socket.push(json: #"{"type":"response.created","response":{"id":"r1","object":"realtime.response","status":"in_progress","output":[],"metadata":{"dee_turn":"\#(token)"}}}"#)
        socket.push(Srv.messageAdded("r1", "a1"))
        socket.push(Srv.audio("r1", "a1", tonePCM(seconds: 0.6)))
        socket.push(Srv.audioDone("r1", "a1"))
        socket.push(Srv.transcriptDone("r1", "a1", "Wide awake. Are you?"))
        socket.push(Srv.responseDone("r1"))
        // The drop step: a new socket must open (the session reconnects).
        let second = try #require(await factory.waitForSocket(count: 2, timeout: 12))
        _ = second
        let record = await run.value

        #expect(record.aborted == nil, "\(record.errors.map(\.text))")
        #expect(record.brain == "realtime" && record.family == "dna" && record.state == "Calm.")
        #expect(record.userItems.map(\.itemID) == ["u1"] && record.userItems[0].transcript == "Are you awake?")
        let r = try #require(record.responses.first { $0.responseID == "r1" })
        #expect(r.kind == "reply" && r.itemIDs == ["a1"] && r.status == "completed")
        #expect(record.deeTranscripts["a1"] == "Wide awake. Are you?")
        #expect(record.heardSentences["a1"]?.isEmpty == false)
        #expect((record.brainTrace ?? []).contains { $0.text.hasPrefix("committed") })
        let creates = record.responseCreates ?? []
        #expect(creates.first?.liveDNA == true && creates.first?.freshDNA == true)
        #expect((record.connections ?? []).count >= 2 && record.connections?.first?.dropped == true)
        // The close at tear-down is not an error (live smoke 20261009-133527 listed one).
        #expect(!record.errors.contains { $0.text.contains("disconnected (connection 2)") }, "\(record.errors.map(\.text))")
        let fault = try #require(record.faults?.first)
        #expect(fault.kind == .drop && (fault.recovery ?? 99) < 10)

        let m = Metrics.compute([record], pricing: .mini)
        #expect(m.dropped == 0 && m.latencyMain.count == 1)
        let gates = Gates.evaluate(m)
        #expect(gates.first { $0.id == "dna" }?.status == .pass)
        #expect(gates.first { $0.id == "fallback" }?.status == .pass, "\(gates.first { $0.id == "fallback" }!.value)")
        // The state lived in the temp dir.
        let dir = stateRoot.appendingPathComponent("offline-brain")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mind.sqlite").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("memory.sqlite").path))
    }

    @Test func theSimulatedClockMovesTheBrainsDay() async throws {
        let scenario = Scenario(name: "clock", steps: [])
        let stateRoot = FileManager.default.temporaryDirectory.appendingPathComponent("vh-clock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stateRoot) }
        let adapter = try #require(try BrainRegistry.make("realtime", scenario: scenario, stateRoot: stateRoot) as? RealtimeBrainAdapter)
        let before = adapter.clock.now()
        // No voice attached: host steps report that there is no host.
        #expect(await adapter.perform(.init(advanceHours: 20)) == "no host")
        adapter.clock.advance(20 * 3600)
        #expect(adapter.clock.now().timeIntervalSince(before) > 20 * 3600 - 1)
        #expect(await MinimalBrain().perform(.init(leave: true)).hasPrefix("ignored"))
    }

    @Test @MainActor func aStrangerWhoGivesTheirNameIsKnownFromThenOn() async throws {
        // Live smoke 20261009-133816: "Hi Dee, my name is Priya." then, after a reconnect,
        // "I should learn your name too — what's it?" and recall found nothing. The app's
        // people layer (People.heard) names the stranger; the harness host had none.
        let memory = try MemoryStore(databaseURL: nil)
        let host = try await HarnessHost(mind: try Mind(databaseURL: nil), memory: memory, selfStore: try SelfStore(url: nil),
                                         person: nil, clock: HarnessClock())
        var seen: [UUID?] = []
        host.onPerson = { seen.append($0) }
        let verdict = await host.heard(HeardTurn(source: .voice(itemID: "u1"), text: "Hi Dee, my name is Priya."))
        guard case .answer = verdict else { Issue.record("not answered: \(verdict)"); return }
        let id = try #require(host.person)
        #expect(await memory.person(id)?.name == "Priya")
        #expect(seen.count == 2 && seen.last == id)              // placeholder first, then the named person
        let parts = try #require(await host.dnaParts(DNARequest(turn: TurnContext(kind: .reply, index: 1, mode: .fast))))
        #expect(parts.extraNotes == ["Their name is Priya. You will remember it."])
        // The note is given once.
        let again = try #require(await host.dnaParts(DNARequest(turn: TurnContext(kind: .reply, index: 2, mode: .fast))))
        #expect(again.extraNotes.isEmpty)
    }

    /// Tune-2 character finding: the harness sent `.identified(person, distance: 0.6)` once,
    /// which the Interpreter reads as one unconfirmed sighting, so the Cortex had no person
    /// all scenario (no reunion, follow-ups, rituals). The app sends a confirmed 0.
    @Test @MainActor func aKnownPersonIsIdentifiedLikeTheAppDoes() async throws {
        let id = PersonID()
        let host = try await HarnessHost(mind: try Mind(databaseURL: nil), memory: try MemoryStore(databaseURL: nil),
                                         selfStore: try SelfStore(url: nil), person: id, clock: HarnessClock())
        #expect(HarnessHost.confirmedDistance == 0)
        #expect(host.cortex.moment.ongoing.person == id)
        host.arrive()
        #expect(host.cortex.moment.ongoing.person == id)
    }
}
