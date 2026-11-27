Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '../check-directory-drift.ps1'
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('directory-drift-' + [guid]::NewGuid().ToString('N'))
$workspace = Join-Path $fixture '_Claude-Workspace'
$passed = 0
$failed = 0

function Assert-Check {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { $script:passed++; Write-Output "PASS: $Name" }
    else { $script:failed++; Write-Output "FAIL: $Name" }
}

function Set-FixtureFile {
    param([string]$RelativePath, [string]$Text = '')
    $path = Join-Path $fixture $RelativePath
    [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
    [IO.File]::WriteAllText($path, $Text)
}

function Set-Tables {
    param([string]$Rows, [string]$Routes, [string]$Date)
    Set-FixtureFile '_Claude-Workspace/CLAUDE.md' @"
## Workstation Directory
| Workstation | What it is | Repos & substations | Other notable folders |
| :---- | :---- | :---- | :---- |
$Rows

Last full verification: $Date - fixture scan.

## Unrelated
| Ignore Me | This is not directory data. |
"@
    Set-FixtureFile 'CLAUDE.md' @"
## Routing Map
|Workstation|Route here when I...|
|:----|:----|
$Routes

## Unrelated
| Ignore Me Too | This is not routing data. |
"@
}

function Invoke-Check {
    return (& $scriptPath -WorkspaceRoot $workspace -Json | ConvertFrom-Json)
}

try {
    $today = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([datetime]::UtcNow, 'America/New_York').Date
    $todayText = $today.ToString('yyyy-MM-dd')
    $cleanRows = @'
| **Email HQ** | Email | Substation **Calendar** | |
| **Tech HQ** | Tech | Specialist areas **For-Mac**, **PC Build**, **Home Server** retain physical paths. | |
| **For-Mac** *(Tech HQ specialist area; retained path)* | Mac | Repo **`livewallpaper`** | |
| **PC Build** *(Tech HQ specialist area; retained path)* | PC | No repos | |
| **Home Server** *(Tech HQ specialist area; retained path)* | Servers | Repo **`session-hub`** | |
| **Build** | Code | Repo **`main-repo`**, **`feature-tree`**, **`deep-repo`**; substation **Child** | |
| **Container Owner** | Code | Repo **`repo-container`** (checkout repo-container/checkout) | |
'@
    $cleanRoutes = @'
|Email HQ|Email|
|Calendar *(substation of Email HQ)*|Calendar|
|Tech HQ|Specialist areas For-Mac, PC Build, and Home Server|
|Build|Code|
|Container Owner|Code|
'@
    Set-Tables $cleanRows $cleanRoutes $todayText
    Set-FixtureFile '_Claude-Workspace/Email HQ/Calendar/CLAUDE.md'
    Set-FixtureFile '_Claude-Workspace/Tech HQ/notes.txt'
    Set-FixtureFile '_Claude-Workspace/Container Owner/repo-container/checkout/.git/config'
    Set-FixtureFile '_Claude-Workspace/For-Mac/livewallpaper/.git/config'
    Set-FixtureFile '_Claude-Workspace/PC Build/notes.txt'
    Set-FixtureFile '_Claude-Workspace/Home Server/session-hub/session-hub/.git/config'
    Set-FixtureFile '_Claude-Workspace/Build/main-repo/.git/config'
    Set-FixtureFile '_Claude-Workspace/Build/feature-tree/.git' 'gitdir: /fixture/unused'
    Set-FixtureFile '_Claude-Workspace/Build/Child/CLAUDE.md'
    Set-FixtureFile '_Claude-Workspace/Build/Child/deep-repo/.git/config'
    Set-FixtureFile '_Claude-Workspace/Build/main-repo/node_modules/ignored/.git/config'
    Set-FixtureFile '_Claude-Workspace/Build/_archive/ignored/.git/config'
    Set-FixtureFile '_Claude-Workspace/Build/.hidden/CLAUDE.md'
    Set-FixtureFile '_Claude-Workspace/Build/ordinary/third/too-deep/.git/config'
    foreach ($name in @('_meta', '.dot', '00_Resources')) {
        Set-FixtureFile "_Claude-Workspace/$name/ignored/.git/config"
    }
    Set-FixtureFile '_Claude-Workspace/plain-file.txt'
    $before = Get-Content -LiteralPath (Join-Path $workspace 'CLAUDE.md') -Raw
    $result = Invoke-Check
    if ($result.findings.Count) { $result | ConvertTo-Json -Depth 5 | Write-Output }
    Assert-Check ($result.findings.Count -eq 0) 'clean case: retained paths, substations, depth 2, git files, excluded folders'
    Assert-Check ($result.verified_date -eq $todayText -and -not $result.full_rescan_due) 'recent verification date'
    Assert-Check (($result.PSObject.Properties.Name -join ',') -eq 'verified_date,full_rescan_due,findings') 'JSON contract'
    Assert-Check ((Get-Content -LiteralPath (Join-Path $workspace 'CLAUDE.md') -Raw) -ceq $before) 'scan leaves source unchanged'
    Push-Location $workspace
    try { $default = & $scriptPath -Json | ConvertFrom-Json }
    finally { Pop-Location }
    Assert-Check ($default.findings.Count -eq 0) 'current-directory workspace default'
    $object = & $scriptPath -WorkspaceRoot $workspace
    Assert-Check ($object.findings.Count -eq 0) 'non-JSON object output'

    Set-Tables $cleanRows $cleanRoutes ($today.AddDays(-31).ToString('yyyy-MM-dd'))
    Assert-Check (-not (Invoke-Check).full_rescan_due) '31 days is not overdue'
    Set-Tables $cleanRows $cleanRoutes ($today.AddDays(-32).ToString('yyyy-MM-dd'))
    Assert-Check ((Invoke-Check).full_rescan_due) '32 days is overdue'

    Set-FixtureFile '_Claude-Workspace/New Station/notes.txt'
    Set-FixtureFile '_Claude-Workspace/Build/unlisted-repo/.git/config'
    Set-FixtureFile '_Claude-Workspace/Build/Unlisted Child/CLAUDE.md'
    # Complete-name matching must not confuse main-repo with main-repo-extra.
    Set-FixtureFile '_Claude-Workspace/Build/main-repo-extra/.git/config'
    # An unmentioned linked worktree is a temporary checkout of a listed repo: never a finding.
    Set-FixtureFile '_Claude-Workspace/Build/scratch-worktree/.git' 'gitdir: D:/fixture/main-repo/.git/worktrees/scratch-worktree'
    $driftRows = $cleanRows + @'

| **Gone Station** | Gone | No repos | |
| **Missing Repo Owner** | Code | Repo **`absent-repo`** | |
'@
    $driftRoutes = $cleanRoutes + @'

|Gone Route|Gone|
|Missing Repo Owner|Code|
'@
    Set-FixtureFile '_Claude-Workspace/Missing Repo Owner/notes.txt'
    Set-Tables $driftRows $driftRoutes '2026-07-05'
    $result = Invoke-Check
    $expected = @{
        workstation_missing_from_table = 'New Station'
        folder_missing_from_routing_map = 'New Station'
        table_row_missing_folder = 'Gone Station'
        routing_row_missing_folder = 'Gone Route'
        repo_missing_from_row = 'Build'
        substation_missing_from_row = 'Build'
        listed_repo_missing_on_disk = 'Missing Repo Owner'
    }
    foreach ($entry in $expected.GetEnumerator()) {
        Assert-Check (@($result.findings | Where-Object { $_.kind -eq $entry.Key -and $_.workstation -eq $entry.Value }).Count -gt 0) "finding: $($entry.Key)"
    }
    Assert-Check ($result.findings.Count -eq 8) 'exact drift set without specialist/substation false positives'
    Assert-Check (@($result.findings | Where-Object { $_.detail -match 'main-repo-extra' }).Count -eq 1) 'complete-name mention boundaries'
    Assert-Check (@($result.findings | Where-Object { $_.detail -match 'scratch-worktree' }).Count -eq 0) 'linked worktrees are not reported as repos'
    Assert-Check (@($result.findings | Where-Object { [string]::IsNullOrWhiteSpace($_.detail) }).Count -eq 0) 'all findings explain evidence'
    Assert-Check ($result.verified_date -eq '2026-07-05') 'reports original verification date'

    Set-Tables $cleanRows $cleanRoutes 'unknown'
    $result = Invoke-Check
    Assert-Check ($null -eq $result.verified_date -and $result.full_rescan_due) 'missing stamp requires rescan'

    # Use a separate tree so the exact findings prove which workstation owns each repo.
    $originalWorkspace = $workspace
    $workspace = Join-Path $fixture 'finance/_Claude-Workspace'
    $originalFixture = $fixture
    $fixture = Join-Path $fixture 'finance'
    $financeRows = @'
| **Finance HQ** | Finance monorepo | Repo **`personal-finance-dashboard`** | |
'@
    $financeRoutes = '|Finance HQ|Personal finances|'
    Set-FixtureFile '_Claude-Workspace/Finance HQ/personal-finance-dashboard/.git/config'
    Set-FixtureFile '_Claude-Workspace/Finance/notes.txt'
    Set-Tables $financeRows $financeRoutes $todayText
    $result = Invoke-Check
    Assert-Check ($result.findings.Count -eq 2 -and @($result.findings | Where-Object { $_.workstation -ne 'Finance' -or $_.kind -notin @('workstation_missing_from_table', 'folder_missing_from_routing_map') }).Count -eq 0) 'unlisted Finance is reported without borrowing Finance HQ repos'
    Assert-Check (@($result.findings | Where-Object { $_.kind -eq 'listed_repo_missing_on_disk' }).Count -eq 0) 'existing Finance HQ repo is not reported missing under Finance'

    Set-Tables ($financeRows + "`n| **Finance** | Separate workstation | Repo **``finance-only``** | |") ($financeRoutes + "`n|Finance|Separate finances|") $todayText
    $result = Invoke-Check
    Assert-Check ($result.findings.Count -eq 1 -and $result.findings[0].kind -eq 'listed_repo_missing_on_disk' -and $result.findings[0].workstation -eq 'Finance' -and $result.findings[0].detail -match 'finance-only') 'exact Finance row owns its actually missing listed repo'
    Set-FixtureFile '_Claude-Workspace/Finance/finance-only/.git/config'
    Assert-Check ((Invoke-Check).findings.Count -eq 0) 'both exact workstation rows validate their own existing repos'
    Remove-Item -LiteralPath (Join-Path $workspace 'Finance HQ/personal-finance-dashboard') -Recurse -Force
    $result = Invoke-Check
    Assert-Check ($result.findings.Count -eq 1 -and $result.findings[0].kind -eq 'listed_repo_missing_on_disk' -and $result.findings[0].workstation -eq 'Finance HQ' -and $result.findings[0].detail -match 'personal-finance-dashboard') 'actually missing Finance HQ repo stays attributed to Finance HQ'
    Set-FixtureFile '_Claude-Workspace/Finance HQ/personal-finance-dashboard/.git/config'
    Set-FixtureFile '_Claude-Workspace/Finance/unlisted-repo/.git/config'
    $result = Invoke-Check
    Assert-Check ($result.findings.Count -eq 1 -and $result.findings[0].kind -eq 'repo_missing_from_row' -and $result.findings[0].workstation -eq 'Finance' -and $result.findings[0].detail -match 'unlisted-repo') 'actual unlisted repo belongs to the exact Finance row'

    $aliasRows = $financeRows + @'

| **Parent** | Aliases | Substation **Calendar**; repo **`alias-repo`** | |
'@
    Set-FixtureFile '_Claude-Workspace/Parent/alias-repo/.git/config'
    Set-FixtureFile '_Claude-Workspace/Parent/Calendar/CLAUDE.md'
    Set-FixtureFile '_Claude-Workspace/Calendar/notes.txt'
    Set-FixtureFile '_Claude-Workspace/Calendar/alias-repo/.git/config'
    Set-FixtureFile '_Claude-Workspace/alias-repo/alias-repo/.git/config'
    Set-Tables $aliasRows ($financeRoutes + "`n|Parent|Calendar and alias-repo retained paths|") $todayText
    $result = Invoke-Check
    Assert-Check (@($result.findings | Where-Object { $_.workstation -in @('Parent', 'Calendar', 'alias-repo') }).Count -eq 0) 'explicit substation and repo aliases retain parent-row and routing mentions'
    $fixture = $originalFixture
    $workspace = $originalWorkspace

    Set-FixtureFile 'CLAUDE.md' '## Routing Map'
    $rejected = $false
    try { $null = Invoke-Check } catch { $rejected = $_.Exception.Message -match 'Missing or empty table' }
    Assert-Check $rejected 'malformed routing table fails instead of reporting clean'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture cleanup escaped temp root.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
Write-Output "SUMMARY: $passed passed; $failed failed"
if ($failed) { exit 1 }
