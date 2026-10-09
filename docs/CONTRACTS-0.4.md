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
    public var pendingName: String?      // heard, NOT applied — confirm, then confirm(_:for:)
    public var mergeCandidate: UUID?     // an existing real person already called pendingName
    public var retracted: [String]       // texts of facts deleted (or narrowed) by a retraction
    public var retractionCandidates: [Fact] // ambiguous retraction ("my dog died", 2 dogs): nothing deleted, ask
    public var differentSpeaker: Bool    // known person claimed another name: nothing stored, switch person
    public var suggestedAlias: String?   // "I'm Thomas, call me Tom" / "I'm John Smith" from John:
                                         // addAlias once confirmed (facts ARE stored)
    public var introduced: [String]      // "this is Sarah", "meet my friend Sarah" — never the speaker
    public var wellbeingConcern: Bool    // self-harm signal: nothing stored
}

public enum ConfirmResult: Sendable, Equatable {
    case named(Person, needsEnrolment: Bool)   // placeholder renamed / name already theirs; needsEnrolment
                                               // = < 3 anchors (add ≥ 3 quality prints with anchor: true)
    case merged(into: Person)                  // same face as the existing person of that name
    case mergeCandidate(placeholder: Person, existing: Person)  // can't tell (no face on a side, or
                                               // in-between faces): NOTHING changed — ask, then
                                               // confirm(…, choice: .sameAs(existing.id) / .newPerson)
    case differentSpeaker(current: Person, heard: String, candidate: Person?)  // known person, name not
                                               // theirs: NOTHING changed, never an alias — switch person
    case rejected                              // unknown id / unusable name
    public var person: Person? { get }
}
public enum SameNameChoice: Sendable, Equatable { case ask, sameAs(UUID), newPerson }

public struct ForgetOutcome: Sendable, Equatable {
    public var forgotten: [Fact]         // deleted
    public var candidates: [Fact]        // several partial matches: nothing deleted, ask which
}

public enum FactExtractor {
    public static func extract(from utterance: String) -> [ExtractedFact]
    public static func extract(from utterance: String, now: Date, calendar: Calendar = .current) -> [ExtractedFact]
    /// "I hate myself", "I want to die", "nobody would miss me", "I hate my life":
    /// nothing is stored; respond with care. Idioms ("kill myself laughing") are not.
    public static func selfHarmSignal(in utterance: String) -> Bool
    /// People introduced by the speaker ("Hey, this is Sarah", "meet my friend Sarah").
    public static func introductions(in utterance: String) -> [String]
}
/// Sensitive in EVERY category (work included): religion and practice ("goes to mass"), sexuality,
/// sex work / strip clubs, drugs and drug use ("does coke"), gambling, addiction/AA, personal legal
/// matters, body weight, reproductive health, mental health, medication ("takes Prozac"), politics
/// and voting, immigration status, debt / pay ("earns 40k"), divorce, homelessness.
/// Illnesses and institutions (cancer, therapist, court, Visa…) are sensitive EXCEPT in a job fact
/// of category .work ("works at Visa", "works in cancer research", "is a lawyer").
/// Health (except allergy/diet/glasses) is always sensitive. Not over-hidden: "Christian rock",
/// "a son named Christian", "AA batteries", "Trans-Am", "Sex Pistols".
public enum FactSensitivity { public static func isSensitive(_ text: String, category: Fact.Category) -> Bool }
/// Hate / violence / drugs / self-referential, the most common English slurs, extremist figures and
/// groups, and hostility to a whole nationality / ethnic / religious group ("hates the Chinese",
/// "hates Africans"; "hates Chinese food" is fine), and to women / men / fat, old, disabled,
/// poor or homeless people.
public enum FactPolicy {
    public static func isDenied(_ text: String) -> Bool
    public static func isSelfHarm(_ text: String) -> Bool
}

public struct FaceCaptureQuality: Sendable, Equatable {        // score, widthFraction, yaw, roll, clipped
    public func passes(_ gate: FaceQualityGate = FaceQualityGate()) -> Bool
}
public struct FaceQualityGate: Sendable, Equatable {           // minScore 0.4, minWidthFraction 0.15,
}                                                              // |yaw|,|roll| ≤ 20°, clipped rejected,
                                                               // requireScore = true (no Vision score → reject)
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
    // matchNeighbours 2 (score = mean of the 2 closest prints), learnAfterFrames 3 (each within
    // learnStreakGap 2 s of the previous), minEnrollPrints 3, differentFaceDistance 0.9 (confirm: a
    // same-named person is a DIFFERENT face only when every print is ≥ this from their anchors).
    // Ambiguity is judged against the runner-up's raw score, even if it fails its anchor check.
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
    public func person(_ id: UUID) -> Person?            // a merged-away id resolves to its person
    public func person(named name: String) -> Person?     // real people only (never placeholders)
    @discardableResult public func addPerson(named: String, at: Date) -> Person?   // voice-only, no face
    /// nil unless ≥ minEnrollPrints (3) DISTINCT prints (each from FaceEmbedder.enrolmentPrint).
    /// Reuses a same-named person only if the face matches or `reuse` is true.
    /// `qualities` (one per print): prints failing `gate` are dropped before the count.
    @discardableResult public func enroll(name: String, facePrints: [FacePrint], at: Date, reuse: Bool = false,
                                          qualities: [FaceCaptureQuality]? = nil, gate: FaceQualityGate = FaceQualityGate()) -> Person?
    /// After the session's placeholder was confirmed (renamed or merged), returns THAT real person.
    @discardableResult public func placeholderPerson(session: UUID, at: Date = Date()) -> Person
    public func discardPlaceholder(_ id: UUID)
    public func pendingName(for id: UUID, now: Date = Date()) -> (name: String, timesHeard: Int)?
    /// Real person: own name/alias, or a fuller/shorter form of it ("John Smith" for John) →
    /// .named (no alias added; addAlias it if wanted); any other name → .differentSpeaker,
    /// NOTHING changes.
    /// Placeholder + same-named real person: merged only when the placeholder's face AS A WHOLE
    /// matches — a strict majority of its prints AND their centroid within `threshold` (score
    /// and nearest anchor); one stray matching print is never enough. Separate when every print
    /// is ≥ differentFaceDistance;
    /// otherwise (incl. either side faceless) .mergeCandidate, nothing changes.
    /// Placeholder otherwise: renamed; ≥ 3 distinct QUALITY prints become anchors, fewer stay
    /// a pending (non-matching) enrolment (needsEnrolment), non-quality prints are deleted.
    public func confirm(_ name: String, for id: UUID, at: Date = Date(), choice: SameNameChoice = .ask) -> ConfirmResult
    /// Compatible wrapper: .mergeCandidate → a separate new person (never a guessed merge);
    /// .differentSpeaker → the known person unchanged (no alias).
    @discardableResult public func confirmName(_ name: String, for id: UUID, at: Date = Date()) -> Person
    public func rename(_ id: UUID, to name: String)
    public func addAlias(_ alias: String, to id: UUID)    // the ONLY way to add an alias
    public func noteEncounter(_ id: UUID, at: Date)
    public func merge(_ from: UUID, into: UUID)           // `from` (and its session) then resolve to `into`
    public func resolve(_ id: UUID) -> UUID               // follows merges; EVERY id-taking call uses it
                                                          // (person, addFacePrints, rename, addAlias, tools…)
    public func forgetPerson(_ id: UUID)                  // a merged-away id forgets the person it became
    public func forgetEverything()                        // delete, checkpoint, VACUUM, checkpoint
    // WAL: every call that deletes or overwrites user text or face prints (forget, retraction,
    // slot / opposite-feeling replacement, alias cap, rename, merge, print pruning, confirm)
    // ends with ONE checkpoint(TRUNCATE).
    // Schema v3: on open, every stored fact is re-checked with the CURRENT rules — rows that
    // FactPolicy.isDenied / isSelfHarm reject are deleted (secure_delete + WAL truncate) and
    // `sensitive` is recomputed. `schemaVersion` is bumped whenever those rules change.

    // Faces
    /// anchor: true = caller vouches the prints passed FaceQualityGate. A real person gets anchors
    /// only once ≥ minEnrollPrints distinct quality prints exist (fewer wait, non-matching).
    /// On a placeholder they stay un-anchored until confirm. `passedQualityGate` overrides
    /// the quality flag (default = anchor). A real person without anchors is never matched.
    public func addFacePrints(_ prints: [FacePrint], to id: UUID, anchor: Bool = false, passedQualityGate: Bool? = nil)
    public func identify(_ print: FacePrint) -> (person: Person, distance: Float)?
    public func identify(_ print: FacePrint, learn: Bool) -> (person: Person, distance: Float)?
    /// All faces of ONE frame; each person assigned at most once. Learns only with
    /// exactly one face, after learnAfterFrames agreeing frames (each ≤ learnStreakGap
    /// apart), with nearest anchor AND mean of the 2 closest anchors within
    /// learnThreshold. Anchors are never trimmed.
    public func identifyAll(_ prints: [FacePrint], learn: Bool = true) -> [(person: Person, distance: Float)?]
    public func identifyAll(_ prints: [FacePrint], learn: Bool, at: Date) -> [(person: Person, distance: Float)?]
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
2. Every utterance: `learn(from:about:at:)`. If `pendingName` is set on a
   placeholder, confirm it (ask "Did you say your name is X?", or
   `pendingName(for:)?.timesHeard >= 2`, or exactly one face visible) and call
   `confirm`; on `.mergeCandidate` ask "Are you the X I met before?" and call
   `confirm` again with `.sameAs`/`.newPerson`. If `differentSpeaker` is set, the face
   may be wrong: switch person (or a new placeholder) and call `learn` again — never
   alias it. `suggestedAlias` → `addAlias` after asking. `introduced` names are
   other people (start a placeholder for a new face, not a rename).
   `retractionCandidates` → ask which one, then `forgetFacts` with its exact text.
3. Camera: `identifyAll(allFacesInFrame)` every frame; enrol with ≥ 3
   `FaceEmbedder.enrolmentPrint`s from different frames.
4. `FactExtractor.selfHarmSignal(in:)` / `LearnOutcome.wellbeingConcern` true →
   nothing is stored; respond with care.
