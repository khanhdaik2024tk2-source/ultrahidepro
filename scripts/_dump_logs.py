"""scripts/_dump_logs.py — fetch failing job logs via curl, keep ANSI."""
import os
import subprocess
import sys

if len(sys.argv) < 3:
    print("usage: _dump_logs.py OWNER/REPO JOB_ID")
    sys.exit(1)

repo, job_id = sys.argv[1], sys.argv[2]
token = open(os.path.join(os.path.dirname(__file__), '.token')).read().strip()
url = f"https://api.github.com/repos/{repo}/actions/jobs/{job_id}/logs"
cmd = [
    "curl", "-sSL",
    "-H", f"Authorization: token {token}",
    "-H", "Accept: application/vnd.github+json",
    "-H", "User-Agent: dump-logs",
    url,
]
text = subprocess.check_output(cmd).decode("utf-8", errors="replace")
# Strip ANSI escapes for readability.
import re
ansi = re.compile(r'\x1b\[[0-9;]*[A-Za-z]')
text = ansi.sub('', text)
print(text[-6000:])
