import DeeRealtime
import Foundation
import HarnessCore

/// Every outbound call a run makes, on the harness clock (contract X1/W2/W3). The
/// harness wraps the run's `DeeRealtime.Transport` with this before handing it to the
/// session / auth / provider, so a DORMANT stretch can be checked for zero requests,
/// sockets and mints, and a mode for hosts it must never contact. Only host, kind,
/// path and purpose are kept: never headers, bodies or queries (no keys).
public final class TransportTape: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [RunRecord.TransportCall] = []
    private var clock: () -> Double = { 0 }

    public init() {}

    /// The harness clock (set once the graph exists).
    public func setClock(_ c: @escaping () -> Double) { lock.withLock { clock = c } }

    public var records: [RunRecord.TransportCall] { lock.withLock { calls } }

    /// The outer Transport's recorder: it records each call (purpose header included)
    /// just before the purpose header is stripped and the call reaches `note`.
    private let outer = TransportRecorder()

    func note(_ kind: String, _ request: URLRequest) {
        let url = request.url
        let purpose = request.value(forHTTPHeaderField: Transport.purposeHeader)
            ?? outer.records.last(where: { $0.host == (url?.host ?? "") && $0.path == (url?.path ?? "") })?.purpose
        lock.withLock {
            calls.append(.init(t: clock(), kind: kind, host: url?.host ?? "?", path: url?.path ?? "", purpose: purpose))
        }
    }

    /// `base` with every call taped first (the base still records into its own recorder too).
    public func wrap(_ base: Transport) -> Transport {
        Transport(recorder: outer, fetch: { [self] req in
            note("http", req)
            return try await base.fetch(req)
        }, stream: { [self] req in
            note("stream", req)
            return try await base.stream(req)
        }, socketFactory: { [self] req in
            note("webSocket", req)
            return base.socketFactory(req)
        })
    }

    /// A mint (`/v1/realtime/client_secrets`): the calls W2 counts as key mints.
    public static func isMint(_ c: RunRecord.TransportCall) -> Bool { c.path.hasSuffix("/client_secrets") || c.purpose == "mint" }
}
