import Foundation
import Testing
import DeeRealtime
@testable import DeeLocal
import DeeMockServer

@Suite(.serialized) struct CascadeSocketTests {
    /// The realtime order the session relies on, end to end through RealtimeSession.
    @Test func replyInRealtimeOrder() async throws {
        let rig = try await CascadeRig.make(chat: { _, _ in .text("Your dog is Biscuit. He is a beagle!", firstTokenDelay: 0.4) })
        defer { Task { await rig.stop() } }
        await rig.hearing.say("what's my dog's name", turn: 1)
        #expect(await rig.log.wait { $0.contains { if case .userTranscript(_, "what's my dog's name") = $0 { true } else { false } } })
        let sent = Date()
        try await rig.session.requestResponse(dna: sampleDNA)
        #expect(await rig.log.wait { !$0.compactMap { if case .responseDone(let s) = $0 { s } else { nil } }.isEmpty })
        let done = try #require(rig.log.done.first)
        #expect(done.status == "completed")
        #expect(done.transcript == "Your dog is Biscuit. He is a beagle!")
        #expect(rig.log.audioBytes > 0)
        #expect(rig.log.sentences == ["Your dog is Biscuit.", "He is a beagle!"])
        #expect(rig.voice.texts == ["Your dog is Biscuit.", "He is a beagle!"])
        let t = rig.frames.types
        // committed before any transcript; response.created at once (OpenAI's order: the session
        // can cancel it by id before the first token, 0.6 LAN verify), well before the 0.4 s first token.
        #expect(t.firstIndex(of: "input_audio_buffer.committed")! < t.firstIndex(of: "conversation.item.input_audio_transcription.completed")!)
        let created = try #require(rig.frames.first("response.created"))
        #expect(created.at.timeIntervalSince(sent) < 0.3)
        #expect(t.firstIndex(of: "response.created")! < t.firstIndex(of: "response.output_item.added")!)
        // transcript delta of each sentence comes right before its audio.
        let firstTranscript = t.firstIndex(of: "response.output_audio_transcript.delta")!
        let firstAudio = t.firstIndex(of: "response.output_audio.delta")!
        #expect(firstTranscript < firstAudio)
        #expect(t.last == "response.done")
        // The request: reasoning off, streaming, keep_alive, the DNA split.
        let body = try #require(rig.chatBodies.first)
        #expect(body["reasoning_effort"] as? String == "none")
        #expect(body["keep_alive"] as? String == "30m")
        let msgs = messages(body)
        #expect(msgs.first?["role"] as? String == "system")
        let stable = msgs[1]["content"] as? String ?? ""
        #expect(msgs[1]["role"] as? String == "system")
        // Section 9 changes per response (CacheDNASplit): it rides with the turn, not the cached prefix.
        #expect(stable.contains("1 IDENTITY") && !stable.contains("9 HOW TO RESPOND") && !stable.contains("3 FEELINGS"))
        let last = try #require(msgs.last)
        #expect(last["role"] as? String == "user")
        let lastText = last["content"] as? String ?? ""
        #expect(lastText.contains("3 FEELINGS NOW") && lastText.contains("8 THIS TURN") && lastText.contains("9 HOW TO RESPOND")
                && lastText.hasSuffix("what's my dog's name"))
        #expect(!lastText.contains("1 IDENTITY"))
        // Exactly one system message carries the stable DNA (the DNA item itself is never a message).
        #expect(msgs.filter { ($0["content"] as? String ?? "").contains("DEE DNA") }.count == 1)
    }

    /// T1: the measured Ollama leak (stray </think>, answer repeated) is never spoken.
    @Test func strayThinkCloseEndsSpeech() async throws {
        let rig = try await CascadeRig.make(chat: { _, _ in
            MockChatReply(content: ["Your dog is **Biscuit** — a beagle! 🐶\n", "</think>\n\n", "Oh yeah — your dog is Biscuit, a beagle!"],
                          reasoning: ["The user asks", " about the dog"])
        })
        defer { Task { await rig.stop() } }
        await rig.hearing.say("dog?", turn: 1)
        _ = await rig.log.wait { !$0.compactMap { if case .userTranscript(_, let t) = $0 { t } else { nil } }.isEmpty }
        try await rig.session.requestResponse(dna: sampleDNA)
        #expect(await rig.log.wait { !$0.compactMap { if case .responseDone(let s) = $0 { s } else { nil } }.isEmpty })
        #expect(rig.voice.texts == ["Your dog is Biscuit — a beagle!"])
        #expect(rig.log.done.first?.transcript == "Your dog is Biscuit — a beagle!")
        let spoken = rig.voice.texts.joined()
        #expect(!spoken.contains("user asks") && !spoken.contains("think") && !spoken.contains("*") && !spoken.contains("🐶"))
        #expect(rig.socket.stats.snapshot.thinkEnds == 1)
        #expect(rig.socket.stats.snapshot.reasoningCharsDropped > 0)
    }

    /// A tool call: unspoken text dropped, function call surfaced, the follow-up sees the tool result;
    /// on Ollama the post-tool turn uses native /api/chat with think:false.
    @Test func toolRoundTrip() async throws {
        let rig = try await CascadeRig.make(chat: { _, i in
            if i == 0 {
                var r = MockChatReply(content: ["Miso!"], toolCalls: [MockToolCall(id: "call_1", name: "recall", arguments: #"{"query":"dog"}"#)])
                r.toolArgPieces = 3
                return r
            }
            return .text("Your dog is Biscuit.")
        })
        defer { Task { await rig.stop() } }
        await rig.session.updateSession(instructions: "You are Dee.", tools: [RealtimeTool(name: "recall", description: "Look up", parameters: ["type": "object"])])
        await rig.session.setToolHandler { call in
            #expect(call.name == "recall")
            #expect(call.arguments == #"{"query":"dog"}"#)
            return RealtimeToolResult(output: #"{"facts":["dog: Biscuit"]}"#, followUp: .always)
        }
        await rig.hearing.say("what's my dog called", turn: 1)
        _ = await rig.log.wait { !$0.compactMap { if case .userTranscript(_, let t) = $0 { t } else { nil } }.isEmpty }
        try await rig.session.requestResponse(dna: sampleDNA)
        #expect(await rig.log.wait { $0.compactMap { if case .responseDone(let s) = $0 { s } else { nil } }.count >= 2 })
        #expect(!rig.voice.texts.contains("Miso!"))
        #expect(rig.voice.texts == ["Your dog is Biscuit."])
        let reqs = rig.server.requests.filter { $0.path == "/v1/chat/completions" || $0.path == "/api/chat" }
        #expect(reqs.map(\.path) == ["/v1/chat/completions", "/api/chat"])
        let follow = try #require(reqs.last?.jsonObject)
        #expect(follow["think"] as? Bool == false)
        let ms = messages(follow)
        #expect(ms.contains { $0["role"] as? String == "tool" && ($0["content"] as? String ?? "").contains("Biscuit") })
        #expect(ms.contains { ($0["tool_calls"] as? [[String: Any]])?.first != nil })
        // Tools are offered byte-identically on both requests (prefix cache).
        let first = try #require(reqs.first?.jsonObject)
        #expect((first["tools"] as? [[String: Any]])?.count == 1)
        let p = rig.server.requests.first?.body
        #expect(p != nil)
    }

    /// Cancel stops chat + TTS: response.done cancelled and no audio after it.
    @Test func cancelStopsEverything() async throws {
        let rig = try await CascadeRig.make(chat: { _, _ in
            var r = MockChatReply.text("One. Two. Three. Four. Five. Six. Seven.")
            r.chunkDelay = 0.15
            return r
        })
        defer { Task { await rig.stop() } }
        await rig.hearing.say("count", turn: 1)
        _ = await rig.log.wait { !$0.compactMap { if case .userTranscript(_, let t) = $0 { t } else { nil } }.isEmpty }
        try await rig.session.requestResponse(dna: sampleDNA)
        _ = await rig.log.wait { $0.contains { if case .assistantAudio = $0 { true } else { false } } }
        let outcome = await rig.session.bargeIn(playedMs: 50)
        #expect(outcome.cancelledResponse)
        #expect(await rig.log.wait { !$0.compactMap { if case .responseDone(let s) = $0 { s } else { nil } }.isEmpty })
        #expect(rig.log.done.first?.status == "cancelled")
        let before = rig.frames.all.filter { $0.type == "response.output_audio.delta" }.count
        try await Task.sleep(for: .seconds(1.3))
        let after = rig.frames.all.filter { $0.type == "response.output_audio.delta" }.count
        #expect(before == after)
        #expect(rig.voice.texts.count < 7)
    }

    /// Debounce: a reply waits for the final transcript; no HTTP before it.
    @Test func replyWaitsForTranscript() async throws {
        let rig = try await CascadeRig.make()
        defer { Task { await rig.stop() } }
        rig.hearing.emit(.speechStarted(turn: 1, frame: 0))
        rig.hearing.emit(.speechStopped(turn: 1, frame: 24_000))
        rig.hearing.emit(.committed(turn: 1))
        _ = await rig.log.wait { !$0.compactMap { if case .userCommitted(let id, _) = $0 { id } else { nil } }.isEmpty }
        try await rig.session.requestResponse(dna: sampleDNA)
        try await Task.sleep(for: .milliseconds(400))
        #expect(rig.chatBodies.isEmpty)
        rig.hearing.emit(.transcriptCompleted(turn: 1, text: "hello"))
        #expect(await rig.log.wait { !$0.compactMap { if case .responseDone(let s) = $0 { s } else { nil } }.isEmpty })
        #expect(rig.chatBodies.count == 1)
        #expect((messages(rig.chatBodies[0]).last?["content"] as? String ?? "").hasSuffix("hello"))
    }

    /// Speech before the first token cancels locally: the late answer never plays.
    @Test func preemptBeforeFirstToken() async throws {
        let rig = try await CascadeRig.make(chat: { _, _ in .text("Late answer.", firstTokenDelay: 1.0) })
        defer { Task { await rig.stop() } }
        await rig.hearing.say("hi", turn: 1)
        _ = await rig.log.wait { !$0.compactMap { if case .userTranscript(_, let t) = $0 { t } else { nil } }.isEmpty }
        try await rig.session.requestResponse(dna: sampleDNA)
        try await Task.sleep(for: .milliseconds(200))
        rig.hearing.emit(.speechStarted(turn: 2, frame: 96_000))
        #expect(await rig.log.wait { $0.contains { if case .replyPreempted = $0 { true } else { false } } })
        try await Task.sleep(for: .seconds(1.3))
        #expect(rig.voice.texts.isEmpty)
        #expect(rig.log.audioBytes == 0)
    }

    /// The cascaded timing profile: a 7 s first token (model loading) is answered, no cancel, no retry request.
    @Test func slowFirstTokenAnswered() async throws {
        let rig = try await CascadeRig.make(chat: { _, _ in .text("Sorry, I was waking up.", firstTokenDelay: 7) })
        defer { Task { await rig.stop() } }
        await rig.hearing.say("hello?", turn: 1)
        _ = await rig.log.wait { !$0.compactMap { if case .userTranscript(_, let t) = $0 { t } else { nil } }.isEmpty }
        try await rig.session.requestResponse(dna: sampleDNA)
        #expect(await rig.log.wait(timeout: 15) { !$0.compactMap { if case .responseDone(let s) = $0 { s } else { nil } }.isEmpty })
        #expect(rig.log.done.first?.status == "completed")
        #expect(rig.chatBodies.count == 1)
        #expect(!rig.log.events.contains { if case .fallbackAdvised(.noResponse) = $0 { true } else { false } })
    }

    /// A verbatim `say` is spoken without a model call, with the DNA's Voice words.
    @Test func verbatimSayNeedsNoModel() async throws {
        let rig = try await CascadeRig.make()
        defer { Task { await rig.stop() } }
        _ = await rig.session.say(instructions: "Say exactly this, word for word, in your own voice, and nothing else: \"Okay. Goodnight!\"\nVoice: sleepy.",
                                  maxOutputTokens: 400)
        #expect(await rig.log.wait { !$0.compactMap { if case .responseDone(let s) = $0 { s } else { nil } }.isEmpty })
        #expect(rig.voice.texts == ["Okay. Goodnight!"])
        #expect(rig.chatBodies.isEmpty)
        #expect(rig.voice.deliveries.first?.instructions?.contains("Voice: sleepy.") == true)
    }

    /// LM Studio answers an unknown model with the loaded one: an error, never Dee's words.
    @Test func modelMismatchIsAProblem() async throws {
        let rig = try await CascadeRig.make(cases: [.lmStudio, .modelFallback], options: { $0.model = "missing-model" })
        defer { Task { await rig.stop() } }
        await rig.hearing.say("hi", turn: 1)
        _ = await rig.log.wait { !$0.compactMap { if case .userTranscript(_, let t) = $0 { t } else { nil } }.isEmpty }
        try await rig.session.requestResponse(dna: sampleDNA)
        #expect(await rig.log.wait { !$0.compactMap { if case .responseDone(let s) = $0 { s } else { nil } }.isEmpty })
        #expect(rig.log.done.first?.status == "failed")
        #expect(rig.voice.texts.isEmpty)
        let p = await firstProblem(rig.socket)
        #expect(p == .modelMismatch(host: rig.server.baseURL.host! + ":\(rig.server.port)", asked: "missing-model", got: "qwen3.8:27b-mlx-bf16"))
    }

    /// History: Dee's text is cut to what was heard after a barge-in; at most N messages + a summary.
    @Test func historyKeepsHeardTextOnly() async throws {
        let rig = try await CascadeRig.make(options: { $0.historyLimit = 4 }, chat: { _, i in
            i == 0 ? .text("First sentence here. Second sentence that was never heard.") : .text("Ok.")
        })
        defer { Task { await rig.stop() } }
        await rig.hearing.say("tell me", turn: 1)
        _ = await rig.log.wait { !$0.compactMap { if case .userTranscript(_, let t) = $0 { t } else { nil } }.isEmpty }
        try await rig.session.requestResponse(dna: sampleDNA)
        #expect(await rig.log.wait { !$0.compactMap { if case .responseDone(let s) = $0 { s } else { nil } }.isEmpty })
        // Cut after the first sentence (each char = 10 ms here: "First sentence here." = 20 chars = 200 ms).
        _ = await rig.session.bargeIn(playedMs: 210)
        try await Task.sleep(for: .milliseconds(200))
        for turn in 2...4 {
            await rig.hearing.say("question \(turn)", turn: turn)
            _ = await rig.log.wait { $0.compactMap { if case .userTranscript(_, let t) = $0 { t } else { nil } }.count >= turn }
            try await rig.session.requestResponse(dna: sampleDNA)
            _ = await rig.log.wait { $0.compactMap { if case .responseDone(let s) = $0 { s } else { nil } }.count >= turn }
        }
        let bodies = rig.chatBodies
        let second = messages(bodies[1]).compactMap { $0["content"] as? String }
        #expect(second.contains("First sentence here."))
        #expect(!second.joined().contains("never heard"))
        let last = messages(bodies.last!)
        let nonSystem = last.filter { $0["role"] as? String != "system" }
        #expect(nonSystem.count <= 4)
        #expect(last.contains { ($0["content"] as? String ?? "").hasPrefix("EARLIER IN THIS CONVERSATION") })
    }

    /// Unreachable server → a provider-named problem asking whether it runs; the response fails, nothing else is tried.
    @Test func unreachableServerIsNamed() async throws {
        let hearing = FakeHearing()
        let recorder = TransportRecorder()
        let client = CompatClient(base: URL(string: "http://127.0.0.1:9")!, key: nil, transport: .live(redirects: .refuse, recorder: recorder))
        var o = CascadeOptions(model: "m"); o.warmUps = false
        let socket = CascadeSocket(options: o, hearing: hearing, chat: VendorChat(client: client, vendor: .ollama), voice: FakeVoice())
        var config = RealtimeSessionConfig(); TimingProfile.cascaded(stt: .onDevice).apply(to: &config); config.autoReconnect = false
        let session = RealtimeSession(config: config, credentials: { _ in .direct("") }, socketFactory: { _ in socket })
        let log = EventLog(session)
        try await session.connect()
        await hearing.say("hi", turn: 1)
        _ = await log.wait { !$0.compactMap { if case .userTranscript(_, let t) = $0 { t } else { nil } }.isEmpty }
        try await session.requestResponse(dna: sampleDNA)
        #expect(await log.wait { !$0.compactMap { if case .responseDone(let s) = $0 { s } else { nil } }.isEmpty })
        #expect(log.done.first?.status == "failed")
        let p = try #require(await firstProblem(socket))
        #expect(p == .unreachable(host: "127.0.0.1:9", vendor: .ollama))
        // A stopped server is not an Ollama bound to localhost: the plain question, no "Expose" claim.
        #expect(p.message == "Can't reach the AI server at 127.0.0.1:9 — is it running?")
        #expect(!p.message.contains("Expose"))
        #expect(recorder.records.allSatisfy { !$0.isOpenAI })
        await session.close()
    }

    /// Summaries (text-only, out of band) come back as output_text, never spoken.
    @Test func outOfBandTextSummary() async throws {
        let rig = try await CascadeRig.make(chat: { _, _ in .text("They talked about a dog.") })
        defer { Task { await rig.stop() } }
        let params = ResponseParams(conversation: "none", input: [.userText("transcript")], instructions: "Summarise.",
                                    maxOutputTokens: .limit(400), metadata: ["purpose": "x"], outputModalities: ["text"], tools: [])
        rig.socket.send(try ClientEvent.responseCreate(params, eventID: "e1").jsonText())
        let ok = await { () async -> Bool in
            for _ in 0..<200 { if rig.frames.types.contains("response.done") { return true }; try? await Task.sleep(for: .milliseconds(20)) }
            return false
        }()
        #expect(ok)
        let text = rig.frames.first("response.output_text.done")?.json["text"]?.stringValue
        #expect(text == "They talked about a dog.")
        #expect(rig.voice.texts.isEmpty)
        let body = try #require(rig.chatBodies.first)
        #expect(messages(body).first?["content"] as? String == "Summarise.")
        #expect(body["tools"] == nil)
    }
}
