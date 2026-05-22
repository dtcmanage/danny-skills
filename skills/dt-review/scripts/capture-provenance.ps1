param(
    [Parameter(Mandatory)]
    [string]$PromptPath,
    [Parameter(Mandatory)]
    [string]$CanonicalPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $PromptPath)) {
    throw "Prompt path not found: $PromptPath"
}

if (-not (Test-Path -LiteralPath $CanonicalPath)) {
    throw "Canonical path not found: $CanonicalPath"
}

$sha = (Get-FileHash -LiteralPath $PromptPath -Algorithm SHA256).Hash.ToUpperInvariant()
$timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$cwd = (Get-Location).Path

[pscustomobject]@{
    ts = $timestamp
    pwd = $cwd
    canonical = $CanonicalPath
    prompt_sha256 = $sha
} | ConvertTo-Json -Compress
