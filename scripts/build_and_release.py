import urllib.request
import urllib.parse
import json
import time
import zipfile
import io
import os
import sys
import subprocess

TOKEN_PATH = os.path.join(os.path.dirname(__file__), ".token")
if os.path.exists(TOKEN_PATH):
    with open(TOKEN_PATH, "r") as f:
        TOKEN = f.read().strip()
else:
    TOKEN = os.environ.get("GITHUB_TOKEN", "")

REPO = "khanhdaik2024tk2-source/ultrahidepro"
HEADERS = {
    "Authorization": f"token {TOKEN}",
    "Accept": "application/vnd.github.v3+json",
    "User-Agent": "ReleaseBot"
}

class StripAuthRedirect(urllib.request.HTTPRedirectHandler):
    def http_error_302(self, req, fp, code, msg, headers):
        location = headers.get("Location")
        clean_req = urllib.request.Request(location, headers={"User-Agent": "ReleaseBot"})
        return urllib.request.urlopen(clean_req)

def api_get(endpoint):
    url = f"https://api.github.com/repos/{REPO}/{endpoint}" if not endpoint.startswith("http") else endpoint
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode())

def get_current_sha():
    res = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True)
    return res.stdout.strip()

def find_run_for_sha(sha):
    print(f"Searching for workflow run with SHA: {sha[:7]}...")
    for _ in range(20):
        data = api_get("actions/runs?per_page=10")
        for r in data.get("workflow_runs", []):
            if r["head_sha"] == sha and r["name"] == "build":
                return r["id"]
        time.sleep(5)
    return None

def wait_for_run(run_id):
    print(f"Checking workflow run {run_id}...")
    while True:
        data = api_get(f"actions/runs/{run_id}")
        status = data.get("status")
        conclusion = data.get("conclusion")
        print(f"Run {run_id}: status={status}, conclusion={conclusion}")
        if status == "completed":
            if conclusion != "success":
                print(f"Workflow failed with conclusion: {conclusion}")
                sys.exit(1)
            print("Workflow completed successfully!")
            return data
        time.sleep(15)

def download_artifact(run_id, out_dir):
    artifacts_data = api_get(f"actions/runs/{run_id}/artifacts")
    artifacts = artifacts_data.get("artifacts", [])
    target = None
    for a in artifacts:
        if a["name"] == "UltraHidePro-arm64-deb":
            target = a
            break
    if not target:
        print("Available artifacts:", [a["name"] for a in artifacts])
        sys.exit(1)

    print(f"Found artifact: {target['name']} (ID: {target['id']}, Size: {target['size_in_bytes']} bytes)")
    dl_url = target["archive_download_url"]
    
    opener = urllib.request.build_opener(StripAuthRedirect)
    req = urllib.request.Request(dl_url, headers=HEADERS)
    with opener.open(req) as resp:
        zip_bytes = resp.read()

    os.makedirs(out_dir, exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(zip_bytes)) as z:
        z.extractall(out_dir)
        print(f"Extracted artifact files: {z.namelist()}")
        for fname in z.namelist():
            if fname.endswith(".deb"):
                return os.path.join(out_dir, fname)
    return None

def create_release(tag, name, body):
    url = f"https://api.github.com/repos/{REPO}/releases"
    payload = json.dumps({
        "tag_name": tag,
        "target_commitish": "main",
        "name": name,
        "body": body,
        "draft": False,
        "prerelease": False
    }).encode("utf-8")
    
    req = urllib.request.Request(url, data=payload, headers=HEADERS, method="POST")
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        err_body = e.read().decode()
        print(f"HTTPError creating release: {e.code} - {err_body}")
        if e.code == 422:
            return api_get(f"releases/tags/{tag}")
        raise

def upload_asset(upload_url_template, file_path):
    upload_url = upload_url_template.split("{")[0]
    filename = os.path.basename(file_path)
    url = f"{upload_url}?name={urllib.parse.quote(filename)}"
    print(f"Uploading {filename} to {url}...")
    
    with open(file_path, "rb") as f:
        file_bytes = f.read()

    upload_headers = {
        "Authorization": f"token {TOKEN}",
        "Content-Type": "application/vnd.debian.binary-package",
        "Content-Length": str(len(file_bytes)),
        "User-Agent": "ReleaseBot"
    }
    
    req = urllib.request.Request(url, data=file_bytes, headers=upload_headers, method="POST")
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode())

def main():
    sha = get_current_sha()
    print(f"Current commit: {sha}")
    
    run_id = find_run_for_sha(sha)
    if not run_id:
        print("Could not find build run for current SHA. Retrying...")
        time.sleep(10)
        run_id = find_run_for_sha(sha)
        if not run_id:
            print("Build run not found.")
            sys.exit(1)
            
    wait_for_run(run_id)
    
    out_dir = os.path.abspath("dist/v1.1.7")
    deb_path = download_artifact(run_id, out_dir)
    if not deb_path or not os.path.exists(deb_path):
        print("Failed to download deb package")
        sys.exit(1)
    
    print(f"Downloaded DEB: {deb_path}")
    
    tag = "v1.1.7"
    name = "UltraHide Pro v1.1.7 (iOS 18+ & ElleKit Architecture Breakthrough)"
    body = """# UltraHide Pro v1.1.7 — Đột Phá Lõi Kiến Trúc Cho iOS 18+ & ElleKit

### 🛡️ Bản Cập Nhật Đột Phá Chấm Dứt Hoàn Toàn Lỗi Văng Ứng Dụng (Zero-Crash)
Bản cập nhật v1.1.7 tái thiết kế kiến trúc hook từ gốc dựa trên bản chất vận hành của **ElleKit** và **iOS 18+ Rootless (Dopamine)**:

1. **Khắc Phục Xung Đột Nhánh Nhảy ElleKit & Syscall Stubs (`libsystem_kernel.dylib`):**
   - Trên iOS 18 rootless, tweak dylib được nạp ở khoảng cách xa (>128MB) so với Dyld Shared Cache. ElleKit không thể dùng lệnh nhảy `B` trực tiếp mà phải thay thế stub bằng `BRK #1` và bắt ngoại lệ Mach `EXC_BREAKPOINT`.
   - Trong `libsystem_kernel.dylib`, các syscall stubs (`open`, `openat`, `fstatat`, `sysctl`, `kill`, `getppid`) chỉ dài 16 bytes xếp liền kề nhau. Việc hook nhiều hàm C liền kề khiến ElleKit làm tràn bộ nhớ stub và phá hỏng con trỏ `cerror`.
   - Các SDK bảo mật ngân hàng (MBBank, VNPay, vcb,...) đăng ký exception handler riêng. Khi đụng `BRK #1` tại syscall stub, app phát hiện can thiệp và gọi `abort()` làm văng app ngay từ giây đầu tiên.
   - **Giải pháp v1.1.7**: Loại bỏ hoàn toàn các hook C nguy hiểm: `open`, `openat`, `fstatat`, `faccessat`, `readlink`, `realpath`, `sysctl`, `sysctlbyname`, `kill`, `getppid`, `execve`, `posix_spawn`.

2. **Chuyển Trục Sang Objective-C Runtime Swizzling Siêu Bền Vững:**
   - Ứng dụng iOS 18 giao tiếp hệ thống tệp và bundle thông qua Foundation/UIKit (`NSFileManager`, `NSBundle`, `UIApplication`).
   - UltraHide Pro v1.1.7 chuyển trọng tâm bảo vệ sang **12 ObjC hooks trên `NSFileManager`**, **2 hooks trên `NSBundle`**, và các hook trên `UIApplication` (`canOpenURL:`), `LSApplicationWorkspace`.
   - Objective-C Swizzling chỉ thay đổi bảng con trỏ selector trong bộ nhớ heap: **100% không vá mã thực thi (0 code patching), 0 sinh bẫy `BRK #1`, an toàn tuyệt đối với PAC & BTI**, hoàn toàn tàng hình trước các trình quét tính toàn vẹn vùng nhớ code.

3. **Chỉ Giữ Lại 6 Hook Libc Tối Cần Thiết & Tinh Gọn:**
   - Giữ lại chỉ 6 hàm C được lọc thuần túy siêu tốc: `stat`, `lstat`, `access`, `fopen`, `fork` (trả về -1/EPERM chuẩn sandbox), và `ptrace` (xử lý an toàn `PT_DENY_ATTACH`).

4. **Xóa Bỏ Rò Rỉ Dấu Vết Tweak Trong `environ`:**
   - Trước đây `Tweak.x` gọi `setenv("ULTRAHIDE_ACTIVE_HOOKS", ...)`. Lệnh này đã ghi tên của tweak trực tiếp vào mảng con trỏ môi trường `environ` của app, khiến trình quét của MBBank phát hiện ngay lập tức. Đã loại bỏ hoàn toàn dấu vết này.

5. **Bộ Lọc Biến Môi Trường Thuần C & Tránh Deadlock `UHLog`:**
   - Thay thế việc phân bổ `NSString` trong `$getenv` bằng hàm lọc C thuần `UHEnvBlockedFast()`.
   - Loại bỏ mọi log phát sinh trong `$getenv`, `$dlopen`, `$dlsym` để triệt tiêu vĩnh viễn hiện tượng re-entrancy / deadlock trong `dispatch_once` của `UHLog`.

6. **Tôn Trọng Tuyệt Đối Danh Sách Lựa Chọn Từ App UI (Không Hardcode):**
   - Loại bỏ toàn bộ mã hardcode bundle ID trong tweak. Tweak chỉ kích hoạt khi bundle ID nằm trong danh sách `target_apps` được người dùng cấu hình và lưu từ ứng dụng UltraHide Pro.

---
### 📦 Hướng Dẫn Cài Đặt (Installation)
1. Tải file `.deb` đính kèm: `com.ultrahidepro.tweak_1.1.7_iphoneos-arm64.deb`.
2. Cài đặt qua **Sileo** hoặc **Zebra** (hoặc lệnh `dpkg -i`).
3. Respring lại thiết bị.
4. Mở app **UltraHide Pro** trên màn hình chính -> Bật ứng dụng cần bảo vệ (MBBank, Techcombank, VCB, Momo,...) -> Nhấn **Lưu**.
5. Mở ứng dụng mục tiêu — ứng dụng sẽ khởi động mượt mà, ổn định tuyệt đối và vượt qua mọi cơ chế kiểm tra jailbreak!
"""
    
    rel = create_release(tag, name, body)
    print(f"Release ready: {rel.get('html_url')}")
    
    # Check if asset already uploaded
    for asset in rel.get("assets", []):
        if asset["name"] == os.path.basename(deb_path):
            print(f"Asset already uploaded: {asset['browser_download_url']}")
            return
            
    asset_res = upload_asset(rel["upload_url"], deb_path)
    print("Asset uploaded successfully!")
    print(f"Direct download URL: {asset_res.get('browser_download_url')}")

if __name__ == "__main__":
    main()
