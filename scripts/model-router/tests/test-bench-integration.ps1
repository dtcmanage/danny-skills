Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Child suites have isolated function scopes, checked exits, and one numeric summary.
function Invoke-IntegrationChild([string]$Name, [string]$SummaryPattern) {
    $logRoot=Join-Path $env:TEMP ('bench-child-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($logRoot)
    $out=Join-Path $logRoot 'stdout.log'; $err=Join-Path $logRoot 'stderr.log'
    $child=Start-Process pwsh -WindowStyle Hidden -ArgumentList @('-NoProfile','-File',('"'+(Join-Path $PSScriptRoot $Name)+'"')) -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
    if(-not $child.WaitForExit(300000)){ $child.Kill($true); throw "Child suite timed out: $Name; logs: $logRoot" }
    if($child.ExitCode -ne 0){ throw "Child suite failed: $Name (exit $($child.ExitCode)); logs: $logRoot; $((Get-Content $err -Tail 40) -join [Environment]::NewLine)" }
    $lines=@(Get-Content $out | Where-Object {$_ -match $SummaryPattern})
    if($lines.Count -ne 1 -or $lines[0] -notmatch $SummaryPattern){throw "Invalid child summary: $Name; logs: $logRoot"}
    return [int]$Matches[1]
}
$researchPassed=Invoke-IntegrationChild 'test-build-roster.ps1' '^TOTAL PASS: ([1-9]\d*)$'
$repairPassed=Invoke-IntegrationChild 'test-bench-repair.ps1' '^SUMMARY: ([1-9]\d*) passed; 0 failed$'
$researchOutput=@("TOTAL PASS: $researchPassed")
$researchSummaries = @($researchOutput | Where-Object { $_ -match '^TOTAL PASS: (\d+)$' })
if ($researchSummaries.Count -ne 1 -or $researchSummaries[0] -notmatch '^TOTAL PASS: ([1-9]\d*)$') { throw 'Research test summary missing or invalid' }
$researchPassed = [int]$Matches[1]
. (Join-Path $PSScriptRoot '../build-roster.ps1')
. (Join-Path $PSScriptRoot 'fixtures/bench-proposal-evidence.ps1')
$integrationChecks = 0
function Check([bool]$ok, [string]$name) { if (-not $ok) { throw $name }; $script:integrationChecks++ }
$prior = $env:DT_MODEL_ROUTER_STATE
$temp = Join-Path $env:TEMP ('bench-integration-' + [guid]::NewGuid().ToString('N'))
$env:DT_MODEL_ROUTER_STATE = $temp
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
$integrationFixture = Enter-RouterTestCodexHome
try {
    [IO.Directory]::CreateDirectory($temp) | Out-Null
    Initialize-TestBenchEvidence
    $roster = (Read-RouterRoster).roster
    $request = [pscustomobject]@{job='coder';incumbent=$roster.jobs.coder.first;effort=$roster.jobs.coder.first_effort}
    $bench = [pscustomobject]@{shadow=$false;raw_gate='pass';effort_down_qualified=$true;incumbent=@{passed=3};effort_down=[pscustomobject]@{model=$request.incumbent;effort='low';passed=3};report_paths=@{markdown='synthetic'}}
    $path = Join-Path $temp 'effort-proposals/coder.json'
    $bench = Add-TestBenchEvidence $bench
    foreach($badShadow in @($true, 'false', $null)) {
        $bench.shadow=$badShadow
        Save-RouterEffortProposal $request $bench
        Check (-not(Test-Path $path)) 'Unapproved or invalid shadow state writes no effort proposal'
    }
    $bench.PSObject.Properties.Remove('shadow')
    Save-RouterEffortProposal $request $bench
    Check (-not(Test-Path $path)) 'Missing shadow state writes no effort proposal'
    $bench | Add-Member -NotePropertyName shadow -NotePropertyValue $false
    Save-RouterEffortProposal $request $bench
    $path = Join-Path $temp 'effort-proposals/coder.json'
    if (-not (Test-Path $path)) { throw 'Qualified effort-only proposal missing' }
    $original = [IO.File]::ReadAllText($path)
    Save-RouterEffortProposal $request $bench
    if ([IO.File]::ReadAllText($path) -cne $original) { throw 'Same effort identity was rewritten' }
    $request.incumbent = 'stale-model'
    Save-RouterEffortProposal $request $bench
    if ([IO.File]::ReadAllText($path) -cne $original) { throw 'Stale model overwrote effort proposal' }
    $request.incumbent = $roster.jobs.coder.first
    $bench.raw_gate = 'unknown'
    Remove-Item -LiteralPath $path
    Save-RouterEffortProposal $request $bench
    if (Test-Path $path) { throw 'UNKNOWN wrote effort proposal' }
    $integrationChecks += 4
    $bench.raw_gate = 'pass'
    Save-RouterEffortProposal $request $bench
    $roster.approved = $true; $roster.approved_at = '2026-10-02T12:00:00Z'
    Write-RouterJsonAtomic (Join-Path $temp 'roster.json') $roster
    $siblings = ConvertTo-Json $roster.jobs.writer -Compress
    $approval = Join-Path $PSScriptRoot '../approve-roster.ps1'
    $show = & pwsh -NoProfile -File $approval -Show | Out-String
    Check ($show -match 'Effort proposal coder.*medium -> low.*pending') 'Show effort details'
    $null = & pwsh -NoProfile -File $approval -ApproveEffort -Job coder
    $live = Read-RouterJsonObject (Join-Path $temp 'roster.json')
    Check ($LASTEXITCODE -eq 0 -and $live.jobs.coder.first_effort -eq 'low') 'Effort approval changes stored effort'
    Check ((ConvertTo-Json $live.jobs.writer -Compress) -ceq $siblings) 'Effort approval preserves sibling'
    $published = Read-RouterJsonObject (Join-Path (Get-RouterSharedDir) 'roster.json')
    Check ($published.jobs.coder.first_effort -eq 'low') 'Effort approval publishes effort'
    $null = & pwsh -NoProfile -File $approval -RevokeEffort -Job coder
    Check ($LASTEXITCODE -eq 0 -and (Read-RouterJsonObject (Join-Path $temp 'roster.json')).jobs.coder.first_effort -eq 'medium') 'Effort revoke restores effort'
    $swap = Read-RouterJsonObject $path; $swap.status = 'pending'; Write-RouterJsonAtomic $path $swap
    $null = & pwsh -NoProfile -File $approval -DeclineEffort -Job coder
    Check ($LASTEXITCODE -eq 0 -and (Read-RouterJsonObject $path).status -eq 'declined') 'Effort decline records decision'
    $swap.status = 'pending'; $swap.current_effort = 'high'; Write-RouterJsonAtomic $path $swap
    $failure = & pwsh -NoProfile -File $approval -ApproveEffort -Job coder 2>&1 | Out-String
    Check ($LASTEXITCODE -ne 0 -and $failure -match 'EFFORT_STALE_ROSTER') 'Effort stale effort refuses approval'
    $swap.current_effort = 'medium'; $swap.model = 'stale-model'; Write-RouterJsonAtomic $path $swap
    $failure = & pwsh -NoProfile -File $approval -ApproveEffort -Job coder 2>&1 | Out-String
    Check ($LASTEXITCODE -ne 0 -and $failure -match 'EFFORT_STALE_ROSTER') 'Effort stale model refuses approval'
    $writerRequest=[pscustomobject]@{job='writer';incumbent=$roster.jobs.writer.first;effort='medium'}
    $writerBench=[pscustomobject]@{shadow=$false;gate='advisory';raw_gate='pass';effort_down_qualified=$true;incumbent=@{passed=1};effort_down=[pscustomobject]@{model=$writerRequest.incumbent;effort='low';passed=1};report_paths=@{markdown='synthetic-approved-writer'}}
    $writerBench = Add-TestBenchEvidence $writerBench
    Save-RouterEffortProposal $writerRequest $writerBench
    $writerPath=Join-Path $temp 'effort-proposals/writer.json'
    Check (Test-Path $writerPath) 'Approved writer advisory still proposes effort swap'
    $writerBefore=[IO.File]::ReadAllText($writerPath)
    $writerBench.shadow=$true
    Save-RouterEffortProposal $writerRequest $writerBench
    Check ([IO.File]::ReadAllText($writerPath) -ceq $writerBefore) 'Shadow result cannot replace existing approved proposal'
    "SUMMARY: $($researchPassed + $repairPassed + $integrationChecks) passed; 0 failed (research=$researchPassed; repair=$repairPassed; integration=$integrationChecks)"

} finally { $env:DT_MODEL_ROUTER_STATE = $prior; Exit-RouterTestCodexHome $integrationFixture }
