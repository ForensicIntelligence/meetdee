# DeeRealtime — v0.6 contract

**Developer:** Forensic Intelligence

New library product `DeeRealtime` in `Packages/DeeKit` (design step B2). It is Dee's client for
OpenAI's Realtime API, **GA interface** (no `OpenAI-Beta` header), over a WebSocket, model
`gpt-realtime-2.1-mini` by default. Depends on Foundation, Network and Security only: no DeeCore,
no DeeVoice, no app code. Every event and field name was checked against the GA reference
(`developers.openai.com/api/reference/resources/realtime/{client,server}-events`).

Names that would collide with DeeCore are prefixed: `RealtimeJSON` (not `JSONValue`),
`RealtimeToolCall` (not `ToolCall`).

Tests: `swift test --filter DeeRealtimeTests` (133 tests, no network; one suite uses a loopback
WebSocket server). Tune 1 (2026-10-09) added: single-use secrets, the DNA lifecycle (N4/F9),
`dropUserItem` / `resetConversation` / `addUserText` / `say`, unanswered turns vs idle, `HeardRule`.

## The model in one paragraph

Dee keeps the floor. The session runs `semantic_vad` (or the configured `turnDetection`, e.g.
`server_vad`) with `create_response: false` and
`interrupt_response: false`, so the server only **reports** speech start/stop and commits the user's
audio as an item; it never answers or interrupts by itself. The app decides when Dee answers
(`requestResponse`), when she speaks first (`initiative`), when a user onset during her speech is a
real barge-in (`bargeIn`) and when it was her own echo (`rejectEcho`). Audio goes in as PCM16 mono
24 kHz and comes out as `.assistantAudio` events; the app plays it on its own `AudioGraph` and
reports what it actually played, so the server's history always equals what the person heard.

## Setup

```swift
let keys = KeyStore()                                   // Keychain, WhenUnlockedThisDeviceOnly
try keys.save(pastedKey)                                // key sheet; throws .invalidKey for non-"sk-…"
let auth = RealtimeAuth(keyStore: keys, safetyIdentifier: hashedUserID)   // mints ek_ secrets

var config = RealtimeSessionConfig()                    // defaults below
config.instructions = persona + selfBlock + memories + styleRules   // keep byte-stable per session
config.tools = [remember, recall, forget]               // RealtimeTool(name:description:parameters:)
config.voice = .named("marin")                          // fixed for the session's life

let session = RealtimeSession(config: config, auth: auth, trace: debugTrace /* optional */)
await session.setToolHandler { call in … RealtimeToolResult(output: json, followUp: .ifSilent) }
Task { for await e in session.events { … } }            // single consumer, unbounded
try await session.connect()                             // throws RealtimeSessionError
```

`RealtimeSessionConfig` defaults (all `var`):

| Field | Default | Notes |
|---|---|---|
| `model` | `gpt-realtime-2.1-mini` | `gpt-realtime-2.1` for the "full" setting |
| `voice` | `.named("marin")` | or `.custom(id:)`; never resent mid-session |
| `instructions`, `tools`, `toolChoice` | `""`, `[]`, `.auto` | `updateSession(instructions:tools:speed:)` changes them live |
| `eagerness` | `auto` | semantic_vad; `low` waits up to 8 s, `high` 2 s. Used only while `turnDetection` is nil. |
| `turnDetection` | nil | `audio.input.turn_detection` (tune 3). nil = `semantic_vad` at `eagerness`, flags false (unchanged). `.serverVAD(threshold:prefixPaddingMs:silenceDurationMs:idleTimeoutMs:createResponse:interruptResponse:)` or `.semantic(eagerness:createResponse:interruptResponse:)` (or a plain `TurnDetection`). Sent as set; fields of the other mode are dropped (`eagerness` semantic only; `threshold` / `prefix_padding_ms` / `silence_duration_ms` / `idle_timeout_ms` server_vad only); flags left nil are sent `false` (the API default is `true`). `wireTurnDetection` is the exact object sent. A response the server starts by itself (`create_response: true`, or `idle_timeout_ms` running out — any `response.created` without `metadata.dee_turn` while either is on) is cancelled at its `response.created` and its items deleted at its `response.done`: no events, never bound to Dee's request. |
| `noiseReduction` | `.farField` | nil sends `null` (off) |
| `transcription` | `gpt-transcribe`, `languages ["en"]`, `keywords ["Dee"]` | keywords are sanitised (`<`, `>`, line breaks); nil = off |
| `truncationRetention` | 0.8 | `retention_ratio` truncation |
| `speed` | 1.0 | clamped 0.25…1.5 |
| `reasoningEffort` | `low` | nil = server default |
| `maxOutputTokens` | 1024 | per response (replies, initiatives, tool follow-ups). Counts audio at 20 tokens/s **plus** transcript and reasoning tokens, so 1024 ≈ 40 s of speech: a runaway guard only; keep replies short via instructions. A reply that hits it: `.responseDone` `incomplete / max_output_tokens` (`summary.hitTokenLimit`). |
| `safetyIdentifier` | nil | `OpenAI-Safety-Identifier` header |
| `connectTimeout` | 10 s | socket open + `session.update` → `session.updated` |
| `responseTimeout` | 10 s | `response.create` → `response.created`, else `.fallbackAdvised(.noResponse)` (tune 9: was 2.5 s) |
| `firstAudioTimeout` | 6 s | `response.created` → first audio (tool-only responses exempt) |
| `cancelTimeout` | 3 s | `response.done` assumed after a cancel that never closes |
| `cancelUnstartedWait` | 2.5 s | added to `cancelTimeout` for a request cancelled before it started; when it closes, a `response.cancel` with no id goes out first (tune 10, T9-4: a create still in the server's queue is cancelled before the next request) |
| `rolloverAfter` / `forceRolloverAfter` | 50 min / 59 min | see Rollover |
| `rolloverSummary` | `.outOfBand` | `.none` = seed recent messages only |
| `seedMessages` | 12 | "last 6 turns" = 6 user + 6 Dee messages |
| `autoReconnect`, `reconnectDelays` | true, 0.5 1 2 4 8 15 30 s | last value repeats |
| `maxUplinkBacklogBytes` | 192 000 (~3 s) | above it mic audio is dropped + `.congested` |
| `preconnectBufferMs` | 10 000 | mic audio kept while (re)connecting, sent once ready (tune 2: was 2000, shorter than a 429 outage) |
| `preconnectMaxAge` | 3 s | that buffer is sent only if its newest audio is at most this old (else dropped + reported) |
| `carryOverMs`, `carryOverMaxAge` | 20 000, 15 s | an unfinished user turn is replayed into the next connection (see Rollover and reconnect), at most this much audio, only if that connection is live within this long |
| `commitWait` | 8 s | after `speech_stopped` the turn counts as open until its commit (semantic VAD holds), at most this long |
| `rateLimitBaseBackoff`, `rateLimitMaxBackoff` | 1 s, 30 s | back-off for a 429 that carries no hint (exponential, jittered) |
| `cancelUnspokenReplyOnSpeech` | true | user speech before a reply's first audio cancels it — except speech that starts while her audio is still playing (maybe echo: the app decides with `rejectEcho` / `bargeIn`) |
| `estimatedMsPerCharacter` | 62 | starting speaking rate used to place sentences on the audio timeline before an item's audio is complete |
| `calibrateSpeakingRate` | true | learn the rate from completed replies (audio ms ÷ transcript chars at speed 1, smoothed 0.6/0.4; live voices measured 40–82 ms/char); `speakingRateMsPerCharacter` reads it |
| `unansweredHold` | 20 s | a committed user turn nobody answered keeps the session busy (no rollover switch) for at most this long |

Every `session.update` Dee sends always includes `"tracing": null`, `output_modalities ["audio"]`,
`audio/pcm` 24 kHz both ways, and the turn detection above (`wireTurnDetection`). Mid-session
`updateSession` payloads carry only what changed and leave the turn detection alone.

## `RealtimeSession` (actor) API

| Call | What it does |
|---|---|
| `connect() async throws` | Opens, configures, waits for `session.updated`. Returns at once if connected; if an open is in flight (a reconnect, or one unwinding after `close()`) waits for it first, then connects if still needed. On failure emits `.fallbackAdvised`, discards mic audio buffered meanwhile, and throws. |
| `close()` | Closes everything (close code 1000), no reconnect. `connect()` works again afterwards. |
| `feedAudio(_ pcm: Data)` **nonisolated** | For the mic tap thread: queued, appended strictly in order. Use this, not `Task { await appendAudio }`. The queue holds 500 chunks; if the actor falls that far behind, the oldest chunk is dropped and reported where it was (`.uplinkDropped`). |
| `appendAudio(_ pcm: Data)` | Same, isolated. PCM16 mono 24 kHz little-endian. Dropped (and reported, `.uplinkDropped`) while the socket backlog is over `maxUplinkBacklogBytes`. |
| `requestResponse(dna:maxOutputTokens:reasoningEffort:answering:) throws -> RequestOutcome` | **The DNA path (DNA.md §4.1, N4).** Sends back to back: `conversation.item.create` (system message, client id `dna_{tag}_{n}`, tag per connection), `conversation.item.delete` for every older DNA of this connection, then a plain `response.create` (no `instructions`). No waiting, no extra round trip. See "DNA lifecycle". **Tune 7 (T6-1): what a reply answers.** `answering` names the committed user item it answers; nil (default) = every committed user turn not answered yet plus the newest commit, in commit order ("Turn keying" below). Otherwise as below. |
| `respondToSpeech(dna:maxOutputTokens:reasoningEffort:) throws -> RequestOutcome` | **Tune 7: the brain's early request (T6-5).** For user speech still open (or stopped, not committed yet): in one actor turn `input_audio_buffer.commit` (quiet, as `commitUserSpeech`), the DNA, `response.create`. The server handles them in order, so the response sees the committed speech; no wait for `.userCommitted`. The reply answers the **next** user item committed (ours, or the server's if it committed first): until then it has no turn item; that item is not counted unanswered. Nothing open: exactly `requestResponse(dna:)`. A reply in flight: throws `.responseInFlight` and commits nothing (a closing one: queued, still bound to the next commit). The second gate is unchanged: speech still open (by the server's VAD) at the first audio delta preempts the reply; the brain's speculative gate holds the audio until the turn is confirmed. |
| `initiative(dna:maxOutputTokens:reasoningEffort:) -> InitiativeOutcome` | Dee speaks first with a DNA; gating as `initiative(instructions:)`. |
| `replaceDNA(_ dna:)` | Create the new DNA, then delete the old one, now (no response): before `forget`'s tool follow-up, or a `retry` DNA before the session's own re-request. Not connected: becomes the DNA the next connection's first DNA-less response gets. |
| `liveDNAItemID` | The DNA the server confirmed (`conversation.item.added`) on this connection and that is not being replaced; nil on a new connection until its first DNA is confirmed. |
| `addUserText(_:) -> String?` | Typed words as a `user` message item (client id `txt_{tag}_{n}`), logged in `recentTurns`, counted as the committed turn: the next `requestResponse(dna:)` answers it. |
| `say(instructions:input:maxOutputTokens:) -> InitiativeOutcome` | Out-of-band line (§4.2): `response.create` with `conversation:"none"`, `input` (default `[]`), these `instructions` (e.g. `Say exactly: …` + the DNA's `Voice:` words), `tools: []`, audio out, `metadata.purpose = dee_say`. Kind `.say`. Gated like `initiative`; cancelled (`.initiativeCancelled`) if the user starts first. Its audio/sentences arrive as usual; it never enters the conversation or `recentTurns`, gets no DNA, and `bargeIn` sends no truncate for it. |
| `dropUserItem(itemID:resumePreempted:)` | Speech that was not for her (TV, people talking to each other, a failed address wait): deleted now (or at its commit), its line removed from `recentTurns` (so from every later seed), later events for it not emitted, no longer unanswered. A reply requested for it with no audio yet is cancelled (ends `.responseDone(cancelled)`) — **tune 7 (T6-1):** only a reply that answers it. A reply that also answers other committed items, when this item's transcript came back **empty** (the server's tail of a burst the voice committed early), is kept and now answers the others (`turnItemID` = the newest of them); one that answers only this item, or whose dropped item had words, is cancelled as before. A queued request is re-pointed the same way. The newest commit still in the conversation becomes the turn again. If it preempted a reply / follow-up and `resumePreempted` (default), the session re-requests that one itself (as after `rejectEcho`). |
| `userTurnHandled(itemID:)` | A committed turn the app dealt with without a reply (a command): it no longer holds the session busy. |
| `resetConversation(keeping:)` | "Start over": deletes every item of the live conversation (the session's ledger of `conversation.item.added` / commits) except `keeping`, the live DNA, the response in progress (and its turn) and open speech; `recentTurns` keeps only those turns; `lastSummary` = nil; a summary being made is discarded. **Tune 6:** the item ids it took out are added to `forgottenItemIDs` (public, ≤256): their turns are gone from the history on purpose, so a heard-vs-history check skips them (live tune 5 reunion-evening: the only "history mismatch" was a cut reply the reunion's new conversation had removed, historyText ""). |
| `hasUnansweredUserTurn` | A committed user turn has had no `requestResponse` / `userTurnHandled` / `dropUserItem` / `rejectEcho` for less than `unansweredHold`. Such a turn makes the session **not idle**: no unforced rollover switch (and a forced one waits like for open speech). Speech **stopped but not committed yet** (up to `commitWait`) and local speech (`setLocalSpeech`) count the same way. |
| `heardText(itemID:)` | What of her item counts as heard (`HeardRule`): after a cut the kept sentences, else all placed so far. |
| `speakingRateMsPerCharacter` | The rate sentence hints use now (learned or the configured start). |
| `requestResponse(cueItem:instructions:maxOutputTokens:reasoningEffort:) throws -> RequestOutcome` | Answer the committed user turn. `cueItem` (the `<dee_state>` cue) goes first as a **system message item**, then `response.create` with optional per-response `instructions` and `reasoningEffort` (`minimal` / `low` / `medium` / `high` / `xhigh`, sent as `response.reasoning.effort`; nil or empty = the session's `reasoning.effort`). A reply the session re-requests by itself (after an echo rejection) keeps its effort. `.queued` if a cancelled response is still closing (sent after its `response.done`); a second queued request replaces the first, which gets `.responseDone(cancelled, superseded)`. Every request — sent or queued — gets exactly one `.responseDone`. Each `response.create` carries `metadata.dee_turn` so a late `response.created` of an abandoned request is cancelled instead of taking over the next one. Throws `.responseInFlight` if one is generating, `.notConnected`. |
| `initiative(instructions:cueItem:maxOutputTokens:reasoningEffort:) -> InitiativeOutcome` | Dee speaks first. `.refused(.userSpeaking / .responseInFlight / .speaking / .notConnected)` (`.speaking` also while `setLocalPlayback(true)`). Gated at send **and** at first audio; cancelled (`.initiativeCancelled`) if the user starts first. `reasoningEffort` as for `requestResponse`. |
| `cancelUnspokenResponse() -> Bool` | Cancel a response that has no audio yet (e.g. local VAD heard the user before the server did). |
| `bargeIn(cuts: [(itemID, playedMs)]) -> BargeInOutcome` | Call **after** flushing the player, listing **every** assistant item that was playing or queued, oldest first, with how much of each was heard (0 for one still queued, e.g. a tool follow-up behind the reply). Sends `response.cancel` (if generating) then one `conversation.item.truncate(item, 0, audio_end_ms = playedMs)` per item (clamped to audio received; skipped for an item that was played to its end and is no longer generating, for unknown or already truncated items, and for repeats). Later audio/text of the cancelled response is dropped. The item still being **generated**, if not listed (its first audio may not have reached the player yet), is truncated at 0 — none of it was heard; other unlisted items count as fully played. `outcome.truncations` lists each truncate. |
| `bargeIn(playedMs:) -> BargeInOutcome` | The same for the newest item only (`truncatedItemID` / `audioEndMs` = the first truncation). Each `Truncation` also carries `heardSentences` / `heardText`: what `HeardRule` keeps at `audioEndMs` (the history keeps exactly this). |
| `playbackFinished()` | The player drained. Required: `.speaking` (and initiative refusal) lasts until this or `bargeIn`. |
| `setLocalPlayback(_ on: Bool)` | The app is playing her audio that the server never sent (a clip: a laugh, "one sec"). While on, user speech that starts counts as possibly her echo, exactly as during her server audio: it does not preempt a reply / follow-up without audio until the app decides (`acceptSpeech`, `bargeIn`, `rejectEcho`), initiatives are refused (`.speaking`), and a rollover waits. Turn it off once the clip's echo tail has passed. Does not change `state`. |
| `setLocalSpeech(_ on: Bool)` | The app's own VAD (EarCore) hears the user — usually ~0.3 s before the server's `speech_started`. While on, a rollover neither starts nor switches (a forced one waits as for open server speech), and a connection that ends carries the audio from 0.5 s before this onset over to the next one. Turn it off at the local end of speech. Does not change `state`. **Ask (DeeVoice):** call it from EarCore onset / end. |
| `commitUserSpeech() -> Bool` | Early end-of-turn seam: `input_audio_buffer.commit` now instead of waiting for semantic VAD (whose hold was 1.78 s at p90 live). Sent only while user speech is open, or stopped and not committed yet; the commit arrives as usual (`.userCommitted`); an "empty buffer" refusal (the server committed first) is swallowed. Returns whether it was sent. Optional for DeeBrain/DeeVoice. |
| `acceptSpeech(itemID:)` | The open user speech `itemID`, which started over her audio (held as maybe-echo), is the user. From then on it is ordinary user speech: a response with no audio yet is preempted as if the speech had begun over silence (`.initiativeCancelled` / `.replyPreempted`), and no tool follow-up starts while it is open. No-op for any other item. Call it whenever the app decides an onset over her audio (or its tail) was the user — also after a `bargeIn` for that onset, and for every onset the app forwards as the user without holding it (e.g. just after a clip it cut, while local playback is still on for the echo tail). |
| `rejectEcho(itemID:)` | That user item was Dee's own voice: `conversation.item.delete` now, or as soon as it commits. No transcript, no commit event, no reply. If a reply was already requested for that (committed) item and has no audio yet, it is cancelled (`.replyPreempted`) — Dee never answers her own echo. If that item had preempted a reply / tool follow-up, the session re-requests it by itself (a new `.responseStarted` follows; the brain does nothing). |
| `updateSession(instructions:tools:speed:)` | Live `session.update` (never voice/model); also used by future rollovers. Instructions/tools go at once; `speed` is held until no response is in progress (the API rejects it mid-response). |
| `setToolHandler(_:)` | `@Sendable (RealtimeToolCall) async -> RealtimeToolResult`. Without one, calls get `{"error":"unavailable"}`. |
| `state`, `sessionID`, `recentTurns`, `lastSummary`, `config` | Read-only. `recentTurns` = user transcripts (in commit order) and what Dee actually said (trimmed on barge-in), max 60. |

`playedMs` is milliseconds of **that assistant item's** audio that actually reached the
speaker (24 kHz: 48 bytes per ms). `recentTurns` after a barge-in keeps the sentences
`HeardRule` counts as heard (see "What was heard"). A response that does **not** complete
(`failed`, `incomplete` — token limit, content filter —, socket lost, `close()`) is treated the same
way at the audio that arrived: its trailing (unterminated) sentence is flushed with an
`audioMsHint` at the speaking rate (`estimatedMsPerCharacter / speed`, or the observed rate if the
audio is ahead), never stretched onto the received audio, and her turn in `recentTurns` (and so the
next session's seed) keeps only the sentences whose midpoint that audio covers. A completed
response keeps its whole transcript, even without a `transcript.done`. Do not request a reply while her previous audio is still
playing unless you barged in first; the new audio would queue behind the old.

### State (`RealtimeState`)

`idle` → `connecting` → `listening` ⇄ `userTurn` (speech_started open) → `awaitingResponse`
(`response.create` sent, no audio) → `speaking` (audio arriving, or still playing until
`playbackFinished`) → `cancelling` (`response.cancel` sent, waiting for `response.done`) →
`listening`. Every change is also emitted as `.stateChanged`.

### Events (`RealtimeEvent`)

| Event | When / what to do |
|---|---|
| `.connected(sessionID, model)` | After every successful (re)connect or takeover (preceded by `.uplinkOrigin`). |
| `.stateChanged(state)` | |
| `.disconnected(code, reason)` | Socket gone (1000 for `close()`). |
| `.recovered(sessionID)` | Reconnected after a drop, seeded. Cloud may take turns again. |
| `.userSpeechStarted(itemID, audioStartMs)` | Server VAD onset. While Dee speaks: decide barge-in (`bargeIn`) or echo (`rejectEcho`). |
| `.userSpeechStopped(itemID, audioEndMs)` | |
| `.userCommitted(itemID, previousItemID)` | The turn is an item: build the cue and call `requestResponse` now (fast mode). |
| `.userTranscriptDelta` / `.userTranscript(itemID, text)` / `.userTranscriptFailed` | Asynchronous `gpt-transcribe` text; key on `itemID` (order across turns not guaranteed). Exact-cue mode waits ≤400 ms for `.userTranscript` before `requestResponse`. |
| `.echoRejected(itemID)` | Confirmation of `rejectEcho`. |
| `.responseStarted(responseID, kind)` | `kind`: `.reply`, `.initiative`, `.toolFollowUp`, `.say`. Not emitted for a response cancelled before the server acknowledged it, nor for one abandoned before it started (watchdog, refused DNA): such an orphan is cancelled at its `response.created` and its output items are deleted at its `response.done`. |
| `.assistantAudio(itemID, pcm)` | PCM16 mono 24 kHz: schedule on the player. |
| `.assistantAudioDone(itemID, totalMs)` | No more audio for the item. |
| `.assistantTranscriptDelta(itemID, delta)` | |
| `.assistantSentence(itemID, text, audioMsHint)` | A complete sentence (numbers, "Dr.", "e.g." and initials stay whole). `audioMsHint` = offset (ms into the item's audio) where the sentence **ends**: its share of the audio when the item's audio is already complete, else `characters × speakingRateMsPerCharacter / speed` (or the observed rate when the audio is ahead); never below the previous sentence's hint. **Final**: the one placement everybody uses (`HeardRule`). Emit `deeSaid` when **playback** passes this sentence's own hint (or the item ends). |
| `.assistantTranscript(itemID, text)` | Full transcript (not emitted for cancelled responses). |
| `.assistantTruncated(itemID, audioEndMs)` | History mirror: drop what was not heard. |
| `.responseDone(ResponseSummary)` | Always exactly one per requested response: `status` `completed / cancelled / failed / incomplete`, `reason` (`turn_detected`, `client_cancelled`, `max_output_tokens`, `content_filter`, or Dee's own `connection_lost`, `no_response`, `cancel_timeout`, `closed`, `superseded`, `dna_rejected`; `responseID` nil for a queued request that never went out), `usage`, `audioMs`, `transcript`, `errorCode`. |
| `.toolCall(RealtimeToolCall)` | Informational; the handler is already running. |
| `.initiativeCancelled(responseID?)` | The user spoke first. |
| `.replyPreempted(responseID?)` | The user kept talking before her reply had audio (or `rejectEcho` withdrew the turn it answered). Request a new reply on the next `.userCommitted` (it will see both user items). If the preempting speech is rejected as echo the session re-requests it itself. Also emitted for a preempted `.toolFollowUp`. |
| `.rateLimits([RateLimit])` | `rate_limits.updated`. |
| `.uplinkDropped(frames, atFeedFrame, atServerMs)` | Mic audio given to the session never reached the server: exactly `frames` 24 kHz frames, dropped while the uplink was congested, the feed queue overflowed, or the (re)connect buffer overflowed / went stale. `atFeedFrame` is its position on the **feed stream**: every frame given to `feedAudio` / `appendAudio` since the session was created, in order, dropped or not (the app counts the same stream). The server's `audio_start_ms` / `audio_end_ms` skip it. `atServerMs` (informational, whole ms) is where the gap sits on the live session's timeline; nil when none was live. Not emitted for audio fed while there is no session at all (it precedes the next origin). |
| `.uplinkOrigin(feedFrame)` | The live session's input timeline (server offset 0) starts at this feed frame; later frames reach it in order except those `.uplinkDropped` reports. Emitted just before every `.connected` (connect, reconnect, takeover) and `.rolledOver`, so the app can rebase its server-offset map exactly, including audio it fed before it handled the event (and pre-connect buffered audio, which comes first on the new timeline). |
| `.error(RealtimeIssue)` | Non-fatal server error, classified: `moderation`, `rateLimit`, `quota`, `auth`, `server`, `invalidRequest`, `sessionExpired`, `other`. Moderation mid-audio: the response is cancelled, the tail is not played, the session continues (show the puzzled face). |
| `.fallbackAdvised(FallbackReason)` | Dee cannot talk through the session right now. There is no local pipeline any more (0.6): show the "no connection" state (`VoiceHealth.cloudVoice`), keep eyes, touch and camera alive, and wait for the reconnect. Reasons: `socketLost(code, detail)`, `connectFailed`, `noResponse`, `rateLimited(retryAfter)`, `quotaExceeded`, `unauthorized`, `noKey`, `congested`, `serverError`. Emitted once per episode; re-armed after a healthy `response.created` or a reconnect. |
| `.rolloverStarted(forced)` / `.rolledOver(sessionID)` | See Rollover. `.rolloverStarted` comes once per rollover (once more only if it turns forced). Rollover is make-before-break and switches only when quiet, so no clip is needed; B6 may still play the "one sec" clip on `forced` if the switch is seen to lag. |

## DNA lifecycle (DNA.md §4.1 — N4, F9)

- **Happy path, no extra round trip:** `create(dna_new)` → `delete(dna_old…)` → `response.create`, one actor
  turn. Create-then-delete: the model is never without a DNA. Ids are client-supplied (`dna_{6-char tag}_{n}`,
  ≤ 32 chars; the tag changes with every connection).
- **Refused create (F9):** the server processes events in order, so its `error` for the create arrives
  **before** the `response.created` of the response sent behind it (the old DNA's delete was processed too, so
  that response would run bare). The session then gives that request's response up before it starts (new
  token: its late `response.created` is cancelled and nothing of it is emitted; its items are deleted at its
  `response.done`) and sends the same request again behind the **previous DNA restored under a fresh id**.
  The caller sees one `.responseStarted` and one `.responseDone` for its request. No previous DNA, or the
  restored one refused too → `.responseDone(failed, "dna_rejected")`. A refused `replaceDNA` restores the
  previous one. An `.error` (with the create's `eventID`) is emitted for visibility; errors for the
  session's own DNA/housekeeping deletes (`item_not_found`) are swallowed.
- **Reuse:** tool follow-ups and the session's own re-requests (echo rejection, `dropUserItem`) reuse the live
  DNA. Once the DNA API is used, **no response runs on a connection without one**: a DNA-less response there
  (follow-up or re-request after a reconnect) is preceded by the last DNA text, under a new id.
- **Connections:** `liveDNAItemID` and the per-connection ledger are cleared on connect, reconnect
  (`.recovered`), takeover and rollover; seeds never contain a DNA. The rollover summary never reads the live
  conversation (so never a DNA): its `input` is one user message with the transcript (see Rollover).
- **Legacy:** `requestResponse(cueItem:)` / `initiative(instructions:cueItem:)` are unchanged (DeeBrain's
  `DNAWire` still rewrites them). When DeeBrain adopts `requestResponse(dna:)`, it must stop `DNAWire` from
  rewriting DNA creates (its `isDNA` would otherwise re-id and double-delete the session's DNA items) and can drop
  `dropItem` / `resetConversation` / canned-line / summary-scoping rewrites in favour of the calls above.

## Turn keying (tune 7, T6-1)

Every reply carries `answers` (the committed user items it answers, commit order) and `turnItemID` (the newest).
- `requestResponse(…, answering: item)`: `[item]`. Recommended for DeeBrain: it knows the item it decided to answer.
- `requestResponse(…)` with no `answering`: every unanswered committed item plus `lastCommitted`. Live q02 / fan15 q08,
  the brain asked right after the server committed an empty tail (`…nfNhl`) of "Are you awake?" (`…mmkG`); the reply
  was keyed to the tail alone and `dropUserItem(tail)` on its empty transcript sent `response.cancel` in the same ms.
  Now the reply answers `[mmkG, nfNhl]`; dropping the wordless tail leaves `[mmkG]`, no cancel.
- `respondToSpeech`: `[the next commit]`.
- `rejectEcho` is unchanged (cancels a reply whose `turnItemID` is the echo).
- Open speech (tune 6 openSpeech patch): once the open item is committed (the voice's quick commit), the server's
  `speech_stopped` of its unannounced tail item closes it too, so the second gate never preempts the answer on a stale
  open item (live T6-2: fan15 q05, kitchen15 q06, echo20 q02, echo20 q08 — `response.cancel` in the ms of the first delta).
- Replay regressions: `Tune7Tests` (both T6-1 traces; the 4 T6-2 traces against the openSpeech patch, applied in
  checkpoint 6; `respondToSpeech`).

## What was heard (one source of truth, agreed with DeeVoice)

`HeardRule` (public, pure) is the only rule. Sentence *i* of an item spans `[hint(i−1), hint(i)]` ms of
that item's audio (`hint(−1)` = 0; hints as emitted in `.assistantSentence`, clamped to never decrease). The
placement is **frozen at emission**: nobody re-derives it later from a better rate or the item's total audio.
A sentence is heard when playback passed its end, or — at a cut — when it had started (the first: any audio
played; later: playback passed its start) and its integer midpoint `(start + end) / 2 ≤ playedMs`.

- The session trims `recentTurns` (and so seeds) with it at `bargeIn` and when a response ends early, and
  reports it per item: `BargeInOutcome.Truncation.heardSentences` / `.heardText`, `heardText(itemID:)`.
- DeeVoice's `SentenceClock` already implements this rule on the same hints; checked over 5 000 random
  hint/cut/arrival orders (all agree for hints ≥ 2 ms; a 0–1 ms placement never occurs for a spoken
  sentence). **DeeVoice owner:** call `HeardRule.heard(start:end:index:playedMs:)` in `SentenceClock`'s `.cut`
  branch (removes the duplicate formula), and optionally cross-check `.finished(heard:)` against
  `Truncation.heardSentences` in debug builds.
- Why it disagreed before (harness defect 8, item `item_EXAjRJhKNTbWkk9LkgHst`, cut at 3660 ms): hints were
  emitted at 62 ms/char (1798, 5208 ms) while the audio was still arriving; by the cut the item's audio was
  complete (9950 ms / 122 chars = 81.6 ms/char) and the session re-placed the sentences at that rate (midpoint
  of sentence 2 at 4651 ms → 1 kept) while `SentenceClock` used the hints (midpoint 3503 ms → 2 heard). Now both
  say 2. To keep the shared placement close to the real audio the session learns the speaking rate
  (`calibrateSpeakingRate`).

## Tools

Calls run as soon as `response.function_call_arguments.done` arrives. Outputs are sent as
`function_call_output` items after that response's `response.done`, oldest response first, even if
it was cancelled (the call item is in the conversation). A follow-up `response.create` is sent only
for a **completed** response, when nobody is speaking and nothing else is generating, and if any
result asks for it:

- `.always` — speak with the result (`recall`).
- `.ifSilent` (default) — only if that response said nothing aloud (`remember` at the end of a
  spoken turn needs no follow-up; a bare `remember` does).
- `.never` — silent side effect.

## Rollover and reconnect

Realtime sessions end at 60 minutes. A rollover starts at the first idle moment (nothing
generating or playing, no open speech — server speech open, stopped but not committed yet, local
speech — no unanswered turn, no pending tools) after `rolloverAfter`, or at
`forceRolloverAfter` regardless. It asks the old connection for a summary (out-of-band
`response.create` with `conversation: "none"`, text only, `tools: []`, `tool_choice: "none"`,
`max_output_tokens` 400, `metadata.purpose = dee_rollover_summary`, ≤`summaryTimeout` 6 s; once per
rollover). **Tune 3:** its `input` is explicit — one user message holding the previous summary
(`<earlier_summary>`) and the newest `recentTurns` as `Person:` / `Dee:` lines inside `<transcript>`
(≤12 000 characters, newest kept) — never item references, and its `instructions`
(`RealtimeSession.summaryInstructions`) are summarisation-only: a third-person note-taker that must
not answer, continue or react to the transcript. Live tune 2, given the conversation itself, 2 of
4 summaries answered the user's last question instead ("I can't see a clock or your device…").
With nothing said (no turns) no summary is asked for. The summary is invisible to the app: no
`.responseStarted` / audio / transcript / `.responseDone` / state change, even if the server sent
audio for it; a refusal of it (`error` for its event id) is quiet (no `.error`, no fallback advice)
and the seed goes without it. It never holds Dee back: user speech during it is handled exactly
as usual (`requestResponse` is sent, not refused), and `initiative` / `say` are no longer refused
`.responseInFlight` because of it. Then it opens
the new connection beside the old one and **parks** it. The switch — seed with **one system
message** ("[The conversation continues…]" + summary + the last `seedMessages` messages as
`Person:` / `Dee:` lines), swap, close the old one — happens only at a quiet moment: fully idle
before `forceRolloverAfter`; after it, as soon as nothing is generating, playing, queued or
pending (the user gets 30 s to finish an utterance, after which it is switched anyway and that
utterance is **carried over**: replayed into the new session from its `audio_start_ms`).
Tune 2 (live fallback-rollover q02): the switch used to happen at `speech_stopped`, before the
commit, and "Are you awake?" was never committed anywhere; the gap until the commit (and the
reply, and the end of her playback) now holds the switch. Never mid-sentence, never while her audio plays, and every response ends with
its own `.responseDone` on the old session. A failed attempt retries after 30 s (10 s when
forced). A park that waits 5 min for an idle gap is discarded and redone. If the old connection
dies while a session is parked, the parked one takes over at once (`.recovered`, no fallback).

**Tune 6 (live tune 5, rollover-speech m01).** The seed is the first event on a new connection
(switch, takeover, reconnect), before any DNA or `response.create`; the server handles events in
order, so no response there runs before the seed is in, and every response there brings the
current DNA (its own, or `lastDNAText` when it has none). A turn committed during the overlap
(parked session open, old one live) is answered on the old connection, which holds the whole
conversation; the parked one gets nothing until the switch, whose seed carries that turn across.
If the server **refuses the seed** (`error` for its event id), a compact seed is sent at once
(summary ≤1 200 characters, the last ≤6 messages, each ≤300) and the response sent behind the
refused one is given up before it starts (its late `response.created` is an orphan) and sent again
behind the compact seed and the current DNA; a refused compact seed surfaces as `.error`. The seed
header is "[The conversation continues from an earlier session. Do not mention this note. What it
says, you already know.]". `summaryInstructions` now require the person's name first as a plain
fact ("The person's name is <name>.") and forbid writing that anyone will remember / store / note /
save something (tune 5 summaries said "Dee confirms it will remember Priya's name", and she said
"I'll store it"). Note: the live m01 reply ran on the old, already-seeded connection with the DNA
in and recall returning "Name: Priya" — the miss was the model's, not a missing seed.

On an unexpected drop: `.responseDone(status: "failed", reason: "connection_lost")` for any open
response, `.disconnected`, `.fallbackAdvised(.socketLost)`, then reconnect with back-off, seeded the
same way (previous summary + recent messages), then `.recovered` + `.connected`. Auth failures stop
reconnecting.

**429 / 503 (tune 2).** The server's hint is a minimum, followed exactly plus a small jitter
(0.05 s … 0.1 s + 15 % of the hint, ≤ 1 s): `Retry-After` on the handshake (`SocketFailure
.rateLimited` / `.server(503, retryAfter)`) or the secret mint, "try again in 1.5s / 350ms" in a
handshake `error` message, else the longest `reset_seconds` of an exhausted limit in the last
`rate_limits.updated`. Without any hint: exponential from `rateLimitBaseBackoff` (1 s) with jitter
in the upper half of each step, up to `rateLimitMaxBackoff` (30 s). The old `max(hint ?? 30, 5)`
floor waited 5.2 s against a 1 s hint live (recovery 7.6 s) and the user's question was lost.

**The user's words survive.** Mic audio during the gap is buffered (`preconnectBufferMs`, 10 s) and
sent only if its newest piece is at most `preconnectMaxAge` (3 s) old. And the user's **unfinished
turn** on the connection that ended — speech open (not held as possible echo), stopped but not
committed, committed but unanswered (or its reply had no audio yet), or local speech — is
**carried over**: the session keeps the last `carryOverMs` of audio it sent, and replays it from the
turn's `audio_start_ms` (local speech: 0.5 s before the onset) to the end, ahead of the buffered
audio, if the new connection is live within `carryOverMaxAge`. The server commits and transcribes it
afresh (new item ids, so the brain answers it after `.recovered` / `.rolledOver` like any turn); its
old user line leaves `recentTurns` so the seed does not hold it twice. `.uplinkOrigin` names the
carried audio's first feed frame (it was fed before the drop; `UplinkMap` still holds those runs).
A stale carry is dropped and reported (`.uplinkDropped`, `atServerMs: nil`). A rollover switch
carries the same way (only reachable mid-turn when forced, or for an onset the server had not
reported yet).

## Auth

- `KeyStore` (generic password, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, never synchronised;
  `normalize` trims paste junk and requires `sk-…`). `MemorySecretStorage` for tests/previews.
- `RealtimeAuth.credential(model:)` mints a **fresh** `ek_…` for **every** call (= every socket: connect,
  reconnect, rollover, retry) via `POST /v1/realtime/client_secrets` (`expires_after {anchor: created_at,
  seconds: 600}`, `session {type: realtime, model}`). Secrets are **single-use** on the live API — a second
  socket with one gets `error ephemeral_token_already_used` and close 3000 (harness, 2026-10-09), although
  the reference says a secret "can be used to create multiple sessions until it expires" — so nothing is
  cached. Falls back to the project key on 400/404/405/501, 5xx or a network error on the minting call.
  401/403 → `.unauthorized`, 429 → `.rateLimited`, no key → `.noKey` (no fallback: the direct key would fail
  the same way). `minted` counts secrets (never their values). `invalidate()` is kept as a no-op.
- `RealtimeSession` treats as a **refused credential**: an `error` before `session.updated` whose code names
  an ephemeral/client-secret/token problem (`RealtimeIssue.isCredentialRefusal`), a close 3000 / 3003 / 4001
  / 4003 / 1008 during the handshake, or an HTTP 401. For an `ek_` secret it is discarded (`invalidate`, if
  given) and the open retried **once** with a freshly minted credential (`init(credentials:)` providers are
  asked again too). Refused again: the project key itself refused → `.unauthorized` (stop); a refused fresh
  secret → a transient `.socket` failure (reconnect continues with new secrets). Same for rollover opens.

## Sockets, traces, tests

- `RealtimeSocket` protocol (send only enqueues, ordered; `incoming` stream ends with one `.closed`).
  `URLSessionRealtimeSocket`: one URLSession per socket, 16 MB frames, ping every 15 s and
  pong timeout 10 s (dead NAT paths), handshake HTTP status mapped to `SocketFailure`
  (`unauthorized`, `rateLimited(retryAfter)`, `server`, `handshake`, `openTimeout`, `pingTimeout`, `network`).
- `FakeSocket` / `FakeSocketFactory` (public, for any package's tests): `push(ServerEvent)`,
  `sent`, `sentEvents`, `waitForSent(type:count:)`, `drop()`, `setPendingBytes`, auto-handshake.
- `ManualRealtimeClock` (public) drives watchdogs, back-off and rollover in tests.
- `TraceRecorder(fileURL:)` → JSONL `{"t":…, "dir":"in"|"out", "event":{…}}`, audio elided to
  `*_bytes`. Pass it as `trace:` in Debug builds only (it holds what was said).
- `TraceReplayServer(entries:speed:)` replays a trace's server side over a loopback `NWListener`
  WebSocket so the real socket code runs in CI (`TraceRecorder.load(url)` reads a recorded file).
- Codecs: `ClientEvent` / `ServerEvent` are `Codable`; `ServerEvent.parse` never throws (unknown types
  → `.unknown(type, raw)`, broken frames → `.malformed`).

## Asks from DeeBrain (wave2-integrate review fix 23) — status

| Ask | Now |
|---|---|
| N4 DNA lifecycle in the session | `requestResponse(dna:)`, `initiative(dna:)`, `replaceDNA`, `liveDNAItemID` (above) |
| F9 refused DNA must not leave a response bare | refused create → response held behind the restored previous DNA (above) |
| `dropUserItem` that also removes the logged turn | `dropUserItem(itemID:resumePreempted:)` |
| `resetConversation` clearing turns / summary | `resetConversation(keeping:)` |
| out-of-band `say` | `say(instructions:input:maxOutputTokens:)` |
| `isIdle` covering unanswered commits | `hasUnansweredUserTurn` / `unansweredHold` / `userTurnHandled` |
| `initiative(instructions: String?)`, `userText(_:)` | `initiative(dna:)`; `addUserText(_:)` |
| never pass `trace:` in Release | caller's job (unchanged): `TraceRecorder` records what was said |

## Not in this module (owners of later steps)

- Audio graph, jitter buffer, played-ms counter, 24 kHz conversion (B1 `AudioGraph`).
- Mapping to `VoiceEvent`s, local barge-in/echo decisions (B3 `RealtimeVoice`).
- Instructions, cue text, tag-free persona, `deeSaid` timing (B4 `RealtimeBrain`, behind DeeCore's `ReplyEngine`).
- Connection state and the "no connection" face (B5), clips (B6), key sheet/settings (B7),
  `TurnTimeline` + live harness (B8).
