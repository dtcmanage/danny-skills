param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:passed = 0
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERT_FAIL: $Message" }
    $script:passed++
}
function Write-Utf8 {
    param([string]$Path, [string]$Content)
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

$ledgerScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'boundary-ledger.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('dt-boundary-ledger-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$run = Join-Path $root 'run with spaces'
New-Item -ItemType Directory -Path $run | Out-Null
$source = Join-Path $root 'boundary [current].md'
$other = Join-Path $root 'approval.md'
$ledger = Join-Path $run 'boundary-ledger.jsonl'
$children = @()
function Plan {
    param([string[]]$SourcePaths = @($source))
    @((& $ledgerScript plan -RunFolder $run -Paths $SourcePaths) | ConvertFrom-Json)
}
function Record {
    param([string[]]$AuthorityLines = @('Verdict: source only.'), [string]$Pin)
    (& $ledgerScript record -RunFolder $run -Path $source -Lines $AuthorityLines -CoordinatorId c1 -ExpectedSha256 $Pin) | ConvertFrom-Json
}
try {
    Write-Utf8 $source "Verdict: source only.`nRestriction: no deploy.`n"
    Write-Utf8 $other "Approval: read only.`n"
    $first = Plan
    Assert-True ($first.Count -eq 1 -and $first[0].action -eq 'read-full' -and $first[0].sha256 -match '^[a-f0-9]{64}$') 'missing ledger returns a hashed full-read plan'
    Assert-True (-not (Test-Path -LiteralPath $ledger)) 'plan never creates a missing ledger'
    $recorded = Record -AuthorityLines @('Verdict: source only.', 'Restriction: no deploy.') -Pin $first[0].sha256
    Assert-True $recorded.recorded 'record appends a full-read attestation'
    $row = Get-Content -LiteralPath $ledger -Raw | ConvertFrom-Json
    Assert-True ($row.path -ceq $source -and $row.size -eq ([IO.FileInfo]::new($source)).Length -and ([DateTimeOffset]$row.read_utc).Offset -eq [TimeSpan]::Zero -and $row.coordinator_id -eq 'c1') 'row records canonical path, byte size, UTC timestamp and coordinator'
    $plan = Plan
    Assert-True ($plan[0].action -eq 'unchanged' -and $plan[0].lines.Count -eq 2 -and $plan[0].lines[1] -ceq 'Restriction: no deploy.') 'unchanged source returns all recorded authority lines'
    Assert-True ($plan[0].coordinator_id -eq 'c1' -and $plan[0].read_utc -eq $row.read_utc) 'reuse reports its full-read provenance'
    $multi = Plan @($source, $other)
    Assert-True ($multi.Count -eq 2 -and $multi[0].action -eq 'unchanged' -and $multi[1].action -eq 'read-full') 'new paths require a full read independently'

    Write-Utf8 $source "Verdict: source only.`nRestriction: no remote.`n"
    $edited = Plan
    Assert-True ($edited[0].action -eq 'read-full' -and $edited[0].sha256 -cne $first[0].sha256) 'same-size edit requires full read'
    $stale = Record -Pin $first[0].sha256
    Assert-True (-not $stale.recorded -and $stale.action -eq 'read-full') 'record rejects a source changed since planning'
    Assert-True (Record -Pin $edited[0].sha256).recorded 'changed source can be recorded after its full read'
    $plan = Plan
    Assert-True ($plan[0].action -eq 'unchanged' -and $plan[0].lines.Count -eq 1) 'latest row replaces earlier lines for a path'
    $badLines = Record -AuthorityLines @('Verdict: deploy approved.')
    Assert-True (-not $badLines.recorded) 'invented authority lines cannot be recorded'

    # A parseable invalid successor must not resurrect a preceding valid entry.
    $validText = [IO.File]::ReadAllText($ledger)
    $badRow = $row | ConvertTo-Json -Compress
    $badRow = $badRow.Replace($row.sha256, 'broken-hash')
    [IO.File]::AppendAllText($ledger, $badRow + "`n")
    Assert-True ((Plan)[0].action -eq 'read-full') 'invalid latest entry forces full read for its path'
    Write-Utf8 $ledger ($validText + '{corrupt ledger line' + "`n")
    Assert-True ((Plan)[0].action -eq 'read-full') 'unparseable latest line is ignored without trusting old rows'
    Assert-True (Record).recorded 'valid append recovers after corruption'
    Assert-True ((Plan)[0].action -eq 'unchanged') 'later valid entry wins after corrupt line'

    # Plan and record failures fall back, including denied access and torn writes.
    $held = [IO.File]::Open($ledger, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        Assert-True ((Plan)[0].action -eq 'read-full') 'ledger read lock timeout falls back to full read'
        Assert-True (-not (Record).recorded) 'ledger write lock timeout falls back to full read'
    }
    finally { $held.Dispose() }
    $held = [IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Assert-True ((Plan)[0].action -eq 'read-full') 'unreadable source requires full read' }
    finally { $held.Dispose() }
    Remove-Item -LiteralPath $source
    Assert-True ((Plan)[0].action -eq 'read-full') 'missing source requires full read'
    Assert-True (-not (Record).recorded) 'missing source cannot create a ledger entry'
    Write-Utf8 $source "Verdict: source only.`nRestriction: no deploy.`n"
    Write-Utf8 $ledger '{torn append'
    Assert-True (Record).recorded 'record preserves and separates an unterminated corrupt row'
    Assert-True ((Plan)[0].action -eq 'unchanged') 'separated valid append remains reusable'

    # Four concurrent processes, six appends each, against one synthetic run.
    Write-Utf8 $ledger ''
    $childScript = Join-Path $root 'append.ps1'
    Write-Utf8 $childScript @'
param([string]$ScriptPath, [string]$Run, [string]$Source, [string]$Coordinator)
$ErrorActionPreference = 'Stop'
foreach ($i in 1..6) {
    $row = & $ScriptPath record -RunFolder $Run -Path $Source -Lines @('Verdict: source only.') -CoordinatorId $Coordinator | ConvertFrom-Json
    if (-not $row.recorded) { throw ($row | ConvertTo-Json -Compress) }
}
'@
    foreach ($i in 1..4) {
        $arguments = @('-NoProfile', '-File', ('"' + $childScript + '"'), '-ScriptPath', ('"' + $ledgerScript + '"'), '-Run', ('"' + $run + '"'), '-Source', ('"' + $source + '"'), '-Coordinator', "parallel-$i")
        $start = @{ FilePath = (Get-Command pwsh).Source; ArgumentList = $arguments; PassThru = $true; RedirectStandardOutput = (Join-Path $root "$i.out"); RedirectStandardError = (Join-Path $root "$i.err") }
        if ($IsWindows) { $start.WindowStyle = 'Hidden' }
        $children += Start-Process @start
    }
    foreach ($child in $children) {
        Assert-True ($child.WaitForExit(30000)) 'concurrent appender completes within timeout'
        Assert-True ($child.ExitCode -eq 0) 'concurrent appender succeeds'
    }
    $rows = @(Get-Content -LiteralPath $ledger | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($rows.Count -eq 24 -and @($rows | Group-Object coordinator_id).Count -eq 4) 'concurrent appends retain all 24 intact JSON rows'
    Assert-True ((Plan)[0].action -eq 'unchanged') 'concurrently appended ledger remains usable'
    Write-Output "PASS: $script:passed boundary-ledger checks"
}
finally {
    foreach ($child in $children) { if (-not $child.HasExited) { $child.Kill($true); $child.WaitForExit() } }
    $cleanup = [IO.Path]::GetFullPath($root)
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
    if ((Split-Path -Parent $cleanup) -ne $tempParent -or (Split-Path -Leaf $cleanup) -notlike 'dt-boundary-ledger-*') { throw 'Unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $cleanup -Recurse -Force
}
