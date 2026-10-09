import DeeCore
import DeeLLM
import Foundation
import Observation

/// One line in the on-screen transcript.
struct TranscriptItem: Identifiable, Equatable {
    enum Kind: Equatable { case user, dee, tool, note }
    let id = UUID()
    var kind: Kind
    var text: String
    var reasoning: String = ""
    var isStreaming = false
}

/// What Dee is doing right now — drives the face.
enum Activity: Equatable {
    case idle, listening, thinking, speaking
}

/// The app's single source of truth: model lifecycle, the conversation, Dee's mood.
@Observable @MainActor
final class DeeModel {
    enum LoadState: Equatable {
        case idle
        case loading(Double)
        case ready
        case failed(String)
    }

    private(set) var loadState: LoadState = .idle
    private(set) var transcript: [TranscriptItem] = []
    private(set) var emotion: Emotion = .neutral
    private(set) var activity: Activity = .idle
    private(set) var thinkingMode = false
    private(set) var isResponding = false
    private(set) var statusLine = ""

    private var engine: LlamaEngine?
    private var agent: ConversationAgent?
    private var responseTask: Task<Void, Never>?
    private var persona = Persona()

    // MARK: - Model lifecycle

    func loadIfNeeded() async {
        guard loadState == .idle || { if case .failed = loadState { true } else { false } }() else { return }
        guard let url = ModelLocator.locate() else {
            loadState = .failed(ModelLocator.Problem.notFound.localizedDescription)
            return
        }
        do {
            try ModelLocator.checkMemory()
            loadState = .loading(0)
            let engine = try await LlamaEngine.load(.init(modelPath: url.path(percentEncoded: false))) { [weak self] p in
                Task { @MainActor in
                    if case .loading = self?.loadState { self?.loadState = .loading(p) }
                }
            }
            let agent = ConversationAgent(generator: engine, tools: ToolRegistry(), persona: persona)
            await agent.newConversation(persona: persona)
            self.engine = engine
            self.agent = agent
            loadState = .ready
            statusLine = engine.modelDescription
            #if DEBUG
            // `-DeeAutoPrompt "text"`: send a message on launch (screenshots, UI tests).
            if let auto = UserDefaults.standard.string(forKey: "DeeAutoPrompt"), !auto.isEmpty {
                send(auto)
            }
            #endif
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Conversation

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let agent, !isResponding else { return }
        transcript.append(TranscriptItem(kind: .user, text: text))
        isResponding = true
        activity = .thinking

        responseTask = Task {
            var deeIndex: Int?
            @MainActor func deeItem() -> Int {
                if let deeIndex { return deeIndex }
                transcript.append(TranscriptItem(kind: .dee, text: "", isStreaming: true))
                deeIndex = transcript.count - 1
                return deeIndex!
            }
            do {
                for try await event in agent.respond(to: text) {
                    switch event {
                    case .thinkingModeChanged(let on):
                        thinkingMode = on
                        transcript.append(TranscriptItem(kind: .note, text: on ? "Thinking mode on for this conversation" : "Thinking mode off"))
                    case .generationStarted:
                        deeIndex = nil
                        activity = .thinking
                    case .reasoning(let s):
                        transcript[deeItem()].reasoning += s
                    case .content(let s):
                        let i = deeItem()
                        if transcript[i].text.isEmpty { activity = .speaking }
                        transcript[i].text += s
                    case .emotion(let e):
                        emotion = e
                    case .toolCall(let call):
                        transcript.append(TranscriptItem(kind: .tool, text: "⚙︎ \(call.name)"))
                    case .toolResult:
                        break
                    case .reasoningBudgetExhausted:
                        break
                    case .compacted(let n):
                        transcript.append(TranscriptItem(kind: .note, text: "Forgot \(n) older messages to make room"))
                    case .messageCompleted(let message):
                        if let i = deeIndex {
                            transcript[i].isStreaming = false
                            transcript[i].text = message.content
                            if transcript[i].text.isEmpty, transcript[i].reasoning.isEmpty { transcript.remove(at: i) }
                        }
                        deeIndex = nil
                    case .turnCompleted:
                        break
                    }
                }
            } catch is CancellationError {
            } catch {
                transcript.append(TranscriptItem(kind: .note, text: error.localizedDescription))
                emotion = .confused
            }
            for i in transcript.indices where transcript[i].isStreaming { transcript[i].isStreaming = false }
            isResponding = false
            activity = .idle
            if let engine {
                statusLine = String(format: "%@ · %.0f tok/s", engine.modelDescription, engine.stats.generateTokensPerSecond)
            }
        }
    }

    func stop() {
        guard let agent else { return }
        Task { await agent.cancel() }
    }

    func newConversation() {
        guard let agent, !isResponding else { return }
        transcript.removeAll()
        thinkingMode = false
        emotion = .happy
        Task { await agent.newConversation(persona: persona) }
    }

    func toggleThinking() {
        guard let agent else { return }
        thinkingMode.toggle()
        let on = thinkingMode
        Task { await agent.setThinking(on) }
    }
}
