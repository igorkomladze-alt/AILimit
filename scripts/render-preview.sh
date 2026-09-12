#!/bin/bash
# Render the real SwiftUI panel offline with synthetic data, using a separate helper.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcodegen generate >/dev/null
xcodebuild -project AILimits.xcodeproj -scheme AILimits -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/MediaDerivedData build \
  >build/media-build.log 2>&1
products="$PWD/build/MediaDerivedData/Build/Products/Debug"
helper="$PWD/build/MediaRenderer.app"
mkdir -p "$helper/Contents/MacOS" "$helper/Contents/Resources"
cat > "$helper/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.ailimits.MediaRenderer</string>
<key>CFBundleExecutable</key><string>MediaRenderer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
cp "$products/AILimits.app/Contents/Resources/Assets.car" "$helper/Contents/Resources/Assets.car"
swiftc -parse-as-library -package-name AILimits -swift-version 6 \
  -I "$products" "$products/AILimitsCore.o" "$products/AILimitsMac.o" \
  App/Views/*.swift scripts/render-preview.swift \
  -o "$helper/Contents/MacOS/MediaRenderer"
codesign --force --sign - "$helper"
"$helper/Contents/MacOS/MediaRenderer" "$PWD/docs/images"
