#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
WATCH_DESTINATION="$(printenv SAFERUN_WATCH_DESTINATION 2>/dev/null || true)"

if [ -z "$WATCH_DESTINATION" ]; then
  WATCH_DESTINATION="platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)"
fi

"$SCRIPT_DIR/verify-m0.sh"

cd "$REPO_ROOT"

xcodebuild \
  -workspace SafeRun.xcworkspace \
  -scheme SafeRunWatchCore \
  -configuration Debug \
  -destination "$WATCH_DESTINATION" \
  CODE_SIGNING_ALLOWED=NO \
  test

xcodebuild \
  -workspace SafeRun.xcworkspace \
  -scheme SafeRunWatchApp \
  -configuration Debug \
  -destination "generic/platform=watchOS Simulator" \
  CODE_SIGNING_ALLOWED=NO \
  build

