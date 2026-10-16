import Foundation
import Synchronization
import DeeCore
import DeeRealtime

/// An in-process realtime-protocol emulator for modes 2 and 3 (contract §2).
///
/// `RealtimeSession` talks to it exactly as to OpenAI's socket, so everything tuned above
/// the wire (EarCore, holds, speculative gate, TurnPolicy, the one-DNA-item rule, preempt,
/// HeardRule) runs unchanged. Inside: `CascadeHearing` (turn detection + speech-to-text) →
/// `/v1/chat/completions` on the LAN (`CascadeChat`) → `CascadeVoice` (text-to-speech), in
/// realtime event order:
/// speech_started/stopped (on its own fed-frame clock) → committed (always before transcripts)
/// → transcription delta/completed → response.created **at the first chat token** →
/// output_item.added → per sentence transcript.delta **then** audio.delta → … → response.done.
///
/// It never touches the network itself: every request goes through the parts' `Transport`.
public final class CascadeSocket: RealtimeSocket, @unchecked Sendable {
    private let engine: CascadeEngine
    private let stream: AsyncStream<SocketEvent>
    private let continuation: AsyncStream<SocketEvent>.Continuation
    private let inbox: AsyncStream<String>
    private let inboxContinuation: AsyncStream<String>.Continuation

    private struct State { var opened = false; var finished = false; var pump: Task<Void, Never>? }
    private let state = Mutex(State())

    /// Problems for the status chip (provider-named; never falls back).
    public let problems: AsyncStream<ProviderIssue>
    private let problemContinuation: AsyncStream<ProviderIssue>.Continuation

    public init(options: CascadeOptions, hearing: any CascadeHearing, chat: any CascadeChat, voice: any CascadeVoice,
                stats: CascadeStats? = nil) {
        (stream, continuation) = AsyncStream<SocketEvent>.makeStream(bufferingPolicy: .unbounded)
        (inbox, inboxContinuation) = AsyncStream<String>.makeStream(bufferingPolicy: .unbounded)
        (problems, problemContinuation) = AsyncStream<ProviderIssue>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let out = continuation
        let problemOut = problemContinuation
        engine = CascadeEngine(options: options, hearing: hearing, chat: chat, voice: voice, stats: stats ?? CascadeStats(),
                               emit: { event in
                                   if let text = try? event.jsonText() { out.yield(.text(text)) }
                               },
                               problem: { problemOut.yield($0) })
    }

    public var stats: CascadeStats { engine.stats }

    // MARK: RealtimeSocket

    public var incoming: AsyncStream<SocketEvent> { stream }

    public func open() async throws {
        let finished = state.withLock { $0.finished }
        if finished { throw SocketFailure.network("closed") }
        do {
            try await engine.start()
        } catch let issue as ProviderIssue {
            problemContinuation.yield(issue)
            throw SocketFailure.network(issue.message)
        }
        let pump = Task { [engine, inbox] in
            for await text in inbox { await engine.client(text) }
        }
        state.withLock { $0.opened = true; $0.pump = pump }
    }

    public func send(_ text: String) {
        let ok = state.withLock { !$0.finished }
        guard ok else { return }
        inboxContinuation.yield(text)
    }

    public var pendingBytes: Int { 0 }

    public func close(code: Int, reason: String?) {
        let (wasFinished, opened, pump) = state.withLock { s -> (Bool, Bool, Task<Void, Never>?) in
            let r = (s.finished, s.opened, s.pump)
            s.finished = true
            s.pump = nil
            return r
        }
        guard !wasFinished else { return }
        inboxContinuation.finish()
        pump?.cancel()
        let engine = self.engine
        Task { await engine.shutdown() }
        if opened { continuation.yield(.closed(code: code, reason: reason, failure: nil)) }
        continuation.finish()
        problemContinuation.finish()
    }

    /// LAN brain warm-up (window opening): a 1-token request with the current prefix.
    public func warmUp() {
        let engine = self.engine
        Task { await engine.warmUp(reason: .open) }
    }
}

/// Counters for the harness / tests (numbers only, no text).
public final class CascadeStats: Sendable {
    public struct Snapshot: Sendable, Equatable {
        public var chatRequests = 0
        public var warmUps = 0
        public var committedTurns = 0
        public var responses = 0
        public var cancelled = 0
        public var toolCalls = 0
        public var reasoningCharsDropped = 0
        public var thinkEnds = 0
        public var spokenSentences = 0
        public var promptTokens = 0
        public var cachedTokens = 0
        /// response.create → first token, seconds.
        public var firstTokenSeconds: [Double] = []
        /// response.create → first audio delta, seconds.
        public var firstAudioSeconds: [Double] = []
        /// Gaps between one sentence's last audio and the next sentence's first, seconds.
        public var sentenceGaps: [Double] = []
    }
    private let state = Mutex(Snapshot())
    public init() {}
    public var snapshot: Snapshot { state.withLock { $0 } }
    func update(_ f: (inout Snapshot) -> Void) { state.withLock { f(&$0) } }
}

// MARK: - Engine

actor CascadeEngine {
    enum WarmReason { case open, speech }

    let options: CascadeOptions
    let hearing: any CascadeHearing
    let chat: any CascadeChat
    let voice: any CascadeVoice
    nonisolated let stats: CascadeStats
    let emit: @Sendable (ServerEvent) -> Void
    let problem: @Sendable (ProviderIssue) -> Void

    // Session
    private var created = false
    private var instructions = ""
    private var tools: [RealtimeTool] = []
    private var speed = 1.0
    private var sessionEcho: [String: RealtimeJSON] = [:]

    // Conversation
    struct Item {
        enum Kind {
            case system(String)
            case user(String?)          // nil = transcript pending
            case assistant(Assistant)
            case functionCall(callID: String, name: String, arguments: String)
            case functionOutput(callID: String, output: String)
        }
        var id: String
        var kind: Kind
    }
    struct Assistant {
        /// Spoken chunks and where each ends in the item's audio (ms).
        var chunks: [(text: String, endMs: Int)] = []
        var heardChunks: Int?      // set by truncate
        var text: String {
            let n = heardChunks ?? chunks.count
            return chunks.prefix(n).map(\.text).joined(separator: " ")
        }
    }
    private var items: [Item] = []
    private var counter = 0
    private var fedFrames: Int64 = 0
    private var turnItems: [Int: String] = [:]
    private var pendingTranscripts: Set<String> = []
    private var rollingSummary: [String] = []
    private var lastStable: String?

    // Responses
    final class Run: @unchecked Sendable {
        let token: Int
        let eventID: String?
        let params: ResponseParams?
        let requestedAt: Date
        var id: String?
        var createdEmitted = false
        var createdAt: Date?
        var cancelled = false
        var task: Task<Void, Never>?
        var speaker: Speaker?
        var messageItemID: String?
        var outputItems: [RealtimeItem] = []
        init(token: Int, eventID: String?, params: ResponseParams?) {
            self.token = token; self.eventID = eventID; self.params = params; self.requestedAt = Date()
        }
    }
    private var current: Run?
    private var runToken = 0
    private var warmTask: Task<Void, Never>?
    private var warmedPrefix: Int?

    init(options: CascadeOptions, hearing: any CascadeHearing, chat: any CascadeChat, voice: any CascadeVoice,
         stats: CascadeStats, emit: @escaping @Sendable (ServerEvent) -> Void,
         problem: @escaping @Sendable (ProviderIssue) -> Void) {
        self.options = options; self.hearing = hearing; self.chat = chat; self.voice = voice; self.stats = stats
        self.emit = emit; self.problem = problem
    }

    private var hearingPump: Task<Void, Never>?

    func start() async throws {
        // One ordered pump: committed always reaches the session before its transcripts.
        let (events, sink) = AsyncStream<HearingEvent>.makeStream(bufferingPolicy: .unbounded)
        hearingPump = Task { [weak self] in
            for await e in events {
                guard let self else { return }
                await self.heard(e)
            }
        }
        do {
            try await hearing.start { event in sink.yield(event) }
        } catch {
            hearingPump?.cancel()
            throw error
        }
        Task { [voice] in await voice.prepare() }
    }

    func shutdown() {
        current?.cancelled = true
        current?.task?.cancel()
        if let speaker = current?.speaker { Task { await speaker.dropUnstarted() } }
        current = nil
        warmTask?.cancel()
        hearingPump?.cancel()
        hearing.stop()
    }

    private func nextID(_ prefix: String) -> String {
        counter += 1
        return "\(prefix)_\(counter)"
    }

    // MARK: Client events

    func client(_ text: String) async {
        guard let event = try? CascadeWire.decodeClient(text) else { return }
        switch event {
        case .sessionUpdate(let p, _):
            sessionUpdate(p)
        case .inputAudioAppend(let audio, _):
            guard let pcm = Data(base64Encoded: audio), !pcm.isEmpty else { return }
            let at = fedFrames
            fedFrames += Int64(pcm.count / 2)
            hearing.feed(pcm, atFrame: at)
        case .inputAudioCommit:
            hearing.commitNow()
        case .inputAudioClear:
            hearing.clear()
            emit(.inputAudioCleared(.init()))
        case .itemCreate(let item, let previous, _):
            create(item, after: previous)
        case .itemRetrieve(let id, _):
            if items.contains(where: { $0.id == id }) {
                emit(.itemRetrieved(.init(item: RealtimeItem(id: id, type: "message", status: "completed"))))
            }
        case .itemTruncate(let id, _, let ms, _):
            truncate(id, ms: ms)
        case .itemDelete(let id, _):
            if let idx = items.firstIndex(where: { $0.id == id }) {
                items.remove(at: idx)
                emit(.itemDeleted(.init(itemID: id)))
            }
        case .responseCreate(let params, let eid):
            await responseCreate(params, eventID: eid)
        case .responseCancel(let rid, _):
            cancel(responseID: rid)
        case .outputAudioBufferClear:
            break
        }
    }

    private func sessionUpdate(_ p: SessionPayload) {
        if let i = p.instructions { instructions = i }
        if let t = p.tools { tools = t }
        if let s = p.audio?.output?.speed { speed = s }
        if let words = p.audio?.input?.transcription?.value?.keywords { hearing.setKeywords(words) }
        if let o = RealtimeJSON.parse((try? CascadeWire.encodeAny(p)) ?? ""), case .object(let obj) = o {
            sessionEcho.merge(obj) { _, b in b }
        }
        var echo = sessionEcho
        echo["id"] = "sess_cascade"
        echo["object"] = "realtime.session"
        echo["model"] = .string(options.model)
        let info = SessionInfo(raw: .object(echo))
        let first = !created
        if first {
            created = true
            emit(.sessionCreated(.init(eventID: nextID("event"), session: info)))
        }
        emit(.sessionUpdated(.init(eventID: nextID("event"), session: info)))
        // The window just opened: load the model and fill the prefix cache while they talk.
        if first, options.warmUps { warmUp(reason: .open) }
    }

    private func create(_ item: RealtimeItem, after previous: String?) {
        let id = item.id ?? nextID("item")
        let kind: Item.Kind
        switch item.type {
        case "function_call_output":
            kind = .functionOutput(callID: item.callID ?? "", output: item.output ?? "")
        case "function_call":
            kind = .functionCall(callID: item.callID ?? "", name: item.name ?? "", arguments: item.arguments ?? "{}")
        default:
            let text = item.text ?? ""
            switch item.role {
            case "system": kind = .system(text)
            case "assistant":
                var a = Assistant(); a.chunks = [(text, 0)]; kind = .assistant(a)
            default: kind = .user(text)
            }
        }
        let new = Item(id: id, kind: kind)
        var prev: String? = items.last?.id
        if let previous, let idx = items.firstIndex(where: { $0.id == previous }) {
            items.insert(new, at: idx + 1)
            prev = previous
        } else if previous == "root" {
            items.insert(new, at: 0)
            prev = nil
        } else {
            items.append(new)
        }
        var echoed = item
        echoed.id = id
        echoed.status = "completed"
        emit(.itemAdded(.init(eventID: nextID("event"), previousItemID: prev, item: echoed)))
        emit(.itemDone(.init(eventID: nextID("event"), previousItemID: prev, item: echoed)))
    }

    private func truncate(_ id: String, ms: Int) {
        guard let idx = items.firstIndex(where: { $0.id == id }), case .assistant(var a) = items[idx].kind else { return }
        let hints = a.chunks.map(\.endMs)
        a.heardChunks = HeardRule.heardCount(hints: hints, playedMs: ms)
        items[idx].kind = .assistant(a)
        emit(.itemTruncated(.init(itemID: id, contentIndex: 0, audioEndMs: ms)))
    }

    // MARK: Hearing

    func heard(_ e: HearingEvent) async {
        switch e {
        case .speechStarted(let turn, let frame):
            let id = turnItems[turn] ?? nextID("item")
            turnItems[turn] = id
            emit(.speechStarted(.init(eventID: nextID("event"), audioStartMs: Int(frame / 24), itemID: id)))
            if options.warmUps, current == nil { warmUp(reason: .speech) }
        case .speechStopped(let turn, let frame):
            let id = turnItems[turn] ?? nextID("item")
            turnItems[turn] = id
            emit(.speechStopped(.init(eventID: nextID("event"), audioEndMs: Int(frame / 24), itemID: id)))
        case .committed(let turn):
            let id = turnItems[turn] ?? nextID("item")
            turnItems[turn] = id
            let prev = items.last?.id
            items.append(Item(id: id, kind: .user(nil)))
            pendingTranscripts.insert(id)
            stats.update { $0.committedTurns += 1 }
            emit(.inputAudioCommitted(.init(eventID: nextID("event"), previousItemID: prev, itemID: id)))
            let item = RealtimeItem(id: id, type: "message", status: "completed", role: "user",
                                    content: [RealtimeContent(type: "input_audio", transcript: nil)])
            emit(.itemAdded(.init(eventID: nextID("event"), previousItemID: prev, item: item)))
        case .transcriptDelta(let turn, let delta):
            guard let id = turnItems[turn] else { return }
            emit(.inputTranscriptionDelta(.init(eventID: nextID("event"), itemID: id, delta: delta)))
        case .transcriptCompleted(let turn, let text):
            guard let id = turnItems[turn] else { return }
            if let idx = items.firstIndex(where: { $0.id == id }) { items[idx].kind = .user(text) }
            pendingTranscripts.remove(id)
            emit(.inputTranscriptionCompleted(.init(eventID: nextID("event"), itemID: id, transcript: text)))
        case .transcriptFailed(let turn, let message):
            guard let id = turnItems[turn] else { return }
            if let idx = items.firstIndex(where: { $0.id == id }) { items[idx].kind = .user("") }
            pendingTranscripts.remove(id)
            emit(.inputTranscriptionFailed(.init(eventID: nextID("event"), itemID: id,
                                                 error: APIError(type: "transcription_error", code: "stt_failed", message: message))))
        case .failed(let issue):
            problem(issue)
            emit(.error(.init(eventID: nextID("event"),
                              error: APIError(type: "server_error", code: "hearing_failed", message: issue.message))))
        }
    }

    // MARK: Responses

    private func responseCreate(_ params: ResponseParams?, eventID: String?) async {
        if let c = current, !c.cancelled {
            emit(.error(.init(eventID: nextID("event"),
                              error: APIError(type: "invalid_request_error", code: "conversation_already_has_active_response",
                                              message: "Conversation already has an active response", eventID: eventID))))
            return
        }
        runToken += 1
        let run = Run(token: runToken, eventID: eventID, params: params)
        current = run
        let outOfBand = params?.conversation == "none"
        // Debounce: an in-band reply waits for the transcripts it answers (no HTTP before them).
        if !outOfBand {
            let deadline = Date().addingTimeInterval(options.transcriptWait)
            while !pendingTranscripts.isEmpty, Date() < deadline, !run.cancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if run.cancelled { return }
        }
        warmTask = nil   // a running warm-up keeps going (same prefix: it fills the cache this request reuses)
        run.task = Task { await self.perform(run) }
    }

    private func cancel(responseID: String?) {
        guard let run = current, !run.cancelled else { return }
        if let responseID, let rid = run.id, responseID != rid { return }
        run.cancelled = true
        run.task?.cancel()
        if let speaker = run.speaker { Task { await speaker.dropUnstarted() } }
        stats.update { $0.cancelled += 1 }
        finish(run, status: "cancelled", reason: "client_cancelled", usage: nil)
    }

    /// Emits response.done once; frees `current`.
    private func finish(_ run: Run, status: String, reason: String?, usage: ChatUsage?, error: APIError? = nil) {
        guard current === run else { return }
        current = nil
        var details: ResponseStatusDetails?
        if status != "completed" || reason != nil {
            var o: [String: RealtimeJSON] = ["type": .string(status)]
            if let reason { o["reason"] = .string(reason) }
            if let error {
                var e: [String: RealtimeJSON] = [:]
                if let t = error.type { e["type"] = .string(t) }
                if let c = error.code { e["code"] = .string(c) }
                o["error"] = .object(e)
            }
            details = try? JSONDecoder().decode(ResponseStatusDetails.self, from: Data(RealtimeJSON.object(o).jsonText.utf8))
        }
        let u = usage.flatMap { u -> Usage? in
            var o: [String: RealtimeJSON] = ["total_tokens": .number(Double((u.promptTokens ?? 0) + (u.completionTokens ?? 0)))]
            if let p = u.promptTokens { o["input_tokens"] = .number(Double(p)) }
            if let c = u.completionTokens { o["output_tokens"] = .number(Double(c)) }
            var d: [String: RealtimeJSON] = [:]
            if let p = u.promptTokens { d["text_tokens"] = .number(Double(p)) }
            if let c = u.cachedTokens { d["cached_tokens"] = .number(Double(c)) }
            o["input_token_details"] = .object(d)
            return try? JSONDecoder().decode(Usage.self, from: Data(RealtimeJSON.object(o).jsonText.utf8))
        }
        let response = ResponseObject(id: run.createdEmitted ? run.id : nil, object: "realtime.response", status: status,
                                      statusDetails: details, output: run.outputItems,
                                      maxOutputTokens: run.params?.maxOutputTokens, usage: u,
                                      metadata: run.params?.metadata)
        emit(.responseDone(.init(eventID: nextID("event"), response: response)))
    }

    private func ensureCreated(_ run: Run) {
        guard !run.createdEmitted else { return }
        run.createdEmitted = true
        run.createdAt = Date()
        run.id = nextID("resp")
        let r = ResponseObject(id: run.id, object: "realtime.response", status: "in_progress",
                               output: [], maxOutputTokens: run.params?.maxOutputTokens, metadata: run.params?.metadata)
        emit(.responseCreated(.init(eventID: nextID("event"), response: r)))
    }

    private func perform(_ run: Run) async {
        let params = run.params
        let outOfBand = params?.conversation == "none"
        let textOnly = params?.outputModalities == ["text"]
        let liveDNA = items.last(where: { $0.id.hasPrefix("dna_") }).flatMap { item -> String? in
            if case .system(let t) = item.kind { t } else { nil }
        }
        let voiceWords = liveDNA.flatMap(CascadePrompt.voiceWords(inDNA:))
        // A verbatim `say`: spoken directly, no model call.
        if outOfBand, !textOnly, let say = CascadePrompt.verbatimLine(params?.instructions) {
            ensureCreated(run)
            let speaker = Speaker(engine: self, run: run, voiceWords: say.voiceWords ?? voiceWords)
            run.speaker = speaker
            await speaker.begin()
            await speaker.add(say.line)
            await speaker.end()
            if !run.cancelled { finish(run, status: "completed", reason: nil, usage: nil) }
            return
        }
        let request = buildRequest(params: params, outOfBand: outOfBand, textOnly: textOnly, dna: liveDNA)
        let native = !outOfBand && chat.vendor == .ollama && items.last.map { if case .functionOutput = $0.kind { true } else { false } } == true
        stats.update { $0.chatRequests += 1 }
        var stripper = ThinkStripper()
        var chunker = SentenceChunker()
        var calls: [Int: (id: String?, name: String?, args: String)] = [:]
        var wholeCalls: [ChatToolCall] = []
        var usage: ChatUsage?
        var finishReason = "stop"
        var text = ""
        let speaker = Speaker(engine: self, run: run, voiceWords: voiceWords)
        run.speaker = speaker
        var gotFirstToken = false
        func firstToken() {
            guard !gotFirstToken else { return }
            gotFirstToken = true
            let dt = Date().timeIntervalSince(run.requestedAt)
            stats.update { $0.firstTokenSeconds.append(dt) }
        }
        do {
            loop: for try await piece in chat.stream(request, nativeRoute: native) {
                if run.cancelled || Task.isCancelled { return }
                switch piece {
                case .model(let m):
                    if options.checkModelEcho, !request.model.isEmpty, !Self.sameModel(m, request.model) {
                        throw CompatError.modelMismatch(asked: request.model, got: m)
                    }
                case .reasoning(let n):
                    stats.update { $0.reasoningCharsDropped += n }
                case .content(let c):
                    firstToken()
                    ensureCreated(run)
                    if textOnly {
                        text += c
                        continue
                    }
                    for out in stripper.push(c) {
                        switch out {
                        case .text(let t):
                            for chunk in chunker.push(t) { await speaker.add(chunk) }
                        case .end:
                            stats.update { $0.thinkEnds += 1 }
                            break loop
                        }
                    }
                case .toolCallDelta(let index, let id, let name, let args):
                    firstToken()
                    ensureCreated(run)
                    var c = calls[index] ?? (nil, nil, "")
                    if let id { c.id = id }
                    if let name, !name.isEmpty { c.name = name }
                    c.args += args
                    calls[index] = c
                case .toolCall(let call):
                    firstToken()
                    ensureCreated(run)
                    wholeCalls.append(call)
                case .finish(let reason):
                    finishReason = reason
                case .usage(let u):
                    usage = u
                case .error(_, let message):
                    throw CompatError.streamError(message)
                }
            }
        } catch {
            if run.cancelled || Task.isCancelled { return }
            let issue = (error as? CompatError)?.issue(host: chat.host, vendor: chat.vendor, model: request.model,
                                                       label: chat.label)
                ?? ProviderIssue.unreachable(host: chat.host, vendor: chat.vendor)
            problem(issue)
            await speaker.end()
            ensureCreated(run)
            finish(run, status: "failed", reason: nil, usage: usage,
                   error: APIError(type: "server_error", code: Self.code(for: issue), message: nil))
            return
        }
        if run.cancelled { return }
        if let u = usage {
            stats.update { $0.promptTokens += u.promptTokens ?? 0; $0.cachedTokens += u.cachedTokens ?? 0 }
        }
        var toolCalls = wholeCalls
        for k in calls.keys.sorted() {
            let c = calls[k]!
            toolCalls.append(ChatToolCall(id: c.id ?? "call_\(nextID("c"))", name: c.name ?? "", arguments: c.args.isEmpty ? "{}" : c.args))
        }
        if textOnly {
            ensureCreated(run)
            let itemID = nextID("item")
            let clean = ThinkStripper.stripAll(text)
            emit(.outputTextDelta(.init(responseID: run.id ?? "", itemID: itemID, delta: clean)))
            emit(.outputTextDone(.init(responseID: run.id ?? "", itemID: itemID, text: clean)))
            run.outputItems.append(RealtimeItem(id: itemID, type: "message", status: "completed", role: "assistant",
                                                content: [.init(type: "output_text", text: clean)]))
            stats.update { $0.responses += 1 }
            finish(run, status: "completed", reason: nil, usage: usage)
            return
        }
        if toolCalls.isEmpty {
            for out in stripper.finish() { if case .text(let t) = out { for chunk in chunker.push(t) { await speaker.add(chunk) } } }
            for chunk in chunker.finish() { await speaker.add(chunk) }
        } else {
            // A tool call discards what was not spoken yet.
            await speaker.dropUnstarted()
        }
        await speaker.end()
        if run.cancelled { return }
        if !toolCalls.isEmpty {
            ensureCreated(run)
            stats.update { $0.toolCalls += toolCalls.count }
            for call in toolCalls {
                let itemID = nextID("item")
                let item = RealtimeItem(id: itemID, type: "function_call", status: "completed", callID: call.id,
                                        name: call.name, arguments: call.arguments)
                if !outOfBand {
                    items.append(Item(id: itemID, kind: .functionCall(callID: call.id, name: call.name, arguments: call.arguments)))
                }
                var added = item
                added.status = "in_progress"
                added.arguments = ""
                emit(.outputItemAdded(.init(responseID: run.id, outputIndex: run.outputItems.count, item: added)))
                emit(.functionCallArgumentsDone(.init(responseID: run.id ?? "", itemID: itemID, callID: call.id,
                                                      name: call.name, arguments: call.arguments)))
                emit(.outputItemDone(.init(responseID: run.id, outputIndex: run.outputItems.count, item: item)))
                run.outputItems.append(item)
            }
        }
        stats.update { $0.responses += 1 }
        let incomplete = finishReason == "length"
        finish(run, status: incomplete ? "incomplete" : "completed", reason: incomplete ? "max_output_tokens" : nil, usage: usage)
    }

    static func sameModel(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        if x == y { return true }
        // "qwen3.8:27b" vs "qwen3.8:27b-…" tags, "library/x" prefixes.
        return x.hasSuffix("/" + y) || y.hasSuffix("/" + x)
    }

    static func code(for issue: ProviderIssue) -> String {
        switch issue {
        case .unreachable, .timedOut: "lan_unreachable"
        case .lanNeedsKey, .badOpenAIKey: "invalid_api_key"
        case .modelMissing: "model_not_found"
        case .modelMismatch: "model_mismatch"
        case .redirected: "redirect_refused"
        case .rateLimited: "rate_limit_exceeded"
        default: "server_error"
        }
    }

    // MARK: Speaking (called by Speaker)

    /// Records a finished assistant message item.
    fileprivate func recordAssistant(_ run: Run, itemID: String, chunks: [(String, Int)], outOfBand: Bool) {
        var a = Assistant()
        a.chunks = chunks.map { (text: $0.0, endMs: $0.1) }
        if !outOfBand { items.append(Item(id: itemID, kind: .assistant(a))) }
        let transcript = a.chunks.map(\.text).joined(separator: " ")
        run.outputItems.append(RealtimeItem(id: itemID, type: "message", status: "completed", role: "assistant",
                                            content: [.init(type: "output_audio", transcript: transcript)]))
    }

    fileprivate func emitEvent(_ e: ServerEvent) { emit(e) }
    /// A response's own event: dropped once that response is done or cancelled (nothing after response.done).
    fileprivate func emit(_ e: ServerEvent, for run: Run) { if current === run && !run.cancelled { emit(e) } }
    fileprivate func newID(_ p: String) -> String { nextID(p) }
    fileprivate var sessionSpeed: Double { speed }
    fileprivate func isLive(_ run: Run) -> Bool { current === run && !run.cancelled }
    fileprivate func noteSentence(gap: Double?) {
        stats.update { s in s.spokenSentences += 1; if let gap { s.sentenceGaps.append(gap) } }
    }
    fileprivate func noteFirstAudio(_ run: Run) {
        let dt = Date().timeIntervalSince(run.requestedAt)
        stats.update { $0.firstAudioSeconds.append(dt) }
    }
    fileprivate func failVoice(_ issue: ProviderIssue) { problem(issue) }
    fileprivate var voiceStyle: String { options.voiceStyle }

    // MARK: Prompt

    /// [system: session instructions + speech style + tool policy] [system: DNA stable, resent only when changed]
    /// [system: rolling summary] [history ≤ N heard messages, tool calls/results] [user: DNA volatile + notes + transcript].
    func buildRequest(params: ResponseParams?, outOfBand: Bool, textOnly: Bool, dna: String?, maxTokensOverride: Int? = nil) -> ChatRequest {
        var maxTokens = options.defaultMaxTokens
        if case .limit(let n) = params?.maxOutputTokens { maxTokens = min(n, 1024) }
        if let maxTokensOverride { maxTokens = maxTokensOverride }
        let useTools = options.toolsSupported && !outOfBand && !textOnly && params?.tools != [] && !tools.isEmpty
        if outOfBand {
            var messages: [ChatMessage] = [.system(params?.instructions ?? instructions)]
            for item in params?.input ?? [] {
                let t = item.text ?? ""
                switch item.role {
                case "system": messages.append(.system(t))
                case "assistant": messages.append(.assistant(t))
                default: messages.append(.user(t))
                }
            }
            if messages.last?.role != .user { messages.append(.user("Go ahead.")) }
            return ChatRequest(model: options.model, messages: messages, maxTokens: maxTokens, keepAlive: options.keepAlive)
        }
        var sys1 = params?.instructions ?? instructions
        sys1 += "\n\n" + CascadePrompt.speechStyle
        if useTools { sys1 += "\n\n" + CascadePrompt.toolPolicy }
        var messages: [ChatMessage] = [.system(sys1)]
        let split = dna.map { DNASplit($0) }
        if let stable = split?.stable, !stable.isEmpty {
            messages.append(.system(stable))
            lastStable = stable
        } else if let lastStable {
            messages.append(.system(lastStable))
        }
        // Seeds (system items before the first user turn) stay with the prefix; later system items are per-turn notes.
        var notes: [String] = []
        var history: [ChatMessage] = []
        var seeds: [String] = []
        var sawUser = false
        for item in items where !item.id.hasPrefix("dna_") {
            switch item.kind {
            case .system(let t):
                if sawUser { notes.append(t) } else { seeds.append(t) }
            case .user(let t):
                sawUser = true
                notes.removeAll()   // notes before an older user turn were for that turn
                if let t, !t.isEmpty { history.append(.user(t)) }
            case .assistant(let a):
                let t = a.text
                if !t.isEmpty { history.append(.assistant(t)) }
            case .functionCall(let callID, let name, let args):
                if let last = history.last, last.role == .assistant, last.toolCalls.isEmpty == false || last.content.isEmpty {
                    history[history.count - 1].toolCalls.append(ChatToolCall(id: callID, name: name, arguments: args))
                } else {
                    history.append(ChatMessage(role: .assistant, content: "",
                                               toolCalls: [ChatToolCall(id: callID, name: name, arguments: args)]))
                }
            case .functionOutput(let callID, let output):
                let name = items.lazy.compactMap { i -> String? in
                    if case .functionCall(let c, let n, _) = i.kind, c == callID { n } else { nil }
                }.first
                history.append(ChatMessage(role: .tool, content: output, toolCallID: callID, toolName: name))
            }
        }
        for s in seeds { messages.append(.system(s)) }
        // Keep the last N messages; never start on a tool result.
        if history.count > options.historyLimit {
            let dropped = history.prefix(history.count - options.historyLimit)
            for m in dropped where m.role == .user || (m.role == .assistant && !m.content.isEmpty) {
                rollingSummary.append((m.role == .user ? "They said: " : "You said: ") + String(m.content.prefix(120)))
            }
            if rollingSummary.count > 8 { rollingSummary.removeFirst(rollingSummary.count - 8) }
            history = Array(history.suffix(options.historyLimit))
            while let first = history.first, first.role == .tool || (first.role == .assistant && !first.toolCalls.isEmpty) {
                history.removeFirst()
            }
        }
        if !rollingSummary.isEmpty {
            messages.append(.system("EARLIER IN THIS CONVERSATION (summary):\n" + rollingSummary.joined(separator: "\n")))
        }
        let volatile = split?.volatile ?? ""
        // The per-turn context rides on the last user message (Ollama hoists every system message).
        if let lastUser = history.lastIndex(where: { $0.role == .user }), lastUser == history.count - 1 || history[(lastUser + 1)...].allSatisfy({ $0.role == .tool || $0.role == .assistant && $0.content.isEmpty }) {
            history[lastUser].content = CascadePrompt.userTurn(volatileDNA: volatile, notes: notes, transcript: history[lastUser].content)
        } else {
            history.append(.user(CascadePrompt.userTurn(volatileDNA: volatile, notes: notes, transcript: nil)))
        }
        messages += history
        return ChatRequest(model: options.model, messages: messages,
                           tools: useTools ? tools.map(ChatTool.init) : [], maxTokens: maxTokens, keepAlive: options.keepAlive)
    }

    // MARK: Warm-ups

    func warmUp(reason: WarmReason) {
        guard options.warmUps, current == nil else { return }
        let dna = items.last(where: { $0.id.hasPrefix("dna_") }).flatMap { item -> String? in
            if case .system(let t) = item.kind { t } else { nil }
        }
        var request = buildRequest(params: nil, outOfBand: false, textOnly: false, dna: dna, maxTokensOverride: 1)
        // Prefix only: the per-turn user message is replaced by a dot (the cache keeps everything before it).
        if let last = request.messages.indices.last, request.messages[last].role == .user {
            request.messages[last].content = "."
        }
        let key = request.messages.dropLast().map { $0.role.rawValue + $0.content }.joined().hashValue
        guard warmedPrefix != key else { return }
        warmedPrefix = key
        warmTask?.cancel()
        stats.update { $0.warmUps += 1 }
        let chat = self.chat
        warmTask = Task {
            do { for try await _ in chat.stream(request, nativeRoute: false) {} } catch {}
        }
    }
}

// MARK: - Speaker: ordered sentence TTS with one-ahead prefetch

/// Speaks chunks of one response in order: every chunk starts rendering when it is added (so
/// chunk n+1 renders while n is delivered), audio is delivered as it arrives, and a chunk's
/// transcript delta goes out just before its first audio delta.
actor Speaker {
    private let engine: CascadeEngine
    private let run: CascadeEngine.Run
    private let voiceWords: String?
    private var itemID: String?
    private struct Entry {
        var text: String
        var stream: AsyncThrowingStream<Data, Error>
        var task: Task<Void, Never>
    }
    private var queue: [Entry] = []
    private var pump: Task<Void, Never>?
    private var chunks: [(String, Int)] = []
    private var totalBytes = 0
    private var lastAudioEnd: Date?
    private var started = false

    init(engine: CascadeEngine, run: CascadeEngine.Run, voiceWords: String?) {
        self.engine = engine; self.run = run; self.voiceWords = voiceWords
    }

    func begin() async {
        guard !started else { return }
        started = true
        let id = await engine.newID("item")
        itemID = id
        let item = RealtimeItem(id: id, type: "message", status: "in_progress", role: "assistant", content: [])
        await engine.emit(.outputItemAdded(.init(responseID: run.id, outputIndex: 0, item: item)), for: run)
    }

    func add(_ raw: String) async {
        let text = SpeechCleaner.clean(raw)
        guard !text.isEmpty, text.contains(where: { $0.isLetter || $0.isNumber }) else { return }
        await begin()
        let style = await engine.voiceStyle
        let delivery = SpeechDelivery(instructions: [style, voiceWords].compactMap { $0 }.joined(separator: " "),
                                      speed: await engine.sessionSpeed)
        let voice = engine.voice
        // The session cancels a reply it no longer wants as soon as it sees response.created (speech
        // started meanwhile): give that cancel a moment before paying for the first sentence's voice.
        if queue.isEmpty, chunks.isEmpty, let created = run.createdAt {
            let wait = 0.04 - Date().timeIntervalSince(created)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard await engine.isLive(run) else { return }
        }
        let (stream, c) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .unbounded)
        let task = Task {
            do {
                for try await d in voice.synthesize(text, delivery: delivery) { c.yield(d) }
                c.finish()
            } catch {
                c.finish(throwing: error)
            }
        }
        queue.append(Entry(text: text, stream: stream, task: task))
        if pump == nil { pump = Task { await self.drain() } }
    }

    /// A tool call came: chunks whose audio hasn't started are dropped.
    func dropUnstarted() {
        for q in queue { q.task.cancel() }
        queue.removeAll()
    }

    private func drain() async {
        while !queue.isEmpty {
            let next = queue.removeFirst()
            await deliver(next)
        }
        pump = nil
    }

    private func deliver(_ entry: Entry) async {
        guard let itemID, let rid = run.id else { return }
        var first = true
        var carry = Data()
        let step = 4800   // 100 ms
        var bytes = 0
        func out(_ piece: Data) async {
            await engine.emit(.outputAudioDelta(.init(responseID: rid, itemID: itemID, delta: piece.base64EncodedString())), for: run)
        }
        do {
            for try await d in entry.stream {
                guard await engine.isLive(run) else { entry.task.cancel(); return }
                if d.isEmpty { continue }
                if first {
                    first = false
                    let gap = lastAudioEnd.map { Date().timeIntervalSince($0) }
                    if chunks.isEmpty { await engine.noteFirstAudio(run) }
                    await engine.noteSentence(gap: gap)
                    await engine.emit(.outputAudioTranscriptDelta(.init(responseID: rid, itemID: itemID,
                                                                         delta: (chunks.isEmpty ? "" : " ") + entry.text)), for: run)
                }
                carry.append(d)
                while carry.count >= step {
                    await out(carry.prefix(step))
                    carry = Data(carry.dropFirst(step))
                    bytes += step
                }
            }
        } catch {
            if !(error is CancellationError), await engine.isLive(run) {
                let label = engine.voice.label
                await engine.failVoice(error.providerIssue(host: label.name, label: label))
            }
            if first { return }
        }
        guard await engine.isLive(run), !first else { return }
        if !carry.isEmpty { await out(carry); bytes += carry.count }
        totalBytes += bytes
        chunks.append((entry.text, totalBytes / 48))
        lastAudioEnd = Date()
    }

    /// Waits for every queued chunk, then closes the message item.
    func end() async {
        while let p = pump { await p.value; if pump == p { pump = nil } }
        guard let itemID, let rid = run.id else { return }
        guard await engine.isLive(run) else { return }
        let transcript = chunks.map(\.0).joined(separator: " ")
        await engine.emit(.outputAudioDone(.init(responseID: rid, itemID: itemID)), for: run)
        await engine.emit(.outputAudioTranscriptDone(.init(responseID: rid, itemID: itemID, text: transcript)), for: run)
        let item = RealtimeItem(id: itemID, type: "message", status: "completed", role: "assistant",
                                content: [.init(type: "output_audio", transcript: transcript)])
        await engine.emit(.outputItemDone(.init(responseID: rid, outputIndex: 0, item: item)), for: run)
        await engine.recordAssistant(run, itemID: itemID, chunks: chunks, outOfBand: run.params?.conversation == "none")
    }
}

extension ThinkStripper {
    /// Whole-text version (summaries).
    static func stripAll(_ text: String) -> String {
        var s = ThinkStripper()
        var out = ""
        for o in s.push(text) + s.finish() { if case .text(let t) = o { out += t } }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CascadeWire {
    static func decodeClient(_ text: String) throws -> ClientEvent {
        try JSONDecoder().decode(ClientEvent.self, from: Data(text.utf8))
    }
    static func encodeAny<T: Encodable>(_ v: T) throws -> String {
        String(decoding: try JSONEncoder().encode(v), as: UTF8.self)
    }
}
