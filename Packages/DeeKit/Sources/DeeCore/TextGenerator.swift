import Foundation

/// Sampler settings. Defaults are the Qwen3.5 model-card recommendations.
public struct SamplingConfig: Sendable, Equatable {
    public var temperature: Float
    public var topP: Float
    public var topK: Int32
    public var minP: Float
    public var presencePenalty: Float
    public var repeatPenalty: Float
    public var penaltyWindow: Int32
    public var seed: UInt32

    public init(temperature: Float, topP: Float, topK: Int32, minP: Float = 0, presencePenalty: Float, repeatPenalty: Float = 1.0, penaltyWindow: Int32 = 64, seed: UInt32 = 0xFFFF_FFFF) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.presencePenalty = presencePenalty
        self.repeatPenalty = repeatPenalty
        self.penaltyWindow = penaltyWindow
        self.seed = seed
    }

    /// Non-thinking, general tasks.
    public static let chat = SamplingConfig(temperature: 0.7, topP: 0.8, topK: 20, presencePenalty: 1.5)
    /// Thinking, general tasks.
    public static let thinking = SamplingConfig(temperature: 1.0, topP: 0.95, topK: 20, presencePenalty: 1.5)
    /// Deterministic (tests).
    public static let greedy = SamplingConfig(temperature: 0, topP: 1, topK: 1, presencePenalty: 0, seed: 42)
}

public struct GenerationOptions: Sendable {
    public var sampling: SamplingConfig
    public var maxTokens: Int
    /// Stop right after the generated text ends with one of these (the stop text is
    /// included in the output and in the engine's state).
    public var stopSequences: [String]

    public init(sampling: SamplingConfig = .chat, maxTokens: Int = 512, stopSequences: [String] = []) {
        self.sampling = sampling
        self.maxTokens = maxTokens
        self.stopSequences = stopSequences
    }
}

public enum GeneratorError: Error, Sendable, Equatable, LocalizedError {
    case notLoaded
    case contextOverflow(needed: Int, available: Int)
    case decodeFailed(Int32)
    case tokenizeFailed
    case loadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notLoaded: "The language model isn't loaded."
        case .contextOverflow(let n, let a): "Conversation too long for the context window (\(n) tokens needed, \(a) available)."
        case .decodeFailed(let c): "The language model failed to evaluate the prompt (code \(c))."
        case .tokenizeFailed: "Couldn't tokenize the prompt."
        case .loadFailed(let why): "Couldn't load the language model: \(why)"
        }
    }
}

/// A text-completion engine. `LlamaEngine` is the real one; tests use scripted fakes.
///
/// Engines are expected to keep their evaluated state between calls and to reuse it
/// whenever the new prompt starts with everything evaluated so far (append-only
/// prompting) — that is what makes multi-turn chat cheap on a phone.
public protocol TextGenerator: AnyObject, Sendable {
    /// Total context window in tokens.
    var contextLength: Int { get }

    /// Streams raw decoded text for the completion of `prompt` (special tokens such
    /// as `<think>` appear verbatim). Ends at end-of-generation or `maxTokens`.
    func generate(prompt: String, options: GenerationOptions) -> AsyncThrowingStream<String, Error>

    /// True when the most recent `generate` ended because the model produced an
    /// end-of-generation token (as opposed to `maxTokens`, a stop sequence or cancel).
    var lastStopWasEndOfGeneration: Bool { get }

    /// Number of tokens `text` occupies.
    func tokenCount(_ text: String) async throws -> Int

    /// Stops an in-flight `generate` as soon as possible. The stream still delivers
    /// every piece that was evaluated before it finishes — consumers should keep
    /// reading until the end rather than breaking out.
    func cancel()

    /// Forgets all evaluated state (new conversation).
    func reset() async

    /// Hint: a prefix (the system block) worth snapshotting so that a full re-prefill
    /// after compaction can restore it instead of re-evaluating it.
    func setPinnedPrefix(_ prefix: String) async
}

public extension TextGenerator {
    func setPinnedPrefix(_ prefix: String) async {}
}
