param(
    [string]$WorkspaceRoot = '.',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TableRows {
    param([string]$Text, [string]$Heading)
    $inSection = $false
    $rows = @()
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match '^##\s+(.+?)\s*$') {
            if ($inSection) { break }
            $inSection = $Matches[1] -eq $Heading
            continue
        }
        if (-not $inSection -or $line -notmatch '^\s*\|') { continue }
        $cells = $line.Trim().Trim('|') -split '(?<!\\)\|'
        $label = $cells[0].Trim()
        if ($label -eq 'Workstation' -or $label -match '^:?-+') { continue }
        # Decorations following the name describe retained paths or parentage.
        $name = ($label -replace '[*`]', '' -replace '\s*\(.*$', '').Trim()
        if ($name) { $rows += [pscustomobject]@{ Name = $name; Text = $line } }
    }
    if ($rows.Count -eq 0) { throw "Missing or empty table: $Heading" }
    return $rows
}

function Test-Mention {
    param([string]$Text, [string]$Name)
    # Match a complete name, including names containing spaces or punctuation.
    return $Text -match ('(?<![\p{L}\p{N}_-])' + [regex]::Escape($Name) + '(?![\p{L}\p{N}_-])')
}

function Get-ContentFolders {
    param([string]$Path)
    return @(Get-ChildItem -LiteralPath $Path -Directory -Force | Where-Object {
        $_.Name -notmatch '^[_.]' -and $_.Name -ne '00_Resources' -and
        -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
    } | Sort-Object Name)
}

function Add-Finding {
    param([string]$Kind, [string]$Workstation, [string]$Detail)
    $findings.Add([pscustomobject]@{ kind = $Kind; workstation = $Workstation; detail = $Detail })
}

# Same current-directory default/Resolve-Path behavior as detect-memory-bloat.ps1.
# WorkspaceRoot denotes _Claude-Workspace; the routing map is in its parent.
$root = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$directoryText = Get-Content -LiteralPath (Join-Path $root 'CLAUDE.md') -Raw
$routingText = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $root) 'CLAUDE.md') -Raw
$directory = @(Get-TableRows -Text $directoryText -Heading 'Workstation Directory')
$routing = @(Get-TableRows -Text $routingText -Heading 'Routing Map')
$findings = [Collections.Generic.List[object]]::new()
$folders = @(Get-ContentFolders -Path $root)
$inventory = @{}
$physicalNames = @{}
foreach ($folder in $folders) {
    $physicalNames[$folder.Name] = $true
    $nodes = [Collections.Generic.List[object]]::new()
    # At most two levels below each workstation. Never descend into repositories
    # (dependencies/build outputs), meta folders, or filesystem links.
    foreach ($child in (Get-ContentFolders -Path $folder.FullName)) {
        $nodes.Add($child)
        if (Test-Path -LiteralPath (Join-Path $child.FullName '.git')) { continue }
        foreach ($grandchild in (Get-ContentFolders -Path $child.FullName)) { $nodes.Add($grandchild) }
    }
    $inventory[$folder.Name] = $nodes.ToArray()
    foreach ($node in $nodes) { $physicalNames[$node.Name] = $true }
}

foreach ($folder in $folders) {
    $rows = @($directory | Where-Object { $_.Name -eq $folder.Name })
    if ($rows.Count -eq 0) {
        $rows = @($directory | Where-Object { Test-Mention -Text $_.Text -Name $folder.Name })
    }
    if ($rows.Count -eq 0) {
        Add-Finding 'workstation_missing_from_table' $folder.Name 'Folder has no directory table entry or named parent-row mention.'
    }
    if (-not @($routing | Where-Object { Test-Mention -Text $_.Text -Name $folder.Name }).Count) {
        Add-Finding 'folder_missing_from_routing_map' $folder.Name 'Folder is not named in the routing map.'
    }
    if ($rows.Count -eq 0) { continue }
    $rowText = ($rows.Text -join ' ')
    foreach ($node in $inventory[$folder.Name]) {
        $relative = [IO.Path]::GetRelativePath($folder.FullName, $node.FullName)
        if (-not (Test-Mention -Text $rowText -Name $node.Name)) {
            $gitPath = Join-Path $node.FullName '.git'
            if (Test-Path -LiteralPath $gitPath) {
                # A linked worktree (.git file pointing into a repo's worktrees folder) is a
                # temporary checkout of a listed repo, not a repo of its own.
                if ((Test-Path -LiteralPath $gitPath -PathType Leaf) -and ((Get-Content -LiteralPath $gitPath -TotalCount 1) -match '[\\/]worktrees[\\/]')) { continue }
                Add-Finding 'repo_missing_from_row' $folder.Name "Repo '$relative' is not mentioned in the directory row."
            } elseif (Test-Path -LiteralPath (Join-Path $node.FullName 'CLAUDE.md') -PathType Leaf) {
                Add-Finding 'substation_missing_from_row' $folder.Name "Substation '$relative' is not mentioned in the directory row."
            }
        }
    }
    foreach ($match in [regex]::Matches($rowText, '\*\*`([^`]+)`\*\*')) {
        $repoName = $match.Groups[1].Value
        # A documented repo name may name its container, with the actual checkout
        # below it (for example tcm-esign/tcm-esign-app). Check folder existence.
        if (-not @($inventory[$folder.Name] | Where-Object { $_.Name -eq $repoName }).Count) {
            Add-Finding 'listed_repo_missing_on_disk' $folder.Name "Named repo '$repoName' has no folder within depth 2."
        }
    }
}
foreach ($row in $directory) {
    if (-not $physicalNames.ContainsKey($row.Name)) {
        Add-Finding 'table_row_missing_folder' $row.Name 'Directory table row has no matching physical folder within the scan.'
    }
}
foreach ($row in $routing) {
    if (-not $physicalNames.ContainsKey($row.Name)) {
        Add-Finding 'routing_row_missing_folder' $row.Name 'Routing map row has no matching physical folder within the scan.'
    }
}

$verifiedDate = $null
$due = $true
if ($directoryText -match 'Last full verification:\s*(\d{4}-\d{2}-\d{2})') {
    $verifiedDate = $Matches[1]
    $parsedDate = [datetime]::ParseExact($verifiedDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $today = [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([datetime]::UtcNow, 'America/New_York').Date
    $due = ($today - $parsedDate).TotalDays -gt 31
}
$result = [pscustomobject]@{ verified_date = $verifiedDate; full_rescan_due = $due; findings = @($findings.ToArray()) }
if ($Json) { $result | ConvertTo-Json -Depth 5 } else { $result }
