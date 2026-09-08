#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

for tool in node java npm xcodegen xcodebuild swift; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool" >&2; exit 1; }
done
[ "$(node -p 'process.versions.node.split(`.`)[0]')" = "22" ] || { echo "Node.js 22 is required." >&2; exit 1; }

"$SCRIPT_DIR/verify-e.sh"
cd "$REPO_ROOT"
xcodebuild -workspace SafeRun.xcworkspace -scheme SafeRunWatchApp -configuration Release -destination "generic/platform=watchOS Simulator" CODE_SIGNING_ALLOWED=NO build
xcodebuild -workspace SafeRun.xcworkspace -scheme SafeRunApp -configuration Release -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build
