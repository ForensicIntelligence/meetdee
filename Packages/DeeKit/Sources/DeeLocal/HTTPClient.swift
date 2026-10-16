import Foundation

/// Transport-level failures, classified (no bodies, no keys).
public enum HTTPFailure: Error, Sendable, Equatable {
    case refused
    case timedOut
    case offline
    case cancelled
    case tls
    case localNetworkDenied
    case other(String)

    /// Maps a URLSession / Network error.
    public static func classify(_ error: Error) -> HTTPFailure {
        if let f = error as? HTTPFailure { return f }
        if error is CancellationError { return .cancelled }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return .timedOut
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed, NSURLErrorBadServerResponse: return .refused
            case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
                return .offline
            case NSURLErrorCancelled: return .cancelled
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorClientCertificateRejected:
                return .tls
            case NSURLErrorAppTransportSecurityRequiresSecureConnection: return .tls
            default: return .other("url \(ns.code)")
            }
        }
        if ns.domain == "NWErrorDomain" || ns.domain == "kNWErrorDomainPOSIX" {
            if ns.code == Int(ECONNREFUSED) { return .refused }
            if ns.code == Int(ETIMEDOUT) { return .timedOut }
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ECONNREFUSED) { return .refused }
        return .other("\(ns.domain) \(ns.code)")
    }
}

/// Runs `body`, throwing `HTTPFailure.timedOut` after `seconds`.
func withDeadline<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw HTTPFailure.timedOut
        }
        guard let first = try await group.next() else { throw HTTPFailure.timedOut }
        group.cancelAll()
        return first
    }
}
