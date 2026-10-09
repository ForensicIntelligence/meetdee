import Foundation
import Synchronization
import Testing
@testable import DeeRealtime

/// Collects a session's events and lets a test wait for one.
final class EventLog: @unchecked Sendable {
    private let store = Mutex<[RealtimeEvent]>([])
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<RealtimeEvent>) {
        task = Task { [weak self] in
            for await e in stream { self?.store.withLock { $0.append(e) } }
        }
    }

    deinit { task?.cancel() }

    var all: [RealtimeEvent] { store.withLock { $0 } }

    /// Waits (polling, real time) until an event matches; returns it.
    @discardableResult
    func wait(timeout: Double = 2, _ match: (RealtimeEvent) -> Bool) async -> RealtimeEvent? {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if let e = all.first(where: match) { return e }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return nil
    }

    func count(_ match: (RealtimeEvent) -> Bool) -> Int { all.filter(match).count }

    func contains(_ match: (RealtimeEvent) -> Bool) -> Bool { all.contains(where: match) }

    func contains(_ event: RealtimeEvent) -> Bool { all.contains(event) }
}

/// Server events, briefly.
enum S {
    static func speechStarted(_ item: String, ms: Int = 100) -> ServerEvent {
        .speechStarted(.init(eventID: "ev_ss_\(item)", audioStartMs: ms, itemID: item))
    }
    static func speechStopped(_ item: String, ms: Int = 900) -> ServerEvent {
        .speechStopped(.init(eventID: "ev_sp_\(item)", audioEndMs: ms, itemID: item))
    }
    static func committed(_ item: String, previous: String? = nil) -> ServerEvent {
        .inputAudioCommitted(.init(eventID: "ev_c_\(item)", previousItemID: previous, itemID: item))
    }
    static func userTranscript(_ item: String, _ text: String) -> ServerEvent {
        .inputTranscriptionCompleted(.init(eventID: "ev_t_\(item)", itemID: item, transcript: text))
    }
    static func responseCreated(_ id: String, metadata: [String: String]? = nil) -> ServerEvent {
        .responseCreated(.init(eventID: "ev_rc_\(id)", response: ResponseObject(
            id: id, object: "realtime.response", status: "in_progress", output: [], metadata: metadata)))
    }
    static func messageAdded(_ resp: String, _ item: String) -> ServerEvent {
        .outputItemAdded(.init(eventID: "ev_oa_\(item)", responseID: resp, item: RealtimeItem(
            id: item, object: "realtime.item", type: "message", status: "in_progress", role: "assistant", content: [])))
    }
    static func functionCallAdded(_ resp: String, _ item: String, name: String) -> ServerEvent {
        .outputItemAdded(.init(eventID: "ev_fa_\(item)", responseID: resp, item: RealtimeItem(
            id: item, type: "function_call", status: "in_progress", name: name)))
    }
    /// `ms` milliseconds of silence (24 kHz PCM16 = 48 bytes/ms).
    static func audio(_ resp: String, _ item: String, ms: Int) -> ServerEvent {
        .outputAudioDelta(.init(responseID: resp, itemID: item, delta: Data(count: ms * 48).base64EncodedString()))
    }
    static func audioDone(_ resp: String, _ item: String) -> ServerEvent {
        .outputAudioDone(.init(responseID: resp, itemID: item))
    }
    static func transcript(_ resp: String, _ item: String, _ delta: String) -> ServerEvent {
        .outputAudioTranscriptDelta(.init(responseID: resp, itemID: item, delta: delta))
    }
    static func transcriptDone(_ resp: String, _ item: String, _ text: String) -> ServerEvent {
        .outputAudioTranscriptDone(.init(responseID: resp, itemID: item, text: text))
    }
    static func callDone(_ resp: String, _ item: String, call: String, name: String, args: String) -> ServerEvent {
        .functionCallArgumentsDone(.init(responseID: resp, itemID: item, callID: call, name: name, arguments: args))
    }
    static func responseDone(_ id: String, status: String = "completed", reason: String? = nil,
                             output: [RealtimeItem] = [], usage: Usage? = nil,
                             metadata: [String: String]? = nil) -> ServerEvent {
        .responseDone(.init(eventID: "ev_rd_\(id)", response: ResponseObject(
            id: id, object: "realtime.response", status: status,
            statusDetails: reason.map { ResponseStatusDetails(type: status, reason: $0, error: nil) },
            output: output, usage: usage, metadata: metadata)))
    }
    static func error(type: String = "invalid_request_error", code: String?, message: String = "x",
                      eventID: String? = nil) -> ServerEvent {
        .error(.init(eventID: "ev_err", error: APIError(type: type, code: code, message: message, eventID: eventID)))
    }
    /// A harmless event with a visible effect, to know everything before it was handled.
    static func marker(_ n: Int) -> ServerEvent {
        .rateLimitsUpdated(.init(rateLimits: [RateLimit(name: "marker\(n)", limit: n, remaining: n, resetSeconds: 0)]))
    }
}

/// A connected session on fake sockets and a manual clock.
final class Harness: Sendable {
    let session: RealtimeSession
    let factory: FakeSocketFactory
    let clock: ManualRealtimeClock
    let log: EventLog
    private let markers = Mutex(0)

    init(session: RealtimeSession, factory: FakeSocketFactory, clock: ManualRealtimeClock, log: EventLog) {
        self.session = session; self.factory = factory; self.clock = clock; self.log = log
    }

    var socket: FakeSocket { factory.made.last! }

    static func make(config: RealtimeSessionConfig = Harness.defaultConfig(),
                     sockets: [FakeSocket] = [],
                     credentials: RealtimeCredentialProvider? = nil) -> Harness {
        let factory = FakeSocketFactory(sockets) { req in
            FakeSocket(request: req, sessionID: "sess_\(Int.random(in: 1000...9999))")
        }
        let clock = ManualRealtimeClock()
        let session = RealtimeSession(
            config: config,
            credentials: credentials ?? { _ in .ephemeral("ek_test", expiresAt: Date().addingTimeInterval(600)) },
            socketFactory: factory.factory, clock: clock)
        return Harness(session: session, factory: factory, clock: clock, log: EventLog(session.events))
    }

    static func connected(config: RealtimeSessionConfig = Harness.defaultConfig(),
                          sockets: [FakeSocket] = []) async throws -> Harness {
        let h = make(config: config, sockets: sockets)
        try await h.session.connect()
        return h
    }

    static func defaultConfig() -> RealtimeSessionConfig {
        var c = RealtimeSessionConfig()
        c.instructions = "You are Dee."
        return c
    }

    func push(_ events: ServerEvent...) { events.forEach { socket.push($0) } }

    /// Returns once every event pushed so far on the live socket has been handled.
    func sync() async {
        let n = markers.withLock { $0 += 1; return $0 }
        socket.push(S.marker(n))
        let seen = await log.wait {
            if case .rateLimits(let l) = $0 { l.first?.name == "marker\(n)" } else { false }
        }
        #expect(seen != nil, "session stopped handling events")
    }

    /// Lets pending tasks register their sleeps, moves the clock, lets woken tasks run.
    func advance(by seconds: Double) async {
        await settle()
        clock.advance(by: seconds)
        await settle()
    }

    /// Lets tasks woken by the manual clock run.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(5))
    }

    func sentCount(_ type: String) -> Int { socket.sentTypes.filter { $0 == type }.count }
}

extension RealtimeEvent {
    var isAudio: Bool { if case .assistantAudio = self { true } else { false } }
    var responseDone: ResponseSummary? { if case .responseDone(let s) = self { s } else { nil } }
    var fallback: FallbackReason? { if case .fallbackAdvised(let r) = self { r } else { nil } }
}

func json(_ text: String) -> RealtimeJSON {
    guard let v = RealtimeJSON.parse(text) else {
        Issue.record("not JSON: \(text.prefix(200))")
        return .null
    }
    return v
}
