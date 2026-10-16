import DeeBrain
import DeeCore
import DeeLocal
import SwiftUI

/// Dee's in-app settings (providers-wake-onboarding §5): opened from the small gear or
/// a two-finger long-press on her eyes. Saving never touches the network while she is
/// dormant; a new provider is used from her next conversation window.
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ProviderSetupView(store: store)
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                } header: {
                    Text("Who does her thinking")
                } footer: {
                    Text(store.issues.first?.message ?? "Changes are used from her next conversation.")
                }

                Section("Wake phrase") { WakePhraseEditor(store: store) }
                Section("Voice") { VoicePicker(store: store) }

                Section {
                    Toggle("Speak first when she sees someone", isOn: $store.speakFirst)
                    Toggle("Share memories with her AI", isOn: $shareMemories)
                } footer: {
                    Text(store.draft.mode == .lanEverything
                         ? "With your own server, memories go only to that server during a conversation."
                         : "Off: what she remembers about people stays on this iPhone and isn't sent to OpenAI.")
                }

                Section("Age") {
                    Toggle("Dee has an age", isOn: $ageEnabled)
                    if ageEnabled {
                        TextField("Starting age (robot-years)", text: $startAge).keyboardType(.decimalPad)
                        Toggle("She grows up", isOn: $agingEnabled)
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
                    NavigationLink("About privacy") { PrivacyView(mode: store.draft.mode) }
                    Button("Run the introduction again") { dismiss(); runOnboarding() }
                    Button("Start over (forget her feelings)", role: .destructive) { confirmReset = true }
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
                Button("Forget her feelings and start over", role: .destructive) {
                    UserDefaults.standard.set(true, forKey: "resetMind")
                }
            } message: {
                Text("Her mood and personality reset the next time Dee opens. People she knows are kept.")
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct PrivacyView: View {
    let mode: ProviderMode

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                item("Her wake phrase", "Listened for only on this iPhone, with Apple's on-device speech recognition, in every mode. Until she hears it (or you tap her), no audio leaves the phone, no connection is open and nothing is paid.")
                item("During a conversation", Self.during(mode))
                item("Ending it", "“Go to sleep”, “stop listening” or “that's all” — or a minute of quiet — closes the connection and stops the microphone audio at once.")
                item("Her camera", "Processed on this iPhone. Never recorded or sent; only a few words about what she notices go to her AI during a conversation.")
                item("Memories", "Stored only on this iPhone. With “Share memories” on, a few relevant ones go with a reply to her AI (OpenAI, or your own server in the all-local mode).")
                item("Keys", "Your OpenAI key and server keys are kept only in this iPhone's Keychain, never in plain settings. An OpenAI key is never sent to your own server.")
            }
            .padding(20)
        }
        .background(Color.deeBackground)
        .navigationTitle("Privacy")
    }

    static func during(_ mode: ProviderMode) -> String {
        switch mode {
        case .openAI:
            "Her microphone audio and the Dee DNA for each reply go to OpenAI, which hears, thinks and speaks. OpenAI may keep it up to 30 days for abuse checks. Paid by your key."
        case .lanBrainOpenAIVoice:
            "Your words (audio) go to OpenAI to be transcribed, and her sentences go to OpenAI to be spoken. Her thinking, Dee DNA and memories go only to your own server."
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
