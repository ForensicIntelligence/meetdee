import DeeCore
import Foundation

// SELF.md §5 — neutral intents for every expressive channel, each a pure function of
// `Stance` only. The app's `Projector.swift` maps them 1:1 onto DeeFace / DeeVoice
// (`FaceInputs`, `VoiceStyle.forMood`, `PerformanceRequest`) with no conditionals.
// (Named `Projection` so it never clashes with the app's own `Projector`.)

/// Face channel → `FaceInputs`.
public struct ExpressionIntent: Sendable, Equatable {
    /// → `FaceInputs.emotion`.
    public var emotion: Emotion
    public var intensity: Double
    /// −1…1 → `FaceInputs.tint` (regard colour).
    public var regard: Double
    /// → `FaceInputs.listenValence` (−1…1; 0 outside the user's turn).
    public var listenValence: Double
    /// → `FaceInputs.listenIntensity` (0…0.5; 0 outside the user's turn).
    public var listenIntensity: Double
    /// → `FaceInputs.lidNarrow` (0.2 while examining the back camera).
    public var lidNarrow: Double
    /// The idle director may run (`floor == .idle && beat == nil`); otherwise the app
    /// suppresses `FaceInputs.mood` to neutral.
    public var idleDirector: Bool
    /// 0…1: the attentive "about to answer" face (Listener). → `FaceInputs` when DeeFace
    /// grows the input; until then the app ignores it.
    public var readyFace: Double
    /// 0…1: softer, lowered lids (hesitation). Same mapping note as `readyFace`.
    public var lidSoften: Double
    /// −1…1: tilt (pending question, hesitation). Same mapping note as `readyFace`.
    public var tilt: Double

    public init(emotion: Emotion, intensity: Double, regard: Double, listenValence: Double, listenIntensity: Double,
                lidNarrow: Double, idleDirector: Bool, readyFace: Double = 0, lidSoften: Double = 0, tilt: Double = 0) {
        self.emotion = emotion
        self.intensity = intensity
        self.regard = regard
        self.listenValence = listenValence
        self.listenIntensity = listenIntensity
        self.lidNarrow = lidNarrow
        self.idleDirector = idleDirector
        self.readyFace = readyFace
        self.lidSoften = lidSoften
        self.tilt = tilt
    }
}

/// Voice channel → `VoiceStyle.forMood(emotion:age:energy:)`, then pitch × `pitchScale`.
public struct VoiceIntent: Sendable, Equatable {
    public var emotion: Emotion
    public var age: Double?
    public var energy: Double
    public var intensity: Double
    /// 1 + 0.08·(intensity − 0.5).
    public var pitchScale: Double

    public init(emotion: Emotion, age: Double?, energy: Double, intensity: Double, pitchScale: Double) {
        self.emotion = emotion
        self.age = age
        self.energy = energy
        self.intensity = intensity
        self.pitchScale = pitchScale
    }
}

public enum Projection {
    public static let maxListenIntensity = 0.5
    public static let examineLids = 0.2

    public static func expression(_ s: Stance) -> ExpressionIntent {
        let listen = s.floor.isUserTurn ? s.listen : nil
        let lids: Double = if case .examineBack = s.gaze.target { examineLids } else { 0 }
        let idle: Bool = if case .idle = s.floor { s.beatStep == nil } else { false }
        return ExpressionIntent(emotion: s.expression, intensity: s.intensity, regard: s.regard,
                                listenValence: clamp(listen?.valence ?? 0, -1, 1),
                                listenIntensity: min(maxListenIntensity, clamp01(listen?.intensity ?? 0)),
                                lidNarrow: lids, idleDirector: idle,
                                readyFace: s.face.readyFace, lidSoften: s.face.lidSoften, tilt: s.face.tilt)
    }

    public static func voice(_ s: Stance) -> VoiceIntent {
        VoiceIntent(emotion: s.expression, age: s.age, energy: s.energy, intensity: s.intensity,
                    pitchScale: 1 + 0.08 * (s.intensity - 0.5))
    }

    /// → `FaceInputs.lookAt` / `touchPoint` via `DeeFace.FaceGaze`.
    public static func gaze(_ s: Stance) -> GazeIntent { s.gaze }

    /// → `PerformanceRequest(id: ++n, performance: Performance(rawValue: m.rawValue)!)`.
    /// Non-nil only on the step it fires.
    public static func mannerism(_ s: Stance) -> Mannerism? { s.mannerism }
}
