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
    
    out_dir = os.path.abspath("dist/v1.1.9")
    deb_path = download_artifact(run_id, out_dir)
    if not deb_path or not os.path.exists(deb_path):
        print("Failed to download deb package")
        sys.exit(1)
    
    print(f"Downloaded DEB: {deb_path}")
    
    tag = "v1.1.9"
    name = "UltraHide Pro v1.1.9 (Reliable Home Screen App Icon & Pure Zero-Crash Engine)"
    body = """# UltraHide Pro v1.1.9 — Hiển Thị App Màn Hình Chính Chuẩn Xác & Pure Zero-Crash Engine

### 📱 Cải Tiến Quan Trọng Trong v1.1.9: Khắc Phục Triệt Để Icon App Trên Màn Hình Chính
Bản cập nhật v1.1.9 giải quyết dứt điểm tình trạng cài đặt xong gói `.deb` nhưng biểu tượng ứng dụng **UltraHide Pro** không xuất hiện trên Màn hình chính (SpringBoard) của iOS 18 (Dopamine rootless):

1. **Thực Thi `uicache` Đúng Chuẩn Dưới Ngữ Cảnh Người Dùng `mobile` (UID 501):**
   - Cơ chế bảo mật và quản lý LaunchServices trên iOS 15/16/17/18 tách biệt hoàn toàn cơ sở dữ liệu biểu tượng người dùng (`/var/mobile/Library/Caches/`) với người dùng `root`.
   - Trước đây `postinst` chạy quyền `root` khiến `uicache` ghi nhận vào phiên quản trị hoặc không cập nhật được cache của `mobile`.
   - Trong v1.1.9, lệnh đăng ký gói ứng dụng được chuyển tiếp trực tiếp vào `su -c "... uicache" mobile` và đồng bộ kép với cả root.

2. **Đăng Ký Đa Tầng Cụ Thể (Specific Bundle Path + Realpath + Global Refresh):**
   - Đăng ký đích danh bundle `/var/jb/Applications/UltraHidePro.app` qua cờ `-p`.
   - Tự động phân giải đường dẫn thật (realpath / symlink canonical) phòng trường hợp Dopamine liên kết ngẫu nhiên (`/private/preboot/...`).
   - Cập nhật toàn diện icon cache với cờ `-a`.

3. **Phát Tín Hiệu Hệ Thống Darwin Notifications:**
   - Tự động gửi thông báo hệ thống `com.apple.mobile.applicationinstalled` và `com.apple.LaunchServices.applicationsChanged` thông qua `notifyutil`.
   - Tự động nạp lại SpringBoard một cách êm ái (soft sbreload) 2 giây sau khi `dpkg` hoàn tất cài đặt an toàn.

4. **Bổ Sung Khai Báo Hệ Thống Tiêu Chuẩn:**
   - Bổ sung `MinimumOSVersion = 15.0` vào `Info.plist`.
   - Bổ sung phụ thuộc `uikittools (>= 2.0)` trong `control` để đảm bảo công cụ quản lý giao diện luôn sẵn sàng.

5. **Giữ Nguyên 100% Kiến Trúc Pure Zero-Crash Engine (Đã Chứng Minh Hiệu Quả Ở v1.1.8):**
   - 0 MSHookFunction trên hàm C hệ thống (không đứt gãy trampoline, không sinh bẫy `BRK #1` gây văng app).
   - 100% Objective-C Runtime Swizzling an toàn tuyệt đối với PAC/BTI.
   - Đồng bộ cấu hình kép qua `cfprefsd` xuyên thấu sandbox ngân hàng (MBBank, VCB, Momo,...).

---
### 📦 Hướng Dẫn Cài Đặt (Installation)
1. Tải file `.deb` đính kèm bên dưới: `com.ultrahidepro.tweak_1.1.9_iphoneos-arm64.deb`.
2. Cài đặt bằng **Sileo**, **Zebra** hoặc **Filza**.
3. Sau khi cài đặt hoàn tất, thiết bị sẽ tự động nạp lại SpringBoard trong 2 giây và icon **UltraHide Pro** sẽ xuất hiện ngay trên Màn hình chính!
   *(Nếu chưa thấy ngay do cache hệ thống cũ, chỉ cần mở Dopamine bấm "Respring" hoặc chạy `uicache -a -r` trong Terminal).*
4. Mở app **UltraHide Pro** -> Chọn ứng dụng cần bảo vệ (MBBank,...) -> Bấm **Lưu**.
5. Mở MBBank: Ứng dụng chạy mượt mà 100%, không bị văng và hoàn toàn vượt qua kiểm tra jailbreak!
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
