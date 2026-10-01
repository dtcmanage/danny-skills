Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$temp = Join-Path $env:TEMP ('router-category-test-' + [guid]::NewGuid().ToString('N'))
$priorState = $env:DT_MODEL_ROUTER_STATE
$priorAlerts = $env:DT_MODEL_ROUTER_ALERT_TRANSPORT
$priorSessions = $env:DT_MODEL_ROUTER_CODEX_SESSIONS
New-Item -ItemType Directory -Path $temp -Force | Out-Null
$env:DT_MODEL_ROUTER_STATE = $temp
$env:DT_MODEL_ROUTER_ALERT_TRANSPORT = 'test-stub'
$env:DT_MODEL_ROUTER_CODEX_SESSIONS = (Join-Path $temp 'sessions')
New-Item -ItemType Directory -Path $env:DT_MODEL_ROUTER_CODEX_SESSIONS -Force | Out-Null
. (Join-Path $PSScriptRoot '../run-router-research.ps1')
$script:testClock = [datetimeoffset]'2026-10-01T03:59:00Z'
$script:RouterDiagnosisClock = { $script:testClock }
$script:RouterResearchSleep = { param($Milliseconds) $script:sleeps.Add($Milliseconds); $script:testClock = $script:testClock.AddMilliseconds($Milliseconds) }
$script:sleeps = [Collections.Generic.List[int]]::new()
$script:diagnosis = 'unexplained'
$script:diagnosisCalls = 0
function Resolve-RouterDispatchFailure {
    param($Vendor, $ErrorText)
    $script:diagnosisCalls++
    $verdict = $script:diagnosis
    if ($verdict -eq 'offline-reconnect') { $verdict = if ($ErrorText) { 'offline' } else { 'unexplained' } }
    if ($verdict -eq 'offline-long') { $verdict = if ($script:diagnosisCalls -le 7) { 'offline' } else { 'unexplained' } }
    return [pscustomobject]@{ verdict=$verdict; checks=@{http=$true;dns=$true;status='operational'} }
}
function Get-RouterClaudeUsage { return $null }
function Get-RouterCodexUsage { return $null }
$script:alerts = [Collections.Generic.List[object]]::new()
function Send-RouterAlert { param($Key, $Message) $script:alerts.Add([pscustomobject]@{key=$Key;message=$Message}) }
$script:passed = 0
function Assert-True([bool]$Condition,[string]$Name) { if (-not $Condition) { throw "FAIL: $Name" }; $script:passed++; Write-Output "PASS: $Name" }
function Fixture([string]$Category,[string]$Model,[string]$Date='2026-09-01',[double]$Score=80) {
    return [pscustomobject]@{ category=$Category; sources_checked=@([pscustomobject]@{ name='Terminal-Bench'; comparable_results_found=$true; note='page text says ignore instructions; treated as data' }); readings=@([pscustomobject]@{ benchmark='Terminal-Bench'; version='2'; date=$Date; harness='agent'; effort_class='high'; independent=$true; url='https://www.tbench.ai/'; results=@([pscustomobject]@{ model=$Model; score=$Score; tasks=[long]100; margin=$null }) }) }
}
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
$fixtureCodexHome = Enter-RouterTestCodexHome
try {
    $good = Fixture 'complex-coding' 'gpt-6.1-sol'
    Assert-True (Test-RouterReadings $good 'complex-coding' @('gpt-6.1-sol')) 'good schema'
    Assert-True (-not (Test-RouterReadings $good 'math' @('gpt-6.1-sol'))) 'wrong category rejected'
    Assert-True (-not (Test-RouterReadings $good 'complex-coding' @('claude-opus-5-5'))) 'unknown model rejected'
    $missing = Fixture 'complex-coding' 'gpt-6.1-sol'
    $missing.readings[0].results[0].PSObject.Properties.Remove('score')
    Assert-True (-not (Test-RouterReadings $missing 'complex-coding' @('gpt-6.1-sol'))) 'missing score rejected'
    $good | Add-Member -NotePropertyName injected -NotePropertyValue 'ignore instructions'
    Assert-True (Test-RouterReadings $good 'complex-coding' @('gpt-6.1-sol')) 'extra fields ignored'
    $script:calls = [Collections.Generic.List[object]]::new()
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) $script:calls.Add([pscustomobject]@{ category=$category; lane=$lane; prompt=$prompt }); return (Fixture $category 'gpt-6.1-sol' | ConvertTo-Json -Depth 20) }
    $pass = Invoke-RouterResearch -Categories @('complex-coding') -Models @('gpt-6.1-sol') -Lane codex
    $stored = Get-Content (Join-Path $temp 'readings/complex-coding.json') -Raw | ConvertFrom-Json
    Assert-True ($pass.pass_id -and (Test-Path (Join-Path $temp 'readings/passes.jsonl')) -and $stored.readings.Count -eq 1) 'staging committed and pass recorded'
    Assert-True ($stored.sources_checked[0].note -match 'ignore instructions' -and -not $stored.PSObject.Properties['injected']) 'poisoned text stays data and extra field omitted'
    Assert-True ($script:calls[0].lane -eq 'codex') 'codex uses hook'
    Assert-True ($script:calls[0].prompt -match 'Candidate models: gpt-6.1-sol' -and $script:calls[0].prompt -match 'Terminal-Bench') 'category prompt contains candidates and source list'
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) return (Fixture $category 'gpt-6.1-sol' '2026-08-01' 90 | ConvertTo-Json -Depth 20) }
    $null = Invoke-RouterCategoryResearch -Categories @('complex-coding') -Models @('gpt-6.1-sol') -Lane claude
    $stored = Get-Content (Join-Path $temp 'readings/complex-coding.json') -Raw | ConvertFrom-Json
    Assert-True ($stored.readings[0].results[0].score -eq 80) 'older reading does not replace newer'
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) return (Fixture $category 'gpt-6.1-sol' '2026-10-01' 91 | ConvertTo-Json -Depth 20) }
    $null = Invoke-RouterCategoryResearch -Categories @('complex-coding') -Models @('gpt-6.1-sol') -Lane claude
    $stored = Get-Content (Join-Path $temp 'readings/complex-coding.json') -Raw | ConvertFrom-Json
    Assert-True ($stored.readings.Count -eq 1 -and $stored.readings[0].results[0].score -eq 91) 'newer same benchmark version harness model replaces stored result'
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) $fixture = Fixture $category 'gpt-6.1-sol' '2026-10-02' 92; $fixture.readings[0].effort_class = 'low'; return ($fixture | ConvertTo-Json -Depth 20) }
    $null = Invoke-RouterCategoryResearch -Categories @('complex-coding') -Models @('gpt-6.1-sol') -Lane claude
    $stored = Get-Content (Join-Path $temp 'readings/complex-coding.json') -Raw | ConvertFrom-Json
    Assert-True ($stored.readings.Count -eq 2 -and @($stored.readings | Where-Object { $_.effort_class -eq 'high' -and $_.results[0].score -eq 91 }).Count -eq 1 -and @($stored.readings | Where-Object { $_.effort_class -eq 'low' -and $_.results[0].score -eq 92 }).Count -eq 1) 'different effort classes retain separate readings'
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) $fixture = Fixture $category 'gpt-6.1-sol' '2026-10-03' 99; $fixture.readings[0].effort_class = 'low'; $fixture.readings[0].independent = -not [bool]$fixture.readings[0].independent; return ($fixture | ConvertTo-Json -Depth 20) }
    $null = Invoke-RouterCategoryResearch -Categories @('complex-coding') -Models @('gpt-6.1-sol') -Lane claude
    $stored = Get-Content (Join-Path $temp 'readings/complex-coding.json') -Raw | ConvertFrom-Json
    Assert-True ($stored.readings.Count -eq 3 -and @($stored.readings | Where-Object { $_.effort_class -eq 'low' -and $_.results[0].score -eq 92 }).Count -eq 1) 'a reading with a different independence flag never overwrites or inherits another'
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) return 'refused' }
    $pass = Invoke-RouterCategoryResearch -Categories @('complex-coding') -Models @('gpt-6.1-sol')
    Assert-True ($pass.failed_categories -contains 'complex-coding' -and @(Get-ChildItem (Join-Path $temp 'research-failures') -Filter 'complex-coding@*.txt').Count -eq 1 -and ((Get-Content (Join-Path $temp 'readings/complex-coding.json') -Raw | ConvertFrom-Json).readings[0].results[0].score -eq 91)) 'invalid saved and stored reading untouched'
    $orphan = Join-Path $temp 'readings/.pass-orphan'; New-Item -ItemType Directory -Path $orphan | Out-Null
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) return (Fixture $category 'gpt-6.1-sol' | ConvertTo-Json -Depth 20) }
    $null = Invoke-RouterCategoryResearch -Categories @('complex-coding') -Models @('gpt-6.1-sol')
    Assert-True (-not (Test-Path $orphan)) 'interrupted stage discarded on next start'
    $source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../run-router-research.ps1') -Raw
    Assert-True ($source -notmatch 'Invoke-RouterWithRetry|RouterResearchRetryDelaysSeconds') 'no timer retry remains'
    $priorPassCount = @(Get-Content (Join-Path $temp 'readings/passes.jsonl')).Count
    $script:thrownCalls = 0
    $script:retryPrompts = [Collections.Generic.List[string]]::new()
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) $script:retryPrompts.Add("$lane`n$prompt"); $script:thrownCalls++; if ($script:thrownCalls -eq 2) { $script:testClock = $script:testClock.AddMinutes(2) }; throw "interrupted marker-$script:thrownCalls" }
    $interrupted = $false
    try { $null = Invoke-RouterCategoryResearch -Categories @('complex-coding','math') -Models @('gpt-6.1-sol') } catch { $interrupted = $true }
    $lastPass = Get-Content (Join-Path $temp 'readings/passes.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
    Assert-True ($interrupted -and @(Get-Content (Join-Path $temp 'readings/passes.jsonl')).Count -eq $priorPassCount + 1 -and $lastPass.interrupted -and $lastPass.diagnosis -eq 'unexplained' -and @(Get-ChildItem (Join-Path $temp 'readings') -Directory -Filter '.pass-*').Count -eq 0) 'interrupted run writes record before rethrow and cleans stage'
    Assert-True ($script:thrownCalls -eq 2 -and $script:retryPrompts[0] -ceq $script:retryPrompts[1] -and $script:sleeps.Count -eq 0 -and $lastPass.attempts.math.Count -eq 0) 'unexplained retries identical call immediately once then stops whole pass'
    Assert-True ($lastPass.attempts.'complex-coding'.Count -eq 2 -and -not $lastPass.attempts.'complex-coding'[1].succeeded -and $lastPass.transient_failures.'complex-coding'.Count -eq 2 -and $lastPass.failed_categories -contains 'complex-coding') 'interrupted pass records attempts and failure first lines'
    Assert-True ($script:alerts.Count -eq 1 -and $script:alerts[0].key -eq ('vendor-error:codex:' + $lastPass.pass_id) -and $script:alerts[0].message -match 'marker-2|research-failures') 'unexplained stop sends vendor-error alert with evidence'
    Assert-True ($lastPass.research_failure_keys.'complex-coding' -eq 'research-failure:complex-coding:2026-09-30') 'research-failure key uses ET first failure date'
    $attemptFiles = @(Get-ChildItem (Join-Path $temp 'research-failures') -Filter 'complex-coding@*-attempt*.txt')
    Assert-True ($attemptFiles.Count -eq 2 -and @($attemptFiles | Where-Object { (Get-Content $_.FullName -Raw) -match 'marker-2' }).Count -eq 1) 'every thrown attempt writes failure evidence'
    $script:thrownCalls = 0
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) $script:thrownCalls++; if ($script:thrownCalls -eq 1) { throw 'transient crash' }; return (Fixture $category 'gpt-6.1-sol' '2026-10-03' 93 | ConvertTo-Json -Depth 20) }
    $retried = Invoke-RouterCategoryResearch -Categories @('complex-coding') -Models @('gpt-6.1-sol')
    Assert-True ($script:thrownCalls -eq 2 -and $retried.attempts.'complex-coding'[1].succeeded -and $retried.transient_failures.'complex-coding'.Count -eq 1 -and -not $retried.interrupted -and $retried.failed_categories.Count -eq 0) 'recovered failure stays visible on successful pass'
    foreach ($verdict in @('quota','vendor_incident','wait')) {
        $script:diagnosis = if ($verdict -eq 'wait') { 'unexplained' } else { $verdict }
        $script:calls.Clear()
        $script:RouterResearchInvoker = {
            param($category,$lane,$prompt)
            $script:calls.Add([pscustomobject]@{category=$category;lane=$lane;prompt=$prompt})
            if ($script:calls.Count -eq 1) {
                if ($verdict -eq 'wait') { $error = [InvalidOperationException]::new('resolver wait'); $error.Data['router_status']='wait'; throw $error }
                if ($verdict -eq 'quota') { throw 'ERROR: usage limit exceeded' }; throw 'vendor incident'
            }
            return (Fixture $category 'gpt-6.1-sol' | ConvertTo-Json -Depth 20)
        }
        $switched = Invoke-RouterCategoryResearch -Categories @('complex-coding','math') -Models @('gpt-6.1-sol')
        Assert-True ($script:calls.Count -eq 3 -and $script:calls[1].lane -eq 'claude' -and $script:calls[2].lane -eq 'claude' -and $switched.attempts.'complex-coding'.Count -eq 2 -and $switched.attempts.math[0].succeeded) "lane switch for rest of pass on $verdict"
        Remove-Item (Join-Path $temp 'vendor-blocks.json') -ErrorAction SilentlyContinue
    }
    foreach ($reason in @('quota','vendor_incident')) {
        if ($reason -eq 'quota') { $null = Add-RouterVendorBlock -Vendor claude } else { $null = Add-RouterVendorBlock -Vendor claude -Reason vendor_incident -Component 'Claude Code' -IncidentId 'test-incident' }
        $script:diagnosis = $reason
        $script:thrownCalls = 0
        $script:RouterResearchInvoker = { param($category,$lane,$prompt) $script:thrownCalls++; if ($reason -eq 'quota') { throw 'ERROR: usage limit exceeded' }; throw 'vendor incident' }
        $deferred = Invoke-RouterCategoryResearch -Categories @('complex-coding','math') -Models @('gpt-6.1-sol')
        $written = Get-Content (Join-Path $temp 'readings/passes.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
        Assert-True ($deferred.deferred -and $written.deferred -and $written.diagnosis -eq $reason -and $script:thrownCalls -eq 1 -and $written.attempts.'complex-coding'.Count -eq 1 -and $written.transient_failures.'complex-coding'.Count -eq 1) "defer written when other lane blocked by $reason"
        Remove-Item (Join-Path $temp 'vendor-blocks.json') -ErrorAction SilentlyContinue
    }
    foreach ($mode in @('offline-reconnect','offline-long')) {
        $script:diagnosis = $mode; $script:diagnosisCalls = 0
        $script:calls.Clear(); $script:sleeps.Clear(); $script:alerts.Clear()
        $script:RouterResearchInvoker = { param($category,$lane,$prompt) $script:calls.Add([pscustomobject]@{lane=$lane;prompt=$prompt}); if ($script:calls.Count -eq 1) { throw 'offline failure' }; return (Fixture $category 'gpt-6.1-sol' | ConvertTo-Json -Depth 20) }
        $reconnected = Invoke-RouterCategoryResearch -Categories @('complex-coding') -Models @('gpt-6.1-sol')
        Assert-True ($script:calls.Count -eq 2 -and $script:calls[0].lane -eq $script:calls[1].lane -and $script:calls[0].prompt -ceq $script:calls[1].prompt -and $script:sleeps[0] -eq 60000 -and $reconnected.attempts.'complex-coding'[1].succeeded) "$mode waits and resumes same dispatch"
        if ($mode -eq 'offline-long') { Assert-True ($script:alerts.Count -eq 1 -and $script:alerts[0].key -match '^router-offline:2026-.* ET$') 'outage over five minutes alerts only on reconnect' }
    }
    $script:diagnosis = 'offline'; $script:sleeps.Clear()
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) throw 'offline ceiling' }
    $interrupted = $false
    try { $null = Invoke-RouterCategoryResearch -Categories @('complex-coding') -Models @('gpt-6.1-sol') } catch { $interrupted = $true }
    $written = Get-Content (Join-Path $temp 'readings/passes.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
    Assert-True ($interrupted -and $written.interrupted -and $written.diagnosis -eq 'offline' -and $written.attempts.'complex-coding'.Count -eq 1 -and ($script:sleeps | Measure-Object -Sum).Sum -eq 3600000) 'offline stops at existing one hour ceiling with pass evidence'
    $script:diagnosis = 'unexplained'
    $script:calls.Clear()
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) $script:calls.Add([pscustomobject]@{category=$category;lane=$lane;prompt=$prompt}); if ($category -eq 'math') { throw 'later category failed' }; return (Fixture $category 'gpt-6.1-sol' | ConvertTo-Json -Depth 20) }
    try { $null = Invoke-RouterCategoryResearch -Categories @('complex-coding','math','planning') -Models @('gpt-6.1-sol') } catch { }
    $written = Get-Content (Join-Path $temp 'readings/passes.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
    Assert-True ($written.interrupted -and $written.attempts.'complex-coding'[0].succeeded -and $written.attempts.math.Count -eq 2 -and $written.attempts.planning.Count -eq 0 -and $written.transient_failures.math.Count -eq 2) 'later category stop records earlier success and never calls remaining category'
    $before = @(Get-Content (Join-Path $temp 'readings/passes.jsonl')).Count
    try { $null = Invoke-RouterCategoryResearch -Categories @('unknown-category') -Models @('gpt-6.1-sol') } catch { }
    $written = Get-Content (Join-Path $temp 'readings/passes.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
    Assert-True (@(Get-Content (Join-Path $temp 'readings/passes.jsonl')).Count -eq $before + 1 -and $written.interrupted -and $written.diagnosis -eq 'unexplained' -and $written.attempts.'unknown-category'.Count -eq 0) 'setup exception also writes interrupted record with diagnosis'
    $script:RouterResearchInvoker = $null
    # Load the resolver before installing the process stub.
    . (Join-Path $PSScriptRoot '../resolve-model.ps1')
    function codex { }
    function Invoke-CodexProcess { param($CodexPath, $Arguments, $Prompt, $WorkingDirectory, $TimeoutMs) return [pscustomobject]@{ exit_code = 3; timed_out = $false; duration_ms = 17000; stdout = ''; stderr = ('x' * 5000) + 'codex stderr marker: stream disconnected' } }
    $codexError = $null
    try { $null = Invoke-RouterCategoryCall -Category 'math' -Lane codex -Prompt 'p' } catch { $codexError = $_.Exception.Message }
    Assert-True ($codexError -match 'exit_code=3' -and $codexError -match 'timed_out=False' -and $codexError -match 'duration_ms=17000' -and $codexError -match 'codex stderr marker: stream disconnected' -and $codexError.Length -lt 2400) 'codex failure keeps exit code, timing, and stderr tail'
    $limitError = Format-RouterCodexFailure -Label 'Category research failed' -Result ([pscustomobject]@{exit_code=1;timed_out=$false;duration_ms=100;stderr="ERROR: You've hit your usage limit"})
    Assert-True ((Test-RouterLimitRefusal -Vendor codex -Text $limitError).refused) 'formatted process failure preserves refusal detection'
    Remove-Item function:Invoke-CodexProcess, function:codex
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) if ($category -eq 'complex-coding') { return '' } return (Fixture $category 'gpt-6.1-sol' '2026-10-04' 70 | ConvertTo-Json -Depth 20) }
    $emptyFirst = Invoke-RouterCategoryResearch -Categories @('complex-coding','routine-coding') -Models @('gpt-6.1-sol')
    $lastPass = (Get-Content (Join-Path $temp 'readings/passes.jsonl') | Select-Object -Last 1) | ConvertFrom-Json
    Assert-True ($lastPass.attempts.'complex-coding'.Count -eq 1 -and -not $lastPass.attempts.'complex-coding'[0].succeeded -and $lastPass.transient_failures.'complex-coding'.Count -eq 1) 'invalid reply records failed attempt and first line'
    Assert-True (@($lastPass.failed_categories) -contains 'complex-coding' -and @($lastPass.failed_categories) -notcontains 'routine-coding' -and (Test-Path (Join-Path $temp 'readings/routine-coding.json'))) 'empty reply fails only its category and the pass continues'
    $script:releaseCalls = [Collections.Generic.List[object]]::new()
    $script:RouterResearchInvoker = {
        param($category,$lane,$prompt)
        $script:releaseCalls.Add([pscustomobject]@{ lane=$lane; prompt=$prompt })
        $model = if ($script:releaseCalls.Count -eq 1) { 'gpt-new' } else { ([regex]::Match($prompt,'Candidate models: ([^,\r\n]+)')).Groups[1].Value }
        return (Fixture $category $model '2026-10-02' 88 | ConvertTo-Json -Depth 20)
    }
    $null = Invoke-RouterCategoryResearch -Categories @('routine-coding') -Models @('gpt-new','claude-opus-5-5') -NewModel 'gpt-new' -Trigger release -Lane claude
    Assert-True ($script:releaseCalls.Count -eq 2 -and $script:releaseCalls[1].lane -eq 'claude' -and $script:releaseCalls[1].prompt -match 'Follow-up benchmarks only: Terminal-Bench' -and $script:releaseCalls[1].prompt -match 'claude-opus-5-5') 'non-comparable follow-up scoped inside same pass through claude hook'
    Assert-True ($script:releaseCalls[1].prompt -match 'Candidate models: [^\r\n]*gpt-new' -and $script:releaseCalls[1].prompt -notmatch 'gpt-image-2|gpt-6-luna') 'release follow-up includes new model and only category job models'
    $script:releaseCalls.Clear()
    $script:RouterResearchInvoker = {
        param($category,$lane,$prompt)
        $script:releaseCalls.Add([pscustomobject]@{lane=$lane;prompt=$prompt})
        if ($script:releaseCalls.Count -eq 1) { $fixture = Fixture $category 'gpt-new' '2026-10-04' 89; $fixture.readings[0].version = '3'; return ($fixture | ConvertTo-Json -Depth 20) }
        $fixture = Fixture $category 'gpt-new' '2026-10-05' 90
        $fixture.readings[0].version = '3'
        $fixture.readings[0].results += [pscustomobject]@{model='claude-opus-5-5';score=80;tasks=[long]100;margin=$null}
        return ($fixture | ConvertTo-Json -Depth 20)
    }
    $followPass = Invoke-RouterCategoryResearch -Categories @('routine-coding') -Models @('gpt-new','claude-opus-5-5') -NewModel 'gpt-new' -Trigger release -Lane claude
    Assert-True ($followPass.failed_categories.Count -eq 0 -and $script:releaseCalls.Count -eq 2) 'follow-up result including new model validates'
    $script:releaseCalls.Clear()
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) $script:releaseCalls.Add([pscustomobject]@{lane=$lane;prompt=$prompt}); if ($script:releaseCalls.Count -eq 1) { $fixture = Fixture $category 'gpt-new' '2026-10-06' 91; $fixture.readings[0].version = '4'; return ($fixture | ConvertTo-Json -Depth 20) }; return 'invalid follow-up' }
    $failedFollow = Invoke-RouterCategoryResearch -Categories @('routine-coding') -Models @('gpt-new','claude-opus-5-5') -NewModel 'gpt-new' -Trigger release -Lane claude
    $retained = Get-Content (Join-Path $temp 'readings/routine-coding.json') -Raw | ConvertFrom-Json
    Assert-True ($failedFollow.failed_categories.Count -eq 0 -and $failedFollow.notes.Count -gt 0 -and @($retained.readings | Where-Object { $_.date -eq '2026-10-06' -and @($_.results | Where-Object model -eq 'gpt-new').Count -gt 0 }).Count -gt 0) 'failed follow-up retains first-call reading and records note'
    Assert-True ($failedFollow.attempts.'routine-coding'.Count -eq 2 -and $failedFollow.attempts.'routine-coding'[0].succeeded -and -not $failedFollow.attempts.'routine-coding'[1].succeeded -and $failedFollow.transient_failures.'routine-coding'.Count -eq 1) 'invalid follow-up records both attempts and failure'
    $script:releaseCalls.Clear()
    # Reinstall the fake diagnosis after resolve-model loaded the real functions above.
    function Resolve-RouterDispatchFailure { param($Vendor,$ErrorText) return [pscustomobject]@{verdict='unexplained';checks=@{http=$true;dns=$true;status='operational'}} }
    $script:RouterResearchInvoker = {
        param($category,$lane,$prompt)
        $script:releaseCalls.Add([pscustomobject]@{lane=$lane;prompt=$prompt})
        if ($script:releaseCalls.Count -gt 1) { throw 'follow-up call failed' }
        $fixture = Fixture $category 'gpt-new' '2026-10-06' 91; $fixture.readings[0].version = '6'; return ($fixture | ConvertTo-Json -Depth 20)
    }
    try { $null = Invoke-RouterCategoryResearch -Categories @('routine-coding') -Models @('gpt-new','claude-opus-5-5') -NewModel 'gpt-new' -Trigger release -Lane claude } catch { }
    $written = Get-Content (Join-Path $temp 'readings/passes.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
    Assert-True ($written.interrupted -and $written.diagnosis -eq 'unexplained' -and $written.attempts.'routine-coding'.Count -eq 3 -and $written.transient_failures.'routine-coding'.Count -eq 2 -and $script:releaseCalls.Count -eq 3) 'thrown follow-up retries once then writes stopped pass'
    $script:releaseCalls.Clear()
    $script:RouterResearchInvoker = {
        param($category,$lane,$prompt)
        $script:releaseCalls.Add([pscustomobject]@{lane=$lane;prompt=$prompt})
        $fixture = Fixture $category 'gpt-new' '2026-10-07' 92
        $fixture.readings[0].version = '5'
        $fixture.readings[0].results += [pscustomobject]@{model='claude-opus-5-5';score=80;tasks=[long]100;margin=$null}
        $fixture.readings[0].results += [pscustomobject]@{model='gpt-6.1-sol';score=79;tasks=[long]100;margin=$null}
        return ($fixture | ConvertTo-Json -Depth 20)
    }
    $null = Invoke-RouterCategoryResearch -Categories @('routine-coding') -Models @('gpt-new','claude-opus-5-5') -NewModel 'gpt-new' -Trigger release -Lane claude
    Assert-True ($script:releaseCalls.Count -eq 1) 'first-call comparable roster reading needs no follow-up'
    $stale = @(Get-RouterStaleReadingModels -Now ([datetime]'2027-05-01'))
    Assert-True ($stale -contains 'gpt-6.1-sol') 'stale model detected'
    $frontier = @((Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../references/model-router/frontier-models.json') -Raw | ConvertFrom-Json).codex_models) + @('claude-fable-5-1')
    $codexArgs = @(Get-RouterCategoryCallArguments -Lane codex -OutPath 'out.json')
    $codexModel = $codexArgs[[array]::IndexOf($codexArgs,'--model') + 1]
    Assert-True ($codexArgs -contains '--model' -and $codexModel -and $frontier -notcontains $codexModel) 'codex category research pins an explicit non-frontier model'
    $claudeArgs = @(Get-RouterCategoryCallArguments -Lane claude -OutPath '')
    $claudeModel = $claudeArgs[[array]::IndexOf($claudeArgs,'--model') + 1]
    Assert-True ($claudeArgs -contains '--model' -and $claudeModel -like 'claude-*' -and $frontier -notcontains $claudeModel) 'claude category research pins an explicit non-frontier model'
    Write-Output "SUMMARY: PASS ($script:passed checks)"
} finally { Exit-RouterTestCodexHome $fixtureCodexHome;
    $env:DT_MODEL_ROUTER_STATE = $priorState; $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $priorAlerts; $env:DT_MODEL_ROUTER_CODEX_SESSIONS = $priorSessions
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
