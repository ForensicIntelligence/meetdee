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
