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
