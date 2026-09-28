param(
    [switch]$Show,
    [switch]$Approve,
    [switch]$Revoke,
    [string]$TablePath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'resolve-model.ps1')

if (([int][bool]$Show + [int][bool]$Approve + [int][bool]$Revoke) -ne 1) { throw 'Choose exactly one of -Show, -Approve, or -Revoke.' }
$path = if ($TablePath) { $TablePath } else { Join-Path (Get-RouterStateDir) 'router-table.json' }
if (-not (Test-Path -LiteralPath $path)) { throw "Router table not found: $path" }
$table = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 40
# Tables written before the approval step lack these fields; treat them as not approved.
foreach ($field in @('evidence_routing_approved','approved_picks')) {
    if (-not $table.PSObject.Properties[$field]) { $table | Add-Member -NotePropertyName $field -NotePropertyValue $(if ($field -eq 'approved_picks') { @() } else { $false }) }
}
$errors = @(Test-RouterTable -Table $table)
if ($errors.Count) { throw "Invalid router table: $($errors -join '; ')" }

if ($Show -or $Approve) {
    $bridgeMap = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/bridge-map.json') -Raw | ConvertFrom-Json
    $current = @(Get-RouterPicksSnapshot -TablePath $path)
    $rows = foreach ($pick in $current) {
        $old = @($table.approved_picks | Where-Object { $_.category -eq $pick.category -and $_.lane -eq $pick.lane -and [bool]$_.protected -eq [bool]$pick.protected } | Select-Object -First 1)
        $bridge = if ($pick.protected -and $pick.category -ne 'image-generation') { $bridgeMap.lanes.($pick.lane).protected } else { $bridgeMap.lanes.($pick.lane).categories.($pick.category) }
        [pscustomobject]@{ category = $pick.category; lane = $pick.lane; protected = $pick.protected; bridge_pick = $bridge; old_approved_pick = $(if ($old.Count) { $old[0].model } else { '' }); evidence_pick = $pick.model; reason = $pick.reason }
    }
    $rows | Format-Table -AutoSize | Out-String -Width 240 | Write-Output
}
if ($Approve) {
    if ($table.source -ne 'research' -or $table.coverage -ne 'full') { throw 'Only a full research table can be approved.' }
    $table.approved_picks = @($current)
    $table.evidence_routing_approved = $true
} elseif ($Revoke) { $table.evidence_routing_approved = $false }
if ($Approve -or $Revoke) {
    $json = ConvertTo-Json -InputObject $table -Depth 40
    $temp = Join-Path (Split-Path -Parent $path) ('.router-approval.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try { [IO.File]::WriteAllText($temp,$json,[Text.UTF8Encoding]::new($false)); [IO.File]::Move($temp,$path,$true) }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}
