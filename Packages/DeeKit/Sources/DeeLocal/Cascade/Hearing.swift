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
/// voice = EarCore's bed-proof `voiceActive` (Apple's SpeechDetector only without an uplink). A turn starts after
/// `minSpeechMs` of voice (reported `prefixMs` earlier, never before the last commit) and
/// stops `silenceMs` after its last voice. It is committed only once the quiet has also lasted
/// `mergeMs` more (`mergeMs + extendMs` while its words so far trail off, `unfinished`): voice
/// of at least `minSpeechMs` inside that window continues the same turn (no new start, one
/// commit), like mode 2's merge window. No energy VAD.
public struct TurnDetectorCore: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case started(turn: Int, frame: Int64)
        case stopped(turn: Int, frame: Int64)
        case committed(turn: Int, startFrame: Int64, endFrame: Int64)
    }

    public var prefixMs = 300
    public var silenceMs = 300
    public var minSpeechMs = 100
    /// Extra quiet before a commit, in which a continuation joins the turn (0: commit at `silenceMs`).
    public var mergeMs = 0
    /// More of it while the turn's words so far trail off ("…went to the").
    public var extendMs = 0

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

    /// Evidence for `[start, end)`: voiced or not. Feed in order without gaps. `unfinished`: the
    /// open turn's words so far trail off (`TrailingWords`).
    public mutating func evidence(start: Int64, end: Int64, voice: Bool, unfinished: Bool = false) -> [Event] {
        guard end > start else { return [] }
        var out: [Event] = []
        let f = frames
        if voice {
            if voiceRunStart == nil { voiceRunStart = start }
            if open {
                // Past its stop (quiet ≥ silenceMs): only real speech (≥ minSpeechMs) continues the turn.
                let stopped = (voiceRunStart ?? start) - lastVoiceEnd >= f.silence
                if !stopped || end - (voiceRunStart ?? start) >= f.minSpeech { lastVoiceEnd = end }
            } else {
                lastVoiceEnd = end
                if let run = voiceRunStart, end - run >= f.minSpeech {
                    open = true
                    turn += 1
                    turnStart = max(lastCommitEnd, run - f.prefix, 0)
                    out.append(.started(turn: turn, frame: turnStart))
                }
            }
        } else {
            voiceRunStart = nil
            let hold = Int64((mergeMs + (unfinished ? extendMs : 0)) * 24)
            if open, end - lastVoiceEnd >= f.silence + hold {
                let stop = lastVoiceEnd + f.silence
                out.append(.stopped(turn: turn, frame: stop))
                out.append(.committed(turn: turn, startFrame: turnStart, endFrame: stop))
                open = false
                lastCommitEnd = stop
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
    /// Seconds of fed audio with no voice evidence at all (no EarCore verdict, no detector
    /// result) before hearing reports `.noVoiceEvidence` instead of staying silent.
    public var noEvidenceAfter: Double = 8
    /// Seconds of quiet after a turn's stop before it is committed; speech inside joins the turn
    /// (`TurnDetectorCore.mergeMs`; mode 2's `OpenAITranscriptionHearing.mergeWindow`, same value).
    public var mergeWindow: Double {
        get { state.withLock { Double($0.core.mergeMs) / 1000 } }
        set { state.withLock { $0.core.mergeMs = Int((newValue * 1000).rounded()) } }
    }
    /// The whole window while the words so far trail off (`TrailingWords`), ≥ `mergeWindow`.
    public var unfinishedWindow: Double {
        get { state.withLock { Double($0.core.mergeMs + $0.core.extendMs) / 1000 } }
        set { state.withLock { $0.core.extendMs = max(0, Int((newValue * 1000).rounded()) - $0.core.mergeMs) } }
    }

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
        /// Recent (uplink fed − our fed) differences; the offset is their minimum (see `feed`).
        var offsetSamples: [Int64] = []
        /// Frames that got a voice verdict (EarCore) / speech-detector results seen.
        var verdicts = 0
        var detectorResults = 0
        var noEvidenceReported = false
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
        mergeWindow = MergeTiming.window
        unfinishedWindow = MergeTiming.unfinishedWindow
    }

    /// The open turn's words so far trail off (on-device text only; LAN STT has none before the commit).
    private func openTurnTrails(_ s: State) -> Bool {
        guard s.core.open, let t = s.turns[s.core.turn] else { return false }
        let finals = t.finals.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ")
        return TrailingWords.trails([finals, t.volatile].filter { !$0.isEmpty }.joined(separator: " "))
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
        let noEvidenceFrames = Int64(noEvidenceAfter * 24_000)
        let out = state.withLock { s -> (samples: [Int16], firstFrame24k: Int64?, events: [TurnDetectorCore.Event], silent: Bool) in
            s.fed = frame + Int64(samples.count)
            s.ring.append(pcm)
            let maxBytes = 24_000 * 2 * 30
            if s.ring.count > maxBytes {
                let drop = s.ring.count - maxBytes
                s.ring.removeFirst(drop)
                s.ringStart += Int64(drop / 2)
            }
            var events: [TurnDetectorCore.Event] = []
            if let up = uplink {
                // The session's feed counter is ahead of ours by a fixed origin. CloudVoice records a
                // chunk right after handing it to the session and this feed runs a hop later, so the
                // difference is the origin or (pump lag) more: the recent minimum is the origin.
                s.offsetSamples.append(up.latestFedFrame - s.fed)
                if s.offsetSamples.count > 32 { s.offsetSamples.removeFirst(s.offsetSamples.count - 32) }
                s.uplinkOffset = s.offsetSamples.min()
                events = uplinkEvidence(&s, up)
            }
            // Audio is arriving but nothing ever says whether a voice is in it: say so, once.
            var silent = false
            if !s.noEvidenceReported, s.verdicts == 0, s.detectorResults == 0, s.fed >= noEvidenceFrames {
                s.noEvidenceReported = true
                silent = true
            }
            let d = s.down.process(samples, firstFrame24k: frame)
            return (d.samples, d.firstFrame24k, events, silent)
        }
        if let first = out.firstFrame24k, !out.samples.isEmpty { engine.feed(out.samples, frame24k: first) }
        handle(out.events)
        if out.silent { emit(.failed(.noVoiceEvidence)) }
    }

    /// Turn evidence from EarCore's per-frame voice (the same bed- and echo-proof signal mode 1's
    /// local barge-in uses), in 20 ms steps up to the newest frame it has a verdict for. Apple's
    /// SpeechDetector gives no results at all when it shares the analyzer with the transcriber
    /// (measured, 0.6 smoke), so with an uplink it is not consulted.
    private func uplinkEvidence(_ s: inout State, _ up: UplinkActivity) -> [TurnDetectorCore.Event] {
        guard let off = s.uplinkOffset else { return [] }
        let recorded = up.latestFedFrame - off
        let end = min(s.fed, recorded)
        var start = s.evidenceUntil
        guard end > start else { return [] }
        var out: [TurnDetectorCore.Event] = []
        let step: Int64 = 480
        let trails = openTurnTrails(s)
        while start < end {
            let e = min(end, start + step)
            let verdict = up.voiceActive(atFedFrame: (start + e) / 2 + off)
            if verdict != nil { s.verdicts += 1 }
            out += s.core.evidence(start: start, end: e, voice: verdict ?? false, unfinished: trails)
            start = e
        }
        s.evidenceUntil = end
        return out
    }

    public func commitNow() {
        let events = state.withLock { s in s.core.commitNow(at: s.fed) }
        handle(events)
    }

    public func clear() {
        state.withLock { s in s.core.clear(at: s.fed) }
    }

    /// SpeechDetector result: the turn evidence only when there is no uplink (EarCore's verdicts
    /// drive turns when there is one: `uplinkEvidence`).
    func activity(_ a: SpeechActivity) {
        let events = state.withLock { s -> [TurnDetectorCore.Event] in
            s.detectorResults += 1
            guard uplink == nil else { return [] }
            var out: [TurnDetectorCore.Event] = []
            var start = max(a.startFrame, s.evidenceUntil)
            let end = a.endFrame
            guard end > start else { return [] }
            let step: Int64 = 480
            let trails = openTurnTrails(s)
            while start < end {
                let e = min(end, start + step)
                out += s.core.evidence(start: start, end: e, voice: a.speechDetected, unfinished: trails)
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

// MARK: - Merge timing (modes 2 and 3)

/// How long hearing waits after a turn's stop for more of the same utterance (0.6 LAN verify).
///
/// Measured on the harness fixtures: pauses inside one utterance are 0.2–0.7 s (l04, l05, c05,
/// k08); the scripted thinking pause p12a is 1.21 s, after "So yesterday I went to the". Both
/// modes stop a piece at 300 ms of quiet (mode 1's tuned server_vad), so a window of 0.8 s
/// covers every pause up to 1.1 s at a cost of 0.8 s on every turn's end; a fixed window long
/// enough for 1.2 s pauses (≥ 1.0 s, with margin 1.4 s) would add that to every reply. Instead the
/// window grows to `unfinishedWindow` only while the words so far trail off ("…the", "…and",
/// "…to", a comma): those turns the brain would hold anyway (`TurnPolicy.trailingWait` 3 s), so
/// the longer wait costs nothing there and joins the halves into one turn.
public enum MergeTiming {
    public static let window = 0.8
    public static let unfinishedWindow = 1.4
}

/// Words a finished sentence does not end on (a lenient subset of the brain's `TurnPolicy`
/// rule: here it only lengthens a merge window).
public enum TrailingWords {
    static let words: Set<String> = [
        "and", "but", "or", "because", "cause", "um", "uh", "er", "erm", "the", "a", "an", "my", "your",
        "their", "our", "than", "very", "gonna", "wanna", "gotta", "whether", "although", "unless",
        "of", "for", "at", "from", "about", "into", "onto", "with", "to", "if",
    ]

    /// `text` ends mid-sentence: a trailing word, comma, dash or ellipsis (a question mark or
    /// an exclamation ends it).
    public static func trails(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastChar = t.last else { return false }
        if lastChar == "?" || lastChar == "!" { return false }
        if t.hasSuffix("…") || t.hasSuffix("...") || lastChar == "," || lastChar == "-" || lastChar == "—" { return true }
        let last = t.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).last.map(String.init) ?? ""
        return words.contains(last)
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
/// 300/300/0.5, gpt-transcribe, streaming deltas; pieces split by short pauses are merged into
/// one turn, see `mergeWindow`), minted per socket with
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
        var merged: [Int: MergedTurn] = [:]
        /// The turn whose last piece just stopped: a speech start within `mergeWindow` continues it.
        var held: Int?
        var holdGeneration = 0
        /// The client asked for a commit (`input_audio_buffer.commit`): the next commit is not held.
        var manualCommit = false
        /// Frames fed so far (the socket's clock, which the transcription session's ms follow).
        var fed: Int64 = 0
        /// The transcription session's VAD is inside a piece (started, not stopped).
        var vadOpen = false
        /// After a manual commit inside a piece: watch our voice evidence for the rest of the burst.
        var restWatch: (until: Date, commitFrame: Int64)?
        var restRun: Int64 = 0
        /// A turn opened for the rest of a burst (`restStart`) that no server item has claimed yet.
        var rest: Int?
        var restVoiceAt = Date()
    }
    /// One turn as the session sees it: the transcription session's pieces (items) merged.
    struct MergedTurn {
        var pieces: [String] = []
        var committed: Set<String> = []
        var texts: [String: String] = [:]
        var failed: [String: String] = [:]
        var stopFrame: Int64?
        var holdExpired = false
        var flushed = false
        var completedEmitted = false
        var buffered: [String] = []
        var deltaStarted: Set<String> = []
        /// The hold was lengthened once because the words trailed off (`unfinishedWindow`).
        var extended = false
    }
    private let state = Mutex(State())
    private var reader: Task<Void, Never>?
    /// Seconds a piece's end is held for a continuation before the turn is committed.
    ///
    /// The transcription session ends a piece after 300 ms of silence (mode 1's tuned
    /// server_vad, kept so its speech starts and barge-ins stay as fast). A thinking pause in
    /// one sentence is longer than that (0.6 smoke: the next piece started 0.1–0.6 s after the
    /// commit), and each piece reached the brain as its own turn, cancelling the reply in
    /// progress. A start within this window joins the same turn: one speech_started, one
    /// commit, one transcript for the whole utterance. Cost: the turn's end is reported this
    /// much later (a LAN brain's first token is 0.2–4 s; the merged question is what it must answer).
    public var mergeWindow: Double = MergeTiming.window
    /// The whole hold while the turn's words so far trail off (`TrailingWords`, `MergeTiming`).
    public var unfinishedWindow: Double = MergeTiming.unfinishedWindow
    /// EarCore's voice evidence (the rest of a burst after a manual commit, `restStart`).
    let uplink: UplinkActivity?
    /// Seconds after a manual commit in which our voice evidence opens the rest of the burst.
    public var restWatchWindow: Double = 1.5
    /// A rest-of-burst turn no server item claims is closed (empty) this long after our voice ended.
    public var restGiveUp: Double = 3

    public init(transport: Transport, credential: @escaping Credential, url: URL = OpenAITranscription.url,
                uplink: UplinkActivity? = nil) {
        self.transport = transport; self.credential = credential; self.url = url; self.uplink = uplink
    }

    public var timingSTT: TimingProfile.CascadeSTT { .openAIRealtime }

    /// Where events go (tests drive `server(_:)` directly after this).
    func attach(_ sink: @escaping @Sendable (HearingEvent) -> Void) { state.withLock { $0.sink = sink } }

    public func start(sink: @escaping @Sendable (HearingEvent) -> Void) async throws {
        attach(sink)
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

    public func feed(_ pcm: Data, atFrame frame: Int64) {
        send(.inputAudioAppend(audio: pcm.base64EncodedString()))
        restEvidence(frames: Int64(pcm.count / 2), at: frame)
    }
    public func commitNow() {
        flushHeld()
        let watch = uplink != nil
        let window = restWatchWindow
        state.withLock { s in
            s.manualCommit = true
            // Committed inside a piece (CloudVoice's quick commit of a short burst in a hold): if
            // they go on talking, that is a new item as far as the session is concerned.
            if watch, s.vadOpen { s.restWatch = (Date().addingTimeInterval(window), s.fed); s.restRun = 0 }
        }
        send(.inputAudioCommit())
    }

    /// The rest of a burst after a manual commit (0.6 LAN verify, c05 over Dee in mode 2):
    /// CloudVoice commits a short burst early in a hold ("Keep" | "going, I'm listening"); the
    /// transcription session then keeps the rest in an item it never reports starting (its
    /// first event is that item's stop, ~3 s later). The session saw words "Cheap." and then
    /// more sound covered by no item, so the hold ended and the rest became a turn of its own
    /// (Dee answered "Oh, what's cheap?"). mode 1's server reports such speech as a new item
    /// at once; so does this: our voice evidence (EarCore, ≥ 100 ms) within `restWatchWindow`
    /// of the commit opens a turn (speech_started), and the session's own Backchannel rules
    /// (`FloorHold.followsContinuer`, `isHoldBackchannel`) decide it with its words.
    private func restEvidence(frames: Int64, at frame: Int64) {
        guard let up = uplink else { state.withLock { $0.fed = frame + frames }; return }
        let voice = up.voiceNow
        let started = state.withLock { s -> (turn: Int, frame: Int64)? in
            s.fed = frame + frames
            if voice, s.rest != nil { s.restVoiceAt = Date() }
            guard let w = s.restWatch else { return nil }
            if Date() > w.until { s.restWatch = nil; return nil }
            s.restRun = voice ? s.restRun + frames : 0
            guard s.restRun >= 2_400 else { return nil }
            s.restWatch = nil
            s.nextTurn += 1
            let t = s.nextTurn
            s.merged[t] = MergedTurn(pieces: [])
            s.rest = t
            s.restVoiceAt = Date()
            return (t, max(w.commitFrame, s.fed - s.restRun - 7_200))
        }
        guard let started else { return }
        emit(.speechStarted(turn: started.turn, frame: started.frame))
        let giveUp = restGiveUp
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                let (done, close) = self.state.withLock { s -> (Bool, Int64?) in
                    guard s.rest == started.turn else { return (true, nil) }   // a server item claimed it
                    guard Date().timeIntervalSince(s.restVoiceAt) >= giveUp else { return (false, nil) }
                    s.rest = nil
                    s.merged[started.turn]?.flushed = true
                    s.merged[started.turn]?.completedEmitted = true
                    return (true, s.fed)
                }
                if let close {
                    // Nothing came for it: an empty item, which decides nothing (as a word-less tail).
                    self.emit(.speechStopped(turn: started.turn, frame: close))
                    self.emit(.committed(turn: started.turn))
                    self.emit(.transcriptCompleted(turn: started.turn, text: ""))
                }
                if done { return }
            }
        }
    }
    public func clear() {
        flushHeld()
        send(.inputAudioClear())
    }
    public func setKeywords(_ words: [String]) {}   // they ride on the mint (OpenAITranscription.Session.keywords)

    public func stop() {
        let socket = state.withLock { s -> (any RealtimeSocket)? in s.stopped = true; s.sink = nil; return s.socket }
        socket?.close(code: 1000, reason: nil)
        reader?.cancel()
    }

    private func emit(_ e: HearingEvent) {
        let sink = state.withLock { $0.sink }
        sink?(e)
    }

    func server(_ e: ServerEvent) {
        switch e {
        case .speechStarted(let x): pieceStarted(x.itemID, frame: Int64(x.audioStartMs) * 24)
        case .speechStopped(let x): pieceStopped(x.itemID, frame: Int64(x.audioEndMs) * 24)
        case .inputAudioCommitted(let x): pieceCommitted(x.itemID)
        case .inputTranscriptionDelta(let x): pieceDelta(x.itemID, x.delta)
        case .inputTranscriptionCompleted(let x): pieceDone(x.itemID, text: x.transcript, failure: nil)
        case .inputTranscriptionFailed(let x): pieceDone(x.itemID, text: nil, failure: x.error?.code ?? "transcription failed")
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

    // MARK: Merging pieces into turns

    private func pieceStarted(_ item: String, frame: Int64) {
        let fresh = state.withLock { s -> Int? in
            s.vadOpen = true
            if s.turns[item] != nil { return nil }
            if let t = s.rest {
                // The rest of a burst we already reported starting.
                s.rest = nil
                s.turns[item] = t
                s.merged[t]?.pieces.append(item)
                return nil
            }
            if let t = s.held, var m = s.merged[t], !m.flushed {
                // A continuation of the held turn: no new speech start for the session.
                s.turns[item] = t
                m.pieces.append(item)
                m.holdExpired = false
                s.merged[t] = m
                s.held = nil
                s.holdGeneration += 1
                return nil
            }
            s.nextTurn += 1
            let t = s.nextTurn
            s.turns[item] = t
            var m = MergedTurn()
            m.pieces = [item]
            s.merged[t] = m
            return t
        }
        if let fresh { emit(.speechStarted(turn: fresh, frame: frame)) }
    }

    private func pieceStopped(_ item: String, frame: Int64) {
        state.withLock { s in
            s.vadOpen = false
            s.restWatch = nil
            let t = turnLocked(&s, item)
            s.merged[t]?.stopFrame = frame
        }
    }

    private func pieceCommitted(_ item: String) {
        let (turn, now, generation) = state.withLock { s -> (Int, Bool, Int) in
            let t = turnLocked(&s, item)
            s.merged[t]?.committed.insert(item)
            let manual = s.manualCommit
            s.manualCommit = false
            if manual { s.merged[t]?.holdExpired = true }
            if s.merged[t]?.holdExpired == true { return (t, true, s.holdGeneration) }
            s.held = t
            s.holdGeneration += 1
            return (t, false, s.holdGeneration)
        }
        if now { flush(turn); return }
        let wait = mergeWindow
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            self?.holdExpired(turn, generation: generation)
        }
    }

    private func holdExpired(_ turn: Int, generation: Int) {
        let more = unfinishedWindow - mergeWindow
        let go = state.withLock { s -> Bool? in
            guard s.holdGeneration == generation, s.held == turn, var m = s.merged[turn] else { return nil }
            // The words so far trail off ("So yesterday I went to the"): wait a little longer once.
            if !m.extended, more > 0, TrailingWords.trails(Self.wordsSoFar(m)) {
                m.extended = true
                s.merged[turn] = m
                return false
            }
            s.held = nil
            s.merged[turn]?.holdExpired = true
            return true
        }
        switch go {
        case true?: flush(turn)
        case false?:
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(more))
                self?.holdExpired(turn, generation: generation)
            }
        case nil: break
        }
    }

    /// The merged turn's words so far: the pieces' transcripts, else their deltas.
    static func wordsSoFar(_ m: MergedTurn) -> String {
        if m.pieces.allSatisfy({ m.texts[$0] != nil }) { return m.pieces.compactMap { m.texts[$0] }.joined(separator: " ") }
        return m.buffered.joined()
    }

    /// Commits the held turn now (a manual commit or clear must not wait behind it).
    private func flushHeld() {
        let t = state.withLock { s -> Int? in
            guard let t = s.held else { return nil }
            s.held = nil
            s.holdGeneration += 1
            s.merged[t]?.holdExpired = true
            return t
        }
        if let t { flush(t) }
    }

    /// The turn's stop + commit (once every piece is committed), its buffered deltas, and its
    /// transcript when every piece has one.
    private func flush(_ turn: Int) {
        let out = state.withLock { s -> [HearingEvent] in
            guard var m = s.merged[turn], !m.flushed, m.holdExpired, m.pieces.allSatisfy(m.committed.contains) else { return [] }
            m.flushed = true
            var events: [HearingEvent] = []
            if let stop = m.stopFrame { events.append(.speechStopped(turn: turn, frame: stop)) }
            events.append(.committed(turn: turn))
            events += m.buffered.map { .transcriptDelta(turn: turn, delta: $0) }
            m.buffered = []
            s.merged[turn] = m
            if let done = completionLocked(&s, turn) { events.append(done) }
            return events
        }
        for e in out { emit(e) }
    }

    private func pieceDelta(_ item: String, _ delta: String) {
        let out = state.withLock { s -> HearingEvent? in
            let t = turnLocked(&s, item)
            guard var m = s.merged[t] else { return nil }
            var d = delta
            if !m.deltaStarted.contains(item) {
                m.deltaStarted.insert(item)
                if m.deltaStarted.count > 1 || m.pieces.first != item, !d.hasPrefix(" ") { d = " " + d }
            }
            defer { s.merged[t] = m }
            if m.flushed { return .transcriptDelta(turn: t, delta: d) }
            m.buffered.append(d)
            return nil
        }
        if let out { emit(out) }
    }

    private func pieceDone(_ item: String, text: String?, failure: String?) {
        let out = state.withLock { s -> HearingEvent? in
            let t = turnLocked(&s, item)
            if let text { s.merged[t]?.texts[item] = text }
            if let failure { s.merged[t]?.failed[item] = failure }
            return completionLocked(&s, t)
        }
        if let out { emit(out) }
    }

    /// The turn's transcript once it is committed and every piece has its own (pieces joined in order).
    private func completionLocked(_ s: inout State, _ turn: Int) -> HearingEvent? {
        guard var m = s.merged[turn], m.flushed, !m.completedEmitted,
              m.pieces.allSatisfy({ m.texts[$0] != nil || m.failed[$0] != nil }) else { return nil }
        m.completedEmitted = true
        s.merged[turn] = m
        let texts = m.pieces.compactMap { m.texts[$0]?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if texts.isEmpty, let failure = m.pieces.compactMap({ m.failed[$0] }).first {
            return .transcriptFailed(turn: turn, message: failure)
        }
        return .transcriptCompleted(turn: turn, text: texts.joined(separator: " "))
    }

    /// The turn of `item`; an item never seen starting (a manual commit of silence) gets its own.
    private func turnLocked(_ s: inout State, _ item: String) -> Int {
        if let t = s.turns[item] { return t }
        if let t = s.rest {
            // The server's first word of the rest of a burst is its stop or commit: the turn we opened.
            s.rest = nil
            s.turns[item] = t
            s.merged[t]?.pieces.append(item)
            return t
        }
        s.nextTurn += 1
        s.turns[item] = s.nextTurn
        var m = MergedTurn()
        m.pieces = [item]
        s.merged[s.nextTurn] = m
        return s.nextTurn
    }
}
