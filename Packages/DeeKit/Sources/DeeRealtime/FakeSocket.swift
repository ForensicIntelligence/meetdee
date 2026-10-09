import Foundation
import Synchronization

/// In-memory `RealtimeSocket` for tests (here and in the app's packages).
///
/// The test plays the server: `push` delivers server events, `sent` records
/// every client frame. With `autoHandshake` it answers the first
/// `session.update` with `session.created` + `session.updated` the way the real
/// server does, so a session connects without a script.
public final class FakeSocket: RealtimeSocket, @unchecked Sendable {
    public let request: URLRequest?
    private let stream: AsyncStream<SocketEvent>
    private let continuation: AsyncStream<SocketEvent>.Continuation

    private struct State {
        var sent: [String] = []
        var closed: (code: Int, reason: String?)?
        var finished = false
        var opened = false
        var pending = 0
        var handshakes = 0
        var waiters: [(id: UUID, predicate: @Sendable ([String]) -> Bool, continuation: CheckedContinuation<Bool, Never>)] = []
    }
    private let state = Mutex(State())

    /// Failure `open()` throws (nil = it opens).
    public let openFailure: SocketFailure?
    public let autoHandshake: Bool
    /// The `session.id` the auto-handshake reports.
    public let sessionID: String

    public init(request: URLRequest? = nil, autoHandshake: Bool = true, openFailure: SocketFailure? = nil,
                sessionID: String = "sess_fake") {
        self.request = request
        self.autoHandshake = autoHandshake
        self.openFailure = openFailure
        self.sessionID = sessionID
        (stream, continuation) = AsyncStream<SocketEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: RealtimeSocket

    public var incoming: AsyncStream<SocketEvent> { stream }

    public func open() async throws {
        if let openFailure { throw openFailure }
        state.withLock { $0.opened = true }
    }

    public func send(_ text: String) {
        let (accepted, waiters, sent) = state.withLock { s -> (Bool, [CheckedContinuation<Bool, Never>], [String]) in
            guard !s.finished else { return (false, [], []) }
            s.sent.append(text)
            var ready: [CheckedContinuation<Bool, Never>] = []
            s.waiters.removeAll { w in
                if w.predicate(s.sent) { ready.append(w.continuation); return true }
                return false
            }
            return (true, ready, s.sent)
        }
        guard accepted else { return }
        waiters.forEach { $0.resume(returning: true) }
        if autoHandshake, Self.type(of: text) == "session.update" {
            let first = state.withLock { s -> Bool in s.handshakes += 1; return s.handshakes == 1 }
            let session = RealtimeJSON.parse(text)?["session"] ?? .object([:])
            var echoed: [String: RealtimeJSON] = ["id": .string(sessionID), "object": "realtime.session"]
            if case .object(let o) = session { echoed.merge(o) { a, _ in a } }
            if first {
                push(.sessionCreated(.init(eventID: "event_created", session: SessionInfo(raw: .object(echoed)))))
            }
            push(.sessionUpdated(.init(eventID: "event_updated_\(sent.count)", session: SessionInfo(raw: .object(echoed)))))
        }
    }

    public var pendingBytes: Int {
        get { state.withLock { $0.pending } }
    }

    /// Simulates a congested uplink.
    public func setPendingBytes(_ n: Int) { state.withLock { $0.pending = n } }

    public func close(code: Int, reason: String?) {
        let first = state.withLock { s -> Bool in
            guard s.closed == nil else { return false }
            s.closed = (code, reason)
            return true
        }
        if first { end(code: code, reason: reason, failure: nil) }
    }

    // MARK: Test controls

    /// Delivers a server event.
    public func push(_ event: ServerEvent) {
        // Encoding a value this module built cannot fail.
        push(json: (try? event.jsonText()) ?? "{}")
    }

    /// Delivers a raw server frame.
    public func push(json: String) {
        guard !state.withLock({ $0.finished }) else { return }
        continuation.yield(.text(json))
    }

    /// Simulates the network dropping the connection.
    public func drop(code: Int = 1006, failure: SocketFailure = .network("connection lost")) {
        end(code: code, reason: nil, failure: failure)
    }

    /// Every client frame sent so far.
    public var sent: [String] { state.withLock { $0.sent } }

    /// The `type` of every client frame sent so far.
    public var sentTypes: [String] { sent.map { Self.type(of: $0) } }

    /// Sent frames decoded as `ClientEvent` (frames that do not decode are skipped).
    public var sentEvents: [ClientEvent] { sent.compactMap { try? Wire.decode(ClientEvent.self, $0) } }

    /// Sent frames of one type, decoded.
    public func sent(type: String) -> [ClientEvent] { sentEvents.filter { $0.type == type } }

    /// The close the client requested, if any.
    public var closedByClient: (code: Int, reason: String?)? { state.withLock { $0.closed } }

    public var isOpen: Bool { state.withLock { $0.opened && !$0.finished } }

    /// Waits until `count` frames of `type` have been sent (or `timeout` seconds pass).
    @discardableResult
    public func waitForSent(type: String, count: Int = 1, timeout: Double = 2) async -> Bool {
        await waitForSent(timeout: timeout) { frames in frames.filter { Self.type(of: $0) == type }.count >= count }
    }

    /// Waits until the sent frames satisfy `predicate` (or `timeout` seconds pass).
    @discardableResult
    public func waitForSent(timeout: Double = 2, _ predicate: @escaping @Sendable ([String]) -> Bool) async -> Bool {
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self else { return }
            let w = self.state.withLock { s -> CheckedContinuation<Bool, Never>? in
                guard let i = s.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return s.waiters.remove(at: i).continuation
            }
            w?.resume(returning: false)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { c in
            let done = state.withLock { s -> Bool in
                if predicate(s.sent) { return true }
                s.waiters.append((id, predicate, c))
                return false
            }
            if done { c.resume(returning: true) }
        }
    }

    // MARK: Internals

    private func end(code: Int, reason: String?, failure: SocketFailure?) {
        let first = state.withLock { s -> Bool in
            guard !s.finished else { return false }
            s.finished = true
            return true
        }
        guard first else { return }
        continuation.yield(.closed(code: code, reason: reason, failure: failure))
        continuation.finish()
    }

    static func type(of text: String) -> String {
        RealtimeJSON.parse(text)?["type"]?.stringValue ?? ""
    }
}

/// Hands out `FakeSocket`s in order (one per connection) and records requests.
public final class FakeSocketFactory: @unchecked Sendable {
    private let state = Mutex<(queue: [FakeSocket], made: [FakeSocket], requests: [URLRequest])>(([], [], []))
    private let makeDefault: @Sendable (URLRequest) -> FakeSocket

    /// `sockets` are used first, in order; after that `makeDefault` builds new ones.
    public init(_ sockets: [FakeSocket] = [],
                makeDefault: @escaping @Sendable (URLRequest) -> FakeSocket = { FakeSocket(request: $0) }) {
        self.makeDefault = makeDefault
        state.withLock { $0.queue = sockets }
    }

    public var factory: RealtimeSocketFactory {
        { [self] request in
            let s = state.withLock { st -> FakeSocket? in
                st.requests.append(request)
                return st.queue.isEmpty ? nil : st.queue.removeFirst()
            } ?? makeDefault(request)
            state.withLock { $0.made.append(s) }
            return s
        }
    }

    /// Every socket handed out so far, oldest first.
    public var made: [FakeSocket] { state.withLock { $0.made } }
    public var requests: [URLRequest] { state.withLock { $0.requests } }

    /// Waits until at least `count` sockets were made.
    public func waitForSocket(count: Int, timeout: Double = 2) async -> FakeSocket? {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            let m = made
            if m.count >= count { return m[count - 1] }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }
}
