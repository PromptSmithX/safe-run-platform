#!/usr/bin/env bash

set -euo pipefail

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen 2.46.0 or newer is required. Install it manually, then retry." >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Xcode command-line tools are required. Select an Xcode installation, then retry." >&2
  exit 1
fi

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$REPO_ROOT"
xcodegen generate --spec project.yml

