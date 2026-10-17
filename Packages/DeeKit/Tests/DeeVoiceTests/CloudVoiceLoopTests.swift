import AVFAudio
import DeeCore
import DeeRealtime
import Foundation
import Synchronization
import Testing
@testable import DeeVoice

// The whole voice loop offline: the real AudioGraph in manual rendering (mic
// injected at the tap point, Dee's output rendered faster than real time), the
// real RealtimeSession, and a scripted server on a FakeSocket.

/// Collects an async stream; lets a test wait for an element.
final class Collector<T: Sendable>: @unchecked Sendable {
    private let items = Mutex<[T]>([])
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<T>) {
        task = Task { [weak self] in
            for await e in stream { self?.items.withLock { $0.append(e) } }
        }
    }

    deinit { task?.cancel() }

    var all: [T] { items.withLock { $0 } }

    @discardableResult
    func wait(timeout: Double = 3, _ match: (T) -> Bool) async -> T? {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if let e = all.first(where: match) { return e }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }
}

/// Server events, briefly (GA shapes).
enum Srv {
    static func speechStarted(_ item: String, ms: Int) -> ServerEvent {
        .speechStarted(.init(eventID: "ev_ss_\(item)", audioStartMs: ms, itemID: item))
    }
    static func speechStopped(_ item: String, ms: Int) -> ServerEvent {
        .speechStopped(.init(eventID: "ev_sp_\(item)", audioEndMs: ms, itemID: item))
    }
    static func committed(_ item: String) -> ServerEvent {
        .inputAudioCommitted(.init(eventID: "ev_c_\(item)", previousItemID: nil, itemID: item))
    }
    static func userTranscript(_ item: String, _ text: String) -> ServerEvent {
        .inputTranscriptionCompleted(.init(eventID: "ev_t_\(item)", itemID: item, transcript: text))
    }
    static func responseCreated(_ id: String) -> ServerEvent {
        .responseCreated(.init(eventID: "ev_rc_\(id)", response: ResponseObject(
            id: id, object: "realtime.response", status: "in_progress", output: [])))
    }
    static func messageAdded(_ resp: String, _ item: String) -> ServerEvent {
        .outputItemAdded(.init(eventID: "ev_oa_\(item)", responseID: resp, item: RealtimeItem(
            id: item, object: "realtime.item", type: "message", status: "in_progress", role: "assistant", content: [])))
    }
    static func audio(_ resp: String, _ item: String, _ pcm: Data) -> ServerEvent {
        .outputAudioDelta(.init(responseID: resp, itemID: item, delta: pcm.base64EncodedString()))
    }
    static func audioDone(_ resp: String, _ item: String) -> ServerEvent {
        .outputAudioDone(.init(responseID: resp, itemID: item))
    }
    static func transcript(_ resp: String, _ item: String, _ delta: String) -> ServerEvent {
        .outputAudioTranscriptDelta(.init(responseID: resp, itemID: item, delta: delta))
    }
    static func transcriptDone(_ resp: String, _ item: String, _ text: String) -> ServerEvent {
        .outputAudioTranscriptDone(.init(responseID: resp, itemID: item, text: text))
    }
    static func responseDone(_ id: String, status: String = "completed", reason: String? = nil) -> ServerEvent {
        .responseDone(.init(eventID: "ev_rd_\(id)", response: ResponseObject(
            id: id, object: "realtime.response", status: status,
            statusDetails: reason.flatMap { details(status, $0) }, output: [])))
    }
    /// `status_details` (no public memberwise init: decoded like the wire).
    static func details(_ type: String, _ reason: String) -> ResponseStatusDetails? {
        try? JSONDecoder().decode(ResponseStatusDetails.self, from: Data(#"{"type":"\#(type)","reason":"\#(reason)"}"#.utf8))
    }
}

/// CloudVoice on a manual graph, a real session and fake sockets.
final class LoopRig: @unchecked Sendable {
    let graph: AudioGraph
    let factory: FakeSocketFactory
    let clock = ManualRealtimeClock()
    let session: RealtimeSession
    let voice: CloudVoice
    let events: Collector<VoiceEvent>
    let brain: Collector<CloudVoice.BrainEvent>
    let timeline = TurnTimeline()
    private let state = Mutex<(output: [Float], noise: UInt64)>(([], 1))
    static let rate = 48_000.0

    init(sockets: [FakeSocket] = [], clips: ClipCache? = nil, retryDelay: Double = 0.02,
         speculativeMax: Double = CloudVoice.speculativeMax) throws {
        graph = try AudioGraph.manual(sampleRate: Self.rate, channels: 1)
        factory = FakeSocketFactory(sockets) { FakeSocket(request: $0, sessionID: "sess_\(Int.random(in: 1000...9999))") }
        var config = RealtimeSessionConfig()
        config.instructions = "You are Dee."
        session = RealtimeSession(config: config,
                                  credentials: { _ in .ephemeral("ek_test", expiresAt: Date().addingTimeInterval(600)) },
                                  socketFactory: factory.factory, clock: clock)
        var c = CloudVoice.Configuration()
        c.speculativeMax = speculativeMax
        c.autoTick = false
        c.classifySounds = false
        c.connectRetryDelays = [retryDelay]
        voice = CloudVoice(session: session, graph: graph, clips: clips, timeline: timeline, configuration: c)
        events = Collector(voice.events)
        brain = Collector(voice.brainEvents)
    }

    var socket: FakeSocket { factory.made.last! }
    var output: [Float] { state.withLock { $0.output } }

    /// Starts and waits until connected.
    func start() async throws {
        await voice.start()
        // Generous: the heavy room simulations run in parallel with these.
        let ok = await brain.wait(timeout: 15) { if case .session(.connected) = $0 { true } else { false } }
        try #require(ok != nil, "never connected")
    }

    /// 20 ms: `mic` (48 kHz; room noise when nil) at the tap point, 20 ms of output, housekeeping.
    func step(_ mic: [Float]? = nil) throws {
        let n = Int(Self.rate * 0.02)
        let samples = mic ?? state.withLock { s -> [Float] in
            s.noise += 1
            return Signal.noise(amplitude: 0.001, count: n, seed: s.noise)
        }
        graph.inject(PCMTone.buffer(samples, rate: Self.rate))
        let out = try graph.render(frames: AVAudioFrameCount(n))
        let rendered = out.firstChannelSamples()
        state.withLock { $0.output += rendered }
        voice.tick()
    }

    func quiet(_ seconds: Double) throws {
        for _ in 0..<Int((seconds / 0.02).rounded()) { try step() }
    }

    /// The user talking (harmonic voice; `amplitude` 0.3 ≈ −18 dBFS).
    func talk(_ seconds: Double, amplitude: Double = 0.3, hz: Double = 180) throws {
        let x = Signal.harmonic(hz: hz, amplitude: amplitude, sampleRate: Self.rate, seconds: seconds)
        for f in Signal.frames(x, size: Int(Self.rate * 0.02)) { try step(f) }
    }

    func push(_ events: ServerEvent...) { events.forEach { socket.push($0) } }

    /// Every client frame of `type` on `socket`, as JSON.
    func sent(_ type: String, on s: FakeSocket? = nil) -> [[String: Any]] {
        (s ?? socket).sent.compactMap { text -> [String: Any]? in
            guard let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  o["type"] as? String == type else { return nil }
            return o
        }
    }

    /// The microphone audio the server received on `s`, decoded.
    func uplink(on s: FakeSocket? = nil) -> [Int16] {
        sent("input_audio_buffer.append", on: s).flatMap { o -> [Int16] in
            guard let b = o["audio"] as? String, let d = Data(base64Encoded: b) else { return [] }
            return PCM16.samples(d)
        }
    }

    /// Waits until the server got at least `ms` of microphone audio on `s`.
    func waitUplink(ms: Double, on s: FakeSocket? = nil) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if Double(uplink(on: s).count) / 24 >= ms { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return false
    }

    /// Lets the session and the voice handle everything pushed so far.
    func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(15))
    }

    func waitSent(_ type: String, count: Int = 1) async -> Bool {
        await socket.waitForSent(type: type, count: count, timeout: 3)
    }

    var voiceEvents: [VoiceEvent] { events.all }

    /// Speaking events only (no levels), in order.
    var speakingTrail: [VoiceEvent] {
        events.all.filter {
            switch $0 {
            case .speakingStarted, .speakingFinished, .bargeIn: true
            default: false
            }
        }
    }

    func brainSession(_ match: (RealtimeEvent) -> Bool) -> [RealtimeEvent] {
        brain.all.compactMap { if case .session(let e) = $0, match(e) { e } else { nil } }
    }

    /// Ms into the server's input audio where the user's voice starts / ends (as a VAD would).
    func voicedSpan(on s: FakeSocket? = nil) -> (start: Int, end: Int)? {
        let pcm = uplink(on: s)
        guard let a = pcm.firstIndex(where: { abs(Int($0)) > 3000 }),
              let b = pcm.lastIndex(where: { abs(Int($0)) > 3000 }) else { return nil }
        return (a / 24, b / 24)
    }

    /// Dee's reply: `ms` of tone in 100 ms deltas.
    func reply(_ resp: String, _ item: String, ms: Int, done: Bool = true) {
        push(Srv.messageAdded(resp, item))
        var left = ms
        while left > 0 {
            let k = min(100, left)
            push(Srv.audio(resp, item, PCMTone.data(ms: Double(k), hz: 440, amplitude: 0.3)))
            left -= k
        }
        if done { push(Srv.audioDone(resp, item)) }
    }

    func audibleMs(fromSample start: Int) -> Double {
        let out = output
        guard start < out.count else { return 0 }
        return Double(out[start...].filter { abs($0) > 0.02 }.count) / Self.rate * 1000
    }
}

@Suite(.serialized) struct CloudVoiceLoopTests {
    /// A user turn goes up with its pre-roll, is heard with prosody, answered,
    /// played, and every event arrives in order.
    @Test func normalTurn() async throws {
        // The first connection attempt fails, so the user's first words are spoken
        // while offline and must still reach the server (the pre-roll).
        let rig = try LoopRig(sockets: [FakeSocket(openFailure: .network("offline"))], retryDelay: 0.5)
        await rig.voice.start()
        try rig.quiet(0.2)
        try rig.talk(0.6)
        try rig.quiet(0.3)
        // Tune 11 review: waited on the event, not on 3 s of wall clock (the reconnect lags
        // under full-suite load: flaked at 89d0c0f too).
        let connected = await rig.brain.wait(timeout: 20) { if case .session(.connected) = $0 { true } else { false } }
        try #require(connected != nil)
        #expect(rig.voiceEvents.prefix(2) == [.permission(microphone: true, speech: true), .ready])
        #expect(await rig.events.wait { $0 == .listening(true) } != nil)
        try rig.quiet(0.2)
        #expect(await rig.waitUplink(ms: 1000))
        let span = try #require(rig.voicedSpan(), "the words spoken offline never reached the server")
        #expect(span.end - span.start > 550)

        // The server's VAD and transcription.
        rig.push(Srv.speechStarted("item_u1", ms: span.start), Srv.speechStopped("item_u1", ms: span.end),
                 Srv.committed("item_u1"), Srv.userTranscript("item_u1", "Hi Dee, how are you?"))
        let heard = await rig.events.wait { if case .heard = $0 { true } else { false } }
        guard case .heard(let u)? = heard else { Issue.record("no heard"); return }
        #expect(u.text == "Hi Dee, how are you?")
        #expect(abs(u.duration - 0.6) < 0.2, "\(u.duration)")
        #expect(abs(u.prosody.meanPitchHz - 180) < 20, "\(u.prosody.meanPitchHz)")
        #expect(u.prosody.loudnessDB > -24, "\(u.prosody.loudnessDB)")
        #expect(rig.brainSession { if case .userCommitted("item_u1", _) = $0 { true } else { false } }.count == 1)

        // The brain answers.
        let outcome = try await rig.voice.respond(cue: "<dee_state>happy</dee_state>")
        #expect(outcome == .sent)
        #expect(await rig.waitSent("response.create"))
        rig.push(Srv.responseCreated("resp_1"))
        rig.reply("resp_1", "item_a1", ms: 600)
        rig.push(Srv.transcript("resp_1", "item_a1", "I'm great. "), Srv.transcript("resp_1", "item_a1", "And you?"),
                 Srv.transcriptDone("resp_1", "item_a1", "I'm great. And you?"), Srv.responseDone("resp_1"))
        _ = await rig.brain.wait { if case .session(.responseDone) = $0 { true } else { false } }
        await rig.settle()
        let startSample = rig.output.count
        try rig.quiet(1.2)
        _ = await rig.events.wait { $0 == .speakingFinished }

        #expect(rig.speakingTrail == [.speakingStarted, .speakingFinished])
        let ev = rig.voiceEvents
        let s = try #require(ev.firstIndex(of: .speakingStarted))
        let f = try #require(ev.firstIndex(of: .speakingFinished))
        let levels = ev[s..<f].compactMap { if case .speechLevel(let l) = $0 { l } else { nil } }
        #expect(levels.count >= 15, "\(levels.count) levels over ~0.75 s")
        #expect(levels.contains { $0 > 0.3 })
        #expect(ev[f - 1] == .speechLevel(0))
        let played = rig.audibleMs(fromSample: startSample)
        #expect(abs(played - 600) < 40, "\(played)")

        // Dee's sentences, placed on what was played.
        let said = rig.brain.all.compactMap { e -> String? in
            if case .sentenceFinished(_, _, let text, true) = e { text } else { nil }
        }
        #expect(said == ["I'm great.", "And you?"])
        #expect(rig.brain.all.contains(.itemPlayed(itemID: "item_a1", playedMs: 600, cut: false)))
        // The session heard that playback finished: Dee has the floor no more.
        #expect(await rig.brain.wait { $0 == .session(.stateChanged(.listening)) } != nil)
        let marks = Set(rig.timeline.turns().last?.marks.map(\.stage) ?? [])
        #expect(marks.isSuperset(of: [.speechStopped, .committed, .transcript, .heard, .responseCreateSent,
                                      .responseCreated, .firstAudioDelta, .firstAudioPlayed, .speakingStarted,
                                      .speakingFinished, .responseDone]), "\(marks)")
        rig.voice.shutdown()
    }

    /// The user talks over Dee: Dee stops at once (paused until their words are
    /// known); their words are a real interruption, so the reply is cancelled and
    /// the server keeps exactly what was played; late audio never plays.
    @Test func bargeInTruncatesToWhatWasPlayed() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        rig.push(Srv.speechStarted("item_u1", ms: 100), Srv.speechStopped("item_u1", ms: 200), Srv.committed("item_u1"))
        _ = await rig.brain.wait { if case .session(.userCommitted) = $0 { true } else { false } }
        _ = try await rig.voice.respond()
        rig.push(Srv.responseCreated("resp_1"))
        rig.reply("resp_1", "item_a1", ms: 2000, done: false)     // still generating
        await rig.settle()
        try rig.quiet(0.6)
        // Tune 11 review: the event pump lags real time under full-suite load (trail was []).
        _ = await rig.events.wait(timeout: 20) { $0 == .speakingStarted }
        #expect(rig.speakingTrail == [.speakingStarted])

        // The user starts talking over Dee; the server notices a moment later.
        try rig.talk(0.15)
        rig.push(Srv.speechStarted("item_u2", ms: 900))
        await rig.settle()
        try rig.talk(0.3)
        // Silent at once, nothing cut yet: their words decide.
        #expect(rig.voice.floorHold?.itemID == "item_u2")
        let pausedAt = rig.output.count
        try rig.quiet(0.2)
        #expect(rig.audibleMs(fromSample: pausedAt) < 10)
        #expect(rig.sent("conversation.item.truncate").isEmpty)
        #expect(!rig.voiceEvents.contains(.bargeIn))
        rig.push(Srv.speechStopped("item_u2", ms: 1500), Srv.committed("item_u2"),
                 Srv.userTranscript("item_u2", "Wait, stop talking for a second."))
        await rig.settle()
        // No brain here to answer them: the voice ends Dee's reply itself.
        try rig.quiet(CloudVoice.holdAfterWords + 0.1)
        _ = await rig.events.wait { $0 == .bargeIn }
        #expect(await rig.waitSent("conversation.item.truncate"))
        #expect(rig.voice.floorHold == nil)
        try rig.quiet(0.06)                                            // the player reports the cut item
        let cut = try #require(rig.brain.all.compactMap { e -> Int? in
            if case .itemPlayed("item_a1", let ms, true) = e { ms } else { nil }
        }.first)
        let truncate = try #require(rig.sent("conversation.item.truncate").first)
        #expect(truncate["item_id"] as? String == "item_a1")
        #expect(truncate["audio_end_ms"] as? Int == cut)
        #expect(cut > 500 && cut < 1200, "\(cut)")
        #expect(rig.sent("response.cancel").count == 1)
        // The brain sees the user's onset (it was them), the face sees the barge-in.
        #expect(rig.brainSession { $0 == .userSpeechStarted(itemID: "item_u2", audioStartMs: 900) }.count == 1)
        #expect(rig.speakingTrail == [.speakingStarted, .bargeIn, .speakingFinished]
                || rig.speakingTrail == [.speakingStarted, .speakingFinished, .bargeIn])

        // Audio of the cancelled response still in flight is dropped.
        let after = rig.output.count
        rig.push(Srv.audio("resp_1", "item_a1", PCMTone.data(ms: 300)), Srv.responseDone("resp_1", status: "cancelled", reason: "client_cancelled"))
        await rig.settle()
        try rig.quiet(0.5)
        #expect(rig.audibleMs(fromSample: after) == 0)
        rig.voice.shutdown()
    }

    /// Dee's own echo trips the server's VAD: the item is deleted, nobody barges in,
    /// the brain never hears of it, and Dee keeps talking.
    @Test func echoIsRejectedAndPlaybackContinues() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        rig.push(Srv.speechStarted("item_u1", ms: 100), Srv.speechStopped("item_u1", ms: 200), Srv.committed("item_u1"))
        _ = await rig.brain.wait { if case .session(.userCommitted) = $0 { true } else { false } }
        _ = try await rig.voice.respond()
        rig.push(Srv.responseCreated("resp_1"))
        rig.reply("resp_1", "item_a1", ms: 1500)
        rig.push(Srv.responseDone("resp_1"))
        await rig.settle()
        let start = rig.output.count
        try rig.quiet(0.4)
        // Residual echo of Dee's voice in the mic; the server opens a "user" item on it.
        try rig.talk(0.1, amplitude: 0.01, hz: 300)
        rig.push(Srv.speechStarted("item_e", ms: 800))
        await rig.settle()
        try rig.talk(0.4, amplitude: 0.01, hz: 300)
        rig.push(Srv.speechStopped("item_e", ms: 1300), Srv.committed("item_e"))
        #expect(await rig.waitSent("conversation.item.delete"))
        #expect(rig.sent("conversation.item.delete").first?["item_id"] as? String == "item_e")
        try rig.quiet(1.0)
        _ = await rig.events.wait { $0 == .speakingFinished }
        #expect(rig.speakingTrail == [.speakingStarted, .speakingFinished])
        #expect(abs(rig.audibleMs(fromSample: start) - 1500) < 80)
        #expect(rig.sent("conversation.item.truncate").isEmpty)
        #expect(rig.brainSession {
            switch $0 {
            case .userSpeechStarted("item_e", _), .userSpeechStopped("item_e", _), .userCommitted("item_e", _): true
            default: false
            }
        }.isEmpty)
        rig.voice.shutdown()
    }

    /// Dee speaks first, but the user starts talking before Dee's first audio:
    /// the initiative is cancelled locally and never heard.
    @Test func initiativeCancelledByUserOnset() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.5)
        let o = await rig.voice.initiative(instructions: "Say one short thing about the lamp.")
        #expect(o == .sent)
        #expect(await rig.waitSent("response.create"))
        rig.push(Srv.responseCreated("resp_i"))
        await rig.settle()
        try rig.talk(0.3)
        #expect(await rig.waitSent("response.cancel"))
        // Dee's audio that was already on its way never plays.
        rig.reply("resp_i", "item_i", ms: 400)
        rig.push(Srv.responseDone("resp_i", status: "cancelled", reason: "client_cancelled"))
        await rig.settle()
        let start = rig.output.count
        try rig.quiet(0.6)
        #expect(rig.audibleMs(fromSample: start) == 0)
        #expect(!rig.voiceEvents.contains(.speakingStarted))
        #expect(rig.brainSession { if case .initiativeCancelled = $0 { true } else { false } }.count == 1)
        // And while the user talks a new initiative is refused outright.
        try rig.talk(0.1)
        #expect(await rig.voice.initiative(instructions: "x") == .refused(.userSpeaking))
        rig.voice.shutdown()
    }

    /// A phone call cuts Dee's reply: the server is told what was heard, but it is
    /// not a barge-in.
    @Test func playbackCutTruncates() async throws {
        let rig = try LoopRig()
        try await rig.start()
        rig.push(Srv.speechStarted("item_u1", ms: 100), Srv.speechStopped("item_u1", ms: 200), Srv.committed("item_u1"))
        _ = await rig.brain.wait { if case .session(.userCommitted) = $0 { true } else { false } }
        _ = try await rig.voice.respond()
        rig.push(Srv.responseCreated("resp_1"))
        rig.reply("resp_1", "item_a1", ms: 1500)
        await rig.settle()
        try rig.quiet(0.7)
        rig.graph.interrupted("Audio was interrupted.", cutStream: true)
        #expect(await rig.waitSent("conversation.item.truncate"))
        try rig.quiet(0.1)
        _ = await rig.events.wait { $0 == .speakingFinished }
        let cut = try #require(rig.brain.all.compactMap { e -> Int? in
            if case .itemPlayed("item_a1", let ms, true) = e { ms } else { nil }
        }.first)
        #expect(rig.sent("conversation.item.truncate").first?["audio_end_ms"] as? Int == cut)
        #expect(!rig.voiceEvents.contains(.bargeIn))
        #expect(rig.voiceEvents.contains(.error("Audio was interrupted.")))
        rig.voice.shutdown()
    }

    /// Clips play locally through the same player; never over Dee's reply.
    @Test func clipPlayback() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dee-clips-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var config = ClipCache.Configuration(directory: dir)
        config.clips = [.giggle, .sorryGoOn]
        let clips = ClipCache(configuration: config, key: { "sk-test-key-0123456789" }, fetch: FakeSpeechServer().fetch)
        #expect(await clips.prepare().rendered.count == 2)
        let rig = try LoopRig(clips: clips)
        #expect(!rig.voice.play(.giggle, deferWhileUserSpeaks: false))   // before start
        try await rig.start()
        try rig.quiet(0.2)
        #expect(rig.voice.play(.giggle, deferWhileUserSpeaks: false))
        #expect(!rig.voice.play(.oneSec, deferWhileUserSpeaks: false))   // not rendered
        let start = rig.output.count
        try rig.quiet(0.8)
        _ = await rig.events.wait { $0 == .speakingFinished }
        #expect(rig.speakingTrail == [.speakingStarted, .speakingFinished])
        #expect(abs(rig.audibleMs(fromSample: start) - 400) < 40)
        #expect(rig.brain.all.contains(.clipPlayed(.giggle, cut: false)))
        #expect(rig.socket.sentTypes.allSatisfy { $0 == "session.update" || $0 == "input_audio_buffer.append" })

        // While the user talks, a deferred clip is refused; a laugh is not deferred.
        try rig.talk(0.2)
        #expect(!rig.voice.play(.sorryGoOn, deferWhileUserSpeaks: true))

        // Never over Dee's reply.
        try rig.quiet(1.0)
        rig.push(Srv.speechStarted("item_u1", ms: 100), Srv.speechStopped("item_u1", ms: 200), Srv.committed("item_u1"))
        _ = await rig.brain.wait { if case .session(.userCommitted) = $0 { true } else { false } }
        _ = try await rig.voice.respond()
        rig.push(Srv.responseCreated("resp_1"))
        rig.reply("resp_1", "item_a1", ms: 800)
        await rig.settle()
        try rig.quiet(0.3)
        #expect(!rig.voice.play(.sorryGoOn, deferWhileUserSpeaks: false))
        rig.voice.shutdown()
    }

    /// The socket drops: listening goes off, the session reconnects, and the audio
    /// spoken during the gap reaches the new connection without a hole or a repeat.
    @Test func reconnectFillsTheGap() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.4)
        let first = rig.socket
        #expect(await rig.waitUplink(ms: 300, on: first))
        let before = rig.uplink(on: first).count
        first.drop()
        _ = await rig.events.wait { $0 == .listening(false) }
        let problem = await rig.brain.wait { if case .connection(.some) = $0 { true } else { false } }
        #expect(problem != nil)
        // The user talks while Dee is offline.
        try rig.talk(0.5)
        try rig.quiet(0.2)
        await rig.settle()
        rig.clock.advance(by: 1)                      // reconnect back-off
        let second = await rig.factory.waitForSocket(count: 2)
        try #require(second != nil)
        _ = await rig.brain.wait { $0 == .connection(nil) }
        for _ in 0..<1500 where rig.voiceEvents.filter({ $0 == .listening(true) }).count < 2 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(rig.voiceEvents.filter { $0 == .listening(true) }.count == 2)
        try rig.quiet(0.2)
        #expect(await rig.waitUplink(ms: 800, on: second!))
        // The gap's words are on the new connection.
        let span = try #require(rig.voicedSpan(on: second!))
        #expect(span.end - span.start > 450)
        // Nothing sent twice: old + new ≈ everything captured once.
        let total = before + rig.uplink(on: second!).count
        let captured = Int(rig.graph.capture.capturedFrames)
        #expect(total <= captured + 480, "\(total) sent of \(captured) captured")
        rig.voice.shutdown()
    }

    @Test func stopSpeakingCutsAndTellsTheServer() async throws {
        let rig = try LoopRig()
        try await rig.start()
        rig.push(Srv.speechStarted("item_u1", ms: 100), Srv.speechStopped("item_u1", ms: 200), Srv.committed("item_u1"))
        _ = await rig.brain.wait { if case .session(.userCommitted) = $0 { true } else { false } }
        _ = try await rig.voice.respond()
        rig.push(Srv.responseCreated("resp_1"))
        rig.reply("resp_1", "item_a1", ms: 1500, done: false)
        await rig.settle()
        try rig.quiet(0.5)
        rig.voice.stopSpeaking()
        #expect(await rig.waitSent("conversation.item.truncate"))
        #expect(rig.sent("response.cancel").count == 1)
        try rig.quiet(0.1)
        #expect(!rig.voiceEvents.contains(.bargeIn))
        #expect(rig.speakingTrail == [.speakingStarted, .speakingFinished])
        rig.voice.shutdown()
    }

    @Test func noKeyIsAVisibleSetupProblemAndNoRetryStorm() async throws {
        let graph = try AudioGraph.manual()
        let session = RealtimeSession(credentials: { _ in throw RealtimeSessionError.noKey })
        var c = CloudVoice.Configuration()
        c.autoTick = false
        c.classifySounds = false
        c.connectRetryDelays = [0.01]
        let voice = CloudVoice(session: session, graph: graph, timeline: TurnTimeline(), configuration: c)
        let brain = Collector(voice.brainEvents)
        let events = Collector(voice.events)
        await voice.start()
        let p = await brain.wait {
            if case .connection(let p?) = $0, case .cloudVoiceNeedsSetup = p { true } else { false }
        }
        #expect(p != nil)
        #expect(voice.problem?.needsUser == true)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(brain.all.filter { if case .connection = $0 { true } else { false } }.count == 1)
        #expect(!events.all.contains(.listening(true)))
        #expect(events.all.contains(.ready))                   // eyes and clips still work
        voice.shutdown()
    }

    @Test func worksThroughTheVoiceIOProtocol() async throws {
        var c = CloudVoice.Configuration()
        c.autoTick = false
        c.classifySounds = false
        let v: any VoiceIO = CloudVoice(session: RealtimeSession(credentials: { _ in throw RealtimeSessionError.noKey }),
                                        graph: try AudioGraph.manual(), timeline: TurnTimeline(), configuration: c)
        #expect(v.listeningEnabled)
        v.listeningEnabled = false
        #expect(!v.listeningEnabled)
        v.pauseScale = 1.3
        #expect(abs(v.pauseScale - 1.3) < 1e-9)
        #expect(!v.userIsSpeaking)
        v.laugh(intensity: 0.5, age: nil, energy: 0.7)          // no clips: nothing
        v.stopSpeaking()
        v.shutdown()
        v.shutdown()
        var seen: [VoiceEvent] = []
        for await e in v.events { seen.append(e) }
        #expect(!seen.contains(.speakingStarted))
    }
}
