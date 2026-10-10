import Foundation
import Testing
@testable import HarnessCore

// Tune 6 (scope: the harness). Tune-5 live T5-7 (Reports/20261010-020243, t2-reunion-evening):
// her reply item_EXNvWzIAyYVxoPoFTvdwO was cut at 6460 ms (3 of 4 sentences heard), then the
// "+50 h, new conversation" step's resetConversation deleted it on purpose (dee_del_7, 15.933).
// The harness read the history at teardown, found it empty, and failed the truncation gate;
// the wire recorder also listed her own reply as an echo rejection.

@Suite("Tune 6 harness")
struct Tune6HarnessTests {
    var rec = WireRecorder()
    var run = RunRecord(scenario: "t2-reunion-evening", model: "m", brain: "realtime", started: "t")

    mutating func send(_ json: String, at t: Double, out: Bool) {
        _ = rec.frame(connection: 1, outgoing: out, text: json, at: t, events: true, record: &run)
    }

    /// Live frames (trace lines 186, 205, 625, 854): a reset's delete of her reply is not echo.
    @Test mutating func aResetDeletingHerReplyIsNotAnEchoRejection() {
        rec.opened(connection: 1, at: 0, record: &run)
        send(#"{"type":"response.created","response":{"id":"resp_EXNvWOvnj22Zjy1lYVyvW","metadata":{"dee_turn":"1"}}}"#, at: 4.5, out: false)
        send(#"{"type":"response.output_item.added","response_id":"resp_EXNvWOvnj22Zjy1lYVyvW","item":{"id":"item_EXNvWzIAyYVxoPoFTvdwO","type":"message","role":"assistant"}}"#, at: 4.593, out: false)
        send(#"{"type":"conversation.item.truncate","item_id":"item_EXNvWzIAyYVxoPoFTvdwO","audio_end_ms":6460,"content_index":0,"event_id":"dee_trunc_5"}"#, at: 11.409, out: true)
        send(#"{"type":"conversation.item.delete","item_id":"item_EXNvWzIAyYVxoPoFTvdwO","event_id":"dee_del_7"}"#, at: 15.933, out: true)
        #expect(run.echoRejected == nil)
        // A user item the session withdraws unanswered is still echo.
        send(#"{"type":"input_audio_buffer.speech_started","item_id":"e1","audio_start_ms":10}"#, at: 20, out: false)
        send(#"{"type":"input_audio_buffer.committed","item_id":"e1"}"#, at: 21, out: false)
        send(#"{"type":"conversation.item.delete","item_id":"e1","event_id":"dee_del_9"}"#, at: 21.1, out: true)
        #expect(run.echoRejected == ["e1"])
    }

    /// The truncation's audio_end_ms is right; the history check skips an item a reset forgot.
    @Test func aForgottenItemIsNotCheckedAgainstHistory() {
        var b = RunBuilder()
        b.run.scenario = "t2-reunion-evening"
        let item = "item_EXNvWzIAyYVxoPoFTvdwO"
        b.reply(item, started: 4.95, ended: 11.41, text: "One. Two. Three. Four.", flushed: true, playedMs: 6460)
        b.reply("a2", started: 20, ended: 21, text: "Hi.")
        b.run.truncations = [.init(itemID: item, audioEndMs: 6460, at: 11.409)]
        b.run.heardSentences = [item: ["One.", "Two.", "Three."]]
        b.run.history = [.init(role: "assistant", text: "Hi.", itemID: "a2")]   // after the reset
        var before = b
        before.run.forgottenItems = nil
        let mBefore = Metrics.compute([before.run], pricing: .mini)
        #expect(mBefore.truncations.first?.historyMatches == false)               // the tune-5 false FAIL
        b.run.forgottenItems = [item]
        let m = Metrics.compute([b.run], pricing: .mini)
        #expect(m.truncations.first?.accurate == true)
        #expect(m.truncations.first?.historyMatches == nil && m.historyChecked == 0)
        #expect(Gates.evaluate(m).first { $0.id == "truncation" }?.status == .pass)
    }

    @Test func forgottenItemsRoundTripAndOlderRecordsDecode() throws {
        var r = RunRecord(scenario: "s", model: "m", brain: "realtime", started: "t")
        r.forgottenItems = ["x"]
        let back = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(r))
        #expect(back.forgottenItems == ["x"])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
        json["forgottenItems"] = nil
        let old = try JSONDecoder().decode(RunRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.forgottenItems == nil)
    }
}
