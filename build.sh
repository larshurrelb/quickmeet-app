#!/bin/bash
# Builds QuickMeet.app.
#
# Signing identity matters more than it looks. macOS ties TCC permissions — Microphone
# and System Audio Recording — to the *code signature*, not just the path. An ad-hoc
# signature changes every time the code changes, so each rebuild silently invalidates
# both: the Privacy list keeps showing QuickMeet as allowed while the app is refused.
#
# Signing with a real (even development) certificate keeps the identity stable across
# rebuilds, so permissions are granted once and stay granted.
set -euo pipefail

cd "$(dirname "$0")"

APP="QuickMeet.app"
CONTENTS="$APP/Contents"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"Apple Development: [^"]+"' | head -1 | tr -d '"')

if [ -z "$IDENTITY" ]; then
    IDENTITY="-"
    echo "⚠︎  No Apple Development certificate found — falling back to ad-hoc signing."
    echo "   Microphone and System Audio Recording will reset on every rebuild."
    echo
fi

# The .icns is generated from AppIcon.png rather than committed — it is a 4 MB build
# artefact of a file already in the repo, and a stale one is worse than none.
if [ ! -f AppIcon.icns ]; then
    echo "▸ Generating AppIcon.icns…"
    swift make-icon.swift
    iconutil -c icns AppIcon.iconset -o AppIcon.icns
    rm -rf AppIcon.iconset
fi

echo "▸ Compiling…"
swift build -c release

echo "▸ Assembling $APP…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp .build/release/QuickMeet "$CONTENTS/MacOS/QuickMeet"
cp Info.plist "$CONTENTS/Info.plist"
cp AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "▸ Signing as: $IDENTITY"
codesign --force --sign "$IDENTITY" --identifier com.quickmeet.QuickMeet "$APP"

# Install straight to /Applications and build nowhere else.
#
# TCC keys permissions on path *and* signature, so a second copy sitting in the build
# folder is a separate identity to macOS — it shows up as another "QuickMeet" in the
# Privacy lists, and granting the wrong one looks exactly like a permission that is
# enabled but not working.
echo "▸ Installing to /Applications…"
killall QuickMeet 2>/dev/null || true
rm -rf /Applications/QuickMeet.app
cp -R "$APP" /Applications/QuickMeet.app
rm -rf "$APP"

echo
echo "✓ Installed /Applications/QuickMeet.app"
codesign -dv /Applications/QuickMeet.app 2>&1 | grep -E "Identifier|TeamIdentifier" | sed 's/^/  /' || true
echo
echo "  Run it:  open /Applications/QuickMeet.app"
echo
echo "  If a permission reads as enabled but the app disagrees, reset and re-grant:"
echo "    tccutil reset Microphone com.quickmeet.QuickMeet"
echo "    tccutil reset ScreenCapture com.quickmeet.QuickMeet"
