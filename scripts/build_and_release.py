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
    
    out_dir = os.path.abspath("dist/v1.2.0")
    deb_path = download_artifact(run_id, out_dir)
    if not deb_path or not os.path.exists(deb_path):
        print("Failed to download deb package")
        sys.exit(1)
    
    print(f"Downloaded DEB: {deb_path}")
    
    tag = "v1.2.0"
    name = "UltraHide Pro v1.2.0 (Dopamine-roothide 3.x Architecture for iOS 18+)"
    body = """# UltraHide Pro v1.2.0 — Kiến Trúc Tương Thích Hoàn Hảo Dopamine-roothide 3.x Trên iOS 18+

### 🚀 Bước Đột Phá Lớn: Học Tập & Phát Triển Trực Tiếp Từ Mã Nguồn Dopamine-roothide
Bản cập nhật **v1.2.0** tái thiết toàn diện quy trình đăng ký ứng dụng và quản lý tệp tin dựa trên kiến trúc lõi của **Dopamine-roothide 3.x**:

1. **Tự Động Nhận Diện `JBROOT` Động (Dynamic JBROOT Resolution):**
   - Trong RootHide, đường dẫn jailbreak không cố định tại `/var/jb` mà được ngẫu nhiên hóa (Randomized Root).
   - `postinst` trong v1.2.0 tự động truy vấn `jbroot /`, phân giải cây thư mục `uicache`, và tự động đồng bộ file `.app` vào cả `/var/jb/Applications` và `$JBROOT/Applications`. Bất kể thiết bị chạy Dopamine thuần, Dopamine-roothide hay RootHide Bootstrap, ứng dụng luôn nằm đúng vị trí LaunchServices tìm kiếm.

2. **Khôi Phục Quyền Sở Hữu `root:wheel (0:0)` Chuẩn System Application:**
   - Trên iOS 18, LaunchServices bắt buộc các ứng dụng hệ thống trong thư mục Applications phải thuộc sở hữu của `root:wheel` (`0:0`) với quyền `0755`.
   - v1.2.0 chuẩn hoá triệt để quyền hạn trên toàn bộ bundle, tệp thực thi Mach-O và `Info.plist`, ngăn chặn việc hệ điều hành âm thầm từ chối nạp ứng dụng.

3. **Tích Hợp `jbctl rebuild_icon_cache` (Công Cụ Gốc Của Dopamine 3.x):**
   - Thay vì chỉ dựa vào `uicache`, script cài đặt tự động kích hoạt `jbctl rebuild_icon_cache` — API gốc của Dopamine gọi `_LSPrivateRebuildApplicationDatabasesForSystemApps:internal:user:` kết hợp hook `lsd.x` để SpringBoard tái nạp icon ngay lập tức.

4. **Tích Hợp URL Scheme `ultrahidepro://` Độc Lập:**
   - Bổ sung URL scheme `ultrahidepro` vào `Info.plist` và `UHAppDelegate`.
   - Người dùng có thể mở app bất kỳ lúc nào bằng cách gõ `ultrahidepro://` vào Safari hoặc Spotlight, kể cả khi trang màn hình chính bị ẩn.

5. **Bổ Sung Bảng Điều Khiển PreferenceLoader Trong Cài Đặt (Settings -> UltraHide Pro):**
   - Tích hợp sẵn panel điều khiển trong **Cài đặt (Settings.app)**.
   - Cung cấp sẵn các nút gạt bật/tắt bảo vệ, nút "Mở Ứng Dụng UltraHide Pro", và nút "Làm Mới Icon (UICache)" trực tiếp trong Settings.

6. **Kế Thừa 100% Pure Zero-Crash Engine:**
   - Tuyệt đối không can thiệp mã máy C qua MSHookFunction, không gây văng MBBank hay bất kỳ ứng dụng ngân hàng nào.

---
### 📦 Hướng Dẫn Cài Đặt (Installation)
1. Tải file `.deb` v1.2.0 đính kèm bên dưới: `com.ultrahidepro.tweak_1.2.0_iphoneos-arm64.deb`.
2. Cài đặt bằng **Sileo**, **Zebra** hoặc **Filza**.
3. Khi cài đặt xong, máy sẽ tự động làm mới giao diện trong 2 giây. Icon **UltraHide Pro** sẽ hiển thị trên Màn hình chính!
4. **Cách mở app dự phòng:**
   - Vào **Cài đặt (Settings)** -> Chọn **UltraHide Pro** -> Bấm **Mở Ứng Dụng UltraHide Pro**.
   - Hoặc mở **Safari** gõ `ultrahidepro://` để vào trực tiếp ứng dụng.
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
