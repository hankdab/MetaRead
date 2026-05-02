#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is not installed."
  echo "Install with: brew install xcodegen"
  exit 1
fi

xcodegen generate
echo "Generated NovelReader.xcodeproj"
