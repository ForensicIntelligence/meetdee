# Dee

A pocket robot companion for iPhone: Loona's eyes, Wall-E's soul. 

Her face, senses,
feelings, memories and sense of self are computed on the device; her voice and words
come from either OpenAI's realtime speech-to-speech model (`gpt-realtime-2.1-mini`, or
`gpt-realtime-2.1` in Settings), or an accessible LAN-base equivalent (built-in on iOS) which hears her human, answers in character and speaks.
Before every reply and every time she speaks first, the model is given a full
description of who she is and how she feels right now ("Dee DNA", `docs/DNA.md`). Her
voice is an AI voice: she says so herself the first time she talks through the cloud,
and the screen shows it.

> **About the LAN option:** LAN models arrive with **0.6.0, which is still in development**.
> The code published here talks to OpenAI only. See [Coming in 0.6.0](#coming-in-060-in-development).

Without a connection (or without a key) Dee stays alive — eyes, touch, camera, feelings —
but cannot talk. A small status chip says why ("Add your OpenAI key in Settings › Dee",
"OpenAI refused the key", "No connection", "rate limited", "LAN Model not Accessible") and her eyes take a quieter,
puzzled look until her voice is back. There is no local language model, only LAN-based (ie: Ollama running on a Mac or PC) or OpenAI.  Maybe I'll change that later.

> In the published code the chip covers OpenAI problems only: no key, key refused, no
> connection, rate limited, spend limit reached, and server trouble. "LAN Model not
> Accessible" comes with LAN support in 0.6.0.

Note that "Dee" is more or less useless at this time. A modern Tamagochi, if you will.  But maybe Dee has a future as an Agentic Harness? 

---

## What this repository contains

This repository holds the **0.6 work in progress**: the realtime voice and Dee DNA, up to
tuning checkpoint 14. `docs/PHASES.md` lists 0.6 as *In progress*. The app's version number
in `project.yml` still reads 0.5.0. The on-device wake phrase, onboarding, in-app key entry and
LAN models are **not** in this code yet. They are part of 0.6.0, described
[below](#coming-in-060-in-development).

## How she works today

- **One realtime session.** `DeeVoice.CloudVoice` runs her microphone and speaker on one audio
  graph (voice-processing I/O, so her own voice is cancelled from the microphone) and connects
  it to one OpenAI Realtime WebSocket session (`DeeRealtime`). The session uses server VAD with
  automatic responses and interruptions turned off, so it never answers on its own.
- **Who decides when she answers.** `DeeBrain.RealtimeBrain` does. If someone is with her and she
  is awake, it answers at once with a Dee DNA built from her current state and from how the words
  sounded. When the words change the right answer, it first waits briefly for the transcript.
  That covers repair after an argument, a loud voice, a pending follow-up, a stated mood, a
  stranger's first words, and speech right after she spoke. When she is asleep or nobody is
  engaged, she answers only speech meant for her, such as her name or "wake up". A TV is never
  answered. In this code her name and "wake up" are recognised in OpenAI's transcript, after
  the audio has been uploaded, not on the phone. Hearing a wake phrase on the device is what
  0.6.0 adds.
- **Spoken commands.** These are recognised in OpenAI's transcript too, so the audio is still
  uploaded. Once they are recognised, she carries them out herself and never sends them to the
  model as something to answer:
  - "stop" or "be quiet" while she is talking
  - "start over" or "new conversation"
  - "go to sleep" or "goodnight"
- **One DNA at a time.** Before each reply or initiative a fresh Dee DNA is inserted into the
  conversation and the previous one is deleted, so the conversation holds exactly one.
- **Tools.**
  - `remember`, `recall` and `forget` work on her memory of people.
  - The device tools are `calendar_events`, `add_calendar_event`, `reminders`, `add_reminder`,
    `find_contact` and `where_am_i` (rough location: town and area). Each asks for its iOS
    permission the first time it is used.
- **Short sounds.** Laughs, a giggle, "Oh, sorry. Go on." and "One sec." are rendered once with
  OpenAI text-to-speech (`gpt-4o-mini-tts`, `/v1/audio/speech`) in her voice. They are kept on the device and played locally.
- **Long conversations.** Realtime sessions end at 60 minutes. Dee moves to a fresh session at a
  quiet moment, carrying over a short summary and the most recent messages.
- **Offline.** The eyes, touch, camera and on-device sound recognition keep working. The voice
  reconnects with back-off.
- Contracts: `docs/contracts-0.6/realtime.md`, `docs/contracts-0.6/brain.md`.

## Privacy and data flow (published code)

**Sent to OpenAI** while Dee is open, connected and has a key:

- **Everything her microphone picks up:** the user, anyone else nearby, the TV.
  - In this code it streams **continuously**, whether she is awake or asleep. There is no
    on-device wake word yet: listening is on whenever she is loaded and in the foreground.
  - The stream starts with about two seconds of audio from just before she connected. After a
    reconnect or a pause, she sends the audio that had not been sent yet, again up to about two
    seconds.
  - When Dee goes to the background, listening is switched off, but the session stays open
    until iOS suspends the app (she declares no background audio, so that is soon). Until
    then, about 0.4 seconds of sustained voice near the phone reopens the stream for 3 seconds
    at a time, with the same two seconds of audio from just before ("wake on voice").
  - Sound that is only the room's background (a TV across the room, a fan) is turned down by
    about 30 dB before sending, but it is still sent.
  - OpenAI transcribes the audio (`gpt-transcribe`). Dee decides only after that whether the
    words were meant for her. Speech that was not for her is then deleted from the realtime
    conversation, but it has already been uploaded.
- **The Dee DNA, with every reply and initiative.** This is a description of:
  - her personality, current feelings and self
  - her relationship with the person and their name
  - a few short words about what she sees
  - the facts and shared memories she recalls about them

  Turn off **Share Memories with Cloud Voice** to keep facts, shared moments, recall notes,
  running jokes, interests and upcoming events out of the DNA, and to withhold the memory
  tools. The person's name is still sent, and she may still mention a follow-up subject (a
  short topic she meant to ask about, such as "job interview").
- **Transcripts and her replies,** plus the summary and recent messages carried into a new
  session when a long conversation moves to a fresh one.
- **Results of tools you ask for:** an event title, a contact's details, the name of your town.
  For example, up to 8 calendar events or 10 open reminders.
- **The text of her short sounds,** sent once to render them with text-to-speech.
- **Key checks.** One check of your key (`GET /v1/models`) when it is first entered. The key is
  also used to get short-lived realtime client secrets. If getting a client secret fails (not
  supported, server trouble or a network problem on that call), Dee opens the realtime
  connection with the API key itself.

**Rules for the Dee DNA:**

- It is rebuilt from her state for every response and is never written to disk or logs.
- A privacy guard makes sure it never repeats five words in a row of what was said to her in
  the session.
- Sensitive facts are never included.

**Stays on the device:**

- **Camera video.** It is processed on the device to follow faces, recognise people and notice
  things, and it is never recorded or sent. Only the few words about what she sees reach the DNA.
- **The people she knows** (`DeeMemory.sqlite`): people and aliases, face prints, short facts.
- **Her self model** (also `DeeMemory.sqlite`): episode gists (up to 100 characters),
  follow-ups, intentions, lessons, boundary topics, interests and tastes (subjects and topics
  up to 40 characters each). These are short derived notes, not transcripts.
  `DeeMemory.sqlite` is excluded from iCloud and device backups.
- **Her mind: emotions, personality and age** (`DeeMind.sqlite`). This holds numbers only
  (traits, feelings, daily totals) and is included in normal device and iCloud backups.
- **Local analysis:** sound recognition (laughter, a doorbell, …) and voice prosody are computed
  on the device.
- **The API key,** stored in the Keychain as "this device only". Until it is moved there (at
  the next launch or return to the foreground), a key pasted into the Settings app sits in
  the app's unencrypted preferences.

The user's words are kept in memory for the session's privacy guard and are not saved as a
transcript. What she keeps long term are the short notes listed above.

OpenAI does not train on API data. It may keep data for up to 30 days in its abuse-monitoring
logs, unless the account is approved for Zero Data Retention.

## Requirements

- An iPhone running **iOS 26** or later (the target also builds for iPad).
- A Mac with **macOS 26** and **Xcode 26** (Swift 6.2 toolchain, iOS 26 SDK). DeeKit uses Swift
  tools 6.2; the app uses Swift 6. The DeeKit tests and the voice harness run on macOS 26.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), if you change `project.yml` or use
  `scripts/build-app.sh` (it always regenerates the project).
- An **OpenAI API key** that can use the Realtime API (including client secrets),
  text-to-speech (`gpt-4o-mini-tts`, for her short sounds) and list Models (the key check).

## Setup

1. **Open the project.** Clone the repository and open `Dee.xcodeproj`, which is committed. If
   you edit `project.yml`, regenerate the project with `xcodegen generate`.
2. **Set up signing.** `project.yml` sets the developer team and the `ca.forensicintelligence`
   bundle prefix. Change both to your own, in `project.yml` (then regenerate) or in Xcode's
   Signing settings. Changes made only in Xcode are lost when the project is regenerated
   (`scripts/build-app.sh` always regenerates it). The `DeeUITests` target has its own bundle
   ID in `project.yml` (`ca.forensicintelligence.dee.uitests`), which also needs changing.
3. **Build and run** the `Dee` scheme on your iPhone. `scripts/build-app.sh` regenerates the
   project and builds for the iOS Simulator. Camera and voice need a real device.
4. **Add your key.**
   - Open the iOS Settings app, go to **Apps › Dee** and paste the key into **Cloud Voice
     (OpenAI) › OpenAI API key**.
   - Use a dedicated project key with a spend limit. If you restrict its permissions, keep
     Realtime (including client secrets), Audio (speech, for `gpt-4o-mini-tts`) and read
     access to Models. The key check calls `GET /v1/models` and treats 401 or 403 as a refused
     key.
   - At launch, or when Dee comes back to the foreground, she checks the key with that one
     request, moves it into the Keychain and clears the Settings field. If the check can't
     confirm the key (offline, or an OpenAI error other than 401/403), it is stored unchecked.
     Until then, the pasted key sits in the app's unencrypted Settings preferences.
   - A refused key (or text that isn't a key) is not stored, and the field is cleared anyway.
     Paste a corrected key. The field is kept only if saving to the Keychain fails.
5. **Grant permissions.** Allow the microphone and camera. Calendar, reminders, contacts and
   location are asked for the first time she needs them.

### Settings (Settings app › Apps › Dee)

| Setting | Values | Default |
|---|---|---|
| OpenAI API key | moved to the Keychain, then cleared (also cleared if refused) | — |
| Voice | marin, cedar (both recommended), alloy, ash, ballad, coral, echo, sage, shimmer, verse | marin |
| Model | Mini `gpt-realtime-2.1-mini`, Full `gpt-realtime-2.1` (about 3× the cost) | Mini |
| Share Memories with Cloud Voice | on / off | on |
| Dee Has an Age, Starting Age (robot-years) | personality and moods depend on her age | off, 6 |
| Dee Grows Older, Ageing Speed | real time to 1 year per hour | off, 1 year per 10 days |
| Reset Dee's Personality on Next Launch | one-shot | off |

Voice and model changes take effect the next time Dee opens.

## Project layout

| Path | What |
|---|---|
| `App/Sources` | The SwiftUI app shell: `DeeApp`, `DeeModel` (wires everything together), `RootView`, `SplashView`, `People`, `SelfDriver`, `Projector`, `TouchCaptureView` |
| `App/Settings.bundle` | The Settings-app page above |
| `Packages/DeeKit` | Swift package with every module that is not app shell |
| ↳ `DeeCore` | Pure Swift: persona, emotion vocabulary, spoken commands, thinking intent, turn ledger, voice health, tool protocol, the `ReplyEngine` seam |
| ↳ `DeeFace` | The Loona / Wall-E face: expression model, procedural animator, SwiftUI view |
| ↳ `DeeVoice` | The audio graph (24 kHz capture, stream player, local VAD, prosody, sound events) and `CloudVoice` |
| ↳ `DeeSense` | The front camera: who's there, where they are, hand gestures |
| ↳ `DeeMind` | Emotions, personality and age: appraisal, dynamics, SQLite persistence |
| ↳ `DeeMemory` | The people Dee knows: names, faces, facts (SQLite, on the device only) |
| ↳ `DeeSelf` | Her shared self: Cortex reducers, Stance, the self store, and the Dee DNA renderer |
| ↳ `DeeRealtime` | OpenAI Realtime client: event codecs, WebSocket, Keychain key and ephemeral secrets, the `RealtimeSession` actor, trace record and replay |
| ↳ `DeeBrain` | `RealtimeBrain`: when she answers, DNA delivery, the tool bridge (memory and device tools), settings, key intake, the status chip |
| ↳ `DeeTools` | A namespace for device tools (they live in `DeeBrain` for now) |
| `Tools/voice-harness` | A macOS loopback harness: the real `CloudVoice` + `RealtimeSession` + `RealtimeBrain` against fixture speech, room noise and echo; live runs, trace replay, gates, reports |
| `UITests` | XCUITest target `DeeUITests` |
| `scripts` | `test.sh` (DeeKit tests), `build-app.sh` (simulator build) |
| `docs` | Plan, devlog, DNA, mind and self designs, contracts, research |

## Testing

- `scripts/test.sh` runs the DeeKit unit tests (`swift test`). Build output goes to
  `~/Library/Caches/Dee/spm`, outside an iCloud-synced folder. `DeeBrainTests` drive the whole
  loop offline: the real audio graph in manual rendering, the real `CloudVoice` and
  `RealtimeSession` against a scripted server, and a real Mind and Cortex.
- The voice harness's offline tests run from `Tools/voice-harness` with
  `swift test --scratch-path /tmp/dee-harness`; build the CLI with
  `swift build --scratch-path /tmp/dee-harness`. Its live commands (`run`, `fixtures`, `judge`)
  need an OpenAI key in `~/.config/dee/openai-key` and cost money (`fixtures` also uses macOS
  `say`). `validate` and `suite` work offline on a fresh clone. `replay`, `gates` and `pool` are
  offline but need traces or reports from an earlier live `run`, which are not committed. See
  `Tools/voice-harness/README.md`.
- The UI tests run with the `Dee` scheme's Test action in Xcode (`DeeUITests`).

## Coming in 0.6.0 (in development)

None of this is in the published code yet:

- **An on-device wake phrase.** It defaults to "Hey Dee" and can be customised. Nothing is sent
  to any server until the phrase is heard on the phone.
- **A conversation window** after the wake phrase. "Go to sleep" ends it.
- **First-launch onboarding.**
- **In-app OpenAI key entry.** The key is kept only in the Keychain, and the key field in the
  Settings app is removed.
- **Three provider modes:**
  1. OpenAI for everything.
  2. A LAN model for thinking, with OpenAI for speech-to-text and text-to-speech.
  3. LAN for everything. If a LAN speech server is missing, on-device iPhone speech is used
     instead, never OpenAI.
- **LAN servers through the OpenAI-compatible API,** such as Ollama or LM Studio.
- **A "speak first" toggle,** off by default.

## Docs

- `docs/PHASES.md`: the phased plan and status
- `docs/DEVLOG.md`: the running developer log (the source for the magazine series)
- `docs/DNA.md`: Dee DNA, her personality, feelings and self, described to the model every turn
- `docs/contracts-0.6/realtime.md`: the DeeRealtime contract
- `docs/contracts-0.6/brain.md`: RealtimeBrain, covering when she answers, DNA delivery, tools and settings
- `docs/contracts-0.5/`: the face, voice, sense, mind and self contracts
- `docs/MIND.md`, `docs/SELF.md`: the mind and the shared self
- `docs/research/`: research briefs (face design, iOS frameworks, self model)
