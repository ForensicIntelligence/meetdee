import DeeBrain
import DeeCore
import DeeLocal
import SwiftUI

/// Dee's in-app settings (providers-wake-onboarding §5): opened from the small gear or
/// a two-finger long-press on Dee's eyes. Saving never touches the network while Dee is
/// dormant; a new provider is used from Dee's next conversation window.
struct DeeSettingsView: View {
    @Environment(DeeModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: ProviderStore
    var runOnboarding: () -> Void

    @AppStorage(CloudSettings.Key.shareMemories) private var shareMemories = true
    @AppStorage("ageEnabled") private var ageEnabled = false
    @AppStorage("startAge") private var startAge = "6"
    @AppStorage("agingEnabled") private var agingEnabled = false
    @AppStorage("yearsPerDay") private var yearsPerDay = "0.1"
    @State private var confirmReset = false
    /// The persona being edited (pronouns of every label below).
    private var p: PersonaPreset { store.persona }
    private var t: PronounText { store.persona.text }

    var body: some View {
        NavigationStack {
            Form {
                CompanionSection(store: store)

                Section {
                    ProviderSetupView(store: store)
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                } header: {
                    Text("Who does \(t.their) thinking")
                } footer: {
                    Text(store.issues.first?.message ?? "Changes are used from the next conversation.")
                }

                Section("Wake phrase") { WakePhraseEditor(store: store) }
                Section("Voice") { VoicePicker(store: store) }

                Section {
                    Toggle("Speak first when \(t.they("see")) someone", isOn: $store.speakFirst)
                    Toggle("Share memories with \(t.their) AI", isOn: $shareMemories)
                } footer: {
                    Text(store.draft.mode == .lanEverything
                         ? "With your own server, memories go only to that server during a conversation."
                         : "Off: what \(t.they("remember")) about people stays on this iPhone and isn't sent to OpenAI.")
                }

                Section("Age") {
                    Toggle("\(p.name) has an age", isOn: $ageEnabled)
                    if ageEnabled {
                        TextField("Starting age (robot-years)", text: $startAge).keyboardType(.decimalPad)
                        Toggle("\(t.They("grow")) up", isOn: $agingEnabled)
                        if agingEnabled {
                            TextField("Years per day", text: $yearsPerDay).keyboardType(.decimalPad)
                        }
                    }
                }

                Section("Today") {
                    let u = model.usageToday
                    LabeledContent("Audio sent", value: String(format: "%.0f s", u.streamedSeconds))
                    LabeledContent("Responses", value: "\(u.responses)")
                    LabeledContent("Conversations", value: "\(u.windows)")
                    if u.falseWakes > 0 { LabeledContent("Woke by mistake", value: "\(u.falseWakes)") }
                }

                Section {
                    NavigationLink("About privacy") { PrivacyView(mode: store.draft.mode, persona: p) }
                    Button("Run the introduction again") { dismiss(); runOnboarding() }
                    Button("Start over (forget \(t.their) feelings)", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("Dee \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.deeBackground)
            .navigationTitle("Dee")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.reload(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.save()
                        Task { await model.settingsChanged() }
                        dismiss()
                    }
                    .disabled(store.wakePhraseError != nil)
                    .accessibilityIdentifier("settingsSave")
                }
            }
            .confirmationDialog("Start over?", isPresented: $confirmReset) {
                Button("Forget \(t.their) feelings and start over", role: .destructive) {
                    UserDefaults.standard.set(true, forKey: "resetMind")
                }
            } message: {
                Text("\(t.Their) mood and personality reset to \(p.name)'s own the next time Dee opens. People \(t.they) \(p.pronouns.verb("know")) are kept.")
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct PrivacyView: View {
    let mode: ProviderMode
    var persona: PersonaPreset = PersonaCatalog.classic
    private var t: PronounText { persona.text }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                item("\(t.Their) wake phrase", "Listened for only on this iPhone, with Apple's on-device speech recognition, in every mode. Until \(t.they("hear")) it (or you tap \(t.them)), no audio leaves the phone, no connection is open and nothing is paid.")
                item("During a conversation", Self.during(mode, persona: persona))
                item("Ending it", "“Go to sleep”, “stop listening” or “that's all” — or a minute of quiet — closes the connection and stops the microphone audio at once.")
                item("\(t.Their) camera", "Processed on this iPhone. Never recorded or sent; only a few words about what \(t.they("notice")) go to \(t.their) AI during a conversation.")
                item("Memories", "Stored only on this iPhone. With “Share memories” on, a few relevant ones go with a reply to \(t.their) AI (OpenAI, or your own server in the all-local mode).")
                item("Keys", "Your OpenAI key and server keys are kept only in this iPhone's Keychain, never in plain settings. An OpenAI key is never sent to your own server.")
            }
            .padding(20)
        }
        .background(Color.deeBackground)
        .navigationTitle("Privacy")
    }

    static func during(_ mode: ProviderMode, persona: PersonaPreset = PersonaCatalog.classic) -> String {
        let t = persona.text
        return switch mode {
        case .openAI:
            "\(t.Their) microphone audio and the Dee DNA for each reply go to OpenAI, which hears, thinks and speaks. OpenAI may keep it up to 30 days for abuse checks. Paid by your key."
        case .lanBrainOpenAIVoice:
            "Your words (audio) go to OpenAI to be transcribed, and \(t.their) sentences go to OpenAI to be spoken. \(t.Their) thinking, Dee DNA and memories go only to your own server."
        case .lanEverything:
            "Everything goes only to your own servers on your network, or stays on this iPhone. Nothing goes to OpenAI."
        }
    }

    private func item(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
