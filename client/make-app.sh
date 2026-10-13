#!/bin/bash
# Wrap the SwiftUI executable into a proper Papertalk.app bundle.
set -euo pipefail
cd "$(dirname "$0")"

swift build >/dev/null

APP="dist/Papertalk.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/debug/Papertalk "$APP/Contents/MacOS/Papertalk"
cp Sources/Papertalk/Info.plist "$APP/Contents/Info.plist"

# App icon (shared asset)
if [ -f ../shared/icon.icns ]; then
  cp ../shared/icon.icns "$APP/Contents/Resources/Papertalk.icns"
  plutil -replace CFBundleIconFile -string Papertalk "$APP/Contents/Info.plist"
fi

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"