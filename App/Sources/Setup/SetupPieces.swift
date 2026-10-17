import AVFoundation
import DeeBrain
import DeeCore
import DeeLocal
import DeeWake
import SwiftUI

/// The wake phrase editor (onboarding and settings).
struct WakePhraseEditor: View {
    @Bindable var store: ProviderStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(store.persona.wakePhraseDefault, text: $store.wakePhraseText)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .font(.title3)
                .padding(12)
                .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 12))
                .accessibilityLabel("Wake phrase")
                .accessibilityIdentifier("wakePhraseField")
            if let error = store.wakePhraseError {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            } else if store.wakePhraseIsShort {
                Label(WakePhrase.shortPhraseWarning, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.yellow)
            }
            Text("One to four words, like “\(store.persona.wakePhraseDefault)”, “Computer” or “Okay Pixel”. \(store.persona.text.They("listen")) for it only on this iPhone — nothing is sent anywhere until \(store.persona.text.they("hear")) it. You can also say: “change your wake phrase to …”.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Use “\(store.persona.wakePhraseDefault)”") { store.wakePhraseText = store.persona.wakePhraseDefault }
                .font(.footnote)
                .disabled(store.wakePhraseText == store.persona.wakePhraseDefault)
        }
    }
}

/// Dee's voice: OpenAI voices (modes 1/2), the LAN TTS voice id, or the iPhone's voices.
struct VoicePicker: View {
    @Bindable var store: ProviderStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch (store.draft.mode, store.draft.tts) {
            case (.lanEverything, .onDevice):
                let p = store.persona
                let voices = OnDeviceVoices.best(for: p)
                let recommended = p.appleVoice.flatMap { PersonaVoicePicker.identifier(rule: $0) }
                Picker("Voice", selection: $store.draft.voice) {
                    Text("Best available").tag("")
                    ForEach(voices, id: \.identifier) { v in
                        Text("\(v.name) · \(OnDeviceVoices.quality(v))" + (v.identifier == recommended ? " · Recommended for \(p.name)" : ""))
                            .tag(v.identifier)
                    }
                }
                .pickerStyle(.inline)
                Text(p.appleVoice.flatMap { PersonaVoicePicker.downloadHint(PersonaVoicePicker.installed(), rule: $0) }
                        .map { "A better voice for \(p.name): \($0). Download it, then come back." }
                     ?? "Better voices: Settings › Accessibility › Spoken Content › Voices — download an Enhanced or Premium English voice, then come back.")
                    .font(.footnote).foregroundStyle(.secondary)
            case (.lanEverything, _):
                TextField("Voice name on your TTS server (e.g. af_heart)", text: $store.draft.voice)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(10).background(Color.white.opacity(0.08), in: .rect(cornerRadius: 10))
                Text("Leave empty for the server's default voice.").font(.footnote).foregroundStyle(.secondary)
            default:
                Picker("Voice", selection: $store.draft.voice) {
                    ForEach(CloudSettings.voices, id: \.self) { v in
                        Text(v.capitalized + Self.badge(v, store.persona)).tag(v)
                    }
                }
                .pickerStyle(.inline)
                Text("OpenAI voices. \(store.persona.text.Their) voice is AI-generated; \(store.persona.text.they)'ll say so the first time \(store.persona.text.they("speak")).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

extension VoicePicker {
    /// " (recommended for Mira)" on the persona's voice (Classic: marin and cedar, as before).
    static func badge(_ v: String, _ p: PersonaPreset) -> String {
        if p.isClassic { return v == "marin" || v == "cedar" ? " (recommended)" : "" }
        return v == p.openAIVoice ? " (recommended for \(p.name))" : ""
    }
}

enum OnDeviceVoices {
    /// English voices, premium first, then enhanced, then default.
    static func best(language: String = "en") -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
    }

    /// `best()`, the persona's voice gender first (then quality, then name).
    static func best(for p: PersonaPreset, language: String = "en") -> [AVSpeechSynthesisVoice] {
        let want: AVSpeechSynthesisVoiceGender? = switch p.appleVoice?.gender {
        case .female?: .female
        case .male?: .male
        default: nil
        }
        guard let want else { return best(language: language) }
        let all = best(language: language)
        return all.filter { $0.gender == want } + all.filter { $0.gender != want }
    }

    static func quality(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Default"
        }
    }
}
