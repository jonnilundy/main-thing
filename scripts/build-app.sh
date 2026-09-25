#!/bin/bash
# Build MainThing in release and assemble build/MainThing.app with an ad hoc signature.
# The mainthing command goes into the bundle at Contents/Resources/mainthing.
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
# Sparkle: the framework from the SwiftPM artifact goes into Contents/Frameworks, with
# Autoupdate, Updater.app and the XPC services inside it. The executable finds it through
# @rpath, so add the standard rpath in case the linker only recorded the .build path.
SPARKLE="$(ls -d .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework | head -1)"
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$APP/Contents/MacOS/MainThing" | /usr/bin/grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/MainThing"
fi
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp Resources/*.wav "$APP/Contents/Resources/"
cp "bin/mainthing" "$APP/Contents/Resources/mainthing"
chmod 755 "$APP/Contents/Resources/mainthing"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad hoc sign inside out: Sparkle's helpers first, then the framework, then the app.
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force -s - "$FW/XPCServices/Installer.xpc"
codesign --force -s - "$FW/XPCServices/Downloader.xpc"
codesign --force -s - "$FW/Autoupdate"
codesign --force -s - "$FW/Updater.app"
codesign --force -s - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force -s - "$APP"
codesign --verify --strict "$APP"

echo "built $APP (version $VERSION)"
