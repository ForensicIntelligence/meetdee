import DeeCore
import DeeMind
import Foundation

/// Sub-reducer 2 — coordinated listening (SELF.md §7.2, step 0.5.2).
///
/// Owns: `momentary.preview`, `momentary.lastBackchannel` (and, privately, backchannel
/// timing, the hesitation response and the silence classification).
///
/// Requests:
/// - backchannel mannerisms (`nod` / `contentSquint` / `giggle`) with rank `.backchannel`;
///   the distress "soft blink" has no `Performance`, so it is a short `lidSoften` pulse;
/// - face modifiers at `.userTurn`: `readyFace` (pause with turnEnd ≥ 0.6), `lidSoften`
///   (hesitant pause, soft blinks), `tilt` (3.5 s into a hesitant silence; a pending
///   question after 6 s);
/// - gaze `.user` at `.userTurn` while a pending question waits (6 s … 14 s);
/// - the `listenHesitant` beat (`requestBeat`, priority `hesitantBeatPriority`).
///
/// Notes: the hesitation note `(They hesitated; be gentle and patient.)`, raised on the
/// `.heard` that ends a turn with a hesitant pause (hesitation ≥ 0.6), once per turn.
///
/// Signals raised (payloads are numbers, labels and ids only):
/// - `"silence"` — label `pendingQuestion` / `comfortable` / `awkward` / `letGo` / `plain`
///   when the class of the silence after Dee's turn changes; for `comfortable` the value
///   is the curiosity-gap multiplier `1 + silenceComfort` (IntentionBoard, idle director
///   at half rate in the app);
/// - `"awkwardSilence"` — value 0.15, once per silence (RepairKeeper: awkwardness += value);
/// - `"questionLetGo"` — at 14 s of an unanswered question; `id` = the intention of the
///   aim issued for that reply, if any (IntentionBoard: mark it `.dropped`, never re-ask);
/// - `"silenceComfort"` — value ±0.05 (Learner, the profile owner: apply to the person's
///   `silenceComfort`, clamped 0…1, persisted with its throttled profile write).
///
/// Reads: `.partial`, `.pause`, `.heard`, `.deeSaid`, `.head`, `.sound`, presence, the
/// floor and its events (FloorKeeper), the person's `SocialProfile` (`backchannelRate`,
/// `silenceComfort`), extraversion, regard, distress hypotheses.
public struct Listener: SubReducer {
    public static let name = "Listener"

    // MARK: Preview (§7.2)
    /// Partials are appraised at most this often (2 Hz).
    public static let previewInterval: TimeInterval = 0.5
    /// The preview never shows more than a partial reaction.
    public static let maxPreviewIntensity = 0.5
    /// A change of sign must persist this long before the face follows it.
    public static let signFlipHold: TimeInterval = 0.6
    /// |valence| below this has no sign (no flip logic).
    public static let signDeadBand = 0.05

    // MARK: Backchannels
    /// The user must have held the floor this long before a nod.
    public static let minSpoken: TimeInterval = 1.5
    /// The pause window for a backchannel.
    public static let pauseWindow: ClosedRange<TimeInterval> = 0.2 ... 0.6
    /// `.pause` arrives after ≥ 150 ms of silence; with the face's onset the nod lands
    /// at ≥ 200 ms, so the pause counts from 0.2 s at the percept.
    public static let pauseAtPercept: TimeInterval = 0.2
    /// No backchannel when the predictor thinks the turn is over.
    public static let maxTurnEndForBackchannel = 0.5
    /// Minimum gap: `3 s / (0.5 + extraversion)`, divided by `backchannelRate`.
    public static let backchannelBase: TimeInterval = 3
    public static let maxPerMinute = 15
    /// `contentSquint` instead of a nod above this preview valence.
    public static let squintValence = 0.3
    /// Laughter heard this recently turns the backchannel into a giggle.
    public static let laughterWindow: TimeInterval = 1
    /// A soft blink: a short, deep lid softening.
    public static let softBlinkDuration: TimeInterval = 0.35
    public static let softBlinkDepth = 0.9
    public static let distressCue = 0.3
    public static let laughterLabels: Set<String> = ["laughter", "baby_laughter", "giggling", "giggle", "snicker",
                                                      "belly_laugh", "chuckle_chortle", "chuckle", "laugh"]

    // MARK: Hesitation and the ready face
    public static let hesitationThreshold = 0.6
    /// No nods this long after a hesitant pause starts.
    public static let hesitationNoNod: TimeInterval = 1
    /// Soft blink and tilt this long into a hesitant silence.
    public static let hesitantSilence: TimeInterval = 3.5
    public static let hesitantLids = 0.5
    public static let hesitantTilt = 0.3
    public static let hesitantBeatPriority = 0.4
    /// The ready face starts at this turn-end probability (§7.1).
    public static let readyTurnEnd = 0.6

    // MARK: Silence model (after Dee's turn)
    public static let questionLookBack: TimeInterval = 6
    public static let questionLetGo: TimeInterval = 14
    public static let questionTilt = 0.25
    public static let comfortableRegard = 0.1
    public static let comfortableHesitation = 0.3
    public static let awkwardYaw = 30.0
    public static let awkwardLookWindow: TimeInterval = 2
    public static let awkwardNoReply: TimeInterval = 4
    public static let awkwardIncrement = 0.15
    /// `silenceComfort` learning: a silence this long before the user picks a new topic.
    public static let comfortLearnSilence: TimeInterval = 10
    public static let comfortStep = 0.05

    public enum SilenceClass: String, Sendable, Equatable, CaseIterable {
        case none, plain, pendingQuestion, comfortable, awkward, letGo
    }

    /// The candidate preview of the opposite sign, waiting out the 0.6 s hold.
    struct PendingFlip: Sendable, Equatable {
        var valence: Double
        var since: Date
    }

    /// A fresh appraiser for previews (`evaluate` is pure: it commits nothing).
    let appraiser = Appraiser()

    // Preview.
    public private(set) var lastPreviewAt: Date?
    /// The last previewed partial and its appraisal (RAM only, never stored or signalled).
    var lastPreviewText: (text: String, appraisal: Appraisal)?
    var pendingFlip: PendingFlip?
    /// Distress of the newest partial (soft-blink backchannel).
    public private(set) var previewDistress = 0.0

    // Turn and backchannels.
    /// When the user's current turn started.
    public private(set) var turnStarted: Date?
    /// Backchannel times of the last minute (rate limit).
    public private(set) var recentBackchannels: [Date] = []
    /// The pause (its `since`) that already got a backchannel.
    var backchanneledPause: Date?
    var softBlinkUntil: Date?
    var lastLaughter: Date?

    // Hesitation.
    /// No nods before this time.
    public private(set) var noNodUntil: Date?
    /// The hesitant pause in progress (its `since`).
    var hesitantPause: Date?
    var hesitantBlinked = false
    public private(set) var hesitantThisTurn = false
    /// The latest hesitation estimate (comfortable silence needs < 0.3).
    public private(set) var lastHesitation = 0.0

    // Silence after Dee's turn.
    public private(set) var silenceStart: Date?
    public private(set) var silenceClass: SilenceClass = .none
    var lastSentenceQuestion = false
    var pendingQuestion = false
    var lookedAwayAt: Date?
    var awkwardRaised = false
    /// The aim issued for the reply that is waiting for an answer.
    public private(set) var issuedAim: UUID?
    /// Length of the silence before the user's current turn (comfort learning).
    var silenceBeforeTurn: TimeInterval?
    var userPresent = true

    public init() {}

    public mutating func reduce(_ p: Percept, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        // The partial's text is held only while the user's turn lasts.
        if case .heard = p { lastPreviewText = nil }
        let now = m.now
        let events = m.momentary.floorEvents

        // The user took the floor: a turn starts, any silence after Dee's line ends.
        if events.contains(.userStarted) {
            resetTurn()
            turnStarted = m.momentary.floor.since ?? now
            silenceBeforeTurn = silenceStart.map { now.timeIntervalSince($0) }
            endSilence(&m)
            lastHesitation = 0
        }

        switch p {
        case .partial(let text):
            userPresent = true
            preview(text, &m, now: now)
        case .pause(_, let hesitation):
            lastHesitation = hesitation
        case .heard(let text, _, _, _):
            userPresent = true
            if hesitantThisTurn { m.ongoing.raise(.hesitation(), by: Self.name) }
            learnComfort(text, &m)
        case .deeSaid(_, let sentence):
            lastSentenceQuestion = Self.isQuestion(sentence)
        case .deeTurnFinished(let text):
            if !text.isEmpty { lastSentenceQuestion = Self.isQuestion(text) }
        case .head(let yaw, _):
            userPresent = true
            if let s = silenceStart, abs(yaw) > Self.awkwardYaw, now.timeIntervalSince(s) <= Self.awkwardLookWindow, lookedAwayAt == nil {
                lookedAwayAt = now
            }
        case .sound(let label, _):
            if Self.laughterLabels.contains(label.lowercased()) { lastLaughter = now }
        case .presence(let arrived):
            userPresent = arrived
        case .identified:
            userPresent = true
        case .promptSubmitted:
            issuedAim = nil
            endSilence(&m)
        case .conversationStarted, .asleep(true):
            resetTurn()
            endSilence(&m)
            issuedAim = nil
            lastSentenceQuestion = false
        default:
            break
        }

        if events.contains(.deeSentence) { endSilence(&m) }
        if events.contains(.deeFinished), !events.contains(.cutOff) { startSilence(&m, now: now) }

        if m.momentary.floor.isUserTurn {
            if turnStarted == nil { turnStarted = m.momentary.floor.since ?? now }
            listen(&m, now: now)
        } else {
            m.momentary.preview = nil
            pendingFlip = nil
            if events.contains(.userFinished) { resetTurn() }
            if case .idle = m.momentary.floor { tickSilence(&m, now: now) }
        }
        if let until = softBlinkUntil, now < until {
            m.momentary.requestFace(.lidSoften, Self.softBlinkDepth, priority: .userTurn, by: Self.name)
        }
        return []
    }

    public mutating func conversationStarted(at d: Date, _ m: inout Moment, _ rng: inout Rand) -> [Effect] {
        resetTurn()
        silenceStart = nil
        silenceClass = .none
        silenceBeforeTurn = nil
        issuedAim = nil
        recentBackchannels = []
        return []
    }

    public mutating func noteIssued(_ n: Note, _ m: inout Moment) -> [Effect] {
        if n.role == .aim, let id = n.intention { issuedAim = id }
        return []
    }

    public mutating func forgetAll(_ m: inout Moment) {
        issuedAim = nil
        lastPreviewText = nil
    }

    // MARK: - The user's turn

    /// Preview appraisal of a partial on a copy of the appraiser (≤ 2 Hz), intensity ≤ 0.5,
    /// sign flips held 0.6 s. The real commit happens at `.heard`.
    mutating func preview(_ text: String, _ m: inout Moment, now: Date) {
        guard m.momentary.floor.isUserTurn else { return }
        if let last = lastPreviewAt, now.timeIntervalSince(last) < Self.previewInterval - 1e-6 { return }
        lastPreviewAt = now
        // Lexicon only and pure (`evaluate` records nothing): the full sentiment model
        // costs ~0.2 s and the preview runs at 2 Hz. The committed appraisal (Mind.hear)
        // uses it.
        // STT often re-sends the same partial while the user pauses: reuse its appraisal.
        let a: Appraisal
        if let last = lastPreviewText, last.text == text {
            a = last.appraisal
        } else {
            a = appraiser.evaluate(text, prosody: nil, sentiment: false).appraisal
            lastPreviewText = (text, a)
        }
        previewDistress = a.distress
        // Without the sentiment model the lexicons hear only social words (praise,
        // insults…); a small tone lexicon lets everyday "lovely" / "awful" move the face.
        let v = clamp(a.valence + Self.previewTone(text), -1, 1)
        guard let current = m.momentary.preview else {
            m.momentary.preview = Self.make(v, since: now)
            pendingFlip = nil
            return
        }
        let old = Self.sign(current.valence), new = Self.sign(v)
        if old != 0, new != 0, old != new {
            // A flip: hold the old face until the new sign has lasted 0.6 s.
            if let f = pendingFlip, Self.sign(f.valence) == new {
                pendingFlip = PendingFlip(valence: v, since: f.since)
            } else {
                pendingFlip = PendingFlip(valence: v, since: now)
            }
            commitFlipIfHeld(&m, now: now)
        } else {
            pendingFlip = nil
            var next = Self.make(v, since: current.signSince)
            if old == 0, new != 0 { next.signSince = now }
            m.momentary.preview = next
        }
    }

    mutating func commitFlipIfHeld(_ m: inout Moment, now: Date) {
        guard let f = pendingFlip, now.timeIntervalSince(f.since) >= Self.signFlipHold - 1e-6 else { return }
        m.momentary.preview = Self.make(f.valence, since: now)
        pendingFlip = nil
    }

    /// Everything that runs on every step of the user's turn.
    mutating func listen(_ m: inout Moment, now: Date) {
        commitFlipIfHeld(&m, now: now)
        guard case .userPaused(let since, let turnEnd, let hesitation) = m.momentary.floor else {
            // Speaking: a hesitant pause (if any) is over.
            hesitantPause = nil
            hesitantBlinked = false
            return
        }
        // Hesitation response.
        if hesitation >= Self.hesitationThreshold {
            if hesitantPause != since {
                hesitantPause = since
                hesitantBlinked = false
                hesitantThisTurn = true
                noNodUntil = now.addingTimeInterval(Self.hesitationNoNod)
                m.momentary.requestBeat(.listenHesitant, priority: Self.hesitantBeatPriority, at: now, by: Self.name)
            }
            m.momentary.requestFace(.lidSoften, Self.hesitantLids, priority: .userTurn, by: Self.name)
            if now.timeIntervalSince(since) >= Self.hesitantSilence {
                if !hesitantBlinked {
                    hesitantBlinked = true
                    softBlinkUntil = now.addingTimeInterval(Self.softBlinkDuration)
                }
                m.momentary.requestFace(.tilt, Self.hesitantTilt, priority: .userTurn, by: Self.name)
            }
        } else if turnEnd >= Self.readyTurnEnd {
            // The ready face: eyes lift and widen slightly when they're clearly done.
            let ready = 0.4 + 0.6 * clamp01((turnEnd - Self.readyTurnEnd) / (1 - Self.readyTurnEnd))
            m.momentary.requestFace(.readyFace, ready, priority: .userTurn, by: Self.name)
        }
        backchannel(&m, now: now, since: since, turnEnd: turnEnd, hesitation: hesitation)
    }

    /// A visual backchannel at a mid-turn pause (§7.2), at most once per pause.
    mutating func backchannel(_ m: inout Moment, now: Date, since: Date, turnEnd: Double, hesitation: Double) {
        recentBackchannels.removeAll { now.timeIntervalSince($0) >= 60 }
        let pause = Self.pauseAtPercept + now.timeIntervalSince(since)
        let profile = m.profile
        guard backchanneledPause != since,
              turnEnd < Self.maxTurnEndForBackchannel,
              hesitation < Self.hesitationThreshold,
              Self.pauseWindow.contains(pause),
              since.timeIntervalSince(turnStarted ?? since) >= Self.minSpoken - 1e-6,
              profile.backchannelRate > 0,
              noNodUntil.map({ now >= $0 }) ?? true,
              recentBackchannels.count < Self.maxPerMinute,
              now.timeIntervalSince(m.momentary.lastBackchannel) >= Self.minGap(m) - 1e-6
        else { return }
        backchanneledPause = since
        m.momentary.lastBackchannel = now
        recentBackchannels.append(now)
        let distress = previewDistress >= Self.distressCue || m.ongoing.distressLive(at: now)
        if distress {
            softBlinkUntil = now.addingTimeInterval(Self.softBlinkDuration)
        } else if let l = lastLaughter, now.timeIntervalSince(l) <= Self.laughterWindow {
            m.momentary.requestMannerism(.giggle, rank: .backchannel, by: Self.name)
        } else if (m.momentary.preview?.valence ?? 0) > Self.squintValence {
            m.momentary.requestMannerism(.contentSquint, rank: .backchannel, by: Self.name)
        } else {
            m.momentary.requestMannerism(.nod, rank: .backchannel, by: Self.name)
        }
    }

    /// `3 s / (0.5 + extraversion)`, scaled by the person's `backchannelRate`.
    static func minGap(_ m: Moment) -> TimeInterval {
        let extraversion = m.ongoing.effectivePersonality[.extraversion]
        let rate = max(0.05, m.profile.backchannelRate)
        return backchannelBase / (0.5 + clamp01(extraversion)) / rate
    }

    mutating func resetTurn() {
        turnStarted = nil
        pendingFlip = nil
        lastPreviewAt = nil
        previewDistress = 0
        backchanneledPause = nil
        hesitantPause = nil
        hesitantBlinked = false
        hesitantThisTurn = false
        noNodUntil = nil
        softBlinkUntil = nil
    }

    // MARK: - Silence after Dee's turn

    mutating func startSilence(_ m: inout Moment, now: Date) {
        silenceStart = now
        pendingQuestion = lastSentenceQuestion
        lastSentenceQuestion = false
        awkwardRaised = false
        lookedAwayAt = nil
        if let yaw = m.momentary.headYaw, abs(yaw) > Self.awkwardYaw { lookedAwayAt = now }
        // Classified by `tickSilence` in this same step (the floor is idle).
    }

    mutating func endSilence(_ m: inout Moment) {
        silenceStart = nil
        pendingQuestion = false
        lookedAwayAt = nil
        awkwardRaised = false
        silenceClass = .none
    }

    /// Classifies the silence on every idle step (pending question, comfortable, awkward).
    mutating func tickSilence(_ m: inout Moment, now: Date) {
        guard let start = silenceStart else { return }
        let t = now.timeIntervalSince(start)
        if pendingQuestion {
            if t >= Self.questionLetGo {
                pendingQuestion = false
                m.signal("questionLetGo", id: issuedAim, by: Self.name)
                issuedAim = nil
                setClass(.letGo, &m)
                return   // reclassified from the next step
            } else if t >= Self.questionLookBack {
                m.momentary.requestGaze(.user, hold: 1, priority: .userTurn, by: Self.name)
                m.momentary.requestFace(.tilt, Self.questionTilt, priority: .userTurn, by: Self.name)
            }
        }
        if !awkwardRaised, lookedAwayAt != nil, t >= Self.awkwardNoReply {
            awkwardRaised = true
            m.signal("awkwardSilence", value: Self.awkwardIncrement, by: Self.name)
        }
        let cls: SilenceClass
        if awkwardRaised { cls = .awkward }
        else if pendingQuestion { cls = .pendingQuestion }
        else if userPresent, m.ongoing.mind.regard > Self.comfortableRegard, lastHesitation < Self.comfortableHesitation {
            cls = .comfortable
        } else if silenceClass == .letGo { cls = .letGo }
        else { cls = .plain }
        setClass(cls, &m)
    }

    mutating func setClass(_ c: SilenceClass, _ m: inout Moment) {
        guard c != silenceClass else { return }
        silenceClass = c
        let value = c == .comfortable ? 1 + clamp01(m.profile.silenceComfort) : 0
        m.signal("silence", value: value, label: c.rawValue, by: Self.name)
    }

    /// `silenceComfort` learning (§7.2): +0.05 when the user picks up after a silence
    /// > 10 s, −0.05 when they check whether she's still there ("hello?").
    mutating func learnComfort(_ text: String, _ m: inout Moment) {
        defer { silenceBeforeTurn = nil }
        if Self.isCheckingIn(text) {
            m.signal("silenceComfort", value: -Self.comfortStep, by: Self.name)
        } else if let s = silenceBeforeTurn, s > Self.comfortLearnSilence {
            m.signal("silenceComfort", value: Self.comfortStep, by: Self.name)
        }
    }

    // MARK: - Helpers

    static func make(_ v: Double, since: Date) -> ListenPreview {
        ListenPreview(valence: v, intensity: min(maxPreviewIntensity, abs(v)), signSince: since)
    }

    /// Everyday tone words for the preview only (RAM; the committed appraisal is Mind's).
    /// The sum of hits, each ±0.35, negated after
    /// "not" / "n't" right before it, capped at ±0.6.
    static let positiveTone: Set<String> = [
        "lovely", "love", "loved", "great", "amazing", "awesome", "wonderful", "fantastic", "nice", "good", "fun",
        "happy", "glad", "excited", "beautiful", "brilliant", "perfect", "best", "cool", "delicious", "proud", "yay",
    ]
    static let negativeTone: Set<String> = [
        "awful", "terrible", "horrible", "bad", "sad", "worst", "hate", "hated", "upset", "angry", "scared", "afraid",
        "worried", "nervous", "tired", "sick", "hurt", "lonely", "miserable", "ugh", "annoying", "annoyed", "stressed",
    ]

    static func previewTone(_ text: String) -> Double {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        var total = 0.0
        for (i, w) in words.enumerated() {
            let hit = positiveTone.contains(w) ? 0.35 : negativeTone.contains(w) ? -0.35 : 0
            guard hit != 0 else { continue }
            let negated = i > 0 && (words[i - 1] == "not" || words[i - 1].hasSuffix("n't") || words[i - 1] == "never")
            total += negated ? -hit : hit
        }
        return clamp(total, -0.6, 0.6)
    }

    static func sign(_ v: Double) -> Int { v > signDeadBand ? 1 : v < -signDeadBand ? -1 : 0 }

    /// Her line ended in a question mark (RAM-only check; the text is never kept).
    static func isQuestion(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'”’)")))
        return t.hasSuffix("?")
    }

    /// "hello?", "are you there?", "still there?" … (RAM-only check).
    static func isCheckingIn(_ s: String) -> Bool {
        let t = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let words = t.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        guard !words.isEmpty, words.count <= 5 else { return false }
        let phrase = words.joined(separator: " ")
        if ["are you there", "you there", "still there", "are you still there", "you still there", "anybody there",
            "anyone there", "dee are you there", "hey are you there"].contains(phrase) { return true }
        if words.count <= 2, let first = words.first,
           first.hasPrefix("hello") || first.hasPrefix("helloo") || first == "hellooo" || first == "yoohoo" {
            return s.contains("?") || first.count > 5 || words.count == 2
        }
        return false
    }

    public static func slice(of m: Moment) -> [String: String] {
        let mine = m.momentary.faceRequests.filter { $0.owner == name }
        func face(_ f: FaceField) -> String {
            mine.last(where: { $0.field == f }).map { String(format: "%.2f", $0.value) } ?? "-"
        }
        let signals = m.momentary.signals.filter { $0.owner == name && $0.seq == m.seq }
            .map { s in s.label.map { "\(s.name):\($0)" } ?? (s.value != 0 ? "\(s.name):\(String(format: "%.2f", s.value))" : s.name) }
        let gaze = m.momentary.gazeRequests.last(where: { $0.owner == name })?.target.name ?? "-"
        let beat = m.momentary.beatRequests.last(where: { $0.owner == name && $0.at == m.now })?.kind.rawValue ?? "-"
        return [
            "preview": m.momentary.preview.map { String(format: "%.2f/%.2f", $0.valence, $0.intensity) } ?? "-",
            "backchannel": m.momentary.backchannel?.rawValue ?? "-",
            "readyFace": face(.readyFace),
            "lidSoften": face(.lidSoften),
            "tilt": face(.tilt),
            "gaze": gaze,
            "beat": beat,
            "signals": signals.joined(separator: ","),
            "notes": m.ongoing.noteCandidates.filter { $0.owner == name }.map(\.kind.rawValue).joined(separator: ","),
        ]
    }
}
