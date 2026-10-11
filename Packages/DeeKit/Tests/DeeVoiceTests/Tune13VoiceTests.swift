import AVFAudio
import DeeCore
import DeeRealtime
import Foundation
import Testing
@testable import DeeVoice

/// Tune 13 (scratchpad/tune12-live.md T12-6; Traces/20261010-214811/t2-interrupt-echo20.jsonl
/// 22.5–28.0): her echo came back as "Yeah." (22.56) and she went on from it; the real question
/// "Are you awake?" began inside `resumeGrace` (24.09), so its words decided. Her reply ("…about
/// six or more hours a day if you can… Strawberries are a bit easier…") held "are" and "you",
/// so only "awake" was foreign: deleted as her echo (25.65), never answered. A question, or a
/// short item, is her echo only as a phrase of hers.
@Suite(.serialized) struct Tune13VoiceTests {
    static let reply = "Tomatoes and basil love steady sun, about six or more hours a day if you can, and they'll get joyful and lush. Strawberries are a bit easier, but they still like sun; they're a little more flexible."

    @Test func herWordsWantAPhraseOfHersNotABagOfWords() {
        var her = HerWords()
        her.add(Self.reply, at: 0)
        // Live T12-6: her words, not in her order.
        #expect(!her.isHerEcho("Are you awake?", at: 1))
        #expect(!her.isHerEcho("Are you awake", at: 1, asks: true), "a rising sound asks too")
        #expect(!her.isHerEcho("You are sun?", at: 1))
        // Her own phrase, asked or not, is her echo; a garbled word in a short echo of hers too.
        #expect(her.isHerEcho("If you can?", at: 1))
        #expect(her.isHerEcho("Steady sun.", at: 1))
        #expect(her.isHerEcho("If you scan.", at: 1))
        #expect(!her.isHerEcho("Sun steady.", at: 1), "short: in her order only")
        // A longer item keeps the word count (her echo comes back garbled).
        #expect(her.isHerEcho("Strawberries are a bit easier but they still like moon.", at: 1))
    }

    @Test func liveEcho20Q02AQuestionInTheResumeGraceIsNotHerEcho() async throws {
        let rig = try LoopRig()
        try await rig.start()
        try rig.quiet(0.3)
        try await rig.answerWith([("item_a1", 6000)], text: Self.reply)
        try rig.quiet(0.6)
        try rig.talk(0.15)
        rig.push(Srv.speechStarted("item_y", ms: rig.uplinkMsNow - 150))
        await rig.settle()
        try rig.talk(0.35)
        try #require(rig.voice.floorHold?.itemID == "item_y", "she was not paused")
        try rig.quiet(0.1)
        rig.push(Srv.speechStopped("item_y", ms: rig.uplinkMsNow - 100), Srv.committed("item_y"))
        try rig.quiet(0.1)
        rig.deltas("item_y", ["Yeah", "."])
        rig.push(Srv.userTranscript("item_y", "Yeah."))
        let resumed = try await rig.stepUntil(1.0) { rig.voice.floorHold == nil }
        try #require(resumed != nil, "never went on")
        // "Are you awake?" inside the grace: no words until its full transcript (live).
        try rig.quiet(0.3)
        try rig.talk(0.15)
        rig.push(Srv.speechStarted("item_q", ms: rig.uplinkMsNow - 150))
        await rig.settle()
        try rig.talk(0.9)
        try rig.quiet(0.12)
        rig.push(Srv.speechStopped("item_q", ms: rig.uplinkMsNow - 120), Srv.committed("item_q"))
        try rig.quiet(0.3)
        rig.push(Srv.userTranscript("item_q", "Are you awake?"))
        try rig.quiet(0.3)
        await rig.settle()
        let deleted = rig.sent("conversation.item.delete").compactMap { $0["item_id"] as? String }
        #expect(!deleted.contains("item_q"), "the question was deleted as her echo")
        rig.voice.shutdown()
    }
}
