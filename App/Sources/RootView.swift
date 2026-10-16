import DeeBrain
import DeeCore
import DeeFace
import SwiftUI

/// Dee is the screen. Interaction is by voice and camera; the only on-screen text
/// is captions. Debug builds add a keyboard and transcript for development.
struct RootView: View {
    @Environment(DeeModel.self) private var model
    @Bindable var store: ProviderStore
    var runOnboarding: () -> Void
    @State private var showSettings = false
    #if DEBUG
    @State private var showDebug = false
    @State private var draft = ""
    #endif

    var body: some View {
        ZStack {
            FaceView(inputs: model.faceInputs)
                .ignoresSafeArea()
            // Touch: pets, pokes, taps on an eye. Sits above the face, below the chrome.
            TouchCaptureView(onSample: { model.touched($0) }, onTwoFingerHold: openSettings)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                statusBar
                Spacer()
                captions
                #if DEBUG
                if showDebug { debugPanel }
                #endif
            }
        }
        .background(Color.deeBackground.ignoresSafeArea())
        .overlay { loadOverlay }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showSettings, onDismiss: { model.settingsClosed() }) {
            DeeSettingsView(store: store, runOnboarding: runOnboarding)
                .environment(model)
        }
        .onChange(of: model.settingsRequested) { _, asked in
            if asked { openSettings() }
        }
    }

    private func openSettings() {
        model.settingsOpened()
        store.reload()
        showSettings = true
    }

    // MARK: - Status

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            topRow
            cloudChip
            wakeChip
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    /// Release too: why she can't talk right now (no key, refused key, offline, rate
    /// limited), a short notice (key saved / refused), or the one-time AI-voice
    /// disclosure. Her face keeps living underneath (the "cloud off" look).
    @ViewBuilder private var cloudChip: some View {
        let line: (text: String, symbol: String, urgent: Bool)? = {
            if let d = model.disclosure { return (d, "waveform", false) }
            if let n = model.notice { return (n, "info.circle", false) }
            if let p = model.providerProblem { return (p, "gearshape", true) }
            if let e = model.earProblem { return (e, "ear.trianglebadge.exclamationmark", true) }
            if let s = model.cloudStatus { return (s.message, s.symbol, s.needsUser) }
            return nil
        }()
        if let line {
            Label(line.text, systemImage: line.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(line.urgent ? Color.orange : Color.white.opacity(0.8))
                .lineLimit(2)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.08), in: .capsule)
                .accessibilityIdentifier("cloudStatus")
                .accessibilityAddTraits(line.urgent ? .isButton : [])
                .onTapGesture { if line.urgent { openSettings() } }
                .transition(.opacity)
        }
    }

    /// Whether she is listening: "Say “Hey Dee”" while dormant (tap to talk), a soft
    /// "Listening" while a conversation window is open. Release too.
    @ViewBuilder private var wakeChip: some View {
        let s = model.wakeStatus
        Button {
            model.tapToTalk()
        } label: {
            Label(s.text, systemImage: s.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(s.open ? Color.deeEye : Color.white.opacity(0.65))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(s.open ? 0.10 : 0.06), in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(s.open || !model.canWake)
        .accessibilityLabel(s.accessibility)
        .accessibilityHint(s.open ? "" : "Starts a conversation")
        .accessibilityIdentifier("wakeState")
        .transition(.opacity)
        .animation(.easeInOut, value: s)
    }

    private var topRow: some View {
        HStack(spacing: 12) {
            if model.thinkingMode {
                Label("Thinking", systemImage: "brain.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.deeThinking)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.deeThinking.opacity(0.15), in: .capsule)
                    .accessibilityIdentifier("thinkingBadge")
                    .transition(.opacity.combined(with: .scale))
            }
            Spacer()
            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(.body)
                    .foregroundStyle(Color.white.opacity(0.35))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("settingsButton")
            #if DEBUG
            Button {
                withAnimation { showDebug.toggle() }
            } label: {
                Image(systemName: showDebug ? "keyboard.chevron.compact.down" : "keyboard")
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("debugToggle")
            #endif
        }
        .animation(.spring, value: model.thinkingMode)
    }

    // MARK: - Captions

    private var captions: some View {
        VStack(spacing: 8) {
            if !model.heard.isEmpty {
                Text(model.heard)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            if !model.caption.isEmpty {
                Text(model.caption)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .accessibilityIdentifier("caption")
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 36)
        // Captions grow token by token: no per-change animation, or each new word
        // cross-fades over the old line and ghosts.
        .transaction { $0.animation = nil }
    }

    // MARK: - Debug

    #if DEBUG
    private var debugPanel: some View {
        VStack(spacing: 8) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(model.transcript) { item in
                        Text(prefix(item.kind) + item.text + (item.reasoning.isEmpty ? "" : "  ✦\(item.reasoning.count) chars of thought"))
                            .font(.caption.monospaced())
                            .foregroundStyle(item.kind == .user ? Color.deeEye : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: 160)
            HStack(spacing: 8) {
                Button { model.newConversation() } label: { Image(systemName: "plus.bubble") }
                Button { model.toggleThinking() } label: { Image(systemName: model.thinkingMode ? "brain.fill" : "brain") }
                    .accessibilityIdentifier("thinkingToggle")
                TextField("Type to Dee (debug)", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                    .accessibilityIdentifier("messageField")
                if model.isResponding {
                    Button(action: model.stop) { Image(systemName: "stop.circle.fill") }
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill") }
                        .accessibilityIdentifier("sendButton")
                }
            }
            if let snap = model.mindSnapshot {
                Text(String(format: "regard %+.2f · %@%@", snap.regard, snap.emotion.rawValue, snap.age.map { String(format: " · age %.1f", $0) } ?? ""))
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                Text(snap.code.display)
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("mindCode")
            }
            Text(model.statusLine).font(.caption2.monospaced()).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func prefix(_ kind: TranscriptItem.Kind) -> String {
        switch kind {
        case .user: "› "
        case .dee: "◉ "
        case .tool: "⚙︎ "
        case .note: "· "
        }
    }

    private func send() {
        model.send(draft)
        draft = ""
    }
    #endif

    // MARK: - Loading

    @ViewBuilder private var loadOverlay: some View {
        switch model.loadState {
        case .idle, .ready, .loading:
            EmptyView() // Loading shows as Dee "thinking"; no chrome.
        case .failed(let why):
            VStack(spacing: 12) {
                Text(why).multilineTextAlignment(.center).font(.callout)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 20))
            .padding()
        }
    }
}

extension Color {
    static let deeBackground = Color(red: 0.02, green: 0.027, blue: 0.04)
    static let deeEye = Color(red: 0.498, green: 0.906, blue: 1.0)
    static let deeThinking = Color(red: 0.663, green: 0.549, blue: 1.0)
}
