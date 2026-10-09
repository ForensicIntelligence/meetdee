import Foundation

/// One named argument of a tool call. Arguments are kept as an ordered list (not a
/// dictionary) so a call reads back in the order it was written.
public struct ToolArgument: Codable, Sendable, Equatable {
    public var name: String
    public var value: String

    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

/// A function call the model asked for. Arguments are plain strings: the tools
/// parse what they need (`require`), so one call shape serves every tool.
public struct ToolCall: Codable, Sendable, Equatable {
    public var name: String
    public var arguments: [ToolArgument]

    public init(name: String, arguments: [ToolArgument] = []) {
        self.name = name
        self.arguments = arguments
    }

    /// A call whose arguments arrive as JSON object text (a realtime
    /// `function_call`'s `arguments`). Strings are taken as they are; numbers and
    /// booleans become their JSON text (`3`, `2.5`, `true`); `null` and absent keys
    /// are left out; arrays and objects keep their compact JSON text. Keys are
    /// sorted, so the result does not depend on the encoder's key order. Empty text
    /// is a call without arguments. Nil when the text is not a JSON object.
    public init?(name: String, jsonArguments: String) {
        let trimmed = jsonArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.init(name: name)
            return
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])) as? [String: Any] else {
            return nil
        }
        var arguments: [ToolArgument] = []
        for key in object.keys.sorted() {
            guard let text = Self.text(of: object[key]!) else { continue }
            arguments.append(ToolArgument(key, text))
        }
        self.init(name: name, arguments: arguments)
    }

    public subscript(_ key: String) -> String? {
        arguments.first { $0.name == key }?.value
    }

    /// `objCType`s of NSNumbers that hold a floating-point value.
    private static let floatingTypes: Set<String> = ["d", "f"]

    private static func text(of value: Any) -> String? {
        switch value {
        case is NSNull:
            return nil
        case let s as String:
            return s
        case let n as NSNumber:
            // JSONSerialization hands booleans over as NSNumber too.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            // Integers keep every digit whatever their size (an ID, a timestamp in
            // ms): JSONSerialization hands them over as integer NSNumbers, or as
            // NSDecimalNumber beyond 64 bits. Only real fractions go through Double.
            if n is NSDecimalNumber { return n.stringValue }
            if !Self.floatingTypes.contains(String(cString: n.objCType)) { return n.stringValue }
            let d = n.doubleValue
            if d.rounded() == d, abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        default:
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
            else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

/// Something Dee can do on the device (remember a fact, look up a reminder, …).
/// The model sees `spec` as a JSON-schema function tool (`ToolSpec.functionJSON`)
/// and calls it by name; the app runs it through a `ToolRegistry`.
public protocol AgentTool: Sendable {
    var spec: ToolSpec { get }
    /// Executes the call and returns a short, plain-text result for the model.
    /// Throw `ToolError` for anything the model should hear about.
    func run(_ call: ToolCall) async throws -> String
}

public enum ToolError: Error, Sendable, LocalizedError {
    case missingArgument(String)
    case invalidArgument(String, String)
    case permissionDenied(String)
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .missingArgument(let n): "Missing required argument '\(n)'."
        case .invalidArgument(let n, let why): "Invalid value for '\(n)': \(why)"
        case .permissionDenied(let what): "Permission to access \(what) was denied. Ask the user to allow it in Settings."
        case .unavailable(let why): "Not available: \(why)"
        case .failed(let why): why
        }
    }
}

public extension ToolCall {
    func require(_ key: String) throws -> String {
        guard let v = self[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else {
            throw ToolError.missingArgument(key)
        }
        return v
    }
}

/// The set of tools offered to the model, looked up by name.
public struct ToolRegistry: Sendable {
    public private(set) var tools: [any AgentTool]

    public init(_ tools: [any AgentTool] = []) { self.tools = tools }

    public var specs: [ToolSpec] { tools.map(\.spec) }

    public func tool(named name: String) -> (any AgentTool)? {
        tools.first { $0.spec.name == name }
    }

    /// Runs a call, converting every failure into text the model can react to.
    public func execute(_ call: ToolCall) async -> String {
        guard let tool = tool(named: call.name) else {
            return "Error: there is no tool named '\(call.name)'. Available: \(tools.map(\.spec.name).joined(separator: ", "))."
        }
        do {
            return try await tool.run(call)
        } catch {
            return "Error: \((error as? LocalizedError)?.errorDescription ?? String(describing: error))"
        }
    }

    /// Runs a call whose arguments are JSON object text (a realtime function call).
    /// Arguments that are not a JSON object come back as an error the model can
    /// react to, never as a crash or a silent no-op.
    public func execute(name: String, jsonArguments: String) async -> String {
        guard let call = ToolCall(name: name, jsonArguments: jsonArguments) else {
            return "Error: the arguments for '\(name)' were not a JSON object."
        }
        return await execute(call)
    }
}
