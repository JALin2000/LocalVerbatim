#!/bin/bash
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE="$APP_ROOT/LocalVerbatim.app"
BUILD_CACHE="${LOCALVERBATIM_BUILD_CACHE:-${LOCALSCRIBE_BUILD_CACHE:-$APP_ROOT/.build-cache}}"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$BUILD_CACHE"
xcrun swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos15.0 -module-cache-path "$BUILD_CACHE" \
  "$APP_ROOT"/Sources/LocalVerbatim/*.swift -o "$APP_BUNDLE/Contents/MacOS/LocalVerbatim"
cp "$APP_ROOT/scripts/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
if [ -f "$APP_ROOT/scripts/AppIcon.icns" ]; then
  cp "$APP_ROOT/scripts/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi
/bin/cp -R "$APP_ROOT/Resources/" "$APP_BUNDLE/Contents/Resources/"
mkdir -p "$APP_BUNDLE/Contents/Resources/Legal"
cp "$APP_ROOT/LICENSE" "$APP_ROOT/NOTICE" "$APP_ROOT/THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/Contents/Resources/Legal/"
/bin/cp -R "$APP_ROOT/LICENSES" "$APP_BUNDLE/Contents/Resources/Legal/"
codesign --force --deep --sign - "$APP_BUNDLE"
echo "Built $APP_BUNDLE"
