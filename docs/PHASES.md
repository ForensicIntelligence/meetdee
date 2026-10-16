# Dee — Phased Development Plan

**Developer:** Forensic Intelligence

Dee is a Loona/Wall-E-style robot companion that lives in an iPhone. It talks and has
expressive animated eyes. Her face, senses, mind, self and memories run on the device;
from 0.6 her hearing, words and voice come from OpenAI's realtime speech-to-speech model
(`gpt-realtime-2.1-mini`), prompted every turn with her current state ("Dee DNA"). Until
0.5 the brain was a local language model; it was removed in 0.6 (see `DEVLOG.md`). ROS
integration comes in a later major version.

Every phase ends with: `swift test` green, iOS app building, a DEVLOG entry, a git
commit (staging `Dee/` only — the Desktop repo is shared), and a project-notes
update. Each phase is one **minor version**.

| Version | Phase | Scope | Status |
|---|---|---|---|
| 0.1 | Foundation | Xcode project (XcodeGen → `Dee.xcodeproj`), `DeeKit` package, the first local language-model brain (prompt builder, streaming output parser, agent loop with tools; removed in 0.6), thinking-intent detector, minimal chat UI | **Done** |
| 0.2 | The Face + Camera | `DeeFace`: 16 expressions (Loona eyes, Wall-E tilt/lids), spring-driven parameters, blinks/double-blinks, saccades, breathing, squash & stretch, glyphs (hearts, stars, zzz, ?, thinking dots), Canvas + TimelineView at 120 Hz. `DeeSense`: front camera (Vision) — eyes follow your face, Dee wakes when you appear and dozes when you leave, hand gestures (wave = hello, open palm = stop, thumbs-up). Full-screen, face-first layout; keyboard is debug-only | **Done** |
| 0.3 | The Mind | `DeeMind`: emotion + personality engine — 13 traits + 13 feelings = 26 parameters, each a byte; the whole state is one 52-hex-character **MindCode**. Appraisal of what is said (on-device sentiment + negation-aware lexicons) and how (loudness/rate vs the user's baseline, caps, dominance). Half-life dynamics, anger → resentment, repair via kindness/apology (with apology fatigue), Tamagotchi needs (loneliness, energy, boredom), slow personality drift. Eye colour = regard for the user, red → yellow → green. Optional age and ageing (variable rate) reshaping traits and dynamics. SQLite persistence of state only — never transcripts. Mood cue fed to the model each turn. See `docs/MIND.md` | **Done** |
| 0.4 | She's alive | **Voice** (`DeeVoice`: hands-free STT/TTS, prosody → Mind, unexpected-sound detection, barge-in), **touch** (pet/hold/tap/poke/slap/tickle → feelings and personality), **sight** from both cameras (Vision classification, novelty), **reflexes** above mood (she laughs at a joke even when upset), **curiosity director** (very interactive: asks about what she sees and hears), **expressive eyes** (37 emotions, glyph eyes, performances, idle director, per-occurrence variation), **people memory** (`DeeMemory`: names, face prints, facts — no transcripts). See `docs/CONTRACTS-0.4.md` | **Done** |
| 0.5 | Someone | One shared `Moment` state (momentary / ongoing / enduring) driving words, voice, gaze, expression, attention and memory: persistent self-model, motivations and intentions, model of the user's perspective, emotional continuity, autobiographical episodes, anticipation ("How did it go?"), shared attention, conversational timing, taste/humour/rituals, self-reflection, relationship repair, mannerisms. Time away carries no relationship penalty. See `docs/SELF.md` and `docs/research/self-model-brief.md` | **Done** |
| 0.6 | Realtime voice + Dee DNA | OpenAI `gpt-realtime-2.1-mini` hears, thinks and speaks: `DeeRealtime` (GA events, WebSocket, Keychain key + ephemeral secrets, session actor with barge-in truncation, rollover, trace replay), `DeeVoice` audio graph (VPIO, 24 kHz capture with pre-roll, stream player with exact played-ms), the realtime brain behind `ReplyEngine`, memory tools as realtime function tools. **Dee DNA**: a comprehensive description of her current personality, feelings, self and relationship in every prompt (`docs/DNA.md`). Thinking = per-response reasoning effort. The local model is removed; offline is a visible "no connection" state while eyes, touch and camera stay alive. Privacy texts rewritten (all microphone audio goes to OpenAI while online; 30-day abuse-monitoring retention). **AI-voice disclosure** (an OpenAI usage-policy requirement for synthetic voices) ships with the voice, in this release | In progress |
| 0.7 | Agentic tools | `DeeTools` as realtime function tools: clock/date, timers & alarms (AlarmKit), calendar & reminders (EventKit), contacts, device status, location, calculator/units; permission UX by voice | Planned |
| 0.8 | Cloud fit | API-key entry and an ephemeral-key minting service, spend limits and cost telemetry, network-quality and offline UX polish, "share memories with the cloud voice" setting, first-launch flow | Planned |
| 0.9 | Polish & hardening | Accessibility (VoiceOver, Reduce Motion), performance on device (turn latency, energy, network), adversarial review pass, App Store readiness | Planned |
| 0.10 | Magazine series | Draft the article series from `DEVLOG.md` | Planned |
| 1.0 | Release candidate | — | — |
| 2.x | ROS | Robot body via ROS 2 bridge | Future |

## Key decisions

- **Hands-free by design (user requirement):** every interaction is voice and/or
  camera. No typing in the shipping UI; a text field exists only in Debug builds.

- **Brain in the cloud, everything else on the device (0.6).** Hearing, words and
  voice come from `gpt-realtime-2.1-mini` over a WebSocket on Dee's own audio engine
  (local echo cancellation, levels, prosody and exact played-time stay available). There
  is no offline language model: without a connection she cannot talk, shows it, and
  her face, touch, camera and feelings carry on.
- **Context:** the realtime session holds up to 128k tokens with server-side
  truncation; sessions roll over before the 60-minute cap, seeded with a summary and
  the last turns. Her persona and self block are the session instructions; her
  per-turn state goes with each response.
- **Thinking off by default.** "Think about it" (and ~30 similar phrasings, see
  `ThinkingIntent`) raises the reasoning effort of that one reply (`low` → `medium`);
  "turn on thinking mode" keeps it raised for the conversation; a new conversation
  turns it off. Manual brain toggle in the debug UI as well.
- **Privacy:** camera video, face prints and the databases behind the MindCode, the
  self model and people memory stay on the device. While online, all microphone audio
  (whoever is talking, with a short pre-roll), transcripts, and every turn's Dee DNA
  (a description of her personality, feelings, self and relationship, the person's
  name, what she sees in a few words, recalled facts and memories) go to OpenAI: no
  training on API data, up to 30 days in abuse-monitoring logs. See `README.md`.
- **Minimum hardware:** any iPhone that runs iOS 26; no large model is held in memory.
