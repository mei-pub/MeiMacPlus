#!/bin/bash
# fetch_hs_runtime.sh — vendor the Hammerspoon Lua runtime into build/hs-vendor.
#
# Downloads the pinned official Hammerspoon release (MIT), verifies its
# sha256, and extracts the pieces MeiMacPlus embeds:
#
#   build/hs-vendor/
#   ├── LuaSkin.framework              (Lua 5.4.7 + ObjC bridge)
#   ├── hs/lib*.dylib                  (ALL hs.* native modules)
#   ├── extensions/hs/**               (pure-Lua modules + hsdocs + docs.json)
#   ├── setup.lua                      (bootstrap; paths are parameterized)
#   ├── third-party/<lib>/             (sources compiled into MeiHSRuntime.dylib)
#   └── VENDOR_INFO.txt
#
# The Hammerspoon main binary, Sparkle.framework, and the external `hs`
# IPC CLI are intentionally NOT vendored — they belong to the upstream app.
#
# The hs dylibs that bind networking/hardware symbols (socket, socket.udp,
# websocket, httpserver, midi, serial) need the same third-party libraries
# upstream links into the Hammerspoon binary; versions are pinned to match
# upstream 1.1.1's Podfile.lock. Their sources are fetched here and compiled
# into MeiHSRuntime.dylib by the build's "Vendor HS Runtime" phase, which
# also compiles vendored HSuicore.h/.m (host AX classes) and HSMJStubs.m.
#
# Upgrading: bump HS_VERSION + HS_SHA256 below (and the third-party pins if
# upstream's Podfile.lock changed), delete build/hs-vendor, re-run. See
# docs/DISTRIBUTION.md → "Hammerspoon runtime vendoring".

set -euo pipefail

HS_VERSION="1.1.1"
# sha256 of the release zip, pinned on first download (trust-on-first-use:
# the pin protects against later upstream asset drift, not the initial fetch).
HS_SHA256="11bb1c90faf5427f37c7bd4fe7eab9774ae43e1d5cb020c5b3088dac32849efa"
HS_URL="https://github.com/Hammerspoon/hammerspoon/releases/download/${HS_VERSION}/Hammerspoon-${HS_VERSION}.zip"

# Third-party libraries upstream links into the app binary (Podfile.lock
# versions), needed by the hs.* dylibs listed above. sha256 = release
# tarball; CocoaHTTPServer is Hammerspoon's fork, pinned to a commit.
THIRD_PARTY=(
  "CocoaAsyncSocket|7.6.5|https://github.com/robbiehanson/CocoaAsyncSocket/archive/refs/tags/7.6.5.tar.gz|8ca96d4715ba7a44c3faefee19124144b3adb48e59dad8c716bd6a3ffedd2ba6"
  "SocketRocket|0.7.1|https://github.com/facebookincubator/SocketRocket/archive/refs/tags/0.7.1.tar.gz|494603046265c4b38bf0a9bb44c26d4f3088a0eec1c1f890c9c08fdb1d0f39e5"
  "CocoaLumberjack|3.8.5|https://github.com/CocoaLumberjack/CocoaLumberjack/archive/refs/tags/3.8.5.tar.gz|c916ae93624b6d65a6c8732ff3ee8677abd26cabd52488cb31deab8e1fc396a9"
  "MIKMIDI|1.7.1|https://github.com/mixedinkey-opensource/MIKMIDI/archive/refs/tags/1.7.1.tar.gz|52b1fafef2c5a0c79026f884fd3bde59dc69c9b6d77aa37d5c33e670bc311bba"
  "ORSSerialPort|2.1.0|https://github.com/armadsen/ORSSerialPort/archive/refs/tags/2.1.0.tar.gz|87b23b2ff44e62e30ce2033ee60e2853ee06f55f2a6ecd424085e65c85feca32"
  "CocoaHTTPServer|aa05e484e2f5c8b6454590ed06a97b2bf636a1ca|https://github.com/Hammerspoon/CocoaHTTPServer/archive/aa05e484e2f5c8b6454590ed06a97b2bf636a1ca.tar.gz|8513671cd6c0f926cd848907302d125ff24c62b46624bd2c1d2e6b33c9d16c0b"
  "ASCIImage|6a3269f09faef3ecdf088b7665eaf4fd2126f2c1|https://github.com/cparnot/ASCIImage/archive/6a3269f09faef3ecdf088b7665eaf4fd2126f2c1.tar.gz|30162681f1e71458fd2e6a70fed15bce630ca6ac004cef8b14f2c6703fbe36a0"
)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/build/hs-download"
VENDOR="$ROOT/build/hs-vendor"
TP_DIR="$VENDOR/third-party"
ZIP="$CACHE/Hammerspoon-${HS_VERSION}.zip"

mkdir -p "$CACHE"

# --- download (cached) ---
if [ -f "$ZIP" ] && echo "$HS_SHA256  $ZIP" | shasum -a 256 -c - >/dev/null 2>&1; then
  echo "cached: $ZIP (sha256 ok)"
else
  echo "downloading $HS_URL"
  curl -fL --retry 3 -o "$ZIP" "$HS_URL"
  ACTUAL="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
  [ "$ACTUAL" = "$HS_SHA256" ] || { echo "sha256 mismatch: expected $HS_SHA256, got $ACTUAL" >&2; exit 1; }
fi

# --- extract ---
rm -rf "$VENDOR"
mkdir -p "$VENDOR" "$TP_DIR"
APP="$CACHE/extracted-${HS_VERSION}/Hammerspoon.app"
rm -rf "$CACHE/extracted-${HS_VERSION}"
unzip -q "$ZIP" -d "$CACHE/extracted-${HS_VERSION}"

[ -d "$APP" ] || { echo "zip layout unexpected: no Hammerspoon.app" >&2; exit 1; }

ditto "$APP/Contents/Frameworks/LuaSkin.framework" "$VENDOR/LuaSkin.framework"
mkdir -p "$VENDOR/hs"
for dylib in "$APP/Contents/Frameworks/hs"/lib*.dylib; do
  cp "$dylib" "$VENDOR/hs/"
done
ditto "$APP/Contents/Resources/extensions" "$VENDOR/extensions"
cp "$APP/Contents/Resources/setup.lua" "$VENDOR/setup.lua"
cp "$APP/Contents/Resources/docs.json" "$APP/Contents/Resources/lua.json" "$VENDOR/"
# hs.chooser's native module instantiates its window from this nib.
cp -R "$APP/Contents/Resources/HSChooserWindow.nib" "$VENDOR/HSChooserWindow.nib"
# timeout3: CGI wrapper used by hs.httpserver.hsminweb
cp "$APP/Contents/Resources/timeout3" "$VENDOR/timeout3"
# man page + CLI binary for hs.ipc.cliInstall (Frameworks/hs/hs)
mkdir -p "$VENDOR/man" "$VENDOR/hs-cli"
cp "$APP/Contents/Resources/man/hs.man" "$VENDOR/man/hs.man"
cp "$APP/Contents/Frameworks/hs/hs" "$VENDOR/hs-cli/hs"

# --- third-party sources (pinned + verified) ---
for entry in "${THIRD_PARTY[@]}"; do
  IFS='|' read -r name version url sha <<< "$entry"
  tarball="$CACHE/${name}-${version}.tar.gz"
  if [ -f "$tarball" ] && echo "$sha  $tarball" | shasum -a 256 -c - >/dev/null 2>&1; then
    echo "cached: $name $version (sha256 ok)"
  else
    echo "downloading $name $version"
    curl -fL --retry 3 -o "$tarball" "$url"
    ACTUAL="$(shasum -a 256 "$tarball" | awk '{print $1}')"
    [ "$ACTUAL" = "$sha" ] || { echo "sha256 mismatch for $name: expected $sha, got $ACTUAL" >&2; exit 1; }
  fi
  mkdir -p "$TP_DIR/$name"
  tar -xzf "$tarball" -C "$TP_DIR/$name" --strip-components=1
done
# ASCIImage commit tarballs need no special handling (strip-components above).

# --- patch: CocoaHTTPServer fork's HTTPLogging.h assumes the legacy
# CocoaLumberjack 2.x headers (LOG_OBJC_MAYBE & friends) were imported
# before it. Include the fork's own vendored legacy DDLog.h explicitly —
# the DDLog/DDOSLogger class symbols at link time still come from the
# pinned CocoaLumberjack 3.8.5 build.
HTTP_LOGGING="$TP_DIR/CocoaHTTPServer/Core/HTTPLogging.h"
if ! grep -q '#import "DDLog.h"' "$HTTP_LOGGING"; then
  sed -i '' '1i\
#import "DDLog.h"
' "$HTTP_LOGGING"
fi
grep -q '#import "DDLog.h"' "$HTTP_LOGGING" || { echo "HTTPLogging.h patch failed" >&2; exit 1; }

# --- patch: drop the "No config file found" system notification entirely.
# The host UI (settings pane shows the active scripts folder; console log
# below) already communicates the state, and a posted notification lingers
# in Notification Center long after the condition is fixed.
CORESETUP="$VENDOR/extensions/hs/_coresetup.lua"
if ! grep -q "MeiMacPlus-patched" "$CORESETUP"; then
  sed -i '' '/local notify = require("hs.notify")/d; /notify.register("__noinitfile"/d; /notify.show("Hammerspoon", "No config file found/d; /hs._notify("No config file found/d' "$CORESETUP"
  printf '' >> "$CORESETUP"
fi
grep -q "MeiMacPlus-patched" "$CORESETUP" || sed -i '' 's|  if not hasinitfile then|  if not hasinitfile then -- MeiMacPlus-patched (notification removed)|' "$CORESETUP"
grep -q "MeiMacPlus-patched" "$CORESETUP" || { echo "_coresetup notify patch failed" >&2; exit 1; }
grep -q 'hs._notify("No config file found' "$CORESETUP" && { echo "notification removal failed" >&2; exit 1; } || true

# --- sanity: fail fast if upstream layout ever changes ---
DYLIB_COUNT="$(find "$VENDOR/hs" -name '*.dylib' | wc -l | tr -d ' ')"
[ -f "$VENDOR/LuaSkin.framework/Versions/A/LuaSkin" ] || { echo "LuaSkin binary missing" >&2; exit 1; }
[ "$DYLIB_COUNT" -ge 86 ] || { echo "expected >=86 hs dylibs, got $DYLIB_COUNT" >&2; exit 1; }
[ -f "$VENDOR/setup.lua" ] || { echo "setup.lua missing" >&2; exit 1; }
[ -f "$VENDOR/extensions/hs/_coresetup.lua" ] || { echo "_coresetup.lua missing" >&2; exit 1; }
[ -f "$VENDOR/docs.json" ] || { echo "docs.json missing" >&2; exit 1; }
[ -f "$VENDOR/HSChooserWindow.nib" ] || { echo "HSChooserWindow.nib missing" >&2; exit 1; }
[ -f "$VENDOR/timeout3" ] || { echo "timeout3 missing" >&2; exit 1; }
[ -f "$VENDOR/man/hs.man" ] || { echo "hs.man missing" >&2; exit 1; }
[ -f "$VENDOR/hs-cli/hs" ] || { echo "hs CLI missing" >&2; exit 1; }
for must in libsocket libwebsocket libhttpserver libmidi libserial; do
  [ -f "$VENDOR/hs/$must.dylib" ] || { echo "expected dylib missing: $must" >&2; exit 1; }
done
[ -f "$TP_DIR/CocoaAsyncSocket/Source/GCD/GCDAsyncSocket.m" ] || { echo "CocoaAsyncSocket sources missing" >&2; exit 1; }
[ -f "$TP_DIR/CocoaHTTPServer/Core/HTTPServer.m" ] || { echo "CocoaHTTPServer sources missing" >&2; exit 1; }
[ -f "$TP_DIR/CocoaLumberjack/Sources/CocoaLumberjack/DDLog.m" ] || { echo "CocoaLumberjack sources missing" >&2; exit 1; }
[ -f "$TP_DIR/MIKMIDI/Source/MIKMIDIDeviceManager.m" ] || { echo "MIKMIDI sources missing" >&2; exit 1; }
[ -f "$TP_DIR/ORSSerialPort/Source/ORSSerialPort.m" ] || { echo "ORSSerialPort sources missing" >&2; exit 1; }
[ -f "$TP_DIR/SocketRocket/SocketRocket/SRWebSocket.m" ] || { echo "SocketRocket sources missing" >&2; exit 1; }
[ -f "$TP_DIR/ASCIImage/Core/PARImage+ASCIIInput.m" ] || { echo "ASCIImage sources missing" >&2; exit 1; }

# --- HSuicore: app-layer AX wrapper classes (HSapplication/HSuielement/HSwindow)
# that libwindow/libapplication/libuielement resolve against the host binary.
# Vendored as compiled source into the app target.
VENDOR_SRC="$ROOT/MeiMacPlus/Source/Scripting/Vendor"
mkdir -p "$VENDOR_SRC"
for f in HSuicore.h HSuicore.m; do
  curl -fsSL --retry 3 -o "$VENDOR_SRC/$f" \
    "https://raw.githubusercontent.com/Hammerspoon/hammerspoon/${HS_VERSION}/Hammerspoon/$f" \
    || { echo "failed to fetch HSuicore/$f" >&2; exit 1; }
done
grep -q "@interface HSapplication" "$VENDOR_SRC/HSuicore.h" || { echo "HSuicore.h content unexpected" >&2; exit 1; }
grep -q "@implementation HSapplication" "$VENDOR_SRC/HSuicore.m" || { echo "HSuicore.m content unexpected" >&2; exit 1; }

cat > "$VENDOR/VENDOR_INFO.txt" <<EOF
Hammerspoon runtime vendored for MeiMacPlus
version:    $HS_VERSION
sha256:     $HS_SHA256
source:     $HS_URL
extracted:  $(date -u +%Y-%m-%dT%H:%M:%SZ)
contents:   LuaSkin.framework, $DYLIB_COUNT hs dylibs, extensions/, setup.lua,
            third-party sources: ${THIRD_PARTY[@]%%|*}
license:    MIT/BSD (Hammerspoon, Lua 5.4.7, third-party); see THIRD_PARTY_LICENSES.md
EOF

echo "vendored $DYLIB_COUNT dylibs + third-party sources -> $VENDOR ($(du -sh "$VENDOR" | awk '{print $1}'))"
