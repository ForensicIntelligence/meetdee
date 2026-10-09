# DeeFace — v0.5 contract addendum

All changes are additive. No public API was renamed or removed, and old call sites
produce exactly the same `FaceAnimator.target` as before (pinned by
`ListenPreviewTests.defaultsAreOff`).

## `FaceInputs` (new stored properties, all default 0 = off)

```swift
public var listenValence: Double    // −1…1. Read only while activity == .listening.
public var listenIntensity: Double  // 0…1. DeeSelf's Listener caps it at 0.5.
public var lidNarrow: Double        // 0…1 extra upper-lid drop on slab eyes (examineBack → 0.2).

public init(emotion:activity:lookAt:speechLevel:micLevel:reduceMotion:tint:mood:touchPoint:performance:
            listenValence: Double = 0, listenIntensity: Double = 0, lidNarrow: Double = 0)
```

Preview semantics (SELF.md §7.2, §3.5 rule 4):
- weight `w = clamp(intensity, 0, 1) × clamp(valence / 0.5, −1, 1)`; non-finite input → 0.
- `w > 0`: soft smile arcs (lower lid up to `0.4·w`, eyes lift and flatten, lens fades), colour leans toward happy's.
- `w < 0`: concerned lids (inner-raised slant `−30°·|w|`, upper lid `0.2·|w|`, droop, eyes drawn in, ears down, faint quiver), colour leans toward a cool pale blue (never green, so it cannot be mistaken for the regard tint).
- Applied only for `activity == .listening`, only to slab eyes (a glyph reflex like joy's `∩` is untouched), never touches gaze (mutual gaze holds). `tint` still overrides colour.
- Changing the preview does not trigger the emotion-change blink or re-roll per-occurrence variation; the springs just follow.

## Face modifiers: `readyFace`, `lidSoften`, `tilt` (closes the self.md open item)

```swift
public var readyFace: Double   // 0…1  ← DeeSelf ExpressionIntent.readyFace (Listener: turnEnd ≥ 0.6)
public var lidSoften: Double   // 0…1  ← ExpressionIntent.lidSoften (hesitation, listenHesitant beat)
public var tilt: Double        // −1…1 ← ExpressionIntent.tilt (pending question, hesitation)

public init(…, listenValence: Double = 0, listenIntensity: Double = 0, lidNarrow: Double = 0,
            readyFace: Double = 0, lidSoften: Double = 0, tilt: Double = 0)
public static let FaceAnimator.maxTiltDegrees: Double   // 10
```

The app's `Projector.swift` maps them 1:1 (`inputs.readyFace = intent.readyFace`, and so on);
the "ignored until DeeFace adds them" row in self.md is now a plain pass-through.

Semantics (`FaceAnimator.target(for:)`, after `lidNarrow`, in this order):
- **Inputs** are clamped (ready, soften 0…1; tilt −1…1); NaN / ±∞ count as 0. All three 0
  → the target is exactly the pre-0.5.x one for every emotion × activity (pinned by
  `FaceModifierTests.defaultsAreOffAndInert`).
- **Any activity but `.sleeping`** (sleeping ignores all three).
- **Ready face** `r`, per slab eye (weight × `1 − glyphAmount`): upper lid × `(1 − 0.6r)`,
  height × `(1 + 0.08r)`, width × `(1 + 0.04r)`, `dy − 0.06r` (eyes lift), gloss `+0.15r`;
  face: ears `+0.4r`, brightness `+0.05r`. A slight lift, not a new emotion: slant and
  lower lid are untouched.
- **Lid soften** `s`, per slab eye: upper lid `+0.22s` (≤ 0.85), slant × `(1 − 0.6s)`
  (relaxes toward level), radius `+0.06s` (≤ 0.5), height × `(1 − 0.04s)`, `dy + 0.02s`;
  face: brightness `−0.06s`. Unlike `lidNarrow` (a flat drop that keeps the scowl), it eases
  the expression. Ready and soften together partly cancel.
- **Tilt** `t`: `headTilt += 10°·t` (whole-face roll, added to the expression's own tilt;
  positive turns the same way as `curious`). Applies to glyph eyes too (it is the head).
- Glyph eyes (a live reflex) keep their shape; gaze is never touched; `tint` still wins.
- Changing a modifier does not trigger the emotion-change blink, re-roll variation or
  draw from the animator's RNG: the springs just follow (pinned by
  `FaceModifierTests.modifierChangesDoNotBlinkOrReroll`).

Visual check: `DEE_SNAPSHOT_DIR=<dir> swift test --filter FaceSnapshotTests/faceModifiers`
writes `modifier-*.png` and `sheet-modifiers.png` (listening face with ready 0.5/1,
soften 0.5/1, tilt ±1, soften+tilt; neutral, angry, sleepy and curious with one modifier each).

## `FaceAnimator` (new statics)

```swift
public static let listenValenceSaturation: Double   // 0.5
public static func listenPreviewWeight(valence: Double, intensity: Double) -> Double   // −1…1
```

## `FaceGaze` (new enum, in Performance.swift): look points for `Projector`

| `GazeIntent.Target` | `FaceInputs` |
|---|---|
| `.user` | `lookAt = <face position>` |
| `.point(p)` | `touchPoint = p` (or `lookAt`) |
| `.examineBack` | `lookAt = FaceGaze.examineBack` (0, 0.35), `lidNarrow = FaceGaze.examineLids` (0.2) |
| `.side(s)` | `lookAt = FaceGaze.side(s)` (x = 0.8·clamp(s), y = 0) |
| `.away` | `lookAt = FaceGaze.away` (−0.5, −0.55: up-left) |
| `.wander` | `lookAt = nil` |

```swift
public enum FaceGaze {
    public static let away: SIMD2<Double>
    public static let examineBack: SIMD2<Double>
    public static let examineLids: Double
    public static func side(_ s: Double) -> SIMD2<Double>
}
```

## `Performance` raw values (pinned)

`ListenPreviewTests.performanceRawValuesArePinned` fixes the exact order and spelling,
which `DeeSelf.Mannerism` mirrors:

`wink, blinkLeft, blinkRight, yawn, eyeRoll, doubleTake, nod, headShake, giggle, squint,
lookAround, startle, sigh, bounce, shiver, contentSquint, dizzySpin`
