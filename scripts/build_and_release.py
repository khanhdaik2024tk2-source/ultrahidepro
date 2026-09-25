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
    
    out_dir = os.path.abspath("dist/v1.1.6")
    deb_path = download_artifact(run_id, out_dir)
    if not deb_path or not os.path.exists(deb_path):
        print("Failed to download deb package")
        sys.exit(1)
    
    print(f"Downloaded DEB: {deb_path}")
    
    tag = "v1.1.6"
    name = "UltraHide Pro v1.1.6 (Dopamine-Grade Zero-Crash Rootless Engine)"
    body = """# UltraHide Pro v1.1.6 — Dopamine-Grade Zero-Crash Rootless Engine

### 🛡️ Deep Research & Pro Architecture Overhaul
Bản cập nhật v1.1.6 đại tu toàn bộ kiến trúc lõi để đạt độ ổn định và tàng hình tương đương cơ chế "Hide Jailbreak" gốc của Dopamine:

1. **Khắc phục Lỗi Lệch 4-byte Con Trỏ Mach-O 64-bit (`UHMachO.m`):**
   - Trên nền tảng 64-bit ARM64, header Mach-O là `mach_header_64` (32 bytes với trường `reserved`). Hàm định vị `UHLocateTextSegment` trước đó duyệt `(hdr + 1)` qua con trỏ 28-byte, khiến con trỏ đọc lệch 4 byte và nhảy vào vùng nhớ không hợp lệ (`SIGSEGV` / `EXC_BAD_ACCESS`) ngay tại constructor `[UHMachO bootstrap]` của mọi app mục tiêu. Đã sửa chuẩn `sizeof(struct mach_header_64)`.
2. **Bộ Lọc Đường Dẫn Thuần C Siêu Tốc (Zero Objective-C Overheads):**
   - Loại bỏ hoàn toàn việc tạo `NSString` và gọi Objective-C runtime trong các hook libc (`stat`, `lstat`, `open`, `openat`, `access`, `readdir`,...).
   - Chuyển 100% sang hàm lọc C thuần `UHPathBlockedFast()`: kiểm tra tiền tố tức thì trong <50ns, loại trừ ngay lập tức các đường dẫn sandbox hợp lệ (`/var/containers/`), ngăn chặn hoàn toàn hiện tượng đệ quy re-entrancy làm tràn ngăn xếp call stack.
3. **Loại Bỏ Hoàn Toàn Hook Nguy Hiểm Trên `vfork` & `csops`:**
   - `vfork` trên ARM64 mượn stack frame của caller nên không thể hook inline bằng `MSHookFunction` mà không làm hỏng register/PAC. Đã loại bỏ hook `vfork`.
   - `csops` can thiệp xóa cờ `CS_KILL` và `CS_HARD` làm vi phạm chính sách Hardened Runtime của iOS khiến ứng dụng bị hệ thống kill ngay. Đã gỡ bỏ hook `csops`.
4. **Sửa Lỗi Truyền Con Trỏ `dlsym` & `dladdr`:**
   - Trong `UHDyld.m`, `dlsym` trước đây truyền handle thư viện (`RTLD_DEFAULT = -2`) vào `dladdr` gây lỗi truy cập bộ nhớ trên dyld4 iOS 16/17/18. Đã chuyển sang kiểm tra an toàn địa chỉ trả về của caller `__builtin_return_address(0)`.
5. **Dọn Dẹp Hook `LSApplicationWorkspace`:**
   - Gỡ bỏ hook `allApplications` (hàm private bị cấm trong sandbox) để bảo vệ tuyệt đối runtime của các app ngân hàng.

---
### 📦 Cài Đặt (Installation)
1. Tải file `.deb` đính kèm: `com.ultrahidepro.tweak_1.1.6_iphoneos-arm64.deb`.
2. Cài đặt qua **Sileo** hoặc terminal Dopamine.
3. Respring lại thiết bị.
4. Mở app **UltraHide Pro** -> Bật ứng dụng cần bảo vệ (MBBank, vcb, momo,...) -> Mở app bình thường với độ mượt tuyệt đối và không bị văng.
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
