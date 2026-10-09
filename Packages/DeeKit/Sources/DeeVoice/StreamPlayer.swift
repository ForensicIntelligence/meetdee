import AVFAudio
import Foundation
import Synchronization

/// Dee's streamed voice: 24 kHz mono PCM16 (the realtime API's `audio/pcm`) played
/// through the shared engine, so voice-processing echo cancellation hears it.
///
/// - **Utterances.** Audio is enqueued per utterance id (the realtime assistant
///   item). Utterances play back to back in arrival order; enqueueing a new id
///   closes the previous one.
/// - **Jitter buffer.** Each utterance (and playback after an underrun) waits until
///   `targetMs` of audio is buffered, or the utterance is complete, before it
///   starts. The target adapts between 120 and 250 ms: +30 ms per underrun, −10 ms
///   per clean utterance of a second or more.
/// - **Exact played time.** `playedMs(utterance:)` counts the samples actually
///   rendered to the output, never silence, never what is still queued, rounded
///   down — the number `conversation.item.truncate` needs as `audio_end_ms` (never
///   more than was received). Samples already rendered are committed to the
///   device: they still reach the speaker one `outputLatency` later even after a
///   flush, so rendered is what the listener ends up hearing.
/// - **Flush.** `flush()` stops output at the next render cycle (with a 5 ms fade
///   so it doesn't click) and reports the cut utterance — also when it was still
///   prebuffering (0 ms played: the server must still drop all of it).
/// - **Ended items.** Audio for an utterance that was flushed or `finish`ed is
///   dropped: late deltas never play (again).
/// - **Level.** `.level` events come from the samples just played (the eye bounce).
/// - **Echo reference.** The energy of every 10 ms it rendered (silence included),
///   stamped on the graph clock, is kept for `takeReference()`: what `EarCore`
///   compares the microphone against so her own echo is never taken for the user.
/// - **Clock.** Live, render times come from the render timestamps' host time; in
///   offline manual rendering (`renderClock`) from the frames rendered, which is
///   the manual graph's clock (`.started(at:)`, the reference, `.flushed` marks).
///
/// The render block only copies samples under a short lock. Nothing that holds
/// that lock allocates or frees memory in steady state (capacities are reserved,
/// dropped strings are released after unlocking), so the render thread never
/// waits behind `malloc`. Events are produced by `poll()`, which the owning
/// `AudioGraph` runs at ~60 Hz (and after every manual render), never on the
/// render thread.
public final class PCMStreamPlayer: @unchecked Sendable {
    public static let sampleRate = 24_000.0
    public static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    public static let minTargetMs = 120.0
    public static let maxTargetMs = 250.0
    static let underrunStepMs = 30.0
    static let cleanStepMs = 10.0
    static let fadeFrames = 120                        // 5 ms
    /// Ring capacity: 2²¹ samples ≈ 87 s, more than any reply arriving in a burst.
    static let capacity = 1 << 21

    public enum Event: Sendable, Equatable {
        /// The utterance's first sample was rendered at host time `at` (plus the route's latency).
        case started(utterance: String, at: Double)
        /// Playback ran dry mid-utterance (the network fell behind).
        case underrun(utterance: String)
        /// All of the utterance played (`flushed == false`) or playback was cut
        /// (`flushed == true`). `playedMs`: exactly what was rendered.
        case finished(utterance: String, playedMs: Int, flushed: Bool)
        /// 0…1 from the samples just played; 0 when playback ends.
        case level(Double)
    }

    /// What `flush()` cut.
    public struct Cut: Sendable, Equatable {
        /// The utterance (realtime item id) that was playing or about to play.
        public var utterance: String
        /// Milliseconds of it rendered (rounded down; 0 if it was still prebuffering):
        /// `audio_end_ms` for `conversation.item.truncate`.
        public var playedMs: Int

        public init(utterance: String, playedMs: Int) {
            self.utterance = utterance
            self.playedMs = playedMs
        }
    }

    /// The owner's event slot (called on the poll queue or the manual-render
    /// thread; may be set at any time). Other parties use `addObserver`, so the
    /// local and realtime voices can share one player without unhooking each other.
    public var onEvent: (@Sendable (Event) -> Void)? {
        get { hooks.withLock { $0.onEvent } }
        set { hooks.withLock { $0.onEvent = newValue } }
    }

    /// Adds an event observer (after `onEvent`, in the order added). Returns its id.
    @discardableResult
    public func addObserver(_ body: @escaping @Sendable (Event) -> Void) -> Int {
        hooks.withLock { h in
            let id = h.nextObserver
            h.nextObserver += 1
            h.observers.append((id, body))
            return id
        }
    }

    public func removeObserver(_ id: Int) {
        hooks.withLock { $0.observers.removeAll { $0.id == id } }
    }

    /// Marks `.firstAudioPlayed` and `.flushed` (the live graph uses `.shared`).
    public var timeline: TurnTimeline? {
        get { hooks.withLock { $0.timeline } }
        set { hooks.withLock { $0.timeline = newValue } }
    }

    private struct Hooks {
        var onEvent: (@Sendable (Event) -> Void)?
        var observers: [(id: Int, body: @Sendable (Event) -> Void)] = []
        var nextObserver = 1
        var timeline: TurnTimeline?
        var clock: (@Sendable () -> Double)?
    }

    private let hooks = Mutex(Hooks())

    /// The owning graph's clock (marks such as `.flushed` are stamped with it;
    /// nil: `systemUptime`).
    public var clock: (@Sendable () -> Double)? {
        get { hooks.withLock { $0.clock } }
        set { hooks.withLock { $0.clock = newValue } }
    }

    /// Offline manual rendering: times are frames rendered / sample rate (the
    /// manual graph's clock), not the render timestamps' host time.
    public var renderClock: Bool {
        get { shared.state.withLock { $0.renderClock } }
        set { shared.state.withLock { $0.renderClock = newValue } }
    }

    /// Seconds from render to the speaker; `.started` times include it.
    public var outputLatency: Double {
        get { shared.state.withLock { $0.outputLatency } }
        set { shared.state.withLock { $0.outputLatency = newValue.isFinite ? max(newValue, 0) : 0 } }
    }

    let node: AVAudioSourceNode
    private let shared: Shared

    struct Segment {
        let name: String
        let start: Int64
        var end: Int64
        var closed = false
        var underruns = 0
        var reportedUnderruns = 0
        /// Host time of the render cycle holding the first sample (0 = not yet / none).
        var firstRenderHost: UInt64 = 0
        /// That cycle's first frame and the utterance's first frame (frames rendered).
        var firstCycleFrame: Int64 = 0
        var firstRenderFrame: Int64 = 0
        var firstRendered = false
        var reportedStart = false
        var flushed = false
    }

    struct State {
        static let segmentReserve = 64
        static let historyLimit = 16
        static let endedLimit = 32
        static let referenceBins = 1024
        static let referenceBinFrames = 240                 // 10 ms

        var readPos: Int64 = 0
        var writePos: Int64 = 0
        var segments: [Segment] = []
        var buffering = true
        var targetFrames = Int64(PCMStreamPlayer.minTargetMs / 1000 * PCMStreamPlayer.sampleRate)
        var fadePos: Int64 = 0
        var fadeLeft = 0
        var levelSum = 0.0
        var levelCount = 0
        var levelActive = false
        var outputLatency = 0.0
        /// Recently finished utterances' played ms (bounded).
        var history: [(name: String, ms: Int)] = []
        /// Recently flushed or finished utterances: late audio for them is dropped (bounded).
        var endedNames: [String] = []
        var overflowed = false
        var renderClock = false
        /// Frames the node has rendered (silence included).
        var renderedFrames: Int64 = 0
        /// Echo reference ring: energy of each 10 ms bin, its last frame, and the
        /// render cycle it ended in (host time + that cycle's first frame).
        var refEnergy = [Double](repeating: 0, count: State.referenceBins)
        var refFrame = [Int64](repeating: 0, count: State.referenceBins)
        var refHost = [UInt64](repeating: 0, count: State.referenceBins)
        var refCycle = [Int64](repeating: 0, count: State.referenceBins)
        var refWritten = 0
        var refRead = 0
        var binSum = 0.0
        var binFill = 0

        init() {
            // Reserved up front so the lock is never held across a reallocation.
            segments.reserveCapacity(Self.segmentReserve)
            history.reserveCapacity(Self.historyLimit + 1)
            endedNames.reserveCapacity(Self.endedLimit + 1)
        }

        /// Remembers `name` as ended; returns the name that fell out (release it
        /// after unlocking).
        mutating func ended(_ name: String) -> String? {
            guard !endedNames.contains(name) else { return nil }
            endedNames.append(name)
            return endedNames.count > Self.endedLimit ? endedNames.removeFirst() : nil
        }
    }

    final class Shared: @unchecked Sendable {
        let state = Mutex(State())
        let ring: UnsafeMutablePointer<Int16>
        let mask = Int64(PCMStreamPlayer.capacity - 1)

        init() {
            ring = .allocate(capacity: PCMStreamPlayer.capacity)
            ring.initialize(repeating: 0, count: PCMStreamPlayer.capacity)
        }

        deinit { ring.deallocate() }
    }

    public init() {
        let shared = Shared()
        self.shared = shared
        node = AVAudioSourceNode(format: Self.format) { isSilence, timestamp, frameCount, bufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let first = abl.first, let data = first.mData else { return noErr }
            let out = data.assumingMemoryBound(to: Float.self)
            let n = Int(frameCount)
            let produced = Self.render(shared, into: out, frames: n, hostTime: timestamp.pointee.mHostTime)
            if produced < n { (out + produced).update(repeating: 0, count: n - produced) }
            for k in 1..<abl.count { if let d = abl[k].mData { memcpy(d, data, n * MemoryLayout<Float>.size) } }
            if produced == 0 { isSilence.pointee = true }
            return noErr
        }
    }

    // MARK: Producer side (any thread)

    /// Appends 24 kHz mono Int16 LE samples to `utterance`.
    public func enqueue(_ pcm16: Data, utterance: String) {
        let count = pcm16.count / 2
        guard count > 0 else { return }
        pcm16.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            shared.state.withLock { s in
                // Deltas still in flight after a barge-in (or after the item was
                // finished) must never play.
                if s.endedNames.contains(utterance) { return }
                var appendTo: Int?
                if let last = s.segments.indices.last, !s.segments[last].closed, s.segments[last].name == utterance {
                    appendTo = last
                }
                if appendTo == nil {
                    if let last = s.segments.indices.last { s.segments[last].closed = true }
                    s.segments.append(Segment(name: utterance, start: s.writePos, end: s.writePos))
                }
                let oldest = s.fadeLeft > 0 ? s.fadePos : s.readPos
                let room = Int64(Self.capacity) - (s.writePos - oldest)
                let k = Int(min(Int64(count), max(room, 0)))
                if k < count { s.overflowed = true }
                var w = s.writePos
                for i in 0..<k {
                    shared.ring[Int(w & shared.mask)] = base.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)
                    w += 1
                }
                s.writePos = w
                s.segments[s.segments.count - 1].end = w
            }
        }
    }

    /// No more audio will come for `utterance`: play out what is buffered without
    /// waiting for the jitter target. Later audio for it is dropped.
    public func finish(utterance: String) {
        let dropped = shared.state.withLock { s -> String? in
            for i in s.segments.indices where s.segments[i].name == utterance { s.segments[i].closed = true }
            return s.ended(utterance)
        }
        withExtendedLifetime(dropped) {}                     // released here, not under the lock
    }

    /// Stops playback now and drops everything queued. Returns the first utterance
    /// cut — the one playing, or the one still prebuffering (`playedMs` 0) — and
    /// exactly how much of it was rendered; nil only when nothing was queued.
    /// `.finished(flushed: true)` events follow on the next poll for every
    /// utterance that was dropped (possibly without a `.started`).
    @discardableResult
    public func flush() -> Cut? {
        var garbage: [String] = []
        garbage.reserveCapacity(4)
        let cut = shared.state.withLock { s -> Cut? in
            var cut: Cut?
            for i in s.segments.indices {
                let seg = s.segments[i]
                if s.readPos < seg.end || !seg.closed {
                    if cut == nil {
                        cut = Cut(utterance: seg.name, playedMs: Self.ms(max(0, min(s.readPos, seg.end) - seg.start)))
                    }
                    s.segments[i].flushed = true
                    if let old = s.ended(seg.name) { garbage.append(old) }
                }
                s.segments[i].closed = true
                s.segments[i].end = max(min(s.readPos, seg.end), seg.start)
            }
            // Fade out only what is actually sounding: audio still prebuffering (or
            // waiting after an underrun) was never heard and must stay silent.
            let left = s.writePos - s.readPos
            if left > 0, !s.buffering {
                s.fadePos = s.readPos
                s.fadeLeft = Int(min(Int64(Self.fadeFrames), left))
            }
            s.readPos = s.writePos
            s.buffering = true
            return cut
        }
        withExtendedLifetime(garbage) {}
        if let cut { timeline?.mark(.flushed, at: clock?(), detail: "\(cut.utterance) played_ms=\(cut.playedMs)") }
        return cut
    }

    /// Milliseconds of `utterance` rendered so far (also after it finished or was
    /// flushed, for the last few utterances); 0 when unknown.
    public func playedMs(utterance: String) -> Int {
        shared.state.withLock { s in
            if let seg = s.segments.first(where: { $0.name == utterance }) {
                return Self.ms(max(0, min(s.readPos, seg.end) - seg.start))
            }
            return s.history.last(where: { $0.name == utterance })?.ms ?? 0
        }
    }

    /// Something is queued or playing.
    public var isBusy: Bool { shared.state.withLock { !$0.segments.isEmpty } }

    /// Milliseconds buffered ahead of the play position.
    public var bufferedMs: Int { shared.state.withLock { Self.ms($0.writePos - $0.readPos) } }

    /// The jitter buffer's current start threshold.
    public var targetMs: Double { shared.state.withLock { Double($0.targetFrames) / Self.sampleRate * 1000 } }

    // MARK: Events (poll queue / manual render thread)

    /// Turns render-side progress into events and delivers them to `onEvent`.
    /// `now`: host seconds for `.started` when the render thread had no timestamp.
    @discardableResult
    func poll(now: Double = ProcessInfo.processInfo.systemUptime) -> [Event] {
        // Allocated before locking; filled in place (no allocation under the lock
        // unless a poll has more than this many events).
        var events: [Event] = []
        events.reserveCapacity(8)
        var garbage: (name: String, ms: Int)?
        shared.state.withLock { s in
            var i = 0
            while i < s.segments.count {
                let seg = s.segments[i]
                if seg.firstRendered && !seg.reportedStart {
                    s.segments[i].reportedStart = true
                    let at = Self.time(frame: seg.firstRenderFrame, host: seg.firstRenderHost,
                                       cycle: seg.firstCycleFrame, renderClock: s.renderClock,
                                       now: now, latestFrame: s.renderedFrames)
                    events.append(.started(utterance: seg.name, at: at + s.outputLatency))
                }
                if seg.underruns > seg.reportedUnderruns {
                    s.segments[i].reportedUnderruns = seg.underruns
                    events.append(.underrun(utterance: seg.name))
                }
                if seg.closed && s.readPos >= seg.end {
                    let played = Self.ms(seg.end - seg.start)
                    events.append(.finished(utterance: seg.name, playedMs: played, flushed: seg.flushed))
                    s.history.append((seg.name, played))
                    if s.history.count > State.historyLimit { garbage = s.history.removeFirst() }
                    s.segments.remove(at: i)                 // in place: capacity kept
                    continue
                }
                i += 1
            }
            if s.levelCount > 0 {
                let db = Level.powerDB(s.levelSum / Double(s.levelCount))
                events.append(.level(Level.meter(db, floor: -50, ceiling: -12)))
                s.levelSum = 0
                s.levelCount = 0
                s.levelActive = true
            } else if s.levelActive && s.segments.isEmpty {
                s.levelActive = false
                events.append(.level(0))
            }
        }
        withExtendedLifetime(garbage) {}
        let (onEvent, observers, timeline) = hooks.withLock { ($0.onEvent, $0.observers, $0.timeline) }
        if let timeline {
            for case .started(let u, let at) in events { timeline.mark(.firstAudioPlayed, at: at, detail: u) }
        }
        for e in events {
            onEvent?(e)
            for o in observers { o.body(e) }
        }
        return events
    }

    // MARK: Render thread

    /// Fills `out` with up to `frames` samples; returns how many were real audio
    /// (the rest is silence the caller zeroes).
    private static func render(_ shared: Shared, into out: UnsafeMutablePointer<Float>, frames n: Int, hostTime: UInt64) -> Int {
        shared.state.withLock { s -> Int in
            var produced = 0
            // Fade out what was playing when flushed.
            if s.fadeLeft > 0 {
                let k = min(s.fadeLeft, n)
                for i in 0..<k {
                    let g = Float(s.fadeLeft - i) / Float(Self.fadeFrames + 1)
                    out[i] = Float(shared.ring[Int((s.fadePos + Int64(i)) & shared.mask)]) / 32768 * g
                }
                s.fadePos += Int64(k)
                s.fadeLeft -= k
                produced = k
                if produced == n { return produced }
            }
            var sumSq = 0.0
            var audible = 0
            while produced < n {
                // The segment holding the play position: skip the ones fully played.
                let pos = s.readPos
                guard let i = s.segments.firstIndex(where: { !($0.closed && pos >= $0.end) }) else { break }
                let seg = s.segments[i]
                let available = seg.end - s.readPos
                if s.buffering {
                    if seg.closed || available >= s.targetFrames {
                        s.buffering = false
                    } else {
                        break
                    }
                }
                if available <= 0 {
                    // Open segment, nothing buffered: the network fell behind.
                    if seg.firstRendered {
                        s.segments[i].underruns += 1
                        s.targetFrames = min(s.targetFrames + Self.frames(ms: Self.underrunStepMs), Self.frames(ms: Self.maxTargetMs))
                    }
                    s.buffering = true
                    break
                }
                if !seg.firstRendered {
                    s.segments[i].firstRendered = true
                    s.segments[i].firstRenderHost = hostTime
                    s.segments[i].firstCycleFrame = s.renderedFrames
                    s.segments[i].firstRenderFrame = s.renderedFrames + Int64(produced)
                }
                let k = Int(min(available, Int64(n - produced)))
                var r = s.readPos
                for j in 0..<k {
                    let v = Float(shared.ring[Int(r & shared.mask)]) / 32768
                    out[produced + j] = v
                    sumSq += Double(v * v)
                    r += 1
                }
                s.readPos = r
                produced += k
                audible += k
                if s.readPos >= seg.end && seg.closed {
                    // Utterance complete: adapt the jitter target, prebuffer the next one.
                    if s.segments[i].underruns == 0, seg.end - seg.start >= Int64(Self.sampleRate) {
                        s.targetFrames = max(s.targetFrames - Self.frames(ms: Self.cleanStepMs), Self.frames(ms: Self.minTargetMs))
                    }
                    s.buffering = true
                }
            }
            if audible > 0 {
                s.levelSum += sumSq
                s.levelCount += audible
            }
            recordReference(&s, out, produced: produced, frames: n, hostTime: hostTime)
            s.renderedFrames += Int64(n)
            return produced
        }
    }

    /// Bins this cycle's output (`produced` real samples, then silence) into 10 ms
    /// reference energies. No allocation: the ring is preallocated.
    private static func recordReference(_ s: inout State, _ out: UnsafeMutablePointer<Float>, produced: Int, frames n: Int,
                                        hostTime: UInt64) {
        var i = 0
        while i < n {
            let take = min(State.referenceBinFrames - s.binFill, n - i)
            if i < produced {
                let upto = min(i + take, produced)
                var sum = 0.0
                for j in i..<upto { let v = Double(out[j]); sum += v * v }
                s.binSum += sum
            }
            s.binFill += take
            i += take
            if s.binFill >= State.referenceBinFrames {
                let k = s.refWritten % State.referenceBins
                s.refEnergy[k] = s.binSum / Double(State.referenceBinFrames)
                s.refFrame[k] = s.renderedFrames + Int64(i)
                s.refHost[k] = hostTime
                s.refCycle[k] = s.renderedFrames
                s.refWritten += 1
                if s.refWritten - s.refRead > State.referenceBins { s.refRead = s.refWritten - State.referenceBins }
                s.binSum = 0
                s.binFill = 0
            }
        }
    }

    /// The echo reference rendered since the last call: 10 ms energies on the
    /// graph clock (render time; the route's latency not included).
    public func takeReference(now: Double? = nil) -> [EchoReference.Bin] {
        let fallback = now ?? clock?() ?? ProcessInfo.processInfo.systemUptime
        return shared.state.withLock { s -> [EchoReference.Bin] in
            let count = s.refWritten - s.refRead
            guard count > 0 else { return [] }
            var bins: [EchoReference.Bin] = []
            bins.reserveCapacity(count)
            for w in s.refRead..<s.refWritten {
                let k = w % State.referenceBins
                let t = Self.time(frame: s.refFrame[k], host: s.refHost[k], cycle: s.refCycle[k],
                                  renderClock: s.renderClock, now: fallback, latestFrame: s.renderedFrames)
                bins.append(EchoReference.Bin(t: t, energy: s.refEnergy[k]))
            }
            s.refRead = s.refWritten
            return bins
        }
    }

    // MARK: Helpers

    /// Whole milliseconds in `frames`, rounded down (a truncate point must never
    /// exceed the audio the server generated).
    static func ms(_ frames: Int64) -> Int { Int((Double(frames) * 1000 / sampleRate).rounded(.down)) }
    static func frames(ms: Double) -> Int64 { Int64((ms / 1000 * sampleRate).rounded()) }

    static func seconds(hostTime: UInt64) -> Double {
        AVAudioTime.seconds(forHostTime: hostTime)
    }

    /// When rendered frame `frame` (an end position, frames rendered so far) left
    /// the node: manual rendering counts frames; live adds its offset in the cycle
    /// to the cycle's host time, or (no host time) backs off from `now`.
    static func time(frame: Int64, host: UInt64, cycle: Int64, renderClock: Bool, now: Double, latestFrame: Int64) -> Double {
        if renderClock { return Double(frame) / sampleRate }
        if host != 0 { return seconds(hostTime: host) + Double(frame - cycle) / sampleRate }
        return now - Double(max(latestFrame - frame, 0)) / sampleRate
    }
}
