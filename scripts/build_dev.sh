#!/bin/bash
# build_dev.sh — Release build + re-sign with a STABLE identity, then
# optionally relaunch (from DerivedData) or install into /Applications.
#
# Why the stable identity matters: TCC grants (accessibility / "Device
# Control & Data Access") are keyed to the code-signing identity. Ad-hoc
# builds get a new fingerprint on every build, so every run re-prompts.
# Signing with a fixed identity keeps grants stable across rebuilds.
#
# Usage:
#   build_dev.sh              # build + re-sign, print bundle path
#   build_dev.sh --relaunch   # ... then kill & relaunch from DerivedData
#   build_dev.sh --install    # ... then replace /Applications copy & launch
#   build_dev.sh --install --developer-id   # sign with Developer ID instead

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="MeiMacPlus Dev"
APP="$ROOT/build/DerivedData/Build/Products/Release/MeiMacPlus.app"
INSTALL_DIR="/Applications"
MODE="${1:-}"

for arg in "$@"; do
  case "$arg" in
    --install) MODE="--install" ;;
    --relaunch) MODE="--relaunch" ;;
    --developer-id) IDENTITY="Developer ID Application: Income Mei (8KV7MAV54M)" ;;
  esac
done

security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY" || {
  echo "ERROR: identity '$IDENTITY' not found" >&2
  exit 1
}

echo "==> build Release"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project "$ROOT/MeiMacPlus.xcodeproj" -scheme MeiMacPlus \
  -configuration Release -derivedDataPath "$ROOT/build/DerivedData" build >/dev/null

echo "==> re-sign with $IDENTITY"
# --entitlements matters twice over: without it the re-sign drops the app's
# designated requirement off the one TCC granted (privacy prompts reappear),
# and the vendored hs.* dylibs lose their library-validation exemption.
codesign --force --options runtime \
  --entitlements "$ROOT/MeiMacPlus/MeiMacPlus.entitlements" \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "signed: $APP"

case "$MODE" in
  --install)
    echo "==> installing into $INSTALL_DIR"
    pkill -x MeiMacPlus 2>/dev/null || true
    sleep 1
    # Remove-then-copy so no stale files (e.g. old vendored dylibs) survive.
    rm -rf "$INSTALL_DIR/MeiMacPlus.app"
    ditto "$APP" "$INSTALL_DIR/MeiMacPlus.app"
    open "$INSTALL_DIR/MeiMacPlus.app"
    echo "installed & launched: $INSTALL_DIR/MeiMacPlus.app"
    ;;
  --relaunch)
    pkill -x MeiMacPlus 2>/dev/null || true
    sleep 1
    open "$APP"
    echo "relaunched"
    ;;
  *)
    echo "bundle at: $APP"
    ;;
esac
