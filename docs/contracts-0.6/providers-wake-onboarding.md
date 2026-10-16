# Providers, wake phrase, onboarding — v0.6 contract (binding, rev 2)

Sources: `scratchpad/wake-map-{voice,app,sdk}.md`, `prov-map-{local,brain,ui}.md`, `lmqual/exp*.py`, `wakefeas/` (HEAD 857d888). The 14 tuned
rounds (`tune*-live.md`) must not regress: **mode 1 is today's path byte-for-byte while a window is open** (timing profile `.realtime`).

## 0. Invariants (each is a test; "all modes" = one test per mode 1/2/3)
- **W1 wake is local.** In every mode the wake phrase is detected and reacted to (eyes, waking, window opening) only by `DeeWake.OnDeviceSpeech`
  (Apple SpeechAnalyzer, on-device assets). No audio leaves the phone before the local hit; detection and reaction never depend on a server.
  A server/LAN transcript containing the phrase or "Dee" never wakes her or changes engagement. Tests: the transport fails every request → wake still
  fires, `eyesWake` precedes any connect, 0 requests before the hit; a server transcript "hey dee" while dormant/open → no wake action.
- **W2 DORMANT is silent.** While DORMANT: 0 sockets, 0 HTTP, 0 key mints, 0 audio bytes, 0 network TTS, 0 deferred client events (dropped).
  Only exceptions: user-tapped "Check key" and "Test connection". Saving a key/endpoint never reconnects or renders clips while dormant.
- **W3 no crossover.** Mode 1 never contacts a LAN host; mode 3 never `*.openai.com` (also with the LAN realtime toggle on); mode 2 OpenAI only for
  STT/TTS, LAN only for chat. Redirects are refused (see N1). A failing part gives a problem, never another provider.
- **X1 one transport.** Every outbound HTTP/WS goes through `DeeRealtime.Transport` (`HTTPFetch` + `RealtimeSocketFactory`) built by
  `ProviderFactory`; W2/W3 assert on its recorder (URLProtocol cannot see ephemeral/WS sessions). Guard test: no `URLSession(`/`URLSession.shared`
  in `Sources/` outside `DeeRealtime/Transport*.swift` and `DeeMockServer`.
- **K1 secrets only in the Keychain.** UserDefaults (incl. `providerConfig` JSON) holds no `openAIKey`, no `sk-…`, no URL userinfo/query/fragment,
  no field named key/token/secret. Logs/traces never contain a key or spoken text.
- **N1 plain http/ws only to private hosts**, classified on `inet_pton` IP literals: RFC1918, 127/8, 169.254/16, 100.64/10, fc00::/7, fe80::/10, ::1.
  Names: `*.local` and single-label allowed; `*.home.arpa`/`*.lan`/`*.internal` only if every resolved address is private, and then the http request
  goes to the IP literal (ATS NSAllowsLocalNetworking). "192.168.1.20.example.com" is public. Public hosts need https/wss. Redirects: the delegate
  returns nil (no follow) for all LAN clients; OpenAI clients allow same-host only.
- **T1 hidden text never reaches TTS** (`<think>`, reasoning deltas, markdown, emoji). **M1** memories: mode 3 only to the LAN server; modes 1/2 keep `shareMemories`; the store never leaves the phone.

## 1. Modules (Package.swift owned by **wake**, written first, exactly this graph)
| Target | Deps | Owner | Contents |
|---|---|---|---|
| `DeeWake` (new) | DeeCore; Speech, AVFoundation | wake | `WakePhrase`, `PhoneticKey`, `WakeMatcher`, `OnDeviceSpeech`, `WakeEar`, `ConversationWindow`, `WakeCorpus`, `Engagement` |
| `DeeRealtime` | — | voice | `Transport`, `reconfigure`, `connect(resume:)`, `TimingProfile`, transcription mint, `KeyStore(account:)`, `OpenAIAuth` |
| `DeeVoice` | +DeeWake | voice | dormant/awake, preroll, mic fan-out to `WakeEar`, `ClipRenderer`, listening cues, provider-named problems |
| `DeeLocal` (new) | DeeCore, DeeRealtime, DeeVoice, DeeWake | local | config, `AddressParser`, probe, SSE/NDJSON clients, `CascadeSocket`, STT/TTS backends, `ProviderFactory` |
| `DeeMockServer` (new lib) | — (Network.framework) | local | offline OpenAI-compatible + Ollama-native server |
| `DeeBrain` | +DeeLocal, DeeWake | app | CloudSettings/KeyIntake rewording, StandaloneHost window rule; RealtimeBrain takes `TimingProfile` **options only** |

**The seam is `RealtimeSocket`.** EarCore, holds, speculative gate, TurnPolicy, DNA single item, preempt, HeardRule sit above the wire unchanged.
Modes 2/3 run `CascadeSocket`, an in-process realtime-protocol emulator. The BrainHost-facing seam is `ProviderRuntime`:
```swift
public enum ProviderMode: String, Codable, Sendable { case openAI, lanBrainOpenAIVoice, lanEverything }
public enum SpeechPart: Codable, Sendable, Equatable { case openAIRealtime, openAIREST, lan(EndpointConfig), onDevice }
public struct EndpointConfig: Codable, Sendable, Equatable { var baseURL: URL; var model: String; var keyAccount: String? } // AddressParser: no userinfo/query/fragment, "/v1" stripped
public struct ProviderConfig: Codable, Sendable, Equatable { var mode; var openAIModel: String; var voice: String; var brain: EndpointConfig?
  var stt: SpeechPart; var tts: SpeechPart; var lanRealtime: Bool; var keepAlive: String = "30m"; func validate() -> [ProviderIssue] }
public struct ServerCapabilities { models; realtime, chat, tools, transcriptions, speech: Bool; vendor: Vendor; contextLength: Int?; loaded: Bool?; probedAt }
public struct ServerProbe { init(transport:); func probe(_ base: URL, key: String?) async -> Result<ServerCapabilities, ProbeFailure>; func testChat(...) }
public struct ProviderRuntime: Sendable { sessionConfig: RealtimeSessionConfig; credentials: @Sendable () async throws -> SocketCredentials
  socketFactory; transport; clipRenderer: any ClipRenderer; timing: TimingProfile; label: ProviderLabel }
public enum ProviderFactory { static func make(_ c: ProviderConfig, secrets: any SecretReader, transport: Transport) throws(ProviderIssue) -> ProviderRuntime }
```
`RealtimeAuth` becomes `OpenAIAuth` whose mint endpoint is fixed to api.openai.com by type (no defaulted URL); LAN credentials are only the closure
`{ .direct(lanKey ?? "") }`. The app keeps one rebuildable `VoiceStack`; `DeeModel.applyProvider(_:)` rebuilds only while DORMANT (closes the window first).

## 2. Providers
- **Mode 1:** today's gpt-realtime path, mint per socket. Test: session.update bytes == HEAD's. **LAN realtime (mode 3, only if probe completes WS upgrade + `session.updated`):** direct credentials, no mint, `rolloverAfter = .infinity`.
- **Cascaded (modes 2/3) `CascadeSocket: RealtimeSocket`** consumes session.update, input_audio_buffer.append/commit/clear, item create/delete/truncate,
  response.create (incl. `conversation:"none"`, max_output_tokens), response.cancel, output_audio_buffer.clear; emits in realtime order speech_started/
  stopped (`audio_*_ms` on its own fed-frame clock), committed (always before transcripts), transcription delta/completed/failed, response.created
  **at the first chat token** (not at request), output_item, per sentence transcript.delta **then** audio.delta (PCM16 24 kHz), function_call
  args.done, response.done(completed|cancelled|incomplete, usage), error.
  - `TurnSource` — mode 2: OpenAI realtime **transcription** session, server_vad 300/300/0.5 as `CloudSettings.turnDetection`, minted via
    `OpenAIAuth(sessionType: .transcription)`; a 400/404 there is a hard `ProviderIssue`, **no direct-key fallback**. Before building it the voice
    owner runs one live probe (fake-free real key, never printed, cents) to pin model id, URL and event names in one constant; if the WS path fails
    the probe, mode 2 uses `/v1/audio/transcriptions` per committed span and this is documented. Mode 3: `LocalTurnDetector` = Apple
    `SpeechDetector` (shares the analyzer) AND EarCore's bed-proof `voiceActive`, 300 ms silence / 300 ms prefix, on UplinkGate-gated frames.
    No energy VAD, no "0.5". Harness reports per-bed commits and false barge-ins vs the mode-1 traces.
  - `STTBackend` — `.openAIRealtime` (mode 2); `.lan` WAV of the committed span → `/v1/audio/transcriptions` (no deltas; covered by the timing
    profile, not chunked uploads); `.onDevice` DictationTranscriber + contextualStrings ["Dee", phrase]: at every commit `finalize(through:)` the
    commit time; deltas are append-only (final text or stable prefix of successive volatiles); completed on the final. Name variants in address
    position (KD/Heidi/Haidee via WakeMatcher aliases) are rewritten to "Dee" ("Heidi Klum was on TV" unchanged).
  - `ChatBackend` — `/v1/chat/completions` SSE, `reasoning_effort:"none"`, include_usage, `max_tokens`. **Message layout (measured: Ollama hoists
    every system message):** [system: session instructions + cascaded tool-policy paragraph] [system: DNA stable part, `DNASplit.stable` = sections
    1,2,4,5,6,9, resent only when its bytes change] [history ≤ 12 heard messages + on-phone rolling summary; her text cut to heard sentences; tool
    calls/results] [user: `DNASplit.volatile` (header, 3,7,8, notes) + prefetched memories (M1/shareMemories) + transcript]. Tools array identical
    every request, only if probed. Reasoning deltas dropped; `ThinkStripper` → `SpeechCleaner` → `SentenceChunker` (first chunk may be a clause:
    comma after ≥ 4 words). A tool call discards unspoken text. `chunk.model` mismatch = error. Ollama: `keep_alive` on every request; post-tool
    turns use native `/api/chat think:false` (NDJSON). Probe reads context length (`/api/ps`, `/api/v0/models`) and warns if < prompt+history+max.
  - **Warm-ups (LAN brain only, window open only):** on `waking` a 1-token request with the current prefix (loads the model, overlaps the question);
    on each `speech_started` a prefix-only `max_tokens:1` request (cancelled when superseded). **Debounce:** response.create waits for the final
    transcript; a newer speech_started first → cancelled locally with no HTTP. Target ≤ 1.2 chat requests per committed turn.
  - `TTSBackend` — `.openAIREST` `/v1/audio/speech` gpt-4o-mini-tts `pcm` streamed with `instructions` = VoiceStyle + DNA §3 delivery line (as
    ClipCache); `.lan` same API resampled to 24 kHz; `.onDevice` AVSpeechSynthesizer.write (best by quality) with VoiceStyle → pitch/rate/volume.
    Sentence n+1 renders while n plays, delivered in order; synthesizer and TTS connection pre-warmed at window open. Target gaps < 150 ms.
  - Cancel/clear stops SSE+TTS, emits `response.done cancelled`, no audio after. Truncate records heard ms and trims history.
- **`TimingProfile`** (RealtimeSessionConfig + RealtimeBrain.Options, set by ProviderFactory): `.realtime` = today's values exactly; `.cascaded` =
  firstAudioTimeout 90 s while loading, stallRetryAfter off, slow clip once per window keyed to measured TTFT, TurnPolicy word waits per STT
  backend (measured; `.lan` longer). Test: mock 7 s first token → answered, no cancel, no retry request.
- Her audio enters `graph.player` via `.assistantAudio` (VPIO AEC, barge-in, holds, eye level unchanged). `ClipRenderer`: OpenAI / LAN / on-device;
  `prepare()` only inside an open window (first window after a key save).
- **Never silently fall back.** Every failure → `VoiceProblem` with `ProviderLabel`.

## 3. Wake (DeeWake)
```swift
public struct WakePhrase: Codable, Sendable, Equatable { init(validating: String) throws(WakePhraseError) // 1–4 words, letters/space/'-', ≤32, not a stop command
  static let `default` = "Hey Dee"; var text; var words: [String]; var isShort: Bool; var aliases: [String]; var contextualStrings: [String] }
public struct WakeMatcher: Sendable { struct Thresholds { keyDistance: Int; letterRatio: Double }; init(_ p: WakePhrase, _ t: Thresholds = .tuned, strict: Bool = false)
  func match(_ texts: [String]) -> WakeMatch?; func candidate(_ text: String) -> Bool; func stripLeading(_ text: String) -> String }
public enum EarAvailability: Sendable, Equatable { case ready, notAsked, assetsDownloading(Double), assetsMissing, denied, unsupported, siriDictationOff, thermalBackoff }
public protocol WakeEar: Sendable { func start(phrase:) async; func stop() async; func setPhrase(_:) async
  func consume(_ pcm16k: [Int16], captureFrame24k: Int64); var hits: AsyncStream<WakeHit>; var candidates: AsyncStream<Void>; var availability: AsyncStream<EarAvailability> }
public struct WakeHit: Sendable { var onsetFrame: Int64?; var onsetFromFinal: Bool; var detectedFrame: Int64; var matched: String; var tier: MatchTier }
```
- **OnDeviceSpeech:** one SpeechAnalyzer, DictationTranscriber [.shortForm,.farField] + contextual strings only (SpeechTranscriber added only if the
  corpus shows a recall gain), `.frequentFinalization`, `finalize(through:)` after a 0.3 s local pause. `bufferStartTime = CMTime(value:
  captureFrame24k, timescale: 24000)`; onset frame = seconds × 24000 (round-trip test over several buffers). Locale from the phrase language
  (default en-US, device locale only if the phrase validates in it); `AssetInventory` install then `reserve(locale:)`, status re-checked each foreground.
  `ProcessInfo.thermalState ≥ .serious` → `thermalBackoff` problem, ear paused (tap still wakes).
- **Matcher:** normalise (lowercase, punctuation, "K.D."→"k d"). Windows are exactly the phrase's word count over best + every alternative,
  volatile and final. Tiers: (a) exact; (b) explicit alias (`aliases`: for "Hey Dee" = heidi, haidee, kd, hey d, hi dee; for any phrase = the joined
  words) — aliases may be 1 word; (c) letter Levenshtein ≤ `letterRatio` on the full-count window; (d) `PhoneticKey` distance ≤ `keyDistance`, only
  when the key has ≥ 3 chars. Never a bare key on a shorter window ("had", "hot", "head", "her robe" never hit).
- **Corpus/tuning (pinned):** positives from measured transcripts per phrase ("Hey Dee", "Computer", "Hey Robo", "Okay Pixel"); negatives = "he is",
  "D is", "hey the", "Lady", had/hot/head/hit/heat/hood/hide/hate/"her robe", **every word from a 10k frequency list whose key or letters fall within
  2 of the phrase** (generated per phrase), and 200 sentences. Grid search (keyDistance 0–2, letterRatio 0.15–0.45) → smallest values with recall
  ≥ 0.95 and 0 negatives; any flip fails a test. Audio suite confirms (§6).
- **Candidate cue:** `candidate` = first phrase word + prefix of the next → local "perking up" eyes within ~0.5 s, no network, no state change.
- **Onset/preroll:** on a hit, `finalize(through: hit)` and keep reading until a final arrives or connect completes; use the final's run
  `audioTimeRange` if present. Otherwise walk back by energy onset but **never earlier than hitEnd − (words × 0.45 s + 0.3 s)**. Uplink starts at
  onset − 0.3 s. Test: speech then "Hey Dee" with no gap → first frame ≤ phraseDuration + 0.35 s before hit end. Ring **12 s** (never sent dormant).
- **False-wake backoff:** a window closing with no accepted turn = likely false wake; 3 in 10 min → `strict` (tiers a–b only) for 15 min, counted in
  `UsageCounter`. Tests with window inputs.
- **Short phrase:** 1 word with key ≤ 3 chars → UI warning "Short phrases wake her by accident more often." **Unavailable ear:** stay DORMANT, one problem "I can't hear my wake phrase — tap me to talk"; never server recognition, never stream everything.

## 4. DORMANT ⇄ CONVERSATION (`ConversationWindow`, pure; driven by DeeModel, StandaloneHost, HarnessHost)
States `.dormant`, `.waking(source, onsetFrame, at)`, `.open(lastAccepted, openedAt)`. `Engagement.answers(window:, …)` (pure, DeeWake) is the one
rule all three hosts call: **window open ⇒ engaged and addressed**; dormant ⇒ nothing answered. `SpokenCommand.addressesDee` no longer wakes or
gates anything (test fails if the branch returns); `SpokenCommand.core`/commands strip the current phrase via `WakeMatcher.stripLeading`.
| From | Input | To / actions |
|---|---|---|
| dormant | `phraseHeard(hit)` / `tapToTalk` / `greetingDue` (speakFirst, known person, ≤ 1 per arrival) | waking · `eyesWake`, `wokenByVoice` (clear sleeping, lastEngagedAt), `connect(resume:)`, `warmUp`, `markUsageStart` |
| waking | `connected` | open · `openUplink(from: onset − 0.3 s)` (tap: tapTime − 0.3 s; greeting: now) · greeting → `allowInitiative(once)` |
| waking | `connectFailed(p)` / 6 s timeout | dormant · `disconnect`, `problem(p)`, `eyesListeningOff` |
| open | `acceptedTurn` (HeardVerdict answered/held; not ignored/echo/misheard), her reply to it, `phraseHeard`, `tapToTalk` | open · refresh `lastAccepted` |
| open | `tick(now)`: ¬busy ∧ now − lastAccepted ≥ 60 s, or now − last acceptedTurn ≥ 600 s (hard cap) | dormant · `closeUplink`, `disconnect`, `logUsage`, `eyesListeningOff` |
| open | `closeCommand` ("go to sleep" / "stop listening" / "that's all", with or without the phrase) | dormant after her local goodbye clip · same |
| any | `background` / `providerChanged` / `earLost` | dormant · same (`earLost` adds a problem) |
- `busy` = replyOutstanding ∨ toolRunning ∨ awaitingWords ∨ holdActive ∨ someone talking now (TurnPolicy.initiativeAllowed inputs); the 60 s is
  measured from when busy ends. Raw speech activity, TV, her initiatives and replies to unanswered initiatives never refresh. Tests: TV bed after one
  wake closes at 60 s ± 2; 3 unanswered initiatives don't extend; mock 75 s first token keeps the window open and the reply plays.
- `disconnect` = `CloudVoice.sleep()`: session.close, connect loop/reconnect/rollover timers stopped, EarCore `wakeOnVoice=false`, `WakeEar.start`.
  `connect(resume: true)` sends `seed(link:)` (summary + recent turns) on the first link unless ≥ 300 s dormant started a new conversation;
  close() keeps carry/summary. Test: close → connect → first client events include the seed.
- **Eyes:** `eyesListeningOff` = a distinct non-sleeping look (soft idle drift) + optional soft local chime, on every → dormant row;
  `eyesWake` the opposite. Body `sleeping` (sleepAfter 180 s) stays separate. Test: every → dormant row emits it.
- **Tap-to-wake** = a single tap outside the eyes or on the "Tap to talk" chip; eye taps (blink), pokes, pets, holds stay local reactions in DORMANT.
- Initiatives, Cortex cues, curiosity, `sayAside`, touch/sound model turns, clip rendering: only while open or the one greeting window.
- Voice change: `SpokenCommand.changeWakePhrase(to:)` → "My wake phrase will be "X". Is that right?" → yes within 20 s saves; invalid → her reason.
- `DeeModel` sets `isIdleTimerDisabled = true` in `.dee` (dim idle face after 2 min), restored on leave/background. No background wake (by choice: no background mic); onboarding says "keep Dee open, ideally on a charger".

## 5. App (app implementer)
- **Phases** `.splash → .onboarding → .dee`; `model.start()` only in `.dee`. **Migration before onboarding shows:** read `openAIKey` default → Keychain
  with no network; always `removeObject` (on Keychain failure tell the user to re-enter); foreground `absorbKey` deleted; old `cloudVoice/cloudModel`
  pre-fill a mode-1 config. Tests: K1, migration makes 0 requests.
- `OnboardingStep` (DeeCore, pure): meet → talking (phrase, "go to sleep", interrupting, "keep going", keep the app open) → seeing → privacy & cost
  per mode → permission cards mic → speech (dropped if a device check shows SpeechAnalyzer needs no SFSpeechRecognizer auth) → camera → local
  network (the card fires the prompt via an NWBrowser/UDP send) → **provider** → wake phrase → voice → speak-first (off). Skip jumps to provider;
  after provider any still-undetermined permission cards show before Done. Done needs `validate()` empty and tested parts OK.
- **Provider step:** three cards (quality / speed / cost / privacy / needs). Every key is a `SecureField` + Paste (pasteboard cleared if it still holds the
  same string); OpenAI "Check key" → GET /v1/models via Transport, shown `sk-…abcd`, restricted key + spend limit hint. LAN: host/IP[:port], chips
  Ollama :11434, LM Studio :1234, llama.cpp :8080; an `sk-` key on an http LAN endpoint is refused ("that looks like an OpenAI key; it would cross
  your Wi-Fi unencrypted"). Test connection: NWConnection preflight (`.localNetworkDenied` → Settings message; waiting → retry when satisfied),
  then probe; per-part status (brain / hearing / voice), model picker (non-chat filtered), "first answer after a pause takes N s" if not loaded,
  separate STT/TTS endpoints, "on this iPhone" when the LAN lacks a part (never OpenAI in mode 3). Voices: realtime / LAN / AVSpeech best-first with
  download hint (Settings › Accessibility › Spoken Content › Voices).
- **In-app settings** `DeeSettingsView`: gear `settingsButton`, **two-finger long-press on the eyes** (one-finger 0.8 s stays the hug `.hold`), status
  chip. Sections: mode, OpenAI key (Replace/Remove, last 4), LAN endpoints/keys/models + Test, wake phrase, voice, speak first, share memories, age,
  start over, today's usage, privacy, run onboarding, about. Saving never touches the network while dormant (W2 test).
- **Settings.bundle removed entirely.** Keychain `KeyStore(account:)`: "openai.api-key" (`sk-`), "lan.<part>.key". `providerConfig` JSON, prefs
  `onboardingVersion=1`, `wakePhrase`, `speakFirst`.
- `UsageCounter` (DeeCore): day buckets {streamedSeconds, responses, falseWakes} per mode; log at close "window closed: open 42 s, streamed 18.2 s,
  3 responses, mode lanEverything" (numbers only). `DNASplit` (DeeCore, pure): stable/volatile by section number; mode 1 never uses it.
- Info.plist: ATS `NSAllowsLocalNetworking`, `NSLocalNetworkUsageDescription`, `NSBonjourServices` for the prompt, `NSSpeechRecognitionUsageDescription`,
  provider-neutral mic/calendar/contacts/location texts, MARKETING_VERSION 0.6.0, AI-voice disclosure modes 1/2 only.
- Accessibility: labels, Dynamic Type + ScrollView per page, all sizes, dark. UITest ids `onboardingNext`, `providerOpenAI`, `providerLanBrain`,
  `providerLan`, `apiKeyField`, `serverAddressField`, `testConnection`, `onboardingDone`, `wakeState`; args `-DeeResetOnboarding`, `-DeeSkipOnboarding`.

## 6. Harness (harness implementer)
- **Spoken-only scoring:** `spokenText` = joined `heardSentences` (transcript only if playback started untruncated) for Leak/Narration scanners and
  Judge; `leaksUnspoken` information only. Tests: cancelled+narration → 0, played → 1.
- `--wake always-open` (explicit, asserted) for the 28 tune2 baseline; **plus `--wake phrase` subset** scored with the same gates: one-breath
  question, pause after phrase, follow-up after close/re-wake (65 s gap), backchannel in the first window turn. HarnessHost calls `Engagement.answers`.
- `--provider openai|lan-brain|lan --lan URL --model ID [--stt URL|on-device] [--tts URL|on-device]`; spend cap from usage (mode 2 ≤ $1.00).
- **Wake suite:** accept "Hey Dee" ≥ 95%, custom ≥ 90%; false wakes/hour over 10-min fan/kitchen/TV + talk-radio beds and unaddressed "Dee" speech
  (gate 0); window length after a TV-bed wake (closes 60 s ± 2); phrase end → candidate cue, → eyes, → first audio p50/p90, volatile vs final hits
  reported separately, next to warm-socket tune2 first audio; W2/W3 per mode; one-breath answered.
- **Local mode (information, looser):** first audio p50 ≤ 4.5 s / p90 ≤ 8 s warm, "cold after dormant" separate; cached/prompt tokens per turn; chat
  requests per turn; sentence gaps; on-device commit→completed p90 ≤ 0.5 s (gate); tool-call rate + memory accuracy; WER ≤ 12%; backchannel/overlap
  gates in mode 3 with LAN STT reported as gates; 0 spoken think/markdown leaks (gate).
- **DeeMockServer:** `/v1/models`, `/api/show`, `/api/ps`, `/api/v0/models`, chat SSE (reasoning, reasoning_content, stray `</think>`, tool calls whole/
  split), native `/api/chat` NDJSON (tool args object, split chunks, done+eval counts, keep_alive echo), 200+error body, model fallback, slow first
  token, 401/404/500, 302 and 307-to-public, refused port, hanging accept, transcriptions, speech pcm, WS `/v1/realtime` toggle.
  Tests: `DeeWakeTests`, `DeeLocalTests`(+mock). Release checklist: 1-hour iPhone soak (CPU/energy/memory/thermal), iPhone wake latency.

## 7. Failure → user message (chip; nothing over the network while DORMANT)
| Case | Message |
|---|---|
| no / bad OpenAI key | "I need an OpenAI key — open my settings" / "That OpenAI key didn't work" |
| local network denied | "Dee needs Local Network access — Settings › Privacy & Security › Local Network" |
| LAN refused / timeout | "I can't reach the AI server at HOST" + hint: Ollama "turn on Expose Ollama to the network (OLLAMA_HOST=0.0.0.0)"; LM Studio "start the server with network access (bind 0.0.0.0)"; other "make sure it listens on your network, not just localhost" |
| LAN 401 / model missing / loading | "The AI server at HOST wants a key" / "HOST doesn't have MODEL" / "The AI server is loading MODEL…" |
| redirect / public http / sk- over http | "HOST tried to send me elsewhere" / "Use https for servers outside your home network" / key refusal above |
| no STT/TTS on LAN | onboarding offers "on this iPhone" |
| ear unavailable / not asked / hot | "I can't hear my wake phrase — tap me to talk" (+ Settings link / permission card / "I'm too warm to listen") |
| transcription mint 400/404 | "OpenAI hearing isn't available for this key" (no fallback) |

## 8. Ownership (edit only your rows; no commits) and APIs each publishes first
| Implementer | Owns | Publish first (stubs that compile, before others use them) |
|---|---|---|
| wake | `Package.swift`, `Sources/DeeWake/**`, `Tests/DeeWakeTests/**` | §3 types, `ConversationWindow` inputs/actions, `Engagement.answers`, `WakeMatcher.stripLeading`, `MatchTier` |
| voice | `Sources/DeeVoice/**`, `Sources/DeeRealtime/**`, their tests | `Transport` (+recorder), `OpenAIAuth(sessionType:)`, `TimingProfile`, `reconfigure`, `connect(resume:)`, `CloudVoice.sleep/wake(onsetFrame:)`, `ClipRenderer`, listening cues, transcription-probe constant |
| local | `Sources/DeeLocal/**`, `Sources/DeeMockServer/**`, `Tests/DeeLocalTests/**` | §1 provider types, `AddressParser`, `ServerProbe`, `ProviderFactory.make`, `DeeMockServer.start(cases:) -> URL` |
| app | `App/**`, `Sources/DeeCore/**`, `Sources/DeeBrain/**`, `Sources/DeeSelf/**`, their tests, `docs/**` | `DNASplit`, `UsageCounter`, `OnboardingStep`, `SpokenCommand.changeWakePhrase`/closeCommand, `RealtimeBrain.Options.timing`, StandaloneHost window rule |
| harness | `Tools/voice-harness/**` | flags in §6, `spokenText`, wake-suite report schema |
Interfaces change only by their owner, announced before use.

## Review log (rev 2)
Accepted and resolved: TP1–TP10; set 2 F1–F15; set 3 F1–F16; LQ-1–LQ-7, LQ-9–LQ-12. Partial / rejected (one line each):
- set 2 F6 "mint on candidate match": rejected, W2 forbids dormant mints; the local candidate cue gives the instant reaction.
- set 2 F10 chunked LAN STT uploads: rejected, per-backend `TimingProfile` + mode-3 gates cover it cheaper. set 2 F15: speech card conditional, not removed.
- LQ-8 "hold first sentence when a tool looks likely": rejected, latency on every turn; memory prefetch + tool policy instead, tool rate measured.
- set 3 F16 suffix names: accepted only with resolve-then-private-check and IP-literal http (ATS cannot vouch for `.lan`/`.home.arpa`).
