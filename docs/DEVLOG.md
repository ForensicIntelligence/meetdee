# Dee — Developer Log

A running, honest record of building Dee: a pocket robot companion with Loona's eyes,
Wall-E's soul, and a 4-billion-parameter brain that never leaves the phone. Written
to become a magazine series, so it keeps the numbers, the dead ends and the
small surprises, not just the wins.

---

## 2026-10-08 — v0.1 "Foundation": a brain in a jar

### The brief
John's ask, roughly: *an expressive, agentic, speaking assistant for iPhone. On-device
AI, Qwen3.5-4B at Q4_K_M. Bundle the model if Apple allows it. Thinking off by default,
switched on when you ask it to "think about it", and off again for a new conversation.
The face should be a Loona / Wall-E mash-up. Build it in phases, keep a log, ROS later.*

### Research day (five agents, one afternoon)
Before writing code we sent five research agents out in parallel, each followed by a
skeptical fact-checker. Their briefs live in `docs/research/`. What we learned:

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
and cancelled at 1024. A reviewer agent pointed out why that's wrong: the engine runs
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
test agent wrote a 94-utterance table, and the first regex set got **9 wrong**:

- *"I can't stop thinking about you"* switched thinking **off**.
- *"Stop and think about it"* was read as a negation.
- *"Give me step by step instructions"* switched it on.

The detector now removes opinion idioms first ("what do you think of…", "I'll think
about it", "let me think"). Negation must sit directly against the verb, and
"step by step" counts only after *think / reason / solve / work it out*. 94/94 now.

### Adversarial review: the Stop button didn't stop
One agent's only job was to read the engine and agent and try to break them. It found
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
Mid-build, John added a rule that rearranged the whole app: *every interaction is
voice and/or camera.* The chat transcript and text field from v0.1 are gone from
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
John again, mid-build: *"Our interactions with the AI need to persist. We don't
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
  more agreeable and confident, but an elastic pull back to its set points means
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
The first version of the heart *worked*, but three verification agents found the
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
  for a few minutes, then rests. Loneliness still grows while it rests, just more
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

## 2026-10-08 (late) — v0.4 "She's alive": voice, touch, sight, memory

John tried v0.3 on his phone. The verdict was blunt: *I couldn't speak to Dee and
she wouldn't speak back… it asked to use the camera, but not the microphone. Then
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
  so when you laugh, she laughs.
- **Touch:** a UIKit layer reads finger contact size, speed and rhythm. Strokes are
  petting, a still palm is a hug, rapid taps are pokes, a hard quick hit is a slap,
  and quick jiggles are a tickle. Kind touch makes her happier *and* nudges her
  personality kinder over time; rough touch does the opposite.
- **Sight:** Vision's on-device classifier on the front camera and, where the phone
  allows two cameras at once, the back camera. New things get a double-take and a
  question.
- **Reflexes above mood:** a joke makes the face giggle even when she's cross. The
  "?" bug turned out to be arithmetic: at rest, curiosity sat a hair above joy, so
  "curious" won forever. Expressions are now chosen by how far each feeling sits
  *from its own resting level*.
- **The eyes:** 37 emotions with glyph eyes (`> <`, spirals, `X X`, `– –`, `U`,
  tears, glossy highlights), 17 little performances (wink, yawn, eye-roll,
  double-take, giggle…), an idle director that keeps her busy, and small random
  variations so she never looks quite the same twice.
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
