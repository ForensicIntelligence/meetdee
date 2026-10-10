# DeeBrain — v0.6 contract

New library product `DeeBrain` in `Packages/DeeKit` (design steps B4, B5, B7). It is Dee's
brain on the OpenAI realtime session: it decides when she answers, describes her to the
model before every response (Dee DNA, `docs/DNA.md`, binding), bridges the tools, and
holds the cloud settings, key intake and status mapping. Depends on DeeCore, DeeMind,
DeeMemory, DeeSelf, DeeRealtime, DeeVoice. No UIKit/SwiftUI and no app code: a macOS
harness drives it exactly as the app does (`StandaloneHost`).

Tests: `swift test --filter DeeBrainTests` (offline: real `AudioGraph.manual()`, real
`CloudVoice` and `RealtimeSession`, scripted `FakeSocket` server, real `Mind` and `Cortex`).

## Parts

| Type | What |
|---|---|
| `RealtimeBrain` (`@MainActor`, `ReplyEngine`) | Sole consumer of `CloudVoice.brainEvents`. Turn decisions, DNA build and delivery, tool handler, reply channels, RAM rings and guard corpus, thinking mode. |
| `BrainHost` (protocol, `@MainActor`) | What the brain needs from the app: `answersOnCommit`, `voiceBaseline`, `modeSignals(at:)`, `heard(_:)`, `wordsFailed()`, `dnaParts(_:)`, `brainStartedReply(_:)`, `thinkingModeChanged(_:)`. Implemented by `DeeModel` (app) and `StandaloneHost` (harness, tests). |
| `DNAWire` | **Retired (tune 1)**, deprecated pass-through kept only so the voice harness compiles: `factory(_:)` returns the socket factory unchanged. The DNA lifecycle and the conversation ledger are `RealtimeSession`'s. Never reintroduce frame rewriting (it would re-id and double-delete the session's DNA). |
| `ProsodyTap` | Second consumer of the mic tap: 30 s of 40 ms frames; the server's utterance span laid onto them at the commit → `Prosody` / `ProsodyRead` (§1.9) without waiting for words. |
| `TurnPolicy` | Pure: `onCommit` (fast / wait for words / wait for partial / wait for address), exact-mode rule, initiative gate, `unfinished(_:)` / `held(_:)` (hold-on / trailing / riddle turns), `isBackchannel`, `isMetaPreamble`, `maxOutputTokens(length:effort:)`, `isCompleteSentence`. |
| `BrainToolbox`, `RenamedTool`, `DeviceTools` | `remember`/`recall`/`forget` (DeeMemory's tools under DNA.md's names; withheld when memories are private) + `calendar_events`, `add_calendar_event`, `reminders`, `add_reminder`, `find_contact`, `where_am_i`. Follow-ups: `recall` always, `remember`/`forget` if silent, device tools always. |
| `CloudSettings`, `KeyIntake`, `CloudStatus`, `AIVoiceDisclosure` | Settings › Dee keys and the session config; the pasted key → validated (GET /v1/models) → Keychain → field cleared; `VoiceProblem` → chip text/symbol/"cloud off"; the disclosure line. |
| `StandaloneHost` | A full host on a real `Mind` + `Cortex` (+ optional `MemoryStore`), body state as flags. |
| `BrainTrace` | Decisions and sizes only (plan, verdict, DNA estimate, section bytes, steps, guard drops, SHA-256, usage): never text. |

## When she answers

On `.userCommitted(item)`:

| Situation | Plan | Then |
|---|---|---|
| `host.answersOnCommit` false (asleep, nobody engaged) | `waitForAddress` | wait for the transcript; `host.heard` → `.answer` only if addressed to Dee (her name wakes her) → exact reply; `.ignored` → `session.dropUserItem` (deleted from the conversation and the history/seeds). Failed transcript, or none within `addressWait` (6 s) → dropped too. |
| exact rule holds | `waitForWords` | ≤ 0.4 s for the transcript → `host.heard` → exact DNA (with `appraisal.text`) → reply; timeout or failed transcript → fast DNA. A command → `.handled`, no reply, `session.userTurnHandled`. |
| speech started over her voice or < 0.35 s after it (`commandWindow`), no exact rule | `waitForPartial` | ≤ `overlapWait` (0.6 s) for the turn's first settled words (transcription deltas, settled after 0.15 s without a new one): a backchannel → no reply (see below); held words → held; anything else → fast reply at once; none in time → fast reply. The full transcript still runs `host.heard`. |
| otherwise | `respondFast` | DNA now (state + `ProsodyRead`), reply now; the transcript still runs `host.heard` (commands stop the reply through the app's `stop`; `.ignored` takes an unheard reply back and drops the item). |

**Tune 2 (live run 20261009-143612 + A/B).**
- *Exact mode only for DNA.md §4.3's cases.* Speech over her voice no longer waits for the full transcript (p50 0.48 s,
  p90 0.77 s after the commit; 136 of 155 exact waits timed out); it waits for its first settled words
  (`waitForPartial`).
- *Provisional words.* `.userTranscriptDelta`s are accumulated per item; 0.15 s after the last one (live: the burst ends
  p50 0.25 s after the commit, 0.22 s before the full transcript, before her first audio) they are the turn's
  provisional words. They decide floor questions only: `TurnPolicy.held(words)` on a turn whose fast reply is out and
  unheard → `stopVoice`, held (trace `.held`); the full words confirm or overrule (answered at once if they are
  finished). The appraisal and `host.heard` still use the full transcript.
- *Held turns.* `unfinished` also covers "let me" / "lemme" / "let's see" (p20c's transcript was "Let me."), a trailing
  "and" heard as "Ann" / "an" / "end" (t03: "…call my mom Ann."), linking verbs after a noun ("The thing is", "the answer
  is"), "to" outside an elliptical "want to / have to / used to", and prepositions not stranded by a wh-word ("…a lot
  of", "We talked about"). `riddle`: a classic set-up ("What do you call a…", "What's the difference between…") or any
  why/what/how question in an utterance that announced a joke ("Want to hear a joke? Why did the scarecrow…?", j01) is
  held `riddleWait` (1.5 s) for the punchline, then answered.
- *Commands answered fast* (`host.heard` → `.handled`) take back the unheard reply (`stopVoice`).
- *Backchannels (user decision: "keep going" while she talks is not a barge-in).* `TurnPolicy.isBackchannel`: every
  clause a continuer ("keep going", "go on", "don't stop", "I'm listening", "mm-hm", "uh-huh", "yeah", "okay"…), ≤ 8
  words, no question ("really?" aside). Over her voice: if she is still playing, no reply and no stop, the turn is
  released (`userTurnHandled`, trace `.backchannel("continued")`); if her voice was already cut (EarCore decided on the
  sound) or ended, a reply with the note "They want you to go on: carry on from where you stopped, without starting over
  or repeating yourself" (trace `.backchannel("resumed")`). Cut within 3 s after a "continued" one → she carries on too.
- *Spoken preambles.* Her reply's first 7 words (assistant transcript deltas) are checked by `isMetaPreamble` ("let me
  think / respond / check / recall…", "I'll check / save…", "how to respond", "quick save", "let me tuck"…). Before the
  user has spoken again: `stopVoice` (it is cut as it starts), and when its response ends the turn is answered again
  once (kind `retry`) with the note "Answer them straight away; if you use a tool, call it without saying anything first"
  plus, when the toolbox has `recall`, the brain's own `recall` result ("You already looked up what you know about them,
  no need to call recall: …", ≤ 320 chars). A second preamble for the same turn is let be (trace `.preamble(cut:)`).
- *Reply length.* Every voice reply carries `max_output_tokens` = `TurnPolicy.maxOutputTokens(length: dna.guidance.length,
  effort:)`: 280 / 380 / 480 for one / two / three sentences at low effort (+300 at medium, none at high); none when
  exact-mode words ask for a story or an explanation. A response that hits it (`hitTokenLimit`) stops playing at its
  last complete sentence: the unfinished one never starts (trace `.tokenLimitStop`), never mid-word.
- *Turn detection (A/B, same brain and fixtures).* Picked: `server_vad` 300 ms (`CloudSettings.turnDetection`), the only
  config inside the latency gate; it waits on the DeeRealtime seam below and semantic_vad `high` stays live until then.

**Tune 3 (live run 20261009-203321).**
- *Turn detection is live.* `CloudSettings.sessionConfig` sets `RealtimeSessionConfig.turnDetection =
  CloudSettings.turnDetection` (`.serverVAD(threshold: 0.5, prefixPaddingMs: 300, silenceDurationMs: 300)`,
  `create_response` / `interrupt_response` false); `turnEagerness` is unused while it is set. The unfinished-turn holds
  below are unchanged (a commit at every 0.3 s pause is absorbed by them).
- *No post-commit wait in ordinary turns.* The exact rule no longer fires on a loud / intense voice or a stranger's first
  turn (live: 7 of 9 exact waits timed out at 0.4 s, all of the brain's 0.44 s commit → create p90); loudness rides in
  the fast DNA's prosody line. Remaining waits: the exact rule's word-dependent cases and `waitForPartial` (speech over
  or right after her voice).
- *Reasoning effort.* Ordinary turns ask for `RealtimeBrain.ordinaryEffort` = `minimal` (`effective(_:)` maps
  `ThinkingMode.chatEffort` to it; thinking efforts are kept; the session default is the same). Live create → first
  audio followed reasoning tokens, not DNA size: 0 tokens 0.44 s p50, 40–99 0.72, 100–199 1.06, 200+ 1.64 s. Text eval:
  mean reasoning tokens 30 vs 50 (low), first text p90 0.47–0.62 s vs 0.67–0.93 s, narration before tool calls 4–7 vs
  13 of 64. An ordinary fast turn is never re-asked for its words (`answeredAt` counts `minimal` as the chat effort).
- *Backchannels: one rule.* `TurnPolicy.isBackchannel` is DeeVoice's `Backchannel.isBackchannel` (hums: "MMHN.", "HM.",
  "mm", "uh-huh"; live F4: the brain's own copy answered both after the voice resumed her).
- *Floor holds (CloudVoice `holdEvents`).* `.resumed(itemIDs:)` → each unrequested item is released
  (`userTurnHandled`, trace `.backchannel("resumed-<why>")`) and never answered; a commit of an item the voice already
  settled (`wasBackchannel(itemID:)`) → released at once (trace `.backchannelReleased`); a `waitForPartial` item in
  `voice.floorHold?.items` is not answered blind at `overlapWait` (re-checked every tick, at most `holdLimit` 6.5 s
  after its commit); a backchannel the brain recognises calls `voice.continueAfterBackchannel()`. `.ended(byVoice:
  false)` (the brain's answer cut the hold, so the voice emitted no `.bargeIn`) → `host.bargedIn()` (trace
  `.bargeInSensed`): the app senses `Percept.bargeIn` without stopping anything; `byVoice: true` was announced by the
  voice (`.bargeIn` → the app's `stop()`).
- *Narration in any sentence.* The reply transcript is split into sentences (`TurnPolicy.sentences`); the first is checked
  with `isMetaPreamble` (tune-2 path: cut + one retry), every later one with `isNarration` (talk about answering,
  looking up or saving: "Let me think about how to respond.", "Let me check what I remember", "I'll note that"; not
  "Let me think of another one!" / "Let me think about it with you."). A later one stops her when that sentence starts
  (`sentenceStarted`, trace `.narrationStop` then `.preamble(cut: true)`); what she said stands, no retry.
- *Host.* `BrainHost.bargedIn()` (default no-op); `StandaloneHost.modeSignalsOverride` and `bargeIns` for tests and the
  harness.

**Turn detection and unfinished turns (tune 1).** The session runs `semantic_vad` at
eagerness **`high`** (`CloudSettings.turnEagerness`; 2 s cap). Live, `auto` held plain turns
0.6–1.0 s past their last word and 3–4.5 s after a punchline or filler — the main latency
gate (p50 ≤ 1.1 s) cannot pass with that. `high` can commit "Hold on." or "I had pasta,
and…" as a turn of its own; the brain absorbs that. When `host.heard` says `.answer` and
`TurnPolicy.unfinished(text)` is:
- `holdOn` (the whole utterance is "hold on", "one sec", "let me think", repeated or with
  fillers/her name): never answered; an unheard reply to it is taken back (`stopVoice`);
  `userTurnHandled`. Trace `.held("holdOn")`.
- `trailing` (ends in "…", a dash, or a word a sentence does not end on: and, but, or,
  because, um/uh/er, the, a, an, with, my, your; "and then"): an unheard reply is taken back;
  the utterance is held. The next commit answers both (both items are in the
  conversation); with nothing more for `trailingWait` (3 s, extended while they talk) it is
  answered (exact mode). Trace `.held("trailing")`.
A question mark or exclamation is never unfinished. A reply already audible is never taken
back. The session also cancels a reply with no audio yet when they go on talking
(`cancelUnspokenReplyOnSpeech`).

Exact rule (`TurnPolicy.exactModeWanted`, DNA.md §4.3): repair ∈
{strained, ruptured, repairing}; the previous DNA issued a follow-up, `deixisAmbiguous` or
`misread` note; a stated hypothesis or live distress. (Tune 2: speech over her voice is no
longer exact; it is `waitForPartial`. Tune 3: a loud voice and a stranger's first turn are
fast.)

Never: `stopSpeaking` on the user-utterance path except to take back an unheard reply to
speech that was not for her or is unfinished, or a late "think hard" (commands stop her
through the app); a re-request on `.replyPreempted` / `.initiativeCancelled` (the session
re-requests after an echo itself).
A request refused with `.responseInFlight` is retried once after that response's
`.responseDone` (kind `retry`, keeping exact mode's words and appraisal); the utterance is
kept until then. On `.replyPreempted` / `.initiativeCancelled` the brain renders a fresh
`retry` (or initiative) DNA and `replaceDNA`s it at once, so the session's own re-request
(after an echo, §4.1 "Echo rejection") carries it (not for a canned line). `cancel()`
(barge-in) never drops user utterances; `cancel(hush: true)` drops those finished before it
(and releases them: `userTurnHandled`). `.disconnected`, `.rolledOver`, `.recovered` forget pending
utterances (their audio is not on the new connection). `waitBeforeAnswering` (an `interruptedThem` lesson) adds a
0.7 s beat before `response.create`; if they are talking by then, their next commit is
answered instead. Thinking: the brain owns `ThinkingMode` per conversation; fast replies
use `effortBeforeWords`, exact ones `turn(for:)`; a late "think hard" re-asks (stop +
exact, higher effort) while nothing of the fast reply was heard.

**Tune 5 (live run 20261010-003257; probes 20261010-011423 / -011624; `tune4-live.md` F1–F7).**
- *A question asked over her is answered (F1, HIGH).* When the brain's answer ends the voice's floor hold, `host.bargedIn()`
  is called, and the host now senses **`Percept.bargeInAnswered`**: FloorKeeper's barge-in bookkeeping (cut off,
  yielding, Dee-interrupted, the cut-off note) without `.stopSpeaking`. Live, `.bargeIn` → `.stopSpeaking` → the app's
  `stop()` cancelled that very answer (0 of 3 interrupting questions answered; 3 of 3 with the stop skipped).
  `DeeModel.bargedIn()` and `StandaloneHost.bargedIn()` sense it; `.bargeIn` (the voice's own barge-in) still stops her,
  and a spoken "stop" still stops her through the command path (`StandaloneHost` now stops as the app does:
  `stopVoice` + `cancel(hush: true)`).
- *Release gate (F2/F3).* The speculative reply plays once all hold: `confirmWindow` (0.8 s) of quiet measured from the
  later of the server's end of speech and EarCore's last voice frame (`voice.lastUserVoiceAt`); their voice not active
  now (`voice.userVoiceActive`: EarCore's 0.15 s, bed-proof voice flag — no longer the 0.6 s latched `userIsSpeaking`,
  which kitchen and TV beds kept on); and words not still settling — unless the final transcript has come and is
  complete (`wordsFinal`: the commit and the final words agree). The gate must pass twice, `releaseRecheck` (0.12 s)
  apart, before she plays (l05: released 0.15 s after they resumed). Unsettled words hold her at most `confirmMax`
  (**1.0 s**, was 1.6) after the commit; their own voice at most `confirmMax + voiceHoldExtra` (1.6 s).
- *Stranded prepositions (F4).* "I didn't get the job I interviewed for." is complete: a determiner's noun phrase, a
  subject pronoun, 1–3 words, the preposition, and the transcript's closing period (`TurnPolicy.strandedInRelative`).
  "We talked about", "Yesterday I went to." and anything without the period still trail.
- *Continuers over her (F6).* Over her voice (in a hold, started over her, or one she went on through) words are
  classified by `voice.isHoldBackchannel(itemID:text:)` (in `provisional`, the backchannel re-check, and a new check
  before an unrequested item over her is answered): "Sheep going.", "I'm listening." are never answered.
- *The unfinished-words aim is never heard.* Her reply transcript is checked as it streams
  (`TurnPolicy.isUnfinishedAim`: "finish the sentence", "you trailed off", their words quoted back with "…"): in her
  first sentence the unheard reply is taken back and their turn held as trailing (their next commit answers both;
  nothing within `trailingWait` → answered with `unfinishedAnswerNote`; the aim a second time → she stays quiet); in a
  later sentence she stops before it. Trace `.unfinishedAim(takenBack:)`.
- *Punchlines (F7).* A reply to the turn after a riddle's set-up, or two after "Knock knock", carries
  `TurnPolicy.punchlineNote` ("laugh first … never explain it").

**Tune 4 (live run 20261009-224148; A/B 20261009-235320/-235323/-235326, confirmation 20261010-001323).**
- *Speculative reply with gated playback (`Options.speculative`, default on).* The reply to a fresh voice turn is still
  requested at the commit, so it costs no latency. Right before `requestResponse` the brain calls
  `voice.speculate()` (CloudVoice tune 4: the response's audio is buffered in the player and never heard), unless another
  response is in flight (`speculationSkipped(busy:)`). Trace `.speculated`.
  - **Release** (`voice.releaseSpeculative()`, trace `.speculationReleased(heldMs:quietMs:overdue:ready:)`): once
    `confirmWindow` (**0.8 s**) has passed since the end of their speech, nobody is talking by the voice's own ear
    (`voice.userIsSpeaking`: their voice in the last 0.6 s, or the server's speech open), and settled transcription
    deltas are not still arriving.
    - The end of speech is the server's: the commit time − `commitLag` (0.25 s), since server_vad commits after its 300 ms
      of silence.
    - A voice that the server never calls speech holds the reply at most `confirmMax` (1.6 s) after the commit.
    - A reply asked for once the window has already passed is not gated (`speculationSkipped(late:)`).
  - **Drop** (`voice.discardSpeculative()`, trace `.speculationDropped(why)`):
    - `"speech"`: a new server `speech_started` (another item) while it is held. The turn is held (`resumeWait` 2 s,
      postponed while they talk), and their next commit answers both parts (`committed` releases held items with
      `userTurnHandled`).
    - `"taken back"`: every unheard take-back (settled words unfinished or a riddle, a command, not for her, a rethink, a
      preamble) discards a held reply instead of cutting it: nothing is truncated beyond the voice's cancel and
      truncate-at-0.
    - `channelUnheard` is true while held.
    - After a drop the next request waits out `stopGuard`, as after a stop.
  - **Voice-side ends** (`.discarded(byVoice:)` other than `"rearmed"`) clear the brain's speculation. A response that
    ends cancelled or failed before any audio releases it, and so does a channel that closed. A non-speculative request
    while the voice is still armed releases it first, so the voice never holds what the brain will not release.
  - Why the brain does not use its own energy VAD: in the first A/B its pitch-gated `ProsodyTap` end read 0.6 s early on
    TTS voices, so 128 of 128 releases came before any audio.
    - Without the pitch gate, a kitchen bed read as one long voice: 7 overdue holds, filler p50 2.13 s in the
      confirmation run.
    - In a fan bed most speech was missed.
    - EarCore (`userIsSpeaking`) showed no false frame over the kitchen, fan and TV beds at 15 dB SNR.
  - Window choice: the live A/B ran 500/650/800 ms, but the gate never held audio there (the bug above), so the
    windows were compared on every turn of the four runs (309 turns): ground-truth speech spans, recorded first-audio
    arrival, and resume detection 80 ms after onset.
    - Her first audio arrives ≥ ~1.0 s after the end of speech on nearly every turn, so any window ≤ 1.0 s left end →
      first audio unchanged (p50 / p90 1.17 / 1.53 s on tune 3).
    - Collisions fell from 10 to 4 at 500 ms, 3 at 650 and 2 at 800. A 1.2 s window raised the p50 to 1.24 s.
    - The two left resumed 1.04 s after the end (j01's punchline), which is now a riddle hold.
- *A joke announced one turn earlier* (`TurnPolicy.held(_:after:)`, `isRiddleSetUp(_:after:)`): server_vad commits "Want
  to hear a joke?" on its own. A why/what/how set-up whose previous user turn (≤ 20 s) said joke or riddle is a riddle
  hold: the held reply is taken back and the punchline is theirs.
- *Sentence cap* (`Options.sentenceCap` 3): she stops before sentence 4 of a reply (trace `.sentenceCapStop`, never
  mid-word). Not for a story or an explanation (`wantsLongAnswer` on the words, also when they arrive after a fast
  reply), not in thinking mode, not for canned lines.
- *Token caps at `minimal`:* 240 / 340 / 440 for one / two / three sentences (`low`: 280 / 380 / 480).
  - Live tune 3 output tokens p50 / p90: two sentences 220 / 303, three 245 / 341, four 287 / 459.
  - Tighter caps cut good replies before they cut long ones: at 300, 23 of 152 replies of three sentences or fewer would
    lose a sentence, and 8 would still run over three. So the cap is a backstop. The DNA v5 Length line does the work.
- *Greeting kept until heard:* the brain counts replies of hers with a heard sentence this conversation
  (`heardReplies`, reset by `newConversation`) and passes it in every `TurnContext`. DNA v5's G5 holds until one was
  heard.

## DNA delivery (DNA.md §4)

`buildDNA`: `host.dnaParts(DNARequest)` (the host calls `Cortex.cue(at:)` first unless the
turn is a Cortex initiative, whose issued notes it kept) → `DNAAssembler.assemble` →
`DNAPrompt.render(_:guard:)` with the session corpus → host notes (people layer, fixed
templates and names only) inserted as "Keep in mind:" lines in section 7 → ring sample.
The text goes with the request: `session.requestResponse(dna:reasoningEffort:)` for replies
(typed turns: `session.addUserText` first; dropped again if the request fails) and
`session.initiative(dna:)` for initiatives. The session sends "create new (`dna_{tag}_{n}`),
delete previous, plain response.create" in one actor turn. Replies and initiatives never
carry `instructions` (D6). Tool follow-ups and the session's re-requests reuse the live DNA;
after `forget` the brain re-renders and `replaceDNA`s it before the follow-up. A new
connection (reconnect, rollover) starts with no DNA, and a response there without its own
gets the last one. A refused DNA create holds its response back (no sound) and resends it
behind the previous DNA under a fresh id (`dna_rejected` if there is none): **no response
ever runs without a DNA** (tested on the wire: `noResponseEverRunsWithoutADNA`,
`aRefusedDNACreateNeverLeavesAReplyBare`).

**Around a request (what CloudVoice's `respond`/`initiative` did).** CloudVoice has no DNA
entry point, so the brain calls the session directly and does the rest itself: a reply
still playing is cut first; no request goes out within `Options.stopGuard` (0.3 s) of a stop
of her voice made by the brain or the app (`RealtimeBrain.stopVoice()`; CloudVoice's reply
gate keeps a response starting < 0.25 s after a stop silent, and the stop's cancel must reach
the session first); the timeline gets `response_create_sent`; initiatives and canned lines
are refused while `voice.userIsSpeaking`, while her voice plays or within 0.4 s of its end,
and are taken back (`stopVoice`, trace `.yieldedToUser`) if the user starts before their
first audio. People-layer notes are added only
outside a minimal DNA and within the 1400-token cap. With "Share memories" off the brain
also drops `recall` / `gagCallback` notes and the running-joke hooks (§1.6).

**Conversation (the session's ledger).** Dropped items: `session.dropUserItem` (deleted,
removed from `recentTurns` and so from every seed; an unheard reply to it cancelled).
`newConversation` (start over, after a long sleep): `session.resetConversation(keeping:)`
(all but the live DNA and the turn being answered; history and `lastSummary` cleared). The
rollover summary never reads a DNA (session). Turns left unanswered on purpose (commands,
hush, hold-on) are released with `userTurnHandled` so they do not hold a rollover. Canned
lines (`brain.say`) go out of band through `session.say` (kind `.say`: `conversation:"none"`,
`input: []`, "Say exactly …" plus the last DNA's `Voice:` line, no DNA, no history line, no
truncate), are not reported to the host as replies, and return `.played / .cut / .refused`.

## Channels (replies the app sees)

Each request has one `AsyncThrowingStream<ReplyEvent, Error>`: `respond(_:)`'s for app
requests (initiatives, event lines, typed text), and `host.brainStartedReply` for spoken
turns. Events: `.content(sentence)` at `.sentenceStarted`, `.sentenceFinished(text, heard:)`
at playback, `.toolCall`, `.messageCompleted(heard text)` per item, `.turnCompleted` once the
response is done, its audio played out and no tool follow-up is pending (tool wait 4 s,
renewed when a slow tool finishes, never expiring while one runs; safety 20 s after done
unless an item is still playing, 300 s absolute). Initiatives are refused while a tool runs.

## App wiring (DeeModel)

- `init`: `CloudSettings(defaults:)` → `RealtimeSession(config: settings.sessionConfig(),
  auth:)` (default socket factory), `CloudVoice(session:clips:)`, `ClipCache(voice:keyStore:)`.
- `start`: key intake → `prepareClips` (when a key exists; `removeOtherVoices` after a
  voice change) → `RealtimeBrain(voice:host: self, toolbox:)` → `brain.start()`
  (instructions + tools + tool handler) → `voice.start()`.
- Stops of her voice go through `realtime.stopVoice()` (so the brain's next request waits
  out the stop).
- Foreground: key intake, settings (share memories → `setToolbox`; voice/model → notice,
  next launch). Background: `brain.backgrounded()` (corpus and prosody frames cleared).
- `.heard` voice events only close the floor; the words come through `heard(_:)`.
- AI-voice disclosure: the caption shows at the first AI audio (reply, laugh, canned line);
  the line is said through `brain.say` at the next quiet moment after a turn, and the flag is
  stored only once it was `.played`.
- Privacy: `recall`/`forget` results never carry sensitive facts (`PrivateFactsFilter`);
  `where_am_i` never sends coordinates; the key check uses an ephemeral, cache-less session
  and the Settings field is kept if the Keychain refuses the key.
- `RootView` status chip: `cloudStatus` (Release too), notices, the disclosure; the face
  takes a softer, tilted, grey-blue look while the cloud is off.

## Open asks

- **Voice harness (tune 5):** `HarnessHost.bargedIn()` must sense `.bargeInAnswered` (not `.bargeIn`) for app parity;
  with `.bargeIn` the parity stop still cancels the brain's answer. Add content barge-ins (`expect: reply`) and a
  "Stop." over her (`expect: silent`) to the regression suite.
- **Live (tune 5):** watch `.speculationReleased` held time in kitchen15 / tv15 (cap now 1.0 s), `.unfinishedAim`,
  answered barge-ins, and the follow-up position in followup-dentist.

- **DeeVoice (tune 4):** expose EarCore's last near-end voiced time (`lastUserSpeech`). The gate reads
  `userIsSpeaking`, which holds for 0.6 s, so the window cannot go below ~0.65 s, and the end of speech is taken from
  the server's commit. Optional: a `.speculative` mark in TurnTimeline, so the harness can show held time per turn.
- **Voice harness (tune 4):** the reply-length gate counts the generated transcript, so a reply the sentence cap stopped
  still counts its unheard 4th sentence. Count heard sentences (`heardSentences`), or count both.

- **DeeRealtime / DeeVoice (tune 2):** done in tune 3 and adopted (`turnDetection`; floor holds, `holdEvents`,
  `wasBackchannel`, `continueAfterBackchannel`, `Backchannel.isBackchannel`).
- **Voice harness (tune 3):** `DeeBrainAdapter` may implement `bargedIn()` to count barge-ins sensed from the brain's
  answer; its `BodyInputs(lastContact:)` is now overridden by `Cortex.lastContactBeforeConversation` inside
  `dnaInputs`, so nothing to change for the reunion line.

- **DeeRealtime:** done in tune 1 (DNA lifecycle, `dropUserItem`, `resetConversation`,
  `say`, `addUserText`, unanswered hold) and adopted. The session's `TraceRecorder` records
  DNA text: pass no trace in Release (the app passes none).
- **DeeVoice (new, tune 1):** DNA entry points on `CloudVoice` — `respond(dna:maxOutputTokens:
  reasoningEffort:)`, `initiative(dna:…)` and an out-of-band `say(instructions:)` that do
  what `respond` / `initiative` do today (cut a playing reply, `gate.requested()`, timeline
  mark, local refusal and `initiativePending` early cancel) and call the session's DNA
  APIs in CloudVoice's command order. The brain then drops its own `stopGuard` wait,
  refusal checks and `speakFirst` take-back. Also: expose EarCore's prosody of the
  committed window, so `ProsodyTap` can go.
- **Voice harness:** drop `DNAWire` and use `RealtimeBrain(voice:host:…)` (deprecated
  shims compile with warnings); latency counted from the end of a held turn's continuation
  still applies.
- **DNA owner:** a formal slot for people-layer notes (`DNAInputs.extraNotes`).
