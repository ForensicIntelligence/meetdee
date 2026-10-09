# Dee — Phased Development Plan

Dee is a Loona/Wall-E-style robot companion that lives in an iPhone. It talks, has
expressive animated eyes, and runs its brain (Qwen3.5-4B, Q4_K_M GGUF, 2.74 GB)
entirely on-device through llama.cpp. ROS integration comes in a later major version.

Every phase ends with: `swift test` green, iOS app building, a DEVLOG entry, a git
commit (staging `Dee/` only — the Desktop repo is shared), and a Claude memory
update. Each phase is one **minor version**.

| Version | Phase | Scope | Status |
|---|---|---|---|
| 0.1 | Foundation | Xcode project (XcodeGen → `Dee.xcodeproj`), llama.xcframework (b11514, built with a Simulator slice), `DeeKit` package; Qwen3.5 prompt builder (golden-tested against the real Jinja template); streaming output parser (reasoning / emotion tags / XML tool calls); thinking-intent detector; agent loop with tools, compaction, reasoning budget; `LlamaEngine` with append-only state reuse and a pinned system snapshot; minimal chat UI | **Done** |
| 0.2 | The Face + Camera | `DeeFace`: 16 expressions (Loona eyes, Wall-E tilt/lids), spring-driven parameters, blinks/double-blinks, saccades, breathing, squash & stretch, glyphs (hearts, stars, zzz, ?, thinking dots), Canvas + TimelineView at 120 Hz. `DeeSense`: front camera (Vision) — eyes follow your face, Dee wakes when you appear and dozes when you leave, hand gestures (wave = hello, open palm = stop, thumbs-up). Full-screen, face-first layout; keyboard is debug-only | **Done** |
| 0.3 | The Mind | `DeeMind`: emotion + personality engine — 13 traits + 13 feelings = 26 parameters, each a byte; the whole state is one 52-hex-character **MindCode**. Appraisal of what is said (on-device sentiment + negation-aware lexicons) and how (loudness/rate vs the user's baseline, caps, dominance). Half-life dynamics, anger → resentment, repair via kindness/apology (with apology fatigue), Tamagotchi needs (loneliness, energy, boredom), slow personality drift. Eye colour = regard for the user, red → yellow → green. Optional age and ageing (variable rate) reshaping traits and dynamics. SQLite persistence of state only — never transcripts. Mood cue fed to the LLM each turn. See `docs/MIND.md` | **Done** |
| 0.4 | She's alive | **Voice** (`DeeVoice`: hands-free on-device STT/TTS, prosody → Mind, unexpected-sound detection, barge-in), **touch** (pet/hold/tap/poke/slap/tickle → feelings and personality), **sight** from both cameras (Vision classification, novelty), **reflexes** above mood (she laughs at a joke even when upset), **curiosity director** (very interactive: asks about what she sees and hears), **expressive eyes** (37 emotions, glyph eyes, performances, idle director, per-occurrence variation), **people memory** (`DeeMemory`: names, face prints, facts — no transcripts). See `docs/CONTRACTS-0.4.md` | In progress |
| 0.5 | Someone | One shared `Moment` state (momentary / ongoing / enduring) driving words, voice, gaze, expression, attention and memory: persistent self-model, motivations and intentions, model of the user's perspective, emotional continuity, autobiographical episodes, anticipation ("How did it go?"), shared attention, conversational timing, taste/humour/rituals, self-reflection, relationship repair, mannerisms. Time away carries no relationship penalty. See `docs/SELF.md` and `docs/research/self-model-brief.md` | Designed |
| 0.6 | Agentic tools | `DeeTools`: clock/date, timers & alarms (AlarmKit), calendar & reminders (EventKit), contacts, device status, location, calculator/units; permission UX by voice | Planned |
| 0.7 | Thinking UX | Visible "pondering" face while reasoning, thought-bubble transcript, thinking-mode indicator and manual toggle polish, per-conversation reset, reasoning budget tuning on device | Planned |
| 0.8 | Model delivery & device fit | Background Assets (Apple-hosted, `essential` pack) vs bundled build configurations, memory gating via `os_proc_available_memory`, thermal throttling behaviour, first-launch flow | Planned |
| 0.9 | Polish & hardening | Accessibility (VoiceOver, Reduce Motion), performance on device (prefill/decode tok/s, energy), adversarial review pass, App Store readiness | Planned |
| 0.10 | Magazine series | Draft the article series from `DEVLOG.md` | Planned |
| 1.0 | Release candidate | — | — |
| 2.x | ROS | Robot body via ROS 2 bridge | Future |

## Key decisions

- **Hands-free by design (user requirement):** every interaction is voice and/or
  camera. No typing in the shipping UI; a text field exists only in Debug builds.

- **Context window 4096 tokens** (configurable in `LlamaEngine.Configuration`).
- **Thinking off by default.** "Think about it" (and ~30 similar phrasings, see
  `ThinkingIntent`) turns it on for the rest of the conversation; a new conversation
  turns it off. Manual brain toggle in the UI as well.
- **Bundle vs download.** The App Store limit is 4 GB uncompressed (80 MB `__TEXT`),
  so the 2.74 GB GGUF fits in the bundle. Apple recommends Background Assets for large
  content and On-Demand Resources is deprecated in the iOS 27 SDK; Phase 7 adds an
  Apple-hosted asset pack. See `docs/research/appstore.md`.
- **Minimum hardware:** 8 GB iPhones (15 Pro and later). The app checks
  `os_proc_available_memory()` before loading.
