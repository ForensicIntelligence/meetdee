import AVFoundation
import DeeBrain
import DeeCore
import DeeLocal
import DeeRealtime
import DeeVoice
import SwiftUI

/// "Choose your companion" (onboarding, and the settings' Companion sheet): one card per
/// persona preset with its name, pronouns and age, its hook, and a ▶ sample in the voice
/// it would have in the current mode.
struct PersonaPicker: View {
    @Bindable var store: ProviderStore
    /// Called instead of choosing directly (the settings confirm a switch first).
    var onPick: ((PersonaPreset) -> Void)? = nil
    @State private var preview = PersonaPreview()

    var body: some View {
        VStack(spacing: 12) {
            ForEach(store.offeredPersonas) { p in
                PersonaCard(preset: p, selected: p.id == store.personaID,
                            playing: preview.playing == p.id, loading: preview.loading == p.id,
                            canPreview: preview.canPreview(store: store)) {
                    if let onPick { onPick(p) } else { store.choosePersona(p.id) }
                } play: {
                    Task { await preview.play(p, store: store) }
                }
            }
            if let problem = preview.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
        }
        .onDisappear { preview.stop() }
    }
}

struct PersonaCard: View {
    let preset: PersonaPreset
    let selected: Bool
    let playing: Bool
    let loading: Bool
    let canPreview: Bool
    var choose: () -> Void
    var play: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: choose) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(preset.isLegacy ? "\(preset.name) (classic)" : preset.name).font(.title3.bold())
                        Text(preset.cardSubtitle).font(.subheadline).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if selected {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.deeEye)
                                .accessibilityHidden(true)
                        }
                    }
                    Text(preset.hook).font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(preset.name), \(preset.pronouns.label)\(preset.age.map { ", \($0)" } ?? ""). \(preset.hook)")
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityIdentifier("persona_\(preset.id)")
            if canPreview {
                Button(action: play) {
                    Group {
                        if loading { ProgressView() } else {
                            Image(systemName: playing ? "speaker.wave.2.fill" : "play.circle.fill").font(.title2)
                        }
                    }
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.deeEye)
                .accessibilityLabel("Hear \(preset.name)")
                .accessibilityIdentifier("personaPreview_\(preset.id)")
            }
        }
        .padding(14)
        .background(Color.white.opacity(selected ? 0.14 : 0.06), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Color.deeEye : .clear, lineWidth: 1.5))
    }
}

/// The ▶ sample: the persona's greeting in its mode voice — OpenAI speech (modes 1/2,
/// the user's key, only on this tap) or this iPhone's voice (mode 3 on this iPhone). A
/// LAN TTS server is not called from setup.
@MainActor @Observable
final class PersonaPreview {
    private(set) var playing: String?
    private(set) var loading: String?
    private(set) var problem: String?
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?

    func canPreview(store: ProviderStore) -> Bool {
        switch (store.draft.mode, store.draft.tts) {
        case (.openAI, _), (.lanBrainOpenAIVoice, _): store.openAIKeyRedacted != nil
        case (.lanEverything, .onDevice): true
        case (.lanEverything, _): false
        }
    }

    func stop() {
        task?.cancel()
        player?.stop()
        player = nil
        playing = nil
        loading = nil
    }

    func play(_ p: PersonaPreset, store: ProviderStore) async {
        stop()
        problem = nil
        loading = p.id
        defer { if loading == p.id { loading = nil } }
        let renderer: any ClipRenderer
        let instructions: String
        switch (store.draft.mode, store.draft.tts) {
        case (.openAI, _), (.lanBrainOpenAIVoice, _):
            let secrets = store.secrets
            let voice = CloudSettings.voices.contains(p.openAIVoice) ? p.openAIVoice : p.openAIFallback
            renderer = SpeechEndpointRenderer(configuration: .openAI(voice: .named(voice)),
                                              key: { secrets.secret(account: SecretAccount.openAI) },
                                              fetch: Transport.live(redirects: .sameHost, recorder: store.recorder).fetch)
            instructions = p.ttsStyle
        default:
            let id = p.appleVoice.flatMap { PersonaVoicePicker.identifier(rule: $0) }
            let picked = id.flatMap(AVSpeechSynthesisVoice.init(identifier:))
            let gender: VoiceGender? = picked?.gender == .male ? .male : picked?.gender == .female ? .female : nil
            let shape = PersonaVoicePicker.shape(rule: p.appleVoice, voiceGender: gender)
            renderer = OnDeviceClipRenderer(voiceIdentifier: id, rate: shape.rate, pitch: shape.pitch)
            instructions = ""
        }
        do {
            let pcm = try await renderer.render(text: p.sampleLine, instructions: instructions)
            guard loading == p.id else { return }
            let player = try AVAudioPlayer(data: Self.wav(pcm24k: pcm))
            self.player = player
            loading = nil
            playing = p.id
            player.play()
            let seconds = player.duration
            task = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds + 0.2))
                if self?.playing == p.id { self?.playing = nil }
            }
        } catch {
            problem = "Couldn't play \(p.name)'s voice just now."
        }
    }

    /// 24 kHz mono PCM16 → a WAV file in memory.
    static func wav(pcm24k pcm: Data) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(24_000); u32(48_000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}

/// The settings' Companion section: who Dee is now, and the switch (with its confirmation).
/// The chooser is pushed in the settings' navigation stack: a sheet presented from a Form
/// section inside the settings sheet dismissed the settings instead.
struct CompanionSection: View {
    @Bindable var store: ProviderStore

    var body: some View {
        Section {
            let p = store.persona
            VStack(alignment: .leading, spacing: 4) {
                Text(p.isLegacy ? "\(p.name) (classic)" : p.name).font(.headline)
                Text(p.cardSubtitle).font(.subheadline).foregroundStyle(.secondary)
                Text(p.hook).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            NavigationLink {
                CompanionChooser(store: store)
            } label: {
                Text("Change…").foregroundStyle(Color.deeEye)
            }
            .accessibilityIdentifier("changeCompanion")
        } header: {
            Text("Companion")
        } footer: {
            Text("Saved with the settings; used from the next conversation.")
        }
    }

    /// The switch confirmation (persona spec §11.8, and the clip re-render note).
    static func switchMessage(_ p: PersonaPreset, mode: ProviderMode) -> String {
        let t = p.text
        var s = "\(p.name) starts with \(t.their) own personality, mood and sense of humour. "
            + "\(t.They)'ll still know you, your people and what you've talked about."
        if mode != .lanEverything {
            s += " \(p.name)'s lines will be re-recorded next time (uses your OpenAI key)."
        }
        return s
    }
}

/// "Choose your companion" from the settings: the cards, the switch confirmation and the
/// "Use <Name>'s voice?" question.
struct CompanionChooser: View {
    @Bindable var store: ProviderStore
    @State private var pending: PersonaPreset?

    var body: some View {
        ScrollView {
            PersonaPicker(store: store) { pending = $0 }
                .padding(20)
        }
        .background(Color.deeBackground)
        .navigationTitle("Choose your companion")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(pending.map { "Switch to \($0.name)?" } ?? "", isPresented: .init(
            get: { pending != nil && pending?.id != store.personaID }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible) {
            if let p = pending {
                Button("Switch to \(p.name)") {
                    store.choosePersona(p.id)
                    pending = nil
                }
                Button("Cancel", role: .cancel) { pending = nil }
            }
        } message: {
            if let p = pending { Text(CompanionSection.switchMessage(p, mode: store.draft.mode)) }
        }
        .alert(store.voiceQuestion.map { "Use \($0.name)'s voice?" } ?? "", isPresented: .init(
            get: { store.voiceQuestion != nil }, set: { if !$0 { store.voiceQuestion = nil } })) {
            if let p = store.voiceQuestion {
                Button("Use \(p.name)'s voice") { store.applyPersonaVoice(p) }
                Button("Keep my voice", role: .cancel) { store.voiceQuestion = nil }
            }
        } message: {
            Text("You picked a voice yourself. Keep it, or switch to the one made for this companion?")
        }
    }
}
