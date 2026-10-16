# Dee

**Developer:** Forensic Intelligence

A pocket robot companion for iPhone: Loona's eyes, Wall-E's soul. Her face, senses,
feelings, memories and sense of self are computed on the device; her voice and words
come from OpenAI's realtime speech-to-speech model (`gpt-realtime-2.1-mini`, or
`gpt-realtime-2.1` in Settings), which hears her human, answers in character and speaks.
Before every reply and every time she speaks first, the model is given a full
description of who she is and how she feels right now ("Dee DNA", `docs/DNA.md`). Her
voice is an AI voice: she says so herself the first time she talks through the cloud,
and the screen shows it.

Without a connection (or without a key) Dee stays alive — eyes, touch, camera, feelings —
but cannot talk. A small status chip says why ("Add your OpenAI key in Settings › Dee",
"OpenAI refused the key", "No connection", "rate limited") and her eyes take a quieter,
puzzled look until her voice is back. There is no local language model.

## Setup
1. Open `Dee.xcodeproj` (regenerate with `xcodegen generate` after editing `project.yml`).
2. Run on an iPhone with iOS 26.
3. In **Settings › Dee › Cloud Voice**, paste an OpenAI API key (a dedicated project key
   restricted to the realtime and audio endpoints, with a spend limit). On launch or when
   Dee comes back to the foreground she checks it with one cheap request, moves it into
   the Keychain (this device only) and clears the Settings field. The same page picks her
   voice (marin, cedar, …; applied at the next launch), the model, and whether her
   memories of people are shared with the cloud voice.

## How she talks (v0.6)
- `DeeVoice.CloudVoice` runs her microphone and speaker on one audio graph and the
  realtime session (`DeeRealtime`) with server VAD that never answers by itself.
- `DeeBrain.RealtimeBrain` decides when she answers: at once when someone is with her
  and she is awake (the DNA built from her state and how the words sounded), or after
  the transcript when the words matter (an argument, a raised voice, a follow-up, a
  stranger's first words, right after she spoke). Asleep or alone she only answers her
  name; a TV is never answered. Spoken commands ("stop", "goodnight", "start over")
  are carried out, never answered.
- Exactly one Dee DNA lives in the conversation: each new one replaces the last.
- Tools: `remember`, `recall`, `forget` (her memory of people) and the device tools
  (calendar, reminders, contacts, rough location), each asking permission on first use.
- Contracts: `docs/contracts-0.6/realtime.md`, `docs/contracts-0.6/brain.md`.

## Privacy
- **Stays on the device:** camera video, face prints, the databases behind her mind
  (MindCode), her self model and her people memory; the API key (Keychain).
- **Sent to OpenAI while Dee is open and online:**
  - everything her microphone picks up — the user, anyone else nearby, the TV — streamed
    from the moment she connects (with about two seconds of audio from just before);
  - with every reply and initiative, the Dee DNA: a description of her personality,
    current feelings, self, her relationship with the person, their name, a few short
    words about what she sees, and the facts and shared memories she recalls about them
    (turn off **Share Memories with Cloud Voice** to keep facts and memories on the
    device; the memory tools are then withheld too);
  - the transcripts and her replies, and the results of tools you ask for (an event
    title, a contact's number, the name of your town).
- The DNA is rebuilt from state for every response and never written to disk or logs;
  it never repeats five words in a row of anything you said.
- OpenAI does not train on API data, but keeps it for up to 30 days in its abuse
  monitoring logs (unless the account is approved for Zero Data Retention).

## Tests
`scripts/test.sh` — the DeeKit unit tests (build output under `~/Library/Caches/Dee`).
`DeeBrainTests` drive the whole loop offline: real audio graph (manual rendering), real
CloudVoice and RealtimeSession, a scripted server, a real Mind and Cortex.

## Docs
- `docs/PHASES.md` — the phased plan and status
- `docs/DEVLOG.md` — the running developer log (source for the magazine series)
- `docs/DNA.md` — Dee DNA: her personality, feelings and self, described to the model every turn
- `docs/contracts-0.6/realtime.md` — the DeeRealtime contract
- `docs/contracts-0.6/brain.md` — RealtimeBrain: when she answers, DNA delivery, tools, settings
- `docs/MIND.md`, `docs/SELF.md` — the mind and the shared self
- `docs/research/` — research briefs (face design, iOS frameworks, self model)
