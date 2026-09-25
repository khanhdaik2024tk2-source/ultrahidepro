# scripts/PUSH_TO_GITHUB.md — how to push this local repo to GitHub.

Local repo is at: `c:\Users\Admin\lol`
Branch: `main`
Commits ready:
  - `d4eccab ci: bootstrap UltraHide Pro v1.0.0 tree`
  - `be08f12 ci: add offline static check + GitHub bootstrap scripts`

## Option A — using `gh` CLI (recommended)

1. Install GitHub CLI:   winget install --id GitHub.cli
2. Login:                gh auth login --web
3. Run (creates a private repo `ultrahidepro` under your account):
   ```
   pwsh scripts/setup_github.ps1 -Owner <your-gh-login> -Repo ultrahidepro -Push -RunCi
   ```

## Option B — using a Personal Access Token (PAT)

1. Create a PAT at https://github.com/settings/tokens with `repo` scope.
2. Set the env var (PowerShell):
   ```
   $env:UH_GH_TOKEN = "ghp_xxx..."
   ```
3. Push via the bash script:
   ```
   bash scripts/setup_github.sh --owner <your-gh-login> --repo ultrahidepro --public=false --push --run-ci
   ```

## After pushing

CI will run two jobs on the remote:

* `offline_check` — fast static validation on ubuntu-22.04
* `verify` — full Theos build on macos-14 (downloads iOS 18.6 SDK, runs `make package`, inspects .deb)
* `lint` — clang static analysis on macos-14
* `plist_json` / `sources_count` / `shellcheck` — lint.yml jobs

You can monitor from your terminal:
```
gh run list
gh run watch
gh run view <run-id> --log
```

## Local pre-flight (no remote)

```
python scripts/ci_offline_check.py
bash scripts/ci_offline_check.sh
```

Both should print `ALL OFFLINE CHECKS PASSED`.
