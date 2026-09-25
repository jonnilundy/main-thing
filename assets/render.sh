#!/bin/zsh
# Rebuild the icon PNGs, AppIcon.icns and cover.png from icon.svg and cover.html.
# Needs a Chromium browser (Helium or Google Chrome) and the Command Line Tools (swiftc, iconutil).
set -e
A=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
for c in "/Applications/Helium.app/Contents/MacOS/Helium" "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"; do
  [ -x "$c" ] && CHROME=$c && break
done
[ -n "$CHROME" ] || { echo "no Chromium browser found"; exit 1; }

# Crop tool that keeps alpha. sips crop drops it.
cat > "$T/crop.swift" <<'SWIFT'
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
let a = CommandLine.arguments
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil)!
let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let w = Int(a[2])!, h = Int(a[3])!
let cropped = img.cropping(to: CGRect(x: 0, y: 0, width: w, height: h))!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[4]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, cropped, nil)
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
SWIFT
swiftc -O -o "$T/crop" "$T/crop.swift" 2>/dev/null

shot() { # shot <url> <w> <h> <out>
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --default-background-color=00000000 --window-size="$2,$3" --screenshot="$4" "$1" >/dev/null 2>&1 || true
}

# Chromium clamps small windows, so each icon size is drawn in a big window and cropped.
mkdir -p "$T/AppIcon.iconset"
for sz in 16 32 64 128 256 512 1024; do
  printf '<!doctype html><body style="margin:0;background:transparent"><img src="file://%s/icon.svg" style="display:block;width:%spx;height:%spx"></body>' "$A" "$sz" "$sz" > "$T/i$sz.html"
  shot "file://$T/i$sz.html" 1100 1100 "$T/full$sz.png"
  "$T/crop" "$T/full$sz.png" "$sz" "$sz" "$T/icon-$sz.png"
done
for pair in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
  cp "$T/icon-${pair%%:*}.png" "$T/AppIcon.iconset/${pair#*:}.png"
done
iconutil -c icns "$T/AppIcon.iconset" -o "$A/AppIcon.icns"
# The cover carries the icon inline as a data URI (between the ICON markers), refreshed from icon.svg.
ICON=$(base64 -i "$A/icon.svg" | tr -d '\n')
python3 - "$A/cover.html" "$ICON" <<'PY'
import re, sys
p, uri = sys.argv[1], "data:image/svg+xml;base64," + sys.argv[2]
s = open(p).read()
s = re.sub(r'(/\*ICON\*/)[^"]*(/\*/ICON\*/)', lambda m: m.group(1) + uri + m.group(2), s)
open(p, "w").write(s)
PY
shot "file://$A/cover.html" 1280 640 "$A/cover.png"
shot "file://$A/cover.html#ember" 1280 640 "$A/cover-alt-ember.png"
echo "wrote $A/AppIcon.icns and $A/cover.png"
rm -rf "$T"
