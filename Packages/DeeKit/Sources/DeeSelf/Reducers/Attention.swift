import DeeCore
import Foundation

/// Sub-reducer 3 — shared attention (SELF.md §7.3).
///
/// Owns: `momentary.focus`, `focusSince`, `referents`, `pendingGlance`, mutual gaze,
/// head pose, `touchPoint`.
/// Requests: gaze to a live touch point (`.touch`), to a sound side or a back-camera
/// referent focus (`.focus`); the `greeting` signature reaction on arrival.
/// Reads: sight, head, touch, sound, heard, presence.
///
/// Status (0.5.1): basic. Head pose and mutual gaze; speech and touch take focus at
/// once; an unexpected sound takes it while nobody is talking; referents are bumped by
/// sight (novel +0.5, repeat +0.15), capped at 12 (LRU) with a 20 s salience half-life;
/// arrival asks for a `greeting` signature reaction.
///
/// TODO(0.5.4, owner: Attention):
/// - focus competition with hysteresis (challenger must win by 0.15 and the incumbent
///   be ≥ 1.5 s old; speech and touch preempt) — property: ≤ 1 change per 1.5 s;
/// - mention / held-up / looked-down bumps, `sharedWithUser`, pointing (+0.2 only);
/// - look requests → `.glanceNow`, the 1.2 s glance wait (`pendingGlance`);
/// - deixis (resolved / ambiguous / unknown notes, uncertainty, squint) and
///   correction demotion ("no, the other one" → misread `.wrongReferent`);
/// - triadic gaze after the user acts on a referent.
public struct Attention: SubReducer {
    public static let name = "Attention"

    public static let maxReferents = 12
    public static let referentHalfLife: TimeInterval = 20
    public static let mutualYaw = 15.0
    public static let mutualPitch = -10.0
    public static let touchGazeHold: TimeInterval = 1.0
    public static let soundFocusHold: TimeInterval = 3

    var lastDecay: Date?

    public init() {}

    public mutating func reduce(_ p: Percept, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        let now = m.now
        decay(&m, now: now)
        switch p {
        case .head(let yaw, let pitch):
            m.momentary.headYaw = yaw
            m.momentary.headPitch = pitch
            if abs(yaw) < Self.mutualYaw && pitch > Self.mutualPitch {
                if m.momentary.mutualGazeSince == nil { m.momentary.mutualGazeSince = now }
            } else {
                m.momentary.mutualGazeSince = nil
            }
        case .faceLost:
            m.momentary.headYaw = nil
            m.momentary.headPitch = nil
            m.momentary.mutualGazeSince = nil
            if case .person = m.momentary.focus { setFocus(.none, &m) }
        case .presence(let arrived):
            if arrived {
                setFocus(.person(m.ongoing.person), &m)
                m.momentary.requestReaction(.greeting, by: Self.name)
            } else {
                m.momentary.mutualGazeSince = nil
                setFocus(.none, &m)
            }
        case .partial, .heard:
            if case .person(m.ongoing.person) = m.momentary.focus {} else { setFocus(.person(m.ongoing.person), &m) }
        case .touch(_, _, let at):
            if let at {
                m.momentary.touchPoint = Timed(at, until: now.addingTimeInterval(Self.touchGazeHold))
                setFocus(.touch(at), &m)
            }
        case .sound(let label, let unexpected):
            if unexpected, !m.momentary.floor.isUserTurn, m.momentary.touchPoint?.live(at: now) == nil, let s = Subject(label) {
                setFocus(.sound(s), &m)
            }
        case .sight(let camera, let things, let novel):
            for t in things { bump(t, camera: camera, by: novel.contains(t) ? 0.5 : 0.15, &m) }
            for t in novel where !things.contains(t) { bump(t, camera: camera, by: 0.5, &m) }
        case .tick:
            if case .sound = m.momentary.focus, now.timeIntervalSince(m.momentary.focusSince) > Self.soundFocusHold {
                setFocus(.none, &m)
            }
            if case .touch = m.momentary.focus, m.momentary.touchPoint?.live(at: now) == nil {
                setFocus(.none, &m)
            }
        default:
            break
        }
        requestGaze(&m, now: now)
        return []
    }

    /// §5 gaze: touch point (1); a focus with a direction (6).
    func requestGaze(_ m: inout Moment, now: Date) {
        if let p = m.momentary.touchPoint?.live(at: now) {
            m.momentary.requestGaze(.point(p), hold: 0.5, priority: .touch, by: Self.name)
        }
        switch m.momentary.focus {
        case .sound(let s): m.momentary.requestGaze(.side(Stance.soundSide(s)), hold: 1.2, priority: .focus, by: Self.name)
        case .referent(_, .back): m.momentary.requestGaze(.examineBack, hold: 1.2, priority: .focus, by: Self.name)
        default: break
        }
    }

    func setFocus(_ f: Focus, _ m: inout Moment) {
        m.momentary.focus = f
        m.momentary.focusSince = m.now
    }

    func bump(_ label: String, camera: CameraSide, by amount: Double, _ m: inout Moment) {
        guard let s = Subject(label) else { return }
        let source: Referent.Source = camera == .front ? .sawFront : .sawBack
        if let i = m.momentary.referents.firstIndex(where: { $0.subject == s }) {
            var r = m.momentary.referents.remove(at: i)
            r.salience = clamp01(r.salience + amount)
            r.sources.insert(source)
            r.camera = camera
            r.lastSeen = m.now
            m.momentary.referents.append(r)
        } else {
            m.momentary.referents.append(Referent(subject: s, camera: camera, sources: [source], salience: clamp01(amount), lastSeen: m.now))
        }
        if m.momentary.referents.count > Self.maxReferents {
            m.momentary.referents.removeFirst(m.momentary.referents.count - Self.maxReferents)
        }
    }

    mutating func decay(_ m: inout Moment, now: Date) {
        defer { lastDecay = now }
        guard let last = lastDecay, now > last else { return }
        let k = halfLife(now.timeIntervalSince(last), Self.referentHalfLife)
        for i in m.momentary.referents.indices { m.momentary.referents[i].salience *= k }
        m.momentary.referents.removeAll { $0.salience < 0.02 }
    }

    public static func slice(of m: Moment) -> [String: String] {
        [
            "focus": m.momentary.focus.name,
            "referents": m.momentary.referents.map { "\($0.subject.text):\(String(format: "%.2f", $0.salience))" }.joined(separator: ","),
            "mutualGaze": m.momentary.mutualGazeSince == nil ? "no" : "yes",
        ]
    }
}
