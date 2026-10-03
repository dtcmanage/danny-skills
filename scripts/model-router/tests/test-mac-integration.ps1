Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../resolve-model.ps1')
. (Join-Path $PSScriptRoot '../publish-roster.ps1')
. (Join-Path $PSScriptRoot '../run-router-cadence.ps1')
. (Join-Path $PSScriptRoot '../register-router-schedules.ps1')
. (Join-Path $PSScriptRoot '../canary/run-canary.ps1')
. (Join-Path $PSScriptRoot '../update-outcomes.ps1')
$script:passed = 0
function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++; Write-Output "PASS: $Name"
}
function Assert-Owner([scriptblock]$Action, [string]$Name) {
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-True ($message -like 'ROUTER_WINDOWS_OWNER:*Windows*') $Name
}
function New-TestRoster {
    $r = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json
    $r.approved = $true; $r.approved_at = '2026-10-02T12:00:00Z'
    return $r
}
$prior = @{}
foreach ($key in @('DT_MODEL_ROUTER_STATE','DT_MODEL_ROUTER_SHARED','DT_MODEL_ROUTER_CODEX_SESSIONS','DT_MODEL_ROUTER_ALERT_TRANSPORT','DT_MODEL_ROUTER_CLAUDE_CREDENTIALS')) { $prior[$key] = [Environment]::GetEnvironmentVariable($key) }
$priorFetcher = $script:RouterClaudeUsageFetcher
$script:RouterClaudeUsageFetcher = { param($Token) throw 'Unexpected live quota fetch in fixture' }
$temp = Join-Path ([IO.Path]::GetTempPath()) ('mac-integration-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null
$platformFixture = [pscustomobject]@{ Value = 'Windows' }
Set-Item Function:Get-RouterPlatform -Value ({ return $platformFixture.Value }.GetNewClosure())
try {
    $win = Join-Path $temp 'windows'; $mac = Join-Path $temp 'mac'; $shared = Join-Path $temp 'synced'
    $env:DT_MODEL_ROUTER_STATE = $win; $env:DT_MODEL_ROUTER_SHARED = $shared
    $env:DT_MODEL_ROUTER_CODEX_SESSIONS = Join-Path $temp 'sessions'
    $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = Join-Path $temp 'missing-credentials.json'
    Assert-True ((Get-RouterClaudeCredential).status -eq 'missing') 'fixture selects exclusive missing credential source'
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = Join-Path $temp 'transport.ps1'
    Set-Content -LiteralPath $env:DT_MODEL_ROUTER_ALERT_TRANSPORT -Value 'param($request) throw "Unexpected alert send"'
    $main = Join-Path $temp 'repo'; $tree = Join-Path $temp 'tree'
    $gitDir = Join-Path $main '.git/worktrees/fixture'
    [IO.Directory]::CreateDirectory($gitDir) | Out-Null
    [IO.Directory]::CreateDirectory($tree) | Out-Null
    Set-Content -LiteralPath (Join-Path $tree '.git') -Value "gitdir: $gitDir"
    Set-Content -LiteralPath (Join-Path $gitDir 'commondir') -Value '../..'
    $mainPath = Get-RouterMainCheckout -ScriptRoot $main
    $treePath = Get-RouterMainCheckout -ScriptRoot $tree
    Assert-True ($mainPath -eq $treePath) 'Git common metadata yields same main path in worktree'
    $windowsDefault = Get-RouterStatePath -Platform Windows -MainCheckout $mainPath -StateOverride ''
    Assert-True ($windowsDefault -eq (Join-Path $temp 'model-router/state')) 'Windows default unchanged'
    $macDefault = Get-RouterStatePath -Platform MacOS -MainCheckout $mainPath -UserHome $temp -StateOverride ''
    Assert-True ($macDefault -eq (Join-Path $temp 'Library/Application Support/DannyModelRouter') -and -not (Test-Path $macDefault)) 'Mac default lookup is pure'
    Assert-True ($macDefault -eq (Get-RouterStatePath -Platform MacOS -MainCheckout $treePath -UserHome $temp -StateOverride '')) 'Mac runtime equal across worktrees'
    Assert-True ((Get-RouterSharedDir -MainCheckout $mainPath -SharedOverride '' -StateOverride '') -eq (Get-RouterSharedDir -MainCheckout $treePath -SharedOverride '' -StateOverride '')) 'shared path equal across worktrees'
    Assert-True ((Get-RouterSharedDir -MainCheckout $mainPath -SharedOverride '' -StateOverride '') -eq (Join-Path $temp 'model-router/shared')) 'shared default canonical sibling'
    Assert-True ((Get-RouterSharedDir -SharedOverride '') -eq (Join-Path $win 'shared')) 'state override contains shared fallback'
    Assert-True ((Get-RouterSharedDir) -eq $shared -and -not (Test-Path $shared)) 'explicit shared override wins without mkdir'
    $null = Get-RouterStateDir
    $r = New-TestRoster
    $r.jobs.coder.first_effort = 'low'
    $r | Add-Member -NotePropertyName credential -NotePropertyValue 'fixture-secret'
    $r.jobs.coder | Add-Member -NotePropertyName token -NotePropertyValue 'fixture-secret'
    Write-RouterJsonAtomic -Path (Join-Path $win 'roster.json') -Value $r
    Set-Content -LiteralPath (Join-Path $win 'credentials.json') -Value 'fixture-secret'
    function git { throw 'Publisher must not invoke Git' }
    $env:DT_MODEL_ROUTER_SHARED = ''
    Publish-RouterRoster
    Assert-True (Test-Path (Join-Path $win 'shared/roster.json')) 'state-only override contains actual publication'
    $env:DT_MODEL_ROUTER_SHARED = $shared
    Publish-RouterRoster
    $snapshot = Join-Path $shared 'roster.json'
    $snapshotText = Get-Content -LiteralPath $snapshot -Raw
    Assert-True ($snapshotText -notmatch 'fixture-secret|credential|token' -and @(Get-ChildItem $shared -Force).Count -eq 1) 'only routing fields are synced, no secrets or runtime files'
    Assert-True (@(Test-RouterRoster (Read-RouterJsonObject $snapshot)).Count -eq 0) 'published roster validates'
    $bytes = [IO.File]::ReadAllBytes($snapshot)
    Assert-True (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) -and @(Get-ChildItem $shared -Filter '*.tmp' -Force).Count -eq 0) 'publication uses UTF8 without BOM and cleans atomic temp'
    Assert-True ((Read-RouterRoster).source -eq 'state') 'Windows reads local authority'
    $env:DT_MODEL_ROUTER_STATE = $mac; $platformFixture.Value = 'MacOS'
    Assert-True ((Read-RouterRoster).source -eq 'shared' -and -not (Test-Path $mac)) 'Mac reads synced approved roster without creating runtime'
    function Get-RouterVendorBlocked { param($Vendor) return $false }
    $catalog = [pscustomobject]@{models=@([pscustomobject]@{slug='gpt-6.1-sol';visibility='list'})}
    $approvedPick = Resolve-RouterModel -Category complex-coding -SkipModelCheck -Catalog $catalog
    Assert-True ($approvedPick.roster_source -eq 'shared' -and $approvedPick.model -eq $r.jobs.coder.first -and $approvedPick.effort -eq 'low') 'Mac resolver uses synced approved slot and effort'
    $null = Get-RouterStateDir
    Write-RouterJsonAtomic -Path (Join-Path $mac 'roster.json') -Value (New-TestRoster)
    $r.approved = $false
    Write-RouterJsonAtomic -Path $snapshot -Value $r
    Assert-True ((Read-RouterRoster).source -eq 'default') 'revocation cannot revive approved local Mac roster'
    $revokedPick = Resolve-RouterModel -Category complex-coding -SkipModelCheck -Catalog $catalog
    Assert-True ($revokedPick.roster_source -eq 'default' -and $revokedPick.effort -eq 'medium' -and @($revokedPick.alerts | Where-Object { $_ -like 'router-roster-invalid: ROSTER_NOT_APPROVED:*' }).Count -eq 1) 'Mac revocation restores default effort and unapproved alert'
    Remove-Item -LiteralPath $snapshot
    Assert-True ((Read-RouterRoster).source -eq 'default') 'missing shared snapshot defaults despite local approved roster'
    $missingPick = Resolve-RouterModel -Category complex-coding -SkipModelCheck -Catalog $catalog
    Assert-True ($missingPick.alerts -contains 'router-roster-missing') 'missing shared snapshot alerts even with local Mac roster'
    Remove-Item -LiteralPath (Join-Path $mac 'roster.json')
    Set-Content -LiteralPath $snapshot -Value '{bad'
    $read = Read-RouterRoster
    Assert-True ($read.source -eq 'default' -and $read.validation_error -like 'ROSTER_PARSE:*') 'malformed snapshot defaults with validation error'
    Set-Content -LiteralPath $snapshot -Value '{}'
    Assert-True ((Read-RouterRoster).source -eq 'default' -and (Read-RouterRoster).validation_error -match 'ROSTER_FIELD') 'structurally invalid snapshot defaults'
    $bad = New-TestRoster; $bad.jobs.coder.first = 'gpt-6-astra'
    Write-RouterJsonAtomic -Path $snapshot -Value $bad
    Assert-True ((Read-RouterRoster).validation_error -match 'ROSTER_FRONTIER') 'every shared read checks schema and model rules'
    function Get-RouterVendorBlocked { param($Vendor) return $false }
    $pick = Resolve-RouterModel -Category complex-coding -SkipModelCheck -Catalog ([pscustomobject]@{models=@([pscustomobject]@{slug='gpt-6.1-sol';visibility='list'})})
    Assert-True ($pick.roster_source -eq 'default' -and @($pick.alerts | Where-Object { $_ -like 'router-roster-invalid:*' }).Count -eq 1) 'Mac invalid snapshot retains resolver alert semantics without sends'
    # Reimport the real vendor functions after the resolver-only stub.
    . (Join-Path $PSScriptRoot '../vendor-limits.ps1')
    $platformFixture.Value = 'Windows'; $env:DT_MODEL_ROUTER_STATE = $win
    $null = Add-RouterVendorBlock -Vendor codex -ResetAtUtc ([datetimeoffset]::UtcNow.AddHours(2)) -Reason quota
    $usage = [pscustomobject]@{used_percent=97; resets_at_utc=[datetimeoffset]::UtcNow.AddDays(1).ToString('o'); observed_at_utc=[datetimeoffset]::UtcNow.ToString('o'); credential_locator_identity=(Get-RouterClaudeCredentialIdentity)}
    Write-RouterJsonAtomic -Path (Join-Path $win 'claude-usage.json') -Value $usage
    Assert-True ((Get-RouterClaudeUsage).used_percent -eq 97 -and (Get-RouterVendorBlocked codex)) 'Windows local observations recorded'
    $platformFixture.Value = 'MacOS'; $env:DT_MODEL_ROUTER_STATE = $mac
    Assert-True (-not (Test-Path (Join-Path $mac 'claude-usage.json')) -and -not (Get-RouterVendorBlocked codex)) 'Mac does not import Windows usage or refusal reset'
    $usage.used_percent = 11
    $usage.credential_locator_identity = Get-RouterClaudeCredentialIdentity
    Write-RouterJsonAtomic -Path (Join-Path $mac 'claude-usage.json') -Value $usage
    $null = Add-RouterVendorBlock -Vendor claude -ResetAtUtc ([datetimeoffset]::UtcNow.AddHours(1)) -Reason quota
    Assert-True ((Get-RouterClaudeUsage).used_percent -eq 11) 'Mac reads its own fresh usage cache'
    $platformFixture.Value = 'Windows'; $env:DT_MODEL_ROUTER_STATE = $win
    Assert-True ((Get-RouterClaudeUsage).used_percent -eq 97 -and @(Read-RouterJsonArray (Join-Path $win 'vendor-blocks.json')).Count -eq 1) 'Mac local writes cannot alter Windows observations'
    $platformFixture.Value = 'MacOS'
    $guardState = Join-Path $temp 'guard-state'; $env:DT_MODEL_ROUTER_STATE = $guardState
    foreach ($action in @('Seed','Approve','Revoke','DeclineDrift')) {
        $options = @{}; $options[$action] = $true
        if ($action -eq 'DeclineDrift') { $options.Job = 'coder' }
        Assert-Owner { & (Join-Path $PSScriptRoot '../approve-roster.ps1') @options } "Mac refuses $action"
    }
    Assert-Owner { Publish-RouterRoster } 'Mac refuses publication'
    Assert-Owner { Invoke-RouterCadence -CheckOnly } 'Mac refuses cadence'
    Assert-Owner { Invoke-RouterCategoryResearch -Categories routine-coding -Models gpt-6.1-sol } 'Mac refuses direct research'
    Assert-Owner { Build-RouterRosterProposal } 'Mac refuses direct proposal construction'
    Assert-Owner { Update-RouterOutcomes } 'Mac refuses outcome import and drift proposal construction'
    Assert-Owner { Invoke-RouterModelCheck -Force } 'Mac refuses direct release polling'
    Assert-Owner { Register-RouterSchedules } 'Mac refuses schedule registration'
    Assert-Owner { Invoke-RouterCanary -DryRun } 'Mac refuses canary'
    Assert-Owner { Invoke-RouterModelCheck -Force } 'Mac refuses new-model benchmark trigger'
    . (Join-Path $PSScriptRoot '../bench/run-bench.ps1')
    $guardState = Join-Path $temp 'bench-guard-no-create'
    Assert-Owner { Invoke-RouterBench -Job coder -Candidate gpt-6.1-sol -Incumbent gpt-6.1-sol -StateDir $guardState } 'Mac refuses direct benchmark'
    Assert-True (-not (Test-Path $guardState)) 'direct benchmark guard precedes state creation'
    $guardScript = Join-Path $temp 'mac-bench-cli-guard.ps1'
    $guardRunner = (Join-Path $PSScriptRoot '../bench/run-bench.ps1').Replace("'", "''")
    $guardStateQuoted = $guardState.Replace("'", "''")
    [IO.File]::WriteAllText($guardScript, "function Get-RouterPlatform { 'MacOS' }`n& '$guardRunner' -Jobs coder -StateDir '$guardStateQuoted'", [Text.UTF8Encoding]::new($false))
    $guardOutput = & pwsh -NoProfile -File $guardScript 2>&1
    Assert-True ($LASTEXITCODE -ne 0 -and ($guardOutput | Out-String) -match 'ROUTER_WINDOWS_OWNER:' -and -not (Test-Path $guardState)) 'CLI benchmark guard precedes state creation'
    Assert-Owner { & (Join-Path $PSScriptRoot '../cost-report.ps1') } 'Mac refuses weekly report'
    $collector = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../skills/dt-build/scripts/collect-usage.ps1'))
    $collectorOutput = & $collector -OutDir $guardState -Quiet | Out-String
    Assert-True ($collectorOutput -match 'owned by Windows' -and -not (Test-Path $guardState)) 'Mac build intake skips reporting collector before any writes'
    $show = & (Join-Path $PSScriptRoot '../approve-roster.ps1') -Show | Out-String
    Assert-True ($show -match 'Current roster' -and -not (Test-Path $guardState)) 'Mac Show is permitted and all guards precede state creation'
    $platformFixture.Value = 'Windows'; $env:DT_MODEL_ROUTER_STATE = $win
    Write-RouterJsonAtomic -Path (Join-Path $win 'roster.json') -Value (New-TestRoster)
    $null = & (Join-Path $PSScriptRoot '../approve-roster.ps1') -Seed
    $null = & (Join-Path $PSScriptRoot '../approve-roster.ps1') -Approve
    Assert-True ((Read-RouterJsonObject $snapshot).approved) 'approval automatically publishes'
    $null = & (Join-Path $PSScriptRoot '../approve-roster.ps1') -Revoke
    Assert-True (-not (Read-RouterJsonObject $snapshot).approved) 'revocation automatically publishes false'
    Write-RouterJsonAtomic -Path (Join-Path $win 'roster.json') -Value (New-TestRoster)
    function Invoke-RouterModelCheck { param([switch]$Force,$Now) return [pscustomobject]@{new_models=@()} }
    function Add-RouterCadenceRefreshes { param($Now) return 0 }
    function Remove-RouterResolvedResearchFailures { param($Now) }
    $null = Invoke-RouterCadence -CheckOnly
    Assert-True ((Read-RouterJsonObject $snapshot).approved) 'cadence intake publishes existing approved state'
    Set-Content -LiteralPath (Join-Path $win 'roster.json') -Value '{bad'
    $errorText = ''; try { Publish-RouterRoster } catch { $errorText = $_.Exception.Message }
    Assert-True ($errorText -and -not (Test-Path $snapshot)) 'invalid authority fails publication and removes stale snapshot'
    Write-RouterJsonAtomic -Path (Join-Path $win 'roster.json') -Value (New-TestRoster)
    Publish-RouterRoster
    Remove-Item -LiteralPath (Join-Path $win 'roster.json')
    Publish-RouterRoster
    Assert-True (-not (Test-Path $snapshot)) 'missing authority clears stale published snapshot'
    # Exercise direct Python writers with an emulated OS; guards precede argument parsing and writes.
    $python = (Get-Command python -ErrorAction Stop).Source
    foreach ($relative in @('../cost_report.py','../../../skills/dt-build/scripts/collect-usage.py')) {
        $target = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $relative))
        $probe = Join-Path $temp 'python-owner-probe.py'
        $pythonProbe = @'
import pathlib, runpy, sys
target = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
sys.platform = 'darwin'
sys.argv = [str(target), '--state-dir', str(root)]
try:
    runpy.run_path(str(target), run_name='__main__')
except SystemExit as exc:
    if 'ROUTER_WINDOWS_OWNER' not in str(exc):
        raise
assert not root.exists(), 'non-Windows writer created state'
print('PASS: direct Python writer has no Mac effects')
'@
        [IO.File]::WriteAllText($probe,$pythonProbe,[Text.UTF8Encoding]::new($false))
        & $python $probe $target (Join-Path $temp 'python-mac-state') *> (Join-Path $temp 'python-probe.log')
        Assert-True ($LASTEXITCODE -eq 0) "Mac refuses Python writer $relative"
    }
    # Hold a publisher after reading approved=true; a concurrent revoke must wait, then publish false last.
    Write-RouterJsonAtomic -Path (Join-Path $win 'roster.json') -Value (New-TestRoster)
    $child = Join-Path $temp 'concurrent-publication.ps1'
    $childBody = @'
param($RouterRoot,$State,$Shared,$Signal,$Release,[switch]$Probe)
$ErrorActionPreference='Stop'
$env:DT_MODEL_ROUTER_STATE=$State; $env:DT_MODEL_ROUTER_SHARED=$Shared
. (Join-Path $RouterRoot 'publish-roster.ps1')
if ($Probe) {
    try { Use-RouterRosterMutex -TimeoutMs 100 -Body {throw 'UNEXPECTED_LOCK_ENTRY'} }
    catch { if ($_.Exception.Message -like 'ROUTER_ROSTER_LOCK_TIMEOUT:*') {exit 0}; throw }
    exit 1
}
$script:originalValidator=${function:Test-RouterRoster}
function Test-RouterRoster {
    param($Roster)
    Set-Content -LiteralPath $Signal -Value 'captured'
    $deadline=[datetimeoffset]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $Release)) {
        if ([datetimeoffset]::UtcNow -gt $deadline) {throw 'TEST_RELEASE_TIMEOUT'}
        Start-Sleep -Milliseconds 20
    }
    & $script:originalValidator -Roster $Roster
}
Publish-RouterRoster
'@
    [IO.File]::WriteAllText($child,$childBody,[Text.UTF8Encoding]::new($false))
    $routerRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
    $signal=Join-Path $temp 'captured'; $release=Join-Path $temp 'release'
    $pwsh=(Get-Command pwsh -ErrorAction Stop).Source
    function Start-IsolatedChild([string[]]$ChildArgs,[string]$Name) {
        $quoted=@($ChildArgs | ForEach-Object {'"'+$_.Replace('"','\"')+'"'})
        Start-Process -FilePath $pwsh -ArgumentList $quoted -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $temp "$Name.out") -RedirectStandardError (Join-Path $temp "$Name.err")
    }
    $publisher=Start-IsolatedChild @('-NoProfile','-File',$child,$routerRoot,$win,$shared,$signal,$release) 'publisher'
    $deadline=[datetimeoffset]::UtcNow.AddSeconds(15)
    while (-not (Test-Path $signal)) {if ([datetimeoffset]::UtcNow -gt $deadline) {$publisher.Kill($true);throw 'TEST_CAPTURE_TIMEOUT'}; Start-Sleep -Milliseconds 20}
    $revoker=Start-IsolatedChild @('-NoProfile','-File',(Join-Path $routerRoot 'approve-roster.ps1'),'-Revoke') 'revoker'
    try {
        Start-Sleep -Milliseconds 200
        Assert-True (-not $revoker.HasExited) 'concurrent revocation waits for publisher lock'
        Set-Content -LiteralPath $release -Value 'continue'
        if (-not $publisher.WaitForExit(15000) -or -not $revoker.WaitForExit(15000)) {throw 'TEST_CHILD_TIMEOUT'}
        Assert-True ($publisher.ExitCode -eq 0 -and $revoker.ExitCode -eq 0 -and -not (Read-RouterJsonObject $snapshot).approved -and -not (Read-RouterJsonObject (Join-Path $win 'roster.json')).approved) 'concurrent publisher cannot resurrect revoked roster'
    } finally {foreach($process in @($publisher,$revoker)){if (-not $process.HasExited){$process.Kill($true)};$process.Dispose()}}
    Use-RouterRosterMutex -Body {
        $probeProcess=Start-IsolatedChild @('-NoProfile','-File',$child,$routerRoot,$win,$shared,$signal,$release,'-Probe') 'mutex-probe'
        try {if(-not $probeProcess.WaitForExit(15000)){$probeProcess.Kill($true);throw 'TEST_MUTEX_TIMEOUT'}; Assert-True ($probeProcess.ExitCode -eq 0) 'roster lock timeout is bounded across processes'} finally {$probeProcess.Dispose()}
    }
    Assert-True (@(Get-ChildItem $temp -Recurse -File | Where-Object { -not $_.FullName.StartsWith($temp + [IO.Path]::DirectorySeparatorChar) }).Count -eq 0) 'fixture writes remain inside isolated directory'
    Write-Output "SUMMARY: $script:passed passed"
} finally {
    $script:RouterClaudeUsageFetcher = $priorFetcher
    foreach ($key in $prior.Keys) { [Environment]::SetEnvironmentVariable($key, $prior[$key]) }
    if ([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
