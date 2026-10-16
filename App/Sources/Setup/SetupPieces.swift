import AVFoundation
import DeeBrain
import DeeLocal
import DeeWake
import SwiftUI

/// The wake phrase editor (onboarding and settings).
struct WakePhraseEditor: View {
    @Bindable var store: ProviderStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(WakePhrase.defaultText, text: $store.wakePhraseText)
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
            Text("One to four words, like “Hey Dee”, “Computer” or “Okay Pixel”. She listens for it only on this iPhone — nothing is sent anywhere until she hears it. You can also tell her: “change your wake phrase to …”.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Use “\(WakePhrase.defaultText)”") { store.wakePhraseText = WakePhrase.defaultText }
                .font(.footnote)
                .disabled(store.wakePhraseText == WakePhrase.defaultText)
        }
    }
}

/// Her voice: OpenAI voices (modes 1/2), the LAN TTS voice id, or the iPhone's voices.
struct VoicePicker: View {
    @Bindable var store: ProviderStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch (store.draft.mode, store.draft.tts) {
            case (.lanEverything, .onDevice):
                let voices = OnDeviceVoices.best()
                Picker("Voice", selection: $store.draft.voice) {
                    Text("Best available").tag("")
                    ForEach(voices, id: \.identifier) { v in
                        Text("\(v.name) · \(OnDeviceVoices.quality(v))").tag(v.identifier)
                    }
                }
                .pickerStyle(.inline)
                Text("Better voices: Settings › Accessibility › Spoken Content › Voices — download an Enhanced or Premium English voice, then come back.")
                    .font(.footnote).foregroundStyle(.secondary)
            case (.lanEverything, _):
                TextField("Voice name on your TTS server (e.g. af_heart)", text: $store.draft.voice)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(10).background(Color.white.opacity(0.08), in: .rect(cornerRadius: 10))
                Text("Leave empty for the server's default voice.").font(.footnote).foregroundStyle(.secondary)
            default:
                Picker("Voice", selection: $store.draft.voice) {
                    ForEach(CloudSettings.voices, id: \.self) { v in
                        Text(v.capitalized + (v == "marin" || v == "cedar" ? " (recommended)" : "")).tag(v)
                    }
                }
                .pickerStyle(.inline)
                Text("OpenAI voices. Her voice is AI-generated; she'll say so the first time she speaks.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

enum OnDeviceVoices {
    /// English voices, premium first, then enhanced, then default.
    static func best(language: String = "en") -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(language) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
    }

    static func quality(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: "Premium"
        case .enhanced: "Enhanced"
        default: "Default"
        }
    }
}
