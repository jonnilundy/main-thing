#!/bin/bash
# Build NextUp in release and assemble build/NextUp.app with an ad hoc signature.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/NextUp.app"

cd "$ROOT"
swift build -c release --product NextUp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/NextUp" "$APP/Contents/MacOS/NextUp"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force -s - "$APP"
codesign --verify --strict "$APP"

echo "built $APP"
