#!/bin/bash
# Build NextUp in release and assemble build/NextUp.app with an ad hoc signature.
# The version comes from one place: NextUpVersion in Sources/NextUpCore/Version.swift.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/NextUp.app"

cd "$ROOT"
VERSION=$(sed -n 's/^public let NextUpVersion = "\([^"]*\)"$/\1/p' Sources/NextUpCore/Version.swift)
if [[ -z "$VERSION" ]]; then
    echo "could not read NextUpVersion from Sources/NextUpCore/Version.swift" >&2
    exit 1
fi

swift build -c release --product NextUp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/NextUp" "$APP/Contents/MacOS/NextUp"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force -s - "$APP"
codesign --verify --strict "$APP"

echo "built $APP (version $VERSION)"
