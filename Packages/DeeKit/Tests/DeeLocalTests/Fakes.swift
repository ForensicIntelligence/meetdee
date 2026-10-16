import Foundation
import Synchronization
import DeeRealtime
@testable import DeeLocal
import DeeMockServer

/// Hearing the test drives by hand.
final class FakeHearing: CascadeHearing, @unchecked Sendable {
    private let state = Mutex<(sink: (@Sendable (HearingEvent) -> Void)?, fed: Int, commits: Int, keywords: [String], stopped: Bool)>((nil, 0, 0, [], false))
    var timingSTT: TimingProfile.CascadeSTT { .onDevice }
    func start(sink: @escaping @Sendable (HearingEvent) -> Void) async throws { state.withLock { $0.sink = sink } }
    func feed(_ pcm: Data, atFrame frame: Int64) { state.withLock { $0.fed += pcm.count / 2 } }
    func commitNow() { state.withLock { $0.commits += 1 } }
    func clear() {}
    func setKeywords(_ words: [String]) { state.withLock { $0.keywords = words } }
    func stop() { state.withLock { $0.stopped = true } }
    var fedFrames: Int { state.withLock { $0.fed } }
    var keywords: [String] { state.withLock { $0.keywords } }
    func emit(_ e: HearingEvent) { state.withLock { $0.sink }?(e) }

    /// A whole user turn: started → stopped → committed → completed.
    func say(_ text: String, turn: Int, transcriptDelay: Double = 0) async {
        emit(.speechStarted(turn: turn, frame: Int64(turn) * 48_000))
        emit(.speechStopped(turn: turn, frame: Int64(turn) * 48_000 + 24_000))
        emit(.committed(turn: turn))
        if transcriptDelay > 0 { try? await Task.sleep(for: .seconds(transcriptDelay)) }
        emit(.transcriptCompleted(turn: turn, text: text))
    }
}

/// A voice that "speaks" 10 ms of PCM per character and records what it was asked.
final class FakeVoice: CascadeVoice, @unchecked Sendable {
    private let state = Mutex<(texts: [String], deliveries: [SpeechDelivery], prepared: Int)>(([], [], 0))
    let delay: Double
    init(delay: Double = 0) { self.delay = delay }
    var label: ProviderLabel { .onDevice }
    func prepare() async { state.withLock { $0.prepared += 1 } }
    func synthesize(_ text: String, delivery: SpeechDelivery) -> AsyncThrowingStream<Data, Error> {
        state.withLock { $0.texts.append(text); $0.deliveries.append(delivery) }
        let delay = self.delay
        return AsyncThrowingStream { c in
            Task {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                c.yield(Data(repeating: 1, count: max(480, text.count * 480)))
                c.finish()
            }
        }
    }
    var texts: [String] { state.withLock { $0.texts } }
    var deliveries: [SpeechDelivery] { state.withLock { $0.deliveries } }
}

/// Collects raw socket frames for order checks.
final class FrameLog: @unchecked Sendable {
    private let state = Mutex<[(at: Date, type: String, json: RealtimeJSON)]>([])
    func add(_ text: String) {
        let j = RealtimeJSON.parse(text) ?? .null
        state.withLock { $0.append((Date(), j["type"]?.stringValue ?? "", j)) }
    }
    var all: [(at: Date, type: String, json: RealtimeJSON)] { state.withLock { $0 } }
    var types: [String] { all.map(\.type) }
    func first(_ type: String) -> (at: Date, type: String, json: RealtimeJSON)? { all.first { $0.type == type } }
}

/// Wraps a socket so the test sees every server frame the session reads.
final class TappedSocket: RealtimeSocket, @unchecked Sendable {
    let inner: any RealtimeSocket
    let log: FrameLog
    let sentLog = Mutex<[String]>([])
    private let stream: AsyncStream<SocketEvent>
    init(_ inner: any RealtimeSocket, log: FrameLog) {
        self.inner = inner
        self.log = log
        let (s, c) = AsyncStream<SocketEvent>.makeStream(bufferingPolicy: .unbounded)
        stream = s
        Task {
            for await e in inner.incoming {
                if case .text(let t) = e { log.add(t) }
                c.yield(e)
            }
            c.finish()
        }
    }
    var incoming: AsyncStream<SocketEvent> { stream }
    func open() async throws { try await inner.open() }
    func send(_ text: String) { sentLog.withLock { $0.append(text) }; inner.send(text) }
    var pendingBytes: Int { inner.pendingBytes }
    func close(code: Int, reason: String?) { inner.close(code: code, reason: reason) }
}

/// Event collector for a RealtimeSession.
final class EventLog: @unchecked Sendable {
    private let state = Mutex<[RealtimeEvent]>([])
    init(_ session: RealtimeSession) {
        Task { for await e in session.events { self.state.withLock { $0.append(e) } } }
    }
    var events: [RealtimeEvent] { state.withLock { $0 } }
    func wait(timeout: Double = 10, _ predicate: ([RealtimeEvent]) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if predicate(events) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate(events)
    }
    var committed: [String] { events.compactMap { if case .userCommitted(let id, _) = $0 { id } else { nil } } }
    var done: [ResponseSummary] { events.compactMap { if case .responseDone(let s) = $0 { s } else { nil } } }
    var audioBytes: Int { events.reduce(0) { if case .assistantAudio(_, let pcm) = $1 { $0 + pcm.count } else { $0 } } }
    var sentences: [String] { events.compactMap { if case .assistantSentence(_, let t, _) = $0 { t } else { nil } } }
}

let sampleDNA = """
DEE DNA v11 — private. Never say these numbers.
1 IDENTITY & AGE
You are Dee, a little robot, 3 years old.
2 TEMPERAMENT
Playful 200/255.
3 FEELINGS NOW (0–255; slow ones: affection, trust)
Overall: happy. Joy 180/255 quite.
4 TOWARD THIS PERSON
Sam, a friend.
5 WHAT YOU KNOW ABOUT THEM
Has a dog.
6 WHO YOU ARE
Curious.
7 RIGHT NOW
Morning, kitchen.
8 THIS TURN
Sam asked a question.
Voice: bright and bubbly, a tiny robot's bright little voice.
9 HOW TO RESPOND
One or two short sentences.
"""

/// A cascaded session wired to the mock server.
struct CascadeRig {
    let server: DeeMockServer
    let hearing: FakeHearing
    let voice: FakeVoice
    let socket: CascadeSocket
    let session: RealtimeSession
    let log: EventLog
    let frames: FrameLog
    let recorder: TransportRecorder

    static func make(cases: Set<MockCase> = [.ollama], options: ((inout CascadeOptions) -> Void)? = nil,
                     voiceDelay: Double = 0, chat: DeeMockServer.ChatScript? = nil,
                     timing: TimingProfile = .cascaded(stt: .onDevice)) async throws -> CascadeRig {
        let server = try await DeeMockServer.start(cases: cases, chat: chat)
        let hearing = FakeHearing()
        let voice = FakeVoice(delay: voiceDelay)
        let recorder = TransportRecorder()
        let transport = Transport.live(redirects: .refuse, recorder: recorder)
        let client = CompatClient(base: server.baseURL, key: nil, transport: transport)
        var o = CascadeOptions(model: "qwen3.8:27b-mlx-bf16")
        o.warmUps = false
        o.keepAlive = "30m"
        options?(&o)
        let socket = CascadeSocket(options: o, hearing: hearing, chat: VendorChat(client: client, vendor: cases.contains(.ollama) ? .ollama : .other),
                                   voice: voice)
        let frames = FrameLog()
        var config = RealtimeSessionConfig()
        timing.apply(to: &config)
        config.autoReconnect = false
        let tapped = TappedSocket(socket, log: frames)
        let session = RealtimeSession(config: config, credentials: { _ in .direct("") }, socketFactory: { _ in tapped })
        let log = EventLog(session)
        try await session.connect()
        return CascadeRig(server: server, hearing: hearing, voice: voice, socket: socket, session: session, log: log,
                          frames: frames, recorder: recorder)
    }

    func stop() async {
        await session.close()
        server.stop()
    }

    /// Chat requests' JSON bodies.
    var chatBodies: [[String: Any]] {
        server.requests.filter { $0.path == "/v1/chat/completions" || $0.path == "/api/chat" }.compactMap(\.jsonObject)
    }
}

func messages(_ body: [String: Any]) -> [[String: Any]] { (body["messages"] as? [[String: Any]]) ?? [] }

/// The first problem a socket reports (nil after `timeout`).
func firstProblem(_ socket: CascadeSocket, timeout: Double = 10) async -> ProviderIssue? {
    let box = Mutex<ProviderIssue?>(nil)
    let t = Task { for await p in socket.problems { box.withLock { $0 = p }; return } }
    let end = Date().addingTimeInterval(timeout)
    while Date() < end, box.withLock({ $0 }) == nil { try? await Task.sleep(for: .milliseconds(20)) }
    t.cancel()
    return box.withLock { $0 }
}

@testable import DeeWake

/// A scripted on-device recogniser (SpeechDetector + transcriber) for LocalHearing.
final class FakeEngine: SpeechEngine, @unchecked Sendable {
    private let state = Mutex<(segs: [AsyncStream<SpeechSegment>.Continuation], acts: [AsyncStream<SpeechActivity>.Continuation],
                               fed: Int, finalized: [Int64], contextual: [String], began: Int, ended: Int)>(([], [], 0, [], [], 0, 0))
    /// Finals sent when a commit finalizes through a frame (text per call).
    var onFinalize: (@Sendable (Int64) -> SpeechSegment?)?
    func begin(contextualStrings: [String]) async throws { state.withLock { $0.contextual = contextualStrings; $0.began += 1 } }
    func end() async { state.withLock { $0.ended += 1 } }
    func feed(_ pcm16k: [Int16], frame24k: Int64) { state.withLock { $0.fed += pcm16k.count } }
    func finalize(throughFrame24k: Int64) async {
        state.withLock { $0.finalized.append(throughFrame24k) }
        if let seg = onFinalize?(throughFrame24k) { segment(seg) }
    }
    func segments() async -> AsyncStream<SpeechSegment> {
        let (s, c) = AsyncStream<SpeechSegment>.makeStream(bufferingPolicy: .unbounded)
        state.withLock { $0.segs.append(c) }
        return s
    }
    func voiceActivity() async -> AsyncStream<SpeechActivity> {
        let (s, c) = AsyncStream<SpeechActivity>.makeStream(bufferingPolicy: .unbounded)
        state.withLock { $0.acts.append(c) }
        return s
    }
    func activity(_ speech: Bool, _ start: Int64, _ end: Int64) {
        for c in state.withLock({ $0.acts }) { c.yield(SpeechActivity(speechDetected: speech, startFrame: start, endFrame: end)) }
    }
    func segment(_ s: SpeechSegment) { for c in state.withLock({ $0.segs }) { c.yield(s) } }
    var fed: Int { state.withLock { $0.fed } }
    var finalized: [Int64] { state.withLock { $0.finalized } }
    var contextual: [String] { state.withLock { $0.contextual } }
}
