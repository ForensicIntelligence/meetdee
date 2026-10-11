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

### Tune 6 (live run 20261010-020243, `tune5-live.md`)

- **Interrupting questions: exactly one answer (T5-2).** The 4 unanswered questions all had the same cause, verified on
  the wire: the voice's hold committed the burst early, the server ended "the rest" as a new item with no
  `speech_started`, and `RealtimeSession.openSpeech` stayed on the committed item, so the session's "never start talking
  over someone" gate preempted the answer and its retry at their first audio. That is DeeRealtime's to fix (patch:
  `scratchpad/tune6-voice-realtime-openSpeech.patch`). The brain side, made impossible:
  - A *tail* — a commit whose `speech_stopped` came with no `speech_started` of its own, within
    `CloudVoice.holdTailWindow` of the commit before it, or in the voice's `floorHold.tails` — is no turn (trace
    `.tailIgnored`): never answered blind, never absorbs held turns, let go silently (`userTurnHandled`). Its words, if
    any come, are handled like any turn's.
  - A request with another response in flight never touches her voice: `reply()` cuts a playing reply only when
    nothing else is in flight, and `stopVoice()` clears `playing` at the cut (live, a stale `playing` would have
    "cut" nothing again and closed the reply gate on the answer).
  - One answer per turn (`coveringReply`, trace `.covered`): a turn is not asked for, nor retried after a refusal, when
    a reply asked for after its commit (the model hears it) is in progress or was heard. Taken-back replies
    (`Channel.takenBack`: `takeBack`, `speculationResumed`, a voice discard) cover nothing.
  - The `retry` DNA for a preempted reply is re-rendered at most once a second without new speech.
- **The release gate (T5-1, T5-4, T5-6).** Every reply is gated (`speculationWanted` never skips: a late exact reply
  or a retry measures its caps from its request). The quiet run (`Speculation.quietSince`: no voice now, no server
  speech of a newer item, `confirmWindow` since their last voice) is tracked from the request, so the 0.12 s re-check
  is already met when her audio arrives (live p50 1.17 → 1.26 s came from starting it at audio-ready). The gate is
  let go only once her first audio is in. While the server hears a newer item of theirs (`openServerSpeech`, closed by
  any `speech_stopped` or its commit), no reply is asked for: the turn is held (`.held("speech")`) and their next
  commit answers all of it; if that commit turns out not to be a turn for her (not for her, a backchannel), the
  newest held turn it took over is answered after all (`restoreAbsorbed`).
- **Interrupt answers (T5-3).** After a cut of her *playing* reply a speculative request waits only until the session
  has taken the cut (`session.state` leaves `speaking`/`cancelling`, at most `stopGuard`), not a fixed 0.3 s; the
  reply gate needs no guard there (`speculate()` marks the request). Asking at the commit while the hold is open needs
  a voice path that ends the hold and keeps the speculation (open ask below).
- **Fragments (T5-4).** "D.", "I.", "Dee.", "Hey, Dee." are `.trailing` (`TurnPolicy.isFragmentOrAddress`; "No.",
  "OK.", "Dee?" are turns) and wait `fragmentWait` (1.5 s) for the rest. "I had pasta for dinner. And." stays
  trailing.
- **Never heard (T5-4, T5-8).** The unfinished-words aim is matched by meaning (`unfinishedAimMeanings`: did they mean
  to say something, is she waiting / listening, only her name; not when it is about someone else: "say *to* her").
  A sentence that sends them to an app, a clock, a forecast, a calendar or a search (`isAppReferral`) is taken back in
  her first sentence (asked again once with `noAppNote`) or stopped before later (trace `.appReferral`).

### Tune 7 (live run 20261010-035320, `tune6-live.md`)

- **The answer belongs to the question (T6-1).** Every reply names the turn it answers
  (`requestResponse(dna:…, answering: item)`, the channel's user item), never whatever the server committed last.
  Live (interrupt-clean q02, interrupt-fan15 q08) the answer was asked for just after the server committed an empty
  tail of the same burst; keyed to that tail, the voice's drop of it cancelled the answer. Taking a tail away (dropped
  empty, rejected as her echo, not for her) now never touches the question's answer. DeeRealtime (tune 7) adds the
  parameter and keeps a reply whose dropped item said nothing.
- **Misheard short fragments over her are backchannels (T6-3; decision: backchannels continue her).** While she
  talks (over her voice, her reply playing or paused in a hold), one or two words that are not clearly a stop ("Stop.",
  "Wait.", "No.", "Hold on."), a question ("Why?", "Who made…"), her name or a letter ("Dee.", "D."), a number or a
  two-word sentence about them or her ("I'm bored.", "Love you.") are a backchannel (`TurnPolicy.isMisheardFragment`,
  `goOnWords`): "Put going.", "Grand.", "She.", the tail "Done.". Over her voice the early words decide only from three
  words, or two that ask ("Who made", "Are you"); one or two wait for their settled or full words. The same rule for the
  voice's hold is `scratchpad/tune7-brain-to-voice.patch` (`Backchannel.isBackchannel(_:inHold: true)`).
- **The sentence budget (T6-6).** She stops before the sentence past the turn's own budget
  (`TurnPolicy.sentenceBudget` of the DNA Length line: three → 3, two or one → 2; never more than `sentenceCap`; not for
  a story, an explanation or thinking mode). Every sentence the voice plays counts, a short exclamation too.
- **Never a robot's report (T6-7).** A sentence that frames her words as a robot's report or status
  (`TurnPolicy.isSelfReport`: "Tiny robot report: …", "Status update: …", "Beep boop") is taken back in her first
  sentence (asked again once with `noReportNote`) or stopped before later (trace `.selfReport`).
- **Early request at the local end of speech (T6-5): tried on paper, not kept.** Tune-6 live: end of speech → commit
  p50 0.51 s (n = 153); a request at EarCore's last voice + 0.25 s would save ≈ 0.2 s, but the release gate (0.8 s quiet
  + 0.12 s re-check ≈ 0.92 s) would then be the only thing holding her where today the audio itself comes at ≈ 1.15 s.
  joke-echo30 j01 (punchline 1.04 s after the set-up) falls in that window: today the resume holds her; with the early
  request she would play over the punchline. And 90 of 253 within-turn pauses (0.28–0.45 s) that the server does not
  split today would be split by the client commit. DeeRealtime's `respondToSpeech` stays available.

### Tune 8 (live run 20261010-063215, `tune7-live.md`)

- **One misheard-fragment rule (T7-1).** `TurnPolicy.isMisheardFragment` is DeeVoice's
  `Backchannel.isMisheardFragment`; the brain's own looser list is gone. Live (interrupt-fan15 q08) "Who made you?" over
  her came back as "Too late."; the brain's rule took it for "go on" (she talked on to her sentence cap) and the voice's
  would not. "Too late." / "Big deal." over her are turns now. A carry-on ("go on from where you stopped") answers no turn
  (`Channel.carryOn`, never `coveringReply`): when the full words of an item first taken for "keep going" are more, the
  unheard carry-on is taken back and the turn gets exactly one answer.
- **Continuer endings never decide early (T7-2).** Over her voice, early words never decide on a partial whose last word
  ends a continuer (`TurnPolicy.endsLikeContinuer`: going/goin/on/listening/listen/ahead, a hum): echo20 c05 "Sheupr
  and going." was decided at once (3 words) and cut her. "I'm listen." (fan15 c05) is a cut-off continuer under the
  voice's rule, so its full words are "go on".
- **No carry-on over a newer turn (T7-3).** A cut of her voice after a backchannel she talked on through brings a
  carry-on only when no newer turn of theirs is being answered or decided (`newerTurnPending`). Live (interrupt-echo20
  q02) the answer to "Are you awake?" cut her; the phantom "Yeah." then got a carry-on, refused, retried when the answer
  completed — the retry re-armed the gate and threw the held 3.9 s answer away (0.9 s lost).
- **Their question answered, never said back (T7-4 / T7-6, DNA v9).** A first sentence that only repeats their words
  (`TurnPolicy.echoesTheirWords`: "Hi Alex, who made you?") is taken back unheard and asked again once with
  `answerFirstNote` (trace `.echoedQuestion`). "I heard you say" is a preamble (first sentence) / narration (later). A
  question asked over her voice carries `answerFirstNote`.
- **`respondToSpeech` (T7-5): measured, not wired.** Tune-7 traces: the server's `speech_stopped` → `committed` is
  p50 1 ms / p90 2 ms (n = 380), so a request at `speech_stopped` saves nothing. The ~74 ms commit round trip exists
  only for the voice's own quick commits in a hold (n = 19), where the reply waits for the words by design (an early
  request there brings back the backchannel stops). The brain's commit → request is 0.00 / 0.02 s.
- **Turn detection (T7-5): kept at server_vad 300 ms.** Projection from the tune-7 report (energy gaps between voiced
  spans vs. the server's splits: every gap ≥ 0.38 s split, nearly none below, so the server splits at about silence +
  0.08 s): 250 ms adds 35 splits (gaps 0.33–0.37 s, all `turn` lines), 200 ms adds 50 (also the joke set-up j01 0.30 s
  and the continuation k01). Each is caught by the speculative gate (their voice is back ≤ 0.37 s after the end; the gate
  holds ≥ 0.67 s; tune 7 caught 143 such splits — `speculationDropped("speech")` — with 0 collisions), at the cost of a
  discarded request each (≈ +$0.07 / +$0.10 a run). Latency gain is the silence saved: p50 1.27 → 1.22 s (250) / 1.17 s
  (200), p90 1.40 → 1.35 / 1.30 — neither reaches the 1.1 s p50 target, whose remaining share is the model (create →
  first audio 0.62 s p50). Recommendation: an A/B live run at 250 ms before any change.

### Tune 9 (live run 20261010-080526, `tune8-live.md`)

- **A question taken for "go on" first gets exactly one answer (T8-1).** Live interrupt-echo20 q08 "Who made you?" came
  back as "Movie." and the one fragment rule took any single word as "go on": `continued`, then the final words (verdict
  "answer") were let go as "go on" too. The rule is now the voice's sound-aware one (`CloudVoice.isMisheardFragment(itemID:
  text:)`, voice patch applied): a word the words don't know is "go on" only if it *sounded* like a backchannel. Brain
  half: when the full words of an item she talked on through are a turn, its answer's own cut of her voice is no "cut
  anyway after keep going" (`continuedThrough` cleared; `newerTurnPending` counts an answer to that same item) — before,
  that asked for a carry-on for the same item, refused, then sent after the answer: two replies to one turn.
- **Server stalls (T8-2).** The session no longer gives a request up at 2.5 s (`responseTimeout` 10 s backstop;
  `cancelUnstartedWait` 2.5 s keeps the old close of an unstarted cancel): a late `response.created` is accepted and
  plays (live 3.56 s and 9.59 s stalls each lost a turn). The brain: past `slowAfter` (2.5 s) with nothing started, a
  thinking sound (`slowClip` `.oneSec`, once, nobody talking, nothing of hers playing; trace `.slowResponse`); past
  `stallRetryAfter` (8 s, or the voice's own 8 s speculative timeout), the stalled request is cancelled and the turn
  asked for once more (`retryItem` path, kind `retry`; trace `.stalled(retried:)`) — only if it is still current (no
  newer commit or request of theirs, nobody talking), never twice per turn, never for a carry-on.
- **Tails and carry-ons (T8-3).** A tail of a burst that was a backchannel whose words are a number, a lone letter,
  nothing or one "go on" word (`TurnPolicy.isNoiseTail`: "10." after "MMHN.") is dropped from the conversation, never
  answered (trace `.backchannel("tail")`); a tail that asks or stops her is still a turn. A held turn a carry-on took
  over is not restored once that carry-on was asked for (live echo10 c02: the restored "…stop." cut the carry-on at
  840 ms and a second carry-on played): one carry-on per hold. Early words over her never decide on a partial that
  breaks off on a comma or an article/conjunction (`TurnPolicy.breaksOff`: "That's like a,"); a partial that asks
  ("Who made", "Can you tell me,") still does.
- **Thinking aloud, "I heard you", two messages (T8-4 / T8-5, DNA v10).** Thinking aloud is narration in any sentence
  (`thinkingAloudPatterns`: let me think / see / take a moment / settle, give me a second…); in a later sentence of an
  unheard reply to a question it is taken back and asked again once with `answerFirstNote` (`.thinkingAloud`), else she
  stops before it. A sentence opening on hearing them (`TurnPolicy.opensOnHearingThem`: I heard/hear you/your, I can
  hear you; not when they asked whether she can hear them) is taken back in the first sentence (`noHeardYouNote`,
  `.heardYou`) or stopped before later. A second message item of one response is never played (`.secondMessage`,
  `.secondMessageStop`).
- **Latency.** The gate's quiet run counts from when it began (`confirmWindow` after their last voice, never before the
  server's speech closed), not from the tick that first saw it; tick 0.05 → 0.02 s. Replayed on the tune-7/8 releases:
  held p50 80–100 → ~30 ms (+ ≤ 20 ms tick), p90 220 → ~150 ms. The window itself is unchanged: counting it from
  commit − 0.35 s released a resume 0.76 s after their end (Tune5 test), so `commitLag` stays 0.25 s. The server VAD
  silence is a setting (`CloudSettings.vadSilenceMs`, default 300): the live operator A/Bs 250 ms with
  `DEE_VAD_SILENCE_MS=250` (the harness builds its session with `CloudSettings(voice:model:)`; 200–800 accepted).

### Tune 10 (live run 20261010-102105 + solo -111224, `tune9-live.md`)

- **Every "go on" continues her (T9-1).** Live kitchen15 c02: "Don't stop." went on (`continued`, the voice deferring the
  go-on while they talked), then the server's tail "Keep going." took the tune-9 tail drop and returned without a go-on;
  the kitchen bed kept the voice's own quiet check false and it cut her at its deadline. `continueHer(items…)` now calls
  `continueAfterBackchannel()` on every decision that their words were "go on" while she is paused for them: the tail
  drop (the tail or its parent in the hold) and full go-on words of an item already taken for a backchannel (a deferred
  go-on is renewed, never left to the voice's deadline). No hold of that item: nothing (she talks on, or a carry-on was
  asked for). The voice half (echo10 c05, `holdAfterWords` after the brain's deferred go-on) is the voice owner's
  tune-10 change: a deferred go-on clears `wordsAt`. Early words use the voice's sound-aware fragment rule
  (`CloudVoice.isMisheardFragment(itemID:text:)`), as `goOnWords` does.
- **A turn survives a rollover (T9-2).** Solo rollover-speech q08: a take-back's retry went out on the new session
  (behind its seed and a fresh DNA) and the brain's `.rolledOver` handling discarded it (cancelled 1 ms after
  `response.created`). The session switches only with nothing in flight and reports the old connection's responses done
  before `.rolledOver`, so a reply still live there was asked for on the new session: `forgetPendingTurns(keepAsked:)`
  keeps it.
- **A stall cancel settles before the next request (T9-4, DeeRealtime).** When the watchdog closes a request cancelled
  before it started (`cancelTimeout + cancelUnstartedWait`), the session first sends `response.cancel` with no id: the
  server takes events in order, so a create still in its queue (fillers-echo10 f04: started 9.5 s late) is cancelled
  before the next request, which no longer fails with `conversation_already_has_active_response`. Nothing active: the
  server's `response_cancel_not_active` is ignored.
- **Thinking aloud and "I heard…" (T9-6 / T9-8).** Thinking aloud counts anywhere in a sentence (`TurnPolicy.thinksAloud`;
  l06 had "let me think" at words 7–9 of her only sentence): in her first sentence it is a preamble (cut, asked again
  once). Later sentences are unchanged (a question: taken back; otherwise she stops before it, keeping the answer she
  gave, e.g. the k05 laugh). A complete first sentence opening on "I heard…" / "I hear…" of any kind is taken back
  (`noHeardYouNote`), still not when they asked whether she can hear them; later sentences keep the "I heard you/your"
  patterns. The unfinished-words aim ("I heard “I couldn't sleep last…” …") keeps its own path.

### Tune 11 (live run 20261010-130349 + solo -134832, `tune10-live.md`)

- **The ASR variants of a trailing "and" (T10-1).** Tunes 7–10 wrote "…call my mom and" as "Ann", "Anne", "and",
  ", and", ", then", ", man", or dropped it. `misheardAnd` takes "anne" like "ann"; `misheardAndAfterPossessive` takes a
  last "then"/"man" right after a possessive's noun ("call my mom, then.") unless a linking verb names it ("That was my
  plan then.") or the turn wraps up (okay, fine, guess, well, so, bye, see, later). A dropped "and" ("…call my mom.") is
  not caught: the fixtures' trailing "and" ends on the same falling pitch and energy as a finished sentence (t03 163→103
  Hz, s03 158→103 Hz), so no sound rule separates them without holding finished turns.
- **The release waits for the words (T10-1, echo10 t03).** A held reply whose turn has no words yet (no delta, no
  transcript) waits for them at most `wordsWait` (0.25 s) past the moment it would have played, then `settling` decides
  within the same bound. Settled deltas are checked before the gate in each housekeeping tick, so an unfinished turn is
  taken back in the tick its words settle instead of released first. Live: 6 of 177 releases had no words yet.
- **Early words just after her voice (T10-4, latency).** A turn begun inside `commandWindow` after her voice ended
  (`waitForPartial`) while she is silent now decides on its early words, as over her voice (same guards; the reply is
  gated) — but its settled words are still checked and the gate still waits for them (review: they take back
  "…call my mom, and."; only over her voice do the early words mark them checked). Live: 6 such turns waited for
  settled words (overhead 0.30–0.48 s). The release-gate median (0.02 → 0.08 s) is
  not a tune-10 change: a gate-bound turn's overhead is ≈ 0.68 s − model time (commit − `commitLag` + window + re-check),
  and the model was faster (p50 0.58 vs 0.66 s).

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

- **DeeVoice (tune 8):** the brain now relies on `Backchannel.isMisheardFragment` for every fragment decision (the
  voice's tune-8 rule: reactions, a cut-off continuer, three words ending like one, "Hang on." / "Goodbye." refused). Keep
  it public and keep its doc as the one rule.

- **DeeVoice (tune 7, T6-3):** apply `scratchpad/tune7-brain-to-voice.patch`: the hold's short-burst rule
  (`Backchannel.isBackchannel(_:inHold: true)`) takes a misheard one- or two-word fragment as "go on", so the voice's
  own hold decision and the brain agree ("Put going.", "Grand.", "She.", "Done.").
- **Voice harness (tune 7, T6-6):** the reply-length gate still counts generated sentences; the brain stops her at the
  turn's budget, so count heard sentences too (heard ≤ 3 was 144/145 in tune 6).

- **DeeRealtime (tune 6, T5-2):** done (the `openSpeech` patch is in checkpoint 6ba5e91; the `withKnownIssue`
  wrappers are gone).
- **DeeVoice (tune 6, T5-3):** an "end the hold, keep the speculation" path (`stopSpeaking` / `cutReply` without
  `specCut`, the speculative response's gate kept open, only her old items flushed). With it the brain asks for the
  answer at the hold's commit (≈ 1.1–1.2 s instead of ≈ 1.5 s).

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
