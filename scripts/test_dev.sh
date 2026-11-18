#!/bin/bash
# test_dev.sh — run the unit test suite with the STABLE dev identity.
#
# The ad-hoc test host gets a new code fingerprint on every build, so macOS
# treats it as an ungranted app every time — any test that touches a
# permission-gated API (event taps, keyboard layout reads, …) re-triggers a
# "Device Control & Data Access" prompt on every run. Signing the test host
# with the same identity as the installed app (MeiMacPlus Dev) makes the
# grants stick, so prompts appear at most once, ever.
#
# CI keeps using the default ad-hoc signing (no local cert there).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="MeiMacPlus Dev"

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "NOTE: identity '$IDENTITY' not found — falling back to ad-hoc test host." >&2
  echo "      Permission prompts may appear; run scripts/make_dev_identity.sh to fix." >&2
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    xcodebuild -project "$ROOT/MeiMacPlus.xcodeproj" -scheme MeiMacPlus \
    -configuration Debug -derivedDataPath "$ROOT/build/DerivedData" test
  exit $?
fi

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project "$ROOT/MeiMacPlus.xcodeproj" -scheme MeiMacPlus \
  -configuration Debug -derivedDataPath "$ROOT/build/DerivedData" \
  test CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual
