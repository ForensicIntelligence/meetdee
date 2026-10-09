import DeeRealtime
import Foundation
import Testing
@testable import DeeCore

final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [ToolCall] = []
    func record(_ c: ToolCall) { lock.withLock { _calls.append(c) } }
    var calls: [ToolCall] { lock.withLock { _calls } }
}

struct FakeClockTool: AgentTool {
    let log: CallLog
    var spec: ToolSpec {
        ToolSpec(name: "get_time", description: "Current time.", parameters: [ToolParameter("zone", .string, "Time zone.", required: false)])
    }
    func run(_ call: ToolCall) async throws -> String {
        log.record(call)
        return "12:00 \(call["zone"] ?? "local")"
    }
}

struct FailingTool: AgentTool {
    var spec: ToolSpec { ToolSpec(name: "remember_fact", description: "Save a fact.", parameters: [ToolParameter("fact", .string, "The fact.")]) }
    func run(_ call: ToolCall) async throws -> String {
        _ = try call.require("fact")
        throw ToolError.permissionDenied("your memories")
    }
}

/// The tool abstraction without a local model: JSON-schema function tools for the
/// realtime session, and calls whose arguments arrive as JSON text.
@Suite struct ToolSpecTests {
    static let remember = ToolSpec(name: "remember_fact", description: "Save a lasting fact about the current person.", parameters: [
        ToolParameter("fact", .string, "Third person, e.g. 'likes jazz'."),
        ToolParameter("category", .string, "Kind of fact.", required: false, allowed: ["likes", "family"]),
        ToolParameter("weight", .number, "How sure.", required: false),
    ])

    @Test func functionJSONIsTheRealtimeToolShapeInDeclarationOrder() {
        #expect(Self.remember.functionJSON == #"{"type":"function","name":"remember_fact","description":"Save a lasting fact about the current person.","parameters":{"type":"object","properties":{"fact":{"type":"string","description":"Third person, e.g. 'likes jazz'."},"category":{"type":"string","description":"Kind of fact.","enum":["likes","family"]},"weight":{"type":"number","description":"How sure."}},"required":["fact"],"additionalProperties":false}}"#)
    }

    @Test func aToolWithoutParametersStillHasAnObjectSchema() {
        let spec = ToolSpec(name: "recall_all", description: "Everything.")
        #expect(spec.parametersSchema.json == #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#)
    }

    @Test func functionJSONDecodesAsARealtimeTool() throws {
        let tool = try JSONDecoder().decode(RealtimeTool.self, from: Data(Self.remember.functionJSON.utf8))
        #expect(tool.type == "function")
        #expect(tool.name == "remember_fact")
        #expect(tool.description == Self.remember.description)
        #expect(tool.parameters?["required"] == .array([.string("fact")]))
        #expect(tool.parameters?["properties"]?["category"]?["enum"] == .array([.string("likes"), .string("family")]))
        // The bridge the brain uses gives the same tool.
        let bridged = RealtimeTool(name: Self.remember.name, description: Self.remember.description,
                                   parameters: RealtimeJSON.parse(Self.remember.parametersSchema.json))
        #expect(bridged == tool)
    }

    @Test func jsonEscapesWhatItMustAndKeepsUnicode() {
        let v = JSONValue.object([("say", .string("“Hi” \\ \"x\"\n\t\u{01}é")), ("n", .number(2.5)), ("i", .number(3)), ("ok", .bool(true)), ("z", .null)])
        #expect(v.json == #"{"say":"“Hi” \\ \"x\"\n\t\u0001é","n":2.5,"i":3,"ok":true,"z":null}"#)
        #expect(RealtimeJSON.parse(v.json)?["say"]?.stringValue == "“Hi” \\ \"x\"\n\t\u{01}é")
    }
}

@Suite struct ToolCallJSONTests {
    @Test func stringsNumbersAndBooleansBecomeArguments() throws {
        let call = try #require(ToolCall(name: "remember_fact", jsonArguments: #"{"fact":"likes jazz","weight":0.5,"count":3,"sure":true,"none":null}"#))
        #expect(call.name == "remember_fact")
        #expect(call.arguments == [ToolArgument("count", "3"), ToolArgument("fact", "likes jazz"), ToolArgument("sure", "true"), ToolArgument("weight", "0.5")])
        #expect(call["fact"] == "likes jazz")
        #expect(call["none"] == nil)
    }

    /// Review F10: integers of 1e15 and more used to come out as "1e+15"-style
    /// doubles (or lose digits).
    @Test func largeIntegersKeepEveryDigit() throws {
        let call = try #require(ToolCall(name: "x", jsonArguments:
            #"{"a":1000000000000000,"b":9007199254740993,"c":-1234567890123456789,"d":123456789012345678901234567890,"e":2.5,"f":1e20,"g":7.0}"#))
        #expect(call["a"] == "1000000000000000")
        #expect(call["b"] == "9007199254740993")
        #expect(call["c"] == "-1234567890123456789")
        #expect(call["d"] == "123456789012345678901234567890")
        #expect(call["e"] == "2.5")
        #expect(call["f"] == "1e+20")
        #expect(call["g"] == "7")
    }

    @Test func nestedValuesKeepTheirJSON() throws {
        let call = try #require(ToolCall(name: "x", jsonArguments: #"{"list":["a",1],"obj":{"b":false,"a":"s/t"}}"#))
        #expect(call["list"] == #"["a",1]"#)
        #expect(call["obj"] == #"{"a":"s/t","b":false}"#)
    }

    @Test func emptyArgumentsAreACallWithoutArguments() throws {
        #expect(try #require(ToolCall(name: "recall", jsonArguments: "")).arguments.isEmpty)
        #expect(try #require(ToolCall(name: "recall", jsonArguments: " {} ")).arguments.isEmpty)
    }

    @Test func textThatIsNotAnObjectIsRejected() {
        #expect(ToolCall(name: "x", jsonArguments: "[1,2]") == nil)
        #expect(ToolCall(name: "x", jsonArguments: "\"fact\"") == nil)
        #expect(ToolCall(name: "x", jsonArguments: "{\"fact\": ") == nil)
    }
}

@Suite struct ToolRegistryTests {
    @Test func runsTheNamedToolWithJSONArguments() async {
        let log = CallLog()
        let registry = ToolRegistry([FakeClockTool(log: log)])
        #expect(registry.specs.map(\.name) == ["get_time"])
        #expect(await registry.execute(name: "get_time", jsonArguments: #"{"zone":"UTC"}"#) == "12:00 UTC")
        #expect(log.calls == [ToolCall(name: "get_time", arguments: [ToolArgument("zone", "UTC")])])
    }

    @Test func anUnknownToolIsAnErrorTheModelCanReadAndRunsNothing() async {
        let log = CallLog()
        let registry = ToolRegistry([FakeClockTool(log: log)])
        let result = await registry.execute(ToolCall(name: "get_weather"))
        #expect(result == "Error: there is no tool named 'get_weather'. Available: get_time.")
        #expect(log.calls.isEmpty)
    }

    @Test func badArgumentsAndThrownErrorsBecomeText() async {
        let registry = ToolRegistry([FailingTool()])
        #expect(await registry.execute(name: "remember_fact", jsonArguments: "not json") == "Error: the arguments for 'remember_fact' were not a JSON object.")
        #expect(await registry.execute(name: "remember_fact", jsonArguments: "{}") == "Error: Missing required argument 'fact'.")
        #expect(await registry.execute(name: "remember_fact", jsonArguments: #"{"fact":"x"}"#)
                == "Error: Permission to access your memories was denied. Ask the user to allow it in Settings.")
    }
}
