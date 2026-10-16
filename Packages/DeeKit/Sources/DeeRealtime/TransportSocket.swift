import Foundation
import Synchronization

/// `URLSessionWebSocketTask` implementation: one URLSession per socket, an
/// ordered writer task, a reader task, and a ping/pong keepalive.
public final class URLSessionRealtimeSocket: NSObject, RealtimeSocket, URLSessionWebSocketDelegate, @unchecked Sendable {
    public struct Options: Sendable {
        /// Handshake must finish within this.
        public var openTimeout: Double = 10
        /// Ping period. Realtime idles a lot between turns; NAT and carrier
        /// middleboxes drop silent TCP flows, so keep it warm.
        public var pingInterval: Double = 15
        /// A ping not answered in this long declares the connection dead.
        public var pongTimeout: Double = 10
        /// Largest incoming frame (session.updated echoes the whole prompt).
        public var maximumMessageSize: Int = 16 << 20
        /// Redirects on the upgrade: LAN sockets refuse every one, OpenAI ones
        /// follow only to the same host (contract N1).
        public var redirects: RedirectPolicy = .sameHost
        public init() {}
    }

    private let request: URLRequest
    private let options: Options
    private let stream: AsyncStream<SocketEvent>
    private let continuation: AsyncStream<SocketEvent>.Continuation
    private let outbox: AsyncStream<String>
    private let outboxContinuation: AsyncStream<String>.Continuation

    private struct State {
        var session: URLSession?
        var task: URLSessionWebSocketTask?
        var opened = false
        var finished = false
        var openWaiter: CheckedContinuation<Void, Error>?
        var pending = 0
        var workers: [Task<Void, Never>] = []
        var lastPong = 0.0
    }
    private let state = Mutex(State())

    public init(request: URLRequest, options: Options = Options()) {
        self.request = request
        self.options = options
        (stream, continuation) = AsyncStream<SocketEvent>.makeStream(bufferingPolicy: .unbounded)
        (outbox, outboxContinuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        super.init()
    }

    /// A factory for `RealtimeSession`.
    public static func factory(options: Options = Options()) -> RealtimeSocketFactory {
        { request in URLSessionRealtimeSocket(request: request, options: options) }
    }

    public var incoming: AsyncStream<SocketEvent> { stream }

    public var pendingBytes: Int { state.withLock { $0.pending } }

    public func open() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = options.openTimeout
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = options.maximumMessageSize
        state.withLock { $0.session = session; $0.task = task }

        let timeout = Task { [weak self, options] in
            try? await Task.sleep(for: .seconds(options.openTimeout))
            self?.failOpen(.openTimeout)
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let finished = state.withLock { s -> Bool in
                    if s.finished { return true }
                    s.openWaiter = c
                    return false
                }
                if finished { c.resume(throwing: SocketFailure.network("closed before open")); return }
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.failOpen(.network("cancelled"))
        }
        startWorkers(task)
    }

    public func send(_ text: String) {
        let accepted = state.withLock { s -> Bool in
            guard !s.finished else { return false }
            s.pending += text.utf8.count
            return true
        }
        if accepted { outboxContinuation.yield(text) }
    }

    public func close(code: Int, reason: String?) {
        let task = state.withLock { $0.task }
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task?.cancel(with: closeCode, reason: reason.map { Data($0.utf8) })
        finish(code: code, reason: reason, failure: nil)
    }

    // MARK: Workers

    private func startWorkers(_ task: URLSessionWebSocketTask) {
        let writer = Task { [weak self, outbox] in
            for await text in outbox {
                guard let self else { return }
                do {
                    try await task.send(.string(text))
                    self.state.withLock { $0.pending -= text.utf8.count }
                } catch {
                    self.finish(code: 1006, reason: nil, failure: .network(error.localizedDescription))
                    return
                }
            }
        }
        let reader = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let s): self?.continuation.yield(.text(s))
                    case .data(let d): self?.continuation.yield(.text(String(decoding: d, as: UTF8.self)))
                    @unknown default: break
                    }
                } catch {
                    guard let self else { return }
                    let code = task.closeCode == .invalid ? 1006 : task.closeCode.rawValue
                    let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) }
                    let failure: SocketFailure? = code == 1000 ? nil : .network(error.localizedDescription)
                    self.finish(code: code, reason: reason, failure: failure)
                    return
                }
            }
        }
        let pinger = Task { [weak self, options] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(options.pingInterval))
                guard !Task.isCancelled, let self else { return }
                let sentAt = ProcessInfo.processInfo.systemUptime
                task.sendPing { [weak self] error in
                    guard let self else { return }
                    if error == nil { self.state.withLock { $0.lastPong = ProcessInfo.processInfo.systemUptime } }
                }
                try? await Task.sleep(for: .seconds(options.pongTimeout))
                guard !Task.isCancelled else { return }
                let answered = self.state.withLock { $0.lastPong >= sentAt }
                if !answered {
                    task.cancel(with: .goingAway, reason: nil)
                    self.finish(code: 1006, reason: "ping timeout", failure: .pingTimeout)
                    return
                }
            }
        }
        state.withLock { $0.workers = [writer, reader, pinger] }
    }

    private func failOpen(_ failure: SocketFailure) {
        let waiter = state.withLock { s -> CheckedContinuation<Void, Error>? in
            defer { s.openWaiter = nil }
            return s.openWaiter
        }
        guard let waiter else { return }
        state.withLock { $0.task }?.cancel()
        finish(code: 1006, reason: nil, failure: failure, notifyStream: false)
        waiter.resume(throwing: failure)
    }

    /// Ends the socket once: wakes an open waiter, emits `.closed`, stops workers.
    private func finish(code: Int, reason: String?, failure: SocketFailure?, notifyStream: Bool = true) {
        let (wasFinished, wasOpened, waiter, workers, session) = state.withLock { s in
            let r = (s.finished, s.opened, s.openWaiter, s.workers, s.session)
            s.finished = true
            s.openWaiter = nil
            s.workers = []
            s.pending = 0
            return r
        }
        guard !wasFinished else { return }
        waiter?.resume(throwing: failure ?? SocketFailure.network("closed"))
        outboxContinuation.finish()
        workers.forEach { $0.cancel() }
        session?.invalidateAndCancel()   // breaks the URLSession → delegate retain cycle
        if notifyStream, wasOpened {
            continuation.yield(.closed(code: code, reason: reason, failure: failure))
        }
        continuation.finish()
    }

    // MARK: URLSessionWebSocketDelegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {
        let waiter = state.withLock { s -> CheckedContinuation<Void, Error>? in
            s.opened = true
            s.lastPong = ProcessInfo.processInfo.systemUptime
            defer { s.openWaiter = nil }
            return s.openWaiter
        }
        waiter?.resume()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let text = reason.map { String(decoding: $0, as: UTF8.self) }
        let code = closeCode == .invalid ? 1006 : closeCode.rawValue
        finish(code: code, reason: text, failure: code == 1000 ? nil : .network("closed by server (\(code))"))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(options.redirects.allows(from: task.originalRequest?.url, to: request.url) ? request : nil)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let opened = state.withLock { $0.opened }
        if !opened {
            failOpen(Self.handshakeFailure(response: task.response as? HTTPURLResponse, error: error))
            return
        }
        finish(code: 1006, reason: nil, failure: .network(error?.localizedDescription ?? "completed"))
    }

    /// Maps a failed WebSocket upgrade to a `SocketFailure`.
    static func handshakeFailure(response: HTTPURLResponse?, error: Error?) -> SocketFailure {
        guard let response else { return .network(error?.localizedDescription ?? "handshake failed") }
        let retryAfter = (response.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
        switch response.statusCode {
        case 401, 403: return .unauthorized(status: response.statusCode)
        case 429: return .rateLimited(retryAfter: retryAfter)
        case 500...599: return .server(status: response.statusCode, retryAfter: retryAfter)
        default: return .handshake(status: response.statusCode)
        }
    }
}
