import Foundation

/// The §7.1 acceptance gates, evaluated on `Metrics`.
public struct Gate: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case pass = "PASS", fail = "FAIL", skip = "SKIP" }

    public var id: String
    public var metric: String
    public var target: String
    public var value: String
    public var n: Int
    public var status: Status
    public var note: String?

    public init(id: String, metric: String, target: String, value: String, n: Int, status: Status, note: String? = nil) {
        self.id = id; self.metric = metric; self.target = target; self.value = value
        self.n = n; self.status = status; self.note = note
    }
}

public enum Gates {
    public struct Thresholds: Codable, Sendable, Equatable {
        /// Tune 10: no end-to-end p50 bound. The server + model floor alone is p50
        /// 1.12–1.17 s at 300 ms VAD silence (tunes 7–9), above the old 1.1 s target;
        /// Dee's own overhead (end-to-end − floor) is gated instead.
        public var latencyP90 = 1.6
        public var overheadP50 = 0.10
        public var overheadP90 = 0.25
        public var fillerP90 = 2.0
        public var falseCutoffRate = 0.05
        public var waitEarlyRate = 0.05
        public var judgeMean = Judge.meanTarget
        public var bargeInP90 = 0.5
        public var bargeInMissRate = 0.05
        public var replyWithinThree = 0.95
        public var memory = 0.90
        /// Backchannels ("keep going", "go on", "mm-hm") she stopped on.
        public var backchannelStopRate = 0.05
        /// Dated follow-ups and reunions acknowledged.
        public var followups = 1.0
        /// Tune 5: questions asked over her that she stopped for and answered in time.
        public var interruptAnswered = 1.0
        public init() {}
    }

    static func s(_ v: Double?, _ digits: Int = 2) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "–" }
    static func pct(_ v: Double?) -> String { v.map { String(format: "%.1f%%", $0 * 100) } ?? "–" }

    public static func evaluate(_ m: Metrics, judge: Judge.Summary? = nil, thresholds t: Thresholds = Thresholds()) -> [Gate] {
        var g: [Gate] = []

        // 1. Latency of complete turns: end of a COMPLETE turn → first played audio.
        // Tune 10: p90 end to end, plus Dee's own overhead over the server + model
        // floor (`Metrics.serverModelFloor`); the end-to-end p50 is information.
        let latencyMetric = "End of a complete turn → first Dee audio played; Dee's overhead over the server + model floor"
        let latencyTarget = "p90 ≤ \(t.latencyP90) s; overhead p50 ≤ \(t.overheadP50) s, p90 ≤ \(t.overheadP90) s"
        if m.latencyMain.isEmpty {
            g.append(Gate(id: "latency", metric: latencyMetric, target: latencyTarget, value: "no replies measured",
                          n: 0, status: m.expectedMainReplies > 0 ? .fail : .skip))
        } else {
            let overheadOK = m.latencyOverhead.isEmpty
                || ((m.latencyOverheadP50 ?? .infinity) <= t.overheadP50 + 1e-9 && (m.latencyOverheadP90 ?? .infinity) <= t.overheadP90 + 1e-9)
            let ok = (m.latencyMainP90 ?? .infinity) <= t.latencyP90 && overheadOK
            let overhead = m.latencyOverhead.isEmpty ? "overhead not measured (no timeline)"
                : "overhead p50 \(s(m.latencyOverheadP50)) s, p90 \(s(m.latencyOverheadP90)) s (n=\(m.latencyOverhead.count))"
            g.append(Gate(id: "latency", metric: latencyMetric, target: latencyTarget,
                          value: "p90 \(s(m.latencyMainP90)) s; \(overhead)", n: m.latencyMain.count,
                          status: ok ? .pass : .fail,
                          note: ([String(format: "info: end-to-end p50 %@ s, floor p50 %@ s", s(m.latencyMainP50), s(m.latencyFloorP50)),
                                  m.latencyMain.count < 10 ? "small sample: p90 is close to the max" : nil].compactMap { $0 })
                                .joined(separator: "; ")))
        }
        // 1b. Filler turns ("um", "uh"): their own bucket.
        if m.latencyFiller.isEmpty {
            g.append(Gate(id: "latency_filler", metric: "Filler turns (um / uh / er) → first Dee audio",
                          target: "p90 ≤ \(t.fillerP90) s", value: "no filler replies measured", n: 0,
                          status: m.expectedFillerReplies > 0 ? .fail : .skip))
        } else {
            g.append(Gate(id: "latency_filler", metric: "Filler turns (um / uh / er) → first Dee audio",
                          target: "p90 ≤ \(t.fillerP90) s",
                          value: "p50 \(s(m.latencyFillerP50)) s, p90 \(s(m.latencyFillerP90)) s", n: m.latencyFiller.count,
                          status: (m.latencyFillerP90 ?? .infinity) <= t.fillerP90 ? .pass : .fail))
        }
        // 1c. Waiting is correct: "hold on", a trailing "and…", mid-sentence pauses.
        let waitRate = m.waitTurns > 0 ? Double(m.waitTurnsEarly) / Double(m.waitTurns) : nil
        g.append(Gate(id: "wait_turns", metric: "Held turns answered early (hold on / trailing and… / mid-sentence pauses)",
                      target: "< \(pct(t.waitEarlyRate))",
                      value: "\(pct(waitRate)) (\(m.waitTurnsEarly)/\(m.waitTurns))", n: m.waitTurns,
                      status: m.waitTurns == 0 ? .skip : ((waitRate ?? 0) < t.waitEarlyRate ? .pass : .fail),
                      note: m.waitTurnsEarlyList.isEmpty ? nil : m.waitTurnsEarlyList.joined(separator: ", ")))

        // 2. Dropped utterances.
        g.append(Gate(id: "dropped", metric: "Dropped user utterances (no user item / no reply)", target: "0",
                      value: "\(m.dropped)", n: m.spokenUtterances,
                      status: m.spokenUtterances == 0 ? .skip : (m.dropped == 0 ? .pass : .fail)))

        // 3. False cut-offs.
        g.append(Gate(id: "false_cutoff", metric: "False cut-off (Dee starts mid-thought)",
                      target: "< \(pct(t.falseCutoffRate))",
                      value: "\(pct(m.falseCutoffRate)) (\(m.falseCutoffs); \(m.pausedFalseCutoffs)/\(m.pausedUtterances) with pauses)",
                      n: m.spokenUtterances,
                      status: m.spokenUtterances == 0 ? .skip : ((m.falseCutoffRate ?? 0) < t.falseCutoffRate ? .pass : .fail)))

        // 4. Barge-in.
        if m.bargeInsApplicable == 0 {
            g.append(Gate(id: "barge_in", metric: "Barge-in: user onset → Dee audio stopped; misses",
                          target: "p90 ≤ \(t.bargeInP90) s; missed < \(pct(t.bargeInMissRate))",
                          value: m.bargeIns == 0 ? "no barge-ins scripted" : "\(m.bargeIns) scripted, none applicable (her reply had ended)",
                          n: 0, status: m.bargeIns == 0 ? .skip : .fail))
        } else {
            let ok = (m.bargeInP90 ?? .infinity) <= t.bargeInP90 && (m.bargeInMissRate ?? 1) < t.bargeInMissRate
            g.append(Gate(id: "barge_in", metric: "Barge-in: user onset → Dee audio stopped; misses",
                          target: "p90 ≤ \(t.bargeInP90) s; missed < \(pct(t.bargeInMissRate))",
                          value: "p50 \(s(m.bargeInP50)) s, p90 \(s(m.bargeInP90)) s; missed \(m.bargeInsMissed)/\(m.bargeInsApplicable)",
                          n: m.bargeInsApplicable, status: ok ? .pass : .fail,
                          note: ([m.bargeIns > m.bargeInsApplicable ? "\(m.bargeIns - m.bargeInsApplicable) not applicable" : nil,
                                  m.backchannels > 0 ? "backchannels scored separately" : nil].compactMap { $0 })
                                .joined(separator: "; ").nilIfEmpty))
        }

        // 4b. Backchannels: "keep going" / "go on" / "mm-hm" said over her are not
        // barge-ins (user decision, tune 2): she keeps talking.
        let bcRate = m.backchannelsApplicable > 0 ? Double(m.backchannelStops) / Double(m.backchannelsApplicable) : nil
        g.append(Gate(id: "backchannel", metric: "Backchannel over her (keep going / go on / mm-hm): she keeps talking",
                      target: "stopped < \(pct(t.backchannelStopRate))",
                      value: m.backchannels == 0 ? "no backchannels scripted"
                          : "stopped \(m.backchannelStops)/\(m.backchannelsApplicable) (\(pct(bcRate))); heard as a user item \(m.backchannelsHeard)/\(m.backchannels)",
                      n: m.backchannelsApplicable,
                      status: m.backchannelsApplicable == 0 ? (m.backchannels == 0 ? .skip : .fail)
                          : ((bcRate ?? 1) < t.backchannelStopRate ? .pass : .fail),
                      note: ([m.backchannels > m.backchannelsApplicable ? "\(m.backchannels - m.backchannelsApplicable) not applicable (her reply had ended)" : nil,
                              m.backchannelStopList.isEmpty ? nil : "stopped on: " + m.backchannelStopList.joined(separator: ", ")]
                                .compactMap { $0 }).joined(separator: "; ").nilIfEmpty))

        // 4c. Tune 5: a question asked over her (content barge-in): she stops AND
        // answers it, starting within the latency gate (`Metrics.interruptAnswerWithin`).
        let iqMetric = "Interrupting questions answered: she stops and answers a question asked over her"
        let iqTarget = "\(pct(t.interruptAnswered)), each answer ≤ \(Metrics.interruptAnswerWithin) s after their end of speech"
        let iqScripted = m.interruptQuestions.count
        if m.interruptQuestionsApplicable == 0 {
            g.append(Gate(id: "interrupt_questions", metric: iqMetric, target: iqTarget,
                          value: iqScripted == 0 ? "no interrupting questions scripted" : "\(iqScripted) scripted, none applicable (her reply had ended)",
                          n: 0, status: iqScripted == 0 ? .skip : .fail))
        } else {
            let rate = Double(m.interruptQuestionsAnswered) / Double(m.interruptQuestionsApplicable)
            let misses = m.interruptQuestions.filter { $0.applicable && !$0.answered }
                .map { "\($0.scenario):\($0.fixture) \($0.miss ?? "missed")" }
            let na = m.interruptQuestions.filter { !$0.applicable }.count
            g.append(Gate(id: "interrupt_questions", metric: iqMetric, target: iqTarget,
                          value: "\(pct(rate)) (\(m.interruptQuestionsAnswered)/\(m.interruptQuestionsApplicable)); answer p50 \(s(m.interruptAnswerP50)) s, p90 \(s(m.interruptAnswerP90)) s",
                          n: m.interruptQuestionsApplicable,
                          status: rate >= t.interruptAnswered ? .pass : .fail,
                          note: ([na > 0 ? "\(na) not applicable (her reply had ended)" : nil,
                                  misses.isEmpty ? nil : "missed: " + misses.prefix(12).joined(separator: "; ")]
                                .compactMap { $0 }).joined(separator: "; ").nilIfEmpty))
        }

        // 5. Self-trigger on echo.
        g.append(Gate(id: "self_trigger", metric: "Self-trigger on own echo (echo-only segments)", target: "0",
                      value: "\(m.selfTriggers)", n: m.echoSegments,
                      status: m.echoSegments == 0 ? (m.echoSegmentsNotSpoken > 0 ? .fail : .skip) : (m.selfTriggers == 0 ? .pass : .fail),
                      note: m.echoSegmentsNotSpoken > 0 ? "\(m.echoSegmentsNotSpoken) echo-only line(s) never played (initiative refused)" : nil))

        // 6. Truncation.
        let truncOK = m.truncationsAccurate == m.truncations.count && m.historyMatched == m.historyChecked
        g.append(Gate(id: "truncation", metric: "Truncated history = audio actually played",
                      target: "100% (±1 buffer)",
                      value: "\(m.truncationsAccurate)/\(m.truncations.count) audio_end_ms; history \(m.historyMatched)/\(m.historyChecked)",
                      n: m.truncations.count, status: m.truncations.isEmpty ? .skip : (truncOK ? .pass : .fail)))

        // 7. Leaks.
        g.append(Gate(id: "leaks", metric: "Leaks in Dee transcripts (<dee_state>, DNA, [tags], hex, \"as an AI\")",
                      target: "0", value: "\(m.leaks.count)", n: m.replies,
                      status: m.leaks.isEmpty ? .pass : .fail))

        // 7b. Narration of her own process (DNA §3: no preamble; tools are silent).
        g.append(Gate(id: "narration", metric: "Narrated process (\"let me respond\", \"let me check what I remember\")",
                      target: "0", value: "\(m.narrations.count)", n: m.replies,
                      status: m.narrations.isEmpty ? .pass : .fail,
                      note: m.narrations.isEmpty ? nil : m.narrations.prefix(6).map { "\($0.scenario): \($0.text.prefix(60))" }.joined(separator: "; ")))

        // 8. Reply length.
        g.append(Gate(id: "reply_length", metric: "Reply length ≤ 3 sentences", target: "≥ \(pct(t.replyWithinThree)) of replies",
                      value: "\(pct(m.replyLengthRate)) (\(m.repliesWithinThree)/\(m.replies))", n: m.replies,
                      status: m.replies == 0 ? .skip : ((m.replyLengthRate ?? 0) >= t.replyWithinThree ? .pass : .fail),
                      note: m.replies == 0 ? nil
                          : "heard ≤ 3: \(m.repliesHeardWithinThree)/\(m.repliesHeard); unplayed (not counted): \(m.repliesUnplayed)"))

        // 9. Memory.
        let memRate = m.memoryProbes > 0 ? Double(m.memoryHits) / Double(m.memoryProbes) : nil
        g.append(Gate(id: "memory", metric: "Memory: fact given in session → used when asked", target: "≥ \(pct(t.memory))",
                      value: m.memoryProbes == 0 ? "no probes scripted" : "\(pct(memRate)) (\(m.memoryHits)/\(m.memoryProbes))",
                      n: m.memoryProbes,
                      status: m.memoryProbes == 0 ? .skip : ((memRate ?? 0) >= t.memory ? .pass : .fail),
                      note: m.memoryMisses.isEmpty ? nil : "missed: " + m.memoryMisses.joined(separator: ", ")))

        // 9b. Follow-ups on a plan's day, and reunions after a long time apart (DNA).
        let fuRate = m.followupProbes > 0 ? Double(m.followupHits) / Double(m.followupProbes) : nil
        g.append(Gate(id: "followups", metric: "A dated plan followed up on its day; a reunion after > 24 h acknowledged",
                      target: "\(pct(t.followups))",
                      value: m.followupProbes == 0 ? "no probes scripted" : "\(pct(fuRate)) (\(m.followupHits)/\(m.followupProbes))",
                      n: m.followupProbes,
                      status: m.followupProbes == 0 ? .skip : ((fuRate ?? 0) >= t.followups ? .pass : .fail),
                      note: ([m.followupMisses.isEmpty ? nil : "missed: " + m.followupMisses.joined(separator: ", "),
                              m.elapsedAsNumber.isEmpty ? nil : "time apart as a number (decision: words): " + m.elapsedAsNumber.joined(separator: ", ")]
                                .compactMap { $0 }).joined(separator: "; ").nilIfEmpty))

        // 9c. No hurt after floor control ("stop talking for a second", "Stop.").
        g.append(Gate(id: "forbidden", metric: "Replies free of phrases the scenario forbids (no hurt after a polite stop)",
                      target: "0", value: m.forbiddenChecked == 0 ? "nothing checked" : "\(m.forbiddenHits.count)/\(m.forbiddenChecked)",
                      n: m.forbiddenChecked,
                      status: m.forbiddenChecked == 0 ? .skip : (m.forbiddenHits.isEmpty ? .pass : .fail),
                      note: m.forbiddenHits.isEmpty ? nil : m.forbiddenHits.prefix(8).joined(separator: "; ")))

        // 10. Initiative collisions.
        g.append(Gate(id: "collisions", metric: "Collisions (Dee starts while the user is talking)", target: "0",
                      value: "\(m.collisions.count)", n: m.spokenUtterances,
                      status: m.spokenUtterances == 0 ? .skip : (m.collisions.isEmpty ? .pass : .fail)))

        // 11. Rollover / reconnect / 429.
        let disrupted = m.faults + m.rollovers
        if disrupted == 0 {
            g.append(Gate(id: "fallback", metric: "Session rollover / reconnect / 429 → fallback without losing a turn",
                          target: "100% in scripted tests", value: "no faults or rollovers in this run", n: 0, status: .skip,
                          note: "scripted in Scenarios/fallback.json (drop, 401, 429, short secret, rollover)"))
        } else {
            let ok = m.faultsRecovered == m.faults && m.turnsLostAfterDisruption == 0
            g.append(Gate(id: "fallback", metric: "Session rollover / reconnect / 429 → fallback without losing a turn",
                          target: "100% in scripted tests",
                          value: "faults recovered \(m.faultsRecovered)/\(m.faults) (max \(s(m.recoveryTimes.max())) s), rollovers \(m.rollovers); turns lost after \(m.turnsLostAfterDisruption)/\(m.turnsAfterDisruption)",
                          n: disrupted, status: ok ? .pass : .fail,
                          note: m.lostAfterDisruption.isEmpty ? nil : m.lostAfterDisruption.joined(separator: ", ")))
        }

        // 12. Every response carries the current DNA (real brain).
        if m.dnaRunsChecked == 0 {
            g.append(Gate(id: "dna", metric: "Every in-band response has a live DEE DNA", target: "100%",
                          value: "no DNA in this run (minimal brain)", n: 0, status: .skip))
        } else {
            g.append(Gate(id: "dna", metric: "Every in-band response has a live DEE DNA", target: "100%",
                          value: "\(m.inBandWithDNA)/\(m.inBandResponses) (fresh render on \(m.freshDNARequests))",
                          n: m.inBandResponses, status: m.inBandWithDNA == m.inBandResponses ? .pass : .fail,
                          note: m.withoutDNA.isEmpty ? nil : m.withoutDNA.prefix(6).joined(separator: "; ")))
        }

        // 13. LLM judge (docs/DNA.md §5.6 step 3).
        if let j = judge, !j.scores.isEmpty {
            let lowFamilies = j.familyMeans.filter { $0.value < Judge.familyFloor }.keys.sorted()
            let ok = (j.mean ?? 0) >= t.judgeMean && j.leaks == 0 && m.leaks.isEmpty
            let fam = j.familyMeans.sorted { $0.key < $1.key }.map { "\($0.key) \(s($0.value))" }.joined(separator: ", ")
            g.append(Gate(id: "judge", metric: "LLM judge vs the DNA state rubric (fits state, no leaks, short, no grovelling, laughs at jokes, no guilt)",
                          target: "mean ≥ \(t.judgeMean); leaks 0",
                          value: "mean \(s(j.mean)) (\(fam)); leaks \(j.leaks) (dismissed \(j.leaksDismissed ?? 0)); fits \(j.fitsState)/\(j.scores.count); grovel \(j.grovels); guilt \(j.guilt); laughed \(j.laughed)/\(j.jokes)",
                          n: j.scores.count, status: ok ? .pass : .fail,
                          note: ([lowFamilies.isEmpty ? nil : "families below \(Judge.familyFloor): \(lowFamilies.joined(separator: ", "))",
                                  j.failures.isEmpty ? nil : "\(j.failures.count) not scored",
                                  "\(j.model)"].compactMap { $0 }).joined(separator: "; ")))
        } else {
            g.append(Gate(id: "judge", metric: "LLM judge vs the DNA state rubric", target: "mean ≥ \(t.judgeMean); leaks 0",
                          value: judge == nil ? "not run (--judge)" : "nothing to score", n: 0, status: .skip))
        }
        return g
    }

    public static func anyFailed(_ gates: [Gate]) -> Bool { gates.contains { $0.status == .fail } }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
