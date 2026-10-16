import Foundation
import Synchronization

/// Whether the on-device ear can listen for the wake phrase.
public enum EarAvailability: Sendable, Equatable {
    case ready
    /// Speech-recognition permission not asked yet.
    case notAsked
    /// The on-device speech model is downloading (0…1).
    case assetsDownloading(Double)
    /// The on-device speech model isn't installed (one-time download, never audio).
    case assetsMissing
    /// Speech recognition (or the microphone) is denied.
    case denied
    /// This device / language has no on-device recogniser.
    case unsupported
    /// Legacy recogniser only: Siri & Dictation are off.
    case siriDictationOff
    /// `ProcessInfo.thermalState ≥ .serious`: the ear pauses (a tap still wakes her).
    case thermalBackoff

    public static let unavailableText = "I can't hear my wake phrase — tap me to talk"

    /// The status-chip text, nil when ready. Never suggests server recognition.
    public var problemText: String? {
        switch self {
        case .ready: nil
        case .thermalBackoff: "I'm too warm to listen — tap me to talk"
        case .assetsDownloading(let p): "I'm still learning to hear my wake phrase (\(Int((p * 100).rounded()))%) — tap me to talk"
        default: Self.unavailableText
        }
    }

    public var isReady: Bool { self == .ready }
}

/// One local wake. Frames are on the 24 kHz capture clock (PCM16Capture positions).
public struct WakeHit: Sendable, Equatable {
    /// Where the phrase starts; already clamped so it never reaches further back than
    /// the phrase itself (contract §3). nil = unknown (use `detectedFrame`).
    public var onsetFrame: Int64?
    /// The onset comes from a final result's word timing (±50 ms) rather than the
    /// energy walk-back.
    public var onsetFromFinal: Bool
    /// The newest fed frame when the match was seen.
    public var detectedFrame: Int64
    /// Normalised matched words ("hey dee", "heidi").
    public var matched: String
    public var tier: MatchTier
    /// End of the matched words when the recogniser placed them.
    public var phraseEndFrame: Int64?

    public init(onsetFrame: Int64?, onsetFromFinal: Bool, detectedFrame: Int64, matched: String, tier: MatchTier, phraseEndFrame: Int64? = nil) {
        self.onsetFrame = onsetFrame
        self.onsetFromFinal = onsetFromFinal
        self.detectedFrame = detectedFrame
        self.matched = matched
        self.tier = tier
        self.phraseEndFrame = phraseEndFrame
    }
}

/// The on-device wake listener (contract §3). `consume` is called from the mic
/// consumer with 16 kHz mono PCM16 (see `Downsampler24to16`) and the 24 kHz capture
/// frame of its first sample; it never sends anything anywhere.
public protocol WakeEar: Sendable {
    func start(phrase: WakePhrase) async
    func stop() async
    func setPhrase(_ phrase: WakePhrase) async
    /// False-wake backoff: tiers exact + alias only.
    func setStrict(_ strict: Bool) async
    func consume(_ pcm16k: [Int16], captureFrame24k: Int64)
    var hits: AsyncStream<WakeHit> { get }
    /// The "perking up" cue: first phrase word + the start of the next.
    var candidates: AsyncStream<Void> { get }
    var availability: AsyncStream<EarAvailability> { get }
}

/// A broadcast `AsyncStream` source: every `stream` call gets its own subscriber.
final class Broadcast<Element: Sendable>: Sendable {
    private let subscribers = Mutex<[UUID: AsyncStream<Element>.Continuation]>([:])
    private let replayLast: Bool
    private let last = Mutex<Element?>(nil)

    init(replayLast: Bool = false) { self.replayLast = replayLast }

    var stream: AsyncStream<Element> {
        let (s, c) = AsyncStream<Element>.makeStream(bufferingPolicy: .bufferingNewest(64))
        let id = UUID()
        if replayLast, let v = last.withLock({ $0 }) { c.yield(v) }
        subscribers.withLock { $0[id] = c }
        c.onTermination = { [weak self] _ in self?.subscribers.withLock { _ = $0.removeValue(forKey: id) } }
        return s
    }

    func yield(_ value: Element) {
        if replayLast { last.withLock { $0 = value } }
        for c in subscribers.withLock({ Array($0.values) }) { c.yield(value) }
    }

    func finish() {
        for c in subscribers.withLock({ s in defer { s.removeAll() }; return Array(s.values) }) { c.finish() }
    }
}

/// A wake ear driven by hand — for host, harness and window tests. `emit` delivers a
/// hit exactly as the on-device ear would; `consume` only counts frames.
public final class ScriptedWakeEar: WakeEar {
    private struct State { var running = false; var phrase = WakePhrase.default; var strict = false; var consumedFrames = 0 }
    private let state = Mutex(State())
    private let hitCast = Broadcast<WakeHit>()
    private let candidateCast = Broadcast<Void>()
    private let availabilityCast = Broadcast<EarAvailability>(replayLast: true)

    public init() {}

    public func start(phrase: WakePhrase) async {
        state.withLock { $0.running = true; $0.phrase = phrase }
        availabilityCast.yield(.ready)
    }
    public func stop() async { state.withLock { $0.running = false } }
    public func setPhrase(_ phrase: WakePhrase) async { state.withLock { $0.phrase = phrase } }
    public func setStrict(_ strict: Bool) async { state.withLock { $0.strict = strict } }
    public func consume(_ pcm16k: [Int16], captureFrame24k: Int64) {
        state.withLock { if $0.running { $0.consumedFrames += pcm16k.count } }
    }
    public var hits: AsyncStream<WakeHit> { hitCast.stream }
    public var candidates: AsyncStream<Void> { candidateCast.stream }
    public var availability: AsyncStream<EarAvailability> { availabilityCast.stream }

    public var isRunning: Bool { state.withLock { $0.running } }
    public var phrase: WakePhrase { state.withLock { $0.phrase } }
    public var isStrict: Bool { state.withLock { $0.strict } }
    public var consumedSamples: Int { state.withLock { $0.consumedFrames } }

    /// Deliver a hit (only while started, like the real ear).
    public func emit(_ hit: WakeHit) { if isRunning { hitCast.yield(hit) } }
    public func emitCandidate() { if isRunning { candidateCast.yield(()) } }
    public func setAvailability(_ a: EarAvailability) { availabilityCast.yield(a) }
}
