# UltraHide Pro

[![Build](https://github.com/OWNER/ultrahidepro/actions/workflows/build.yml/badge.svg)](https://github.com/OWNER/ultrahidepro/actions/workflows/build.yml)
[![Lint](https://github.com/OWNER/ultrahidepro/actions/workflows/lint.yml/badge.svg)](https://github.com/OWNER/ultrahidepro/actions/workflows/lint.yml)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Audit](https://img.shields.io/badge/iOS-18.6.2-blueviolet)](AUDIT_REPORT.md)

Tweak dylib rootless (THEOS_PACKAGE_SCHEME=rootless) target **Dopamine 3.0.9** + **iOS 18.6.2** (A8–A13, arm64).

UltraHide Pro là một **detection-bypass engine thực sự**, không phải tweak-injection controller. Nó hook trực tiếp **75+ vector detection** ở user-mode + kernel-mode thông qua ElleKit + libjailbreak primitives. Phủ sóng toàn bộ filesystem/dyld/objc/sandbox/AMFI/process/mach/syscall/crypto/IOKit/MobileGestalt vectors mà các tweak như **Choicy** hoàn toàn không xử lý.

## Tại sao UltraHide Pro vượt trội hơn Choicy

| Capability | Choicy | UltraHide Pro |
|---|---|---|
| Per-app tweak disable | Có (dlopen filter) | Có (tương đương) |
| Hide jailbreak files (stat/access) | Không | Có (10 hook ở Lớp 1) |
| Hide jailbreak processes (sysctl) | Không | Có (sysctl KERN_PROC filter) |
| Hide dyld injection | Không | Có (8 hook ở Lớp 3) |
| Hide env vars (DYLD_*) | Không | Có (getenv + setenv + secure_getenv) |
| Bypass sandbox/AMFI user-mode | Không | Có (10 hook ở Lớp 5) |
| Hide network interfaces (utun*) | Không | Có (getifaddrs) |
| Aggregate bypass (IOSSecurity/Checker) | Không | Có (regex hook, Lớp 7) |
| Kernel patches qua kcall | Không | Có (5 patches ở Lớp 8) |
| Anti-anti-hook (ẩn tweak khỏi detect) | Không | Có (4 vector) |
| Runtime protection (BRK/PAC spoof) | Không | Có |
| MobileGestalt hook | Không | Có |
| Dynamic rule loader | Không | Có (vectors.json + kqueue watchdog) |
| Per-app custom config | Có (plist) | Có (plist + JSON + hot-reload) |

## Cấu trúc project

```
UltraHidePro/
├── Makefile                          # Theos rootless build
├── control                           # Sileo/Zebra metadata
├── Tweak.x                           # Entry point (constructor)
├── entry.plist                       # Filter plist
├── Resources/
│   ├── config.plist                  # Per-app config + layer toggles
│   └── vectors.json                  # Dynamic vector map
├── Sources/
│   ├── UHCommon.h                    # Visibility macros, shared includes
│   ├── UHCore/
│   │   ├── UHConfig.{h,m}            # Singleton config loader
│   │   ├── UHLog.{h,m}               # os_log wrapper (subsystem com.ultrahidepro.tweak)
│   │   ├── UHHookStats.{h,m}         # Counter cho active hooks
│   │   ├── UHMachO.{h,m}             # Mach-O inspection helpers + __TEXT range
│   │   ├── UHPAC.{h,m}               # PAC strip/sign wrappers
│   │   └── UHBrkGuard.{h,m}          # SIGTRAP/SIGBUS safety net
│   ├── UHHooks/
│   │   ├── UHFileSystem.{h,m}        # Lớp 1 (10 hook + NSBundle)
│   │   ├── UHProcess.{h,m}           # Lớp 2 (10 hook)
│   │   ├── UHDyld.{h,m}              # Lớp 3 (6 hook + dlsym spoof)
│   │   ├── UHEnvironment.{h,m}       # Lớp 4 (6 hook)
│   │   ├── UHSandboxAMFI.{h,m}       # Lớp 5 (7 hook)
│   │   ├── UHNetworkIOKit.{h,m}      # Lớp 6 (3 hook)
│   │   ├── UHBridge.{h,m}            # Lớp 7 (aggregate bypass)
│   │   ├── UHAntiHook.{h,m}          # Anti-anti-hook (4 vector + _dyld_get_image_header)
│   │   └── UHRuntimeProtection.{h,m} # BRK/PAC spoof (2 vector)
│   ├── UHKernel/
│   │   └── UHKcall.{h,m}             # libjailbreak wrappers (5 patches guarded)
│   ├── UHRules/
│   │   └── UHRuleLoader.{h,m}        # vectors.json parser + watchdog
│   └── UHTests/
│       └── UHSmokeTests.{h,m}        # In-process sanity tests
├── Tests/
│   └── test_plan_banking.md          # Manual test plan cho banking VN
├── .github/
│   └── workflows/
│       ├── build.yml                 # macOS-14 + Theos + iOS 18.6 SDK
│       └── lint.yml                  # plist/json/shellcheck trên Ubuntu
├── scripts/
│   ├── test_app.sh                   # Build verification script
│   └── sign.sh                       # ldid re-sign cho .deb
└── AUDIT_REPORT.md                   # Audit kỹ thuật iOS 18.6.2 + ElleKit
```

## Các vector hook chi tiết (75+)

### Lớp 1 — File system (10 hook)
- `-[NSFileManager fileExistsAtPath:]` (Objective-C)
- `-[NSFileManager fileExistsAtPath:isDirectory:]` (Objective-C)
- `-[NSFileManager attributesOfItemAtPath:error:]` (Objective-C)
- `fopen` (libc, fishhook)
- `open` (libc, fishhook)
- `stat` (libc, fishhook)
- `lstat` (libc, fishhook)
- `access` (libc, fishhook)
- `opendir` (libc, fishhook)
- `readdir` (libc, filter blacklist entries)

### Lớp 2 — Process & execution (10 hook)
- `fork` / `vfork` → EPERM trong target app
- `execve` / `posix_spawn` → chặn exec binaries jailbreak
- `sysctl` → filter `KERN_PROC` / `KERN_PROCARGS`
- `sysctlbyname` → filter `kern.jailbreak*`
- `getppid` → return 1 nếu parent đáng ngờ
- `kill` → chặn signal tới PID jailbreak
- `ptrace` → return 0 cho `PT_DENY_ATTACH`
- `csops` → spoof csflags (clear CS_KILL | CS_HARD)

### Lớp 3 — dyld & runtime (6 hook)
- `_dyld_image_count`
- `_dyld_get_image_name`
- `dlopen`
- `dlsym`
- `objc_copyClassList`
- `objc_getClassList`

### Lớp 4 — Environment & URL (7 hook)
- `getenv` / `setenv` / `secure_getenv`
- `__system_property_get` → mask `ro.boot.jailbreak`
- `-[UIApplication canOpenURL:]` (Objective-C)
- `-[LSApplicationWorkspace applicationIsInstalled:]` (private API)
- `-[LSApplicationProxy applicationIsInstalled:]` (private API)

### Lớp 5 — Sandbox & AMFI (7 hook)
- `sandbox_check` (libsystem_sandbox)
- `SecCodeCopySigningInformation`
- `SecCodeCheckValidity`
- `SecTaskCopyValueForEntitlement`
- `MISValidateSignature`
- `MISValidateSignatureAndCopyInfo`
- `xpc_connection_create`

### Lớp 6 — Network & IOKit (4 hook)
- `getifaddrs` → filter utun/ipsec
- `io_service_open_extended`
- `MGCopyAnswer` (MobileGestalt)
- `MGCopyAnswerWithError`

### Lớp 7 — Objective-C aggregate bypass
Lazy scan `objc_getClassList` + hook tất cả method có selector khớp
regex blacklist (amIJailbroken, isJailbroken, amIDebugged, performChecks, v.v.)
trên class khớp regex blacklist (JailbreakChecker, IOSSecurity, ...).

### Lớp 8 — Kernel patches (5 patches)
Dùng libjailbreak `kcall` + `kwritebuf`:

1. **AMFIIsCDHashInTrustCache** → write `mov x0, #0; ret`
2. **mac_policy_conf ops 201-316** → patch từng entry thành allow stub
3. **_cred_label_update_execve** → NOP csflags kill path
4. **task_conversion_eval** → return 0
5. **Per-process csflags mask** → clear CS_KILL/CS_HARD, set CS_DEBUGGED

### Anti-Anti-Hook (3 hook)
- `mach_vm_region`
- `vm_region_64`
- `vm_region_recurse_64`
- Bump `_dyld_image_count` down

### Runtime Protection (2 hook)
- `vm_read` → replace BRK #1 với NOP
- `vm_read_overwrite` → replace BRK #1 với NOP

## Cài đặt

### Build trên macOS

```bash
# Cài Theos
git clone --depth 1 https://github.com/theos/theos.git /opt/theos
echo 'export THEOS=/opt/theos' >> ~/.zshrc
echo 'export PATH=$THEOS/bin:$PATH' >> ~/.zshrc

# Cài iOS 18.6 SDK
curl -L -o /tmp/ios18.6.tar.xz \
  https://github.com/theos/sdks/releases/download/iPhoneOS18.6/iPhoneOS18.6.sdk.tar.xz
mkdir -p /opt/theos/sdks
tar -xJf /tmp/ios18.6.tar.xz -C /opt/theos/sdks

# Build
cd UltraHidePro
make package FINALPACKAGE=1
```

### GitHub Actions

CI đa workflow (xem `.github/workflows/`):

| Workflow | Runner | Mục đích |
| -------- | ------ | -------- |
| `build.yml::verify` | macos-14 | Build bằng Theos + iOS 18.6 SDK, upload `.deb` artifact. |
| `build.yml::lint`   | macos-14 | Static analysis (`make analyze=1`). |
| `lint.yml::plist_json` | ubuntu-22.04 | Validate `*.plist`, `vectors.json`. |
| `lint.yml::sources_count` | ubuntu-22.04 | Đảm bảo số file `.m` / hook site ở mức tối thiểu. |
| `lint.yml::shellcheck` | ubuntu-22.04 | Shellcheck trên `scripts/*.sh`. |

Cache:
* `/opt/theos` cache theo tuần.
* iOS SDK cache theo tuần.
* Build log upload khi fail (3 ngày), `.deb` upload khi pass (14 ngày).

Trigger: push lên `master` / `main`, mọi PR, hoặc manual `workflow_dispatch`.

```bash
# Local reproduce CI:
THEOS=/opt/theos bash scripts/test_app.sh
```

### Cài trên thiết bị

```bash
# Cài qua Sileo/Zebra hoặc:
dpkg -i packages/com.ultrahidepro.tweak_1.0.0_iphoneos-arm64.deb

# Respring
killall -9 SpringBoard
```

### Verify tweak load

```bash
# Theo dõi log
log stream --predicate 'subsystem == "com.ultrahidepro.tweak"' --info

# Check số hook active
xcrun simctl spawn booted env | grep ULTRAHIDE_ACTIVE_HOOKS
# Hoặc trên thiết bị:
ssh root@iphone 'echo $ULTRAHIDE_ACTIVE_HOOKS'
```

## Cấu hình

Chỉnh `/var/jb/Library/UltraHidePro/config.plist`:

```xml
<key>target_apps</key>
<array>
    <string>com.vcb.digibank</string>
    <string>com.mbbank.mobilebanking</string>
    <string>com.momo.wallet</string>
</array>

<key>enabled_layers</key>
<dict>
    <key>filesystem</key>   <true/>
    <key>process</key>      <true/>
    <key>dyld</key>         <true/>
    <key>environment</key>  <true/>
    <key>sandbox_amfi</key>  <true/>
    <key>network_iokit</key> <true/>
    <key>objc_aggregate</key><true/>
    <key>kernel</key>       <false/>  <!-- bật cẩn thận -->
</dict>
```

Nếu `target_apps` rỗng, tweak chạy cho mọi process (catch-all mode).
Mỗi layer tương ứng một module `Sources/UHHooks/UH*.m`.

## Dynamic rules

Chỉnh `/var/jb/Library/UltraHidePro/vectors.json` rồi đợi 5 giây — watchdog tự reload.

```json
{
  "vectors": [
    {
      "id": "custom_path_check",
      "layer": "filesystem",
      "selector": "/path/to/new/jailbreak/file",
      "hook_type": "objc_method",
      "strategy": "return_false_for_blacklist",
      "risk": "low"
    }
  ]
}
```

## Ký .deb

```bash
# Sau khi build
ldid -S packages/com.ultrahidepro.tweak_1.0.0_iphoneos-arm64.deb

# Hoặc ký dylib trước khi build
ldid -S entitlements.plist packages/com.ultrahidepro.tweak_1.0.0_iphoneos-arm64.deb
```

entitlements.plist mẫu:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.private.security.no-sandbox</key>
    <true/>
    <key>get-task-allow</key>
    <true/>
</dict>
</plist>
```

## Lưu ý quan trọng

1. **Dopamine 3.0.9** là bản public mới nhất (Aug 22, 2026). Plan tương thích với 3.0.x.

2. **iOS 18.6.2 chỉ support A8-A13** với Dopamine 3.0 (Momentarius bypass). Thiết bị A14+ (iPhone 12 trở lên) chưa support.

3. **kcall availability**: A8-A11 (arm64 thuần) có kcall đầy đủ. A12-A13 (arm64e) bị disabled ở iOS 16+ nhưng có Fugu14 fallback dùng `pmap_enter_options_addr`. **Cẩn thận**: Patch csflags kill path với offset sai có thể gây kernel panic — test trên thiết bị cá nhân trước.

4. **Build**: Bạn cần macOS + Xcode 14+ + Theos (Linux + cross-toolchain cũng work). GitHub Actions runner macOS cung cấp sẵn qua `.github/workflows/build.yml`.

5. **Ethical use**: Tweak này dành cho **nghiên cứu bảo mật được ủy quyền**. Bypass detection của app banking/streaming/game trên thiết bị cá nhân có thể vi phạm Terms of Service và luật pháp địa phương (PCI-DSS, chống fraud theo Nghị định 13/2023/NĐ-CP VN).

## Tương thích

| Component | Version |
|-----------|---------|
| Dopamine | 3.0.x (3.0.9 mới nhất) |
| iOS | 18.6.2 |
| Device | A8–A13 (arm64) |
| ElleKit | bất kỳ version kèm Dopamine |

## Testing

### Smoke tests

Tweak đính kèm 9 in-process smoke tests ở `Sources/UHSmokeTests.c`. Chạy bằng:

```objc
#import "Sources/Tests/UHSmokeTests.h"
UHRunSmokeTests();
```

### Banking apps VN

Xem `Tests/test_plan_banking.md` cho checklist chi tiết cho VCB Digibank, MBBank, MoMo, etc.

### CI

GitHub Actions workflow ở `.github/workflows/build.yml` chạy build verification trên macOS-14 + Xcode 15.

## License

MIT License. Xem LICENSE.
