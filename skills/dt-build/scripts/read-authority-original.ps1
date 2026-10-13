#Requires -Version 7.0
param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)][string]$BuildStatePath, [Parameter(Mandatory)][string]$Path, [switch]$BootstrapFallback)
. (Join-Path $PSScriptRoot 'authority-digest.ps1')
$resolved = [IO.Path]::GetFullPath($Path)
$records = @(Get-AuthorityInventory -RunFolder $RunFolder -BuildStatePath $BuildStatePath)
$isCheckpoint = $resolved -eq [IO.Path]::GetFullPath($BuildStatePath)
if (-not $isCheckpoint -and $resolved -notin @($records.path)) { throw "AUTHORITY_UNCOVERED: $resolved" }
if (-not $BootstrapFallback) {
    # Verify immediately before reading. Any changed original stops the action; re-bootstrap
    # from originals (or rebuild via scripts) rather than acting on stale authority.
    $verification = & (Join-Path $PSScriptRoot 'verify-authority-digest.ps1') -RunFolder $RunFolder -BuildStatePath $BuildStatePath | ConvertFrom-Json
}
$bytes = [IO.File]::ReadAllBytes($resolved)
if (-not $BootstrapFallback) {
    if ($isCheckpoint) {
        $manifestBytes = [IO.File]::ReadAllBytes((Join-Path $RunFolder 'authority-digest.json'))
        $manifestHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($manifestBytes)).ToLowerInvariant()
        if ($manifestHash -cne $verification.manifest_sha256) { throw 'AUTHORITY_MANIFEST_HASH: manifest changed during read' }
        $manifest = [Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json
        if ((Get-AuthorityCheckpointHash ([Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF))) -cne $manifest.checkpoint_authority_sha256) { throw 'AUTHORITY_CHECKPOINT_HASH: checkpoint changed during read' }
    } else {
    $expected = @($records | Where-Object path -eq $resolved)[0]
    $actual = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if ($actual -cne $expected.sha256 -or $bytes.Length -ne $expected.bytes) { throw "AUTHORITY_ORIGINAL_HASH: $resolved changed during read" }
    }
}
# Emit the same snapshot just checked, avoiding a verify/read race.
[Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
