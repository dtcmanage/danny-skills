#Requires -Version 7.0
# build-orchestrator-rules.ps1: root rules minus excluded sections, scoped chain in order, imports listed not inlined,
# workspace directory map skipped, fail-closed when the root CLAUDE.md is missing.
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script = Join-Path (Split-Path -Parent $PSScriptRoot) 'build-orchestrator-rules.ps1'
$failures = 0
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { Write-Host "FAIL: $Message"; $script:failures++ } else { Write-Host "ok: $Message" } }

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("orch-rules-" + [guid]::NewGuid().ToString('N'))
try {
    $ws = Join-Path $root '_Claude-Workspace'
    $station = Join-Path $ws 'Station'
    $repo = Join-Path $station 'repo'
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $root 'CLAUDE.md') -Value @"
# CLAUDE.md

## Memory System

MEMORY-PLACEMENT-RULE

@MEMORY.md

## Preferences

- KEEP-PREFERENCE

## Routing Map

ROUTING-TABLE

## Rules

### Verification

KEEP-VERIFY
"@
    Set-Content -LiteralPath (Join-Path $root 'MEMORY.md') -Value 'MEMORY-FACT'
    Set-Content -LiteralPath (Join-Path $ws 'CLAUDE.md') -Value 'WORKSPACE-MAP'
    Set-Content -LiteralPath (Join-Path $station 'CLAUDE.md') -Value "# Station`n`nSTATION-RULE`n`n@notes.md"
    Set-Content -LiteralPath (Join-Path $repo 'CLAUDE.md') -Value '# Repo`n`nREPO-RULE'
    $out = Join-Path $root 'out.md'

    $printed = & pwsh -NoProfile -File $script -WorkDir $repo -OutPath $out -ConfigDir $root
    Assert-True ($LASTEXITCODE -eq 0) 'generator exits 0'
    Assert-True ($printed -eq [System.IO.Path]::GetFullPath($out)) 'prints the output path'
    $text = Get-Content -LiteralPath $out -Raw
    Assert-True ($text -match 'KEEP-PREFERENCE' -and $text -match 'KEEP-VERIFY') 'keeps root sections not excluded'
    Assert-True ($text -notmatch 'MEMORY-PLACEMENT-RULE' -and $text -notmatch 'ROUTING-TABLE') 'drops Memory System and Routing Map'
    Assert-True ($text -notmatch 'MEMORY-FACT') 'does not inline the root MEMORY.md import'
    Assert-True ($text -match 'Not loaded[^\n]*MEMORY\.md' -and $text -match 'Not loaded[^\n]*notes\.md') 'lists root and scoped imports as not loaded'
    Assert-True ($text -notmatch 'WORKSPACE-MAP') 'skips the workspace directory map'
    $s = $text.IndexOf('STATION-RULE'); $r = $text.IndexOf('REPO-RULE')
    Assert-True ($s -gt 0 -and $r -gt $s) 'includes the scoped chain outermost first'
    $firstHash = (Get-FileHash -LiteralPath $out).Hash
    & pwsh -NoProfile -File $script -WorkDir $repo -OutPath $out -ConfigDir $root | Out-Null
    Assert-True ((Get-FileHash -LiteralPath $out).Hash -eq $firstHash) 'unchanged rules regenerate byte-identically'

    # A rule edited in the source shows up on the next generation: nothing to sync.
    Add-Content -LiteralPath (Join-Path $root 'CLAUDE.md') -Value "`n- NEW-RULE-AFTER-EDIT"
    & pwsh -NoProfile -File $script -WorkDir $repo -OutPath $out -ConfigDir $root | Out-Null
    Assert-True ((Get-Content -LiteralPath $out -Raw) -match 'NEW-RULE-AFTER-EDIT') 'regeneration reflects a source edit'

    # Fail closed: no root CLAUDE.md, nothing written, non-zero exit.
    $empty = Join-Path $root 'empty'; New-Item -ItemType Directory -Path $empty | Out-Null
    $out2 = Join-Path $root 'out2.md'
    & pwsh -NoProfile -File $script -WorkDir $repo -OutPath $out2 -ConfigDir $empty 2>$null | Out-Null
    Assert-True ($LASTEXITCODE -ne 0 -and -not (Test-Path -LiteralPath $out2)) 'missing root CLAUDE.md fails closed'
}
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
if ($failures) { Write-Host "$failures failure(s)"; exit 1 }
Write-Host 'all passed'
