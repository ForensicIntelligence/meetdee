import Foundation

/// Decides when the user has finished an utterance.
///
/// End of utterance ≈ the transcriber has finalized the text, plus `quietInterval`
/// (~0.8 s) with no new text *and* no voiced frames from the energy VAD. When the
/// transcriber sits on volatile text through a pause, the detector first asks for a
/// forced finalize, then gives up waiting and takes the volatile text as said.
/// Constant background noise can't hold an utterance open forever: after
/// `noTextTimeout` without new words it ends anyway.
public struct EndpointDetector: Sendable {
    public enum Decision: Sendable, Equatable {
        case wait
        /// Ask the analyzer to finalize its volatile range now.
        case finalizeVolatile
        case endUtterance(String)
    }

    public var quietInterval: Double = 0.8
    public var volatileTimeout: Double = 1.4
    public var volatileGiveUp: Double = 2.6
    public var noTextTimeout: Double = 3.0
    public var maxUtterance: Double = 30

    public private(set) var committed = ""
    public private(set) var volatile = ""
    private var lastTextTime: Double?
    private var lastVoicedTime: Double?
    private var startTime: Double?
    private var askedToFinalize = false

    public init() {}

    /// Allowed range for `setQuietInterval(_:)` (SELF.md §7.1).
    public static let quietIntervalRange: ClosedRange<Double> = 0.35...2.5

    /// Sets how long the user must be quiet before the utterance ends, clamped to
    /// 0.35…2.5 s (non-finite values are ignored). Driven by `TurnPredictor`.
    public mutating func setQuietInterval(_ seconds: Double) {
        guard seconds.isFinite else { return }
        quietInterval = min(max(seconds, Self.quietIntervalRange.lowerBound), Self.quietIntervalRange.upperBound)
    }

    /// What the user has said so far (finalized + volatile).
    public var text: String { Self.join(committed, volatile) }
    public var isEmpty: Bool { committed.isEmpty && volatile.isEmpty }

    public mutating func final(_ text: String, at t: Double) {
        let clean = Self.normalize(text)
        if !clean.isEmpty {
            committed = Self.join(committed, clean)
            touchText(t)
        }
        volatile = ""
        askedToFinalize = false
    }

    public mutating func volatile(_ text: String, at t: Double) {
        let clean = Self.normalize(text)
        if clean != volatile {
            volatile = clean
            if !clean.isEmpty { touchText(t) }
        }
    }

    public mutating func voice(_ voiced: Bool, at t: Double) {
        if voiced { lastVoicedTime = t }
    }

    public mutating func check(at t: Double) -> Decision {
        guard !isEmpty, let lastText = lastTextTime else { return .wait }
        let lastActivity = max(lastText, lastVoicedTime ?? lastText)
        let quiet = t - lastActivity
        let sinceText = t - lastText
        let long = (startTime.map { t - $0 } ?? 0) >= maxUtterance

        if !volatile.isEmpty {
            if sinceText >= volatileGiveUp && (quiet >= quietInterval || sinceText >= noTextTimeout + volatileGiveUp) {
                return end()
            }
            if !askedToFinalize && (min(quiet, sinceText) >= volatileTimeout || sinceText >= noTextTimeout || long) {
                askedToFinalize = true
                return .finalizeVolatile
            }
            return .wait
        }
        if quiet >= quietInterval || sinceText >= noTextTimeout || long {
            return end()
        }
        return .wait
    }

    public mutating func reset() {
        committed = ""
        volatile = ""
        lastTextTime = nil
        lastVoicedTime = nil
        startTime = nil
        askedToFinalize = false
    }

    private mutating func end() -> Decision {
        let said = text
        reset()
        return said.isEmpty ? .wait : .endUtterance(said)
    }

    private mutating func touchText(_ t: Double) {
        if startTime == nil { startTime = t }
        lastTextTime = t
    }

    static func normalize(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }
}

/// Detects the user clearly talking over Dee while she speaks.
///
/// Only meaningful with voice-processing echo cancellation on; without it her own
/// voice would trip it, so `aecActive == false` never fires. Needs sustained,
/// loud, voiced input; the bar rises with how loud Dee herself is right now, so
/// residual echo doesn't count.
public struct BargeInDetector: Sendable {
    public var minAboveFloorDB: Double = 16
    public var minDB: Double = -40
    /// Extra dB required per unit of Dee's own speech level (0…1).
    public var echoMarginDB: Double = 8
    public var sustain: Double = 0.28

    private var run = 0.0
    private var fired = false

    public init() {}

    public mutating func update(frameDB: Double, voiced: Bool, floorDB: Double, ownSpeechLevel: Double,
                                aecActive: Bool, speaking: Bool, frameDuration dt: Double) -> Bool {
        guard aecActive, speaking, !fired else { return false }
        let bar = bar(floorDB: floorDB, ownSpeechLevel: ownSpeechLevel)
        if voiced && frameDB >= bar {
            run += dt
        } else {
            run = max(0, run - dt * 0.5)
        }
        if run >= sustain {
            fired = true
            return true
        }
        return false
    }

    public var hasFired: Bool { fired }

    /// The level (dBFS) the user's voice must reach to count over Dee's own.
    public func bar(floorDB: Double, ownSpeechLevel: Double) -> Double {
        max(floorDB + minAboveFloorDB, minDB) + echoMarginDB * min(max(ownSpeechLevel, 0), 1)
    }

    public mutating func reset() {
        run = 0
        fired = false
    }
}

/// Half-duplex gate: is the recognizer allowed to listen right now?
///
/// Closed while Dee is about to speak or speaking, reopened `resumeDelay` (~0.4 s)
/// after she finishes — or immediately on barge-in.
public struct DuplexGate: Sendable, Equatable {
    public var resumeDelay: Double = 0.4
    public private(set) var speaking = false
    public private(set) var bargedIn = false
    private var resumeAt: Double = -.infinity

    public init() {}

    public mutating func speechRequested() {
        speaking = true
        bargedIn = false
    }

    public mutating func bargeIn() {
        if speaking { bargedIn = true }
    }

    public mutating func speechFinished(at t: Double) {
        let wasBargedIn = bargedIn
        speaking = false
        bargedIn = false
        resumeAt = wasBargedIn ? t : t + resumeDelay
    }

    public func isOpen(at t: Double) -> Bool {
        if speaking { return bargedIn }
        return t >= resumeAt
    }
}
