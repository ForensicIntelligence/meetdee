# Dee

A pocket robot companion for iPhone: Loona's eyes, Wall-E's soul, and a Qwen3.5-4B
brain that runs entirely on-device via llama.cpp.

## Setup
1. `scripts/build-llama.sh` — builds `llama.xcframework` (b11514) into `Packages/DeeKit/Binaries/`.
2. Download the model into `Models/`:
   `curl -L -o Models/Qwen3.5-4B-Q4_K_M.gguf https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf`
3. Open `Dee.xcodeproj` (regenerate with `xcodegen generate` after editing `project.yml`).

## Tests
`scripts/test.sh` — unit tests plus real-model tests (skipped if the GGUF is absent).

## Docs
- `docs/PHASES.md` — the phased plan and status
- `docs/DEVLOG.md` — the running developer log (source for the magazine series)
- `docs/research/` — research briefs (App Store limits, Qwen3.5, llama.cpp, face design, iOS frameworks)
