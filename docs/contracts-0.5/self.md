# CONTRACTS-0.5 addendum: DeeSelf (SELF.md §2–§6, §10–§13, step 0.5.1 + review fixes)

Revised after the 0.5.1 core review (`self-core-review.md`): request channels, per-reducer
RNG streams and hooks so the eight unfinished sub-reducers can be built in parallel,
issued-note effects, forget / merge / forget-person, schema v2 (no cascade from
`people`), and the MEDIUM/LOW fixes. The "Reducer author guide" below is binding for
0.5.2–0.5.6.

New SwiftPM target `DeeSelf` (`Packages/DeeKit/Sources/DeeSelf`, tests in
`Tests/DeeSelfTests`). It depends on DeeCore, DeeMind and DeeMemory and links
`sqlite3`. It does **not** import DeeFace, DeeVoice or DeeSense (a test
enforces this). Pure code never reads the clock, never uses global randomness and
never calls `UUID()`. Time comes in as `at now: Date`, randomness is the seeded
`Rand`, and ids come from `rng.uuid()`. A lint test enforces all three. Only
`SelfStore` and `SelfDatabase` are exempt.

## What the app calls

### Launch

```swift
let memory = try MemoryStore(databaseURL: MemoryStore.defaultURL())
let selfStore = try SelfStore.open()                                   // = SelfStore(url: MemoryStore.defaultURL())
try await selfStore.forgetPeople(notIn: memory.people().map(\.id))     // sweep rows of people DeeMemory no longer has
let enduring = try await selfStore.loadEnduring(personality: snap.code.personality,
                                                seed: UInt64.random(in: .min ... .max), // used only on the very first launch
                                                at: Date())
var cortex = Cortex(enduring: enduring, mind: snap, at: Date(),
                    carried: try await selfStore.loadCarried(at: Date()),
                    session: try await selfStore.nextSession())        // a different random sequence per launch
cortex.cueBudget = SelfBudget.cueTokens; cortex.tokenCounter = SelfBudget.count  // real tokenizer (optional)
```

### newConversation

```swift
for e in cortex.step(.conversationStarted(now), mind: snap, at: now) { await execute(e) }
let persona = cortex.persona(basePersona, person: personID, at: now)   // mutating: records who the prompt is for
await brain.newConversation(persona: persona, now: now)   // ReplyEngine
```

- Do **not** reload `Enduring` from the store here: Cortex's `moment.enduring` is the authority while it runs (every learnt change flows through it and out as `.persist`). `setEnduring` is only for an external edit, after `flush(at:)` and applying every pending write.
- Call `persona` after identification when you can. If it ran before the face was identified (`person: nil`), RepairKeeper raises that person's "Don't bring up" topics as a context note on each of their turns, because the frozen prompt lacks the line.
- When someone is identified (and once at launch with `person: nil`), hand their stored episodes to Cortex: `cortex.prefetch(episodes: try await selfStore.episodes(person: id, limit: 20))`. Without it, episodes of an earlier launch are scored but never recalled (the index holds no gists).
- Identification goes through Interpreter's §10.3 gate: three consecutive face matches, or `.identified(id, distance: 0)` after a name confirmation. A single `.identified(id, 0.2)` does not set `ongoing.person`.

### Every percept (SELF.md §4.3)

```swift
let effects = cortex.step(percept, mind: newestSnapshot, at: Date())
let s = cortex.stance
apply(Projection.expression(s))      // → FaceInputs (see the mapping below)
apply(Projection.voice(s))           // → VoiceStyle.forMood(emotion:age:energy:), pitch × pitchScale
apply(Projection.gaze(s))            // → FaceInputs.lookAt / touchPoint via DeeFace.FaceGaze
if let m = Projection.mannerism(s) { performance = PerformanceRequest(id: n += 1, performance: Performance(rawValue: m.rawValue)!) }
for e in effects { await execute(e) }   // in order; batch .persist writes per turn → selfStore.apply([...])
```

- The transcript shows `cortex.reconciledTag`, not the raw LLM tag.
- After `.stopSpeaking`, sentences that were already in flight are neither spoken nor shown (FloorKeeper ignores a `.deeSaid` while yielding).
- `.initiative(cue:)` is a complete `<dee_state>`: call `brain.respond(.initiative(""), state: cue, effort: ThinkingMode.chatEffort)` (`ReplyEngine`) as today's `perceive(.initiative)`, then `.promptSubmitted`. Do not call `cue(at:)` for it.

### Per LLM turn

```swift
_ = cortex.step(.promptSubmitted, mind: snap, at: now)
let (state, fx) = cortex.cue(at: now)       // the whole <dee_state>…</dee_state>; replaces snapshot.cue
for e in fx { await execute(e) }            // issued-note bookkeeping: .persist(intention / facet / recalled / gag)
brain.respond(.user(words: text), state: state, effort: thinking.turn(for: text).reasoningEffort)
// per spoken sentence: cortex.step(.deeSaid(tag:sentence:)); at the end: .deeTurnFinished(text:)
```

`cortex.cueText(at:)` returns only the string and queues the effects; the next `step` returns them first.

### Persistence

- `.persist(w)` effects: collect per turn, then `try await selfStore.apply(writes)`. The result lists any failed write (`ApplyResult.failed`); in DEBUG a failure also asserts.
- On background, sleep and quit: `for e in cortex.flush(at: now) { … }`, then apply the batch. A quit loses all RAM state, so `flush` also closes the open episode segment (episode or digest; the conversation is counted once) and counts this conversation's taste exposures (once per subject per conversation).

### Forget and people (call order matters)

Cortex first (so nothing in RAM re-persists a forgotten row), then the pending write batch, then the stores.

| Event | Calls, in order |
|---|---|
| "Forget that" (subject `s`) | `cortex.forget(subject: s)` → apply pending writes → `MemoryStore.forgetFacts(matching:about:)` → `let g = try await selfStore.forget(subject: s)` → `cortex.forget(episodes: g.episodes)` |
| Forget a person / discard a placeholder (`id`) | `cortex.forgetPerson(id)` → apply pending writes → `memory.forgetPerson(id)` (or `discardPlaceholder`) → `try await selfStore.forgetPerson(id)` |
| DeeMemory merge `from` → `into` (placeholder named, duplicate found) | `cortex.merge(from:into:)` → apply pending writes → `memory.merge(from, into: into)` → `try await selfStore.merge(from:into:)`. Pass resolved ids (`MemoryStore` redirects merged ids). |
| Forget everything | `cortex.forgetAll()` → drop the pending write batch → `memory.forgetEverything()` → `try await selfStore.forgetAll()` |

Self rows no longer cascade from `people(id)` (schema v2), so a DeeMemory merge never wipes them; the calls above keep the two stores in step, and the launch sweep (`forgetPeople(notIn:)`) cleans up after a crash between two calls.

## Public API

### Cortex

```swift
public struct Cortex: Sendable {
    public internal(set) var moment: Moment
    public private(set) var stance: Stance
    public private(set) var streams: [Rand]                    // one per sub-reducer, pipeline order
    public private(set) var stanceRNG: Rand, pickerRNG: Rand
    public private(set) var frozenEnduring: Enduring          // what selfLines renders from
    public private(set) var queuedEffects: [Effect]           // from cueText, returned by the next step
    public var cueBudget: Int = 120
    public var tokenCounter: @Sendable (String) -> Int = CueWriter.estimateTokens
    public static let pipeline: [String]                       // the 9 sub-reducers, in their fixed order
    public static let ruleLines: [String]                      // = SelfBlock.ruleLines
    public static func baseSeed(_ enduringSeed: UInt64, session: UInt64) -> UInt64
    public static func stream(_ name: String, base: UInt64) -> Rand   // Rand(seed: base ^ StableHash.of(name))

    public init(enduring: Enduring, mind: MindSnapshot, at now: Date, carried: Carried = Carried(), session: UInt64 = 0)
    public mutating func step(_ p: Percept, mind: MindSnapshot, at now: Date) -> [Effect]
    public mutating func cue(at now: Date, budget: Int? = nil, count: (@Sendable (String) -> Int)? = nil) -> (cue: String, effects: [Effect])
    public mutating func cueText(at now: Date, budget: Int? = nil, count: (@Sendable (String) -> Int)? = nil) -> String
    public func selfLines(person: PersonID?, at now: Date) -> [String]   // self block (+ "Don't bring up:" line), measured with tokenCounter
    public mutating func persona(_ base: Persona, person: PersonID?, at now: Date) -> Persona
    public var reconciledTag: Emotion? { get }
    public mutating func setEnduring(_ e: Enduring)            // external edits only; flush first
    public mutating func prefetch(episodes: [Episode])         // gists for recall (at identification)
    public mutating func flush(at now: Date) -> [Effect]
    public func adjust(_ appraisal: Appraisal) -> Appraisal    // reducers' pre-commit pass (see Open items)
    public mutating func forget(subject: Subject)
    public mutating func forget(episodes ids: [UUID])
    public mutating func forgetPerson(_ id: PersonID)
    public mutating func merge(from: PersonID, into: PersonID)
    public mutating func forgetAll(keepingSeeded seeded: Enduring? = nil)   // nil → enduring.keepingSeeded()
}

public struct Carried: Sendable, Equatable {                   // from SelfStore.loadCarried(at:)
    public var intentions: [Intention], expectations: [Expectation]   // → IntentionBoard
    public var interests: [Interest], misreads: [Misread]             // → Learner (misreads: last 14 days)
    public var openRepair: [PersonID: RepairPhase]                    // → RepairKeeper
}
```

`step` semantics:
- A snapshot whose `sequence` is lower than the highest seen is ignored.
- `moment.now` never moves backward; `moment.seq` increments on every step; `Momentary.beginStep` clears the per-step channels.
- A **new** reflex is shown for 4 s from its stimulus and requests a signature reaction (owner `"Cortex"`). New means a new `MindSnapshot.reflexAt` stamp, so two "giddy" reflexes in a row both restart; snapshots without a stamp fall back to "a different reflex, or none showing".
- The 9 sub-reducers reduce in their fixed order, each with its own RNG stream.
- `.conversationStarted(d)`: note candidates are cleared *before* the pipeline; after it Cortex sets `conversationStarted = d`, calls every reducer's `conversationStarted` hook (each resets its own conversation-scoped fields), then freezes the self block — *after* the pipeline, so what reducers load or learn on that step reaches this conversation's prompt.
- Then `Stance.resolve` (own stream), then the best `InitiativeRequest` becomes `.initiative(cue:)` if the floor is idle and its aim passes NotePicker's generic rules.
- Effect order: queued `cueText` effects, the reducers' effects in pipeline order, the conversation hooks' effects, initiative (with its notes' bookkeeping).

### Percept, Effect, SelfWrite

The cases are exactly those of SELF.md §4.1. `Percept.name` and `Effect.traceName` are
stable and text-free, for traces. `SelfWrite` has these cases:
- `episode`, `deleteEpisode`, `recalled(episode:at:)`, `intention`, `expectation`, `interest`, `facet`;
- `lesson`, `deleteLesson`, `misread`, `profile(PersonID, SocialProfile)`, `boundary`, `gag`, `ritual`;
- `openRepair(PersonID, RepairPhase, togetherSecondsLeft:)`, `clearOpenRepair`, `digest(day:person:conversations:lowSalience:)`.

### Stance and the projection intents

```swift
public struct Stance { expression, intensity, regard, energy, playGate, floor, focus, gaze: GazeIntent,
                       listen: ListenPreview?, beatStep, mannerism, uncertainty, notes: [Note], age, face: FaceModifiers }
public struct FaceModifiers { readyFace: Double /* 0…1 */, lidSoften: Double /* 0…1 */, tilt: Double /* −1…1 */ }
public static func Stance.resolve(_ m: Moment, _ rng: inout Rand) -> Stance
public static func Stance.gaze(_ requests: [GazeRequest]) -> GazeIntent      // the generic arbiter
public static func Stance.face(_ requests: [FaceRequest]) -> FaceModifiers
public var Moment.playGate: Bool                                              // == stance.playGate, for reducers' gates
public struct GazeIntent { target: .user | .point(SIMD2) | .examineBack | .side(Double) | .away | .wander; hold }

public struct ExpressionIntent { emotion, intensity, regard, listenValence, listenIntensity, lidNarrow, idleDirector,
                                 readyFace, lidSoften, tilt }
public struct VoiceIntent { emotion, age, energy, intensity, pitchScale }      // pitchScale = 1 + 0.08·(intensity − 0.5)
public enum Projection {
    static func expression(_: Stance) -> ExpressionIntent
    static func voice(_: Stance) -> VoiceIntent
    static func gaze(_: Stance) -> GazeIntent
    static func mannerism(_: Stance) -> Mannerism?             // non-nil only on the step it fires
}
public enum Mannerism: String { wink … dizzySpin }             // == DeeFace.Performance raw values (pinned both sides)
```

`Stance.resolve` reads state and arbitrates requests; it holds no reducer policy.

Expression precedence (first match wins):
1. live reflex (≤ 4 s);
2. beat overlay;
3. reconciled tag (speech + 1.5 s, capped at 15 s past the latest sentence);
4. floor overlay: `listening` while the user speaks or pauses; `thinking` while `deeThinking` if the mood is calm, else the mood;
5. `mind.emotion`.

Gaze: the winner of `momentary.gazeRequests` by `ChannelPriority` (ties: the later request), `.wander` if none. Who asks today:

| Priority | Requester | Target |
|---|---|---|
| 1 `touch` | Attention | `.point` (live touch) |
| 2 `beat` | Beats | the active step's gaze |
| 3 `jointAttention` | Attention (0.5.4) | triadic user → referent → user |
| 4 `deeTurn` | FloorKeeper | Dee speaking: `.user`, or `.away` during thinking aversion; `deeThinking`: `.away` 0.6 s |
| 5 `userTurn` | FloorKeeper | `.user` while the user speaks, pauses, or Dee yields |
| 6 `focus` | Attention | sound `.side`; back-camera referent `.examineBack` |
| 7 `idle` | (none) | `.wander` |

Face modifiers: per field, the winner of `momentary.faceRequests` by the same priorities (ties: later), 0 if none.

Mannerism: the winner of `momentary.mannerismRequests` by rank — `beat` (Beats, once per step) > `backchannel` (Listener) > `reaction` (a signature slot: Cortex for a fresh reflex, FloorKeeper `thinking`, Attention `greeting`); ties: the later request. Only signature picks enter `recentMannerisms` (no 3 in a row).

**App `Projector.swift` mapping (1:1, no conditionals):**

| Intent | FaceInputs / voice |
|---|---|
| `ExpressionIntent.emotion` | `emotion` |
| `.regard` | `tint` (regard colour) |
| `.listenValence` / `.listenIntensity` | `listenValence` / `listenIntensity` |
| `.lidNarrow` | `lidNarrow` |
| `.idleDirector == false` | `mood` = neutral |
| `.readyFace` / `.lidSoften` / `.tilt` | not yet in `FaceInputs`: ignored until DeeFace adds them (0 today) |
| `GazeIntent.user` / `.point` / `.examineBack` / `.side` / `.away` / `.wander` | `lookAt` = face / `touchPoint` / `FaceGaze.examineBack` / `FaceGaze.side(s)` / `FaceGaze.away` / nil |
| `Mannerism` | `PerformanceRequest(id: ++n, performance: Performance(rawValue: m.rawValue)!)` |
| `VoiceIntent` | `VoiceStyle.forMood(emotion:age:energy:)`, then pitch × `pitchScale` |

### Tag reconciliation

```swift
public enum EmotionBand { positive, neutral, negLow, negHigh; init(_ e: Emotion); init(mood: MindSnapshot); func distance(to:) -> Int }
public enum TagReconciler {
    static func reconcile(_ tag: Emotion, mind: MindSnapshot, liveReflex: Emotion?) -> (emotion: Emotion, verdict: Verdict)
    static func substitute(_ tag: Emotion, into band: EmotionBand) -> Emotion   // always lands in `band`
}
```

A tag is substituted only at band distance 2, and only when none of these exemptions applies:
- `exemptReflex`: a live reflex is in the tag's band;
- `exemptAffection`: the tag is positive and regard > 0.3;
- `exemptWry`: the tag is smug or mischievous while the mood band is negHigh.

### CueWriter, notes, NotePicker

```swift
public enum CueWriter {
    static let maxTokens = 120, maxNoteTokens = 30
    static func estimateTokens(_: String) -> Int                        // ceil(chars/3)
    static func mood(_: MindSnapshot) -> String                          // byte-identical port of MindSnapshot.cue's body
    static func cue(mind: MindSnapshot, notes: [Note]) -> String         // == snapshot.cue when notes == []
    static func cue(stance: Stance, mind: MindSnapshot) -> String
    static func fit(mood:notes:budget:count:) -> [Note]                  // ≤ 1 context + ≤ 1 aim; context dropped first
    static let reproachWords: [String]
}
public struct Note { kind: Kind, slots, variant, intention?, episode?, facet?, gag?, owner?; var text; static factories per catalogue row }
public struct NotePicker {
    func eligible(_: Note, moment: Moment) -> Bool                       // the generic §6.3 rules
    mutating func pick(_ candidates: [Note], moment:, mood:, rng:, budget:, count:) -> [Note]
}
```

Notes are raised with `m.ongoing.raise(note, by: Self.name)` into `ongoing.noteCandidates`, each already past its raiser's own gates. `Cortex.cue(at:)` then:
1. runs `NotePicker`, which applies only the generic rules: never a note (other than the user-boundary note itself) that names one of the speaker's active user boundaries; the §6.3 cooldowns (recall 1 per 4 turns and not the same episode within 2 days; one taste reveal per conversation; a gag at most once per 2 days; hypothesis 1 per 3 turns), the distress drop (taste/gag/recall/intention), "context must not contradict the aim" (and no gag unless repair is fine), the §6.2 priority order, the seeded variant (never the same twice in a row) and the budget;
2. sets `stance.notes`;
3. hands every issued note to every reducer's `noteIssued` and returns their effects;
4. clears `noteCandidates`.

Notes are one-shot.

### SelfSeeder, SelfBlock

```swift
SelfSeeder.seed(personality: Personality, seed: UInt64, at: Date) -> Enduring   // deterministic
SelfSeeder.values(_:), humourFit(_:), innateTaste(_ subject:, seed:, personality:), category(of:), traitFit(_:_:)
SelfBlock.render(_ e: Enduring, person: PersonID?, budget: Int = 70, count: = CueWriter.estimateTokens) -> [String]
SelfBlock.lines(_:person:) -> [(line: Line, text: String)];  SelfBlock.boundaryLine(_:person:count:) -> String?
SelfBlock.ruleLines: [String]   // the two fixed §6.4 rule lines
```

### SelfStore (actor)

```swift
public init(url: URL?, assertOnFailedWrites: Bool = true) throws   // nil = in-memory
public static func open(at url: URL = MemoryStore.defaultURL()) throws -> SelfStore
public func loadEnduring(personality: Personality, seed: UInt64, at: Date) throws -> Enduring   // seeds once; never re-seeds
public func loadCarried(at now: Date? = nil) throws -> Carried       // misreads of the 14 days before `now`
public func nextSession() throws -> UInt64                            // launch counter for Cortex(session:)
@discardableResult public func apply(_ writes: [SelfWrite]) throws -> ApplyResult   // { applied, failed: [FailedWrite] }
@discardableResult public func apply(_ write: SelfWrite) throws -> ApplyResult
public func episode(_ id: UUID) throws -> Episode?
public func episodes(person: PersonID?, limit: Int = 20) throws -> [Episode]
public func episodeIndex(limit: Int = 300) throws -> [EpisodeKey]
public func facets() / lessons() / misreads() / profiles() / boundaries() / gags() / rituals()
public func intentions(live:) / expectations(pending:) / interests() / openRepairs() / digest(day:person:)
@discardableResult public func forget(subject: Subject) throws -> Forgotten        // { rows, episodes }
@discardableResult public func forgetPerson(_ id: PersonID) throws -> Int
@discardableResult public func forgetPeople(notIn known: [PersonID]) throws -> Int // launch sweep
public func merge(from: PersonID, into: PersonID) throws
public func forgetAll() throws                        // keeps the seeded self (== Enduring.keepingSeeded())
public func meta(_:) / setMeta(_:_:) / storedSchemaVersion() / checkpoint() / columns() / allText()
```

Schema v2, in the DeeMemory file:
- **Connection:** its own, with WAL, foreign keys, `secure_delete` and a 2 s busy timeout.
- **Person rows:** plain `person_id TEXT`, no foreign key. v1 files (which cascaded from `people(id)`) are rebuilt on open with every row kept, and the `people_fk` meta key is dropped.
- **Merge clashes** (`merge(from:into:)`, mirrored by `Moment.merge`): lesson (person, situation) → into's row, evidence summed, earliest `created`, latest `last_applied`; social profile and open repair → into's; digest (day) → counters summed; boundary (topic, owner) → into's, active if either was; ritual (trigger) → into's; everything else re-pointed.
- **"Forget that"**: whole-word match either way (`Subject.overlaps`, plural-tolerant): episodes by topic or by gist / why / expected / changed; expectations, intentions, misreads, interests, gags by subject or topic. Boundaries and Dee's own facets stay.
- **`loadEnduring`**: once a seed is stored the caller's seed is never used. A stored piece that no longer decodes (values, humour, signature) is re-derived from the **stored** seed and rewritten alone; facets and learning are untouched.
- **Versioning:** a newer `self_meta.schema_version` is refused and the file is left untouched.

### Test helpers

`SimClock` (public):
- `epoch` is Monday 21 Sep 2026 00:00 UTC;
- `advance(_:)` and `set(_:)` move it;
- `SimClock.at("Thu 19:30", week:)` gives a time in that week.

Test target helpers (`TestKit.swift`, core-owned):
- `ReducerRun(<SubReducer>)` steps one reducer exactly as Cortex does; `.step(_:at:events:mind:)`, `.issue(_ note:)`;
- `Golden.record(<SubReducer>, name:, mind:, [Cue])` records one reducer; `Golden.recordCortex(name:, reducers:, …)` records the whole Cortex with the listed slices plus the stance;
- `Golden.verify(_:)` / `Golden.check(_:)` compare a trace with its fixture in `Tests/DeeSelfTests/Fixtures/<reducer>/<name>.json`;
- each fixture holds, per step, the percept description, the effects and the reducer's own `slice(of:)`;
- `DEE_UPDATE_GOLDENS=1` regenerates the fixtures.

Each `SubReducer` exposes `static func slice(of: Moment) -> [String: String]` for its traces.

## Sub-reducer ownership

| # | Reducer | Owns (writes) | Requests / raises | Status |
|---|---|---|---|---|
| 1 | FloorKeeper | `floor`, `llmTag`, `floorEvents`, `aversionUntil`, `ongoing.cutOff`, `turnsThisConversation` | gaze 4/5; `thinking` reaction; cut-off note | **complete**; review fixes 4 and 5 |
| 2 | Listener | `preview`, `lastBackchannel` | (0.5.2) backchannel mannerisms, face modifiers, `listenHesitant` beat, hesitation note, "awkwardSilence" signal | basic: clears the preview outside the user's turn |
| 3 | Attention | `focus`, `focusSince`, `referents`, `pendingGlance`, `mutualGazeSince`, head pose, `touchPoint` | gaze 1/6 (3 in 0.5.4); `greeting` reaction; (0.5.4) deixis notes, uncertainty | basic |
| 4 | Interpreter | `ongoing.person`, `hypotheses`, `topic`, `misreadThisTurn` | (0.5.3) hypothesis / misread notes, uncertainty, signals | basic; identity needs 3 misses to clear |
| 5 | RepairKeeper | `repair`, `awkwardness`, boundaries | awkward-repair note; boundary reminder note (finding 10) | basic |
| 6 | IntentionBoard | `intentions`, `expectations` (status), `followUpsThisConversation` | (0.5.3) aim notes, initiative | basic; issued-aim bookkeeping |
| 7 | Beats | `beat`, `beatStepShown`; consumes `beatRequests` | gaze 2; beat-step mannerism | basic |
| 8 | EpisodeBuilder | episode accumulator, `episodeIndex.recalled` | `.persist(.recalled)` | basic |
| 9 | Learner | `interests`, `recentMisreads`, `revealedThisConversation`, facets, gags, profiles, lessons | taste / gag bookkeeping | `reduce` no-op; hooks done |

Cortex owns `moment.now`, `seq`, `ongoing.mind`, `conversationStarted`, `noteCandidates` (clearing), `promptPerson` / `promptRendered`, `reflex` and `recentMannerisms`.

## Reducer author guide

This is the contract for building Listener, Attention, Interpreter, RepairKeeper, IntentionBoard, Beats, EpisodeBuilder and Learner **in parallel**. Each engineer touches only `Sources/DeeSelf/Reducers/<Name>.swift`, `Tests/DeeSelfTests/<Name>Tests.swift` and `Tests/DeeSelfTests/Fixtures/<Name>/`. Never edit `Cortex.swift`, `Stance.swift`, `CueWriter.swift`, `Notes.swift`, `Basics.swift`, `Requests.swift`, `Momentary.swift`, `Ongoing.swift`, `Enduring.swift`, `Privacy.swift`, `TestKit.swift` or another reducer's files. If you truly need a new shared field or a new note kind, ask the core owner; do not add it yourself.

### What a reducer may read and write

- **Read:** anything in `Moment`, including fields other reducers own. A reducer earlier in the pipeline sees this step's values of later reducers' fields only on the next step.
- **Write:** only the fields your header lists under "Owns" (see the table above). Everything else goes through a channel.
- **Private state:** keep it in your struct (`var` fields). It is RAM only. Anything that must survive a relaunch is written with `.persist(SelfWrite)` and comes back through `Carried` (`seed(from:)`) or `Enduring`.
- **Time and randomness:** use `m.now` only, and only the `rng` you are handed (your own stream; your draws never shift anyone else's). Ids come from `rng.uuid()`. Never `Date()`, `.now`, `UUID()`, `random…`, `shuffled`, `Hasher`, or iteration over a `Dictionary` / `Set` without sorting; the lint test fails on them.
- **Text:** `.heard`, `.partial`, `.deeSaid` and `.deeTurnFinished` text is RAM only. Never put it in a `SelfWrite`, a note slot, a signal or a stored field; only labels, `Subject`s (≤ 4 words) and template output may be stored. The no-transcript fuzz covers every persisted effect.

### Request channels (per step; re-assert every step while you want it)

| You want | Call | Arbitration |
|---|---|---|
| Gaze | `m.momentary.requestGaze(target, hold:, priority:, by: Self.name)` | lowest `ChannelPriority`, ties → later |
| Ready face, lid softening, tilt | `m.momentary.requestFace(.readyFace / .lidSoften / .tilt, value, priority:, by:)` | per field, lowest priority, ties → later |
| A specific mannerism | `m.momentary.requestMannerism(.nod, rank: .backchannel, by:)` | `beat` > `backchannel` > `reaction`, ties → later |
| A signature reaction | `m.momentary.requestReaction(.amused, by:)` | rank `reaction`; seeded pick, no 3 in a row |
| Uncertainty | `m.momentary.requestUncertainty(0.8, by:)` | max |
| Speak first | `m.momentary.requestInitiative(score:, aim:, by:)` | highest score; only while the floor is idle and the aim passes NotePicker's generic rules |
| A beat | `m.momentary.requestBeat(.listenHesitant, priority:, at: m.now, by:)` | Beats decides (not per step: Beats consumes the list) |

Use the priority that matches the §5 table row of *why* you want it, not the one that wins.

### Notes

- Raise with `m.ongoing.raise(Note.<factory>(…), by: Self.name)`. Apply **your own gates first**: hypothesis confidence ≥ 0.5 × `moodInferenceGain` (0.6 after a `moodGuess` lesson) in Interpreter; deixis thresholds in Attention; `m.playGate` and the seeded 0.4 × playfulness draw (from your stream) for gags in Learner; follow-up firing rules and p > 0.35 in IntentionBoard. NotePicker only applies the generic §6.3 rules and the §6.2 priorities.
- Candidates live until the next cue and are cleared at `.conversationStarted` (before the pipeline, so you may raise on that step).
- Bookkeeping after issue goes in `noteIssued(_:_:)`: return `.persist` effects for anything that must survive a relaunch (issued counts, `revealedAt`, recall counts, gag uses). Every reducer sees every issued note; act on `n.owner == Self.name` or ids you hold.

### Signals between reducers

`m.signal("laughter", subject:, value:, id:, label:, by: Self.name)` raises a fact; `m.inbox(for: Self.name)` returns the ones you have not seen, exactly once: a signal from a reducer earlier in the pipeline arrives in the same step, one from yourself or a later reducer on the next step. Names are free strings: document the ones you raise in your header. Payloads are labels, subjects, ids and numbers, never user text.

### Hooks (`SubReducer`; all default to no-ops)

| Hook | When | Use it to |
|---|---|---|
| `reduce(_:_:_:)` | every percept | everything; on `.conversationStarted` close out the *old* conversation |
| `seed(from:_:)` | once, in `Cortex.init` | take your part of `Carried` |
| `conversationStarted(at:_:_:)` | after all reducers reduced `.conversationStarted` | reset your conversation-scoped fields |
| `noteIssued(_:_:)` | per issued note | bookkeeping + `.persist` |
| `flush(_:)` | `Cortex.flush(at:)` (background, sleep, quit) | write throttled state (profiles: at most every 60 s, plus flush) |
| `flush(_:_:)` | the same, with your stream (default: calls `flush(_:)`) | persist what needs fresh ids before RAM is lost (EpisodeBuilder: the open segment; Learner: taste exposures) |
| `forget(subject:_:)`, `forgetPerson(_:_:)`, `merge(from:into:_:)`, `forgetAll(_:)` | privacy calls | scrub or re-point **private** state; Cortex already did every shared `Moment` field |
| `adjust(_:_:)` | `Cortex.adjust(_:)` | pre-commit appraisal changes (e.g. `tookLiterally` softening hostility) |
| `slice(of:)` | golden traces | your owned fields as stable strings |

### Tests and golden traces

- **File naming:** `Tests/DeeSelfTests/<Name>Tests.swift`, `@Suite struct <Name>Tests`. Unit tests use `ReducerRun(<Name>())` (TestKit), which steps exactly as Cortex does (`seq`, `beginStep`, the conversation hook); `run.issue(note)` simulates an issued note. Do not write a private harness.
- **Goldens:** `Fixtures/<Name>/<scenario>.json`, recorded with `Golden.record(<Name>(), name: "<scenario>", mind:, [Cue])` and checked with `Golden.verify(...)`. A whole-pipeline trace that you own goes in `Fixtures/Cortex/<name>-<scenario>.json` via `Golden.recordCortex(name:, reducers: [("<name>", <Name>.slice(of:))], …)` so it records only your slice plus the stance.
- **Updating:** `DEE_UPDATE_GOLDENS=1 swift test --filter <Name>Tests`, then review the JSON diff and explain each intended change in the commit. Never regenerate another reducer's goldens; if your change moves one (through the stance), that is a cross-reducer behaviour change: say so in the commit and tell its owner.
- **Must stay green:** your suite, `CortexTests`, `GoldenTraceTests`, `AgreementPropertyTests` (agreement invariants), `PolicyTests` (lint, no-transcript fuzz).

## Deviations from SELF.md (with reasons)

1. **`Rand` and `StableHash` are DeeSelf's own.** DeeMind's `Rand` is internal to DeeMind. The algorithm is the same SplitMix64. `StableHash` is FNV-1a plus SplitMix, because `Hasher` is randomised per process.
2. **The DeeSelf type is called `Projection`, not `Projector`.** This avoids a name clash with the app's `Projector.swift`, which maps the intents.
3. **Additive state fields:**
   - `Momentary` gains `floorEvents`, `recentMannerisms` (for the no-3-in-a-row rule), `beatStepShown` (one mannerism per beat step), `aversionUntil`, `touchPoint`, and the request channels `gazeRequests`, `faceRequests`, `mannerismRequests`, `uncertaintyRequests`, `initiative`, `beatRequests`, `signals`. `uncertainty`, `reaction` and `backchannel` are read-only views of this step's requests;
   - `Ongoing` gains `noteCandidates`, `recentMisreads`, `promptPerson`, `promptRendered`, and the derived `effectivePersonality` (recomputed only when the snapshot's personality bytes or age change) and `feeling(_:)` (one feeling without decoding all; reducers read these every step);
   - `Stance` gains `face: FaceModifiers` (ready face, lid softening, tilt) and `ExpressionIntent` the same three fields;
   - `Note` gains `owner`; `SelfWrite` gains `recalled(episode:at:)`; `Carried` gains `misreads`;
   - `Expectation` gains `episode`;
   - `Intention` gains `created` and `updated` (the §10.2 schema already has them);
   - `Misread` is defined: §3.3 used it without a definition. Its stored record is id, person, at, situation and topic. `wrongGuess` stays in RAM.

   These are the inter-reducer channels that let each reducer own one file without touching Cortex.
4. **`selfLines(person:at:)` returns only the self block** (plus the boundary line). The rule lines are `Cortex.ruleLines`, and `cortex.persona(_:person:at:)` sets both fields. The reason is that `Persona` has separate `selfLines` and `ruleLines` fields. The block renders from the `Enduring` frozen at the last `.conversationStarted`, so `at` does not change the output.
5. **`Cortex.init` takes extra defaulted `carried:` and `session:`.** `carried` holds the persisted intentions, expectations, interests, misreads and open ruptures (§11: Enduring and Ongoing are loaded from SelfStore at launch); each reducer takes its part in `seed(from:)`. `session` (`SelfStore.nextSession()`) makes every launch a different random sequence.
6. **The substitution table always lands in the mood band.** §3.5's example `excited→skeptical` lands in the neutral band, which contradicts "nearest emotion in the mood band". Instead, `excited` becomes `worried` (negLow) or `grumpy` (negHigh). `happy→unimpressed` and `love→hurt` are kept as in §3.5.
7. **Note order in the cue is context, then aim**, as in the §6.1 example. When the budget is tight, the context note is still dropped first.
8. **Slots have caps per template** so that every rendered note is ≤ 30 tokens at `ceil(chars/3)`. For example, the recall gist is cut at a word boundary to 72 characters inside the note, and the misread slot to 11.
9. **Thinking aversion is never on the *first* sentence**, but it can fall on the last. "Never on the final sentence" is not knowable when a sentence starts streaming. TODO(0.5.2): the chunker must flag the last sentence.
10. **`Lesson.Situation.doInstead` templates are shorter** (for example "check if they're joking") so a lesson line fits the 70-token self block.
11. **The self block budget uses the worst-case estimator by default** (`ceil(chars/3)`). Lesson and capability lines therefore drop more often than they would with the real tokenizer. `render(count:)` accepts a real counter.
12. **`SelfStore` does not need a `people` table.** §10.1 says open *requires* `people`; with schema v2 nothing references it.
13. **No cascades, more CHECKs than §10.2 (schema v2):**
    - person rows have a plain `person_id` (no `REFERENCES people(id) ON DELETE CASCADE`), because DeeMemory deletes `people` rows when it merges; the app calls `merge` / `forgetPerson` / `forgetPeople(notIn:)` instead (SELF.md §10.3 amended);
    - `digest`'s primary key is replaced by a unique index on `(day, ifnull(person_id,''))`, so the global row can have a NULL person;
    - extra length CHECKs cover subject, topic, why, expected, changed, reason and do_instead;
    - `apply` rolls back a single failing write instead of aborting the batch, and reports it (`ApplyResult.failed`, a DEBUG assertion).
14. **Golden fixtures store percept *descriptions*, not percepts.** `Appraisal` is not `Codable`, and user text must never be committed. The input timelines live in the Swift tests, and each fixture stores the description, the effects and the state slice per step.
15. **`calmForThinking` is duplicated from DeeFace** (it is internal there), and the same set is used.
16. **Reflex tracking and the reflex → signature-slot mapping live in `Cortex.ingest`.** No sub-reducer in §4.2 owns `reflex`. A fresh reflex is recognised by `MindSnapshot.reflexAt` (an additive DeeMind field), and lives 4 s from that stamp.
17. **`EmotionBand` puts `listening` and `asleep` in the neutral band.** They are app-driven and §3.5 does not list them.
18. **Gaze rows beyond the §5 list.** `deeThinking` → `.away` (0.6 s) is a priority-4 (Dee's turn) row, and an idle back-camera referent focus → `.examineBack` is a priority-6 (focus) row next to the sound side. Yielding counts as the user's turn (5).
19. **`Stance.resolve` arbitrates requests.** Gaze, face modifiers, mannerisms and uncertainty come from the reducers' requests by the §5 tables, not from a resolve-owned rule list; the expression precedence (§3.5) is unchanged. Ties go to the later request (the later reducer has seen more of the step).
20. **One RNG stream per reducer**, plus one for `Stance.resolve` and one for `NotePicker`, all from `baseSeed(enduring.seed, session)` (§4.2 threads one `Rand`). One reducer's extra draw no longer shifts any other's outcome or golden.
21. **`cue(at:)` returns `(cue, effects)`**, and `persona(_:person:at:)` is `mutating` (it records `promptPerson`). Issued-note bookkeeping is the owning reducer's `noteIssued` hook, not Cortex's.
22. **NotePicker keeps only the generic §6.3 rules.** The gag's 0.4 × playfulness draw and playGate move to the raiser (Learner), like the other reducer-specific gates (§6.2 "only if confidence ≥ 0.5 × gain", deixis thresholds).
23. **Conversation reset is per reducer.** `.conversationStarted` resets go through each owner's `conversationStarted` hook after the pipeline, and note candidates are cleared *before* the pipeline (so a reducer may raise a note on that step). The self block freezes after the pipeline.
24. **FloorKeeper review fixes.** The reconciled tag is capped at 15 s past its latest sentence (refreshed per sentence; a lingering tag is never refreshed by the next reply); `.deeSpeaking` falls back to idle after 20 s without a sentence; a `.deeSaid` arriving while yielding is ignored; a barge-in during the user's own turn (a partial came first) keeps the user's floor and only emits the cut-off and `.stopSpeaking`.
25. **Identity hysteresis.** Interpreter clears `person` only after 3 non-matching identifications in a row (one bad frame no longer flaps it); a confident match switches at once. The full §10.3 gate (name confirmation or ≥ 3 matches) stays a 0.5.3 TODO.
26. **Follow-through checks only the intentions aimed this turn** (IntentionBoard remembers the ids `noteIssued` marked), so a later mention of an older issued intention is not counted as follow-through.

27. **Integration pass (all eight reducers together, §12.4 scenarios).** Fixed while wiring the reducers through the full stack:
    - `Cortex.prefetch(episodes:)` (EpisodeBuilder's gists were unreachable from the app);
    - `flush` closes the open episode and counts taste exposures (a relaunch used to drop the whole last conversation: no episode, no digest, no taste evidence);
    - EpisodeBuilder never recalls an episode on a topic under the speaker's user boundary, and NotePicker drops any note naming one (a "we talked about job" recall reached the cue the day after "don't ask me about my job");
    - Learner never touches interests or taste exposures for a boundary topic (it stored `interest(job)` from the boundary sentence itself);
    - Attention treats a look request ("look what I made") as a strong deixis trigger while something is in view, so focus moves to the shown thing and the examine beat runs (§1 walk-through); without visual context it stays a figure of speech;
    - a show-and-tell beat chain closes the segment only when it is already salient (the beats end during Dee's first reply; closing there dropped the showing and stored the explanation as a plain "we talked about" episode);
    - IntentionBoard consumes the director's arrival greeting when Learner performs the morning / welcome-home ritual (Dee said the ritual line and then greeted again);
    - Listener's preview adds a small tone lexicon (the lexicon-only appraiser hears no everyday "lovely" / "awful", so the preview face stayed neutral) and reuses the appraisal of a repeated partial; the text is dropped at the end of the turn;
    - Interpreter's topic phrase stops at a past-tense verb ("my cat knocked over…" → "cat");
    - `selfLines` measures the block with `tokenCounter` (the app's real tokenizer was never used for it).

## Open items

- **Appraisal ordering (§4.3, review 2g).** The app hands the appraisal to `Mind.hear` / `Mind.react` before `Cortex.step`, so a lesson cannot soften it after the fact. `Cortex.adjust(_:)` (each reducer's `adjust` hook) is the agreed pre-commit pass; using it needs a DeeMind entry point that appraises heard text without committing (or commits a given appraisal for it, keeping the daily aggregate). Owner: DeeMind + Interpreter, before 0.5.3 scenario 4.
- **Face modifiers in DeeFace.** `readyFace`, `lidSoften` and `tilt` reach `ExpressionIntent`; `FaceInputs` has no inputs for them yet (owner: DeeFace, with Listener 0.5.2).

## Tests (`swift test --filter DeeSelfTests`: 452 tests, about 85 s wall on an M3 Ultra)

The time is dominated by `AgreementPropertyTests` (§12.3 fixes it at 10,000 × 200 = 2 M Cortex steps, ≈ 1,300 CPU-s in a debug build, 16 parallel chunks ≈ 80 s wall); about a third of a step is DeeMind's lexicon appraiser in Listener's preview. Everything else finishes within 20 s.

| Suite | Owner | What it covers |
|---|---|---|
| MannerismPinTests | core | Literal pin of the 17 `Performance` raw values; `calmForThinking` compared with DeeFace's source |
| FloorKeeperTests | FloorKeeper | Turn cycle, stale pause, barge-in and cut-off note (once), Dee interrupts (1 s window), failsafes, first-sentence aversion at about 30%; review fixes (barge-in after a partial keeps the user's floor, late sentence ignored, tag cap and refresh, speaking timeout, lingering tag); gaze requests; bands, substitution, exemptions; goldens turn-cycle / reconciliation / barge-in |
| ListenerTests, AttentionTests, InterpreterTests, RepairKeeperTests, IntentionBoardTests, BeatsTests, EpisodeBuilderTests, LearnerTests | each reducer | Basic behaviour, requests, hooks (seed, conversation reset, noteIssued bookkeeping, merge/forget), identity hysteresis, boundary reminder, aimed-this-turn follow-through, beat once per step; their goldens |
| StanceTests | core | Precedence table; thinking face only when calm; tag expiry; intensity and boost; listen only in the user's turn; playGate; gaze arbitration by priority (ties → later); never `.wander` in the user's turn (whole pipeline); face modifiers per field; uncertainty max; mannerism ranks; no 3 in a row; weights |
| ProjectionTests | core | Face and voice agree for every emotion; listen caps; lids; idle director; pass-through |
| CueWriterTests | core | Mood parity with `MindSnapshot.cue`; every template ≤ 30 tokens; cue ≤ 120; fit and drop order; NotePicker generic rules; no reproach words |
| SelfSeederTests | core | Determinism; values; humour; signature; capability facets; innate tastes; golden `SelfSeeder/default-seed7.json` |
| SelfBlockTests | core | Budgets; drop order; per-person lines; frozen per conversation; system prompt byte-identical across turns while the per-turn cue changes |
| SelfStoreTests | core | Seeds once; round-trip of every `SelfWrite`; reopen; no cascade on a `people` delete; `forgetPerson`; orphan sweep; `merge` clash rules (checked against `Moment.merge`); v1 → v2 migration keeps rows; newer schema refused; `forgetAll` == `keepingSeeded()`; `forget(subject:)` across every table; `recalled`; identity re-derived from the stored seed; carried misreads window; sessions; failed writes reported |
| CortexTests | core | Pipeline order; newest-sequence rule; monotonic clock; reflex 4 s + reaction, restamped reflexes; cue parity; issued-note effects; `cueText` queueing; no third issue across relaunches; initiative; per-reducer streams; sessions; conversation hooks; persona recording; signals exactly once; forget / forgetAll / merge / forgetPerson in RAM; deterministic replay |
| GoldenTraceTests | core | Harness; Cortex `laugh-while-upset` |
| AgreementPropertyTests | core | 10,000 seeded sequences × 200 steps; the §12.3 invariants at every step |
| ScenarioTests | integration | §12.4 multi-session scenarios through a real in-memory `Mind`, the full Cortex, an in-memory `SelfStore` and a relaunch between sessions (`SimDee`, `SimClock`): follow-through and the ignored aim; no penalty or guilt after 7 + 5 days away; misread → lesson → no more guessing; show-and-tell remembered; user boundary across conversations; rudeness → boundary → apology → reconciliation; taste reveal over weeks; gag callback then retirement; good-morning ritual; coordinated listening; identity over 60 days with 3 people; deterministic replay. Every persisted write is checked for 5-word transcript fragments. `DEE_SCENARIO_LOG=1` prints the cues |
| PolicyTests | core | Lint (clock, randomness, UUIDs, `.now`, `Hasher`, unsorted Dictionary/Set iteration) with a planted-violation canary; no DeeFace/DeeVoice/DeeSense import; 1,000-utterance no-transcript fuzz over every persisted effect (cue and flush included) with a planted-leak canary |
