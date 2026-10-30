#!/bin/bash
# make_dmg.sh — build the MeiQuitManage disk image.
#
# Produces dist/MeiQuitManage-<version>.dmg with a styled background,
# an /Applications symlink, and fixed icon positions (Finder view options).
# Falls back to a plain compressed image if Finder automation is denied.
#
# Usage: make_dmg.sh [path-to-MeiQuitManage.app]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$ROOT/build/DerivedData/Build/Products/Release/MeiQuitManage.app}"
DIST="$ROOT/dist"
STAGING="$ROOT/build/dmg-staging"
RW_DMG="$ROOT/build/MeiQuitManage-rw.dmg"

[ -d "$APP_PATH" ] || { echo "app not found: $APP_PATH (build it first)" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
VOLNAME="MeiQuitManage"
FINAL_DMG="$DIST/MeiQuitManage-$VERSION.dmg"

mkdir -p "$DIST" "$STAGING"
rm -rf "$STAGING/$VOLNAME"
mkdir -p "$STAGING/$VOLNAME/.background"

# Background art (regenerate if missing).
if [ ! -f "$STAGING/$VOLNAME/.background/background.png" ]; then
  swift "$ROOT/scripts/make_dmg_background.swift" \
    "$STAGING/$VOLNAME/.background/background.png" \
    "$ROOT/build/appicon_1024.png"
fi

cp -R "$APP_PATH" "$STAGING/$VOLNAME/"
ln -sfh /Applications "$STAGING/$VOLNAME/Applications"

rm -f "$RW_DMG" "$FINAL_DMG"

# Read-write image so Finder can record view options.
hdiutil create -volname "$VOLNAME" \
  -srcfolder "$STAGING/$VOLNAME" \
  -ov -fs HFS+ -format UDRW "$RW_DMG" >/dev/null

DEV_NODE=$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" | grep '^/dev/' | tail -1 | awk '{print $1}')
[ -n "$DEV_NODE" ] || { echo "failed to attach $RW_DMG" >&2; exit 1; }
cleanup() { hdiutil detach "$DEV_NODE" -force >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Try to style the window via Finder. If Automation permission is denied,
# we keep the plain layout and still produce a valid image.
osascript <<APPLESCRIPT || echo "warn: Finder styling skipped (automation denied); producing plain DMG" >&2
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {120, 120, 840, 520}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 110
    set background picture of theViewOptions to file ".background:background.png"
    set position of item "MeiQuitManage.app" of container window to {300, 310}
    set position of item "Applications" of container window to {620, 310}
    close
    open
    update without registering applications
    delay 2
  end tell
end tell
APPLESCRIPT

hdiutil detach "$DEV_NODE" >/dev/null
trap - EXIT

hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL_DMG" >/dev/null
rm -f "$RW_DMG"

echo "wrote $FINAL_DMG ($(du -h "$FINAL_DMG" | awk '{print $1}'))"
