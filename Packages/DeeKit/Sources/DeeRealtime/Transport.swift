import Foundation
import Synchronization

/// One HTTP request → its whole body.
public typealias HTTPFetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)
/// Kept for existing callers (`OpenAIAuth(transport:)`, tests).
public typealias HTTPTransport = HTTPFetch

/// A streamed HTTP response: the head, then the body as it arrives (SSE, NDJSON,
/// streamed PCM). Stop iterating (or cancel the iterating task) to cancel the request.
public struct HTTPStreamResponse: Sendable {
    public let response: HTTPURLResponse
    public let body: AsyncThrowingStream<Data, Error>
    public init(response: HTTPURLResponse, body: AsyncThrowingStream<Data, Error>) {
        self.response = response
        self.body = body
    }
}

/// One HTTP request → a streamed response.
public typealias HTTPStreamFetch = @Sendable (URLRequest) async throws -> HTTPStreamResponse

/// What a client does with an HTTP redirect (contract N1).
public enum RedirectPolicy: Sendable, Equatable {
    /// Never follow (every LAN client: a 30x to a public host must not carry a key or audio there).
    case refuse
    /// Follow only to the same scheme and host (OpenAI clients).
    case sameHost

    public func allows(from: URL?, to: URL?) -> Bool {
        switch self {
        case .refuse:
            return false
        case .sameHost:
            guard let from, let to, let a = from.host?.lowercased(), let b = to.host?.lowercased() else { return false }
            return a == b && from.scheme?.lowercased() == to.scheme?.lowercased()
        }
    }
}

/// One outbound connection as the recorder saw it. Never a header, a body or a
/// query string: nothing in here can hold a key or spoken words.
public struct TransportRecord: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable { case http, stream, webSocket }
    public var kind: Kind
    public var method: String
    public var scheme: String
    public var host: String
    public var port: Int?
    public var path: String
    /// The caller's label (`Transport.purposeHeader`), e.g. "mint", "clip", "chat".
    public var purpose: String?

    public init(kind: Kind, method: String, scheme: String, host: String, port: Int?, path: String, purpose: String?) {
        self.kind = kind; self.method = method; self.scheme = scheme; self.host = host
        self.port = port; self.path = path; self.purpose = purpose
    }

    init(kind: Kind, request: URLRequest) {
        let url = request.url
        self.init(kind: kind, method: kind == .webSocket ? "GET" : (request.httpMethod ?? "GET"),
                  scheme: url?.scheme?.lowercased() ?? "", host: url?.host?.lowercased() ?? "", port: url?.port,
                  path: url?.path ?? "", purpose: request.value(forHTTPHeaderField: Transport.purposeHeader))
    }

    /// `*.openai.com` (or openai.com itself).
    public var isOpenAI: Bool { host == "openai.com" || host.hasSuffix(".openai.com") }
}

/// Every connection a `Transport` was asked to make, in order (contract X1: the
/// invariants W2 / W3 are asserted on this, since `URLProtocol` cannot see
/// ephemeral sessions or WebSockets).
public final class TransportRecorder: Sendable {
    private let state = Mutex<[TransportRecord]>([])

    public init() {}

    public var records: [TransportRecord] { state.withLock { $0 } }
    public var count: Int { state.withLock { $0.count } }
    public func hosts() -> Set<String> { Set(records.map(\.host)) }
    public func clear() { state.withLock { $0.removeAll() } }

    func record(_ r: TransportRecord) { state.withLock { $0.append(r) } }
}

/// The only way Dee reaches a network (contract X1). Built per provider part by
/// `ProviderFactory`; every request, stream and WebSocket made through it is
/// recorded first. Only `Transport*.swift` creates a `URLSession`.
public struct Transport: Sendable {
    /// A request header naming why a request is made ("mint", "clip", "models", …).
    /// Recorded, then removed before the request leaves.
    public static let purposeHeader = "X-Dee-Purpose"

    public let recorder: TransportRecorder
    public let fetch: HTTPFetch
    public let stream: HTTPStreamFetch
    public let socketFactory: RealtimeSocketFactory

    /// Wraps the given calls with recording (tests, the mock server, the harness).
    /// Without `stream`, a stream is `fetch`'s whole body delivered as one chunk.
    public init(recorder: TransportRecorder = TransportRecorder(), fetch: @escaping HTTPFetch,
                stream: HTTPStreamFetch? = nil, socketFactory: @escaping RealtimeSocketFactory) {
        self.recorder = recorder
        self.fetch = { request in
            recorder.record(TransportRecord(kind: .http, request: request))
            return try await fetch(Self.stripped(request))
        }
        let streamCall: HTTPStreamFetch = stream ?? { request in
            let (data, response) = try await fetch(request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return HTTPStreamResponse(response: http, body: AsyncThrowingStream { c in
                if !data.isEmpty { c.yield(data) }
                c.finish()
            })
        }
        self.stream = { request in
            recorder.record(TransportRecord(kind: .stream, request: request))
            return try await streamCall(Self.stripped(request))
        }
        self.socketFactory = { request in
            recorder.record(TransportRecord(kind: .webSocket, request: request))
            return socketFactory(Self.stripped(request))
        }
    }

    /// The real network: one ephemeral `URLSession` (no cache, no cookies, no
    /// stored credentials) whose delegate applies `redirects`.
    public static func live(redirects: RedirectPolicy, recorder: TransportRecorder = TransportRecorder(),
                            requestTimeout: Double = 30,
                            socket: URLSessionRealtimeSocket.Options = URLSessionRealtimeSocket.Options()) -> Transport {
        let client = LiveHTTPClient(redirects: redirects, requestTimeout: requestTimeout)
        var socketOptions = socket
        socketOptions.redirects = redirects
        return Transport(recorder: recorder, fetch: { try await client.data(for: $0) },
                         stream: { try await client.stream(for: $0) },
                         socketFactory: URLSessionRealtimeSocket.factory(options: socketOptions))
    }

    /// Every request is recorded, then fails as if offline; sockets fail to open.
    /// (W1: the wake phrase must work with this.)
    public static func failing(recorder: TransportRecorder = TransportRecorder()) -> Transport {
        Transport(recorder: recorder, fetch: { _ in throw URLError(.notConnectedToInternet) },
                  stream: { _ in throw URLError(.notConnectedToInternet) },
                  socketFactory: { _ in FailingSocket() })
    }

    /// The process-wide OpenAI transport (same-host redirects) used when a caller
    /// passes none. `ProviderFactory` builds its own, recorded, per provider.
    public static let openAIDefault = Transport.live(redirects: .sameHost)

    static func stripped(_ request: URLRequest) -> URLRequest {
        guard request.value(forHTTPHeaderField: purposeHeader) != nil else { return request }
        var r = request
        r.setValue(nil, forHTTPHeaderField: purposeHeader)
        return r
    }
}

/// A socket that never opens (offline).
final class FailingSocket: RealtimeSocket, @unchecked Sendable {
    let incoming: AsyncStream<SocketEvent>
    init() { incoming = AsyncStream { $0.finish() } }
    func open() async throws { throw SocketFailure.network("offline") }
    func send(_ text: String) {}
    var pendingBytes: Int { 0 }
    func close(code: Int, reason: String?) {}
}

/// The live HTTP client behind `Transport.live`: whole bodies and streamed bodies
/// over one ephemeral session, redirects decided by the policy.
final class LiveHTTPClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let redirects: RedirectPolicy
    private var session: URLSession!

    private struct Pending {
        var head: CheckedContinuation<HTTPStreamResponse, Error>?
        var body: AsyncThrowingStream<Data, Error>.Continuation
        var stream: AsyncThrowingStream<Data, Error>
    }
    private let pending = Mutex<[Int: Pending]>([:])

    init(redirects: RedirectPolicy, requestTimeout: Double) {
        self.redirects = redirects
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    func stream(for request: URLRequest) async throws -> HTTPStreamResponse {
        let task = session.dataTask(with: request)
        let id = task.taskIdentifier
        let (stream, body) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .unbounded)
        body.onTermination = { @Sendable [weak task] reason in
            if case .cancelled = reason { task?.cancel() }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<HTTPStreamResponse, Error>) in
                pending.withLock { $0[id] = Pending(head: c, body: body, stream: stream) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(redirects.allows(from: task.originalRequest?.url, to: request.url) ? request : nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let head = pending.withLock { p -> (CheckedContinuation<HTTPStreamResponse, Error>, AsyncThrowingStream<Data, Error>)? in
            guard let entry = p[dataTask.taskIdentifier], let c = entry.head else { return nil }
            p[dataTask.taskIdentifier]?.head = nil
            return (c, entry.stream)
        }
        guard let (c, stream) = head else { completionHandler(.allow); return }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            c.resume(throwing: URLError(.badServerResponse))
            return
        }
        completionHandler(.allow)
        c.resume(returning: HTTPStreamResponse(response: http, body: stream))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let body = pending.withLock { $0[dataTask.taskIdentifier]?.body }
        body?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = pending.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let head = entry.head {
            // Never got a response (refused redirect, connection refused, timeout).
            let response = task.response as? HTTPURLResponse
            if error == nil, let response {
                head.resume(returning: HTTPStreamResponse(response: response, body: entry.stream))
            } else if let response, (300..<400).contains(response.statusCode) {
                head.resume(returning: HTTPStreamResponse(response: response, body: entry.stream))
            } else {
                head.resume(throwing: error ?? URLError(.badServerResponse))
            }
        }
        if let error { entry.body.finish(throwing: error) } else { entry.body.finish() }
    }
}
