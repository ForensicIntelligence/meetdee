import DeeBrain
import DeeCore
import DeeFace
import DeeLocal
import DeeWake
import SwiftUI

/// First launch (providers-wake-onboarding §5): what Dee is, how to talk with the
/// companion, what Dee sees, privacy and cost, the permission cards, then the provider,
/// the companion (persona), wake phrase, voice and speak-first. Every pronoun is the
/// chosen persona's. Nothing here uses the mic, camera or network on its own:
/// each permission is asked from its card, and the network only on "Check key" /
/// "Test connection".
struct OnboardingView: View {
    @Bindable var store: ProviderStore
    var onDone: () -> Void
    @State private var flow: OnboardingFlow
    @State private var asking = false
    /// Who the user is meeting (the chosen persona: the default for a fresh install).
    private var p: PersonaPreset { store.persona }
    private var t: PronounText { store.persona.text }

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
            header("Who does \(t.their) thinking?", "Pick how \(p.name) hears, thinks and speaks. You can change this any time in the settings.")
            ProviderSetupView(store: store)
                .onChange(of: store.status(.brain)) { _, _ in refresh() }
                .onChange(of: store.status(.openAI)) { _, _ in refresh() }
                .onChange(of: store.status(.stt)) { _, _ in refresh() }
                .onChange(of: store.status(.tts)) { _, _ in refresh() }
        case .persona:
            header("Choose your companion", "Each has a name, an age, a personality, a sense of humour and a voice of their own. You can switch later in the settings; your people and memories stay.")
            PersonaPicker(store: store)
        case .wakePhrase:
            header("\(t.Their) wake phrase", "Say it to start a conversation. Until \(t.they("hear")) it, nothing leaves your iPhone.")
            WakePhraseEditor(store: store)
        case .voice:
            header("\(t.Their) voice", nil)
            VoicePicker(store: store)
        case .speakFirst:
            header("Speak first?", "When \(t.they("see")) someone \(t.they) \(p.pronouns.verb("know")) arrive, \(p.name) can say hello first — that opens one short conversation by itself.")
            Toggle("Speak first when \(t.they("see")) someone", isOn: $store.speakFirst)
                .accessibilityIdentifier("speakFirstToggle")
            Text("Off by default: \(t.they("wait")) for \(t.their) wake phrase or a tap.").font(.footnote).foregroundStyle(.secondary)
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
            header("Meet \(p.name)", "A companion who lives in your iPhone. Only \(t.their) eyes show — \(t.they("talk")), \(p.pronouns.verb("listen")), \(p.pronouns.have) moods and a personality of \(t.their) own, and \(p.pronouns.verb("remember")) the people \(t.they) \(p.pronouns.verb("meet")). All of that is \(t.their) “Dee DNA”, and it grows with you.")
        }
    }

    private var talking: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Talking with \(t.them)", nil)
            bullet("waveform", "Say \(t.their) wake phrase", "“\(store.wakePhraseText)” (or your own) starts a conversation. You can ask in one breath: “\(store.wakePhraseText), what time is it?”. Or tap the screen outside \(t.their) eyes.")
            bullet("ellipsis.bubble", "Just talk", "While a conversation is open you don't need the phrase. It ends a minute after you both go quiet.")
            bullet("moon.zzz", "“Go to sleep” · “That's all”", "Ends the conversation right away. “Stop listening” works too.")
            bullet("hand.raised", "Interrupt any time", "Talk over \(t.them) and \(t.they("stop")) to listen. Say “keep going” and \(t.they("carry")) on.")
            bullet("iphone.gen3", "Keep Dee open", "\(t.They("listen")) only while Dee is open — ideally on a charger. The screen stays on.")
        }
    }

    private var seeing: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("What \(t.they("see"))", nil)
            bullet("eye", "Your face", "\(t.Their) eyes follow you, and \(t.they) can recognise friends \(t.they) \(p.pronouns.have) met.")
            bullet("lock.iphone", "Stays on your iPhone", "Camera video and faces are processed on the device — never recorded, never sent. Only a few words about what \(t.they("notice")) (“a cup you're showing \(t.them)”) go to \(t.their) AI during a conversation.")
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 16) {
            header("Privacy and cost", "\(t.Their) memories and Dee DNA store stay on this iPhone in every mode. What goes where depends on the mode you pick next:")
            bullet("cloud", "OpenAI for everything", "During a conversation, the audio and the Dee DNA for each reply go to OpenAI (kept up to 30 days for abuse checks). Paid per use by your own OpenAI key.")
            bullet("desktopcomputer", "Your Mac's brain, OpenAI's voice", "Your words and \(t.their) voice go to OpenAI; the thinking, Dee DNA and memories go only to your own server. OpenAI speech is paid by your key; your server is free.")
            bullet("house", "Your own network for everything", "Nothing goes to OpenAI. Your server (or this iPhone) hears, thinks and speaks. Free.")
            bullet("ear", "\(t.Their) wake phrase", "Always listened for on this iPhone only, in every mode. Before it is heard, no audio leaves the phone.")
        }
    }

    private func permissionCard(_ kind: PermissionKind) -> some View {
        let card = Permissions.card(kind, persona: p)
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
                   flow.providerReady ? "Say “\(store.wakePhraseText)” or tap the screen to talk to \(t.them)." : nil)
            if !flow.providerReady {
                Text("\(p.name) needs a working provider first: go back to “Who does \(t.their) thinking?” and check your key or test your server.")
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
                    .accessibilityHint("Goes straight to choosing who does \(t.their) thinking")
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
