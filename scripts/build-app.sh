#!/bin/bash
# Build MainThing in release and assemble build/MainThing.app with an ad hoc signature.
# The version comes from one place: MainThingVersion in Sources/MainThingCore/Version.swift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/MainThing.app"

cd "$ROOT"
VERSION=$(sed -n 's/^public let MainThingVersion = "\([^"]*\)"$/\1/p' Sources/MainThingCore/Version.swift)
if [[ -z "$VERSION" ]]; then
    echo "could not read MainThingVersion from Sources/MainThingCore/Version.swift" >&2
    exit 1
fi

swift build -c release --product MainThing

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/MainThing" "$APP/Contents/MacOS/MainThing"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force -s - "$APP"
codesign --verify --strict "$APP"

echo "built $APP (version $VERSION)"
