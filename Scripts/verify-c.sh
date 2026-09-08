#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
FUNCTIONS_ROOT="$REPO_ROOT/Backend/functions"

for command in node npm java; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "$command is required; this script does not install dependencies." >&2
    exit 1
  fi
done

if [ "$(node -p 'process.versions.node.split(`.`)[0]')" != "22" ]; then
  echo "Node.js 22 is required to match the Cloud Functions runtime." >&2
  exit 1
fi

"$SCRIPT_DIR/verify-b.sh"

cd "$FUNCTIONS_ROOT"
npm ci
npm run typecheck
npm test
npx firebase emulators:exec \
  --config "$REPO_ROOT/firebase.json" \
  --project demo-safe-run \
  --only auth,firestore,functions \
  "npm run test:emulator"

cd "$REPO_ROOT"
xcodebuild \
  -workspace SafeRun.xcworkspace \
  -scheme SafeRunPhoneCore \
  -configuration Debug \
  -destination "platform=iOS Simulator,name=iPhone 16" \
  CODE_SIGNING_ALLOWED=NO \
  test

xcodebuild \
  -workspace SafeRun.xcworkspace \
  -scheme SafeRunApp \
  -configuration Debug \
  -destination "generic/platform=iOS Simulator" \
  CODE_SIGNING_ALLOWED=NO \
  build
