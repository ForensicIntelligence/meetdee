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
    case pokes(count: Int, rate: Double, total: Int) // rapid; count = new pokes in this event, total = pokes so far in the burst
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

## DeeMemory (owner: memory) — `Sources/DeeMemory`, `Tests/DeeMemoryTests`

User rule: *"If I introduce myself with my name, to the camera and microphone, I'd
like Dee to remember that. Dee should remember as much as possible of the users."*
Still no transcripts: only people and distilled facts.

```swift
public struct FacePrint: Sendable, Equatable, Codable {          // L2-normalised Vision rev-2 print
    public var vector: [Float]
    public init(vector: [Float])
    public func distance(to other: FacePrint) -> Float
}

public struct Fact: Sendable, Equatable, Codable, Identifiable {
    public enum Category: String, Sendable, Codable, CaseIterable {
        case identity, preference, dislike, relationship, pet, work, place, health, event, birthday, other
    }
    public var id: UUID
    public var text: String              // third person, e.g. "likes jazz", "has a dog named Miso"
    public var category: Category
    public var confidence: Double
    public var createdAt: Date
    public var updatedAt: Date
    public var sensitive: Bool           // health (except allergy/diet/glasses), religion, sexuality,
                                         // politics…: recall only, NEVER in promptMemories
}

public struct Person: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var aliases: [String]         // at most MemoryStore.maxAliases (6)
    public var firstMet: Date
    public var lastSeen: Date
    public var encounters: Int
    public var facts: [Fact]
    public var session: UUID?            // placeholders only
    public var isPlaceholder: Bool { get }
    public func answers(to name: String) -> Bool   // name or alias, case-insensitive
}

public struct ExtractedFact: Sendable, Equatable {
    public var text: String
    public var category: Fact.Category
    public var name: String?             // self-introductions ("I'm John", "call me Johnny")
    public var retracts: Bool            // "my dog died", "I used to like jazz", "I quit my job"
}

public struct LearnOutcome: Sendable, Equatable {
    public var stored: [Fact]            // facts written (new or merged)
    public var pendingName: String?      // heard, NOT applied — confirm, then confirmName
    public var mergeCandidate: UUID?     // an existing real person already called pendingName
    public var retracted: [String]       // texts of facts deleted by a retraction
}

public struct ForgetOutcome: Sendable, Equatable {
    public var forgotten: [Fact]         // deleted
    public var candidates: [Fact]        // several partial matches: nothing deleted, ask which
}

public enum FactExtractor {
    public static func extract(from utterance: String) -> [ExtractedFact]
    public static func extract(from utterance: String, now: Date, calendar: Calendar = .current) -> [ExtractedFact]
    /// "I hate myself", "I want to die": nothing is stored; respond with care.
    public static func selfHarmSignal(in utterance: String) -> Bool
}
public enum FactSensitivity { public static func isSensitive(_ text: String, category: Fact.Category) -> Bool }
public enum FactPolicy { public static func isDenied(_ text: String) -> Bool }   // hate / violence / drugs / self-referential

public struct FaceCaptureQuality: Sendable, Equatable {        // score, widthFraction, yaw, roll, clipped
    public func passes(_ gate: FaceQualityGate = FaceQualityGate()) -> Bool
}
public struct FaceQualityGate: Sendable, Equatable {           // minScore 0.4, minWidthFraction 0.15,
}                                                              // |yaw|,|roll| ≤ 20°, clipped rejected
public enum FaceEmbedder {
    /// Vision feature print of a square face crop; past the frame edge the crop is
    /// PADDED (grey), never clipped and stretched. Throws when unavailable.
    public static func print(of image: CGImage, faceBox: CGRect) async throws -> FacePrint
    public static func print(of image: CGImage, faceBox: CGRect, orientation: CGImagePropertyOrientation) async throws -> FacePrint
    /// Vision face-capture quality + pose + size + clipping for one face box.
    public static func quality(of image: CGImage, faceBox: CGRect, orientation: CGImagePropertyOrientation = .up) async -> FaceCaptureQuality
    /// Print only if the capture passes the gate (throws .poorQuality otherwise). Use for enrolment.
    public static func enrolmentPrint(of image: CGImage, faceBox: CGRect, orientation: CGImagePropertyOrientation = .up,
                                      gate: FaceQualityGate = FaceQualityGate()) async throws -> FacePrint
}

public struct FaceMatching: Sendable, Equatable {
    // threshold 0.62, learnThreshold 0.45 (distance to an ANCHOR), ambiguityMargin 0.08 (until
    // calibrated on device), minNovelty 0.12, maxPrintsPerPerson 12, maxAnchorsPerPerson 6,
    // matchNeighbours 2 (score = mean of the 2 closest prints), learnAfterFrames 3,
    // minEnrollPrints 3, sameNameMergeDistance 0.9
}

public actor MemoryStore {
    public static let unknownFriendName: String          // "unknown friend"
    public static let nameConfirmWindow: TimeInterval     // 10 min
    public static let maxAliases: Int                     // 6
    public static let askNameLine: String                 // "You don't know their name yet — ask."

    /// The folder is excluded from backups and (iOS) given file protection BEFORE
    /// the database opens; -wal/-shm too. Placeholders from earlier runs are purged.
    public init(databaseURL: URL?) throws
    public init(databaseURL: URL?, faceMatching: FaceMatching, calendar: Calendar = .current) throws
    public static func defaultURL() -> URL               // Application Support/Dee/DeeMemory.sqlite

    // People
    public func people() -> [Person]
    public func person(_ id: UUID) -> Person?
    public func person(named name: String) -> Person?     // real people only (never placeholders)
    @discardableResult public func addPerson(named: String, at: Date) -> Person?   // voice-only, no face
    /// nil unless ≥ minEnrollPrints (3) DISTINCT prints (each from FaceEmbedder.enrolmentPrint).
    /// Reuses a same-named person only if the face matches or `reuse` is true.
    @discardableResult public func enroll(name: String, facePrints: [FacePrint], at: Date, reuse: Bool = false) -> Person?
    @discardableResult public func placeholderPerson(session: UUID, at: Date = Date()) -> Person
    public func discardPlaceholder(_ id: UUID)
    public func pendingName(for id: UUID, now: Date = Date()) -> (name: String, timesHeard: Int)?
    /// Placeholder → merged into an existing same-named person when faces don't
    /// contradict (or both faceless) and THAT person is returned; else renamed
    /// (its prints become anchors). Real person → name added as alias.
    @discardableResult public func confirmName(_ name: String, for id: UUID, at: Date = Date()) -> Person
    public func rename(_ id: UUID, to name: String)
    public func addAlias(_ alias: String, to id: UUID)
    public func noteEncounter(_ id: UUID, at: Date)
    public func merge(_ from: UUID, into: UUID)
    public func forgetPerson(_ id: UUID)                  // + WAL checkpoint(TRUNCATE)
    public func forgetEverything()                        // delete, checkpoint, VACUUM, checkpoint

    // Faces
    public func addFacePrints(_ prints: [FacePrint], to id: UUID, anchor: Bool = false)
    public func identify(_ print: FacePrint) -> (person: Person, distance: Float)?
    public func identify(_ print: FacePrint, learn: Bool) -> (person: Person, distance: Float)?
    /// All faces of ONE frame; each person assigned at most once. Learns only with
    /// exactly one face, after learnAfterFrames agreeing frames, within
    /// learnThreshold of an anchor. Anchors are never trimmed.
    public func identifyAll(_ prints: [FacePrint], learn: Bool = true) -> [(person: Person, distance: Float)?]
    public func facePrintCount(of id: UUID) -> Int
    public func anchorCount(of id: UUID) -> Int

    // Facts
    @discardableResult public func remember(_ text: String, category: Fact.Category, about id: UUID, at: Date) -> Fact?  // nil = denied/unknown
    @discardableResult public func learn(from utterance: String, about id: UUID, at: Date) -> LearnOutcome
    public func forget(factMatching text: String, about id: UUID) -> Bool
    @discardableResult public func forgetFacts(matching text: String, about id: UUID) -> ForgetOutcome  // whole words
    public func search(_ query: String, about id: UUID, limit: Int = 8) -> [Fact]   // includes sensitive
    /// Non-sensitive facts only; placeholder → [askNameLine]. Pass limit ≤ 12 (~300 tokens).
    public func promptMemories(for id: UUID, limit: Int) -> [String]
}

/// Agent tools (DeeCore.AgentTool) bound to the current person:
public struct RememberTool: AgentTool   // remember_fact(fact, category?) — first person goes through learn()
public struct RecallTool: AgentTool     // recall(query) → header (≤ 2 aliases) + matching facts
public struct ForgetTool: AgentTool     // forget_fact(fact) — lists candidates when ambiguous
// Each takes `store: MemoryStore` and `currentPerson: @Sendable () async -> UUID?` in its init.
// currentPerson must return the identified person OR this session's placeholder;
// with nil the tools save nothing (they never create placeholders).
```

App wiring rules:

1. One `placeholderPerson(session:)` per conversation session (or per unrecognised
   face); `discardPlaceholder` when the session ends without a confirmed name.
2. Every utterance: `learn(from:about:at:)`. If `pendingName` is set, confirm it
   (ask "Did you say your name is X?", or `pendingName(for:)?.timesHeard >= 2`, or
   exactly one face visible) and then call `confirmName`. If the speaker is a known
   person and `stored` is empty with a `pendingName`, the face may be wrong: switch
   person (or enrol) and call `learn` again for the right one.
3. Camera: `identifyAll(allFacesInFrame)` every frame; enrol with ≥ 3
   `FaceEmbedder.enrolmentPrint`s from different frames.
4. `FactExtractor.selfHarmSignal(in:)` true → nothing is stored; respond with care.
