#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Validate and append one acceptance row to <run-folder>/acceptance-rows.jsonl,
    or audit an existing file read-only.
.DESCRIPTION
    The file is append-only: existing lines are never rewritten. A row that fails
    the schema in references/acceptance-contract.md is refused (exit 1) and nothing
    is written. -Audit reports each line's schema state (current / legacy /
    invalid) and never writes.
.EXAMPLE
    pwsh -NoProfile -File append-acceptance-row.ps1 -RunFolder <run> -RowPath <row.json> -Json
    pwsh -NoProfile -File append-acceptance-row.ps1 -RunFolder <run> -Audit -Json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RunFolder,
    [string]$RowPath,
    [string]$RowJson,
    [switch]$Audit,
    [switch]$Json
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'acceptance-row-schema.ps1')
$target = Join-Path $RunFolder 'acceptance-rows.jsonl'

function Out-Result($Object, [int]$Code) {
    if ($Json) { $Object | ConvertTo-Json -Depth 8 } else { $Object | Format-List | Out-String | Write-Output }
    exit $Code
}

if ($Audit) {
    $lines = @()
    if (Test-Path -LiteralPath $target) {
        $n = 0
        foreach ($line in [IO.File]::ReadAllLines($target)) {
            $n++
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $row = $line | ConvertFrom-Json -Depth 40 -DateKind String } catch { $lines += [pscustomobject]@{ line = $n; state = 'invalid'; errors = @('invalid JSON') }; continue }
            $errs = @(Get-AcceptanceRowSchemaErrors $row)
            $state = if (Test-AcceptanceRowLegacy $row) { 'legacy' } elseif ($errs.Count) { 'invalid' } else { 'current' }
            $lines += [pscustomobject]@{ line = $n; milestone_id = (Get-AcceptanceRowValue $row 'milestone_id'); dispatch_id = (Get-AcceptanceRowValue $row 'dispatch_id'); state = $state; errors = $errs }
        }
    }
    Out-Result ([pscustomobject]@{ path = $target; rows = $lines }) 0
}

if ([bool]$RowPath -eq [bool]$RowJson) { Write-Error 'Pass exactly one of -RowPath or -RowJson (or -Audit).'; exit 2 }
$raw = if ($RowPath) { Get-Content -LiteralPath $RowPath -Raw } else { $RowJson }
try { $row = $raw | ConvertFrom-Json -Depth 40 -DateKind String } catch { Out-Result ([pscustomobject]@{ appended = $false; errors = @('invalid JSON: ' + $_.Exception.Message) }) 1 }
$errors = @(Get-AcceptanceRowSchemaErrors $row)
if ($errors.Count) { Out-Result ([pscustomobject]@{ appended = $false; errors = $errors }) 1 }
if (-not (Test-Path -LiteralPath $RunFolder -PathType Container)) { Write-Error "Run folder not found: $RunFolder"; exit 2 }
$compact = $row | ConvertTo-Json -Depth 40 -Compress
$prefix = ''
if ((Test-Path -LiteralPath $target) -and (Get-Item -LiteralPath $target).Length -gt 0) {
    $bytes = [IO.File]::ReadAllBytes($target)
    if ($bytes[-1] -ne 10) { $prefix = "`n" }
}
[IO.File]::AppendAllText($target, $prefix + $compact + "`n")
Out-Result ([pscustomobject]@{ appended = $true; path = $target; milestone_id = $row.milestone_id; dispatch_id = (Get-AcceptanceRowValue $row 'dispatch_id') }) 0
