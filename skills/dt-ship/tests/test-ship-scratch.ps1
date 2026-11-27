# Regression test: dt-ship runs the gate under the shared ram-scratch helper only when
# .ship.json has a "scratch" key; an absent key means disk with no wrapper.
#   pwsh -NoProfile -File skills/dt-ship/tests/test-ship-scratch.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ship = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/ship.ps1'
$failures = 0
function Assert {
    param([bool]$Condition, [string]$Name)
    if ($Condition) { Write-Output "PASS: $Name" } else { Write-Output "FAIL: $Name"; $script:failures++ }
}
if ($IsWindows) { Write-Output 'SKIP: ram-scratch is Linux-only'; exit 0 }

$tool = if ($env:RAM_SCRATCH_TOOL) { $env:RAM_SCRATCH_TOOL } else { '/home/danny/Claude/_system-tools/ram-scratch/ram-scratch' }
$root = Join-Path ([IO.Path]::GetTempPath()) ("ship-scratch-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$repo = Join-Path $root 'repo'
$record = Join-Path $root 'gate.txt'
$saved = @{}
foreach ($k in 'RAM_SCRATCH_TOOL', 'RAM_SCRATCH_RAM_ROOT', 'RAM_SCRATCH_DISK_ROOT', 'RAM_SCRATCH_STATE', 'RAM_SCRATCH_SAMPLE_S') {
    $saved[$k] = [Environment]::GetEnvironmentVariable($k)
}
function Invoke-Ship($scratch) {
    $cfg = [ordered]@{
        gateCommand     = "Set-Content -LiteralPath '$record' -Value ('mode=' + `$env:RAM_SCRATCH_MODE + ' tmp=' + `$env:TMPDIR); exit 1"
        deployCommand   = 'exit 0'
        prodCommitProbe = @{ command = 'git rev-parse HEAD' }
    }
    if ($null -ne $scratch) { $cfg.scratch = $scratch }
    $cfg | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $repo '.ship.json')
    git -C $repo add -A; git -C $repo commit -q -m 'cfg' --allow-empty
    Remove-Item -LiteralPath $record -ErrorAction SilentlyContinue
    Push-Location $repo
    try { $out = & pwsh -NoProfile -File $ship -RepoRoot $repo -Branch main -SkipPull -SkipPush -Json } finally { Pop-Location }
    ($out -join "`n") | ConvertFrom-Json
}
try {
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    git -C $repo init -q -b main
    git -C $repo config user.email 'test@example.com'
    git -C $repo config user.name 'test'
    git -C $repo config commit.gpgsign false
    $env:RAM_SCRATCH_TOOL = $tool
    $env:RAM_SCRATCH_RAM_ROOT = Join-Path $root 'shm'
    $env:RAM_SCRATCH_DISK_ROOT = Join-Path $root 'disk'
    $env:RAM_SCRATCH_STATE = Join-Path $root 'state'
    $env:RAM_SCRATCH_SAMPLE_S = '0'

    $r = Invoke-Ship $null
    $txt = Get-Content -Raw -LiteralPath $record
    Assert ($r.failed_step -eq 'gate') 'no scratch key: gate ran'
    Assert ($txt -match 'mode= ' -and $txt -notmatch [regex]::Escape($root)) 'no scratch key: disk, no wrapper'

    $r = Invoke-Ship @{ mode = 'auto'; capGb = 1 }
    $txt = Get-Content -Raw -LiteralPath $record
    Assert ($r.failed_step -eq 'gate') 'scratch auto: gate failure still fails the ship'
    Assert ($txt -match 'mode=(ram|disk) ' -and $txt -match [regex]::Escape($root)) 'scratch auto: gate got a helper folder'
    Assert ($r.scratch.cap_gb -eq 1) 'scratch auto: summary records scratch'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $root 'shm') -ErrorAction SilentlyContinue).Count -eq 0) 'scratch auto: folder cleaned'

    $r = Invoke-Ship @{ mode = 'disk'; capGb = 1 }
    $txt = Get-Content -Raw -LiteralPath $record
    Assert ($txt -match 'mode= ') 'scratch disk: no wrapper'

    $r = Invoke-Ship @{ mode = 'fast'; capGb = 1 }
    Assert ($r.failed_step -eq 'config') 'bad scratch.mode fails config'
    $r = Invoke-Ship @{ mode = 'auto'; capGb = 0 }
    Assert ($r.failed_step -eq 'config') 'non-positive scratch.capGb fails config'
}
finally {
    foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failures) { Write-Output "$failures failure(s)"; exit 1 }
Write-Output 'All dt-ship scratch tests passed.'
