import AVFAudio
import DeeCore
import Foundation
import Testing
@testable import DeeLocal

// Mode 3's on-device voice for a persona (persona spec §3 "Mode-3 voice algorithm",
// §11.10 DeeVoiceTests / DeeLocalTests), on a fake voice list.
@Suite struct PersonaVoicePickerTests {
    typealias C = PersonaVoicePicker.Candidate
    static let voices: [C] = [
        C(identifier: "samantha.default", name: "Samantha", language: "en-US", quality: 0, gender: .female),
        C(identifier: "ava.enhanced", name: "Ava", language: "en-US", quality: 1, gender: .female),
        C(identifier: "zoe.enhanced", name: "Zoe", language: "en-US", quality: 1, gender: .female),
        C(identifier: "allison.premium", name: "Allison", language: "en-US", quality: 2, gender: .female),
        C(identifier: "evan.enhanced", name: "Evan", language: "en-US", quality: 1, gender: .male),
        C(identifier: "tom.default", name: "Tom", language: "en-US", quality: 0, gender: .male),
        C(identifier: "daniel.premium", name: "Daniel", language: "en-GB", quality: 2, gender: .male),
        C(identifier: "bells.novelty", name: "Bells", language: "en-US", quality: 2, gender: nil, novelty: true),
        C(identifier: "robot.premium", name: "Zoe", language: "en-US", quality: 2, gender: nil),
        C(identifier: "me.personal", name: "My Voice", language: "en-US", quality: 2, gender: .female, personal: true),
        C(identifier: "com.apple.eloquence.en-US.Eddy", name: "Eddy", language: "en-US", quality: 2, gender: .male),
        C(identifier: "amelie", name: "Amélie", language: "fr-CA", quality: 2, gender: .female),
    ]

    @Test func qualityFirstThenTheNameList() throws {
        let mira = try #require(PersonaCatalog.mira.appleVoice)
        // Allison is premium, so it beats the enhanced Zoe even though Zoe is first on Mira's list.
        #expect(PersonaVoicePicker.pick(Self.voices, rule: mira)?.identifier == "allison.premium")
        let noPremium = Self.voices.filter { $0.identifier != "allison.premium" }
        #expect(PersonaVoicePicker.pick(noPremium, rule: mira)?.identifier == "zoe.enhanced", "same quality: Mira's list order")
    }

    @Test func genderIsTheRulesAndNoveltyPersonalEloquenceAndOtherLanguagesAreOut() throws {
        let atlas = try #require(PersonaCatalog.atlas.appleVoice)
        #expect(PersonaVoicePicker.pick(Self.voices, rule: atlas)?.identifier == "daniel.premium")
        let picks = Self.voices.compactMap { v in PersonaVoicePicker.pick([v], rule: PersonaCatalog.nova.appleVoice!) }
        #expect(!picks.contains { $0.novelty || $0.personal || $0.isEloquence || $0.language == "fr-CA" })
    }

    /// `.any` accepts male or female voices, never `.unspecified` (mostly novelty voices).
    @Test func anyNeverPicksUnspecified() throws {
        let nova = try #require(PersonaCatalog.nova.appleVoice)
        let onlyUnspecified = Self.voices.filter { $0.gender == nil }
        #expect(PersonaVoicePicker.pick(onlyUnspecified, rule: nova) == nil)
        let pick = try #require(PersonaVoicePicker.pick(Self.voices, rule: nova))
        #expect(pick.gender != nil)
        #expect(pick.identifier == "allison.premium", "premium first; then Nova's names")
        let enhanced = Self.voices.filter { $0.quality < 2 }
        #expect(PersonaVoicePicker.pick(enhanced, rule: nova)?.identifier == "zoe.enhanced")
    }

    static func eq(_ a: (pitch: Float, rate: Float), _ pitch: Float, _ rate: Float) -> Bool { a.pitch == pitch && a.rate == rate }

    @Test func pitchAndRatePerPreset() {
        #expect(Self.eq(PersonaVoicePicker.shape(rule: nil, voiceGender: .female), PersonaVoicePicker.classicPitch, AVSpeechUtteranceDefaultSpeechRate))
        #expect(Self.eq(PersonaVoicePicker.shape(rule: PersonaCatalog.mira.appleVoice, voiceGender: .female), 1.06, 0.52))
        #expect(Self.eq(PersonaVoicePicker.shape(rule: PersonaCatalog.atlas.appleVoice, voiceGender: .male), 0.92, 0.47))
        // `.any`: the pitch follows the gender of the voice that was picked.
        #expect(Self.eq(PersonaVoicePicker.shape(rule: PersonaCatalog.nova.appleVoice, voiceGender: .female), 0.90, 0.50))
        #expect(Self.eq(PersonaVoicePicker.shape(rule: PersonaCatalog.nova.appleVoice, voiceGender: .male), 1.12, 0.50))
        #expect(Self.eq(PersonaVoicePicker.shape(rule: PersonaCatalog.haven.appleVoice, voiceGender: .male), 1.08, 0.46))
        #expect(Self.eq(PersonaVoicePicker.shape(rule: PersonaCatalog.haven.appleVoice, voiceGender: .female), 0.90, 0.46))
    }

    @Test func downloadHintOnlyWhenNothingBetterThanDefault() throws {
        let rio = try #require(PersonaCatalog.rio.appleVoice)
        #expect(PersonaVoicePicker.downloadHint(Self.voices, rule: rio) == nil, "an enhanced Evan is there")
        let poor = [C(identifier: "tom.default", name: "Tom", language: "en-US", quality: 0, gender: .male)]
        #expect(PersonaVoicePicker.downloadHint(poor, rule: rio) == "Settings → Accessibility → Spoken Content → Voices → English → Evan (Premium)")
    }

    /// The on-device voice's base pitch is the persona's (Classic: the 1.15 lift).
    @Test func onDeviceVoiceTakesThePersonasPitch() {
        let classic = OnDeviceVoice(voiceIdentifier: nil)
        #expect(classic.basePitch == PersonaVoicePicker.classicPitch && classic.baseRate == AVSpeechUtteranceDefaultSpeechRate)
        let atlas = OnDeviceVoice(voiceIdentifier: nil, persona: PersonaCatalog.atlas.appleVoice)
        #expect(atlas.basePitch == 0.92 && atlas.baseRate == 0.47)
        let d = SpeechDelivery(instructions: "", speed: 1)
        #expect(OnDeviceVoice.shape(d, basePitch: 0.92, baseRate: 0.47).pitch == 0.92)
    }
}
