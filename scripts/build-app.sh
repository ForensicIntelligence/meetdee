#!/usr/bin/env bash
# Regenerates Dee.xcodeproj and builds the app for the iOS Simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project Dee.xcodeproj -scheme Dee \
  -destination "${DEE_DESTINATION:-generic/platform=iOS Simulator}" \
  -derivedDataPath "$HOME/Library/Caches/Dee/DD" build
