#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
IOS_DESTINATION="$(printenv SAFERUN_IOS_DESTINATION 2>/dev/null || true)"

if [ -z "$IOS_DESTINATION" ]; then
  IOS_DESTINATION="platform=iOS Simulator,name=iPhone 16"
fi

"$SCRIPT_DIR/verify-a.sh"

cd "$REPO_ROOT"

xcodebuild \
  -workspace SafeRun.xcworkspace \
  -scheme SafeRunPhoneCore \
  -configuration Debug \
  -destination "$IOS_DESTINATION" \
  CODE_SIGNING_ALLOWED=NO \
  test

xcodebuild \
  -workspace SafeRun.xcworkspace \
  -scheme SafeRunApp \
  -configuration Debug \
  -destination "generic/platform=iOS Simulator" \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -workspace SafeRun.xcworkspace \
  -scheme SafeRunWatchApp \
  -configuration Debug \
  -destination "generic/platform=watchOS Simulator" \
  CODE_SIGNING_ALLOWED=NO \
  build
