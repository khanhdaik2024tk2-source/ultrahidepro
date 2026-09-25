# Test Plan: Banking apps VN

## Quy tắc nghiêm ngặt

- **CHỈ chạy trên thiết bị thuộc sở hữu cá nhân của bạn.**
- KHÔNG sử dụng trên thiết bị của người khác hoặc thiết bị công ty.
- KHÔNG bypass detection cho mục đích gian lận tài chính.
- Mục đích test: xác minh tính đúng đắn của các vector hook, không phải
  để lừa đảo ngân hàng.

## Phương pháp test

1. Cài đặt Dopamine 3.0.9 rootless trên thiết bị A8-A13 chạy iOS 18.6.2.
2. Reboot, jailbreak bằng Dopamine.
3. Cài UltraHidePro `.deb` qua Sileo/Zebra.
4. Verify tweak load: `os_log --predicate 'subsystem == "com.ultrahidepro.tweak"'`.
5. Cài từng app ngân hàng test bên dưới.
6. Mở app, đăng nhập (nếu cho phép), điều hướng qua các màn chính.
7. Quan sát:
   - App có cảnh báo "Phát hiện jailbreak" không?
   - Login có thành công không?
   - Các chức năng (chuyển tiền, xem số dư) có hoạt động không?
8. Sau mỗi app, check log:
   ```
   log stream --predicate 'subsystem == "com.ultrahidepro.tweak"' --info
   ```

## Checklist cho từng app

| App | Bundle ID | Vector chính (theo nghiên cứu) | Kỳ vọng |
|-----|-----------|---------------------------------|---------|
| VCB Digibank | com.vcb.digibank | File + DTTJailbreakDetection + Security SDK | Pass (login OK, no warning) |
| MBBank | com.mbbank.mobilebanking | Custom SDK + Env var check | Pass |
| Techcombank | com.techcombank.mobile | Custom + Deep linking check | Pass |
| VPBank | com.vnpay.vpbankneo | App Attest + File system | Pass (basic) |
| MoMo | com.momo.wallet | Multi-layer + Behavioral | Pass |
| Timo | vn.timo.app | Basic file check | Pass |
| Cake | vn.cake.app | Basic file check | Pass |
| VNPay | com.vnpay.vntrip | Cert pinning + integrity | Pass (basic) |

## Framework test (nếu không có banking app)

| Framework | Repo | Kỳ vọng |
|-----------|------|---------|
| DVIA-v2 | https://github.com/prateek147/DVIA-v2 | Tất cả jailbreak detection vectors PASS |
| IAC | https://github.com/iac-security | Pass |
| IOSSecurity_Slayer test app | https://github.com/dodola/IOSSecuritySuite | Pass |
| JailbreakChecker demo | https://github.com/theoddball/JailbreakChecker | Pass |
| DTTJailbreakDetection demo | - | Pass |

## Test cases cụ thể cho từng layer

### Lớp 1 — File system
- [ ] DVIA "Jailbreak Test 1: File system check" → "Not jailbroken"
- [ ] IOSSecuritySuite `IOSSecuritySuite.amIJailbroken()` returns `false`
- [ ] Custom: `access("/var/jb", F_OK) == -1`

### Lớp 2 — Process
- [ ] DVIA "Suspicious PID check" → clean
- [ ] sysctl KERN_PROC không list các process jailbreak
- [ ] fork() trong app test bị block

### Lớp 3 — dyld
- [ ] `_dyld_image_count` không bao gồm UltraHidePro
- [ ] `_dyld_get_image_name(i)` không có "UltraHidePro" substring

### Lớp 4 — Environment
- [ ] `getenv("DYLD_INSERT_LIBRARIES") == NULL`
- [ ] `canOpenURL("cydia://") == NO`

### Lớp 5 — Sandbox/AMFI
- [ ] `SecCodeCheckValidity` returns errSecSuccess
- [ ] `sandbox_check` cho phép access /var/jb

### Lớp 6 — Network/IOKit
- [ ] `getifaddrs()` không trả về utun* trên thiết bị không jailbroken (control)
- [ ] `MGCopyAnswer("Jailbroken") == NULL`

### Lớp 7 — Aggregate
- [ ] `JailbreakChecker.performChecks == 1`
- [ ] `IOSSecuritySuite.amIJailbroken() == false`

### Lớp 8 — Kernel
- [ ] Sau bật kernel layer, target app có thể chạy được
- [ ] Không có kernel panic log
- [ ] csflags được patch đúng (process có CS_DEBUGGED)

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| App crash ngay khi mở | Hook quá aggressive | Tắt lớp tương ứng trong config.plist |
| App vẫn báo jailbreak | Vector chưa hook | Thêm vào vectors.json + reload |
| Kernel panic | Patch csflags sai offset | Tắt kernel layer, kiểm tra trên A12 |
| Tweak không load | Thiếu libjailbreak | Cài lại Dopamine, kiểm tra /var/jb/usr/lib/libjailbreak.dylib |
| SpringBoard respring liên tục | Hook class hệ thống | Whitelist bundle ID trong target_apps |

## Báo cáo kết quả

Sau khi test, tạo issue với format:
```
App: <tên app>
Device: <iPhone model>
iOS: <version>
Bundle ID: <id>
Result: PASS / PARTIAL / FAIL
Logs: <os_log excerpt>
Notes: <mô tả chi tiết>
```
