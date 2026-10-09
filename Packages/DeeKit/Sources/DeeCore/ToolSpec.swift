import Foundation

/// JSON-schema-ish description of one tool parameter.
public struct ToolParameter: Sendable, Equatable {
    public enum Kind: String, Sendable { case string, integer, number, boolean }

    public var name: String
    public var kind: Kind
    public var description: String
    public var required: Bool
    public var allowed: [String]?

    public init(_ name: String, _ kind: Kind = .string, _ description: String, required: Bool = true, allowed: [String]? = nil) {
        self.name = name
        self.kind = kind
        self.description = description
        self.required = required
        self.allowed = allowed
    }
}

/// What the model is told about a tool. Rendered into the system prompt exactly the
/// way the Qwen3.5 template does it: one `tool | tojson` line per tool inside `<tools>`.
public struct ToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    public var parameters: [ToolParameter]

    public init(name: String, description: String, parameters: [ToolParameter] = []) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    /// The single-line JSON the template produces with Jinja's `tojson`
    /// (Python `json.dumps` defaults: `", "` / `": "` separators, insertion order,
    /// non-ASCII left as-is).
    public var templateJSON: String {
        var properties: [(String, JSONValue)] = []
        for p in parameters {
            var fields: [(String, JSONValue)] = [("type", .string(p.kind.rawValue)), ("description", .string(p.description))]
            if let allowed = p.allowed { fields.append(("enum", .array(allowed.map(JSONValue.string)))) }
            properties.append((p.name, .object(fields)))
        }
        let schema: JSONValue = .object([
            ("type", .string("object")),
            ("properties", .object(properties)),
            ("required", .array(parameters.filter(\.required).map { .string($0.name) })),
        ])
        let root: JSONValue = .object([
            ("type", .string("function")),
            ("function", .object([
                ("name", .string(name)),
                ("description", .string(description)),
                ("parameters", schema),
            ])),
        ])
        return root.pythonJSON
    }
}

/// Minimal ordered JSON value, serialised the way Python's `json.dumps` would.
public indirect enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool { lhs.pythonJSON == rhs.pythonJSON }

    public var pythonJSON: String {
        switch self {
        case .string(let s): return JSONValue.quote(s)
        case .number(let d):
            if d.rounded() == d, abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let items): return "[" + items.map(\.pythonJSON).joined(separator: ", ") + "]"
        case .object(let pairs):
            return "{" + pairs.map { JSONValue.quote($0.0) + ": " + $0.1.pythonJSON }.joined(separator: ", ") + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
