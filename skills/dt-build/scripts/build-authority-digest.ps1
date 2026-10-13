#Requires -Version 7.0
param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)][string]$BuildStatePath, [switch]$DryRun, [string]$OutputDirectory)
. (Join-Path $PSScriptRoot 'authority-digest.ps1')
function Get-AuthorityPhysicalDirectory([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    if (-not $parent) { return $full }
    $physical = Join-Path (Get-AuthorityPhysicalDirectory $parent) (Split-Path -Leaf $full)
    if (Test-Path -LiteralPath $physical) {
        $item = Get-Item -LiteralPath $physical -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $item.ResolveLinkTarget($true).FullName }
    }
    return $physical
}
if ($DryRun -and -not $OutputDirectory) { throw 'AUTHORITY_DRYRUN_OUTPUT: supply an external OutputDirectory' }
$destination = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else { [IO.Path]::GetFullPath($RunFolder) }
if ($DryRun) {
    $physicalDestination = Get-AuthorityPhysicalDirectory $destination
    foreach ($protected in @([IO.Path]::GetFullPath($RunFolder), (Split-Path -Parent ([IO.Path]::GetFullPath($BuildStatePath))))) {
        $physicalProtected = Get-AuthorityPhysicalDirectory $protected
        if ($physicalDestination -eq $physicalProtected -or $physicalDestination.StartsWith($physicalProtected.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'AUTHORITY_DRYRUN_OUTPUT: output must be outside run and checkpoint directories' }
    }
}
[IO.Directory]::CreateDirectory($destination) | Out-Null
try { $records = @(Get-AuthorityInventory -RunFolder $RunFolder -BuildStatePath $BuildStatePath) }
catch {
    [IO.File]::WriteAllText((Join-Path $destination 'authority-diagnostics.json'), (ConvertTo-Json -InputObject @($script:AuthorityDiagnostics) -Depth 8), [Text.UTF8Encoding]::new($false))
    throw
}
$mandatory = @(Get-AuthorityMandatoryPaths -Records $records -BuildStatePath $BuildStatePath)
$markdown = Get-AuthorityMarkdown -RunFolder $RunFolder -Records $records -BuildStatePath $BuildStatePath
$mdPath = Join-Path $destination 'authority-digest.md'
$jsonPath = Join-Path $destination 'authority-digest.json'
[IO.File]::WriteAllText($mdPath, $markdown, [Text.UTF8Encoding]::new($false))
$manifest = [ordered]@{ schema_version = 1; producer = 'deterministic'; checkpoint = [IO.Path]::GetFullPath($BuildStatePath); checkpoint_authority_sha256 = Get-AuthorityCheckpointHash ([IO.File]::ReadAllText($BuildStatePath)); budget_chars = $script:AuthorityReadBudgetChars; mandatory_paths = $mandatory; markdown_sha256 = Get-AuthorityHash $mdPath; originals = $records; enumerated_paths = $script:AuthorityEnumeratedPaths; diagnostics = @($script:AuthorityDiagnostics) }
[IO.File]::WriteAllText($jsonPath, ($manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
# Publish the pin last. A partially written pair never verifies.
[IO.File]::WriteAllText("$jsonPath.sha256", (Get-AuthorityHash $jsonPath), [Text.UTF8Encoding]::new($false))
& (Join-Path $PSScriptRoot 'verify-authority-digest.ps1') -RunFolder $RunFolder -BuildStatePath $BuildStatePath -DigestDirectory $destination
