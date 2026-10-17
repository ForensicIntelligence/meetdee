import AVFAudio
import DeeCore
import DeeMemory
import DeeMind
import DeeRealtime
import DeeSelf
import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

// The brain end to end, offline: the real AudioGraph in manual rendering, the real
// CloudVoice and RealtimeSession (which carries the DNA), a scripted server on FakeSockets,
// a real Mind and Cortex (StandaloneHost), and RealtimeBrain on top.

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
    static func transcriptFailed(_ item: String) -> ServerEvent {
        .inputTranscriptionFailed(.init(itemID: item, error: nil))
    }
    static func responseCreated(_ id: String) -> ServerEvent {
        .responseCreated(.init(eventID: "ev_rc_\(id)", response: ResponseObject(
            id: id, object: "realtime.response", status: "in_progress", output: [])))
    }
    static func messageAdded(_ resp: String, _ item: String) -> ServerEvent {
        .outputItemAdded(.init(eventID: "ev_oa_\(item)", responseID: resp, item: RealtimeItem(
            id: item, object: "realtime.item", type: "message", status: "in_progress", role: "assistant", content: [])))
    }
    /// `conversation.item.added` (the live server sends it for every item that
    /// enters the conversation; the session's ledger is built from it).
    static func itemAdded(_ item: String, role: String) -> ServerEvent {
        .itemAdded(.init(item: RealtimeItem(id: item, type: "message", role: role)))
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
    static func callDone(_ resp: String, item: String, call: String, name: String, args: String) -> ServerEvent {
        .functionCallArgumentsDone(.init(responseID: resp, itemID: item, callID: call, name: name, arguments: args))
    }
    static func responseCreated(_ id: String, metadata: [String: String]) -> ServerEvent {
        .responseCreated(.init(eventID: "ev_rc_\(id)", response: ResponseObject(
            id: id, object: "realtime.response", status: "in_progress", output: [], metadata: metadata)))
    }
    static func textDone(_ resp: String, _ item: String, _ text: String) -> ServerEvent {
        .outputTextDone(.init(responseID: resp, itemID: item, text: text))
    }
    static func responseDone(_ id: String, status: String = "completed") -> ServerEvent {
        .responseDone(.init(eventID: "ev_rd_\(id)", response: ResponseObject(
            id: id, object: "realtime.response", status: status, output: [])))
    }
}

enum Sig {
    static func harmonic(hz: Double, amplitude: Double, rate: Double, seconds: Double) -> [Float] {
        let n = Int(rate * seconds)
        return (0..<n).map { i in
            var v = 0.0
            for h in 1...6 { v += sin(2 * .pi * hz * Double(h) * Double(i) / rate) / Double(h) }
            return Float(amplitude * v / 2)
        }
    }
    static func noise(amplitude: Double, count: Int, seed: UInt64) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let u = Double(state >> 11) / Double(1 << 53)
            return Float(amplitude * (u * 2 - 1))
        }
    }
    static func buffer(_ samples: [Float], rate: Double) -> AVAudioPCMBuffer {
        let f = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
        b.frameLength = AVAudioFrameCount(samples.count)
        for (i, v) in samples.enumerated() { b.floatChannelData![0][i] = v }
        return b
    }
    /// `ms` of a 24 kHz Int16 LE tone.
    static func pcm(ms: Double, hz: Double = 440, amplitude: Double = 0.3) -> Data {
        let n = Int(ms / 1000 * 24_000)
        let s: [Int16] = (0..<n).map { Int16((amplitude * sin(2 * .pi * hz * Double($0) / 24_000) * 32767).rounded()) }
        return s.withUnsafeBytes { Data($0) }
    }
}

/// A tool the tests control.
struct FakeTool: AgentTool {
    let name: String
    let reply: String
    var spec: ToolSpec { ToolSpec(name: name, description: "Test \(name).", parameters: [ToolParameter("fact", .string, "x", required: false)]) }
    func run(_ call: ToolCall) async throws -> String { reply }
}

@MainActor
final class BrainRig {
    let graph: AudioGraph
    let factory: FakeSocketFactory
    let clock = ManualRealtimeClock()
    let session: RealtimeSession
    let voice: CloudVoice
    let host: StandaloneHost
    let brain: RealtimeBrain
    private var noiseSeed: UInt64 = 1
    private(set) var output: [Float] = []
    static let rate = 48_000.0

    /// `exactWords`: every turn waits for its words (a stated mood: the exact rule).
    init(identified: Bool = true, engaged: Bool = true, exactWords: Bool = false, tools: [any AgentTool] = [],
         sockets: [FakeSocket] = [], memory: MemoryStore? = nil, person: UUID? = nil,
         configure: (inout RealtimeSessionConfig) -> Void = { _ in },
         tune: (inout RealtimeBrain.Options) -> Void = { _ in }, duckOnOnset: Bool? = nil) async throws {
        graph = try AudioGraph.manual(sampleRate: Self.rate, channels: 1)
        factory = FakeSocketFactory(sockets) { FakeSocket(request: $0, sessionID: "sess_\(Int.random(in: 1000...9999))") }
        var config = CloudSettings().sessionConfig()
        configure(&config)
        session = RealtimeSession(config: config,
                                  credentials: { _ in .ephemeral("ek_test", expiresAt: Date().addingTimeInterval(600)) },
                                  socketFactory: factory.factory, clock: clock)
        var c = CloudVoice.Configuration()
        c.autoTick = false
        c.classifySounds = false
        c.connectRetryDelays = [0.02]
        c.duckOnOnset = duckOnOnset
        voice = CloudVoice(session: session, graph: graph, clips: nil, timeline: TurnTimeline(), configuration: c)
        let mind = try Mind(databaseURL: nil)
        host = await StandaloneHost(mind: mind, memory: memory, person: person ?? (identified ? UUID() : nil))
        host.engaged = engaged
        if exactWords { host.modeSignalsOverride = CueModeSignals(statedHypothesis: true, turnsThisConversation: 1) }
        var options = RealtimeBrain.Options()
        options.tick = 0.01
        options.toolFollowUpWait = 0.3
        tune(&options)
        brain = RealtimeBrain(voice: voice, host: host,
                              toolbox: BrainToolbox(tools: tools), options: options)
        host.brain = brain
    }

    var socket: FakeSocket { factory.made.last! }

    func start() async throws {
        await brain.start()
        await voice.start()
        let ok = await until { self.brain.connected }
        try #require(ok, "never connected")
    }

    /// 20 ms of microphone (`mic`, else room noise), 20 ms of output, housekeeping.
    func step(_ mic: [Float]? = nil) throws {
        let n = Int(Self.rate * 0.02)
        noiseSeed += 1
        let samples = mic ?? Sig.noise(amplitude: 0.001, count: n, seed: noiseSeed)
        graph.inject(Sig.buffer(samples, rate: Self.rate))
        let out = try graph.render(frames: AVAudioFrameCount(n))
        output += Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
        voice.tick()
    }

    func quiet(_ seconds: Double) throws {
        for _ in 0..<Int((seconds / 0.02).rounded()) { try step() }
    }

    func talk(_ seconds: Double, amplitude: Double = 0.3) throws {
        let x = Sig.harmonic(hz: 180, amplitude: amplitude, rate: Self.rate, seconds: seconds)
        let size = Int(Self.rate * 0.02)
        for i in stride(from: 0, to: x.count - size + 1, by: size) { try step(Array(x[i..<(i + size)])) }
    }

    func push(_ events: ServerEvent..., on s: FakeSocket? = nil) {
        events.forEach { (s ?? socket).push($0) }
    }

    /// A user utterance the server reports (speech started/stopped, committed).
    func utterance(_ item: String, startMs: Int = 100, endMs: Int = 900) {
        push(Srv.speechStarted(item, ms: startMs), Srv.speechStopped(item, ms: endMs), Srv.committed(item))
    }

    /// Dee's reply audio and transcript for `resp` / `item`.
    func reply(_ resp: String, _ item: String, ms: Int, text: String) {
        push(Srv.responseCreated(resp), Srv.messageAdded(resp, item), Srv.itemAdded(item, role: "assistant"))
        var left = ms
        while left > 0 {
            let k = min(100, left)
            push(Srv.audio(resp, item, Sig.pcm(ms: Double(k))))
            left -= k
        }
        push(Srv.transcript(resp, item, text), Srv.audioDone(resp, item), Srv.transcriptDone(resp, item, text),
             Srv.responseDone(resp))
    }

    // MARK: Frames on the wire

    /// Every client frame on `s` (default: the newest socket), audio left out, as JSON.
    /// The session's random per-connection id tag reads `tagabc` here
    /// (`dna_x7k2p9_3` → `dna_tagabc_3`; the counter runs across connections).
    func frames(on s: FakeSocket? = nil) -> [[String: Any]] {
        (s ?? socket).sent.compactMap { text -> [String: Any]? in
            guard !text.hasPrefix(#"{"type":"input_audio_buffer.append""#) else { return nil }
            let normal = Self.normalTags(text)
            return try? JSONSerialization.jsonObject(with: Data(normal.utf8)) as? [String: Any]
        }
    }

    static func normalTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"\b(dna|txt)_[a-z0-9]{6}_(\d+)"#, with: "$1_tagabc_$2", options: .regularExpression)
    }

    /// Frames after the session handshake, summarised: "dna:<id>", "user:<text>",
    /// "delete:<id>", "response.create", "output:<call>", other types as is.
    func trail(on s: FakeSocket? = nil) -> [String] {
        frames(on: s).compactMap { o -> String? in
            let type = o["type"] as? String ?? ""
            switch type {
            case "session.update", "input_audio_buffer.append": return nil
            case "conversation.item.create":
                let item = o["item"] as? [String: Any] ?? [:]
                let content = (item["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
                if item["role"] as? String == "system", content.hasPrefix("DEE DNA") { return "dna:\(item["id"] as? String ?? "?")" }
                if item["role"] as? String == "user" { return "user:\(content)" }
                if item["type"] as? String == "function_call_output" { return "output:\(item["call_id"] as? String ?? "?")" }
                return "item:\(item["role"] as? String ?? item["type"] as? String ?? "?")"
            case "conversation.item.delete": return "delete:\(o["item_id"] as? String ?? "?")"
            case "conversation.item.truncate": return "truncate:\(o["item_id"] as? String ?? "?")"
            default: return type
            }
        }
    }

    /// The text of DNA item `id`.
    func dnaText(_ id: String, on s: FakeSocket? = nil) -> String? {
        for o in frames(on: s) where o["type"] as? String == "conversation.item.create" {
            let item = o["item"] as? [String: Any] ?? [:]
            if item["id"] as? String == id { return (item["content"] as? [[String: Any]])?.first?["text"] as? String }
        }
        return nil
    }

    func responseCreates(on s: FakeSocket? = nil) -> [[String: Any]] {
        frames(on: s).filter { $0["type"] as? String == "response.create" }
    }

    func count(_ entry: String, on s: FakeSocket? = nil) -> Int { trail(on: s).filter { $0 == entry }.count }

    /// Polls `condition` (main actor) for up to `timeout` seconds.
    func until(_ timeout: Double = 3, _ condition: @escaping @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    func settle() async {
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
    }

    func shutdown() {
        brain.stop()
        voice.shutdown()
    }
}
