Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Temporary = Join-Path ([System.IO.Path]::GetTempPath()) ('fs66-preflight-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $Temporary | Out-Null
try {
    $Requirements = Join-Path $Temporary 'requirements.txt'
    'fs66-nonexistent-package==0.0.0' | Set-Content -LiteralPath $Requirements
    $Output = & pwsh -NoProfile -File (Join-Path $Root 'scripts/test-preflight.ps1') -RequirementsPath $Requirements 2>&1
    $Code = $LASTEXITCODE
    $Expected = "fs66-nonexistent-package missing or cannot import; fix: python -m pip install --user -r `"$Requirements`""
    if ($Code -ne 1) { throw "Expected exit 1, got $Code" }
    if ($Expected -notin $Output) { throw "Expected fix line absent: $($Output -join [Environment]::NewLine)" }
    Write-Output 'PASS: missing module exits 1 with the exact fix command.'
} finally {
    # Only known fixture files are removed; no recursive directory deletion.
    Remove-Item -LiteralPath $Requirements -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $Temporary
}
