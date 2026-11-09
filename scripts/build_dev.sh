#!/bin/bash
# build_dev.sh — Release build + re-sign with the stable dev identity
# ("MeiMacPlus Dev", see make_dev_identity.sh), then optionally relaunch.
#
# Usage: build_dev.sh [--relaunch]

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="MeiMacPlus Dev"
APP="$ROOT/build/DerivedData/Build/Products/Release/MeiMacPlus.app"

security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY" || {
  echo "ERROR: identity '$IDENTITY' not found — run scripts/make_dev_identity.sh first" >&2
  exit 1
}

echo "==> build Release"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project "$ROOT/MeiMacPlus.xcodeproj" -scheme MeiMacPlus \
  -configuration Release -derivedDataPath "$ROOT/build/DerivedData" build >/dev/null

echo "==> re-sign with $IDENTITY"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "signed: $APP"

if [ "${1:-}" = "--relaunch" ]; then
  pkill -x MeiMacPlus 2>/dev/null || true
  sleep 1
  open "$APP"
  echo "relaunched"
fi
