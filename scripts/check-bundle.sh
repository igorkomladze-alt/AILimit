#!/bin/bash
# Task 2, шаг 5: проверка bundle.
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/build/AI Limits.app"
[[ -x "$app/Contents/MacOS/AILimitsApp" ]] || { echo "FAIL: executable missing" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$app/Contents/Info.plist")" == "true" ]] \
  || { echo "FAIL: LSUIElement must be true" >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "local.gutfresh.AILimits" ]] \
  || { echo "FAIL: bundle id" >&2; exit 1; }
/usr/bin/codesign --verify --strict "$app"
echo "OK: bundle valid"
