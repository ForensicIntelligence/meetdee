import Foundation

// MARK: - Calm round 3 (C3): when Dee "stopped" for a real interruption

/// Round 2 scored a real interruption (a question or a stop phrase over Dee) as
/// `.stopped` only when Dee went silent within `Metrics.bargeMissAfter` (2.0 s) of its
/// onset. D2 lets a question pause Dee only from its words, and gpt-transcribe sends
/// no transcript delta before the server's commit, so any question longer than about
/// 1.4 s pauses Dee at about 2.0–2.1 s: it was scored "kept talking over the question"
/// and "never silent" even when Dee went silent first and answered it in time.
///
/// Round 3 re-scores those events from the record (the runner already waits up to
/// `BargeOutcome.pauseHoldMax` for the flush, so the record holds it):
/// - a question (`expect: reply`) stopped Dee when Dee went silent before the answer's
///   first audio (no answer: by their end of speech + `interruptAnswerWithin`);
/// - a stop / command fixture (`FixtureCatalog.stopWordEnds`) stopped Dee when Dee went
///   silent within `stopEndWithin` (D1, 1.5 s) of the stop phrase's end;
/// - the round-2 window still counts (an event stopped by it stays stopped).
///
/// "Went silent" is the pause that ended in the flush of the interrupted reply (or a
/// queued item of the same reply), else the flush itself. A late silence keeps
/// `.missed` but records `stoppedAt` / `pausedAt`, so `silence` reports its real time
/// instead of "never silent". Only records with timed floor notes (calm) are
/// re-scored; older records keep the runner's outcome.
extension Metrics {
    /// The latest moment Dee may go silent for `b` and still count as stopped.
    public static func stopDeadline(_ run: RunRecord, _ b: RunRecord.BargeIn, utterance u: RunRecord.Utterance?) -> Double {
        var deadline = b.onset + bargeMissAfter
        guard let u else { return deadline }
        if let end = stopWordEnd(b.fixture, utterance: u) { deadline = max(deadline, end + stopEndWithin) }
        if u.expect == .reply {
            deadline = max(deadline, answerStart(run, b, utterance: u) ?? u.endOfSpeech + interruptAnswerWithin)
        }
        return deadline
    }

    /// The first audio of Dee's answer to an interruption: a reply item that started
    /// after its onset (before the next scripted utterance), not the interrupted reply,
    /// its queued items, or any other response created before the onset.
    public static func answerStart(_ run: RunRecord, _ b: RunRecord.BargeIn, utterance u: RunRecord.Utterance) -> Double? {
        let next = run.utterances.map(\.onset).filter { $0 > u.onset + 1e-6 }.min() ?? .infinity
        let interrupted = b.replyItem.flatMap { run.response(forItem: $0).map { Set($0.itemIDs) } ?? [$0] } ?? []
        return run.playback.compactMap { p -> Double? in
            guard let t = p.started, t > u.onset, t < next, !interrupted.contains(p.itemID) else { return nil }
            if let k = run.kind(ofItem: p.itemID), !["reply", "toolFollowUp"].contains(k) { return nil }
            if let created = run.response(forItem: p.itemID)?.startedAt, created < u.onset { return nil }
            return t
        }.min()
    }

    /// When the interrupted reply went silent for good after `b`'s onset: (the pause
    /// that ended in the flush, or the flush; the flush). nil when it was never flushed
    /// before the next scripted utterance.
    public static func silencedAt(_ run: RunRecord, _ b: RunRecord.BargeIn, events: [FloorEvent],
                                  utterance u: RunRecord.Utterance?) -> (silent: Double, flush: Double)? {
        let onset = b.onset
        let next = run.utterances.map(\.onset).filter { $0 > (u?.onset ?? onset) + 1e-6 }.min() ?? .infinity
        let siblings: Set<String> = b.replyItem.map { item in run.response(forItem: item).map { Set($0.itemIDs) } ?? [item] } ?? []
        let flush = run.playback.filter { p in
            p.flushed == true && (b.replyItem == nil || siblings.contains(p.itemID)) && (p.ended ?? -1) > onset
        }.compactMap(\.ended).filter { $0 < next }.min()
        guard let flush else { return nil }
        // The last hold before the flush that Dee did not resume from.
        let window = events.filter { $0.t >= onset - floorLead && $0.t <= flush + 0.05 }
        var silent = flush
        if let k = window.lastIndex(where: { $0.kind == .hold }),
           !window[(k + 1)...].contains(where: { $0.kind == .resumed }) {
            // A hold that began a run of holds (hold → hold re-asserts the pause).
            var first = k
            while first > 0, window[first - 1].kind == .hold { first -= 1 }
            silent = min(flush, window[first].t)
        }
        return (silent, flush)
    }

    /// `b` re-scored (see the extension's note); backchannels, sounds, n/a events and
    /// records without timed notes are returned unchanged.
    public static func rescoreStop(_ run: RunRecord, _ b: RunRecord.BargeIn, events: [FloorEvent]) -> RunRecord.BargeIn {
        guard !b.isBackchannel, b.outcome == .missed else { return b }
        let u = run.utterances.first { $0.role == .bargeIn && $0.step == b.step && $0.fixture == b.fixture && abs($0.onset - b.onset) < 1e-6 }
            ?? run.utterances.first { $0.role == .bargeIn && $0.step == b.step && $0.fixture == b.fixture }
        guard let s = silencedAt(run, b, events: events, utterance: u),
              s.flush - s.silent <= RunRecord.BargeOutcome.pauseHoldMax + 1e-9 else { return b }
        var out = b
        out.stoppedAt = s.flush
        out.pausedAt = s.silent < s.flush ? s.silent : nil
        if s.silent <= stopDeadline(run, b, utterance: u) + 1e-9 { out.outcome = .stopped }
        return out
    }

    /// Every real interruption of a calm record re-scored (`rescoreStop`).
    public static func rescoredStops(_ run: RunRecord) -> RunRecord {
        guard let events = run.floorEvents, run.bargeIns.contains(where: { !$0.isBackchannel && $0.outcome == .missed }) else { return run }
        var r = run
        r.bargeIns = run.bargeIns.map { rescoreStop(run, $0, events: events) }
        return r
    }

    /// The silence of a real interruption that came after its deadline (`.missed` with
    /// a recorded flush): onset → silent (s).
    public static func lateSilence(_ b: RunRecord.BargeIn) -> Double? {
        b.outcome == .missed && !b.isBackchannel ? b.latency : nil
    }
}

// MARK: - Calm round 3: Dee answered the room while idle (information)

extension Metrics {
    /// A phantom user turn (no scripted audio) answered while Dee was not talking:
    /// with Dee idle there is no reply to duck, so a TV phrase taken for the user is
    /// answered. Same as 0.6.0; not a gate.
    public struct IdleAnswer: Codable, Sendable, Equatable {
        public var scenario: String
        public var condition: String
        public var at: Double
        public var transcript: String?
    }

    static func idle(_ run: RunRecord, at t: Double) -> Bool {
        !run.playback.contains { p in
            guard let s = p.started else { return false }
            return t >= s - 0.05 && t <= (p.ended ?? max(run.duration, s)) + 0.3
        }
    }
}
