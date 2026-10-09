import DeeCore
import SwiftUI

struct RootView: View {
    @Environment(DeeModel.self) private var model
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            FacePlaceholder(emotion: model.emotion, activity: model.activity)
                .frame(height: 220)
                .padding(.horizontal, 24)
            TranscriptView(items: model.transcript)
            inputBar
        }
        .background(Color.deeBackground.ignoresSafeArea())
        .overlay { loadOverlay }
    }

    private var header: some View {
        HStack {
            Button {
                model.newConversation()
            } label: {
                Image(systemName: "plus.bubble")
            }
            .accessibilityLabel("New conversation")
            .disabled(model.isResponding)

            Spacer()
            Text(model.statusLine)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()

            Button {
                model.toggleThinking()
            } label: {
                Image(systemName: model.thinkingMode ? "brain.fill" : "brain")
                    .foregroundStyle(model.thinkingMode ? Color.deeThinking : .secondary)
            }
            .accessibilityLabel(model.thinkingMode ? "Thinking mode on" : "Thinking mode off")
            .accessibilityIdentifier("thinkingToggle")
        }
        .font(.title3)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Say something to Dee…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.white.opacity(0.08), in: .rect(cornerRadius: 20))
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .accessibilityIdentifier("messageField")

            if model.isResponding {
                Button(action: model.stop) {
                    Image(systemName: "stop.circle.fill").font(.title)
                }
                .accessibilityLabel("Stop")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || model.loadState != .ready)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("sendButton")
            }
        }
        .padding()
    }

    private func send() {
        model.send(draft)
        draft = ""
    }

    @ViewBuilder private var loadOverlay: some View {
        switch model.loadState {
        case .idle, .ready:
            EmptyView()
        case .loading(let p):
            VStack(spacing: 12) {
                ProgressView(value: p)
                    .frame(width: 180)
                Text("Waking Dee up…").font(.callout).foregroundStyle(.secondary)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 20))
        case .failed(let why):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text(why).multilineTextAlignment(.center).font(.callout)
                Button("Try again") { Task { await model.loadIfNeeded() } }
            }
            .padding(24)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 20))
            .padding()
        }
    }
}

struct TranscriptView: View {
    let items: [TranscriptItem]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { item in
                        TranscriptRow(item: item).id(item.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: items.last?.text) {
                if let last = items.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: items.count) {
                if let last = items.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }
}

struct TranscriptRow: View {
    let item: TranscriptItem
    @State private var showReasoning = false

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(item.text)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color.deeEye.opacity(0.22), in: .rect(cornerRadius: 18))
            }
        case .dee:
            VStack(alignment: .leading, spacing: 6) {
                if !item.reasoning.isEmpty {
                    Button {
                        showReasoning.toggle()
                    } label: {
                        Label(item.isStreaming && item.text.isEmpty ? "Thinking…" : "Thoughts", systemImage: "sparkles")
                            .font(.caption)
                            .foregroundStyle(Color.deeThinking)
                    }
                    if showReasoning {
                        Text(item.reasoning.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .background(Color.deeThinking.opacity(0.08), in: .rect(cornerRadius: 12))
                    }
                }
                if !item.text.isEmpty || item.reasoning.isEmpty {
                    Text(item.text.isEmpty ? "…" : item.text)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.white.opacity(0.07), in: .rect(cornerRadius: 18))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("deeMessage")
        case .tool:
            Text(item.text).font(.caption.monospaced()).foregroundStyle(.secondary)
        case .note:
            Text(item.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Phase 1 stand-in for the real face (DeeFace, Phase 2).
struct FacePlaceholder: View {
    let emotion: Emotion
    let activity: Activity

    var body: some View {
        HStack(spacing: 36) {
            eye
            eye
        }
        .overlay(alignment: .bottom) {
            Text("[\(emotion.rawValue)]").font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    private var eye: some View {
        RoundedRectangle(cornerRadius: 40)
            .fill(Color.deeEye)
            .frame(width: 90, height: activity == .thinking ? 70 : 120)
            .shadow(color: .deeEye.opacity(0.7), radius: 18)
            .animation(.spring, value: activity)
    }
}

extension Color {
    static let deeBackground = Color(red: 0.02, green: 0.027, blue: 0.04)
    static let deeEye = Color(red: 0.498, green: 0.906, blue: 1.0)
    static let deeThinking = Color(red: 0.663, green: 0.549, blue: 1.0)
}
