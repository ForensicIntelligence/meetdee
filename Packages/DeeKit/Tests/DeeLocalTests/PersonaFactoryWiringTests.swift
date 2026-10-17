import AVFoundation
import Foundation
import Testing
import DeeCore
import DeeVoice
@testable import DeeLocal

/// 0.6.0 wrap: the persona reaches the cascaded voice (modes 2 and 3) through
/// `ProviderFactory.make`: its speech style for the TTS instructions, and its on-device
/// pitch and rate for mode-3 clips. No network: the factory never contacts it.
@Suite struct PersonaFactoryWiringTests {
    let key = "sk-proj-" + String(repeating: "f", count: 40)   // fake
    var secrets: StaticSecrets { StaticSecrets([SecretAccount.openAI: key]) }
    let brain = EndpointConfig(baseURL: URL(string: "http://192.168.1.20:11434")!, model: "qwen3.8:27b-mlx-bf16")

    /// Regression: mode 2 spoke every persona with Classic Dee's "small, sweet, playful robot" style.
    @Test func mode2UsesThePersonasSpeechStyle() throws {
        let rio = PersonaCatalog.rio
        let rt = try ProviderFactory.make(.lanBrainOpenAIVoice(brain: brain), secrets: secrets, transport: .failing(),
                                          voiceStyle: rio.ttsStyle)
        #expect(rt.voiceStyle == rio.ttsStyle)
        #expect(rt.voiceStyle?.contains("small, sweet, playful robot") == false)
    }

    /// Classic Dee (no style passed) keeps today's style byte for byte.
    @Test func classicKeepsTodaysStyle() throws {
        let rt = try ProviderFactory.make(.lanBrainOpenAIVoice(brain: brain), secrets: secrets, transport: .failing())
        #expect(rt.voiceStyle == CascadeOptions(model: "x").voiceStyle)
        let mode1 = try ProviderFactory.make(.openAI(), secrets: secrets, transport: .failing(), voiceStyle: "ignored")
        #expect(mode1.voiceStyle == nil)
    }

    /// Regression: mode-3 clips on this iPhone ignored the persona's pitch and rate.
    @Test func mode3ClipsUseThePersonasPitchAndRate() throws {
        let config = ProviderConfig.lanEverything(brain: brain, stt: .onDevice, tts: .onDevice)
        let atlas = PersonaCatalog.atlas
        let rt = try ProviderFactory.make(config, secrets: StaticSecrets(), transport: .failing(),
                                          appleVoice: atlas.appleVoice)
        let clips = try #require(rt.clipRenderer as? OnDeviceClipRenderer)
        let live = OnDeviceVoice(voiceIdentifier: nil, persona: atlas.appleVoice)
        #expect(clips.pitch == live.basePitch)
        #expect(clips.rate == live.baseRate)
        #expect(clips.pitch != PersonaVoicePicker.classicPitch)
    }

    @Test func classicClipsAreUnchanged() throws {
        let config = ProviderConfig.lanEverything(brain: brain, stt: .onDevice, tts: .onDevice)
        let rule: AppleVoiceRule? = nil
        let classic = OnDeviceVoice(voiceIdentifier: nil, persona: rule)
        let rt = try ProviderFactory.make(config, secrets: StaticSecrets(), transport: .failing(),
                                          appleVoice: PersonaCatalog.classic.appleVoice)
        let clips = try #require(rt.clipRenderer as? OnDeviceClipRenderer)
        #expect(clips.pitch == classic.basePitch)
        #expect(clips.rate == classic.baseRate)
    }
}
