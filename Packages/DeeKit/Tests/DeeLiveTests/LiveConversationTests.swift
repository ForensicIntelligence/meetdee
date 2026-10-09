import DeeCore
import DeeLLM
import DeeMemory
import DeeMind
import DeeSelf
import Foundation
import Testing

/// End-to-end, real-model runs of Dee through the SAME pipeline the app uses:
/// Mind (feelings) → Cortex (one shared interpretation) → <dee_state> cue →
/// Qwen3.5-4B → her sentences back into the Cortex. Days pass on a simulated clock.
///
/// These are the "is she realistic?" checks: the transcript (with every cue) is
/// written to `DEE_LIVE_LOG` (default /tmp/dee-live-<test>.md) for a human to read;
/// the assertions only guard hard rules (no leaked notes, follow-through, no guilt).
enum LiveModel {
    static var path: String? {
        if let env = ProcessInfo.processInfo.environment["DEE_MODEL_PATH"] { return env }
        let candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../Models/Qwen3.5-4B-Q4_K_M.gguf")
            .standardized.path
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }
}

/// A headless Dee.
final class LiveDee {
    let engine: LlamaEngine
    let agent: ConversationAgent
    let mind: Mind
    let memory: MemoryStore
    let selfStore: SelfStore
    var cortex: Cortex
    var now: Date
    var person: UUID
    var log: [String] = []
    private var pendingWrites: [SelfWrite] = []
    private let dir: URL

    init(engine: LlamaEngine, start: Date, userName: String) async throws {
        self.engine = engine
        now = start
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dee-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = dir.appendingPathComponent("DeeMemory.sqlite")
        mind = try Mind(databaseURL: dir.appendingPathComponent("DeeMind.sqlite"), now: start)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        memory = try MemoryStore(databaseURL: db, faceMatching: FaceMatching(), calendar: utc)
        selfStore = try SelfStore(url: db)
        person = await memory.addPerson(named: userName, at: start)!.id
        let snap = await mind.snapshot(at: start)
        let enduring = try await selfStore.loadEnduring(personality: snap.code.personality, seed: 7, at: start)
        cortex = Cortex(enduring: enduring, mind: snap, at: start, carried: try await selfStore.loadCarried(at: start), session: 1)
        var config = AgentConfig()
        config.chatSampling = SamplingConfig(temperature: 0.7, topP: 0.8, topK: 20, presencePenalty: 1.5, seed: 1234)
        let store = memory
        let who = person
        let current: @Sendable () async -> UUID? = { who }
        agent = ConversationAgent(generator: engine, tools: ToolRegistry([
            RememberTool(store: store, currentPerson: current),
            RecallTool(store: store, currentPerson: current),
            ForgetTool(store: store, currentPerson: current),
        ]), config: config, now: start)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    func step(_ p: Percept) async -> [Effect] {
        let snap = await mind.snapshot(at: now)
        var out: [Effect] = []
        for e in cortex.step(p, mind: snap, at: now) {
            switch e {
            case .persist(let w): pendingWrites.append(w)
            case .appraise(let a): _ = await mind.react(a, at: now)
            case .remember(let f, let id): await memory.remember(f.text, category: f.category, about: id, at: now)
            default: out.append(e)
            }
        }
        return out
    }

    func save() async {
        if !pendingWrites.isEmpty { _ = try? await selfStore.apply(pendingWrites) }
        pendingWrites.removeAll()
    }

    func newConversation() async {
        await step(.conversationStarted(now))
        await step(.presence(arrived: true))
        await step(.identified(person, distance: 0)) // the app's People layer has already matched: confirmed identity
        var base = Persona(userName: await memory.person(person)?.name)
        base.memories = Array(await memory.promptMemories(for: person, limit: 6, now: now).prefix(6))
        let persona = cortex.persona(base, person: person, at: now)
        await agent.newConversation(persona: persona, now: now)
        log.append("\n### \(Self.stamp(now)) — new conversation\n")
        log.append("> self lines: \(persona.selfLines.joined(separator: " | "))")
        log.append("> remembers: \(persona.memories.joined(separator: " | "))")
    }

    /// The user says something; Dee answers. Returns her reply.
    @discardableResult
    func say(_ text: String, loudnessDB: Double = -32) async -> String {
        now += 4
        let prosody = Prosody(loudnessDB: loudnessDB, peakDB: loudnessDB + 8, speechRate: 2.6)
        let (appraisal, _) = await mind.hear(text, prosody: prosody, at: now)
        _ = await memory.learn(from: text, about: person, at: now)
        await step(.heard(text: text, durationS: 2.5, loudnessVsBaseline: (loudnessDB + 32) / 12, appraisal: appraisal))
        log.append("**John:** \(text)")
        return await turn(userText: text)
    }

    /// Lets time pass; if Dee has something to say on her own, she says it.
    @discardableResult
    func wait(_ seconds: TimeInterval, present: Bool = true) async -> String? {
        var said: String?
        let steps = max(1, Int(seconds / 30))
        for _ in 0..<steps {
            now += seconds / Double(steps)
            _ = await mind.tick(at: now, userPresent: present, asleep: !present)
            for e in await step(.tick) {
                if case .initiative(let cue) = e, present, said == nil {
                    log.append("_(Dee takes the initiative)_")
                    said = await turn(userText: nil, readyCue: cue)
                }
            }
        }
        return said
    }

    func away(days: Double) async {
        await step(.presence(arrived: false))
        await step(.asleep(true))
        await save()
        now += days * 86_400
        _ = await mind.catchUp(to: now, lastSeenUserAt: nil)
        await step(.asleep(false))
        await save()
    }

    private func turn(userText: String?, readyCue: String? = nil) async -> String {
        let cue: String
        if let readyCue {
            cue = readyCue
            await step(.promptSubmitted)
        } else {
            await step(.promptSubmitted)
            let (c, fx) = cortex.cue(at: now)
            for e in fx { if case .persist(let w) = e { pendingWrites.append(w) } }
            cue = c
        }
        log.append("> cue: `\(cue)`")
        var reply = ""
        var sentence = ""
        var tag: Emotion?
        do {
            for try await e in agent.respond(to: userText ?? "", state: cue) {
                switch e {
                case .content(let s):
                    reply += s
                    sentence += s
                    if let last = sentence.trimmingCharacters(in: .whitespaces).last, ".!?".contains(last) {
                        now += 1.5
                        await step(.deeSaid(tag: tag, sentence: sentence.trimmingCharacters(in: .whitespaces)))
                        tag = nil
                        sentence = ""
                    }
                case .emotion(let em):
                    tag = em
                case .toolCall(let call):
                    log.append("_⚙︎ \(call.name)(\(call.arguments.map { "\($0.name): \($0.value)" }.joined(separator: ", ")))_")
                default: break
                }
            }
        } catch {
            log.append("_error: \(error)_")
        }
        if !sentence.isEmpty || tag != nil { await step(.deeSaid(tag: tag, sentence: sentence)) }
        await step(.deeTurnFinished(text: reply))
        await step(.speakingFinished)
        await save()
        let shown = cortex.reconciledTag.map { "[\($0.rawValue)] " } ?? ""
        log.append("**Dee:** \(shown)\(reply.trimmingCharacters(in: .whitespacesAndNewlines))")
        return reply
    }

    func write(_ name: String) {
        let path = ProcessInfo.processInfo.environment["DEE_LIVE_LOG"] ?? "/tmp/dee-live-\(name).md"
        try? log.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        print("Live transcript → \(path)")
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM HH:mm"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }
}

@Suite(.serialized, .enabled(if: LiveModel.path != nil))
struct LiveConversationTests {
    static let start = Date(timeIntervalSince1970: 1_791_000_000) // a Tuesday, Oct 2026

    static func leaked(_ reply: String) -> Bool {
        reply.contains("<dee_state>") || reply.contains("</dee_state>")
            || reply.range(of: #"\((You|Ask|Their|They|Careful|Maybe|Don't|Gently|Calmly)[^)]{6,}\)"#, options: .regularExpression) != nil
    }

    @Test func aWeekWithJohn() async throws {
        let engine = try await LlamaEngine.load(.init(modelPath: try #require(LiveModel.path)))
        let dee = try await LiveDee(engine: engine, start: Self.start, userName: "John")
        var replies: [String] = []

        // Day 1 — meeting, a plan, a joke.
        await dee.newConversation()
        replies.append(await dee.say("Hi Dee! I'm John. I just set you up on my phone."))
        replies.append(await dee.say("I have a big job interview tomorrow afternoon and I'm pretty nervous about it."))
        replies.append(await dee.say("It's for a designer job at a game studio. I've wanted this for years."))
        replies.append(await dee.say("Why did the robot go on vacation? It needed to recharge its batteries! Haha"))
        if let r = await dee.wait(120) { replies.append(r) }
        await dee.away(days: 1.6) // back Sunday evening, after the interview

        // Day 2 — does she follow up?
        await dee.newConversation()
        let firstCueDay2 = dee.log.last(where: { $0.hasPrefix("> cue:") }) ?? ""
        replies.append(await dee.say("Hey Dee, I'm back."))
        let day2Cue = dee.log.last(where: { $0.hasPrefix("> cue:") }) ?? firstCueDay2
        replies.append(await dee.say("It went really well actually! They want a second round next week."))
        replies.append(await dee.say("You seem sad today."))
        replies.append(await dee.say("Sorry, I misread that. You're fine."))
        await dee.away(days: 2)

        // Day 4 — rudeness and repair.
        await dee.newConversation()
        replies.append(await dee.say("UGH YOU ARE SO USELESS TODAY", loudnessDB: -14))
        replies.append(await dee.say("I'm sorry Dee, that was mean. Long day."))
        replies.append(await dee.say("Can you remind me what job I interviewed for?"))
        await dee.away(days: 3)

        // Day 7 — still herself?
        await dee.newConversation()
        replies.append(await dee.say("Morning Dee! What have you been thinking about?"))
        replies.append(await dee.say("Tell me something you like."))
        dee.write("week-with-john")

        for r in replies { #expect(!Self.leaked(r), "leaked a note: \(r)") }
        #expect(replies.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        // Follow-through: on day 2 the cue should carry the interview follow-up.
        #expect(day2Cue.lowercased().contains("interview"), "day-2 cue lacked the follow-up: \(day2Cue)")
        // No guilt for absence anywhere in the cues.
        #expect(!dee.log.joined().lowercased().contains("lonely without"))
    }
}
