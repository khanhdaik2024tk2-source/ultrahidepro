# Changelog

All notable changes to UltraHide Pro will be documented in this file.

## [1.0.0] - 2026-09-25

### Added
- Initial release targeting Dopamine 3.0.9 + iOS 18.6.2 (A8-A13).
- **Lớp 1 — File system hooks (10 vectors)**:
  - `NSFileManager::fileExistsAtPath:`, `fileExistsAtPath:isDirectory:`, `attributesOfItemAtPath:error:`
  - `fopen`, `open`, `stat`, `lstat`, `access`, `opendir`, `readdir`
- **Lớp 2 — Process & execution hooks (10 vectors)**:
  - `fork`, `vfork` → EPERM in target app
  - `execve`, `posix_spawn` → block jb binary exec
  - `sysctl` (filter KERN_PROC/KERN_PROCARGS), `sysctlbyname` (filter kern.jailbreak*)
  - `getppid` → spoof to 1, `kill` → block to jb PIDs
  - `ptrace` → return 0 for PT_DENY_ATTACH
  - `csops` → spoof csflags (clear CS_KILL | CS_HARD, set CS_VALID | CS_DEBUGGED)
- **Lớp 3 — dyld & runtime hooks (6 vectors)**:
  - `_dyld_image_count`, `_dyld_get_image_name`
  - `dlopen`, `dlsym`
  - `objc_copyClassList`, `objc_getClassList`
- **Lớp 4 — Environment & URL hooks (7 vectors)**:
  - `getenv`, `setenv`, `secure_getenv`
  - `__system_property_get` (mask `ro.boot.jailbreak`)
  - `UIApplication::canOpenURL:`
  - `LSApplicationWorkspace::applicationIsInstalled:`
  - `LSApplicationProxy::applicationIsInstalled:`
- **Lớp 5 — Sandbox & AMFI hooks (7 vectors)**:
  - `sandbox_check`, `SecCodeCopySigningInformation`, `SecCodeCheckValidity`
  - `SecTaskCopyValueForEntitlement`
  - `MISValidateSignature`, `MISValidateSignatureAndCopyInfo`
  - `xpc_connection_create`
- **Lớp 6 — Network & IOKit hooks (4 vectors)**:
  - `getifaddrs` (filter utun/ipsec)
  - `io_service_open_extended`
  - `MGCopyAnswer`, `MGCopyAnswerWithError`
- **Lớp 7 — Objective-C aggregate bypass**:
  - Lazy scan `objc_getClassList`
  - Regex match class names (JailbreakChecker, IOSSecurity, SecurityCheck, RootDetector, ...)
  - Hook all selectors matching blacklist (amIJailbroken, isJailbroken, amIDebugged, performChecks, verifyIntegrity, ...)
- **Lớp 8 — Kernel patches (5 patches)**:
  - AMFIIsCDHashInTrustCache → write `mov x0, #0; ret`
  - mac_policy_conf ops 201-316 → patch to allow stub
  - `_cred_label_update_execve` → NOP csflags kill path
  - `task_conversion_eval` → return 0
  - Per-process csflags mask (clear CS_KILL/CS_HARD, set CS_DEBUGGED)
- **Anti-anti-hook (3 vectors)**:
  - `mach_vm_region`, `vm_region_64`, `vm_region_recurse_64` → skip own regions
  - Bump `_dyld_image_count` down by 1
- **Runtime protection (2 vectors)**:
  - `vm_read`, `vm_read_overwrite` → replace BRK #1 with NOP in own pages
- **Dynamic rule loader**:
  - Parse `vectors.json`
  - 5-second watchdog polls for mtime changes
  - Hot reload without respring
- **Per-app config**:
  - `config.plist` with target_apps, layer toggles, blacklists
  - Loaded from `/var/jb/Library/UltraHidePro/config.plist`
- **Smoke tests**: 9 in-process sanity tests
- **CI**: GitHub Actions workflow (macOS-14 + Xcode 15)

### Notes
- Total: 75+ detection vectors covered.
- Designed to work alongside Choicy (which only handles tweak-injection
  filtering). UltraHide Pro does the actual detection bypass; Choicy can
  optionally be used to disable other tweaks on a per-app basis.
- Kernel patches require the `com.apple.private.security.no-sandbox`
  entitlement and the device running Dopamine 3.0.9. Disabled by default;
  enable in `config.plist` only after smoke-testing.
