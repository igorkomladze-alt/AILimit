#!/bin/bash
# Task 2, шаг 4: сборка .app в build/ проекта. Ничего не устанавливает.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo "macOS required" >&2; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { echo "Apple Silicon required" >&2; exit 1; }

# Сборка через xcodegen + xcodebuild (отклонение от SPM-продукта задокументировано
# в docs/source-audit.md; приёмка Task 2 — запускаемая .app — выполняется).
xcodegen generate >/dev/null
xcodebuild -project AILimits.xcodeproj -scheme AILimits -configuration Release -destination "platform=macOS,arch=arm64" build \
  -derivedDataPath build/DerivedData >/dev/null

bin_dir="build/DerivedData/Build/Products/Release"
app="$PWD/build/AI Limits.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/AILimits.app/Contents/MacOS/AILimits" "$app/Contents/MacOS/AILimitsApp"
cp "$bin_dir/AILimits.app/Contents/Resources/Assets.car" "$app/Contents/Resources/Assets.car"
cp App/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable AILimitsApp" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName AI Limits" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.gutfresh.AILimits" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDevelopmentRegion ru" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$app/Contents/Info.plist"
swift scripts/render-icon.swift "$PWD/build/AppIcon.iconset"
iconutil -c icns "$PWD/build/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
/usr/bin/plutil -lint "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --strict --verbose=1 "$app"
echo "$app"
