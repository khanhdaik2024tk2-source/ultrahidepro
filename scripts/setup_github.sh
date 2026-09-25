#!/usr/bin/env bash
# scripts/setup_github.sh — bootstrap a GitHub repo and push the source
# tree so CI workflows under .github/ run end-to-end.
#
# Usage:
#   UH_GH_TOKEN=<PAT> bash scripts/setup_github.sh \
#     --owner OWNER --repo ultrahidepro [--public] [--push] [--run-ci]
#
# Requires:
#   * git
#   * curl
#   * Either 'gh' CLI authenticated, or $UH_GH_TOKEN with 'repo' scope.

set -euo pipefail

OWNER=""
REPO=""
PUBLIC=0
PUSH=0
RUN_CI=0
BRANCH="${BRANCH:-master}"

usage() {
    cat <<'USAGE'
Usage: UH_GH_TOKEN=<PAT> bash scripts/setup_github.sh --owner OWNER --repo NAME [--public] [--push] [--run-ci]
USAGE
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --owner) OWNER="$2"; shift 2 ;;
        --repo)  REPO="$2";  shift 2 ;;
        --public) PUBLIC=1; shift ;;
        --push)  PUSH=1; shift ;;
        --run-ci) RUN_CI=1; shift ;;
        --branch) BRANCH="$2"; shift 2 ;;
        *) usage ;;
    esac
done

[[ -z "$OWNER" || -z "$REPO" ]] && usage

command -v git >/dev/null || { echo "git missing"; exit 1; }
command -v curl >/dev/null || { echo "curl missing"; exit 1; }

token() {
    if [[ -n "${UH_GH_TOKEN:-}" ]]; then
        echo "$UH_GH_TOKEN"
        return
    fi
    if command -v gh >/dev/null; then
        gh auth token 2>/dev/null && return
    fi
    echo "no credential" >&2
    exit 2
}

api() {
    local method="$1"; shift
    local url="$1";    shift
    local body="${1:-}"
    curl -sS -X "$method" \
        -H "Authorization: token $1" \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: ultrahidepro-setup" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        ${body:+--data "$body"} \
        "$url" >/dev/null
}

init_repo() {
    if [[ ! -d .git ]]; then
        echo "[setup] git init"
        git init -q -b "$BRANCH"
    fi
    git config user.name  "UltraHide Pro Bot"
    git config user.email "bot@ultrahidepro.local"
    [[ -f .gitignore ]] || { echo ".gitignore missing"; exit 1; }
}

commit() {
    git add -A
    if ! git diff --cached --quiet; then
        echo "[setup] committing"
        git commit -q -m "ci: bootstrap UltraHide Pro tree"
    else
        echo "[setup] nothing to commit"
    fi
}

create_remote_repo() {
    local token="$1" private="true"
    if [[ "$PUBLIC" -eq 1 ]]; then private="false"; fi
    echo "[setup] creating repo $OWNER/$REPO (public=$PUBLIC)"
    curl -sS -X POST \
        -H "Authorization: token $token" \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: ultrahidepro-setup" \
        --data "{\"name\":\"$REPO\",\"private\":$private,\"auto_init\":false,\"description\":\"UltraHide Pro - pro-grade jailbreak detection bypass for Dopamine 3.0.9 + iOS 18.6.2\"}" \
        "https://api.github.com/user/repos" >/dev/null
}

confirm_remote_repo() {
    local token="$1" code
    code=$(curl -sS -o /dev/null -w "%{http_code}" \
        -H "Authorization: token $token" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$OWNER/$REPO")
    [[ "$code" == "200" ]]
}

push() {
    local token="$1" remote
    remote="https://x-access-token:$token@github.com/$OWNER/$REPO.git"
    git remote remove origin 2>/dev/null || true
    git remote add origin "$remote"
    echo "[setup] pushing $BRANCH -> origin"
    git push --set-upstream origin "$BRANCH"
}

dispatch_ci() {
    local token="$1" body
    body=$(printf '{"ref":"%s"}' "$BRANCH")
    echo "[setup] dispatching build.yml"
    curl -sS -X POST \
        -H "Authorization: token $token" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        --data "$body" \
        "https://api.github.com/repos/$OWNER/$REPO/actions/workflows/build.yml/dispatches" >/dev/null
    sleep 5
    curl -sS -H "Authorization: token $token" \
        "https://api.github.com/repos/$OWNER/$REPO/actions/runs?per_page=1" \
        | grep -m1 '"html_url"' | head -c 200
    echo
}

main() {
    init_repo
    commit
    if [[ "$PUSH" -eq 1 ]]; then
        local tk; tk=$(token)
        if ! confirm_remote_repo "$tk"; then
            create_remote_repo "$tk"
        fi
        push "$tk"
        if [[ "$RUN_CI" -eq 1 ]]; then
            dispatch_ci "$tk"
        fi
    fi
}

main
