# Qwen3.5-4B brief for Dee (checked against Hugging Face, 2026-10-08)

## Repos and files
- **Official weights:** https://huggingface.co/Qwen/Qwen3.5-4B. Apache-2.0, created 2026-02-27, pipeline `image-text-to-text`, about 4.66B parameters stored in BF16 safetensors. Architecture class is `Qwen3_5ForConditionalGeneration` and `model_type` is `qwen3_5` (re-checked in config.json).
- **Official Qwen GGUF:** both `Qwen/Qwen3.5-4B-GGUF` and `ggml-org/Qwen3.5-4B-GGUF` return HTTP 401 from the HF API (re-checked). They are not public or do not exist. Not checked further.
- **Community GGUFs:** these are public: `unsloth/Qwen3.5-4B-GGUF`, `lmstudio-community/Qwen3.5-4B-GGUF`, `bartowski/Qwen_Qwen3.5-4B-GGUF`.
- **Q4_K_M (unsloth):** `Qwen3.5-4B-Q4_K_M.gguf`, **2,740,937,888 bytes (about 2.55 GiB)**. I confirmed this through the HF tree API and the `x-linked-size` header.
  - URL: https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf
  - Nearby sizes (confirmed): Q4_K_S 2,590,430,368 · IQ4_XS 2,477,053,088 · UD-Q4_K_XL 2,912,109,728 · Q3_K_M 2,293,388,448.
- **Multimodal: YES.** The model is a "Causal Language Model with Vision Encoder".
  - mmproj files: `mmproj-F16.gguf` 672,423,616 B, `mmproj-BF16.gguf` 675,569,344 B, `mmproj-F32.gguf` 1,334,075,072 B (confirmed).
  - Text-only use needs no mmproj.
  - `tokenizer_config.json` also lists audio tokens (`<|audio_start|>`, `<|audio_end|>`, `<|audio_pad|>`). Audio support is UNVERIFIED.

## Architecture (`config.json`, re-checked)
- **Layers:** 32, with `full_attention_interval: 4`. That gives 24 Gated DeltaNet layers and 8 Gated Attention layers.
- **Sizes:** hidden 2560, FFN 9216.
- **Gated DeltaNet:** 32 linear V heads and 16 linear K heads.
- **Gated Attention:** 16 Q heads, 4 KV heads, head dim 256. RoPE `partial_rotary_factor` 0.25, `rope_theta` 1e7, interleaved M-RoPE with `mrope_section` [11,11,10].
- **Vocab:** 248,320, tied embeddings, `mtp_num_hidden_layers: 1`.
- **Context:** 262,144 native. The YaRN 1,010,000 figure comes from the card and was not re-checked.
- **KV cache at 4096 context:** 8 × 2 × 4 × 256 × 4096 × 2 B ≈ **64 MiB in fp16**. Only the 8 attention layers keep a KV cache; the DeltaNet layers keep a fixed recurrent state.
- **Card warning:** "maintaining a context length of at least 128K tokens to preserve thinking capabilities". At 4096 tokens, Dee should cap the thinking budget.
- **GGUF header (re-parsed):**
  - `general.architecture = qwen35`, `qwen35.context_length = 262144`.
  - `tokenizer.ggml.eos_token_id = 248046`, which is `<|im_end|>`.
  - `config.json` `eos_token_id` is 248044 (`<|endoftext|>`). Stop on both.
- **llama.cpp:** the local tree at `~/.unsloth/llama.cpp` supports the architecture.
  - `src/llama-arch.cpp` has `LLM_ARCH_QWEN35 → "qwen35"`, and `llama_model_qwen35` exists in `src/llama-model.cpp`. A `QWEN35MOE` architecture is also present.
  - The tree ships `build-xcframework.sh`, which is useful for building for iOS.
  - The local tree is not a git checkout, so its build number is unknown.
  - Upstream releases use `bNNNNN` tags; the latest is `b11514` (2026-10-08).
  - The GitHub "latest" endpoint returns a stray `v0.6.0` tag (2026-10-05). Ignore it: pin a `b`-tag and test on a device.
  - The first build that supports `qwen35` is UNVERIFIED.

## Special tokens (`tokenizer_config.json`, re-checked)
`<|endoftext|>` 248044 · `<|im_start|>` 248045 · `<|im_end|>` 248046 · `<|vision_start|>` 248053 · `<|vision_end|>` 248054 · `<|image_pad|>` 248056 · `<tool_call>` 248058 · `</tool_call>` 248059 · `<tool_response>` 248066 · `</tool_response>` 248067 · `<think>` 248068 · `</think>` 248069.

- `bos_token` is null and `add_bos_token` is false. `eos_token` is `<|im_end|>`; `pad_token` is `<|endoftext|>`.
- `<think>`, `</think>`, `<tool_call>` and `<tool_response>` all have `special: false`. They show up when detokenizing, so parse them out of the text stream.

## Chat template (official, quoted exactly; confirmed)
Source: https://huggingface.co/Qwen/Qwen3.5-4B/raw/main/chat_template.jinja
```jinja
{%- if add_generation_prompt %}
    {{- '<|im_start|>assistant\n' }}
    {%- if enable_thinking is defined and enable_thinking is false %}
        {{- '<think>\n\n</think>\n\n' }}
    {%- else %}
        {{- '<think>\n' }}
    {%- endif %}
{%- endif %}
```
**The unsloth GGUF's embedded template flips the default** (confirmed in the Q4_K_M header):
```jinja
    {%- if enable_thinking is defined and enable_thinking is true %}
        {{- '<think>\n' }}
    {%- else %}
        {{- '<think>\n\n</think>\n\n' }}
```
So the official template thinks unless told otherwise, and the unsloth GGUF does not.

Past assistant turns:
- After the last user query, an assistant turn is rendered as `'<|im_start|>' + role + '\n<think>\n' + reasoning_content + '\n</think>\n\n' + content`.
- Earlier assistant turns are rendered as content only.

Other formatting:
- System message: `<|im_start|>system\n{content}<|im_end|>\n`
- User message: `<|im_start|>user\n{content}<|im_end|>\n`
- Tool results go inside a **user** turn as `\n<tool_response>\n{content}\n</tool_response>`. Consecutive tool results share one turn, which is closed by `<|im_end|>\n`.

## Thinking control
- **Default is thinking ON.** The card says "Qwen3.5 models operate in thinking mode by default" and "Qwen3.5 will think by default before response." (confirmed)
- **Soft switches are gone.** "Qwen3.5 does not officially support the soft switch of Qwen3, i.e., `/think` and `/nothink`." (confirmed)
- **The only control is `enable_thinking`.**
- **Recommendation for Dee:** build the prompt in Swift.
  - Thinking off: end the prompt with `<|im_start|>assistant\n<think>\n\n</think>\n\n`.
  - Thinking on: end it with `<|im_start|>assistant\n<think>\n`.
  - Keep a per-conversation flag, set it when the user says "think about it", and reset it on a new conversation.

## Recommended sampling (card, confirmed)
| Mode | temp | top_p | top_k | min_p | presence | rep |
|---|---|---|---|---|---|---|
| Thinking, general | 1.0 | 0.95 | 20 | 0 | 1.5 | 1.0 |
| Thinking, coding | 0.6 | 0.95 | 20 | 0 | 0.0 | 1.0 |
| Non-thinking, general | 0.7 | 0.8 | 20 | 0 | 1.5 | 1.0 |
| Non-thinking, reasoning | 1.0 | 0.95 / 1.0 | 20 / 40 | 0 | 1.5 / 2.0 | 1.0 |

- The card contradicts itself on the last row (line 838 vs. line 1144).
- `generation_config.json` returns 404.

## Tool calling (XML, Qwen3-Coder style)
Tools are listed as JSON (`tool | tojson`) inside `<tools>…</tools>` in the system message. The template then says (confirmed):
```
If you choose to call a function ONLY reply in the following format with NO suffix:

<tool_call>
<function=example_function_name>
<parameter=example_parameter_1>
value_1
</parameter>
<parameter=example_parameter_2>
This is the value for the second parameter
that can span
multiple lines
</parameter>
</function>
</tool_call>
```
- The same block warns: "You may provide optional reasoning for your function call in natural language BEFORE the function call, but NOT after."
- Mapping and sequence arguments are written with `tojson`; everything else is written with `string`.
- The card's vLLM and SGLang commands use `--tool-call-parser qwen3_coder` (and `--reasoning-parser qwen3`).
- Write a Swift parser for `<tool_call>\n<function=NAME>\n<parameter=K>\nV\n</parameter>…</function>\n</tool_call>`.

## Unverified
- Which llama.cpp build first supports `qwen35`.
- Audio capability.
- How much 4096 tokens hurts thinking quality.
- The official Qwen GGUF repo (401).
- The YaRN 1,010,000 figure, the ViT layer count and patch size, and the SSM state dtype were not re-checked.

Sources:
- https://huggingface.co/Qwen/Qwen3.5-4B (README, config.json, tokenizer_config.json, chat_template.jinja)
- https://huggingface.co/unsloth/Qwen3.5-4B-GGUF (file tree, the Q4_K_M header)
- https://api.github.com/repos/ggml-org/llama.cpp/releases
- local `~/.unsloth/llama.cpp/src/llama-arch.cpp`

## Corrections
1. **llama.cpp release tag:** the brief reported `v0.6.0` as the latest release. That tag is a stray. Real llama.cpp releases are `bNNNNN` tags (latest `b11514`, 2026-10-08), so pin a `b`-tag.
2. **Local llama.cpp support:** added that the local tree at `~/.unsloth/llama.cpp` does support `qwen35` (`LLM_ARCH_QWEN35` and `llama_model_qwen35`), plus a `qwen35moe` variant, and ships `build-xcframework.sh`.
3. **Special-token flags:** `<tool_response>` and `</tool_response>` are also marked non-special. The brief named only `<think>` and `<tool_call>`.
4. **Tool-result formatting:** fixed the exact newlines in the tool-response wrapper.
5. **Audio tokens:** the brief listed `<tts_pad>`, which `tokenizer_config.json` does not show; the actual audio tokens are `<|audio_start|>`, `<|audio_end|>` and `<|audio_pad|>`.
6. **Claims I did not re-check:** marked as such (the YaRN figure, the ViT details, the SSM state dtype).
7. **Confirmed unchanged:** every other file size, token ID, template excerpt, eos ID, config value and sampling figure in the brief.