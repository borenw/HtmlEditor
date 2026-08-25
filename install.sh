#!/bin/bash
# One-shot installer: builds HtmlEditor from source and puts it in /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/borenw/HtmlEditor/main/install.sh | bash
#
set -euo pipefail

REPO="https://github.com/borenw/HtmlEditor.git"
APP_NAME="HtmlEditor.app"
DEST="/Applications"

say()  { printf "\033[1m==>\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31m==>\033[0m %s\n" "$*" >&2; exit 1; }

# swiftc ships with the Command Line Tools; full Xcode is not needed.
if ! xcrun --show-sdk-path >/dev/null 2>&1; then
    die "Xcode Command Line Tools are required. Run:  xcode-select --install"
fi

# Use the checkout we were run from, or fetch a fresh one when piped from curl.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
if [ -f "$SCRIPT_DIR/Sources/HtmlEditor/main.swift" ]; then
    SRC="$SCRIPT_DIR"
else
    CLONE_DIR="$(mktemp -d)"
    trap 'rm -rf "$CLONE_DIR"' EXIT
    SRC="$CLONE_DIR/HtmlEditor"
    say "Downloading HtmlEditor…"
    git clone --depth 1 --quiet "$REPO" "$SRC" || die "Could not clone $REPO"
fi

say "Building for $(uname -m)…"
STAGE="$(mktemp -d)"
APP="$STAGE/$APP_NAME"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O \
    -target "$(uname -m)-apple-macos12.0" \
    -sdk "$(xcrun --show-sdk-path)" \
    "$SRC"/Sources/HtmlEditor/*.swift \
    -o "$APP/Contents/MacOS/HtmlEditor" || die "Build failed"

cp "$SRC/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc sign and strip quarantine so it opens without a Gatekeeper detour.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

say "Installing to ${DEST}…"
pkill -f "$APP_NAME/Contents/MacOS/HtmlEditor" 2>/dev/null || true
if ! { rm -rf "$DEST/$APP_NAME" && cp -R "$APP" "$DEST/"; } 2>/dev/null; then
    say "Administrator password needed to write to $DEST"
    sudo rm -rf "$DEST/$APP_NAME"
    sudo cp -R "$APP" "$DEST/"
fi
rm -rf "$STAGE"

say "Installed $DEST/$APP_NAME"
open "$DEST/$APP_NAME"
