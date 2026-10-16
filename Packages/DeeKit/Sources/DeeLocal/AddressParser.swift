import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// How a host name or literal is treated by the plain-http rule (contract N1).
public enum HostClass: Sendable, Equatable {
    /// An IP literal in a private/loopback/link-local/CGNAT/ULA range.
    case privateIP
    /// Any other IP literal.
    case publicIP
    /// `*.local` (mDNS) or a single-label name: ATS NSAllowsLocalNetworking covers it.
    case localName
    /// `*.home.arpa`, `*.lan`, `*.internal`: plain http only if every resolved address is private,
    /// and then the request goes to the IP literal.
    case needsResolve
    /// A public DNS name (https/wss only).
    case publicName

    public var plainHTTPAllowed: Bool { self == .privateIP || self == .localName }
}

public enum AddressError: Error, Sendable, Equatable {
    case empty
    case invalid(String)
    case unsupportedScheme(String)
    /// `user:pass@host` (would land in UserDefaults/logs).
    case userinfo
    case query
    case fragment
    /// Plain http to a public host.
    case publicHTTP(host: String)

    public var issue: ProviderIssue {
        switch self {
        case .empty: .noLANServer
        case .invalid(let t): .invalidAddress(t)
        case .unsupportedScheme(let t): .invalidAddress(t)
        case .userinfo, .query, .fragment: .invalidAddress("that address")
        case .publicHTTP(let host): .publicHTTP(host: host)
        }
    }
}

/// Parses what the user typed into a server base URL and enforces N1.
public enum AddressParser {
    /// "192.168.1.20:11434" → `http://192.168.1.20:11434`; "https://ai.example.com/v1" → `https://ai.example.com`.
    /// A bare public name gets https. Throws for userinfo, query, fragment, unknown schemes and plain http to a
    /// public host. Names that need resolving (`.lan`, `.home.arpa`, `.internal`) pass here and are checked
    /// again per request by `NetworkPolicy.resolve`.
    public static func parse(_ text: String) throws(AddressError) -> URL {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw .empty }
        let hadScheme = t.range(of: "://") != nil
        if !hadScheme { t = "http://" + t }
        guard var c = URLComponents(string: t) else { throw .invalid(text) }
        let scheme = (c.scheme ?? "").lowercased()
        switch scheme {
        case "http", "https": break
        case "ws": c.scheme = "http"
        case "wss": c.scheme = "https"
        default: throw .unsupportedScheme(scheme)
        }
        if c.user != nil || c.password != nil || t.contains("@") { throw .userinfo }
        if c.query != nil || t.contains("?") { throw .query }
        if c.fragment != nil || t.contains("#") { throw .fragment }
        guard let host = c.host, !host.isEmpty else { throw .invalid(text) }
        if host.contains(" ") { throw .invalid(text) }
        let cls = classify(host: host)
        if !hadScheme, cls == .publicName || cls == .publicIP { c.scheme = "https" }
        // Path: keep a prefix, drop trailing "/" and "/v1".
        var path = c.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/v1") { path.removeLast(3) }
        while path.hasSuffix("/") { path.removeLast() }
        c.path = path
        c.host = host.lowercased() == host ? host : host.lowercased()
        guard let url = c.url else { throw .invalid(text) }
        return try validateBase(url)
    }

    /// Re-checks a stored base URL (configs are user data too).
    @discardableResult
    public static func validateBase(_ url: URL) throws(AddressError) -> URL {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = c.host, !host.isEmpty else {
            throw .invalid(url.absoluteString)
        }
        if c.user != nil || c.password != nil { throw .userinfo }
        if c.query != nil { throw .query }
        if c.fragment != nil { throw .fragment }
        let scheme = (c.scheme ?? "").lowercased()
        guard ["http", "https", "ws", "wss"].contains(scheme) else { throw .unsupportedScheme(scheme) }
        if !isTLS(url) {
            let cls = classify(host: host)
            if cls == .publicIP || cls == .publicName { throw .publicHTTP(host: hostLabel(url)) }
        }
        return url
    }

    public static func isTLS(_ url: URL) -> Bool {
        let s = (url.scheme ?? "").lowercased()
        return s == "https" || s == "wss"
    }

    /// Plain http/ws to this URL needs no resolving to be allowed.
    public static func allowsPlainHTTP(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return classify(host: host).plainHTTPAllowed
    }

    /// "host:port" (IPv6 in brackets) for messages; never userinfo or path.
    public static func hostLabel(_ url: URL) -> String {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = c.host else {
            return url.absoluteString
        }
        let h = host.contains(":") ? "[\(host)]" : host
        return c.port.map { "\(h):\($0)" } ?? h
    }

    /// Classifies by IP literal (`inet_pton`) first, then by name suffix.
    public static func classify(host raw: String) -> HostClass {
        var host = raw.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }   // IPv6 zone id
        if let v4 = ipv4(host) { return isPrivate(v4: v4) ? .privateIP : .publicIP }
        if let v6 = ipv6(host) { return isPrivate(v6: v6) ? .privateIP : .publicIP }
        while host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty { return .publicName }
        if host == "localhost" || host.hasSuffix(".localhost") { return .localName }
        if !host.contains(".") { return .localName }
        if host.hasSuffix(".local") { return .localName }
        if host.hasSuffix(".home.arpa") || host.hasSuffix(".lan") || host.hasSuffix(".internal") { return .needsResolve }
        return .publicName
    }

    static func ipv4(_ s: String) -> [UInt8]? {
        var a = in_addr()
        guard s.withCString({ inet_pton(AF_INET, $0, &a) }) == 1 else { return nil }
        let v = UInt32(bigEndian: a.s_addr)
        return [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }

    static func ipv6(_ s: String) -> [UInt8]? {
        var a = in6_addr()
        guard s.withCString({ inet_pton(AF_INET6, $0, &a) }) == 1 else { return nil }
        return withUnsafeBytes(of: &a) { Array($0) }
    }

    static func isPrivate(v4 b: [UInt8]) -> Bool {
        switch (b[0], b[1]) {
        case (10, _): return true
        case (172, 16...31): return true
        case (192, 168): return true
        case (127, _): return true
        case (169, 254): return true
        case (100, 64...127): return true
        default: return false
        }
    }

    static func isPrivate(v6 b: [UInt8]) -> Bool {
        if b[0] & 0xfe == 0xfc { return true }                       // fc00::/7
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return true }       // fe80::/10
        if b.dropLast().allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }   // ::1
        // IPv4-mapped ::ffff:a.b.c.d
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
            return isPrivate(v4: Array(b[12..<16]))
        }
        return false
    }
}

/// Resolves names to IP literals (for the `.lan` / `.home.arpa` / `.internal` rule).
public protocol HostResolver: Sendable {
    func addresses(of host: String) async -> [String]
}

/// `getaddrinfo` (no sockets opened; DNS only).
public struct SystemResolver: HostResolver {
    public init() {}
    public func addresses(of host: String) async -> [String] {
        await Task.detached {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return [String]() }
            defer { freeaddrinfo(first) }
            var out: [String] = []
            var p: UnsafeMutablePointer<addrinfo>? = first
            while let ai = p {
                var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let s = String(cString: buf)
                    if !out.contains(s) { out.append(s) }
                }
                p = ai.pointee.ai_next
            }
            return out
        }.value
    }
}

/// A fixed table (tests).
public struct StaticResolver: HostResolver {
    public var table: [String: [String]]
    public init(_ table: [String: [String]]) { self.table = table }
    public func addresses(of host: String) async -> [String] { table[host.lowercased()] ?? [] }
}

/// Per-request N1 enforcement.
public enum NetworkPolicy {
    /// The URL to actually request. https/wss: unchanged (TLS vouches for the name). Plain http/ws: allowed for
    /// private IP literals and local names; a `needsResolve` name only if every resolved address is private, and
    /// then rewritten to the (first) IP literal; anything else throws `.publicHTTP`.
    public static func effectiveURL(_ url: URL, resolver: any HostResolver) async throws(AddressError) -> URL {
        try AddressParser.validateBase(url)
        guard !AddressParser.isTLS(url), let host = url.host else { return url }
        switch AddressParser.classify(host: host) {
        case .privateIP, .localName: return url
        case .publicIP, .publicName: throw .publicHTTP(host: AddressParser.hostLabel(url))
        case .needsResolve:
            let addrs = await resolver.addresses(of: host)
            guard !addrs.isEmpty else { throw .invalid(host) }
            guard addrs.allSatisfy({ AddressParser.classify(host: $0) == .privateIP }) else {
                throw .publicHTTP(host: AddressParser.hostLabel(url))
            }
            let ip = addrs.first(where: { AddressParser.ipv4($0) != nil }) ?? addrs[0]
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            c.host = ip
            return c.url ?? url
        }
    }
}
