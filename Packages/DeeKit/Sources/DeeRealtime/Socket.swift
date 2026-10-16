import Foundation
import Synchronization

/// Why a socket could not open, or why it closed.
public enum SocketFailure: Error, Sendable, Equatable {
    /// HTTP 401 / 403 on the handshake: bad, revoked or wrong-project key.
    case unauthorized(status: Int)
    /// HTTP 429 on the handshake: rate limit or the project's hard spend cap.
    case rateLimited(retryAfter: Double?)
    /// HTTP 5xx on the handshake.
    case server(status: Int, retryAfter: Double?)
    /// Any other HTTP status on the handshake.
    case handshake(status: Int)
    /// No open within the timeout.
    case openTimeout
    /// No pong within the timeout: the path is dead even if TCP has not noticed.
    case pingTimeout
    /// Transport error (offline, DNS, TLS, reset, …).
    case network(String)
}

/// One thing that came off a socket.
public enum SocketEvent: Sendable, Equatable {
    case text(String)
    /// The socket is gone. `code` is the WebSocket close code (1000 normal,
    /// 1006 abnormal / none received); `failure` is set when it was not a clean close.
    case closed(code: Int, reason: String?, failure: SocketFailure?)
}

/// A text WebSocket as the session sees it.
///
/// `send` only enqueues (ordered, never blocks the caller): the session actor
/// never suspends between two related events, so nothing can slip between
/// `conversation.item.create` and its `response.create`.
public protocol RealtimeSocket: AnyObject, Sendable {
    /// Opens the connection. Throws `SocketFailure`.
    func open() async throws
    /// Incoming frames, then exactly one `.closed`. Single consumer.
    var incoming: AsyncStream<SocketEvent> { get }
    /// Queues a text frame. Dropped silently once the socket is closed.
    func send(_ text: String)
    /// Bytes queued but not yet handed to the transport (backpressure signal).
    var pendingBytes: Int { get }
    /// Closes with a WebSocket close code. Idempotent.
    func close(code: Int, reason: String?)
}

/// Makes a socket for a request (the session calls it once per connection).
public typealias RealtimeSocketFactory = @Sendable (URLRequest) -> any RealtimeSocket

