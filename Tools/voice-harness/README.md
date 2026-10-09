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
| `$H suite [--write]` | Regenerates `Scenarios/{full,dna,fallback,smoke-brain}.json` from `HarnessCore/Suite.swift` and prints fixture coverage per condition. |
| `$H validate --scenarios Scenarios/full.json` | Checks scenarios against the manifest and prints a spend projection. |
| `$H run --scenarios Scenarios/smoke-brain.json [--max-usd 2] [--only a,b] [--audio /tmp/dir] [--brain realtime\|minimal] [--model gpt-realtime-2.1] [--judge] [--judge-model gpt-4.1-mini] [--over-projection]` | Live run. `--over-projection` starts a run whose (pessimistic) projection is above `--max-usd`; the live spend guard still stops it at the cap. Traces go to `Traces/<run>/`, reports to `Reports/<run>/report.{md,json}`. `--judge` adds the LLM judge pass. Exit codes: 0 pass, 1 gate fail, 2 setup error, 3 aborted (spend cap or no connection). |
| `$H judge --report Reports/<run>/report.json [--write]` | Runs (or re-runs) the LLM judge on a stored run. |
| `$H replay --trace Traces/<run>/<scenario>.jsonl` | Layer 2: replays the server side over a loopback WebSocket through the real socket, session and voice code. No key, no cost. |
| `$H gates --report Reports/<run>/report.json [--write]` | Recomputes metrics and gates from stored run records, e.g. after a metric fix. |

Scenario format: see `HarnessCore/Scenario.swift`. Steps are `say` (with optional `bargeIn {say, atMs}`, `then {say, afterMs}`
for a held turn the user finishes later, `faultDuringReply {kind, afterMs}`, `expect`, `expectMention`, `rubric`,
`instructions`), `silence`, `deeSays`, `deeInitiative`, `fault {kind: drop|reject401|reject429}` and
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

Echo with "AEC off": the manual AudioGraph always reports `aecActive: true` to CloudVoice (no public seam), so the
`echo*` conditions model an uncancelled echo path acoustically only; see the tune-1 report.
