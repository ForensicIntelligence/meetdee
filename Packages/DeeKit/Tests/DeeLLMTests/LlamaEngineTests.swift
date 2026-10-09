import DeeCore
import Foundation
import Testing
@testable import DeeLLM

/// Real-model tests. They need the GGUF in `Models/` (or `DEE_MODEL_PATH`) and are
/// skipped when it's absent, so machines without the 2.7 GB file stay green.
///
/// Each test loads its own engine and lets it deinit before returning: a model
/// still alive at process exit trips a ggml-metal teardown assert.
enum TestModel {
    static var path: String? {
        if let env = ProcessInfo.processInfo.environment["DEE_MODEL_PATH"] { return env }
        let candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../Models/Qwen3.5-4B-Q4_K_M.gguf")
            .standardized.path
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    static func withEngine(_ body: (LlamaEngine) async throws -> Void) async throws {
        let engine = try await LlamaEngine.load(.init(modelPath: try #require(path)))
        try await body(engine)
    }

    static func agent(_ engine: LlamaEngine) -> ConversationAgent {
        var config = AgentConfig()
        config.chatSampling = .greedy
        config.thinkingSampling = .greedy
        return ConversationAgent(generator: engine, config: config)
    }
}

struct Reply {
    var content = ""
    var reasoning = ""
    var emotions: [Emotion] = []
    var events: [AgentEvent] = []

    static func collect(_ stream: AsyncThrowingStream<AgentEvent, Error>) async throws -> Reply {
        var r = Reply()
        for try await e in stream {
            r.events.append(e)
            switch e {
            case .content(let s): r.content += s
            case .reasoning(let s): r.reasoning += s
            case .emotion(let em): r.emotions.append(em)
            default: break
            }
        }
        return r
    }
}

@Suite(.serialized, .enabled(if: TestModel.path != nil))
struct LlamaEngineTests {
    @Test func agentAnswersAndReusesState() async throws {
        try await TestModel.withEngine { engine in
            let agent = TestModel.agent(engine)
            await agent.newConversation()

            let first = try await Reply.collect(agent.respond(to: "Hi! I'm John. What's your name?"))
            print("REPLY1:", first.content, first.emotions)
            #expect(!first.content.isEmpty)
            #expect(!first.content.hasPrefix(" "))
            #expect(!first.emotions.isEmpty, "Dee should open with a feeling tag")
            let before = engine.stats

            let second = try await Reply.collect(agent.respond(to: "What's my name?"))
            print("REPLY2:", second.content, engine.stats)
            #expect(second.content.contains("John"))
            #expect(engine.stats.fullPrefills == before.fullPrefills, "second turn must extend the cached state")
        }
    }

    @Test func thinkAboutItEnablesReasoning() async throws {
        try await TestModel.withEngine { engine in
            let agent = TestModel.agent(engine)
            await agent.newConversation()

            let r = try await Reply.collect(agent.respond(to: "Think about it carefully: is 91 a prime number?"))
            print("REASONING:", r.reasoning.prefix(300), "…\nANSWER:", r.content)
            #expect(r.events.contains(.thinkingModeChanged(true)))
            #expect(!r.reasoning.isEmpty)
            #expect(!r.content.isEmpty)
            #expect(!r.content.contains("</think>"))
            #expect(!r.content.hasPrefix("\n"))
            #expect(await agent.thinkingEnabled)

            await agent.newConversation()
            #expect(await agent.thinkingEnabled == false)
        }
    }

    @Test func cancelStopsTheTurn() async throws {
        try await TestModel.withEngine { engine in
            let agent = TestModel.agent(engine)
            await agent.newConversation()
            var pieces = 0
            for try await e in agent.respond(to: "Tell me a very long story about a robot who learns to dance.") {
                if case .content = e {
                    pieces += 1
                    if pieces == 5 { await agent.cancel() }
                }
            }
            #expect(pieces < 30, "generation should stop shortly after cancel (got \(pieces) pieces)")
            // The conversation is still usable and still append-only.
            let before = engine.stats.fullPrefills
            let r = try await Reply.collect(agent.respond(to: "Okay, just say hi."))
            #expect(!r.content.isEmpty)
            #expect(engine.stats.fullPrefills == before)
        }
    }

    @Test func utf8AssemblerHoldsSplitCharacters() {
        var a = UTF8Assembler()
        let heart = Array("é❤️".utf8)
        #expect(a.append(Array(heart[0..<1])) == nil)
        #expect(a.append(Array(heart[1..<3])) == "é")
        #expect(a.append(Array(heart[3...])) == "❤️")
        #expect(a.flush() == nil)
    }
}
