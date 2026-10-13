#Requires -Version 7.0
param([Parameter(Mandatory)][string]$RunFolder, [Parameter(Mandatory)][string]$BuildStatePath)
. (Join-Path $PSScriptRoot 'authority-digest.ps1')
$records = @(Get-AuthorityInventory -RunFolder $RunFolder -BuildStatePath $BuildStatePath)
$mandatory = @(Get-AuthorityMandatoryPaths -Records $records -BuildStatePath $BuildStatePath)
$markdown = Get-AuthorityMarkdown -RunFolder $RunFolder -Records $records -BuildStatePath $BuildStatePath
$mdPath = Join-Path $RunFolder 'authority-digest.md'
$jsonPath = Join-Path $RunFolder 'authority-digest.json'
[IO.File]::WriteAllText($mdPath, $markdown, [Text.UTF8Encoding]::new($false))
$manifest = [ordered]@{ schema_version = 1; producer = 'deterministic'; checkpoint = [IO.Path]::GetFullPath($BuildStatePath); checkpoint_authority_sha256 = Get-AuthorityCheckpointHash ([IO.File]::ReadAllText($BuildStatePath)); budget_chars = $script:AuthorityReadBudgetChars; mandatory_paths = $mandatory; markdown_sha256 = Get-AuthorityHash $mdPath; originals = $records }
[IO.File]::WriteAllText($jsonPath, ($manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
# Publish the pin last. A partially written pair never verifies.
[IO.File]::WriteAllText("$jsonPath.sha256", (Get-AuthorityHash $jsonPath), [Text.UTF8Encoding]::new($false))
& (Join-Path $PSScriptRoot 'verify-authority-digest.ps1') -RunFolder $RunFolder -BuildStatePath $BuildStatePath
