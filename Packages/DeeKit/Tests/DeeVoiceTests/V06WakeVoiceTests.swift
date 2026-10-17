import AVFAudio
import DeeCore
import DeeRealtime
import Foundation
import Synchronization
import Testing
import DeeWake
@testable import DeeVoice

// v0.6 (docs/contracts-0.6/providers-wake-onboarding.md §0 W1/W2, §2, §4): DORMANT
// is silent (no socket, no request, no key mint, no audio, no clip render), the
// wake phrase is local (the mic reaches the ear in every state; waking never
// waits for the network), `wake(onsetFrame:)` sends from onset − 0.3 s, `sleep()`
// closes everything and nothing reopens it, and the cascaded event order keeps
// holds / barge-in working.

/// CloudVoice on a manual graph and a real session whose sockets and mints go
/// through a recorded `Transport`.
final class WakeRig: @unchecked Sendable {
    let graph: AudioGraph
    let factory: FakeSocketFactory
    let recorder = TransportRecorder()
    let transport: Transport
    let clock = ManualRealtimeClock()
    let session: RealtimeSession
    let voice: CloudVoice
    let events: Collector<VoiceEvent>
    let brain: Collector<CloudVoice.BrainEvent>
    let awake: Collector<CloudVoice.AwakeState>
    final class Counter: Sendable {
        private let n = Mutex(0)
        func bump() { n.withLock { $0 += 1 } }
        var value: Int { n.withLock { $0 } }
    }
    let mints = Counter()
    private let noise = Mutex<UInt64>(7)
    private let out = Mutex<[Float]>([])
    static let rate = 48_000.0

    init(dormant: Bool = true, transport custom: Transport? = nil, clips: ClipCache? = nil,
         credentials: RealtimeCredentialProvider? = nil,
         configure: (inout CloudVoice.Configuration) -> Void = { _ in }) throws {
        graph = try AudioGraph.manual(sampleRate: Self.rate, channels: 1)
        let f = FakeSocketFactory { FakeSocket(request: $0, sessionID: "sess_\(Int.random(in: 1000...9999))") }
        factory = f
        transport = custom ?? Transport(recorder: recorder, fetch: { _ in throw URLError(.notConnectedToInternet) },
                                        socketFactory: f.factory)
        var config = RealtimeSessionConfig()
        config.instructions = "You are Dee."
        let mints = self.mints
        let creds: RealtimeCredentialProvider = credentials ?? { _ in
            mints.bump()
            return .ephemeral("ek_test", expiresAt: Date().addingTimeInterval(600))
        }
        session = RealtimeSession(config: config, credentials: creds, socketFactory: transport.socketFactory, clock: clock)
        var c = CloudVoice.Configuration()
        c.autoTick = false
        c.classifySounds = false
        c.connectRetryDelays = [0.05]
        c.startsDormant = dormant
        configure(&c)
        voice = CloudVoice(session: session, graph: graph, clips: clips, timeline: TurnTimeline(), configuration: c)
        events = Collector(voice.events)
        brain = Collector(voice.brainEvents)
        awake = Collector(voice.awakeStates)
    }

    var output: [Float] { out.withLock { $0 } }

    func step(_ mic: [Float]? = nil) throws {
        let n = Int(Self.rate * 0.02)
        let samples = mic ?? noise.withLock { s -> [Float] in
            s += 1
            return Signal.noise(amplitude: 0.001, count: n, seed: s)
        }
        graph.inject(PCMTone.buffer(samples, rate: Self.rate))
        let rendered = try graph.render(frames: AVAudioFrameCount(n)).firstChannelSamples()
        out.withLock { $0 += rendered }
        voice.tick()
    }

    func quiet(_ seconds: Double) throws { for _ in 0..<Int((seconds / 0.02).rounded()) { try step() } }

    func talk(_ seconds: Double, amplitude: Double = 0.3, hz: Double = 180) throws {
        let x = Signal.harmonic(hz: hz, amplitude: amplitude, sampleRate: Self.rate, seconds: seconds)
        for f in Signal.frames(x, size: Int(Self.rate * 0.02)) { try step(f) }
    }

    /// A long stretch of room life while Dee sleeps: talk, TV-ish tones, silence;
    /// the session's clock runs too (its reconnect / rollover timers would fire).
    func liveARoom(seconds: Double) async throws {
        var t = 0.0
        while t < seconds {
            try talk(1.2)
            try talk(0.8, amplitude: 0.15, hz: 300)
            try quiet(2.0)
            clock.advance(by: 4)
            t += 4
            await Task.yield()
        }
    }

    func appends(_ s: FakeSocket) -> [Int16] {
        s.sent.compactMap { text -> [Int16]? in
            guard let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  o["type"] as? String == "input_audio_buffer.append",
                  let b = o["audio"] as? String, let d = Data(base64Encoded: b) else { return nil }
            return PCM16.samples(d)
        }.flatMap { $0 }
    }

    func waitAwake(timeout: Double = 15) async -> Bool {
        await awake.wait(timeout: timeout) { $0 == .awake } != nil
    }

    func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(15))
    }
}

@Suite(.serialized) struct V06DormantTests {
    /// W2 over a long dormant stretch: the mic runs (the wake ear gets it), but no
    /// socket, no request, no mint, no audio byte, no clip render — whatever the
    /// app pokes (reconnect, clip prepare) and however long the session's clock runs.
    @Test func dormantIsSilentForMinutes() async throws {
        let speech = FakeSpeechServer()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v06-clips-\(UUID().uuidString)")
        let clips = ClipCache(configuration: ClipCache.Configuration(directory: dir), key: { "sk-test-key-0123456789" },
                              fetch: speech.fetch)
        let rig = try WakeRig(clips: clips)
        let heard = Mutex(0)
        rig.voice.addMicSink { pcm, _ in heard.withLock { $0 += pcm.count } }
        await rig.voice.start()
        #expect(await rig.awake.wait(timeout: 20) { $0 == .dormant } != nil)
        try await rig.liveARoom(seconds: 120)
        rig.voice.reconnect()                     // a key was saved in settings
        rig.voice.listeningEnabled = true
        let report = await clips.prepare()        // the app asks for clips
        try await rig.liveARoom(seconds: 60)
        await rig.settle()

        #expect(rig.factory.made.isEmpty, "a socket opened while DORMANT")
        #expect(rig.recorder.count == 0)
        #expect(rig.mints.value == 0)
        #expect(speech.all.isEmpty && report.stopped == "dormant" && report.rendered.isEmpty)
        #expect(!rig.voice.isAwake && !rig.voice.isConnected)
        #expect(await rig.session.state == .idle)
        // The ear heard all of it, at 16 kHz.
        let expected = Int(180 * 16_000.0)
        #expect(abs(heard.withLock { $0 } - expected) < 16_000, "\(heard.withLock { $0 }) vs \(expected)")
        rig.voice.shutdown()
    }

    /// W2: what the brain asks for while DORMANT is refused there and then — it is
    /// never queued to go out when the next window opens.
    @Test func requestsWhileDormantNeverGoOutLater() async throws {
        let rig = try WakeRig()
        await rig.voice.start()
        try rig.quiet(0.5)
        await #expect(throws: RealtimeSessionError.notConnected) { _ = try await rig.voice.respond() }
        #expect(await rig.voice.initiative(instructions: "Say hi.") == .refused(.notConnected))
        #expect(await rig.voice.say("Hello!") == .refused(.notConnected))
        await rig.session.replaceDNA("DEE DNA test")
        await rig.session.updateSession(instructions: "You are Dee, v2.")
        #expect(rig.factory.made.isEmpty)
        rig.voice.wake(onsetFrame: nil, resume: false)
        #expect(await rig.waitAwake())
        try rig.quiet(0.3)
        await rig.settle()
        let s = try #require(rig.factory.made.first)
        #expect(Set(s.sentTypes) == ["session.update", "input_audio_buffer.append"], "\(s.sentTypes)")
        #expect(s.sent.first?.contains("You are Dee, v2.") == true)     // settings apply to the next session
        rig.voice.shutdown()
    }

    /// The default (harness "always open") is v0.5: connected at start, no awake states.
    @Test func alwaysOpenConnectsAtStartAsBefore() async throws {
        let rig = try WakeRig(dormant: false)
        await rig.voice.start()
        #expect(await rig.brain.wait(timeout: 15) { if case .session(.connected) = $0 { true } else { false } } != nil)
        #expect(rig.voice.isAwake)
        #expect(rig.awake.all.isEmpty)
        #expect(rig.factory.made.count == 1 && rig.mints.value == 1)
        rig.voice.shutdown()
    }
}

@Suite(.serialized) struct V06WakeTests {
    /// "Hey Dee, what time is it?" in one breath: the uplink starts 0.3 s before the
    /// phrase's onset — not where the last window ended, not the 2 s default — so
    /// the server hears it whole and nothing said before it.
    @Test func theUplinkStartsAtTheOnsetMinusAThirdOfASecond() async throws {
        let rig = try WakeRig()
        await rig.voice.start()
        try rig.quiet(1.0)
        try rig.talk(0.6, hz: 140)                 // earlier private speech (never sent)
        try rig.quiet(1.4)
        let onset = rig.voice.captureFrame
        try rig.talk(1.5)                          // "Hey Dee, what time is it?"
        try rig.quiet(0.8)                         // recognised ~2 s late (the v0.5 2 s pre-roll would miss the start)
        #expect(rig.factory.made.isEmpty)
        rig.voice.wake(onsetFrame: onset)
        #expect(await rig.waitAwake())
        try rig.quiet(0.3)
        await rig.settle()
        let pcm = rig.appends(try #require(rig.factory.made.first))
        let firstLoud = try #require(pcm.firstIndex { abs(Int($0)) > 3000 })
        #expect(abs(firstLoud - 7_200) < 600, "the phrase starts \(firstLoud) samples into the uplink, want 7200")
        // Nothing before onset − 0.3 s: the earlier speech is 1.4 s before the phrase.
        let loudSpans = pcm.prefix(firstLoud).filter { abs(Int($0)) > 3000 }
        #expect(loudSpans.isEmpty)
        #expect(pcm.count >= Int((0.3 + 1.5 + 0.8) * 24_000) - 2_400, "\(pcm.count)")
        rig.voice.shutdown()
    }

    /// The window's own pre-roll (already −0.3 s) is used as is.
    @Test func wakeFromAnExplicitUplinkFrame() async throws {
        let rig = try WakeRig()
        await rig.voice.start()
        try rig.quiet(2.0)
        let onset = rig.voice.captureFrame
        try rig.talk(0.8)
        rig.voice.wake(uplinkFromFrame: onset - 4_800)          // 0.2 s before
        #expect(await rig.waitAwake())
        try rig.quiet(0.2)
        await rig.settle()
        let pcm = rig.appends(try #require(rig.factory.made.first))
        let firstLoud = try #require(pcm.firstIndex { abs(Int($0)) > 3000 })
        #expect(abs(firstLoud - 4_800) < 600, "\(firstLoud)")
        rig.voice.shutdown()
    }

    /// W1: the wake reaction never waits for the network: with every request
    /// failing, `.waking` still comes first (the eyes), nothing was asked of the
    /// network before it, no audio is ever sent, and the failure is a problem for
    /// the window — once per provider style (mode 1 mint, LAN key, keyless LAN).
    @Test(arguments: ["openai-mint", "lan-key", "lan-keyless"])
    func wakingIsLocalEvenWhenTheNetworkIsGone(style: String) async throws {
        let recorder = TransportRecorder()
        let offline = Transport.failing(recorder: recorder)
        let keys = KeyStore(storage: MemorySecretStorage())
        try keys.save("sk-proj-" + String(repeating: "k", count: 40))
        let auth = OpenAIAuth(keyStore: keys, transport: offline.fetch)
        let creds: RealtimeCredentialProvider = switch style {
        case "openai-mint": { try await auth.credential(model: $0) }
        case "lan-key": { _ in .direct("lan-token") }
        default: { _ in .direct("") }
        }
        let rig = try WakeRig(transport: offline, credentials: creds, configure: {
            $0.provider = style == "openai-mint" ? .openAI : .lan(host: "studio.local")
        })
        await rig.voice.start()
        try await rig.liveARoom(seconds: 40)
        #expect(recorder.count == 0, "the network was used before the wake")
        rig.voice.wake(onsetFrame: rig.voice.captureFrame - 12_000)
        let states = rig.awake
        #expect(await states.wait { $0 == .waking } != nil)
        let failed = await states.wait(timeout: 10) { if case .failed = $0 { true } else { false } }
        #expect(failed != nil, "\(states.all) problem=\(String(describing: rig.voice.problem)) records=\(recorder.count) sockets=\(rig.factory.made.count) awake=\(rig.voice.isAwake)")
        #expect(states.all.prefix(2) == [.dormant, .waking], "\(states.all)")
        #expect(recorder.count >= 1)
        if case .failed(let p)? = failed, style != "openai-mint" {
            #expect(CloudVoice.detail(p).contains("studio.local"), "\(p)")
        }
        rig.voice.sleep()
        let after = recorder.count
        try await rig.liveARoom(seconds: 20)
        try await Task.sleep(for: .milliseconds(200))       // past every retry delay
        #expect(recorder.count == after, "the connect loop went on after sleep")
        rig.voice.shutdown()
    }

    /// `sleep()` closes the socket and nothing reopens it: not a server drop's
    /// reconnect, not the idle restart, not `reconnect()`, not two hours of clock.
    @Test func sleepClosesEverythingAndNothingReopensIt() async throws {
        let rig = try WakeRig()
        await rig.voice.start()
        rig.voice.wake(onsetFrame: nil)
        #expect(await rig.waitAwake())
        try rig.quiet(0.5)
        let first = try #require(rig.factory.made.first)
        #expect(!rig.appends(first).isEmpty)
        rig.voice.sleep()
        #expect(await rig.awake.wait(timeout: 20) { $0 == .dormant && rig.awake.all.filter { $0 == .dormant }.count == 2 } != nil)
        let gone = await rig.brain.wait { if case .session(.disconnected) = $0 { true } else { false } }
        #expect(gone != nil)
        #expect(first.closedByClient != nil)
        let sentAtSleep = first.sent.count
        rig.voice.reconnect()
        for _ in 0..<240 { rig.clock.advance(by: 30); await Task.yield() }
        try await rig.liveARoom(seconds: 30)
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.factory.made.count == 1, "a socket reopened while DORMANT")
        #expect(first.sent.count == sentAtSleep)
        #expect(rig.mints.value == 1)
        #expect(!rig.voice.isConnected)
        rig.voice.shutdown()
    }

    /// A new window resumes the conversation: its socket's first item is the seed.
    @Test func aSecondWindowIsSeededWithTheFirst() async throws {
        let rig = try WakeRig()
        await rig.voice.start()
        rig.voice.wake(onsetFrame: nil)
        #expect(await rig.waitAwake())
        _ = await rig.session.addUserText("My name is Priya.")
        rig.voice.sleep()
        _ = await rig.brain.wait { if case .session(.disconnected) = $0 { true } else { false } }
        try rig.quiet(1)
        rig.voice.wake(onsetFrame: nil)
        let second = try #require(await rig.factory.waitForSocket(count: 2, timeout: 10))
        #expect(await second.waitForSent(type: "conversation.item.create", count: 1, timeout: 5))
        #expect(second.sentTypes.prefix(2) == ["session.update", "conversation.item.create"], "\(second.sentTypes)")
        #expect(second.sent.dropFirst().first?.contains("Priya") == true)
        rig.voice.shutdown()
    }

    /// Sleep right after wake (still connecting) and wake again: one live socket
    /// at the end, never two; nothing left half-open.
    @Test func sleepWhileWakingThenWakeAgain() async throws {
        let rig = try WakeRig()
        await rig.voice.start()
        rig.voice.wake(onsetFrame: nil)
        rig.voice.sleep()
        rig.voice.wake(onsetFrame: nil)
        #expect(await rig.waitAwake())
        try await Task.sleep(for: .milliseconds(300))
        await rig.settle()
        let open = rig.factory.made.filter(\.isOpen)
        #expect(open.count == 1, "\(rig.factory.made.map(\.isOpen))")
        #expect(rig.voice.isConnected)
        rig.voice.shutdown()
    }

    /// Clips render once per window, after it connected — never while DORMANT.
    @Test func clipsRenderOnlyInsideAWindow() async throws {
        let speech = FakeSpeechServer()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v06-clips-\(UUID().uuidString)")
        var config = ClipCache.Configuration(directory: dir)
        config.clips = [.oneSec, .giggle]
        let clips = ClipCache(configuration: config, key: { "sk-test-key-0123456789" }, fetch: speech.fetch)
        let rig = try WakeRig(clips: clips, configure: { $0.prepareClipsOnWake = true })
        await rig.voice.start()
        try rig.quiet(1)
        #expect(clips.renderAllowed == false)
        #expect(speech.all.isEmpty)
        rig.voice.wake(onsetFrame: nil)
        #expect(await rig.waitAwake())
        let deadline = ContinuousClock.now + .seconds(5)
        while speech.all.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(speech.all.count == 2)
        #expect(clips.available == [.oneSec, .giggle])
        rig.voice.sleep()
        #expect(clips.renderAllowed == false)
        rig.voice.shutdown()
    }

    /// Mode 3's turn detector gets EarCore's verdict for every uplinked frame.
    @Test func uplinkActivityFollowsTheirVoice() async throws {
        let activity = UplinkActivity()
        let rig = try WakeRig(configure: { $0.uplinkActivity = activity })
        await rig.voice.start()
        rig.voice.wake(onsetFrame: nil)
        #expect(await rig.waitAwake())
        try rig.quiet(0.6)
        await rig.settle()
        #expect(!activity.voiceNow)
        try rig.talk(0.8)
        await rig.settle()
        #expect(activity.voiceNow)
        #expect(activity.latestFedFrame >= Int64(1.2 * 24_000))
        rig.voice.shutdown()
    }
}

@Suite(.serialized) struct V06MicAndCueTests {
    /// The wake ear's feed: 16 kHz, contiguous capture positions, in every state.
    @Test func theMicSinkIsSixteenKilohertzOnTheCaptureClock() async throws {
        let rig = try WakeRig()
        let chunks = Mutex<[(n: Int, frame: Int64)]>([])
        rig.voice.addMicSink { pcm, frame in chunks.withLock { $0.append((pcm.count, frame)) } }
        await rig.voice.start()
        try rig.talk(3)
        let c = chunks.withLock { $0 }
        #expect(c.count >= 100)
        // Each chunk's 24 kHz position follows the previous one by its 24 kHz length (~20 ms = ~480,
        // as the 48→24 kHz converter hands it out; the first is short by the filter's delay),
        // with no gap and no overlap.
        for (a, b) in zip(c.dropFirst(), c.dropFirst(2)) { #expect((470...490).contains(b.frame - a.frame), "\(b.frame - a.frame)") }
        let total = c.reduce(0) { $0 + $1.n }
        #expect(abs(total - 48_000) < 400, "\(total)")
        // 16 kHz samples line up with the 24 kHz span they came from (2 : 3).
        let span = Double(c.last!.frame - c.first!.frame)
        let before = Double(c.dropLast().reduce(0) { $0 + $1.n })
        #expect(abs(before - span * 2 / 3) < 64, "\(before) vs \(span * 2 / 3)")
        rig.voice.shutdown()
    }

    /// The wake ear is fed from the same tap while DORMANT (W1: nothing else hears it).
    @Test func anAttachedWakeEarHearsTheRoomWhileDormant() async throws {
        final class Ear: WakeEar, @unchecked Sendable {
            let fed = Mutex<(n: Int, last: Int64)>((0, -1))
            func start(phrase: WakePhrase) async {}
            func stop() async {}
            func setPhrase(_ phrase: WakePhrase) async {}
            func setStrict(_ strict: Bool) async {}
            func consume(_ pcm16k: [Int16], captureFrame24k: Int64) {
                fed.withLock { $0 = ($0.n + pcm16k.count, captureFrame24k) }
            }
            var hits: AsyncStream<WakeHit> { AsyncStream { _ in } }
            var candidates: AsyncStream<Void> { AsyncStream { _ in } }
            var availability: AsyncStream<EarAvailability> { AsyncStream { _ in } }
        }
        let rig = try WakeRig()
        let ear = Ear()
        rig.voice.attach(wakeEar: ear)
        await rig.voice.start()
        try rig.talk(2)
        let fed = ear.fed.withLock { $0 }
        #expect(abs(fed.n - 32_000) < 400, "\(fed.n)")
        #expect(fed.last > 0 && fed.last <= rig.voice.captureFrame)
        #expect(rig.factory.made.isEmpty && rig.recorder.count == 0)
        rig.voice.shutdown()
    }

    @Test func theCaptureRingKeepsTwelveSeconds() async throws {
        let rig = try WakeRig()
        await rig.voice.start()
        try rig.quiet(15)
        let pre = rig.graph.capture.preroll(seconds: 20)
        #expect(pre.frames == 12 * 24_000)
        #expect(pre.startFrame == rig.graph.capture.capturedFrames - 12 * 24_000)
        #expect(rig.graph.capture.preroll().frames == 2 * 24_000)        // the default pre-roll is still 2 s
        rig.voice.shutdown()
    }

    /// A listening cue plays locally (no socket, no request), DORMANT or not.
    @Test func cuesAreLocal() async throws {
        let rig = try WakeRig()
        await rig.voice.start()
        try rig.quiet(0.3)
        let at = rig.output.count
        #expect(rig.voice.playCue(.wake))
        try rig.quiet(0.5)
        let loud = rig.output[at...].filter { abs($0) > 0.01 }.count
        #expect(Double(loud) / WakeRig.rate > 0.08, "\(loud)")
        #expect(rig.factory.made.isEmpty && rig.recorder.count == 0)
        #expect(!rig.brain.all.contains { if case .clipPlayed = $0 { true } else { false } })
        #expect(CloudVoice.cuePCM(.wake) != CloudVoice.cuePCM(.listeningOff))
        rig.voice.shutdown()
    }

    @Test func problemsNameTheProvider() {
        let lan = ProviderLabel.lan(host: "studio.local")
        #expect(CloudVoice.problem(for: .connectFailed("refused"), provider: lan)?.0
                == .cloudVoiceUnavailable("Can't reach the AI server at studio.local: refused"))
        #expect(CloudVoice.problem(for: .unauthorized, provider: lan)?.0
                == .cloudVoiceNeedsSetup("The AI server at studio.local refused the key."))
        // OpenAI keeps v0.5's texts.
        #expect(CloudVoice.problem(for: .unauthorized, provider: .openAI)?.0 == .cloudVoiceNeedsSetup("The OpenAI key was refused."))
        #expect(CloudVoice.unreachable(.openAI, "timed out") == "timed out")
    }
}

// MARK: - The cascaded event order (CascadeSocket: transcript before audio per sentence)

extension LoopRig {
    /// Dee's reply as `CascadeSocket` emits it: `response.created` at the first token,
    /// then per sentence its transcript delta **then** its audio.
    func cascadedReply(_ sentences: [(String, Int)], resp: String = "resp_1", item: String = "item_a1") async throws {
        push(Srv.speechStarted("item_u1", ms: 100), Srv.speechStopped("item_u1", ms: 200), Srv.committed("item_u1"))
        _ = await brain.wait { if case .session(.userCommitted) = $0 { true } else { false } }
        _ = try await voice.respond()
        push(Srv.responseCreated(resp), Srv.messageAdded(resp, item))
        for (text, ms) in sentences {
            push(Srv.transcript(resp, item, text))
            var left = ms
            while left > 0 {
                let k = min(100, left)
                push(Srv.audio(resp, item, PCMTone.data(ms: Double(k), hz: 440, amplitude: 0.3)))
                left -= k
            }
        }
        push(Srv.audioDone(resp, item), Srv.transcriptDone(resp, item, sentences.map(\.0).joined()), Srv.responseDone(resp))
        await settle()
    }
}

@Suite(.serialized) struct V06CascadedOrderTests {
    /// "Keep going" over Dee's cascaded reply: paused at once, goes on from there, plays whole.
    @Test func aBackchannelContinuesHer() async throws {
        let rig = try LoopRig(duckOnOnset: false)   // calm off: pins 0.6.0's pause (see CalmVoiceTests)
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.cascadedReply([("Volcanoes are mountains. ", 1200), ("They breathe fire.", 900)])
        try rig.quiet(0.6)
        try rig.talk(0.15)
        rig.push(Srv.speechStarted("item_u2", ms: rig.uplinkMsNow - 150))
        await rig.settle()
        try rig.talk(0.3)
        #expect(rig.voice.floorHold?.itemID == "item_u2")
        let pausedAt = rig.output.count
        try rig.quiet(0.3)
        #expect(rig.audibleMs(fromSample: pausedAt) < 10)
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 200), Srv.committed("item_u2"),
                 Srv.userTranscript("item_u2", "Keep going."))
        await rig.settle()
        try rig.quiet(0.04)
        #expect(rig.voice.floorHold == nil)
        try rig.quiet(2.0)
        let played = try #require(rig.itemPlayed("item_a1"))
        #expect(played.ms == 2100 && !played.cut, "\(played)")
        #expect(rig.sent("conversation.item.truncate").isEmpty && rig.sent("response.cancel").isEmpty)
        let said = rig.brain.all.compactMap { e -> String? in
            if case .sentenceFinished(_, _, let text, true) = e { text } else { nil }
        }
        #expect(said == ["Volcanoes are mountains.", "They breathe fire."], "\(said)")
        rig.voice.shutdown()
    }

    /// A real interruption over a cascaded reply ends it where Dee paused: the
    /// emulator gets the truncate at the heard point and the cut is reported.
    @Test func aBargeInStopsHer() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.cascadedReply([("Let me tell you about the moon. ", 1500), ("It is far away.", 1500)])
        try rig.quiet(0.6)
        try rig.talk(0.15)
        rig.push(Srv.speechStarted("item_u2", ms: rig.uplinkMsNow - 150))
        await rig.settle()
        try rig.talk(0.3)
        #expect(rig.voice.floorHold?.itemID == "item_u2")
        rig.push(Srv.speechStopped("item_u2", ms: rig.uplinkMsNow - 100), Srv.committed("item_u2"),
                 Srv.userTranscript("item_u2", "Wait, what time is it?"))
        await rig.settle()
        try rig.quiet(CloudVoice.holdAfterWords + 0.1)
        _ = await rig.events.wait { $0 == .bargeIn }
        #expect(await rig.waitSent("conversation.item.truncate"))
        let truncate = try #require(rig.sent("conversation.item.truncate").first)
        let at = try #require(truncate["audio_end_ms"] as? Int)
        #expect(at > 400 && at < 1500, "\(at)")
        try rig.quiet(0.1)
        let played = try #require(rig.itemPlayed("item_a1"))
        #expect(played.cut)
        rig.voice.shutdown()
    }
}

// MARK: - Clip renderers and 24 kHz conversion

@Suite struct V06ClipRendererTests {
    func wav(rate: Int, channels: Int, bits: Int, float: Bool = false, seconds: Double = 0.5) -> Data {
        let frames = Int(Double(rate) * seconds)
        var body = Data()
        for i in 0..<frames {
            let v = sin(2 * Double.pi * 440 * Double(i) / Double(rate)) * 0.5
            for _ in 0..<channels {
                if float {
                    var f = Float(v).bitPattern.littleEndian
                    body.append(Data(bytes: &f, count: 4))
                } else if bits == 16 {
                    var s = Int16(v * 32767).littleEndian
                    body.append(Data(bytes: &s, count: 2))
                } else {
                    var s = Int32(v * 2_147_483_647).littleEndian
                    body.append(Data(bytes: &s, count: 4))
                }
            }
        }
        func le32(_ x: Int) -> Data { var v = UInt32(x).littleEndian; return Data(bytes: &v, count: 4) }
        func le16(_ x: Int) -> Data { var v = UInt16(x).littleEndian; return Data(bytes: &v, count: 2) }
        var d = Data("RIFF".utf8) + le32(36 + body.count) + Data("WAVE".utf8)
        d += Data("fmt ".utf8) + le32(16) + le16(float ? 3 : 1) + le16(channels) + le32(rate)
        d += le32(rate * channels * bits / 8) + le16(channels * bits / 8) + le16(bits)
        d += Data("data".utf8) + le32(body.count) + body
        return d
    }

    @Test(arguments: [(16_000, 1, 16, false), (22_050, 1, 16, false), (24_000, 1, 16, false), (48_000, 2, 16, false),
                      (24_000, 1, 32, true), (44_100, 2, 32, false)])
    func anyWAVBecomes24kMono(rate: Int, channels: Int, bits: Int, float: Bool) throws {
        let pcm = try #require(PCM24k.fromWAV(wav(rate: rate, channels: channels, bits: bits, float: float)))
        let n = pcm.count / 2
        #expect(abs(n - 12_000) < 200, "\(rate) Hz → \(n) frames")
        let peak = PCM16.samples(pcm).map { abs(Int($0)) }.max() ?? 0
        #expect(peak > 12_000 && peak < 20_000, "peak \(peak)")
    }

    @Test func notAWAV() {
        #expect(PCM24k.fromWAV(Data("{\"error\":\"nope\"}".utf8)) == nil)
    }

    /// OpenAI clips keep v0.5's request and fingerprint (nothing re-renders on update).
    @Test func openAIClipsAreUnchanged() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v06-fp-\(UUID().uuidString)")
        let c = ClipCache(configuration: .init(voice: .named("marin"), directory: dir), key: { "sk-x" })
        let key = ["v1", "gpt-4o-mini-tts", "marin", c.configuration.style, VoiceClip.oneSec.text, VoiceClip.oneSec.delivery]
            .joined(separator: "\u{1F}")
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        #expect(c.fingerprint(.oneSec) == String(h, radix: 16))
        #expect(c.fileURL(.oneSec).lastPathComponent.hasPrefix("marin-oneSec-"))
        let body = c.requestBody(.oneSec)
        #expect(Set(body.keys) == ["model", "voice", "input", "instructions", "response_format"])
        #expect(body["response_format"] as? String == "pcm")
    }

    /// A LAN speech server: WAV converted, no style instructions, its own key (if any),
    /// a fingerprint of its own, and a refused redirect / error is a clean failure.
    @Test func aLANSpeechServerRenders() async throws {
        let seen = Mutex<[URLRequest]>([])
        let body = wav(rate: 22_050, channels: 1, bits: 16, seconds: 0.4)
        let fetch: HTTPFetch = { req in
            seen.withLock { $0.append(req) }
            return (body, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let r = SpeechEndpointRenderer(configuration: .lan(baseURL: URL(string: "http://192.168.1.20:8880")!,
                                                           model: "kokoro", voice: "af_bella"),
                                       key: { nil }, fetch: fetch)
        let pcm = try await r.render(text: "One sec.", instructions: "bright")
        #expect(abs(pcm.count / 2 - 9_600) < 200)
        let req = try #require(seen.withLock { $0.first })
        #expect(req.url?.absoluteString == "http://192.168.1.20:8880/v1/audio/speech")
        #expect(req.value(forHTTPHeaderField: "Authorization") == nil)
        let json = try #require(try JSONSerialization.jsonObject(with: req.httpBody ?? Data()) as? [String: Any])
        #expect(json["instructions"] == nil && json["response_format"] as? String == "wav" && json["voice"] as? String == "af_bella")
        #expect(r.fingerprintModel != "kokoro")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("v06-lan-\(UUID().uuidString)")
        var config = ClipCache.Configuration(directory: dir)
        config.clips = [.oneSec]
        let cache = ClipCache(configuration: config, renderer: r)
        let report = await cache.prepare()
        #expect(report.rendered == [.oneSec])
        #expect(cache.fileURL(.oneSec).lastPathComponent.hasPrefix("af_bella-oneSec-"))

        let refused = SpeechEndpointRenderer(configuration: .lan(baseURL: URL(string: "http://192.168.1.20:8880")!,
                                                                 model: "kokoro", voice: "af_bella"),
                                             key: { nil }, fetch: { req in
            (Data(), HTTPURLResponse(url: req.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!)
        })
        await #expect(throws: ClipRenderError.status(302, nil)) { _ = try await refused.render(text: "x", instructions: "") }
    }

    /// The iPhone's own voice (when this machine has one installed).
    @Test func onDeviceClipsRenderLocally() async throws {
        guard OnDeviceClipRenderer.bestVoice(language: "en-US") != nil else { return }
        let pcm = try await OnDeviceClipRenderer().render(text: "One sec.", instructions: "")
        #expect(pcm.count / 2 > 24_000 / 5, "\(pcm.count / 2) frames")
        #expect((PCM16.samples(pcm).map { abs(Int($0)) }.max() ?? 0) > 1_000)
    }
}
