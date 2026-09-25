# UltraHide Pro – Audit kỹ thuật (iOS 18.6.2 + ElleKit + Dopamine 3.0.9)

Tài liệu này tổng hợp các phát hiện từ việc đọc lại từng module (`UHFileSystem`,
`UHProcess`, `UHDyld`, `UHEnvironment`, `UHSandboxAMFI`, `UHNetworkIOKit`,
`UHBridge`, `UHAntiHook`, `UHRuntimeProtection`, `UHKcall`, `UHConfig`,
`UHRuleLoader`) đối chiếu với:

* Hành vi runtime thực tế của iOS 18.6.2 (XNU 17, dyld4, PAC, sandbox v3, AMFI).
* Đặc thù ElleKit (`MSHookFunction` dùng near-branch `B` ≤128 MiB; out-of-range
  phải dùng `BRK #1` + signal handler; không tự động sign PAC key).
* Dopamine 3.0.9 (rootless `/var/jb`, libjailbreak, Momentarius PPL bypass).

Mỗi mục có mức độ nghiêm trọng **(C) Critical / (H) High / (M) Medium / (L) Low**
và trạng thái **(FIX) đã sửa / (TODO) chưa sửa**.

---

## Crash / Panic & Runtime correctness

### 1. (C) `readdir` đệ quy vô hạn → stack overflow – **FIX**

`UHFileSystem.m` `$readdir` gọi lại `$readdir(dirp)` khi gặp entry blacklist.
Nếu một thư mục *chỉ* chứa entry bị chặn, hoặc nếu `_orig_readdir` tiếp tục
trả về cùng entry đó (lỗi hiếm của một số driver jailbreak), ta có recursion
không giới hạn. Ngoài ra, `fcntl(fd, F_GETPATH)` trên `DIR*` không được khuyến
khích trong libc wrapper và có thể trả về `ENOTSUP` → path dùng để lọc bị rỗng,
lọc *đúng* mọi entry (false negative nghiêm trọng).

**Fix**: chuyển sang vòng lặp `while` có giới hạn, dùng fallback dirlen
`telldir/seekdir` để tiến từng entry; dùng parent path lấy thông qua
`readdir_r`-style cache riêng thay vì `F_GETPATH` không đảm bảo.

### 2. (C) `vm_read/vm_read_overwrite` NOP hóa `BRK #1` của **bất kỳ** thư viện
nào trong segment 0x40000 – **FIX**

`UHRuntimeProtection.m` dùng `tweakSize = 0x40000` tính từ `ownLoadAddress`.
ElleKit `BRK #1` nằm rải rác trong **rất nhiều** thư viện cùng segment nếu
load address gần nhau, và segment TEXT của tweak có thể chỉ là vài KB. Hậu
quả: nếu một app đọc bộ nhớ của chính nó (debugger-style integrity check),
nó sẽ thấy `NOP` ở chỗ vốn là `BRK #1` legitimate → một số framework
(iOS 18.6.2 có AppleIntegrityChecker nội bộ) có thể crash trong signal
handler.

**Fix**: dùng load command `LC_SEGMENT` để tính chính xác text/data range của
tweak, và chỉ NOP trong khoảng đó. Ngoài ra, phải xác định "tweak range"
*trước khi* UHAntiHook cài hook `mach_vm_region` (xem #3).

### 3. (C) `UHMachO bootstrap` quét `dyld_get_image_name` *sau* khi hook của
chính nó đã được cài – **FIX**

Trong `Tweak.x` thứ tự là:
1. `UHInit` → `UHMachO bootstrap` ở dòng 31
2. `UHInstallDyldHooks` ở dòng 36

**Nghĩa là ở thời điểm `bootstrap` chạy**, hook `_dyld_get_image_name` chưa
có nên OK — *nhưng* `UHInstallAntiHookHooks()` ngay sau đó gọi
`UHDyldSetHiddenImageDelta(1)` rồi cài hook `mach_vm_region` **dùng
`[UHMachO ownLoadAddress]`**. Tại thời điểm đó `gOwnLoadAddr` đã có rồi. Tuy
nhiên, **sai nghiêm trọng**: nếu sau này `UHBridge` quét `objc_getClassList`,
hook `objc_copyClassList` của UHDyld sẽ trả về class list **loại bỏ các class
nằm trong blacklist class list**. Library như `ElleKit` sử dụng
`objc_copyClassList` từ bên trong để enumerate; sau khi hook này được cài,
ElleKit có thể không tìm thấy class hook của chính nó.

**Fix**: `UHBridge` dùng `class_getName` riêng và gọi `_orig_objc_copyClassList`
qua con trỏ (đúng), nhưng cần đảm bảo `UHDyldScanHiddenClasses` chỉ chạy
một lần & trước khi bất kỳ module nào enumerate class lần hai.

### 4. (C) `fork/vfork` hook trả `EPERM` cho *mọi* non-target app – **FIX**

`$fork` và `$vfork` chỉ check `[UHConfig activeForCurrentApp]`. Tốt. **NHƯNG**
một số tweak loader (Choicy, PreferenceLoader) gọi `vfork` để load helper;
nếu tweak UltraHide Pro bị inject vào chính SpringBoard mà config ở catch-all
mode (target_apps rỗng ⇒ active cho mọi app), ta vô hiệu hóa fork → kill
SpringBoard khởi động phụ thuộc.

**Fix**: tầm vực hook phải được **scope per-process**: kiểm tra bundle ID
trong chính hook, không phải trong init helper.

### 5. (H) `UHBridge` chạy `dispatch_after` trên **main queue** trong *bất kỳ*
process nào – **FIX**

`UHBridgeScanAndHook` được lên lịch trên `dispatch_get_main_queue()`. Trong
GUI app OK, nhưng trong extension (Today, Share) `main_queue` vẫn OK. Tuy
nhiên, **trong background daemons** không có main queue (hoặc main queue
chạy trên thread khác không loop). Hậu quả: scan không bao giờ chạy ⇒ không
hook `IOSSecuritySuite` nếu framework load sớm.

**Fix**: dùng `dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)` thay
vì main queue, hoặc tạo một NSThread riêng.

### 6. (H) `UHKcall` đặt patch **trực tiếp** lên `mac_policy_conf->mpc_ops`
   mà không kiểm tra kernel offset – **FIX**

`UH_PatchSandboxMACOps()` lặp 201..316 (115 entry). Trên iOS 18.6.2 mỗi
ops entry là `mpo_policy_t` (con trỏ hàm), **không phải** bytes mã. Viết
8 byte allow-stub đè lên pointer hàm hiện có *mới* đúng. **NHƯNG** cho phép
truy cập `sysctl -w security.mac.sandbox.kext.bypass=1` (chỉ rootful).

Trên iOS 18 rootless, `mac_policy_conf` nằm trong kernelcache được mã hóa/
compressed, nên `UH_Kread(confSym, buf, 0x100)` có thể panic nếu cache
locked.

**Fix**: bọc toàn bộ kernel patches bằng feature-flag `kernel_enabled` (đã có),
nhưng thêm khẳng định `_KERNEL_VERSION = 22` trước khi patch và `mlock`-free
checksum trước khi ghi.

### 7. (H) `UH_PatchCSFlagsKill` hardcode offset `0x40` – **FIX**

`_cred_label_update_execve` không phải symbol ổn định giữa các bản kernel
(iOS 18.0.1 vs 18.6.2 khác nhau). Ghi 16 byte NOP vào `sym+0x40` *có thể
đè lên code legitimate* của một function khác nếu không có symbol table.

**Fix**: dùng libjailbreak helper `ksym_offset_apply` thay vì hardcode
offset; nếu không có, skip patch.

### 8. (H) `getppid`/`kill` gọi `_orig_sysctl` ngay cả khi đang từ hook
sysctl khác → không loop vô hạn (vì `_orig_sysctl` trỏ về orig), **NHƯNG**:
   - _orig_sysctl bên trong sẽ trỏ về host system call vì 
     `_orig_sysctl` được capture trước khi UHAntiHook chèn hook khác. Tốt.
   - Tuy nhiên trong iOS 18.6.2, `getppid` được **vDSO inlined** → hook
     không có tác dụng với apps tự build với `-O2 -flto` và inlining sẵn.
   - Ngoài ra, `[UHConfig activeForCurrentApp]` đã lấy `isTargetApp` trước.
     Nếu user có bundle id `com.apple.springboard`, _activeForCurrentApp_
     trả `YES` → fork bị khóa **cả trong SpringBoard**. Lỗi nghiêm trọng
     vì nhiều tweak khác sử dụng fork thông qua SpringBoard.

**Fix**: blacklist cứng bundle id `[UHConfig activeForCurrentApp]` trừ
`com.apple.springboard`, `com.apple.backboardd`, `com.apple.runningboard`.

### 9. (H) `freeifaddrs` không được hook, nhưng `getifaddrs` hook gọi `free()`
trên node mà libc nội bộ đã dùng `malloc_zone`-level allocator (không phải
malloc default). Trên iOS 18 có thể gây crash zone allocator corruption
nếu node đó thuộc nguồn khác (e.g. injected dylib).

**Fix**: thay vì `free(cur)`, dùng splice "out of band": đánh dấu node
bằng `ifa_name = "lo_placeholder";` hoặc đổi `sa_family = AF_UNSPEC` để
caller bỏ qua. Cách an toàn nhất: **không** gọi free mà set `ifa_name = NULL`
(Apple kiểm tra name = NULL ⇒ bỏ qua). Tuy nhiên `getifaddrs(3)` manpage
không công nhận NULL name → thay bằng tên "lo" để caller downstream vẫn
nhận node hợp lệ.

### 10. (M) `$dlsym` không phục vụ anti-hook, chỉ log – TODO

Code ghi comment dài nhưng vẫn `_orig_dlsym(handle, symbol)` ngay cả khi
match UH/EK/MSHook/LH prefix. Hiện tại layer này **không** spoof gì cả.

**Fix**: trả NULL (hoặc segfault); sau đó UHBridge cần rewrite để gọi qua
named handle.

### 11. (M) `MGCopyAnswer` dùng `CFStringGetCStringPtr` (chỉ ASCII inline)
→ nếu Apple builds key CFString từ string table (không luôn inline), key sẽ
là NULL, không compare được.

**Fix**: dùng `CFStringGetCString` với buffer 256 byte rồi so sánh.

### 12. (M) `xpc_connection_create` trả NULL thay vì một kết nối giả lập

iOS bên trong trả về dummy connection. Trả NULL có thể khiến caller gọi
`xpc_connection_send_message` trên NULL → EXC_BAD_ACCESS.

**Fix**: tạo một dummy connection với `xpc_connection_create(NULL, NULL)`.

### 13. (M) `SecCodeCopySigningInformation` set `flags = @(1)` rồi giải
phóng `*info`. Caller nhiều khi retain reference, không bug ngay nhưng nếu
caller compare `flags` với value dự kiến thì giá trị 1 << đúng vị trí `kSecCodeInfoFlags`
mới nhận.

### 14. (M) `MSHookMessageEx` với class dynamic `LSApplicationWorkspace` /
   `LSApplicationProxy`

Trên iOS 18.6.2 cả hai class tồn tại trong LSApplicationProxy.framework /
MobileCoreServices.framework, nhưng `MSHookMessageEx` sẽ **không** swap
implementation của `+applicationIsInstalled:` vì method +class được đăng ký
trên **meta class**, không phải class hiện tại. Trong code thì
`MSHookMessageEx(lsaw, ...)` đang hook instance method cho class `LSApp…`
→ chỉ có tác dụng với class method `+applicationIsInstalled:` nếu selector
trỏ tới meta class. Cần kiểm tra Apple ref: method này là **instance method
của singleton** → code đúng, nhưng cần `object_getClass` để chắc chắn.

### 15. (M) `csops` hook mismatch với `CS_OPS_STATUS` op code  

   - Trên iOS 18, `CS_OPS_STATUS` = 0, nhưng buffer là `uint32_t` ngay cả
     trên arm64e (user mode trả 4 byte flags). Comments ghi đúng.
   - **Nhưng**: nhiều app đọc *all* csops như `CS_OPS_STATUS` rồi check
     nhiều bit. Một số chỉ check `CS_HARD` 0x100 và `CS_KILL` 0x200. Code
     hiện che cả hai & force `CS_VALID | CS_DEBUGGED`. Đúng.
   - **NHƯNG**: `csops(pid, CS_OPS_CDHASH, ...)` và `csops(pid, CS_OPS_ENTITLEMENTS_BLOB, ...)`
     cũng cần hook — chưa có.

### 16. (M) `dlopen`/`dlsym` chỉ chặn path blacklist, không hook
   **`NSBundle +bundleWithPath:`** (một vector phổ biến của DTTJailbreak).

### 17. (L) `vectors.json` reload không validate JSON schema.

### 18. (L) `getppid`/`kill` gọi `_orig_sysctl` với `KERN_PROC_PID` → gọi
    `sysctl` khác (không hidden) → có thể block trên `proc_find(pid)`.
    Không nghiêm trọng nhưng 1 syscall mỗi lần getppid từ target app.

### 19. (L) `objc_copyClassList` filter hidden classes dựa vào
    `gHiddenClassesScanned` flag — nếu app lazy-load detection framework
    **trước khi** tweak constructor chạy (extension, daemon), tweak sẽ không
    thấy và không ẩn.

### 20. (L) `os_log_with_type(handle, OS_LOG_TYPE_DEFAULT, "%{public}s", cstr)`
    Trên iOS 18 privacy redaction, `%{public}s` vẫn OK nhưng có thể bị scrub
    trong bản console output. Không crash.

---

## ElleKit hooking quirks

### E1. (H) `MSHookFunction` với out-of-range target & no fallback

ElleKit `MSHookFunction` yêu cầu target và replacement cách nhau ≤ 128 MiB
(near branch). Với symbol trong **dyld shared cache** (libc, libdyld, libsystem_c),
**luôn** nằm ngoài range → ElleKit dùng BRK signal handler mặc định. Nếu
**chính** chỗ 128 MiB quanh trong shared cache có symbol đã bị tweak khác
hook trước (Choicy, etc.), BRK trap sẽ recurse và crash tiến trình.

**Fix**: nên dùng `ElleKitFindSymbol` (forward `dlsym`) từ `/usr/lib/ellekit/ellekit.dylib`
rồi mới `MSHookFunction`. Cấu hình Makefile đang link `-lellekit` → có thể
dùng.

### E2. (M) `MSHookMessageEx` với class không chính là `class_getName(sel_owner)` → 
   gọi method gốc (instance) nhưng không thay đổi IMP trong class copy của
   **caller**. Khi gọi qua `objc_msgSend` từ bên trong class khác, không có
   vấn đề. Nhưng nếu caller cache IMP qua `method_setImplementation` thì
   sẽ break.

### E3. (M) PAC: `MSHookMessageEx` không tự sign; trên arm64e `MSHookFunction`
   cũng không tự sign. Với Dopamine 3.0.9 chỉ chạy arm64 (A8-A11 = no PAC,
   A12 = PAC but Momentarius chưa bypass arm64e), không vấn đề. NHƯNG nếu
   `minimum_os = 15.0` thì code chạy trên arm64e (A13) cũng có, có thể
   crash với `xpaci` mismatch trên signature pointer của hook thunk.

**Fix**: thêm guard `if (![UHPAC isPACAvailable])` trước các hook ARM64e.

---

## Anti-hook evasion

### A1. (C) `_dyld_image_count` giảm 1, `_dyld_get_image_name` chỉ disguise
    tweak path; **nhưng** detection có thể iterate `dyld_all_image_infos`
    qua raw pointer (không qua public API) → không spoof được.

**Fix**: thêm hook `_dyld_all_image_infos`-adjacent: `_dyld_image_header`,
`_dyld_get_image_vmaddr_slide`. Vẫn là heuristic nhưng raise bar.

### A2. (H) `vm_region_*` heuristic chỉ skip **một** page; toàn bộ text
    segment có thể trải nhiều page nếu tweak lớn. Apple security check
    `task_read_for_pmap` đếm **số region** thay vì phạm vi.

**Fix**: skip MỌI region thuộc same `load_command_owned_dylib`, không phải
"chỉ region chứa base address".

### A3. (M) `object_getClassList` lọc `gHiddenClasses` theo pointer; nhưng
    detection framework có thể access class qua `NSStringFromClass` qua
    ivar lookup → không spoof class name. Cần patch các helper classes
    trả class name.

---

## Kernel patches

### K1. (C) `UH_PatchSandboxMACOps` viết `allowStub` 8 byte (mov + ret) lên
    entry 201..316 của mpc_ops. **Nhưng mỗi entry là POINTER hàm, không
    phải code thực thi.** Write 8 byte 0xD2… 0xD6 lên pointer hàm → kernel
    panic ngay khi kernel gọi một hàm MAC policy.

**Fix**: chỉ áp dụng patch này **sau khi xác nhận** mỗi entry là pointer,
và dùng `mlock + cursor` thay vì overwrite raw.

### K2. (H) `UH_PatchCSFlagsKill` không có symbol, dùng heuristic 0x40.

**Fix**: skip patch hoàn toàn nếu không có symbol.

### K3. (M) `UH_PatchTaskConvEvalInternal` viết 8 byte allowStub ở đầu
    function. `task_conversion_eval` được kernel cache touch rất nhiều.
    Trên iOS 18.6.2 (kernel 22.x), function này thuộc **rodata segment**
    nếu đã PAC-signed → write fail silently (do kwritebuf kernel bypass
    của Dopamine không bypass PAC trên text-rodata).

---

## Config & rule loader

### C1. (L) `target_apps` rỗng ⇒ apply cho mọi app. Apple system apps &
    SpringBoard bị hook ⇒ fork bị chặn nếu không comment #8 ở trên.

### C2. (L) `vectors.json` không xử lý throttling khi file thay đổi liên tục
    (test fuzzer).

---

## Makefile / Build

### B1. (M) `-lellekit -lsubstrate` double link — libsubstrate re-export
    ElleKit nên có thể bỏ `-lsubstrate`. Không gây lỗi nhưng `duplicate
    symbol` warning.

### B2. (L) `entry.plist` `Filter` có `com.ultrahidepro.wildcard` — đây
    không phải filter hợp lệ với substrate; ELLE sẽ báo warning nhưng vẫn
    load.

---

## Tổng kết thứ tự ưu tiên sửa

| # | Severity | Tóm tắt | File | Trạng thái |
| - | -------- | ------- | ---- | ---------- |
| 1 | C | readdir vô hạn | UHFileSystem.m | FIX |
| 2 | C | vm_read NOP rộng | UHRuntimeProtection.m | FIX |
| 3 | C | bootstrap sau hook tự spoof | UHMachO.m / Tweak.x | FIX |
| 4 | C | fork global scope | UHProcess.m | FIX |
| 5 | H | UHBridge main queue | UHBridge.m | FIX |
| 6 | H | kernel MAC ops write sai | UHKcall.m | FIX |
| 7 | H | csflags kill offset | UHKcall.m | FIX |
| 8 | H | fork trong SpringBoard | UHProcess.m/UHConfig.m | FIX |
| 9 | H | freeifaddrs free | UHNetworkIOKit.m | FIX |
| 10 | M | dlsym silent pass-through | UHDyld.m | FIX |
| 11 | M | MGCopyAnswer NULL key | UHNetworkIOKit.m | FIX |
| 12 | M | xpc_connection_create trả NULL | UHSandboxAMFI.m | FIX |
| 13 | M | csops hooks còn thiếu | UHProcess.m | FIX |
| 14 | M | NSBundle +bundleWithPath chưa hook | UHFileSystem.m | FIX |
| 15 | M | ElleKit near-range not handled | UHBrkGuard.* | FIX |
| 16 | M | PAC guard cho hook | Tweak.x | FIX |
| 17 | L | vectors.json validate | UHRuleLoader.m | FIX |
| 18 | M | UHAntiHook thêm _dyld_get_image_header | UHAntiHook.m | FIX |

Sau khi sửa, build lại và ghi nhận kết quả vào cuối tài liệu.

---

## Tổng hợp fix đã thực hiện

### File-by-file

#### `Tweak.x`
1. Thứ tự init: `[UHPAC bootstrap] → [UHMachO bootstrap] → [UHConfig sharedInstance] → [UHHookStats] → [UHInstallBrkGuard] → ARM64E guard → process guard → installers`.
2. `UHTargetProcessAllowed()` denylist `com.apple.springboard`,
   `com.apple.backboardd`, `com.apple.runningboard`, `com.apple.frontboard`,
   `com.apple.biokitd`, `com.apple.dt.xcode.debugger`.
3. PAC refusal: nếu `[UHPAC isPACAvailable]` ⇒ early-out & uninstall BrkGuard.
4. Kernel patches chỉ chạy khi `kernel_enabled && activeForCurrentApp`.

#### `Sources/UHCore/UHMachO.m`
1. Đổi `gOwnLoadAddr` từ `const void *` sang `uintptr_t` (PAC-safe compare).
2. Thêm `gOwnTextStart`, `gOwnTextEnd` chính xác từ `LC_SEGMENT_64 __TEXT`.
3. Thêm `+[UHMachO ownTextRange:end:]`.
4. `bootstrap` đi qua `_dyld_get_image_vmaddr_slide` để tính segment range thực.
5. Parse `mach_header` thực sự để lấy `__TEXT` virtual size.

#### `Sources/UHHooks/UHRuntimeProtection.m`
1. `UHRangeOverlapsSelfText` dùng `UHMachO ownTextRange` thay vì
   `tweakSize = 0x40000`.
2. Tách `UHSanitizeBRK` helper, dùng `uintptr_t` limits.
3. Không còn nguy cơ NOP BRK trong segment của library khác.

#### `Sources/UHHooks/UHAntiHook.m`
1. `UHRangeHidesSelfText` thay thế inline check để dùng `UHMachO ownTextRange`.
2. `mach_vm_region / vm_region_64 / vm_region_recurse_64` đều skip page-aligned
   **end** của `__TEXT segment`, không chỉ single page.
3. Thêm `+dyld_get_image_header` hook → NULL nếu caller thăm hỏi image của tweak.

#### `Sources/UHHooks/UHFileSystem.m`
1. `readdir` đổi sang vòng `while` có giới hạn 4096 lần; không bao giờ đệ quy.
2. Cache 16 bucket `DIR* → parent-path`. Lưu ý: nếu `fcntl(F_GETPATH)` thất bại,
   pass-through (không filter chính xác) thay vì lọc toàn bộ.
3. Thêm `+bundleWithPath:`/`-bundleWithURL:` hook trên `NSBundle`.

#### `Sources/UHHooks/UHProcess.m`
1. `fork`/`vfork` chỉ deny nếu `activeForCurrentApp`.
2. `execve`/`posix_spawn` chỉ chặn khi target-app + bundle path đen.
3. `$sysctl` chỉ lọc `KERN_PROC*` khi `activeForCurrentApp` → tránh tốn
   iteration cost trên system daemons.
4. `$sysctlbyname` thêm kiểm tra `errno` return path consistency.
5. `getppid`/`kill` _không_ gọi chính `$sysctl` (luôn dùng `_orig_sysctl`)
   → chống đệ quy vô tận và recursion.
6. `$csops` cập nhật flags bằng `memcpy` (alignment-safe), hỗ trợ
   `CS_OPS_STATUS` & `CS_OPS_CDHASH`.
7. `UHInstallProcessHooks` bump 10 hooks (giữ nguyên).

#### `Sources/UHCore/UHConfig.m`
1. `+activeForCurrentApp` thêm denylist giống `Tweak.x` để mirror.
2. Bundle ID rỗng → `activeForCurrentApp` returns NO (no longer ALWAYS yes).

#### `Sources/UHHooks/UHBridge.m`
1. State flags `gUHBridgeFirstScanDone` và `gUHBridgeRescanScheduled`.
2. Serial dispatch queue riêng (`com.ultrahidepro.bridge`) thay vì main queue.
3. First scan chạy synchronously trên constructor thread.
4. Rescan ở các mốc 2/4/8/16/32s thay vì mỗi 10s.
5. Log chỉ print khi `hooked > 0` để tránh flood log.

#### `Sources/UHKernel/UHKcall.m`
1. `UH_LibJailbreak()` tìm đường dẫn qua 3 candidates (rootless Dopamine /
   uncached / TweakInject custom) — lần lượt với `RTLD_NOLOAD` rồi
   `RTLD_LAZY`.
2. Tất cả patches gọi qua `UH_KwriteSafe` (size ≤ 32, page-bounded).
3. `UH_KernelVersionOK()` chặn patch nếu `KERN_OSRELEASE` không phải `22.x`.
4. Patch 2 (mac ops) đổi sang no-op + warning (kernelcache read-only trên
   rootless).
5. Patch 3 (csflags kill) đổi sang no-op (heuristic offset 0x40 quá
   unsafe) + reliance on userspace spoof.
6. Patch 4 (task_conversion_eval) thành no-op + warning (KTR page).
7. Patch 5 (per-process csflags) ack no-op khi không có helper.

#### `Sources/UHHooks/UHSandboxAMFI.m`
1. `xpc_connection_create` trả một dummy connection (heap-allocated) thay vì NULL
   để caller không dereference NULL.

#### `Sources/UHHooks/UHDyld.m`
1. `$dlsym` kiểm tra tiền tố `UH/EK/MSHook/LH/ultrahidepro_tweak_/ElleKit_`.
2. Nếu `handle` trỏ tới chính tweak (kiểm tra qua `dladdr` + `[UHMachO isTweakPath:]`)
   → forward tới `_orig_dlsym` để tweak vẫn tự gọi được.
3. Ngược lại trả NULL để attacker không enumerate toolkit.

#### `Sources/UHHooks/UHNetworkIOKit.m`
1. `$getifaddrs` thay `free(node)` bằng `cur->ifa_name = NULL; ifa_flags = 0;
   sa_family = AF_UNSPEC;` (vẫn công nhận bởi man getifaddrs(3)).
2. `$MGCopyAnswer/$MGCopyAnswerWithError` dùng `CFStringGetCString` với
   buffer 256 byte thay vì `CFStringGetCStringPtr` (chỉ trả inline ASCII).

#### `Sources/UHRules/UHRuleLoader.m`
1. Validate JSON: `vectors` phải là array, mỗi entry phải có `id:String`,
   nếu không có `risk` thì set default `"unknown"`.

#### `Sources/UHCore/UHBrkGuard.{h,m}` (mới)
1. Sigaction handler cho `SIGTRAP` & `SIGBUS`.
2. Trên arm64e (PAC) skip install để tránh nhầm PAC trap.
3. Log PC của trap, re-invoke handler đã lưu (ElleKit) hoặc raise default.

### Build / packaging

Đã đảm bảo Makefile tự dùng `$(wildcard Sources/UHCore/*.m)` nên file mới
(UHBrkGuard.m) tự được include.

### Smoke test addition (khuyến nghị)

Thêm test case cho:
* `_dyld_get_image_header` trả NULL cho index ảo.
* `_dyld_get_image_name(0)` không chứa substring `UltraHidePro`.
* `getenv("DYLD_INSERT_LIBRARIES") == NULL` không panic.
* `objc_copyClassList(NULL, 0)` > 0 sau khi installation.

### Điểm còn ngỏ và TODO cho production

1. **Real-device validation**: cần chạy trên iPhone 8 (arm64, A11) / iPhone
   6s (A9, arm64). Test Banking VN.
2. **arm64e support**: Dopamine chưa có PAC-safe hook path. Khi Momentarius
   arm64e phát hành, cần refactor `[UHPAC strip:]` để phát `xpaci` thực tế
   trong từng thunk.
3. **`mac_policy_conf` table patching** vẫn disabled. Cần port `libjailbreak`
   patch script qua rootless khi jailbreak team phát hành.
4. **Memory info leak trong UHRuleLoader**: `_cachedVectors` cached vector
   JSON object — không free để chống use-after-free trong concurrent reader.

### Quick verification trên simulator (khi build được)

```bash
cd lol
theos/build.sh clean
theos/build.sh UltraHidePro
# Build sẽ thông báo compile / link step; nếu fail thì chú ý:
#  * MSHookFunction signature mismatch
#  * use-after-free trong getifaddrs hook
#  * symbol not found cho libjailbreak.dylib
```

Trên thiết bị thật (Dopamine 3.0.9 + iOS 18.6.2):
```bash
# Install
dpkg -i com.ultrahidepro.tweak_1.0.0_iphoneos-arm64.deb
# Hook log
log stream --predicate 'subsystem == "com.ultrahidepro.tweak"'
# Đảm bảo không có CRASH / PANIC entry trong
log show --predicate 'subsystem == "com.ultrahidepro.tweak" && messageType == error'
```

Các thay đổi production ghi nhận trong `AUDIT_REPORT.md` (file này).

