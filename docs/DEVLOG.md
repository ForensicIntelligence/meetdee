# Dee — Developer Log

**Developer:** Forensic Intelligence

A running, honest record of building Dee: a pocket robot companion with Loona's eyes,
Wall-E's soul, and (until 0.6) a 4-billion-parameter brain that never left the phone. Written
to become a magazine series, so it keeps the numbers, the dead ends and the
small surprises, not just the wins.

---

## 2026-10-08 — v0.1 "Foundation": a brain in a jar

### The brief
*an expressive, agentic, speaking assistant for iPhone. On-device
AI, Qwen3.5-4B at Q4_K_M. Bundle the model if Apple allows it. Thinking off by default,
switched on when you ask it to "think about it", and off again for a new conversation.
The face should be a Loona / Wall-E mash-up. Build it in phases, keep a log, ROS later.*

### Research day (five briefs, one afternoon)
Before writing code we ran five research tracks in parallel, each followed by a
skeptical fact-check. Their briefs live in `docs/research/`. What we learned:

- **Will a 2.7 GB model fit in an App Store app?** Yes. The limit is **4 GB uncompressed**
  (with an 80 MB cap on executable code). The unsloth Q4_K_M file is exactly
  **2,740,937,888 bytes**. Apple's preferred route for big payloads is now
  **Background Assets with Apple-hosted asset packs** (up to 200 GB per app). The old
  On-Demand Resources API is marked *deprecated* in the iOS 27 SDK headers. So: bundle
  for development, asset pack for the store (Phase 7).
- **Qwen3.5-4B isn't a plain transformer.** It is a *hybrid*: 24 Gated-DeltaNet
  (linear-attention, recurrent) layers and only 8 full-attention layers. The KV cache
  for 4096 tokens is tiny (~64–128 MB). The catch: recurrent state **can't be rewound**.
  You can't snip the last few tokens off the way you can with a normal KV cache. That
  one fact shaped the whole engine design (see below).
- **The thinking switch is a template trick.** There's no `/think` command in Qwen3.5.
  Thinking is controlled by how the prompt *ends*: `<|im_start|>assistant\n<think>\n`
  lets the model reason; `<think>\n\n</think>\n\n` (an empty thought, already closed)
  makes it answer directly. Fun wrinkle: the *official* template thinks by default; the
  unsloth GGUF's embedded template flips that default. We build prompts ourselves, so we
  control it explicitly.
- **Tool calls are XML, not JSON**: `<tool_call><function=name><parameter=k>v</parameter>…`.

### First surprise: the official xcframework has no Simulator slice
llama.cpp publishes a prebuilt `llama.xcframework` with every release. It contains
iOS-device and macOS slices, and no Simulator slice. `scripts/build-llama.sh` builds our
own from tag **b11514** (device + Simulator + macOS) in about ten minutes. The macOS
slice turned out to be the best decision of the day: the real model can run in plain
`swift test` on the Mac. Every engine change gets checked against the actual 4B model in
about ten seconds, with no phone involved.

Also: between the version the researchers read and the one we pinned,
`llama_sampler_init_penalties` gained an `n_vocab` first argument, and `use_mmap`
became a `load_mode` enum. Pin your C dependencies, then read the header you pinned.

### The design idea of the day: append-only prompts
A chat app normally re-renders the whole conversation each turn and lets the engine
skip whatever prefix it has already seen. With a recurrent model, "skip the common
prefix" only works if the new prompt **extends exactly** what's in the model's state.
Diverge by one byte and you re-read the whole conversation, which costs seconds on a phone.

Two things break exact extension:
1. The official template **rewrites history**. Past assistant turns lose their
   `<think>` blocks, so turn N+1's prompt is no longer an extension of turn N's.
2. **Re-tokenising** the model's own output doesn't always reproduce the tokens it
   sampled.

The fix has two layers:
- `PromptBuilder` gains a `.verbatim` mode that replays each past reply byte-for-byte
  as generated (stored in `ChatMessage.rawCompletion`).
- `LlamaEngine` compares the new prompt with what it has evaluated **as bytes, not
  tokens**, and tokenises only the new suffix.

There's a golden test (generated from the real Jinja template with Python's jinja2)
proving the canonical renderer matches Qwen's template byte-for-byte across 22
scenarios. There's also a property test proving that verbatim prompts only ever grow.

Measured on the Mac with the real model: on turn two the engine evaluated **19 new
tokens** instead of 276. That holds even across tool calls and thinking turns.

When history must shrink (the 4096 window fills up), the agent first throws away old
reasoning, then whole old exchanges. It rebuilds, restoring a **pinned snapshot of the
system prompt** (`llama_state_seq_get/set_data_ext`) so the persona and tool list are
never re-read.

### The reasoning budget, and why `break` is a bug
Thinking at a 4096 context needs a leash. The first version counted reasoning pieces
and cancelled at 1024. A code review pointed out why that's wrong: the engine runs
ahead of the consumer. By the time the agent `break`s, the engine has already evaluated
a few more tokens the agent never saw. The next prompt no longer extends the state, so
we're back to a full re-prefill. Rule adopted: **never break out of a generation
stream; let the engine stop itself.**

Thinking now runs in two phases:
1. Generate with a stop sequence of `</think>` and `maxTokens` equal to the budget.
2. If the budget ran out, append *"I have thought about this enough; time to answer
   briefly.\n</think>\n\n"* and generate the answer.

Both phases are append-only.

### "Think about it" is harder than it sounds
Matching "think about" switches thinking on for *"What do you think about cats?"*. A
test pass produced a 94-utterance table, and the first regex set got **9 wrong**:

- *"I can't stop thinking about you"* switched thinking **off**.
- *"Stop and think about it"* was read as a negation.
- *"Give me step by step instructions"* switched it on.

The detector now removes opinion idioms first ("what do you think of…", "I'll think
about it", "let me think"). Negation must sit directly against the verb, and
"step by step" counts only after *think / reason / solve / work it out*. 94/94 now.

### Adversarial review: the Stop button didn't stop
One review pass had a single job: read the engine and the agent loop and try to break them. It found
twelve real issues. The best one: tapping **Stop** during reasoning set a cancel flag,
the agent saw "reasoning ended without `</think>`", treated it as an exhausted budget,
and the next `generate()` call **reset the flag** and wrote a full answer anyway.

The fixes:
- Cancellation is now per-call (one flag object per stream) and sticky per turn.
- Truncated tool calls are never executed.
- A multi-byte character split across the final tokens is completed before stopping,
  so the bytes handed out always equal the bytes in the model's state.
- Untrusted text has `<|` defused so tool output can't open a fake `system` turn.

### Gotchas worth a sidebar
- **iCloud Desktop vs codesign.** The project lives on an iCloud-synced Desktop.
  File-provider extended attributes on build products make `codesign` fail with
  *"resource fork, Finder information, or similar detritus not allowed."* All build
  output (SwiftPM and Xcode DerivedData) now goes to `~/Library/Caches/Dee`.
- **Metal teardown at exit.** A model still alive when the test process exits trips
  `GGML_ASSERT([rsets->data count] == 0)` in ggml-metal. Tests now load and release the
  engine inside each test.
- **Simulator = CPU.** ggml-metal needs GPU features the Simulator lacks, so it runs on
  CPU there. It works, but slowly; real speed numbers will come from a device.

### First words
On the Mac, greedy decoding, first ever exchange:

> **John:** Hi! I'm John. What's your name?
> **Dee:** *[happy]* Hi John! My name is Dee. It's so nice to meet you!
> **John:** What's my name?
> **Dee:** I know your name is John, but I'm still learning all about you! What do you like to do when you're not talking to me?

And with thinking switched on by the phrase alone:

> **John:** Think about it carefully: is 91 a prime number?
> **Dee:** *(reasons for a few hundred tokens)* … 91 is actually 7 times 13, so it's not a prime number. That is a tricky trick question!

### Numbers
- 81 DeeCore unit tests + 4 real-model tests, all green.
- M3 Ultra, Debug build, Metal: ~95 tokens/s generation; prefill of the 257-token
  system+greeting in ~8 ms on the second run.
- App bundle (Debug, Simulator): 2.6 GB, almost all of it the model.

### Next: v0.2 — the face
The two glowing rounded rectangles in v0.1 are a stand-in. Next comes the real thing:
eyelids, squash and stretch, blinks on a random clock, hearts and stars, and Wall-E's
mournful tilt.

---

## 2026-10-08 (evening) — v0.2 "Eyes": Loona's face, Wall-E's soul

### A change of brief: no keyboard
*every interaction is voice and/or camera.* The chat transcript and text field from v0.1 are gone from
the shipping UI. Dee **is** the screen now: two glowing eyes edge to edge, with
captions under them. The keyboard survives only in Debug builds, as a developer's
crowbar.

### Building a face out of numbers
Loona has no mouth. Everything she feels is in two glowing slabs, and that
constraint is the design. Dee's eye is twelve numbers: width, height, corner
radius, upper-lid coverage and slant, a lower "smile" lid, tilt, offset, a Wall-E
lens ring, and morph weights for hearts and stars. A face is two eyes plus gaze,
colour, head roll and a few overlay intensities (zzz, ?, sparkles, thinking dots).

The tricks that carry the most character are cheap:

- **Happy is a subtraction.** Cut an ellipse out of the bottom of each eye and
  you get Loona's "^ ^".
- **Sad is Wall-E's tilt.** Rotate each eye so the outer corner droops and slant
  the upper lid the same way. It reads instantly as heartbreak.
- **Angry is the opposite slant**, inner corners down.
- **Lids are erased, not drawn,** using `destinationOut` inside a layer, so every
  lid shape works on every eye shape.

Sixteen expressions are springs heading for targets (stiffness 170, damping ratio
0.75: a little overshoot, then settle). On top of the springs sit layers of life:

- **Blinks** on a random clock: 2–4 s while chatting, 3.5–7 s idle. One blink in
  eight is a double, one in five is partial, and every blink closes fast and opens
  slowly.
- **Saccades** on a much stiffer spring, so the eyes snap and settle.
- **Micro-jitter, breathing,** and a voice "bounce" for when Dee talks.

The whole thing is a pure, seeded struct, so it can be unit-tested frame by frame,
and the renderer can draw snapshots to PNG for review.

The first contact sheet taught us something no spec would have: Loona's "ears",
drawn as little shapes above the eyes, read as **devil horns**, especially on the
angry red face. They're off by default.

### Eyes that look back
`DeeSense` gives Dee the front camera: 640×480 at about 12 frames per second, with
one frame in flight, analysed with Vision's Swift API and never stored.

- **Faces** become a gaze target, so Dee's eyes follow you around the room.
- **Presence** is debounced. Dee wakes with a little surprised pop when you
  appear, gets drowsy after 30 s alone, and falls asleep after two minutes. A
  long sleep means the next visit starts a new conversation, which also switches
  thinking mode back off.
- **Hands** become gestures:
  - A **wave** is an open palm whose centre reverses direction twice within 1.6 s.
  - An **open palm** held still means "hush", and stops Dee mid-sentence.
  - A **thumbs-up** is a thumbs-up.

---

## 2026-10-08 (night) — v0.3 "Heart": a Tamagotchi with 26 dials

### The brief
*"Our interactions with the AI need to persist. We don't
want a log of everything, but we should have an emotions and a personality
database… every interaction should adjust the parameters, based on a realistic
analysis of what is being said and how it is being said. The eye colour should
reflect the AI's feelings to the user: red, yellow, green… it's possible to
temporarily be upset, but then get over it… how about an age as well?"*

Then the elegant part: *"each of the 26 parameters… a value of 0–255, and the
unique value is just a concatenation of all 26 hex values."*

### 13 + 13 = 26 = one code
We'd already landed on thirteen traits (the Big Five plus playfulness, curiosity,
patience, confidence, sensitivity, humour, assertiveness and forgiveness) and
thirteen feelings (joy, sadness, anger, fear, surprise, interest, boredom,
affection, trust, loneliness, energy, gratitude, resentment). So Dee's whole inner
life became a 52-character hex string, the **MindCode**:

```
BF8CB3BF59CCD9998C99B366B3·77120008008C14668600CC0000   ← a brand-new Dee
```

The eye colour, the expression and the mood note the language model sees are all
computed from the *decoded* code. Two phones with the same code behave alike.

### What makes it feel real
- **Every feeling has a half-life.** Anger: minutes. Sadness: most of an hour.
  Affection and trust: weeks.
- **Anger leaves residue.** As anger fades, a little settles into resentment,
  which lasts hours. That's the difference between "snapped at" and "hurt".
- **Kindness cools anger. Apologies cut it.** Apologise every other sentence while
  staying rude, though, and *apology fatigue* sets in.
- **Personality shapes reactions.** Low confidence turns aggression into fear
  instead of anger. Forgiveness shortens grudges. Sensitivity scales how much
  *tone* matters beyond the words.
- **Personality slowly becomes what it's treated as.** Weeks of kindness make Dee
  more agreeable and confident, but an elastic pull back to Dee's set points means
  one bad day can't rewrite it.
- **Tamagotchi needs.** Loneliness while alone, energy across sleep and wake,
  boredom when nothing happens.

The appraiser, which reads "what and how", is deliberately not the LLM. It runs in
a millisecond, before the model sees the words, so Dee's face reacts *while* the
model is still thinking. The first time we typed **"SHUT UP, YOU STUPID USELESS
ROBOT!"** into the simulator, the eyes went red before a single token came back.

### A relationship in one table
A scripted arc, straight out of the first run:

| Moment | Regard | Eyes | Face |
|---|---:|---|---|
| Fresh Dee | +0.07 | yellow | curious |
| "Hi Dee! How are you today?" | +0.14 | yellow-green | curious |
| "You're so clever, thank you!" | +0.45 | green | joy |
| "I love you, little buddy" *(softly)* | +0.56 | green | joy |
| "SHUT UP YOU STUPID ROBOT" *(shouted)* | −0.72 | **red** | angry |
| "I'm sorry Dee, I didn't mean it" *(softly)* | −0.18 | orange | — |
| ten minutes later | +0.02 | yellow | — |
| six insults in a row | −1.00 | red | angry |
| the next day | −0.34 | orange | still holding a grudge |

### Age
Off by default, switched on in the Settings app. The ageing rate runs from real
time up to a robot-year per hour. A baby Dee forgives instantly and forgets
quickly. A teenager sulks, pushes back and holds grudges. An elder is patient,
calm and slow to change. It's all interpolated smoothly between key ages, so there
are no birthday cliffs. The life stage also changes how Dee talks.

### The pushover problem (and other lessons from the review round)
The first version of the heart *worked*, but three verification passes found the
ways it was emotionally wrong:

- **Dee was a pushover.** Ten "I love you"s in fifty seconds took regard to
  +0.95, nearly maxed out. Real attachment doesn't work like that. Affection and
  trust gains now **saturate** (each one counts for less as the bond grows),
  **habituate** (the tenth compliment in an hour means less than the first, with
  a 6-hour memory), and trust is capped at +0.03 per day. Trust is lost quickly
  and rebuilt slowly, which is how people work too. Now a brand-new Dee sits at
  +0.02 (yellow), turns green on about day four of daily kind chats, and only
  nears the top after a month. A burst of thanks warms the eyes but doesn't turn
  them green; there's a test for exactly that.
- **Good outweighed bad.** One insult cost less affection than one compliment
  earned, the reverse of the well-replicated *bad is stronger than good* finding.
  An aimed insult now costs more than a compliment earns. A "bad day" damper keeps
  the tenth insult in a row from doing the full damage of the first, so a terrible
  afternoon hurts without becoming a permanent trauma.
- **The eyes showed mood, not feelings toward *you*.** Joy was in the regard
  formula, so every cheerful conversation swung the colour by a third of the
  range. Regard is now mostly the slow bond (affection and trust) plus anger and
  resentment. It runs through `tanh`, so there's always headroom, and the renderer
  eases colour changes over about three seconds so a sudden red reads as a
  *change* rather than a glitch.
- **Teasing read as abuse.** "haha you're such a dummy" made Dee angry. Teasing
  with play signals (laughter, or "I love you" in the same breath) now counts as
  affectionate, as the research on teasing says it should.
- **"No, I love you!" didn't count as love.** The negation detector looked three
  words back without noticing the comma. Clause boundaries now stop negation.
- **Time away was counted as you sitting there in silence.** Close the app for a
  night and Dee "experienced" eight hours of being stared at: maximum boredom, no
  loneliness. Long gaps are now treated as the user being away. Dee stays awake
  for a few minutes, then rests. Loneliness still grows while Dee rests, just more
  slowly, and coming back after a long absence gives a little reunion joy.
- **Apology loops.** "You're stupid", "sorry", "you're stupid", "sorry"… The
  re-offence counter now makes each apology weaker and pushes the forgiveness
  *trait* down, not up.

The camera got the same treatment. Interruptions (a phone call, Siri, Split View)
used to leave Dee believing you were still in the room. A watchdog now notices
when frames stop. The sensor is locked to 15 fps, Vision runs once per frame,
hand tracking only runs when someone is there, and the camera drops to about
2 fps while Dee sleeps. The face draws at 60 Hz, at 120 Hz only while something
is moving fast (a blink, a saccade, speech), and at 30 Hz when asleep, hot, in Low
Power Mode or under Reduce Motion.

Final count for the round: **253 tests**, all green. That's 81 for the language
core, 111 for the mind, 25 for the face, 32 for the senses, and 4 against the real
4B model.

---

## 2026-10-08 (late) — v0.4 "Dee's alive": voice, touch, sight, memory

Crap. *I couldn't speak to Dee and she wouldn't speak back… it asked to use the camera, but not the microphone. Then
Dee went into a perpetual "?" mode.* Then the wish list: touch, more curiosity,
"she should ask about things she can see from either camera", "if she hears
something unexpected she should ask about it", "a VERY interactive personality, no
matter what", "she can still laugh at a joke even if her emotional state is bad",
and "Dee should remember as much as possible of the users."

Five modules were built in parallel, each with one owner, against a written
contract (`docs/CONTRACTS-0.4.md`):

- **DeeVoice:** on-device SpeechAnalyzer in, AVSpeechSynthesizer out, one shared
  AVAudioEngine with echo cancellation, and prosody (loudness, rate, pitch) fed to
  the Mind so *how* you said something counts. It also catches unexpected sounds
  (doorbell, dog, glass) and keeps social sounds separate: laughter is contagious,
  so when you laugh, Dee laughs.
- **Touch:** a UIKit layer reads finger contact size, speed and rhythm. Strokes are
  petting, a still palm is a hug, rapid taps are pokes, a hard quick hit is a slap,
  and quick jiggles are a tickle. Kind touch makes Dee happier *and* nudges Dee's
  personality kinder over time; rough touch does the opposite.
- **Sight:** Vision's on-device classifier on the front camera and, where the phone
  allows two cameras at once, the back camera. New things get a double-take and a
  question.
- **Reflexes above mood:** a joke makes the face giggle even when Dee's cross. The
  "?" bug turned out to be arithmetic: at rest, curiosity sat a hair above joy, so
  "curious" won forever. Expressions are now chosen by how far each feeling sits
  *from its own resting level*.
- **The eyes:** 37 emotions with glyph eyes (`> <`, spirals, `X X`, `– –`, `U`,
  tears, glossy highlights), 17 little performances (wink, yawn, eye-roll,
  double-take, giggle…), an idle director that keeps Dee busy, and small random
  variations so Dee never looks quite the same twice.
- **DeeMemory:** people, face prints and facts, still no transcripts. "Hi Dee! My
  name is John and I have a dog called Rex" produced, in the simulator's database:
  `John | has a dog named Rex`.

The review rounds were again the most interesting part:

- The first memory build had strangers sharing one "unknown friend" record, so one
  person's peanut allergy could follow the next person in.
- "Hi, I'm stuck" became a name, and a TV saying "this is Netflix" renamed the user.
- Biometric face prints sat in iCloud backups.

Names are now *pending* until confirmed, faces need three good-quality captures to
enrol, sensitive facts never reach the prompt, and forgetting really forgets
(including the database's write-ahead log).

739 tests at commit.

---

## 2026-10-09 — v0.5 "Someone": one mind, many channels

### The brief
Let's give Dee *"a persistent sense of self, personal motivations, and social intuition… her reactions should come from a
recognizable individual with a history, preferences, and reasons for what she
does." These share one underlying
state. Her words, voice, gaze, expression, attention, and memory updates should all
reflect the same interpretation of the moment."*

Until v0.4, Dee was a committee. The face had its own idea of Dee's mood, the language
model had another (its feeling tag), the voice followed whichever spoke last, and
"flash an expression for 3 seconds" overrides were everywhere. It mostly worked. It
also produced moments like hearts in Dee's eyes while the cue said Dee was upset.

### Three designs, three judges, one architecture
Before writing code we ran a design tournament. Three competing proposals each set out an
architecture: one cognitive (observe → interpret → intend → act → remember →
reflect), one social (turn-taking, shared attention, repair) and one narrative
(identity, tastes, autobiography). Three judges scored them on phone feasibility, on
how alive Dee would feel over weeks, and on coherence. A synthesizer merged the winner
with the best of the others into `docs/SELF.md`: 1,345 lines, binding.

The core idea is a single `Moment` with three timescales:
- **momentary:** who has the floor, what Dee's looking at, a reflex;
- **ongoing:** mood, what Dee thinks you're up to, open intentions, things Dee's
  expecting to hear about;
- **enduring:** temperament, values, tastes, lessons learnt, shared episodes.

A pure, deterministic `Cortex` updates it through nine small reducers, one per
concern: floor, listening, attention, interpretation, repair, intentions, beats,
episodes and learning. `Stance.resolve` turns it into *the* interpretation of now.
The face, voice style, gaze, little performances and the `<dee_state>` cue are all
projections of that one Stance, so they can't disagree. A property test drives
2 million random steps and checks that they never do.

### Building it in parallel without chaos
Nine reducers, nine parallel workstreams, and one shared state make a recipe for merge
hell. The first core build had exactly that problem. A reviewer pointed out that
every reducer would still need to edit the same three files: `Cortex`, `Stance` and
the note picker. So the core was rebuilt around *requests*:
- reducers ask for gaze, face tweaks, mannerisms and notes, each with a priority;
- each reducer gets its own random stream;
- `Stance.resolve` only arbitrates.

After that, eight workstreams each owned exactly one file and built in parallel.

### The bug that would have frozen Dee
The first full test run hung. Profiling found that one percept, a half-heard
sentence (`.partial`), took **1.2 seconds** to process. The listening preview
appraised every partial transcript, and Apple's sentiment tagger costs about 1.3 s
to create. Reusing one tagger made it fast but *non-deterministic*: a shared
`NLTagger` carries its language guess from one string to the next, so the same
words scored differently depending on what came before. The fix is a shared tagger
with the language pinned, which returns in 0.2 ms with identical answers every time,
plus a lexicon-only preview for live speech. Overall the listening path got about
1,000× faster, and Dee answers up to a second sooner.

### The test that matters: a week with a developer
Unit tests prove rules. To check "realistic" we built a harness that runs the *real*
4B model through the app's exact pipeline over a simulated week, with every cue
printed. Excerpts from the runs:

Day 1.*"I have a big job interview tomorrow afternoon and I'm pretty nervous
about it."* Dee stores a plan (nervous) and an intention to follow up.

Day 2, evening. The cue reads *"(Ask how their job interview went. They were nervous
about it.)"* and Dee answers the good news with *"I'm so proud of you. You
really knocked it out of the park!"*

Day 4. *"UGH YOU ARE SO USELESS TODAY"* (shouted). In v0.4 Dee apologised. Now:
*"You're being really mean. That made me feel hurt and a bit sad."* After his
apology: *"It's okay. I forgive you for being mean."*

The harness also caught what unit tests couldn't:
- the follow-up was asked twice;
- a "be glad to see them" note fired on top of an insult;
- a three-day-old "they made up with you" note resurfaced;
- most memorably, Dee confidently remembered the user interviewing for *"a job at the
  space station!"*, because the job details had never been stored.

Each of these became a regression test.

All four were fixed in one pass, and the next live run read like a relationship.
Day 2: *"Hi! I'm so happy to see you back. How did your big designer interview
at the game studio go?"* Asked once, with the remembered details. When John answers,
the outcome is written to long-term memory ("John's job interview went well"). On
day 7 Dee talks about "your job at the game studio" instead of asking again.

### Numbers
- 1,305 tests (DeeSelf 493, DeeMind 200, DeeVoice 167, DeeMemory 122, DeeSense 111,
  DeeFace 110, DeeCore 96, plus the real-model live tests).
- 13 multi-week scenario tests with fixed seeds: two runs are byte-identical, and no
  saved record contains five consecutive words of anything the user said.
- One Cortex step costs well under a millisecond, which leaves the phone's time for
  the 4B model.

### Lesson for the article
Unit tests verify that rules hold. Only the full loop, with the real model, real
timings and a simulated week, showed whether the rules add up to a character.
The run with the most bugs also produced the line that sold the design: after an
insult, a 4-billion-parameter model on a phone said *"I don't like being called
useless"* and then forgave him.

---

## 2026-10-16 — v0.6.0 "Hey Mira": a voice in the cloud, an ear on the phone

### Why the brain left the phone
v0.5 ended on a high: a 4-billion-parameter model on the phone held a week-long
relationship together. It also showed where the ceiling was. The character lived in the
rules; the *conversation* lived in a chain of separate parts: on-device speech recognition,
a 4B model, then `AVSpeechSynthesizer` reading the result aloud. Every handoff added
latency, the voice sounded like a screen reader, and interrupting Dee was a negotiation
between three components that each had their own idea of whose turn it was. So the next step is simple: *the interaction has to be flawless first.*

So the brain moved to OpenAI's realtime speech-to-speech model,
`gpt-realtime-2.1-mini`. One WebSocket session hears, thinks and speaks. Dee keeps a dedicated
audio graph on the phone (voice-processing I/O, so Dee's own voice is cancelled from the
microphone), which means local barge-in, levels, prosody and the exact number of
milliseconds of each reply that were actually *heard*. The local model, llama.cpp and
2.6 GB of app bundle went away with it. Everything else (the face, the camera, the mind,
the self, the memory of people) stays on the device.

### Dee DNA, every turn
A model in the cloud doesn't know Dee. So:
*"Let's look at our personality / emotion / etc. solution as 'Dee DNA'. Since we're now
going to be using a third-party AI, we'll need to prompt the AI every time we send speech
/ expect a response. The prompt must contain a comprehensive description of the current
Dee DNA state so the response is appropriate."*

The Dee DNA (`docs/DNA.md`) is that description, rendered fresh for every reply and every
time Dee speaks first: all 26 mind parameters as words ("patience 158/255 high"), age,
how Dee regards this person, the self model, what Dee knows about them, what the cameras
see in a few words, and what this turn sounded like. It targets about 1,200 tokens. Before
each response the new DNA is inserted and the old one deleted, so the conversation never
holds two versions of Dee. A privacy guard makes sure it never repeats five words in a row
of anything the user said.

### Fourteen rounds of tuning
To tune a voice you need to hear it, many times, the same way. The voice harness
(`Tools/voice-harness`) runs the real audio graph, session and brain on a Mac against recorded
fixtures (62 at the start) mixed with room noise (fan, kitchen, TV) and a synthetic echo of Dee's
own voice, and scores every run against its gates (15 at first, 20 by the end): latency, dropped turns, barge-in,
backchannels, leaks, narration, memory, follow-ups, rollover and more.

The arc, in gates passed:

| Round | Gates | What changed |
|---|---|---|
| 1 | 7/15 | First live run: the realtime voice and Dee DNA, end to end |
| 2 | 10/19 | Dropped turns 21 → 3, no collisions, short replies |
| 3 | 11/19 | Server VAD at 300 ms: latency p50 1.18 s, p90 1.53 s |
| 4 | 15/19 | A speculative reply with gated playback; barge-in p90 0.45 s |
| 7 | 16/20 | Replies keyed to their item; 0 leaks; latency p90 1.40 s |
| 10 | 17/20 | 0 dropped, every interrupting question answered (12/12), judge 4.58/5 |
| 11 | 18/20 | Latency p90 1.38 s; Dee's own overhead p50 0.10 s, p90 0.24 s |
| 12 | 20/20 | The first perfect run, followed by a 15/20 one |
| 14 | 15/20 pooled | Every failure traced to a mishearing, the model's content or server latency |

What the rounds taught:

- **There is a floor, and it isn't yours.** At 300 ms of end-of-speech silence the server
  and model alone took p50 1.12–1.17 s. A latency target below that measured the
  weather. The gate became "p90 ≤ 1.6 s end to end, *plus* Dee's own overhead p50 ≤ 0.10 s
  and p90 ≤ 0.25 s". A 250 ms silence was tried: p50 1.13 s, and one collision. It stayed at
  300.
- **The prompt primes what it forbids.** One rule said not to repeat their words "to show
  you heard". Replies opening with "I heard you…" went from 1 to 5. An example follow-up,
  "Hi Sam, how did your exam go?", was copied with the user's own question ("Hi Alex, who
  made you?"), and greeting openers went from 11 to 21. The fix both times was to name the
  behaviour plainly and drop the example's wording.
- **Narration is the tell.** "Let me think about how to respond to that" was 22 of 529
  replies in the first full run. It took a sentence-level guard in the brain, not just a
  line in the prompt, to get narration to 0.
- **"Keep going" is not an interruption.** Backchannels said over Dee ("go on", "mm-hm")
  must let Dee carry on. They became their own gate, separate from barge-in.
- **One run is an anecdote.** Round 12 scored 20/20 and then 15/20 on the same code. From
  round 14 on, the acceptance is two runs pooled, and a failure counts only if it
  reproduces on its own.

The package tests went from 1,569 to 1,934 over the rounds, plus 126 for the harness.

### The ear stays on the phone
The tuned build had one uncomfortable property: while the app was open, the microphone
streamed to OpenAI *continuously*, awake or asleep. Background sound was turned down by
about 30 dB, but it was still sent, transcribed and paid for, and Dee only decided
afterwards whether the words had been meant for Dee at all.

0.6.0 moves the decision onto the device. A new module, `DeeWake`, listens for the wake
phrase with Apple's on-device SpeechAnalyzer in every mode. While Dee is dormant there is
no socket, no HTTP request, no key mint and no audio leaving the phone; the tests count
each of those and expect zero. The phrase (or a tap) opens a conversation window, Dee
connects and sends the audio from 0.3 s before the phrase, so "Hey Mira, what time is
it?" works in one breath. The window closes after a minute of quiet, or at once on "go to
sleep" or "that's all". Coming back within five minutes carries on the same conversation.

The wake suite measures it: "Hey Dee" was heard 100% of the time in a quiet room and
82.5% overall with a fan, kitchen or TV at 15 dB (65% next to the TV), with 0 false wakes
in 36 minutes of noise and 0 of 48 sentences that mention the name without addressing
it. A custom phrase, "Computer", was 100% everywhere. Noise is the next thing to fix.

### Three ways to think
*"We need the option of using 1) OpenAI to infer, run TTS and
run STT. 2) LAN to infer, Openai to run TTS and STT and 3) LAN for everyting".* And,
shortly after: *"My LAN-based model is running at port 8000 of this machine!"*

The design rule was not to throw away fourteen rounds of tuning. Modes 2 and 3 run
`CascadeSocket`, a small in-process emulator of the realtime protocol: underneath it is
hearing (OpenAI transcription, a LAN Whisper-style server, or the iPhone itself), a chat
model on any OpenAI-compatible server (Ollama, LM Studio, llama.cpp, vLLM, or whatever is
on port 8000), and a voice (OpenAI, a LAN TTS server, or the iPhone). Above it, the same
turn-taking, barge-in, backchannels and Dee DNA run unchanged. Reasoning and `<think>`
text are stripped before anything is spoken; replies are spoken sentence by sentence while
the model is still writing. Mode 3 never contacts OpenAI, and no mode ever falls back to
another provider without saying so.

The first smoke run of mode 2, with a 27B model on Ollama on the same Mac, came back on
character ("Oh Alex. That stings, doesn't it? I'm right here with you.") with 0 leaks and
0 narration. End of speech to first audio was p50 6.33 s, of which Dee's own share was
p50 0.00 s and p90 0.22 s: the rest was the model. The smoke also found two real bugs.
Pauses mid-sentence split one utterance into several turns, and each new one cancelled the
reply in progress; pieces now merge within 0.8 s. In mode 3, Apple's speech detector gave
no results at all on the test Mac, so no turn ever started; turns now come from Dee's own
voice detector, and silence that should not be silent shows a problem on the screen.

Then came the server on port 8000, and it taught two more lessons. It serves exactly one
request at a time and answers a second one with HTTP 429, at once, no queue. Dee had been
overlapping requests all the time (a warm-up still running under the real reply, a new
request right after a cancel), so every overlapping turn was simply lost. Now each server
gets one lane: a request holds it until its stream has actually closed, and a refused reply
is retried for up to 8 seconds before Dee says so.

The second lesson was about caching, measured with six tiny requests on a 27B model and a
3,400-token prompt. First token, cold: 9.5 s. The same prompt again: 0.34 s. Only the last
*user* message changed: 0.19 s. Only the last *system* message changed: 8.49 s. The server,
like Ollama, hoists every system message to the top of the prompt, so the per-turn part of
the DNA, which Dee had sent as a system message, was invalidating the whole cache on every
turn. The per-turn context now rides on the user message, the stable DNA is pinned, and small
drift goes in as "(updated)" lines. The difference between a companion that answers and one
you wait for was one message role.

### Onboarding, and a key that never touches plain text
Until 0.6 the OpenAI key went into the iOS Settings app, where it sat in plain
preferences until the next launch. 0.6.0 has a first-launch onboarding (what Dee is, how
to talk, what is sent where in each mode and what it costs, one card per permission, the
provider, the wake phrase, the voice) and in-app settings behind a gear or a two-finger
press on the eyes. Keys are entered in the app and stored only in the Keychain. An old key
is moved there at first launch without a single network request, and the Settings-app page
is gone.

### Six people
Adding Six Personas: *"2 male, 2
female and 2 not identified personas ... one 20-something and one 40-something ...
appropriate DNA settings ... appropriate voice synthesizer ... Default will be 20-something
female.  *"The default Dee has no gender assignment. Don't say 'it' either. Just
use 'Dee' or I suppose 'they'"*.

So Dee, the companion, has no gender, and the docs now say "Dee". The personas do:

| Persona | Pronouns | Age | In one line |
|---|---|---|---|
| Mira (default) | she/her | 24 | A wide-eyed best friend who finds something wonderful in everything |
| Vera | she/her | 46 | Warm, unflappable, dry; tells you the truth kindly |
| Rio | he/him | 27 | A high-energy hype man with a teasing grin |
| Atlas | he/him | 44 | Calm as a lighthouse; deadpan you'll miss the first time |
| Nova | they/them | 23 | A night-owl daydreamer; quiet until something sparks |
| Haven | they/them | 47 | Grounded, quietly sure; makes hard days smaller |

Two complete designs were drawn up and scored on distinctiveness, fidelity to the request,
plausibility between the twenties and forties, valid parameters, names, voices and
stereotypes. The character-led one won, mainly on names that come out of the numbers:
Mira peaks on curiosity (.90) and openness (.85), and *mirari* is Latin for "to wonder";
Vera's top values are honesty and independence; Haven has the highest patience,
forgiveness and agreeableness of the set. Two fixes came out of the scoring. Haven's
confidence went up from .50 to .62, so that the two they/them personas aren't simply the
two soft ones. And every trait byte was checked to sit at least 4 away from a level edge,
so no persona flickers between "moderate" and "high" on a rounding error. Each persona sets
its own age, set points, humour, voice, speaking style and wake phrase: "Hey Mira" by
default.

### Numbers
- Package tests at the wrap of 0.6.0, by target: DeeSelf 607, DeeBrain 231, DeeWake 216, DeeMind 196,
  DeeMemory 122, DeeCore 111, DeeRealtime 110, DeeLocal 101, plus the face and sense suites and the
  harness's offline tests. Two DeeVoice timing tests are flaky under full-suite load and pass alone.
- Mode 1: end of a complete turn to first audio p90 1.53 s, Dee's own overhead p50 0.02 s, p90 0.14 s
  (the 0.6.0 smoke run).
- Wake: 100% in a quiet room, 82.5% in noise, 0 false wakes in 36 minutes.

### Lesson for the article
The expensive part of a voice companion is not the model. It's everything around it:
when to answer, when to keep quiet, what was actually heard, and what never needs to leave
the room. Fourteen rounds of tuning were spent on the first three. The fourth turned out
to be the simplest change of the release: listen for your name on the phone, and stay
disconnected until you hear it.
