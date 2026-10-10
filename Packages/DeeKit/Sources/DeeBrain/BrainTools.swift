import DeeCore
import DeeMemory
import DeeRealtime
import Foundation

/// The realtime function tools (docs/DNA.md §3: `remember`, `recall`, `forget`,
/// plus the device tools), their follow-up policy, and the bridge from the
/// session's tool calls to DeeCore's `ToolRegistry`.
public struct BrainToolbox: Sendable {
    public let registry: ToolRegistry
    /// When the session speaks with a tool's result (`RealtimeToolResult.FollowUp`).
    public let followUps: [String: RealtimeToolResult.FollowUp]

    /// The names DNA.md and the session instructions use for the memory tools.
    public static let memoryNames: [String: String] = ["remember_fact": "remember", "recall": "recall", "forget_fact": "forget"]

    public init(tools: [any AgentTool], followUps: [String: RealtimeToolResult.FollowUp] = [:]) {
        registry = ToolRegistry(tools)
        var f = Self.defaultFollowUps
        for (k, v) in followUps { f[k] = v }
        self.followUps = f
    }

    /// `remember` at the end of a spoken turn needs no follow-up; `recall` and the
    /// device look-ups are spoken; `forget` is acknowledged only when she said nothing.
    public static let defaultFollowUps: [String: RealtimeToolResult.FollowUp] = [
        "remember": .ifSilent, "recall": .always, "forget": .ifSilent,
    ]

    /// How each memory tool is used, said where the model reads it (tune 2 F-LEAK: 22
    /// of 529 live replies narrated a call — "Got it, let me think about how to respond
    /// to that.", "Quick save for your name, then I'll respond." — and a narrated
    /// `remember` gets no follow-up, so she never answered). Calls are silent.
    public static let memoryDescriptions: [String: String] = [
        "remember": "Save a lasting fact about the current person. Answer them normally, then call this last, silently; never say you are saving, noting, tucking away or remembering it.",
        "recall": "Look up what you know about the current person, only when the DNA does not already say it. Call it as your very first action, with no words before it, and answer from its result.",
        "forget": "Forget a fact when the person asks. Call it silently first, then confirm in a few words.",
    ]

    /// The memory tools under their DNA.md names. Empty when memories are private
    /// (Settings "Share memories with cloud voice" off).
    public static func memoryTools(store: MemoryStore, currentPerson: @escaping @Sendable () async -> UUID?,
                                   share: Bool = true) -> [any AgentTool] {
        guard share else { return [] }
        return [
            RenamedTool(RememberTool(store: store, currentPerson: currentPerson), as: "remember",
                        description: memoryDescriptions["remember"]),
            PrivateFactsFilter(RenamedTool(RecallTool(store: store, currentPerson: currentPerson), as: "recall",
                                           description: memoryDescriptions["recall"]),
                               store: store, currentPerson: currentPerson),
            PrivateFactsFilter(RenamedTool(ForgetTool(store: store, currentPerson: currentPerson), as: "forget",
                                           description: memoryDescriptions["forget"]),
                               store: store, currentPerson: currentPerson),
        ]
    }

    /// The `session.tools` entries (stable for the session: prompt caching).
    public var realtimeTools: [RealtimeTool] {
        registry.specs.map { RealtimeTool(name: $0.name, description: $0.description, parameters: RealtimeJSON.parse($0.parametersSchema.json)) }
    }

    public var names: [String] { registry.specs.map(\.name) }

    /// Runs one call. Never throws: failures come back as text the model can react to.
    public func run(_ call: RealtimeToolCall) async -> RealtimeToolResult {
        let output = await registry.execute(name: call.name, jsonArguments: call.arguments)
        return RealtimeToolResult(output: output, followUp: followUps[call.name] ?? .always)
    }
}

/// A tool offered under another name (DeeMemory's `remember_fact` as `remember`).
/// Mentions of the old names in its results are rewritten too.
public struct RenamedTool: AgentTool {
    public let base: any AgentTool
    public let name: String

    /// Replaces the base tool's description (nil keeps it).
    public let description: String?

    public init(_ base: any AgentTool, as name: String, description: String? = nil) {
        self.base = base
        self.name = name
        self.description = description
    }

    public var spec: ToolSpec {
        let s = base.spec
        return ToolSpec(name: name, description: description ?? s.description, parameters: s.parameters)
    }

    public func run(_ call: ToolCall) async throws -> String {
        var out = try await base.run(ToolCall(name: base.spec.name, arguments: call.arguments))
        for (old, new) in BrainToolbox.memoryNames where old != new {
            out = out.replacingOccurrences(of: old, with: new)
        }
        return out
    }
}

/// Keeps sensitive facts (`Fact.sensitive`: health, beliefs, sexuality, …) out of a
/// memory tool's result: they never go to OpenAI, exactly as they never appear in a
/// DNA (docs/DNA.md §1.6, §5.4). `recall` lists only the others and says how many
/// private ones it left out; `forget` names a private fact it deleted, or offers as a
/// choice, only as "something private".
public struct PrivateFactsFilter: AgentTool {
    public let base: any AgentTool
    public let store: MemoryStore
    public let currentPerson: @Sendable () async -> UUID?

    public init(_ base: any AgentTool, store: MemoryStore, currentPerson: @escaping @Sendable () async -> UUID?) {
        self.base = base
        self.store = store
        self.currentPerson = currentPerson
    }

    public var spec: ToolSpec { base.spec }

    public func run(_ call: ToolCall) async throws -> String {
        // Read before running: `forget` deletes what it names.
        var privateTexts: Set<String> = []
        if let id = await currentPerson() {
            privateTexts = Set(await store.search("everything", about: id, limit: 10_000).filter(\.sensitive).map(\.text))
        }
        let out = try await base.run(call)
        return privateTexts.isEmpty ? out : Self.redact(out, privateTexts: privateTexts)
    }

    /// `- fact` lines and the `Forgot: a; b.` line without the private facts.
    nonisolated static func redact(_ output: String, privateTexts: Set<String>) -> String {
        var hidden = 0
        var lines: [String] = []
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("- "), privateTexts.contains(String(line.dropFirst(2))) {
                hidden += 1
                continue
            }
            if line.hasPrefix("Forgot: ") {
                var body = String(line.dropFirst("Forgot: ".count))
                if body.hasSuffix(".") { body.removeLast() }
                let parts = body.components(separatedBy: "; ").map { privateTexts.contains($0) ? "something private" : $0 }
                lines.append("Forgot: " + parts.joined(separator: "; ") + ".")
                continue
            }
            lines.append(line)
        }
        if hidden > 0 {
            if lines.last == "No facts yet." { lines.removeLast() }
            lines.append(hidden == 1
                ? "There is also 1 private thing you know; never bring it up, and if they ask to forget it, have them say it."
                : "There are also \(hidden) private things you know; never bring them up, and if they ask to forget one, have them say it.")
        }
        return lines.joined(separator: "\n")
    }
}
