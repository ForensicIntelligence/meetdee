import Foundation

/// One tool parameter, described the JSON-schema way.
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

/// What the model is told about a tool: a function tool with a JSON-schema
/// parameter object, in the shape the OpenAI Realtime API takes in
/// `session.tools` — `{"type":"function","name":…,"description":…,"parameters":{…}}`.
///
/// DeeCore does not depend on DeeRealtime; the brain bridges the two with
/// `RealtimeTool(name: spec.name, description: spec.description,
/// parameters: RealtimeJSON.parse(spec.parametersSchema.json))`, or decodes
/// `functionJSON` as a `RealtimeTool` directly (both are tested).
public struct ToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    public var parameters: [ToolParameter]

    public init(name: String, description: String, parameters: [ToolParameter] = []) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    /// The JSON schema of the arguments: an object with one property per
    /// parameter (in declaration order), `enum` for allowed values, and the
    /// required names. `additionalProperties: false` keeps the model to the names
    /// the tool actually reads.
    public var parametersSchema: JSONValue {
        var properties: [(String, JSONValue)] = []
        for p in parameters {
            var fields: [(String, JSONValue)] = [("type", .string(p.kind.rawValue)), ("description", .string(p.description))]
            if let allowed = p.allowed { fields.append(("enum", .array(allowed.map(JSONValue.string)))) }
            properties.append((p.name, .object(fields)))
        }
        return .object([
            ("type", .string("object")),
            ("properties", .object(properties)),
            ("required", .array(parameters.filter(\.required).map { .string($0.name) })),
            ("additionalProperties", .bool(false)),
        ])
    }

    /// The whole function tool as a JSON value (realtime `session.tools` entry).
    public var function: JSONValue {
        .object([
            ("type", .string("function")),
            ("name", .string(name)),
            ("description", .string(description)),
            ("parameters", parametersSchema),
        ])
    }

    /// `function` as compact JSON text.
    public var functionJSON: String { function.json }
}

/// Minimal ordered JSON value. Key order is kept exactly as built, so a tool's
/// schema text is stable from run to run (good for prompt caching and goldens).
public indirect enum JSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool { lhs.json == rhs.json }

    /// Compact standard JSON (`,` and `:` without spaces; non-ASCII left as is).
    /// Whole numbers are written as integers.
    public var json: String {
        switch self {
        case .string(let s): return JSONValue.quote(s)
        case .number(let d):
            guard d.isFinite else { return "null" }
            if d.rounded() == d, abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let items): return "[" + items.map(\.json).joined(separator: ",") + "]"
        case .object(let pairs):
            return "{" + pairs.map { JSONValue.quote($0.0) + ":" + $0.1.json }.joined(separator: ",") + "}"
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
