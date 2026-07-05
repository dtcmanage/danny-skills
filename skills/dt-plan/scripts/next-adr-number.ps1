# Given an ADR directory, scan existing ADR filenames and return the next
# ADR number as JSON: { next_number, existing_count }.
#
# Matches both "ADR-<digits>*" and the dt-plan on-disk convention
# "<digits>-<kebab-title>.md" (a leading number). A missing or empty
# directory means no ADRs yet: next_number = 1, existing_count = 0.

param(
    [Parameter(Mandatory)]
    [string]$Dir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$regex = [regex]::new('^(?:ADR-)?(\d+)', 'IgnoreCase')

$numbers = @()
if (Test-Path -LiteralPath $Dir) {
    foreach ($file in Get-ChildItem -LiteralPath $Dir -File) {
        $match = $regex.Match($file.Name)
        if ($match.Success) {
            $numbers += [int]$match.Groups[1].Value
        }
    }
}

$nextNumber = if ($numbers.Count -eq 0) { 1 } else { [int](($numbers | Measure-Object -Maximum).Maximum) + 1 }

[pscustomobject]@{
    next_number = $nextNumber
    existing_count = $numbers.Count
} | ConvertTo-Json
