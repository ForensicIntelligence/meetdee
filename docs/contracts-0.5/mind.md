# DeeMind — v0.5 contract addendum: appraise, adjust, then commit

**Developer:** Forensic Intelligence

Closes the self.md open item "Appraisal ordering (§4.3, review 2g)". The other v0.5
DeeMind changes (`CuriosityDirector.candidates` / `commit` / `avoid`, `Appraisal.internal`,
no neglect penalty) are in `mindcore.md`.

All changes are additive. `Mind.hear(_:prosody:at:)`, `Mind.react(_:at:)` and
`Appraiser.appraise(_:prosody:)` keep their signatures and their exact behaviour
(pinned by `MindPreviewTests.previewThenCommitEqualsHear` and
`evaluateThenRecordIsExactlyAppraise`; every existing DeeMind test passes unchanged).

## `Appraiser`

```swift
public struct Footprint: Sendable, Equatable   // opaque: prosody sample + content-word set
public func evaluate(_ text: String, prosody: Prosody? = nil) -> (appraisal: Appraisal, footprint: Footprint)  // pure
public mutating func record(_ footprint: Footprint)   // voice baseline update + repetition window
public func peek(_ text: String, prosody: Prosody? = nil) -> Appraisal   // = evaluate(…).appraisal
// unchanged: appraise(t, p) ≡ { let (a, f) = evaluate(t, p); record(f); return a }
```

`peek` is the cheap throwaway appraisal the Listener's preview needs (SELF.md §7.2): no
baseline drift and no repetition build-up however often a partial is re-appraised.

## `Mind`

```swift
public struct HeardPreview: Sendable, Equatable {
    public let appraisal: Appraisal            // what the utterance would do, unadjusted
    // internal: footprint, serial, issuing Mind
}
public func preview(_ text: String, prosody: Prosody? = nil) -> HeardPreview
@discardableResult
public func commit(_ preview: HeardPreview, as appraisal: Appraisal? = nil, at now: Date = Date()) -> MindSnapshot
@discardableResult
public func hear(_ text: String, prosody: Prosody? = nil, at now: Date = Date(),
                 adjust: @Sendable (Appraisal) -> Appraisal) -> (appraisal: Appraisal, snapshot: MindSnapshot)
public var voiceBaseline: Appraiser.VoiceBaseline { get }
public static let maxOutstandingPreviews: Int  // 8
```

Semantics:
- **`preview`** commits nothing: feelings, personality, counters, the voice baseline, the
  repetition window, the reflex, the store and the snapshot `sequence` are unchanged.
- **`commit(p, as: a)`** absorbs `a` (default `p.appraisal`) exactly as `hear` does: the
  reflex is judged on it, state and the **daily aggregate** (interactions, kind / hostile,
  regard) are written in one transaction, judged on the committed appraisal, and a new
  snapshot is returned. It takes no text. It then applies `p`'s footprint to the appraiser
  (voice baseline, repetition window): the appraiser is text-driven, so it moves the same
  way whether or not the appraisal was adjusted.
- **`preview` + `commit(p)`** (unadjusted, same `at`) is byte-for-byte `hear(text, prosody:, at:)`:
  same appraisal, snapshot (incl. reflex, `reflexAt`, `sequence`), state, baseline and daily rows.
- **`hear(_:prosody:at:adjust:)`** = preview, `adjust`, commit; returns the adjusted appraisal.
- **Ordering:** another `hear` / `react` / `tick` between preview and commit is fine. The
  footprint is applied on top (in commit order); the preview's novelty / repetition were
  judged against the window at preview time.
- **Misuse guards:** the footprint is applied only for a preview this `Mind` issued and has
  not committed yet, among the latest 8. A second commit of the same preview, a preview
  from another `Mind`, one older than 8 newer previews, or one from before `reset` still
  absorbs its appraisal (feelings, counters, daily row) but never records the utterance
  in the appraiser twice.
- **Privacy:** a `HeardPreview` holds the utterance's content words (inside the opaque
  footprint), RAM only, like the appraiser's own window. Never persist, log or forward it;
  hand on only `appraisal` (e.g. `Percept.heard(…, appraisal:)`). Nothing new is stored.

## App wiring (SELF.md §4.3; scenario 4 `tookLiterally`)

```swift
// .heard(text):
let preview = await mind.preview(text, prosody: prosody)
let appraisal = cortex.adjust(preview.appraisal)                 // reducers' pre-commit pass
let snap = await mind.commit(preview, as: appraisal, at: now)
let effects = cortex.step(.heard(text: text, durationS: d, loudnessVsBaseline: l, appraisal: appraisal),
                          mind: snap, at: now)
// or in one call (Cortex is a value type, so capture a copy):
let c = cortex
let (appraisal, snap) = await mind.hear(text, prosody: prosody, at: now) { c.adjust($0) }
```

`Cortex.adjust` is pure and reads only `moment`, so capturing a copy before the `await`
is equivalent. A `tookLiterally` lesson that halves hostility gives a visibly smaller
anger rise on the snapshot (pinned by `MindPreviewTests.softenedTeaseRaisesLessAnger`).

## Tests (`swift test --filter MindPreviewTests`, 15 tests)

evaluate + record ≡ appraise over a 20-utterance script with prosody; `peek` / `evaluate`
change nothing; preview commits nothing (state, baseline, sequence) and leaves a twin's
next `hear` identical; preview + commit ≡ hear (appraisal, snapshot, reflex, state,
baseline, daily rows byte-equal, reopen); `hear(adjust: { $0 })` ≡ `hear`; softened tease →
less anger, higher regard, same appraiser drift; `hear(adjust:)` ≡ preview + commit(as:);
the daily row judges the committed appraisal and stores no text; any appraisal (e.g.
`.internal(relief:)`) can be committed for heard text; interleaved hear keeps both
footprints in commit order; double commit, stale preview, foreign preview, preview before
reset never double-record; deterministic replay.
