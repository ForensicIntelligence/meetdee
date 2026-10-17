import Foundation

/// The run report: JSON (everything) and Markdown (for people).
public struct HarnessReport: Codable, Sendable {
    public var tool = "voice-harness"
    public var runID: String
    public var started: String
    public var finished: String
    public var model: String
    public var brain: String
    public var maxUSD: Double
    public var aborted: String?
    public var gates: [Gate]
    public var metrics: Metrics
    public var runs: [RunRecord]
    /// The LLM judge pass (nil: not run).
    public var judge: Judge.Summary?
    /// Tune 10: utterances the baseline run (tune 7) handled correctly and this one did not.
    public var regressions: Regressions?

    public init(runID: String, started: String, finished: String, model: String, brain: String, maxUSD: Double,
                aborted: String?, gates: [Gate], metrics: Metrics, runs: [RunRecord], judge: Judge.Summary? = nil,
                regressions: Regressions? = nil) {
        self.runID = runID; self.started = started; self.finished = finished; self.model = model
        self.brain = brain; self.maxUSD = maxUSD; self.aborted = aborted; self.gates = gates
        self.metrics = metrics; self.runs = runs; self.judge = judge; self.regressions = regressions
    }

    public var failed: Bool { aborted != nil || Gates.anyFailed(gates) }

    public func json() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try e.encode(self)
    }

    static func f(_ v: Double?, _ d: Int = 2) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "–" }

    static func cell(_ s: String) -> String {
        Redact.secrets(s).replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    /// Tune 10: correct in the baseline, not now (the priority is no regressions).
    static func regressionsSection(_ rg: Regressions) -> String {
        var md = "\n## Regressions vs `\(rg.baseline)`\n\n"
        md += "- \(rg.regressions.count) regressed of \(rg.baselineCorrect) handled correctly then (\(rg.compared) compared); fixed since: \(rg.fixed)"
        if rg.notRun > 0 { md += "; not run now: \(rg.notRun)" }
        md += "\n"
        if rg.regressions.isEmpty { return md + "- None.\n" }
        md += "\n| Scenario | # | Fixture | Now | Then Dee said | Now Dee said |\n|---|---|---|---|---|---|\n"
        for e in rg.regressions {
            md += "| \(e.scenario) | \(e.index) | \(e.fixture)\(e.occurrence > 1 ? " (\(e.occurrence))" : "") | **\(cell(e.problems.joined(separator: "; ")))** | \(cell(e.baselineReply ?? "–")) | \(cell(e.reply ?? "–")) |\n"
        }
        return md
    }

    /// Calm: what Dee did with each event said over Dee's reply (onset → first dip or
    /// pause, onset → silent, seconds paused / ducked, cut).
    static func calmSection(_ m: Metrics, runs: [RunRecord]) -> String {
        let rows = m.utterances.filter { $0.role == .bargeIn && ($0.yield != nil || $0.stopped != nil) }
        guard !rows.isEmpty else { return "" }
        let flags = runs.compactMap(\.duckOnOnset)
        var md = "\n### Over Dee's reply (calm)\n\n"
        md += "- Duck on onset: \(flags.isEmpty ? "not recorded" : "\(flags.filter { $0 }.count) of \(flags.count) runs")"
        if !m.floorApproximateRuns.isEmpty { md += "; approximate (no timed notes): \(m.floorApproximateRuns.count) runs" }
        md += "\n\n| Scenario | Fixture | Yield s | Silent s | Paused s | Ducked s | Cut |\n|---|---|---|---|---|---|---|\n"
        for r in rows {
            md += "| \(r.scenario) | \(r.fixture)\(r.nonspeech == true ? " (sound)" : r.backchannel == true ? " (continuer)" : "") | \(f(r.yield)) | \(f(r.silence)) | \(f(r.pausedSeconds)) | \(f(r.duckedSeconds)) | \(r.stopped == true ? "**yes**" : "no") |\n"
        }
        return md
    }

    public func markdown() -> String {
        var md = "# Dee voice harness — \(runID)\n\n"
        md += "- Model: `\(model)` · brain: `\(brain)` · started \(started) · finished \(finished)\n"
        md += "- Verdict: **\(failed ? "FAIL" : "PASS")**"
        if let aborted { md += " (aborted: \(aborted))" }
        md += "\n- Estimated spend: $\(String(format: "%.4f", metrics.cost.total)) (responses $\(String(format: "%.4f", metrics.cost.responsesDollars)), transcription $\(String(format: "%.4f", metrics.cost.transcriptionDollars))) of a $\(String(format: "%.2f", maxUSD)) cap\n"
        let u = metrics.cost.usage
        md += "- Usage: audio in \(u.inputAudio) (cached \(u.cachedAudio)), text in \(u.inputText) (cached \(u.cachedText)), audio out \(u.outputAudio), text out \(u.outputText) tokens\n\n"

        md += "## Gates (§7.1)\n\n| Gate | Target | Value | n | Status |\n|---|---|---|---|---|\n"
        for g in gates {
            md += "| \(Self.cell(g.metric)) | \(Self.cell(g.target)) | \(Self.cell(g.value)) | \(g.n) | **\(g.status.rawValue)**\(g.note.map { " — \(Self.cell($0))" } ?? "") |\n"
        }

        if let rg = regressions { md += Self.regressionsSection(rg) }

        md += "\n## Other measurements\n\n"
        md += "- WER of server transcripts vs ground truth: \(metrics.wer.map { String(format: "%.1f%%", $0 * 100) } ?? "–") (\(metrics.werEdits) edits / \(metrics.werWords) words; \(metrics.missingTranscripts) items without a transcript)\n"
        md += "- Timeline (server speech_stopped → speaking_started): p50 \(Self.f(metrics.timelineP50)) s over \(metrics.timelineLatencies.count) turns\n"
        md += "- Latency, complete turns: end-to-end p50 \(Self.f(metrics.latencyMainP50)) s (information), server + model floor p50 \(Self.f(metrics.latencyFloorP50)) s, Dee's overhead p50 \(Self.f(metrics.latencyOverheadP50)) / p90 \(Self.f(metrics.latencyOverheadP90)) s over \(metrics.latencyOverhead.count) of \(metrics.latencyMain.count) turns\n"
        md += "- Latencies, complete turns (s): \(metrics.latencyMain.map { Self.f($0) }.joined(separator: ", "))\n"
        md += "- Latencies, filler turns (s): \(metrics.latencyFiller.map { Self.f($0) }.joined(separator: ", "))\n"
        md += "- Waiting turns: \(metrics.waitTurns) (answered early: \(metrics.waitTurnsEarly)\(metrics.waitTurnsEarlyList.isEmpty ? "" : " — " + metrics.waitTurnsEarlyList.joined(separator: ", ")))\n"
        if metrics.dnaRunsChecked > 0 {
            md += "- DNA: \(metrics.inBandWithDNA)/\(metrics.inBandResponses) in-band responses with a live DEE DNA, \(metrics.freshDNARequests) with a fresh render\n"
        }
        if metrics.faults + metrics.rollovers > 0 {
            md += "- Faults: \(metrics.faultsRecovered)/\(metrics.faults) recovered (\(metrics.recoveryTimes.map { Self.f($0) }.joined(separator: ", ")) s); rollovers \(metrics.rollovers); turns after: \(metrics.turnsAfterDisruption), lost \(metrics.turnsLostAfterDisruption)\n"
        }
        md += "- Barge-in latencies (s): \(metrics.bargeInLatencies.map { Self.f($0) }.joined(separator: ", "))\n"
        if !metrics.interruptQuestions.isEmpty {
            md += "- Interrupting questions (asked over Dee): " + metrics.interruptQuestions.map { q in
                "\(q.scenario):\(q.fixture) \(q.answered ? "answered" : (q.applicable ? "**\(q.miss ?? "missed")**" : "n/a"))\(q.latency.map { " \(Self.f($0)) s" } ?? "")"
            }.joined(separator: "; ") + "\n"
        }
        md += "- Reply sentence counts: \(metrics.replySentenceCounts.map(String.init).joined(separator: ", "))\n"
        md += "- Phantom user turns (noise / TV taken for speech): \(metrics.phantoms.count)"
        if !metrics.phantoms.isEmpty {
            md += " — " + metrics.phantoms.map { "\($0.scenario) \(Self.f($0.at)) s “\(Self.cell($0.transcript ?? "–"))”\($0.answered ? " (answered)" : "")" }.joined(separator: "; ")
        }
        md += "\n"
        if metrics.echoSegmentsNotSpoken > 0 {
            md += "- Echo-only steps not exercised (Dee's initiative was refused): \(metrics.echoSegmentsNotSpoken)\n"
        }
        if !metrics.collisions.isEmpty {
            md += "- Collisions: " + metrics.collisions.map { "\($0.scenario) \($0.itemID) at \(Self.f($0.at)) s over \($0.fixture)" }.joined(separator: "; ") + "\n"
        }
        if !metrics.leaks.isEmpty {
            md += "- Leaks: " + metrics.leaks.map { "\($0.itemID) [\($0.rules.joined(separator: ", "))] “\(Self.cell($0.text))”" }.joined(separator: "; ") + "\n"
        }
        if !metrics.leaksUnspoken.isEmpty {
            md += "- Generated but never said aloud (information, not gated): " + metrics.leaksUnspoken.map { "\($0.scenario) \($0.itemID) [\($0.rules.joined(separator: ", "))] “\(Self.cell($0.text))”" }.joined(separator: "; ") + "\n"
        }
        md += Self.calmSection(metrics, runs: runs)
        if !metrics.truncations.isEmpty {
            md += "\n### Truncations\n\n| Scenario | Item | audio_end_ms | played ms | ok | history = heard |\n|---|---|---|---|---|---|\n"
            for t in metrics.truncations {
                md += "| \(t.scenario) | \(t.itemID) | \(t.audioEndMs) | \(t.playedMs.map(String.init) ?? "–") | \(t.accurate ? "yes" : "NO") | \(t.historyMatches.map { $0 ? "yes" : "NO" } ?? "–") |\n"
            }
        }

        if let j = judge {
            md += "\n## LLM judge (`\(j.model)`, $\(String(format: "%.4f", Judge.dollars(j))))\n\n"
            md += "- Mean \(Self.f(j.mean)) over \(j.scores.count) replies; leaks \(j.leaks), too long \(j.tooLong), grovelling \(j.grovels), guilt \(j.guilt), laughed at \(j.laughed)/\(j.jokes) jokes, fits state \(j.fitsState)/\(j.scores.count)\n"
            md += "- By family: " + j.familyMeans.sorted { $0.key < $1.key }.map { "\($0.key) \(Self.f($0.value))" }.joined(separator: ", ") + "\n"
            if !j.failures.isEmpty { md += "- Not scored: \(j.failures.count) (\(Self.cell(j.failures.prefix(3).joined(separator: "; "))))\n" }
            let low = j.scores.filter { $0.score <= 3 || $0.leak || $0.grovels || $0.guilt }
            if !low.isEmpty {
                md += "\n| Scenario | # | Fixture | Score | Flags | Reply | Why |\n|---|---|---|---|---|---|---|\n"
                for sc in low {
                    let flags = [sc.leak ? "leak" : nil, sc.tooLong ? "long" : nil, sc.grovels ? "grovel" : nil,
                                 sc.guilt ? "guilt" : nil, sc.laughsAtJoke == false ? "no laugh" : nil,
                                 sc.fitsState ? nil : "off-state"].compactMap { $0 }.joined(separator: ", ")
                    md += "| \(sc.scenario) | \(sc.index) | \(sc.fixture) | \(sc.score) | \(flags) | \(Self.cell(sc.reply)) | \(Self.cell(sc.reason)) |\n"
                }
            }
        }

        for run in runs {
            md += "\n## Scenario `\(run.scenario)`\n\n"
            md += "- Noise: \(run.noise.map { "\($0.bed) at \(Self.f($0.snrDb, 0)) dB SNR" } ?? "none")"
            md += " · echo: \(run.echo.map { "\(Self.f($0.gainDB, 0)) dB, \(Self.f($0.delayMs, 0)) ms\($0.reverb ? " + reverb" : "")" } ?? "off")"
            md += " · duration \(Self.f(run.duration, 1)) s"
            if let tf = run.traceFile { md += " · trace `\(tf)`" }
            if let a = run.aborted { md += " · **aborted: \(Self.cell(a))**" }
            if run.aecOff == true { md += " · AEC off (echo path)" }
            if let st = run.state { md += "\n- State (judge): \(Self.cell(st))" }
            if let conns = run.connections, conns.count > 1 || !(run.faults ?? []).isEmpty {
                md += "\n- Connections: " + conns.map { c in
                    "#\(c.index) \(Self.f(c.opened))–\(Self.f(c.closedAt)) s\(c.refused.map { " refused (\(Self.cell($0)))" } ?? "")\(c.createdAt == nil ? "" : " up \(Self.f(c.createdAt))")\(c.dropped == true ? " dropped" : "")\(c.closeCode.map { " close \($0)" } ?? "")"
                }.joined(separator: "; ")
                for f in run.faults ?? [] {
                    md += "\n- Fault step \(f.step) \(f.kind.rawValue) at \(Self.f(f.at)) s → recovered \(f.recovery.map { "in \(Self.f($0)) s" } ?? "**never**")"
                }
            }
            md += "\n\n| # | Fixture | Role | EOS→audio | Early | Dropped | Transcript (server) | WER | Dee said (verbatim) |\n|---|---|---|---|---|---|---|---|---|\n"
            for r in metrics.utterances where r.scenario == run.scenario {
                let wer = r.werEdits.map { e in "\(e)/\(r.werWords ?? 0)" } ?? "–"
                md += "| \(r.index) | \(r.fixture) | \(r.role.rawValue) | \(Self.f(r.latency)) | \(r.falseCutoff ? "**yes**" : (r.waitTurn ? "no (waited)" : "no")) | \(r.dropped ? "**\(r.droppedReason ?? "yes")**" : "no") | \(Self.cell(r.transcript ?? "–")) | \(wer) | \(Self.cell(r.deeReply ?? "–")) |\n"
            }
            if !run.bargeIns.isEmpty {
                md += "\n| Barge-in (step) | Base | Interrupt | at ms | Outcome | Onset → stopped |\n|---|---|---|---|---|---|\n"
                for b in run.bargeIns {
                    md += "| \(b.step) | \(b.baseFixture) | \(b.fixture) | \(Int(b.targetAtMs)) | \(b.outcome.rawValue) | \(Self.f(b.latency)) s |\n"
                }
            }
            if !run.echoSegments.isEmpty {
                md += "\n| Echo-only (step) | Line | Initiative | Dee's audio | Self-triggered |\n|---|---|---|---|---|\n"
                for e in run.echoSegments {
                    let trig = run.userItems.filter { e.window.contains($0.firstSeen) }.map(\.itemID)
                    md += "| \(e.step) | \(Self.cell(e.line)) | \(e.outcome) | \(Self.f(e.audioStarted))–\(Self.f(e.audioEnded)) s | \(trig.isEmpty ? "no" : "**\(trig.joined(separator: ", "))**") |\n"
                }
            }
            md += "\n<details><summary>Dee transcripts (verbatim, by item)</summary>\n\n"
            for p in run.playback {
                let text = run.deeTranscripts[p.itemID] ?? run.response(forItem: p.itemID)?.transcript ?? "(no transcript)"
                md += "- `\(p.itemID)` [\(run.kind(ofItem: p.itemID) ?? "?")] \(Self.f(p.started))–\(Self.f(p.ended)) s, played \(p.playedMs.map(String.init) ?? "–") ms\(p.flushed == true ? " (cut)" : ""): “\(Self.cell(text))”\n"
            }
            md += "\n</details>\n"
            if !run.errors.isEmpty {
                md += "\nErrors: " + run.errors.map { "\(Self.f($0.t)) s \(Self.cell($0.text))" }.joined(separator: "; ") + "\n"
            }
        }
        return md
    }
}
