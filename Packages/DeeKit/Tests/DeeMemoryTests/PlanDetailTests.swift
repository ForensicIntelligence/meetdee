import Foundation
import Testing
@testable import DeeMemory

/// Live transcript "a week with John": "It's for a designer job at a game studio. I've
/// wanted this for years." right after the interview plan stored nothing, so three days
/// later the model invented "a job at the space station". Details of the plan just
/// mentioned are now facts.
@Suite("Plan details")
struct PlanDetailTests {
    @Test func jobDetailsOfTheInterviewJustMentionedAreRemembered() async throws {
        let s = try memStore()
        let john = try await named(s, "John")
        await s.learn(from: "Hi Dee! I'm John. I just set you up on my phone.", about: john.id, at: t0)
        await s.learn(from: "I have a big job interview tomorrow afternoon and I'm pretty nervous about it.", about: john.id, at: t0 + 4)
        let r = await s.learn(from: "It's for a designer job at a game studio. I've wanted this for years.", about: john.id, at: t0 + 8)
        #expect(r.stored.map(\.text) == ["is applying for a designer job at a game studio"])
        await s.learn(from: "Why did the robot go on vacation? It needed to recharge its batteries! Haha", about: john.id, at: t0 + 12)

        // Three days later the prompt still carries it.
        let lines = await s.promptMemories(for: john.id, limit: 6, now: t0 + 3 * 86_400)
        #expect(lines.contains("John is applying for a designer job at a game studio"), "\(lines)")
        #expect(lines.contains { $0.hasPrefix("John had a big job interview on ") }, "\(lines)")
    }

    @Test func planDetailForms() {
        let interview = "has a job interview on Fri 9 Oct 2026"
        func details(_ u: String, _ plan: String = interview) -> [String] { FactExtractor.planDetails(from: u, plan: plan).map(\.text) }
        #expect(details("It's for a designer job at a game studio.") == ["is applying for a designer job at a game studio"])
        #expect(details("It's for an engineering position.") == ["is applying for an engineering position"])
        #expect(details("The interview's for a senior producer role at Ubisoft") == ["is applying for a senior producer role at Ubisoft"])
        #expect(details("Oh, it's at Pixel Forge.") == ["is interviewing at Pixel Forge"])
        // Conservative: not a time, not home, not an unrelated "it's for".
        #expect(details("It's at 3pm.").isEmpty)
        #expect(details("It's at noon tomorrow.").isEmpty)
        #expect(details("it's at home, on video").isEmpty)
        #expect(details("It's for a friend.").isEmpty)
        #expect(details("It's for my sister's birthday.").isEmpty)
        #expect(details("I've wanted this for years.").isEmpty)
        // Only about a job-like plan.
        #expect(details("It's for a cleaning job at the clinic", "has a dentist appointment on Fri 9 Oct 2026").isEmpty)
        #expect(details("It's at Pixel Forge", "has an application deadline on Fri 9 Oct 2026").isEmpty, "only an interview is 'at' a company")
    }

    @Test func detailsNeedAPlanJustMentioned() async throws {
        let s = try memStore()
        let john = try await named(s, "John")
        // No plan: "it's for a designer job" has no referent.
        var r = await s.learn(from: "It's for a designer job at a game studio.", about: john.id, at: t0)
        #expect(r.stored.isEmpty)
        // A plan, then the detail 11 minutes later: too late to be about it.
        await s.learn(from: "I have a job interview tomorrow.", about: john.id, at: t0 + 60)
        r = await s.learn(from: "It's for a designer job at a game studio.", about: john.id, at: t0 + 60 + 11 * 60)
        #expect(r.stored.isEmpty)
        // In the same breath works too.
        r = await s.learn(from: "I have a job interview on Friday. It's for a teaching position at Westview.", about: john.id, at: t0 + 3600)
        #expect(r.stored.map(\.text).contains("is applying for a teaching position at Westview"), "\(r.stored.map(\.text))")
    }

    @Test func applyingForIsAWorkFact() {
        let f = FactExtractor.extract(from: "I'm applying for a designer job at Ubisoft", now: t0, calendar: utc)
        #expect(f == [ExtractedFact(text: "is applying for a designer job at Ubisoft", category: .work)])
        let g = FactExtractor.extract(from: "I applied for a nursing position", now: t0, calendar: utc)
        #expect(g == [ExtractedFact(text: "applied for a nursing position", category: .work)])
        #expect(FactExtractor.extract(from: "I'm applying for it tomorrow", now: t0, calendar: utc).allSatisfy { !$0.text.contains("applying") })
    }
}
