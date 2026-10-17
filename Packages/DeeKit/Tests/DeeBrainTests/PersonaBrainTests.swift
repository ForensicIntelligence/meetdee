import DeeCore
import DeeLocal
import DeeMind
import DeeRealtime
import DeeSelf
import DeeWake
import Foundation
import Testing
@testable import DeeBrain

// Persona presets in the brain (persona spec §11.4, §11.5, §11.6, §11.10 DeeBrainTests).
@Suite struct PersonaBrainTests {
    @Test func everyPresetVoiceIsARealtimeVoice() {
        for p in PersonaCatalog.all + [PersonaCatalog.classic] {
            #expect(CloudSettings.voices.contains(p.openAIVoice), "\(p.id): \(p.openAIVoice)")
            #expect(CloudSettings.voices.contains(p.openAIFallback), "\(p.id): \(p.openAIFallback)")
            #expect(CloudSettings(voice: p.openAIVoice).voice == p.openAIVoice, "\(p.id) must not fall back to marin")
        }
    }

    /// Regression (persona spec §11.4 "fix the bypasses"): the session config's
    /// instructions come from `DNAPrompt.sessionInstructions`, never a fixed constant.
    @Test func sessionConfigUsesThePersonasInstructions() {
        #expect(CloudSettings().sessionConfig().instructions == DNASessionInstructions.v11, "Classic: v11 byte-for-byte")
        for p in PersonaCatalog.all {
            let c = CloudSettings(voice: p.openAIVoice, persona: Persona(preset: p)).sessionConfig()
            #expect(c.instructions == DNAPrompt.sessionInstructions(preset: p))
            #expect(c.instructions.hasPrefix("You are \(p.name)"))
        }
    }

    @MainActor @Test func realtimeBrainOptionsDefaultToClassic() {
        #expect(RealtimeBrain.Options().persona == Persona())
        var o = RealtimeBrain.Options(timing: .realtime)
        o.persona = Persona(preset: PersonaCatalog.atlas)
        #expect(DNAPrompt.sessionInstructions(persona: o.persona).hasPrefix("You are Atlas, 44"))
    }

    @Test func everyDefaultWakePhraseIsValid() throws {
        for p in PersonaCatalog.all {
            let w = try WakePhrase(validating: p.wakePhraseDefault)
            #expect(w.text == "Hey \(p.name)", "\(p.id)")
        }
    }

    static func prefs() -> DeePrefs {
        let name = "dee-persona-\(UUID().uuidString)"
        return DeePrefs(defaults: UserDefaults(suiteName: name)!)
    }

    @Test func personaPrefsAndMigration() {
        let p = Self.prefs()
        #expect(p.personaID == nil && p.persona.isClassic, "an install from before the presets is Classic")
        #expect(!p.wakePhraseIsCustom, "no phrase saved: not custom")
        p.wakePhrase = try! WakePhrase(validating: "Hey Dee")
        #expect(!p.wakePhraseIsCustom, "Hey Dee is Classic's default")
        p.wakePhrase = try! WakePhrase(validating: "Computer")
        #expect(p.wakePhraseIsCustom, "a phrase of their own is kept on a switch")
        p.personaID = "mira"
        p.wakePhraseIsCustom = false
        #expect(p.persona.id == "mira" && !p.wakePhraseIsCustom)
        #expect(!p.voiceIsCustom(.openAI))
        p.setVoiceIsCustom(true, for: .openAI)
        #expect(p.voiceIsCustom(.openAI) && !p.voiceIsCustom(.lanEverything), "per mode")
        #expect(DeePrefs.fold("  hey   MIRA ") == "hey mira")
    }

    @MainActor @Test func standaloneHostSpeaksAsThePersona() async throws {
        let mind = try DeeMind.Mind(databaseURL: nil)
        let host = await StandaloneHost(mind: mind, persona: PersonaCatalog.nova)
        #expect(host.cortex.identity == PersonaCatalog.nova)
        #expect(host.persona == PersonaCatalog.nova)
        #expect(host.wakePhrase.text == "Hey Nova")
        let id = await mind.personaID
        #expect(id == "nova")
        #expect(host.cortex.moment.enduring.humour == .absurd)
        let classic = await StandaloneHost(mind: try DeeMind.Mind(databaseURL: nil))
        #expect(classic.cortex.identity.isClassic && classic.wakePhrase.text == "Hey Dee")
    }
}
