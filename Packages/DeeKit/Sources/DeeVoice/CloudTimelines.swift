import DeeRealtime
import Foundation

/// Where the server's audio clock sits on the local capture timeline.
///
/// The realtime server counts input audio in milliseconds "from the start of all
/// audio written to the input buffer during the session" (`audio_start_ms`,
/// `audio_end_ms`). The uplink feeds capture chunks to the session, but not
/// always contiguously: a pause (listening off), a reconnect (gap fill from the
/// pre-roll) or a new session (rollover) breaks the run. The map keeps one entry
/// per contiguous run, positioned on the *feed* stream (every frame handed to the
/// session, in order, counted the same way the session counts it), so:
/// - a new session's clock starts at the feed frame the session names
///   (`.uplinkOrigin`), even for audio fed before the app saw that event;
/// - audio the session dropped (`.uplinkDropped`, exact feed frames) is cut out
///   exactly, wherever and whenever it is reported.
/// A server offset is then the count of surviving frames from the origin, and
/// maps back to the exact capture frame (and from there to host time and prosody).
public struct UplinkMap: Sendable, Equatable {
    public struct Run: Sendable, Equatable {
        /// First frame of the run on the feed stream (24 kHz frames).
        public var feedStart: Int64
        /// First frame of the run on the capture timeline.
        public var captureStart: Int64
        public var frames: Int64
    }

    /// Runs on the current session's timeline, in order (the server's timeline
    /// is their concatenation, after `forgotten` frames that fell out).
    public private(set) var runs: [Run] = []
    /// Frames fed to the session so far (the feed stream's clock).
    public private(set) var fedFrames: Int64 = 0
    /// Feed frame where the current session's server clock starts.
    public private(set) var origin: Int64 = 0
    /// Server frames of runs that fell out of the map (kept small).
    private var forgotten: Int64 = 0
    /// Capture frame just after the last chunk sent (nil before the first).
    public private(set) var captureEnd: Int64?
    /// False after `invalidate()` (audio lost with no position): server offsets
    /// no longer map to capture frames until the next `reset`.
    public private(set) var reliable = true
    /// Runs kept (older ones fall out; a turn never spans this many breaks).
    static let maxRuns = 64

    public init() {}

    /// 24 kHz frames on the current session's timeline so far.
    public var serverFrames: Int64 { forgotten + runs.reduce(0) { $0 + $1.frames } }

    /// A chunk was fed: `frames` capture frames starting at `startFrame`.
    public mutating func sent(startFrame: Int64, frames: Int) {
        guard frames > 0 else { return }
        if let last = runs.indices.last,
           runs[last].captureStart + runs[last].frames == startFrame,
           runs[last].feedStart + runs[last].frames == fedFrames {
            runs[last].frames += Int64(frames)
        } else {
            runs.append(Run(feedStart: fedFrames, captureStart: startFrame, frames: Int64(frames)))
            if runs.count > Self.maxRuns {
                let n = runs.count - Self.maxRuns
                forgotten += runs[..<n].reduce(0) { $0 + $1.frames }
                runs.removeFirst(n)
            }
        }
        fedFrames += Int64(frames)
        captureEnd = startFrame + Int64(frames)
    }

    /// A new server session whose clock starts at feed frame `originFeedFrame`
    /// (`.uplinkOrigin`): what was fed before it is off this timeline. The capture
    /// position of the last chunk is kept (gap fill resumes from it).
    public mutating func reset(originFeedFrame: Int64) {
        origin = originFeedFrame
        forgotten = 0
        reliable = true
        cut(from: Int64.min, to: originFeedFrame)
    }

    /// A new server session starting with the next chunk fed.
    public mutating func reset() { reset(originFeedFrame: fedFrames) }

    /// Audio was lost and nobody can say where: stop mapping (callers fall back
    /// to arrival-time estimates) until `reset`. Sending goes on as before. (The
    /// session reports every drop it makes, positioned: this is a last resort.)
    public mutating func invalidate() {
        reliable = false
    }

    /// The session dropped `frames` fed frames at feed frame `atFeedFrame`
    /// (`.uplinkDropped`): they never reached the server, and everything fed
    /// after them sits that much earlier on its timeline. Order does not matter;
    /// a drop before the current origin is a no-op.
    public mutating func dropped(atFeedFrame: Int64, frames: Int64) {
        guard frames > 0 else { return }
        cut(from: max(atFeedFrame, origin), to: atFeedFrame + frames)
    }

    /// Removes feed frames [from, to) from the runs.
    private mutating func cut(from: Int64, to: Int64) {
        guard to > from else { return }
        var out: [Run] = []
        for r in runs {
            let rEnd = r.feedStart + r.frames
            if rEnd <= from || r.feedStart >= to {
                out.append(r)
                continue
            }
            if r.feedStart < from {                              // the part before the gap
                out.append(Run(feedStart: r.feedStart, captureStart: r.captureStart, frames: from - r.feedStart))
            }
            if rEnd > to {                                       // the part after it
                out.append(Run(feedStart: to, captureStart: r.captureStart + (to - r.feedStart), frames: rEnd - to))
            }
        }
        runs = out
    }

    /// The capture frame of server offset `ms`, nil when it was never sent (or
    /// fell out of the map). An offset at a break maps to the start of the next
    /// run; one past the end clamps to the end.
    public func captureFrame(serverMs ms: Int) -> Int64? {
        let f = Int64(ms) * 24
        guard reliable, f >= forgotten, let last = runs.last else { return nil }
        var pos = forgotten
        for r in runs {
            if f < pos + r.frames { return r.captureStart + (f - pos) }
            pos += r.frames
        }
        return last.captureStart + last.frames
    }
}

/// Places the assistant transcript's sentences on what was actually played, so
/// the brain hears "Dee is now saying sentence X" when the listener does.
///
/// Sentences arrive with `audioMsHint`, the estimated offset into the item's
/// audio where the sentence ends (`.assistantSentence`). Sentence *i* starts where
/// sentence *i − 1* ends. As playback moves:
/// - `.started` when playback passes the sentence's start (the first one with
///   the item's first sample);
/// - `.finished(heard: true)` when playback passes its end, or when the item
///   played out completely;
/// - when the item is cut (barge-in, interruption), a sentence already started
///   finishes with `heard` = its midpoint was played; sentences not started get
///   no event.
/// Placement and the heard rule are `DeeRealtime.HeardRule`, the one the session
/// trims its history by (`BargeInOutcome.Truncation.heardSentences`), so what she
/// "said" here and what the server remembers never disagree.
/// Sentences that arrive after playback passed them are reported at once.
public struct SentenceClock: Sendable {
    public enum Event: Sendable, Equatable {
        case started(itemID: String, index: Int, text: String)
        case finished(itemID: String, index: Int, text: String, heard: Bool)
    }

    private struct Sentence: Sendable {
        var text: String
        var start: Int
        var end: Int
    }

    private enum Phase: Sendable, Equatable {
        case waiting
        case playing
        /// Played out completely.
        case complete
        /// Cut after `playedMs`.
        case cut(Int)
    }

    private struct Item: Sendable {
        var sentences: [Sentence] = []
        var started = 0
        var finished = 0
        var played = 0
        var phase = Phase.waiting
    }

    private var items: [String: Item] = [:]
    private var order: [String] = []
    static let keep = 16

    public init() {}

    /// A sentence of `itemID` ending at `audioMsHint`.
    public mutating func add(itemID: String, text: String, endMs: Int) -> [Event] {
        var item = items[itemID] ?? Item()
        let previous = item.sentences.last?.end ?? 0
        let place = HeardRule.placements([previous, endMs]).last ?? (previous, max(endMs, previous))
        item.sentences.append(Sentence(text: text, start: place.start, end: place.end))
        remember(itemID)
        items[itemID] = item
        return advance(itemID)
    }

    /// The item's first sample played.
    public mutating func itemStarted(_ itemID: String) -> [Event] {
        var item = items[itemID] ?? Item()
        if item.phase == .waiting { item.phase = .playing }
        remember(itemID)
        items[itemID] = item
        return advance(itemID)
    }

    /// Playback of the item is at `playedMs`.
    public mutating func progress(_ itemID: String, playedMs: Int) -> [Event] {
        guard var item = items[itemID], item.phase == .playing || item.phase == .waiting else { return [] }
        item.played = max(item.played, playedMs)
        if playedMs > 0 { item.phase = .playing }
        items[itemID] = item
        return advance(itemID)
    }

    /// The item stopped: played out (`cut == false`) or cut after `playedMs`.
    public mutating func itemFinished(_ itemID: String, playedMs: Int, cut: Bool) -> [Event] {
        var item = items[itemID] ?? Item()
        item.played = max(item.played, playedMs)
        item.phase = cut ? .cut(playedMs) : .complete
        remember(itemID)
        items[itemID] = item
        return advance(itemID)
    }

    /// Item ids with sentences not yet finished whose audio is playing.
    public var playingItems: [String] { order.filter { items[$0]?.phase == .playing } }

    private mutating func advance(_ id: String) -> [Event] {
        guard var item = items[id] else { return [] }
        var out: [Event] = []
        let n = item.sentences.count
        switch item.phase {
        case .waiting:
            break
        case .playing:
            while item.started < n {
                let s = item.sentences[item.started]
                guard item.started == 0 || item.played > s.start else { break }
                out.append(.started(itemID: id, index: item.started, text: s.text))
                item.started += 1
            }
            while item.finished < item.started, item.played >= item.sentences[item.finished].end {
                out.append(.finished(itemID: id, index: item.finished, text: item.sentences[item.finished].text, heard: true))
                item.finished += 1
            }
        case .complete:
            while item.started < n {
                out.append(.started(itemID: id, index: item.started, text: item.sentences[item.started].text))
                item.started += 1
            }
            while item.finished < n {
                out.append(.finished(itemID: id, index: item.finished, text: item.sentences[item.finished].text, heard: true))
                item.finished += 1
            }
        case .cut(let p):
            while item.started < n {
                let s = item.sentences[item.started]
                guard (item.started == 0 && p > 0) || p > s.start else { break }
                out.append(.started(itemID: id, index: item.started, text: s.text))
                item.started += 1
            }
            while item.finished < item.started {
                let s = item.sentences[item.finished]
                out.append(.finished(itemID: id, index: item.finished, text: s.text,
                                     heard: HeardRule.heard(start: s.start, end: s.end, index: item.finished, playedMs: p)))
                item.finished += 1
            }
        }
        items[id] = item
        return out
    }

    private mutating func remember(_ id: String) {
        guard !order.contains(id) else { return }
        order.append(id)
        while order.count > Self.keep {
            let old = order.removeFirst()
            items[old] = nil
        }
    }
}

/// Which assistant audio may play: after a cut or a stop, nothing of the stopped
/// response does, until the next response starts.
///
/// A stop can land before `CloudVoice` has seen the response it stops: the
/// session already created it (and maybe has its first audio), but its
/// `.responseStarted` is still in the event pump. A `.responseStarted` within
/// `stopGuard` of such a stop, with no request since, is that response and keeps
/// the gate closed. Its first audio then tells the server none of it was heard.
struct ReplyGate: Sendable, Equatable {
    enum Admit: Sendable, Equatable {
        case play
        /// A cut response's late audio; the server already knows.
        case drop
        /// The first audio of a response stopped before any of it played: drop it
        /// and tell the server nothing of its item was heard (`bargeIn(0)`).
        case dropAndTellServer
    }

    static let stopGuard = 0.25

    private(set) var isOpen = true
    /// The server was told about the cut of the current response.
    private(set) var cutNotified = false
    private var guardUntil = -Double.infinity
    private var requestedSinceStop = true

    /// Her audio was cut and the server told (`bargeIn` with what was played).
    mutating func closeAfterCut() {
        isOpen = false
        cutNotified = true
    }

    /// Stopped before any of the response played; it may not have started yet.
    mutating func closeBeforeAudio(at t: Double) {
        isOpen = false
        guardUntil = t + Self.stopGuard
        requestedSinceStop = false
    }

    /// The brain asked for a new response (a reply or an initiative).
    mutating func requested() {
        requestedSinceStop = true
    }

    /// `.responseStarted`: opens the gate unless this is the response a stop just
    /// closed it on. Returns true when it stays closed.
    mutating func responseStarted(at t: Double) -> Bool {
        let stopped = !requestedSinceStop && t < guardUntil
        isOpen = !stopped
        cutNotified = false
        return stopped
    }

    /// Assistant audio arrived.
    mutating func audio() -> Admit {
        if isOpen { return .play }
        if cutNotified { return .drop }
        cutNotified = true
        return .dropAndTellServer
    }
}
