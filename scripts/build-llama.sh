#!/usr/bin/env bash
# Builds llama.xcframework (iOS device + iOS Simulator + macOS) from a pinned
# llama.cpp tag and installs it into Packages/DeeKit/Binaries/.
#
# Why build instead of using the release zip: upstream's published
# llama-bNNNN-xcframework.zip ships ios-arm64 + macOS only — no Simulator slice.
set -euo pipefail
TAG="${LLAMA_TAG:-b11514}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/llama.cpp-$TAG"
DEST="$ROOT/Packages/DeeKit/Binaries"

if [[ ! -d "$WORK" ]]; then
  git clone --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp.git "$WORK"
fi
cd "$WORK"
./build-xcframework.sh ios-sim ios-device macos
mkdir -p "$DEST"
rm -rf "$DEST/llama.xcframework"
cp -R build-apple/llama.xcframework "$DEST/"
echo "$TAG" > "$DEST/LLAMA_TAG"
echo "Installed llama.xcframework ($TAG) → $DEST"
