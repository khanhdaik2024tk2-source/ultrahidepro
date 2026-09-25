#!/usr/bin/env bash
# scripts/sign.sh — sign the built .deb with ldid using entitlements.
#
# Usage:
#   bash scripts/sign.sh packages/com.ultrahidepro.tweak_1.0.0_iphoneos-arm64.deb

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <path-to-deb>" >&2
  exit 1
fi

DEB=$1
LDID=${LDID:-ldid}
ENT=${ENT:-Resources/entitlements.plist}

if [[ ! -f "$DEB" ]]; then
  echo "[!] $DEB not found" >&2
  exit 1
fi

if ! command -v "$LDID" >/dev/null; then
  echo "[!] ldid not in PATH" >&2
  exit 1
fi

WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT
echo "[+] Extracting $DEB"
dpkg-deb -x "$DEB" "$WORK/install"
dpkg-deb -e "$DEB" "$WORK/control"

echo "[+] Locating dylib"
DYLIB=$(find "$WORK/install" -name "UltraHidePro*" -type f | head -n1)
if [[ -z "$DYLIB" ]]; then
  echo "[!] Could not find UltraHidePro dylib" >&2
  exit 1
fi
echo "[+] Found $DYLIB"

echo "[+] Re-signing dylib"
"$LDID" -S"$ENT" "$DYLIB"

echo "[+] Rebuilding deb"
mkdir -p "$(dirname "$DEB")"
dpkg-deb -b "$WORK/install" "$DEB"

echo "[+] Done. Signed: $DEB"
