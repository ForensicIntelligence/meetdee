import Foundation

/// Module namespace for DeeRealtime.
///
/// DeeRealtime is Dee's client for OpenAI's Realtime API (GA interface,
/// `gpt-realtime-2.1-mini` by default) over a WebSocket. It knows nothing about
/// Dee's mind, face or audio graph: the app feeds it 24 kHz PCM16 and reads back
/// `RealtimeEvent`s. Foundation, Network and Security only.
public enum DeeRealtimeModule {}

/// Arbitrary JSON, used where the wire schema is open (tool parameter schemas,
/// session objects echoed by the server, unknown events).
///
/// Named `RealtimeJSON` (not `JSONValue`) so it never collides with
/// `DeeCore.JSONValue` in files that import both.
public indirect enum RealtimeJSON: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RealtimeJSON])
    case object([String: RealtimeJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([RealtimeJSON].self) { self = .array(a); return }
        self = .object(try c.decode([String: RealtimeJSON].self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d):
            // Whole numbers go out as integers ("24000", not "24000.0").
            if d.rounded() == d, abs(d) < 1e15 { try c.encode(Int64(d)) } else { try c.encode(d) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> RealtimeJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var doubleValue: Double? { if case .number(let d) = self { d } else { nil } }
    public var intValue: Int? { doubleValue.map { Int($0) } }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }

    /// Parses UTF-8 JSON text; nil if it is not JSON.
    public static func parse(_ text: String) -> RealtimeJSON? {
        try? JSONDecoder().decode(RealtimeJSON.self, from: Data(text.utf8))
    }

    /// Compact JSON text (keys sorted, so equal values print equally).
    public var jsonText: String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}

extension RealtimeJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: RealtimeJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, RealtimeJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
    public init(nilLiteral: ()) { self = .null }
}

/// The coders every DeeRealtime wire type goes through.
enum Wire {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder().encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(text.utf8))
    }
}

/// Coding key from any string (used by the hand-written coders).
struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension KeyedDecodingContainer where Key == AnyKey {
    /// Integers on the wire are sometimes sent as `1500.0`; accept both.
    func lenientInt(_ key: String) throws -> Int? {
        let k = AnyKey(key)
        guard contains(k), try !decodeNil(forKey: k) else { return nil }
        if let i = try? decode(Int.self, forKey: k) { return i }
        return Int(try decode(Double.self, forKey: k))
    }

    func string(_ key: String) throws -> String? {
        let k = AnyKey(key)
        guard contains(k), try !decodeNil(forKey: k) else { return nil }
        return try decode(String.self, forKey: k)
    }

    func value<T: Decodable>(_ type: T.Type, _ key: String) throws -> T? {
        let k = AnyKey(key)
        guard contains(k), try !decodeNil(forKey: k) else { return nil }
        return try decode(type, forKey: k)
    }
}
