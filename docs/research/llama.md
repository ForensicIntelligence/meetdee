# llama.cpp on iOS for Dee (checked 2026-10-08)

## 1. Getting the binary
- **Official xcframework zips exist.** Release `b10079` includes `llama-b10079-xcframework.zip`, which is 259,148,213 bytes with sha256 `1c1f27e6a909b5bc5769c8997ef9a69026ab6c28ef3cef5d72f48da36cdc7e65` (verified through the GitHub API). URL pattern: `https://github.com/ggml-org/llama.cpp/releases/download/bNNNN/llama-bNNNN-xcframework.zip`.
  - Recent `bNNNN` builds such as b11514 and b11513 are marked *prerelease*. b10079 is **not**.
  - The newest today is b11514. GitHub's "latest" release is `v0.6.0` (2026-10-05). Source: GitHub API `repos/ggml-org/llama.cpp/releases`.
- **SPM:** the upstream README documents `.binaryTarget(name:"LlamaFramework", url:…, checksum:…)` ([README](https://github.com/ggml-org/llama.cpp#xcframework)). The README example uses b5046, so substitute your pinned tag. The GitHub digest is the zip's sha256, so you can use it directly. Confirm it with `swift package compute-checksum`.
- **Module name:** `import llama` (as in `examples/llama.swiftui/llama.cpp.swift/LibLlama.swift`).
- **Building it yourself** (`build-xcframework.sh`): static library (`BUILD_SHARED_LIBS=OFF`), `GGML_METAL=ON`, `GGML_METAL_EMBED_LIBRARY=ON` (no separate .metallib), `GGML_METAL_USE_BF16=ON`, `GGML_BLAS_DEFAULT=ON` (Accelerate), `IOS_MIN_OS_VERSION=16.4`. It builds slices for the iOS device and simulator plus macOS/visionOS/tvOS, and needs CMake 3.28 or later.
- **Version caveat:** the local tree at `~/.unsloth/llama.cpp` is Unsloth's fork, not the upstream repo. `UNSLOTH_PREBUILT_INFO.json` shows `unslothai/llama.cpp`, tag `b10079-mix-fb3d4ca`, commit d161b26.
  - I diffed upstream `b10079` `include/llama.h` against the fork. The only API additions are `llama_diffusion_*` functions, and the APIs below match.
  - Upstream master has added `QWEN4EXP`, `KIMI_K3` and `DEEPSEEK4` (confirmed in `src/llama-arch.cpp`).
  - **Pin one tag** and keep the header and binary at the same version.

## 2. Current C API (b10079 `include/llama.h`)
- **Lifecycle:** `llama_backend_init()`, `llama_model_default_params()`, `llama_model_load_from_file(path, mp)`, `llama_init_from_model(model, cp)`, `llama_model_get_vocab(model)`, `llama_free`, `llama_model_free`, `llama_backend_free`. The old `llama_free_model` is deprecated.
- **Model params:** `n_gpu_layers` (a negative value means all layers), `use_mmap`, `use_direct_io` (takes precedence over mmap when supported), `use_mlock`, `use_extra_bufts`.
- **Context params:** `n_ctx`, `n_batch`, `n_ubatch`, `n_seq_max`, **`n_rs_seq`** (recurrent-state rollback snapshots, EXPERIMENTAL), `n_threads`/`n_threads_batch`, `flash_attn_type` (`LLAMA_FLASH_ATTN_TYPE_AUTO = -1`, `DISABLED = 0`, `ENABLED = 1`), `type_k`/`type_v`, `offload_kqv`, `swa_full`, `kv_unified`.
- **Batch:** `llama_batch_init(n, 0, 1)`, `llama_batch_free`, `llama_batch_get_one` ("avoid using it").
- **`llama_decode` return codes:**
  - 0 ok; 1 no KV slot; 2 aborted (the ubatches already processed stay in memory); -1 bad batch; < -1 fatal (processed ubatches also stay).
  - After an abort or fatal error, query `llama_memory_seq_pos_min` and `llama_memory_seq_pos_max`.
  - For any other code, the memory is restored to its state before the call.
- **Memory:** `llama_get_memory(ctx)`, `llama_memory_clear(mem, data)`, `llama_memory_seq_rm` (returns a Bool), `seq_cp`, `seq_keep`, `seq_add`, `seq_div`, `seq_pos_min`, `seq_pos_max`, `llama_memory_can_shift`.
- **State:** `llama_state_seq_get_size_ext`, `get_data_ext` and `set_data_ext` with `LLAMA_STATE_SEQ_FLAGS_PARTIAL_ONLY = 1` (an alias of the old `SWA_ONLY`) and `ON_DEVICE = 2`.
- **Vocab:**
  - `llama_tokenize(vocab, text, len, buf, max, add_special, parse_special)` returns a negative count when the buffer is too small (`INT32_MIN` on overflow).
  - `llama_token_to_piece(vocab, tok, buf, len, lstrip, special)` writes no NUL terminator.
  - Also `llama_vocab_is_eog` and `llama_detokenize`.
- **Samplers:**
  - Start with `llama_sampler_chain_init(llama_sampler_chain_default_params())`, then `llama_sampler_chain_add` (the chain takes ownership).
  - Available samplers: `init_penalties(last_n, repeat, freq, present)`, `top_k`, `top_p(p, min_keep)`, `min_p`, `temp`, `dist(seed)`.
  - Sample with `llama_sampler_sample(smpl, ctx, -1)`. `llama_sampler_reset` clears it.
- **Cancel:** `llama_set_abort_callback(ctx, cb, ud)`. If the callback returns true, `llama_decode` aborts.
- **`llama_chat_apply_template` is not a Jinja engine.** It only handles a fixed list of templates (here it would map to `chatml`), so it cannot pass `enable_thinking` ([wiki](https://github.com/ggml-org/llama.cpp/wiki/Templates-supported-by-llama_chat_apply_template)). **Build the ChatML prompt yourself in Swift.** That also gives Dee direct control of the thinking toggle.

## 3. Qwen3.5 (`qwen35`) as a hybrid model
- `llm_arch_is_hybrid` includes `LLM_ARCH_QWEN35`, so the model has both a KV cache and a recurrent state (`src/llama-arch.cpp`).
- **`seq_rm` on the recurrent part** (`src/llama-memory-recurrent.cpp:150`):
  - Removing the whole sequence always works.
  - Removing a trailing suffix works only if `1 <= rollback <= n_rs_seq`. Otherwise it **returns false**.
  - Only `QWEN35` and `QWEN35MOE` pass `llm_arch_supports_rs_rollback`. For any other architecture, `n_rs_seq` is clamped to 0 (`src/llama-context.cpp:104`).
- **What this means for Dee:**
  - **Multi-turn chat that only appends new tokens needs no removal.** Keep the state and decode only the new turn's tokens.
  - **Regenerate, edit, or dropping old turns when the context is full:** suffix removal is limited to the `n_rs_seq` snapshots, and you can't drop old turns from the front. Either re-run the whole prompt, or save a checkpoint after the system prompt with `llama_state_seq_get_data_ext(..., PARTIAL_ONLY)` and restore it. llama-server's "context checkpoints" do the same thing.
  - **Context shift is unavailable.** The hybrid memory defers to its KV cache, and qwen35 uses `LLAMA_ROPE_TYPE_IMROPE` (`n_pos_per_embd() = 4`). As a result `llama_kv_cache::get_can_shift()` returns false, so `llama_memory_can_shift` is false. At 4096 tokens, compress the history and re-run the prompt.
  - With M-RoPE, each new batch must start at a position greater than the last one stored (`llama-batch.cpp:255`). Appending one token at a time with plain 1-D positions is fine.
- **Thinking:**
  - The official Qwen3.5-4B template (`Qwen/Qwen3.5-4B/chat_template.jinja`) **turns thinking ON by default**. It emits `<think>\n` unless `enable_thinking` is explicitly false. The [model card](https://huggingface.co/Qwen/Qwen3.5-4B) says "Qwen3.5 models operate in thinking mode by default".
  - Since Dee builds its own ChatML, **Dee must send the off suffix itself.**
  - For "off", end the prompt with `<|im_start|>assistant\n<think>\n\n</think>\n\n` (verified).
  - For "on", end it with `<|im_start|>assistant\n<think>\n` (verified), and remove the `<think>…</think>` text from the speech and transcript.
  - EOS is `<|im_end|>`.
  - The embedded template in the Unsloth GGUF may differ from the official one (**UNVERIFIED**). Check it with `llama_model_chat_template(model, nil)`.

## 4. Metal, flash attention and memory on iOS
- **Metal:** builds for iOS 16+, with extra paths behind `iOS 18` availability checks (`ggml-metal-device.m`). The Metal sources contain kernels for gated-delta-net and SSM_CONV, so qwen35 should run fully on the GPU. **Real-device performance: UNVERIFIED.**
- **Model file:** `unsloth/Qwen3.5-4B-GGUF` `Qwen3.5-4B-Q4_K_M.gguf` is 2,740,937,888 bytes (HF API).
- **`n_gpu_layers`:** use `-1` (or 99) on a device. In the simulator, force `0`, as the example does with `#if targetEnvironment(simulator)`.
- **Flash attention:** use `AUTO`.
- **mmap:** leave it on. A read-only file in the app bundle is clean, file-backed memory that the OS can evict, so it puts less pressure on the memory limit.
- **mlock:** leave it off. Wiring about 2.7 GB on iOS will likely fail (**UNVERIFIED**).
- **Memory limit:** add the `com.apple.developer.kernel.increased-memory-limit` entitlement ([Apple docs](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit)).
- **Settings for a 4096 context:** `n_batch` 512 and `n_seq_max` 1.
- **Abort callback:** whether it interrupts a running Metal command buffer, rather than only stopping between ubatches, is **UNVERIFIED**. Also check a cancel flag between tokens.

## 5. Swift wrapper sketch
The sketch from the original brief is unchanged except for one line, the penalties sampler:
```swift
llama_sampler_chain_add(smpl, llama_sampler_init_penalties(64, 1.0, 0, 1.5)) // Qwen: repetition 1.0, presence 1.5
```
The other sampler lines (`top_k(20)`, `top_p(0.8, 1)`, `temp(0.7)`, `dist(seed)`) stay as they are.

**Notes on the sketch:**
- `reset()` is meant for the start of a new conversation, which also turns thinking back off.
- `prefill` takes `tokenize(text, special: nPast == 0)` as `add_special`, and `parse_special` is always true so the ChatML tags parse correctly.
- Turn the `AbortFlag` into an atomic (`Synchronization.Atomic`) before shipping.
- Swift 6 actor-isolation details are **UNVERIFIED**.
- Sampler values: the [Qwen3.5 card](https://huggingface.co/Qwen/Qwen3.5-4B) gives `temperature=0.7, top_p=0.8, top_k=20, min_p=0, presence_penalty=1.5, repetition_penalty=1.0` for non-thinking mode, and `temperature=1.0, top_p=0.95, top_k=20, presence_penalty=1.5` for thinking mode. Switch the chain when thinking turns on.

**Files read:** `/Users/johnczlonka/.unsloth/llama.cpp/{build-xcframework.sh, include/llama.h, examples/llama.swiftui/llama.cpp.swift/LibLlama.swift, src/llama-memory-recurrent.cpp, src/llama-memory-hybrid.cpp, src/llama-kv-cache.cpp, src/llama-arch.cpp, src/llama-context.cpp, src/llama-batch.cpp, src/llama-model.cpp, UNSLOTH_PREBUILT_INFO.json}`. Fetched copies of the official template, the upstream header and HF tokenizer config are in `/private/tmp/claude-501/-Users-johnczlonka-Desktop-Dee/8094b980-0cc0-4e79-81ec-aa80684a07d3/scratchpad/`: `q_chat_template.jinja`, `up_llama.h`, `q_tokenizer_config.json`.

## Corrections
1. **Thinking default was wrong.** The official Qwen3.5-4B template and model card turn thinking ON by default. Dee must explicitly append the `<think>\n\n</think>\n\n` off suffix. The exact strings were marked UNVERIFIED in the brief and are now verified.
2. **Sampler values corrected.** The penalties sampler is now `(64, 1.0, 0, 1.5)`: repetition 1.0, presence 1.5. Thinking-mode values were added.
3. **"`bNNNN` builds are now marked prerelease" was clarified.** Recent builds are, but b10079 itself is not.
4. **Context shift: the reason is now confirmed.** It is unavailable because of IMROPE (`n_pos_per_embd = 4`). The earlier "should be false" was a guess. The M-RoPE batch-position rule was added.
5. **Fork provenance and header diff confirmed.** The fork only adds the `llama_diffusion_*` APIs, and the new upstream architectures were confirmed.
6. **Small additions:** the model file size, the `PARTIAL_ONLY`/`SWA_ONLY` alias, the full set of decode return-code semantics, and the note that the README example uses b5046.