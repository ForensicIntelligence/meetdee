import DeeCore
import DeeFace
import DeeMind
import DeeSelf
import DeeVoice

/// Maps DeeSelf's channel intents onto the face and the voice — mechanically,
/// 1:1 (docs/contracts-0.5/self.md, "App Projector.swift mapping"). All judgement
/// lives in `Stance.resolve`; nothing here decides anything.
enum Projector {
    static func face(_ s: Stance, faceAt lookAt: SIMD2<Double>?, touchPoint: SIMD2<Double>?) -> FaceInputs {
        let e = Projection.expression(s)
        let c = regardColor(e.regard)
        var inputs = FaceInputs(emotion: e.emotion, activity: activity(s), lookAt: gaze(s, faceAt: lookAt, touchPoint: touchPoint),
                                tint: FaceColor(c.r, c.g, c.b))
        inputs.listenValence = e.listenValence
        inputs.listenIntensity = e.listenIntensity
        inputs.lidNarrow = e.lidNarrow
        inputs.touchPoint = touchPoint
        if !e.idleDirector { inputs.mood = FaceMood(curiosity: 0, boredom: 0, playfulness: 0, energy: s.energy, affection: 0, arousal: 0) }
        return inputs
    }

    static func gaze(_ s: Stance, faceAt lookAt: SIMD2<Double>?, touchPoint: SIMD2<Double>?) -> SIMD2<Double>? {
        switch Projection.gaze(s).target {
        case .user: lookAt
        case .point(let p): SIMD2((p.x - 0.5) * 2, (p.y - 0.47) * 2)
        case .examineBack: FaceGaze.examineBack
        case .side(let x): FaceGaze.side(x)
        case .away: FaceGaze.away
        case .wander: nil
        }
    }

    static func activity(_ s: Stance) -> FaceActivity {
        switch s.floor {
        case .idle: .idle
        case .userSpeaking, .userPaused: .listening
        case .deeThinking: .thinking
        case .deeSpeaking: .speaking
        case .yielding: .listening
        }
    }

    static func voice(_ s: Stance) -> VoiceStyle {
        let v = Projection.voice(s)
        var style = VoiceStyle.forMood(emotion: v.emotion, age: v.age, energy: v.energy)
        style.pitch = Float(Double(style.pitch) * v.pitchScale)
        return style
    }

    static func performance(_ s: Stance, id: Int) -> PerformanceRequest? {
        guard let m = Projection.mannerism(s), let p = Performance(rawValue: m.rawValue) else { return nil }
        return PerformanceRequest(id: id, performance: p)
    }

    /// Red (−1) → yellow (0) → green (+1); same mapping as DeeMind's regard colour.
    static func regardColor(_ r: Double) -> (r: Double, g: Double, b: Double) {
        EmotionEngine.regardColor(r)
    }
}
