import DeeCore

// Public value types of the v0.4 voice contract (docs/CONTRACTS-0.4.md).

/// How someone said something, measured from the microphone over the utterance.
public struct VoiceProsody: Sendable, Equatable {
    /// Mean dBFS over voiced frames (energy mean, not mean of dB values).
    public var loudnessDB: Double
    /// Loudest sample in dBFS.
    public var peakDB: Double
    /// Words per second of voiced audio.
    public var speechRate: Double
    /// Standard deviation of f0 in semitones (flat ≈ 0–1, lively ≈ 3+).
    public var pitchVariability: Double
    /// Mean fundamental frequency; 0 when unknown.
    public var meanPitchHz: Double

    public init(loudnessDB: Double = -100, peakDB: Double = -100, speechRate: Double = 0,
                pitchVariability: Double = 0, meanPitchHz: Double = 0) {
        self.loudnessDB = loudnessDB
        self.peakDB = peakDB
        self.speechRate = speechRate
        self.pitchVariability = pitchVariability
        self.meanPitchHz = meanPitchHz
    }
}

/// One finished utterance from the user.
public struct HeardUtterance: Sendable, Equatable {
    public var text: String
    public var prosody: VoiceProsody
    /// Seconds of speech.
    public var duration: Double

    public init(text: String, prosody: VoiceProsody, duration: Double) {
        self.text = text
        self.prosody = prosody
        self.duration = duration
    }
}

/// A non-speech sound the classifier picked up.
public struct HeardSound: Sendable, Equatable {
    /// Human words: "doorbell", "dog barking".
    public var label: String
    /// Classifier identifier (SoundAnalysis v1), e.g. "door_bell".
    public var identifier: String
    public var confidence: Double
    public var loudnessDB: Double
    /// Novel, salient, not speech/silence/ambient.
    public var isUnexpected: Bool

    public init(label: String, identifier: String, confidence: Double, loudnessDB: Double, isUnexpected: Bool) {
        self.label = label
        self.identifier = identifier
        self.confidence = confidence
        self.loudnessDB = loudnessDB
        self.isUnexpected = isUnexpected
    }

    /// What family the sound belongs to. `.laughter` events are reported even when
    /// they are not unexpected, so Dee can laugh along whatever her mood.
    public var kind: SoundKind { SoundCatalog.kind(of: identifier) }
}

/// Coarse families of classifier identifiers.
public enum SoundKind: String, Sendable, Equatable, CaseIterable {
    case speech      // talking, whispering, chatter
    case silence
    case ambient     // fans, rain, traffic, typing ... the room's furniture
    case music       // music, instruments, singing
    case laughter    // laughter, giggling, chuckles (social: always reported)
    case crying      // crying, sobbing (social: always reported)
    case applause    // clapping, cheering, applause (social: always reported)
    case event       // everything else: doorbells, dogs, glass breaking ...

    /// Social sounds are emitted even when familiar (rate-limited), never as "unexpected".
    public var isSocial: Bool { self == .laughter || self == .crying || self == .applause }
}

/// Everything the voice service tells the app.
public enum VoiceEvent: Sendable, Equatable {
    case permission(microphone: Bool, speech: Bool)
    case ready
    case listening(Bool)
    case partial(String)
    case heard(HeardUtterance)
    case sound(HeardSound)
    /// 0…1, ~20 Hz while listening.
    case micLevel(Double)
    case speakingStarted
    /// 0…1, ~30 Hz while speaking (eye bounce).
    case speechLevel(Double)
    case speakingFinished
    /// The user started talking over Dee.
    case bargeIn
    /// The user paused mid-turn (≥ 150 ms; re-sent when the estimate changes during
    /// the same pause). `turnEnd`: 0…1 probability they have finished; `hesitation`:
    /// 0…1, holding the floor while searching for words ("um", "and…", restarts).
    case pause(turnEnd: Double, hesitation: Double)
    case error(String)
}
