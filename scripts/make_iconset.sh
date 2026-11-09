#!/bin/bash
# make_iconset.sh — from the master 1024px icon PNG, produce:
#   1. Full macOS appiconset (all slots) for the asset catalog
#   2. A standalone MeiMacPlus.icns via iconutil
# Usage: make_iconset.sh <master_1024.png>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MASTER="${1:-$ROOT/build/appicon_1024.png}"
ICONSET_DIR="$ROOT/build/AppIcon.iconset"
APPICONSET_DIR="$ROOT/MeiMacPlus/Resources/Assets.xcassets/AppIcon.appiconset"
ICNS_OUT="$ROOT/build/MeiMacPlus.icns"

[ -f "$MASTER" ] || { echo "master icon not found: $MASTER" >&2; exit 1; }

mkdir -p "$ICONSET_DIR" "$APPICONSET_DIR"

# iconset (for iconutil): size[@scale] → pixel size
slot() { # <filename> <pixels>
  sips -z "$2" "$2" "$MASTER" --out "$ICONSET_DIR/$1" >/dev/null
}
slot icon_16x16.png      16
slot icon_16x16@2x.png   32
slot icon_32x32.png      32
slot icon_32x32@2x.png   64
slot icon_128x128.png    128
slot icon_128x128@2x.png 256
slot icon_256x256.png    256
slot icon_256x256@2x.png 512
slot icon_512x512.png    512
slot icon_512x512@2x.png 1024

# appiconset: reference the iconset copies from the asset catalog
rm -f "$APPICONSET_DIR"/*.png
cp "$ICONSET_DIR"/*.png "$APPICONSET_DIR/"

cat > "$APPICONSET_DIR/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png",      "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png",      "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png",    "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",    "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",    "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

iconutil -c icns -o "$ICNS_OUT" "$ICONSET_DIR"
echo "wrote $ICNS_OUT"
echo "appiconset updated: $APPICONSET_DIR"
