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
(
  cd Backend/functions
  npm ci --ignore-scripts
  npm run typecheck
  npm test
  npx firebase emulators:exec --project demo-safe-run --only auth,firestore,functions "npm run test:emulator"
)
xcodebuild -workspace SafeRun.xcworkspace -scheme SafeRunWatchCore -configuration Debug -destination "platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)" CODE_SIGNING_ALLOWED=NO test
xcodebuild -workspace SafeRun.xcworkspace -scheme SafeRunPhoneCore -configuration Debug -destination "platform=iOS Simulator,name=iPhone 16" CODE_SIGNING_ALLOWED=NO test
xcodebuild -workspace SafeRun.xcworkspace -scheme SafeRunWatchApp -configuration Debug -destination "generic/platform=watchOS Simulator" CODE_SIGNING_ALLOWED=NO build
xcodebuild -workspace SafeRun.xcworkspace -scheme SafeRunApp -configuration Debug -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build
