import Foundation
import Testing
@testable import DeeVoice

// Tune 11 regression review (scratchpad/tune11-review.md): the tune-11 one-word rule
// (`EarCore.echoExplains`) judged a real "Stop." over her un-cancelled voice as her echo
// and deleted it, whatever its word — at 89d0c0f the words decided ("stop" is a word a
// person says alone: the user's) and she stopped. Offline sweep through the harness's own
// mixing in the full loop (−10 dB, 80 ms, room IR, c01 at fixture level): her voices l03
// 3.0 s in and l02 4.2 s in, "Stop." was left to its words ("words decide"), measured
// "explained" and was deleted ("words of …: her echo"). Her echo model never deletes a stop.
@Suite(.serialized) struct OneWordStopIsNeverDeletedAsEchoTests {
    @Test(arguments: [("l03", 3.0), ("l02", 4.2)])
    func aRealStopHerEchoModelExplainsStillStopsHer(her: String, at: Double) async throws {
        let room = try EchoTenRoom()
        let replyStart = try await room.startReply(her: her, seconds: 8)
        let u = try room.say("c01", atSample: replyStart + Int(at * LoopRig.rate))
        let onset = u.onset - Int(0.1 * LoopRig.rate), end = u.end + Int(0.1 * LoopRig.rate)
        try await room.serverItem("item_s", onset: onset, end: end, words: ["Stop", "."], text: "Stop.")
        #expect(!room.deleted.contains("item_s"), "a real \"Stop.\" was deleted as her echo: \(room.notes.suffix(10))")
        #expect(!room.rig.voice.isMisheardFragment(itemID: "item_s", text: "Stop."))
        room.rig.voice.shutdown()
    }
}
