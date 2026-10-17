# Dee

A pocket robot companion for iPhone: Loona's eyes, Wall-E's soul. 

Dee's face, senses,
feelings, memories and sense of self are computed on the device; Dee's voice and words
come from either OpenAI's realtime speech-to-speech model (`gpt-realtime-2.1-mini`, or
`gpt-realtime-2.1` in Settings), or an accessible LAN-base equivalent which hears Dee's human, answers in character and speaks.
Before every reply and every time Dee speaks first, the model is given a full
description of who Dee is and how Dee feels right now ("Dee DNA", `docs/DNA.md`). Dee's
voice is an AI voice: Dee says so the first time Dee talks through the cloud,
and the screen shows it.

Without a connection (or without a key) Dee stays alive — eyes, touch, camera, feelings —
but cannot talk. A small status chip says why ("Add your OpenAI key in Settings › Dee",
"OpenAI refused the key", "No connection", "rate limited", "LAN Model not Accessible") and Dee's eyes take a quieter,
puzzled look until Dee's voice is back. There is no local language model, only LAN-based (ie: Ollama running on a Mac or PC) or OpenAI.  Maybe I'll change that later.

Note that "Dee" is more or less useless at this time. A modern Tamagochi, if you will.  But maybe Dee has a future as an Agentic Harness? 

---

## What this repository contains

Dee **0.6.0** (`MARKETING_VERSION` in `project.yml`). This is a phone test build: the realtime
voice and Dee DNA (tuned over 14 live rounds), first-launch onboarding, in-app settings and key
entry, three provider modes (OpenAI, a LAN brain with OpenAI speech, or LAN for everything), an
on-device wake phrase, and six personas. `docs/PHASES.md` has the plan and status;
`docs/DEVLOG.md` tells the story.

## The three modes

You pick a mode during onboarding and can change it any time in Dee's settings.

| | 1. OpenAI for everything | 2. Your Mac's brain, OpenAI's voice | 3. Your own network for everything |
|---|---|---|---|
| Hears (speech to text) | OpenAI realtime (`gpt-realtime-2.1-mini`) | OpenAI realtime transcription (`gpt-transcribe`) | A LAN speech server (`/v1/audio/transcriptions`), or this iPhone (Apple on-device speech) |
| Thinks | OpenAI realtime, same session | Your LAN server (`/v1/chat/completions`) | Your LAN server |
| Speaks (text to speech) | OpenAI realtime, same session | OpenAI `gpt-4o-mini-tts` (`/v1/audio/speech`) | A LAN speech server (`/v1/audio/speech`), or this iPhone (`AVSpeechSynthesizer`) |
| Needs | An OpenAI API key | An OpenAI key and your server's address | Your server's address. Speech servers are optional |
| Cost | Paid per use by your key | OpenAI speech only, cheaper than mode 1 | Free |
| Speed | Answers in about a second | Slower; depends on your model | Slowest; depends on your hardware |

- **Mode 1** is the tuned realtime path, unchanged from the 14 tuning rounds. One realtime
  WebSocket session hears, thinks and speaks.
- **Modes 2 and 3** run `DeeLocal.CascadeSocket`, which speaks the same realtime protocol to the
  rest of Dee and is built from separate parts underneath: hearing, a chat model and a voice.
  Turn-taking, barge-in, backchannels ("keep going") and Dee DNA work the same way on top. Each
  reply is spoken sentence by sentence while the model is still writing. Hidden text (`<think>`
  blocks, reasoning, markdown, emoji) is never spoken.
- **No crossover.** Mode 1 never contacts a LAN host. Mode 3 never contacts OpenAI. In mode 2,
  OpenAI is used only for hearing and speaking and the LAN server only for thinking. When a part
  fails, Dee shows a problem; it never quietly switches to another provider.

### LAN servers

Any server with the OpenAI-compatible API works: `GET /v1/models` and streaming
`POST /v1/chat/completions` for the brain, and optionally `/v1/audio/transcriptions` and
`/v1/audio/speech` for hearing and voice.

- **Tested with** Ollama (default port 11434) and LM Studio (1234). llama.cpp's server (8080) and
  vLLM are recognised by the probe. Any other port works too: type `host:port`, for example
  `192.168.1.20:8000` or `my-mac.local:11434`. For speech, the examples are a Whisper server
  (`:8000`) for hearing and Kokoro-FastAPI (`:8880`) for voice.
- **Test connection** probes the server: which models it lists (non-chat models are filtered out),
  whether it streams chat, supports tools, can transcribe and can speak, and whether the model is
  already loaded ("the first answer after a pause takes N s" if not). Ollama gets a `keep_alive`
  on every request, so the model stays loaded between conversations.
- **Servers that run one request at a time** (a single slot that answers a second request with
  HTTP 429, as some local servers do) are supported. Dee sends chat requests to one server strictly
  one after another: each request holds that server's lane until its stream has closed (finished,
  failed or cancelled), and a new request after a cancel waits for the cancelled one to close. A
  reply refused with 429 is retried for up to 8 seconds (honouring `Retry-After`); after that the
  turn fails with a "talking too much" problem naming the server, never another provider.
  Servers that queue on their own (Ollama) lose nothing by it.
- **Prompt caching.** Many servers (Ollama among them) move every system message to the top of the
  prompt, so anything that changes per turn goes in the user message, and the stable part of the
  Dee DNA is pinned: small changes are sent as "(updated)" lines in the per-turn part. Each request
  then repeats the previous one byte for byte up to the last user turn, so the server can reuse its
  cache. On a 27B model, changing only the user message gave a first token in 0.19 s; changing a
  system message, 8.49 s.
- **Turn endings.** In modes 2 and 3 a turn is committed about 1.1 s after you stop talking (1.7 s
  when the words trail off, as in "…and then we went to the"), so short pauses mid-sentence don't
  split one utterance into two turns.
- **Let the server listen on your network.** Ollama and LM Studio listen only on the Mac itself by
  default. Ollama: turn on "Expose Ollama to the network" (`OLLAMA_HOST=0.0.0.0`). LM Studio: start
  the server with network access. Allow the port through the Mac's firewall.
- **Local Network permission.** iOS asks once whether Dee may find devices on your local network.
  Without it every LAN request fails, and the chip says "Dee needs Local Network access — Settings ›
  Privacy & Security › Local Network".
- **Plain `http` only on your own network.** Private addresses (192.168.x.x, 10.x.x.x,
  172.16–31.x.x, 100.64/10, link-local, IPv6 ULA) and `*.local` / single-label names may use
  `http`. A server outside your home network needs `https`. Redirects from a LAN server are
  refused. A server key is optional; an OpenAI key (`sk-…`) is refused on a plain-http LAN address,
  because it would cross your Wi-Fi unencrypted.

## The wake phrase

In every mode, Dee listens for the wake phrase **on the iPhone** with Apple's on-device speech
recognition (SpeechAnalyzer). Nothing leaves the phone until the phrase is heard on the device:
a server transcript can never wake Dee.

- **Default:** "Hey" plus the persona's name ("Hey Mira" for the default persona). You can change it
  in onboarding, in settings, or by voice ("change your wake phrase to …", then "yes"). Phrases are
  1 to 4 words; a very short phrase gets a warning, because it wakes Dee by accident more often.
- **Dormant means disconnected.** While Dee waits for the phrase there is no socket, no HTTP
  request, no key mint and no audio sent. Only "Check key" and "Test connection", when you tap
  them, use the network.
- **The conversation window.** The phrase (or a tap on the screen outside the eyes) opens a
  conversation: Dee connects and sends the audio from just before the phrase, so "Hey Mira, what
  time is it?" works in one breath. While the window is open you don't need the phrase. It closes
  after about a minute with nothing said to Dee once Dee is done talking, and at the latest 10
  minutes after the last turn Dee took up. A TV in the background does not keep it open. Coming back within 5 minutes carries
  on the same conversation.
- **"Go to sleep"**, "goodnight", "stop listening" or "that's all" close the window at once, after a
  short goodbye.
- **Speak first** (off by default): when Dee sees someone Dee knows arrive, Dee may say hello, which
  opens one short conversation without the phrase.
- **False wakes.** A window that closes with nothing answered counts as a likely false wake. After
  3 in 10 minutes, Dee accepts only exact matches for 15 minutes.
- **Noisy rooms.** In the wake suite, "Hey Dee" was heard 100% of the time in a quiet room, but only
  82.5% overall with a fan, kitchen or TV at 15 dB (65% next to the TV). There were 0 false wakes in
  36 minutes of noise and 48 unaddressed uses of the name. In a loud room, say the phrase a little
  closer or tap the screen. The persona phrases ("Hey Mira", "Hey Rio", …) are not in the wake
  suite yet.
- **Keep Dee open.** Listening runs only while the app is open in the foreground (there is no
  background microphone), ideally on a charger. The screen stays on and dims to an idle face.

## Personas

Dee comes with six adult personas, two female, two male and two not identified, one in their
twenties and one in their forties for each. Each has its own Dee DNA (13 traits and resting
feelings, at its age), humour, tastes, rituals, way of speaking, voice and wake phrase. **Mira is the
default.**

| Persona | Pronouns | Age | Hook | OpenAI voice | Voice on the iPhone (mode 3) |
|---|---|---|---|---|---|
| **Mira** (default) | she/her | 24 | A wide-eyed best friend who finds something wonderful in everything | `marin` | Female (Zoe, Ava, Samantha…) |
| **Vera** | she/her | 46 | Warm, unflappable, dry; tells you the truth kindly | `sage` | Female (Allison, Susan, Serena…) |
| **Rio** | he/him | 27 | A high-energy hype man with a teasing grin | `verse` | Male (Evan, Nathan, Aaron…) |
| **Atlas** | he/him | 44 | Calm as a lighthouse; deadpan you'll miss the first time | `cedar` | Male (Tom, Daniel, Nathan…) |
| **Nova** | they/them | 23 | A night-owl daydreamer; quiet until something sparks | `alloy` | Any (Zoe, Ava, Evan…) |
| **Haven** | they/them | 47 | Grounded, quietly sure; makes hard days smaller | `ballad` | Any (Jamie, Oliver, Susan…) |

- The names come from the DNA: Mira (to wonder), Vera (true), Rio (a river, flow), Atlas (holds
  steady), Nova (new things), Haven (a safe place).
- Picking a persona sets its age (ageing off; if you turn ageing on, the default is real time),
  its personality set points and resting feelings, its humour, tastes, voice, speaking style and
  default wake phrase. The people Dee knows, shared episodes, lessons and the relationship are
  kept; the current mood starts fresh. A wake phrase or voice you chose yourself is kept (Dee
  asks before replacing a hand-picked voice).
- In mode 3 with on-device speech, Dee picks the best installed Apple voice that fits the persona.
  Better voices: Settings › Accessibility › Spoken Content › Voices (download an Enhanced or Premium
  English voice).
- An install from before 0.6.0 keeps "Classic Dee" (today's childlike robot) until another persona
  is chosen.

## How Dee works

- **One conversation pipe.** `DeeVoice.CloudVoice` runs the microphone and speaker on one audio
  graph (voice-processing I/O, so Dee's own voice is cancelled from the microphone) and talks to a
  `RealtimeSocket`: OpenAI's Realtime WebSocket in mode 1 (`DeeRealtime`), or `CascadeSocket` in
  modes 2 and 3. Server VAD never answers on its own.
- **Who decides when Dee answers.** `DeeBrain.RealtimeBrain`. While a window is open, it answers at
  once with a Dee DNA built from Dee's current state and from how the words sounded. When the words
  change the right answer, it first waits briefly for the transcript: repair after an argument, a
  loud voice, a pending follow-up, a stated mood, a stranger's first words, speech right after Dee
  spoke. A TV is never answered. While dormant, nothing is answered.
- **Spoken commands** are carried out by Dee and never sent to the model as something to answer:
  "stop" or "be quiet" while Dee is talking, "keep going", "start over" or "new conversation",
  "go to sleep" or "that's all", and changing the wake phrase.
- **One DNA at a time.** Before each reply or initiative a fresh Dee DNA is inserted and the
  previous one is deleted. In modes 2 and 3 the stable part of the DNA is a pinned system message
  and everything that changes every turn goes with the user's words (see Prompt caching above).
- **Tools.** `remember`, `recall` and `forget` work on Dee's memory of people. The device tools are
  `calendar_events`, `add_calendar_event`, `reminders`, `add_reminder`, `find_contact` and
  `where_am_i` (town and area). Each asks for its iOS permission the first time it is used. In
  modes 2 and 3 tools are offered only if the probe found that the server supports them.
- **Short sounds.** Laughs, a giggle, "Oh, sorry. Go on." and "One sec." are rendered once in the
  persona's voice (OpenAI `gpt-4o-mini-tts` in modes 1 and 2, the LAN voice or the iPhone in mode
  3), kept on the device and played locally. They are rendered only while a window is open.
- **Long conversations.** Realtime sessions end at 60 minutes. In mode 1 Dee moves to a fresh
  session at a quiet moment, carrying over a short summary and the most recent messages. In modes 2
  and 3 the history sent to the server is the last 12 messages plus a short summary kept on the
  phone.
- **Offline.** The eyes, touch, camera and on-device sound recognition keep working.
- Contracts: `docs/contracts-0.6/realtime.md`, `docs/contracts-0.6/brain.md`,
  `docs/contracts-0.6/providers-wake-onboarding.md`; app decisions: `docs/app-0.6.md`.

## Privacy and data flow (0.6.0)

**In every mode:**

- **The wake phrase is heard on the iPhone only.** While Dee is dormant, nothing is sent anywhere:
  no audio, no connection, no key check. The audio kept for the phrase (a ring of 12 seconds) never
  leaves the phone while dormant.
- **When the window closes** ("go to sleep", "that's all", a minute of quiet, or the app going to
  the background), the microphone audio stops and the connection is closed at once.
- **Stays on the device:**
  - **Camera video.** It is processed on the device to follow faces, recognise people and notice
    things, and it is never recorded or sent. Only a few words about what Dee sees reach the DNA.
  - **The people Dee knows** (`DeeMemory.sqlite`): people and aliases, face prints, short facts.
  - **Dee's self model** (also `DeeMemory.sqlite`): episode gists (up to 100 characters),
    follow-ups, intentions, lessons, boundary topics, interests and tastes. These are short derived
    notes, not transcripts. `DeeMemory.sqlite` is excluded from iCloud and device backups.
  - **Dee's mind: emotions, personality and age** (`DeeMind.sqlite`). Numbers only (traits,
    feelings, daily totals); included in normal device and iCloud backups.
  - **Local analysis:** the wake phrase, sound recognition (laughter, a doorbell, …) and voice
    prosody.
  - **Keys.** The OpenAI key and any LAN server keys are stored only in the Keychain ("when
    unlocked, this device only"), never in preferences or logs. A key from the 0.5 Settings-app field
    is moved into the Keychain at the first launch of 0.6.0, without any network request, and the
    plain copy is deleted.
- **Rules for the Dee DNA:** it is rebuilt from Dee's state for every response and never written
  to disk or logs; a privacy guard makes sure it never repeats five words in a row of what was said
  in the session; sensitive facts are never included.
- The user's words are kept in memory for the session's privacy guard and are not saved as a
  transcript.

**Mode 1, OpenAI for everything.** While a window is open, OpenAI receives:

- **Everything the microphone picks up** (the user, anyone nearby, the TV), from about 0.3 seconds
  before the wake phrase or tap until the window closes. Background sound that is only the room's
  bed is turned down by about 30 dB before sending, but it is still sent. OpenAI transcribes it;
  speech that was not for Dee is deleted from the conversation afterwards, but it has been
  uploaded.
- **The Dee DNA with every reply and initiative:** the persona's personality, current feelings and
  self; the relationship with the person and their name; a few words about what Dee sees; the facts
  and shared memories Dee recalls about them. Turn off **Share memories** to keep facts, shared
  moments, recall notes, running jokes, interests and upcoming events out of the DNA and to withhold
  the memory tools. The person's name is still sent, and Dee may still mention a follow-up subject
  (such as "job interview").
- **Transcripts and Dee's replies,** plus the summary and recent messages carried into a new
  session.
- **Results of tools you ask for:** an event title, a contact's details, the name of your town
  (for example up to 8 calendar events or 10 open reminders).
- **The text of the short sounds,** sent once to render them.
- **The key:** checked with `GET /v1/models` when you tap "Check key", and used to get short-lived
  realtime client secrets for each connection.

**Mode 2, a LAN brain with OpenAI's voice.**

- **OpenAI** receives the microphone audio during a window (realtime transcription session,
  `gpt-transcribe`) and the text of each of Dee's sentences, with a style line, to speak it
  (`gpt-4o-mini-tts`), plus the short sounds' text.
- **Your LAN server** receives the Dee DNA, the transcripts, the recent history and summary, the
  memories Dee recalls (when **Share memories** is on) and tool results.
- OpenAI does not see the DNA or the memories.

**Mode 3, your own network for everything.**

- **Nothing goes to OpenAI.** The DNA, transcripts, memories and tool results go only to your LAN
  server, during a window. Audio goes to your LAN speech server, or stays on the iPhone when
  hearing is "on this iPhone"; the same for the voice.
- With **Share memories** off, the memories stay on the iPhone in this mode too.

OpenAI does not train on API data. It may keep data for up to 30 days in its abuse-monitoring logs,
unless the account is approved for Zero Data Retention. What a LAN server keeps is up to that server.

## Requirements

- An iPhone running **iOS 26** or later (the target also builds for iPad), with Apple's on-device
  speech recognition available for the wake phrase (Siri & Dictation language assets; onboarding
  downloads them).
- A Mac with **macOS 26** and **Xcode 26** (Swift 6.2 toolchain, iOS 26 SDK). DeeKit uses Swift
  tools 6.2; the app uses Swift 6. The DeeKit tests and the voice harness run on macOS 26.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), if you change `project.yml` or use
  `scripts/build-app.sh` (it always regenerates the project).
- **Modes 1 and 2:** an OpenAI API key. Mode 1 uses the Realtime API (including client secrets);
  mode 2 uses realtime transcription sessions and text-to-speech. Both use `GET /v1/models` for the
  key check and `gpt-4o-mini-tts` for the short sounds.
- **Modes 2 and 3:** an OpenAI-compatible server on your network with a chat model (Ollama, LM
  Studio or similar), reachable from the iPhone.

## Setup

1. **Open the project.** Clone the repository and open `Dee.xcodeproj`, which is committed. If you
   edit `project.yml`, regenerate it with `xcodegen generate`.
2. **Set up signing.** `project.yml` sets the developer team and the `ca.forensicintelligence`
   bundle prefix. Change both to your own, in `project.yml` (then regenerate) or in Xcode's Signing
   settings. Changes made only in Xcode are lost when the project is regenerated. The `DeeUITests`
   target has its own bundle ID (`ca.forensicintelligence.dee.uitests`), which also needs changing.
3. **Build and run** the `Dee` scheme on your iPhone. `scripts/build-app.sh` regenerates the project
   and builds for the iOS Simulator. Camera, voice and the wake phrase need a real device.
4. **Onboarding** runs at the first launch. Nothing uses the microphone, camera or network until it
   is done, and each permission is asked on its own card.
   1. Meet Dee, how talking works, what Dee sees, and privacy and cost per mode.
   2. Permissions: microphone, speech recognition, camera, local network. **Skip** jumps straight to
      the provider.
   3. **Who does the thinking:** pick a mode.
      - OpenAI key: paste it into the key field and tap **Check key**. Use a dedicated project key
        with a monthly spend limit. If you restrict it, keep Realtime (including client secrets),
        Audio (speech) and read access to Models. A 401 or 403 means a refused key.
      - LAN server: type its address or tap a preset (Ollama, LM Studio, llama.cpp), add a key if the
        server wants one, tap **Test connection** and pick a model. In mode 3 choose hearing and
        voice: the same server, another server, or "on this iPhone".
   4. **Choose your companion:** one of the six personas (Mira is preselected), with a spoken
      sample of each voice on tap.
   5. Wake phrase, voice and **speak first**, then any permission cards still undecided, then
      **Done** (only once the provider checks out).
5. **Talk:** say "Hey Mira" (or your phrase), or tap the screen outside the eyes.

### Settings (in the app)

Open them with the gear, a **two-finger** long-press on the eyes (a one-finger press is a hug), or by
tapping an urgent status chip.

| Setting | What |
|---|---|
| Who does the thinking | Mode cards; OpenAI key (Replace / Remove, shown as `sk-…abcd`); LAN address, key, model and Test; in mode 3, hearing and voice |
| Companion | Mira (default), Vera, Rio, Atlas, Nova, Haven; switching asks first. The wake phrase and voice follow the persona unless you set your own |
| Wake phrase | Default "Hey" plus the persona's name; 1 to 4 words |
| Voice | OpenAI voices in modes 1 and 2 (the persona's own voice is marked recommended), the LAN voice name, or an installed iPhone voice in mode 3 |
| Speak first when Dee sees someone | Off by default |
| Share memories | On by default. Off keeps what Dee remembers about people on the iPhone; on, a few relevant memories go with a reply to OpenAI (mode 1) or to your own server (modes 2 and 3) |
| Age | Dee has an age, starting age, grows up, years per day |
| Today | Audio sent, responses, conversations, wakes by mistake |
| About privacy, Run the introduction again, Start over | Start over resets mood and personality at the next launch; the people Dee knows are kept |

Changes are used from the next conversation. Saving never touches the network while Dee is dormant.

## Project layout

| Path | What |
|---|---|
| `App/Sources` | The SwiftUI app shell: `DeeApp` (splash → onboarding → Dee), `DeeModel` (wires everything together), `VoiceStack` (rebuilt when the provider changes), `ProviderStore`, `Permissions`, `RootView`, `SplashView`, `People`, `SelfDriver`, `Projector`, `TouchCaptureView` |
| `App/Sources/Setup` | `OnboardingView`, `DeeSettingsView`, `ProviderSetupView`, `PersonaViews` (companion picker and settings section), `ConnectionTest`, `SetupPieces` |
| `Packages/DeeKit` | Swift package with every module that is not app shell |
| ↳ `DeeCore` | Pure Swift: persona, emotion vocabulary, spoken commands, onboarding steps, usage counter, DNA split, thinking intent, turn ledger, voice health, tool protocol, the `ReplyEngine` seam |
| ↳ `DeeFace` | The Loona / Wall-E face: expression model, procedural animator, SwiftUI view |
| ↳ `DeeVoice` | The audio graph (24 kHz capture, stream player, local VAD, prosody, sound events), `CloudVoice`, clip rendering |
| ↳ `DeeWake` | The on-device wake phrase: `WakePhrase`, `WakeMatcher`, `PhoneticKey`, `OnDeviceSpeech` (SpeechAnalyzer), `ConversationWindow`, `Engagement` |
| ↳ `DeeSense` | The front camera: who's there, where they are, hand gestures |
| ↳ `DeeMind` | Emotions, personality and age: appraisal, dynamics, SQLite persistence |
| ↳ `DeeMemory` | The people Dee knows: names, faces, facts (SQLite, on the device only) |
| ↳ `DeeSelf` | Dee's shared self: Cortex reducers, Stance, the self store, and the Dee DNA renderer |
| ↳ `DeeRealtime` | OpenAI Realtime client: event codecs, the one `Transport` every request goes through, Keychain keys and ephemeral secrets, the `RealtimeSession` actor, transcription sessions, timing profiles, trace record and replay |
| ↳ `DeeLocal` | LAN providers: `ProviderConfig`, `AddressParser`, `ServerProbe`, the OpenAI-compatible chat client (SSE and Ollama NDJSON), `CascadeSocket` (hearing, chat and voice behind the realtime protocol), `ProviderFactory` |
| ↳ `DeeMockServer` | An offline OpenAI-compatible and Ollama-native server for tests (models, chat, tools, reasoning, errors, redirects, speech) |
| ↳ `DeeBrain` | `RealtimeBrain`: when Dee answers, DNA delivery, the tool bridge, settings, key intake, the wake controller, the status chip |
| ↳ `DeeTools` | A namespace for device tools (they live in `DeeBrain` for now) |
| `Tools/voice-harness` | A macOS loopback harness: the real `CloudVoice` + session + `RealtimeBrain` against fixture speech, room noise and echo; all three modes, the wake suite, trace replay, gates, reports |
| `UITests` | XCUITest target `DeeUITests` |
| `scripts` | `test.sh` (DeeKit tests), `build-app.sh` (simulator build) |
| `docs` | Plan, devlog, DNA, mind and self designs, contracts, research |

## Testing

- `scripts/test.sh` runs the DeeKit unit tests (`swift test`). Build output goes to
  `~/Library/Caches/Dee/spm`, outside an iCloud-synced folder. `DeeBrainTests` drive the whole loop
  offline: the real audio graph in manual rendering, the real `CloudVoice` and `RealtimeSession`
  against a scripted server, and a real Mind and Cortex. `DeeWakeTests` cover the matcher, the
  conversation window and the wake corpus; `DeeLocalTests` run the LAN modes against
  `DeeMockServer`. Tests also check that nothing is sent while dormant and that no mode contacts
  another mode's provider.
- The voice harness's offline tests run from `Tools/voice-harness` with
  `swift test --scratch-path /tmp/dee-harness`; build the CLI with
  `swift build --scratch-path /tmp/dee-harness`. Live `run` needs `--wake always-open` (the tuning
  baseline) or `--wake phrase`, and `--provider openai|lan-brain|lan` (LAN modes take
  `--lan HOST:PORT --model ID`). OpenAI runs need a key in `~/.config/dee/openai-key` and cost
  money; `wake` runs the on-device wake suite with no key and no network. `validate` and `suite`
  work offline on a fresh clone. See `Tools/voice-harness/README.md`.
- The UI tests run with the `Dee` scheme's Test action in Xcode (`DeeUITests`).

## Docs

- `docs/PHASES.md`: the phased plan and status
- `docs/DEVLOG.md`: the running developer log (the source for the magazine series)
- `docs/DNA.md`: Dee DNA, the personality, feelings and self described to the model every turn
- `docs/contracts-0.6/providers-wake-onboarding.md`: the three modes, the wake phrase and onboarding
- `docs/app-0.6.md`: the app's onboarding, settings and wake-window decisions
- `docs/contracts-0.6/realtime.md`: the DeeRealtime contract
- `docs/contracts-0.6/brain.md`: RealtimeBrain, covering when Dee answers, DNA delivery, tools and settings
- `docs/contracts-0.5/`: the face, voice, sense, mind and self contracts
- `docs/MIND.md`, `docs/SELF.md`: the mind and the shared self
- `docs/research/`: research briefs (face design, iOS frameworks, self model)
