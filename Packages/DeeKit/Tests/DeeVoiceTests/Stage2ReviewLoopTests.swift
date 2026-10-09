import DeeRealtime
import Foundation
import Testing
@testable import DeeVoice

// Stage-2 review fixes, on the full offline loop (manual AudioGraph, real
// RealtimeSession, scripted FakeSocket).

@Suite(.serialized) struct Stage2ReviewLoopTests {
    /// Answers item_u1 and waits until the request went out.
    func answer(_ rig: LoopRig) async throws {
        rig.push(Srv.speechStarted("item_u1", ms: 100), Srv.speechStopped("item_u1", ms: 200), Srv.committed("item_u1"))
        _ = await rig.brain.wait { if case .session(.userCommitted) = $0 { true } else { false } }
        _ = try await rig.voice.respond()
        #expect(await rig.waitSent("response.create"))
    }

    func finished(_ rig: LoopRig) -> [String] {
        rig.brain.all.compactMap { e -> String? in
            if case .sentenceFinished(_, _, let text, let heard) = e { "\(text)=\(heard)" } else { nil }
        }
    }

    func clips(_ list: [VoiceClip]) async throws -> (ClipCache, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dee-clips-\(UUID().uuidString)")
        var config = ClipCache.Configuration(directory: dir)
        config.clips = list
        let cache = ClipCache(configuration: config, key: { "sk-test-key-0123456789" }, fetch: FakeSpeechServer().fetch)
        #expect(await cache.prepare().rendered.count == list.count)
        return (cache, dir)
    }

    /// 3. The socket drops mid-reply: the transcript ran ahead of the audio, and
    /// only what was played counts as said.
    @Test func aDroppedReplyOnlyClaimsWhatWasPlayed() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        try await answer(rig)
        rig.push(Srv.responseCreated("resp_1"))
        rig.reply("resp_1", "item_a1", ms: 400, done: false)
        rig.push(Srv.transcript("resp_1", "item_a1", "Okay. "),
                 Srv.transcript("resp_1", "item_a1", "I will tell you a long secret about the moon. "),
                 Srv.transcript("resp_1", "item_a1", "It is made of cheese. "))
        await rig.settle()
        try rig.quiet(0.2)
        rig.socket.drop()
        await rig.settle()
        try rig.quiet(1.0)
        await rig.settle()
        let fin = finished(rig)
        #expect(fin.contains("Okay.=true"), "\(fin)")
        #expect(!fin.contains("I will tell you a long secret about the moon.=true"), "\(fin)")
        #expect(!fin.contains("It is made of cheese.=true"), "\(fin)")
        let played = rig.brain.all.compactMap { e -> (Int, Bool)? in
            if case .itemPlayed("item_a1", let ms, let cut) = e { (ms, cut) } else { nil }
        }
        #expect(played.count == 1 && played[0].1, "an abnormal end reads as a cut")
        #expect(abs((played.first?.0 ?? 0) - 400) <= 25)
        rig.voice.shutdown()
    }

    /// 3. A response that fails (or is filtered) after its audio arrived: the same.
    @Test func aFailedReplyOnlyClaimsWhatWasPlayed() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        try await answer(rig)
        rig.push(Srv.responseCreated("resp_1"))
        rig.reply("resp_1", "item_a1", ms: 400, done: false)
        // The last sentence is flushed by the session at `response.done`, placed at
        // the speaking rate (stage 2b), not squeezed into the audio received.
        rig.push(Srv.transcript("resp_1", "item_a1", "Okay. "),
                 Srv.transcript("resp_1", "item_a1", "I will tell you a long secret about the moon. "),
                 Srv.transcript("resp_1", "item_a1", "It is made of"),
                 Srv.responseDone("resp_1", status: "incomplete", reason: "content_filter"))
        await rig.settle()
        try rig.quiet(1.0)
        await rig.settle()
        let fin = finished(rig)
        #expect(fin.contains("Okay.=true"), "\(fin)")
        #expect(!fin.contains("I will tell you a long secret about the moon.=true"), "\(fin)")
        #expect(!fin.contains("It is made of=true"), "\(fin)")
        let turns = await rig.session.recentTurns.filter { $0.role == .assistant }.map(\.text)
        #expect(turns == ["Okay."], "\(turns)")
        rig.voice.shutdown()
    }

    /// 3. A normally completed reply still reports all of its sentences, even one
    /// whose hint ran past the audio.
    @Test func aCompletedReplyClaimsEverySentence() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        try await answer(rig)
        rig.push(Srv.responseCreated("resp_1"))
        rig.reply("resp_1", "item_a1", ms: 500)
        rig.push(Srv.transcript("resp_1", "item_a1", "Sure. "), Srv.transcript("resp_1", "item_a1", "Here you go."),
                 Srv.transcriptDone("resp_1", "item_a1", "Sure. Here you go."), Srv.responseDone("resp_1"))
        await rig.settle()
        try rig.quiet(1.0)
        await rig.settle()
        #expect(finished(rig) == ["Sure.=true", "Here you go.=true"])
        #expect(rig.brain.all.contains(.itemPlayed(itemID: "item_a1", playedMs: 500, cut: false)))
        rig.voice.shutdown()
    }

    /// 4. Her echo tail after a reply: the session still counts her as playing, so
    /// an echo onset there neither preempts the next reply nor reaches the brain.
    @Test func echoInHerTailDoesNotPreemptTheNextReply() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        try await answer(rig)
        rig.push(Srv.responseCreated("resp_1"))
        rig.reply("resp_1", "item_a1", ms: 300)
        rig.push(Srv.responseDone("resp_1"))
        await rig.settle()
        let listening = { rig.brainSession { $0 == .stateChanged(.listening) }.count }
        let before = listening()
        try rig.quiet(0.4)                            // played out; her echo is still in the room
        _ = await rig.events.wait { $0 == .speakingFinished }
        await rig.settle()
        #expect(listening() == before, "the session was told she stopped while her echo was in the room")
        // The brain asks for a follow-up; her echo opens a server item meanwhile.
        _ = try await rig.voice.respond()
        #expect(await rig.waitSent("response.create", count: 2))
        rig.push(Srv.speechStarted("item_e", ms: 600))
        await rig.settle()
        try rig.talk(0.1, amplitude: 0.005, hz: 300)
        try rig.quiet(0.2)
        rig.push(Srv.speechStopped("item_e", ms: 900), Srv.committed("item_e"))
        #expect(await rig.waitSent("conversation.item.delete"))
        await rig.settle()
        #expect(rig.sent("response.cancel").isEmpty, "the pending reply was preempted by her echo")
        #expect(rig.brainSession { if case .replyPreempted = $0 { true } else { false } }.isEmpty)
        #expect(rig.brainSession {
            switch $0 {
            case .echoRejected, .userSpeechStarted("item_e", _), .userCommitted("item_e", _): true
            default: false
            }
        }.isEmpty)
        rig.voice.shutdown()
    }

    /// 4. The session hears `playbackFinished` once her echo tail has passed.
    @Test func theSessionHearsSheStoppedAfterHerTail() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        try await answer(rig)
        rig.push(Srv.responseCreated("resp_1"))
        rig.reply("resp_1", "item_a1", ms: 300)
        rig.push(Srv.responseDone("resp_1"))
        await rig.settle()
        let listening = { rig.brainSession { $0 == .stateChanged(.listening) }.count }
        let before = listening()
        try rig.quiet(0.5)
        await rig.settle()
        #expect(listening() == before)
        try rig.quiet(EarCore.echoTail + 0.1)
        #expect(await rig.brain.wait { _ in listening() == before + 1 } != nil)
        rig.voice.shutdown()
    }

    /// 4. No initiative inside her echo tail; no clip while an initiative is on its way.
    @Test func initiativesAndClipsKeepClearOfEachOthersEcho() async throws {
        let (cache, dir) = try await clips([.giggle])
        defer { try? FileManager.default.removeItem(at: dir) }
        let rig = try LoopRig(clips: cache)
        try await rig.start()
        try rig.quiet(0.3)
        #expect(rig.voice.play(.giggle, deferWhileUserSpeaks: false))
        try rig.quiet(0.5)
        _ = await rig.events.wait { $0 == .speakingFinished }
        #expect(await rig.voice.initiative(instructions: "x") == .refused(.speaking))   // her laugh's tail
        try rig.quiet(EarCore.echoTail + 0.1)
        #expect(await rig.voice.initiative(instructions: "Say something about the lamp.") == .sent)
        #expect(!rig.voice.play(.giggle, deferWhileUserSpeaks: false))
        rig.voice.shutdown()
    }

    /// 6. A phone call while her reply is still being generated: it never plays
    /// after the call.
    @Test func anInterruptionBeforeTheFirstAudioCancelsTheReply() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        try await answer(rig)
        rig.push(Srv.responseCreated("resp_1"))
        await rig.settle()
        rig.graph.interrupted("Audio was interrupted.", cutStream: true)
        #expect(await rig.waitSent("response.cancel"))
        // Audio that was already on the way arrives during (or after) the call.
        rig.reply("resp_1", "item_a1", ms: 500)
        rig.push(Srv.responseDone("resp_1", status: "cancelled", reason: "client_cancelled"))
        await rig.settle()
        let start = rig.output.count
        try rig.quiet(0.8)
        #expect(rig.audibleMs(fromSample: start) == 0)
        #expect(!rig.voiceEvents.contains(.speakingStarted))
        rig.voice.shutdown()
    }

    /// 7. `stopClip` stops her laugh and leaves the reply that is on its way alone.
    @Test func stopClipLeavesTheReplyAlone() async throws {
        let (cache, dir) = try await clips([.laugh1])
        defer { try? FileManager.default.removeItem(at: dir) }
        let rig = try LoopRig(clips: cache)
        try await rig.start()
        try rig.quiet(0.3)
        try await answer(rig)                        // the reply is being generated…
        #expect(rig.voice.play(.laugh1, deferWhileUserSpeaks: false))   // …while she laughs at the joke
        try rig.quiet(0.1)
        #expect(rig.voice.stopClip())
        try rig.quiet(0.05)
        _ = await rig.brain.wait { $0 == .clipPlayed(.laugh1, cut: true) }
        await rig.settle()
        #expect(rig.sent("response.cancel").isEmpty)
        // The reply plays normally.
        rig.push(Srv.responseCreated("resp_1"))
        rig.reply("resp_1", "item_a1", ms: 400)
        rig.push(Srv.responseDone("resp_1"))
        await rig.settle()
        let start = rig.output.count
        try rig.quiet(0.2)
        #expect(!rig.voice.stopClip())                // nothing but her reply: left alone
        try rig.quiet(0.5)
        #expect(abs(rig.audibleMs(fromSample: start) - 400) < 40)
        rig.voice.shutdown()
    }
}
