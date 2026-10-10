import Foundation
import Testing
@testable import DeeRealtime

/// Tune 9 (T8-2, live 20261010-080526): a server stall never throws a late answer away.
@Suite struct Tune9Tests {

    /// t2-fillers-echo10 f01: `response.create` 19.409 → `response.created` 22.968 (3.56 s).
    /// At the old 2.5 s timeout the request was given up ("no response in time") and the late
    /// response cancelled the moment it started: the turn was lost. It is accepted now: it
    /// starts, talks, and nothing is cancelled or advised.
    @Test func liveFillersEcho10F01ALateResponseIsKept() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        await h.advance(by: 3.56)
        h.push(S.responseCreated("resp_late"), S.messageAdded("resp_late", "a1"), S.audio("resp_late", "a1", ms: 100))
        #expect(await h.log.wait { $0 == .responseStarted(responseID: "resp_late", kind: .reply) } != nil)
        await h.log.wait { $0.isAudio }
        #expect(h.log.count(\.isAudio) > 0, "her late answer plays")
        #expect(h.sentCount("response.cancel") == 0)
        #expect(!h.log.contains(.fallbackAdvised(.noResponse)))
    }

    /// t2-interrupt-clean q01: `response.created` 9.59 s after the request (the server
    /// stalled whole: a truncate ack took as long). Under the 10 s backstop it is kept too.
    @Test func liveInterruptCleanQ01ANineSecondStallIsKept() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        await h.advance(by: 9.59)
        h.push(S.responseCreated("resp_late"), S.messageAdded("resp_late", "a1"), S.audio("resp_late", "a1", ms: 100))
        #expect(await h.log.wait { $0 == .responseStarted(responseID: "resp_late", kind: .reply) } != nil)
        #expect(h.sentCount("response.cancel") == 0)
    }

    /// A request cancelled before it started (the brain's stall retry, a barge-in) closes
    /// `cancelTimeout` + `cancelUnstartedWait` later if its start never comes (as before
    /// the backstop grew), so a request queued behind it is not held 13 s.
    @Test func anUnstartedCancelClosesAsBefore() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        #expect(await h.session.cancelUnspokenResponse())
        #expect(try await h.session.requestResponse() == .queued)
        await h.advance(by: 5.5)
        #expect(await h.log.wait { $0.responseDone?.reason == "no_response" } != nil)
        #expect(await h.socket.waitForSent(type: "response.create", count: 2))
    }
}
