import Foundation

/// Something the agent can do on the device.
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
}
