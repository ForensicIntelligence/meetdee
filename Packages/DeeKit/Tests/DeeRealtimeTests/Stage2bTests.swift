import Foundation
import Testing
@testable import DeeRealtime

/// Stage 2b: per-response reasoning effort, local (clip) playback, multi-item
/// barge-in, replies that end early, accepted speech, and uplink drops.
@Suite struct Stage2bTests {
    static func effort(_ e: ClientEvent?) -> String? {
        if case .responseCreate(let p, _)? = e { p?.reasoning?.effort } else { nil }
    }

    func assistantTurns(_ h: Harness) async -> [String] {
        await h.session.recentTurns.filter { $0.role == .assistant }.map(\.text)
    }

    /// Opens user speech `item` and commits it.
    func userTurn(_ h: Harness, _ item: String) async {
        h.push(S.speechStarted(item), S.speechStopped(item), S.committed(item))
        await h.sync()
    }

    // MARK: 1. reasoning effort per response

    @Test func reasoningEffortGoesOnThatResponseOnly() async throws {
        let h = try await Harness.connected()
        await userTurn(h, "u1")
        try await h.session.requestResponse(reasoningEffort: "high")
        #expect(await h.socket.waitForSent(type: "response.create", count: 1))
        #expect(Self.effort(h.socket.sent(type: "response.create").last) == "high")
        // On the wire: response.reasoning.effort.
        let raw = try #require(h.socket.sent.last { $0.contains("\"response.create\"") })
        guard case .object(let o) = json(raw), case .object(let r)? = o["response"],
              case .object(let reasoning)? = r["reasoning"] else {
            Issue.record("no response.reasoning in \(raw)"); return
        }
        #expect(reasoning["effort"] == .string("high"))
        h.push(S.responseCreated("r1"), S.responseDone("r1"))
        await h.sync()

        // Without one, the session's effort applies: no per-response field.
        await userTurn(h, "u2")
        try await h.session.requestResponse()
        #expect(await h.socket.waitForSent(type: "response.create", count: 2))
        #expect(Self.effort(h.socket.sent(type: "response.create").last) == nil)
        h.push(S.responseCreated("r2"), S.responseDone("r2"))
        await h.sync()

        #expect(await h.session.initiative(instructions: "Say hi.", reasoningEffort: "minimal") == .sent)
        #expect(Self.effort(h.socket.sent(type: "response.create").last) == "minimal")
    }

    /// A reply preempted by what turns out to be her echo is asked for again with
    /// the same effort.
    @Test func aReRequestedReplyKeepsItsEffort() async throws {
        let h = try await Harness.connected()
        await userTurn(h, "u1")
        try await h.session.requestResponse(reasoningEffort: "medium")
        h.push(S.responseCreated("r1"), S.speechStarted("u2"))
        #expect(await h.log.wait { $0 == .replyPreempted(responseID: "r1") } != nil)
        h.push(S.responseDone("r1", status: "cancelled", reason: "client_cancelled"))
        await h.sync()
        await h.session.rejectEcho(itemID: "u2")
        #expect(await h.socket.waitForSent(type: "response.create", count: 2))
        #expect(Self.effort(h.socket.sent(type: "response.create").last) == "medium")
    }

    // MARK: 2. local playback (clips)

    /// Speech that starts over a clip is maybe her echo: it does not preempt the
    /// reply being generated, and her reply still plays.
    @Test func speechOverAClipDoesNotPreemptTheReply() async throws {
        let h = try await Harness.connected()
        await userTurn(h, "u1")
        try await h.session.requestResponse()
        await h.session.setLocalPlayback(true)               // she laughs at the joke
        h.push(S.responseCreated("r1"), S.speechStarted("u2"))
        await h.sync()
        #expect(!h.log.contains { if case .replyPreempted = $0 { true } else { false } })
        #expect(h.sentCount("response.cancel") == 0)
        h.push(S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 200))
        #expect(await h.log.wait(\.isAudio) != nil)          // the second gate holds too
        await h.session.rejectEcho(itemID: "u2")
        #expect(h.sentCount("response.cancel") == 0)
    }

    /// The same speech without a clip playing preempts (the control).
    @Test func withoutTheClipTheSameSpeechPreempts() async throws {
        let h = try await Harness.connected()
        await userTurn(h, "u1")
        try await h.session.requestResponse()
        await h.session.setLocalPlayback(true)
        await h.session.setLocalPlayback(false)              // its echo has left the room
        h.push(S.responseCreated("r1"), S.speechStarted("u2"))
        #expect(await h.log.wait { $0 == .replyPreempted(responseID: "r1") } != nil)
    }

    @Test func noInitiativeOverAClip() async throws {
        let h = try await Harness.connected()
        await h.session.setLocalPlayback(true)
        #expect(await h.session.initiative(instructions: "Hi.") == .refused(.speaking))
        await h.session.setLocalPlayback(false)
        #expect(await h.session.initiative(instructions: "Hi.") == .sent)
    }

    // MARK: 3. barge-in over several items

    /// Her reply is playing and a second one is queued behind it: both are
    /// truncated to what was heard, and the generating one is cancelled.
    @Test func bargeInCutsEveryQueuedItem() async throws {
        let h = try await Harness.connected()
        await userTurn(h, "u1")
        try await h.session.requestResponse()
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 1000),
               S.transcript("r1", "a1", "One. "), S.transcript("r1", "a1", "Two."),
               S.audioDone("r1", "a1"), S.transcriptDone("r1", "a1", "One. Two."), S.responseDone("r1"))
        await h.sync()
        await userTurn(h, "u2")
        try await h.session.requestResponse()
        h.push(S.responseCreated("r2"), S.messageAdded("r2", "a2"), S.audio("r2", "a2", ms: 500),
               S.transcript("r2", "a2", "Three. "))
        await h.sync()

        let o = await h.session.bargeIn(cuts: [(itemID: "a1", playedMs: 600), (itemID: "a2", playedMs: 0),
                                               (itemID: "nope", playedMs: 10), (itemID: "a1", playedMs: 900)])
        #expect(o.cancelledResponse)
        #expect(o.truncations.map { "\($0.itemID)@\($0.audioEndMs)" } == ["a1@600", "a2@0"])
        #expect(o.truncatedItemID == "a1" && o.audioEndMs == 600)
        let truncates = h.socket.sent(type: "conversation.item.truncate").compactMap { e -> String? in
            if case .itemTruncate(let id, _, let end, _) = e { "\(id)@\(end)" } else { nil }
        }
        #expect(truncates == ["a1@600", "a2@0"])
        #expect(h.sentCount("response.cancel") == 1)
        #expect(await h.log.wait { $0 == .assistantTruncated(itemID: "a2", audioEndMs: 0) } != nil)
        // History: "One." (midpoint 222 ms of 1000 over 9 chars) was heard; nothing of a2.
        #expect(await assistantTurns(h) == ["One."])
        h.push(S.transcriptDone("r2", "a2", "Three."), S.responseDone("r2", status: "cancelled", reason: "client_cancelled"))
        await h.sync()
        #expect(await assistantTurns(h) == ["One."])
        #expect(await h.session.state == .listening)
    }

    /// A fully played item is left alone; the old single-item call still works.
    @Test func aFullyPlayedItemIsNotTruncated() async throws {
        let h = try await Harness.connected()
        await userTurn(h, "u1")
        try await h.session.requestResponse()
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 400),
               S.transcriptDone("r1", "a1", "Hi."), S.responseDone("r1"))
        await h.sync()
        let o = await h.session.bargeIn(cuts: [(itemID: "a1", playedMs: 400)])
        #expect(o.truncations.isEmpty && !o.cancelledResponse)
        #expect(h.sentCount("conversation.item.truncate") == 0)
        #expect(await assistantTurns(h) == ["Hi."])
    }

    // MARK: 4. a reply that does not complete

    /// Cut by the token limit: the transcript ran ahead of the audio. Her turn
    /// keeps what the audio covers, and the trailing sentence is placed at the
    /// speaking rate, not squeezed into the audio that came.
    @Test func anIncompleteReplyKeepsOnlyWhatItsAudioCovers() async throws {
        let h = try await Harness.connected()
        await userTurn(h, "u1")
        try await h.session.requestResponse()
        // 62 ms per character: One. ends 248, Two. 558, Three. 992, Four. 1364 (midpoint 1209).
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 1000),
               S.transcript("r1", "a1", "One. Two. Three. Four."),
               S.responseDone("r1", status: "incomplete", reason: "max_output_tokens"))
        let done = try #require(await h.log.wait { $0.responseDone != nil }?.responseDone)
        #expect(done.hitTokenLimit)
        let hints = h.log.all.compactMap { e -> String? in
            if case .assistantSentence(_, let text, let hint) = e { "\(text)@\(hint)" } else { nil }
        }
        #expect(hints.last == "Four.@1364", "\(hints)")
        #expect(await assistantTurns(h) == ["One. Two. Three."])
    }

    /// The same when its full transcript had already been logged.
    @Test func aFailedReplyTrimsItsLoggedTranscript() async throws {
        let h = try await Harness.connected()
        await userTurn(h, "u1")
        try await h.session.requestResponse()
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 500),
               S.transcriptDone("r1", "a1", "One. Two. Three. Four."))
        await h.sync()
        #expect(await assistantTurns(h) == ["One. Two. Three. Four."])
        h.push(S.responseDone("r1", status: "failed"))
        await h.sync()
        #expect(await assistantTurns(h) == ["One. Two."])
    }

    /// The socket drops mid-reply: the seed for the next session holds only what
    /// her audio covered.
    @Test func aReplyCutByTheSocketKeepsOnlyWhatCame() async throws {
        let h = try await Harness.connected()
        await userTurn(h, "u1")
        try await h.session.requestResponse()
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 500),
               S.transcriptDone("r1", "a1", "One. Two. Three. Four."))
        await h.sync()
        h.socket.drop()
        let done = try #require(await h.log.wait { $0.responseDone != nil }?.responseDone)
        #expect(done.reason == "connection_lost")
        #expect(await assistantTurns(h) == ["One. Two."])
    }

    /// A completed reply is unchanged: every sentence, proportional hints.
    @Test func aCompletedReplyKeepsEverything() async throws {
        let h = try await Harness.connected()
        await userTurn(h, "u1")
        try await h.session.requestResponse()
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 500),
               S.transcript("r1", "a1", "One. Two. Three. Four."), S.responseDone("r1"))
        await h.sync()
        #expect(await assistantTurns(h) == ["One. Two. Three. Four."])
    }

    // MARK: 5. acceptSpeech

    /// Speech held as maybe-echo (it began over her audio) is confirmed as the
    /// user: from then on it preempts like any user speech.
    @Test func acceptedSpeechPreemptsAPendingReply() async throws {
        let h = try await Harness.connected()
        await userTurn(h, "u1")
        try await h.session.requestResponse()
        await h.session.setLocalPlayback(true)
        h.push(S.responseCreated("r1"), S.speechStarted("u2"))
        await h.sync()
        #expect(!h.log.contains { if case .replyPreempted = $0 { true } else { false } })
        await h.session.acceptSpeech(itemID: "nope")           // not the open speech: nothing
        #expect(h.sentCount("response.cancel") == 0)
        await h.session.acceptSpeech(itemID: "u2")
        #expect(await h.log.wait { $0 == .replyPreempted(responseID: "r1") } != nil)
        #expect(await h.socket.waitForSent(type: "response.cancel"))
        await h.session.acceptSpeech(itemID: "u2")             // idempotent
        await h.sync()
        #expect(h.log.count { $0 == .replyPreempted(responseID: "r1") } == 1)
    }

    /// A tool follow-up waits while accepted user speech is open (it would talk
    /// over them).
    @Test func noFollowUpOverAcceptedSpeech() async throws {
        let h = try await Harness.connected()
        await h.session.setToolHandler { _ in RealtimeToolResult(output: "{}", followUp: .always) }
        await userTurn(h, "u1")
        try await h.session.requestResponse()
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 300),
               S.functionCallAdded("r1", "f1", name: "recall"),
               S.callDone("r1", "f1", call: "c1", name: "recall", args: "{}"),
               S.speechStarted("u2"))                         // over her playing audio
        await h.sync()
        await h.session.acceptSpeech(itemID: "u2")
        h.push(S.responseDone("r1"))
        await h.sync()
        await h.settle()
        #expect(await h.socket.waitForSent(type: "conversation.item.create", count: 1))
        #expect(h.sentCount("response.create") == 1, "no follow-up over the user")
    }

    // MARK: 6. uplink drops

    @Test func congestionReportsWhereAudioWasDropped() async throws {
        let h = try await Harness.connected()
        let chunk = Data(count: 4_800)                        // 100 ms
        await h.session.appendAudio(chunk)
        await h.session.appendAudio(chunk)
        h.socket.setPendingBytes(1_000_000)
        await h.session.appendAudio(chunk)
        await h.session.appendAudio(chunk)
        h.socket.setPendingBytes(0)
        await h.session.appendAudio(chunk)
        await h.sync()
        let drops = h.log.all.compactMap { e -> String? in
            if case .uplinkDropped(let frames, let feed, let at) = e { "\(frames)@\(feed)/\(at.map(String.init) ?? "-")" } else { nil }
        }
        // Exact frames, at their place in the feed (frames 4800 and 7200) and on
        // the server's timeline (200 ms: where both gaps are).
        #expect(drops == ["2400@4800/200", "2400@7200/200"])
        #expect(h.sentCount("input_audio_buffer.append") == 3)
        #expect(h.log.contains(.fallbackAdvised(.congested)))
    }

    /// The feed queue keeps order and turns overflow into a gap where it happened.
    @Test func theFeedQueueMarksItsGap() async {
        let feed = AudioFeed(limit: 3)
        for n in 1...5 { feed.push(Data(repeating: UInt8(n), count: 48 * n)) }
        var got: [AudioFeed.Item] = []
        for _ in 0..<4 { if let i = await feed.next() { got.append(i) } }
        #expect(got == [.gap(bytes: 48 + 96), .audio(Data(repeating: 3, count: 144)),
                        .audio(Data(repeating: 4, count: 192)), .audio(Data(repeating: 5, count: 240))])
        feed.push(Data(count: 2))
        #expect(await feed.next() == .audio(Data(count: 2)))
        feed.finish()
        #expect(await feed.next() == nil)
    }
}
