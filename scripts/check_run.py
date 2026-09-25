import urllib.request
import json
import time
import sys

import os

TOKEN_PATH = os.path.join(os.path.dirname(__file__), ".token")
if os.path.exists(TOKEN_PATH):
    with open(TOKEN_PATH, "r") as f:
        TOKEN = f.read().strip()
else:
    TOKEN = os.environ.get("GITHUB_TOKEN", "")
REPO = "khanhdaik2024tk2-source/ultrahidepro"

def get_runs():
    req = urllib.request.Request(
        f"https://api.github.com/repos/{REPO}/actions/runs?per_page=5",
        headers={
            "Authorization": f"token {TOKEN}",
            "Accept": "application/vnd.github.v3+json",
            "User-Agent": "CI-Monitor"
        }
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode())

runs = get_runs()
for r in runs.get("workflow_runs", []):
    print(f"Run ID: {r['id']} | {r['name']} | Status: {r['status']} | Conclusion: {r['conclusion']} | SHA: {r['head_sha'][:7]}")
