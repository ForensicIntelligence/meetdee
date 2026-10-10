import Foundation
import Testing
@testable import DeeRealtime

/// Tune 10 (T9-4, live 20261010-102105 fillers-echo10 f04): a stall cancel settles before
/// the next request.
@Suite struct Tune10Tests {
    /// 63.844 `response.create` (turn 7) stalled; cancelled unstarted at 65.02 (they went on);
    /// at 70.52 the watchdog closed it ("no_response") and the queued turn 8 went out. The
    /// server was still holding turn 7: it started at 73.40 and turn 8 was refused
    /// (`conversation_already_has_active_response`, 74.43); the late answer was then cancelled
    /// as an orphan — both answers lost. The server takes events in order: a cancel of
    /// whatever is active goes out before the next request, so the stalled one is settled
    /// first and the next request runs.
    @Test func liveFillersEcho10F04TheStalledRequestIsCancelledBeforeTheNext() async throws {
        let h = try await Harness.connected()
        try await h.session.requestResponse()
        #expect(await h.session.cancelUnspokenResponse())
        #expect(try await h.session.requestResponse() == .queued)
        await h.advance(by: 5.5)
        #expect(await h.log.wait { $0.responseDone?.reason == "no_response" } != nil)
        #expect(await h.socket.waitForSent(type: "response.create", count: 2))
        let order = h.socket.sent.compactMap { text -> String? in
            guard let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let type = o["type"] as? String, type == "response.cancel" || type == "response.create" else { return nil }
            return type == "response.cancel" ? (o["response_id"] == nil ? "cancel(any)" : "cancel(id)") : "create"
        }
        #expect(order == ["create", "cancel(any)", "create"], "\(order)")
        // Nothing was active by then: the server's refusal of that cancel is no error.
        h.push(S.error(code: "response_cancel_not_active", eventID: nil))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!h.log.contains { if case .error = $0 { true } else { false } })
    }
}
