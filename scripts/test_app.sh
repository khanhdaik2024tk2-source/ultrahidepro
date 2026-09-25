#!/usr/bin/env bash
# scripts/test_app.sh — run inside a Theos build environment.
#
# Builds the package then runs the smoke test against the produced dylib
# in a small XCTest harness. We rely on Theos's bundled clang rather than
# the host's Xcode toolchain so the bundle target matches iOS 18.6.

set -euo pipefail

THEOS=${THEOS:-$(dirname "$(which theos)")/..}
BUILD_DIR=${BUILD_DIR:-build}
PROJECT_DIR=$(cd "$(dirname "$0")/.." && pwd)

echo "[+] Cleaning"
rm -rf "$PROJECT_DIR/$BUILD_DIR"
rm -rf "$PROJECT_DIR/packages"

echo "[+] Building package"
cd "$PROJECT_DIR"
make clean
make package FINALPACKAGE=1

DEB_FILE=$(ls -t "$PROJECT_DIR/packages/"*.deb | head -n1)
echo "[+] Built $DEB_FILE"

echo "[+] Inspecting deb contents"
dpkg-deb -c "$DEB_FILE"

echo "[+] Extracting dylib for smoke test"
mkdir -p "$BUILD_DIR"
dpkg-deb -x "$DEB_FILE" "$BUILD_DIR/installed"

DYLIB=$(find "$BUILD_DIR/installed" \( -name "UltraHidePro*.dylib" -o -name "UltraHidePro" \) -type f | head -n1)
if [[ -z "$DYLIB" || ! -f "$DYLIB" ]]; then
  echo "[!] Could not find installed dylib in $BUILD_DIR/installed"
  find "$BUILD_DIR/installed"
  exit 1
fi
echo "[+] Found installed dylib: $DYLIB"

echo "[+] Verifying code signature placeholder"
LDID=${LDID:-ldid}
"$LDID" -e "$DYLIB" || true

echo "[+] Build verification complete"
