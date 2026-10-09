# v0.4 module contracts — "She's alive"

Four modules are built in parallel; the app (`App/Sources`) is wired against these
signatures at the same time. **Implement them exactly** (names, parameter labels,
types). Adding extra API is fine; renaming or removing is not.

Product rules for this round (from John, the user):
- Dee ("she") is **eyes only**, but far more expressive: many more expressions,
  glyph-shaped eyes, little performances, never looking quite the same twice.
- Dee is **very interactive, no matter what**: curious idle behaviour; she asks about
  things she sees through **either camera** and about **unexpected sounds**.
- Dee **talks and listens** hands-free. Microphone permission must be requested.
- **Touch** on the screen counts: gentle, kind, caring touch raises positive feelings
  and personality traits; rough touch lowers them.
- Dee must **feel alive**: she can still laugh at a joke or light up at a kind word
  even when her mood is bad (reflexes sit above mood).
- The perpetual "?" bug: at rest, "curious" must not be the permanent expression.

---

## DeeVoice (owner: voice) — `Sources/DeeVoice`, `Tests/DeeVoiceTests`

```swift
public struct VoiceProsody: Sendable, Equatable {
    public var loudnessDB: Double        // mean dBFS over voiced frames
    public var peakDB: Double
    public var speechRate: Double        // words per second
    public var pitchVariability: Double  // semitone standard deviation of f0
    public var meanPitchHz: Double       // 0 when unknown
}

public struct HeardUtterance: Sendable, Equatable {
    public var text: String
    public var prosody: VoiceProsody
    public var duration: Double          // seconds of speech
}

public struct HeardSound: Sendable, Equatable {
    public var label: String             // human words: "doorbell", "dog barking"
    public var identifier: String        // classifier identifier
    public var confidence: Double
    public var loudnessDB: Double
    public var isUnexpected: Bool        // novel, salient, not speech/silence/ambient
}

public struct VoiceStyle: Sendable, Equatable {
    public var pitch: Float              // AVSpeechUtterance.pitchMultiplier 0.5…2
    public var rate: Float               // AVSpeechUtterance.rate
    public var volume: Float
    public static func forMood(emotion: Emotion, age: Double?, energy: Double) -> VoiceStyle
}

public enum VoiceEvent: Sendable, Equatable {
    case permission(microphone: Bool, speech: Bool)
    case ready
    case listening(Bool)
    case partial(String)
    case heard(HeardUtterance)
    case sound(HeardSound)
    case micLevel(Double)                // 0…1, ~20 Hz while listening
    case speakingStarted
    case speechLevel(Double)             // 0…1, ~30 Hz while speaking (eye bounce)
    case speakingFinished
    case bargeIn                         // user started talking over Dee
    case error(String)
}

public final class VoiceService: @unchecked Sendable {
    public init()
    public var events: AsyncStream<VoiceEvent> { get }
    /// Requests microphone + speech permission, configures the audio session,
    /// installs on-device speech assets if needed, starts the engine.
    public func start() async
    /// App gate: false while Dee sleeps / nobody is there. Sound classification
    /// keeps running regardless (cheaply) so Dee can wake to an unexpected noise.
    public var listeningEnabled: Bool { get set }
    public func say(_ text: String, style: VoiceStyle)
    /// Incremental text from the LLM; spoken sentence by sentence as it arrives.
    public func stream(_ fragment: String, style: VoiceStyle)
    public func endStream()
    public func stopSpeaking()
    public func shutdown()
}
```
Behaviour: half-duplex by default — recognition pauses while Dee speaks and resumes
~0.4 s after; `.bargeIn` when the user clearly talks over her (voice-processing echo
cancellation on). Strip `[tags]`, markdown and emoji before speaking. End of
utterance ≈ final result + ~0.8 s without new text, gated by an energy VAD.

## DeeSense additions (owner: sense) — `Sources/DeeSense`, `Tests/DeeSenseTests`

```swift
public struct TouchSample: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case began, moved, ended, cancelled }
    public var id: Int
    public var time: Double                // seconds, monotonic
    public var location: SIMD2<Double>     // 0…1 in the face view, y down
    public var majorRadius: Double         // points (UITouch.majorRadius)
    public var phase: Phase
    public init(id: Int, time: Double, location: SIMD2<Double>, majorRadius: Double, phase: Phase)
}

public enum TouchGesture: Sendable, Equatable {
    case tap(at: SIMD2<Double>)
    case doubleTap(at: SIMD2<Double>)
    case pet(duration: Double, gentleness: Double)  // slow strokes; gentleness 0…1
    case hold(duration: Double)                     // still, steady contact ("a hug")
    case pokes(count: Int, rate: Double)            // rapid repeated taps
    case slap(force: Double)                        // fast, hard, short contact; 0…1
    case tickle(duration: Double)                   // quick small jiggles
}

public struct TouchInterpreter: Sendable {
    public init()
    public mutating func add(_ sample: TouchSample) -> [TouchGesture]
    public mutating func tick(at t: Double) -> [TouchGesture]
}

public enum CameraSide: String, Sendable, Equatable { case front, back }
public struct SeenThing: Sendable, Equatable { public var label: String; public var confidence: Double }
public struct SightReport: Sendable, Equatable {
    public var camera: CameraSide
    public var things: [SeenThing]          // top labels this glance
    public var novel: [SeenThing]           // not seen recently
}
// SenseUpdate gains:  case sight(SightReport)
// CameraSense gains:  public var lookAround: Bool   // scan the back camera too (multi-cam when supported)
```

## DeeMind additions (owner: mind) — `Sources/DeeMind`, `Tests/DeeMindTests`

```swift
public enum Touch: Sendable, Equatable {
    case tap, doubleTap
    case pet(gentleness: Double, seconds: Double)
    case hold(seconds: Double)
    case pokes(count: Int)
    case slap(force: Double)
    case tickle(seconds: Double)
}
extension Appraisal {
    public static func touch(_ t: Touch) -> Appraisal
    public static func sound(label: String, unexpected: Bool, loudness: Double) -> Appraisal
    public static func sight(novelty: Double) -> Appraisal
}

public struct MoodSignals: Sendable, Equatable {
    public var curiosity, boredom, playfulness, affection, energy, loneliness, arousal, valence: Double
}
// MindSnapshot gains:
//   public var reflex: Emotion?     // momentary reaction to the last stimulus
//                                    // (joke → giddy even when upset; kind word → shy smile)
//   public var urgeToTalk: Double   // 0…1
//   public var mood: MoodSignals

public struct CuriosityDirector: Sendable {
    public enum Stimulus: Sendable, Equatable {
        case saw([String], camera: String)
        case heard(sound: String, unexpected: Bool)
        case userArrived
        case userSpoke
        case deeSpoke
        case touched(String)
    }
    public init()
    public mutating func note(_ stimulus: Stimulus, at: Date)
    /// A short stage direction for the LLM, e.g. "(You just noticed a guitar behind
    /// your human. Ask about it, briefly and playfully.)", or nil to stay quiet.
    public mutating func nextPrompt(at: Date, snapshot: MindSnapshot, userPresent: Bool, busy: Bool) -> String?
}
```

## DeeFace additions (owner: face) — `Sources/DeeFace`, `Tests/DeeFaceTests`

```swift
public enum Performance: String, CaseIterable, Sendable, Equatable {
    case wink, blinkLeft, blinkRight, yawn, eyeRoll, doubleTake, nod, headShake, giggle,
         squint, lookAround, startle, sigh, bounce, shiver, contentSquint, dizzySpin
}
public struct PerformanceRequest: Sendable, Equatable {
    public var id: Int                  // a new id triggers the performance once
    public var performance: Performance
    public init(id: Int, performance: Performance)
}
public struct FaceMood: Sendable, Equatable {
    public var curiosity, boredom, playfulness, energy, affection, arousal: Double
    public init(curiosity: Double = 0.5, boredom: Double = 0, playfulness: Double = 0.5, energy: Double = 0.8, affection: Double = 0.4, arousal: Double = 0.3)
}
// FaceInputs gains:
//   public var mood: FaceMood = FaceMood()
//   public var touchPoint: SIMD2<Double>?        // eyes glance at the finger (0…1, y down)
//   public var performance: PerformanceRequest?
```
The animator runs an **idle director**: spontaneous performances driven by `mood`
(curious → lookAround/squint/tilt; bored → yawn/eyeRoll/sigh; playful → wink/bounce;
tired → yawn; affectionate → contentSquint). Every one of the 37 `Emotion`s gets its
own distinct target; glyph eyes (`> <`, spirals, `X`, `–`, `U`, sparkle highlights,
tears) join hearts and stars; every expression gets small per-occurrence variation.
