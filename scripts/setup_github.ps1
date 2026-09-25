#!/usr/bin/env pwsh
# scripts/setup_github.ps1 — local helper to bootstrap a GitHub repo and
# push the UltraHide Pro source tree so CI (workflows under .github/)
# runs end-to-end.
#
# Requires:
#   * PowerShell 7+ on Windows / Linux / macOS
#   * Network access to github.com
#   * Either: 'gh' CLI authenticated, OR a Personal Access Token (PAT)
#     exported as $env:UH_GH_TOKEN with `repo` scope.
#
# Usage:
#   pwsh scripts/setup_github.ps1 -Owner 'OWNER' -Repo 'ultrahidepro' `
#         [-Public] [-Push] [-RunCi]
#
# What it does:
#   1) `git init` if missing, config user.name/user.email from args.
#   2) Stage every file (Makefile, Tweak.x, Sources/, Resources/, scripts/,
#      .github/, LICENSE, README, AUDIT_REPORT.md, etc.).
#   3) Create repo on GitHub via gh / REST API.
#   4) Push branch `master` with --set-upstream.
#   5) Optionally trigger the 'verify' workflow via workflow_dispatch and
#      tail logs.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Owner,
    [Parameter(Mandatory)] [string] $Repo,
    [switch] $Public,
    [switch] $Push,
    [switch] $RunCi,
    [string] $UserName  = 'UltraHide Pro Bot',
    [string] $UserEmail = 'bot@ultrahidepro.local',
    [string] $Branch    = 'master'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-Git() {
    $g = Get-Command git -ErrorAction SilentlyContinue
    if (-not $g) {
        throw "git is required. Install via: winget install --id Git.Git ; or choco install git."
    }
    return $g
}

function Resolve-Tools() {
    $git = Resolve-Git
    $gh  = Get-Command gh  -ErrorAction SilentlyContinue
    Write-Host ("[setup] git={0} gh={1}" -f $git.Path, $(if ($gh) { $gh.Path } else { '(none)' }))
    return $git, $gh
}

function Test-Token() {
    if ($env:UH_GH_TOKEN) { return $env:UH_GH_TOKEN }
    if ($gh) {
        try {
            gh auth token 2>$null | Out-Null
            return (gh auth token 2>$null | Select-Object -First 1)
        } catch {
            Write-Warning "[setup] gh auth token not available"
        }
    }
    throw "No GitHub credential. Export UH_GH_TOKEN=<PAT> with 'repo' scope, or run 'gh auth login'."
}

function New-RemoteRepo {
    param([string] $token, [string] $owner, [string] $repo, [bool] $public)
    $headers = @{
        'Authorization' = "token $token"
        'Accept'        = 'application/vnd.github+json'
        'User-Agent'    = 'ultrahidepro-setup'
    }
    $body = @{
        name        = $repo
        description = 'UltraHide Pro — pro-grade jailbreak-detection bypass for Dopamine 3.0.9 + iOS 18.6.2'
        @($true) ? { homepage = 'https://github.com/' + $owner + '/' + $repo } | Out-Null
        private     = -not $public
        auto_init   = $false
    } | ConvertTo-Json
    $url = "https://api.github.com/user/repos"
    Write-Host "[setup] creating repo $owner/$repo (public=$public)"
    Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body | Out-Null
}

function Confirm-Repo {
    param([string] $token, [string] $owner, [string] $repo)
    $headers = @{
        'Authorization' = "token $token"
        'Accept'        = 'application/vnd.github+json'
        'User-Agent'    = 'ultrahidepro-setup'
    }
    $url = "https://api.github.com/repos/$owner/$repo"
    try {
        Invoke-RestMethod -Method Get -Uri $url -Headers $headers | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Invoke-Push {
    param([string] $token, [string] $owner, [string] $repo, [string] $branch)
    $remote = "https://x-access-token:$token@github.com/$owner/$repo.git"
    git remote remove origin 2>$null
    git remote add origin $remote
    Write-Host "[setup] pushing $branch -> origin"
    git push --set-upstream origin $branch 2>&1 | Tee-Object -Variable out
    if ($LASTEXITCODE -ne 0) { throw "git push failed: $out" }
}

function Invoke-RunCi {
    param([string] $token, [string] $owner, [string] $repo, [string] $branch)
    $headers = @{
        'Authorization'        = "token $token"
        'Accept'               = 'application/vnd.github+json'
        'User-Agent'           = 'ultrahidepro-setup'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $url = "https://api.github.com/repos/$owner/$repo/actions/workflows/build.yml/dispatches"
    $body = @{ ref = $branch } | ConvertTo-Json
    Write-Host "[setup] dispatching workflow_dispatch on $branch"
    Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body | Out-Null
    Start-Sleep -Seconds 5
    $runsUrl = "https://api.github.com/repos/$owner/$repo/actions/runs?per_page=1"
    $run = Invoke-RestMethod -Method Get -Uri $runsUrl -Headers $headers
    if ($run.workflow_runs.Count -gt 0) {
        $html = $run.workflow_runs[0].html_url
        Write-Host "[setup] live run: $html"
    }
}

# --- main --------------------------------------------------------------------

Write-Host "[setup] resolving tools"
$git, $gh = Resolve-Tools

if (-not (Test-Path .git)) {
    Write-Host "[setup] git init"
    git init -q -b $Branch
}

git config user.name  $UserName
git config user.email $UserEmail

# Ensure .gitignore covers build artifacts.
if (-not (Test-Path .gitignore)) {
    throw ".gitignore missing — required for Theos builds."
}

Write-Host "[setup] staging"
git add -A
git status --short | Select-Object -First 30

if (-not (git diff --cached --quiet)) {
    $msg = "ci: bootstrap UltraHide Pro tree"
    git commit -q -m $msg
    Write-Host "[setup] committed: $msg"
} else {
    Write-Host "[setup] nothing to commit"
}

if ($Push) {
    $token = Test-Token
    if (-not (Confirm-Repo -token $token -owner $Owner -repo $Repo)) {
        New-RemoteRepo -token $token -owner $Owner -repo $Repo -public:$Public
    }
    Invoke-Push -token $token -owner $Owner -repo $Repo -branch $Branch
    if ($RunCi) {
        Invoke-RunCi -token $token -owner $Owner -repo $Repo -branch $Branch
    }
}

Write-Host "[setup] done"
