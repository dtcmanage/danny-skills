param(
    [Parameter(Mandatory)]
    [string]$Path,

    [Parameter(Mandatory)]
    [string]$Content
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$directory = Split-Path -Parent $Path
if (-not [string]::IsNullOrWhiteSpace($directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

$tempPath = "$Path.tmp"
[System.IO.File]::WriteAllText($tempPath, $Content, [System.Text.UTF8Encoding]::new($false))
Move-Item -LiteralPath $tempPath -Destination $Path -Force

Write-Output (Resolve-Path -LiteralPath $Path).Path
