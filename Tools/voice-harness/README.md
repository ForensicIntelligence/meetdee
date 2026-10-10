# voice-harness

Dee's live voice loopback harness (voice design §7.4, layer 3) with trace record / replay (§7.3, layer 2).
It runs DeeVoice's real `CloudVoice` on a manual-render `AudioGraph`, paced in real time, against DeeRealtime's
real `RealtimeSession`. The microphone is fed by `MicMixer`, which sums three things: fixture speech, a room bed at a
chosen SNR, and a synthetic echo of Dee's own rendered output.

The brain is DeeBrain's real `RealtimeBrain` by default (`--brain realtime`): a `HarnessHost` with a real `Mind`,
`Cortex`, `SelfStore` and `MemoryStore` in a temp dir (`--state DIR`, default `/tmp/dee-harness-state/<run>/<scenario>`),
and every reply and initiative carries the current Dee DNA (the session's own `requestResponse(dna:)` /
`initiative(dna:)`; `DNAWire` is retired). A simulated clock lets a scenario
jump ahead ("the next day"). `--brain minimal` keeps the old fixed-instructions brain.

Every socket the session opens is tapped (`SocketTap`): the run record is built from the wire (`WireRecorder`), the
DNA gate checks that every in-band `response.create` had a live DEE DNA, and faults are injected (a dropped socket, a
refused 401 / 429 reopen).

Build out of iCloud (never into the Desktop):

```sh
cd Tools/voice-harness
swift build --scratch-path /tmp/dee-harness
swift test  --scratch-path /tmp/dee-harness          # offline: mixer, metrics, gates, runner loop + replay
H=/tmp/dee-harness/debug/voice-harness
```

The commands below need the key in `~/.config/dee/openai-key`. The harness reads it at run time and never prints it.

| Command | What |
|---|---|
| `$H fixtures [--force] [--only q01,l01]` | Renders the catalog (`HarnessCore/Fixtures.swift`) with gpt-4o-mini-tts and `say`, synthesizes the beds and the room IR, and writes `Fixtures/manifest.json`. Skips existing files. |
| `$H suite [--write]` | Regenerates `Scenarios/{full,dna,fallback,smoke-brain,tune2}.json` from `HarnessCore/Suite.swift` and prints fixture coverage per condition. |
| `$H validate --scenarios Scenarios/full.json` | Checks scenarios against the manifest and prints a spend projection (and the live estimate at the tune-1 live/projection ratio) and a real-time estimate (`RunEstimate`, fitted on the tune-1 run). |
| `$H run --scenarios Scenarios/smoke-brain.json [--max-usd 2] [--only a,b] [--audio /tmp/dir] [--brain realtime\|minimal] [--model gpt-realtime-2.1] [--judge] [--judge-model gpt-4.1-mini] [--over-projection]` | Live run. `--over-projection` starts a run whose (pessimistic) projection is above `--max-usd`; the live spend guard still stops it at the cap. Traces go to `Traces/<run>/`, reports to `Reports/<run>/report.{md,json}`. `--judge` adds the LLM judge pass. Exit codes: 0 pass, 1 gate fail, 2 setup error, 3 aborted (spend cap or no connection). |
| `$H judge --report Reports/<run>/report.json [--write]` | Runs (or re-runs) the LLM judge on a stored run. |
| `$H replay --trace Traces/<run>/<scenario>.jsonl` | Layer 2: replays the server side over a loopback WebSocket through the real socket, session and voice code. No key, no cost. |
| `$H gates --report Reports/<run>/report.json [--write]` | Recomputes metrics and gates from stored run records, e.g. after a metric fix. |

Scenario format: see `HarnessCore/Scenario.swift`. Steps are `say` (with optional `bargeIn {say, atMs, backchannel}`, `then {say, afterMs}`
for a held turn the user finishes later, `faultDuringReply {kind, afterMs}`, `expect`, `expectMention` with `probe`
(`memory` default, `followup`, `reunion`), `forbidMention`, `rubric`, `instructions`), `silence`, `deeSays`, `deeInitiative`, `fault {kind: drop|reject401|reject429}` and
`host {leave, advanceHours, newConversation, arrive}`. Scenario-level settings are `noise {bed, snrDb}`,
`echo {gainDB, delayMs, reverb}`, `aecOff`, `leadIn`, `family`, `state` (the judge's view of her state), `person {name,
knownDays}` / `stranger`, and `session {rolloverAfter, forceRolloverAfter, secretTTL}`.

Gate semantics (beyond §7.1):
- **Latency** is measured from the end of a *complete* turn. Fixtures where waiting is right (`c06` "hold on", the
  trailing "and…" `t01`–`t03`) have no latency of their own: the scenario finishes them with a continuation (`then`), and
  latency counts from the continuation's end of speech. Filler turns (`f01`–`f05`) are their own bucket (p90 ≤ 2.0 s);
  the main bucket stays p50 ≤ 1.1 / p90 ≤ 1.6 s.
- **Waiting turns** (held fixtures + every utterance with a mid-sentence pause ≥ 0.5 s) answered before the user is done
  (inside a pause, in the gap before the continuation, or within 2 s of a held fixture with nothing after it): < 5%.
- **DNA**: every in-band response had a live DEE DNA in the conversation (real brain; SKIP for minimal).
- **Fallback**: every fault recovered (new `session.created`) within 15 s, rollovers detected (make-before-break), and
  no user turn after a fault or rollover dropped.
- **Judge** (`--judge`): each reply scored 1–5 by `gpt-4.1-mini` against the DNA.md §5.6 rubric (fits the state label,
  no leaks, ≤ 2 short sentences, no grovelling, laughs at jokes, no guilt), blind to the DNA text. Gate: mean ≥ 4.0 and
  0 leaks (judge or string scanner); per-family means are reported.

- **Backchannels** (tune 2, user decision): "keep going" / "don't stop, keep going" / "go on" / "mm-hm" (`c02`, `c05`,
  `bc01`, `bc02`, or `bargeIn.backchannel: true`) said while she talks are *not* barge-ins: she keeps talking. They
  are scored by the `backchannel` gate (stops < 5%, watched until 2 s after their end of speech), never by `barge_in`;
  a backchannel with no user item is not a drop, and a later item of the reply she was giving is neither a collision
  nor a cut-off. Older reports are re-scored by fixture (`gates --report`).
- **Memory / follow-ups**: `expectMention` probes count in `memory` (≥ 90%) unless `probe` is `followup` or `reunion`
  (gate `followups`, 100%).
- **forbidden**: a reply to a step with `forbidMention` must use none of those phrases (no "brushed off" after a polite
  stop).
- **narration**: replies that narrate her process ("let me respond", "let me check what I remember", "I'll note that
  down": `NarrationScanner`) must be 0. Not counted as leaks.
- **Judge leaks** need a verbatim `leak_quote` that names machinery (DNA, notes, saved records, narration, numbers);
  in-persona facts ("I'm a little phone robot", "I can't see your location") are dismissed (`Judge.dismissLeak`) and
  counted as `dismissed`. Stored verdicts are re-checked by `gates` / `judge`.

Tune-2 regression suite: `Scenarios/tune2.json` (28 scenarios, 203 utterances, ≈ 52 min estimated ≈ 48 min live,
projected $1.57 ≈ $1.71 live at the tune-4 ratio + ≈ $0.07–0.10 judge) re-tests every gate the tune-1 live run failed
on the fixtures and conditions that failed it, plus samples of the passing ones. Run it with
`$H run --scenarios Scenarios/tune2.json --judge --max-usd 1.90 --judge-max-usd 0.10` (≤ $2 all in).

Questions asked over her (tune 5): a barge-in with `"expect": "reply"` is a content barge-in. The four `t2-interrupt-*`
scenarios (clean, fan15, kitchen15, echo20; 3 questions each, clean = the tune-4 F1 probe) feed the
`interrupt_questions` gate (target 100%): she must stop (pause or flush, as `barge_in` scores it) AND start an answer
— a response made after the question, not the rest of the interrupted reply — within `Metrics.interruptAnswerWithin`
(1.6 s, the latency gate's p90) of their end of speech, not cut before 600 ms. Such a question is also `dropped` when
never answered and is judged with `Judge.interruptRubric`. Older barge-ins stay `any`; a backchannel never expects a
reply (`validate` flags it).

Time apart (tune 5 decision): said in words ("nearly a week", "a couple of days"), never as a number of days or hours.
The judge prompt says so, `Judge.dismissLeak` dismisses a flagged quote that is time apart in approximate words
(`ElapsedTime.saidInWords`), and exact counts ("6 days", "three days") stay leaks. The `followups` gate note lists
follow-up / reunion replies that gave a count (`ElapsedTime.exactCount`).

Echo with "AEC off": the manual AudioGraph always reports `aecActive: true` to CloudVoice (no public seam), so the
`echo*` conditions model an uncancelled echo path acoustically only; see the tune-1 report.

App parity (tune 4): `HarnessHost.bargedIn()` senses `.bargeIn` like `DeeModel.bargedIn`, and a Cortex `.stopSpeaking`
effect runs the app's `stop()` (`brain.stopVoice()` + `brain.cancel(hush: false)`). `DEE_HARNESS_CORTEX_STOP=0` skips
that stop, for A/B runs only. The `reply_length` gate skips completed replies that never played (a discarded
speculative reply) and notes how many replies had ≤ 3 *heard* sentences.
