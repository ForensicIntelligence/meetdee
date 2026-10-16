import Foundation
import Testing
import DeeRealtime
@testable import DeeLocal

@Suite struct AddressParserTests {
    @Test func bareHostPortGetsHTTP() throws {
        #expect(try AddressParser.parse("192.168.1.20:11434").absoluteString == "http://192.168.1.20:11434")
        #expect(try AddressParser.parse(" 10.0.0.5:1234/v1/ ").absoluteString == "http://10.0.0.5:1234")
        #expect(try AddressParser.parse("http://mac-studio.local:11434/v1").absoluteString == "http://mac-studio.local:11434")
        #expect(try AddressParser.parse("[fe80::1]:8080").absoluteString == "http://[fe80::1]:8080")
        #expect(try AddressParser.parse("studio:11434").absoluteString == "http://studio:11434")
        #expect(try AddressParser.parse("https://ai.example.com/prefix/v1").absoluteString == "https://ai.example.com/prefix")
    }

    @Test func publicNameWithoutSchemeGetsHTTPS() throws {
        #expect(try AddressParser.parse("ai.example.com").absoluteString == "https://ai.example.com")
    }

    @Test func refusesSecretsInURL() {
        #expect(throws: AddressError.userinfo) { try AddressParser.parse("http://user:pw@192.168.1.2:11434") }
        #expect(throws: AddressError.query) { try AddressParser.parse("http://192.168.1.2:11434/v1?key=abc") }
        #expect(throws: AddressError.fragment) { try AddressParser.parse("http://192.168.1.2:11434#x") }
        #expect(throws: AddressError.empty) { try AddressParser.parse("   ") }
        #expect(throws: AddressError.unsupportedScheme("ftp")) { try AddressParser.parse("ftp://192.168.1.2") }
    }

    @Test func plainHTTPOnlyToPrivate() {
        #expect(throws: AddressError.publicHTTP(host: "8.8.8.8:80")) { try AddressParser.parse("http://8.8.8.8:80") }
        #expect(throws: AddressError.publicHTTP(host: "192.168.1.20.example.com")) {
            try AddressParser.parse("http://192.168.1.20.example.com")
        }
        #expect(throws: AddressError.publicHTTP(host: "ai.example.com")) { try AddressParser.parse("http://ai.example.com") }
    }

    @Test(arguments: [
        ("10.1.2.3", HostClass.privateIP), ("172.16.0.1", .privateIP), ("172.31.255.255", .privateIP),
        ("172.32.0.1", .publicIP), ("192.168.0.1", .privateIP), ("127.0.0.1", .privateIP), ("169.254.3.4", .privateIP),
        ("100.64.0.1", .privateIP), ("100.127.255.1", .privateIP), ("100.128.0.1", .publicIP), ("8.8.8.8", .publicIP),
        ("::1", .privateIP), ("fd12::1", .privateIP), ("fc00::1", .privateIP), ("fe80::1%en0", .privateIP),
        ("2001:4860::8888", .publicIP), ("::ffff:192.168.1.1", .privateIP), ("::ffff:8.8.8.8", .publicIP),
        ("mac.local", .localName), ("studio", .localName), ("localhost", .localName),
        ("box.home.arpa", .needsResolve), ("box.lan", .needsResolve), ("box.internal", .needsResolve),
        ("192.168.1.20.example.com", .publicName), ("api.openai.com", .publicName),
    ])
    func classify(_ host: String, _ expected: HostClass) {
        #expect(AddressParser.classify(host: host) == expected)
    }

    @Test func suffixNamesResolveToPrivateIPLiteral() async throws {
        let resolver = StaticResolver(["box.lan": ["192.168.1.9"], "evil.lan": ["192.168.1.9", "8.8.8.8"]])
        let ok = try await NetworkPolicy.effectiveURL(URL(string: "http://box.lan:11434")!, resolver: resolver)
        #expect(ok.absoluteString == "http://192.168.1.9:11434")
        await #expect(throws: AddressError.publicHTTP(host: "evil.lan:11434")) {
            try await NetworkPolicy.effectiveURL(URL(string: "http://evil.lan:11434")!, resolver: resolver)
        }
        // https: TLS vouches for the name, nothing is rewritten.
        let tls = try await NetworkPolicy.effectiveURL(URL(string: "https://evil.lan")!, resolver: resolver)
        #expect(tls.absoluteString == "https://evil.lan")
    }
}

@Suite struct ProviderConfigTests {
    let brain = EndpointConfig(baseURL: URL(string: "http://192.168.1.20:11434")!, model: "qwen3.8:27b-mlx-bf16",
                               keyAccount: SecretAccount.lan(.brain))

    @Test func mode3NeverOpenAI() {
        var c = ProviderConfig.lanEverything(brain: brain)
        #expect(c.validate().isEmpty)
        c.tts = .openAIREST
        #expect(c.validate() == [.partNotAllowed(.voice, .lanEverything)])
        c.tts = .onDevice
        c.stt = .openAIRealtime
        #expect(c.validate() == [.partNotAllowed(.hearing, .lanEverything)])
    }

    @Test func openAIModesNeedKey() {
        #expect(ProviderConfig.openAI().validate(secrets: StaticSecrets()) == [.noOpenAIKey])
        #expect(ProviderConfig.openAI().validate(secrets: StaticSecrets([SecretAccount.openAI: "sk-x"])).isEmpty)
        #expect(ProviderConfig.lanBrainOpenAIVoice(brain: brain).validate(secrets: StaticSecrets()) == [.noOpenAIKey])
        #expect(ProviderConfig.lanEverything(brain: brain).validate(secrets: StaticSecrets()).isEmpty)
    }

    @Test func openAIKeyOverPlainHTTPRefused() {
        let c = ProviderConfig.lanEverything(brain: brain)
        let issues = c.validate(secrets: StaticSecrets([SecretAccount.lan(.brain): "sk-proj-abcdefghijklmnopqrstuvwxyz"]))
        #expect(issues == [.openAIKeyOverHTTP(host: "192.168.1.20:11434")])
        #expect(c.validate(secrets: StaticSecrets([SecretAccount.lan(.brain): "lm-studio-token"])).isEmpty)
    }

    /// K1: the persisted JSON holds no key, token or secret.
    @Test func jsonHoldsNoSecrets() throws {
        let c = ProviderConfig.lanBrainOpenAIVoice(brain: brain)
        let json = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        #expect(!json.contains("sk-"))
        for word in ["\"key\"", "token", "secret", "openAIKey", "password"] { #expect(!json.lowercased().contains(word.lowercased())) }
        #expect(try JSONDecoder().decode(ProviderConfig.self, from: Data(json.utf8)) == c)
    }

    @Test func publicHTTPStoredConfigRejected() {
        let bad = EndpointConfig(baseURL: URL(string: "http://ai.example.com")!, model: "m")
        #expect(ProviderConfig.lanEverything(brain: bad).validate().contains(.publicHTTP(host: "ai.example.com")))
    }
}

@Suite struct ThinkStripperTests {
    func run(_ chunks: [String]) -> (String, Bool) {
        var s = ThinkStripper()
        var text = ""
        var ended = false
        for c in chunks {
            for o in s.push(c) { if case .text(let t) = o { text += t } else { ended = true } }
        }
        for o in s.finish() { if case .text(let t) = o { text += t } else { ended = true } }
        return (text, ended)
    }

    @Test func dropsThinkBlocksSplitAcrossChunks() {
        #expect(run(["<thi", "nk>secret plan</th", "ink>Hello there."]).0 == "Hello there.")
        #expect(run(["Hi <think>x</think>you."]).0 == "Hi you.")
    }

    /// The measured Ollama leak: answer, stray </think>, answer repeated → only the first answer.
    @Test func strayCloseAfterTextEndsResponse() {
        let (text, ended) = run(["Your dog is **Biscuit** — a beagle! 🐶\n", "</think>\n\nOh yeah — your dog is **Biscuit**, a beagle! 🐶"])
        #expect(text == "Your dog is **Biscuit** — a beagle! 🐶\n")
        #expect(ended)
    }

    @Test func strayCloseBeforeTextDropsEverythingBefore() {
        #expect(run(["The user asks about the dog.</think>\n\nIt's Biscuit."]).0 == "It's Biscuit.")
    }

    @Test func unclosedThinkDropped() {
        #expect(run(["Sure. <think>and then I'll"]).0 == "Sure. ")
    }

    @Test func partialTagAtEndIsText() {
        #expect(run(["a < b and 3 <"]).0 == "a < b and 3 <")
    }

    @Test func leadingBlankLinesTrimmed() {
        #expect(run(["\n\n", "Hi!"]).0 == "Hi!")
    }
}

@Suite struct SpeechCleanerTests {
    @Test func stripsMarkdownEmojiStageDirections() {
        #expect(SpeechCleaner.clean("Your dog is **Biscuit** — a beagle! 🐶") == "Your dog is Biscuit — a beagle!")
        #expect(SpeechCleaner.clean("*giggles* That's funny.") == "That's funny.")
        #expect(SpeechCleaner.clean("## Hi\n- one") == "Hi\none")
        #expect(SpeechCleaner.clean("Dee: Hello 👋🏽!") == "Hello!")
        #expect(SpeechCleaner.clean("See [this](http://x.y) `code`") == "See this code")
        #expect(SpeechCleaner.clean("I ❤️ you") == "I you")
    }
}

@Suite struct SentenceChunkerTests {
    func chunks(_ deltas: [String]) -> [String] {
        var c = SentenceChunker()
        var out: [String] = []
        for d in deltas { out += c.push(d) }
        return out + c.finish()
    }

    @Test func sentencesAndEarlyClause() {
        #expect(chunks(["Oh yeah, your dog ", "is Biscuit, a beagle. ", "He loves walks!"])
                == ["Oh yeah, your dog is Biscuit,", "a beagle.", "He loves walks!"])
        // Fewer than four words before the comma: no early cut.
        #expect(chunks(["Oh, hi. How are you?"]) == ["Oh, hi.", "How are you?"])
    }

    @Test func keepsNumbersAndAbbreviationsWhole() {
        #expect(chunks(["It costs 3.5 dollars, Mr. Bell said. ", "Ok."]) == ["It costs 3.5 dollars,", "Mr. Bell said.", "Ok."])
        #expect(chunks(["Mr. Bell paid 3.5 dollars. ", "Ok."]) == ["Mr. Bell paid 3.5 dollars.", "Ok."])
        #expect(chunks(["There were 1,000 people at the show. Wow."]) == ["There were 1,000 people at the show.", "Wow."])
    }

    @Test func longRunsAreCut() {
        let long = String(repeating: "word ", count: 80)
        let out = chunks([long])
        #expect(out.count >= 2)
        #expect(out.allSatisfy { $0.count <= 220 })
    }
}

@Suite struct ChatDecoderTests {
    @Test func reasoningIsNeverContent() {
        let p = ChatChunkDecoder.decodeOpenAI(#"{"model":"m","choices":[{"index":0,"delta":{"reasoning":"hmm"},"finish_reason":null}]}"#)
        #expect(p == [.model("m"), .reasoning(3)])
        let q = ChatChunkDecoder.decodeOpenAI(#"{"choices":[{"delta":{"reasoning_content":"ok so"}}]}"#)
        #expect(q == [.reasoning(5)])
    }

    @Test func toolCallsAndUsage() {
        let p = ChatChunkDecoder.decodeOpenAI(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"id":"call_1","index":0,"type":"function","function":{"name":"recall","arguments":"{\"q\":"}}]},"finish_reason":null}]}"#)
        #expect(p == [.toolCallDelta(index: 0, id: "call_1", name: "recall", arguments: #"{"q":"#)])
        let u = ChatChunkDecoder.decodeOpenAI(#"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2,"prompt_tokens_details":{"cached_tokens":8}}}"#)
        #expect(u == [.usage(ChatUsage(promptTokens: 10, completionTokens: 2, cachedTokens: 8))])
    }

    @Test func ollamaNativeToolArgsObject() {
        var n = 0
        let p = ChatChunkDecoder.decodeOllama(#"{"model":"m","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"recall","arguments":{"query":"dog"}}}]},"done":false}"#, callCounter: &n)
        #expect(p == [.model("m"), .toolCall(ChatToolCall(id: "call_ollama_1", name: "recall", arguments: #"{"query":"dog"}"#))])
        let d = ChatChunkDecoder.decodeOllama(#"{"model":"m","message":{"role":"assistant","content":""},"done":true,"done_reason":"stop","prompt_eval_count":5,"eval_count":7}"#, callCounter: &n)
        #expect(d == [.model("m"), .usage(ChatUsage(promptTokens: 5, completionTokens: 7)), .finish(reason: "stop")])
    }

    @Test func sseJoinsAndSplits() {
        var p = SSEParser()
        var out = p.push(Data("data: {\"a\":1}\n\ndata: {\"b\"".utf8))
        out += p.push(Data(":2}\n\ndata: [DONE]\n\n".utf8))
        #expect(out == [.data(#"{"a":1}"#), .data(#"{"b":2}"#), .done])
    }

    @Test func requestBodyTurnsReasoningOffAndKeepsToolsOrdered() throws {
        let tools = [ChatTool(name: "recall", description: "d", parameters: nil), ChatTool(name: "remember", description: nil, parameters: nil)]
        let r = ChatRequest(model: "m", messages: [.system("s"), .user("u")], tools: tools, maxTokens: 50, keepAlive: "30m")
        let o = try #require(try JSONSerialization.jsonObject(with: r.openAIBody()) as? [String: Any])
        #expect(o["reasoning_effort"] as? String == "none")
        #expect(o["stream"] as? Bool == true)
        #expect((o["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
        #expect(o["keep_alive"] as? String == "30m")
        let names = (o["tools"] as? [[String: Any]])?.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        #expect(names == ["recall", "remember"])
        #expect(r.openAIBody() == r.openAIBody())   // byte-identical (prefix cache)
        let n = try #require(try JSONSerialization.jsonObject(with: r.ollamaBody()) as? [String: Any])
        #expect(n["think"] as? Bool == false)
    }
}
