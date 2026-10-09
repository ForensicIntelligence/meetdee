#!/usr/bin/env bash
# Runs the DeeKit test suite. Build output lives outside the iCloud-synced Desktop
# (file-provider xattrs break codesign).
set -euo pipefail
cd "$(dirname "$0")/../Packages/DeeKit"
swift test --scratch-path "$HOME/Library/Caches/Dee/spm" "$@"
