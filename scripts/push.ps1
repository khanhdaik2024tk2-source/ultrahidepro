#!/usr/bin/env pwsh
# scripts/push.ps1 — non-interactive push to GitHub using a token file.
# Usage:
#   1) Create a GitHub PAT at https://github.com/settings/tokens (scope: repo).
#   2) Save it to scripts/.token (this file is git-ignored).
#   3) Run:  pwsh scripts/push.ps1 -Owner <your-gh-login> -Repo ultrahidepro [-Public]
#
# What it does:
#   * Verifies token has 'repo' scope (via REST /user).
#   * Creates the repo (private by default) if it doesn't exist.
#   * Pushes branch `main`.
#   * Dispatches workflow_dispatch on `build.yml`.
#   * Polls the resulting run until completion.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Owner,
    [Parameter(Mandatory)] [string] $Repo,
    [switch]   $Public,
    [string]   $Branch = 'main',
    [string]   $TokenFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $TokenFile) {
    if ($PSScriptRoot) {
        $TokenFile = Join-Path $PSScriptRoot '.token'
    } else {
        $here = Split-Path -Parent $MyInvocation.MyCommand.Path
        $TokenFile = Join-Path $here '.token'
    }
}

if (-not (Test-Path $TokenFile)) {
    Write-Error "Token file not found: $TokenFile. Create it with: Set-Content -Path '$TokenFile' -Value '<ghp_xxx>'"
}
$token = (Get-Content -Raw $TokenFile).Trim()
if (-not $token.StartsWith('ghp_') -and -not $token.StartsWith('github_pat_')) {
    Write-Warning "Token doesn't look like a classic/fine-grained PAT. Continuing anyway."
}

function Get-AuthHeaders {
    return @{
        'Authorization'        = "token $token"
        'Accept'               = 'application/vnd.github+json'
        'User-Agent'           = 'ultrahidepro-push'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
}

function Test-RepoExists {
    $url = "https://api.github.com/repos/$Owner/$Repo"
    try {
        $r = Invoke-RestMethod -Method Get -Uri $url -Headers (Get-AuthHeaders)
        return $true
    } catch {
        return $false
    }
}

function New-Repo {
    $payload = [ordered]@{}
    $payload['name']        = $Repo
    $payload['description'] = 'UltraHide Pro - jailbreak-detection bypass for Dopamine 3.0.9 + iOS 18.6.2'
    $payload['private']     = -not $Public
    $payload['auto_init']   = $false
    $body = $payload | ConvertTo-Json -Compress -Depth 5
    $url  = 'https://api.github.com/user/repos'
    Write-Host "[push] POST $url  body=$body"
    Invoke-RestMethod -Method Post -Uri $url -Headers (Get-AuthHeaders) -Body $body -ContentType 'application/json' | Out-Null
    Write-Host "[push] created $Owner/$Repo (public=$Public)"
}

function Push-Branch {
    $remote = "https://x-access-token:$token@github.com/$Owner/$Repo.git"
    # Tolerate missing remote — only suppress stderr, not the exception text.
    try {
        $rc = & git remote remove origin 2>&1
    } catch {
        Write-Host "[push] (no existing origin to remove)"
    }
    & git remote add origin $remote
    if ($LASTEXITCODE -ne 0) { throw "git remote add failed" }
    & git push --set-upstream origin $Branch
    if ($LASTEXITCODE -ne 0) { throw "git push failed" }
}

function Invoke-DispatchCi {
    $url  = "https://api.github.com/repos/$Owner/$Repo/actions/workflows/build.yml/dispatches"
    $body = (@{ ref = $Branch } | ConvertTo-Json -Compress)
    Invoke-RestMethod -Method Post -Uri $url -Headers (Get-AuthHeaders) -Body $body -ContentType 'application/json' | Out-Null
    Write-Host "[push] dispatched build.yml on $Branch"
}

function Watch-Run {
    $url = "https://api.github.com/repos/$Owner/$Repo/actions/runs?per_page=1"
    $deadline = (Get-Date).AddMinutes(60)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 10
        $run = Invoke-RestMethod -Method Get -Uri $url -Headers (Get-AuthHeaders)
        if ($run.workflow_runs.Count -gt 0) {
            $r = $run.workflow_runs[0]
            $ts = $r.created_at
            Write-Host ("[push] run id={0} status={1} conclusion={2} url={3}" -f $r.id, $r.status, $r.conclusion, $r.html_url)
            if ($r.status -eq 'completed') {
                Write-Host "[push] CI completed: $($r.conclusion)"
                Write-Host "[push] full log: $($r.html_url)"
                return $r.conclusion -eq 'success'
            }
        }
    }
    Write-Warning "[push] timed out waiting for run"
    return $false
}

# --- main -------------------------------------------------------------------

Write-Host "[push] verifying token via /user"
$me = Invoke-RestMethod -Method Get -Uri 'https://api.github.com/user' -Headers (Get-AuthHeaders)
Write-Host "[push] authenticated as $($me.login) (id=$($me.id))"
if ($me.login -ne $Owner) {
    Write-Warning "Owner ($Owner) differs from authenticated user ($($me.login)). Continuing."
}

if (-not (Test-RepoExists)) {
    New-Repo
} else {
    Write-Host "[push] repo $Owner/$Repo already exists"
}

Push-Branch
Invoke-DispatchCi
$ok = Watch-Run
if ($ok) {
    Write-Host "[push] SUCCESS"
    exit 0
} else {
    Write-Host "[push] FAILED"
    exit 1
}
