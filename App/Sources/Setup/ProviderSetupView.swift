import DeeBrain
import DeeLocal
import SwiftUI
import UIKit

/// The provider step of onboarding and the provider section of the in-app settings:
/// the three modes with their trade-offs, the OpenAI key, the LAN server(s), and
/// "Test connection" with per-part status. Nothing connects until the user taps
/// "Check key" or "Test connection".
struct ProviderSetupView: View {
    @Bindable var store: ProviderStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(ProviderMode.allCases, id: \.self) { mode in
                ModeCard(mode: mode, selected: store.draft.mode == mode) { store.setMode(mode) }
            }
            if store.draft.mode != .lanEverything {
                OpenAIKeySection(store: store)
            }
            if store.draft.mode != .openAI {
                ServerSection(store: store)
            }
            if store.draft.mode == .lanEverything {
                SpeechPartSection(store: store, part: .stt)
                SpeechPartSection(store: store, part: .tts)
            }
            let problems = store.issues.filter { $0 != .noOpenAIKey || store.draft.mode != .lanEverything }
            if !problems.isEmpty, store.status(.brain) != nil || store.status(.openAI) != nil {
                ForEach(problems, id: \.self) { issue in
                    Label(issue.message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: - Mode cards

struct ModeCard: View {
    let mode: ProviderMode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? Color.deeEye : .secondary)
                        .accessibilityHidden(true)
                    Text(mode.title).font(.headline)
                    Spacer(minLength: 0)
                }
                Text(Self.summary(mode)).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if selected {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Self.tradeOffs(mode), id: \.0) { row in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(row.0).font(.caption.weight(.semibold)).frame(minWidth: 64, alignment: .leading)
                                Text(row.1).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(selected ? 0.10 : 0.05), in: .rect(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? Color.deeEye.opacity(0.7) : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(Self.identifier(mode))
    }

    static func identifier(_ mode: ProviderMode) -> String {
        switch mode {
        case .openAI: "providerOpenAI"
        case .lanBrainOpenAIVoice: "providerLanBrain"
        case .lanEverything: "providerLan"
        }
    }

    static func summary(_ mode: ProviderMode) -> String {
        switch mode {
        case .openAI: "OpenAI hears, thinks and speaks. The most natural conversations, paid per use with your own key."
        case .lanBrainOpenAIVoice: "A model on your Mac or server thinks; OpenAI only hears and speaks. Needs an OpenAI key and your server's address."
        case .lanEverything: "Everything on your own network, or on this iPhone. Nothing goes to OpenAI, and it's free."
        }
    }

    static func tradeOffs(_ mode: ProviderMode) -> [(String, String)] {
        switch mode {
        case .openAI:
            [("Quality", "Best: one realtime model, natural voice, quick turn-taking."),
             ("Speed", "Answers in about a second."),
             ("Cost", "Paid by your OpenAI key, per minute of conversation."),
             ("Privacy", "During a conversation the audio and the Dee DNA go to OpenAI (kept up to 30 days for abuse checks)."),
             ("Needs", "An OpenAI API key.")]
        case .lanBrainOpenAIVoice:
            [("Quality", "Depends on your model; OpenAI's voice and hearing."),
             ("Speed", "A second or two slower; a model that isn't loaded takes longer the first time."),
             ("Cost", "Only OpenAI speech (cheaper than mode 1); your server is free."),
             ("Privacy", "Your words and the spoken replies go to OpenAI; the thinking, Dee DNA and memories stay on your network."),
             ("Needs", "An OpenAI key and your AI server's address.")]
        case .lanEverything:
            [("Quality", "Depends on your model and speech servers."),
             ("Speed", "Slowest; depends on your Mac."),
             ("Cost", "Free."),
             ("Privacy", "Nothing leaves your home network (or this iPhone)."),
             ("Needs", "Your AI server's address; speech servers optional — this iPhone can hear and speak.")]
        }
    }
}

// MARK: - OpenAI key

struct OpenAIKeySection: View {
    @Bindable var store: ProviderStore
    @State private var entry = ""
    @State private var replacing = false

    var body: some View {
        SetupGroup(title: "OpenAI key", symbol: "key.fill") {
            if let redacted = store.openAIKeyRedacted, !replacing {
                HStack {
                    Text(redacted).font(.body.monospaced())
                        .accessibilityLabel("Saved key ending in \(String(redacted.suffix(4)))")
                    Spacer()
                    Button("Replace") { replacing = true }
                    Button("Remove", role: .destructive) { store.removeOpenAIKey() }
                }
            } else {
                SecretEntry(text: $entry, prompt: "sk-…", identifier: "apiKeyField")
                HStack {
                    Button {
                        Task {
                            await store.saveOpenAIKey(entry)
                            if store.status(.openAI)?.isOK == true { entry = ""; replacing = false }
                        }
                    } label: {
                        if store.busy == .openAI { ProgressView() } else { Text("Check key") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(entry.isEmpty || store.busy != nil)
                    .accessibilityIdentifier("checkKey")
                    if replacing { Button("Cancel") { replacing = false; entry = "" } }
                }
            }
            PartStatusRow(status: store.status(.openAI))
            Text("Tip: make a restricted project key with a monthly spend limit at platform.openai.com. It's stored only in this iPhone's Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - LAN server

struct ServerSection: View {
    @Bindable var store: ProviderStore
    @State private var address = ""
    @State private var keyEntry = ""
    @State private var addressError: String?
    @State private var keyError: String?

    var body: some View {
        SetupGroup(title: "Your AI server", symbol: "desktopcomputer") {
            TextField("192.168.1.20:11434", text: $address)
                .textContentType(.URL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 10))
                .accessibilityLabel("Server address")
                .accessibilityIdentifier("serverAddressField")
                .onSubmit(applyAddress)
                .onChange(of: address) { _, _ in addressError = nil }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach([("Ollama", 11434), ("LM Studio", 1234), ("llama.cpp", 8080)], id: \.0) { preset in
                        Button("\(preset.0) :\(preset.1)") { address = Self.withPort(address, preset.1); applyAddress() }
                            .buttonStyle(.bordered)
                            .font(.caption)
                    }
                }
            }
            if let addressError { Text(addressError).font(.footnote).foregroundStyle(.orange) }
            if store.lanKeyRedacted(.brain) != nil {
                HStack {
                    Text("Server key \(store.lanKeyRedacted(.brain) ?? "")").font(.footnote.monospaced())
                    Spacer()
                    Button("Remove", role: .destructive) { store.removeLANKey(.brain) }
                }
            } else {
                SecretEntry(text: $keyEntry, prompt: "Server key (optional)", identifier: "serverKeyField")
                    .onSubmit(saveKey)
                if !keyEntry.isEmpty { Button("Save server key", action: saveKey).font(.footnote) }
                if let keyError { Text(keyError).font(.footnote).foregroundStyle(.orange) }
            }
            Button {
                applyAddress()
                if !keyEntry.isEmpty { saveKey() }
                guard addressError == nil, keyError == nil else { return }
                Task { await store.testBrain() }
            } label: {
                HStack {
                    if store.busy == .brain { ProgressView() }
                    Text("Test connection")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(address.isEmpty || store.busy != nil)
            .accessibilityIdentifier("testConnection")
            PartStatusRow(status: store.status(.brain), label: "Brain")
            if store.draft.mode == .lanEverything {
                PartStatusRow(status: store.status(.stt), label: "Hearing")
                PartStatusRow(status: store.status(.tts), label: "Voice")
            }
            if !store.brainModels.isEmpty {
                Picker("Model", selection: Binding(get: { store.draft.brain?.model ?? "" },
                                                   set: { store.draft.brain?.model = $0 })) {
                    ForEach(store.brainModels, id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("modelPicker")
            }
            Text("Ollama and LM Studio listen only on the Mac itself by default. Ollama: turn on “Expose Ollama to the network” (OLLAMA_HOST=0.0.0.0). LM Studio: start the server with network access.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { address = store.draft.brain.map { AddressParser.hostLabel($0.baseURL) } ?? "" }
    }

    private func applyAddress() {
        guard !address.isEmpty else { return }
        addressError = store.setBrainAddress(address)
    }

    private func saveKey() {
        keyError = store.saveLANKey(keyEntry, part: .brain, for: store.draft.brain)
        if keyError == nil { keyEntry = "" }
    }

    /// "192.168.1.20" + 11434 → "192.168.1.20:11434"; empty → "my-mac.local:11434".
    static func withPort(_ text: String, _ port: Int) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        if let scheme = t.range(of: "://") { t = String(t[scheme.upperBound...]) }
        let host = t.split(separator: "/").first.map(String.init) ?? ""
        let bare = host.split(separator: ":").first.map(String.init) ?? ""
        return (bare.isEmpty ? "my-mac.local" : bare) + ":\(port)"
    }
}

/// Mode 3: where hearing / Dee's voice run — the brain server, another LAN server, or
/// this iPhone (never OpenAI).
struct SpeechPartSection: View {
    @Bindable var store: ProviderStore
    let part: LANPart
    @State private var address = ""
    @State private var model = ""
    @State private var error: String?

    enum Choice: String, CaseIterable, Identifiable {
        case sameServer = "Same server", otherServer = "Another server", onDevice = "On this iPhone"
        var id: String { rawValue }
    }

    private var current: SpeechPart { part == .stt ? store.draft.stt : store.draft.tts }
    private var choice: Choice {
        switch current {
        case .onDevice: .onDevice
        case .lan(let e): e.baseURL == store.draft.brain?.baseURL ? .sameServer : .otherServer
        default: .onDevice
        }
    }

    var body: some View {
        SetupGroup(title: part == .stt ? "Hearing" : "Voice", symbol: part == .stt ? "ear" : "speaker.wave.2.fill") {
            Picker(part == .stt ? "Hearing" : "Voice", selection: Binding(get: { choice }, set: select)) {
                ForEach(Choice.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            switch choice {
            case .onDevice:
                Text(part == .stt ? "Apple's speech recognition on this iPhone: free and private."
                     : "This iPhone's built-in voices: free and private. Better voices: Settings › Accessibility › Spoken Content › Voices (download an Enhanced or Premium one).")
                    .font(.caption).foregroundStyle(.secondary)
            case .sameServer:
                Text(part == .stt ? "Uses /v1/audio/transcriptions on your AI server." : "Uses /v1/audio/speech on your AI server.")
                    .font(.caption).foregroundStyle(.secondary)
            case .otherServer:
                TextField(part == .stt ? "Whisper server, e.g. 192.168.1.20:8000" : "TTS server, e.g. 192.168.1.20:8880", text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(10).background(Color.white.opacity(0.08), in: .rect(cornerRadius: 10))
                TextField("Model (optional)", text: $model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(10).background(Color.white.opacity(0.08), in: .rect(cornerRadius: 10))
                if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
            }
            Button("Test \(part == .stt ? "hearing" : "voice")") {
                if choice == .otherServer { error = store.setSpeechAddress(part, address, model: model) }
                guard error == nil else { return }
                Task { await store.testSpeech(part) }
            }
            .buttonStyle(.bordered)
            .disabled(store.busy != nil)
            PartStatusRow(status: store.status(part == .stt ? .stt : .tts))
        }
        .onAppear {
            if case .lan(let e) = current, e.baseURL != store.draft.brain?.baseURL {
                address = AddressParser.hostLabel(e.baseURL)
                model = e.model
            }
        }
    }

    private func select(_ c: Choice) {
        switch c {
        case .onDevice: store.setSpeech(part, to: .onDevice)
        case .sameServer:
            if let b = store.draft.brain { store.setSpeech(part, to: .lan(EndpointConfig(baseURL: b.baseURL, model: ""))) }
        case .otherServer:
            if !address.isEmpty { error = store.setSpeechAddress(part, address, model: model) }
            else if let b = store.draft.brain {
                // Placeholder until an address is entered (distinct from the brain's).
                var c = URLComponents(url: b.baseURL, resolvingAgainstBaseURL: false)
                c?.port = part == .stt ? 8000 : 8880
                if let u = c?.url { store.setSpeech(part, to: .lan(EndpointConfig(baseURL: u, model: ""))) }
                address = c?.url.map(AddressParser.hostLabel) ?? ""
            }
        }
    }
}

// MARK: - Pieces

struct SetupGroup<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: .rect(cornerRadius: 16))
    }
}

struct PartStatusRow: View {
    let status: ProviderStore.PartStatus?
    var label: String?

    var body: some View {
        if let status {
            let (symbol, color): (String, Color) = switch status {
            case .ok: ("checkmark.circle.fill", .green)
            case .warning: ("exclamationmark.circle.fill", .yellow)
            case .failed: ("xmark.octagon.fill", .orange)
            }
            Label((label.map { "\($0): " } ?? "") + status.text, systemImage: symbol)
                .font(.footnote)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A secure field with a Paste button. After pasting, the pasteboard is cleared if it
/// still holds what was pasted (a key should not linger there).
struct SecretEntry: View {
    @Binding var text: String
    let prompt: String
    let identifier: String

    var body: some View {
        HStack(spacing: 8) {
            SecureField(prompt, text: $text)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(Color.white.opacity(0.08), in: .rect(cornerRadius: 10))
                .accessibilityIdentifier(identifier)
            Button {
                let board = UIPasteboard.general
                let count = board.changeCount
                guard let s = board.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
                text = s
                if board.changeCount == count { board.items = [] }
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard").labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Paste")
        }
    }
}
