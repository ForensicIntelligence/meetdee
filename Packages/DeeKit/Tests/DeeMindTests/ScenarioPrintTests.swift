import DeeCore
import Foundation
import Testing
@testable import DeeMind

/// Prints a relationship arc for eyeballing the dynamics (always passes).
@Test func printRelationshipArc() async throws {
    let mind = try Mind(databaseURL: nil, now: Date(timeIntervalSince1970: 0))
    var t = Date(timeIntervalSince1970: 0)
    func show(_ label: String, _ s: MindSnapshot) {
        let f = s.code.feelings
        print(String(format: "%-34@ regard %+.2f  joy %.2f anger %.2f resent %.2f sad %.2f affect %.2f trust %.2f  %@  %@", label as NSString, s.regard, f[.joy], f[.anger], f[.resentment], f[.sadness], f[.affection], f[.trust], s.emotion.rawValue, s.code.display))
    }
    show("fresh Dee", await mind.snapshot(at: t))
    let soft = Prosody(loudnessDB: -38, peakDB: -30, speechRate: 2.4)
    let normal = Prosody(loudnessDB: -32, peakDB: -24, speechRate: 2.6)
    let shout = Prosody(loudnessDB: -16, peakDB: -6, speechRate: 3.6)
    for (line, p) in [("Hi Dee! How are you today?", normal), ("You're so clever, thank you!", normal), ("I love you, little buddy", soft)] {
        t += 60; show(line, await mind.hear(line, prosody: p, at: t).snapshot)
    }
    t += 60; show("SHUT UP YOU STUPID ROBOT", await mind.hear("SHUT UP YOU STUPID ROBOT", prosody: shout, at: t).snapshot)
    t += 30; show("(30 s later)", await mind.tick(at: t, userPresent: true, asleep: false))
    t += 30; show("I'm sorry Dee, I didn't mean it", await mind.hear("I'm sorry Dee, I didn't mean it", prosody: soft, at: t).snapshot)
    t += 600; show("(10 min later)", await mind.tick(at: t, userPresent: true, asleep: false))
    t += 3600 * 3; show("(3 h alone)", await mind.tick(at: t, userPresent: false, asleep: false))
    t += 3600 * 8; show("(8 h asleep)", await mind.tick(at: t, userPresent: false, asleep: true))
    for i in 0..<6 { t += 20; _ = await mind.hear(["you're useless", "I hate you", "you're dumb", "whatever", "shut up", "useless robot"][i], prosody: shout, at: t) }
    show("after 6 hostile lines", await mind.snapshot(at: t))
    t += 3600; show("(1 h later)", await mind.tick(at: t, userPresent: true, asleep: false))
    t += 86400; show("(next day)", await mind.tick(at: t, userPresent: true, asleep: false))
    print("CUE:", await mind.snapshot(at: t).cue)
}
