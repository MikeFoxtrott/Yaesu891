#!/bin/bash
# Baut "Mike Foxtrott.app" (Release) neben diesem Skript. Braucht Xcode oder die Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/FT891Control"
APP="Mike Foxtrott.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FT891Control"
cp Info.plist "$APP/Contents/Info.plist"
# App-Icon (Quelle: Icon/make_icon.py); ohne die Datei wird das Standard-Icon verwendet
[ -f Icon/AppIcon.icns ] && cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "Fertig: $PWD/$APP"
