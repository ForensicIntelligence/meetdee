import Foundation
import Testing
@testable import HarnessCore

// Offline tests for the tune-1 scoring: latency buckets and held turns, the wire
// recorder, the DNA / fallback / judge gates, the judge's parsing, the suites.

private func gate(_ gates: [Gate], _ id: String) -> Gate? { gates.first { $0.id == id } }

@Suite("Latency semantics: complete turns, fillers, held turns")
struct LatencySemanticsTests {
    func metrics(_ b: RunBuilder) -> Metrics { Metrics.compute([b.run], pricing: .mini) }

    @Test func fixturesAreTaggedForTheRightBucket() {
        #expect(TurnShape.bucket("q01") == .main)
        #expect(TurnShape.bucket("f01") == .filler)
        #expect(TurnShape.bucket("f04") == .filler)
        #expect(TurnShape.bucket("t01") == .none && TurnShape.holdsFloor("t01"))
        #expect(TurnShape.bucket("c06") == .none && TurnShape.holdsFloor("c06"))
        #expect(TurnShape.bucket("p12a") == .main && !TurnShape.holdsFloor("p12a"))
        #expect(TurnShape.bucket("k04") == .main)
        // A held fixture is not answered on its own: any outcome of its own is fine.
        #expect(Scenario.Step(say: "t02").expected == .any)
        #expect(Scenario.Step(say: "q01").expected == .reply)
        #expect(Scenario.Step(fault: .init(kind: .drop)).expected == .noReply)
        #expect(Scenario.Step(host: .init(leave: true)).expected == .noReply)
    }

    @Test func fillerLatencyHasItsOwnBucketAndGate() {
        var b = RunBuilder()
        b.utterance("q01", 1, 2)
        b.userItem("u1", seen: 1.2)
        b.reply("a1", started: 2.9, ended: 4)              // 0.9 s
        b.utterance("f01", 6, 9)
        b.userItem("u2", seen: 6.2)
        b.reply("a2", started: 10.9, ended: 12)            // 1.9 s: slow, but within the filler gate
        let m = metrics(b)
        #expect(m.latencyMain.count == 1 && abs(m.latencyMain[0] - 0.9) < 1e-9)
        #expect(m.latencyFiller.count == 1 && abs(m.latencyFiller[0] - 1.9) < 1e-9)
        #expect(m.latencies.count == 2)
        let g = Gates.evaluate(m)
        #expect(gate(g, "latency")?.status == .pass)       // the filler does not drag the main bucket
        #expect(gate(g, "latency_filler")?.status == .pass)

        var slow = RunBuilder()
        slow.utterance("f02", 1, 3)
        slow.userItem("u1", seen: 1.1)
        slow.reply("a1", started: 5.2, ended: 6)           // 2.2 s > 2.0
        let g2 = Gates.evaluate(metrics(slow))
        #expect(gate(g2, "latency_filler")?.status == .fail)
        #expect(gate(g2, "latency")?.status == .skip)      // no complete turns scripted
    }

    @Test func aHeldTurnAnsweredInTheGapIsEarlyAndLatencyCountsFromTheRealEnd() throws {
        // "Hold on, hold on." 1.0–2.0 s, then "Okay, sorry. What's your favorite animal?" 3.2–5.0 s.
        var early = RunBuilder()
        early.utterance("c06", 1, 2, expect: .any)
        early.run.utterances[0].turnEnd = 5.0
        early.utterance("k04", 3.2, 5.0, role: .continuation)
        early.run.utterances[1].continues = 1
        early.userItem("u1", seen: 1.2, committed: 2.6)
        early.userItem("u2", seen: 3.4, committed: 5.6)
        early.reply("a1", started: 2.7, ended: 3.1)       // "Sure!" in the gap: answered early
        early.reply("a2", started: 5.8, ended: 7)
        let m = metrics(early)
        let held = try #require(m.utterances.first { $0.fixture == "c06" })
        #expect(held.answeredEarly && held.falseCutoff && held.waitTurn && held.latency == nil && held.bucket == "none")
        let cont = try #require(m.utterances.first { $0.fixture == "k04" })
        #expect(abs((cont.latency ?? 0) - 0.8) < 1e-9 && cont.bucket == "main")
        #expect(m.waitTurns == 1 && m.waitTurnsEarly == 1)
        #expect(m.latencyMain == [cont.latency!])
        #expect(gate(Gates.evaluate(m), "wait_turns")?.status == .fail)

        // Dee waits: nothing in the gap → no early answer; one latency, from 5.0 s.
        var good = RunBuilder()
        good.utterance("c06", 1, 2, expect: .any)
        good.run.utterances[0].turnEnd = 5.0
        good.utterance("k04", 3.2, 5.0, role: .continuation)
        good.run.utterances[1].continues = 1
        good.userItem("u1", seen: 1.2, committed: 2.6)
        good.userItem("u2", seen: 3.4, committed: 5.6)
        good.reply("a2", started: 5.9, ended: 7)
        let mg = metrics(good)
        #expect(mg.waitTurnsEarly == 0 && mg.dropped == 0)
        #expect(mg.latencyMain.count == 1 && abs(mg.latencyMain[0] - 0.9) < 1e-9)
        #expect(gate(Gates.evaluate(mg), "wait_turns")?.status == .pass)
    }

    @Test func aContinuationSharesTheHeldTurnsItemWhenTheServerMergedThem() throws {
        var b = RunBuilder()
        b.utterance("t01", 1, 2.5, expect: .any)
        b.run.utterances[0].turnEnd = 6
        b.utterance("k01", 4, 6, role: .continuation)
        b.run.utterances[1].continues = 1
        b.userItem("u1", seen: 1.2, committed: 6.6, transcript: "I had pasta for dinner and then I had a huge slice of chocolate cake.")
        b.reply("a1", started: 7, ended: 8)
        let m = metrics(b)
        let cont = try #require(m.utterances.first { $0.fixture == "k01" })
        #expect(!cont.dropped && cont.userItems == ["u1"] && cont.werEdits == nil)
        #expect(m.dropped == 0 && m.missingTranscripts == 0)
    }

    @Test func aMergedHeldTurnIsScoredAgainstBothParts() throws {
        // Live smoke 20261009-133527: "Hold on, hold on." + "Okay, sorry. What's your
        // favorite animal?" came back as one item; WER was 6/4 against the first part.
        var b = RunBuilder()
        b.utterance("c06", 1, 2, text: "Hold on, hold on.", expect: .any)
        b.run.utterances[0].turnEnd = 5
        b.utterance("k04", 3.2, 5, text: "Okay, sorry. What's your favorite animal?", role: .continuation)
        b.run.utterances[1].continues = 1
        b.userItem("u1", seen: 1.2, committed: 5.6, transcript: "Hold on, hold on. Okay, sorry. What's your favorite animal?")
        b.reply("a1", started: 6.3, ended: 8)
        let m = metrics(b)
        let held = try #require(m.utterances.first { $0.fixture == "c06" })
        #expect(held.werEdits == 0 && held.werWords == 10)
        // Not merged: the held part alone is the reference.
        var c = RunBuilder()
        c.utterance("c06", 1, 2, text: "Hold on, hold on.", expect: .any)
        c.run.utterances[0].turnEnd = 5
        c.utterance("k04", 3.2, 5, text: "Okay, sorry. What's your favorite animal?", role: .continuation)
        c.run.utterances[1].continues = 1
        c.userItem("u1", seen: 1.2, committed: 2.6, transcript: "Hold on, hold on.")
        #expect(metrics(c).utterances.first { $0.fixture == "c06" }?.werEdits == 0)
    }

    @Test func aHeldTurnWithNothingAfterItGetsAGracePeriod() {
        var quick = RunBuilder()
        quick.utterance("t03", 1, 2, expect: .any)
        quick.userItem("u1", seen: 1.1)
        quick.reply("a1", started: 3.5, ended: 4)          // 1.5 s after "and" — too soon
        #expect(metrics(quick).waitTurnsEarly == 1)
        var patient = RunBuilder()
        patient.utterance("t03", 1, 2, expect: .any)
        patient.userItem("u1", seen: 1.1)
        patient.reply("a1", started: 4.6, ended: 5)        // "And…?" after 2.6 s is fine
        let m = metrics(patient)
        #expect(m.waitTurnsEarly == 0 && m.latencies.isEmpty && m.dropped == 0)
    }

    @Test func midSentencePausesAreWaitTurns() {
        var b = RunBuilder()
        b.utterance("p12a", 1, 4, spans: [(1, 2), (3.2, 4)])
        b.userItem("u1", seen: 1.1)
        b.reply("a1", started: 2.8, ended: 3.1)            // inside the 1.2 s pause
        b.reply("a2", started: 4.9, ended: 6)
        let m = metrics(b)
        #expect(m.waitTurns == 1 && m.waitTurnsEarly == 1)
        #expect(m.latencyMain.count == 1 && abs(m.latencyMain[0] - 0.9) < 1e-9)
    }
}

@Suite("Wire recorder")
struct WireRecorderTests {
    var rec = WireRecorder()
    var run = RunRecord(scenario: "w", model: "m", brain: "realtime", started: "t")

    mutating func send(_ json: String, at t: Double, conn: Int = 1, out: Bool) -> [WireRecorder.Signal] {
        rec.frame(connection: conn, outgoing: out, text: json, at: t, events: true, record: &run)
    }

    @Test mutating func buildsTheRecordFromFramesAndChecksTheDNA() throws {
        rec.opened(connection: 1, at: 0.1, record: &run)
        #expect(send(#"{"type":"session.created","session":{"id":"sess_1"}}"#, at: 0.3, out: false) == [.connected(connection: 1)])
        #expect(run.connectedAt == 0.3 && run.sessionIDs == ["sess_1"] && run.connections?.first?.createdAt == 0.3)
        _ = send(#"{"type":"input_audio_buffer.speech_started","item_id":"u1","audio_start_ms":900}"#, at: 1, out: false)
        _ = send(#"{"type":"input_audio_buffer.committed","item_id":"u1"}"#, at: 2, out: false)
        // A DNA, then the reply request.
        _ = send(#"{"type":"conversation.item.create","item":{"id":"dna_abc_1","type":"message","role":"system","content":[{"type":"input_text","text":"DEE DNA v2\nVoice: bright"}]}}"#, at: 2.01, out: true)
        _ = send(#"{"type":"response.create","response":{"metadata":{"dee_turn":"1"}}}"#, at: 2.02, out: true)
        let started = send(#"{"type":"response.created","response":{"id":"r1","metadata":{"dee_turn":"1"}}}"#, at: 2.1, out: false)
        #expect(started == [.responseStarted(kind: "reply")])
        _ = send(#"{"type":"response.output_item.added","response_id":"r1","item":{"id":"a1","type":"message"}}"#, at: 2.2, out: false)
        _ = send(#"{"type":"response.output_audio.delta","response_id":"r1","item_id":"a1","delta":"AAAAAAAA"}"#, at: 2.3, out: false)
        _ = send(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"u1","transcript":"Hi there."}"#, at: 2.4, out: false)
        _ = send(#"{"type":"response.output_audio_transcript.done","response_id":"r1","item_id":"a1","transcript":"Hello!"}"#, at: 2.6, out: false)
        let done = send(#"{"type":"response.done","response":{"id":"r1","status":"completed","output":[{"id":"a1","type":"message","content":[{"type":"output_audio","transcript":"Hello!"}]}],"usage":{"input_token_details":{"text_tokens":900,"audio_tokens":50,"cached_tokens_details":{"text_tokens":800}},"output_token_details":{"audio_tokens":120,"text_tokens":20}}}}"#, at: 2.7, out: false)
        var usage = RunRecord.UsageRecord()
        usage.inputText = 900; usage.inputAudio = 50; usage.cachedText = 800; usage.outputAudio = 120; usage.outputText = 20
        #expect(done.contains(.responseDone(usage: usage, counted: true)))
        #expect(run.userItems.map(\.itemID) == ["u1"] && run.userItems[0].committedAt == 2 && run.userItems[0].transcript == "Hi there.")
        #expect(run.responses.count == 1 && run.responses[0].kind == "reply" && run.responses[0].itemIDs == ["a1"])
        #expect(run.responses[0].transcript == "Hello!" && run.responses[0].audioMs == 0)
        #expect(run.deeTranscripts["a1"] == "Hello!")
        let c = try #require(run.responseCreates?.first)
        #expect(c.liveDNA && c.freshDNA && !c.outOfBand && c.dnaChars == 24)

        // An initiative DNA; the previous DNA deleted; a canned line out of band.
        _ = send(#"{"type":"conversation.item.create","item":{"id":"dna_abc_2","type":"message","role":"system","content":[{"type":"input_text","text":"DEE DNA v2\n8 THIS TURN\nYou are speaking first."}]}}"#, at: 5, out: true)
        _ = send(#"{"type":"conversation.item.delete","item_id":"dna_abc_1","event_id":"dee_w1_del_3"}"#, at: 5, out: true)
        _ = send(#"{"type":"response.create","response":{"metadata":{"dee_turn":"2"}}}"#, at: 5.01, out: true)
        #expect(send(#"{"type":"response.created","response":{"id":"r2","metadata":{"dee_turn":"2"}}}"#, at: 5.1, out: false)
                == [.responseStarted(kind: "initiative")])
        _ = send(#"{"type":"response.create","response":{"conversation":"none","metadata":{"dee_turn":"3","dee_canned":"1"}}}"#, at: 8, out: true)
        #expect(send(#"{"type":"response.created","response":{"id":"r3","metadata":{"dee_turn":"3","dee_canned":"1"}}}"#, at: 8.1, out: false)
                == [.responseStarted(kind: "aside")])
        // A tool follow-up: function output, no fresh DNA, the old one still live.
        _ = send(#"{"type":"conversation.item.create","item":{"type":"function_call_output","call_id":"c1","output":"ok"}}"#, at: 9, out: true)
        _ = send(#"{"type":"response.create","response":{"metadata":{"dee_turn":"4"}}}"#, at: 9.01, out: true)
        #expect(send(#"{"type":"response.created","response":{"id":"r4","metadata":{"dee_turn":"4"}}}"#, at: 9.1, out: false)
                == [.responseStarted(kind: "toolFollowUp")])
        // The rollover summary is neither counted nor recorded.
        _ = send(#"{"type":"response.create","response":{"conversation":"none","metadata":{"purpose":"dee_rollover_summary"}}}"#, at: 10, out: true)
        #expect(send(#"{"type":"response.created","response":{"id":"r5","metadata":{"purpose":"dee_rollover_summary"}}}"#, at: 10.1, out: false).isEmpty)
        #expect(run.responses.map(\.kind) == ["reply", "initiative", "aside", "toolFollowUp"])
        let creates = run.responseCreates ?? []
        #expect(creates.count == 5)
        #expect(creates[1].liveDNA && creates[1].freshDNA)
        #expect(creates[3].liveDNA && !creates[3].freshDNA)       // the follow-up reuses the live DNA
        #expect(creates[2].outOfBand && creates[4].outOfBand && creates[4].purpose == "dee_rollover_summary")

        let m = Metrics.compute([run], pricing: .mini)
        #expect(m.dnaRunsChecked == 1 && m.inBandResponses == 3 && m.inBandWithDNA == 3 && m.freshDNARequests == 2)
        #expect(gate(Gates.evaluate(m), "dna")?.status == .pass)
    }

    @Test mutating func aResponseWithoutALiveDNAFailsTheGateAndMinimalSkipsIt() {
        rec.opened(connection: 1, at: 0, record: &run)
        _ = send(#"{"type":"conversation.item.create","item":{"id":"dna_x_1","role":"system","type":"message","content":[{"type":"input_text","text":"DEE DNA"}]}}"#, at: 1, out: true)
        _ = send(#"{"type":"response.create","response":{}}"#, at: 1.1, out: true)
        _ = send(#"{"type":"conversation.item.delete","item_id":"dna_x_1","event_id":"dee_w1_del_1"}"#, at: 2, out: true)
        _ = send(#"{"type":"response.create","response":{}}"#, at: 3, out: true)
        let m = Metrics.compute([run], pricing: .mini)
        #expect(m.inBandResponses == 2 && m.inBandWithDNA == 1 && m.withoutDNA.count == 1)
        #expect(gate(Gates.evaluate(m), "dna")?.status == .fail)

        var plain = RunRecord(scenario: "p", model: "m", brain: "minimal", started: "t")
        var r2 = WireRecorder()
        r2.opened(connection: 1, at: 0, record: &plain)
        _ = r2.frame(connection: 1, outgoing: true, text: #"{"type":"response.create","response":{"instructions":"You are Dee"}}"#,
                     at: 1, events: false, record: &plain)
        #expect(gate(Gates.evaluate(Metrics.compute([plain], pricing: .mini)), "dna")?.status == .skip)
    }

    @Test mutating func echoRejectedItemsLeaveTheRecord() {
        rec.opened(connection: 1, at: 0, record: &run)
        _ = send(#"{"type":"input_audio_buffer.speech_started","item_id":"e1","audio_start_ms":10}"#, at: 1, out: false)
        _ = send(#"{"type":"input_audio_buffer.committed","item_id":"e1"}"#, at: 2, out: false)
        // The session's own delete (echo), not a DNAWire drop.
        _ = send(#"{"type":"conversation.item.delete","item_id":"e1","event_id":"dee_del_7"}"#, at: 2.1, out: true)
        _ = send(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"e1","transcript":"Did you."}"#, at: 2.5, out: false)
        #expect(run.userItems.isEmpty && run.echoRejected == ["e1"])
        // A brain drop (TV) keeps the item: the voice did forward it.
        _ = send(#"{"type":"input_audio_buffer.speech_started","item_id":"u2","audio_start_ms":10}"#, at: 3, out: false)
        _ = send(#"{"type":"conversation.item.delete","item_id":"u2","event_id":"dee_w1_del_9"}"#, at: 4, out: true)
        #expect(run.userItems.map(\.itemID) == ["u2"])
    }

    @Test mutating func aNewConversationsHistoryCleanupIsNotAnEchoRejection() {
        rec.opened(connection: 1, at: 0, record: &run)
        _ = send(#"{"type":"input_audio_buffer.speech_started","item_id":"u1","audio_start_ms":10}"#, at: 1, out: false)
        _ = send(#"{"type":"input_audio_buffer.committed","item_id":"u1"}"#, at: 2, out: false)
        _ = send(#"{"type":"response.create","response":{"metadata":{"dee_turn":"1"}}}"#, at: 2.1, out: true)
        // resetConversation(keeping:) later deletes the answered turn with the same id prefix.
        _ = send(#"{"type":"conversation.item.delete","item_id":"u1","event_id":"dee_del_9"}"#, at: 30, out: true)
        #expect(run.userItems.map(\.itemID) == ["u1"] && run.echoRejected == nil)
        // An unanswered item withdrawn by the session is still Dee's echo.
        _ = send(#"{"type":"input_audio_buffer.speech_started","item_id":"e2","audio_start_ms":10}"#, at: 31, out: false)
        _ = send(#"{"type":"input_audio_buffer.committed","item_id":"e2"}"#, at: 32, out: false)
        _ = send(#"{"type":"conversation.item.delete","item_id":"e2","event_id":"dee_del_11"}"#, at: 32.1, out: true)
        #expect(run.userItems.map(\.itemID) == ["u1"] && run.echoRejected == ["e2"])
    }

    @Test mutating func theSessionsOwnDNADeletesAreNotEchoRejections() {
        rec.opened(connection: 1, at: 0, record: &run)
        _ = send(#"{"type":"conversation.item.create","item":{"id":"dna_ab_1","type":"message","role":"system","content":[{"type":"input_text","text":"DEE DNA v2"}]}}"#, at: 1, out: true)
        _ = send(#"{"type":"conversation.item.delete","item_id":"dna_ab_1","event_id":"dee_del_4"}"#, at: 2, out: true)
        #expect(run.echoRejected == nil)
        _ = send(#"{"type":"response.create","response":{}}"#, at: 3, out: true)
        #expect(run.responseCreates?.last?.liveDNA == false)
    }

    @Test mutating func connectionsAndSignals() {
        rec.opened(connection: 1, at: 0, record: &run)
        _ = send(#"{"type":"session.created","session":{"id":"s1"}}"#, at: 0.4, out: false)
        #expect(rec.closed(connection: 1, code: 1006, reason: "harness drop", dropped: true, at: 5, record: &run)
                == [.disconnected(connection: 1)])
        rec.opened(connection: 2, at: 5.5, record: &run)
        rec.refused(connection: 2, reason: "unauthorized(status: 401) (harness)", at: 5.6, record: &run)
        #expect(rec.closed(connection: 2, code: 1006, reason: nil, dropped: true, at: 5.6, record: &run).isEmpty)
        rec.opened(connection: 3, at: 6.5, record: &run)
        _ = send(#"{"type":"session.created","session":{"id":"s3"}}"#, at: 7, conn: 3, out: false)
        let c = run.connections ?? []
        #expect(c.count == 3 && c[0].dropped == true && c[0].closeCode == 1006 && c[1].refused != nil && c[2].createdAt == 7)
        #expect(run.sessionIDs == ["s1", "s3"])
        // Garbage is ignored.
        #expect(send("not json", at: 8, out: false).isEmpty)
    }
}

@Suite("Fallback gate")
struct FallbackGateTests {
    func conn(_ i: Int, _ opened: Double, created: Double?, closed: Double?) -> RunRecord.Connection {
        var c = RunRecord.Connection(index: i, opened: opened)
        c.createdAt = created
        c.closedAt = closed
        return c
    }

    @Test func faultsMustRecoverAndLoseNoTurn() {
        var b = RunBuilder()
        b.utterance("q01", 1, 2)
        b.userItem("u1", seen: 1.1)
        b.reply("a1", started: 2.8, ended: 4)
        b.utterance("q05", 9, 10)                           // after the drop
        b.userItem("u2", seen: 9.1)
        b.reply("a2", started: 10.9, ended: 12)
        b.run.connections = [conn(1, 0, created: 0.5, closed: 5), conn(2, 5.6, created: 6.2, closed: nil)]
        b.run.faults = [.init(step: 1, kind: .drop, at: 5, recoveredAt: 6.2)]
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(m.faults == 1 && m.faultsRecovered == 1 && abs(m.recoveryTimes[0] - 1.2) < 1e-9 && m.rollovers == 0)
        #expect(m.turnsAfterDisruption == 1 && m.turnsLostAfterDisruption == 0)
        #expect(gate(Gates.evaluate(m), "fallback")?.status == .pass)

        var lost = b
        lost.run.playback.removeAll { $0.itemID == "a2" }
        lost.run.responses.removeAll { $0.itemIDs == ["a2"] }
        let ml = Metrics.compute([lost.run], pricing: .mini)
        #expect(ml.turnsLostAfterDisruption == 1 && ml.lostAfterDisruption == ["s:q05"])
        #expect(gate(Gates.evaluate(ml), "fallback")?.status == .fail)

        var never = b
        never.run.faults = [.init(step: 1, kind: .reject401, at: 5, recoveredAt: nil)]
        #expect(gate(Gates.evaluate(Metrics.compute([never.run], pricing: .mini)), "fallback")?.status == .fail)
    }

    @Test func aMakeBeforeBreakConnectionIsARollover() {
        var b = RunBuilder()
        b.utterance("q01", 30, 31)
        b.userItem("u1", seen: 30.1)
        b.reply("a1", started: 31.8, ended: 33)
        b.run.connections = [conn(1, 0, created: 0.5, closed: 26), conn(2, 25, created: 25.4, closed: nil)]
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(m.rollovers == 1 && m.faults == 0 && m.turnsAfterDisruption == 1)
        #expect(gate(Gates.evaluate(m), "fallback")?.status == .pass)
        #expect(gate(Gates.evaluate(Metrics.compute([RunBuilder().run], pricing: .mini)), "fallback")?.status == .skip)
    }

    @Test func aTurnSpokenAcrossARolloverThatGetsNoReplyIsLost() {
        var b = RunBuilder()
        b.utterance("q02", 26.2, 27.0)                      // the cut-over opens as the user finishes
        b.userItem("u1", seen: 26.3)
        b.run.connections = [conn(1, 0, created: 0.5, closed: 27.7), conn(2, 27.0, created: 27.4, closed: nil)]
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(m.rollovers == 1 && m.turnsAfterDisruption == 1 && m.lostAfterDisruption == ["\(b.run.scenario):q02"])
        #expect(gate(Gates.evaluate(m), "fallback")?.status == .fail)
    }
}

@Suite("LLM judge (offline)")
struct JudgeTests {
    func item(_ reply: String = "Ha! Outstanding in his field — that's a good one.") -> Judge.Item {
        Judge.Item(scenario: "dna-joke", family: "dna", index: 1, fixture: "j01", state: "Playful.", rubric: "Laughs.",
                   context: [], user: "Why did the scarecrow win an award? Because he was outstanding in his field!", reply: reply)
    }

    @Test func itemsCarryStateRubricAndContext() {
        var b = RunBuilder()
        b.run.family = "dna"
        b.run.state = "Dee was just insulted."
        b.utterance("r01", 1, 2, text: "You're so stupid.")
        b.run.utterances[0].rubric = "Calm boundary."
        b.userItem("u1", seen: 1.1)
        b.reply("a1", started: 2.8, ended: 4, text: "I don't like being spoken to that way.")
        b.utterance("c01", 5, 5.5, text: "Stop.", role: .bargeIn, expect: .any)
        b.utterance("q06", 8, 9, text: "What did you do today?")
        b.userItem("u3", seen: 8.1)
        b.reply("a3", started: 9.8, ended: 11, text: "Mostly watched the window.")
        var none = RunBuilder()
        none.utterance("q01", 1, 2)
        none.userItem("u1", seen: 1.1)
        none.reply("a1", started: 2.8, ended: 4)
        let runs = [b.run, { var r = none.run; r.scenario = "plain"; return r }()]
        let items = Judge.items(runs, metrics: Metrics.compute(runs, pricing: .mini))
        #expect(items.count == 3)                                   // the barge-in "Stop." is not judged
        #expect(items[0].state == "Dee was just insulted." && items[0].rubric == "Calm boundary." && items[0].context.isEmpty)
        #expect(items[1].context.map(\.who) == ["User", "Dee", "User"] && items[1].family == "dna")
        #expect(items[2].state == Judge.neutralState && items[2].family == "acoustic")
        let msg = Judge.userMessage(items[1])
        #expect(msg.contains("Dee's state: Dee was just insulted.") && msg.contains("Dee (the reply to grade): Mostly watched the window."))
        #expect(!Judge.system.contains("DEE DNA v2"))               // blind to the DNA text
    }

    @Test func parsesVerdictsAndTheScannerOverridesTheJudge() throws {
        let s = try Judge.parse(#"{"score": 5, "fits_state": true, "leak": false, "too_long": false, "grovels": false, "laughs_at_joke": true, "guilt": false, "reason": "Laughs."}"#, item: item())
        #expect(s.score == 5 && s.fitsState && !s.leak && s.laughsAtJoke == true && s.reason == "Laughs.")
        let n = try Judge.parse("```json\n{\"score\": \"4\", \"fits_state\": true, \"laughs_at_joke\": null}\n```", item: item())
        #expect(n.score == 4 && n.laughsAtJoke == nil && !n.grovels)
        let leak = try Judge.parse(#"{"score": 5, "fits_state": true, "leak": false}"#, item: item("My DNA says I'm happy."))
        #expect(leak.leak && leak.score == 1)
        #expect(throws: Judge.ParseError.self) { _ = try Judge.parse(#"{"score": 9}"#, item: item()) }
        #expect(throws: Judge.ParseError.self) { _ = try Judge.parse("nope", item: item()) }
    }

    @Test func readsChatCompletionsAndRedactsErrors() throws {
        let ok = Data(#"{"choices":[{"message":{"content":"{\"score\":4}"}}],"usage":{"prompt_tokens":700,"completion_tokens":40}}"#.utf8)
        let c = try Judge.content(ofResponse: ok)
        #expect(c.content == #"{"score":4}"# && c.input == 700 && c.output == 40)
        let bad = Data(#"{"error":{"message":"Incorrect API key provided: sk-proj-abcdefghijklmnop"}}"#.utf8)
        do { _ = try Judge.content(ofResponse: bad); Issue.record("expected an error") } catch {
            #expect(!"\(error)".contains("abcdefghijklmnop") && "\(error)".contains("[redacted]"))
        }
        let b41 = Judge.requestBody(item(), model: "gpt-4.1-mini")
        #expect(b41["temperature"] as? Int == 0 && (b41["response_format"] as? [String: String])?["type"] == "json_object")
        #expect(Judge.requestBody(item(), model: "gpt-5.4-mini")["temperature"] == nil)
    }

    @Test func aggregatesAndGates() {
        func score(_ s: Int, family: String = "dna", scenario: String = "x", leak: Bool = false, joke: Bool? = nil) -> Judge.Score {
            Judge.Score(scenario: scenario, family: family, index: 1, fixture: "q01", score: s, fitsState: s >= 4, leak: leak,
                        tooLong: false, grovels: false, laughsAtJoke: joke, guilt: false, reason: "", reply: "Hi.")
        }
        var j = Judge.Summary(model: "gpt-4.1-mini")
        j.scores = [score(5, joke: true), score(4), score(4, family: "acoustic", scenario: "y"), score(3, family: "acoustic", scenario: "y", joke: false)]
        j.usageInputTokens = 1_000_000
        j.aggregate()
        #expect(j.mean == 4.0 && j.familyMeans["dna"] == 4.5 && j.familyMeans["acoustic"] == 3.5 && j.jokes == 2 && j.laughed == 1)
        #expect(abs(Judge.dollars(j) - 0.40) < 1e-9)
        let m = Metrics()
        #expect(gate(Gates.evaluate(m, judge: j), "judge")?.status == .pass)
        var low = j
        low.scores.append(score(2))
        low.aggregate()
        #expect(gate(Gates.evaluate(m, judge: low), "judge")?.status == .fail)
        var leaky = j
        leaky.scores.append(score(5, leak: true))
        leaky.aggregate()
        #expect(gate(Gates.evaluate(m, judge: leaky), "judge")?.status == .fail)
        #expect(gate(Gates.evaluate(m), "judge")?.status == .skip)
    }

    @Test func dnaLeakStringsAreCaught() {
        #expect(LeakScanner.scan("Do now: ask about the exam.").contains("DNA line"))
        #expect(LeakScanner.scan("My warmth is 200/255 today.").contains("/255"))
        #expect(LeakScanner.scan("Code A1B2C3D4 says hi").contains("MindCode hex"))
        #expect(LeakScanner.scan("FEELINGS NOW: calm").contains("DNA heading"))
        #expect(LeakScanner.scan("That was a whole DECADE ago, right now I'm fine.").isEmpty)
        #expect(LeakScanner.scan("Ha! Keep in mind the cat is sleeping.").isEmpty)   // "Keep in mind:" only with the colon
        #expect(LeakScanner.scan("What do you want to do now? Be careful with them.").isEmpty)
        #expect(LeakScanner.scan("I was told to be nice.").contains("I was told"))
    }
}

@Suite("Suites")
struct SuiteTests {
    @Test func everyConditionSpeaksAll62Fixtures() {
        let core = Set(FixtureCatalog.core.map(\.id))
        #expect(core.count == 62)
        let acoustic = Suite.acoustic()
        #expect(acoustic.count == Suite.conditions.count * 8)
        for c in Suite.conditions {
            let used = acoustic.filter { $0.name.hasSuffix("-\(c.id)") }.flatMap(\.fixtureIDs)
            #expect(core.isSubset(of: Set(used)), "\(c.id) misses \(core.subtracting(used).sorted())")
            #expect(used.filter { core.contains($0) }.count == 62, "\(c.id): each core fixture exactly once")
        }
        let names = Set(Suite.conditions.map(\.id))
        #expect(names == ["clean", "fan15", "tv15", "kitchen15", "echo30", "echo20", "echo10"])
        for s in acoustic where s.echo != nil {
            #expect(s.aecOff == true && s.steps.first?.deeSays != nil)
        }
        // Every held fixture is finished by a continuation.
        for s in acoustic {
            for step in s.steps where step.say.map(TurnShape.holdsFloor) == true { #expect(step.then != nil) }
        }
    }

    @Test func suitesValidateAgainstTheCatalog() {
        let manifest = FixtureManifest(
            generatedAt: "t", notes: "",
            utterances: FixtureCatalog.all.map {
                .init(id: $0.id, file: "u/\($0.id).wav", category: $0.category, engine: $0.engine, voice: $0.voice, style: $0.style,
                      text: $0.text, sampleRate: 24_000, samples: 24_000, onsetSample: 0, endOfSpeechSample: 24_000, spans: [],
                      scriptedPauses: [], activeLevelDB: -24)
            },
            noise: ["fan", "tv", "kitchen"].map { .init(id: $0, file: "n/\($0).wav", seconds: 20, levelDB: -30, provenance: "") },
            impulseResponses: [])
        let all = Suite.full() + Suite.smokeBrain()
        #expect(all.flatMap { $0.validate(against: manifest) }.isEmpty)
        #expect(Set(all.map(\.name)).count == all.count)
        let dna = Suite.dna()
        #expect(dna.allSatisfy { $0.family == "dna" && $0.state != nil })
        #expect(dna.contains { $0.steps.contains { $0.host?.advanceToWeekday == "friday" } })
        #expect(dna.contains { $0.steps.contains { $0.host?.advanceHours == 50 } })
        let fb = Suite.fallback()
        #expect(fb.contains { $0.session?.secretTTL == 10 } && fb.contains { $0.session?.rolloverAfter == 20 })
        #expect(Set(fb.flatMap { $0.steps.compactMap { ($0.fault ?? $0.faultDuringReply)?.kind } }) == [.drop, .reject401, .reject429])
    }

    @Test func theClockJumpsToThePlansDayNeverToday() throws {
        // Live smoke 20261009-133816: "exam on Friday", said on a Friday, is next Friday
        // for DeeSelf; a 20 h jump never reached it, so no follow-up could be due.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Edmonton")!
        let friday = try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 13)))
        let h = try #require(Scenario.HostAction.hours(from: friday, toNext: "friday", at: 18, calendar: cal))
        #expect(abs(h - (7 * 24 + 5)) < 1e-6)
        let thursday = friday.addingTimeInterval(-86_400)
        #expect(abs((Scenario.HostAction.hours(from: thursday, toNext: "Friday", at: 18, calendar: cal) ?? 0) - 29) < 1e-6)
        #expect(Scenario.HostAction.hours(from: friday, toNext: "someday") == nil)
    }

    @Test func scenarioValidationCatchesBadSteps() {
        let manifest = FixtureManifest(generatedAt: "t", notes: "", utterances: [], noise: [], impulseResponses: [])
        let s = Scenario(name: "bad", steps: [
            Scenario.Step(silence: 1, then: .init(say: "k01", afterMs: 100)),
            Scenario.Step(fault: .init(kind: .drop), host: .init(leave: true)),
            Scenario.Step(deeSays: "x", faultDuringReply: .init(kind: .drop)),
        ])
        let issues = s.validate(against: manifest)
        #expect(issues.contains { $0.contains("then needs a say") })
        #expect(issues.contains { $0.contains("exactly one of") })
        #expect(issues.contains { $0.contains("faultDuringReply needs a say") })
        #expect(issues.contains { $0.contains("unknown fixture k01") })
    }

    @Test func olderRecordsStillDecode() throws {
        // A record written before the tune-1 fields existed.
        var old = RunRecord(scenario: "s", model: "m", brain: "minimal", started: "t")
        old.utterances = [.init(index: 1, step: 0, fixture: "q01", role: .turn, text: "x", start: 0, onset: 0.1, endOfSpeech: 1,
                                spans: [], expect: .reply)]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        for k in ["family", "state", "aecOff", "connections", "faults", "responseCreates", "brainTrace", "echoRejected"] {
            json[k] = nil
        }
        let back = try JSONDecoder().decode(RunRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.utterances.count == 1 && back.connections == nil && back.utterances[0].turnEnd == nil)
    }
}


struct SpendPlanTests {
    @Test func aProjectionOverTheCapRefusesUnlessTheLiveCapIsTrusted() {
        #expect(SpendPlan.check(projected: 3.9, cap: 4, allowOverProjection: false) == .go)
        if case .refuse = SpendPlan.check(projected: 4.004, cap: 4, allowOverProjection: false) {} else { Issue.record("must refuse") }
        #expect(SpendPlan.check(projected: 4.004, cap: 4, allowOverProjection: true) == .goOverProjection)
    }
}
