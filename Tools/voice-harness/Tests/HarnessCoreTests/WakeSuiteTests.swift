import Foundation
import Testing
@testable import HarnessCore

// 0.6 wake suite, pure parts (scope: the harness): the plan, the gates, the always-open
// assertion and the live measurements read from a run record.

private func gate(_ gates: [Gate], _ id: String) -> Gate? { gates.first { $0.id == id } }

@Suite("0.6: wake suite plan + gates")
struct WakeSuiteTests {
    @Test func planCoversEveryPhraseConditionAndTheGatedSets() {
        let t = WakeSuite.trials()
        #expect(Set(t.map(\.phrase)) == Set(WakeSuite.phrases))
        #expect(Set(t.map(\.condition)) == ["clean", "fan15", "kitchen15", "tv15"])
        // Hey Dee: 14 alone + 4 one-breath + 2 with a pause, under 4 conditions, all gated.
        let heyDee = t.filter { $0.phrase == "Hey Dee" && $0.expect == .accept }
        #expect(heyDee.count == 20 * 4 && heyDee.allSatisfy(\.gated))
        #expect(heyDee.filter(\.oneBreath).count == 4 * 4)
        // Unaddressed speech is a gated negative for Hey Dee only; other phrases' lines are information.
        let negs = t.filter { $0.phrase == "Hey Dee" && $0.expect == .reject }
        #expect(negs.filter(\.gated).allSatisfy { $0.fixture.hasPrefix("un") })
        #expect(negs.contains { $0.fixture == "cc01" && !$0.gated })
        // "Computer" is never its own negative ("…an old computer museum").
        #expect(!WakeSuite.negatives(for: "Computer").contains("un07"))
        #expect(WakeSuite.negatives(for: "Hey Dee").contains("un07"))
        // Wake-suite fixtures stay out of the 62 acoustic ones.
        #expect(FixtureCatalog.core.count == 62)
        #expect(FixtureCatalog.core.allSatisfy { !FixtureCatalog.isWakeSuite($0) })
    }

    @Test func liveScenariosAreWakeScenariosAndTune2IsNot() {
        let live = WakeSuite.liveScenarios()
        #expect(live.allSatisfy { $0.wake != nil })
        #expect(live.map(\.name).contains("wk-tv-window") && live.map(\.name).contains("wk-onebreath-clean"))
        #expect(Suite.tune2().count == 28 && Suite.tune2().allSatisfy { $0.wake == nil })
        // Asserted before a run: the baseline only always-open, the wake subset only phrase.
        #expect(WakeMode.alwaysOpen.issues(Suite.tune2()).isEmpty)
        #expect(WakeMode.phrase.issues(live).isEmpty)
        #expect(WakeMode.alwaysOpen.issues(live).count == live.count)
        #expect(WakeMode.phrase.issues(Suite.tune2()).count == 28)
    }

    func result(_ phrase: String, _ fixture: String, _ cond: String, accept: Bool, hit: Bool, gated: Bool = true) -> WakeTrialResult {
        let t = WakeSuite.Trial(id: "\(phrase)-\(fixture)-\(cond)", phrase: phrase, fixture: fixture, condition: cond, noise: nil,
                                expect: accept ? .accept : .reject, oneBreath: fixture.hasPrefix("wq"), gated: gated)
        var r = WakeTrialResult(trial: t, hit: hit, phraseEnd: 1.5)
        if hit { r.matched = "hey dee"; r.tier = "exact"; r.fromFinal = false }
        return r
    }

    @Test func acceptGateIsNinetyFivePercentAndCustomNinetyEach() {
        var r = WakeReport(runID: "w", started: "", finished: "", engine: "test", pace: "fast")
        r.trials = (0..<19).map { result("Hey Dee", "wd\($0)", "clean", accept: true, hit: true) }
            + [result("Hey Dee", "wd99", "fan15", accept: true, hit: false)]
        #expect(gate(WakeGates.evaluate(r), "wake_accept")?.status == .pass)          // 19/20 = 95 %
        r.trials.append(result("Hey Dee", "wd98", "fan15", accept: true, hit: false))
        #expect(gate(WakeGates.evaluate(r), "wake_accept")?.status == .fail)          // 19/21
        #expect(gate(WakeGates.evaluate(r), "wake_accept")?.note?.contains("wd98@fan15") == true)
        r.trials += (0..<9).map { result("Computer", "cc\($0)", "clean", accept: true, hit: true) }
            + [result("Computer", "cc9", "tv15", accept: true, hit: false)]
        #expect(gate(WakeGates.evaluate(r), "wake_accept_custom")?.status == .pass)   // 9/10
        r.trials.append(result("Computer", "cc10", "tv15", accept: true, hit: false))
        #expect(gate(WakeGates.evaluate(r), "wake_accept_custom")?.status == .fail)
    }

    @Test func anyFalseWakeOnABedOrUnaddressedSpeechFails() {
        var r = WakeReport(runID: "w", started: "", finished: "", engine: "test", pace: "fast")
        r.trials = [result("Hey Dee", "un01", "clean", accept: false, hit: false),
                    result("Hey Dee", "cc01", "clean", accept: false, hit: true, gated: false)]
        r.exposures = [WakeExposureResult(phrase: "Hey Dee", bed: "radio", snrDb: 10, seconds: 600)]
        var g = WakeGates.evaluate(r)
        #expect(gate(g, "wake_false")?.status == .pass)
        #expect(gate(g, "wake_near_miss")?.value == "1/1 woke")                         // information only
        r.exposures[0].falseWakes = [312.4]; r.exposures[0].matched = ["heidi"]
        g = WakeGates.evaluate(r)
        #expect(gate(g, "wake_false")?.status == .fail && gate(g, "wake_false")?.value.contains("(6.00/h)") == true)
        r.exposures[0].falseWakes = []
        r.trials[0].hit = true
        #expect(gate(WakeGates.evaluate(r), "wake_false")?.status == .fail)
    }

    @Test func tvWindowMustCloseAtSixtySecondsPlusMinusTwo() {
        var r = WakeReport(runID: "w", started: "", finished: "", engine: "live", pace: "realtime")
        var l = WakeLiveResult(scenario: "wk-tv-window", mode: "openAI")
        l.tvWindowSeconds = 61.4
        r.live = [l]
        #expect(gate(WakeGates.evaluate(r), "wake_window")?.status == .pass)
        r.live[0].tvWindowSeconds = 63.0
        #expect(gate(WakeGates.evaluate(r), "wake_window")?.status == .fail)
    }

    @Test func dormantInvariantFailsOnAnyRequestSocketMintOrByteBeforeTheHit() {
        var r = WakeReport(runID: "w", started: "", finished: "", engine: "live", pace: "realtime")
        let ok = WakeInvariantResult(mode: "openAI", requestsBeforeHit: 0, socketsBeforeHit: 0, mintsBeforeHit: 0, audioBytesBeforeHit: 0,
                                     hitWithNetworkDown: true, eyesBeforeConnect: true, serverTranscriptWoke: false)
        r.invariants = [ok]
        #expect(gate(WakeGates.evaluate(r), "wake_local")?.status == .pass)
        func with(_ f: (inout WakeInvariantResult) -> Void) -> WakeInvariantResult { var b = ok; f(&b); return b }
        let bads: [WakeInvariantResult] = [with { $0.mintsBeforeHit = 1 }, with { $0.audioBytesBeforeHit = 1 },
                                           with { $0.eyesBeforeConnect = false }, with { $0.serverTranscriptWoke = true },
                                           with { $0.crossover = ["api.openai.com"] }, with { $0.hitWithNetworkDown = false }]
        for bad in bads {
            r.invariants = [ok, bad]
            #expect(gate(WakeGates.evaluate(r), "wake_local")?.status == .fail)
        }
    }

    @Test func alwaysOpenRunsThatGoDormantFailTheWakeModeGate() {
        var b = RunBuilder()
        b.run.wakeMode = "always-open"
        b.run.dormantTransitions = 0
        #expect(gate(Gates.evaluate(Metrics.compute([b.run], pricing: .mini)), "wake_mode")?.status == .pass)
        b.run.dormantTransitions = 1
        let g = gate(Gates.evaluate(Metrics.compute([b.run], pricing: .mini)), "wake_mode")
        #expect(g?.status == .fail && g?.note?.contains("dormant 1×") == true)
        // Older reports (no wake mode): no gate row at all (their gates are unchanged).
        #expect(gate(Gates.evaluate(Metrics.compute([RunBuilder().run], pricing: .mini)), "wake_mode") == nil)
    }

    @Test func liveMeasurementsAndTheInvariantAreReadFromTheRecord() {
        var b = RunBuilder()
        b.run.scenario = "wk-tv-window"
        b.utterance("wd02", 3.0, 3.6, text: "Hey Dee.", expect: .any)
        b.run.wakeEvents = [.init(t: 4.9, text: "perkUp"), .init(t: 5.6, text: "eyesWake"), .init(t: 5.6, text: "connect resume=true"),
                            .init(t: 66.1, text: "eyesListeningOff")]
        b.run.transport = [.init(t: 5.62, kind: "http", host: "api.openai.com", path: "/v1/realtime/client_secrets"),
                           .init(t: 5.9, kind: "webSocket", host: "api.openai.com", path: "/v1/realtime")]
        b.reply("a1", started: 7.0, ended: 8.0)
        let m = Metrics.compute([b.run], pricing: .mini)
        let live = WakeLive.result(b.run, metrics: m, mode: "openAI")
        let w = live.wakes.first
        #expect(w?.eyesAt == 5.6 && w?.candidateAt == 4.9 && w?.connectAt == 5.9 && w?.firstAudioAt == 7.0)
        #expect(abs((live.tvWindowSeconds ?? 0) - 60.5) < 1e-9)
        let inv = WakeLive.invariant(b.run, mode: "openAI", allowedHosts: { $0.hasSuffix("openai.com") })
        #expect(inv.ok && inv.hostsAfterWake == ["api.openai.com"])
        // A request before the hit (a mint while dormant) and a LAN host in mode 1 both fail it.
        b.run.transport!.insert(.init(t: 1.0, kind: "http", host: "api.openai.com", path: "/v1/realtime/client_secrets"), at: 0)
        b.run.transport!.append(.init(t: 9.0, kind: "http", host: "192.168.1.20", path: "/v1/chat/completions"))
        let bad = WakeLive.invariant(b.run, mode: "openAI", allowedHosts: { $0.hasSuffix("openai.com") })
        #expect(!bad.ok && bad.mintsBeforeHit == 1 && bad.crossover == ["192.168.1.20"])
    }

    @Test func reportRoundTripsAndRendersEverySection() throws {
        var r = WakeReport(runID: "wake-1", started: "s", finished: "f", engine: "on-device", pace: "fast")
        r.trials = [result("Hey Dee", "wd01", "clean", accept: true, hit: true)]
        r.exposures = [WakeExposureResult(phrase: "Hey Dee", bed: "fan", snrDb: 15, seconds: 600)]
        r.gates = WakeGates.evaluate(r)
        let back = try WakeReport.load(r.json())
        #expect(back.trials == r.trials && back.exposures == r.exposures && back.gates == r.gates)
        let md = WakeGates.markdown(back)
        #expect(md.contains("## Accept rate by phrase and condition") && md.contains("## False-wake exposures"))
    }
}
