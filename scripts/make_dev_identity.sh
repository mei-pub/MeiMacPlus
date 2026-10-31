#!/bin/bash
# make_dev_identity.sh — create a stable self-signed code-signing identity
# for local development builds ("MeiQuitManage Dev").
#
# Why: ad-hoc signatures change on every rebuild, so macOS TCC keeps
# forgetting the Accessibility grant. Signing dev builds with this fixed
# identity keeps the grant stable across rebuilds.
#
# One-time setup; safe to re-run (idempotent). No App Store impact —
# release builds use your Developer ID certificate instead.

set -euo pipefail

NAME="MeiQuitManage Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "identity already valid: $NAME"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/dev.key" -out "$TMP/dev.cer" -days 3650 \
    -subj "/CN=$NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=codeSigning" \
    -addext "basicConstraints=critical,CA:FALSE" >/dev/null 2>&1

  security import "$TMP/dev.key" -k "$KEYCHAIN" -T /usr/bin/codesign
  security import "$TMP/dev.cer" -k "$KEYCHAIN"
else
  security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$TMP/dev.cer"
fi

# Mark the self-signed cert as trusted for code signing so the identity is
# usable by codesign. (May prompt for the login keychain password once.)
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/dev.cer"

echo "identity ready:"
security find-identity -v -p codesigning | grep "$NAME"
