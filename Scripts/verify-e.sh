#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

"$SCRIPT_DIR/verify-d.sh"
cd "$REPO_ROOT"

xcodebuild -workspace SafeRun.xcworkspace -scheme SafeRunWatchCore -configuration Debug \
  -destination "platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)" CODE_SIGNING_ALLOWED=NO test
xcodebuild -workspace SafeRun.xcworkspace -scheme SafeRunPhoneCore -configuration Debug \
  -destination "platform=iOS Simulator,name=iPhone 16" CODE_SIGNING_ALLOWED=NO test
xcodebuild -workspace SafeRun.xcworkspace -scheme SafeRunWatchApp -configuration Debug \
  -destination "generic/platform=watchOS Simulator" CODE_SIGNING_ALLOWED=NO build
xcodebuild -workspace SafeRun.xcworkspace -scheme SafeRunApp -configuration Debug \
  -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build
