import Foundation
import Testing
@testable import DeeRealtime

// Goldens are the JSON examples from the GA reference
// (developers.openai.com/api/reference/resources/realtime/{client,server}-events,
// cached in the design scratchpad as docs/reference_resources_realtime_*.md).
// Some doc examples are not strict JSON (trailing commas, `//` comments); those
// are removed here and nothing else is changed.

@Suite struct ClientEventGoldenTests {
    /// Encoding `event` gives exactly the documented JSON (as values, key order aside),
    /// and the documented JSON decodes back to `event`.
    func check(_ event: ClientEvent, _ doc: String) throws {
        let encoded = json(try event.jsonText())
        #expect(encoded == json(doc), "\(event.type)\n got: \(encoded.jsonText)\nwant: \(json(doc).jsonText)")
        let decoded = try Wire.decode(ClientEvent.self, doc)
        #expect(decoded == event)
    }

    @Test func sessionUpdate() throws {
        let params: RealtimeJSON = [
            "type": "object",
            "properties": [
                "theme": ["type": "string", "description": "Description of the theme for the color scheme."],
                "colors": [
                    "type": "array",
                    "description": "Array of five hex color codes based on the theme.",
                    "items": ["type": "string", "description": "Hex color code"],
                ],
            ],
            "required": ["theme", "colors"],
        ]
        let event = ClientEvent.sessionUpdate(SessionPayload(
            type: "realtime",
            instructions: "You are a creative assistant that helps with design tasks.",
            tools: [RealtimeTool(name: "display_color_palette",
                                 description: "Call this function when a user asks for a color palette.",
                                 parameters: params)],
            toolChoice: .auto))
        try check(event, """
            {
              "type": "session.update",
              "session": {
                "type": "realtime",
                "instructions": "You are a creative assistant that helps with design tasks.",
                "tools": [
                  {
                    "type": "function",
                    "name": "display_color_palette",
                    "description": "Call this function when a user asks for a color palette.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "theme": {
                          "type": "string",
                          "description": "Description of the theme for the color scheme."
                        },
                        "colors": {
                          "type": "array",
                          "description": "Array of five hex color codes based on the theme.",
                          "items": {
                            "type": "string",
                            "description": "Hex color code"
                          }
                        }
                      },
                      "required": [
                        "theme",
                        "colors"
                      ]
                    }
                  }
                ],
                "tool_choice": "auto"
              }
            }
            """)
    }

    @Test func noiseReductionOff() throws {
        // From the session.update prose: explicit null turns noise reduction off.
        let event = ClientEvent.sessionUpdate(SessionPayload(
            type: "realtime", audio: AudioConfig(input: AudioInputConfig(noiseReduction: .null))))
        #expect(json(try event.jsonText())
            == json(#"{"type":"session.update","session":{"type":"realtime","audio":{"input":{"noise_reduction":null}}}}"#))
    }

    @Test func inputAudioBuffer() throws {
        try check(.inputAudioAppend(audio: "Base64EncodedAudioData", eventID: "event_456"), """
            { "event_id": "event_456", "type": "input_audio_buffer.append", "audio": "Base64EncodedAudioData" }
            """)
        try check(.inputAudioCommit(eventID: "event_789"),
                  #"{ "event_id": "event_789", "type": "input_audio_buffer.commit" }"#)
        try check(.inputAudioClear(eventID: "event_012"),
                  #"{ "event_id": "event_012", "type": "input_audio_buffer.clear" }"#)
        try check(.outputAudioBufferClear(eventID: "optional_client_event_id"),
                  #"{ "event_id": "optional_client_event_id", "type": "output_audio_buffer.clear" }"#)
    }

    @Test func conversationItems() throws {
        try check(.itemCreate(.userText("hi")), """
            { "type": "conversation.item.create",
              "item": { "type": "message", "role": "user", "content": [ { "type": "input_text", "text": "hi" } ] } }
            """)
        try check(.itemRetrieve(itemID: "item_003", eventID: "event_901"),
                  #"{ "event_id": "event_901", "type": "conversation.item.retrieve", "item_id": "item_003" }"#)
        try check(.itemTruncate(itemID: "item_002", contentIndex: 0, audioEndMs: 1500, eventID: "event_678"), """
            { "event_id": "event_678", "type": "conversation.item.truncate", "item_id": "item_002",
              "content_index": 0, "audio_end_ms": 1500 }
            """)
        try check(.itemDelete(itemID: "item_003", eventID: "event_901"),
                  #"{ "event_id": "event_901", "type": "conversation.item.delete", "item_id": "item_003" }"#)
    }

    @Test func functionCallOutputAndSystemMessage() throws {
        // From the function-calling guide.
        try check(.itemCreate(.functionCallOutput(callID: "call_sHlR7iaFwQ2YQOqm",
                                                  output: #"{"horoscope": "You will soon meet a new friend."}"#)), """
            { "type": "conversation.item.create",
              "item": { "type": "function_call_output", "call_id": "call_sHlR7iaFwQ2YQOqm",
                        "output": "{\\"horoscope\\": \\"You will soon meet a new friend.\\"}" } }
            """)
        // Schema: RealtimeConversationItemSystemMessage.
        try check(.itemCreate(.systemMessage("<dee_state>calm</dee_state>")), """
            { "type": "conversation.item.create",
              "item": { "type": "message", "role": "system",
                        "content": [ { "type": "input_text", "text": "<dee_state>calm</dee_state>" } ] } }
            """)
    }

    @Test func responseCreate() throws {
        try check(.responseCreate(nil), #"{ "type": "response.create" }"#)
        let outOfBand = ResponseParams(
            conversation: "none",
            input: [.reference("item_12345"), .userText("Summarize the above message in one sentence.")],
            instructions: "Provide a concise answer.",
            metadata: ["response_purpose": "summarization"],
            outputModalities: ["text"],
            tools: [])
        try check(.responseCreate(outOfBand), """
            {
              "type": "response.create",
              "response": {
                "instructions": "Provide a concise answer.",
                "tools": [],
                "conversation": "none",
                "output_modalities": ["text"],
                "metadata": { "response_purpose": "summarization" },
                "input": [
                  { "type": "item_reference", "id": "item_12345" },
                  { "type": "message", "role": "user",
                    "content": [ { "type": "input_text", "text": "Summarize the above message in one sentence." } ] }
                ]
              }
            }
            """)
        // Per-response instructions + token cap (Dee's initiatives).
        try check(.responseCreate(ResponseParams(instructions: "Say one short thing about the lamp.",
                                                 maxOutputTokens: .limit(200))), """
            { "type": "response.create",
              "response": { "instructions": "Say one short thing about the lamp.", "max_output_tokens": 200 } }
            """)
        try check(.responseCreate(ResponseParams(maxOutputTokens: .inf)),
                  #"{ "type": "response.create", "response": { "max_output_tokens": "inf" } }"#)
    }

    @Test func responseCancel() throws {
        try check(.responseCancel(responseID: "resp_12345"), #"{ "type": "response.cancel", "response_id": "resp_12345" }"#)
        try check(.responseCancel(), #"{ "type": "response.cancel" }"#)
    }

    /// Dee's full session config, field by field against the GA schema.
    @Test func deeSessionPayload() throws {
        var c = RealtimeSessionConfig()
        c.instructions = "You are Dee."
        c.tools = [RealtimeTool(name: "remember", description: "Save a fact.",
                                parameters: ["type": "object", "properties": ["fact": ["type": "string"]]])]
        c.transcription?.keywords = ["Dee", "bad<keyword>", "line\nbreak", "  "]
        let text = try ClientEvent.sessionUpdate(c.sessionPayload(), eventID: "e1").jsonText()
        #expect(json(text) == json("""
            {
              "type": "session.update", "event_id": "e1",
              "session": {
                "type": "realtime",
                "model": "gpt-realtime-2.1-mini",
                "instructions": "You are Dee.",
                "output_modalities": ["audio"],
                "audio": {
                  "input": {
                    "format": { "type": "audio/pcm", "rate": 24000 },
                    "noise_reduction": { "type": "far_field" },
                    "transcription": { "model": "gpt-transcribe", "languages": ["en"],
                                       "keywords": ["Dee", "bad keyword", "line break"] },
                    "turn_detection": { "type": "semantic_vad", "eagerness": "auto",
                                        "create_response": false, "interrupt_response": false }
                  },
                  "output": { "format": { "type": "audio/pcm", "rate": 24000 }, "voice": "marin", "speed": 1 }
                },
                "tools": [ { "type": "function", "name": "remember", "description": "Save a fact.",
                             "parameters": { "type": "object", "properties": { "fact": { "type": "string" } } } } ],
                "tool_choice": "auto",
                "truncation": { "type": "retention_ratio", "retention_ratio": 0.8 },
                "tracing": null,
                "reasoning": { "effort": "low" }
              }
            }
            """))
        // tracing must be an explicit null on the wire, not absent.
        #expect(text.contains(#""tracing":null"#))
        // Mid-session updates never resend the voice.
        #expect(c.sessionPayload(includeVoice: false).audio?.output?.voice == nil)
        #expect(c.url.absoluteString == "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini")
    }

    @Test func nullablesAndSpecials() throws {
        var c = RealtimeSessionConfig()
        c.noiseReduction = nil
        c.transcription = nil
        c.truncationRetention = nil
        c.reasoningEffort = nil
        c.voice = .custom(id: "voice_1234")
        let s = json(try ClientEvent.sessionUpdate(c.sessionPayload()).jsonText())["session"]
        #expect(s?["audio"]?["input"]?["noise_reduction"] == .null)
        #expect(s?["audio"]?["input"]?["transcription"] == .null)
        #expect(s?["truncation"] == nil)
        #expect(s?["reasoning"] == nil)
        #expect(s?["audio"]?["output"]?["voice"] == ["id": "voice_1234"])
        #expect(s?["tool_choice"] == nil)   // no tools → no tool_choice
        #expect(json(try Wire.encode(Truncation.auto)) == "auto")
        #expect(try Wire.decode(Truncation.self, #"{"type":"retention_ratio","retention_ratio":0.5,"token_limits":{"post_instructions":5000}}"#)
            == .retentionRatio(0.5, postInstructionsTokens: 5000))
        #expect(json(try Wire.encode(ToolChoice.function("recall"))) == ["type": "function", "name": "recall"])
    }
}

@Suite struct ServerEventGoldenTests {
    /// Parses a documented example; it must decode to a known case and survive
    /// encode → parse unchanged.
    @discardableResult
    func parse(_ text: String) throws -> ServerEvent {
        let e = ServerEvent.parse(text)
        switch e {
        case .unknown(let t, _), .malformed(let t, _, _):
            Issue.record("did not decode \(t): \(e)")
        default:
            #expect(e.type == json(text)["type"]?.stringValue)
            #expect(ServerEvent.parse(try e.jsonText()) == e, "round trip \(e.type)")
        }
        return e
    }

    @Test func error() throws {
        let e = try parse("""
            { "event_id": "event_890", "type": "error",
              "error": { "type": "invalid_request_error", "code": "invalid_event",
                         "message": "The 'type' field is missing.", "param": null, "event_id": "event_567" } }
            """)
        guard case .error(let x) = e else { Issue.record("\(e)"); return }
        #expect(x.error.code == "invalid_event")
        #expect(x.error.eventID == "event_567")
        #expect(x.error.param == nil)
        #expect(RealtimeIssue.classify(x.error) == .invalidRequest)
    }

    @Test func sessionCreatedAndUpdated() throws {
        let created = try parse("""
            {
              "type": "session.created",
              "event_id": "event_C9G5RJeJ2gF77mV7f2B1j",
              "session": {
                "type": "realtime", "object": "realtime.session", "id": "sess_C9G5QPteg4UIbotdKLoYQ",
                "model": "gpt-realtime-2025-08-28", "output_modalities": ["audio"],
                "instructions": "Your knowledge cutoff is 2023-10.",
                "tools": [], "tool_choice": "auto", "max_output_tokens": "inf", "tracing": null, "prompt": null,
                "expires_at": 1756324625,
                "audio": {
                  "input": {
                    "format": { "type": "audio/pcm", "rate": 24000 },
                    "transcription": null, "noise_reduction": null,
                    "turn_detection": { "type": "server_vad", "threshold": 0.5, "prefix_padding_ms": 300,
                      "silence_duration_ms": 200, "idle_timeout_ms": null, "create_response": true,
                      "interrupt_response": true }
                  },
                  "output": { "format": { "type": "audio/pcm", "rate": 24000 }, "voice": "marin", "speed": 1 }
                },
                "include": null
              }
            }
            """)
        guard case .sessionCreated(let s) = created else { Issue.record("\(created)"); return }
        #expect(s.session.id == "sess_C9G5QPteg4UIbotdKLoYQ")
        #expect(s.session.model == "gpt-realtime-2025-08-28")
        #expect(s.session.voice == "marin")
        #expect(s.session.expiresAt == 1756324625)

        let updated = try parse("""
            { "type": "session.updated", "event_id": "event_C9G8mqI3IucaojlVKE8Cs",
              "session": { "type": "realtime", "object": "realtime.session", "id": "sess_C9G8l3zp50uFv4qgxfJ8o",
                           "model": "gpt-realtime-2025-08-28", "tools": [ { "type": "function",
                           "name": "display_color_palette", "parameters": { "type": "object", "strict": true } } ],
                           "expires_at": 1756324832 } }
            """)
        guard case .sessionUpdated(let u) = updated else { Issue.record("\(updated)"); return }
        #expect(u.session.id == "sess_C9G8l3zp50uFv4qgxfJ8o")
    }

    @Test func conversationItemEvents() throws {
        let added = try parse("""
            { "type": "conversation.item.added", "event_id": "event_C9G8pjSJCfRNEhMEnYAVy", "previous_item_id": null,
              "item": { "id": "item_C9G8pGVKYnaZu8PH5YQ9O", "type": "message", "status": "completed", "role": "user",
                        "content": [ { "type": "input_text", "text": "hi" } ] } }
            """)
        guard case .itemAdded(let a) = added else { Issue.record("\(added)"); return }
        #expect(a.previousItemID == nil)
        #expect(a.item.text == "hi")

        let done = try parse("""
            { "type": "conversation.item.done", "event_id": "event_CCXLgMZPo3qioWCeQa4WH",
              "previous_item_id": "item_CCXLecNJVIVR2HUy3ABLj",
              "item": { "id": "item_CCXLfxmM5sXVJVz4mCa2S", "type": "message", "status": "completed",
                        "role": "assistant", "content": [ { "type": "output_audio",
                        "transcript": "Oh, I can hear you loud and clear!" } ] } }
            """)
        guard case .itemDone(let d) = done else { Issue.record("\(done)"); return }
        #expect(d.item.role == "assistant")
        #expect(d.item.text == "Oh, I can hear you loud and clear!")

        try parse("""
            { "type": "conversation.item.retrieved", "event_id": "event_CCXGSizgEppa2d4XbKA7K",
              "item": { "id": "item_CCXGRxbY0n6WE4EszhF5w", "object": "realtime.item", "type": "message",
                        "status": "completed", "role": "assistant", "content": [ { "type": "audio",
                        "transcript": "Yes, I can hear you loud and clear.", "audio": "8//2//v/9//q/+//+P/s...",
                        "format": "pcm16" } ] } }
            """)
        try parse("""
            { "event_id": "event_1920", "type": "conversation.item.created", "previous_item_id": "msg_002",
              "item": { "id": "msg_003", "object": "realtime.item", "type": "message", "status": "completed",
                        "role": "user", "content": [] } }
            """)
        let truncated = try parse("""
            { "event_id": "event_2526", "type": "conversation.item.truncated", "item_id": "msg_004",
              "content_index": 0, "audio_end_ms": 1500 }
            """)
        #expect(truncated == .itemTruncated(.init(eventID: "event_2526", itemID: "msg_004", contentIndex: 0, audioEndMs: 1500)))
        let deleted = try parse(#"{ "event_id": "event_2728", "type": "conversation.item.deleted", "item_id": "msg_005" }"#)
        #expect(deleted == .itemDeleted(.init(eventID: "event_2728", itemID: "msg_005")))
    }

    @Test func inputTranscription() throws {
        let completed = try parse("""
            { "type": "conversation.item.input_audio_transcription.completed", "event_id": "event_CCXGRvtUVrax5SJAnNOWZ",
              "item_id": "item_CCXGQ4e1ht4cOraEYcuR2", "content_index": 0, "transcript": "Hey, can you hear me?",
              "usage": { "type": "tokens", "total_tokens": 22, "input_tokens": 13,
                         "input_token_details": { "text_tokens": 0, "audio_tokens": 13 }, "output_tokens": 9 } }
            """)
        guard case .inputTranscriptionCompleted(let c) = completed else { Issue.record("\(completed)"); return }
        #expect(c.transcript == "Hey, can you hear me?")
        #expect(c.usage?["total_tokens"] == 22)

        let delta = try parse("""
            { "type": "conversation.item.input_audio_transcription.delta", "event_id": "event_CCXGRxsAimPAs8kS2Wc7Z",
              "item_id": "item_CCXGQ4e1ht4cOraEYcuR2", "content_index": 0, "delta": "Hey", "obfuscation": "aLxx0jTEciOGe" }
            """)
        #expect(delta == .inputTranscriptionDelta(.init(eventID: "event_CCXGRxsAimPAs8kS2Wc7Z",
                                                        itemID: "item_CCXGQ4e1ht4cOraEYcuR2", delta: "Hey")))
        let failed = try parse("""
            { "event_id": "event_2324", "type": "conversation.item.input_audio_transcription.failed",
              "item_id": "msg_003", "content_index": 0,
              "error": { "type": "transcription_error", "code": "audio_unintelligible",
                         "message": "The audio could not be transcribed.", "param": null } }
            """)
        guard case .inputTranscriptionFailed(let f) = failed else { Issue.record("\(failed)"); return }
        #expect(f.error?.code == "audio_unintelligible")
    }

    @Test func inputAudioBuffer() throws {
        #expect(try parse(#"{ "event_id": "event_1121", "type": "input_audio_buffer.committed", "previous_item_id": "msg_001", "item_id": "msg_002" }"#)
            == .inputAudioCommitted(.init(eventID: "event_1121", previousItemID: "msg_001", itemID: "msg_002")))
        #expect(try parse(#"{ "event_id": "event_1314", "type": "input_audio_buffer.cleared" }"#)
            == .inputAudioCleared(.init(eventID: "event_1314")))
        #expect(try parse(#"{ "event_id": "event_1516", "type": "input_audio_buffer.speech_started", "audio_start_ms": 1000, "item_id": "msg_003" }"#)
            == .speechStarted(.init(eventID: "event_1516", audioStartMs: 1000, itemID: "msg_003")))
        #expect(try parse(#"{ "event_id": "event_1718", "type": "input_audio_buffer.speech_stopped", "audio_end_ms": 2000, "item_id": "msg_003" }"#)
            == .speechStopped(.init(eventID: "event_1718", audioEndMs: 2000, itemID: "msg_003")))
        try parse("""
            { "type":"input_audio_buffer.timeout_triggered", "event_id":"event_CEKKrf1KTGvemCPyiJTJ2",
              "audio_start_ms":13216, "audio_end_ms":19232, "item_id":"item_CEKKrWH0GiwN0ET97NUZc" }
            """)
    }

    @Test func responseLifecycle() throws {
        let created = try parse("""
            { "type": "response.created", "event_id": "event_C9G8pqbTEddBSIxbBN6Os",
              "response": { "object": "realtime.response", "id": "resp_C9G8p7IH2WxLbkgPNouYL", "status": "in_progress",
                "status_details": null, "output": [], "conversation_id": "conv_C9G8mmBkLhQJwCon3hoJN",
                "output_modalities": ["audio"], "max_output_tokens": "inf",
                "audio": { "output": { "format": { "type": "audio/pcm", "rate": 24000 }, "voice": "marin" } },
                "usage": null, "metadata": null } }
            """)
        guard case .responseCreated(let c) = created else { Issue.record("\(created)"); return }
        #expect(c.response.id == "resp_C9G8p7IH2WxLbkgPNouYL")
        #expect(c.response.maxOutputTokens == .inf)
        #expect(c.response.metadata == nil)

        let done = try parse("""
            { "type": "response.done", "event_id": "event_CCXHxcMy86rrKhBLDdqCh",
              "response": { "object": "realtime.response", "id": "resp_CCXHw0UJld10EzIUXQCNh", "status": "completed",
                "status_details": null,
                "output": [ { "id": "item_CCXHwGjjDUfOXbiySlK7i", "type": "message", "status": "completed",
                              "role": "assistant", "content": [ { "type": "output_audio",
                              "transcript": "Loud and clear! I can hear you perfectly. How can I help you today?" } ] } ],
                "conversation_id": "conv_CCXHsurMKcaVxIZvaCI5m", "output_modalities": ["audio"],
                "max_output_tokens": "inf",
                "audio": { "output": { "format": { "type": "audio/pcm", "rate": 24000 }, "voice": "alloy" } },
                "usage": { "total_tokens": 253, "input_tokens": 132, "output_tokens": 121,
                  "input_token_details": { "text_tokens": 119, "audio_tokens": 13, "image_tokens": 0, "cached_tokens": 64,
                    "cached_tokens_details": { "text_tokens": 64, "audio_tokens": 0, "image_tokens": 0 } },
                  "output_token_details": { "text_tokens": 30, "audio_tokens": 91 } },
                "metadata": null } }
            """)
        guard case .responseDone(let d) = done else { Issue.record("\(done)"); return }
        #expect(d.response.status == "completed")
        #expect(d.response.usage?.totalTokens == 253)
        #expect(d.response.usage?.inputTokenDetails?.cachedTokens == 64)
        #expect(d.response.usage?.inputTokenDetails?.cachedTokensDetails?.textTokens == 64)
        #expect(d.response.usage?.outputTokenDetails?.audioTokens == 91)
        #expect(d.response.output?.first?.text?.hasPrefix("Loud and clear!") == true)

        // Cancelled / content-filtered status details (schema: RealtimeResponseStatus).
        let cancelled = try parse("""
            { "type": "response.done", "event_id": "e", "response": { "id": "resp_1", "status": "cancelled",
              "status_details": { "type": "cancelled", "reason": "client_cancelled" } } }
            """)
        guard case .responseDone(let x) = cancelled else { Issue.record("\(cancelled)"); return }
        #expect(x.response.statusDetails?.reason == "client_cancelled")
        let failed = try parse("""
            { "type": "response.done", "event_id": "e", "response": { "id": "resp_2", "status": "failed",
              "status_details": { "type": "failed", "error": { "type": "rate_limit_error", "code": "rate_limit_exceeded" } } } }
            """)
        guard case .responseDone(let y) = failed else { Issue.record("\(failed)"); return }
        #expect(y.response.statusDetails?.error?.code == "rate_limit_exceeded")
    }

    @Test func outputItemsAndParts() throws {
        try parse("""
            { "event_id": "event_3334", "type": "response.output_item.added", "response_id": "resp_001", "output_index": 0,
              "item": { "id": "msg_007", "object": "realtime.item", "type": "message", "status": "in_progress",
                        "role": "assistant", "content": [] } }
            """)
        try parse("""
            { "event_id": "event_3536", "type": "response.output_item.done", "response_id": "resp_001", "output_index": 0,
              "item": { "id": "msg_007", "object": "realtime.item", "type": "message", "status": "completed",
                        "role": "assistant", "content": [ { "type": "text", "text": "Sure, I can help with that." } ] } }
            """)
        #expect(try parse("""
            { "event_id": "event_4142", "type": "response.output_text.delta", "response_id": "resp_001",
              "item_id": "msg_007", "output_index": 0, "content_index": 0, "delta": "Sure, I can h" }
            """) == .outputTextDelta(.init(eventID: "event_4142", responseID: "resp_001", itemID: "msg_007", delta: "Sure, I can h")))
        #expect(try parse("""
            { "event_id": "event_4344", "type": "response.output_text.done", "response_id": "resp_001",
              "item_id": "msg_007", "output_index": 0, "content_index": 0, "text": "Sure, I can help with that." }
            """) == .outputTextDone(.init(eventID: "event_4344", responseID: "resp_001", itemID: "msg_007",
                                          text: "Sure, I can help with that.")))
        #expect(try parse("""
            { "event_id": "event_4546", "type": "response.output_audio_transcript.delta", "response_id": "resp_001",
              "item_id": "msg_008", "output_index": 0, "content_index": 0, "delta": "Hello, how can I a" }
            """) == .outputAudioTranscriptDelta(.init(eventID: "event_4546", responseID: "resp_001", itemID: "msg_008",
                                                      delta: "Hello, how can I a")))
        let tdone = try parse("""
            { "event_id": "event_4748", "type": "response.output_audio_transcript.done", "response_id": "resp_001",
              "item_id": "msg_008", "output_index": 0, "content_index": 0, "transcript": "Hello, how can I assist you today?" }
            """)
        #expect(tdone == .outputAudioTranscriptDone(.init(eventID: "event_4748", responseID: "resp_001", itemID: "msg_008",
                                                          text: "Hello, how can I assist you today?")))
        // The transcript goes back out under "transcript", not "text".
        #expect(json(try tdone.jsonText())["transcript"] == "Hello, how can I assist you today?")
        #expect(try parse("""
            { "event_id": "event_4950", "type": "response.output_audio.delta", "response_id": "resp_001",
              "item_id": "msg_008", "output_index": 0, "content_index": 0, "delta": "Base64EncodedAudioDelta" }
            """) == .outputAudioDelta(.init(eventID: "event_4950", responseID: "resp_001", itemID: "msg_008",
                                            delta: "Base64EncodedAudioDelta")))
        #expect(try parse("""
            { "event_id": "event_5152", "type": "response.output_audio.done", "response_id": "resp_001",
              "item_id": "msg_008", "output_index": 0, "content_index": 0 }
            """) == .outputAudioDone(.init(eventID: "event_5152", responseID: "resp_001", itemID: "msg_008")))
    }

    @Test func functionCalls() throws {
        try parse("""
            { "event_id": "event_5354", "type": "response.function_call_arguments.delta", "response_id": "resp_002",
              "item_id": "fc_001", "output_index": 0, "call_id": "call_001", "delta": "{\\"location\\": \\"San\\"" }
            """)
        let done = try parse("""
            { "event_id": "event_5556", "type": "response.function_call_arguments.done", "response_id": "resp_002",
              "item_id": "fc_001", "output_index": 0, "call_id": "call_001", "name": "get_weather",
              "arguments": "{\\"location\\": \\"San Francisco\\"}" }
            """)
        guard case .functionCallArgumentsDone(let f) = done else { Issue.record("\(done)"); return }
        #expect(f.name == "get_weather")
        #expect(RealtimeJSON.parse(f.arguments)?["location"] == "San Francisco")
        // From the function-calling guide: the call inside response.done.
        let rd = try parse("""
            { "type": "response.done", "event_id": "event_AeqLA8iR6FK20L4XZs2P6",
              "response": { "object": "realtime.response", "id": "resp_AeqL8XwMUOri9OhcQJIu9", "status": "completed",
                "status_details": null, "output": [ { "object": "realtime.item", "id": "item_AeqL8gmRWDn9bIsUM2T35",
                "type": "function_call", "status": "completed", "name": "generate_horoscope",
                "call_id": "call_sHlR7iaFwQ2YQOqm", "arguments": "{\\"sign\\":\\"Aquarius\\"}" } ] } }
            """)
        guard case .responseDone(let r) = rd else { Issue.record("\(rd)"); return }
        #expect(r.response.output?.first?.callID == "call_sHlR7iaFwQ2YQOqm")
        #expect(r.response.output?.first?.name == "generate_horoscope")
    }

    @Test func rateLimits() throws {
        let e = try parse("""
            { "event_id": "event_5758", "type": "rate_limits.updated", "rate_limits": [
              { "name": "requests", "limit": 1000, "remaining": 999, "reset_seconds": 60 },
              { "name": "tokens", "limit": 50000, "remaining": 49950, "reset_seconds": 60 } ] }
            """)
        guard case .rateLimitsUpdated(let r) = e else { Issue.record("\(e)"); return }
        #expect(r.rateLimits == [RateLimit(name: "requests", limit: 1000, remaining: 999, resetSeconds: 60),
                                 RateLimit(name: "tokens", limit: 50000, remaining: 49950, resetSeconds: 60)])
    }

    @Test func unknownAndBrokenFramesNeverThrow() throws {
        // Real but unmodelled events.
        for text in [
            #"{ "event_id": "event_abc123", "type": "output_audio_buffer.started", "response_id": "resp_abc123" }"#,
            #"{ "event_id": "event_9101", "type": "conversation.created", "conversation": { "id": "conv_001", "object": "realtime.conversation" } }"#,
            #"{ "event_id": "event_6301", "type": "response.mcp_call.in_progress", "output_index": 0, "item_id": "mcp_call_001" }"#,
            #"{ "event_id": "event_3738", "type": "response.content_part.added", "response_id": "resp_001", "item_id": "msg_007", "output_index": 0, "content_index": 0, "part": { "type": "text", "text": "" } }"#,
            #"{"type":"some.future_event","x":[1,2,3]}"#,
        ] {
            let e = ServerEvent.parse(text)
            guard case .unknown(let type, let raw) = e else { Issue.record("expected unknown: \(e)"); continue }
            #expect(type == json(text)["type"]?.stringValue)
            #expect(raw == json(text))
            #expect(json(try e.jsonText()) == json(text))   // traces keep them verbatim
        }
        // A known type missing a required field.
        if case .malformed(let t, _, _) = ServerEvent.parse(#"{"type":"input_audio_buffer.speech_started"}"#) {
            #expect(t == "input_audio_buffer.speech_started")
        } else { Issue.record("expected malformed") }
        // Not JSON, no type.
        if case .malformed(let t, _, _) = ServerEvent.parse("not json") { #expect(t == "") } else { Issue.record("expected malformed") }
        if case .malformed = ServerEvent.parse(#"{"x":1}"#) {} else { Issue.record("expected malformed") }
        // Lenient integers.
        #expect(ServerEvent.parse(#"{"type":"conversation.item.truncated","item_id":"a","content_index":0.0,"audio_end_ms":1500.0}"#)
            == .itemTruncated(.init(itemID: "a", contentIndex: 0, audioEndMs: 1500)))
    }

    @Test func issueClassification() {
        func k(_ type: String?, _ code: String?, _ msg: String? = nil) -> RealtimeIssue.Kind {
            RealtimeIssue.classify(APIError(type: type, code: code, message: msg))
        }
        #expect(k("rate_limit_error", "slow_down") == .rateLimit)
        #expect(k("invalid_request_error", "rate_limit_exceeded") == .rateLimit)
        #expect(k("insufficient_quota", "insufficient_quota") == .quota)
        #expect(k("invalid_request_error", "invalid_api_key") == .auth)
        #expect(k("invalid_request_error", "content_policy_violation") == .moderation)
        #expect(k("server_error", nil) == .server)
        #expect(k("invalid_request_error", "session_expired") == .sessionExpired)
        #expect(k("invalid_request_error", "invalid_value") == .invalidRequest)
        #expect(k(nil, nil) == .other)
    }

    @Test func jsonValues() throws {
        let v = json(#"{"a":[1,2.5,true,null,"s"],"b":{"c":false}}"#)
        #expect(v["a"] == [1, 2.5, true, nil, "s"])
        #expect(v["b"]?["c"] == false)
        #expect(json(v.jsonText) == v)
        #expect(json("1").boolValue == nil)   // numbers never read as booleans
        #expect(RealtimeJSON.number(24000).jsonText == "24000")
    }
}
