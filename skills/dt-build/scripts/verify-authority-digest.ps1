#Requires -Version 7.0
param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)][string]$BuildStatePath)
. (Join-Path $PSScriptRoot 'authority-digest.ps1')
$jsonPath = Join-Path $RunFolder 'authority-digest.json'
$mdPath = Join-Path $RunFolder 'authority-digest.md'
$manifestBytes = [IO.File]::ReadAllBytes($jsonPath)
$manifestHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($manifestBytes)).ToLowerInvariant()
if ($manifestHash -cne [IO.File]::ReadAllText("$jsonPath.sha256").Trim()) { throw 'AUTHORITY_MANIFEST_HASH: manifest changed' }
$manifest = [Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json
if ($manifest.schema_version -ne 1 -or $manifest.producer -ne 'deterministic' -or $manifest.budget_chars -ne $script:AuthorityReadBudgetChars -or $manifest.checkpoint -cne [IO.Path]::GetFullPath($BuildStatePath)) { throw 'AUTHORITY_MANIFEST_INVALID' }
if ((Get-AuthorityCheckpointHash ([IO.File]::ReadAllText($BuildStatePath))) -cne $manifest.checkpoint_authority_sha256) { throw 'AUTHORITY_CHECKPOINT_HASH: checkpoint authority changed' }
if ((Get-AuthorityHash $mdPath) -cne $manifest.markdown_sha256) { throw 'AUTHORITY_DIGEST_HASH: digest changed' }
$records = @(Get-AuthorityInventory -RunFolder $RunFolder -BuildStatePath $BuildStatePath)
foreach ($record in $records) {
    $pinned = @($manifest.originals | Where-Object { $_.path -ceq $record.path })
    if ($pinned.Count -ne 1) { throw "AUTHORITY_UNCOVERED: $($record.path)" }
    if ($pinned[0].sha256 -cne $record.sha256 -or $pinned[0].bytes -ne $record.bytes -or $pinned[0].kind -cne $record.kind -or $pinned[0].extract -cne $record.extract) { throw "AUTHORITY_ORIGINAL_HASH: $($record.path)" }
}
if ($records.Count -ne @($manifest.originals).Count) { throw 'AUTHORITY_COVERAGE: inventory changed' }
if ([IO.File]::ReadAllText($mdPath) -cne (Get-AuthorityMarkdown -RunFolder $RunFolder -Records $records -BuildStatePath $BuildStatePath)) { throw 'AUTHORITY_DIGEST_CONTENT: index differs from deterministic original extracts' }
$mandatory = @(Get-AuthorityMandatoryPaths -Records $records -BuildStatePath $BuildStatePath)
if (($mandatory -join "`n") -cne (@($manifest.mandatory_paths) -join "`n")) { throw 'AUTHORITY_MANDATORY: current authority changed' }
$checkpointChars = [IO.File]::ReadAllText($BuildStatePath).Length
$total = [long]($records | Measure-Object chars -Sum).Sum + $checkpointChars
$bootstrapChars = [IO.File]::ReadAllText($mdPath).Length + $checkpointChars
foreach ($record in $records) { if ($record.path -in $mandatory) { $bootstrapChars += $record.chars } }
$useDigest = $total -gt $script:AuthorityReadBudgetChars -or (Test-Path -LiteralPath (Join-Path $RunFolder 'context-wall.json'))
if ($useDigest -and $bootstrapChars -gt $script:AuthorityReadBudgetChars) { throw "AUTHORITY_BOOTSTRAP_BUDGET: digest plus current authority is $bootstrapChars chars; mechanical worker must compact inherited index; never omit mandatory originals" }
[ordered]@{ verified = $true; mode = $(if ($useDigest) { 'digest' } else { 'originals' }); authority_chars = $total; bootstrap_chars = $bootstrapChars; budget_chars = $script:AuthorityReadBudgetChars; manifest_sha256 = $manifestHash; digest_path = $mdPath; mandatory_paths = $mandatory } | ConvertTo-Json -Depth 4 -Compress
