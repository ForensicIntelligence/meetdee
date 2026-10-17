import Foundation

/// Detects the user clearly talking over Dee while Dee speaks.
///
/// Only meaningful with voice-processing echo cancellation on; without it Dee's own
/// voice would trip it, so `aecActive == false` never fires (`EarCore` passes
/// true and raises the bar by `EarCore.noAECMarginDB` instead). Needs sustained,
/// loud, voiced input; the bar rises with how loud Dee is right now, so
/// residual echo doesn't count. `EarCore` uses it as the local evidence that a
/// server speech onset during Dee's playback is the user, not Dee's echo.
public struct BargeInDetector: Sendable {
    public var minAboveFloorDB: Double = 16
    public var minDB: Double = -40
    /// Extra dB required per unit of Dee's own speech level (0…1).
    public var echoMarginDB: Double = 8
    public var sustain: Double = 0.28

    /// Share of the sustained run that must be pitched (`update(near:pitched:)`).
    public var pitchedShare = 0.4

    private var run = 0.0
    private var pitchedRun = 0.0
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

    /// Sustain only, for a caller that has already decided the frame is above its
    /// bar (`near`). Frames above the bar build the run (anything else lets it
    /// decay); it fires once the run is `sustain` long *and* enough of it was
    /// pitched (`pitchedShare`): voice, not a clatter. Consonants between vowels
    /// keep the run going without counting as pitch.
    public mutating func update(near: Bool, pitched: Bool, frameDuration dt: Double) -> Bool {
        guard !fired else { return false }
        if near {
            run += dt
            if pitched { pitchedRun += dt }
        } else {
            run = max(0, run - dt * 0.5)
            pitchedRun = max(0, pitchedRun - dt * 0.5)
        }
        pitchedRun = min(pitchedRun, run)
        if run >= sustain - 1e-9, pitchedRun >= sustain * pitchedShare - 1e-9 {
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
        pitchedRun = 0
        fired = false
    }
}
