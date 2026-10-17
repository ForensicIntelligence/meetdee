import DeeCore
import DeeRealtime
import DeeVoice
import DeeWake
import Foundation
import Synchronization
import Testing
@testable import DeeBrain

/// The app's window driver (providers-wake-onboarding §4, W1/W2): what DeeModel does
/// with the on-device ear, taps and the voice.
@MainActor
final class RecordingWakeHost: WakeControllerHost {
    var calls: [String] = []
    var voice: CloudVoice?
    func wakeEyes() { calls.append("eyesWake") }
    func listeningOffEyes() { calls.append("eyesListeningOff") }
    func perkUp() { calls.append("perkUp") }
    func woken(by source: WakeSource) { calls.append("woken:\(source.rawValue)") }
    func startNewConversation() { calls.append("newConversation") }
    func connect(resume: Bool, uplinkFrom: Int64?) {
        calls.append("connect:\(resume):\(uplinkFrom.map(String.init) ?? "now")")
        voice?.wake(uplinkFromFrame: uplinkFrom, resume: resume)
    }
    func disconnect() { calls.append("disconnect"); voice?.sleep() }
    func sayGoodbye() { calls.append("goodbye") }
    func show(problem: String) { calls.append("problem:\(problem)") }
    func clearProblem() { calls.append("clearProblem") }
}

@MainActor
@Suite struct WakeControllerTests {
    final class Clock: @unchecked Sendable {
        var t: TimeInterval = 1_000
        func now() -> TimeInterval { t }
    }

    static func hit(onset: Int64 = 240_000) -> WakeHit {
        WakeHit(onsetFrame: onset, onsetFromFinal: false, detectedFrame: onset + 24_000, matched: "hey dee", tier: .exact)
    }

    static func make(ear: ScriptedWakeEar? = ScriptedWakeEar()) -> (WakeController, RecordingWakeHost, Clock) {
        let clock = Clock()
        let c = WakeController(phrase: .default, ear: ear, mode: "openAI", monotonic: { clock.now() },
                               wallClock: { Date(timeIntervalSince1970: 1_760_616_000 + clock.t) })
        let h = RecordingWakeHost()
        c.host = h
        return (c, h, clock)
    }

    /// W1: the eyes react before anything connects; the uplink starts 0.3 s before the onset.
    @Test func phraseWakesEyesFirstThenConnectsFromThePreroll() async throws {
        let ear = ScriptedWakeEar()
        let (c, h, _) = Self.make(ear: ear)
        await c.start()
        ear.emit(Self.hit(onset: 240_000))
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.calls.first == "eyesWake")
        #expect(h.calls.contains("connect:true:\(240_000 - 7_200)"))
        let eyes = try #require(h.calls.firstIndex(of: "eyesWake"))
        let connect = try #require(h.calls.firstIndex { $0.hasPrefix("connect:") })
        #expect(eyes < connect)
        #expect(!c.answers, "waking is not open")
        c.connected()
        #expect(c.answers)
    }

    @Test func idleWindowClosesAfterSixtySecondsAndLogsNumbersOnly() {
        let (c, h, clock) = Self.make()
        c.tapToTalk(captureFrame: 48_000)
        c.connected()
        c.acceptedTurn()
        clock.t += 30
        c.tick(busy: Busy(replyOutstanding: true))
        clock.t += 59
        c.tick(busy: .idle)
        #expect(c.isOpen, "60 s from when busy ended")
        clock.t += 2
        c.tick(busy: .idle)
        #expect(c.isDormant)
        #expect(h.calls.suffix(2) == ["disconnect", "eyesListeningOff"])
        let line = try? #require(c.log.last)
        #expect(line?.hasPrefix("window closed: open 91 s, streamed 91.0 s, 0 responses, mode openAI") == true, "\(line ?? "")")
        #expect(c.usage.today(at: Date(timeIntervalSince1970: 1_760_616_000 + clock.t)).windows == 1)
    }

    /// TV bed: speech activity without accepted turns never keeps the window open.
    @Test func unansweredActivityDoesNotExtendTheWindow() {
        let (c, _, clock) = Self.make()
        c.input(.phraseHeard(Self.hit()))
        c.connected()
        for _ in 0..<3 {
            clock.t += 20
            c.replyEnded(toAccepted: false)   // Dee's initiatives / replies to unanswered ones
            c.tick(busy: .idle)
        }
        #expect(c.isDormant, "closed at 60 s")
        #expect(c.usage.today(at: Date(timeIntervalSince1970: 1_760_616_000 + clock.t)).falseWakes == 1)
    }

    @Test func closeCommandSaysGoodbyeAndDisconnects() {
        let (c, h, _) = Self.make()
        c.tapToTalk(captureFrame: nil)
        c.connected()
        c.closeCommand()
        #expect(c.isDormant)
        let g = h.calls.firstIndex(of: "goodbye")
        let d = h.calls.firstIndex(of: "disconnect")
        #expect(g != nil && d != nil && g! < d!)
    }

    @Test func longDormancyStartsANewConversation() {
        let (c, h, clock) = Self.make()
        c.tapToTalk(captureFrame: nil)
        c.connected()
        c.closeCommand()
        clock.t += 301
        h.calls = []
        c.tapToTalk(captureFrame: nil)
        #expect(h.calls.contains("newConversation"))
        #expect(h.calls.contains { $0.hasPrefix("connect:false") })
    }

    @Test func greetingWindowAllowsOneInitiative() {
        let (c, _, _) = Self.make()
        c.greetingDue()
        #expect(!c.greetingInitiativeOpen)
        c.connected()
        #expect(c.greetingInitiativeOpen)
        c.usedGreetingInitiative()
        #expect(!c.greetingInitiativeOpen)
    }

    @Test func lostEarIsOneProblemAndStaysDormant() async throws {
        let ear = ScriptedWakeEar()
        let (c, h, _) = Self.make(ear: ear)
        await c.start()
        ear.setAvailability(.denied)
        try await Task.sleep(for: .milliseconds(50))
        #expect(c.isDormant)
        #expect(h.calls.contains { $0.hasPrefix("problem:") })
        #expect(!h.calls.contains { $0.hasPrefix("connect") })
        // A tap still wakes Dee.
        c.tapToTalk(captureFrame: nil)
        #expect(h.calls.contains { $0.hasPrefix("connect") })
    }

    @Test func candidatePerksUpOnlyWhileDormant() async throws {
        let ear = ScriptedWakeEar()
        let (c, h, _) = Self.make(ear: ear)
        await c.start()
        ear.emitCandidate()
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.calls == ["perkUp"])
        #expect(c.isDormant)
    }
}

/// W1 / W2 with a real CloudVoice: dormant = no socket, no key mint; a local hit wakes
/// Dee even when every network call fails; the eyes come first.
@MainActor
@Suite struct WakeVoiceIntegrationTests {
    final class Mints: @unchecked Sendable {
        private let n = Mutex(0)
        func bump() { n.withLock { $0 += 1 } }
        var count: Int { n.withLock { $0 } }
    }

    static func voice(factory: FakeSocketFactory, mints: Mints, failing: Bool) throws -> CloudVoice {
        let graph = try AudioGraph.manual(sampleRate: 48_000, channels: 1)
        let session = RealtimeSession(config: CloudSettings().sessionConfig(), credentials: { _ in
            mints.bump()
            if failing { throw URLError(.notConnectedToInternet) }
            return .ephemeral("ek_test", expiresAt: Date().addingTimeInterval(600))
        }, socketFactory: factory.factory)
        var c = CloudVoice.Configuration()
        c.autoTick = false
        c.classifySounds = false
        c.startsDormant = true
        c.connectRetryDelays = [0.02]
        return CloudVoice(session: session, graph: graph, clips: nil, timeline: TurnTimeline(), configuration: c)
    }

    @Test func dormantOpensNothingAndTheEarWakesHer() async throws {
        let factory = FakeSocketFactory()
        let mints = Mints()
        let voice = try Self.voice(factory: factory, mints: mints, failing: false)
        await voice.start()
        let ear = ScriptedWakeEar()
        let c = WakeController(phrase: .default, ear: ear, mode: "openAI")
        let h = RecordingWakeHost()
        h.voice = voice
        c.host = h
        await c.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(factory.made.isEmpty, "W2: no socket while dormant")
        #expect(mints.count == 0, "W2: no key mint while dormant")
        ear.emit(WakeControllerTests.hit(onset: voice.captureFrame))
        for _ in 0..<100 where factory.made.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(h.calls.first == "eyesWake")
        #expect(factory.made.count == 1)
        #expect(mints.count == 1)
        c.closeCommand()
        #expect(!voice.isAwake)
        voice.shutdown()
    }

    /// W1: the network failing changes nothing about the local wake.
    @Test func wakeWorksWithEveryRequestFailing() async throws {
        let factory = FakeSocketFactory()
        let mints = Mints()
        let voice = try Self.voice(factory: factory, mints: mints, failing: true)
        await voice.start()
        let ear = ScriptedWakeEar()
        let c = WakeController(phrase: .default, ear: ear, mode: "openAI")
        let h = RecordingWakeHost()
        h.voice = voice
        c.host = h
        await c.start()
        ear.emit(WakeControllerTests.hit())
        try await Task.sleep(for: .milliseconds(100))
        #expect(h.calls.prefix(2) == ["eyesWake", "woken:phrase"])
        #expect(voice.isAwake, "woken locally; connecting fails on its own")
        voice.shutdown()
    }
}
