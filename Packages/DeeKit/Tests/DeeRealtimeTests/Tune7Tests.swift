import Foundation
import Testing
@testable import DeeRealtime

/// Tune 7: the live tune-6 failures owned by DeeRealtime, replayed frame by frame
/// from `Tools/voice-harness/Traces/20261010-035320/` (item ids are the live ones).
///
/// - T6-1: dropping the server's empty tail of a burst cancelled the answer that
///   was requested after that tail committed (interrupt-clean q02, interrupt-fan15 q08).
/// - T6-2: the answer was cancelled at its first audio delta because `openSpeech`
///   stayed on the voice's quick-committed item (the applied openSpeech patch);
///   all 4 live cases (fan15 q05, kitchen15 q06, echo20 q02, echo20 q08).
@Suite struct Tune7Tests {
    /// One "question over Dee's reply" from a live trace.
    struct Window: CustomStringConvertible {
        var name: String
        /// Dee's reply that was playing, and where the voice cut it (the live truncate).
        var herItem: String
        var cutMs: Int
        /// The question (`speech_started` over Dee's audio, quick-committed by the voice).
        var question: String
        var said: String
        /// The server's unannounced tail item of the same burst (`speech_stopped` with no
        /// `speech_started`), whether it was committed, and its (empty) transcript.
        var tail: String
        var tailCommitted: Bool
        /// The brain's `response.create` went out after the tail's stop / commit.
        var requestAfterTail: Bool
        /// The tail's empty transcript (and so the voice's drop) came before the first audio.
        var tailDroppedBeforeAudio: Bool
        var response: String
        var answerItem: String
        var answer: String
        var description: String { name }
    }

    static let t61: [Window] = [
        // 39.436 started …mmkG; 40.327 commit; 40.395 committed; 40.552 stop+commit tail …nfNhl;
        // 40.684 request (after the tail); 41.113 tail "" → delete + cancel (live), first audio never.
        Window(name: "interrupt-clean q02", herItem: "item_EXPPkrR79WnjVia8BzQbC", cutMs: 1965,
               question: "item_EXPPmmkGEVNDI17lh5nbn", said: "Are you awake?",
               tail: "item_EXPPnfNhlq81wtvsQAMZI", tailCommitted: true, requestAfterTail: true,
               tailDroppedBeforeAudio: true, response: "resp_EXPPoZZRQjRMkZx5NQhKd",
               answerItem: "item_EXPPoCo5sDVsOaLjH7riV", answer: "Yes, I'm awake and listening."),
        // 18.782 started …jh51; 19.645 commit; 19.716 committed; 19.924 tail …kLkW committed;
        // 19.953 request; 20.513 tail "" → dee_del_28 + dee_cancel_29 in the same ms (live).
        Window(name: "interrupt-fan15 q08", herItem: "item_EXPQhABgBaMjun6888HZ3", cutMs: 1645,
               question: "item_EXPQjh51NiT5FnadwnFje", said: "Who are you?",
               tail: "item_EXPQkLkWvuvut0D6JwU0p", tailCommitted: true, requestAfterTail: true,
               tailDroppedBeforeAudio: true, response: "resp_EXPQlGwJOFiWmzaeiHc02",
               answerItem: "item_EXPQlufM0becVD0t3nN2w", answer: "Okay! So what would you like to know? I'm Dee."),
    ]

    static let t62: [Window] = [
        // 62.159 started …R6T; 63.31 commit; 63.38 committed; 63.606 request; 63.768 tail …SLpl
        // stop+commit; 64.182 first audio → response.cancel same ms (live); 64.22 tail "".
        Window(name: "interrupt-fan15 q05", herItem: "item_EXPROqgyOOIBsibAOEU4B", cutMs: 1765,
               question: "item_EXPRR6TIi2D105tS0lzlX", said: "Can you hear me okay?",
               tail: "item_EXPRSLplpV2lLZmkFfgVr", tailCommitted: true, requestAfterTail: false,
               tailDroppedBeforeAudio: false, response: "resp_EXPRSLg5v7FZyEKwl8gqo",
               answerItem: "item_EXPRSfySiT5WeUz0ntBlJ", answer: "Yes, I can hear you fine."),
        // 47.007 commit; 47.078 committed …MzBs; 47.23 request; 47.338 tail …OQEb stop+commit;
        // 47.713 tail ""; 47.912 first audio → cancel 47.913 (live).
        Window(name: "interrupt-kitchen15 q06", herItem: "item_EXPSJQp1SYSO6vNMcbDo9", cutMs: 2465,
               question: "item_EXPSMzBs3MqTJJItzSMHY", said: "What did you do today?",
               tail: "item_EXPSOQEbf8dfZnHoVCGFE", tailCommitted: true, requestAfterTail: false,
               tailDroppedBeforeAudio: true, response: "resp_EXPSPfBnT7MDv7PMB9Tum",
               answerItem: "item_EXPSP39jYipUKWuD9lv5T", answer: "Oh, hi! I watched the light move."),
        // 23.952 started …PmN3; 24.93 commit; 24.996 committed; 25.111 tail …QvaG stopped (no
        // commit); 25.406 request; 25.9 first audio → cancel same ms (live).
        Window(name: "interrupt-echo20 q02", herItem: "item_EXPTMvTFoJ1x3FjfcQbd2", cutMs: 1945,
               question: "item_EXPTPmN3B4SbkzqfzWFuE", said: "Are you awake?",
               tail: "item_EXPTQvaGUrMknRcW0CddK", tailCommitted: false, requestAfterTail: true,
               tailDroppedBeforeAudio: false, response: "resp_EXPTQnISp587l7meKlADr",
               answerItem: "item_EXPTQwr9xUR3BtSdVnZMh", answer: "Oh yes, I'm awake, listening."),
        // 49.712 started …poSX; 50.95 commit; 51.015 committed; 51.109 tail …qjFE stopped (no
        // commit); 51.221 request; 51.768 first audio → cancel same ms (live).
        Window(name: "interrupt-echo20 q08", herItem: "item_EXPTnPL068jh3mVW7YpIz", cutMs: 1485,
               question: "item_EXPTpoSXn6pFywfZXvNPD", said: "It's too new.",
               tail: "item_EXPTqjFEnUfeOAhj0zBUD", tailCommitted: false, requestAfterTail: true,
               tailDroppedBeforeAudio: false, response: "resp_EXPTqjDjW7zFOVns7Kmbk",
               answerItem: "item_EXPTqGXyQ41EjJGjqlACD", answer: "Hi Alex, I'm Dee, a tiny voice in your phone."),
    ]

    static let dna = "DEE DNA v7 · reply · response 8\n1 IDENTITY\nYou are Dee."

    /// Dee's reply playing when the question starts (not finished: still audible).
    func herReplyPlaying(_ h: Harness, _ w: Window) async throws {
        h.push(S.speechStarted("u0", ms: 30_000), S.speechStopped("u0", ms: 32_000), S.committed("u0"),
               S.userTranscript("u0", "I'm trying to plan a little garden."))
        await h.log.wait { $0 == .userTranscript(itemID: "u0", text: "I'm trying to plan a little garden.") }
        try await h.session.requestResponse(dna: Self.dna)
        h.push(S.responseCreated("r0"), S.messageAdded("r0", w.herItem), S.audio("r0", w.herItem, ms: 3000),
               S.transcriptDone("r0", w.herItem, "Good question. Tomatoes love bright sun."),
               S.audioDone("r0", w.herItem), S.responseDone("r0"))
        await h.log.wait { $0.responseDone?.responseID == "r0" }
        await h.sync()
    }

    /// Replays a window the way the live run went: the voice's quick commit, the
    /// server's tail, the voice's cut + accept, the brain's request (before or after
    /// the tail), the voice dropping the tail on its empty transcript, the answer.
    func replay(_ w: Window, request: (Harness) async throws -> RequestOutcome) async throws -> Harness {
        let h = try await Harness.connected()
        try await herReplyPlaying(h, w)
        h.push(S.speechStarted(w.question, ms: 39_028))
        await h.sync()
        #expect(await h.session.commitUserSpeech(), "\(w)")
        h.push(S.committed(w.question, previous: w.herItem))
        await h.sync()
        func tail() async {
            h.push(S.speechStopped(w.tail, ms: 40_480))
            if w.tailCommitted { h.push(S.committed(w.tail, previous: w.question)) }
            await h.sync()
        }
        func dropTail() async {
            guard w.tailCommitted else { return }
            h.push(S.userTranscript(w.tail, ""))
            await h.log.wait { $0 == .userTranscript(itemID: w.tail, text: "") }
            // CloudVoice: "empty tail dropped".
            await h.session.dropUserItem(itemID: w.tail, resumePreempted: false)
        }
        if w.requestAfterTail { await tail() }
        _ = await h.session.bargeIn(cuts: [(w.herItem, w.cutMs)])
        await h.session.acceptSpeech(itemID: w.question)
        #expect(try await request(h) == .sent, "\(w)")
        if !w.requestAfterTail { await tail() }
        h.push(S.responseCreated(w.response), S.messageAdded(w.response, w.answerItem), S.userTranscript(w.question, w.said))
        await h.log.wait { $0 == .userTranscript(itemID: w.question, text: w.said) }
        if w.tailDroppedBeforeAudio { await dropTail() }
        h.push(S.audio(w.response, w.answerItem, ms: 400))
        await h.sync()
        if !w.tailDroppedBeforeAudio { await dropTail() }
        h.push(S.audio(w.response, w.answerItem, ms: 400), S.transcriptDone(w.response, w.answerItem, w.answer),
               S.audioDone(w.response, w.answerItem), S.responseDone(w.response))
        await h.log.wait { $0.responseDone?.responseID == w.response }
        await h.sync()
        return h
    }

    /// Dee answers: no `response.cancel`, both audio deltas reach the app, the reply
    /// completes, and the history holds the question and Dee's whole answer.
    func expectAnswered(_ h: Harness, _ w: Window) async {
        #expect(h.sentCount("response.cancel") == 0, "\(w): the answer was cancelled")
        #expect(h.log.count { if case .assistantAudio(w.answerItem, _) = $0 { true } else { false } } == 2, "\(w)")
        #expect(!h.log.contains { $0 == .replyPreempted(responseID: w.response) }, "\(w)")
        let done = h.log.all.compactMap(\.responseDone).last { $0.responseID == w.response }
        #expect(done?.status == "completed", "\(w)")
        let turns = await h.session.recentTurns
        #expect(turns.contains { $0.role == .user && $0.itemID == w.question && $0.text == w.said }, "\(w)")
        #expect(turns.contains { $0.itemID == w.answerItem && $0.text == w.answer }, "\(w)")
        if w.tailCommitted {
            // The tail is gone from the conversation and the history.
            let deletes = h.socket.sent(type: "conversation.item.delete").compactMap { e -> String? in
                if case .itemDelete(let id, _) = e { id } else { nil }
            }
            #expect(deletes.contains(w.tail), "\(w)")
            #expect(!turns.contains { $0.itemID == w.tail }, "\(w)")
        }
    }

    // MARK: 1. T6-1: a reply is keyed to every item it answers

    /// Live interrupt-clean q02 and interrupt-fan15 q08: the request after the tail's
    /// commit answers the question *and* the tail; dropping the empty tail keeps it.
    @Test(arguments: Tune7Tests.t61)
    func droppingTheEmptyTailNeverCancelsTheAnswer(_ w: Window) async throws {
        let h = try await replay(w) { try await $0.session.requestResponse(dna: Self.dna) }
        await expectAnswered(h, w)
    }

    /// The same, with the brain naming the item it answers (`answering:`).
    @Test(arguments: Tune7Tests.t61)
    func aReplyNamedForTheQuestionIgnoresTheTail(_ w: Window) async throws {
        let h = try await replay(w) { try await $0.session.requestResponse(dna: Self.dna, answering: w.question) }
        await expectAnswered(h, w)
    }

    /// What `dropUserItem` must still do: a reply that answers only the dropped item
    /// (a TV line) is cancelled, and so is one whose dropped item had words.
    @Test func aReplyToTheDroppedItemAloneOrToItsWordsIsStillCancelled() async throws {
        // Only the dropped item.
        let h = try await Harness.connected()
        h.push(S.speechStarted("tv"), S.speechStopped("tv"), S.committed("tv"))
        await h.sync()
        try await h.session.requestResponse(dna: Self.dna)
        h.push(S.responseCreated("r1"), S.userTranscript("tv", "Tonight on channel nine."))
        await h.log.wait { $0 == .userTranscript(itemID: "tv", text: "Tonight on channel nine.") }
        await h.session.dropUserItem(itemID: "tv", resumePreempted: false)
        #expect(h.sentCount("response.cancel") == 1)

        // Question + a tail with words (people talking): the reply heard those words.
        let g = try await Harness.connected()
        g.push(S.speechStarted("q"), S.committed("q"), S.speechStopped("t"), S.committed("t", previous: "q"))
        await g.sync()
        try await g.session.requestResponse(dna: Self.dna)
        g.push(S.responseCreated("r2"), S.userTranscript("t", "pass the salt"))
        await g.log.wait { $0 == .userTranscript(itemID: "t", text: "pass the salt") }
        await g.session.dropUserItem(itemID: "t", resumePreempted: false)
        #expect(g.sentCount("response.cancel") == 1)

        // Named for the question: a dropped later item, words or not, is not its turn.
        let k = try await Harness.connected()
        k.push(S.speechStarted("q"), S.committed("q"), S.speechStopped("t"), S.committed("t", previous: "q"))
        await k.sync()
        try await k.session.requestResponse(dna: Self.dna, answering: "q")
        k.push(S.responseCreated("r3"), S.userTranscript("t", "pass the salt"))
        await k.log.wait { $0 == .userTranscript(itemID: "t", text: "pass the salt") }
        await k.session.dropUserItem(itemID: "t", resumePreempted: false)
        #expect(k.sentCount("response.cancel") == 0)
        // …but dropping the question itself still cancels it.
        await k.session.dropUserItem(itemID: "q", resumePreempted: false)
        #expect(k.sentCount("response.cancel") == 1)
    }

    /// After the tail is dropped, the turn is the question again: a later request
    /// (e.g. a retry) is keyed to it, not to nothing.
    @Test func afterTheTailIsDroppedTheQuestionIsTheTurnAgain() async throws {
        let h = try await Harness.connected()
        h.push(S.speechStarted("q"), S.committed("q"), S.speechStopped("t"), S.committed("t", previous: "q"),
               S.userTranscript("t", ""))
        await h.log.wait { $0 == .userTranscript(itemID: "t", text: "") }
        await h.session.dropUserItem(itemID: "t", resumePreempted: false)
        try await h.session.requestResponse(dna: Self.dna)
        h.push(S.responseCreated("r1"))
        await h.sync()
        // The question is the reply's turn: dropping it cancels the reply.
        await h.session.dropUserItem(itemID: "q", resumePreempted: false)
        #expect(h.sentCount("response.cancel") == 1)
    }

    // MARK: 2. T6-2: the applied openSpeech patch against all 4 live traces

    @Test(arguments: Tune7Tests.t62)
    func theAnswerIsNeverCancelledAtItsFirstAudio(_ w: Window) async throws {
        let h = try await replay(w) { try await $0.session.requestResponse(dna: Self.dna) }
        await expectAnswered(h, w)
        // Nothing of the session is left thinking the user is still talking.
        #expect(await h.session.state != .userTurn, "\(w)")
    }

    /// The gate itself still works: speech that really started after the request
    /// (no commit of it yet) preempts the answer at its first audio.
    @Test func realNewSpeechStillPreemptsAtFirstAudio() async throws {
        let h = try await Harness.connected()
        h.push(S.speechStarted("q"), S.speechStopped("q"), S.committed("q"), S.userTranscript("q", "Are you awake?"))
        await h.log.wait { $0 == .userTranscript(itemID: "q", text: "Are you awake?") }
        try await h.session.requestResponse(dna: Self.dna)
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"))
        await h.sync()
        h.push(S.speechStarted("n"))
        await h.sync()
        #expect(h.log.contains { $0 == .replyPreempted(responseID: "r1") })
        #expect(h.sentCount("response.cancel") == 1)
    }

    // MARK: 3. The brain's early request: `respondToSpeech`

    /// commit → DNA → response.create in one actor turn; the reply answers the
    /// commit that follows (the question), and the server's empty tail of the same
    /// burst, dropped later, never touches it.
    @Test func respondToSpeechCommitsAndAnswersTheCommittedSpeech() async throws {
        let h = try await Harness.connected()
        h.push(S.speechStarted("q", ms: 39_028))
        await h.sync()
        let before = h.socket.sentTypes.count
        #expect(try await h.session.respondToSpeech(dna: Self.dna) == .sent)
        let sent = h.socket.sentTypes.dropFirst(before).filter { $0 != "input_audio_buffer.append" }
        #expect(Array(sent) == ["input_audio_buffer.commit", "conversation.item.create", "response.create"])
        h.push(S.committed("q"), S.responseCreated("r1"), S.messageAdded("r1", "a1"),
               S.speechStopped("t"), S.committed("t", previous: "q"), S.userTranscript("q", "Are you awake?"),
               S.userTranscript("t", ""))
        await h.log.wait { $0 == .userTranscript(itemID: "t", text: "") }
        await h.session.dropUserItem(itemID: "t", resumePreempted: false)
        h.push(S.audio("r1", "a1", ms: 300), S.transcriptDone("r1", "a1", "Yes, I'm awake."), S.responseDone("r1"))
        await h.log.wait { $0.responseDone?.responseID == "r1" }
        #expect(h.sentCount("response.cancel") == 0)
        #expect(h.log.contains { $0.responseDone?.responseID == "r1" && $0.responseDone?.status == "completed" })
        // The question was answered: it holds nothing open.
        #expect(await !h.session.hasUnansweredUserTurn)
        // The question is its turn: had it been dropped before the audio, the reply goes.
        let g = try await Harness.connected()
        g.push(S.speechStarted("q"))
        await g.sync()
        try await g.session.respondToSpeech(dna: Self.dna)
        g.push(S.committed("q"), S.responseCreated("r1"))
        await g.sync()
        await g.session.dropUserItem(itemID: "q", resumePreempted: false)
        #expect(g.sentCount("response.cancel") == 1)
    }

    /// Nothing open: it is `requestResponse(dna:)`. A reply in flight: refused, and
    /// nothing is committed.
    @Test func respondToSpeechWithNothingOpenOrAReplyInFlight() async throws {
        let h = try await Harness.connected()
        h.push(S.speechStarted("q"), S.speechStopped("q"), S.committed("q"))
        await h.sync()
        #expect(try await h.session.respondToSpeech(dna: Self.dna) == .sent)
        #expect(h.sentCount("input_audio_buffer.commit") == 0)
        #expect(h.sentCount("response.create") == 1)
        // Dee's answer is playing; "q2" starts over it (maybe Dee's echo: nothing is preempted).
        h.push(S.responseCreated("r1"), S.messageAdded("r1", "a1"), S.audio("r1", "a1", ms: 300), S.speechStarted("q2"))
        await h.sync()
        await #expect(throws: RealtimeSessionError.self) { try await h.session.respondToSpeech(dna: Self.dna) }
        #expect(h.sentCount("input_audio_buffer.commit") == 0)
    }
}
