#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

"$SCRIPT_DIR/bootstrap-xcode.sh"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift is required to run SafeRunDomain tests." >&2
  exit 1
fi

cd "$REPO_ROOT"

swift test --package-path Packages/SafeRunDomain

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

