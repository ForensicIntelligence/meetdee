import DeeCore
import Foundation
import Testing
@testable import DeeSelf

@Suite struct ProjectionTests {
    @Test func faceAndVoiceReadTheSameEmotion() {
        for e in Emotion.allCases {
            let s = Stance(expression: e, intensity: 0.7, regard: 0.3, energy: 0.6, age: 12)
            #expect(Projection.expression(s).emotion == e)
            #expect(Projection.voice(s).emotion == e)
            #expect(Projection.voice(s).age == 12)
            #expect(abs(Projection.voice(s).pitchScale - (1 + 0.08 * 0.2)) < 1e-12)
            #expect(Projection.expression(s).regard == 0.3)
        }
    }

    @Test func listenFieldsOnlyInUserTurnAndCapped() {
        let preview = ListenPreview(valence: -2, intensity: 0.9, signSince: Kit.t0)
        var s = Stance(expression: .listening, floor: .userSpeaking(since: Kit.t0), listen: preview)
        #expect(Projection.expression(s).listenValence == -1)
        #expect(Projection.expression(s).listenIntensity == 0.5)
        s.floor = .deeSpeaking(since: Kit.t0)
        #expect(Projection.expression(s).listenIntensity == 0)
        #expect(Projection.expression(s).listenValence == 0)
    }

    @Test func lidsAndIdleDirector() {
        var s = Stance(gaze: GazeIntent(target: .examineBack, hold: 1))
        #expect(Projection.expression(s).lidNarrow == Projection.examineLids)
        #expect(Projection.expression(s).idleDirector)
        s.gaze = GazeIntent(target: .user, hold: 1)
        #expect(Projection.expression(s).lidNarrow == 0)
        s.beatStep = BeatStep(gaze: .user, duration: 1)
        #expect(!Projection.expression(s).idleDirector)
        s.beatStep = nil
        s.floor = .deeThinking(since: Kit.t0)
        #expect(!Projection.expression(s).idleDirector)
    }

    @Test func gazeAndMannerismPassThrough() {
        let s = Stance(gaze: GazeIntent(target: .side(0.4), hold: 1.2), mannerism: .wink)
        #expect(Projection.gaze(s) == GazeIntent(target: .side(0.4), hold: 1.2))
        #expect(Projection.mannerism(s) == .wink)
    }
}
