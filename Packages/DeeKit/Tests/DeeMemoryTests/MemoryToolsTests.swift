import DeeCore
import Foundation
import Testing
@testable import DeeMemory

final class Box: @unchecked Sendable {
    var id: UUID?
    init(_ id: UUID?) { self.id = id }
}

func call(_ name: String, _ args: [String: String]) -> ToolCall {
    ToolCall(name: name, arguments: args.sorted { $0.key < $1.key }.map { ToolArgument($0.key, $0.value) })
}

@Suite("Memory tools")
struct MemoryToolsTests {
    @Test func specsAreTerse() async throws {
        let s = try memStore()
        let tools: [any AgentTool] = [
            RememberTool(store: s, currentPerson: { nil }),
            RecallTool(store: s, currentPerson: { nil }),
            ForgetTool(store: s, currentPerson: { nil }),
        ]
        #expect(tools.map(\.spec.name) == ["remember_fact", "recall", "forget_fact"])
        let total = tools.map(\.spec.templateJSON.count).reduce(0, +)
        #expect(total < 1000, "tool specs cost context: \(total) chars")
        #expect(tools[0].spec.parameters.first { $0.name == "category" }?.required == false)
        #expect(tools[0].spec.parameters.first { $0.name == "category" }?.allowed?.count == Fact.Category.allCases.count)
    }

    @Test func rememberRecallForgetRoundTrip() async throws {
        let s = try memStore()
        let p = try await named(s, "John")
        let current = Box(p.id)
        let registry = ToolRegistry([
            RememberTool(store: s, currentPerson: { current.id }),
            RecallTool(store: s, currentPerson: { current.id }),
            ForgetTool(store: s, currentPerson: { current.id }),
        ])
        let r1 = await registry.execute(call("remember_fact", ["fact": "likes jazz", "category": "preference"]))
        #expect(r1 == "Remembered: likes jazz.")
        _ = await registry.execute(call("remember_fact", ["fact": "has a cat named Miso"]))
        #expect(await s.person(p.id)?.facts.first { $0.text.contains("Miso") }?.category == .pet)
        let recall = await registry.execute(call("recall", ["query": "pets"]))
        #expect(recall.contains("Name: John"))
        #expect(recall.contains("- has a cat named Miso"))
        #expect(!recall.contains("jazz"))
        let all = await registry.execute(call("recall", ["query": "everything"]))
        #expect(all.contains("jazz") && all.contains("Miso"))
        let f = await registry.execute(call("forget_fact", ["fact": "jazz"]))
        #expect(f == "Forgot: likes jazz.")
        let none = await registry.execute(call("forget_fact", ["fact": "rugby"]))
        #expect(none.hasPrefix("Nothing matched"))
    }

    @Test func badCategoryAndMissingFactAreErrors() async throws {
        let s = try memStore()
        let reg = ToolRegistry([RememberTool(store: s, currentPerson: { nil })])
        #expect(await reg.execute(call("remember_fact", ["fact": "x", "category": "weird"])).hasPrefix("Error: Invalid value for 'category'"))
        #expect(await reg.execute(call("remember_fact", [:])).hasPrefix("Error: Missing required argument 'fact'"))
    }

    @Test func noCurrentPersonSavesNothing() async throws {
        let s = try memStore()
        let out = try await RememberTool(store: s, currentPerson: { nil }).run(call("remember_fact", ["fact": "likes tea"]))
        #expect(out.contains("nothing was saved"))
        #expect(await s.people().isEmpty, "tools never create a shared placeholder")
    }

    @Test func sessionPlaceholderThenMerge() async throws {
        let s = try memStore()
        let ghost = await s.placeholderPerson(session: UUID(), at: t0)
        let current = Box(ghost.id)
        let remember = RememberTool(store: s, currentPerson: { current.id })
        _ = try await remember.run(call("remember_fact", ["fact": "likes tea"]))
        #expect(await s.person(ghost.id)?.facts.map(\.text) == ["likes tea"])
        let kim = try await named(s, "Kim")
        await s.merge(ghost.id, into: kim.id)
        current.id = kim.id
        let recall = try await RecallTool(store: s, currentPerson: { current.id }).run(call("recall", ["query": "tea"]))
        #expect(recall.contains("likes tea"))
    }

    @Test func firstPersonFactIsRephrasedAndNameKeptPending() async throws {
        let s = try memStore()
        let ghost = await s.placeholderPerson(session: UUID(), at: t0)
        let remember = RememberTool(store: s, currentPerson: { ghost.id })
        let out = try await remember.run(call("remember_fact", ["fact": "My name is Lena and I have a dog named Pip"]))
        #expect(out.contains("Heard the name Lena"))
        #expect(out.contains("has a dog named Pip"))
        #expect(await s.person(named: "Lena") == nil, "not applied until confirmed")
        #expect(await s.pendingName(for: ghost.id)?.name == "Lena")
        #expect(await s.person(ghost.id)?.facts.map(\.text) == ["has a dog named Pip"])
    }

    @Test func classifierGuesses() {
        #expect(FactClassifier.guess("is allergic to peanuts") == .health)
        #expect(FactClassifier.guess("has a dog named Rex") == .pet)
        #expect(FactClassifier.guess("has a daughter named Emma") == .relationship)
        #expect(FactClassifier.guess("dislikes jazz") == .dislike)
        #expect(FactClassifier.guess("likes jazz") == .preference)
        #expect(FactClassifier.guess("works at the hospital") == .work)
        #expect(FactClassifier.guess("lives in Ottawa") == .place)
        #expect(FactClassifier.guess("birthday is March 3") == .birthday)
        #expect(FactClassifier.guess("has an exam tomorrow") == .event)
        #expect(FactClassifier.guess("speaks French") == .other)
    }
}
