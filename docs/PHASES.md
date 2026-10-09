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
| 0.2 | The Face | `DeeFace`: 16 expressions (Loona eyes, Wall-E tilt/lids), spring-driven parameters, blinks/double-blinks, saccades, breathing, squash & stretch, glyphs (hearts, stars, zzz, ?), touch reactions (pet/poke), gaze follows touch; Canvas + TimelineView at 120 Hz; full-screen face-first layout with a collapsible transcript | Planned |
| 0.3 | Voice | `DeeVoice`: SpeechAnalyzer/SpeechTranscriber on-device STT with end-of-utterance detection; AVSpeechSynthesizer streamed sentence-by-sentence through an AVAudioEngine effects chain (cute robot timbre); amplitude envelope drives eye bounce; echo cancellation; barge-in | Planned |
| 0.4 | Agentic tools | `DeeTools`: clock/date, timers & alarms (AlarmKit), calendar & reminders (EventKit), contacts, device status (battery, thermal, storage), location (CoreLocation), calculator/unit conversion, `remember`/`recall` memory, `set_mood`; permission UX | Planned |
| 0.5 | Thinking UX | Visible "pondering" face while reasoning, thought-bubble transcript, thinking-mode indicator and manual toggle polish, per-conversation reset, reasoning budget tuning on device | Planned |
| 0.6 | Memory & persona | SwiftData persistence of conversations and long-term memories, user name onboarding, persona settings (voice pitch, chattiness), memory review UI | Planned |
| 0.7 | Model delivery & device fit | Background Assets (Apple-hosted, `essential` pack) vs bundled build configurations, memory gating via `os_proc_available_memory`, thermal throttling behaviour, first-launch flow | Planned |
| 0.8 | Polish & hardening | Accessibility (VoiceOver, Reduce Motion), performance on device (prefill/decode tok/s, energy), adversarial review pass, App Store readiness | Planned |
| 0.9 | Magazine series | Draft the article series from `DEVLOG.md` | Planned |
| 1.0 | Release candidate | — | — |
| 2.x | ROS | Robot body via ROS 2 bridge | Future |

## Key decisions

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
