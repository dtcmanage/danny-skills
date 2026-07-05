# Inventory every _handoffs folder under a workstation or repo root and report
# the status of each handoff .md deterministically.
#
# Convention: a handoff is CONSUMED when it lives in a '_handoffs\consumed\'
# subfolder (including '_handoffs\consumed\_archive\'); otherwise it is OPEN.
# The intaking session moves the file to consumed\ after loading it.
#
# -Prune moves CONSUMED files older than 30 days from '_handoffs\consumed\'
# into '_handoffs\consumed\_archive\'. Nothing is ever deleted.
#
# Output (default): summary lines.
# Output (-Json):  { root, handoff_folders[], handoffs[], pruned[] }
# where each handoff entry is { folder, name, path, created, age_days,
# status, archived }.

param(
    [Parameter(Mandatory)]
    [string]$Root,

    [switch]$Prune,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "Root folder not found: $Root"
}

$resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
$maxDepth = 3
$pruneAgeDays = 30
$now = Get-Date

# --- Locate every _handoffs folder, bounded to $maxDepth levels below Root ---

function Find-HandoffFolders {
    param(
        [string]$Folder,
        [int]$Depth
    )
    $found = @()
    foreach ($child in Get-ChildItem -LiteralPath $Folder -Directory -ErrorAction SilentlyContinue) {
        if ($child.Name -eq '_handoffs') {
            $found += $child.FullName
        }
        elseif ($Depth -lt $maxDepth) {
            $found += Find-HandoffFolders -Folder $child.FullName -Depth ($Depth + 1)
        }
    }
    return $found
}

$handoffFolders = @(Find-HandoffFolders -Folder $resolvedRoot -Depth 1)
if ((Split-Path -Leaf $resolvedRoot) -eq '_handoffs') {
    $handoffFolders = @($resolvedRoot) + $handoffFolders
}

# --- Build the handoff inventory ---

function Get-CreatedDate {
    param([System.IO.FileInfo]$File)
    # Dated filename prefix wins: handoff-YYYY-MM-DD-... or YYYY-MM-DD-...
    if ($File.Name -match '(?:^|^handoff-)(\d{4}-\d{2}-\d{2})') {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact($Matches[1], 'yyyy-MM-dd', $null,
                [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            return $parsed
        }
    }
    return $File.CreationTime
}

function New-HandoffEntry {
    param(
        [System.IO.FileInfo]$File,
        [string]$HandoffFolder,
        [string]$Status,
        [bool]$Archived
    )
    $created = Get-CreatedDate -File $File
    [pscustomobject]@{
        folder = $HandoffFolder
        name = $File.Name
        path = $File.FullName
        created = $created.ToString('yyyy-MM-dd')
        age_days = [int][math]::Floor(($now - $created).TotalDays)
        status = $Status
        archived = $Archived
    }
}

$handoffs = @()
foreach ($folder in $handoffFolders) {
    foreach ($file in Get-ChildItem -LiteralPath $folder -File -Filter '*.md' -ErrorAction SilentlyContinue) {
        $handoffs += New-HandoffEntry -File $file -HandoffFolder $folder -Status 'OPEN' -Archived $false
    }
    $consumedFolder = Join-Path $folder 'consumed'
    if (Test-Path -LiteralPath $consumedFolder -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $consumedFolder -File -Filter '*.md' -ErrorAction SilentlyContinue) {
            $handoffs += New-HandoffEntry -File $file -HandoffFolder $folder -Status 'CONSUMED' -Archived $false
        }
        $archiveFolder = Join-Path $consumedFolder '_archive'
        if (Test-Path -LiteralPath $archiveFolder -PathType Container) {
            foreach ($file in Get-ChildItem -LiteralPath $archiveFolder -File -Filter '*.md' -ErrorAction SilentlyContinue) {
                $handoffs += New-HandoffEntry -File $file -HandoffFolder $folder -Status 'CONSUMED' -Archived $true
            }
        }
    }
}

# --- Prune: move CONSUMED files older than 30 days to consumed\_archive ---

$pruned = @()
if ($Prune) {
    foreach ($entry in $handoffs) {
        if ($entry.status -ne 'CONSUMED' -or $entry.archived) { continue }
        if ($entry.age_days -le $pruneAgeDays) { continue }

        $archiveFolder = Join-Path (Join-Path $entry.folder 'consumed') '_archive'
        if (-not (Test-Path -LiteralPath $archiveFolder)) {
            New-Item -ItemType Directory -Path $archiveFolder -Force | Out-Null
        }
        $target = Join-Path $archiveFolder $entry.name
        if (Test-Path -LiteralPath $target) {
            $stamp = $now.ToString('yyyyMMdd-HHmmss')
            $base = [System.IO.Path]::GetFileNameWithoutExtension($entry.name)
            $ext = [System.IO.Path]::GetExtension($entry.name)
            $target = Join-Path $archiveFolder "$base-$stamp$ext"
        }
        # Move-Item within one volume is an atomic rename.
        Move-Item -LiteralPath $entry.path -Destination $target
        $entry.path = $target
        $entry.archived = $true
        $pruned += [pscustomobject]@{
            name = $entry.name
            from = (Join-Path (Join-Path $entry.folder 'consumed') $entry.name)
            to = $target
            age_days = $entry.age_days
        }
    }
}

# --- Report ---

$result = [pscustomobject]@{
    root = $resolvedRoot
    handoff_folders = $handoffFolders
    handoffs = $handoffs
    pruned = $pruned
}

if ($Json) {
    $result | ConvertTo-Json -Depth 5
}
else {
    Write-Output "Root: $resolvedRoot"
    Write-Output "Handoff folders found: $($handoffFolders.Count)"
    foreach ($folder in $handoffFolders) {
        Write-Output "  $folder"
    }
    if ($handoffs.Count -eq 0) {
        Write-Output "No handoff files."
    }
    else {
        Write-Output "Handoffs ($($handoffs.Count)):"
        foreach ($h in $handoffs) {
            $flag = if ($h.archived) { ' [archived]' } else { '' }
            Write-Output "  [$($h.status)]$flag $($h.name)  created $($h.created)  ($($h.age_days)d)  $($h.path)"
        }
    }
    if ($Prune) {
        if ($pruned.Count -eq 0) {
            Write-Output "Prune: nothing older than $pruneAgeDays days in consumed\."
        }
        else {
            Write-Output "Pruned ($($pruned.Count)):"
            foreach ($p in $pruned) {
                Write-Output "  $($p.name) -> $($p.to)"
            }
        }
    }
}
