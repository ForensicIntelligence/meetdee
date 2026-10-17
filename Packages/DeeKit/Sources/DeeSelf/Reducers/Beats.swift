import DeeCore
import Foundation

/// Sub-reducer 7 — beats: short scripted sequences of gaze / overlay / mannerism
/// (SELF.md §1 walk-through, §7.1 clipped-speaker recovery, §7.2, step 0.5.2).
///
/// Owns: `momentary.beat`, `momentary.beatStepShown`, `momentary.beatRequests` (the only
/// consumer: cleared every step).
///
/// Kinds (step tables in `steps(for:_:_:)`):
/// - `examine` — shown something: eyes drop toward the referent, a `thinking` signature
///   glance, a curious overlay. Its last step is held while Dee prepares a reply
///   (`.deeThinking`), so the LLM prefill reads as examining (≤ `maxHeld` in all);
/// - `recognize` → `brighten` — a recall hit (signal `"recallHit"`) during or just after
///   an examine: `doubleTake`, then `excited` +0.2 (also held through the prefill);
/// - `listenHesitant` — requested by Listener: soft lids (`lidSoften` at `.beat`);
/// - `sorryGoOn` — Dee interrupted the user (FloorKeeper's `.deeInterrupted`): a sheepish
///   look and a "go on" nod, plus — only on an idle floor, never over the user — one
///   canned line (`.say`) from a seeded variant table for Dee's humour style (≥ 4 per
///   style, never the same twice in a row) and the `"sorrySaid"` signal. While the floor
///   is yielding (Dee just stopped *because* they are talking) the line waits; it is said
///   if the floor goes idle within `sorryWait` with nobody talking, and dropped the moment
///   the user has the floor (RepairKeeper's cue note covers the apology then) (audit C3);
/// - `reunion` — requested, or Learner's signal `"reunion"`: a glad bounce and a greeting glance.
///
/// Who may preempt whom: a beat starts when none runs, or when its priority is higher
/// than the running beat's (`defaultPriority`, or the request's own). The same kind never
/// restarts itself. A finished beat starts the next queued one (recognize → brighten).
///
/// Starts on its own (besides `beatRequests`):
/// - `examine` when focus moves to a back-camera referent, or to any referent while a
///   `shareCreation` goal hypothesis is live (not the same subject within 30 s);
/// - `recognize`(→ `brighten`) on `"recallHit"` (brighten only if `value` ≥ 0 after an
///   examine, > 0.2 otherwise; never while `distressLive`);
/// - `sorryGoOn` on `.deeInterrupted` (at most once per 3 s).
///
/// Requests: the active step's gaze (`.beat`), its mannerism once per step (rank `.beat`),
/// and `listenHesitant`'s lid softening (`.beat`). `Stance.resolve` reads the active
/// step's overlay and boost itself (§3.5).
/// Signals raised: `"beatFinished"` (label = kind) when a beat completes (EpisodeBuilder
/// segments there).
/// Reads: floor and floor events, focus, hypotheses, signals `recallHit` / `reunion`.
public struct Beats: SubReducer {
    public static let name = "Beats"

    /// An examine (or brighten) is held through the prefill at most this long in all.
    public static let maxHeld: TimeInterval = 8
    /// Hold extension granted per step while Dee prepares a reply.
    public static let holdStep: TimeInterval = 0.5
    /// A recall hit this soon after an examine ends still counts as "recognised it".
    public static let recognizeWindow: TimeInterval = 4
    /// The same referent is not examined again within this long.
    public static let reexamineAfter: TimeInterval = 30
    /// One apology per this long (a partial and the barge-in both flag the interruption).
    public static let sorryCooldown: TimeInterval = 3
    /// A sorry line owed while yielding is said only if the floor goes idle this soon.
    public static let sorryWait: TimeInterval = FloorKeeper.yieldingTimeout + 1
    public static let hesitantLids = 0.5

    /// Who wins when beats compete (higher preempts lower).
    public static func defaultPriority(_ k: Beat.Kind) -> Double {
        switch k {
        case .sorryGoOn: 0.9
        case .reunion: 0.7
        case .recognize, .brighten: 0.6
        case .examine: 0.5
        case .listenHesitant: 0.4
        }
    }

    /// Kinds whose last step is held while Dee prepares a reply.
    static func heldThroughPrefill(_ k: Beat.Kind) -> Bool { k == .examine || k == .brighten }

    /// The running beat's priority.
    public private(set) var activePriority = 0.0
    /// Beats to start when the active one finishes.
    public private(set) var queue: [Beat.Kind] = []
    /// When the last examine finished (recognize window).
    var examineEnded: Date?
    /// Referents examined recently (subject, at).
    var examined: [(subject: Subject, at: Date)] = []
    var lastFocus: Focus = .none
    var lastSorry: Date?
    /// The sorry line is owed but waits for an idle floor (since when).
    public private(set) var sorryOwedSince: Date?
    /// The last canned line variant (no immediate repeat).
    public private(set) var lastLineVariant: Int?

    public init() {}

    public mutating func reduce(_ p: Percept, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        let now = m.now
        var effects: [Effect] = []

        switch p {
        case .conversationStarted, .asleep(true):
            m.momentary.beat = nil
            queue = []
            activePriority = 0
            sorryOwedSince = nil
        default:
            break
        }

        finishIfDone(&m, now: now, rng: &rng)
        cancelIfStale(&m)

        // Dee interrupted the user: say sorry, go on. The words only on an idle floor;
        // while they are talking — or Dee is yielding to them, which means they are —
        // the sheepish look and the "go on" nod say it without talking over them again
        // (finding 14, audit C3: speaking over them closes their turn).
        if m.momentary.floorEvents.contains(.deeInterrupted), lastSorry.map({ now.timeIntervalSince($0) >= Self.sorryCooldown }) ?? true {
            if start(.sorryGoOn, priority: Self.defaultPriority(.sorryGoOn), &m, now: now, rng: &rng) {
                lastSorry = now
                sorryOwedSince = nil
                if Self.floorFree(m.momentary.floor) {
                    sayingSorry(&m, rng: &rng, into: &effects)
                } else if case .yielding = m.momentary.floor {
                    sorryOwedSince = now
                }
            }
        } else if let owed = sorryOwedSince {
            if m.momentary.floor.isUserTurn || m.momentary.floorEvents.contains(.userStarted) || now.timeIntervalSince(owed) > Self.sorryWait {
                sorryOwedSince = nil
            } else if Self.floorFree(m.momentary.floor) {
                sorryOwedSince = nil
                sayingSorry(&m, rng: &rng, into: &effects)
            } else if case .yielding = m.momentary.floor {
                // still waiting
            } else {
                sorryOwedSince = nil   // Dee is thinking or speaking again: the moment passed
            }
        }

        // Signals from other reducers.
        for s in m.inbox(for: Self.name) {
            switch s.name {
            case "recallHit": recallHit(value: s.value, &m, now: now, rng: &rng)
            case "reunion": _ = start(.reunion, priority: Self.defaultPriority(.reunion), &m, now: now, rng: &rng)
            default: break
            }
        }

        // Requests (consumed here only): the best one may start or preempt.
        let requests = m.momentary.beatRequests
        m.momentary.beatRequests = []
        if let best = Stance.winner(requests, by: { -Int(($0.priority * 1000).rounded()) }) {
            if best.kind == .recognize {
                recallHit(value: 0, &m, now: now, rng: &rng, priority: best.priority)
            } else {
                _ = start(best.kind, priority: best.priority, &m, now: now, rng: &rng)
            }
        }

        // Shown something: examine it.
        if m.momentary.focus != lastFocus {
            lastFocus = m.momentary.focus
            if case .referent(let subject, let camera) = m.momentary.focus,
               camera == .back || shareCreationLive(m, now: now),
               !examined.contains(where: { $0.subject == subject && now.timeIntervalSince($0.at) < Self.reexamineAfter }) {
                if start(.examine, priority: Self.defaultPriority(.examine), &m, now: now, rng: &rng) {
                    examined.removeAll { now.timeIntervalSince($0.at) >= Self.reexamineAfter }
                    examined.append((subject, now))
                }
            }
        }

        holdThroughPrefill(&m, now: now)
        requestActiveStep(&m)
        return effects
    }

    public mutating func conversationStarted(at d: Date, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        queue = []
        examined = []
        examineEnded = nil
        return []
    }

    public mutating func forget(subject: Subject, _ m: inout Moment) {
        examined.removeAll { $0.subject.overlaps(subject) }
        if case .referent(let s, _) = lastFocus, s.overlaps(subject) { lastFocus = .none }
    }

    public mutating func forgetAll(_ m: inout Moment) {
        examined = []
        lastFocus = .none
    }

    // MARK: - Starting, finishing, holding

    /// Starts `kind` if nothing runs or it outranks the running beat. Returns whether it started.
    @discardableResult
    mutating func start(_ kind: Beat.Kind, priority: Double, _ m: inout Moment, now: Date, rng: inout Rand) -> Bool {
        if let active = m.momentary.beat, active.step(at: now) != nil {
            guard active.kind != kind, priority > activePriority else { return false }
            if active.kind == .examine { examineEnded = now }
        }
        m.momentary.beat = Beat(kind: kind, steps: Self.steps(for: kind, m, &rng), started: now)
        m.momentary.beatStepShown = nil
        activePriority = priority
        if kind != .recognize { queue = [] }
        return true
    }

    mutating func finishIfDone(_ m: inout Moment, now: Date, rng: inout Rand) {
        guard let b = m.momentary.beat, now.timeIntervalSince(b.started) >= b.totalDuration - 1e-6 else { return }
        m.momentary.beat = nil
        m.momentary.beatStepShown = nil
        activePriority = 0
        if b.kind == .examine { examineEnded = now }
        m.signal("beatFinished", label: b.kind.rawValue, by: Self.name)
        if !queue.isEmpty {
            let next = queue.removeFirst()
            let rest = queue
            start(next, priority: Self.defaultPriority(next), &m, now: now, rng: &rng)
            queue = rest
        }
    }

    /// A hesitant-listening beat ends when the user carries on or the turn ends.
    mutating func cancelIfStale(_ m: inout Moment) {
        guard let b = m.momentary.beat, b.kind == .listenHesitant else { return }
        if case .userPaused = m.momentary.floor { return }
        m.momentary.beat = nil
        m.momentary.beatStepShown = nil
        activePriority = 0
    }

    /// Recognised something from memory: recognize, then brighten.
    mutating func recallHit(value: Double, _ m: inout Moment, now: Date, rng: inout Rand, priority: Double? = nil) {
        let examining = m.momentary.beat?.kind == .examine
            || examineEnded.map { now.timeIntervalSince($0) <= Self.recognizeWindow } ?? false
        guard start(.recognize, priority: priority ?? Self.defaultPriority(.recognize), &m, now: now, rng: &rng) else { return }
        // No lighting up while they are upset (review finding 6).
        queue = !m.ongoing.distressLive(at: now) && (examining ? value >= 0 : value > 0.2) ? [.brighten] : []
    }

    /// Holds an examine / brighten's last step while Dee prepares a reply (the prefill).
    mutating func holdThroughPrefill(_ m: inout Moment, now: Date) {
        guard var b = m.momentary.beat, Self.heldThroughPrefill(b.kind), case .deeThinking = m.momentary.floor,
              let active = b.step(at: now), active.index == b.steps.count - 1 else { return }
        let left = b.totalDuration - now.timeIntervalSince(b.started)
        guard left < Self.holdStep + 0.1 else { return }
        let extra = min(Self.holdStep, Self.maxHeld - b.totalDuration)
        guard extra > 0 else { return }
        b.steps[b.steps.count - 1].duration += extra
        m.momentary.beat = b
    }

    /// Only an idle floor is free for a canned line: `.yielding` means the user just
    /// started talking over Dee.
    static func floorFree(_ f: Floor) -> Bool {
        if case .idle = f { true } else { false }
    }

    mutating func sayingSorry(_ m: inout Moment, rng: inout Rand, into effects: inout [Effect]) {
        effects.append(.say(sorryLine(m.enduring.humour, rng: &rng)))
        m.signal("sorrySaid", by: Self.name)
    }

    func shareCreationLive(_ m: Moment, now: Date) -> Bool {
        m.ongoing.hypotheses.contains { $0.kind == .goal && $0.value == "shareCreation" && now < $0.expires }
    }

    // MARK: - Step tables

    /// The steps of each kind. Signature glances (examine's `thinking`, reunion's
    /// `greeting`) are picked once, at the start, from Dee's seeded repertoire.
    static func steps(for kind: Beat.Kind, _ m: Moment, _ rng: inout Rand) -> [BeatStep] {
        func signature(_ slot: Signature.Slot) -> Mannerism? {
            m.enduring.signature.pick(slot, energy: m.ongoing.mind.mood.energy, playGate: m.playGate,
                                      recent: m.momentary.recentMannerisms, rng: &rng)
        }
        switch kind {
        case .examine:
            return [BeatStep(gaze: .referent, overlay: .curious, intensityBoost: 0.1, mannerism: signature(.thinking), duration: 1.2),
                    BeatStep(gaze: .referent, overlay: .curious, duration: 1.0)]
        case .recognize:
            return [BeatStep(gaze: .user, overlay: .surprised, intensityBoost: 0.15, mannerism: .doubleTake, duration: 0.8)]
        case .brighten:
            return [BeatStep(gaze: .user, overlay: .excited, intensityBoost: 0.2, duration: 1.5)]
        case .listenHesitant:
            return [BeatStep(gaze: .user, duration: 1.5)]
        case .sorryGoOn:
            return [BeatStep(gaze: .user, overlay: .shy, intensityBoost: 0.1, duration: 0.8),
                    BeatStep(gaze: .user, mannerism: .nod, duration: 0.8)]
        case .reunion:
            return [BeatStep(gaze: .user, overlay: .excited, intensityBoost: 0.2, mannerism: .bounce, duration: 1.0),
                    BeatStep(gaze: .user, overlay: .happy, intensityBoost: 0.1, mannerism: signature(.greeting), duration: 1.4)]
        }
    }

    // MARK: - Clipped-speaker apology (§7.1)

    /// ≥ 4 canned variants per humour style. Short, warm, no reproach.
    public static func sorryLines(_ style: HumourStyle) -> [String] {
        switch style {
        case .wordplay:
            ["Oops, you first.", "Sorry, my words jumped the queue. Go on.", "Sorry, I spoke too soon. Go on.", "Ah, I cut in. Go ahead."]
        case .deadpan:
            ["Sorry. Go on.", "That was me interrupting. Go ahead.", "My mistake. You first.", "I'll stop there. Go on."]
        case .absurd:
            ["Oops, my mouth ran ahead of me. Go on.", "Sorry, a sentence escaped. You first.", "Whoa, sorry. Go on.",
             "Oops, rogue sentence. Go ahead."]
        case .gentleTeasing:
            ["Oh, sorry, go on.", "Oops, you first.", "Sorry, I jumped in. Go on.", "My bad, keep going."]
        case .selfDeprecatingRobot:
            ["Sorry, my timing circuits jumped. Go on.", "Oops, I jumped in. Go on.", "Sorry, still learning when to wait. Go on.",
             "My fault. You first."]
        }
    }

    /// A seeded pick for Dee's humour style, never the same variant twice in a row.
    mutating func sorryLine(_ style: HumourStyle, rng: inout Rand) -> String {
        let lines = Self.sorryLines(style)
        var i = rng.index(lines.count)
        if let last = lastLineVariant, i == last, lines.count > 1 { i = (i + 1 + rng.index(lines.count - 1)) % lines.count }
        lastLineVariant = i
        return lines[i]
    }

    // MARK: - Requests for the active step

    /// The active step's gaze (priority 2) and, once per step, its mannerism.
    func requestActiveStep(_ m: inout Moment) {
        guard let b = m.momentary.beat, let active = b.step(at: m.now) else {
            m.momentary.beatStepShown = nil
            return
        }
        let s = active.step
        if active.index != m.momentary.beatStepShown, let man = s.mannerism {
            m.momentary.requestMannerism(man, rank: .beat, by: Self.name)
        }
        m.momentary.beatStepShown = active.index
        if b.kind == .listenHesitant {
            m.momentary.requestFace(.lidSoften, Self.hesitantLids, priority: .beat, by: Self.name)
        }
        switch s.gaze {
        case .user: m.momentary.requestGaze(.user, hold: s.duration, priority: .beat, by: Self.name)
        case .down: m.momentary.requestGaze(.examineBack, hold: s.duration, priority: .beat, by: Self.name)
        case .away: m.momentary.requestGaze(.away, hold: s.duration, priority: .beat, by: Self.name)
        case .referent:
            if case .referent(_, .back) = m.momentary.focus {
                m.momentary.requestGaze(.examineBack, hold: s.duration, priority: .beat, by: Self.name)
            } else {
                m.momentary.requestGaze(.user, hold: s.duration, priority: .beat, by: Self.name)
            }
        case .keep: break
        }
    }

    public static func slice(of m: Moment) -> [String: String] {
        let active = m.momentary.beat?.step(at: m.now)
        return [
            "beat": m.momentary.beat.map { "\($0.kind.rawValue)#\(active?.index ?? -1)" } ?? "-",
            "overlay": active?.step.overlay?.rawValue ?? "-",
            "mannerism": m.momentary.mannerismRequests.last(where: { $0.owner == name }).map { r in
                if case .mannerism(let x) = r.what { x.rawValue } else { "?" }
            } ?? "-",
            "gaze": m.momentary.gazeRequests.last(where: { $0.owner == name })?.target.name ?? "-",
            "signals": m.momentary.signals.filter { $0.owner == name && $0.seq == m.seq }
                .map { "\($0.name):\($0.label ?? "")" }.joined(separator: ","),
        ]
    }
}
