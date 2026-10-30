#!/bin/bash
# sign_and_notarize.sh — Developer ID 签名 + 公证 + 打 DMG（正式分发用）
#
# 前置条件：
#   1. 钥匙串里有 "Developer ID Application" 证书
#   2. 已用 `xcrun notarytool store-credentials <profile> ...` 存好公证凭据
#
# 环境变量：
#   SIGN_IDENTITY  证书名，默认自动探测第一个 Developer ID Application
#   SIGN_TEAM      Team ID（用于 --apple-team-id 公证参数）
#   NOTARY_PROFILE notarytool keychain profile 名，默认 "notary-meiquit"

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/DerivedData"
APP="$DERIVED/Build/Products/Release/MeiQuitManage.app"

SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
[ -n "${SIGN_IDENTITY:-}" ] || { echo "ERROR: no Developer ID Application identity found" >&2; exit 1; }
NOTARY_PROFILE="${NOTARY_PROFILE:-notary-meiquit}"

echo "==> identity: $SIGN_IDENTITY"

echo "==> building Release"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project "$ROOT/MeiQuitManage.xcodeproj" -scheme MeiQuitManage \
  -configuration Release -derivedDataPath "$DERIVED" build \
  >/dev/null

echo "==> codesign"
codesign --force --deep --options runtime --timestamp \
  --sign "$SIGN_IDENTITY" "$APP"

echo "==> verify"
codesign --verify --strict --verbose=2 "$APP"
spctl -a -t exec --verbose=4 "$APP" || true  # Gatekeeper 评估（公证前可能 rejected，正常）

echo "==> notarize app bundle (then staple)"
ditto -c -k --keepParent "$APP" "$ROOT/build/MeiQuitManage-for-notary.zip"
xcrun notarytool submit "$ROOT/MeiQuitManage-for-notary.zip" \
  --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ROOT/build/MeiQuitManage-for-notary.zip"

echo "==> build DMG"
"$ROOT/scripts/make_dmg.sh" "$APP"

DMG="$(ls -t "$ROOT"/dist/MeiQuitManage-*.dmg | head -1)"
echo "==> codesign + notarize DMG"
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> done: $DMG"
spctl -a -t open --context context:primary-signature -v "$DMG" || true
