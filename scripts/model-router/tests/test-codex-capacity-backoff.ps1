Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
. (Join-Path $repoRoot 'scripts/invoke-codex-process.ps1')
$script:passed = 0
function Check([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++; Write-Host "PASS: $Name"
}
function Write-Utf8([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

# This entire suite uses PowerShell peers, temporary router state, and no Python.
$saved = @{}
foreach ($name in @('CODEX_HOME','DT_MODEL_ROUTER_STATE','DT_MODEL_ROUTER_CODEX_SESSIONS','DT_MODEL_ROUTER_CLAUDE_CREDENTIALS','DT_MODEL_ROUTER_ALERT_TRANSPORT','DT_BUILD_DISPATCH_SEAMS','DT_BUILD_RUN_PIN_VENDOR','DT_BUILD_RUN_PIN_MODEL','FS63_COUNTER','FS63_SUCCEED','FS63_SIGNAL','FS63_WORK_MS','FS63_TIME_JUMP_MS')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$temp = Join-Path $env:TEMP ('fs63-capacity-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try {
    foreach ($text in @('Selected model is at capacity','ERROR: Model is currently overloaded','Error: server temporarily at capacity','ERROR: service overloaded','ERROR: overloaded_error','ERROR: model gpt-6.1-sol is overloaded','Error: selected model is over capacity','ERROR: at-capacity refusal','ERROR: vendor overload','{"type":"error","message":"Selected model is at capacity"}',"ERROR: Selected model is at capacity`nWarning: no last agent message")) {
        Check ([bool](Get-CodexCapacitySignal $text)) "capacity diagnostic: $text"
    }
    foreach ($text in @('ERROR: usage limit reached: model is at capacity','ERROR: insufficient_quota; server overloaded','ERROR: rate limit reached; service overloaded','quoted: Selected model is at capacity','Source model_overloaded.ps1 failed','')) {
        Check ($null -eq (Get-CodexCapacitySignal $text)) "non-capacity diagnostic: $text"
    }

    $env:DT_BUILD_RUN_PIN_VENDOR = 'codex'; $env:DT_BUILD_RUN_PIN_MODEL = 'gpt-6.1-sol'
    $env:DT_MODEL_ROUTER_STATE = Join-Path $temp 'state'
    $env:DT_MODEL_ROUTER_CODEX_SESSIONS = Join-Path $temp 'sessions'
    $env:DT_MODEL_ROUTER_CLAUDE_CREDENTIALS = Join-Path $temp 'missing-credentials.json'
    $env:CODEX_HOME = Join-Path $temp 'codex-home'
    Write-Utf8 (Join-Path $env:CODEX_HOME 'models_cache.json') '{"fetched_at":"fixture","models":[{"slug":"gpt-6.1-sol","visibility":"list","priority":1,"supported_reasoning_levels":[{"effort":"medium"}]}]}'
    Write-Utf8 (Join-Path $env:DT_MODEL_ROUTER_STATE 'last-check.json') (@{checked_at=(Get-Date).ToString('o')} | ConvertTo-Json)
    $fixtureRoster = Get-Content (Join-Path $repoRoot 'references/model-router/default-roster.json') -Raw | ConvertFrom-Json
    $fixtureRoster.approved = $true; $fixtureRoster.approved_at = '2026-10-13T00:00:00Z'
    Write-Utf8 (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json') ($fixtureRoster | ConvertTo-Json -Depth 30)
    $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = Join-Path $temp 'no-alert.ps1'
    Write-Utf8 $env:DT_MODEL_ROUTER_ALERT_TRANSPORT 'param($request); throw "Unexpected alert transport call"'
    $env:DT_BUILD_DISPATCH_SEAMS = Join-Path $temp 'seams.ps1'
    Write-Utf8 $env:DT_BUILD_DISPATCH_SEAMS @'
$script:fs63Clock = [datetimeoffset]'2026-10-13T14:00:00Z'
$script:fs63Jumped = $false
$script:RouterDiagnosisClock = {
    # Simulate substantial completed work after the child exits, not a timeout.
    $activeProc = Get-Variable -Name proc -ValueOnly -ErrorAction SilentlyContinue
    if (-not $script:fs63Jumped -and $activeProc -and $activeProc.HasExited -and (Test-Path ($env:FS63_COUNTER + '.done'))) {
        $script:fs63Clock = $script:fs63Clock.AddMilliseconds([int]$env:FS63_TIME_JUMP_MS)
        $script:fs63Jumped = $true
    }
    $script:fs63Clock
}
$script:RouterDispatchSleep = {
    param($Milliseconds)
    $waiting = Get-Content ($env:FS63_COUNTER + '.output.provenance.json') -Raw | ConvertFrom-Json
    if ($waiting.failure_category -ne 'capacity' -or -not $waiting.capacity_backoffs.Count) { throw 'Wait provenance missing' }
    [IO.File]::AppendAllText(($env:FS63_COUNTER + '.sleeps'), "$Milliseconds`n")
    Start-Sleep -Milliseconds ([Math]::Min(20, $Milliseconds))
    $script:fs63Clock = $script:fs63Clock.AddMilliseconds($Milliseconds)
}
$script:RouterDiagnosisHttp = { throw 'Capacity must bypass status/connectivity probes' }
$script:RouterDiagnosisDns = { throw 'Capacity must bypass DNS probes' }
'@
    $project = Join-Path $temp 'project'; [void][IO.Directory]::CreateDirectory($project)
    & git -C $project init -q
    $prompt = Join-Path $temp 'prompt.md'
    Write-Utf8 $prompt 'fixture prompt'
    $fake = Join-Path $temp 'fake-codex.ps1'
    Write-Utf8 $fake @'
if ($args -contains '--version') { 'codex-cli fixture'; exit 0 }
if ($args -contains 'debug') { Get-Content (Join-Path $env:CODEX_HOME 'models_cache.json') -Raw; exit 0 }
$text = [Console]::In.ReadToEnd()
$n = if (Test-Path $env:FS63_COUNTER) { [int](Get-Content $env:FS63_COUNTER) + 1 } else { 1 }
[IO.File]::WriteAllText($env:FS63_COUNTER, [string]$n)
$out = [string]$args[[Array]::IndexOf([object[]]$args, '--output-last-message') + 1]
[IO.File]::AppendAllText(($env:FS63_COUNTER + '.calls'), ((@{argv=$args;prompt=$text;had_output=(Test-Path $out)} | ConvertTo-Json -Compress) + "`n"))
if ([int]$env:FS63_WORK_MS -gt 0) { Start-Sleep -Milliseconds ([int]$env:FS63_WORK_MS) }
if ($n -lt [int]$env:FS63_SUCCEED) {
    [IO.File]::WriteAllText($out, 'partial report must be discarded')
    [Console]::Error.WriteLine($env:FS63_SIGNAL)
    [IO.File]::WriteAllText(($env:FS63_COUNTER + '.done'), 'done')
    exit 1
}
[IO.File]::WriteAllText($out, 'complete report')
'@
    function Run-Case([string]$Name, [int]$Succeed, [string]$Signal, [int]$JumpMs = 0, [switch]$Defaults, [switch]$NoRetry) {
        $env:FS63_COUNTER = Join-Path $temp $Name
        $env:FS63_SUCCEED = [string]$Succeed; $env:FS63_SIGNAL = $Signal
        $env:FS63_WORK_MS = '0'; $env:FS63_TIME_JUMP_MS = [string]$JumpMs
        $out = $env:FS63_COUNTER + '.output'
        Write-Utf8 $out 'stale report'
        $wrapperArgs = @{ ProjectPath=$project; PromptPath=$prompt; OutputPath=$out; CodexCliPath=$fake; AdHoc=$true; Effort='medium'; Category='complex-coding'; SelectionReason='capacity fixture'; TimeoutMs=1000; Json=$true }
        # A script invocation (rather than -File argv) preserves the array parameter.
        $runner = Join-Path $temp ($Name + '.runner.ps1')
        $argFile = Join-Path $temp ($Name + '.args.json')
        if (-not $Defaults) { $wrapperArgs.CapacityBackoffMs = @(if (-not $NoRetry) { 5; 10; 20 }) }
        Write-Utf8 $argFile ($wrapperArgs | ConvertTo-Json)
        Write-Utf8 $runner @'
param($Wrapper, $ArgFile)
$params = Get-Content $ArgFile -Raw | ConvertFrom-Json -AsHashtable
& $Wrapper @params
'@
        & pwsh -NoProfile -File $runner (Join-Path $repoRoot 'skills/dt-build/scripts/invoke-codex-chunk.ps1') $argFile > ($out + '.stdout') 2> ($out + '.stderr')
        $code = $LASTEXITCODE
        if (-not (Test-Path ($out + '.provenance.json'))) { throw "Wrapper omitted provenance: $(Get-Content ($out + '.stderr') -Raw)" }
        $prov = Get-Content ($out + '.provenance.json') -Raw | ConvertFrom-Json
        $calls = @(Get-Content ($env:FS63_COUNTER + '.calls') | ConvertFrom-Json)
        $sleeps = @(if (Test-Path ($env:FS63_COUNTER + '.sleeps')) { Get-Content ($env:FS63_COUNTER + '.sleeps') })
        Check (@($calls | Where-Object had_output).Count -eq 0) "$Name removes stale and partial output before every exec"
        Check (@($calls | Where-Object { ($_.argv -join '|') -cne ($calls[0].argv -join '|') -or $_.prompt -cne $calls[0].prompt }).Count -eq 0) "$Name identical model effort prompt and output argv"
        Check ($prov.resolved_model -ceq 'gpt-6.1-sol' -and $prov.effort -ceq 'medium' -and [string]::IsNullOrEmpty($prov.escalated_from) -and -not $prov.backup_pick) "$Name honors run pin without escalation or vendor switch"
        Check (@($calls | Where-Object { $_.argv[[Array]::IndexOf([object[]]$_.argv, '--model') + 1] -cne 'gpt-6.1-sol' -or $_.argv -cnotcontains 'model_reasoning_effort="medium"' }).Count -eq 0) "$Name actual CLI argv honors pinned model and effort"
        Check (@($prov.dispatch_attempts).Count -eq $calls.Count) "$Name records every dispatch attempt"
        Check ($null -eq $prov.diagnosis -and $null -eq $prov.dispatch_diagnosis -and $prov.termination_reason -notmatch 'ROUTER_UNEXPLAINED') "$Name avoids unexplained and degraded diagnosis"
        $isQuota = $Signal -match 'usage limit'
        if (-not $isQuota) {
            Check (@($prov.dispatch_attempts | Where-Object { $_.exit_code -ne 0 -and ($_.failure_category -ne 'capacity' -or -not $_.failure_detail) }).Count -eq 0) "$Name retains matched capacity signal per failed attempt"
            Check ($prov.capacity_backoffs.Count -eq $sleeps.Count) "$Name persists each backoff before sleep"
            Check (([regex]::Matches((Get-Content ($out + '.stderr') -Raw), 'CODEX_CAPACITY_WAIT:')).Count -eq $sleeps.Count) "$Name logs every wait to stderr"
            foreach ($wait in $prov.capacity_backoffs) {
                Check ($wait.wait_started_et -match '2026-10-13 .* ET$' -and $wait.resume_after_et -match ' ET$' -and $wait.message -match 'same model gpt-6.1-sol and effort medium') "$Name wait includes ET times and retained selection"
            }
            Check (($sleeps -join ',') -eq $(if ($Defaults) { '300000,600000,1200000' } elseif ($NoRetry) { '' } elseif ($Succeed -eq 3) { '5,10' } else { '5,10,20' })) "$Name uses exact bounded backoff schedule"
            if ($code -eq 0) {
                Check ($prov.pass -and -not $prov.failure_category -and -not $prov.failure_detail -and (Get-Content $out -Raw) -eq 'complete report') "$Name later success replaces partial output cleanly"
            } else {
                Check (-not $prov.pass -and $prov.failure_category -ceq 'capacity' -and $prov.failure_detail -and $prov.termination_reason -match '^CODEX_CAPACITY_EXHAUSTED:' -and -not $prov.output_path -and -not $prov.output_sha256 -and -not (Test-Path $out)) "$Name exhaustion reports capacity and retains no partial output"
            }
            $stream = Get-Content ($out + '.stream.log') -Raw
            Check (([regex]::Matches($stream, '(?m)^' + [regex]::Escape($Signal) + '\r?$')).Count -eq ($calls.Count - $(if ($code -eq 0) { 1 } else { 0 }))) "$Name stream retains all refusal attempts"
        } else {
            Check ($code -ne 0 -and $prov.failure_category -ceq 'environment' -and $prov.failure_detail -ceq 'quota' -and $prov.termination_reason -match '^ROUTER_LIMIT:' -and $prov.vendor_block.vendor -eq 'codex' -and $calls.Count -eq 1 -and $sleeps.Count -eq 0) "$Name quota retains vendor-block path without capacity retry"
        }
        return $prov
    }
    $r = Run-Case 'recover' 3 'Selected model is at capacity'
    Check ($r.capacity_backoffs.Count -eq 2 -and $r.dispatch_attempts.Count -eq 3) 'recovery stops at first successful attempt'
    $r = Run-Case 'exhaust' 99 'ERROR: Model is currently overloaded'
    Check ($r.dispatch_attempts.Count -eq 4 -and $r.termination_reason -match '35ms') 'exhaustion is bounded to three waits and four calls'
    $r = Run-Case 'default' 99 'ERROR: server overloaded' -Defaults
    Check ($r.termination_reason -match '2100000ms') 'production schedule totals exactly 35 minutes'
    $r = Run-Case 'disabled' 99 'ERROR: service at capacity' -NoRetry
    Check ($r.dispatch_attempts.Count -eq 1) 'empty schedule fails capacity without immediate retry'
    $r = Run-Case 'long-job' 3 'Selected model is at capacity' 4440000
    Check ($r.pass -and $r.dispatch_attempts[0].duration_ms -ge 4440000) '74-minute prior work cannot consume fresh capacity attempt timeout'
    $r = Run-Case 'quota' 99 'ERROR: usage limit reached; selected model is at capacity'

    # -SingleDispatch: a capacity refusal fails closed after one child, with the production backoff schedule left in place.
    # The quota case above leaves a Codex vendor block; this case is a fresh capacity outage.
    Remove-Item -LiteralPath (Join-Path $env:DT_MODEL_ROUTER_STATE 'vendor-blocks.json') -Force -ErrorAction SilentlyContinue
    $env:FS63_COUNTER = Join-Path $temp 'single'; $env:FS63_SUCCEED = '99'; $env:FS63_SIGNAL = 'Selected model is at capacity'
    $env:FS63_WORK_MS = '0'; $env:FS63_TIME_JUMP_MS = '0'
    $out = $env:FS63_COUNTER + '.output'
    $argFile = Join-Path $temp 'single.args.json'
    Write-Utf8 $argFile (@{ ProjectPath=$project; PromptPath=$prompt; OutputPath=$out; CodexCliPath=$fake; AdHoc=$true; Effort='medium'; Category='complex-coding'; SelectionReason='single-dispatch fixture'; TimeoutMs=1000; Json=$true; SingleDispatch=$true } | ConvertTo-Json)
    & pwsh -NoProfile -File (Join-Path $temp 'recover.runner.ps1') (Join-Path $repoRoot 'skills/dt-build/scripts/invoke-codex-chunk.ps1') $argFile > ($out + '.stdout') 2> ($out + '.stderr')
    $code = $LASTEXITCODE
    if (-not (Test-Path ($env:FS63_COUNTER + '.calls'))) { throw "single-dispatch capacity never launched a child: $(Get-Content ($out + '.stderr') -Raw)" }
    $prov = Get-Content ($out + '.provenance.json') -Raw | ConvertFrom-Json
    $calls = @(Get-Content ($env:FS63_COUNTER + '.calls'))
    Check ($code -ne 0 -and $calls.Count -eq 1 -and @($prov.dispatch_attempts).Count -eq 1 -and @($prov.capacity_backoffs).Count -eq 0 -and -not (Test-Path ($env:FS63_COUNTER + '.sleeps'))) "single-dispatch capacity launches exactly one child and never waits (calls $($calls.Count))"
    Check ($prov.failure_category -ceq 'single-dispatch-refused' -and $prov.single_dispatch -eq $true -and $prov.single_dispatch_refused_branch -ceq 'capacity' -and $prov.termination_reason -match '^CODEX_SINGLE_DISPATCH_REFUSED: capacity:') "single-dispatch capacity fails closed with a distinct category in provenance ($($prov.failure_category); $($prov.termination_reason))"
    $prior = Get-Content (Join-Path $temp 'exhaust.output.provenance.json') -Raw | ConvertFrom-Json
    Check ($prior.single_dispatch -eq $false -and $null -eq $prior.single_dispatch_refused_branch) 'without -SingleDispatch provenance records single_dispatch false'

    # Shared process API classifies the same stderr without adding retries to its callers.
    $env:FS63_COUNTER = Join-Path $temp 'process'; $env:FS63_SUCCEED = '99'; $env:FS63_SIGNAL = 'ERROR: overloaded_error'
    $r = Invoke-CodexProcess -CodexPath $fake -Arguments @('--output-last-message', (Join-Path $temp 'process-output')) -Prompt 'fixture' -WorkingDirectory $project -TimeoutMs 10000
    Check ($r.exit_code -eq 1 -and $r.failure_category -ceq 'capacity' -and $r.failure_detail -ceq 'overloaded_error') 'shared process returns capacity and matched failure_detail'

    . (Join-Path $repoRoot 'scripts/model-router/update-outcomes.ps1')
    # No quality drift should be possible; a mistaken capacity denominator fails before bench/Python.
    function Invoke-RouterTriggeredComparison { throw 'Capacity incorrectly triggered quality drift' }
    $env:DT_MODEL_ROUTER_STATE = Join-Path $temp 'outcome-state'
    $sourceRepo = Join-Path $temp 'source-repo'
    $sources = Join-Path $temp 'sources.json'; Write-Utf8 $sources (ConvertTo-Json -InputObject @($sourceRepo))
    $roster = Get-Content (Join-Path $repoRoot 'references/model-router/default-roster.json') -Raw | ConvertFrom-Json
    $roster.approved = $true; $roster.approved_at = '2026-10-13T00:00:00Z'
    Write-Utf8 (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json') ($roster | ConvertTo-Json -Depth 30)
    foreach ($era in @('prior','recent','capacity')) {
        for ($i=1; $i -le 10; $i++) {
            $item = @{pass=($era -ne 'capacity'); resolved_model='gpt-6.1-sol'; category='complex-coding'; tier='complex'; chunk_id='M01'; attempt=1; at=$(if ($era -eq 'prior') {'2026-08-01T12:00:00Z'} else {'2026-10-12T12:00:00Z'}); failure_category=$(if ($era -eq 'capacity') {'capacity'} else {$null}); failure_detail=$(if ($era -eq 'capacity') {'Selected model is at capacity'} else {$null}); diagnosis=$(if ($era -eq 'capacity') {'unexplained'} else {$null})}
            Write-Utf8 (Join-Path $sourceRepo ".dt-build/$era-$i/M01.provenance.json") ($item | ConvertTo-Json)
        }
    }
    Write-Utf8 (Join-Path $sourceRepo '.dt-build/acceptance/acceptance-rows.jsonl') (@{status='FAIL'; model='gpt-6.1-sol'; category='complex-coding'; milestone_id='M01'; at='2026-10-12T12:00:00Z'; failure_category='capacity'; failure_detail='server overloaded'; diagnosis='unexplained'} | ConvertTo-Json -Compress)
    $r = Update-RouterOutcomes -Now ([datetime]'2026-10-13T12:00:00Z') -SourcesPath $sources
    $rows = @(Get-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'outcomes.jsonl') | ConvertFrom-Json)
    $capacity = @($rows | Where-Object failure_category -eq 'capacity')
    Check ($r.total_records -eq 31 -and $capacity.Count -eq 11) 'outcome import retains ten capacity provenance events and one acceptance event'
    Check (@($capacity | Where-Object { $_.diagnosis -or -not $_.failure_detail -or $_.escalated }).Count -eq 0) 'capacity mining preserves failure_detail and drops unexplained diagnosis on both paths'
    Check (@($r.alerts).Count -eq 0 -and @(Get-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'drift-marks.json') -Raw | ConvertFrom-Json).Count -eq 0) 'capacity vendor availability events leave 100-percent quality rate without drift'
    $r = Update-RouterOutcomes -Now ([datetime]'2026-10-13T12:00:00Z') -SourcesPath $sources
    Check ($r.new_records -eq 0 -and $r.total_records -eq 31) 'capacity outcome import remains idempotent'
    Write-Output "SUMMARY: $script:passed passed"
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    $resolvedTemp = [IO.Path]::GetFullPath($temp)
    if ($resolvedTemp.StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar) -and (Split-Path -Leaf $resolvedTemp) -like 'fs63-capacity-*') { Remove-Item -LiteralPath $resolvedTemp -Recurse -Force }
}
