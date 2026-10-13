#Requires -Version 7.0
param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)][string]$BuildStatePath, [string]$DigestDirectory)
. (Join-Path $PSScriptRoot 'authority-digest.ps1')
$destination = if ($DigestDirectory) { $DigestDirectory } else { $RunFolder }
$jsonPath = Join-Path $destination 'authority-digest.json'
$mdPath = Join-Path $destination 'authority-digest.md'
$manifestBytes = [IO.File]::ReadAllBytes($jsonPath)
$manifestHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($manifestBytes)).ToLowerInvariant()
if ($manifestHash -cne [IO.File]::ReadAllText("$jsonPath.sha256").Trim()) { throw 'AUTHORITY_MANIFEST_HASH: manifest changed' }
$manifest = [Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json
if ($manifest.schema_version -ne 1 -or $manifest.producer -ne 'deterministic' -or $manifest.budget_chars -ne $script:AuthorityReadBudgetChars -or -not $manifest.PSObject.Properties['ceiling_chars'] -or $manifest.ceiling_chars -ne $script:AuthorityReadCeilingChars -or $manifest.checkpoint -cne [IO.Path]::GetFullPath($BuildStatePath)) { throw 'AUTHORITY_MANIFEST_INVALID' }
if ((Get-AuthorityCheckpointHash ([IO.File]::ReadAllText($BuildStatePath))) -cne $manifest.checkpoint_authority_sha256) { throw 'AUTHORITY_CHECKPOINT_HASH: checkpoint authority changed' }
if ((Get-AuthorityHash $mdPath) -cne $manifest.markdown_sha256) { throw 'AUTHORITY_DIGEST_HASH: digest changed' }
$records = @(Get-AuthorityInventory -RunFolder $RunFolder -BuildStatePath $BuildStatePath)
if (($script:AuthorityEnumeratedPaths -join "`n") -cne (@($manifest.enumerated_paths) -join "`n") -or
    (ConvertTo-Json -InputObject @($script:AuthorityDiagnostics) -Depth 8 -Compress) -cne (ConvertTo-Json -InputObject @($manifest.diagnostics) -Depth 8 -Compress)) { throw 'AUTHORITY_DISCOVERY: enumeration or diagnostics changed' }
foreach ($record in $records) {
    $pinned = @($manifest.originals | Where-Object { $_.path -ceq $record.path })
    if ($pinned.Count -ne 1) { throw "AUTHORITY_UNCOVERED: $($record.path)" }
    if ($pinned[0].sha256 -cne $record.sha256 -or $pinned[0].bytes -ne $record.bytes -or $pinned[0].chars -ne $record.chars -or $pinned[0].kind -cne $record.kind -or $pinned[0].extract -cne $record.extract) { throw "AUTHORITY_ORIGINAL_HASH: $($record.path)" }
}
if ($records.Count -ne @($manifest.originals).Count) { throw 'AUTHORITY_COVERAGE: inventory changed' }
$publishedMarkdown = [IO.File]::ReadAllText($mdPath)
$expectedMarkdown = Get-AuthorityMarkdown -RunFolder $RunFolder -Records $records -BuildStatePath $BuildStatePath
# Owned status/cursor changes may cross the soft target after publication. Both
# fixed-width headers are mechanical; only that warning state may differ.
$normalHeader = Get-AuthorityBudgetHeader -OverTarget $false
$warningHeader = Get-AuthorityBudgetHeader -OverTarget $true
$title = "# Authority digest`n"
$bodyOffset = $title.Length + $normalHeader.Length
if ((-not $publishedMarkdown.StartsWith($title + $normalHeader, [StringComparison]::Ordinal) -and
     -not $publishedMarkdown.StartsWith($title + $warningHeader, [StringComparison]::Ordinal)) -or
    $publishedMarkdown.Substring($bodyOffset) -cne $expectedMarkdown.Substring($bodyOffset)) { throw 'AUTHORITY_DIGEST_CONTENT: index differs from deterministic original extracts' }
$mandatory = @(Get-AuthorityMandatoryPaths -Records $records -BuildStatePath $BuildStatePath)
if (($mandatory -join "`n") -cne (@($manifest.mandatory_paths) -join "`n")) { throw 'AUTHORITY_MANDATORY: current authority changed' }
$checkpointChars = [IO.File]::ReadAllText($BuildStatePath).Length
$total = $checkpointChars
if ($records.Count) { $total += [long]($records | Measure-Object chars -Sum).Sum }
$bootstrapChars = [IO.File]::ReadAllText($mdPath).Length + $checkpointChars
foreach ($record in $records) { if ($record.path -in $mandatory) { $bootstrapChars += $record.chars } }
$useDigest = $total -gt $script:AuthorityReadBudgetChars -or (Test-Path -LiteralPath (Join-Path $RunFolder 'context-wall.json'))
if ($useDigest -and $bootstrapChars -gt $script:AuthorityReadCeilingChars) { throw "AUTHORITY_BOOTSTRAP_BUDGET: digest plus current authority is $bootstrapChars chars, above the $script:AuthorityReadCeilingChars-character hard ceiling (target $script:AuthorityReadBudgetChars). Operator: consolidate or supersede old stop records, then rebuild and verify; never omit mandatory current authority." }
$budgetState = if ($useDigest -and $bootstrapChars -gt $script:AuthorityReadBudgetChars) { 'over_target' } else { 'within_target' }
$mandatoryBytes = (Get-Item -LiteralPath $BuildStatePath).Length
foreach ($record in $records) { if ($record.path -in $mandatory) { $mandatoryBytes += $record.bytes } }
$deferred = @($records | Where-Object { $_.path -notin $mandatory })
$deferredBytes = if ($deferred.Count) { [long]($deferred | Measure-Object bytes -Sum).Sum } else { 0 }
[ordered]@{ verified = $true; mode = $(if ($useDigest) { 'digest' } else { 'originals' }); budget_state = $budgetState; originals_discovered = $records.Count; enumerated_originals = $script:AuthorityEnumeratedPaths.Count; unresolved_candidates = @($script:AuthorityDiagnostics); markdown_chars = [IO.File]::ReadAllText($mdPath).Length; authority_chars = $total; bootstrap_chars = $bootstrapChars; budget_chars = $script:AuthorityReadBudgetChars; ceiling_chars = $script:AuthorityReadCeilingChars; deferred_original_bytes = $deferredBytes; mandatory_full_read_bytes = $mandatoryBytes; manifest_sha256 = $manifestHash; digest_path = $mdPath; mandatory_paths = $mandatory } | ConvertTo-Json -Depth 5 -Compress
