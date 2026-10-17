import DeeRealtime
import Foundation
import Synchronization
import Testing
@testable import DeeVoice

// Stage 2b: the session APIs CloudVoice adopted (local playback, multi-item
// barge-in, accepted speech, uplink drops, per-response reasoning effort).

@Suite struct UplinkMapDropTests {
    @Test func aDropShiftsEverythingAfterIt() {
        var m = UplinkMap()
        m.sent(startFrame: 0, frames: 4_800)
        m.sent(startFrame: 4_800, frames: 4_800)
        m.sent(startFrame: 9_600, frames: 4_800)              // 600 ms, one run
        m.dropped(atFeedFrame: 4_800, frames: 2_400)          // capture 4800..<7200 never arrived
        #expect(m.serverFrames == 12_000)
        #expect(m.captureFrame(serverMs: 100) == 2_400)       // before the gap: unchanged
        #expect(m.captureFrame(serverMs: 200) == 7_200)       // the gap is skipped
        #expect(m.captureFrame(serverMs: 300) == 9_600)
        m.sent(startFrame: 14_400, frames: 2_400)             // later chunks continue the map
        #expect(m.captureFrame(serverMs: 550) == 15_600)
        #expect(m.captureEnd == 16_800)
    }

    @Test func aDropAcrossRunsAndPastTheEnd() {
        var m = UplinkMap()
        m.sent(startFrame: 0, frames: 2_400)                  // server 0–100 ms
        m.sent(startFrame: 10_000, frames: 2_400)             // server 100–200 ms (after a pause)
        m.dropped(atFeedFrame: 1_200, frames: 2_400)          // 50–150 ms: the end of one, the start of the other
        #expect(m.serverFrames == 2_400)
        #expect(m.captureFrame(serverMs: 25) == 600)
        #expect(m.captureFrame(serverMs: 50) == 11_200)
        #expect(m.captureFrame(serverMs: 75) == 11_800)
        m.dropped(atFeedFrame: 4_800, frames: 1_200)          // nothing fed there: ignored
        #expect(m.serverFrames == 2_400)
        m.dropped(atFeedFrame: 4_560, frames: 12_000)         // server 90 ms on: only what exists goes
        #expect(m.serverFrames == 2_160)
    }

    /// Review fix 2: the mic tap's 2048-frame buffers become 1024-frame (42.667 ms)
    /// chunks; dropping 234 of them one at a time (10 s of congestion) must move
    /// later offsets by exactly what was dropped, not by 234 x 43 ms.
    @Test func manyOddSizedDropsDoNotDrift() {
        var r = UplinkMap()
        var capture: Int64 = 0
        for _ in 0..<10 { r.sent(startFrame: capture, frames: 1_024); capture += 1_024 }
        for _ in 0..<234 {
            let at = r.fedFrames
            r.sent(startFrame: capture, frames: 1_024); capture += 1_024
            r.dropped(atFeedFrame: at, frames: 1_024)
        }
        for _ in 0..<10 { r.sent(startFrame: capture, frames: 1_024); capture += 1_024 }
        #expect(r.serverFrames == 20 * 1_024)
        // Server offset 500 ms (12 000 frames) is 1 760 frames into the first chunk
        // fed after the congestion, which starts at capture frame 244 x 1024.
        let want: Int64 = 244 * 1_024 + (12_000 - 10_240)
        #expect(r.captureFrame(serverMs: 500) == want)
        #expect(r.captureFrame(serverMs: 400) == 9_600)       // before it: untouched
    }

    /// Review fix 4: the session switched sessions while chunks were still on the
    /// way; the app sees `.uplinkOrigin` only after feeding them. They are on the
    /// new timeline, and audio before the origin is not.
    @Test func theOriginRebasesAudioFedBeforeTheEvent() {
        var m = UplinkMap()
        m.sent(startFrame: 0, frames: 4_800)                  // old session
        m.sent(startFrame: 4_800, frames: 2_400)              // already on the new one
        m.sent(startFrame: 7_200, frames: 2_400)
        m.reset(originFeedFrame: 4_800)
        #expect(m.serverFrames == 4_800)
        #expect(m.captureFrame(serverMs: 0) == 4_800)
        #expect(m.captureFrame(serverMs: 150) == 8_400)
        m.dropped(atFeedFrame: 0, frames: 2_400)              // late report from the old session: no-op
        #expect(m.captureFrame(serverMs: 0) == 4_800)
        m.dropped(atFeedFrame: 4_000, frames: 2_400)          // straddles the origin: only its part after
        #expect(m.captureFrame(serverMs: 0) == 6_400)
        #expect(m.serverFrames == 3_200)
        m.reset()                                             // next session starts with the next chunk
        #expect(m.captureFrame(serverMs: 0) == nil)
        m.sent(startFrame: 9_600, frames: 480)
        #expect(m.captureFrame(serverMs: 0) == 9_600)
    }
}

@Suite(.serialized) struct Stage2bLoopTests {
    func answer(_ rig: LoopRig, effort: String? = nil) async throws {
        rig.push(Srv.speechStarted("item_u1", ms: 100), Srv.speechStopped("item_u1", ms: 200), Srv.committed("item_u1"))
        _ = await rig.brain.wait { if case .session(.userCommitted) = $0 { true } else { false } }
        _ = try await rig.voice.respond(reasoningEffort: effort)
        #expect(await rig.waitSent("response.create"))
    }

    func clips(_ list: [VoiceClip]) async throws -> (ClipCache, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dee-clips-\(UUID().uuidString)")
        var config = ClipCache.Configuration(directory: dir)
        config.clips = list
        let cache = ClipCache(configuration: config, key: { "sk-test-key-0123456789" }, fetch: FakeSpeechServer().fetch)
        #expect(await cache.prepare().rendered.count == list.count)
        return (cache, dir)
    }

    var uplinkMs: (LoopRig) -> Int { { $0.uplink().count / 24 } }

    /// 1. `respond(reasoningEffort:)` reaches `response.reasoning.effort`.
    @Test func respondCarriesItsReasoningEffort() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.2)
        try await answer(rig, effort: "high")
        let create = try #require(rig.sent("response.create").last)
        let response = create["response"] as? [String: Any]
        #expect((response?["reasoning"] as? [String: Any])?["effort"] as? String == "high")
        rig.voice.shutdown()
    }

    /// 2. Dee laughs at the joke while Dee's reply is generated; the laugh's echo
    /// opens a server item. The session counts the clip as Dee's voice: the reply
    /// is not preempted, and it plays.
    @Test func herLaughsEchoDoesNotPreemptTheReply() async throws {
        let (cache, dir) = try await clips([.laugh1])
        defer { try? FileManager.default.removeItem(at: dir) }
        let rig = try LoopRig(clips: cache)
        try await rig.start()
        try rig.quiet(0.3)
        try await answer(rig)
        #expect(rig.voice.play(.laugh1, deferWhileUserSpeaks: false))
        await rig.settle()
        try rig.quiet(0.1)
        rig.push(Srv.responseCreated("resp_1"), Srv.speechStarted("item_e", ms: uplinkMs(rig)))
        await rig.settle()
        try rig.quiet(0.2)
        await rig.settle()
        #expect(rig.sent("response.cancel").isEmpty, "Dee's laugh's echo preempted the reply")
        #expect(rig.brainSession { if case .replyPreempted = $0 { true } else { false } }.isEmpty)
        rig.reply("resp_1", "item_a1", ms: 400)
        rig.push(Srv.responseDone("resp_1"))
        await rig.settle()
        let start = rig.output.count
        try rig.quiet(1.0)
        #expect(rig.audibleMs(fromSample: start) > 300)
        rig.voice.shutdown()
    }

    /// 2. Once the laugh and its echo tail are over, the session hears it.
    @Test func afterTheLaughsTailSpeechPreemptsAgain() async throws {
        let (cache, dir) = try await clips([.giggle])
        defer { try? FileManager.default.removeItem(at: dir) }
        let rig = try LoopRig(clips: cache)
        try await rig.start()
        try rig.quiet(0.3)
        #expect(rig.voice.play(.giggle, deferWhileUserSpeaks: false))
        try rig.quiet(0.6)                                   // 400 ms giggle
        try rig.quiet(EarCore.echoTail + 0.2)
        await rig.settle()
        try await answer(rig)
        rig.push(Srv.responseCreated("resp_1"), Srv.speechStarted("item_u2", ms: uplinkMs(rig)))
        #expect(await rig.waitSent("response.cancel"))
        rig.voice.shutdown()
    }

    /// 3. The user barges in while Dee's reply plays and a tool follow-up is queued
    /// behind it: the server keeps what was heard of the first and nothing of the
    /// second, and the follow-up is cancelled.
    @Test func bargeInCutsTheQueuedFollowUpToo() async throws {
        let rig = try LoopRig()
        await rig.session.setToolHandler { _ in RealtimeToolResult(output: "{}", followUp: .always) }
        try await rig.start()
        try rig.quiet(0.3)
        try await answer(rig)
        rig.push(Srv.responseCreated("resp_1"))
        rig.reply("resp_1", "item_a1", ms: 1500)
        rig.push(.outputItemAdded(.init(eventID: "ev_f1", responseID: "resp_1", item: RealtimeItem(
                    id: "item_f1", type: "function_call", status: "in_progress", name: "recall"))),
                 .functionCallArgumentsDone(.init(responseID: "resp_1", itemID: "item_f1", callID: "call_1",
                                                  name: "recall", arguments: "{}")),
                 Srv.responseDone("resp_1"))
        #expect(await rig.waitSent("response.create", count: 2))   // the follow-up
        rig.push(Srv.responseCreated("resp_2"))
        rig.reply("resp_2", "item_a2", ms: 800)                    // queued behind item_a1; still generating
        await rig.settle()
        try rig.quiet(0.5)
        try rig.talk(0.15)
        rig.push(Srv.speechStarted("item_u2", ms: uplinkMs(rig)))
        await rig.settle()
        try rig.talk(0.3)
        #expect(rig.voice.floorHold?.itemID == "item_u2")             // paused: their words decide
        rig.push(Srv.speechStopped("item_u2", ms: uplinkMs(rig)), Srv.committed("item_u2"),
                 Srv.userTranscript("item_u2", "Hang on, what about tomorrow?"))
        await rig.settle()
        try rig.quiet(CloudVoice.holdAfterWords + 0.1)                 // no brain to answer: the voice ends it
        _ = await rig.events.wait { $0 == .bargeIn }
        #expect(await rig.waitSent("conversation.item.truncate", count: 2))
        try rig.quiet(0.06)                                            // the player reports the cut item
        let truncates = rig.sent("conversation.item.truncate").map {
            "\($0["item_id"] as? String ?? "?")@\($0["audio_end_ms"] as? Int ?? -1)"
        }
        let played = try #require(rig.brain.all.compactMap { e -> Int? in
            if case .itemPlayed("item_a1", let ms, true) = e { ms } else { nil }
        }.first)
        #expect(truncates == ["item_a1@\(played)", "item_a2@0"], "\(truncates)")
        #expect(played > 400 && played < 1300, "\(played)")
        #expect(rig.sent("response.cancel").count == 1)
        let turns = await rig.session.recentTurns
        #expect(!turns.contains { $0.itemID == "item_a2" })
        rig.voice.shutdown()
    }

    /// 5. A quick answer in Dee's echo tail is accepted as the user: the session is
    /// told, so a tool follow-up whose result lands meanwhile waits instead of
    /// talking over them.
    @Test func anAcceptedTailAnswerHoldsTheFollowUp() async throws {
        let release = Mutex(false)
        let rig = try LoopRig()
        await rig.session.setToolHandler { _ in
            while !release.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(2)) }
            return RealtimeToolResult(output: "{}", followUp: .always)
        }
        try await rig.start()
        try rig.quiet(0.3)
        try await answer(rig)
        rig.push(Srv.responseCreated("resp_1"))
        rig.reply("resp_1", "item_a1", ms: 300)
        rig.push(.outputItemAdded(.init(eventID: "ev_f1", responseID: "resp_1", item: RealtimeItem(
                    id: "item_f1", type: "function_call", status: "in_progress", name: "recall"))),
                 .functionCallArgumentsDone(.init(responseID: "resp_1", itemID: "item_f1", callID: "call_1",
                                                  name: "recall", arguments: "{}")),
                 Srv.responseDone("resp_1"))
        await rig.settle()
        try rig.quiet(0.4)                                   // played out; Dee's tail is in the room
        try rig.talk(0.1)
        rig.push(Srv.speechStarted("item_u2", ms: uplinkMs(rig) - 100))
        await rig.settle()
        try rig.talk(0.25)
        let accepted = await rig.brain.wait { if case .session(.userSpeechStarted("item_u2", _)) = $0 { true } else { false } }
        try #require(accepted != nil, "the tail answer was not accepted")
        await rig.settle()
        release.withLock { $0 = true }
        #expect(await rig.waitSent("conversation.item.create"))   // the tool output
        await rig.settle()
        #expect(rig.sent("response.create").count == 1, "a follow-up started over the user")
        rig.voice.shutdown()
    }

    /// Review fix 3: the user talks over Dee's laugh (it stops) while the reply to
    /// their last turn is being generated. Their next onset lands inside the
    /// laugh's echo window; the ear does not hold it (the laugh was cut), so it
    /// is the user, and the session is told: the reply without audio yields.
    @Test func anOnsetRightAfterACutLaughIsTheUser() async throws {
        let (cache, dir) = try await clips([.laugh1])
        defer { try? FileManager.default.removeItem(at: dir) }
        let rig = try LoopRig(clips: cache)
        try await rig.start()
        try rig.quiet(0.3)
        try await answer(rig)                                // the reply is being generated…
        rig.push(Srv.responseCreated("resp_1"))
        #expect(rig.voice.play(.laugh1, deferWhileUserSpeaks: false))   // …while Dee laughs
        try rig.quiet(0.1)
        try rig.talk(0.5)                                    // the user talks over the laugh
        _ = await rig.brain.wait { $0 == .clipPlayed(.laugh1, cut: true) }
        await rig.settle()
        #expect(rig.sent("response.cancel").isEmpty)
        rig.push(Srv.speechStarted("item_u2", ms: uplinkMs(rig) - 300))
        await rig.settle()
        let seen = await rig.brain.wait { if case .session(.userSpeechStarted("item_u2", _)) = $0 { true } else { false } }
        #expect(seen != nil)
        #expect(await rig.waitSent("response.cancel"), "the reply talked over the user")
        rig.voice.shutdown()
    }

    /// 6. The uplink was congested and the session dropped 600 ms: the user's turn
    /// after it still maps onto the right capture audio (its prosody is theirs).
    @Test func droppedUplinkAudioKeepsTheMapExact() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        await rig.settle()
        rig.socket.setPendingBytes(10_000_000)
        try rig.quiet(0.6)
        await rig.settle()
        rig.socket.setPendingBytes(0)
        try rig.quiet(0.2)
        try rig.talk(0.5)
        try rig.quiet(0.3)
        await rig.settle()
        let span = try #require(rig.voicedSpan())
        #expect(rig.timeline.turns().flatMap(\.marks).contains { $0.detail?.hasPrefix("uplink dropped") == true })
        rig.push(Srv.speechStarted("item_u1", ms: span.start), Srv.speechStopped("item_u1", ms: span.end),
                 Srv.committed("item_u1"), Srv.userTranscript("item_u1", "Hello there."))
        let heard = await rig.events.wait { if case .heard = $0 { true } else { false } }
        guard case .heard(let u)? = heard else { Issue.record("no heard"); return }
        #expect(abs(u.duration - 0.5) < 0.15, "\(u.duration)")
        #expect(abs(u.prosody.meanPitchHz - 180) < 20, "\(u.prosody.meanPitchHz)")
        #expect(u.prosody.loudnessDB > -24, "\(u.prosody.loudnessDB)")
        rig.voice.shutdown()
    }
}
