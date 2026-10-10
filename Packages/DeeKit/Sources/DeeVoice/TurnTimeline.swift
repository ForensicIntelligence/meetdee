import Foundation
import os
import Synchronization

/// Monotonic timestamps for every stage of a conversational turn, so latency
/// claims are measured, not guessed (voice design §1, §7).
///
/// A turn starts when the user stops talking (`beginTurn`); every later `mark`
/// lands in that turn until the next one begins. Each mark goes to `os_signpost`
/// (Instruments → Points of Interest, subsystem `com.dee.voice`) and, when a file
/// sink is set, to one JSON line:
///
///     {"turn":3,"stage":"speech_stopped","t":5123.402114,"ms":0,"detail":"item_ab12"}
///
/// `t` is host uptime in seconds (`ProcessInfo.systemUptime`, the clock every
/// DeeVoice timestamp uses); `ms` is milliseconds since the turn began. Debug
/// builds on iPhone write `Caches/DeeTimeline/turns-<date>.jsonl`; anywhere,
/// `DEE_TIMELINE=<path>` (or `DEE_TIMELINE=1` for the default place) turns the
/// file on. Thread-safe; marking costs a lock and an async write.
public final class TurnTimeline: Sendable {
    public enum Stage: String, Sendable, Codable, CaseIterable {
        // The user's side.
        /// Server VAD: `input_audio_buffer.speech_started`.
        case speechStarted = "speech_started"
        /// Server VAD: `input_audio_buffer.speech_stopped` (turn start, cloud path).
        case speechStopped = "speech_stopped"
        /// `input_audio_buffer.committed`.
        case committed
        /// `.heard` delivered to the app (transcript + local prosody).
        case heard
        /// `conversation.item.input_audio_transcription.completed`.
        case transcript
        // Dee's side.
        /// `response.create` sent.
        case responseCreateSent = "response_create_sent"
        /// `response.created` received.
        case responseCreated = "response_created"
        /// First `response.output_audio.delta` received.
        case firstAudioDelta = "first_audio_delta"
        /// First sample of the reply rendered to the output (plus the route's latency).
        case firstAudioPlayed = "first_audio_played"
        /// `.speakingStarted` sent to the app.
        case speakingStarted = "speaking_started"
        /// `.speakingFinished` sent to the app.
        case speakingFinished = "speaking_finished"
        /// `response.done`.
        case responseDone = "response_done"
        // Barge-in.
        /// Server `speech_started` while she was playing.
        case bargeInSpeechStarted = "barge_in_speech_started"
        /// Local barge-in decision (`.bargeIn`).
        case bargeIn = "barge_in"
        /// Player flushed (with `played_ms` in the detail).
        case flushed
        /// `response.cancel` sent.
        case cancelSent = "cancel_sent"
        /// `conversation.item.truncate` sent.
        case truncateSent = "truncate_sent"
        /// Anything else worth a timestamp (detail says what).
        case note

        /// Stages recorded only the first time in a turn (later deltas are noise).
        public var oncePerTurn: Bool {
            switch self {
            case .firstAudioDelta, .firstAudioPlayed, .speakingStarted: true
            default: false
            }
        }
    }

    public struct Mark: Sendable, Codable, Equatable {
        public var turn: Int
        public var stage: Stage
        /// Host uptime, seconds.
        public var t: Double
        /// Milliseconds since the turn began.
        public var ms: Double
        public var detail: String?
    }

    public struct Turn: Sendable, Equatable {
        public var id: Int
        public var start: Double
        public var marks: [Mark]

        /// Time of the first mark of `stage` in this turn.
        public func time(of stage: Stage) -> Double? { marks.first { $0.stage == stage }?.t }

        /// Seconds from the first `from` mark to the first `to` mark, when both exist.
        public func elapsed(from: Stage, to: Stage) -> Double? {
            guard let a = time(of: from), let b = time(of: to) else { return nil }
            return b - a
        }
    }

    /// The process-wide timeline every DeeVoice component marks.
    public static let shared = TurnTimeline(fileURL: TurnTimeline.defaultFileURL())

    private struct State {
        var turns: [Turn] = []
        var nextID = 1
        /// Tune 7: when each stage was last marked.
        var last: [Stage: Double] = [:]
    }

    private let state = Mutex(State())
    private let keep: Int
    private let sink: FileSink?
    private let signposter: OSSignposter

    /// `fileURL`: where to append JSON lines (nil: no file). `keep`: turns kept in memory.
    public init(fileURL: URL? = nil, keep: Int = 64) {
        self.keep = max(1, keep)
        self.sink = fileURL.map(FileSink.init(url:))
        self.signposter = OSSignposter(subsystem: "com.dee.voice", category: .pointsOfInterest)
    }

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// Starts a new turn at `t` (default now) with its first mark; returns its id.
    @discardableResult
    public func beginTurn(_ stage: Stage = .speechStopped, at t: Double? = nil, detail: String? = nil) -> Int {
        let time = t ?? Self.now()
        let mark = state.withLock { s -> Mark in
            let id = s.nextID
            s.nextID += 1
            let m = Mark(turn: id, stage: stage, t: time, ms: 0, detail: detail)
            s.turns.append(Turn(id: id, start: time, marks: [m]))
            s.last[stage] = time
            if s.turns.count > keep { s.turns.removeFirst(s.turns.count - keep) }
            return m
        }
        publish(mark)
        return mark.turn
    }

    /// Records `stage` in the current turn (a turn is started if there is none).
    /// `oncePerTurn` stages are ignored after their first mark.
    public func mark(_ stage: Stage, at t: Double? = nil, detail: String? = nil) {
        let time = t ?? Self.now()
        let mark = state.withLock { s -> Mark? in
            if s.turns.isEmpty {
                let id = s.nextID
                s.nextID += 1
                s.turns.append(Turn(id: id, start: time, marks: []))
            }
            let i = s.turns.count - 1
            s.last[stage] = time
            if stage.oncePerTurn, s.turns[i].marks.contains(where: { $0.stage == stage }) { return nil }
            let m = Mark(turn: s.turns[i].id, stage: stage, t: time, ms: (time - s.turns[i].start) * 1000, detail: detail)
            s.turns[i].marks.append(m)
            return m
        }
        if let mark { publish(mark) }
    }

    /// Tune 7: when `stage` was last marked (any turn; nil: never). The brain marks
    /// `.responseCreateSent` right before it asks the session for a response.
    public func lastTime(of stage: Stage) -> Double? { state.withLock { $0.last[stage] } }

    /// The turns still in memory, oldest first.
    public func turns() -> [Turn] { state.withLock { $0.turns } }

    public var currentTurn: Turn? { state.withLock { $0.turns.last } }

    /// Waits until queued file writes are on disk (tests, harness).
    public func flush() { sink?.flush() }

    private func publish(_ mark: Mark) {
        signposter.emitEvent("turn", "\(mark.stage.rawValue, privacy: .public) turn=\(mark.turn) ms=\(Int(mark.ms))")
        sink?.write(mark)
    }

    /// `DEE_TIMELINE=<path>` or `=1`; otherwise Debug iPhone/iPad builds only.
    static func defaultFileURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let v = environment["DEE_TIMELINE"], !v.isEmpty {
            if v == "0" { return nil }
            if v != "1" { return URL(fileURLWithPath: v) }
            return defaultDirectoryFile()
        }
        #if DEBUG && os(iOS)
        return defaultDirectoryFile()
        #else
        return nil
        #endif
    }

    private static func defaultDirectoryFile() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return caches.appendingPathComponent("DeeTimeline", isDirectory: true)
            .appendingPathComponent("turns-\(f.string(from: Date())).jsonl")
    }

    /// Appends JSON lines on a background queue.
    private final class FileSink: @unchecked Sendable {
        private let queue = DispatchQueue(label: "dee.voice.timeline", qos: .utility)
        private let url: URL
        private var handle: FileHandle?       // queue-confined
        private var failed = false            // queue-confined

        init(url: URL) { self.url = url }

        func write(_ mark: Mark) {
            queue.async { [self] in
                guard !failed else { return }
                if handle == nil {
                    let fm = FileManager.default
                    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
                    handle = try? FileHandle(forWritingTo: url)
                    _ = try? handle?.seekToEnd()
                    if handle == nil { failed = true; return }
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                guard var line = try? encoder.encode(mark) else { return }
                line.append(0x0A)
                try? handle?.write(contentsOf: line)
            }
        }

        func flush() {
            queue.sync { try? handle?.synchronize() }
        }

        deinit { try? handle?.close() }
    }
}
