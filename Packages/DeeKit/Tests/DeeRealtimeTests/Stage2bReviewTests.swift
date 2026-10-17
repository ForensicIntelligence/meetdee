import Foundation
import Testing
@testable import DeeRealtime

/// Stage 2b review fixes: the generating item on barge-in, exact uplink drops,
/// and the uplink origin of each session.
@Suite struct Stage2bReviewTests {
    func userTurn(_ h: Harness, _ item: String) async {
        h.push(S.speechStarted(item), S.speechStopped(item), S.committed(item))
        await h.sync()
    }

    /// Fix 1: a tool follow-up (a2) is generating while a1 still plays; the app's
    /// player has not seen a2 yet, so the cuts list only a1. a2 is truncated at 0
    /// all the same: the server and Dee's history keep none of it.
    @Test func bargeInTruncatesTheGeneratingItemItWasNotTold() async throws {
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
               S.transcript("r2", "a2", "Three is long. "))
        await h.sync()

        let o = await h.session.bargeIn(cuts: [(itemID: "a1", playedMs: 500)])
        #expect(o.cancelledResponse)
        #expect(o.truncations.map { "\($0.itemID)@\($0.audioEndMs)" } == ["a1@500", "a2@0"])
        let truncates = h.socket.sent(type: "conversation.item.truncate").compactMap { e -> String? in
            if case .itemTruncate(let id, _, let end, _) = e { "\(id)@\(end)" } else { nil }
        }
        #expect(truncates == ["a1@500", "a2@0"])
        h.push(S.transcriptDone("r2", "a2", "Three is long."),
               S.responseDone("r2", status: "cancelled", reason: "client_cancelled"))
        await h.sync()
        let turns = await h.session.recentTurns.filter { $0.role == .assistant }.map(\.text)
        #expect(turns == ["One."], "\(turns)")

        // The single-item form gets the same treatment, and a listed generating
        // item keeps the figure it was given.
        await userTurn(h, "u3")
        try await h.session.requestResponse()
        h.push(S.responseCreated("r3"), S.messageAdded("r3", "a3"), S.audio("r3", "a3", ms: 800))
        await h.sync()
        let o2 = await h.session.bargeIn(cuts: [(itemID: "a3", playedMs: 300)])
        #expect(o2.truncations == [.init(itemID: "a3", audioEndMs: 300)])
    }

    /// Fixes 2 and 4: every session's timeline starts at a named feed frame
    /// (`.uplinkOrigin`, just before `.connected`), and drops while reconnecting
    /// are exact and positioned.
    @Test func eachSessionNamesWhereItsTimelineStarts() async throws {
        var config = Harness.defaultConfig()
        config.preconnectBufferMs = 100                     // 4800 bytes
        let h = try await Harness.connected(config: config)
        let first = h.socket
        let origins = { h.log.all.compactMap { e -> Int? in if case .uplinkOrigin(let f) = e { f } else { nil } } }
        // The origin comes right before `.connected`.
        #expect(await h.log.wait { if case .connected = $0 { true } else { false } } != nil)
        let i0 = try #require(h.log.all.firstIndex { if case .uplinkOrigin = $0 { true } else { false } })
        if case .connected = h.log.all[i0 + 1] {} else { Issue.record("origin not right before connected") }
        #expect(origins() == [0])

        await h.session.appendAudio(Data(count: 4_800))      // feed frames 0..<2400
        await h.session.appendAudio(Data(count: 4_800))      // 2400..<4800
        first.drop()
        #expect(await h.log.wait { if case .disconnected = $0 { true } else { false } } != nil)
        for _ in 0..<3 { await h.session.appendAudio(Data(count: 2_400)) }   // 4800..<8400, buffered
        // The buffer holds 100 ms: the first 50 ms piece goes, exactly where it was.
        #expect(await h.log.wait { $0 == .uplinkDropped(frames: 1_200, atFeedFrame: 4_800, atServerMs: nil) } != nil)

        await h.advance(by: 0.5)
        let second = try #require(await h.factory.waitForSocket(count: 2))
        #expect(second !== first)
        #expect(await h.log.wait { $0 == .uplinkOrigin(feedFrame: 6_000) } != nil)
        let all = h.log.all
        let i1 = try #require(all.firstIndex(of: .uplinkOrigin(feedFrame: 6_000)))
        if case .connected = all[i1 + 1] {} else { Issue.record("origin not right before connected") }
        #expect(origins() == [0, 6_000])
        // What the new session got starts at feed frame 6000: 2400 frames (4800 bytes).
        let sentBytes = second.sent(type: "input_audio_buffer.append").reduce(0) { n, e in
            if case .inputAudioAppend(let b64, _) = e { n + (Data(base64Encoded: b64)?.count ?? 0) } else { n }
        }
        #expect(sentBytes == 4_800)
    }
}
