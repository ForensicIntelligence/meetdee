import Foundation
import Synchronization

/// The waits that differ between providers (contract §2), set by `ProviderFactory`
/// on the session config (`apply(to:)`) and read by `RealtimeBrain.Options.timing`.
/// `.realtime` is today's values exactly: mode 1 is byte-for-byte the tuned path.
public struct TimingProfile: Sendable, Equatable {
    /// Which hearing a cascaded profile is tuned for (its word waits differ).
    public enum CascadeSTT: String, Sendable, Equatable, Codable { case openAIRealtime, lanREST, onDevice }

    public var name: String
    /// `RealtimeSessionConfig.responseTimeout`: `response.create` → `response.created`.
    public var responseTimeout: Double
    /// `RealtimeSessionConfig.firstAudioTimeout`: `response.created` → first audio.
    public var firstAudioTimeout: Double
    /// `RealtimeSessionConfig.cancelUnstartedWait`.
    public var cancelUnstartedWait: Double
    /// `RealtimeSessionConfig.rolloverAfter` / `forceRolloverAfter` (∞: never).
    public var rolloverAfter: Double
    public var forceRolloverAfter: Double

    // Brain side (RealtimeBrain reads these; `.realtime` = today's behaviour).
    /// The brain re-requests a reply that hasn't started (`stallRetryAfter`). Off for
    /// a LAN model loading for 35 s: a second request would only queue behind it.
    public var stallRetry: Bool
    /// The "one sec" clip for a slow start plays at most once per window, keyed to the
    /// measured time to first token (false: today's rule).
    public var slowClipOncePerWindow: Bool
    /// Multiplies TurnPolicy's waits for words (1 = today). Longer for LAN speech-to-text
    /// (no deltas: the whole transcript comes at once, later).
    public var wordWaitScale: Double

    public init(name: String, responseTimeout: Double, firstAudioTimeout: Double, cancelUnstartedWait: Double,
                rolloverAfter: Double, forceRolloverAfter: Double, stallRetry: Bool, slowClipOncePerWindow: Bool,
                wordWaitScale: Double) {
        self.name = name
        self.responseTimeout = responseTimeout
        self.firstAudioTimeout = firstAudioTimeout
        self.cancelUnstartedWait = cancelUnstartedWait
        self.rolloverAfter = rolloverAfter
        self.forceRolloverAfter = forceRolloverAfter
        self.stallRetry = stallRetry
        self.slowClipOncePerWindow = slowClipOncePerWindow
        self.wordWaitScale = wordWaitScale
    }

    /// Mode 1, OpenAI gpt-realtime: exactly today's values (`RealtimeSessionConfig()`).
    public static let realtime: TimingProfile = {
        let c = RealtimeSessionConfig()
        return TimingProfile(name: "realtime", responseTimeout: c.responseTimeout, firstAudioTimeout: c.firstAudioTimeout,
                             cancelUnstartedWait: c.cancelUnstartedWait, rolloverAfter: c.rolloverAfter,
                             forceRolloverAfter: c.forceRolloverAfter, stallRetry: true, slowClipOncePerWindow: false,
                             wordWaitScale: 1)
    }()

    /// A LAN server that speaks the realtime protocol: realtime waits, no 60-minute
    /// session limit to roll over from.
    public static let lanRealtime: TimingProfile = {
        var p = TimingProfile.realtime
        p.name = "lanRealtime"
        p.rolloverAfter = .infinity
        p.forceRolloverAfter = .infinity
        return p
    }()

    /// Modes 2 / 3 (`CascadeSocket`): a first token may take 35 s while a LAN model
    /// loads (measured), so the request and first-audio waits are 90 s; no rollover
    /// (the emulator has no session limit); no stall re-request.
    public static func cascaded(stt: CascadeSTT) -> TimingProfile {
        TimingProfile(name: "cascaded-\(stt.rawValue)", responseTimeout: 90, firstAudioTimeout: 90,
                      cancelUnstartedWait: 2.5, rolloverAfter: .infinity, forceRolloverAfter: .infinity,
                      stallRetry: false, slowClipOncePerWindow: true,
                      wordWaitScale: stt == .lanREST ? 1.6 : 1)
    }

    /// Writes the session-side values into `c`.
    public func apply(to c: inout RealtimeSessionConfig) {
        c.responseTimeout = responseTimeout
        c.firstAudioTimeout = firstAudioTimeout
        c.cancelUnstartedWait = cancelUnstartedWait
        c.rolloverAfter = rolloverAfter
        c.forceRolloverAfter = forceRolloverAfter
    }
}

/// Who a problem, a usage line or a status names: OpenAI, a LAN server by host,
/// or this iPhone. (Lives here, not in DeeLocal, because DeeVoice words its
/// problems with it; DeeLocal uses this one.)
public enum ProviderLabel: Sendable, Equatable, Hashable, Codable {
    case openAI
    case lan(host: String)
    case onDevice

    /// "OpenAI" / "HOST" / "this iPhone".
    public var name: String {
        switch self {
        case .openAI: "OpenAI"
        case .lan(let host): host
        case .onDevice: "this iPhone"
        }
    }

    /// "OpenAI" / "the AI server at HOST" / "this iPhone".
    public var spokenName: String {
        switch self {
        case .openAI: "OpenAI"
        case .lan(let host): "the AI server at \(host)"
        case .onDevice: "this iPhone"
        }
    }

    public var isOpenAI: Bool { self == .openAI }
}

/// EarCore's bed-proof "a voice is in the room" for every frame CloudVoice
/// uplinked, positioned on the feed stream (`RealtimeSession.feedAudio` order):
/// what mode 3's local turn detector (`DeeLocal.LocalTurnDetector`) ANDs with
/// Apple's speech detector. Written on the tap path, read by `CascadeSocket`.
public final class UplinkActivity: Sendable {
    private struct Run { var start: Int64; var frames: Int64; var voice: Bool }
    private struct State { var runs: [Run] = []; var fed: Int64 = 0; var now = false }
    private let state = Mutex(State())
    /// Frames of history kept (60 s at 24 kHz).
    static let keepFrames: Int64 = 24_000 * 60

    public init() {}

    /// The next `frames` fed frames carry (or don't) a voice.
    public func record(frames: Int, voice: Bool) {
        guard frames > 0 else { return }
        state.withLock { s in
            if let last = s.runs.indices.last, s.runs[last].voice == voice,
               s.runs[last].start + s.runs[last].frames == s.fed {
                s.runs[last].frames += Int64(frames)
            } else {
                s.runs.append(Run(start: s.fed, frames: Int64(frames), voice: voice))
            }
            s.fed += Int64(frames)
            s.now = voice
            while let first = s.runs.first, first.start + first.frames < s.fed - Self.keepFrames { s.runs.removeFirst() }
        }
    }

    /// Whether a voice was in feed frame `frame` (nil: not recorded / forgotten).
    public func voiceActive(atFedFrame frame: Int64) -> Bool? {
        state.withLock { s in s.runs.last { $0.start <= frame && frame < $0.start + $0.frames }?.voice }
    }

    /// The newest uplinked frame's verdict (what a consumer that processes appends
    /// as they arrive can use without mapping positions).
    public var voiceNow: Bool { state.withLock { $0.now } }

    /// Frames recorded so far (the feed stream's clock as CloudVoice counts it).
    public var latestFedFrame: Int64 { state.withLock { $0.fed } }
}
