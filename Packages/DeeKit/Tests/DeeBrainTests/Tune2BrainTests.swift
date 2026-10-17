import DeeCore
import DeeRealtime
import DeeVoice
import Foundation
import Testing
@testable import DeeBrain

/// Tune 2 (live run 20261009-143612): floor decisions from the transcription
/// deltas, backchannels, spoken preambles, the per-response token cap. Each test
/// reproduces a live trace where it can.
@Suite(.serialized) @MainActor struct Tune2BrainTests {
    /// `conversation.item.input_audio_transcription.delta`, as the live server sends it.
    static func delta(_ rig: BrainRig, _ item: String, _ text: String) {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        rig.socket.push(json: #"{"type":"conversation.item.input_audio_transcription.delta","event_id":"ev_d_\#(item)_\#(text.count)","item_id":"\#(item)","content_index":0,"delta":"\#(escaped)"}"#)
    }

    /// Streams `text` as the live burst does (a few words per delta).
    static func deltas(_ rig: BrainRig, _ item: String, _ text: String) {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var first = true
        while !words.isEmpty {
            let chunk = words.prefix(2).joined(separator: " ")
            words.removeFirst(min(2, words.count))
            delta(rig, item, (first ? "" : " ") + chunk)
            first = false
        }
    }

    static func assistantDelta(_ rig: BrainRig, _ resp: String, _ item: String, _ text: String) {
        rig.push(Srv.transcript(resp, item, text))
    }

    static func responseCaps(_ rig: BrainRig) -> [Int?] {
        rig.responseCreates().map { (($0["response"] as? [String: Any])?["max_output_tokens"] as? Int) }
    }

    // MARK: Unfinished turns caught from the deltas (F-COLL t03, F-EARLY p20c)

    /// fillers-holds-echo30 t03: "I was going to call my mom and" came back as
    /// "…my mom Ann." and was answered across the continuation. The deltas settle
    /// ~0.2 s before the full transcript and before Dee's first audio: the unheard
    /// fast reply is taken back and the continuation answers both.
    @Test func aTrailingAndHeardAsAnnIsHeldFromTheDeltas() async throws {
        let rig = try await BrainRig(tune: { $0.trailingWait = 1.0 })
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"))
        Self.deltas(rig, "item_u1", "I was going to call my mom Ann.")
        #expect(await rig.until { rig.brain.trace.contains(.held("trailing")) }, "\(rig.brain.trace)")
        #expect(await rig.until { rig.count("response.cancel") >= 1 }, "taken back before it was heard")
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        // The full transcript agrees: still held, no reply of its own.
        rig.push(Srv.userTranscript("item_u1", "I was going to call my mom Ann."))
        await rig.settle()
        rig.utterance("item_u2", startMs: 2500, endMs: 3500)
        #expect(await rig.until { rig.responseCreates().count == 2 }, "the continuation is answered")
        rig.push(Srv.responseCreated("resp_2"), Srv.responseDone("resp_2"))
        try? await Task.sleep(for: .milliseconds(1300))
        #expect(rig.responseCreates().count == 2, "the held turn was answered with the rest")
        rig.shutdown()
    }

    /// pauses-echo10 p20c: "Let me think. [2 s] Okay, tell me one fact about
    /// octopuses." The transcript said only "Let me." and Dee answered in the pause.
    @Test func letMeIsAHoldFromTheDeltas() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"))
        Self.deltas(rig, "item_u1", "Let me.")
        #expect(await rig.until { rig.count("response.cancel") >= 1 }, "\(rig.brain.trace)")
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        rig.push(Srv.userTranscript("item_u1", "Let me."))
        #expect(await rig.until { rig.brain.trace.contains(.held("holdOn")) })
        #expect(await rig.until { await rig.session.hasUnansweredUserTurn == false }, "released")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(rig.responseCreates().count == 1, "nothing answers \"let me\"")
        rig.shutdown()
    }

    /// The deltas say "unfinished" but the full words do not: it is answered then.
    @Test func theFullWordsOverruleTheDeltas() async throws {
        let rig = try await BrainRig(tune: { $0.trailingWait = 5 })
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"))
        Self.deltas(rig, "item_u1", "I went to the")
        #expect(await rig.until { rig.count("response.cancel") >= 1 })
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        rig.push(Srv.userTranscript("item_u1", "I went to the zoo today."))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "answered with its words, not after the hold")
        rig.shutdown()
    }

    /// dna-joke / feelings-echo30 j01: "Want to hear a joke? Why did the scarecrow
    /// win an award?" + pause: Dee answered at the question and was cut by the
    /// punchline. A riddle's set-up waits a beat; nothing follows → answered.
    @Test func aRiddleSetUpWaitsABeat() async throws {
        let rig = try await BrainRig(tune: { $0.riddleWait = 0.4 })
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"))
        Self.deltas(rig, "item_u1", "Want to hear a joke? Why did the scarecrow win an award?")
        #expect(await rig.until { rig.brain.trace.contains(.held("riddle")) })
        #expect(await rig.until { rig.count("response.cancel") >= 1 })
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        rig.push(Srv.userTranscript("item_u1", "Want to hear a joke? Why did the scarecrow win an award?"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "no punchline came: Dee answers")
        rig.shutdown()
    }

    /// A command answered fast (it was ordinary turn-taking) is taken back while
    /// unheard (the old command window waited 0.4 s on every turn after Dee's voice).
    @Test func aCommandsFastReplyIsTakenBack() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"))
        rig.push(Srv.userTranscript("item_u1", "Goodnight."))
        #expect(await rig.until { rig.host.commands == [.sleep] })
        #expect(await rig.until { rig.count("response.cancel") >= 1 }, "\(rig.trail())")
        rig.shutdown()
    }

    // MARK: Backchannels (user decision: "keep going" is not a barge-in)

    /// long-* c05 "Keep going, I'm listening." over Dee's voice: Dee goes on. No
    /// reply, no stop of Dee's voice, the turn is released.
    @Test func keepGoingOverHerVoiceLetsHerGoOn() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"))
        #expect(await rig.until { rig.brain.trace.contains(.responseStarted(kind: "reply")) })
        for _ in 0..<5 { rig.push(Srv.audio("resp_1", "item_a1", Sig.pcm(ms: 100))) }   // Dee's audio is out
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 0, text: "So the volcano went whoosh."))
        await rig.settle()
        rig.push(Srv.speechStarted("item_u2", ms: 3000))
        await rig.settle()
        rig.push(Srv.speechStopped("item_u2", ms: 4200), Srv.committed("item_u2"))
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "waitForPartial")) })
        Self.deltas(rig, "item_u2", "Keep going, I'm listening.")
        #expect(await rig.until { rig.brain.trace.contains(.backchannel("continued")) }, "\(rig.brain.trace)")
        rig.push(Srv.userTranscript("item_u2", "Keep going, I'm listening."))
        #expect(await rig.until { rig.host.heardLog.count == 1 })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.responseCreates().count == 1, "no reply to a backchannel")
        #expect(rig.count("response.cancel") == 0 && !rig.trail().contains { $0.hasPrefix("truncate:") }, "Dee's voice was not stopped")
        #expect(await rig.until { await rig.session.hasUnansweredUserTurn == false })
        rig.shutdown()
    }

    /// long-echo10 c02 "Don't stop, keep going." after the barge-in already cut Dee
    /// (it decides on the sound): Dee carries on from where Dee stopped.
    @Test func keepGoingAfterACutCarriesOn() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"))
        #expect(await rig.until { rig.brain.trace.contains(.responseStarted(kind: "reply")) })
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 0, text: "So the volcano went whoosh."))
        await rig.settle()
        rig.push(Srv.speechStarted("item_u2", ms: 3000))
        await rig.settle()
        rig.brain.inject(.itemPlayed(itemID: "item_a1", playedMs: 900, cut: true))      // the barge-in
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        rig.push(Srv.speechStopped("item_u2", ms: 4200), Srv.committed("item_u2"))
        Self.deltas(rig, "item_u2", "Don't stop, keep going.")
        #expect(await rig.until { rig.brain.trace.contains(.backchannel("resumed")) }, "\(rig.brain.trace)")
        #expect(await rig.until { rig.responseCreates().count == 2 })
        let dnaID = try #require(rig.trail().last { $0.hasPrefix("dna:") }).dropFirst(4)
        let dna = try #require(rig.dnaText(String(dnaID)))
        #expect(dna.contains("carry on from where you stopped"), "\(dna)")
        rig.push(Srv.userTranscript("item_u2", "Don't stop, keep going."))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.responseCreates().count == 2, "answered once")
        rig.shutdown()
    }

    /// Speech over Dee's voice that is a real turn ("Wait, what's a caldera?") is
    /// answered at once from its first words, not after the full transcript.
    @Test func aRealTurnOverHerVoiceIsAnsweredFromItsFirstWords() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"))
        #expect(await rig.until { rig.brain.trace.contains(.responseStarted(kind: "reply")) })
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 0, text: "So the volcano went whoosh."))
        await rig.settle()
        rig.push(Srv.speechStarted("item_u2", ms: 3000))
        await rig.settle()
        rig.brain.inject(.itemPlayed(itemID: "item_a1", playedMs: 900, cut: true))
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        rig.push(Srv.speechStopped("item_u2", ms: 4200), Srv.committed("item_u2"))
        Self.deltas(rig, "item_u2", "Wait, what's a caldera?")
        #expect(await rig.until { rig.responseCreates().count == 2 }, "before the full transcript")
        #expect(rig.host.heardLog.isEmpty, "no transcript yet")
        rig.shutdown()
    }

    /// No words in time over Dee's voice: answered fast after `overlapWait`.
    @Test func overlappedSpeechWithoutWordsIsAnsweredAfterTheWait() async throws {
        let rig = try await BrainRig(tune: { $0.overlapWait = 0.3 })
        try await rig.start()
        rig.brain.inject(.sentenceStarted(itemID: "item_a0", index: 0, text: "Hi."))
        rig.push(Srv.speechStarted("item_u1", ms: 100))
        await rig.settle()
        rig.brain.inject(.itemPlayed(itemID: "item_a0", playedMs: 300, cut: true))
        rig.push(Srv.speechStopped("item_u1", ms: 900), Srv.committed("item_u1"))
        #expect(await rig.until { rig.brain.trace.contains(.committed(plan: "waitForPartial")) })
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.shutdown()
    }

    // MARK: Spoken preambles (F-LEAK)

    /// names-echo10 n03: "Got it, let me think about how to respond to that." then a
    /// `remember` call. The opening is cut before it is heard and the turn answered
    /// again, once, with a reminder to answer straight away.
    @Test func aSpokenPreambleIsCutAndTheTurnAnsweredAgain() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        Self.assistantDelta(rig, "resp_1", "item_a1", "Got it, ")
        Self.assistantDelta(rig, "resp_1", "item_a1", "let me think")
        #expect(await rig.until { rig.brain.trace.contains(.preamble(cut: true)) }, "\(rig.brain.trace)")
        #expect(await rig.until { rig.count("response.cancel") >= 1 }, "\(rig.trail())")
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        #expect(await rig.until { rig.responseCreates().count == 2 }, "answered again")
        let dnaID = try #require(rig.trail().last { $0.hasPrefix("dna:") }).dropFirst(4)
        #expect(rig.dnaText(String(dnaID))?.contains("Answer them straight away") == true)
        // A second preamble is let be (never a loop of cuts).
        rig.push(Srv.responseCreated("resp_2"), Srv.messageAdded("resp_2", "item_a2"), Srv.itemAdded("item_a2", role: "assistant"))
        Self.assistantDelta(rig, "resp_2", "item_a2", "Let me think about that.")
        #expect(await rig.until { rig.brain.trace.contains(.preamble(cut: false)) })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.count("response.cancel") == 1)
        rig.shutdown()
    }

    /// p06c "Let me check what I remember…" before a `recall`: the retry gets the
    /// look-up itself in its DNA, so it has nothing left to narrate.
    @Test func thePreambleRetryCarriesTheLookUp() async throws {
        let rig = try await BrainRig(tools: [FakeTool(name: "recall", reply: "Name: Maya. Likes: volcanoes.")])
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"), Srv.itemAdded("item_a1", role: "assistant"))
        Self.assistantDelta(rig, "resp_1", "item_a1", "Let me check what I remember")
        #expect(await rig.until { rig.count("response.cancel") >= 1 })
        rig.push(Srv.responseDone("resp_1", status: "cancelled"))
        #expect(await rig.until { rig.responseCreates().count == 2 })
        let dnaID = try #require(rig.trail().last { $0.hasPrefix("dna:") }).dropFirst(4)
        let dna = try #require(rig.dnaText(String(dnaID)))
        #expect(dna.contains("You already looked up what you know about them") && dna.contains("Likes: volcanoes"), "\(dna)")
        rig.shutdown()
    }

    /// A real answer that happens to say "let me" later is never touched.
    @Test func anAnswerIsNotAPreamble() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"))
        Self.assistantDelta(rig, "resp_1", "item_a1", "Octopuses have three hearts, which is wild. ")
        Self.assistantDelta(rig, "resp_1", "item_a1", "Let me think of another one!")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.count("response.cancel") == 0)
        #expect(!rig.brain.trace.contains { if case .preamble = $0 { true } else { false } })
        rig.shutdown()
    }

    // MARK: Reply length (F-LEN)

    /// Every reply carries a per-response cap sized to the DNA `Length:` line.
    @Test func repliesCarryALengthCap() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        let cap = try #require(Self.responseCaps(rig).first ?? nil)
        #expect((280...480).contains(cap), "\(cap)")
        rig.shutdown()
    }

    /// A reply cut by the token limit stops at its last complete sentence: the
    /// unfinished one never plays (never mid-word).
    @Test func aTokenLimitedReplyStopsAtItsLastCompleteSentence() async throws {
        let rig = try await BrainRig()
        try await rig.start()
        rig.utterance("item_u1")
        #expect(await rig.until { rig.responseCreates().count == 1 })
        rig.push(Srv.responseCreated("resp_1"), Srv.messageAdded("resp_1", "item_a1"))
        #expect(await rig.until { rig.brain.trace.contains(.responseStarted(kind: "reply")) })
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 0, text: "Tomatoes love sun."))
        rig.socket.push(json: #"{"type":"response.done","event_id":"ev_rd_1","response":{"id":"resp_1","object":"realtime.response","status":"incomplete","status_details":{"type":"incomplete","reason":"max_output_tokens"},"output":[{"id":"item_a1","type":"message","role":"assistant","status":"incomplete","content":[]}]}}"#)
        #expect(await rig.until { rig.brain.trace.contains(.responseDone(status: "incomplete", reason: "max_output_tokens", audioMs: 0, inputTokens: nil, cachedTokens: nil)) || rig.brain.trace.contains { if case .responseDone(let s, _, _, _, _) = $0 { s == "incomplete" } else { false } } })
        rig.brain.inject(.sentenceFinished(itemID: "item_a1", index: 0, text: "Tomatoes love sun.", heard: true))
        #expect(!rig.brain.trace.contains(.tokenLimitStop), "a complete sentence plays")
        rig.brain.inject(.sentenceStarted(itemID: "item_a1", index: 1, text: "Give them six to eight hou"))
        #expect(await rig.until { rig.brain.trace.contains(.tokenLimitStop) }, "\(rig.brain.trace)")
        rig.shutdown()
    }
}

@Suite struct Tune2PolicyTests {
    @Test func misheardTrailingAnd() {
        for t in ["I was going to call my mom Ann.", "I had pasta for dinner an.", "We went to the park end.",
                  "Let me.", "Lemme think.", "Let's see."] {
            #expect(TurnPolicy.unfinished(t) != nil, "\(t)")
        }
        for t in ["My aunt is Ann.", "That's the end.", "It was the weekend.", "I'm going with Ann.", "We reached the end.",
                  "An apple a day."] {
            #expect(TurnPolicy.unfinished(t) == nil, "\(t)")
        }
    }

    /// Live A/B 20261009-171052 (server_vad 300 ms): the first halves the server
    /// committed at the pause and Dee answered.
    @Test func pausedHalvesAreUnfinished() {
        for t in ["So yesterday I went to the.", "The thing is.", "I think the answer is.", "What I really want to know is.",
                  "I'm going to.", "My favorite thing about weekends is", "It was a lot of", "I'll go with",
                  "We talked about", "I'm gonna"] {
            #expect(TurnPolicy.unfinished(t) != nil, "\(t)")
        }
        for t in ["That's what it is.", "Here we are.", "I know where it is.", "I want to.", "I'd love to.", "I have to.",
                  "I used to.", "That is how it is.", "I don't know what that is.", "Yes it is.", "We were.", "You're welcome to.",
                  "Farmers market with my sister.", "42.", "That's what I was thinking of.", "What are you looking at.",
                  "It's kind of.", "Who did you go with."] {
            #expect(TurnPolicy.unfinished(t) == nil, "\(t)")
        }
    }

    @Test func riddles() {
        for t in ["Want to hear a joke? Why did the scarecrow win an award?", "What do you call a fish with no eyes?",
                  "Here's a joke. Why did the chicken cross the road?", "So, what's the difference between a cat and a comma?"] {
            #expect(TurnPolicy.held(t) == .riddle, "\(t)")
        }
        for t in ["Why did you say that?", "Knock knock.", "What do you call your cat?", "How many hearts does an octopus have?",
                  "What's your favorite color?", "Why do you like blue?", "Why did the dinosaurs die out?",
                  "Do you like jokes?", "Tell me a joke. Why do you like jokes?", "What kind of music do you like?"] {
            #expect(TurnPolicy.held(t) != .riddle, "\(t)")
        }
    }

    @Test func backchannels() {
        for t in ["Keep going, I'm listening.", "Don't stop, keep going.", "Mm-hm.", "Uh-huh.", "Go on.", "Yeah, go on.",
                  "Keep going.", "No, keep going.", "Okay, keep going, Dee.", "mhm", "Really?"] {
            #expect(TurnPolicy.isBackchannel(t), "\(t)")
        }
        for t in ["Wait, stop talking for a second.", "Stop.", "No.", "Keep going with what?", "What did you say?",
                  "Yeah, but what about the moon?", "Okay, stop.", "Hold on.", "", "I like volcanoes too."] {
            #expect(!TurnPolicy.isBackchannel(t), "\(t)")
        }
    }

    @Test func preambles() {
        for t in ["Got it, let me think about how to respond to that.", "Let me check what I remember…",
                  "I'll check what I've got saved.", "Okay, let me think about that for a moment.", "Let me think how to respond.",
                  "Hmm, let me see what I have.", "Quick save for your name, then I'll respond.",
                  "Okay, fun! I'll tuck that away in my little memory bank first."] {
            #expect(TurnPolicy.isMetaPreamble(t), "\(t)")
        }
        for t in ["Octopuses have three hearts!", "That sounds like a vivid moment from your day; let me respond.",
                  "Let me guess, pizza?", "Ooh, let's go!", "Sure."] {
            #expect(!TurnPolicy.isMetaPreamble(t), "\(t)")
        }
    }

    /// The A/B's pick, pinned (server_vad, 300 ms; never answers or interrupts by itself).
    @Test func theChosenTurnDetection() throws {
        let t = CloudSettings.turnDetection
        #expect(t.type == "server_vad" && t.silenceDurationMs == 300 && t.prefixPaddingMs == 300 && t.threshold == 0.5)
        #expect(t.createResponse == false && t.interruptResponse == false)
        let json = String(data: try JSONEncoder().encode(t), encoding: .utf8) ?? ""
        #expect(json.contains(#""silence_duration_ms":300"#) && json.contains(#""create_response":false"#), "\(json)")
    }

    @Test func lengthCaps() {
        #expect(TurnPolicy.maxOutputTokens(length: "at most two short sentences", effort: .low) == 380)
        #expect(TurnPolicy.maxOutputTokens(length: "one short sentence", effort: .low) == 280)
        #expect(TurnPolicy.maxOutputTokens(length: "at most three short sentences", effort: .low) == 480)
        #expect(TurnPolicy.maxOutputTokens(length: "at most three short sentences", effort: .minimal) == 440, "tune 4: tighter at minimal")
        #expect(TurnPolicy.maxOutputTokens(length: "at most two short sentences", effort: .medium) == 680)
        #expect(TurnPolicy.maxOutputTokens(length: "at most two short sentences", effort: .high) == nil)
        #expect(TurnPolicy.wantsLongAnswer("Can you tell me a story about dragons?"))
        #expect(!TurnPolicy.wantsLongAnswer("What's your favorite color?"))
        #expect(TurnPolicy.isCompleteSentence("Tomatoes love sun."))
        #expect(TurnPolicy.isCompleteSentence("Really?\u{201D}"))
        #expect(!TurnPolicy.isCompleteSentence("Give them six to eight hou"))
    }
}
