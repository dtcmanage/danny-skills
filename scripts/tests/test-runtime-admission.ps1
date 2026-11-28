$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../lib/runtime-test-admission.ps1')
function Check($condition, $message) { if (-not $condition) { throw $message }; Write-Output "PASS: $message" }
Check ((Get-TestWorkerBudget -CpuCount 40 -Load 0 -Limit 16) -eq 16) 'idle host preserves useful explicit limit'
Check ((Get-TestWorkerBudget -CpuCount 40 -Load 28 -Limit 16) -eq 2) 'high load reduces workers deterministically'
Check ((Get-TestWorkerBudget -CpuCount 40 -Load 75 -Limit 16) -eq 1) 'overload admits one worker'
Check ((Get-TestWorkerBudget -CpuCount 8 -Load 0 -Limit 3) -eq 3) 'explicit cap remains upper bound'
$root = Join-Path ([IO.Path]::GetTempPath()) ('runtime-admission-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$saved = @{}
foreach ($key in @('DT_RUNTIME_TEST_OWNER','DT_RUNTIME_TEST_OWNER_START','DT_RUNTIME_TEST_OWNER_PATH','DT_RUNTIME_TEST_OWNER_NONCE')) { $saved[$key]=[Environment]::GetEnvironmentVariable($key) }
Remove-Item Env:DT_RUNTIME_TEST_OWNER -ErrorAction SilentlyContinue
$script:RuntimeTestLease = $null
$children = @()
function Start-Fixture([string]$Code, [string]$Name) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Code))
    Start-Process (Join-Path $PSHOME 'pwsh') -ArgumentList @('-NoProfile','-EncodedCommand',$encoded) -RedirectStandardOutput (Join-Path $root "$Name.out") -RedirectStandardError (Join-Path $root "$Name.err") -PassThru
}
try {
    Enter-RuntimeTestSuite -LockPath (Join-Path $root 'suite.mutex')
    $helper = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../lib/runtime-test-admission.ps1')).Replace("'", "''")
    $quotedRoot = $root.Replace("'", "''")
    $lease = $script:RuntimeTestLease
    . $helper
    Enter-RuntimeTestSuite -LockPath (Join-Path $root 'suite.mutex')
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    Check ([object]::ReferenceEquals($lease,$script:RuntimeTestLease) -and $lease.CanWrite) 'repeat calls and dot-sourcing retain a strong handle'
    $nested = ". '$helper'; Enter-RuntimeTestSuite -LockPath '$quotedRoot/suite.mutex'; Set-Content '$quotedRoot/nested' 1"
    $grandEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($nested))
    $child = Start-Fixture ($nested + "; & (Join-Path `$PSHOME 'pwsh') -NoProfile -EncodedCommand '$grandEncoded'; exit `$LASTEXITCODE") 'nested'
    $children += $child
    Check ($child.WaitForExit(30000) -and $child.ExitCode -eq 0 -and (Test-Path "$root/nested") -and $lease.CanWrite) 'fresh child and grandchild enter while ancestor retains lease'
    $sleeper = Start-Fixture 'Start-Sleep -Seconds 300' 'sleeper'; $children += $sleeper
    $wrongLiveStart = (Get-RuntimeProcessIdentity $sleeper.Id).start
    $cases = @{
        independent = 'Remove-Item Env:DT_RUNTIME_TEST_OWNER -ErrorAction SilentlyContinue'
        staleLivePid = "`$env:DT_RUNTIME_TEST_OWNER='$($sleeper.Id)'; `$env:DT_RUNTIME_TEST_OWNER_START='$wrongLiveStart'"
        wrongStart = "`$env:DT_RUNTIME_TEST_OWNER_START='wrong-start'"
        wrongPath = "`$env:DT_RUNTIME_TEST_OWNER_PATH='$quotedRoot/other.mutex'"
        wrongNonce = "`$env:DT_RUNTIME_TEST_OWNER_NONCE='stale-lease'"
    }
    foreach ($name in $cases.Keys) {
        $code = "$($cases[$name]); . '$helper'; Enter-RuntimeTestSuite -LockPath '$quotedRoot/suite.mutex'; Set-Content '$quotedRoot/$name.entered' 1"
        $child=Start-Fixture $code $name; $children += $child
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while ([string](Get-Content "$root/$name.out" -Raw) -notmatch 'Waiting for another' -and [DateTime]::UtcNow -lt $deadline -and -not $child.HasExited) { Start-Sleep -Milliseconds 50 }
        Check (([string](Get-Content "$root/$name.out" -Raw)) -match 'Waiting for another' -and -not (Test-Path "$root/$name.entered")) "$name waits on the actual lease"
    }
    $oldNonce = $env:DT_RUNTIME_TEST_OWNER_NONCE
    $script:RuntimeTestLease.Dispose()
    foreach ($child in $children | Where-Object { $_.Id -ne $sleeper.Id }) { Check ($child.WaitForExit(30000) -and $child.ExitCode -eq 0) 'waiter or nested child completes after release' }
    Enter-RuntimeTestSuite -LockPath (Join-Path $root 'suite.mutex')
    Check ($script:RuntimeTestLease.CanWrite -and $env:DT_RUNTIME_TEST_OWNER_NONCE -cne $oldNonce) 'disposed lease cannot bypass; same process acquires a new live lease'
    # Reproduce the disposal race: another process owns the mutex while the
    # old owner's PID/start/path/receipt are still valid but its handle is gone.
    $script:RuntimeTestLease.Dispose()
    $holderCode = "`$h=[IO.FileStream]::new('$quotedRoot/suite.mutex','Open','ReadWrite','None'); try { Set-Content '$quotedRoot/replacement.held' 1; while(-not(Test-Path '$quotedRoot/replacement.release')) { Start-Sleep -Milliseconds 50 } } finally { `$h.Dispose() }"
    $replacement = Start-Fixture $holderCode 'replacement'; $children += $replacement
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path "$root/replacement.held") -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    Check (Test-Path "$root/replacement.held") 'different process now owns the mutex without refreshing the stale receipt'
    $follower = Start-Fixture ". '$helper'; Enter-RuntimeTestSuite -LockPath '$quotedRoot/suite.mutex'; Set-Content '$quotedRoot/stale.entered' 1" 'stale-follower'; $children += $follower
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not $follower.HasExited -and [string](Get-Content "$root/stale-follower.out" -Raw) -notmatch 'Waiting for another' -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    Check (-not $follower.HasExited -and [string](Get-Content "$root/stale-follower.out" -Raw) -match 'Waiting for another' -and -not (Test-Path "$root/stale.entered")) 'disposed ancestor env cannot bypass a replacement owner'
    Set-Content "$root/replacement.release" 1
    Check ($replacement.WaitForExit(30000) -and $replacement.ExitCode -eq 0 -and $follower.WaitForExit(30000) -and $follower.ExitCode -eq 0 -and (Test-Path "$root/stale.entered")) 'stale follower enters only after the replacement releases'
} finally {
    if ($script:RuntimeTestLease) { $script:RuntimeTestLease.Dispose() }
    foreach ($child in $children) { if (-not $child.HasExited) { $child.Kill($true); $child.WaitForExit() }; $child.Dispose() }
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) }
}
