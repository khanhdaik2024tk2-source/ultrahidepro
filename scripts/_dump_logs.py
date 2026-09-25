"""scripts/_dump_logs.py — fetch and pretty-print failing step logs."""
import json
import os
import subprocess
import sys
import zipfile
from io import BytesIO

if len(sys.argv) < 3:
    print("usage: _dump_logs.py OWNER/REPO JOB_ID [STEP_INDEX]")
    sys.exit(1)

repo, job_id = sys.argv[1], sys.argv[2]
step_idx = int(sys.argv[3]) if len(sys.argv) > 3 else None
token = open(os.path.join(os.path.dirname(__file__), '.token')).read().strip()
# Direct curl instead of gh — gh re-renders output with ANSI escapes.
url = f"https://api.github.com/repos/{repo}/actions/jobs/{job_id}/logs"
cmd = [
    "curl", "-sSL",
    "-H", f"Authorization: token {token}",
    "-H", "Accept: application/vnd.github+json",
    "-H", "User-Agent: dump-logs",
    url,
]
text = subprocess.check_output(cmd).decode("utf-8", errors="replace")
print(text[-8000:] if len(text) > 8000 else text)

