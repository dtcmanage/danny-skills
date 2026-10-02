Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../update-outcomes.ps1')
$passed = 0
function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++; Write-Output "PASS: $Name"
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ('router-outcome-concurrency-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
$priorState = $env:DT_MODEL_ROUTER_STATE
$env:DT_MODEL_ROUTER_STATE = Join-Path $temp 'state'
$state = Get-RouterStateDir
$processes = [Collections.Generic.List[Diagnostics.Process]]::new()
function Start-Worker([string]$Mode, [string]$Argument = '') {
    $info = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach ($arg in @('-NoProfile','-File',(Join-Path $temp 'worker.ps1'),$Mode,$Argument)) { $info.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::Start($info)
    $processes.Add($process)
    return $process
}
function Wait-Marker([string]$Path) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $Path)) {
        if ($watch.Elapsed.TotalSeconds -gt 20) { throw "Worker did not create $Path" }
        Start-Sleep -Milliseconds 25
    }
}
function Wait-Worker([Diagnostics.Process]$Process) {
    if (-not $Process.WaitForExit(30000)) { throw 'Worker timeout' }
    $out = $Process.StandardOutput.ReadToEnd(); $err = $Process.StandardError.ReadToEnd()
    if ($Process.ExitCode -ne 0) { throw "Worker exit $($Process.ExitCode): $out $err" }
    return $out
}
try {
    $routerDir = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $worker = @'
param([string]$Mode, [string]$Argument)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. '__ROUTER__/update-outcomes.ps1'
$temp = $PSScriptRoot
if ($Mode -eq 'append') {
    1..20 | ForEach-Object {
        Add-RouterOutcome -Row ([pscustomobject]@{key="append:$Argument`:$($_)";run_id="append-$Argument";repo='test';at='2026-10-02T08:00:00Z';lane='codex';model='gpt-6.1-sol';category='routine-coding';attempt=1;pass=$true;escalated=$false;failure_category='environment';source='test';tier='standard'})
    }
} elseif ($Mode -eq 'decline') {
    & '__ROUTER__/approve-roster.ps1' -DeclineDrift -Job coder
} elseif ($Mode -eq 'hold') {
    Use-RouterOutcomeMutex -StateDir (Get-RouterStateDir) -Action {
        Set-Content -LiteralPath (Join-Path $temp 'held') -Value 'held'
        while ($true) { Start-Sleep -Milliseconds 100 }
    }
} else {
    if ($Mode -eq 'import-held') {
        function Get-ChildItem {
            param([string]$LiteralPath, [switch]$Directory, [switch]$File, [string]$Filter)
            if ($LiteralPath -eq (Join-Path $temp 'repo-a/.dt-build')) {
                Set-Content -LiteralPath (Join-Path $temp 'import-read') -Value 'snapshot-read'
                $watch = [Diagnostics.Stopwatch]::StartNew()
                while (-not (Test-Path -LiteralPath (Join-Path $temp 'release'))) {
                    if ($watch.Elapsed.TotalSeconds -gt 20) { throw 'Barrier timeout' }
                    Start-Sleep -Milliseconds 25
                }
            }
            Microsoft.PowerShell.Management\Get-ChildItem @PSBoundParameters
        }
    }
    Update-RouterOutcomes -Now ([datetime]'2026-10-02T12:00:00Z') -SourcesPath (Join-Path $temp $Argument) | ConvertTo-Json -Compress
}
'@
    $worker = $worker.Replace('__ROUTER__', $routerDir.Replace("'", "''"))
    [IO.File]::WriteAllText((Join-Path $temp 'worker.ps1'), $worker)
    $roster = (Read-RouterRoster).roster
    $roster.approved = $true; $roster.approved_at = '2026-10-01T00:00:00Z'
    Write-RouterJsonAtomic -Path (Join-Path $state 'roster.json') -Value $roster
    $base = @(1..20 | ForEach-Object {
        [pscustomobject]@{key="baseline:M$_`:1";run_id='baseline';repo='test';at=$(if ($_ -le 10) {'2026-08-01T12:00:00Z'} else {'2026-09-25T12:00:00Z'});lane='codex';model='gpt-6.1-sol';category='routine-coding';attempt=1;pass=($_ -le 10);escalated=$false;failure_category='';source='test';tier='standard'}
    })
    [IO.File]::WriteAllLines((Join-Path $state 'outcomes.jsonl'), @($base | ForEach-Object { $_ | ConvertTo-Json -Compress }))
    foreach ($suffix in @('a','b')) {
        $repo = Join-Path $temp "repo-$suffix"
        $dir = Join-Path $repo ".dt-build/run-$suffix"
        [IO.Directory]::CreateDirectory($dir) | Out-Null
        Write-RouterJsonAtomic -Path (Join-Path $dir 'piece.provenance.json') -Value ([pscustomobject]@{resolved_model='gpt-6.1-sol';chunk_id='piece';attempt=1;pass=$false;at='2026-09-25T12:00:00Z';tier='standard';category='routine-coding'})
        Write-RouterJsonAtomic -Path (Join-Path $temp "sources-$suffix.json") -Value @($repo)
    }
    $first = Start-Worker 'import-held' 'sources-a.json'
    Wait-Marker (Join-Path $temp 'import-read')
    $second = Start-Worker 'import' 'sources-b.json'
    $appenders = @(1..4 | ForEach-Object { Start-Worker 'append' ([string]$_) })
    $decline = Start-Worker 'decline'
    Start-Sleep -Milliseconds 300
    Assert-True (-not $second.HasExited -and -not $decline.HasExited -and @($appenders | Where-Object HasExited).Count -eq 0) 'import, appenders and decline wait while import owns snapshot lock'
    Set-Content -LiteralPath (Join-Path $temp 'release') -Value 'release'
    $null = Wait-Worker $first; $null = Wait-Worker $second
    foreach ($process in $appenders) { $null = Wait-Worker $process }
    $null = Wait-Worker $decline
    $rows = @(Get-Content -LiteralPath (Join-Path $state 'outcomes.jsonl') | ConvertFrom-Json)
    Assert-True ($rows.Count -eq 102 -and @($rows.key | Sort-Object -Unique).Count -eq 102) 'two overlapping imports and 80 concurrent appends preserve all 102 unique rows'
    Assert-True (@($rows | Where-Object key -Like 'append:*').Count -eq 80 -and @($rows | Where-Object key -Like 'run-*:piece:1').Count -eq 2) 'all independent process rows and both imported records retained'
    $again = Update-RouterOutcomes -Now ([datetime]'2026-10-02T12:00:00Z') -SourcesPath (Join-Path $temp 'sources-a.json')
    Assert-True ($again.new_records -eq 0 -and $again.total_records -eq 102) 'fresh reread makes repeated import idempotent'
    $marks = @(Read-RouterJsonArray -Path (Join-Path $state 'drift-marks.json'))
    $declines = @(Read-RouterJsonArray -Path (Join-Path $state 'drift-declines.json'))
    Assert-True ($marks.Count -eq 0 -and $declines.Count -eq 1 -and $declines[0].job -eq 'coder') 'competing importer preserves decline and does not restore declined drift'
    try { Use-RouterOutcomeMutex -StateDir $state -Action { throw 'intentional-test-error' } } catch {
        if ($_.Exception.Message -ne 'intentional-test-error') { throw }
    }
    $afterError = Use-RouterOutcomeMutex -StateDir $state -TimeoutMs 200 -Action { 'released' }
    Assert-True ($afterError -eq 'released') 'finally releases lock after action exception'
    $holder = Start-Worker 'hold'
    Wait-Marker (Join-Path $temp 'held')
    $timedOut = $false
    try { Use-RouterOutcomeMutex -StateDir $state -TimeoutMs 150 -Action { throw 'should not enter' } } catch { $timedOut = $_.Exception.Message -eq 'ROUTER_OUTCOME_MUTEX_TIMEOUT' }
    Assert-True $timedOut 'competing process times out with named error instead of writing unlocked'
    $holder.Kill(); $holder.WaitForExit()
    Assert-True ((Use-RouterOutcomeMutex -StateDir $state -TimeoutMs 200 -Action { 'released' }) -eq 'released') 'OS releases lock after owner process is killed'
    Assert-True (Test-Path -LiteralPath (Join-Path $state 'outcomes.mutex')) 'persistent mutex file avoids unlink/recreate race'
    Write-Output "PASS: $passed tests"
} finally {
    foreach ($process in $processes) {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
    $env:DT_MODEL_ROUTER_STATE = $priorState
    if ([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
