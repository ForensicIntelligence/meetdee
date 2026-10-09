import DeeCore
import Foundation
import llama
import os
import Synchronization

/// Qwen3.5 (or any GGUF) running in-process through llama.cpp.
///
/// All llama.cpp calls happen on one private serial queue — the C API is not
/// thread-safe per context, and long blocking decodes must stay off Swift's
/// cooperative pool.
///
/// **Append-only state.** The engine remembers the exact bytes it has evaluated
/// (`cached`). When a new prompt starts with those bytes, only the remainder is
/// evaluated. Qwen3.5 is a hybrid recurrent model whose state can't be rewound to an
/// arbitrary point, so any other prompt means: clear, restore the pinned system-block
/// snapshot if it matches, and evaluate the rest.
public final class LlamaEngine: TextGenerator, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var modelPath: String
        public var contextLength: Int = 4096
        public var batchSize: Int = 512
        /// -1 = offload every layer to Metal. 0 = CPU only.
        public var gpuLayers: Int32 = LlamaEngine.defaultGPULayers
        public var threads: Int32 = LlamaEngine.defaultThreads

        public init(modelPath: String) { self.modelPath = modelPath }
    }

    public static var defaultGPULayers: Int32 {
        #if targetEnvironment(simulator)
        0 // The Simulator's Metal lacks features ggml-metal needs.
        #else
        -1
        #endif
    }

    public static var defaultThreads: Int32 {
        Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount - 2)))
    }

    public let configuration: Configuration
    public var contextLength: Int { configuration.contextLength }
    /// Human-readable description from the GGUF ("qwen35 4B Q4_K - Medium").
    public let modelDescription: String
    public let parameterCount: UInt64

    private let queue = DispatchQueue(label: "dee.llama", qos: .userInitiated)
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let nVocab: Int32
    private var batch: llama_batch

    // Queue-confined state.
    private var cached: [UInt8] = []
    private var nPast: Int32 = 0
    private var pinnedPrefix: [UInt8] = []
    private var pinnedState: [UInt8]?
    private var pinnedPast: Int32 = 0

    /// One cancellation flag per `generate` call, so cancelling (or abandoning) one
    /// stream can never be undone by the next call resetting a shared flag.
    private final class CancelFlag: Sendable {
        let value = Atomic<Bool>(false)
        var isSet: Bool { value.load(ordering: .acquiring) }
        func set() { value.store(true, ordering: .releasing) }
    }
    private let currentCancel = Mutex(CancelFlag())
    private let lastEOG = Atomic<Bool>(false)
    private let statsBox = Mutex(Stats())
    public var stats: Stats { statsBox.withLock { $0 } }

    public struct Stats: Sendable {
        public var promptTokens = 0
        public var promptSeconds = 0.0
        public var generatedTokens = 0
        public var generateSeconds = 0.0
        public var reusedBytes = 0
        public var fullPrefills = 0
        public var snapshotRestores = 0
        public var prefillTokensPerSecond: Double { promptSeconds > 0 ? Double(promptTokens) / promptSeconds : 0 }
        public var generateTokensPerSecond: Double { generateSeconds > 0 ? Double(generatedTokens) / generateSeconds : 0 }
    }

    static let log = Logger(subsystem: "ca.forensicintelligence.dee", category: "llama")

    private static let backendInit: Void = {
        llama_log_set({ level, text, _ in
            guard let text, level.rawValue >= GGML_LOG_LEVEL_WARN.rawValue else { return }
            LlamaEngine.log.notice("\(String(cString: text), privacy: .public)")
        }, nil)
        llama_backend_init()
    }()

    // MARK: - Loading

    /// Loads the model and creates a context. Runs off the caller's thread.
    public static func load(_ configuration: Configuration, progress: (@Sendable (Double) -> Void)? = nil) async throws -> LlamaEngine {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try LlamaEngine(configuration, progress: progress))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private final class ProgressBox {
        let callback: @Sendable (Double) -> Void
        init(_ callback: @escaping @Sendable (Double) -> Void) { self.callback = callback }
    }

    private init(_ configuration: Configuration, progress: (@Sendable (Double) -> Void)?) throws {
        _ = Self.backendInit
        self.configuration = configuration
        guard FileManager.default.fileExists(atPath: configuration.modelPath) else {
            throw GeneratorError.loadFailed("model file not found at \(configuration.modelPath)")
        }

        var mp = llama_model_default_params()
        mp.n_gpu_layers = configuration.gpuLayers
        // mmap: weights are clean, file-backed pages the OS can evict and re-read,
        // which keeps a 2.7 GB model inside an iPhone's memory limit.
        mp.load_mode = LLAMA_LOAD_MODE_MMAP
        let box = progress.map(ProgressBox.init)
        if let box {
            mp.progress_callback = { value, user in
                Unmanaged<ProgressBox>.fromOpaque(user!).takeUnretainedValue().callback(Double(value))
                return true
            }
            mp.progress_callback_user_data = Unmanaged.passUnretained(box).toOpaque()
        }
        guard let model = withExtendedLifetime(box, { llama_model_load_from_file(configuration.modelPath, mp) }) else {
            throw GeneratorError.loadFailed("llama.cpp could not load \(URL(fileURLWithPath: configuration.modelPath).lastPathComponent)")
        }

        var cp = llama_context_default_params()
        cp.n_ctx = UInt32(configuration.contextLength)
        cp.n_batch = UInt32(configuration.batchSize)
        cp.n_ubatch = UInt32(configuration.batchSize)
        cp.n_seq_max = 1
        cp.n_threads = configuration.threads
        cp.n_threads_batch = configuration.threads
        cp.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO
        cp.no_perf = true
        guard let context = llama_init_from_model(model, cp) else {
            llama_model_free(model)
            throw GeneratorError.loadFailed("could not create a \(configuration.contextLength)-token context (out of memory?)")
        }

        self.model = model
        self.context = context
        self.vocab = llama_model_get_vocab(model)
        self.nVocab = llama_vocab_n_tokens(vocab)
        self.batch = llama_batch_init(Int32(configuration.batchSize), 0, 1)

        var desc = [CChar](repeating: 0, count: 256)
        llama_model_desc(model, &desc, desc.count)
        self.modelDescription = String(decoding: desc.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        self.parameterCount = llama_model_n_params(model)
    }

    deinit {
        llama_batch_free(batch)
        llama_free(context)
        llama_model_free(model)
    }

    // MARK: - TextGenerator

    public var lastStopWasEndOfGeneration: Bool { lastEOG.load(ordering: .acquiring) }

    public func cancel() { currentCancel.withLock { $0 }.set() }

    public func reset() async {
        await onQueue { self.clearState() }
    }

    public func setPinnedPrefix(_ prefix: String) async {
        let bytes = Array(prefix.utf8)
        await onQueue {
            guard bytes != self.pinnedPrefix else { return }
            self.pinnedPrefix = bytes
            self.pinnedState = nil
        }
    }

    public func tokenCount(_ text: String) async throws -> Int {
        try await onQueue { try self.tokenize(text).count }
    }

    public func generate(prompt: String, options: GenerationOptions) -> AsyncThrowingStream<String, Error> {
        let flag = CancelFlag()
        currentCancel.withLock { $0 = flag }
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { reason in
                if case .cancelled = reason { flag.set() }
            }
            queue.async {
                self.lastEOG.store(false, ordering: .releasing)
                do {
                    try self.run(prompt: prompt, options: options, cancel: flag) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Queue-confined implementation

    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in
            queue.async { c.resume(with: Result { try work() }) }
        }
    }

    private func onQueue(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { c in
            queue.async { work(); c.resume() }
        }
    }

    private func clearState() {
        llama_memory_clear(llama_get_memory(context), true)
        cached.removeAll(keepingCapacity: true)
        nPast = 0
    }

    private func run(prompt: String, options: GenerationOptions, cancel: CancelFlag, yield: (String) -> Void) throws {
        if cancel.isSet { return }
        let promptBytes = Array(prompt.utf8)
        var suffix: ArraySlice<UInt8>

        if !cached.isEmpty, promptBytes.count >= cached.count, promptBytes.starts(with: cached) {
            suffix = promptBytes[cached.count...]
            let reused = cached.count
            statsBox.withLock { $0.reusedBytes += reused }
        } else {
            clearState()
            statsBox.withLock { $0.fullPrefills += 1 }
            suffix = promptBytes[...]
            if !pinnedPrefix.isEmpty, promptBytes.starts(with: pinnedPrefix) {
                if let state = pinnedState, restore(state) {
                    statsBox.withLock { $0.snapshotRestores += 1 }
                } else {
                    try evaluate(String(decoding: pinnedPrefix, as: UTF8.self), bytes: pinnedPrefix[...], wantLogits: false, cancel: cancel)
                    pinnedState = snapshot()
                    pinnedPast = nPast
                    if let size = pinnedState?.count {
                        Self.log.info("Pinned system snapshot: \(self.nPast) tokens, \(size) bytes")
                    }
                }
                suffix = promptBytes[pinnedPrefix.count...]
            }
        }

        if !suffix.isEmpty {
            try evaluate(String(decoding: suffix, as: UTF8.self), bytes: suffix, wantLogits: true, cancel: cancel)
        }
        try sampleLoop(options: options, cancel: cancel, yield: yield)
    }

    /// Restores the pinned snapshot into an empty context.
    private func restore(_ state: [UInt8]) -> Bool {
        let read = state.withUnsafeBufferPointer { llama_state_seq_set_data_ext(context, $0.baseAddress, $0.count, 0, 0) }
        guard read > 0 else {
            clearState()
            return false
        }
        cached = pinnedPrefix
        nPast = pinnedPast
        return true
    }

    private func snapshot() -> [UInt8]? {
        let size = llama_state_seq_get_size_ext(context, 0, 0)
        guard size > 0 else { return nil }
        var data = [UInt8](repeating: 0, count: size)
        let written = data.withUnsafeMutableBufferPointer { llama_state_seq_get_data_ext(context, $0.baseAddress, size, 0, 0) }
        return written == size ? data : nil
    }

    private func tokenize(_ text: String) throws -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 8)
        var n = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), false, true)
        if n < 0 {
            guard n != Int32.min else { throw GeneratorError.tokenizeFailed }
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), false, true)
            guard n >= 0 else { throw GeneratorError.tokenizeFailed }
        }
        return Array(tokens.prefix(Int(n)))
    }

    /// Evaluates `text` on top of the current state and records it in `cached`.
    private func evaluate(_ text: String, bytes: ArraySlice<UInt8>, wantLogits: Bool, cancel: CancelFlag) throws {
        let tokens = try tokenize(text)
        guard !tokens.isEmpty else { return }
        let available = configuration.contextLength - Int(nPast)
        guard tokens.count < available else {
            throw GeneratorError.contextOverflow(needed: Int(nPast) + tokens.count, available: configuration.contextLength)
        }

        let start = Date()
        var index = 0
        while index < tokens.count {
            // A long prefill (after compaction) can take seconds on a phone; honour
            // Stop between chunks. The partial state is useless, so clear it.
            if cancel.isSet {
                clearState()
                return
            }
            let chunk = min(configuration.batchSize, tokens.count - index)
            batch.n_tokens = Int32(chunk)
            for i in 0..<chunk {
                batch.token[i] = tokens[index + i]
                batch.pos[i] = nPast + Int32(index + i)
                batch.n_seq_id[i] = 1
                batch.seq_id[i]![0] = 0
                batch.logits[i] = 0
            }
            let isLast = index + chunk == tokens.count
            if isLast && wantLogits { batch.logits[chunk - 1] = 1 }
            let rc = llama_decode(context, batch)
            guard rc == 0 else {
                clearState()
                throw GeneratorError.decodeFailed(rc)
            }
            index += chunk
        }
        nPast += Int32(tokens.count)
        cached.append(contentsOf: bytes)
        let elapsed = Date().timeIntervalSince(start)
        statsBox.withLock {
            $0.promptTokens += tokens.count
            $0.promptSeconds += elapsed
        }
    }

    private func makeSampler(_ s: SamplingConfig) -> UnsafeMutablePointer<llama_sampler> {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        if s.temperature <= 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
            return chain
        }
        if s.presencePenalty != 0 || s.repeatPenalty != 1 {
            llama_sampler_chain_add(chain, llama_sampler_init_penalties(nVocab, s.penaltyWindow, s.repeatPenalty, 0, s.presencePenalty))
        }
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(s.topK))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(s.topP, 1))
        if s.minP > 0 { llama_sampler_chain_add(chain, llama_sampler_init_min_p(s.minP, 1)) }
        llama_sampler_chain_add(chain, llama_sampler_init_temp(s.temperature))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(s.seed))
        return chain
    }

    private func sampleLoop(options: GenerationOptions, cancel: CancelFlag, yield: (String) -> Void) throws {
        // Prefill was cancelled (state cleared): nothing to sample from.
        if cancel.isSet && nPast == 0 { return }
        let sampler = makeSampler(options.sampling)
        defer { llama_sampler_free(sampler) }

        let stops = options.stopSequences.map { Array($0.utf8) }.filter { !$0.isEmpty }
        var generated: [UInt8] = []
        var utf8 = UTF8Assembler()
        let start = Date()
        var count = 0
        defer {
            let elapsed = Date().timeIntervalSince(start)
            statsBox.withLock {
                $0.generatedTokens += count
                $0.generateSeconds += elapsed
            }
        }

        var stopRequested = false
        var overrun = 0
        while true {
            if Int(nPast) >= configuration.contextLength - 1 { break }
            if count >= options.maxTokens || cancel.isSet || stopRequested {
                // Never stop inside a multi-byte character: the bytes in `cached`
                // must equal the text handed out, or the next prompt can't extend
                // the state. A few extra tokens complete it.
                guard utf8.hasPending, overrun < 4 else { break }
                overrun += 1
            }

            let token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) {
                lastEOG.store(true, ordering: .releasing)
                break
            }
            let piece = tokenPiece(token)

            batch.n_tokens = 1
            batch.token[0] = token
            batch.pos[0] = nPast
            batch.n_seq_id[0] = 1
            batch.seq_id[0]![0] = 0
            batch.logits[0] = 1
            let rc = llama_decode(context, batch)
            guard rc == 0 else {
                clearState()
                throw GeneratorError.decodeFailed(rc)
            }
            nPast += 1
            count += 1
            cached.append(contentsOf: piece)
            generated.append(contentsOf: piece)
            if let text = utf8.append(piece) { yield(text) }

            if !stopRequested, Self.containsStop(stops, in: generated, newBytes: piece.count) { stopRequested = true }
        }
        if let rest = utf8.flush() { yield(rest) }
    }

    /// True when a stop sequence ends inside the bytes just added (not only exactly
    /// at the end — a piece like ">\n\n" can complete "</think>" mid-piece).
    static func containsStop(_ stops: [[UInt8]], in generated: [UInt8], newBytes: Int) -> Bool {
        for stop in stops {
            let window = min(generated.count, stop.count + newBytes - 1)
            guard window >= stop.count else { continue }
            let tail = generated.suffix(window)
            if tail.firstRange(of: stop) != nil { return true }
        }
        return false
    }

    private func tokenPiece(_ token: llama_token) -> [UInt8] {
        var buf = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, true)
        if n < 0 {
            buf = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, true)
        }
        return buf.prefix(Int(max(0, n))).map { UInt8(bitPattern: $0) }
    }
}

/// Turns a byte stream that may split multi-byte UTF-8 characters across token
/// pieces into whole-character strings.
struct UTF8Assembler {
    private var pending: [UInt8] = []
    var hasPending: Bool { !pending.isEmpty }

    mutating func append(_ bytes: [UInt8]) -> String? {
        pending.append(contentsOf: bytes)
        let cut = Self.completePrefixLength(pending)
        guard cut > 0 else { return nil }
        let text = String(decoding: pending[..<cut], as: UTF8.self)
        pending.removeFirst(cut)
        return text
    }

    mutating func flush() -> String? {
        defer { pending.removeAll() }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }

    /// Length of the longest prefix that doesn't end inside a multi-byte sequence.
    static func completePrefixLength(_ bytes: [UInt8]) -> Int {
        var i = bytes.count - 1
        var continuation = 0
        while i >= 0, bytes[i] & 0xC0 == 0x80, continuation < 3 {
            i -= 1
            continuation += 1
        }
        guard i >= 0 else { return bytes.count } // all continuation bytes: give up, emit
        let lead = bytes[i]
        let expected: Int
        switch lead {
        case 0x00...0x7F: expected = 1
        case 0xC0...0xDF: expected = 2
        case 0xE0...0xEF: expected = 3
        case 0xF0...0xF7: expected = 4
        default: expected = 1
        }
        return continuation + 1 >= expected ? bytes.count : i
    }
}
