import Foundation
import Testing
@testable import DeeVoice

@Suite struct UplinkMapTests {
    @Test func contiguousChunksMapOneToOne() {
        var m = UplinkMap()
        m.sent(startFrame: 48_000, frames: 480)        // pre-roll starts 2 s into capture
        m.sent(startFrame: 48_480, frames: 480)
        #expect(m.runs.count == 1)
        #expect(m.captureFrame(serverMs: 0) == 48_000)
        #expect(m.captureFrame(serverMs: 30) == 48_720)
        #expect(m.serverFrames == 960)
        #expect(m.captureEnd == 48_960)
    }

    @Test func aPauseStartsANewRun() {
        var m = UplinkMap()
        m.sent(startFrame: 0, frames: 2400)             // 100 ms
        m.sent(startFrame: 24_000, frames: 2400)        // resumed 1 s later
        #expect(m.runs.count == 2)
        #expect(m.captureFrame(serverMs: 50) == 1200)
        #expect(m.captureFrame(serverMs: 150) == Int64(25_200))
    }

    @Test func resetStartsTheServerClockAgainButKeepsThePosition() {
        var m = UplinkMap()
        m.sent(startFrame: 0, frames: 4800)
        m.reset()
        #expect(m.captureEnd == 4800)
        #expect(m.captureFrame(serverMs: 0) == nil)
        m.sent(startFrame: 4800, frames: 480)
        #expect(m.captureFrame(serverMs: 0) == 4800)
    }

    @Test func offsetsBeyondWhatWasSentClampToTheEnd() {
        var m = UplinkMap()
        m.sent(startFrame: 100, frames: 240)
        #expect(m.captureFrame(serverMs: 1000) == 340)
        #expect(m.captureFrame(serverMs: -5) == nil)
    }
}

@Suite struct SentenceClockTests {
    @Test func sentencesStartAndFinishWithPlayback() {
        var c = SentenceClock()
        #expect(c.add(itemID: "a", text: "Hi there.", endMs: 600).isEmpty)
        #expect(c.add(itemID: "a", text: "How are you?", endMs: 1500).isEmpty)
        #expect(c.itemStarted("a") == [.started(itemID: "a", index: 0, text: "Hi there.")])
        #expect(c.progress("a", playedMs: 300).isEmpty)
        #expect(c.progress("a", playedMs: 620) == [
            .started(itemID: "a", index: 1, text: "How are you?"),
            .finished(itemID: "a", index: 0, text: "Hi there.", heard: true),
        ])
        #expect(c.itemFinished("a", playedMs: 1480, cut: false) == [
            .finished(itemID: "a", index: 1, text: "How are you?", heard: true),
        ])
    }

    @Test func aCutKeepsOnlyWhatWasMostlyHeard() {
        var c = SentenceClock()
        _ = c.add(itemID: "a", text: "I went to the park.", endMs: 1000)
        _ = c.add(itemID: "a", text: "It was lovely.", endMs: 2000)
        _ = c.add(itemID: "a", text: "Then it rained.", endMs: 3000)
        #expect(c.itemStarted("a") == [.started(itemID: "a", index: 0, text: "I went to the park.")])
        #expect(c.progress("a", playedMs: 1300) == [
            .started(itemID: "a", index: 1, text: "It was lovely."),
            .finished(itemID: "a", index: 0, text: "I went to the park.", heard: true),
        ])
        // Cut before the second sentence's midpoint (1500): not heard.
        let cut = c.itemFinished("a", playedMs: 1400, cut: true)
        #expect(cut == [.finished(itemID: "a", index: 1, text: "It was lovely.", heard: false)])
        // A late sentence after the cut point never starts.
        #expect(c.add(itemID: "a", text: "Late.", endMs: 3500).isEmpty)
    }

    @Test func sentencesArrivingAfterPlaybackAreReportedAtOnce() {
        var c = SentenceClock()
        _ = c.itemStarted("a")
        #expect(c.progress("a", playedMs: 900).isEmpty)
        #expect(c.add(itemID: "a", text: "Quick one.", endMs: 700) == [
            .started(itemID: "a", index: 0, text: "Quick one."),
            .finished(itemID: "a", index: 0, text: "Quick one.", heard: true),
        ])
        _ = c.itemFinished("a", playedMs: 900, cut: false)
        #expect(c.add(itemID: "a", text: "Tail.", endMs: 950) == [
            .started(itemID: "a", index: 1, text: "Tail."),
            .finished(itemID: "a", index: 1, text: "Tail.", heard: true),
        ])
    }

    @Test func playingItemsListsOnlyThoseInProgress() {
        var c = SentenceClock()
        _ = c.add(itemID: "a", text: "One.", endMs: 300)
        #expect(c.playingItems.isEmpty)
        _ = c.itemStarted("a")
        #expect(c.playingItems == ["a"])
        _ = c.itemFinished("a", playedMs: 300, cut: false)
        #expect(c.playingItems.isEmpty)
    }
}
