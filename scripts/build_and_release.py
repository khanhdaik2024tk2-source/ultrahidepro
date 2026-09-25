import urllib.request
import urllib.parse
import json
import time
import zipfile
import io
import os
import sys

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
    run_id = 36169360084
    wait_for_run(run_id)
    
    out_dir = os.path.abspath("dist/v1.1.5")
    deb_path = download_artifact(run_id, out_dir)
    if not deb_path or not os.path.exists(deb_path):
        print("Failed to download deb package")
        sys.exit(1)
    
    print(f"Downloaded DEB: {deb_path}")
    
    tag = "v1.1.5"
    name = "UltraHide Pro v1.1.5 (Zero-Crash Architecture & Universal App Stability)"
    body = """# UltraHide Pro v1.1.5 — Zero-Crash Architecture & Universal App Stability

### 🚀 Highlights & Root-Cause Crash Fixes
Bản cập nhật v1.1.5 khắc phục triệt để lỗi **văng/crash ngay khi bật bảo vệ cho bất kỳ ứng dụng nào** (MBBank, Banking, và mọi app được chọn):

1. **Khắc phục Crash `_objc_fatal` Duplicate Class Registration:**
   - Đã loại bỏ hook đè `_dyld_get_image_header` trả về header `0` của executable chính. Hook cũ khiến Apple `libobjc` trong quá trình khởi động nạp lại toàn bộ class của file thực thi lần 2 dẫn đến abort `_objc_fatal` crash ngay tức khắc.
2. **Khắc phục Lỗi Cấp Phát Bộ Nhớ `freeifaddrs` (`SIGABRT`):**
   - Loại bỏ can thiệp head con trỏ `getifaddrs` trong `UHNetworkIOKit.m`. Cấu trúc `ifaddrs` trên Darwin được cấp phát trong một khối nhớ đơn lẻ (`malloc`), việc thay đổi head pointer khiến `freeifaddrs` giải phóng sai offset và crash `SIGABRT` khi bất kỳ app nào khởi tạo mạng.
3. **Loại Bỏ Hook Nguy Hiểm Trên XPC và MobileGestalt:**
   - Không hook `xpc_connection_create` trả về `NULL` (UIKit gọi XPC không check null).
   - Tắt hook `MGCopyAnswer` trả về `NULL` cho các khóa phần cứng (`HasBaseband`, `ChipID`) gây sập UIKit/CoreTelephony lúc mở app.
4. **Tối Ưu Hóa & Luồng An Toàn Tuyệt Đối Cho `readdir` / Dyld:**
   - Thay thế bộ đệm tĩnh toàn cục bằng kiểm tra trực tiếp qua descriptor thread-safe `fcntl(fd, F_GETPATH)`.
   - Giữ nguyên các tầng hook cốt lõi an toàn: `dlopen`, `dlsym`, `dladdr`, `sandbox_check`, `SecCodeCheckValidity`, `sysctl`, và filesystem filtering.

---
### 📦 Cài Đặt (Installation)
1. Tải file `.deb` đính kèm bên dưới: `com.ultrahidepro.tweak_1.1.5_iphoneos-arm64.deb`.
2. Mở bằng **Sileo** hoặc cài đặt qua terminal Dopamine.
3. Respring lại thiết bị.
4. Mở ứng dụng **UltraHide Pro** trên Màn hình chính -> Bật ứng dụng cần bảo vệ -> Lưu thành công và mở app mượt mà không bị văng.
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
