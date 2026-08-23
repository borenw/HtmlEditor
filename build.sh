#!/bin/bash
# Builds HtmlEditor.app into build/. Needs the Xcode Command Line Tools only.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/HtmlEditor.app"
SDK="$(xcrun --show-sdk-path)"
ARCH="$(uname -m)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O \
    -target "${ARCH}-apple-macos12.0" \
    -sdk "$SDK" \
    Sources/HtmlEditor/*.swift \
    -o "$APP/Contents/MacOS/HtmlEditor"

cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo "Run it with:  open $APP"
