"""scripts/_dump_steps.py — dump per-step conclusion for a run."""
import json
import os
import subprocess
import sys

if len(sys.argv) < 3:
    print("usage: _dump_steps.py OWNER/REPO RUN_ID")
    sys.exit(1)

repo, run_id = sys.argv[1], sys.argv[2]
token = open(os.path.join(os.path.dirname(__file__), '.token')).read().strip()
headers = [
    "-H", f"Authorization: token {token}",
    "-H", "Accept: application/vnd.github+json",
    "-H", "User-Agent: dump-steps",
]
out = subprocess.check_output(
    ["gh", "api", f"repos/{repo}/actions/runs/{run_id}/jobs", *headers],
    text=True,
)
data = json.loads(out)
for j in data["jobs"]:
    print(f"\n== {j['name']} (conclusion={j['conclusion']}) ==")
    for s in j.get("steps") or []:
        print(f"  [{s.get('conclusion','?')}] {s.get('name','?')} (#{s.get('number')})")
