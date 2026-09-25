#!/bin/zsh
# Build assets/AppIcon.icns from assets/icon-1024.png (1024x1024, transparent corners).
set -e
A=$(cd "$(dirname "$0")/../assets" && pwd)
T=$(mktemp -d)
S="$T/AppIcon.iconset"
mkdir -p "$S"
for size in 16 32 128 256 512; do
  sips -z $size $size "$A/icon-1024.png" --out "$S/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$A/icon-1024.png" --out "$S/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$S" -o "$A/AppIcon.icns"
rm -rf "$T"
echo "built $A/AppIcon.icns"
