#!/usr/bin/env bash
# scripts/ci_offline_check.sh — offline static checks for CI without
# requiring Theos / iOS SDK. Run this on any Ubuntu / macOS runner as
# a fast pre-flight before the expensive macos-14 build.
#
# Verifies:
#   * YAML workflows parse and have the expected jobs.
#   * JSON / plist files parse.
#   * Bash scripts have no syntax errors.
#   * Required source files exist.
#   * No obvious banned characters in Tweak.x (NULL bytes, etc.).
#
# Use python3 explicitly so the script works on ubuntu-22.04 / macos-14
# even if Windows-only 'python' is on PATH.

set -euo pipefail

cd "$(dirname "$0")/.."

ok()   { printf '  [OK] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; exit 1; }

# Pick python that has PyYAML available; on CI we just install it via
# pip or rely on the system package. The python file ships with the
# repo to make offline checks fully portable.
PYTHON_BIN="${PYTHON_BIN:-python3}"

echo "=== YAML workflows ==="
for w in .github/workflows/build.yml .github/workflows/lint.yml; do
    "$PYTHON_BIN" -c "import yaml,sys;d=yaml.safe_load(open('$w'));assert 'jobs' in d;print('$w jobs:', sorted(d['jobs'].keys()))" \
        || fail "$w invalid YAML (PyYAML missing? run: pip install pyyaml)"
    ok "$w"
done

echo "=== Plist / JSON files ==="
for p in entry.plist Resources/config.plist Resources/entitlements.plist; do
    "$PYTHON_BIN" -c "import plistlib;plistlib.load(open('$p','rb'));print('$p ok')" \
        || fail "$p invalid plist"
    ok "$p"
done
for j in Resources/vectors.json; do
    "$PYTHON_BIN" -c "import json;json.load(open('$j'));print('$j ok')" \
        || fail "$j invalid json"
    ok "$j"
done

echo "=== Bash scripts ==="
for s in scripts/test_app.sh scripts/sign.sh scripts/setup_github.sh scripts/ci_offline_check.sh; do
    [[ -f "$s" ]] || fail "$s missing"
    bash -n "$s" || fail "$s syntax error"
    ok "$s"
done

echo "=== Required source files ==="
required=(
    Tweak.x
    Makefile
    control
    entry.plist
    Sources/UHCommon.h
    Sources/UHCore/UHConfig.m
    Sources/UHCore/UHMachO.m
    Sources/UHCore/UHPAC.m
    Sources/UHCore/UHBrkGuard.m
    Sources/UHCore/UHHookStats.m
    Sources/UHCore/UHLog.m
    Sources/UHHooks/UHFileSystem.m
    Sources/UHHooks/UHProcess.m
    Sources/UHHooks/UHDyld.m
    Sources/UHHooks/UHEnvironment.m
    Sources/UHHooks/UHBridge.m
    Sources/UHHooks/UHAntiHook.m
    Sources/UHHooks/UHRuntimeProtection.m
    Sources/UHHooks/UHSandboxAMFI.m
    Sources/UHHooks/UHNetworkIOKit.m
    Sources/UHKernel/UHKcall.m
    Sources/UHRules/UHRuleLoader.m
    Sources/UHTests/UHSmokeTests.m
)
for f in "${required[@]}"; do
    [[ -f "$f" ]] || fail "missing required file $f"
    ok "$f"
done

echo "=== Sanity ==="
for f in Tweak.x Makefile; do
    if grep -l $'\x00' "$f" >/dev/null 2>&1; then
        fail "$f contains NULL bytes"
    fi
    ok "$f no NULL bytes"
done

# Check Makefile variables expected by the workflow.
for v in THEOS_PROJECT_DIR FINALPACKAGE; do
    grep -q "$v" Makefile || fail "Makefile missing $v reference"
    ok "Makefile uses $v"
done

echo
echo "ALL OFFLINE CHECKS PASSED"
