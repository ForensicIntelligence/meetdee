import Foundation
import Network
import Synchronization

/// Records every frame of a Realtime session as JSONL, with monotonic time:
///
///     {"t":12.034,"dir":"in","event":{"type":"input_audio_buffer.speech_started",…}}
///
/// `dir` is `in` (server → Dee) or `out` (Dee → server). Audio payloads are
/// elided by default (`"delta":""` plus `"delta_bytes":N`, or `"audio":""` plus
/// `"audio_bytes":N`), which keeps an hour of talk to a few MB; replay
/// regenerates silence of the same length so timing and sizes stay real.
/// Debug builds only: the trace holds what was said.
public final class TraceRecorder: @unchecked Sendable {
    public enum Direction: String, Codable, Sendable { case server = "in", client = "out" }

    public struct Entry: Codable, Sendable, Equatable {
        /// Seconds since the recorder started.
        public var t: Double
        public var dir: Direction
        public var event: RealtimeJSON

        public init(t: Double, dir: Direction, event: RealtimeJSON) { self.t = t; self.dir = dir; self.event = event }
        public var type: String { event["type"]?.stringValue ?? "" }
    }

    private let clock: any RealtimeClock
    private let start: Double
    private let elideAudio: Bool
    private let keepInMemory: Bool
    private let queue = DispatchQueue(label: "dee.realtime.trace")
    private let handle: FileHandle?
    private let memory = Mutex<[Entry]>([])

    /// - Parameters:
    ///   - fileURL: JSONL destination (created or truncated). nil = memory only.
    ///   - keepInMemory: also keep entries in `entries` (default: only without a file).
    public init(fileURL: URL?, clock: any RealtimeClock = SystemRealtimeClock(), elideAudio: Bool = true,
                keepInMemory: Bool? = nil) throws {
        self.clock = clock
        self.start = clock.now()
        self.elideAudio = elideAudio
        self.keepInMemory = keepInMemory ?? (fileURL == nil)
        if let fileURL {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            handle = try FileHandle(forWritingTo: fileURL)
        } else {
            handle = nil
        }
    }

    deinit { try? handle?.close() }

    /// Records one frame (called by the session for every frame in and out).
    public func record(_ dir: Direction, text: String) {
        let t = clock.now() - start
        guard var event = RealtimeJSON.parse(text) else { return }
        if elideAudio { event = Self.elide(event) }
        let entry = Entry(t: (t * 1000).rounded() / 1000, dir: dir, event: event)
        if keepInMemory { memory.withLock { $0.append(entry) } }
        guard let handle else { return }
        queue.async {
            let e = JSONEncoder()
            e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard var line = try? e.encode(entry) else { return }
            line.append(0x0A)
            try? handle.write(contentsOf: line)
        }
    }

    /// Entries recorded in memory.
    public var entries: [Entry] { memory.withLock { $0 } }

    /// Waits for queued writes to reach the file.
    public func flush() { queue.sync { try? handle?.synchronize() } }

    /// Reads a JSONL trace (blank and broken lines are skipped).
    public static func load(_ url: URL) throws -> [Entry] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(Entry.self, from: Data($0.utf8)) }
    }

    static func elide(_ event: RealtimeJSON) -> RealtimeJSON {
        guard case .object(var o) = event, let type = o["type"]?.stringValue else { return event }
        let field: String
        switch type {
        case "response.output_audio.delta": field = "delta"
        case "input_audio_buffer.append": field = "audio"
        default: return event
        }
        guard let b64 = o[field]?.stringValue else { return event }
        o[field] = ""
        o[field + "_bytes"] = .number(Double(Data(base64Encoded: b64)?.count ?? 0))
        return .object(o)
    }

    /// Undoes `elide` with silence of the recorded length.
    static func restore(_ event: RealtimeJSON) -> RealtimeJSON {
        guard case .object(var o) = event else { return event }
        for field in ["delta", "audio"] {
            if let n = o[field + "_bytes"]?.intValue {
                o[field] = .string(Data(count: n).base64EncodedString())
                o[field + "_bytes"] = nil
            }
        }
        return .object(o)
    }
}

/// A loopback WebSocket server (`NWListener`) that replays the server side of a
/// recorded trace, at recorded timing, to whatever client connects. Lets tests
/// run the real `URLSessionRealtimeSocket` + `RealtimeSession` against
/// real-shaped, real-timed traffic with no network and no cost.
///
/// Replay starts when the client sends its first `startOn` frame (default
/// `session.update`), so server reaction times are preserved. Each `in` entry is
/// sent at `(t − anchor) / speed`, where `anchor` is the recorded time of that
/// first client frame.
public final class TraceReplayServer: @unchecked Sendable {
    private let entries: [TraceRecorder.Entry]
    private let speed: Double
    private let startOn: String?
    private let queue = DispatchQueue(label: "dee.realtime.replay")

    private struct State {
        var listener: NWListener?
        var connection: NWConnection?
        var received: [String] = []
        var headers: [String: String] = [:]
        var started = false
        var sentCount = 0
    }
    private let state = Mutex(State())

    public init(entries: [TraceRecorder.Entry], speed: Double = 1, startOn: String? = "session.update") {
        self.entries = entries
        self.speed = max(speed, 0.001)
        self.startOn = startOn
    }

    /// Starts listening on 127.0.0.1 and returns the port.
    public func start() async throws -> UInt16 {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 16 << 20
        ws.setClientRequestHandler(queue) { [weak self] _, headers in
            var h: [String: String] = [:]
            for (k, v) in headers { h[k.lowercased()] = v }
            self?.state.withLock { $0.headers = h }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        state.withLock { $0.listener = listener }

        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            let once = Mutex(false)
            listener.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    if once.withLock({ let f = $0; $0 = true; return !f }) { c.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let e):
                    if once.withLock({ let f = $0; $0 = true; return !f }) { c.resume(throwing: e) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// `ws://127.0.0.1:<port>/v1/realtime?model=<model>`.
    public func url(port: UInt16, model: String = "gpt-realtime-2.1-mini") -> URL {
        URL(string: "ws://127.0.0.1:\(port)/v1/realtime?model=\(model)")!
    }

    /// Client frames received so far.
    public var received: [String] { state.withLock { $0.received } }

    /// Handshake headers of the last connection (lowercased names).
    public var requestHeaders: [String: String] { state.withLock { $0.headers } }

    /// Server entries sent so far.
    public var sentCount: Int { state.withLock { $0.sentCount } }

    /// Drops the TCP connection without a close frame (simulates network loss).
    public func dropConnection() {
        state.withLock { $0.connection }?.cancel()
    }

    public func stop() {
        let (l, c) = state.withLock { s in (s.listener, s.connection) }
        c?.cancel()
        l?.cancel()
    }

    // MARK: Internals

    private func accept(_ connection: NWConnection) {
        state.withLock { $0.connection = $0.connection ?? connection }
        connection.start(queue: queue)
        receive(on: connection)
        if startOn == nil { beginReplay(on: connection) }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let data, !data.isEmpty,
               let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               meta.opcode == .text {
                let text = String(decoding: data, as: UTF8.self)
                self.state.withLock { $0.received.append(text) }
                if let startOn = self.startOn, RealtimeJSON.parse(text)?["type"]?.stringValue == startOn {
                    self.beginReplay(on: connection)
                }
            }
            if error == nil { self.receive(on: connection) }
        }
    }

    private func beginReplay(on connection: NWConnection) {
        let first = state.withLock { s -> Bool in
            guard !s.started else { return false }
            s.started = true
            return true
        }
        guard first else { return }
        let anchor = entries.first { $0.dir == .client && $0.type == startOn }?.t
            ?? entries.first { $0.dir == .server }?.t ?? 0
        for entry in entries where entry.dir == .server {
            let delay = max(0, entry.t - anchor) / speed
            let text = TraceRecorder.restore(entry.event).jsonText
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                let meta = NWProtocolWebSocket.Metadata(opcode: .text)
                let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
                connection.send(content: Data(text.utf8), contentContext: context, isComplete: true,
                                completion: .contentProcessed { _ in })
                self?.state.withLock { $0.sentCount += 1 }
            }
        }
    }
}
