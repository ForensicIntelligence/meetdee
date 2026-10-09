import DeeRealtime
import Foundation
import Synchronization

/// Taps every socket the session opens (the session's own sockets, so it sees the
/// frames exactly as they go to and come from the server) and injects faults:
/// a dropped connection (no close frame) or a refused open (401 / 429).
///
/// Callbacks run on the socket's own tasks; the runner locks.
public final class SocketTap: @unchecked Sendable {
    public enum Event: Sendable {
        case opened(connection: Int)
        case refused(connection: Int, reason: String)
        case frame(connection: Int, outgoing: Bool, text: String)
        case closed(connection: Int, code: Int?, reason: String?, dropped: Bool)
    }

    private struct State {
        var count = 0
        var sockets: [(index: Int, socket: TappedSocket)] = []
        var failNext: SocketFailure?
    }
    private let state = Mutex(State())
    private let observe: @Sendable (Event) -> Void

    public init(observe: @escaping @Sendable (Event) -> Void) {
        self.observe = observe
    }

    /// Wraps the session's socket factory.
    public func wrap(_ base: @escaping RealtimeSocketFactory) -> RealtimeSocketFactory {
        { [self] request in
            let (n, fail) = state.withLock { s -> (Int, SocketFailure?) in
                s.count += 1
                let f = s.failNext
                s.failNext = nil
                return (s.count, f)
            }
            let socket = TappedSocket(base: base(request), index: n, failOpen: fail, observe: observe)
            state.withLock { s in
                s.sockets.removeAll { $0.socket.isClosed }
                s.sockets.append((n, socket))
            }
            return socket
        }
    }

    /// The next socket open fails with `failure` (before any network traffic).
    public func failNextOpen(_ failure: SocketFailure) {
        state.withLock { $0.failNext = failure }
    }

    /// Kills the newest open connection as a network loss would (no close frame).
    /// Returns its index, or nil when none is open.
    @discardableResult
    public func dropNewest() -> Int? {
        let s = state.withLock { s in s.sockets.last { !$0.socket.isClosed } }
        guard let s else { return nil }
        s.socket.drop()
        return s.index
    }

    public var connections: Int { state.withLock { $0.count } }
}

final class TappedSocket: RealtimeSocket, @unchecked Sendable {
    private let base: any RealtimeSocket
    let index: Int
    private let failOpen: SocketFailure?
    private let observe: @Sendable (SocketTap.Event) -> Void
    private let stream: AsyncStream<SocketEvent>
    private let continuation: AsyncStream<SocketEvent>.Continuation
    private let closed = Mutex(false)
    private let pump = Mutex<Task<Void, Never>?>(nil)

    init(base: any RealtimeSocket, index: Int, failOpen: SocketFailure?, observe: @escaping @Sendable (SocketTap.Event) -> Void) {
        self.base = base
        self.index = index
        self.failOpen = failOpen
        self.observe = observe
        (stream, continuation) = AsyncStream<SocketEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    var isClosed: Bool { closed.withLock { $0 } }

    func open() async throws {
        observe(.opened(connection: index))
        if let failOpen {
            observe(.refused(connection: index, reason: "\(failOpen) (harness)"))
            finish(code: 1006, reason: "refused by harness", failure: failOpen, dropped: true, report: false)
            throw failOpen
        }
        do {
            try await base.open()
        } catch {
            observe(.refused(connection: index, reason: "\(error)"))
            finish(code: 1006, reason: nil, failure: nil, dropped: false, report: false)
            throw error
        }
        let incoming = base.incoming
        let task = Task { [weak self] in
            for await e in incoming {
                guard let self, !self.isClosed else { return }
                switch e {
                case .text(let t):
                    self.observe(.frame(connection: self.index, outgoing: false, text: t))
                    self.continuation.yield(e)
                case .closed(let code, let reason, let failure):
                    self.finish(code: code, reason: reason, failure: failure, dropped: false, report: true, forward: e)
                    return
                }
            }
        }
        pump.withLock { $0 = task }
    }

    var incoming: AsyncStream<SocketEvent> { stream }

    func send(_ text: String) {
        guard !isClosed else { return }
        observe(.frame(connection: index, outgoing: true, text: text))
        base.send(text)
    }

    var pendingBytes: Int { base.pendingBytes }

    func close(code: Int, reason: String?) {
        base.close(code: code, reason: reason)
        finish(code: code, reason: reason, failure: nil, dropped: false, report: true)
    }

    /// Network loss: the session sees an abnormal close; the real socket is closed
    /// underneath (the server sees the client go).
    func drop() {
        finish(code: 1006, reason: "harness drop", failure: .network("connection lost (harness)"), dropped: true, report: true)
        base.close(code: 1001, reason: "harness drop")
    }

    private func finish(code: Int, reason: String?, failure: SocketFailure?, dropped: Bool, report: Bool,
                        forward: SocketEvent? = nil) {
        let first = closed.withLock { c -> Bool in defer { c = true }; return !c }
        guard first else { return }
        if report { observe(.closed(connection: index, code: code, reason: reason, dropped: dropped)) }
        continuation.yield(forward ?? .closed(code: code, reason: reason, failure: failure))
        continuation.finish()
        pump.withLock { $0 }?.cancel()
    }
}
