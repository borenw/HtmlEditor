#!/bin/bash
# Regenerates Resources/AppIcon.icns from Tools/MakeIcon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

swiftc -O -target "$(uname -m)-apple-macos12.0" -sdk "$(xcrun --show-sdk-path)" \
    Tools/MakeIcon.swift -o "$STAGE/makeicon"
"$STAGE/makeicon" "$STAGE/AppIcon.iconset"
iconutil -c icns "$STAGE/AppIcon.iconset" -o Resources/AppIcon.icns

echo "Wrote Resources/AppIcon.icns"
