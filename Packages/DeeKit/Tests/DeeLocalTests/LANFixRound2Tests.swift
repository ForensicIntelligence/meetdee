import Foundation
import Testing
import Synchronization
import DeeRealtime
import DeeVoice
@testable import DeeWake
@testable import DeeLocal
import DeeMockServer

// Regressions from the 0.6 LAN verify (scratchpad lanverify.md): the user's single-slot server on
// port 8000 answered 0 of 7 turns; mode 2 lost replies to conversation_already_has_active_response;
// mode 3 split sentences at 300 ms; "keep going" over Dee in mode 2 became a turn of its own.

/// A raw cascaded socket on a mock server (no RealtimeSession: the test speaks the wire).
struct RawCascade {
    let server: DeeMockServer
    let hearing: FakeHearing
    let socket: CascadeSocket
    let frames: FrameLog
    let reader: Task<Void, Never>

    static func make(vendor: Vendor = .other, warmUps: Bool = false, systemInPlace: Bool = false,
                     chat: @escaping DeeMockServer.ChatScript) async throws -> RawCascade {
        let server = try await DeeMockServer.start(cases: [.ollama], chat: chat)
        let hearing = FakeHearing()
        let client = CompatClient(base: server.baseURL, key: nil, transport: .live(redirects: .refuse))
        var o = CascadeOptions(model: "qwen3.8:27b-mlx-bf16")
        o.warmUps = warmUps
        o.turnContextAsSystem = systemInPlace
        var vc = VendorChat(client: client, vendor: vendor)
        vc.systemMessagesInPlace = systemInPlace
        let socket = CascadeSocket(options: o, hearing: hearing, chat: vc, voice: FakeVoice())
        let frames = FrameLog()
        let reader = Task { for await e in socket.incoming { if case .text(let t) = e { frames.add(t) } } }
        try await socket.open()
        return RawCascade(server: server, hearing: hearing, socket: socket, frames: frames, reader: reader)
    }

    func stop() { reader.cancel(); socket.close(code: 1000, reason: nil); server.stop() }

    func send(_ o: [String: Any]) {
        socket.send(String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self))
    }

    func waitFor(_ timeout: Double = 10, _ p: @escaping ([(at: Date, type: String, json: RealtimeJSON)]) -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if p(frames.all) { return true }; try? await Task.sleep(for: .milliseconds(20)) }
        return p(frames.all)
    }

    func dones() -> [RealtimeJSON] { frames.all.filter { $0.type == "response.done" }.map(\.json) }

    var chatRequests: [MockRequest] { server.requests.filter { $0.path == "/v1/chat/completions" || $0.path == "/api/chat" } }
}

// MARK: (1) one request at a time; 429 waited out

@Suite(.serialized) struct SingleSlotTests {
    /// Two streams to one server through its lane never overlap (lithos-metal answers the second with 429).
    @Test func laneSerializesStreams() async throws {
        let server = try await DeeMockServer.start(cases: [.ollama], chat: { _, _ in .text("Hi there.", firstTokenDelay: 0.3) })
        defer { server.stop() }
        server.setSingleSlot(true)
        let client = CompatClient(base: server.baseURL, key: nil, transport: .live(redirects: .refuse))
        let chat = VendorChat(client: client, vendor: .other, lane: ChatLane())
        var warm = ChatRequest(model: "qwen3.8:27b-mlx-bf16", messages: [.user(".")], maxTokens: 1)
        warm.prefixCount = 0
        let real = ChatRequest(model: "qwen3.8:27b-mlx-bf16", messages: [.user("hi")], maxTokens: 50)
        async let a: Int = { var n = 0; for try await _ in chat.stream(warm, nativeRoute: false) { n += 1 }; return n }()
        try await Task.sleep(for: .milliseconds(30))
        async let b: Int = { var n = 0; for try await _ in chat.stream(real, nativeRoute: false) { n += 1 }; return n }()
        let (na, nb) = try await (a, b)
        #expect(na > 0 && nb > 0)
        #expect(server.slotRejections == 0)
        #expect(server.maxConcurrentChats == 1)
        let reqs = server.requests(path: "/v1/chat/completions")
        #expect(reqs.count == 2)
        #expect(reqs[1].at.timeIntervalSince(reqs[0].at) >= 0.25)   // sent after the first one finished
    }

    /// A cancelled reply's stream closes before the next is sent; the server keeps the slot ~1.5 s
    /// after a hang-up (measured), so the next one is answered 429 and retried, never failed.
    @Test func cancelThenNextReplyIsAnswered() async throws {
        let rig = try await RawCascade.make(chat: { _, i in
            i == 0 ? .text("This one is cancelled before it starts.", firstTokenDelay: 1.5) : .text("Sure, here you go.")
        })
        defer { rig.stop() }
        rig.server.setSingleSlot(true, releaseDelay: 0.6)
        rig.send(["type": "response.create"])
        #expect(await rig.waitFor { $0.contains { $0.type == "response.created" } })
        try await Task.sleep(for: .milliseconds(200))   // its request is out, waiting for a first token
        let rid = rig.frames.first("response.created")?.json["response"]?["id"]?.stringValue
        rig.send(["type": "response.cancel", "response_id": rid ?? ""])
        rig.send(["type": "response.create"])
        #expect(await rig.waitFor { _ in rig.dones().count == 2 })
        let statuses = rig.dones().compactMap { $0["response"]?["status"]?.stringValue }
        #expect(statuses == ["cancelled", "completed"])
        #expect(!rig.frames.all.contains { $0.type == "error" })
        #expect(rig.server.maxConcurrentChats == 1)
        #expect(rig.server.slotRejections >= 1)   // the server still held the slot: waited out
    }

    /// 429 with Retry-After: waited (≥ its seconds), retried, answered. Never another provider.
    @Test func retryAfterIsHonoured() async throws {
        let rig = try await RawCascade.make(chat: { _, i in
            if i == 0 { var r = MockChatReply(); r.status = 429; r.retryAfter = "0.5"; return r }
            return .text("Okay!")
        })
        defer { rig.stop() }
        let sent = Date()
        rig.send(["type": "response.create"])
        #expect(await rig.waitFor { _ in rig.dones().count == 1 })
        #expect(rig.dones().first?["response"]?["status"]?.stringValue == "completed")
        let reqs = rig.chatRequests
        #expect(reqs.count == 2)
        #expect(reqs[1].at.timeIntervalSince(reqs[0].at) >= 0.45)
        #expect(Date().timeIntervalSince(sent) < 3)
    }

    /// Past the budget, 429 is the turn's failure (rate_limit_exceeded), with the server named.
    @Test func persistent429FailsTheTurn() async throws {
        let rig = try await RawCascade.make(chat: { _, _ in var r = MockChatReply(); r.status = 429; r.retryAfter = "1"; return r })
        defer { rig.stop() }
        rig.send(["type": "response.create"])
        let problem = await firstProblem(rig.socket, timeout: 15)
        #expect(problem == .rateLimited(.lan(host: rig.server.baseURL.host! + ":" + String(rig.server.port))))
        #expect(await rig.waitFor(15) { _ in rig.dones().count == 1 })
        #expect(rig.dones().first?["response"]?["status"]?.stringValue == "failed")
        #expect(rig.chatRequests.count >= 3 && rig.chatRequests.count <= 10)
    }

    @Test func retryDelays() {
        #expect(RateLimitRetry.delay(retryAfter: "2", attempt: 0) == 2)
        #expect(RateLimitRetry.delay(retryAfter: "30", attempt: 0) == 3)
        #expect(RateLimitRetry.delay(retryAfter: "0", attempt: 0) == 0.2)
        #expect(RateLimitRetry.delay(retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT", attempt: 1) == 0.6)
        #expect(RateLimitRetry.delay(retryAfter: nil, attempt: 0) == 0.3)
        #expect(RateLimitRetry.delay(retryAfter: nil, attempt: 7) == 1.5)
    }

    /// A warm-up is never retried (it only fills a cache) and never holds a reply back for long.
    @Test func warmUpOf429IsNotRetried() async throws {
        let server = try await DeeMockServer.start(cases: [.ollama], chat: { _, _ in var r = MockChatReply(); r.status = 429; return r })
        defer { server.stop() }
        let client = CompatClient(base: server.baseURL, key: nil, transport: .live(redirects: .refuse))
        let chat = VendorChat(client: client, vendor: .other, lane: ChatLane())
        let warm = ChatRequest(model: "qwen3.8:27b-mlx-bf16", messages: [.user(".")], maxTokens: 1)
        do { for try await _ in chat.stream(warm, nativeRoute: false) {} } catch {}
        #expect(server.requests(path: "/v1/chat/completions").count == 1)
    }
}

// MARK: (3) response.created at once

@Suite(.serialized) struct EarlyCreatedTests {
    /// The verify trace: response.create at 74.49 s, response.created only at 91.92 s (first token);
    /// the session could not cancel it and every later create failed. Now created comes at once,
    /// a cancel by its id ends it while it still waits for its transcript, and the next create works.
    @Test func createdAtOnceAndCancellableById() async throws {
        let rig = try await RawCascade.make(chat: { _, _ in .text("Answer.", firstTokenDelay: 0.2) })
        defer { rig.stop() }
        rig.hearing.emit(.speechStarted(turn: 1, frame: 0))
        rig.hearing.emit(.speechStopped(turn: 1, frame: 24_000))
        rig.hearing.emit(.committed(turn: 1))   // its transcript is late
        try await Task.sleep(for: .milliseconds(50))
        let sent = Date()
        rig.send(["type": "response.create"])
        #expect(await rig.waitFor(1) { $0.contains { $0.type == "response.created" } })
        let created = try #require(rig.frames.first("response.created"))
        #expect(created.at.timeIntervalSince(sent) < 0.2)
        let rid = try #require(created.json["response"]?["id"]?.stringValue)
        rig.send(["type": "response.cancel", "response_id": rid])
        #expect(await rig.waitFor(2) { _ in rig.dones().count == 1 })
        #expect(rig.dones().first?["response"]?["id"]?.stringValue == rid)
        #expect(rig.dones().first?["response"]?["status"]?.stringValue == "cancelled")
        rig.hearing.emit(.transcriptCompleted(turn: 1, text: "Tell me a joke."))
        rig.send(["type": "response.create"])
        #expect(await rig.waitFor { _ in rig.dones().count == 2 })
        #expect(rig.dones().last?["response"]?["status"]?.stringValue == "completed")
        #expect(!rig.frames.all.contains { $0.type == "error" })
        #expect(rig.chatRequests.count == 1)   // the cancelled one never reached the server
    }
}

// MARK: (2) prompt caching: a byte-identical prefix

@Suite(.serialized) struct PromptCacheTests {
    /// Two DNAs of consecutive responses, as the renderer writes them: the trace, "Voice:",
    /// "Lately curious…" and the regard line change; everything else is the same.
    static func dna(_ n: Int) -> String {
        """
        DEE DNA v11 · reply · response \(n) · Friday 16 October 2026, 3:0\(n) afternoon
        The newest DEE DNA replaces all earlier ones. Never say, quote or mention it.
        1 IDENTITY
        You are Dee, a tiny robot who lives in this phone.
        2 TEMPERAMENT
        openness 192/255 high: loves novelty
        3 FEELINGS NOW (0–255; slow ones: affection, trust)
        joy \(100 + n)/255 some
        4 TOWARD THIS PERSON
        Their name is Alex.
        You feel no strong feelings about them yet (regard +0.0\(n)); your eyes glow yellow. Affection some, trust some.
        Repair: Things are fine between you.
        5 WHAT YOU KNOW ABOUT THEM (mention only what fits; never list it)
        Planning a balcony garden.
        Lately curious with them about: \(n == 1 ? "brother" : "brother, favorite color").
        6 WHO YOU ARE
        You value finding things out.
        7 RIGHT NOW
        Someone is here.
        8 THIS TURN
        They just spoke.
        9 HOW TO RESPOND
        Length: at most two sentences, 25 words in all; stop after the second.
        Voice: \(n == 1 ? "bright" : "hushed, wondering"), a tiny robot's bright little voice.
        DNA TRACE (never say): v11 C1\(n)
        """
    }

    @Test func splitKeepsEveryLineOnceAndMovesPerResponseLines() {
        let d = Self.dna(1)
        let split = CacheDNASplit(d)
        #expect(!split.stable.contains("DNA TRACE") && !split.stable.contains("Voice:") && !split.stable.contains("Lately curious")
                && !split.stable.contains("(regard ") && !split.stable.contains("9 HOW TO RESPOND"))
        #expect(split.stable.contains("1 IDENTITY") && split.stable.contains("Their name is Alex.") && split.stable.contains("Planning"))
        #expect(split.volatile.contains("4 TOWARD THIS PERSON (now)\nYou feel no strong feelings"))
        #expect(split.volatile.contains("5 WHAT YOU KNOW ABOUT THEM (mention only what fits; never list it) (now)\nLately curious"))
        let original = d.split(separator: "\n").map(String.init)
        let out = (split.stable + "\n" + split.volatile).split(separator: "\n").map(String.init).filter { !$0.hasSuffix(" (now)") }
        #expect(out.sorted() == original.sorted())
        // Consecutive responses: the stable part is byte-identical.
        #expect(CacheDNASplit(Self.dna(1)).stable == CacheDNASplit(Self.dna(2)).stable)
    }

    func twoTurns(vendor: Vendor, systemInPlace: Bool = false, dna: @escaping (Int) -> String = PromptCacheTests.dna)
        async throws -> (first: [[String: Any]], second: [[String: Any]], prefix: Int) {
        let rig = try await RawCascade.make(vendor: vendor, systemInPlace: systemInPlace,
                                            chat: { _, i in .text(i == 0 ? "Tomatoes love sun." : "Basil too!") })
        defer { rig.stop() }
        rig.send(["type": "session.update", "session": ["type": "realtime", "instructions": "You are Dee."]])
        for n in 1...2 {
            await rig.hearing.say(n == 1 ? "I want tomatoes." : "And basil?", turn: n)
            rig.send(["type": "conversation.item.create", "item": ["id": "dna_\(n)", "type": "message", "role": "system",
                                                                    "content": [["type": "input_text", "text": dna(n)]]]])
            if n == 2 { rig.send(["type": "conversation.item.delete", "item_id": "dna_1"]) }
            rig.send(["type": "response.create"])
            #expect(await rig.waitFor { _ in rig.dones().count == n })
        }
        let bodies = rig.chatRequests.compactMap(\.jsonObject).map(messages)
        let engineRequest = bodies.count == 2 ? bodies : [[], []]
        return (engineRequest[0], engineRequest[1], 0)
    }

    static func text(_ m: [String: Any]) -> String { "\(m["role"] ?? "")|\(m["content"] ?? "")" }

    /// A server known to keep system messages in place (option): the 2nd request starts with every
    /// message of the 1st request's prefix, byte for byte, then the history; the per-turn DNA is
    /// the last system message, right before the user turn.
    @Test func secondTurnReusesTheFirstTurnsPrefix() async throws {
        let (a, b, _) = try await twoTurns(vendor: .other, systemInPlace: true)
        #expect(a.count >= 4 && b.count >= 6)
        // Request 1: [sys, stable DNA, volatile DNA, user]; its prefix is the first two.
        #expect(a.map { $0["role"] as? String } == ["system", "system", "system", "user"])
        #expect(b.map { $0["role"] as? String } == ["system", "system", "user", "assistant", "system", "user"])
        #expect(Self.text(a[0]) == Self.text(b[0]) && Self.text(a[1]) == Self.text(b[1]))
        #expect((b[2]["content"] as? String) == "I want tomatoes.")
        #expect((b[3]["content"] as? String) == "Tomatoes love sun.")
        let volatile = b[4]["content"] as? String ?? ""
        #expect(volatile.contains("DNA TRACE (never say): v11 C12") && volatile.contains("8 THIS TURN"))
        #expect((b[5]["content"] as? String) == "THEY JUST SAID:\nAnd basil?")
    }

    /// Ollama and lithos-metal (port 8000) hoist every system message to the top: the per-turn
    /// part rides on the user message (the default for every server).
    @Test(arguments: [Vendor.ollama, .other])
    func hoistingServersGetTheTurnOnTheUserMessage(_ vendor: Vendor) async throws {
        let (a, b, _) = try await twoTurns(vendor: vendor)
        #expect(a.map { $0["role"] as? String } == ["system", "system", "user"])
        #expect(b.map { $0["role"] as? String } == ["system", "system", "user", "assistant", "user"])
        #expect(Self.text(a[0]) == Self.text(b[0]) && Self.text(a[1]) == Self.text(b[1]))
        let last = b[4]["content"] as? String ?? ""
        #expect(last.contains("DNA TRACE (never say): v11 C12") && last.hasSuffix("THEY JUST SAID:\nAnd basil?"))
    }

    /// The stable DNA drifts (a temperament byte, a fact just learned): the prefix keeps the
    /// pinned text and the changed lines ride with the turn as "(updated)" (port 8000: a system
    /// message change costs the whole 8.5 s prefill).
    @Test func driftInTheStableDNAKeepsThePrefix() async throws {
        let drift: (Int) -> String = { n in
            var d = PromptCacheTests.dna(n)
            if n == 2 {
                d = d.replacingOccurrences(of: "openness 192/255", with: "openness 193/255")
                d = d.replacingOccurrences(of: "Planning a balcony garden.", with: "Planning a balcony garden.\nHas a sister.")
            }
            return d
        }
        let (a, b, _) = try await twoTurns(vendor: .other, dna: drift)
        #expect(Self.text(a[1]) == Self.text(b[1]))
        #expect((b[1]["content"] as? String ?? "").contains("openness 192/255"))
        let last = b.last?["content"] as? String ?? ""
        #expect(last.contains("2 TEMPERAMENT (updated)\nopenness 193/255"))
        #expect(last.contains("5 WHAT YOU KNOW ABOUT THEM (mention only what fits; never list it) (updated)\nHas a sister."))
        #expect(!last.contains("Planning a balcony garden."))
    }

    /// Who Dee is changed (section 1, a persona switch): re-pinned, nothing carried as an update.
    @Test func identityChangeRepins() async throws {
        let other: (Int) -> String = { n in
            n == 2 ? PromptCacheTests.dna(n).replacingOccurrences(of: "You are Dee, a tiny robot", with: "You are Nova, a tiny robot")
                   : PromptCacheTests.dna(n)
        }
        let (_, b, _) = try await twoTurns(vendor: .other, dna: other)
        #expect((b[1]["content"] as? String ?? "").contains("You are Nova"))
        let last = b.last?["content"] as? String ?? ""
        #expect(last.contains("DNA TRACE") && !last.contains("(updated)"))
    }

    /// Old history goes to the rolling summary once per message (it was re-added on every
    /// request), and the cut moves in steps: the prefix stays the same for a few turns.
    @Test func historyTrimsInStepsAndSummarisesOnce() async throws {
        let server = try await DeeMockServer.start(cases: [.ollama])
        defer { server.stop() }
        let client = CompatClient(base: server.baseURL, key: nil, transport: .live(redirects: .refuse))
        var o = CascadeOptions(model: "m"); o.historyLimit = 6; o.historyTrimStep = 4; o.warmUps = false
        let engine = CascadeEngine(options: o, hearing: FakeHearing(), chat: VendorChat(client: client, vendor: .other),
                                   voice: FakeVoice(), stats: CascadeStats(), emit: { _ in }, problem: { _ in })
        var prefixes: [[ChatMessage]] = []
        for n in 1...8 {
            await engine.client(#"{"type":"conversation.item.create","item":{"id":"u\#(n)","type":"message","role":"user","content":[{"type":"input_text","text":"line \#(n)"}]}}"#)
            await engine.client(#"{"type":"conversation.item.create","item":{"id":"a\#(n)","type":"message","role":"assistant","content":[{"type":"output_text","text":"reply \#(n)"}]}}"#)
            let r = await engine.buildRequest(params: nil, outOfBand: false, textOnly: false, dna: nil)
            _ = await engine.buildRequest(params: nil, outOfBand: false, textOnly: false, dna: nil)   // a warm-up builds too
            prefixes.append(Array(r.messages.prefix(r.prefixCount)))
            let history = r.messages.prefix(r.prefixCount).filter { $0.role == .user || $0.role == .assistant }
            #expect(history.count <= 6)
        }
        let summary = prefixes.last!.first { $0.content.hasPrefix("EARLIER IN THIS CONVERSATION") }?.content ?? ""
        let lines = summary.split(separator: "\n").dropFirst()
        #expect(Set(lines).count == lines.count)   // no duplicates
        #expect(lines.contains("They said: line 6") && !lines.contains("They said: line 7"))
        // The summary (and so the prefix start) changes only when the cut moves, not every turn.
        let summaries = prefixes.map { $0.first { $0.content.hasPrefix("EARLIER") }?.content ?? "" }
        #expect(Set(summaries).count <= 4)
    }
}

// MARK: (4) mode 3: a merge window like mode 2's

@Suite struct LocalMergeTests {
    /// 100 ms of voice per call for `voiceMs`, then quiet for `quietMs`, in 20 ms steps.
    static func run(_ d: inout TurnDetectorCore, at t: inout Int64, voice: Bool, ms: Int, unfinished: Bool = false) -> [TurnDetectorCore.Event] {
        var out: [TurnDetectorCore.Event] = []
        for _ in 0..<(ms / 20) {
            out += d.evidence(start: t, end: t + 480, voice: voice, unfinished: unfinished)
            t += 480
        }
        return out
    }

    func detector() -> TurnDetectorCore {
        var d = TurnDetectorCore()
        d.mergeMs = Int(MergeTiming.window * 1000)
        d.extendMs = Int((MergeTiming.unfinishedWindow - MergeTiming.window) * 1000)
        return d
    }

    /// l05's 0.6–0.7 s pauses: one turn, one commit, the stop at the end of the last voice.
    @Test func pausesInsideTheWindowAreOneTurn() {
        var d = detector(); var t: Int64 = 0; var e: [TurnDetectorCore.Event] = []
        e += Self.run(&d, at: &t, voice: true, ms: 1_000)
        e += Self.run(&d, at: &t, voice: false, ms: 700)
        e += Self.run(&d, at: &t, voice: true, ms: 1_000)
        e += Self.run(&d, at: &t, voice: false, ms: 1_200)
        #expect(e.filter { if case .started = $0 { true } else { false } }.count == 1)
        #expect(e.filter { if case .committed = $0 { true } else { false } }.count == 1)
        #expect(e.contains(.stopped(turn: 1, frame: Int64(2_700 * 24 + 300 * 24))))
    }

    /// p12a: "So yesterday I went to the" — 1.21 s — "farmers market…": one turn while the words trail off…
    @Test func aTrailingPauseOf1_2sIsOneTurn() {
        var d = detector(); var t: Int64 = 0; var e: [TurnDetectorCore.Event] = []
        e += Self.run(&d, at: &t, voice: true, ms: 1_400)
        e += Self.run(&d, at: &t, voice: false, ms: 1_220, unfinished: true)
        e += Self.run(&d, at: &t, voice: true, ms: 1_200)
        e += Self.run(&d, at: &t, voice: false, ms: 1_200)
        #expect(e.filter { if case .committed = $0 { true } else { false } }.count == 1)
    }

    /// …but after finished words the same pause ends the turn (latency of plain turns: 0.3 + 0.8 s).
    @Test func aFinishedTurnCommitsAfterTheBaseWindow() {
        var d = detector(); var t: Int64 = 0; var e: [TurnDetectorCore.Event] = []
        e += Self.run(&d, at: &t, voice: true, ms: 1_000)
        e += Self.run(&d, at: &t, voice: false, ms: 1_080)
        #expect(!e.contains { if case .committed = $0 { true } else { false } })
        e += Self.run(&d, at: &t, voice: false, ms: 40)
        #expect(e.contains { if case .committed = $0 { true } else { false } })
    }

    /// A click in the window neither continues nor restarts the turn.
    @Test func aBlipInTheWindowDoesNotContinue() {
        var d = detector(); var t: Int64 = 0; var e: [TurnDetectorCore.Event] = []
        e += Self.run(&d, at: &t, voice: true, ms: 1_000)
        e += Self.run(&d, at: &t, voice: false, ms: 500)
        e += Self.run(&d, at: &t, voice: true, ms: 40)
        e += Self.run(&d, at: &t, voice: false, ms: 600)
        #expect(e.contains(.stopped(turn: 1, frame: Int64(1_300 * 24))))
        #expect(e.filter { if case .committed = $0 { true } else { false } }.count == 1)
    }

    @Test func trailingWords() {
        #expect(TrailingWords.trails("So yesterday I went to the"))
        #expect(TrailingWords.trails("Tomorrow I'm going to call my mom and"))
        #expect(TrailingWords.trails("I was thinking,"))
        #expect(!TrailingWords.trails("I went to the farmers market with my sister."))
        #expect(!TrailingWords.trails("What's your favorite color?"))
        #expect(!TrailingWords.trails("I like that."))
        #expect(!TrailingWords.trails(""))
    }

    /// End to end in LocalHearing (EarCore evidence + on-device words): p12a is one turn.
    @Test func localHearingJoinsATrailingPause() async throws {
        let engine = FakeEngine()
        engine.onFinalize = { end in SpeechSegment(text: "So yesterday I went to the farmers market with my sister.", isFinal: true,
                                                    startFrame: 2_400, endFrame: end - 7_200) }
        let uplink = UplinkActivity()
        let hearing = LocalHearing(stt: .onDevice, engine: engine, uplink: uplink)
        let sink = LocalHearingTests.Sink()
        try await hearing.start { sink.add($0) }
        func chunk(_ i: Int, _ voice: Bool) { uplink.record(frames: 2_400, voice: voice); hearing.feed(Data(count: 4_800), atFrame: Int64(i) * 2_400) }
        var i = 0
        for _ in 0..<14 { chunk(i, true); i += 1 }                       // 1.4 s "So yesterday I went to the"
        engine.segment(SpeechSegment(text: "So yesterday I went to the", isFinal: false, startFrame: 2_400))
        try await Task.sleep(for: .milliseconds(50))
        for _ in 0..<12 { chunk(i, false); i += 1 }                      // 1.2 s pause
        for _ in 0..<12 { chunk(i, true); i += 1 }                       // "farmers market with my sister."
        for _ in 0..<20 { chunk(i, false); i += 1 }
        #expect(await sink.wait { $0.contains { if case .transcriptCompleted = $0 { true } else { false } } })
        let all = sink.all
        #expect(all.filter { if case .speechStarted = $0 { true } else { false } }.count == 1)
        #expect(all.filter { if case .committed = $0 { true } else { false } } == [.committed(turn: 1)])
        #expect(all.contains(.transcriptCompleted(turn: 1, text: "So yesterday I went to the farmers market with my sister.")))
        hearing.stop()
    }
}

// MARK: (4) mode 2: the window grows while the words trail off; (5) "keep going" over Dee

@Suite(.serialized) struct TranscriptionRound2Tests {
    func hearing(uplink: UplinkActivity? = nil) -> (OpenAITranscriptionHearing, LocalHearingTests.Sink) {
        let h = OpenAITranscriptionHearing(transport: .failing(), credential: { throw RealtimeAuthError.noKey }, uplink: uplink)
        h.mergeWindow = 0.3
        h.unfinishedWindow = 0.9
        let sink = LocalHearingTests.Sink()
        h.attach { sink.add($0) }
        return (h, sink)
    }

    func ev(_ o: [String: Any]) -> ServerEvent {
        ServerEvent.parse(String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self))
    }
    func started(_ h: OpenAITranscriptionHearing, _ item: String, _ ms: Int) {
        h.server(ev(["type": "input_audio_buffer.speech_started", "audio_start_ms": ms, "item_id": item]))
    }
    func rest(_ h: OpenAITranscriptionHearing, _ item: String, stop ms: Int, _ text: String) {
        h.server(ev(["type": "input_audio_buffer.speech_stopped", "audio_end_ms": ms, "item_id": item]))
        h.server(ev(["type": "input_audio_buffer.committed", "item_id": item, "previous_item_id": NSNull()]))
        h.server(ev(["type": "conversation.item.input_audio_transcription.delta", "item_id": item, "content_index": 0, "delta": text]))
        h.server(ev(["type": "conversation.item.input_audio_transcription.completed", "item_id": item, "content_index": 0, "transcript": text]))
    }
    func starts(_ s: LocalHearingTests.Sink) -> Int { s.all.filter { if case .speechStarted = $0 { true } else { false } }.count }

    @Test func trailingWordsHoldLonger() async throws {
        let (h, sink) = hearing()
        started(h, "item_A", 100); rest(h, "item_A", stop: 1_500, "So yesterday I went to the")
        try await Task.sleep(for: .milliseconds(550))   // past the base window (0.3 s), inside the grown one (0.9 s)
        #expect(!sink.all.contains(.committed(turn: 1)))
        started(h, "item_B", 2_800); rest(h, "item_B", stop: 4_200, "farmers market with my sister.")
        #expect(await sink.wait { $0.contains { if case .transcriptCompleted = $0 { true } else { false } } })
        #expect(starts(sink) == 1)
        #expect(sink.all.contains(.transcriptCompleted(turn: 1, text: "So yesterday I went to the farmers market with my sister.")))
    }

    @Test func finishedWordsKeepTheBaseWindow() async throws {
        let (h, sink) = hearing()
        started(h, "item_A", 100); rest(h, "item_A", stop: 1_500, "I went to the farmers market.")
        #expect(await sink.wait(0.6) { $0.contains(.committed(turn: 1)) })
    }

    /// c05 over Dee (verify run 150048): the session committed "Keep" early in its hold; the
    /// transcription session put "going, I'm listening" in an item it never reported starting.
    /// Now our voice evidence opens that item at once, and the server's item joins it: one start,
    /// one commit, its own words — what mode 1's server sends, so the hold's Backchannel rules
    /// (continuer, then its split-off rest) let Dee go on.
    @Test func restOfABurstAfterAManualCommitIsAnItemAtOnce() async throws {
        let uplink = UplinkActivity()
        let (h, sink) = hearing(uplink: uplink)
        func feed(_ voice: Bool, _ n: Int = 1) {
            for _ in 0..<n { uplink.record(frames: 2_400, voice: voice); h.feed(Data(count: 4_800), atFrame: uplink.latestFedFrame - 2_400) }
        }
        feed(false, 5)
        started(h, "item_89", 300)
        feed(true, 3)                    // "Keep"
        feed(false, 3)
        h.commitNow()                    // CloudVoice's quick commit (hold)
        h.server(ev(["type": "input_audio_buffer.committed", "item_id": "item_89", "previous_item_id": NSNull()]))
        h.server(ev(["type": "conversation.item.input_audio_transcription.completed", "item_id": "item_89", "content_index": 0,
                     "transcript": "Cheap."]))
        #expect(await sink.wait(1) { $0.contains(.transcriptCompleted(turn: 1, text: "Cheap.")) })
        feed(true, 2)                    // "going, I'm listening" begins
        #expect(await sink.wait(0.5) { _ in self.starts(sink) == 2 })
        let second = sink.all.compactMap { e -> (Int, Int64)? in if case .speechStarted(let t, let f) = e, t == 2 { (t, f) } else { nil } }.first
        #expect(second.map { $0.1 >= 11 * 2_400 } == true)   // never before the commit
        feed(true, 10)
        feed(false, 4)
        rest(h, "item_99", stop: 2_400, "Going. I'm listening.")   // the server's first event for it is its stop
        #expect(await sink.wait { $0.contains(.transcriptCompleted(turn: 2, text: "Going. I'm listening.")) })
        #expect(starts(sink) == 2)
        #expect(sink.all.filter { $0 == .committed(turn: 2) }.count == 1)
        // The session's own rule then reads both as "go on" (Backchannel, the one rule for every mode).
        #expect(Backchannel.isBackchannel("Cheap.") && Backchannel.isBackchannel("Going. I'm listening."))
    }

    /// No voice after the manual commit: nothing is opened (a word-less tail stays a tail).
    @Test func noVoiceAfterAManualCommitOpensNothing() async throws {
        let uplink = UplinkActivity()
        let (h, sink) = hearing(uplink: uplink)
        h.restWatchWindow = 0.3
        started(h, "item_1", 100)
        h.commitNow()
        for _ in 0..<10 { uplink.record(frames: 2_400, voice: false); h.feed(Data(count: 4_800), atFrame: uplink.latestFedFrame - 2_400) }
        try await Task.sleep(for: .milliseconds(400))
        for _ in 0..<5 { uplink.record(frames: 2_400, voice: true); h.feed(Data(count: 4_800), atFrame: uplink.latestFedFrame - 2_400) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(starts(sink) == 1)
    }

    /// An opened rest no server item claims is closed, empty, after the voice ends (never left open).
    @Test func anUnclaimedRestCloses() async throws {
        let uplink = UplinkActivity()
        let (h, sink) = hearing(uplink: uplink)
        h.restGiveUp = 0.4
        started(h, "item_1", 100)
        h.commitNow()
        for _ in 0..<3 { uplink.record(frames: 2_400, voice: true); h.feed(Data(count: 4_800), atFrame: uplink.latestFedFrame - 2_400) }
        #expect(await sink.wait(1) { _ in self.starts(sink) == 2 })
        #expect(await sink.wait(2) { $0.contains(.transcriptCompleted(turn: 2, text: "")) })
        #expect(sink.all.contains(.committed(turn: 2)))
    }
}
