import Foundation
import Synchronization
import DeeRealtime
import DeeWake

// MARK: - The on-device engine seam

/// What LocalHearing needs from Apple's on-device recogniser (`DeeWake.OnDeviceSpeech`);
/// a fake in tests. Frames are on the socket's fed-frame clock (LocalHearing feeds it so).
public protocol SpeechEngine: Sendable {
    func begin(contextualStrings: [String]) async throws
    func end() async
    func feed(_ pcm16k: [Int16], frame24k: Int64)
    func finalize(throughFrame24k: Int64) async
    func segments() async -> AsyncStream<SpeechSegment>
    func voiceActivity() async -> AsyncStream<SpeechActivity>
}

/// `OnDeviceSpeech` as a hearing engine (its own analyzer, fed the uplinked frames, with the
/// SpeechDetector on: one analyzer for the turn detector and the transcriber).
public final class OnDeviceSpeechEngine: SpeechEngine, @unchecked Sendable {
    public let speech: OnDeviceSpeech
    private let user = "cascade"
    public init(speech: OnDeviceSpeech = OnDeviceSpeech()) { self.speech = speech }

    public func begin(contextualStrings: [String]) async throws {
        do {
            try await speech.acquire(user, .init(contextualStrings: contextualStrings, detector: true, punctuation: true))
        } catch {
            throw ProviderIssue.onDeviceSpeechUnavailable(.hearing)
        }
    }
    public func end() async { await speech.release(user) }
    public func feed(_ pcm16k: [Int16], frame24k: Int64) { speech.feed(pcm16k, captureFrame24k: frame24k) }
    public func finalize(throughFrame24k: Int64) async { await speech.finalize(throughFrame24k: throughFrame24k) }
    public func segments() async -> AsyncStream<SpeechSegment> { await speech.results() }
    public func voiceActivity() async -> AsyncStream<SpeechActivity> { await speech.activity() }
}

// MARK: - Turn detection (pure)

/// server_vad-equivalent endpointing on local evidence (contract §2, mode 3):
/// voice = Apple SpeechDetector AND EarCore's bed-proof `voiceActive`. A turn starts after
/// `minSpeechMs` of voice (reported `prefixMs` earlier, never before the last commit) and
/// ends after `silenceMs` without voice (stopped at the last voice + silence, then committed).
/// No energy VAD.
public struct TurnDetectorCore: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case started(turn: Int, frame: Int64)
        case stopped(turn: Int, frame: Int64)
        case committed(turn: Int, startFrame: Int64, endFrame: Int64)
    }

    public var prefixMs = 300
    public var silenceMs = 300
    public var minSpeechMs = 100

    private(set) var turn = 0
    private(set) var open = false
    private var voiceRunStart: Int64?
    private var lastVoiceEnd: Int64 = 0
    private var turnStart: Int64 = 0
    private var lastCommitEnd: Int64 = 0

    public init() {}

    var frames: (prefix: Int64, silence: Int64, minSpeech: Int64) {
        (Int64(prefixMs * 24), Int64(silenceMs * 24), Int64(minSpeechMs * 24))
    }

    /// Evidence for `[start, end)`: voiced or not. Feed in order without gaps.
    public mutating func evidence(start: Int64, end: Int64, voice: Bool) -> [Event] {
        guard end > start else { return [] }
        var out: [Event] = []
        let f = frames
        if voice {
            if voiceRunStart == nil { voiceRunStart = start }
            lastVoiceEnd = end
            if !open, let run = voiceRunStart, end - run >= f.minSpeech {
                open = true
                turn += 1
                turnStart = max(lastCommitEnd, run - f.prefix, 0)
                out.append(.started(turn: turn, frame: turnStart))
            }
        } else {
            if !open { voiceRunStart = nil }
            if open, end - lastVoiceEnd >= f.silence {
                let stop = lastVoiceEnd + f.silence
                out.append(.stopped(turn: turn, frame: stop))
                out.append(.committed(turn: turn, startFrame: turnStart, endFrame: stop))
                open = false
                voiceRunStart = nil
                lastCommitEnd = stop
            } else if !open {
                voiceRunStart = nil
            }
        }
        return out
    }

    /// `input_audio_buffer.commit`: close the open turn now, or make one from the buffer since the last commit.
    public mutating func commitNow(at frame: Int64) -> [Event] {
        var out: [Event] = []
        if open {
            out.append(.stopped(turn: turn, frame: frame))
            out.append(.committed(turn: turn, startFrame: turnStart, endFrame: frame))
        } else {
            guard frame > lastCommitEnd else { return [] }
            turn += 1
            out.append(.committed(turn: turn, startFrame: lastCommitEnd, endFrame: frame))
        }
        open = false
        voiceRunStart = nil
        lastCommitEnd = frame
        return out
    }

    public mutating func clear(at frame: Int64) {
        open = false
        voiceRunStart = nil
        lastCommitEnd = frame
    }
}

// MARK: - Name rewrite

/// The on-device transcriber hears "Dee" as KD / Heidi / Haidee / Hey D. In address position
/// (at the start, before a pause or after a greeting) it becomes "Dee"; elsewhere it is left
/// alone ("Heidi Klum was on TV").
public enum NameRewrite {
    static let variants = ["k\\.? ?d\\.?", "heidi", "haidee", "haydee", "hyde", "hidi", "dee", "d"]

    public static func rewrite(_ text: String) -> String {
        let alt = variants.joined(separator: "|")
        var s = text
        // "Hey D what time…" / "Hi KD, …": after a greeting, the name needs no comma.
        s = s.replacingOccurrences(of: "^(\\s*(?:hey|hi|okay|ok|hello)[,]?\\s+)(?:\(alt))\\b",
                                   with: "$1Dee", options: [.regularExpression, .caseInsensitive])
        // "Heidi, what's up" / "KD?" alone: the name then a pause.
        s = s.replacingOccurrences(of: "^(\\s*)(?:\(alt))(?=\\s*[,.!?]|\\s*$)",
                                   with: "$1Dee", options: [.regularExpression, .caseInsensitive])
        // "…, Heidi?" at the end of a question.
        s = s.replacingOccurrences(of: ",\\s*(?:\(alt))(?=\\s*[?.!]?\\s*$)",
                                   with: ", Dee", options: [.regularExpression, .caseInsensitive])
        // "Haidee" for "Hi Dee" as one word at the start.
        s = s.replacingOccurrences(of: "^(\\s*)(?:haidee|heidi|haydee)(?=\\s+(?:what|how|can|could|do|are|is|tell|i|we|you|let)\\b)",
                                   with: "$1Hi Dee,", options: [.regularExpression, .caseInsensitive])
        return s
    }
}

// MARK: - Local hearing (mode 3): on-device turns, on-device or LAN speech-to-text

public enum LocalSTT: Sendable {
    /// Apple DictationTranscriber on this iPhone (deltas + fast finals at each commit).
    case onDevice
    /// A LAN `/v1/audio/transcriptions` server: WAV of the committed span, no deltas.
    case lan(CompatClient, model: String)
}

public final class LocalHearing: CascadeHearing, @unchecked Sendable {
    public let stt: LocalSTT
    let engine: any SpeechEngine
    let uplink: UplinkActivity?
    let rewrite: Bool
    /// Seconds a commit waits for its on-device final before completing with what it has.
    public var finalWait: Double = 1.0

    private struct State {
        var sink: (@Sendable (HearingEvent) -> Void)?
        var core = TurnDetectorCore()
        var fed: Int64 = 0
        var evidenceUntil: Int64 = 0
        var activity: [(start: Int64, end: Int64, speech: Bool)] = []
        var down = Downsampler24to16()
        var ring = Data()
        var ringStart: Int64 = 0
        var turns: [Int: Turn] = [:]
        var uplinkOffset: Int64?
        var keywords: [String] = ["Dee"]
        var stopped = false
    }
    struct Turn {
        var start: Int64
        var end: Int64?
        var committed = false
        var finals: [(start: Int64, end: Int64, text: String)] = []
        var volatile = ""
        var emitted = ""
        var completed = false
    }
    private let state = Mutex(State())
    private var tasks: [Task<Void, Never>] = []

    public init(stt: LocalSTT, engine: any SpeechEngine = OnDeviceSpeechEngine(), uplink: UplinkActivity? = nil,
                rewriteName: Bool = true) {
        self.stt = stt; self.engine = engine; self.uplink = uplink; self.rewrite = rewriteName
    }

    public var timingSTT: TimingProfile.CascadeSTT {
        if case .lan = stt { .lanREST } else { .onDevice }
    }

    public func start(sink: @escaping @Sendable (HearingEvent) -> Void) async throws {
        state.withLock { $0.sink = sink }
        let words = state.withLock { $0.keywords }
        try await engine.begin(contextualStrings: words)
        let segs = await engine.segments()
        let acts = await engine.voiceActivity()
        tasks.append(Task { [weak self] in for await s in segs { self?.segment(s) } })
        tasks.append(Task { [weak self] in for await a in acts { self?.activity(a) } })
    }

    public func stop() {
        state.withLock { $0.stopped = true; $0.sink = nil }
        tasks.forEach { $0.cancel() }
        let engine = self.engine
        Task { await engine.end() }
    }

    public func setKeywords(_ words: [String]) {
        state.withLock { $0.keywords = Array(Set(["Dee"] + words)).sorted() }
    }

    public func feed(_ pcm: Data, atFrame frame: Int64) {
        let samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let out = state.withLock { s -> (samples: [Int16], firstFrame24k: Int64?) in
            s.fed = frame + Int64(samples.count)
            s.ring.append(pcm)
            let maxBytes = 24_000 * 2 * 30
            if s.ring.count > maxBytes {
                let drop = s.ring.count - maxBytes
                s.ring.removeFirst(drop)
                s.ringStart += Int64(drop / 2)
            }
            if let up = uplink {
                // The session's feed counter is ahead of ours by a fixed origin.
                s.uplinkOffset = up.latestFedFrame - s.fed
            }
            return s.down.process(samples, firstFrame24k: frame)
        }
        if let first = out.firstFrame24k, !out.samples.isEmpty { engine.feed(out.samples, frame24k: first) }
    }

    public func commitNow() {
        let events = state.withLock { s in s.core.commitNow(at: s.fed) }
        handle(events)
    }

    public func clear() {
        state.withLock { s in s.core.clear(at: s.fed) }
    }

    /// SpeechDetector result: evidence up to its end, ANDed with EarCore's per-frame voice.
    func activity(_ a: SpeechActivity) {
        let events = state.withLock { s -> [TurnDetectorCore.Event] in
            var out: [TurnDetectorCore.Event] = []
            var start = max(a.startFrame, s.evidenceUntil)
            let end = a.endFrame
            guard end > start else { return [] }
            // Walk 20 ms steps so EarCore's evidence can veto a bed the detector calls speech.
            let step: Int64 = 480
            while start < end {
                let e = min(end, start + step)
                var voice = a.speechDetected
                if voice, let up = uplink, let off = s.uplinkOffset {
                    voice = up.voiceActive(atFedFrame: (start + e) / 2 + off) ?? true
                }
                out += s.core.evidence(start: start, end: e, voice: voice)
                start = e
            }
            s.evidenceUntil = end
            return out
        }
        handle(events)
    }

    private func handle(_ events: [TurnDetectorCore.Event]) {
        for e in events {
            switch e {
            case .started(let turn, let frame):
                state.withLock { $0.turns[turn] = Turn(start: frame) }
                emit(.speechStarted(turn: turn, frame: frame))
            case .stopped(let turn, let frame):
                emit(.speechStopped(turn: turn, frame: frame))
            case .committed(let turn, let start, let end):
                state.withLock { s in
                    var t = s.turns[turn] ?? Turn(start: start)
                    t.end = end
                    t.committed = true
                    s.turns[turn] = t
                }
                emit(.committed(turn: turn))
                transcribe(turn: turn, start: start, end: end)
            }
        }
    }

    private func emit(_ e: HearingEvent) {
        let sink = state.withLock { $0.sink }
        sink?(e)
    }

    // MARK: Speech-to-text

    private func transcribe(turn: Int, start: Int64, end: Int64) {
        switch stt {
        case .onDevice:
            let engine = self.engine
            let wait = finalWait
            Task { [weak self] in
                await engine.finalize(throughFrame24k: end)
                let deadline = Date().addingTimeInterval(wait)
                while Date() < deadline {
                    if self?.finalCovers(turn: turn, end: end) == true { break }
                    try? await Task.sleep(for: .milliseconds(15))
                }
                self?.complete(turn: turn)
            }
        case .lan(let client, let model):
            let wav = state.withLock { s -> Data in
                let from = max(0, Int((start - s.ringStart) * 2))
                let to = min(s.ring.count, Int((end - s.ringStart) * 2))
                return WAV.pcm16(to > from ? s.ring.subdata(in: from..<to) : Data(), rate: 24_000)
            }
            let prompt = state.withLock { $0.keywords.joined(separator: ", ") }
            Task { [weak self] in
                do {
                    let text = try await client.transcribe(wav: wav, model: model, prompt: prompt)
                    self?.finish(turn: turn, text: text)
                } catch {
                    let issue = error.providerIssue(host: client.host, model: model, label: client.label)
                    self?.emit(.failed(issue))
                    self?.emitFailed(turn: turn, message: issue.message)
                }
            }
        }
    }

    private func finalCovers(turn: Int, end: Int64) -> Bool {
        state.withLock { s in
            guard let t = s.turns[turn] else { return true }
            let lastFinal = t.finals.map(\.end).max() ?? Int64.min
            return lastFinal >= end - 24 * 350 && t.volatile.isEmpty
        }
    }

    private func complete(turn: Int) {
        let text = state.withLock { s -> String? in
            guard var t = s.turns[turn], !t.completed else { return nil }
            t.completed = true
            s.turns[turn] = t
            var text = t.finals.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")
            if text.trimmingCharacters(in: .whitespaces).isEmpty { text = t.volatile }
            return text
        }
        guard let text else { return }
        finish(turn: turn, text: text, already: true)
    }

    private func finish(turn: Int, text raw: String, already: Bool = false) {
        if !already {
            let fresh = state.withLock { s -> Bool in
                guard s.turns[turn]?.completed != true else { return false }
                s.turns[turn]?.completed = true
                return true
            }
            guard fresh else { return }
        }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        if rewrite { text = NameRewrite.rewrite(text) }
        emit(.transcriptCompleted(turn: turn, text: text))
    }

    private func emitFailed(turn: Int, message: String) {
        let fresh = state.withLock { s -> Bool in
            guard s.turns[turn]?.completed != true else { return false }
            s.turns[turn]?.completed = true
            return true
        }
        if fresh { emit(.transcriptFailed(turn: turn, message: message)) }
    }

    /// An on-device result: assigned to the turn it falls in; deltas are append-only.
    func segment(_ seg: SpeechSegment) {
        guard case .onDevice = stt else { return }
        let deltas = state.withLock { s -> [(Int, String)] in
            let at = seg.startFrame ?? s.fed
            // The turn this text belongs to: the latest one starting at or before it (finals carry true times).
            let candidates = s.turns.filter { !$0.value.completed && $0.value.start <= at + 24 * 200 }
            guard let (turn, _) = candidates.max(by: { $0.key < $1.key }) ?? s.turns.filter({ !$0.value.completed }).min(by: { $0.key < $1.key }) else {
                return []
            }
            var t = s.turns[turn]!
            if seg.isFinal {
                if !seg.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    t.finals.append((seg.startFrame ?? at, seg.endFrame ?? at, seg.text.trimmingCharacters(in: .whitespaces)))
                }
                t.volatile = ""
            } else {
                t.volatile = seg.text.trimmingCharacters(in: .whitespaces)
            }
            // Append-only deltas: the stable text (finals + volatile) only when it extends what went out.
            let finals = t.finals.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")
            let candidate = [finals, t.volatile].filter { !$0.isEmpty }.joined(separator: " ")
            var out: [(Int, String)] = []
            if candidate.hasPrefix(t.emitted), candidate.count > t.emitted.count {
                // Only whole words: cut at the last space unless final.
                var newText = String(candidate.dropFirst(t.emitted.count))
                if !seg.isFinal, let sp = newText.lastIndex(of: " ") { newText = String(newText[..<sp]) } else if !seg.isFinal { newText = "" }
                if !newText.isEmpty {
                    t.emitted += newText
                    out.append((turn, newText))
                }
            }
            s.turns[turn] = t
            return out
        }
        for (turn, d) in deltas { emit(.transcriptDelta(turn: turn, delta: d)) }
    }
}

// MARK: - WAV

enum WAV {
    /// Mono PCM16 little-endian WAV.
    static func pcm16(_ pcm: Data, rate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}

extension Error {
    /// A provider issue for any error from a CompatClient call.
    func providerIssue(host: String, vendor: Vendor = .other, model: String = "", label: ProviderLabel) -> ProviderIssue {
        if let i = self as? ProviderIssue { return i }
        if let c = self as? CompatError { return c.issue(host: host, vendor: vendor, model: model, label: Optional(label)) }
        return .unreachable(host: host, vendor: vendor)
    }
}

// MARK: - OpenAI realtime transcription (mode 2)

/// Mode 2's hearing: an OpenAI realtime **transcription** session over WebSocket (server VAD
/// 300/300/0.5, gpt-transcribe, streaming deltas), minted per socket with
/// `OpenAIAuth(sessionType: .transcription)`. A refused mint (400/404) is a hard
/// `.transcriptionUnavailable`: there is no direct-key or other fallback.
public final class OpenAITranscriptionHearing: CascadeHearing, @unchecked Sendable {
    public typealias Credential = @Sendable () async throws -> RealtimeCredential
    let transport: Transport
    let credential: Credential
    let url: URL
    public var openTimeout: Double = 10

    private struct State {
        var sink: (@Sendable (HearingEvent) -> Void)?
        var socket: (any RealtimeSocket)?
        var ready = false
        var pending: [String] = []
        var turns: [String: Int] = [:]
        var nextTurn = 0
        var stopped = false
    }
    private let state = Mutex(State())
    private var reader: Task<Void, Never>?

    public init(transport: Transport, credential: @escaping Credential, url: URL = OpenAITranscription.url) {
        self.transport = transport; self.credential = credential; self.url = url
    }

    public var timingSTT: TimingProfile.CascadeSTT { .openAIRealtime }

    public func start(sink: @escaping @Sendable (HearingEvent) -> Void) async throws {
        state.withLock { $0.sink = sink }
        let cred: RealtimeCredential
        do {
            cred = try await credential()
        } catch let e as RealtimeAuthError {
            switch e {
            case .noKey: throw ProviderIssue.noOpenAIKey
            case .unauthorized: throw ProviderIssue.badOpenAIKey
            case .rateLimited: throw ProviderIssue.rateLimited(.openAI)
            case .transcriptionUnavailable: throw ProviderIssue.transcriptionUnavailable
            @unknown default: throw ProviderIssue.transcriptionUnavailable
            }
        } catch {
            throw ProviderIssue.unreachable(host: "api.openai.com", vendor: .openAI)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(cred.bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("stt", forHTTPHeaderField: Transport.purposeHeader)
        let socket = transport.socketFactory(request)
        do {
            try await withDeadline(openTimeout) { try await socket.open() }
        } catch let f as SocketFailure {
            switch f {
            case .unauthorized: throw ProviderIssue.badOpenAIKey
            case .handshake(let s) where s == 400 || s == 404: throw ProviderIssue.transcriptionUnavailable
            case .rateLimited: throw ProviderIssue.rateLimited(.openAI)
            default: throw ProviderIssue.unreachable(host: "api.openai.com", vendor: .openAI)
            }
        } catch {
            throw ProviderIssue.unreachable(host: "api.openai.com", vendor: .openAI)
        }
        state.withLock { $0.socket = socket }
        // Ready at session.created; audio fed before it is queued and sent in order.
        let created = Mutex<CheckedContinuation<Void, Never>?>(nil)
        reader = Task { [weak self] in
            for await e in socket.incoming {
                guard let self else { return }
                switch e {
                case .text(let t):
                    let ev = ServerEvent.parse(t)
                    if case .sessionCreated = ev { created.withLock { $0?.resume(); $0 = nil }; self.markReady() }
                    self.server(ev)
                case .closed(_, _, let failure):
                    created.withLock { $0?.resume(); $0 = nil }
                    let stopped = self.state.withLock { $0.stopped }
                    if !stopped, failure != nil {
                        self.emit(.failed(.unreachable(host: "api.openai.com", vendor: .openAI)))
                    }
                }
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            created.withLock { $0 = c }
            Task { try? await Task.sleep(for: .seconds(5)); created.withLock { $0?.resume(); $0 = nil } }
        }
        markReady()
    }

    private func markReady() {
        let (socket, pending) = state.withLock { s -> ((any RealtimeSocket)?, [String]) in
            guard !s.ready else { return (nil, []) }
            s.ready = true
            defer { s.pending.removeAll() }
            return (s.socket, s.pending)
        }
        for p in pending { socket?.send(p) }
    }

    private func send(_ event: ClientEvent) {
        guard let text = try? event.jsonText() else { return }
        let socket = state.withLock { s -> (any RealtimeSocket)? in
            if !s.ready { s.pending.append(text); return nil }
            return s.socket
        }
        socket?.send(text)
    }

    public func feed(_ pcm: Data, atFrame frame: Int64) { send(.inputAudioAppend(audio: pcm.base64EncodedString())) }
    public func commitNow() { send(.inputAudioCommit()) }
    public func clear() { send(.inputAudioClear()) }
    public func setKeywords(_ words: [String]) {}   // they ride on the mint (OpenAITranscription.Session.keywords)

    public func stop() {
        let socket = state.withLock { s -> (any RealtimeSocket)? in s.stopped = true; s.sink = nil; return s.socket }
        socket?.close(code: 1000, reason: nil)
        reader?.cancel()
    }

    private func turn(for itemID: String) -> Int {
        state.withLock { s in
            if let t = s.turns[itemID] { return t }
            s.nextTurn += 1
            s.turns[itemID] = s.nextTurn
            return s.nextTurn
        }
    }

    private func emit(_ e: HearingEvent) {
        let sink = state.withLock { $0.sink }
        sink?(e)
    }

    func server(_ e: ServerEvent) {
        switch e {
        case .speechStarted(let x): emit(.speechStarted(turn: turn(for: x.itemID), frame: Int64(x.audioStartMs) * 24))
        case .speechStopped(let x): emit(.speechStopped(turn: turn(for: x.itemID), frame: Int64(x.audioEndMs) * 24))
        case .inputAudioCommitted(let x): emit(.committed(turn: turn(for: x.itemID)))
        case .inputTranscriptionDelta(let x): emit(.transcriptDelta(turn: turn(for: x.itemID), delta: x.delta))
        case .inputTranscriptionCompleted(let x): emit(.transcriptCompleted(turn: turn(for: x.itemID), text: x.transcript))
        case .inputTranscriptionFailed(let x):
            emit(.transcriptFailed(turn: turn(for: x.itemID), message: x.error?.code ?? "transcription failed"))
        case .error(let x):
            let kind = RealtimeIssue.classify(x.error)
            switch kind {
            case .auth: emit(.failed(.badOpenAIKey))
            case .quota, .rateLimit: emit(.failed(.rateLimited(.openAI)))
            case .sessionExpired: emit(.failed(.transcriptionUnavailable))
            default: break   // e.g. an empty commit: harmless
            }
        default: break
        }
    }
}
