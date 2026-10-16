# CONTRACTS-0.5 addendum: DeeVoice (SELF.md §7.1, §2)

**Developer:** Forensic Intelligence

All changes are additive. No public API was renamed or removed.

## VoiceEvent (new case)

```swift
/// The user paused mid-turn (≥ 150 ms; re-sent during the same pause only when the
/// estimate moves by ≥ 0.01). Both values 0…1.
case pause(turnEnd: Double, hesitation: Double)
```

**Integrator note:** `DeeModel.handle(_ event: VoiceEvent)` switches exhaustively, so it
needs a `case .pause(let turnEnd, let hesitation):` arm (route it to `cortex.step(.pause(...))`,
or `break` until the Listener lands).

## VoiceService

```swift
public var pauseScale: Double            // get/set, clamped 0.7…1.6; 1 = typical
public var turnPredictionEnabled: Bool   // default true; false = v0.4 fixed 0.8 s · pauseScale hold, no .pause
```

Push the stored `SocialProfile.pauseScale` when someone is identified (`.setPauseScale`).
Clipped-speaker recovery: `voice.pauseScale += 0.1`. Read it back after a `.heard` to
persist what was learned (it adapts after every turn that had within-turn pauses).

## ListeningCore

```swift
public var pauseScale: Double                         // same semantics as above
public var turnPredictionEnabled: Bool
public var turnEstimate: TurnPredictor.Estimate? { get }   // latest estimate this turn
public var quietInterval: Double { get }              // the endpoint's current hold
```

## EndpointDetector

```swift
public static let quietIntervalRange: ClosedRange<Double>   // 0.35...2.5
public mutating func setQuietInterval(_ seconds: Double)    // clamped; non-finite ignored
```

## TurnPredictor (new, `public struct`, Sendable)

```swift
public struct Features { lexComplete, lexTrailing, filler, lexQuestion, f0Fall, f0Rise, f0Flat, energyDrop, short: Double; var vector: [Double] }
public struct Weights  { bias -0.2, lexComplete 1.2, lexTrailing -2.5, filler -1.5, lexQuestion 0.5, f0Fall 0.9, f0Rise 0.6, f0Flat -0.5, energyDrop 0.5, short -0.4; static let standard }
public struct Estimate { turnEnd, hesitation, hold: Double; features: Features; pause: Double }

static func turnEnd(_: Features, weights: Weights = .standard) -> Double
static func hold(turnEnd:hesitation:pauseScale:) -> Double
static func lexical(_ text: String) -> Features
static func hesitation(text:pause:speechRate:baselineRate:) -> Double
static func fillerRate(_:) / hasRestart(_:) / words(_:) / isFiller(_:) / isTrailing(_:)
static let trailingWords, fillerWords, holdRange (0.35...2.5), defaultHold (0.8), …

var weights: Weights
var baselineRate: Double?                 // learned words/s
var personMeanSemitones: Double? { get }
var last: Estimate? { get }
var voicedTime: Double { get }
var withinTurnPauses: [Double] { get }
func stableText(at:) -> String
mutating func partial(_:at:)
mutating func frame(sounding:db:f0Hz:duration:at:)
mutating func update(at:pauseScale:) -> Estimate?
func estimate(stableText:pause:pauseScale:) -> Estimate
mutating func endTurn(text:) -> [Double]
mutating func resetTurn() / resetSpeaker()
```

`lexQuestion` (stable text ends in "?" after ≥ 2 real words, +0.5) is the only
addition to the SELF.md §7.1 feature table.

## PauseScaleLearner (new, `public struct`, Sendable, Equatable)

```swift
init(scale: Double = 1, observations: Int = 0)
var scale: Double { get }          // (10·base + n·ewma) / (10 + n), clamped 0.7…1.6
var ewma: Double? { get }          // EWMA α = 0.1 of (median within-turn pause / 0.5 s)
var observations: Int { get }
mutating func observe(pauses: [Double])
mutating func set(_ value: Double)
```

## SpeechText / SentenceChunker

```swift
public static func SpeechText.dropAsides(_ text: String) -> String
```

`SpeechText.clean` and `SentenceChunker` (streaming, across fragment splits) now drop
`( … )` / `（ … ）` asides (an unclosed `(` drops the rest of the reply) and `<…>` tags;
state/reasoning blocks (`<dee_state>`, `<think>`, `<note>`, any tag name containing
"state"/"think", …) are dropped with their whole body. Kept literal: emoticons `:(` `;)`,
markdown link targets `](url)`, `3 < 4`, `<3`. Behaviour change: `<think>x</think>Okay.`
now speaks "Okay." (was "x Okay.").

## ProsodyAccumulator

`add(frame:sampleRate:voiced:)` now returns the frame's f0 (`@discardableResult Double?`),
so TurnPredictor reuses the existing YIN pass.
