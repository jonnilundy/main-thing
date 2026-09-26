#!/bin/bash
# Build MainThing in release and assemble build/MainThing.app with an ad hoc signature.
# The mainthing command goes into the bundle at Contents/Resources/mainthing.
# The version and the build number come from one place, Sources/MainThingCore/Version.swift:
# MainThingVersion becomes CFBundleShortVersionString, MainThingBuild becomes CFBundleVersion.
#
# Test builds only (never for a release): these override the bundle without touching the source.
#   MAINTHING_APP_OUT      where the app goes, instead of build/MainThing.app
#   MAINTHING_BUNDLE_ID    a test bundle id; the app then keeps its own list and config
#   MAINTHING_VERSION      CFBundleShortVersionString, for example 0.2.0-test
#   MAINTHING_BUILD        CFBundleVersion, an integer
#   MAINTHING_FEED_URL     SUFeedURL, for example a localhost appcast
#   MAINTHING_PUBLIC_KEY   SUPublicEDKey, a throwaway test key
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${MAINTHING_APP_OUT:-$ROOT/build/MainThing.app}"

cd "$ROOT"
VERSION=$(sed -n 's/^public let MainThingVersion = "\([^"]*\)"$/\1/p' Sources/MainThingCore/Version.swift)
BUILD=$(sed -n 's/^public let MainThingBuild = \([0-9][0-9]*\)$/\1/p' Sources/MainThingCore/Version.swift)
if [[ -z "$VERSION" || -z "$BUILD" ]]; then
    echo "could not read MainThingVersion and MainThingBuild from Sources/MainThingCore/Version.swift" >&2
    exit 1
fi
VERSION="${MAINTHING_VERSION:-$VERSION}"
BUILD="${MAINTHING_BUILD:-$BUILD}"

swift build -c release --product MainThing

rm -rf "${APP:?}"
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
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
[[ -n "${MAINTHING_BUNDLE_ID:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $MAINTHING_BUNDLE_ID" "$PLIST"
[[ -n "${MAINTHING_FEED_URL:-}" ]] && /usr/libexec/PlistBuddy -c "Set :SUFeedURL $MAINTHING_FEED_URL" "$PLIST"
[[ -n "${MAINTHING_PUBLIC_KEY:-}" ]] && /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $MAINTHING_PUBLIC_KEY" "$PLIST"
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

echo "built $APP (version $VERSION, build $BUILD, $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST"))"
