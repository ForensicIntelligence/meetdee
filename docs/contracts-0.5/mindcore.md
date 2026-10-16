# DeeMind + DeeCore — v0.5 contract addendum

**Developer:** Forensic Intelligence

All changes are additive. No public API was renamed or removed. With the new
fields at their defaults, every existing call site behaves exactly as in v0.4
(the system prompt is byte-identical; `nextPrompt` keeps its behaviour; existing
DeeMind/DeeCore tests pass unchanged).

## DeeMind

### `CuriosityDirector`

```swift
public var avoid: Set<String>                     // default []: subjects not to bring up
public func avoids(_ text: String) -> Bool        // whole-word match, plural s/es tolerated, case-insensitive

public mutating func candidates(at now: Date, snapshot: MindSnapshot,
                                userPresent: Bool, busy: Bool) -> [Candidate]   // best first; consumes nothing
@discardableResult
public mutating func commit(_ candidate: Candidate, at now: Date, asReply: Bool = false) -> String

public struct Candidate: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case callout, greeting, sound, sight, touch, music, human, game, thought, feeling
    }
    public var kind: Kind
    public var subject: String   // cooldown key: "greet", "sound:doorbell", "thing:guitar", "human:food", …
    public var label: String     // bare topic: "doorbell", "guitar", "food"
    public var prompt: String    // the full "( … )" stage direction, exactly as nextPrompt emits it
    public var priority: Double  // 0…1
    public var urgency: Double   // 0…1; 1 = due now; 0 while busy / in a quiet window
    public init(kind:subject:label:prompt:priority:urgency:)
}

// unchanged signature, now a wrapper over the same builders:
public mutating func nextPrompt(at:snapshot:userPresent:busy:) -> String?
```

Semantics:
- **Priority tiers:** callout 1 · greeting 0.95 · alarming sound 0.9 · crying 0.88 ·
  other sound 0.8 · animal/awe sight 0.75 · fresh sight 0.7 · touch 0.6 · general
  topics `min(0.55, 0.1 + 0.1 × moodWeight)` (sight in memory 0.5, music 0.35,
  "glad of your company" 0.3, each human/game/thought topic ≈ 0.13–0.3).
- **Urgency:** stimuli 1; general topics `clamp01(elapsed / backedOffGap)`; all × 0
  while `busy`, within 3 s of speech, or within 6 s of the last prompt. Priority never
  depends on the gate, so a caller may use candidates as reply aims on a user turn.
- Ordering: priority desc, then urgency desc, then subject asc. One entry per subject.
- Same rules as `nextPrompt`: cooldowns (20 min / greeting 10 min), freshness, sight
  pacing, back-off (after 3 unanswered only sights and sounds), empty room → call-out
  only, `avoid`.
- `avoid` exemptions: greeting, call-out, alarming sounds.
- Phrasing in `candidates` comes from a copy of the seeded RNG: repeated calls with no
  commit in between return equal arrays. For a single stimulus `nextPrompt` returns
  the top candidate's `prompt` byte-for-byte.
- `commit`: puts the subject on cooldown, consumes its stimulus (sound, sight, touch,
  arrival), starts prompt spacing, and counts as unanswered unless `asReply: true`
  or the kind is `.callout`. It advances the RNG by one draw.
- Reunion greetings say "glad they're back" / "happy to see them again"; no
  "lonely without them".

### `Appraisal`

```swift
public var isInternal: Bool   // default false
public var relief: Double     // 0…1, default 0
public var pride: Double      // 0…1, default 0
public static func `internal`(relief: Double = 0, pride: Double = 0) -> Appraisal   // call as .internal(relief:)
```

- `social = false`, `aimedAtDee = false`, `novelty = 0`, `valence = min(1, 0.4·(relief + pride))`; inputs clamped.
- Engine (non-social path): relief → fear −0.7·relief·fear, sadness −0.3·relief·sadness,
  joy +0.2·relief·(1−joy); pride → joy +0.25·pride·(1−joy), interest +0.1·pride·(1−interest),
  boredom −0.1·pride. Never touches affection, trust, loneliness, counters or personality.
- Reflex: `relief ≥ 0.2 && relief ≥ pride` → `.relieved`; else `pride ≥ 0.2` → `.proud`
  (`.shy` if effective confidence < 0.3); else nil.
- Use via `Mind.react(.internal(relief: 0.8), at:)`.

### `EmotionEngine` (confirmed, no API change)

The neglect rule is gone (no `neglectThreshold` / `neglectAffectionPerDay` /
`neglectAffectionFloor`). While `!userPresent`, affection and trust use
`x = max(x, base + (x − base)·0.5^(dt/h))`: they only relax upward. Loneliness still
grows and feeds only reunion joy and the urge to talk.

## DeeCore

### `Persona`

```swift
public var selfLines: [String]   // default []
public var ruleLines: [String]   // default []
public init(name: String = "Dee", userName: String? = nil, memories: [String] = [],
            selfLines: [String] = [], ruleLines: [String] = [])
```

`systemPrompt` inserts `selfLines`, then `ruleLines`, right after the
"Personality: …" line (line 2), one line each: newlines inside an entry become spaces,
entries are trimmed, and blank entries are skipped. With both empty the prompt is
byte-identical to v0.4 (pinned by `V05CoreTests`). Set them only at `newConversation`
(the system prompt is frozen per conversation).

### Cue leaks (dev-only; `CueLeak` / `CueLeakWatch` since 0.6)

0.5 shipped this check inside the local model's output parser. 0.6 removed the local
model and kept the check as a standalone DeeCore type, fed with the realtime
transcript:

```swift
public enum CueLeak: Sendable, Equatable, Hashable {
    case stateTag               // "dee_state" anywhere in what she said
    case moodSentence           // "Toward your human:"
    case note(String)           // a watched note repeated verbatim (carries the note as given)
    public static let minimumNoteLength: Int   // 12 (shorter note bodies are ignored)
    public static func find(in reply: String, notes: [String] = []) -> [CueLeak]  // order: stateTag, moodSentence, notes
    public static func notes(inCue cue: String) -> [String]   // top-level "( … )" segments, parens kept
}
public struct CueLeakWatch {
    public init(notes: [String] = []), init(cue: String)
    public var notes: [String]                // setting it re-checks
    public mutating func feed(_ piece: String)
    public private(set) var text: String, leaks: [CueLeak]
    public var leaked: Bool
}
```

- Matching is case-insensitive, whitespace-collapsed, with typographic quotes
  straightened; a note matches with or without its parentheses.
- Purely diagnostic: nothing is filtered, and history is not modified. The brain keeps
  one watch per reply, made from that turn's cue.
