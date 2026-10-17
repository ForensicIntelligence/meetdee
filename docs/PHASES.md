# Dee — Phased Development Plan

**Developer:** Forensic Intelligence

Dee is a Loona/Wall-E-style robot companion that lives in an iPhone. Dee talks and has
expressive animated eyes. Dee's face, senses, mind, self and memories run on the device.
Since 0.6 Dee's hearing, words and voice come from a provider the user picks: OpenAI's
realtime speech-to-speech model (`gpt-realtime-2.1-mini`), a LAN model with OpenAI's speech,
or the user's own network for everything. Every turn is prompted with Dee's current state
("Dee DNA"). The wake phrase is always heard on the iPhone. Until 0.5 the brain was a local
language model; it was removed in 0.6 (see `DEVLOG.md`). ROS integration comes in a later
major version.

Every phase ends with: `swift test` green, iOS app building, a DEVLOG entry and a git
commit (staging `Dee/` only — the Desktop repo is shared). Each phase is one **minor
version**.

| Version | Phase | Scope | Status |
|---|---|---|---|
| 0.1 | Foundation | Xcode project (XcodeGen → `Dee.xcodeproj`), `DeeKit` package, the first local language-model brain (prompt builder, streaming output parser, agent loop with tools; removed in 0.6), thinking-intent detector, minimal chat UI | **Done** |
| 0.2 | The Face + Camera | `DeeFace`: 16 expressions (Loona eyes, Wall-E tilt/lids), spring-driven parameters, blinks/double-blinks, saccades, breathing, squash & stretch, glyphs (hearts, stars, zzz, ?, thinking dots), Canvas + TimelineView at 120 Hz. `DeeSense`: front camera (Vision) — eyes follow your face, Dee wakes when you appear and dozes when you leave, hand gestures (wave = hello, open palm = stop, thumbs-up). Full-screen, face-first layout; keyboard is debug-only | **Done** |
| 0.3 | The Mind | `DeeMind`: emotion + personality engine — 13 traits + 13 feelings = 26 parameters, each a byte; the whole state is one 52-hex-character **MindCode**. Appraisal of what is said (on-device sentiment + negation-aware lexicons) and how (loudness/rate vs the user's baseline, caps, dominance). Half-life dynamics, anger → resentment, repair via kindness/apology (with apology fatigue), Tamagotchi needs (loneliness, energy, boredom), slow personality drift. Eye colour = regard for the user, red → yellow → green. Optional age and ageing (variable rate) reshaping traits and dynamics. SQLite persistence of state only — never transcripts. Mood cue fed to the model each turn. See `docs/MIND.md` | **Done** |
| 0.4 | Dee's alive | **Voice** (`DeeVoice`: hands-free STT/TTS, prosody → Mind, unexpected-sound detection, barge-in), **touch** (pet/hold/tap/poke/slap/tickle → feelings and personality), **sight** from both cameras (Vision classification, novelty), **reflexes** above mood (Dee laughs at a joke even when upset), **curiosity director** (very interactive: asks about what Dee sees and hears), **expressive eyes** (37 emotions, glyph eyes, performances, idle director, per-occurrence variation), **people memory** (`DeeMemory`: names, face prints, facts — no transcripts). See `docs/CONTRACTS-0.4.md` | **Done** |
| 0.5 | Someone | One shared `Moment` state (momentary / ongoing / enduring) driving words, voice, gaze, expression, attention and memory: persistent self-model, motivations and intentions, model of the user's perspective, emotional continuity, autobiographical episodes, anticipation ("How did it go?"), shared attention, conversational timing, taste/humour/rituals, self-reflection, relationship repair, mannerisms. Time away carries no relationship penalty. See `docs/SELF.md` and `docs/research/self-model-brief.md` | **Done** |
| 0.6 | Realtime voice + Dee DNA | OpenAI `gpt-realtime-2.1-mini` hears, thinks and speaks: `DeeRealtime` (GA events, WebSocket, Keychain key + ephemeral secrets, session actor with barge-in truncation, rollover, trace replay), `DeeVoice` audio graph (VPIO, 24 kHz capture with pre-roll, stream player with exact played-ms), the realtime brain behind `ReplyEngine`, memory tools as realtime function tools. **Dee DNA**: a comprehensive description of Dee's current personality, feelings, self and relationship in every prompt (`docs/DNA.md`). Thinking = per-response reasoning effort. The local model is removed; offline is a visible "no connection" state while eyes, touch and camera stay alive. 14 live tuning rounds with the voice harness. **0.6.0 adds:** first-launch onboarding; in-app settings and key entry (Keychain only; Settings.bundle removed); three provider modes (OpenAI for everything, a LAN brain with OpenAI speech, LAN for everything with on-device speech as an option) through OpenAI-compatible servers (`DeeLocal`, `DeeMockServer`); an on-device wake phrase in every mode (`DeeWake`: dormant = no connection, a conversation window, "go to sleep"); six adult personas (Mira, Vera, Rio, Atlas, Nova, Haven; Mira is the default). Privacy texts rewritten per mode (30-day OpenAI abuse-monitoring retention in modes 1 and 2). **AI-voice disclosure** (an OpenAI usage-policy requirement for synthetic voices) ships with the voice, in this release | **Done** (0.6.0, phone test build) |
| 0.6.1 | Field fixes | Live re-check of the LAN fixes on the iPhone and the harness, kept light on the user's server (mode 2: one utterance is one turn across pauses, "keep going" stays a backchannel; mode 3: turns from Dee's own voice detector; one request at a time per server with 429 retry; cached-prompt first-token time on turn 2+); wake-phrase confusions and corpus for the six persona phrases ("Hey Mira" …) and a harness `--persona` flag; pronoun-free clip deliveries in DeeVoice; wake recall in noise (82.5% → ≥ 95% with a fan, kitchen or TV); 1-hour iPhone soak (CPU, energy, memory, heat) and wake latency on the device; audition the six persona voices on the device | Next |
| 0.7 | Agentic tools | `DeeTools` as realtime function tools (calendar, reminders, contacts and rough location already ship in 0.6): clock/date, timers & alarms (AlarmKit), device status, calculator/units, tools in every mode; permission UX by voice | Planned |
| 0.8 | Cloud fit | An ephemeral-key minting service (so the app holds no OpenAI key), spend limits and cost telemetry beyond today's usage counter, network-quality and offline UX polish. (In-app key entry, "share memories" and the first-launch flow shipped early, in 0.6.0) | Planned |
| 0.9 | Polish & hardening | Accessibility (VoiceOver, Reduce Motion), performance on device (turn latency, energy, network), adversarial review pass, App Store readiness | Planned |
| 0.10 | Magazine series | Draft the article series from `DEVLOG.md` | Planned |
| 1.0 | Release candidate | — | — |
| 2.x | ROS | Robot body via ROS 2 bridge | Future |

## Key decisions

- **Hands-free by design (user requirement):** every interaction is voice and/or
  camera. No typing in the shipping UI; a text field exists only in Debug builds.

- **Brain off the device, everything else on it (0.6).** In mode 1, hearing, words and
  voice come from `gpt-realtime-2.1-mini` over a WebSocket on Dee's own audio engine
  (local echo cancellation, levels, prosody and exact played-time stay available). There
  is no offline language model: without a connection Dee cannot talk, shows it, and
  Dee's face, touch, camera and feelings carry on.
- **Context:** the realtime session holds up to 128k tokens with server-side
  truncation; sessions roll over before the 60-minute cap, seeded with a summary and
  the last turns. Dee's persona and self block are the session instructions; Dee's
  per-turn state goes with each response.
- **Thinking off by default.** "Think about it" (and ~30 similar phrasings, see
  `ThinkingIntent`) raises the reasoning effort of that one reply (`low` → `medium`);
  "turn on thinking mode" keeps it raised for the conversation; a new conversation
  turns it off. Manual brain toggle in the debug UI as well.
- **Three providers, no crossover (0.6.0).** Mode 1 is the tuned realtime path; modes 2
  and 3 run a cascaded pipeline (hearing → chat model → voice) behind the same realtime
  protocol, so turn-taking and Dee DNA are shared. Mode 3 never contacts OpenAI. A failing
  part shows a problem and never falls back to another provider.
- **The wake phrase is local (0.6.0).** Detected only on the iPhone, in every mode. While
  dormant there is no connection and no audio leaves the phone; that removed the cost and
  privacy problem of streaming every sound in the room.
- **Personas (0.6.0).** Six adults (two female, two male, two not identified; one in their
  twenties and one in their forties each), each a complete Dee DNA with its own voice and
  wake phrase. Dee, the app and companion concept, has no gender: docs say "Dee";
  what users and the model hear uses the current persona's name and pronouns.
- **Privacy:** camera video, face prints and the databases behind the MindCode, the
  self model and people memory stay on the device in every mode. During a conversation
  window, the microphone audio (whoever is talking, from 0.3 s before the wake phrase),
  transcripts and every turn's Dee DNA (a description of the persona's personality,
  feelings, self and relationship, the person's name, what Dee sees in a few words,
  recalled facts and memories) go to the chosen provider: OpenAI in mode 1 (no training
  on API data, up to 30 days in abuse-monitoring logs); in mode 2 audio and Dee's
  sentences go to OpenAI and everything else to the LAN server; in mode 3 nothing goes
  to OpenAI. See `README.md`.
- **Minimum hardware:** any iPhone that runs iOS 26; no large model is held in memory.
