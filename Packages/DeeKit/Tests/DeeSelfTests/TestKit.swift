import DeeCore
import DeeMind
import Foundation
import Testing
@testable import DeeSelf

/// Shared builders for DeeSelf tests.
enum Kit {
    static let t0 = SimClock.epoch
    static let john = UUID(uuidString: "00000000-0000-4000-8000-00000000000A")!
    static let ann = UUID(uuidString: "00000000-0000-4000-8000-00000000000B")!

    /// A snapshot from feelings (others at 0 / defaults).
    static func snap(_ feelings: [Feeling: Double] = [:], personality: [DeeMind.Trait: Double] = [:], seq: UInt64 = 0,
                     reflex: Emotion? = nil, age: Double? = nil) -> MindSnapshot {
        var f: [Feeling: Double] = [.joy: 0.5, .interest: 0.5, .energy: 0.8, .affection: 0.4, .trust: 0.5]
        for (k, v) in feelings { f[k] = v }
        return MindSnapshot(code: MindCode(personality: Personality(personality), feelings: Feelings(f)), age: age,
                            sequence: seq, reflex: reflex)
    }

    /// Clearly positive mood with low regard (so the affection exemption is off).
    static var happyNeutralRegard: MindSnapshot { snap([.joy: 0.9, .affection: 0.35, .trust: 0.5]) }
    /// Upset: angry (negHigh band).
    static var angry: MindSnapshot { snap([.anger: 0.8, .joy: 0.1, .affection: 0.3, .trust: 0.4, .resentment: 0.4]) }
    /// Sad (negLow band), regard low.
    static var sad: MindSnapshot { snap([.sadness: 0.9, .joy: 0.05, .affection: 0.3, .trust: 0.4]) }
    /// Frustrated but fond: angry band via anger > 0.4, yet regard > 0.3.
    static var fondButCross: MindSnapshot { snap([.anger: 0.45, .joy: 0.5, .affection: 1.0, .trust: 1.0, .gratitude: 0.6]) }

    static func enduring(seed: UInt64 = 7, personality: Personality = Personality()) -> Enduring {
        SelfSeeder.seed(personality: personality, seed: seed, at: t0)
    }

    static func cortex(seed: UInt64 = 7, mind: MindSnapshot = snap(), at: Date = t0, carried: Carried = Carried()) -> Cortex {
        Cortex(enduring: enduring(seed: seed), mind: mind, at: at, carried: carried)
    }

    static func moment(mind: MindSnapshot = snap(), at: Date = t0, enduring: Enduring = enduring()) -> Moment {
        Moment(ongoing: Ongoing(mind: mind, conversationStarted: at), enduring: enduring, now: at)
    }

    static func heard(_ text: String, _ a: Appraisal = Appraisal()) -> Percept {
        .heard(text: text, durationS: 1.5, loudnessVsBaseline: 0, appraisal: a)
    }
}

/// Never includes user or reply text (traces are committed).
func describe(_ p: Percept) -> String {
    switch p {
    case .pause(let te, let h): String(format: "pause(%.2f,%.2f)", te, h)
    case .deeSaid(let tag, _): "deeSaid(\(tag?.rawValue ?? "-"))"
    case .sound(let l, let u): "sound(\(l),\(u))"
    case .sight(let c, let t, let n): "sight(\(c.rawValue),\(t.joined(separator: "+")),novel:\(n.joined(separator: "+")))"
    case .head(let y, let pi): String(format: "head(%.0f,%.0f)", y, pi)
    case .presence(let a): "presence(\(a))"
    case .identified(let id, let d): "identified(\(id.map { String($0.uuidString.suffix(4)) } ?? "nil"),\(String(format: "%.2f", d)))"
    case .touch(let k, let g, let at): "touch(\(k),\(g),\(at.map { String(format: "%.1f,%.1f", $0.x, $0.y) } ?? "-"))"
    case .gesture(let g): "gesture(\(g))"
    case .asleep(let b): "asleep(\(b))"
    default: p.name
    }
}

// MARK: - Golden traces (SELF.md §12.2)

struct TraceStep: Codable, Equatable {
    var t: Double
    var percept: String
    var effects: [String]
    var slice: [String: String]
}

struct GoldenTrace: Codable, Equatable {
    var reducer: String
    var name: String
    var steps: [TraceStep]
}

/// One timeline entry: seconds after `Kit.t0`, the percept, and optionally a new snapshot.
struct Cue { var t: Double; var p: Percept; var mind: MindSnapshot? = nil }

enum Golden {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static var updating: Bool { ProcessInfo.processInfo.environment["DEE_UPDATE_GOLDENS"] == "1" }

    /// Runs one sub-reducer alone over a timeline (floor events and per-step channels
    /// cleared each step exactly as Cortex does), recording its own slice.
    static func record<R: SubReducer>(_ reducer: R, name: String, mind: MindSnapshot = Kit.snap(),
                                      seed: UInt64 = 7, _ timeline: [Cue]) -> GoldenTrace {
        var r = reducer
        var m = Kit.moment(mind: mind)
        var rng = Rand(seed: seed)
        var steps: [TraceStep] = []
        for c in timeline {
            m.now = Kit.t0.addingTimeInterval(c.t)
            m.seq += 1
            m.momentary.beginStep(seq: m.seq)
            if let s = c.mind { m.ongoing.mind = s }
            let effects = r.reduce(c.p, &m, &rng)
            steps.append(TraceStep(t: c.t, percept: describe(c.p), effects: effects.map(\.traceName), slice: R.slice(of: m)))
        }
        return GoldenTrace(reducer: R.name, name: name, steps: steps)
    }

    /// Runs a whole Cortex, recording the slices of `reducers` (by default FloorKeeper,
    /// Attention and RepairKeeper, prefixed "floor." / "attention." / "repair.") plus
    /// the stance. A reducer's own whole-pipeline trace lists only its own slice, so
    /// another reducer's change shows up only through the stance fields.
    static func recordCortex(name: String, mind: MindSnapshot = Kit.snap(), seed: UInt64 = 7,
                             reducers: [(prefix: String, slice: @Sendable (Moment) -> [String: String])] = defaultCortexSlices,
                             _ timeline: [Cue]) -> GoldenTrace {
        var cx = Kit.cortex(seed: seed, mind: mind)
        var current = mind
        var steps: [TraceStep] = []
        for c in timeline {
            if let s = c.mind { current = s }
            let effects = cx.step(c.p, mind: current, at: Kit.t0.addingTimeInterval(c.t))
            var slice: [String: String] = [:]
            for r in reducers { for (k, v) in r.slice(cx.moment) { slice[r.prefix + "." + k] = v } }
            slice["stance.expression"] = cx.stance.expression.rawValue
            slice["stance.gaze"] = cx.stance.gaze.target.name
            slice["stance.mannerism"] = cx.stance.mannerism?.rawValue ?? "-"
            slice["stance.playGate"] = String(cx.stance.playGate)
            steps.append(TraceStep(t: c.t, percept: describe(c.p), effects: effects.map(\.traceName), slice: slice))
        }
        return GoldenTrace(reducer: "Cortex", name: name, steps: steps)
    }

    static let defaultCortexSlices: [(prefix: String, slice: @Sendable (Moment) -> [String: String])] = [
        ("floor", FloorKeeper.slice(of:)), ("attention", Attention.slice(of:)), ("repair", RepairKeeper.slice(of:)),
    ]

    /// Records an issue with the readable diff when `g` differs from its fixture.
    static func verify(_ g: GoldenTrace) throws {
        if let diff = try check(g) { Issue.record(Comment(rawValue: diff)) }
    }

    static func url(_ g: GoldenTrace) -> URL { root.appendingPathComponent(g.reducer).appendingPathComponent(g.name + ".json") }

    static func encode(_ g: GoldenTrace) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(g) + Data("\n".utf8)
    }

    /// nil when the trace matches the committed fixture; otherwise a readable diff.
    /// With DEE_UPDATE_GOLDENS=1 the fixture is (re)written instead.
    static func check(_ g: GoldenTrace) throws -> String? {
        let u = url(g)
        if updating {
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encode(g).write(to: u)
            return nil
        }
        guard let data = try? Data(contentsOf: u) else {
            return "missing golden \(g.reducer)/\(g.name).json — run with DEE_UPDATE_GOLDENS=1 and review the diff"
        }
        let want = try JSONDecoder().decode(GoldenTrace.self, from: data)
        guard want != g else { return nil }
        var lines = ["golden \(g.reducer)/\(g.name) differs (regenerate with DEE_UPDATE_GOLDENS=1 only if intended):"]
        if want.steps.count != g.steps.count { lines.append("  steps: want \(want.steps.count), got \(g.steps.count)") }
        for (i, (a, b)) in zip(want.steps, g.steps).enumerated() where a != b {
            lines.append("  step \(i) t=\(b.t) \(b.percept)")
            if a.percept != b.percept { lines.append("    percept: \(a.percept) → \(b.percept)") }
            if a.effects != b.effects { lines.append("    effects: \(a.effects) → \(b.effects)") }
            for k in Set(a.slice.keys).union(b.slice.keys).sorted() where a.slice[k] != b.slice[k] {
                lines.append("    \(k): \(a.slice[k] ?? "∅") → \(b.slice[k] ?? "∅")")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// Runs one sub-reducer alone, exactly as Cortex steps it (seq, per-step channels).
/// Every `<Name>Tests.swift` uses this instead of a private harness.
struct ReducerRun<R: SubReducer> {
    var r: R
    var m: Moment
    var rng: Rand

    init(_ r: R, mind: MindSnapshot = Kit.snap(), seed: UInt64 = 1) {
        self.r = r
        m = Kit.moment(mind: mind)
        rng = Rand(seed: seed)
    }

    /// One step at `t` seconds after `Kit.t0`. `events` stand in for FloorKeeper's
    /// floor events of this step; `mind` replaces the snapshot.
    @discardableResult
    mutating func step(_ p: Percept, at t: Double, events: [FloorEvent] = [], mind: MindSnapshot? = nil) -> [Effect] {
        m.now = Kit.t0.addingTimeInterval(t)
        m.seq += 1
        m.momentary.beginStep(seq: m.seq)
        m.momentary.floorEvents = events
        if let mind { m.ongoing.mind = mind }
        var fx = r.reduce(p, &m, &rng)
        if case .conversationStarted(let d) = p { fx += r.conversationStarted(at: d, &m, &rng) }
        return fx
    }

    /// Simulates NotePicker issuing `n` (Cortex calls every reducer's `noteIssued`).
    @discardableResult
    mutating func issue(_ n: Note) -> [Effect] { r.noteIssued(n, &m) }
}
