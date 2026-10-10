#Requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$RunId,
    [string]$ChunkId,
    [switch]$Json
)

# validate-continuation.ps1
# -------------------------
# Validates a worker's continuation record (contract in report-contract.ps1): the first ```json block
# must hold every field with the right type, and match -RunId/-ChunkId when given. Exits 0 when valid,
# 1 otherwise; prints each error, or with -Json one result object.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'report-contract.ps1')

$checked = Get-DtContinuationRecord -Path $Path -RunId $RunId -ChunkId $ChunkId
$valid = (@($checked.errors).Count -eq 0)
if ($Json) {
    [pscustomobject][ordered]@{ path = $Path; valid = $valid; errors = @($checked.errors) } | ConvertTo-Json -Depth 4 -Compress
}
elseif ($valid) { Write-Output "VALID: $Path" }
else { foreach ($problem in $checked.errors) { Write-Output "INVALID: $problem" } }
if ($valid) { exit 0 } else { exit 1 }
