import DeeBrain
import DeeCore
import DeeFace
import DeeLocal
import DeeWake
import SwiftUI

/// First launch (providers-wake-onboarding §5): what Dee is, how to talk to her, what
/// she sees, privacy and cost, the permission cards, then the provider, wake phrase,
/// voice and speak-first. Nothing here uses the mic, camera or network on its own:
/// each permission is asked from its card, and the network only on "Check key" /
/// "Test connection".
struct OnboardingView: View {
    @Bindable var store: ProviderStore
    var onDone: () -> Void
    @State private var flow: OnboardingFlow
    @State private var asking = false

    init(store: ProviderStore, startAt: OnboardingStep = .meet, onDone: @escaping () -> Void) {
        self.store = store
        self.onDone = onDone
        var f = OnboardingFlow(permissions: [:], speechCardNeeded: true, localNetworkNeeded: false, providerReady: false)
        if startAt == .provider { f.skip() }
        _flow = State(initialValue: f)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    page
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 24)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .id(flow.step)
            bottomBar
        }
        .background(Color.deeBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear(perform: refresh)
        .onChange(of: store.draft.mode) { _, _ in refresh() }
    }

    private func refresh() {
        flow.permissions = Permissions.all
        flow.localNetworkNeeded = store.draft.mode != .openAI
        flow.providerReady = store.isReady && store.wakePhraseError == nil
    }

    // MARK: Pages

    @ViewBuilder private var page: some View {
        switch flow.step {
        case .meet: meet
        case .talking: talking
        case .seeing: seeing
        case .privacy: privacy
        case .micPermission, .speechPermission, .cameraPermission, .localNetworkPermission:
            if let kind = flow.step.permission { permissionCard(kind) }
        case .provider:
            header("Who does her thinking?", "Pick how Dee hears, thinks and speaks. You can change this any time in her settings.")
            ProviderSetupView(store: store)
                .onChange(of: store.status(.brain)) { _, _ in refresh() }
                .onChange(of: store.status(.openAI)) { _, _ in refresh() }
                .onChange(of: store.status(.stt)) { _, _ in refresh() }
                .onChange(of: store.status(.tts)) { _, _ in refresh() }
        case .wakePhrase:
            header("Her wake phrase", "Say it to start a conversation. Until she hears it, nothing leaves your iPhone.")
            WakePhraseEditor(store: store)
        case .voice:
            header("Her voice", nil)
            VoicePicker(store: store)
        case .speakFirst:
            header("Speak first?", "When she sees someone she knows arrive, Dee can say hello first — that opens one short conversation by itself.")
            Toggle("Speak first when she sees someone", isOn: $store.speakFirst)
                .accessibilityIdentifier("speakFirstToggle")
            Text("Off by default: she waits for her wake phrase or a tap.").font(.footnote).foregroundStyle(.secondary)
        case .done:
            done
        }
    }

    private var meet: some View {
        VStack(alignment: .leading, spacing: 18) {
            FaceView(inputs: FaceInputs(emotion: .happy, activity: .idle))
                .frame(height: 200)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            header("Meet Dee", "A little robot who lives in your iPhone. Only her eyes show — she talks, listens, has moods and a personality of her own, and remembers the people she meets. All of that is her “Dee DNA”, and it grows with you.")
        }
    }

    private var talking: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Talking with her", nil)
            bullet("waveform", "Say her wake phrase", "“Hey Dee” (or your own) starts a conversation. You can ask in one breath: “Hey Dee, what time is it?”. Or tap the screen outside her eyes.")
            bullet("ellipsis.bubble", "Just talk", "While a conversation is open you don't need the phrase. It ends a minute after you both go quiet.")
            bullet("moon.zzz", "“Go to sleep” · “That's all”", "Ends the conversation right away. “Stop listening” works too.")
            bullet("hand.raised", "Interrupt any time", "Talk over her and she stops to listen. Say “keep going” and she carries on.")
            bullet("iphone.gen3", "Keep Dee open", "She listens only while her app is open — ideally on a charger. The screen stays on with her.")
        }
    }

    private var seeing: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("What she sees", nil)
            bullet("eye", "Your face", "Her eyes follow you, and she can recognise friends she has met.")
            bullet("lock.iphone", "Stays on your iPhone", "Camera video and faces are processed on the device — never recorded, never sent. Only a few words about what she notices (“a cup you're showing her”) go to her AI during a conversation.")
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Privacy and cost", "Her memories and Dee DNA store stay on this iPhone in every mode. What goes where depends on the mode you pick next:")
            bullet("cloud", "OpenAI for everything", "During a conversation, her audio and the Dee DNA for each reply go to OpenAI (kept up to 30 days for abuse checks). Paid per use by your own OpenAI key.")
            bullet("desktopcomputer", "Your Mac's brain, OpenAI's voice", "Your words and her voice go to OpenAI; the thinking, Dee DNA and memories go only to your own server. OpenAI speech is paid by your key; your server is free.")
            bullet("house", "Your own network for everything", "Nothing goes to OpenAI. Your server (or this iPhone) hears, thinks and speaks. Free.")
            bullet("ear", "Her wake phrase", "Always listened for on this iPhone only, in every mode. Before she hears it, no audio leaves the phone.")
        }
    }

    private func permissionCard(_ kind: PermissionKind) -> some View {
        let card = Permissions.card(kind)
        let state = flow.state(kind)
        return VStack(alignment: .leading, spacing: 18) {
            Image(systemName: card.symbol).font(.system(size: 44)).foregroundStyle(Color.deeEye).accessibilityHidden(true)
            header(card.title, card.body)
            switch state {
            case .granted:
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .denied:
                Label("Turned off. You can turn it on in the Settings app › Dee.", systemImage: "xmark.circle")
                    .foregroundStyle(.orange)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            case .undetermined:
                Button {
                    asking = true
                    Task {
                        _ = await Permissions.request(kind)
                        asking = false
                        refresh()
                    }
                } label: {
                    Text("Allow").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(asking)
                .accessibilityIdentifier("allowPermission")
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(flow.providerReady ? "All set" : "Almost there",
                   flow.providerReady ? "Say “\(store.wakePhraseText)” or tap the screen to talk to her." : nil)
            if !flow.providerReady {
                Text("Dee needs a working provider first: go back to “Who does her thinking?” and check your key or test your server.")
                    .foregroundStyle(.orange)
                Button("Go to the provider step") {
                    while flow.step != .provider, flow.canBack { flow.back() }
                }
            }
        }
    }

    // MARK: Chrome

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if flow.canBack {
                Button("Back") { withAnimation { flow.back() }; refresh() }
                    .accessibilityIdentifier("onboardingBack")
            }
            Spacer()
            if flow.canSkip {
                Button("Skip") { withAnimation { flow.skip() }; refresh() }
                    .foregroundStyle(.secondary)
                    .accessibilityHint("Goes straight to choosing who does her thinking")
                    .accessibilityIdentifier("onboardingSkip")
            }
            if flow.step == .done {
                Button("Start") { finish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!flow.canFinish)
                    .accessibilityIdentifier("onboardingDone")
            } else {
                Button("Next") { advance() }
                    .buttonStyle(.borderedProminent)
                    .disabled(flow.step == .wakePhrase && store.wakePhraseError != nil)
                    .accessibilityIdentifier("onboardingNext")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func advance() {
        refresh()
        withAnimation { flow.next() }
        refresh()
    }

    private func finish() {
        refresh()
        guard flow.canFinish else { return }
        store.save()
        store.prefs.onboardingVersion = OnboardingFlow.version
        onDone()
    }

    private func header(_ title: String, _ body: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            if let body { Text(body).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func bullet(_ symbol: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Color.deeEye).frame(width: 30).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(body).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
