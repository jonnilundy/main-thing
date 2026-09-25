#!/bin/bash
# Build the release app and wrap it in build/MainThing.dmg: the app plus an Applications link,
# so a drag installs it. The app is ad hoc signed, so the first launch needs right click, Open.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/MainThing.app"
DMG="$ROOT/build/MainThing.dmg"
STAGE="$ROOT/build/dmg"

"$ROOT/scripts/build-app.sh"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/MainThing.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -quiet -volname "Main Thing $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

hdiutil verify -quiet "$DMG"
echo "packaged $DMG (version $VERSION, $(du -h "$DMG" | cut -f1 | tr -d ' '))"
