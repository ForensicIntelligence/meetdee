import DeeCore
import Foundation

/// Sub-reducer 3 — shared attention (SELF.md §7.3, step 0.5.4).
///
/// Owns: `momentary.focus`, `focusSince`, `referents`, `pendingGlance`, `mutualGazeSince`,
/// head pose (`headYaw` / `headPitch`), `touchPoint`.
///
/// Requests:
/// - gaze 1 `touch` (live touch point), 3 `jointAttention` (the triadic user → referent →
///   user sequence after the user acts on a referent), 6 `focus` (sound side, back-camera
///   referent → `.examineBack`);
/// - the `greeting` signature reaction on arrival; a `squint` (rank `reaction`) when
///   deixis can't be resolved;
/// - uncertainty 0.6 (ambiguous deixis) / 0.8 (unknown), held ≤ 6 s or until the user's
///   next turn starts.
///
/// Notes (own gates, §7.3): `deixisResolved` (s₁ ≥ 0.5 — 0.65 after a `wrongReferent`
/// lesson — and s₁ − s₂ ≥ 0.2), `deixisAmbiguous` (two candidates ≥ 0.3), `deixisUnknown`
/// (otherwise); on a correction ("no, the other one") a `misread` note naming the wrong
/// label plus the resolved note for the next candidate.
///
/// Effects: `.glanceNow(.back)` (and `.front` while a hand is present) on a look request
/// ("look at this", "can you see", "what's this", "check this out"), once per user turn.
///
/// Signals raised (payloads are labels / subjects / ids, never user text):
/// - `"misread"`: label `"wrongReferent"`, subject = the wrongly chosen referent, id = a
///   fresh misread id, value 1. Attention already raised the misread note; consumers
///   should only record it (Interpreter `misreadThisTurn`, Learner `recentMisreads` +
///   `.persist(.misread)`, RepairKeeper awkwardness).
/// - `"deixis"`: label `"resolved"` / `"ambiguous"` / `"unknown"` / `"corrected"`,
///   subject = the chosen referent (resolved / corrected).
/// - `"heldUp"`: subject = the referent the user held up to the front camera.
/// - `"engaged"`: value 1 when engagement begins, 0 when it ends (§7.3 initiative gate:
///   mutual gaze held ≥ 1 s, or user speech within 10 s, or — when no head pose has
///   arrived for 3 s — face presence within the last 3 s). Edge-triggered.
///
/// Focus competition (§7.3): `score = base × novelty × (1 + interest)`; base speech 1.0,
/// touch 0.9, unexpected sound 0.8, user-bumped referent 0.75, novel sight 0.6, known
/// face 0.5. The incumbent keeps a +0.3 bonus (`kind == current`) and its own score
/// decays (half-life 3 s since its last evidence; a referent incumbent is re-scored from
/// its live salience). A challenger wins only by ≥ 0.15 over that and only once the
/// incumbent is ≥ 1.5 s old; speech and touch preempt at once, and so does a resolved
/// deixis (the user told her what to look at).
///
/// Approximations (no percept exists yet): "held up" uses "a new non-person front label
/// while the face was lost < 2 s ago, or while a hand is present" (face-box shrink needs
/// a percept); a hand is present for 2 s after a `.gesture`. Pointing (a `point` gesture)
/// is a weak +0.2 to referents seen in the last 2 s.
public struct Attention: SubReducer {
    public static let name = "Attention"

    // §7.3 constants.
    public static let maxReferents = 12
    public static let referentHalfLife: TimeInterval = 20
    public static let mutualYaw = 15.0
    public static let mutualPitch = -10.0
    /// Mutual gaze counts once held this long.
    public static let mutualHold: TimeInterval = 1
    public static let touchGazeHold: TimeInterval = 1.0
    public static let soundFocusHold: TimeInterval = 3

    public static let novelBump = 0.5
    public static let repeatBump = 0.15
    public static let mentionBump = 0.6
    public static let heldUpBump = 0.5
    public static let lookDownBump = 0.2
    public static let pointBump = 0.2
    /// A novel label found by a requested glance (the user directed her look).
    public static let glanceBump = 0.2
    public static let lookDownPitch = -15.0
    public static let lookDownHold: TimeInterval = 1
    public static let heldUpFaceLostWindow: TimeInterval = 2
    public static let handWindow: TimeInterval = 2

    public static let hysteresis = 0.15
    public static let incumbentBonus = 0.3
    public static let minFocusAge: TimeInterval = 1.5
    public static let focusScoreHalfLife: TimeInterval = 3
    public static let userBumpWindow: TimeInterval = 5
    /// A referent focus lapses once its salience falls below this.
    public static let referentLapse = 0.1

    public static let glanceWait: TimeInterval = 1.2
    public static let resolvedThreshold = 0.5
    public static let resolvedThresholdAfterLesson = 0.65
    public static let resolvedGap = 0.2
    public static let ambiguousFloor = 0.3
    public static let ambiguousUncertainty = 0.6
    public static let unknownUncertainty = 0.8
    public static let uncertaintyHold: TimeInterval = 6
    public static let correctionDemote = 0.3
    public static let correctionWindow: TimeInterval = 60
    /// Visual context for a bare demonstrative: a referent at least this salient.
    public static let visualContextSalience = 0.3

    /// Triadic joint attention: user 0.3 s → referent 1.2 s → user (held 1.5 s).
    public static let triadUser: TimeInterval = 0.3
    public static let triadReferent: TimeInterval = 1.2
    public static let triadReturn: TimeInterval = 1.5
    /// Gaze target for a front-camera referent (held up in front of the phone): straight ahead.
    public static let frontReferentPoint = SIMD2<Double>(0.5, 0.47)

    public static let engagementSpeechWindow: TimeInterval = 10
    public static let faceFallbackWindow: TimeInterval = 3

    /// Front labels that are never a held-up object.
    static let personLabels: Set<String> = ["person", "people", "face", "hand", "adult", "child", "baby", "man", "woman", "skin"]

    // MARK: Private state (RAM only)

    enum Kind: String, Sendable, Equatable { case speech, touch, sound, userReferent, sightReferent, face }

    struct Incumbent: Sendable, Equatable {
        var kind: Kind
        var score: Double
        var at: Date
    }

    enum DeixisOutcome: String, Sendable, Equatable { case resolved, ambiguous, unknown }

    struct Triad: Sendable, Equatable {
        var subject: Subject
        var camera: CameraSide
        var start: Date
    }

    var lastDecay: Date?
    var incumbent: Incumbent?
    /// Subject text → when the user last bumped it (mention / held up / pointed).
    var userBumped: [String: Date] = [:]
    var triad: Triad?
    var lastHeadAt: Date?
    var facePresent = false
    var faceSeenAt: Date?
    var faceLostAt: Date?
    var lookDownSince: Date?
    var lastFrontLabels: [String] = []
    var lastGestureAt: Date?
    var lastSpeechAt: Date?
    var engaged = false
    /// Last greeting signature reaction (a flapping presence must not spam it).
    var lastGreeting: Date?
    public static let greetingCooldown: TimeInterval = 10 * 60
    var glancedThisTurn = false
    /// A deixis waiting for the glance (≤ 1.2 s); `promptGone` = the cue was already built.
    var deixisPending: (at: Date, promptGone: Bool)?
    var lastResolved: (subject: Subject, at: Date)?
    var uncertaintyLevel = 0.0
    var uncertaintyUntil: Date?
    /// A "which one?" / "show me" question is outstanding until this time.
    var askedUntil: Date?
    /// Subjects Dee named since the user last spoke (common ground once they reply).
    var deeNamed: [Subject] = []

    public init() {}

    // MARK: reduce

    public mutating func reduce(_ p: Percept, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        let now = m.now
        var fx: [Effect] = []
        decay(&m, now: now)
        if m.momentary.floorEvents.contains(.userStarted) {
            glancedThisTurn = false
            clearUncertainty()
        }
        if case .person(let who) = m.momentary.focus, who != m.ongoing.person, m.ongoing.person != nil {
            m.momentary.focus = .person(m.ongoing.person)          // same target, refined identity
        }

        switch p {
        case .head(let yaw, let pitch):
            m.momentary.headYaw = yaw
            m.momentary.headPitch = pitch
            lastHeadAt = now
            markFace(now)
            if abs(yaw) < Self.mutualYaw && pitch > Self.mutualPitch {
                if m.momentary.mutualGazeSince == nil { m.momentary.mutualGazeSince = now }
            } else {
                m.momentary.mutualGazeSince = nil
            }
            if pitch < Self.lookDownPitch {
                if lookDownSince == nil { lookDownSince = now }
            } else {
                lookDownSince = nil
            }
        case .faceLost:
            m.momentary.headYaw = nil
            m.momentary.headPitch = nil
            m.momentary.mutualGazeSince = nil
            lookDownSince = nil
            if facePresent { faceLostAt = now }
            facePresent = false
            if case .person = m.momentary.focus { lapse(&m) }
        case .presence(let arrived):
            if arrived {
                markFace(now)
                consider(.person(m.ongoing.person), .face, score: 0.5, &m)
                // Once per 10 min, and not while a rupture is open (review finding 16).
                let open = m.ongoing.repair == .ruptured || m.ongoing.repair == .repairing
                if !open, lastGreeting.map({ now.timeIntervalSince($0) >= Self.greetingCooldown }) ?? true {
                    lastGreeting = now
                    m.momentary.requestReaction(.greeting, by: Self.name)
                }
            } else {
                facePresent = false
                faceLostAt = now
                m.momentary.mutualGazeSince = nil
                lookDownSince = nil
                if case .person = m.momentary.focus { lapse(&m) }
            }
        case .identified(let id, _):
            if id != nil {
                markFace(now)
                consider(.person(m.ongoing.person), .face, score: 0.5, &m)
            }
        case .partial(let text):
            lastSpeechAt = now
            consider(.person(m.ongoing.person), .speech, score: 1.0, &m)
            fx += lookRequest(Self.tokens(text), &m)
        case .heard(let text, _, _, _):
            lastSpeechAt = now
            consider(.person(m.ongoing.person), .speech, score: 1.0, &m)
            fx += heard(text, &m, &rng)
        case .touch(_, _, let at):
            if let at {
                m.momentary.touchPoint = Timed(at, until: now.addingTimeInterval(Self.touchGazeHold))
                consider(.touch(at), .touch, score: 0.9, &m)
            }
        case .sound(let label, let unexpected):
            if unexpected, !m.momentary.floor.isUserTurn, m.momentary.touchPoint?.live(at: now) == nil, let s = Subject(label) {
                consider(.sound(s), .sound, score: 0.8 * (1 + interest(s, m)), &m)
            }
        case .sight(let camera, let things, let novel):
            sight(camera: camera, things: things, novel: novel, &m)
            if let g = m.momentary.pendingGlance?.live(at: now), g == camera {
                m.momentary.pendingGlance = nil
                // What the requested glance found new is what they asked her to look at.
                for t in novel { bump(t, camera: camera, by: Self.glanceBump, source: camera == .front ? .sawFront : .sawBack, &m) }
                if deixisPending != nil { fx += finishPendingDeixis(&m) }
            }
        case .gesture(let g):
            lastGestureAt = now
            if g.lowercased().hasPrefix("point") { point(&m) }
        case .deeSaid(_, let sentence):
            for r in m.momentary.referents where r.subject.appears(in: sentence) {
                if let i = index(r.subject, m) { m.momentary.referents[i].sources.insert(.deeMentioned) }
                if !deeNamed.contains(r.subject) { deeNamed.append(r.subject) }
            }
        case .promptSubmitted:
            if deixisPending != nil { deixisPending?.promptGone = true }
        case .conversationStarted:
            clearUncertainty()                                  // the hook resets the rest
        case .tick:
            tick(&m)
        default:
            break
        }

        if let g = m.momentary.pendingGlance, g.live(at: now) == nil {
            m.momentary.pendingGlance = nil
        }
        if deixisPending != nil, m.momentary.pendingGlance == nil {
            fx += finishPendingDeixis(&m)
        }
        cap(&m)
        updateEngagement(&m)
        requestGaze(&m, now: now)
        if let until = uncertaintyUntil, now < until {
            m.momentary.requestUncertainty(uncertaintyLevel, by: Self.name)
        } else if uncertaintyUntil != nil {
            clearUncertainty()
        }
        return fx
    }

    // MARK: Percept handlers

    mutating func tick(_ m: inout Moment) {
        let now = m.now
        switch m.momentary.focus {
        case .sound:
            if now.timeIntervalSince(m.momentary.focusSince) > Self.soundFocusHold { lapse(&m) }
        case .touch:
            if m.momentary.touchPoint?.live(at: now) == nil { lapse(&m) }
        case .referent(let s, _):
            if (index(s, m).map { m.momentary.referents[$0].salience } ?? 0) < Self.referentLapse { lapse(&m) }
        default:
            break
        }
        if m.momentary.touchPoint?.live(at: now) == nil { m.momentary.touchPoint = nil }
        // Per-tick competition: the strongest referent, and a present face when unfocused.
        if let r = rankedReferents(m).first {
            consider(.referent(r.subject, r.camera ?? .back), userBumpedRecently(r.subject, now) ? .userReferent : .sightReferent,
                     score: referentScore(r, m), &m)
        }
        if facePresent, m.momentary.focus == .none {
            consider(.person(m.ongoing.person), .face, score: 0.5, &m)
        }
    }

    mutating func sight(camera: CameraSide, things: [String], novel: [String], _ m: inout Moment) {
        let now = m.now
        var all = things
        for t in novel where !things.contains(t) { all.append(t) }
        let lookingDown = lookDownSince.map { now.timeIntervalSince($0) > Self.lookDownHold } ?? false
        let faceJustLost = !facePresent && faceLostAt.map { now.timeIntervalSince($0) < Self.heldUpFaceLostWindow } == true
        let hand = handPresent(now)
        for t in all {
            bump(t, camera: camera, by: novel.contains(t) ? Self.novelBump : Self.repeatBump, source: camera == .front ? .sawFront : .sawBack, &m)
        }
        if camera == .front {
            let fresh = all.filter { !lastFrontLabels.contains($0) && !Self.personLabels.contains($0.lowercased()) }
            for t in fresh {
                if faceJustLost || hand {
                    bump(t, camera: .front, by: Self.heldUpBump, source: .heldUp, shared: true, &m)
                    if let s = Subject(t) {
                        userBumped[s.text] = now
                        startTriad(s, .front, &m)
                        m.signal("heldUp", subject: s, by: Self.name)
                    }
                } else if lookingDown {
                    bump(t, camera: .front, by: Self.lookDownBump, source: .sawFront, &m)
                }
            }
            lastFrontLabels = all
        }
        // Competition: the best of what was just seen.
        let seen = all.compactMap(Subject.init)
        if let r = rankedReferents(m).first(where: { seen.contains($0.subject) }) {
            consider(.referent(r.subject, r.camera ?? camera), userBumpedRecently(r.subject, now) ? .userReferent : .sightReferent,
                     score: referentScore(r, m), &m)
        }
    }

    mutating func point(_ m: inout Moment) {
        let now = m.now
        for i in m.momentary.referents.indices where now.timeIntervalSince(m.momentary.referents[i].lastSeen) <= Self.handWindow {
            m.momentary.referents[i].salience = clamp01(m.momentary.referents[i].salience + Self.pointBump)
        }
    }

    mutating func heard(_ text: String, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        let now = m.now
        let words = Self.tokens(text)
        var fx = lookRequest(words, &m)
        defer { glancedThisTurn = false }

        // The user replied: whatever Dee named is now common ground.
        for s in deeNamed { if let i = index(s, m) { m.momentary.referents[i].sharedWithUser = true } }
        deeNamed = []

        // Mentions (lemma match, plural-tolerant): +0.6, common ground, joint attention.
        var mentioned: [Subject] = []
        for r in m.momentary.referents where r.subject.appears(in: text) { mentioned.append(r.subject) }
        for s in mentioned {
            bump(s.text, camera: nil, by: Self.mentionBump, source: .mentioned, shared: true, &m)
            userBumped[s.text] = now
        }
        if let s = mentioned.last, let r = index(s, m).map({ m.momentary.referents[$0] }) {
            startTriad(s, r.camera ?? .back, &m)
            if let until = askedUntil, now < until {
                // The answer to "which one?" / "show me".
                setFocus(.referent(s, r.camera ?? .back), .userReferent, score: referentScore(r, m), &m)
                askedUntil = nil
                clearUncertainty()
            }
        }

        if Self.isCorrection(words), let last = lastResolved, now.timeIntervalSince(last.at) <= Self.correctionWindow {
            correct(last.subject, &m, &rng)
            return fx
        }

        // "Look what I made" (shown to the camera) is deictic without a "this": a look
        // request counts as a strong trigger while something is actually in view
        // (SELF.md §1 walk-through). Without visual context it stays a figure of speech.
        let inView = m.momentary.referents.contains { $0.salience >= Self.visualContextSalience }
        guard let trigger = Self.deixisTrigger(words) ?? (Self.isLookRequest(words) && inView ? (true, "look") : nil) else { return fx }
        let frame = Self.hasFrame(words)
        let visual = m.momentary.referents.contains { $0.salience >= Self.visualContextSalience }
            || m.momentary.pendingGlance?.live(at: now) != nil
            || userBumped.values.contains { now.timeIntervalSince($0) <= Self.userBumpWindow }
        guard frame || (trigger.strong && visual) else { return fx }

        if m.momentary.pendingGlance?.live(at: now) != nil, outcome(m) != .resolved {
            deixisPending = (now, false)                          // wait ≤ 1.2 s for the glance
        } else {
            resolve(&m, raise: true)
        }

        return fx
    }

    /// "look (at this)", "can you see", "what's this", "check this out" → glance once per turn.
    mutating func lookRequest(_ words: [String], _ m: inout Moment) -> [Effect] {
        guard !glancedThisTurn, Self.isLookRequest(words) else { return [] }
        glancedThisTurn = true
        m.momentary.pendingGlance = Timed(.back, until: m.now.addingTimeInterval(Self.glanceWait))
        var fx: [Effect] = [.glanceNow(.back)]
        if handPresent(m.now) { fx.append(.glanceNow(.front)) }
        return fx
    }

    // MARK: Deixis

    func threshold(_ m: Moment) -> Double {
        let lesson = m.enduring.lessons.contains { l in
            l.situation == .wrongReferent && l.evidence >= 1 && (l.person == nil || l.person == m.ongoing.person)
        }
        return lesson ? Self.resolvedThresholdAfterLesson : Self.resolvedThreshold
    }

    func outcome(_ m: Moment) -> DeixisOutcome {
        let r = rankedReferents(m)
        let s1 = r.first?.salience ?? 0
        let s2 = r.count > 1 ? r[1].salience : 0
        if s1 >= threshold(m) && s1 - s2 >= Self.resolvedGap { return .resolved }
        if s1 >= Self.ambiguousFloor && s2 >= Self.ambiguousFloor { return .ambiguous }
        return .unknown
    }

    mutating func resolve(_ m: inout Moment, raise: Bool) {
        let ranked = rankedReferents(m)
        switch outcome(m) {
        case .resolved:
            choose(ranked[0], &m, raise: raise)
            m.signal("deixis", subject: ranked[0].subject, label: DeixisOutcome.resolved.rawValue, by: Self.name)
        case .ambiguous:
            if raise { m.ongoing.raise(.deixisAmbiguous(ranked[0].subject, ranked[1].subject), by: Self.name) }
            setUncertainty(Self.ambiguousUncertainty, m.now)
            askedUntil = m.now.addingTimeInterval(Self.correctionWindow)
            m.signal("deixis", label: DeixisOutcome.ambiguous.rawValue, by: Self.name)
        case .unknown:
            unknown(&m, raise: raise)
        }
    }

    mutating func unknown(_ m: inout Moment, raise: Bool) {
        if raise { m.ongoing.raise(.deixisUnknown(), by: Self.name) }
        m.momentary.requestMannerism(.squint, rank: .reaction, by: Self.name)
        setUncertainty(Self.unknownUncertainty, m.now)
        askedUntil = m.now.addingTimeInterval(Self.correctionWindow)
        m.signal("deixis", label: DeixisOutcome.unknown.rawValue, by: Self.name)
    }

    /// "That" is this referent: note, focus (a user-directed preempt), common ground, triad.
    mutating func choose(_ r: Referent, _ m: inout Moment, raise: Bool) {
        let camera = r.camera ?? .back
        if raise { m.ongoing.raise(.deixisResolved(r.subject), by: Self.name) }
        if let i = index(r.subject, m) { m.momentary.referents[i].sharedWithUser = true }
        setFocus(.referent(r.subject, camera), .userReferent, score: referentScore(r, m), &m)
        startTriad(r.subject, camera, &m)
        lastResolved = (r.subject, m.now)
        askedUntil = nil
        clearUncertainty()
    }

    mutating func finishPendingDeixis(_ m: inout Moment) -> [Effect] {
        guard let pending = deixisPending else { return [] }
        deixisPending = nil
        resolve(&m, raise: !pending.promptGone)
        return []
    }

    /// "No, the other one": the chosen referent × 0.3, the next candidate is used, and it
    /// counts as a `wrongReferent` misread.
    mutating func correct(_ wrong: Subject, _ m: inout Moment, _ rng: inout Rand) {
        if let i = index(wrong, m) { m.momentary.referents[i].salience *= Self.correctionDemote }
        m.ongoing.raise(.misread(notX: wrong.text), by: Self.name)
        m.signal("misread", subject: wrong, value: 1, id: rng.uuid(), label: Lesson.Situation.wrongReferent.rawValue, by: Self.name)
        if let next = rankedReferents(m).first(where: { $0.subject != wrong }) {
            choose(next, &m, raise: true)
            m.signal("deixis", subject: next.subject, label: "corrected", by: Self.name)
        } else {
            lastResolved = nil
            unknown(&m, raise: true)
        }
    }

    mutating func setUncertainty(_ v: Double, _ now: Date) {
        uncertaintyLevel = v
        uncertaintyUntil = now.addingTimeInterval(Self.uncertaintyHold)
    }

    mutating func clearUncertainty() {
        uncertaintyLevel = 0
        uncertaintyUntil = nil
    }

    // MARK: Focus competition

    func base(_ k: Kind) -> Double {
        switch k {
        case .speech: 1.0
        case .touch: 0.9
        case .sound: 0.8
        case .userReferent: 0.75
        case .sightReferent: 0.6
        case .face: 0.5
        }
    }

    func userBumpedRecently(_ s: Subject, _ now: Date) -> Bool {
        userBumped[s.text].map { now.timeIntervalSince($0) <= Self.userBumpWindow } ?? false
    }

    /// base × novelty × (1 + interest); novelty = min(1, 2 × salience) (a novel sighting is 1).
    func referentScore(_ r: Referent, _ m: Moment) -> Double {
        let b = base(userBumpedRecently(r.subject, m.now) ? .userReferent : .sightReferent)
        return b * min(1, 2 * r.salience) * (1 + interest(r.subject, m))
    }

    func interest(_ s: Subject, _ m: Moment) -> Double {
        m.ongoing.interests.filter { $0.subject.overlaps(s) }.map(\.weight).max().map(clamp01) ?? 0
    }

    /// The incumbent's live score (without the +0.3 bonus).
    func incumbentScore(_ m: Moment) -> Double {
        switch m.momentary.focus {
        case .none, .inward: return 0
        case .referent(let s, _):
            return index(s, m).map { referentScore(m.momentary.referents[$0], m) } ?? 0
        default:
            guard let inc = incumbent else { return 0 }
            return inc.score * halfLife(m.now.timeIntervalSince(inc.at), Self.focusScoreHalfLife)
        }
    }

    static func sameTarget(_ a: Focus, _ b: Focus) -> Bool {
        switch (a, b) {
        case (.person, .person), (.touch, .touch): true
        case (.referent(let x, _), .referent(let y, _)): x == y
        case (.sound(let x), .sound(let y)): x == y
        default: false
        }
    }

    mutating func consider(_ f: Focus, _ kind: Kind, score: Double, _ m: inout Moment) {
        let now = m.now
        if Self.sameTarget(f, m.momentary.focus) {
            // Fresh evidence for the incumbent. A person id or touch point is refined in
            // place; a referent seen on the other camera moves only once the focus is
            // ≥ 1.5 s old (a change like any other, so labels on both cameras can't dither).
            if f != m.momentary.focus {
                if case .referent = f {
                    guard now.timeIntervalSince(m.momentary.focusSince) >= Self.minFocusAge else { return }
                    m.momentary.focusSince = now
                }
                m.momentary.focus = f
            }
            if case .referent = f {} else {
                let live = incumbentScore(m)
                incumbent = Incumbent(kind: score >= live ? kind : (incumbent?.kind ?? kind), score: max(live, score), at: now)
            }
            return
        }
        if kind != .speech && kind != .touch {
            if m.momentary.focusSince != .distantPast, now.timeIntervalSince(m.momentary.focusSince) < Self.minFocusAge { return }
            let bonus = m.momentary.focus == .none ? 0 : Self.incumbentBonus
            guard score > incumbentScore(m) + bonus + Self.hysteresis else { return }
        }
        setFocus(f, kind, score: score, &m)
    }

    mutating func setFocus(_ f: Focus, _ kind: Kind, score: Double, _ m: inout Moment) {
        if case .sound = f { triad = nil }
        m.momentary.focus = f
        m.momentary.focusSince = m.now
        incumbent = Incumbent(kind: kind, score: score, at: m.now)
    }

    mutating func lapse(_ m: inout Moment) {
        m.momentary.focus = .none
        m.momentary.focusSince = m.now
        incumbent = nil
    }

    // MARK: Gaze

    mutating func startTriad(_ s: Subject, _ camera: CameraSide, _ m: inout Moment) {
        if let t = triad, t.subject == s, m.now.timeIntervalSince(t.start) < Self.triadUser + Self.triadReferent { return }
        triad = Triad(subject: s, camera: camera, start: m.now)
    }

    /// §5 gaze: touch point (1); triadic joint attention (3); a focus with a direction (6).
    mutating func requestGaze(_ m: inout Moment, now: Date) {
        if let p = m.momentary.touchPoint?.live(at: now) {
            m.momentary.requestGaze(.point(p), hold: 0.5, priority: .touch, by: Self.name)
        }
        if let t = triad {
            let dt = now.timeIntervalSince(t.start)
            let busyFloor: Bool = switch m.momentary.floor {
            case .userSpeaking, .userPaused, .deeSpeaking: true
            default: false
            }
            if case .sound = m.momentary.focus {
                triad = nil
            } else if dt < Self.triadUser {
                m.momentary.requestGaze(.user, hold: Self.triadUser - dt, priority: .jointAttention, by: Self.name)
            } else if dt < Self.triadUser + Self.triadReferent {
                // Never look away from someone mid-turn (theirs or hers): the referent
                // glance waits out the floor, the return to the user does not.
                if !busyFloor {
                    let target: GazeIntent.Target = t.camera == .back ? .examineBack : .point(Self.frontReferentPoint)
                    m.momentary.requestGaze(target, hold: Self.triadUser + Self.triadReferent - dt, priority: .jointAttention, by: Self.name)
                }
            } else if dt < Self.triadUser + Self.triadReferent + Self.triadReturn {
                m.momentary.requestGaze(.user, hold: Self.triadUser + Self.triadReferent + Self.triadReturn - dt,
                                        priority: .jointAttention, by: Self.name)
            } else {
                triad = nil
            }
        }
        switch m.momentary.focus {
        case .sound(let s): m.momentary.requestGaze(.side(Stance.soundSide(s)), hold: 1.2, priority: .focus, by: Self.name)
        case .referent(_, .back): m.momentary.requestGaze(.examineBack, hold: 1.2, priority: .focus, by: Self.name)
        default: break
        }
    }

    // MARK: Engagement (initiative gate, §7.3)

    mutating func markFace(_ now: Date) {
        facePresent = true
        faceSeenAt = now
    }

    func handPresent(_ now: Date) -> Bool {
        lastGestureAt.map { now.timeIntervalSince($0) <= Self.handWindow } ?? false
    }

    mutating func updateEngagement(_ m: inout Moment) {
        let now = m.now
        if facePresent { faceSeenAt = now }
        let gaze = Self.mutualGaze(m)
        let spoke = lastSpeechAt.map { now.timeIntervalSince($0) <= Self.engagementSpeechWindow } ?? false
        let noYaw = lastHeadAt.map { now.timeIntervalSince($0) > Self.faceFallbackWindow } ?? true
        let face = noYaw && (faceSeenAt.map { now.timeIntervalSince($0) <= Self.faceFallbackWindow } ?? false)
        let e = gaze || spoke || face
        if e != engaged {
            engaged = e
            m.signal("engaged", value: e ? 1 : 0, by: Self.name)
        }
    }

    // MARK: Referents

    func index(_ s: Subject, _ m: Moment) -> Int? { m.momentary.referents.firstIndex { $0.subject == s } }

    /// Strongest first; ties → most recently seen, then by subject (deterministic).
    func rankedReferents(_ m: Moment) -> [Referent] {
        m.momentary.referents.sorted { a, b in
            if a.salience != b.salience { return a.salience > b.salience }
            if a.lastSeen != b.lastSeen { return a.lastSeen > b.lastSeen }
            return a.subject < b.subject
        }
    }

    /// Bumps (or adds) a referent and moves it to the LRU end. `camera` nil keeps the
    /// existing one (a mention is not a sighting).
    func bump(_ label: String, camera: CameraSide?, by amount: Double, source: Referent.Source, shared: Bool = false, _ m: inout Moment) {
        guard let s = Subject(label) else { return }
        if let i = index(s, m) {
            var r = m.momentary.referents.remove(at: i)
            r.salience = clamp01(r.salience + amount)
            r.sources.insert(source)
            if let camera { r.camera = camera }
            r.lastSeen = m.now
            if shared { r.sharedWithUser = true }
            m.momentary.referents.append(r)
        } else if camera != nil {
            m.momentary.referents.append(Referent(subject: s, camera: camera, sources: [source], salience: clamp01(amount),
                                                  lastSeen: m.now, sharedWithUser: shared))
        }
    }

    func cap(_ m: inout Moment) {
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

    // MARK: Hooks

    public mutating func conversationStarted(at d: Date, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        deeNamed = []
        deixisPending = nil
        lastResolved = nil
        askedUntil = nil
        glancedThisTurn = false
        clearUncertainty()
        return []
    }

    public mutating func forget(subject s: Subject, _ m: inout Moment) {
        userBumped = userBumped.filter { k, _ in Subject(k).map { !$0.overlaps(s) } ?? false }
        if triad?.subject.overlaps(s) == true { triad = nil }
        if lastResolved?.subject.overlaps(s) == true { lastResolved = nil }
        deeNamed.removeAll { $0.overlaps(s) }
        lastFrontLabels.removeAll { Subject($0)?.overlaps(s) ?? false }
        if m.momentary.focus == .none { incumbent = nil }
    }

    public mutating func forgetAll(_ m: inout Moment) {
        userBumped = [:]
        triad = nil
        lastResolved = nil
        deeNamed = []
        lastFrontLabels = []
        deixisPending = nil
        askedUntil = nil
        clearUncertainty()
    }

    // MARK: Public helpers (other reducers read these from `Moment`)

    /// §7.3 mutual gaze: |yaw| < 15° and pitch > −10° held for 1 s.
    public static func mutualGaze(_ m: Moment) -> Bool {
        m.momentary.mutualGazeSince.map { m.now.timeIntervalSince($0) >= mutualHold } ?? false
    }

    /// Common ground: the user mentioned it, held it up, pointed "that" at it, or replied
    /// after Dee named it.
    public static func isShared(_ s: Subject, in m: Moment) -> Bool {
        m.momentary.referents.first { $0.subject == s }?.sharedWithUser ?? false
    }

    /// §7.3 common-ground wording for a note slot: "that guitar" once shared, "a guitar"
    /// (news: "you just noticed a guitar") otherwise.
    public static func phrase(_ s: Subject, in m: Moment) -> String {
        if isShared(s, in: m) { return "that " + s.text }
        let vowel = s.text.first.map { "aeiou".contains($0) } ?? false
        return (vowel ? "an " : "a ") + s.text
    }

    // MARK: Lexical cues (RAM only; the text is never stored)

    /// Lower-cased words; "that's" / "what's" / "it's" split into the word + "is".
    static func tokens(_ text: String) -> [String] {
        let raw = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
        var out: [String] = []
        for w in raw {
            if w.hasSuffix("'s"), ["that", "this", "it", "what", "there", "here", "who"].contains(String(w.dropLast(2))) {
                out.append(String(w.dropLast(2)))
                out.append("is")
            } else {
                out.append(w.trimmingCharacters(in: CharacterSet(charactersIn: "'")))
            }
        }
        return out.filter { !$0.isEmpty }
    }

    static let demonstratives: Set<String> = ["this", "that", "these", "those"]
    /// Words that may follow a demonstrative without making it a determiner ("this is",
    /// "that one", "those over there"): anything else is taken as the noun it determines.
    static let nonNounFollowers: Set<String> = [
        "one", "ones", "is", "was", "are", "were", "here", "there", "over", "right", "please", "now", "again", "too",
        "then", "and", "or", "but", "so", "looks", "look", "does", "do", "did", "can", "could", "would", "will",
        "called", "mean", "means", "for", "to", "in", "on", "at", "with", "of", "thing", "might", "should", "must",
    ]
    /// A preceding word that makes "that" a conjunction / relative ("I think that…").
    static let conjunctionLead: Set<String> = ["think", "know", "said", "say", "so", "such", "hope", "guess", "believe", "sure",
                                               "glad", "now", "thought", "knew", "says", "mean", "feel", "felt"]

    /// A deictic reference with no noun: `this|that|it|that one|this one|these|those|over there`.
    /// `strong` excludes bare "that" / "it" (usually discourse), which need a look frame.
    static func deixisTrigger(_ w: [String]) -> (strong: Bool, word: String)? {
        var found: (strong: Bool, word: String)?
        for (i, x) in w.enumerated() {
            let next = i + 1 < w.count ? w[i + 1] : nil
            let prev = i > 0 ? w[i - 1] : nil
            if x == "over", next == "there" { return (true, "over there") }
            if demonstratives.contains(x) {
                if x == "that", let prev, conjunctionLead.contains(prev) { continue }
                if next == "one" || next == "ones" { return (true, "\(x) one") }
                guard next == nil || nonNounFollowers.contains(next!) else { continue }
                let strong = x != "that"
                if found == nil || (strong && found?.strong == false) { found = (strong, x) }
            } else if x == "it", found == nil {
                found = (false, "it")
            }
        }
        return found
    }

    /// "look (at this)", "can you see", "what's this/that", "check this out", "see this".
    static func isLookRequest(_ w: [String]) -> Bool {
        let objects: Set<String> = ["this", "that", "it", "these", "those", "here"]
        for (i, x) in w.enumerated() {
            let next = i + 1 < w.count ? w[i + 1] : nil
            let next2 = i + 2 < w.count ? w[i + 2] : nil
            switch x {
            case "look", "looking":
                if next == nil || ["at", "here", "this", "what"].contains(next!) { return true }
            case "see":
                if let p = i > 0 ? w[i - 1] : nil, p == "you", i > 1, ["can", "do", "could"].contains(w[i - 2]) { return true }
                if let next, objects.contains(next) { return true }
            case "check":
                if let next, objects.contains(next) || next == "out" { return true }
            case "what":
                if next == "is" || next == "are", let next2, objects.contains(next2) { return true }
            default:
                break
            }
        }
        return false
    }

    /// A look request, "do you like this/that/it", or "what do you think (of/about)".
    static func hasFrame(_ w: [String]) -> Bool {
        if isLookRequest(w) { return true }
        let objects: Set<String> = ["this", "that", "it", "these", "those"]
        for (i, x) in w.enumerated() {
            if x == "like", i >= 2, w[i - 1] == "you", ["do", "would", "did"].contains(w[i - 2]), i + 1 < w.count, objects.contains(w[i + 1]) {
                return true
            }
            if x == "think", i >= 3, w[i - 1] == "you", w[i - 2] == "do", w[i - 3] == "what" { return true }
        }
        return false
    }

    /// "no, the other one", "not that one", "wrong one".
    static func isCorrection(_ w: [String]) -> Bool {
        for (i, x) in w.enumerated() {
            let next = i + 1 < w.count ? w[i + 1] : nil
            let next2 = i + 2 < w.count ? w[i + 2] : nil
            if x == "other", next == "one" || next == "ones" { return true }
            if x == "wrong", next == "one" { return true }
            if x == "not", next == "that" || next == "this", next2 == "one" { return true }
            if x == "no", next == "that" || next == "this", next2 == "one" { return true }
        }
        return false
    }

    // MARK: Trace slice

    /// Stable strings. `glance` (a pending glance), `notes` (Attention's note candidates)
    /// and `uncertainty` (its request this step) appear only when present, and a shared
    /// referent carries a trailing `*`, so traces without them keep their old shape.
    public static func slice(of m: Moment) -> [String: String] {
        var s = [
            "focus": m.momentary.focus.name,
            "referents": m.momentary.referents.map { "\($0.subject.text):\(String(format: "%.2f", $0.salience))\($0.sharedWithUser ? "*" : "")" }
                .joined(separator: ","),
            "mutualGaze": m.momentary.mutualGazeSince == nil ? "no" : "yes",
        ]
        if let g = m.momentary.pendingGlance { s["glance"] = g.value.rawValue }
        let notes = m.ongoing.noteCandidates.filter { $0.owner == name }
        if !notes.isEmpty { s["notes"] = notes.map { "\($0.kind.rawValue)(\($0.slots.joined(separator: "|")))" }.joined(separator: ",") }
        if let u = m.momentary.uncertaintyRequests.last(where: { $0.owner == name }) { s["uncertainty"] = String(format: "%.1f", u.value) }
        return s
    }
}
