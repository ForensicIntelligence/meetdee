import Foundation
import Testing
@testable import DeeRealtime

/// Tune 6: the live tune-5 failures owned by DeeRealtime (T5-5 rollover, T5-7 history).
@Suite struct Tune6Tests {
    func seedText(_ socket: FakeSocket) -> String? {
        for e in socket.sent(type: "conversation.item.create") {
            if case .itemCreate(let item, _, _) = e, item.role == "system", item.id == nil,
               let t = item.text, t.hasPrefix("[The conversation continues") { return t }
        }
        return nil
    }

    /// What a socket was sent, as kinds in order: "seed", "dna", "create" (an
    /// in-band `response.create`), "summary"; everything else left out.
    func order(_ socket: FakeSocket) -> [String] {
        socket.sentEvents.compactMap { e -> String? in
            switch e {
            case .itemCreate(let item, _, _) where item.role == "system":
                if item.id?.hasPrefix("dna_") == true { return "dna" }
                return item.text?.hasPrefix("[The conversation continues") == true ? "seed" : "system"
            case .responseCreate(let p, _):
                return p?.metadata?["purpose"] == "dee_rollover_summary" ? "summary" : "create"
            default:
                return nil
            }
        }
    }

    /// The event id of the seed sent on a socket.
    func seedEventID(_ socket: FakeSocket) -> String? {
        for e in socket.sent(type: "conversation.item.create") {
            if case .itemCreate(let item, _, let eid) = e, item.text?.hasPrefix("[The conversation continues") == true {
                return eid
            }
        }
        return nil
    }

    func exchange(_ h: Harness, item: String, said: String, resp: String, reply: String) async throws {
        h.push(S.speechStarted(item), S.speechStopped(item), S.committed(item), S.userTranscript(item, said))
        await h.log.wait { $0 == .userTranscript(itemID: item, text: said) }
        try await h.session.requestResponse(dna: "DEE DNA v6 · reply\n4 TOWARD THIS PERSON\nPriya.")
        h.push(S.responseCreated(resp), S.messageAdded(resp, "a_\(resp)"), S.audio(resp, "a_\(resp)", ms: 200),
               S.transcriptDone(resp, "a_\(resp)", reply), S.responseDone(resp))
        await h.log.wait { $0.responseDone?.responseID == resp }
        await h.session.playbackFinished()
        await h.sync()
    }

    // MARK: 1. Rollover (T5-5)

    /// Live trace t2-fallback-rollover-speech m01: the summary went out at 94.17,
    /// "Do you remember what my name is?" started at 94.41, the new connection was
    /// up (parked) at 96.22 and m01 committed at 96.45 — during the overlap. It
    /// must be answered where the conversation so far is (the old connection,
    /// already seeded), never on the new one before its seed; after the switch,
    /// every response on the new connection runs behind its seed *and* a DNA, and
    /// the seed carries the question across.
    @Test func aQuestionDuringTheHandoverIsAnsweredWithTheConversationSoFar() async throws {
        var config = Harness.defaultConfig()
        config.rolloverAfter = 60
        let h = try await Harness.connected(config: config)
        let first = h.socket
        try await exchange(h, item: "n01", said: "My name is Priya.", resp: "r1", reply: "Nice to meet you, Priya!")
        try await exchange(h, item: "q01", said: "Is it going to rain tomorrow?", resp: "r2",
                           reply: "I can't see the forecast from my little phone window.")
        await h.advance(by: 61)
        #expect(await first.waitForSent(type: "response.create", count: 3))   // the summary
        let purpose = "dee_rollover_summary"
        first.pushAll(S.responseCreated("r_sum", metadata: ["purpose": purpose]),
                      S.speechStarted("m01", ms: 11_028),
                      .outputTextDone(.init(responseID: "r_sum", itemID: "s1",
                                            text: "The person's name is Priya. They asked about rain.")),
                      S.responseDone("r_sum", metadata: ["purpose": purpose]))
        let second = try #require(await h.factory.waitForSocket(count: 2))
        #expect(await second.waitForSent(type: "session.update"))
        for _ in 0..<400 where await !h.session.hasParkedSession { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(await h.session.hasParkedSession)
        await h.advance(by: 1)
        #expect(!h.log.contains { if case .rolledOver = $0 { true } else { false } })   // the user is talking
        first.pushAll(S.speechStopped("m01", ms: 13_408), S.committed("m01"),
                      S.userTranscript("m01", "Do you remember what my name is?"))
        #expect(await h.log.wait { $0 == .userTranscript(itemID: "m01", text: "Do you remember what my name is?") } != nil)
        #expect(try await h.session.requestResponse(dna: "DEE DNA v6 · reply\n4 TOWARD THIS PERSON\nPriya.") == .sent)
        // Answered on the connection that holds the conversation; nothing on the parked one.
        #expect(order(first).suffix(2) == ["dna", "create"])
        #expect(!order(second).contains("create"))
        #expect(!order(second).contains("dna"))
        first.pushAll(S.responseCreated("r3"), S.messageAdded("r3", "a3"), S.audio("r3", "a3", ms: 300),
                      S.transcriptDone("r3", "a3", "Of course, Priya."), S.responseDone("r3"))
        #expect(await h.log.wait { $0.responseDone?.responseID == "r3" } != nil)
        await h.session.playbackFinished()
        await h.advance(by: 1)
        #expect(await h.log.wait { if case .rolledOver = $0 { true } else { false } } != nil)
        // The seed is the first thing on the new connection and carries the question across.
        #expect(order(second).first == "seed")
        let seed = try #require(seedText(second))
        #expect(seed.contains("Summary of the conversation so far: The person's name is Priya."))
        #expect(seed.contains("Person: Do you remember what my name is?\nDee: Of course, Priya."))
        // The next question on the new connection: seed, then the DNA, then the response.
        second.pushAll(S.speechStarted("m02"), S.speechStopped("m02"), S.committed("m02"),
                       S.userTranscript("m02", "What's my name again?"))
        #expect(await h.log.wait { $0 == .userTranscript(itemID: "m02", text: "What's my name again?") } != nil)
        #expect(try await h.session.requestResponse(dna: "DEE DNA v6 · reply\n4 TOWARD THIS PERSON\nPriya.") == .sent)
        #expect(order(second) == ["seed", "dna", "create"])
    }

    /// The summary states the name as a fact and never narrates memory: tune 5's
    /// summaries said "Dee confirms it will remember Priya's name", and she then
    /// said "I'll store it" (DNA decision: she never says she'll remember/store).
    @Test func theSummaryStatesTheNameAndNeverNarratesMemory() {
        let i = RealtimeSession.summaryInstructions
        #expect(i.contains("The person's name is <name>."))
        #expect(i.contains("never write that anyone will remember, store, note or save something"))
        #expect(RealtimeSession.seedHeader.hasPrefix("[The conversation continues from an earlier session."))
    }

    /// A seed the server refuses must not leave the response behind it running
    /// without the conversation: that response is given up before it starts and
    /// sent again behind a compact seed and the current DNA.
    @Test func aRefusedSeedIsResentAndTheResponseBehindItWaitsForIt() async throws {
        var config = Harness.defaultConfig()
        config.rolloverAfter = 60
        config.rolloverSummary = .none
        let h = try await Harness.connected(config: config)
        try await exchange(h, item: "n01", said: "My name is Priya.", resp: "r1", reply: "Nice to meet you, Priya!")
        await h.advance(by: 61)
        #expect(await h.log.wait { if case .rolledOver = $0 { true } else { false } } != nil)
        let second = h.socket
        let seedID = try #require(seedEventID(second))
        second.pushAll(S.speechStarted("m01"), S.speechStopped("m01"), S.committed("m01"),
                       S.userTranscript("m01", "Do you remember what my name is?"))
        #expect(await h.log.wait { $0 == .userTranscript(itemID: "m01", text: "Do you remember what my name is?") } != nil)
        let dna = "DEE DNA v6 · reply\n4 TOWARD THIS PERSON\nPriya."
        #expect(try await h.session.requestResponse(dna: dna) == .sent)
        #expect(order(second) == ["seed", "dna", "create"])
        second.push(S.error(code: "invalid_value", message: "Item too large", eventID: seedID))
        #expect(await second.waitForSent(type: "response.create", count: 2))
        #expect(order(second) == ["seed", "dna", "create", "seed", "dna", "create"])
        let seeds = second.sent(type: "conversation.item.create").compactMap { e -> String? in
            if case .itemCreate(let item, _, _) = e, item.text?.hasPrefix("[The conversation continues") == true { return item.text }
            return nil
        }
        #expect(seeds.count == 2)
        #expect(seeds.last?.contains("Person: My name is Priya.") == true)
        guard case .itemCreate(let lastDNA, _, _)? = second.sent(type: "conversation.item.create").last else {
            Issue.record("no DNA"); return
        }
        #expect(lastDNA.text == dna)
        #expect(!h.log.contains { if case .error = $0 { true } else { false } })   // handled, not surfaced
        // The given-up response's late `response.created` is an orphan; the new one runs.
        guard case .responseCreate(let p, _)? = second.sent(type: "response.create").last else { Issue.record("no create"); return }
        let token = try #require(p?.metadata?["dee_turn"])
        second.pushAll(S.responseCreated("r_old", metadata: ["dee_turn": "\(Int(token)! - 1)"]),
                       S.responseCreated("r_new", metadata: ["dee_turn": token]))
        #expect(await h.log.wait { $0 == .responseStarted(responseID: "r_new", kind: .reply) } != nil)
        #expect(!h.log.contains { $0 == .responseStarted(responseID: "r_old", kind: .reply) })
    }

    // MARK: 2. History = heard (T5-7)

    /// Live trace t2-reunion-evening: "Oh, absolutely! I love music—like tiny robot
    /// popcorn for the ears. Bright, funny, and full of surprises. How about you—what
    /// kind of music makes you bounce in your seat?" (11 000 ms) was cut at 6 460 ms;
    /// the voice heard 3 sentences. The truncate, the stored history and
    /// `heardText` are HeardRule's heard text, exactly. The reunion then started a
    /// new conversation (`resetConversation`, 15.93 s): her turn leaves the history
    /// on purpose and is listed in `forgottenItemIDs`, so a history check skips it
    /// (the live 30/31 "mismatch" was historyText "" for exactly this item).
    @Test func aCutReplyIsStoredExactlyAsHeardAndAResetForgetsItOnPurpose() async throws {
        let h = try await Harness.connected()
        h.push(S.speechStarted("u1"), S.speechStopped("u1"), S.committed("u1"), S.userTranscript("u1", "Do you like music?"))
        await h.log.wait { $0 == .userTranscript(itemID: "u1", text: "Do you like music?") }
        try await h.session.requestResponse(dna: "DEE DNA v6 · reply")
        let sentences = ["Oh, absolutely!", "I love music—like tiny robot popcorn for the ears.",
                         "Bright, funny, and full of surprises.",
                         "How about you—what kind of music makes you bounce in your seat?"]
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"))
        for (i, s) in sentences.enumerated() { h.push(S.transcript("r1", "a1", (i == 0 ? "" : " ") + s)) }
        for _ in 0..<55 { h.push(S.audio("r1", "a1", ms: 200)) }   // 11 000 ms, as live
        h.push(S.audioDone("r1", "a1"), S.transcriptDone("r1", "a1", sentences.joined(separator: " ")), S.responseDone("r1"))
        #expect(await h.log.wait { $0.responseDone?.responseID == "r1" } != nil)
        let hints = h.log.all.compactMap { e -> Int? in
            if case .assistantSentence("a1", _, let ms) = e { ms } else { nil }
        }
        #expect(hints.count == 4)
        let n = HeardRule.heardCount(hints: hints, playedMs: 6460)
        let heard = sentences.prefix(n).joined(separator: " ")
        #expect(n == 3)
        #expect(heard == "Oh, absolutely! I love music—like tiny robot popcorn for the ears. Bright, funny, and full of surprises.")

        let outcome = await h.session.bargeIn(cuts: [("a1", 6460)])
        let cut = try #require(outcome.truncations.first)
        #expect(cut.audioEndMs == 6460)
        #expect(cut.heardSentences == n)
        #expect(cut.heardText == heard)
        #expect(await h.session.heardText(itemID: "a1") == heard)
        #expect(await h.session.recentTurns.last { $0.itemID == "a1" }?.text == heard)
        #expect(h.socket.sent(type: "conversation.item.truncate").contains {
            if case .itemTruncate("a1", 0, 6460, _) = $0 { true } else { false }
        })

        // +50 h, a new conversation: forgotten on purpose, and said so.
        await h.session.resetConversation()
        #expect(await h.session.recentTurns.isEmpty)
        let forgotten = await h.session.forgottenItemIDs
        #expect(forgotten.isSuperset(of: ["u1", "a1"]))
        // The next exchange is recorded as heard as before and is not "forgotten".
        h.push(S.speechStarted("u2"), S.speechStopped("u2"), S.committed("u2"), S.userTranscript("u2", "How was your day?"))
        await h.log.wait { $0 == .userTranscript(itemID: "u2", text: "How was your day?") }
        try await h.session.requestResponse(dna: "DEE DNA v6 · reply")
        h.push(S.responseCreated("r2"), S.messageAdded("r2", "a2"), S.audio("r2", "a2", ms: 3000),
               S.transcriptDone("r2", "a2", "Bright and busy. Like tiny sparks."), S.responseDone("r2"))
        #expect(await h.log.wait { $0.responseDone?.responseID == "r2" } != nil)
        #expect(await h.session.recentTurns.map(\.text) == ["How was your day?", "Bright and busy. Like tiny sparks."])
        #expect(await !h.session.forgottenItemIDs.contains("a2"))
    }
}
