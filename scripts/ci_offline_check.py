"""scripts/ci_offline_check.py — cross-platform offline static check
runner (Windows / Linux / macOS). Validates the same surface as the bash
version, so CI on ubuntu-22.04 can run a single Python command instead
of installing bash."""
from __future__ import annotations
import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

REQUIRED_FILES = [
    "Tweak.x", "Makefile", "control", "entry.plist",
    "Sources/UHCommon.h",
    "Sources/UHCore/UHConfig.m",
    "Sources/UHCore/UHMachO.m",
    "Sources/UHCore/UHPAC.m",
    "Sources/UHCore/UHBrkGuard.m",
    "Sources/UHCore/UHHookStats.m",
    "Sources/UHCore/UHLog.m",
    "Sources/UHHooks/UHFileSystem.m",
    "Sources/UHHooks/UHProcess.m",
    "Sources/UHHooks/UHDyld.m",
    "Sources/UHHooks/UHEnvironment.m",
    "Sources/UHHooks/UHBridge.m",
    "Sources/UHHooks/UHAntiHook.m",
    "Sources/UHHooks/UHRuntimeProtection.m",
    "Sources/UHHooks/UHSandboxAMFI.m",
    "Sources/UHHooks/UHNetworkIOKit.m",
    "Sources/UHKernel/UHKcall.m",
    "Sources/UHRules/UHRuleLoader.m",
    "Sources/UHTests/UHSmokeTests.m",
]

WORKFLOWS = [
    ".github/workflows/build.yml",
    ".github/workflows/lint.yml",
]

PLIST_FILES = [
    "entry.plist",
    "Resources/config.plist",
    "Resources/entitlements.plist",
    "app/Info.plist",
    "app/entitlements.plist",
]

JSON_FILES = [
    "Resources/vectors.json",
]

BASH_SCRIPTS = [
    "scripts/test_app.sh",
    "scripts/sign.sh",
    "scripts/setup_github.sh",
    "scripts/ci_offline_check.sh",
]

EXPECTED_JOBS = {
    ".github/workflows/build.yml": {"verify", "lint", "offline_check"},
    ".github/workflows/lint.yml": {"plist_json", "sources_count", "shellcheck"},
}

EXPECTED_RUNNER = {
    ".github/workflows/build.yml": "macos-14",
    ".github/workflows/lint.yml": "ubuntu-22.04",
}


def fail(msg: str) -> None:
    print(f"  [FAIL] {msg}")
    sys.exit(1)


def ok(msg: str) -> None:
    print(f"  [OK] {msg}")


def check_workflows() -> None:
    import yaml  # type: ignore
    print("=== YAML workflows ===")
    for path in WORKFLOWS:
        fp = ROOT / path
        if not fp.exists():
            fail(f"missing {path}")
        try:
            data = yaml.safe_load(fp.read_text(encoding="utf-8"))
        except Exception as e:  # noqa: BLE001
            fail(f"{path}: YAML parse error: {e}")
        if "jobs" not in data:
            fail(f"{path}: missing 'jobs'")
        jobs = set(data["jobs"].keys())
        missing = EXPECTED_JOBS[path] - jobs
        if missing:
            fail(f"{path}: missing jobs {missing}")
        runners = {data["jobs"][j].get("runs-on") for j in EXPECTED_JOBS[path]}
        if EXPECTED_RUNNER[path] not in runners:
            fail(f"{path}: missing runner {EXPECTED_RUNNER[path]}")
        ok(f"{path}: jobs={sorted(jobs)} runner OK")


def check_plist() -> None:
    print("=== Plist / JSON ===")
    for path in PLIST_FILES:
        fp = ROOT / path
        if not fp.exists():
            fail(f"missing {path}")
        try:
            with open(fp, "rb") as f:
                plistlib.load(f)
        except Exception as e:  # noqa: BLE001
            fail(f"{path}: plist error: {e}")
        ok(f"{path}")
    for path in JSON_FILES:
        fp = ROOT / path
        if not fp.exists():
            fail(f"missing {path}")
        try:
            json.loads(fp.read_text(encoding="utf-8"))
        except Exception as e:  # noqa: BLE001
            fail(f"{path}: json error: {e}")
        ok(f"{path}")


def check_required_sources() -> None:
    print("=== Required source files ===")
    for path in REQUIRED_FILES:
        fp = ROOT / path
        if not fp.exists():
            fail(f"missing {path}")
        ok(path)


def check_bash_scripts() -> None:
    print("=== Bash scripts (best-effort) ===")
    for path in BASH_SCRIPTS:
        fp = ROOT / path
        if not fp.exists():
            fail(f"missing {path}")
        try:
            subprocess.run(["bash", "-n", str(fp)], check=True, capture_output=True)
        except FileNotFoundError:
            ok(f"{path} (bash not installed; skipped syntax)")
            continue
        except subprocess.CalledProcessError as e:
            fail(f"{path}: {e.stderr.decode(errors='replace')}")
        ok(f"{path}")


def check_makefile() -> None:
    print("=== Makefile sanity ===")
    fp = ROOT / "Makefile"
    text = fp.read_text(encoding="utf-8")
    # Only THEOS_PROJECT_DIR and FINALPACKAGE are actually used. THEOS_PACKAGE_DIR
    # is a Theos default that does not need to be referenced explicitly.
    for v in ("THEOS_PROJECT_DIR", "FINALPACKAGE"):
        if v not in text:
            fail(f"Makefile missing reference to {v}")
        ok(f"Makefile has {v}")


def check_no_null_bytes() -> None:
    print("=== Null-byte scan ===")
    for path in ("Tweak.x", "Makefile", "control", "entry.plist"):
        fp = ROOT / path
        data = fp.read_bytes()
        if b"\x00" in data:
            fail(f"{path} contains NULL byte")
        ok(f"{path}")


def main() -> int:
    os.chdir(ROOT)
    check_workflows()
    check_plist()
    check_required_sources()
    check_bash_scripts()
    check_makefile()
    check_no_null_bytes()
    print()
    print("ALL OFFLINE CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
