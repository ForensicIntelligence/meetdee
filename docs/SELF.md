# Dee v0.5 "Someone": the self-model architecture

Status: **design, final**. This document combines three proposals (cognitive, social,
narrative) and three judges' critiques. It is binding for v0.5 unless John changes
it. Requirements: `docs/research/self-model-brief.md`. Existing engine:
`docs/MIND.md`. Module contracts in flight: `docs/CONTRACTS-0.4.md`.

**Where each part came from:**
- The **backbone** is cognitive's: one `Moment`, one `Stance`, and pure projections
  to every channel.
- The **listening layer** is social's: turn prediction, a listening face, visual
  backchannels, deixis that asks when unsure, the repair state machine, and
  boundaries.
- The **enduring self** is narrative's: fixed values, a seeded humour style, innate
  plus learned tastes with hysteresis, anticipation, episodes built without text,
  gradual reveal, and "the LLM proposes, the code decides".

Every flaw the judges raised is fixed in place. §15 lists each fix.

---

## 0. Decisions at a glance

| # | Decision |
|---|---|
| D1 | **One shared state.** A new target **`DeeSelf`** owns `Moment` (three timescales) and `Cortex`, a pure reducer built from small sub-reducers, each with its own tests. `Stance.resolve(Moment)` gives **the** interpretation of now. Every expressive output (expression, voice style, gaze, performance, the LLM cue) is a pure function of `Stance`. |
| D2 | **One writer of `<dee_state>`.** `CueWriter` owns it: the existing mood sentence (byte-identical port of `Mind.cue`) plus **at most two parenthesised notes**. Hard cap **120 tokens per turn**, typically 45–70. No `key: value` lines and no delta encoding. |
| D3 | **The system prompt is frozen per conversation.** A self block of ≤70 tokens plus ≤45 tokens of fixed rule lines are added once at `newConversation`. A test checks the system prompt is byte-identical on every turn. |
| D4 | **No LLM is needed for state.** Every update is deterministic. Reflection is deterministic (`Reflector`). The planned optional LLM polish pass was dropped in 0.6 (§8.2); nothing about state ever reads **the transcript**. |
| D5 | **Time away carries no relationship penalty.** The neglect→affection rule is deleted. While the user is away, affection and trust may only relax *upward* toward baseline, never downward. Loneliness shows only as reunion joy. Nothing that expires while the user is away is ever mentioned. |
| D6 | **Memory changes behaviour through parameters first, words second.** A lesson changes a deterministic parameter (inference gain, pause scale, note choice) and only then, optionally, a short note. "Memory changes behaviour" is therefore testable without the LLM. |
| D7 | **One SQLite file.** The `DeeSelf` tables live in the DeeMemory database (`MemoryStore.defaultURL()`), with `ON DELETE CASCADE` to `people(id)`. No transcripts, no utterances. Stored strings are labels, ≤4-word subjects, names, or template output. |
| D8 | **Version.** v0.5 becomes "Someone", and agentic tools move to 0.6 (later phases shift by one). `PHASES.md` needs that edit when John approves. The memory tools in DeeMemory are unaffected. |
| D9 | **Audio features that depend on echo cancellation (AEC) come last and are optional.** Vocal "mm-hm", graded barge-in (duck/resume) and own-voice masking ship only after AEC is proven on device across routes. Until then the half-duplex behaviour stays. |

---

## 1. Overview: one Moment, three timescales

```
            percepts (voice, sight, touch, sound, presence, LLM output, tick)
                                   │   stamped with Date by DeeModel
                                   ▼
   Mind (actor) ── react/tick/hear ──► MindSnapshot (seq) ──┐
                                                            ▼
                        Cortex.step(percept, mind:, at:)  — pure, sync, seeded
             ┌──────────────┬──────────────┬───────────────┬──────────────┐
             │ Floor        │ Attention    │ Interpreter   │ Intentions   │  … sub-reducers
             │ (turns)      │ (focus,      │ (user read,   │ (board,      │
             │              │  referents)  │  plans, repair│  follow-up)  │
             └──────┬───────┴──────┬───────┴───────┬───────┴──────┬───────┘
                    ▼              ▼               ▼              ▼
                           Moment { momentary, ongoing, enduring }
                                         │
                                 Stance.resolve(Moment)        ← THE interpretation
                 ┌──────────┬──────────┼──────────┬──────────┬──────────┐
                 ▼          ▼          ▼          ▼          ▼          ▼
             expression   voice      gaze     performance   cue      [Effect]s
             (face)       style     target    (beat/idle)  <dee_state>  memory writes,
                                                                        sensor requests
```

| Timescale | Lifetime | Contents | Stored? |
|---|---|---|---|
| **Momentary** | seconds | floor/turn phase, focus, referents, reflex, LLM tag, uncertainty, current beat, listening preview | RAM only |
| **Ongoing** | minutes to days | `MindSnapshot` (mood, 26 bytes), user hypotheses, topic, open intentions, expectations, interests, repair phase, awkwardness | intentions, expectations and interests persisted; conversation-scoped parts RAM only (one exception: an open rupture survives a relaunch for 6 h) |
| **Enduring** | weeks and longer | temperament (traits in MindCode), fixed values, humour style, signature repertoire, tastes, lessons, per-person social profile, episodes, gags, rituals, boundaries | persisted |

Example walk-through: the brief's "shown something you made".
1. `.sight(back: ["painting"], novel)` and `.heard("look what I made")` arrive. `Attention` moves focus to `painting` (back camera). `Interpreter` sets `user.goal = .shareCreation`.
2. The `Beats` sub-reducer starts the **examine** beat: gaze drops and narrows toward the back camera, and her `thinking` mannerism plays.
3. Recall finds the episode "John is learning watercolor", so the **recognise** step plays (`doubleTake`), then **brighten** (expression `excited`, intensity +0.2).
4. `CueWriter` emits the mood sentence plus `(You remember: they're learning watercolor.)` and `(Ask about one choice they made in it.)`.
5. The beat runs while the model prepares its reply, so that wait reads as examining.
6. At turn end, `EpisodeBuilder` records "John showed me a painting" with `why: "they seemed proud"`, and an `Intention(.followUp, "painting")` if John said he would finish it.

---

## 2. Module placement

New SwiftPM target **`DeeSelf`**: `Packages/DeeKit/Sources/DeeSelf`, with tests in `Tests/DeeSelfTests`.

- **Depends on:** `DeeCore` (`Emotion`, `Persona`), `DeeMind` (`MindSnapshot`, `MindCode`, `Appraisal`, `Appraiser`, `Rand`/SplitMix64), and `DeeMemory` (`Person` ids, `Fact`, `FactExtractor`, and the database file URL). It links `sqlite3`.
- **Does not depend on** `DeeFace`, `DeeVoice` or `DeeSense`. Its projections emit neutral intents (`ExpressionIntent`, `VoiceIntent`, `GazeIntent`, `Mannerism`). `App/Sources/Projector.swift` maps them to `FaceInputs`, `VoiceStyle.forMood` and `PerformanceRequest`. That file is mechanical: no conditionals beyond 1:1 mapping, about 60 lines. `Mannerism` mirrors `Performance` raw values, and a `DeeSelfTests` test pins the raw-value list.
- **Why a new module rather than DeeMind:** DeeMind is a stable, well-tested emotion engine with its own store. `DeeSelf` needs people (DeeMemory) and must not drag those into Mind. Mind stays the source of feeling, and `DeeSelf` interprets.

**Changes to existing modules.** All are additive except the neglect deletion.

| Module | Change |
|---|---|
| DeeMind | Delete the neglect rule. Affection and trust relax only upward while away (§11). `CuriosityDirector` gains `avoid: Set<String>` and `candidates(at:snapshot:userPresent:busy:) -> [Candidate]`. `nextPrompt` stays as a wrapper for compatibility. Reunion greeting variants lose "lonely without them" wording. `Appraisal.internal(relief:pride:)` is a tiny new appraisal for resolved expectations and completed intentions. |
| DeeCore | `Persona` gains `selfLines: [String]` and `ruleLines: [String]`, appended after the personality line. A dev-only cue-leak check (`CueLeak` / `CueLeakWatch` since 0.6) fires when a reply contains `<dee_state>` or a parenthesised note verbatim. |
| DeeVoice | `TurnPredictor` (inside `ListeningCore`). `EndpointDetector.setQuietInterval(_:)`, clamped to 0.35…2.5. `ListeningCore.pauseScale` (set per person). `VoiceEvent.pause(turnEnd: Double, hesitation: Double)` (additive). `SentenceChunker` drops text inside `( … )` and `<…>` before speaking. S7 only: `VoiceService.backchannel(_:)` and graded barge-in. |
| DeeSense | `SenseUpdate.head(yaw: Double, pitch: Double)` (additive, from the face observation already computed). `CameraSense.glanceNow(_ side: CameraSide)`, a one-shot that bypasses the sight pacer. |
| DeeFace | `FaceInputs.listenValence` and `listenIntensity` (0…1, default 0). The animator blends them into the `.listening` target. |
| DeeMemory | `forgetEverything()` posts no new API. `SelfStore.forgetAll()` is called alongside it (§10.3). |
| App | `DeeModel` keeps only I/O. It funnels everything through `cortex.step`, executes `[Effect]`, and sets the face, voice style, gaze and performance **only** from `Projector`. `spokenEmotion`, `spokenEmotionUntil`, `refreshEmotion()`, `flash(_:)` and direct `lookAt` writes are deleted. |

Each additive contract change needs a CONTRACTS-0.5 addendum before coding.

---

## 3. Swift types

All types are `Sendable`, `Equatable` value types unless noted. Every function that depends on time takes `at now: Date` explicitly. There is **one clock**: `Date`. Durations are `now.timeIntervalSince(x)`. `DeeModel` stamps each percept with `Date()` on receipt, and tests use a `SimClock`. Randomness is `Rand` (SplitMix64) seeded from `self_meta.seed` and threaded through `Cortex`.

### 3.1 Shared small types

```swift
public struct Timed<Value: Sendable & Equatable>: Sendable, Equatable {
    public var value: Value
    public var until: Date
    public func live(at now: Date) -> Value? { now < until ? value : nil }
}

public enum CameraSide: String, Sendable, Equatable, Codable { case front, back }   // mirrors DeeSense
public typealias PersonID = UUID

/// Lexicon-safe subject: ≤ 4 words, lower-cased, from labels / NLTagger noun lemmas / plan subjects.
public struct Subject: Sendable, Equatable, Hashable, Codable {
    public let text: String
    public init?(_ raw: String)          // nil if > 4 words, empty, or on the stoplist
}
```

### 3.2 Momentary (RAM only)

```swift
public enum Floor: Sendable, Equatable {
    case idle
    case userSpeaking(since: Date)
    case userPaused(since: Date, turnEnd: Double, hesitation: Double)
    case deeThinking(since: Date)        // prompt submitted, no audio yet
    case deeSpeaking(since: Date)
    case yielding(since: Date)           // user barged in; Dee stopped
}

public enum Focus: Sendable, Equatable {
    case person(PersonID?)               // nil = unidentified face
    case referent(Subject, CameraSide)
    case sound(Subject)
    case touch(SIMD2<Double>)
    case inward                          // recalling / thinking
    case none
}

public struct Referent: Sendable, Equatable {
    public enum Source: String, Sendable { case sawFront, sawBack, mentioned, heldUp, deeMentioned }
    public var subject: Subject
    public var camera: CameraSide?
    public var sources: Set<Source>
    public var salience: Double          // 0…1, half-life 20 s
    public var lastSeen: Date
    public var sharedWithUser: Bool      // common ground: user mentioned / held it up / replied after Dee named it
}

public struct ListenPreview: Sendable, Equatable {
    public var valence: Double           // −1…1, from a copy of Appraiser over the partial
    public var intensity: Double         // ≤ 0.5
    public var signSince: Date           // sign flips need 0.6 s hold
}

public struct BeatStep: Sendable, Equatable {
    public enum Gaze: Sendable, Equatable { case user, referent, down, away, keep }
    public var gaze: Gaze
    public var overlay: Emotion?         // expression override for this step
    public var intensityBoost: Double
    public var mannerism: Mannerism?
    public var duration: TimeInterval
}
public struct Beat: Sendable, Equatable {
    public enum Kind: String, Sendable { case examine, recognize, brighten, listenHesitant, sorryGoOn, reunion }
    public var kind: Kind
    public var steps: [BeatStep]
    public var started: Date
}

public struct Momentary: Sendable, Equatable {
    public var floor: Floor = .idle
    public var focus: Focus = .none
    public var focusSince: Date = .distantPast
    public var referents: [Referent] = []              // cap 12, LRU
    public var reflex: Timed<Emotion>?                 // from MindSnapshot.reflex, 4 s
    public var llmTag: Timed<Emotion>?                 // reconciled tag, until speech end + 1.5 s
    public var preview: ListenPreview?
    public var uncertainty: Double = 0                 // 0…1: how unsure the current interpretation is
    public var beat: Beat?
    public var headYaw: Double?                        // degrees, front camera
    public var headPitch: Double?
    public var mutualGazeSince: Date?
    public var lastBackchannel: Date = .distantPast
    public var pendingGlance: Timed<CameraSide>?       // waiting for glanceNow result (≤ 1.2 s)
}
```

### 3.3 Ongoing

```swift
public struct Hypothesis: Sendable, Equatable {        // tentative model of the user
    public enum Kind: String, Sendable, Codable { case mood, busy, wantsQuiet, goal }
    public var kind: Kind
    public var value: String                            // "tired", "sad", "busy", "shareCreation"
    public var confidence: Double                       // inferred: ≤ 0.7; stated by the user: 1.0
    public var evidence: Int
    public var stated: Bool
    public var expires: Date                            // mood 20 min (stated 30 min), busy 10 min
}

public enum RepairPhase: String, Sendable, Codable { case fine, strained, ruptured, repairing, reconciled }

public struct Expectation: Sendable, Equatable, Codable, Identifiable {
    public enum Framing: String, Sendable, Codable { case nervous, excited, neutral }
    public enum Status: String, Sendable, Codable { case pending, asked, resolved, expired }
    public var id: UUID
    public var person: PersonID
    public var subject: Subject                          // "job interview"
    public var due: Date
    public var expires: Date                             // due + 7 d
    public var framing: Framing
    public var status: Status
    public var outcomeValence: Double?
}

public struct Intention: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable { case followUp, ask, share, learn, repair, skill, ritual }
    public enum Status: String, Sendable, Codable { case open, issued, done, dropped }
    public var id: UUID
    public var kind: Kind
    public var subject: Subject
    public var person: PersonID?
    public var reason: String                            // template, ≤ 8 words: "they were nervous about it"
    public var notBefore: Date
    public var expires: Date
    public var priority: Double                          // 0…1
    public var status: Status
    public var issuedCount: Int                          // aim notes emitted (max 2)
    public var stepsDone: Int, stepsNeeded: Int          // learn/skill progress
    public var source: String                            // "curiosity", "plan", "misread", "interest", "ritual"
}

public struct Interest: Sendable, Equatable, Codable {
    public var subject: Subject
    public var weight: Double                            // 0…1, half-life 7 d, cap 20 entries
    public var lastTouched: Date
}

public struct Ongoing: Sendable, Equatable {
    public var mind: MindSnapshot
    public var person: PersonID?                         // identified speaker, gated by FaceMatching distance
    public var hypotheses: [Hypothesis]                  // ≤ 4 live
    public var topic: [Subject]                          // ≤ 3, current conversation topic lemmas
    public var intentions: [Intention]                   // ≤ 16 open; self-motivated (learn/skill/share) ≤ 3
    public var expectations: [Expectation]               // ≤ 8 pending
    public var interests: [Interest]
    public var repair: RepairPhase
    public var awkwardness: Double                       // 0…1, half-life 3 min
    public var turnsThisConversation: Int
    public var followUpsThisConversation: Int
    public var revealedThisConversation: Bool
    public var cutOff: Bool                              // Dee was cut off last turn
    public var misreadThisTurn: Misread?
    public var conversationStarted: Date
}
```

### 3.4 Enduring

```swift
public enum Value: String, Sendable, Codable, CaseIterable { case honesty, kindness, curiosity, independence }

public enum HumourStyle: String, Sendable, Codable, CaseIterable {
    case wordplay, deadpan, absurd, gentleTeasing, selfDeprecatingRobot
}

public enum Mannerism: String, Sendable, Codable, CaseIterable {   // mirrors DeeFace.Performance raw values
    case wink, blinkLeft, blinkRight, yawn, eyeRoll, doubleTake, nod, headShake, giggle,
         squint, lookAround, startle, sigh, bounce, shiver, contentSquint, dizzySpin
}

/// Small seeded repertoire per slot; weights shift with state. Never a single fixed variant.
public struct Signature: Sendable, Equatable, Codable {
    public enum Slot: String, Sendable, Codable, CaseIterable { case thinking, amused, fond, doubtful, greeting }
    public var repertoire: [Slot: [WeightedMannerism]]   // 2–3 entries per slot
    public var linesVariant: UInt64                      // seed for canned-line variants
    public var prePause: TimeInterval                    // 0…0.6 s, ∝ patience
}
public struct WeightedMannerism: Sendable, Equatable, Codable {
    public var mannerism: Mannerism
    public var base: Double
    public var energyBias: Double                        // + favours high energy
    public var playBias: Double                          // + favours playGate
}

public struct Facet: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable { case taste, strength, limit }
    public enum Source: String, Sendable, Codable { case seed, heuristic, reflection }
    public var id: UUID
    public var kind: Kind
    public var subject: Subject                          // "rain sounds", "timers"
    public var innate: Double                            // taste: hash(seed, subject) ⊕ trait fit, −1…1
    public var learned: Double                           // taste: EMA of episode valence, −1…1
    public var polarity: Double                          // 0.5·innate + 0.5·learned
    public var evidence: Int
    public var contrary: Int                             // evidence against the crystallised sign
    public var crystallised: Bool                        // evidence ≥ 3 && |polarity| ≥ 0.35
    public var revealedAt: Date?                         // nil = latent
    public var reason: String?                           // ≤ 8 words, template or (S7) grounded reflection
    public var source: Source
    public var updatedAt: Date
}

public struct Lesson: Sendable, Equatable, Codable, Identifiable {
    public enum Situation: String, Sendable, Codable {
        case moodGuess          // she guessed a mood, was corrected
        case tookLiterally      // "I was joking"
        case wrongReferent      // "no, the other one"
        case interruptedThem    // she spoke over a slow speaker
        case jokeFlopped        // playful reply → flat/negative
        case askedTooMuch       // busy/quiet signals after her questions
    }
    public var id: UUID
    public var person: PersonID?                         // nil = general lesson
    public var situation: Situation
    public var doInstead: String                         // template: "check whether they're joking"
    public var evidence: Int                             // ≥ 2 to exist; retired below 1
    public var lastApplied: Date?
    public var createdAt: Date
}

public struct SocialProfile: Sendable, Equatable, Codable {       // per person; learnt
    public var pauseScale = 1.0                 // 0.7…1.6, shrinkage prior 10 obs at 1.0
    public var pauseN = 0
    public var backchannelRate = 1.0            // 0 disables
    public var humorReceptiveness = 0.5         // EWMA α 0.15
    public var moodInferenceGain = 1.0          // ×0.85 per correction, floor 0.4, +0.02 per confirmation
    public var silenceComfort = 0.3             // 0…1
    public var kindnessEMA = 0.0                // predicted valence for prediction-error "surprise"
}

public struct Episode: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable { case conversation, followUp, misread, discovery, repair, play, shared }
    public var id: UUID
    public var person: PersonID?
    public var start: Date, end: Date
    public var kind: Kind
    public var topics: [Subject]                  // ≤ 3
    public var gist: String                       // ≤ 100 chars, template-filled from slots
    public var why: String?                       // ≤ 8 words, from the largest feeling delta
    public var expected: String?                  // ≤ 8 words: "I thought he'd be nervous"
    public var changed: String?                   // ≤ 8 words: "now I ask about his playing"
    public var valence: Double
    public var salience: Double
    public var surprise: Double                   // |predicted − actual| valence
    public var mindBefore: MindCode, mindAfter: MindCode
    public var recalled: Int
    public var lastRecalled: Date?
    public var openLoop: UUID?                    // intention it spawned
}

public struct Gag: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID; public var person: PersonID?; public var topic: Subject
    public var hookTemplate: Int                  // index into the humour-style hook table
    public var uses: Int; public var laughs: Int; public var flatStreak: Int
    public var lastUsed: Date?; public var retired: Bool
}

public struct Ritual: Sendable, Equatable, Codable, Identifiable {
    public enum Trigger: String, Sendable, Codable { case firstSightOfDay, goodnight, returnHome }
    public var id: UUID; public var person: PersonID?; public var trigger: Trigger
    public var variant: Int                       // phrase variant, coined once from humour style + seed
    public var mannerism: Mannerism
    public var count: Int; public var streak: Int; public var lastDone: Date?
}

public struct Boundary: Sendable, Equatable, Codable, Identifiable {
    public enum Owner: String, Sendable, Codable { case user, dee }
    public var id: UUID; public var person: PersonID; public var topic: Subject
    public var owner: Owner; public var createdAt: Date; public var active: Bool
}

public struct Enduring: Sendable, Equatable {
    public var seed: UInt64
    public var values: [Value: Double]            // weights from traits at seeding; never change
    public var humour: HumourStyle                // primary; secondary stays latent
    public var humourSecondary: HumourStyle
    public var signature: Signature
    public var facets: [Facet]
    public var lessons: [Lesson]
    public var profiles: [PersonID: SocialProfile]
    public var boundaries: [Boundary]
    public var gags: [Gag]
    public var rituals: [Ritual]
    // Episodes are NOT held in RAM wholesale: Cortex keeps an index (id, person, topics,
    // salience, recalled) of ≤ 300 for recall; bodies are fetched from SelfStore on demand.
    public var episodeIndex: [EpisodeKey]
}

public struct Moment: Sendable, Equatable {
    public var momentary: Momentary
    public var ongoing: Ongoing
    public var enduring: Enduring
    public var now: Date
    public var seq: UInt64                         // increments every step
}
```

### 3.5 Stance: the resolved interpretation

`Stance` contains **everything** any expressive channel reads. The rule: a projection's only parameter is `Stance` (plus `Enduring.signature`, which is constant). Memory writes are not expressive channels. `EpisodeBuilder` reads `Moment` deltas and `Stance`, and the agreement claim is restated to cover expressive outputs only.

```swift
public struct Stance: Sendable, Equatable {
    public var expression: Emotion        // THE one emotion: face, voice, tag reconciliation
    public var intensity: Double          // 0…1
    public var regard: Double             // −1…1 → eye tint
    public var energy: Double
    public var playGate: Bool             // playfulness·humorReceptiveness > 0.3 && repair == .fine && no distress hypothesis
    public var floor: Floor
    public var focus: Focus
    public var gaze: GazeIntent           // resolved here, not in the projection, so tests see it
    public var listen: ListenPreview?     // only while .userSpeaking/.userPaused
    public var beatStep: BeatStep?
    public var mannerism: Mannerism?      // chosen this step (beat > backchannel > signature reaction)
    public var uncertainty: Double
    public var notes: [Note]              // ≤ 2, chosen by NotePicker (§6.3)
    public var age: Double?
}

public struct GazeIntent: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        case user                         // face position from camera
        case point(SIMD2<Double>)         // touch / front-camera hand
        case examineBack                  // back-camera referent: eyes drop and narrow (gazeY +0.35, lids 0.2)
        case side(Double)                 // sound direction guess, −1…1
        case away                         // thinking aversion, up-left
        case wander                       // idle director
    }
    public var target: Target
    public var hold: TimeInterval
}
```

**Expression precedence in `Stance.resolve`** (first match wins):
1. **Live reflex** (≤4 s). Reflexes sit above mood, per CONTRACTS-0.4.
2. **Beat overlay**, while a beat step is active.
3. **Reconciled LLM tag**, while Dee is speaking, plus 1.5 s.
4. **Floor overlay.** During `.userSpeaking` or `.userPaused`, the expression is `listening`, and the face blends in `ListenPreview` through `listenValence`/`listenIntensity`. During `.deeThinking` it is `thinking` when mood is calm, otherwise the mood emotion (same rule as `FaceAnimator.calmForThinking`).
5. **Mood:** `mind.emotion`.

**Tag reconciliation** (in the `Floor` sub-reducer, applied to `.deeSaid(tag:)`):
- **Bands:** `positive` (happy, joy, love, excited, giddy, playful, proud, content, relieved, hopeful, awe, smug, mischievous, shy, dreamy), `neutral` (neutral, curious, thinking, surprised, confused, skeptical, determined, bored, sleepy, dizzy, pleading), `negLow` (sad, hurt, worried, lonely, scared, overwhelmed), `negHigh` (angry, grumpy, unimpressed). Band distance: positive–neutral 1, neutral–negLow 1, negLow–negHigh 1, positive–negLow 2, positive–negHigh 2, neutral–negHigh 1.
- **The mood band** comes from `mind.valence` and anger: anger > 0.4 or regard < −0.5 gives `negHigh`; valence < −0.25 gives `negLow`; valence > 0.2 gives `positive`; anything else is `neutral`.
- **When to substitute:** only when the band distance is 2 **and** none of these holds:
  - a reflex in the tag's band fired within 4 s (she can laugh while upset);
  - the tag is positive and `regard > 0.3` (affection coexisting with frustration, the brief's own example);
  - the tag is `smug` or `mischievous` while mood is `negHigh` (wry).
- **The substitute** is the nearest emotion in the mood band by a fixed table, e.g. `happy`→`unimpressed`, `love`→`hurt`, `excited`→`skeptical`. Face, voice and the on-screen transcript all use the substitute.

---

## 4. The update loop

### 4.1 Percepts and effects

```swift
public enum Percept: Sendable, Equatable {
    case partial(String)                                   // volatile STT text (≤ 2 Hz forwarded)
    case pause(turnEnd: Double, hesitation: Double)        // from TurnPredictor
    case heard(text: String, durationS: Double, loudnessVsBaseline: Double, appraisal: Appraisal)
    case sound(label: String, unexpected: Bool)
    case sight(camera: CameraSide, things: [String], novel: [String])
    case head(yaw: Double, pitch: Double)
    case faceLost, presence(arrived: Bool)
    case identified(PersonID?, distance: Float)
    case touch(kind: String, gentle: Bool, at: SIMD2<Double>?)
    case gesture(String)                                   // wave / palm / thumbsUp
    case promptSubmitted                                   // DeeModel called agent.respond
    case deeSaid(tag: Emotion?, sentence: String)          // per spoken sentence (RAM only, never stored)
    case deeTurnFinished(text: String)                     // full reply, RAM only, for follow-through check
    case speakingStarted, speakingFinished
    case bargeIn
    case conversationStarted(Date), asleep(Bool)
    case tick                                              // 2 Hz
}

public enum Effect: Sendable, Equatable {
    case reply(userText: String?, cue: String)             // → ReplyEngine.respond(_:state:effort:)
    case initiative(cue: String)                           // Dee speaks first (userText nil)
    case say(String)                                       // canned line, no LLM (VoiceService.say)
    case stopSpeaking
    case setPauseScale(Double)                             // → ListeningCore
    case glanceNow(CameraSide), lookAround(Bool)           // → CameraSense
    case appraise(Appraisal)                               // → Mind.react
    case curiosity(CuriosityDirector.Stimulus)             // keeps the director's cooldowns in sync
    case persist(SelfWrite)                                // → SelfStore (batched per turn)
    case remember(ExtractedFact, person: PersonID)         // → MemoryStore.remember
    case reflect                                           // schedule Reflector
}
```

### 4.2 Cortex

```swift
public struct Cortex: Sendable {
    public private(set) var moment: Moment
    public private(set) var stance: Stance
    public init(enduring: Enduring, mind: MindSnapshot, at now: Date)

    /// Pure and synchronous. `mind` must be the newest snapshot (by `sequence`);
    /// older ones are ignored. Order of sub-reducers is fixed (below).
    public mutating func step(_ p: Percept, mind: MindSnapshot, at now: Date) -> [Effect]

    /// Builds the `<dee_state>` for the next LLM turn and marks notes as issued.
    public mutating func cue(at now: Date) -> String

    /// Self block + rule lines for Persona, frozen until the next newConversation.
    public func selfLines(person: PersonID?, at now: Date) -> [String]
}
```

**Sub-reducers.** Each is a `struct` with `mutating func reduce(_ p: Percept, _ m: inout Moment, _ rng: inout Rand) -> [Effect]`. Each has its own unit tests and its own golden trace (§12). This addresses the judges' "god-object" critique: a rule change only churns its own trace. They run in this fixed order:

| # | Sub-reducer | Owns | Reads |
|---|---|---|---|
| 1 | `FloorKeeper` | `floor`, `llmTag` (reconciliation), cut-off, Dee-interrupts detection | voice percepts, mind |
| 2 | `Listener` | `preview`, backchannel timing, hesitation response, silence classification | partials, pause, profile |
| 3 | `Attention` | `focus`, `referents`, `pendingGlance`, mutual gaze, head pose | sight, head, touch, sound, heard |
| 4 | `Interpreter` | hypotheses, topic, deixis, `PlanDetector`, `RepairDetector`, expectation checks | heard, appraisal, referents |
| 5 | `RepairKeeper` | `repair`, `awkwardness`, boundaries | appraisal, misreads, floor events |
| 6 | `IntentionBoard` | intentions, follow-through, initiative | curiosity candidates, expectations, interests, lessons |
| 7 | `Beats` | `beat` | focus changes, recall hits, floor |
| 8 | `EpisodeBuilder` | per-conversation accumulator, `SelfWrite` at boundaries | mind before/after, topics, events (no text) |
| 9 | `Learner` | tastes (online evidence), interests, profile EWMAs, lessons (minting) | episodes in progress, misreads, laughter |

After the sub-reducers, `stance = Stance.resolve(moment, rng)`. `NotePicker` runs only when `cue(at:)` is called.

### 4.3 Driving it from DeeModel (@MainActor)

```swift
func perceive(_ p: Percept) async {
    let snap = await mindFor(p)                 // Mind.hear / react / tick as today; newest-sequence rule
    let effects = cortex.step(p, mind: snap, at: Date())
    apply(Projector.face(cortex.stance, signature))   // FaceInputs: emotion, tint, lookAt, listen*, performance
    voiceStyle = Projector.voice(cortex.stance)       // VoiceStyle.forMood(emotion: stance.expression, …)
    for e in effects { await execute(e) }       // in order; SelfStore/MemoryStore writes batched per turn
}
```

- `Mind` stays an actor. `Cortex` never awaits, which is the source of determinism.
- The 2 Hz `.tick` replaces the mood clock's direct `refreshEmotion()`. There is no 20 Hz loop: the face animator already smooths at 120 Hz.
- `considerInitiative()` becomes `.tick`, and `IntentionBoard` may return `.initiative(cue:)`.

---

## 5. What each channel reads

| Channel | Reads (from `Stance` only) | Function | Plugs in at |
|---|---|---|---|
| **Words** | `notes`, plus the mood sentence from `mind` (same snapshot `seq` as the stance) | `CueWriter.cue(stance:mind:)` | `ReplyEngine.respond(_:state:effort:)`, replacing `snapshot.cue` |
| **Voice** | `expression`, `intensity`, `energy`, `age` | `VoiceStyle.forMood(emotion:age:energy:)`, then pitch × (1 + 0.08·(intensity − 0.5)) | `DeeModel.voiceStyle` |
| **Expression** | `expression`, `intensity`, `regard` (tint), `listen` | `Projector.face` | `FaceInputs.emotion`, `.tint`, `.listenValence`, `.listenIntensity` |
| **Gaze** | `gaze` (resolved from `focus`, `floor` and `beatStep`; priority below) | `Projector.face` | `FaceInputs.lookAt` |
| **Performances** | `mannerism` | `Projector.face` → `PerformanceRequest(id: ++n)` | `FaceInputs.performance`. The idle director runs only while `floor == .idle && beat == nil` (`FaceInputs.mood` is suppressed to neutral otherwise) |
| **Listening** | `floor`, `listen`, backchannel mannerisms | face-only in S2. Vocal clips only in S7 with AEC | `FaceInputs`; `VoiceService.backchannel` (S7) |
| **Attention / sensors** | effects `glanceNow`, `lookAround` | | `CameraSense` |
| **Initiative** | `IntentionBoard` → `.initiative(cue)` | | `ReplyEngine.respond(.initiative(""), state: cue, effort:)`, as today's `perceive(.initiative)` |
| **Memory** | `Moment` deltas + `Stance` | `EpisodeBuilder`, `Learner` → `SelfWrite` | `SelfStore` (and `MemoryStore` for facts) |

**Gaze priority** (resolved in `Stance.resolve`):
1. Touch point.
2. Active beat step.
3. Triadic joint attention after the user acts on a referent: user for 0.3 s, then the referent for 1.2 s, then back to the user and hold.
4. While Dee speaks: the user. Thinking aversion (`.away` for 0.6 s) at 30% of sentence starts, chosen by seeded RNG, never on the final sentence.
5. While the user speaks or pauses: the user (micro-saccades stay on).
6. Focus is a sound: `.side`.
7. Idle: `.wander`.

**Agreement invariants** (property-tested, §12.3):
- face emotion == the emotion passed to `VoiceStyle.forMood` == `stance.expression`;
- the transcript tag == the reconciled tag;
- the gaze target is consistent with focus and floor;
- `Projector` compiles against `Stance` only.

---

## 6. The per-turn cue

### 6.1 Format

```
<dee_state>{mood sentence} {note1} {note2}</dee_state>
```

- **Mood sentence:** a byte-identical port of today's `MindSnapshot.cue` body: `Toward your human: … Mood: … Lately you've become … [age]`. Measured at 25–55 tokens. S1 keeps it byte-identical, which a golden test checks. `MindSnapshot.cue` stays for compatibility, and `CueWriter.mood(_:)` is the new source.
- **Notes:** zero to two parenthesised, concrete, present-tense lines, each ≤30 tokens. **At most one note is an *aim*** (something to do). The other, if present, is *context* (something true now).
- **Hard cap: 120 tokens.** Estimated as `ceil(chars / 3)` (worst case; `CueWriter.estimateTokens`), in tests and at runtime: there is no local tokenizer since 0.6. If over the cap, the context note is dropped first, then the aim. The mood sentence always stays.
- **No delta encoding.** The cue is self-contained every turn. This avoids the stale `aim:` problem in append-only history:
  - notes are one-shot events, not standing state;
  - an aim note is emitted at most twice (§7.6);
  - the system rule says notes apply "now, once".

Example (≈68 tokens):
```
<dee_state>Toward your human: fond of them. Mood: cheerful, curious. (You remember: they're learning watercolor.) (Ask about one choice they made in the painting.)</dee_state>
```

### 6.2 Note catalogue

All notes are templates with ≤4-word slots. Variants are picked by seeded RNG with no immediate repeat.

| Priority | Note | Kind | Template (≤30 tokens) |
|---:|---|---|---|
| 1 | boundary (Dee's) | aim | `(Calmly say you don't like being spoken to that way.)` |
| 2 | reconciled | aim | `(They made up with you. Accept warmly and briefly; don't dwell.)` |
| 3 | user boundary set | context | `(Don't bring up {topic}.)` |
| 4 | cut off | context | `(You were cut off mid-reply; don't repeat it unless asked.)` |
| 5 | misread | aim | `(You misread them: not {x}. Own it in a few words, then check what they meant.)` |
| 6 | lesson applies | context | `(Careful: {doInstead}.)`, e.g. "they often joke with a straight face; check before taking it literally" |
| 7 | follow-up | aim | `(Ask how their {subject} went. They were {framing} about it.)`. Health facts: `(Gently ask how today went.)` |
| 8 | deixis resolved | context | `("That" is probably the {label}.)` |
| 8 | deixis ambiguous | aim | `("That" might be the {a} or the {b}; ask which.)` |
| 8 | deixis unknown | aim | `(You can't tell what they mean; ask them to show you.)` |
| 9 | recall | context | `(You remember: {gist}.)` |
| 10 | intention (ask/learn/share) | aim | `({nextAction})`, e.g. "Ask one short question about the music they play." |
| 11 | hypothesis | context | `(Maybe they're {value}; don't assume.)`, only if confidence ≥ 0.5 × gain |
| 12 | hesitation | context | `(They hesitated; be gentle and patient.)` |
| 13 | taste reveal | context | `(You happen to {love/find … odd} {subject}.)`, once per facet ever |
| 14 | gag callback | aim | `(Maybe a quick callback to your {topic} joke, {style}.)` |
| 15 | reunion | context | `(They're back; be glad to see them. Never guilt them for being away.)`, only if absence > 1 day, first turn only |
| 16 | awkward self-repair | aim | `(That was a bit awkward; a light word about it is fine.)` |

### 6.3 NotePicker

1. Collect candidates. Drop any whose cooldown is active:
   - recall: one per 4 turns, and never the same episode within 2 days;
   - taste: one new reveal per conversation;
   - gag: one per 2 days per gag, with probability 0.4 × playfulness via the seeded RNG;
   - hypothesis: one per 3 turns.
2. Pick the highest-priority **aim**, then the highest-priority **context** note that is compatible:
   - context must not contradict the aim, e.g. no gag while `repair != .fine`;
   - no taste/gag/recall/intention aim while a distress hypothesis is live (≥ 0.5).
3. Fit to budget (§6.1).
4. Mark them issued.

### 6.4 System prompt additions (frozen at `newConversation`)

`Persona.ruleLines` (fixed text, ≈40 tokens):
- `Notes in brackets inside <dee_state> are what you just noticed or want to do now: act on them naturally, once, and never read them out.`
- `Only mention shared memories that appear in <dee_state> or in what you remember.`

`Persona.selfLines`: the **self block**, ≤70 tokens, from `SelfBlock.render(enduring, person:, now:)`:
- values (always);
- primary humour style (always);
- up to 2 **revealed** crystallised tastes (`revealedAt != nil`), the highest |polarity|·evidence;
- one strength or limit;
- one lesson for the identified person ("Lately you've learned: John jokes with a straight face.");
- user boundaries, ≤3 topics (`Don't bring up: X, Y.`, ≤15 tokens, counted separately).

**Never** in the self block: open intentions, secret projects, or topical tastes that are not yet revealed. This avoids the broken-record effect a judge flagged. The self-block budget drops lines in reverse priority (lesson, limit, tastes, humour; values always stay) to fit.

Example (≈62 tokens):
> About you: you value honesty, kindness, and people being their own person. Your humour is deadpan understatement. You love rain sounds and find vacuum cleaners suspicious. You can't see anything when the phone is face down. Lately you've learned that John jokes with a straight face.

### 6.5 Prompt budget

Since 0.6 the brain is the realtime model, with a 128k-token session context,
server-side truncation and a rollover before the 60-minute cap, so history is no longer
squeezed into a small window. The budgets still matter, for cost, latency and how well
the model follows its notes:

| Block | Budget |
|---|---:|
| System persona (session instructions) | ~330 |
| Rule lines + self block + boundaries | ≤125 |
| `promptMemories(limit: 6)` | ≤90 |
| Per-turn cue | ≤120 |

- The per-turn cue goes with each response, never into the instructions.
- Thinking mode uses an identical cue; it only raises that response's reasoning effort.
- **Test:** the system prompt is byte-identical across all turns of a conversation, and a new `Persona` is accepted only at `newConversation`.

---

## 7. Algorithms

### 7.1 Conversational timing: TurnPredictor (DeeVoice, inside ListeningCore)

TurnPredictor reuses the existing YIN f0 and the dB ring buffer.

**When it runs:** at every voiced→unvoiced transition longer than 150 ms.

**Feature extraction:**
- Lexical features use only partial text that has been **stable for ≥300 ms**, never punctuation alone.
- `f0` is measured in semitones relative to the person's mean.

| Feature | Definition | w |
|---|---|---:|
| `lexComplete` | ≥ 3 stable words, the last word not in the trailing or filler sets | +1.2 |
| `lexTrailing` | last word ∈ {and, but, so, because, or, the, a, an, to, of, with, my, like, if, then, that} | −2.5 |
| `filler` | last word ∈ {um, uh, er, erm, hmm, mm} | −1.5 |
| `f0Fall` | slope over the final 400 ms voiced < −4 st/s | +0.9 |
| `f0Rise` | slope > +4 st/s (question) | +0.6 |
| `f0Flat` | \|slope\| < 1.5 and level ≥ the user's mean | −0.5 |
| `energyDrop` | final 200 ms < utterance mean − 6 dB | +0.5 |
| `short` | < 2 words so far | −0.4 |

**Scores:**
- `turnEnd = σ(−0.2 + Σ wᵢxᵢ)`
- `hesitation = max(fillerRate·2, restart 0.5, (pause > 0.6 s ∧ lexTrailing) 0.7, (rate < 0.7·baseline) 0.4)`, clamped to 0…1.

**Hold time:**
- `hold = clamp(lerp(1.4, 0.45, turnEnd) · pauseScale, 0.35, 2.5)`
- If `hesitation ≥ 0.6`, then `hold = max(hold, 1.8)`.
- `EndpointDetector.setQuietInterval(hold)`.
- Emits `VoiceEvent.pause(turnEnd:hesitation:)`.

**Per-person `pauseScale`:** an EWMA (α = 0.1) of the median within-turn pause ÷ 0.5 s, clamped to 0.7…1.6. It uses a shrinkage prior of 10 pseudo-observations at 1.0, is stored in `SocialProfile`, and is pushed with `.setPauseScale` when someone is identified.

**Clipped-speaker recovery:** if the user resumes within 1 s of Dee starting, that counts as Dee interrupting:
- `pauseScale += 0.1`;
- the `sorryGoOn` beat plus a canned line from the seeded variant table (e.g. "Oh, sorry, go on." / "Oops, you first." / "Sorry, I jumped in."), chosen by humour style;
- `awkwardness += 0.2`.

**Calibration.** The weights above are hand-set defaults. In Debug builds, `TurnPredictor` logs **feature vectors only** (no text) with the label "user continued within 2 s". `scripts/fit-turn.py` (S2) fits the logistic weights offline. New weights ship as constants only if the false cut-off rate on the logged set does not rise.

**No speculative reply.** The cue depends on the final appraisal, so the reply is requested only once the turn has ended. The latency win comes from shorter holds (0.8 → 0.45 s when confident), plus a **ready face**: at `turnEnd ≥ 0.6` the eyes lift and widen slightly.

### 7.2 Listening face and backchannels (`Listener`)

**Preview appraisal.** On each partial (forwarded at ≤2 Hz), `var a = appraiser; a.appraise(partial)` on a *copy* (a value type, so nothing commits) gives `valence`.
- `intensity = min(0.5, |valence|)`.
- A sign flip requires 0.6 s of persistence.
- The real commit happens at `.heard`, as today.

**Hesitation response** (`hesitation ≥ 0.6`):
- lids soften (the `listenHesitant` beat);
- no nods for 1 s;
- after 3.5 s of silence following a hesitant fragment, a soft blink and tilt. Dee never speaks into it.

**Visual backchannel.** Fires when all of these hold:
- the user has spoken ≥1.5 s this turn;
- a pause of 200–600 ms with `turnEnd < 0.5`;
- `now − lastBackchannel ≥ 3 s / (0.5 + extraversion)`;
- `profile.backchannelRate > 0`;
- no hesitation hold is active.

**Which mannerism:**
- `nod` by default;
- `contentSquint` if the preview valence is > 0.3;
- a soft blink if a distress cue is present;
- `giggle` if `SoundKind.laughter` was heard within 1 s.

Rate limit: ≤15 per minute.

**Silence model**, after Dee's turn:
- **pendingQuestion** (her last sentence ended in "?"):
  - at 6 s, gaze returns to the user with a small tilt;
  - at 14 s, she lets it go: no re-ask, and the intention becomes `.dropped` if it was an aim.
- **comfortable** (user present, regard > 0.1, last hesitation < 0.3, no pending question): curiosity gaps × (1 + `silenceComfort`), idle director at half rate.
- **awkward** (\|yaw\| > 30° within 2 s of her line and no reply in 4 s): `awkwardness += 0.15`. The silence is not filled.

**`silenceComfort` learning:** +0.05 each time the user starts the next topic after a silence > 10 s; −0.05 when the user says "hello?" or similar. Clamped to 0…1.

### 7.3 Shared attention (`Attention`)

**Focus competition**, evaluated per percept and per tick:
- `score = base[kind] × novelty × (1 + interest(subject)) + 0.3·[kind == current]`
- Base weights: speech 1.0, touch 0.9, unexpected sound 0.8, user-bumped referent 0.75, novel sight 0.6, known face 0.5.
- A challenger wins only if it beats the incumbent by **0.15** (hysteresis) **and** the incumbent is older than **1.5 s**. Speech and touch preempt immediately.
- These two constants are chosen to stop gaze dithering at 2 Hz sight updates. They are tuned by the property test "≤ 1 focus change per 1.5 s under random sight noise" and are not justified beyond that.

**Referents:** cap 12, LRU, salience half-life 20 s. Bumps:
- novel sight +0.5, repeat sight +0.15;
- the user mentions the label (lemma match) +0.6, which also sets `sharedWithUser`;
- **held up** +0.5: a front label that is not a person while the face box shrinks or the face is lost for < 2 s with a hand present;
- the user looks down (pitch < −15°) for > 1 s while front labels change +0.2.
- Pointing is a weak +0.2 only, because front-camera pointing geometry is unreliable.

**Look requests:** "look (at this)", "can you see", "what's this/that" emit `.glanceNow(back)` (and front if a hand is present). Deixis waits ≤1.2 s for the glance.

**Deixis.** Triggers: `this|that|it|that one|this one|these|those|over there`, with no noun.
- `s₁ ≥ 0.5 ∧ s₁ − s₂ ≥ 0.2`: the "probably the X" note; focus becomes the referent.
- two candidates ≥ 0.3: the "ask which" note; `uncertainty = 0.6`.
- otherwise: the "ask them to show you" note, a `squint`, and `uncertainty = 0.8`.

**Correction** ("no, the other one"):
- the chosen referent's salience × 0.3, and the next candidate is used;
- it counts as a misread of kind `wrongReferent`.

**Mutual gaze:** \|yaw\| < 15° and pitch > −10° held for 1 s. The initiative threshold requires mutual gaze or speech within the last 10 s, so she does not talk at the back of someone's head. If yaw is unavailable, face presence within the last 3 s substitutes.

**Common ground:** a note names a referent as news ("you just noticed a…") if `!sharedWithUser`, and as shared ("that guitar") otherwise.

### 7.4 Tentative model of the user (`Interpreter`)

**Sources of hypotheses:**
- **Mood:** existing appraisal cues (distress, loudness vs baseline, flat pitch, slow rate). Confidence `(0.35 + 0.1·evidence) × moodInferenceGain`, capped at 0.7.
- **Stated feeling** ("I'm fine/tired/sad") overrides at 1.0 for 30 min.
- **Busy/wantsQuiet:** < 3-word replies three times in a row, looking away during Dee's speech, the palm gesture, or "not now". Expires after 10 min. While live, `IntentionBoard` initiative needs p > 0.85.
- **Goal:** a pattern table. "look/check this out" gives `shareCreation`, "can you…" gives `task`, "guess what" gives `news`.

**Corrections** ("I'm not X", "I'm fine", "no, I meant", "I was joking", "that's not what I said", "you misunderstood", or the same question repeated within 60 s):
- the matching hypothesis goes to confidence 0;
- `moodInferenceGain ×= 0.85` (floor 0.4);
- `uncertainty = 0.8`;
- a misread note is emitted;
- the misread is recorded (§7.7).

### 7.5 Anticipation: PlanDetector and Expectations

**Detection** runs on the live utterance only, which is never stored. It combines:
- future-event patterns ("I have / I've got / I'm going to / my … exam|interview|appointment|trip|game|date|surgery|party|presentation|match", "I'm going to finish …");
- `NSDataDetector` for the date (none found: due = now + 1 d);
- framing from the appraisal (distress → nervous, joy → excited).

It produces an `Expectation` (subject ≤4 words) plus `Intention(.followUp, notBefore: due + 2 h, expires: due + 7 d, priority 0.8)`.

**Firing.** A follow-up is eligible when all of these hold:
- `now ≥ notBefore`;
- the person is identified (distance gate);
- `turnsThisConversation ≥ 1`;
- `followUpsThisConversation == 0`;
- it is not within 10 s of arrival.

`Fact.Category.health` subjects use the gentle variant.

**Outcome.** The appraisal of the next user turn sets `outcomeValence`:
- `.appraise(.internal(relief:))` when the framing was nervous and the outcome positive; sympathy when negative;
- a `.followUp` episode with `expected = framing` and `changed = outcome`;
- `status = .resolved`.

**Unprompted resolution:** if the user mentions the subject first, the same outcome path runs and the intention is `done`.

**Expiry:** silent, at `expires`. Absence never generates a note.

### 7.6 Intentions and follow-through (`IntentionBoard`)

**Sources:**
- `CuriosityDirector.candidates` (sight, sound, ask-about-human, play, share-a-thought), with cooldowns kept in the director;
- follow-ups;
- repairs, which jump the queue;
- **learn**: an interest > 0.6 with fewer than 2 facts on the subject;
- **skill**: misreads with a person ≥ 2 in 7 days ("get better at telling when John is joking"); done after 5 clean conversations;
- **ritual** triggers.

At most 3 self-motivated intentions are open, and at most one new one is born per day.

**Score:** `p = priority × relevance(topic, focus, person) × timing(floor, quietAfterSpeech) × (0.5 + urgeToTalk)`, where relevance is 1 for a subject match, 0.6 for a person match, and 0.3 otherwise.
- On a user turn, the top candidate with `p > 0.35` becomes the aim note.
- With nobody speaking (initiative), it needs `p > 0.6` plus mutual gaze. With a busy hypothesis live, it needs > 0.85.

**Follow-through** (deterministic):
- When an aim is issued, `status = .issued, issuedCount += 1`.
- On `.deeTurnFinished(text)` (RAM only), the intention is `done` if the reply contains the subject lemma or a question about it.
- Otherwise it is re-eligible after ≥2 turns. After `issuedCount == 2` it is `dropped` **silently**.
- `done` advances learn/skill steps and may fire `.internal(pride:)` on completion.

### 7.7 Learning from misunderstandings (`Learner`)

A **misread record** stores `(person, at, situation, topic)`. No text.

**Minting a lesson:** two misreads of the same `situation` with the same person within 14 days mint a `Lesson`. Further hits add evidence.

**What a lesson changes** (D6, deterministic first):

| Situation | Parameter effect | Note when the situation recurs |
|---|---|---|
| `moodGuess` | `moodInferenceGain ×0.85`; hypothesis notes need confidence ≥ 0.6 | `(Careful: ask how they feel rather than guessing.)` |
| `tookLiterally` | after laughter/play signals, `Interpreter` downgrades hostility by 0.5 for that person's teasing | `(Careful: they often joke with a straight face.)` |
| `wrongReferent` | deixis "resolved" threshold rises 0.5 → 0.65 | `(Check which one they mean before answering.)` |
| `interruptedThem` | `pauseScale += 0.1` | (none; timing only) |
| `jokeFlopped` | `humorReceptiveness` EWMA update; `playGate` threshold +0.1 | `(Keep it low-key.)` |
| `askedTooMuch` | initiative threshold +0.1 for that person; curiosity gap ×1.3 | (none) |

**Lifecycle:** each reflection applies `evidence × 0.95` per week. Lessons are retired below 1. A lesson whose situation stops recurring for 5 conversations loses one evidence. The top lesson for the identified person enters the self block ("Lately you've learned…"), which is her grounded account of what changed.

### 7.8 Relationship repair and boundaries (`RepairKeeper`)

**Phases:** fine → strained → ruptured → repairing → reconciled.

**Awkwardness:** 0…1 with a 3 min half-life. Increments:
- Dee interrupted +0.2;
- misread +0.25;
- awkward silence +0.15;
- failed joke +0.2: a playful reply (tag in {playful, mischievous, giddy}) followed by a flat or negative appraisal, or "not funny".

**Transitions:**
- `fine → strained`: awkwardness ≥ 0.5.
- `strained → fine`: awkwardness < 0.2. If Dee caused it, a one-time self-repair note.
- `* → ruptured`: hostility ≥ 0.5, or regard drops ≥ 0.4 within 10 min, or anger > 0.5.
- `ruptured → repairing`: any reconciliation bid. Bids are an apology appraisal, gentle pet or hold, shared laughter, thumbsUp, "are we ok", "friends?", or "I didn't mean it".
- `repairing → reconciled`: resentment < 0.2 and anger < 0.1, or two bids. The reconciled note fires **exactly once**, plus `contentSquint`. Back to `fine` after 2 min.

**Dee's boundary** fires when all of these hold:
- the phase is `ruptured`;
- a second hostile utterance comes within 10 min;
- assertiveness ≥ 0.35;
- no boundary has been stated in the last 10 min.

It produces the boundary note once and a `Boundary(owner: .dee)` episode. It is never raised again after reconciliation, and there is no sulking.

**User boundaries:** "don't ask me about X", "I don't want to talk about X", "stop asking about X" create a `Boundary(owner: .user)`. Effects:
- `CuriosityDirector.avoid` gains X;
- the `IntentionBoard` drops subjects matching X;
- that turn's context note;
- the self block's `Don't bring up` line from the next conversation.

"You can ask me about X again" lifts it.

**Absence is never a rupture.** `RepairKeeper` ignores time entirely. An open `ruptured` or `repairing` phase survives an app relaunch for up to 6 h of *together time* (not wall time), so a quarrel neither vanishes on relaunch nor waits for someone who has gone.

### 7.9 Taste, humour, play (`Learner`, `SelfSeeder`)

**Seeding** (once, `SelfSeeder.seed(personality:seed:)`, deterministic):
- **Values:** fixed, with weights from traits.
- **Humour style:** scored by trait fit, plus seeded noise of ±0.1:
  - deadpan ← humor·(1−extraversion)
  - gentleTeasing ← playfulness·assertiveness
  - absurd ← openness·playfulness
  - wordplay ← openness·conscientiousness
  - selfDeprecatingRobot ← agreeableness·(1−confidence)

  The top style is primary and the second is secondary (latent).
- **Signature repertoire:** 2–3 weighted mannerisms per slot, chosen by trait fit and the seed.
  - Example `thinking` slot: squint / lookAround / blinkLeft.
  - **Pick:** weight = base + energyBias·(energy − 0.5) + playBias·[playGate], sampled by seeded RNG, with the same variant not chosen 3 times in a row.
  - Same Dee, recognisably the same family of glances, never mechanically identical.
- **Strengths and limits:** taken from capabilities: two cameras, hearing sounds, remembering faces; can't move, no internet, short memory. They evolve with counts, e.g. ≥10 successful timers gives "good at timers" (0.6+).

**Tastes** (per label met: sight labels, sound labels, topic lemmas):
- `innate = 0.6·hashUnit(seed, subject) + 0.4·traitFit(category)`, in −1…1. `traitFit` maps label categories, e.g. openness → novel objects, neuroticism → loud machines (negative).
- `learned`: an EMA (α 0.3) of the valence of episodes containing the subject, counting only exposures with |valence| > 0.2.
- `polarity = 0.5·innate + 0.5·learned`.
- **Crystallises** at evidence ≥ 3 and |polarity| ≥ 0.35. **Flips** only after 3 contrary exposures (hysteresis).
- A crystallised taste gets a template `reason` from its strongest contributor: innate → "no idea why, you just do"; learned → "since {episode gist}".

**Gradual reveal:**
- Facets are latent until crystallised.
- Revealed when first emitted in a note, while the topic or focus matches, with at most one new reveal per conversation.
- Only revealed tastes may enter the self block.

**Interests:** weight += 0.2·curiosity per conversational touch, half-life 7 d, cap 20.

**Gags:**
- **Birth:** a laughter appraisal within 15 s of Dee finishing a turn on a topic. The hook is template index = `hash(seed, topic) mod hookTable[humour].count`.
- **Callback:** the gag note (§6.2), only if `playGate`.
- **Retirement:** after 6 uses or a flat streak of 2.
- **Per-person `humorReceptiveness`:** an EWMA of laughter or positive appraisal after playful replies (α 0.15). It scales playful candidates. Below 0.3, with high playfulness, `(Keep it low-key.)` is added.

**Rituals:**
- **Birth:** the same trigger on 3 consecutive days (first sighting before 11:00, goodnight, return home).
- **Phrase:** a variant coined once from `(humour style, seed)` with ≥4 variants per style per trigger, then reused. Mannerism from the `greeting` slot.
- **Skipped** when the regard cue is "upset" or repair ≠ fine.
- **A broken streak** resets silently and is never mentioned.

### 7.10 Episodes and recall (`EpisodeBuilder`)

**Accumulator input:** per user turn, `(appraisal, mindBefore, mindAfter, topics ≤3, events)`, where events are sight, sound, touch, follow-up, gag, misread and repair transitions. **No text.**

**Segmenting:** at topic change, at conversation end (`newConversation`, sleep ≥ 300 s) and at beat completion. 0–3 episodes per conversation.

**Salience:** `|Δregard|·2 + surprise + novelty(topics) + 0.5·[distress] + 0.5·[laughter] + [followUp] + [misread]`.
- `surprise = |profile.kindnessEMA − turn valence|`.
- At ≥ 0.4 the episode is persisted. Lower salience increments the daily digest counter only.

**Gist templates (slots only):**
- `"{Name} showed me {thing}"`
- `"{Name} said they have {subject} {when}"`
- `"Talked with {Name} about {topic}; they laughed a lot"`
- `"I misread {Name}: thought {x}, was {y}"`
- `"{Name} and I made up after {topic}"`

**why** comes from the largest feeling delta ("made me laugh", "they seemed proud", "I was worried for them"). **expected** and **changed** are filled for follow-ups, misreads and revised tastes.

**Recall** (for the recall note and the `recognize` beat):
- score = `jaccard(tags, topic ∪ focus labels) × salience × exp(−days/30) × (recalled < 3 ? 1 : 0.5)`.
- The top one is taken if ≥ 0.35, it is not on cooldown, and its person matches (or it is global).
- `recalled += 1`.

---

## 8. Background reflection

### 8.1 Deterministic Reflector (S3; always on)

**When it runs** (the `.reflect` effect):
- asleep ≥ 300 s, or
- `newConversation` after ≥ 4 user turns, or
- once per 6 h of awake time.

It runs in `SelfStore` as a single transaction, takes milliseconds, and uses no LLM.

**Steps:**
1. Merge near-duplicate episodes (same person, ≥ 2 shared topics, within 24 h).
2. Salience × 0.9 per pass, except episodes with open loops.
3. Taste crystallisation and flip checks. Interest decay.
4. Lesson evidence decay and retirement. Skill-intention progress.
5. Expire intentions and expectations past `expires` (silently). Retire gags.
6. Mint rituals from streaks.
7. Prune episodes to 300 per person and 1,000 total by lowest `salience × recency`. Folded episodes go into `digest.lowSalience`.
8. Recompute the **self block preview**, which is used at the next `newConversation`.

### 8.2 Optional language polish (dropped in 0.6)

A night-time pass that reworded gists and gave short in-character reasons for new tastes
was planned for a local model (S7, off by default). There is no local model any more,
and running it in the cloud would send stored records about people to the provider, so
it is not planned. Gists and reasons stay template-made.

---

## 9. Removing the "neglect" penalty (time away carries no relationship penalty)

In `EmotionEngine`:
1. **Delete** `neglectThreshold`, `neglectAffectionPerDay`, `neglectAffectionFloor` and the neglect block in `advance`. Delete its test.
2. **Bond freeze while away.** In `advance`, when `!c.userPresent`, affection and trust use `relaxed = base + (x − base)·0.5^(dt/h)`, then `x = max(x, relaxed)`. They can recover upward toward baseline after a quarrel but never decay downward while the user is away. While the user is present, behaviour is unchanged.
3. **Loneliness** still grows (for reunion joy). It has no other bond effect.
4. **MIND.md** update: the "Absence and reunion" bullet loses the neglect line and gains "time away never lowers affection or trust".

Elsewhere:
- **CuriosityDirector:** reunion greetings say "glad you're back" and no longer say "it got a bit lonely without them".
- **CueWriter** reunion note, as in §6.2.
- **Expectations, intentions, ritual streaks and gags** expire or reset silently.

**Tests:**
- `catchUp` over 1, 7 and 30 days leaves affection and trust ≥ their pre-absence values;
- regard after a 30-day absence plus a neutral hello is ≥ regard before;
- no cue, note or canned line produced in the reunion scenario contains {"where were you", "finally", "left me", "lonely", "ignored", "abandon", "missed you so"};
- `RepairKeeper` stays `.fine` across absences.

---

## 10. Persistence

### 10.1 Location and ownership

- The tables live in the **DeeMemory database file** (`MemoryStore.defaultURL()`).
- They are owned by `DeeSelf.SelfStore`, an actor with its own connection: WAL, `foreign_keys=ON`, `secure_delete=ON`, busy timeout 2 s.
- **Schema version:** `self_meta.schema_version`, independent of DeeMemory's version. A newer schema is refused and left untouched. Upgrades run step by step.
- `SelfStore.open` requires DeeMemory's `people` table to exist. The app opens `MemoryStore` first.

### 10.2 Schema (v1)

```sql
CREATE TABLE self_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
  -- schema_version, seed, values JSON, humour, humour2, signature JSON, last_reflection,
  -- bond-relevant 'together_time' for rupture expiry
CREATE TABLE facet (
  id TEXT PRIMARY KEY, kind TEXT NOT NULL CHECK(kind IN ('taste','strength','limit')),
  subject TEXT NOT NULL CHECK(length(subject) <= 40),
  innate REAL, learned REAL, polarity REAL, evidence INTEGER, contrary INTEGER,
  crystallised INTEGER, revealed_at REAL, reason TEXT CHECK(reason IS NULL OR length(reason) <= 60),
  source TEXT, updated_at REAL, UNIQUE(kind, subject));
CREATE TABLE interest (subject TEXT PRIMARY KEY CHECK(length(subject) <= 40), weight REAL, last REAL);
CREATE TABLE episode (
  id TEXT PRIMARY KEY, person_id TEXT REFERENCES people(id) ON DELETE CASCADE,
  start REAL, end REAL, kind TEXT, topics TEXT,              -- JSON array of ≤3 subjects
  gist TEXT NOT NULL CHECK(length(gist) <= 100), why TEXT, expected TEXT, changed TEXT,
  valence REAL, salience REAL, surprise REAL, mind_before BLOB, mind_after BLOB,
  recalled INTEGER DEFAULT 0, last_recalled REAL, open_loop TEXT);
CREATE INDEX episode_person_end ON episode(person_id, end DESC);
CREATE TABLE expectation (
  id TEXT PRIMARY KEY, person_id TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  subject TEXT NOT NULL, due REAL, expires REAL, framing TEXT, status TEXT,
  outcome REAL, episode_id TEXT);
CREATE TABLE intention (
  id TEXT PRIMARY KEY, kind TEXT, subject TEXT, person_id TEXT REFERENCES people(id) ON DELETE CASCADE,
  reason TEXT, not_before REAL, expires REAL, priority REAL, status TEXT, issued_count INTEGER,
  steps_done INTEGER, steps_needed INTEGER, source TEXT, created REAL, updated REAL);
CREATE TABLE lesson (
  id TEXT PRIMARY KEY, person_id TEXT REFERENCES people(id) ON DELETE CASCADE,
  situation TEXT NOT NULL, do_instead TEXT NOT NULL, evidence INTEGER, last_applied REAL, created REAL,
  UNIQUE(person_id, situation));
CREATE TABLE misread (
  id TEXT PRIMARY KEY, person_id TEXT REFERENCES people(id) ON DELETE CASCADE,
  at REAL, situation TEXT, topic TEXT);
CREATE TABLE social_profile (
  person_id TEXT PRIMARY KEY REFERENCES people(id) ON DELETE CASCADE,
  pause_scale REAL DEFAULT 1.0, pause_n INTEGER DEFAULT 0, backchannel_rate REAL DEFAULT 1.0,
  humor_receptiveness REAL DEFAULT 0.5, mood_inference_gain REAL DEFAULT 1.0,
  silence_comfort REAL DEFAULT 0.3, kindness_ema REAL DEFAULT 0, updated_at REAL);
CREATE TABLE boundary (
  id TEXT PRIMARY KEY, person_id TEXT NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  topic TEXT NOT NULL, owner TEXT CHECK(owner IN ('user','dee')), created_at REAL, active INTEGER);
CREATE TABLE gag (
  id TEXT PRIMARY KEY, person_id TEXT REFERENCES people(id) ON DELETE CASCADE, topic TEXT,
  hook_template INTEGER, uses INTEGER, laughs INTEGER, flat_streak INTEGER, last_used REAL, retired INTEGER);
CREATE TABLE ritual (
  id TEXT PRIMARY KEY, person_id TEXT REFERENCES people(id) ON DELETE CASCADE,
  trigger TEXT, variant INTEGER, mannerism TEXT, count INTEGER, streak INTEGER, last_done REAL);
CREATE TABLE open_repair (                -- the single cross-relaunch conversational exception
  person_id TEXT PRIMARY KEY, phase TEXT, together_seconds_left REAL);
CREATE TABLE digest (day TEXT, person_id TEXT, conversations INTEGER, low_salience INTEGER,
  PRIMARY KEY(day, person_id));
```

### 10.3 Policies

**Never stored:**
- `Momentary`;
- hypotheses;
- topic;
- utterances, partials, replies;
- `deeSaid` sentences;
- the reflection input.

"Never stored" is about this device. Since 0.6 the realtime model hears and answers
her, so while she is online the provider (OpenAI) receives the user's audio and
transcripts, her replies, the session instructions and each turn's Dee DNA (her personality,
feelings, self and relationship, the person's name, a few words about what she sees,
recalled facts and memories; `docs/DNA.md`). All microphone audio is streamed while
she is online, whoever is talking. API data is not used for
training; the provider keeps abuse-monitoring logs for up to 30 days. Camera frames,
face prints, the MindCode and these tables never leave the device.

**Stored strings come only from:**
- sight/sound labels;
- NLTagger noun lemmas;
- plan subjects (≤4 words);
- person names;
- template output.

**Writes:** one transaction per user turn (episode, intention, expectation, profile, plus facts through `MemoryStore`, separately). Profiles are written at most every 60 s and on flush. Unknown people (person == nil) get an in-memory default profile, and only global facets learn from them.

**Forget:**
- "Forget that" deletes matching facts (DeeMemory) **and** episodes or expectations whose topics contain the subject.
- Person deletion cascades by foreign key.
- `forgetEverything()` is coordinated by `DeeModel`: `MemoryStore.forgetEverything()` then `SelfStore.forgetAll()`, which wipes everything except seed facets and `self_meta` seed, values, humour and signature.
- A crash between the two leaves orphan-free global tables only. Person-scoped rows are already gone by cascade.

> **Amended after the 0.5.1 review (schema v2; binding detail in `docs/contracts-0.5/self.md`).**
> - Person rows **no longer cascade** from `people(id)`: DeeMemory deletes a `people` row when it merges a placeholder into a named person, which would have wiped that person's boundaries, lessons and profile. `person_id` is a plain column; `DeeModel` calls `SelfStore.merge(from:into:)` on `MemoryStore.merge`, `SelfStore.forgetPerson(_:)` on `forgetPerson` / `discardPlaceholder`, and `forgetPeople(notIn:)` at launch as a sweep. `SelfStore.open` no longer requires `people`.
> - "Forget that" matches whole words either way ("interview" ~ "job interview") and also removes intentions, misreads, interests, gags and episodes whose gist / why / expected / changed name it. `Cortex.forget…` runs first so nothing in RAM re-persists a forgotten row.
> - §4.3: the appraisal reaches `Mind` before `Cortex.step`, so a reducer cannot adjust it after the fact. `Cortex.adjust(_:)` (each reducer's `adjust` hook) is the agreed pre-commit pass; wiring it needs a DeeMind entry point that commits a given appraisal for heard text (open item for 0.5.3, owner DeeMind + Interpreter).

**Identity gate:** person-scoped writes require `identified` distance ≤ the DeeMemory match threshold **and** either a name confirmation this conversation or ≥3 consecutive matches. Otherwise `person = nil`.

---

## 11. Concurrency (Swift 6)

- `Cortex` is a value type owned by the `@MainActor` `DeeModel`.
- `Mind` and `SelfStore` are actors. `MemoryStore` is an actor.
- Effects that touch actors are awaited in order after `step`.
- Snapshots use the newest-`sequence` rule. `Cortex` ignores any `mind` with a lower sequence than it has seen.
- `Enduring` is loaded from `SelfStore` at launch and at `newConversation`, and written through via `.persist`. `Cortex` never reads the database synchronously. Episode bodies for recall are prefetched by person at identification (≤300 index rows, ≤20 bodies).
- No `Date()` and no global state inside `DeeSelf` pure code. Enforced by a lint test that greps `Sources/DeeSelf` for `Date()` outside `SelfStore` and the app.

---

## 12. Deterministic test plan (`Tests/DeeSelfTests`)

### 12.1 Unit tests per sub-reducer

| Sub-reducer | What the tests cover |
|---|---|
| `FloorKeeper` | Tag reconciliation table, including the three exemptions. |
| `Listener` | Backchannel rate (60 s synthetic speech → ≤15 nods, none at `turnEnd ≥ 0.5`). Preview flicker hold. Silence classes. |
| `Attention` | Hysteresis (random sight noise → ≤1 focus change per 1.5 s). Deixis three outcomes plus correction demotion. Glance wait. |
| `Interpreter` | Hypothesis caps (inferred ≤ 0.7). Stated override. Corrections. `PlanDetector` fixtures (20 utterances with dates and framing). `RepairDetector` patterns. |
| `RepairKeeper` | Table test of every transition. Reconciled note exactly once. Boundary once. Absence never ruptures. |
| `IntentionBoard` | Scoring thresholds. Follow-through done/re-issue/silent drop. Busy suppression. User-boundary avoid. |
| `EpisodeBuilder` | Salience formula. Segmenting. Gist templates. |
| `Learner` | Taste crystallise/flip hysteresis. Lesson minting at 2 misreads in 14 days. Profile EWMAs with floors. |
| `SelfSeeder` | Same (seed, personality) → identical values, humour, signature and innate tastes (golden). |
| `TurnPredictor` (DeeVoiceTests) | Synthetic f0 ramps and dB envelopes. Monotonicity (trailing "and" < plain clause < falling clause). Hold bounds 0.35…2.5. Hesitation ≥ 1.8 s. Per-person scale with shrinkage. |
| `CueWriter` | **Golden parity:** mood sentence byte-identical to `MindSnapshot.cue` for 500 random MindCodes. Every note template with the longest slots ≤30 tokens (`ceil(chars/3)`). Whole cue ≤120. |
| `SelfBlock` | ≤70 tokens. Drop order. Never contains unrevealed facets or open intentions. |
| `EmotionEngine` (DeeMindTests) | The §9 absence tests. Neglect test removed. |

### 12.2 Golden traces

Each sub-reducer has fixtures in `Tests/DeeSelfTests/Fixtures/<reducer>/*.json`. Each fixture holds the percept timeline, the expected effects and the state slice per step. They are regenerated only with `DEE_UPDATE_GOLDENS=1`, and their diffs are reviewed in the commit.

### 12.3 Agreement property test

10,000 random seeded percept sequences, each 200 steps. At each step, assert the §5 invariants:
- the face emotion equals the voice emotion;
- the transcript tag equals the reconciled tag;
- gaze is consistent with focus and floor (e.g. never `.wander` during `.userSpeaking`);
- `notes.count ≤ 2`, at most one aim;
- the cue is ≤120 tokens;
- no reproach word in any cue.

### 12.4 Multi-session scenario tests

Scenario tests (`ScenarioTests`) with a `SimClock`, scripted user lines and canned replies (no model), an in-memory `SelfStore`, and an in-memory `Mind(databaseURL: nil)`. Sessions are separated by clock jumps through `Mind.catchUp` and `Cortex` re-init from the store, so they exercise persistence round-trips.

```swift
scenario("interview follow-through", seed: 7) {
    session(day: "Mon 18:00", person: john) {
        user("I've got a job interview Thursday, I'm really nervous")
        expectStored(.expectation(subject: "job interview", framing: .nervous))
    }
    session(day: "Thu 12:00", person: john) { user("hey"); expectNoNote(.followUp) }   // before due + 2h
    session(day: "Thu 19:30", person: john) {
        user("hi Dee")
        expectCue(contains: "(Ask how their job interview went. They were nervous about it.)")
        dee("[curious] How did the interview go?")                                    // scripted reply
        expectIntention(.followUp, status: .done)
        user("it went great actually!")
        expectAppraisal(.relief); expectEpisode(kind: .followUp, expected: "nervous", changed: nonEmpty)
    }
    session(day: "Fri 09:00", person: john) { user("morning"); expectNoNote(.followUp) }  // exactly once
}
```

**Required scenarios:**

1. **Follow-through** (above), plus:
   - **Ignored aim:** the scripted reply never mentions the subject → re-issued once after ≥2 turns → dropped silently. No third cue.
2. **Away 12 days:**
   - the expectation expires with no note;
   - affection, trust and regard are not lower on return;
   - the self block is byte-identical before and after;
   - no reproach words.
3. **Learns from a misunderstanding:**
   - Session 1: Dee infers "sad" (note emitted). The user says "I'm fine, just tired". Results: correction, `moodInferenceGain` 0.85, misread note.
   - Session 2 (day +3): the same pattern → a `Lesson(.moodGuess)` is minted.
   - Session 3: the same cues produce **no** hypothesis note at confidence 0.55 (behaviour changed by parameter). The self block contains "Lately you've learned…". The `(Careful: ask how they feel…)` note appears when distress cues recur.
4. **Took literally:**
   - "you're useless lol" twice across sessions with "I was joking" → `Lesson(.tookLiterally)`.
   - A third tease produces a smaller anger rise than the first (asserted on the snapshot delta) and the "jokes with a straight face" note.
5. **Remains recognisably herself** (60 simulated days, random seeded interactions, 3 people):
   - values never change;
   - humour style is unchanged;
   - the signature repertoire is unchanged;
   - self-block Jaccard similarity day to day ≥ 0.7;
   - no taste flips without ≥3 contrary exposures;
   - trait drift stays within MIND.md's bounds;
   - two Dees with different seeds differ in humour or ≥2 crystallised tastes.
6. **Gradual reveal:**
   - over 20 conversations, ≤1 new facet revealed per conversation;
   - the first appearance of each taste is a context note on a matching topic;
   - unrevealed tastes never appear in the self block.
7. **Repair:**
   - an insult → `ruptured` → apology plus a gentle pet → `reconciled`, with the note exactly once;
   - the next session is `fine`, with no boundary mention;
   - a second insult within 10 min (assertive Dee) → boundary note once.
8. **User boundary:**
   - "don't ask me about my job" → the curiosity candidates about "job" vanish, and the next conversation's system prompt contains `Don't bring up: job.`;
   - "you can ask about my job again" lifts it.
9. **Shown a creation** (the brief's example):
   - beat order examine → recognize → brighten;
   - recall note for the matching episode;
   - aim to ask about a choice;
   - episode stored with `why`.
10. **Coordinated listening:**
    - a hesitant fragment ("so I was, um, thinking that") → hold ≥1.8 s, no nod for 1 s, lids softened, no speech;
    - a falling complete clause → hold ≤0.6 s and the ready face.
11. **Gag lifecycle:**
    - laughter → gag; callbacks ≤1 per 2 days;
    - two flat uses → retired.

### 12.5 Safety and invariant tests

- **No-transcript fuzz:** 1,000 random utterances from a word list (seeded) are run through full sessions. The DB file bytes and all text columns contain no 5-word sequence from any utterance (subjects are ≤4 words).
- **System prompt stability:** byte-identical system prompt on every turn of every scenario. The brain receives a `Persona` only at `newConversation`.
- **Determinism:** each scenario run twice with the same seed gives an identical trace hash. A different seed changes it.
- **Lint:** no `Date()`, `Double.random` or `UUID()` in pure `DeeSelf` code. IDs come from `rng.uuid()`.

### 12.6 Non-gating evaluations (on device or Mac)

- **LLM adherence** (the realtime model through the voice harness; sampled, so treated as indicative). 50 cue/reply pairs scored for:
  - aim followed;
  - note not read aloud;
  - tag in band;
  - ≤3 sentences;
  - no invented "remember when" without a recall note.

  The target is ≥85%. A drop of more than 10 points between builds blocks release review, not CI.
- **Timing** (device, 30 scripted voice sessions recorded as feature traces): false cut-off rate < 5%, median response gap < 0.9 s, backchannel density 4–12 per minute.

---

## 13. Phased build order (v0.5.x; each step: `swift test` green, iOS build, DEVLOG entry, commit staging `Dee/` only)

| Step | Theme | Scope | Visible result |
|---|---|---|---|
| **0.5.1** | **One Moment + self-model core** | `DeeSelf` target. Types. `Cortex` with `FloorKeeper` and `Stance.resolve`. `Projector`. Delete `spokenEmotion`/`refreshEmotion`/`flash`. `CueWriter` (golden parity plus notes infrastructure). Tag reconciliation. `SelfSeeder` (values, humour, signature repertoire). `SelfStore` v1 plus migrations. `SelfBlock` plus `Persona.selfLines`/`ruleLines`. `SentenceChunker` parenthesis filter. **Neglect removal and bond freeze (§9).** | Face and voice always agree. Her own consistent thinking and amused mannerisms. She knows her values and humour. No penalty for absence. |
| **0.5.2** | **Coordinated listening** | `TurnPredictor` plus `setQuietInterval`/`pauseScale`. `VoiceEvent.pause`. `Listener` (preview face, visual backchannels, hesitation, silence model). `FaceInputs.listen*`. Gaze priority (listening/speaking aversion, ready face). `Beats` (examine/recognize/brighten run while the reply is prepared). Clipped-speaker apology with seeded variants. Debug feature logging for calibration. | Her face reacts while you talk, she nods at pauses, waits through "um", and answers faster when you're clearly done. |
| **0.5.3** | **Memory that changes behaviour** | `Interpreter` (hypotheses, corrections, `PlanDetector`, `RepairDetector`). `IntentionBoard` (curiosity candidates, follow-ups, follow-through). `EpisodeBuilder` plus recall note. `Learner` (lessons, profiles, interests). Deterministic `Reflector`. Scenarios 1–4, 9. | "How did the interview go?" She stops guessing your mood after being corrected, and remembers what you showed her. |
| **0.5.4** | Shared attention | `SenseUpdate.head`, mutual-gaze gating, referents, `glanceNow`, deixis notes, triadic gaze, common-ground wording. Scenario 9 (full). | "What's this?" works. She looks where you're showing her and asks when unsure. |
| **0.5.5** | Repair and boundaries | `RepairKeeper`, awkwardness, user/Dee boundaries, `CuriosityDirector.avoid`. Scenarios 7–8. | She makes up gracefully, respects "don't ask me about that", and stands up for herself once. |
| **0.5.6** | Taste, humour, play | Tastes with hysteresis, gradual reveal, gags, rituals, `humorReceptiveness`, `playGate`. Scenarios 5, 6, 11. | Quirks of her own that emerge over weeks. Running jokes that retire. Morning rituals. |
| **0.5.7** | Optional extras + evaluation | AEC-dependent features behind a flag (vocal backchannel clip with own-voice masking, graded barge-in duck/resume on acknowledgements). LLM polish reflection (GBNF plumbing, cancellation, latency gate). 60-day simulation report (follow-through rate, misread recurrence, identity similarity, token overhead) in DEVLOG. | Only after device proof. |

Ordering rationale: the brief's top three (self-model, coordinated listening, memory that changes behaviour) are 0.5.1–0.5.3. Unlike cognitive's pure-refactor S1, 0.5.1 ships visible behaviour (agreeing channels, mannerisms, self block, absence fix).

---

## 14. Risks

| Risk | Mitigation |
|---|---|
| **The model ignores, quotes or over-applies notes** | Two notes at most, parenthesised concrete imperatives, one aim. `SentenceChunker` drops parenthesised text before speech. `CueLeakWatch` leak flag. Every must-happen behaviour (gaze, beats, nods, memory, follow-through bookkeeping) is independent of the LLM. Mac adherence eval. |
| **Stale notes in append-only history** | No standing `key:` state. Notes are one-shot events. The aim is issued at most twice, then dropped. The rule line says "now, once". Server-side truncation and session rollover drop the oldest turns. |
| **Prompt cache invalidation** | The system prompt is frozen, a test asserts byte identity, and `Persona` only changes at `newConversation`. Reflection never shares the sequence mid-conversation. |
| **Hand-set timing weights clip slow speakers** | Hesitation floor 1.8 s, per-person `pauseScale` with shrinkage, clipped-speaker recovery (+0.1), offline calibration from feature logs, false cut-off target < 5%. |
| **Weak vision (scene labels are not objects)** | Deixis prefers asking. `glanceNow`. Pointing is a weak bump only. `uncertainty` is surfaced on the face (squint). |
| **Echo cancellation fragility across routes** | All AEC-dependent audio in 0.5.7, behind a flag, with half-duplex fallback. Backchannels are visual first. |
| **Creepy anticipation or over-familiarity** | Only volunteered plans. One follow-up per conversation, never in the first 10 s. Health subjects get the gentle wording. Silent expiry. Boundaries honoured. |
| **Wrong person identification** | Identity gate on distance plus a name confirmation or 3 matches. Otherwise `person = nil` and only global learning. |
| **Identity drift or sycophancy** | Fixed values. Seeded humour and signature. Taste hysteresis. ≤1 new self-motivated intention per day. 60-day stability property. Trait drift governed by Mind's set-point pulls. |
| **Arbitrary-looking quirks** | Innate tastes carry a reason ("no idea why, you just do") and learned ones cite their episode. Optional grounded LLM reason in 0.5.7. |
| **Mechanical repetition of mannerisms or canned lines** | Seeded repertoires with state weighting and a no-3-in-a-row rule. ≥4 line variants per style per situation. |
| **Leakage of user speech into storage** | Slot-only templates, length CHECK constraints, a 5-gram fuzz test, and reflection input restricted to stored records. |
| **Scope and schedule** | Seven small steps, each shippable. Sub-reducers isolate golden churn. 0.5.4–0.5.7 can slip without blocking the top three priorities. |
| **Contract churn with modules in flight** | Additive API only, listed in §2. A CONTRACTS-0.5 addendum before coding. `nextPrompt` stays as a wrapper. |
| **Two SQLite connections on one file** | WAL plus busy timeout, and `SelfStore` opens after `MemoryStore`. Separate schema versions. Coordinated `forgetEverything`. |
| **Battery and thermal** | 2 Hz Cortex tick. Preview appraisal ≤2 Hz. Head pose comes free from the existing face request. LLM reflection only while charging, asleep and nominal. |
| **Roadmap shift (tools → 0.6)** | Explicit decision D8. Needs John's sign-off and a PHASES.md edit. |

---

## 15. Judge critiques: how each was resolved

| Critique | Resolution |
|---|---|
| Delta `key:` cue lines go stale and read as data | Self-contained cue each turn: mood sentence plus ≤2 parenthesised one-shot notes (§6) |
| Two writers of `<dee_state>` (social) | `CueWriter` is the single writer, and notes come from `Stance` (§6) |
| Tuples in an `Equatable` struct; `self_` naming | `Timed<T>` struct; `Moment.enduring` (§3) |
| `Stance` lacks fields that projections need; "only Stance" was overclaimed | `Stance` carries gaze, beat step, mannerism, listen preview, notes and uncertainty. The claim is restricted to expressive channels (§3.5, §5) |
| Cortex is a god-object | Nine sub-reducers with their own tests and goldens (§4.2) |
| Two clocks (`t` and `date`) | `Date` only inside `DeeSelf` (§3) |
| Thin turn-taking (cognitive); no listening (narrative) | Social's `TurnPredictor`, listening face, backchannels and silence model in 0.5.2 (§7.1–7.2) |
| TurnPredictor weights unfitted; punctuation unreliable | Stable-text lexical features, feature-only logging, offline fit (§7.1) |
| AEC fragility | Deferred and flagged (D9, 0.5.7) |
| Weak vision; no ask-when-unsure (cognitive) | Social's deixis outcomes plus `glanceNow` (§7.3) |
| Cost of the 20 Hz loop and camera | 2 Hz tick. Head pose reuses the existing face observation (§4.3) |
| Thin individuality (cognitive/social) | Narrative's values, humour style, innate+learned tastes, gags, rituals and gradual reveal (§7.9) |
| Fixed single-variant signature; canned lines grate | Seeded weighted repertoires and line variants (§3.4, §7.9) |
| Tag reconciliation flattens mixed feelings | Substitute only at band distance 2, with reflex, affection and wry exemptions (§3.5) |
| S1 with no visible behaviour | 0.5.1 ships agreement, mannerisms, the self block and the absence fix (§13) |
| Reflection cost, single sequence, no cancellation, no GBNF | Deterministic Reflector by default. LLM polish only while asleep and charging, GBNF, cancel-on-wake, latency gate (§8) |
| Reflection fed the raw transcript (paraphrase leakage) | Input is stored structured records only (§8.2) |
| Separate `DeeSelf.sqlite` breaks cascades | One file, foreign keys to `people(id)` (§10) |
| "Secret project" frozen in the system prompt | Self block excludes intentions and projects. Create-projects are dropped from v0.5 (§6.4) |
| Probability without seeded RNG | `Rand` threaded through `Cortex`; lint test (§11–12) |
| `UserRead` persisted while `Momentary` is not | Conversation-scoped state is RAM-only. One explicit exception: open rupture, in together-time (§3.3, §7.8) |
| Neglect penalty; decay while away | Rule deleted, upward-only bond relaxation while away, tests (§9) |
| Mac eval not bit-exact with the phone | Eval is indicative and non-gating for CI (§12.6) |
| Tools pushed to 0.6 | Explicit decision D8, pending John's sign-off |
