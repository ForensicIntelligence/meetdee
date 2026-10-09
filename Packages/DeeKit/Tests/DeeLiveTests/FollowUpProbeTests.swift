import DeeCore
import DeeMind
import DeeSelf
import Foundation
import Testing

/// Model-free probe of the live pipeline's follow-up path.
@Test func zzFollowUpProbe() async throws {
    let t0 = Date(timeIntervalSince1970: 1_791_000_000)
    let mind = try Mind(databaseURL: nil, now: t0)
    let john = UUID()
    var now = t0
    let snap0 = await mind.snapshot(at: now)
    var cx = Cortex(enduring: SelfSeeder.seed(personality: snap0.code.personality, seed: 7, at: now), mind: snap0, at: now, carried: Carried(), session: 1)
    func step(_ p: Percept) async -> [Effect] { cx.step(p, mind: await mind.snapshot(at: now), at: now) }
    _ = await step(.conversationStarted(now)); _ = await step(.presence(arrived: true)); _ = await step(.identified(john, distance: 0))
    for line in ["Hi Dee! I'm John.", "I have a big job interview tomorrow afternoon and I'm pretty nervous about it."] {
        now += 5
        let (a, _) = await mind.hear(line, prosody: nil, at: now)
        let fx = await step(.heard(text: line, durationS: 2, loudnessVsBaseline: 0, appraisal: a))
        print("PROBE heard fx:", fx.map(\.traceName), "expectations:", cx.moment.ongoing.expectations.map { "\($0.subject.text) due \($0.due) \($0.status)" })
        _ = await step(.promptSubmitted); print("PROBE cue:", cx.cueText(at: now))
        _ = await step(.deeTurnFinished(text: "Good luck!"))
    }
    now += 1.6 * 86_400
    _ = await step(.conversationStarted(now)); _ = await step(.presence(arrived: true)); _ = await step(.identified(john, distance: 0))
    print("PROBE day2 expectations:", cx.moment.ongoing.expectations.map { "\($0.subject.text) due \($0.due) \($0.status)" }, "intentions:", cx.moment.ongoing.intentions.map { "\($0.kind) \($0.subject.text) \($0.status) notBefore \($0.notBefore)" })
    now += 5
    let (a, _) = await mind.hear("Hey Dee, I'm back.", prosody: nil, at: now)
    _ = await step(.heard(text: "Hey Dee, I'm back.", durationS: 1, loudnessVsBaseline: 0, appraisal: a))
    _ = await step(.promptSubmitted)
    print("PROBE day2 cue:", cx.cueText(at: now), "candidates:", cx.moment.ongoing.noteCandidates.map { "\($0)" })
}
