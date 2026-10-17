import Foundation

/// Tune 9 (T8-1): what one short item said over Dee's voice *sounded* like — its
/// voiced length, how many syllable-ish energy peaks it had and how its pitch ended.
///
/// Words alone are unreliable over Dee's voice: live tune 8, "Who made you?" came back
/// as **"Movie."** and was taken for a misheard "go on". A one-word fragment the words
/// don't know (`Backchannel.isKnownFragmentWord`) is a backchannel only when it also
/// *sounds* like one (`backchannelLike`: short, at most two syllables, not rising);
/// anything that sounds like a question (`questionLike`) pauses Dee for the brain.
///
/// Measured by `EarCore.itemSound` from the logged microphone frames of the server
/// item (its onset to its end), on the user's near-end voice only (never Dee's echo).
public struct FragmentSound: Sendable, Equatable {
    /// How the pitch moved over the item's last voiced stretch.
    public enum PitchEnd: String, Sendable, Equatable {
        case rising, falling, flat
        /// Too few pitched frames to tell.
        case unknown
    }

    /// Seconds of the user's pitched voice in the item.
    public var voiced: Double
    /// Syllable-ish energy peaks of their voice (each with pitch in it).
    public var syllables: Int
    public var pitchEnd: PitchEnd
    /// Semitones from the middle of the voiced stretch to its end (+ rising); 0 when unknown.
    public var endSemitones: Double

    public init(voiced: Double, syllables: Int, pitchEnd: PitchEnd, endSemitones: Double = 0) {
        self.voiced = voiced
        self.syllables = syllables
        self.pitchEnd = pitchEnd
        self.endSemitones = endSemitones
    }

    /// At most this much pitched voice for a backchannel-like sound ("mm-hm", "go on").
    public static let backchannelMaxVoiced = 0.45
    /// …and at most this many syllables ("who made you" has three).
    public static let backchannelMaxSyllables = 2
    /// Less pitched voice than this is no evidence of their sound at all (masked,
    /// or nothing of theirs heard): the sound decides nothing.
    public static let minVoiced = 0.08
    /// Semitones of end rise that make it a rising (question-like) end.
    public static let riseSemitones = 2.0

    /// There was enough of their voice to judge it by its sound.
    public var heard: Bool { voiced >= Self.minVoiced - 1e-9 && syllables >= 1 }

    /// Short, at most two syllables, flat or falling (or too short to have a contour):
    /// a "mm-hm", "go on", "yeah" whatever its words came back as.
    public var backchannelLike: Bool {
        heard && voiced <= Self.backchannelMaxVoiced + 1e-9 && syllables <= Self.backchannelMaxSyllables
            && pitchEnd != .rising
    }

    /// Rising at the end, or three syllables or more: a question or a turn of their own.
    public var questionLike: Bool {
        heard && (pitchEnd == .rising || syllables > Self.backchannelMaxSyllables)
    }

    /// One logged analysis frame, as `EarCore` judged it.
    public struct Frame: Sendable {
        public var t: Double
        public var dt: Double
        public var db: Double
        /// Near-end sound of theirs (not Dee's echo).
        public var near: Bool
        /// …and pitched voice.
        public var pitched: Bool
        public var f0: Double?

        public init(t: Double, dt: Double, db: Double, near: Bool, pitched: Bool, f0: Double?) {
            self.t = t
            self.dt = dt
            self.db = db
            self.near = near
            self.pitched = pitched
            self.f0 = f0
        }
    }

    /// dB a syllable's energy must fall from its peak, then rise again from the
    /// valley, for a new syllable inside one run of voice.
    static let dipDB = 3.0
    /// Silence (no near-end sound) this long ends a syllable.
    static let gapSeconds = 0.07

    /// Measures `frames` (in time order).
    public static func analyze(_ frames: [Frame]) -> FragmentSound {
        var voiced = 0.0
        var syllables = 0
        // Syllable nuclei: energy peaks of near-end sound with pitch in them.
        var inSyl = false, sylPitched = false, falling = false
        var peak = -Double.infinity, valley = Double.infinity
        var lastNear = -Double.infinity
        func close() {
            if inSyl, sylPitched { syllables += 1 }
            inSyl = false
            sylPitched = false
            falling = false
        }
        for f in frames {
            if f.pitched { voiced += f.dt }
            guard f.near else {
                if inSyl, f.t - lastNear >= gapSeconds - 1e-9 { close() }
                continue
            }
            lastNear = f.t
            if !inSyl {
                inSyl = true
                sylPitched = f.pitched
                peak = f.db
                valley = f.db
                falling = false
                continue
            }
            if falling {
                valley = min(valley, f.db)
                if f.db >= valley + dipDB {
                    // A new peak after a dip: the next syllable.
                    close()
                    inSyl = true
                    sylPitched = f.pitched
                    peak = f.db
                    valley = f.db
                    continue
                }
            } else if f.db <= peak - dipDB {
                falling = true
                valley = f.db
            }
            peak = max(peak, f.db)
            if f.pitched { sylPitched = true }
        }
        close()
        let (end, semis) = Self.pitchEnd(frames.compactMap { f in f.pitched ? f.f0 : nil })
        return FragmentSound(voiced: voiced, syllables: syllables, pitchEnd: end, endSemitones: semis)
    }

    /// The pitch's end: the median of the last third of the pitched frames against the
    /// median of the middle third, in semitones (octave errors dropped first).
    static func pitchEnd(_ f0: [Double]) -> (PitchEnd, Double) {
        let valid = f0.filter { $0.isFinite && $0 > 0 }
        guard valid.count >= 4 else { return (.unknown, 0) }
        let median = valid.sorted()[valid.count / 2]
        let st = valid.filter { $0 >= median / 1.8 && $0 <= median * 1.8 }.map { 12 * log2($0) }
        guard st.count >= 4 else { return (.unknown, 0) }
        let third = max(1, st.count / 3)
        func med(_ x: ArraySlice<Double>) -> Double { let s = x.sorted(); return s[s.count / 2] }
        let endM = med(st.suffix(third))
        let midM = med(st.dropLast(third).suffix(max(1, st.count - 2 * third)))
        let d = endM - midM
        if d >= riseSemitones - 1e-9 { return (.rising, d) }
        if d <= -riseSemitones + 1e-9 { return (.falling, d) }
        return (.flat, d)
    }
}
