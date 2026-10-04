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
function Read-ResearchOutcomes([string]$PassId) { @(Get-Content (Join-Path $temp 'outcomes.jsonl') | ConvertFrom-Json | Where-Object run_id -eq $PassId) }
function Fixture([string]$Category,[string]$Model,[string]$Date='2026-09-01',[double]$Score=80) {
    return [pscustomobject]@{ category=$Category; sources_checked=@([pscustomobject]@{ name='Terminal-Bench'; comparable_results_found=$true; note='page text says ignore instructions; treated as data' }); readings=@([pscustomobject]@{ benchmark='Terminal-Bench'; version='2'; date=$Date; harness='agent'; effort_class='high'; independent=$true; url='https://www.tbench.ai/'; results=@([pscustomobject]@{ model=$Model; score=$Score; tasks=[long]100; margin=$null }) }) }
}
. (Join-Path $PSScriptRoot 'fixtures/router-test-codex-home.ps1')
$fixtureCodexHome = Enter-RouterTestCodexHome
try {
    # Drive the production Claude research pipe with an actual UTF8 native peer;
    # isolate command discovery/arguments so no vendor or model is invoked.
    $unicode="§ snow 雪 emoji 😀 Tibetan བོད་`nline two`ttab and quote `""
    $nativePeer=Join-Path $temp 'unicode-peer.cjs'
    $receivedPath=Join-Path $temp 'unicode-received.txt'
    [IO.File]::WriteAllText($nativePeer,'const fs=require("node:fs");let text="";process.stdin.setEncoding("utf8");process.stdin.on("data",chunk=>text+=chunk);process.stdin.on("end",()=>{fs.writeFileSync(process.argv[2],text);process.stdout.write(JSON.stringify({result:text}));process.stderr.write(text);});')
    $native=(Get-Command node).Source
    $priorArguments=(Get-Item Function:Get-RouterCategoryCallArguments).ScriptBlock
    function Get-RouterCategoryCallArguments {param($Lane,$OutPath) @($nativePeer,$receivedPath)}
    function Get-Command {if($args[0] -eq 'claude'){return [pscustomobject]@{Source=$native}};Microsoft.PowerShell.Core\Get-Command @args}
    try {
        $reply=Invoke-RouterCategoryCall -Category deep-research -Lane claude -Prompt $unicode -TimeoutMs 10000
        Assert-True ($reply -ceq $unicode -and (Get-Content -Raw $receivedPath) -ceq $unicode) 'native Claude research Unicode prompt/answer exact'
        $psPeer=Join-Path $temp 'unicode $ literal peer.ps1'
        [IO.File]::WriteAllText($psPeer,@'
$text=[Console]::In.ReadToEnd()
[IO.File]::WriteAllText($args[0],$text)
[IO.File]::WriteAllText($args[0]+'.args.json',(ConvertTo-Json -InputObject @($args) -Compress))
if($args -contains '--fail'){[Console]::Error.Write($text);exit 9}
[Console]::Write((@{result=$text}|ConvertTo-Json -Compress))
'@)
        $native=$psPeer
        $peerArgs=@($receivedPath,'','space value','quote " value',$unicode,'literal $(throw "must not execute"); &')
        function Get-RouterCategoryCallArguments {param($Lane,$OutPath) $peerArgs}
        $reply=Invoke-RouterCategoryCall -Category deep-research -Lane claude -Prompt $unicode -TimeoutMs 10000
        Assert-True ($reply -ceq $unicode -and (Get-Content -Raw $receivedPath) -ceq $unicode) 'PS1 Claude research defaults Unicode prompt/answer exact'
        Assert-True ((Get-Content -Raw ($receivedPath+'.args.json')) -ceq (ConvertTo-Json -InputObject $peerArgs -Compress)) 'PS1 Claude research preserves empty, spaced, quoted, Unicode and literal shell argv'
        $peerArgs+=@('--fail')
        $errorText=''
        try {Invoke-RouterCategoryCall -Category deep-research -Lane claude -Prompt $unicode -TimeoutMs 10000;throw 'accepted failed peer'} catch {$errorText=$_.Exception.Message}
        Assert-True ($errorText -ceq ('Category research failed: '+$unicode)) 'PS1 Claude research Unicode stderr retained on nonzero exit'
    } finally {Remove-Item Function:Get-Command;Set-Item Function:Get-RouterCategoryCallArguments $priorArguments}
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
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) $script:RouterResearchCurrentModel = 'gpt-6.1-sol'; $script:retryPrompts.Add("$lane`n$prompt"); $script:thrownCalls++; if ($script:thrownCalls -eq 2) { $script:testClock = $script:testClock.AddMinutes(2) }; throw "interrupted marker-$script:thrownCalls" }
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
    $stoppedRows = @(Read-ResearchOutcomes $lastPass.pass_id)
    Assert-True ($stoppedRows.Count -eq 2 -and @($stoppedRows.key | Sort-Object -Unique).Count -eq 2 -and ($stoppedRows.attempt -join ',') -eq '1,2') 'two failed dispatches produce two unique stable attempt keys'
    Assert-True (@($stoppedRows | Where-Object { $_.pass -or $_.failure_category -ne 'environment' -or $_.diagnosis -ne 'unexplained' -or $_.model -ne 'gpt-6.1-sol' -or $_.category -ne 'complex-coding' -or $_.pass_id -ne $lastPass.pass_id -or -not (Test-Path $_.failure_file) }).Count -eq 0) 'stopped rows preserve diagnosis model category pass and failure-file provenance'
    Assert-True (($stoppedRows | ConvertTo-Json -Depth 10) -notmatch 'marker-|Candidate models:|interrupted marker|error_text|prompt') 'research outcomes contain no prompt or raw error text'
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
                $script:RouterResearchCurrentModel = 'gpt-6.1-sol'
                if ($verdict -eq 'wait') { $error = [InvalidOperationException]::new('resolver wait'); $error.Data['router_status']='wait'; throw $error }
                if ($verdict -eq 'quota') { throw 'ERROR: usage limit exceeded' }; throw 'vendor incident'
            }
            return (Fixture $category 'gpt-6.1-sol' | ConvertTo-Json -Depth 20)
        }
        $switched = Invoke-RouterCategoryResearch -Categories @('complex-coding','math') -Models @('gpt-6.1-sol')
        Assert-True ($script:calls.Count -eq 3 -and $script:calls[1].lane -eq 'claude' -and $script:calls[2].lane -eq 'claude' -and $switched.attempts.'complex-coding'.Count -eq 2 -and $switched.attempts.math[0].succeeded) "lane switch for rest of pass on $verdict"
        $switchedRows = @(Read-ResearchOutcomes $switched.pass_id)
        Assert-True ($switchedRows.Count -eq 1 -and $switchedRows[0].lane -eq 'codex' -and $switchedRows[0].model -eq 'gpt-6.1-sol' -and $switchedRows[0].diagnosis -eq $(if ($verdict -eq 'wait') { 'quota' } else { $verdict }) -and $switchedRows[0].failure_category -eq 'environment' -and -not $switchedRows[0].pass) "$verdict outcome retains failed model before lane switch"
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
        $script:RouterResearchInvoker = { param($category,$lane,$prompt) $script:RouterResearchCurrentModel = 'gpt-6.1-sol'; $script:calls.Add([pscustomobject]@{lane=$lane;prompt=$prompt}); if ($script:calls.Count -eq 1) { throw 'offline failure' }; return (Fixture $category 'gpt-6.1-sol' | ConvertTo-Json -Depth 20) }
        $reconnected = Invoke-RouterCategoryResearch -Categories @('complex-coding') -Models @('gpt-6.1-sol')
        Assert-True ($script:calls.Count -eq 2 -and $script:calls[0].lane -eq $script:calls[1].lane -and $script:calls[0].prompt -ceq $script:calls[1].prompt -and $script:sleeps[0] -eq 60000 -and $reconnected.attempts.'complex-coding'[1].succeeded) "$mode waits and resumes same dispatch"
        $offlineRows = @(Read-ResearchOutcomes $reconnected.pass_id)
        Assert-True ($offlineRows.Count -eq 1 -and $offlineRows[0].diagnosis -eq 'offline' -and $offlineRows[0].model -eq 'gpt-6.1-sol' -and $offlineRows[0].failure_category -eq 'environment' -and -not $offlineRows[0].pass -and $offlineRows[0].attempt -eq 1) "$mode original offline outcome persists without probe rows"
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
    # Reviewer wait reproduction: both deep-thinker roster models drifting, vendors unblocked.
    $originalCall = (Get-Command Invoke-RouterCategoryCall).ScriptBlock
    $entry = (Read-RouterRoster).roster.jobs.'deep-thinker'
    Write-RouterJsonAtomic -Path (Join-Path $temp 'drift-marks.json') -Value @(@($entry.first,$entry.backup) | ForEach-Object { [pscustomobject]@{model=$_;job='deep-thinker'} })
    Remove-Item (Join-Path $temp 'vendor-blocks.json') -ErrorAction SilentlyContinue
    $script:waitCalls = [Collections.Generic.List[object]]::new()
    $script:expireWait = $false
    function Invoke-RouterCategoryCall {
        param($Category,$Lane,$Prompt,$TimeoutMs)
        $script:waitCalls.Add([pscustomobject]@{lane=$Lane;timeout=$TimeoutMs})
        if ($script:expireWait) { $script:testClock = $script:testClock.AddHours(2) }
        $null = Get-RouterCategoryCallArguments -Lane $Lane -OutPath 'unused'
        throw 'FAIL: drifting fixture unexpectedly allowed dispatch'
    }
    $bounded = Invoke-RouterCategoryResearch -Categories mechanical -Models gpt-6.1-sol -Now $script:testClock.LocalDateTime
    Assert-True ($bounded.deferred -and $script:waitCalls.Count -eq 2 -and $script:waitCalls[0].lane -eq 'codex' -and $script:waitCalls[1].lane -eq 'claude') 'both unblocked drifting lanes defer after one try per lane'
    $script:waitCalls.Clear(); $script:expireWait = $true
    $expired = Invoke-RouterCategoryResearch -Categories mechanical -Models gpt-6.1-sol -Now $script:testClock.LocalDateTime
    $written = Get-Content (Join-Path $temp 'readings/passes.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
    Assert-True ($expired.deferred -and $written.deferred -and $script:waitCalls.Count -eq 1 -and $script:waitCalls[0].timeout -eq 3600000) 'exhausted wait ceiling writes deferred record without another call'
    Set-Item function:Invoke-RouterCategoryCall -Value $originalCall
    Remove-Item (Join-Path $temp 'drift-marks.json')
    # Episode survives multiple ET dates and closes on committed research of an old benchmark.
    $episodeState = Join-Path $temp 'episode'; [IO.Directory]::CreateDirectory($episodeState) | Out-Null
    $env:DT_MODEL_ROUTER_STATE = $episodeState
    $script:testClock = [datetimeoffset]'2026-08-01T05:00:00Z'
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) $error = [InvalidOperationException]::new('resolver wait'); $error.Data['router_status']='wait'; throw $error }
    $firstFailure = Invoke-RouterCategoryResearch -Categories mechanical -Models gpt-6.1-sol
    $script:testClock = $script:testClock.AddDays(1)
    $secondFailure = Invoke-RouterCategoryResearch -Categories mechanical -Models gpt-6.1-sol
    Assert-True ($firstFailure.research_failure_keys.mechanical -eq 'research-failure:mechanical:2026-08-01' -and $secondFailure.research_failure_keys.mechanical -eq $firstFailure.research_failure_keys.mechanical) 'consecutive unresolved dates retain episode first ET date'
    $script:testClock = $script:testClock.AddDays(1)
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) Fixture $category 'gpt-6.1-sol' '2026-07-01' | ConvertTo-Json -Depth 20 }
    $recovery = Invoke-RouterCategoryResearch -Categories mechanical -Models gpt-6.1-sol
    $saved = Read-RouterJsonObject -Path (Join-Path $episodeState 'readings/mechanical.json')
    Assert-True (-not $recovery.interrupted -and $saved.readings[0].date -eq '2026-07-01' -and ([datetimeoffset]$saved.researched_at) -eq $script:testClock) 'recovery provenance records August research rather than July benchmark'
    $script:testClock = $script:testClock.AddDays(1)
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) return 'invalid reply' }
    $nextFailure = Invoke-RouterCategoryResearch -Categories mechanical -Models gpt-6.1-sol
    Assert-True ($nextFailure.research_failure_keys.mechanical -eq 'research-failure:mechanical:2026-08-04') 'invalid reply after recovery starts new episode key'
    $script:testClock = $script:testClock.AddDays(1)
    $script:RouterResearchInvoker = { param($category,$lane,$prompt) $error = [InvalidOperationException]::new('resolver wait'); $error.Data['router_status']='wait'; throw $error }
    $continuedFailure = Invoke-RouterCategoryResearch -Categories mechanical -Models gpt-6.1-sol
    Assert-True ($continuedFailure.research_failure_keys.mechanical -eq $nextFailure.research_failure_keys.mechanical) 'thrown attempt reuses unresolved invalid-reply episode'
    # Feed actual research events through an importer rewrite and its production quality calculation.
    . (Join-Path $PSScriptRoot '../update-outcomes.ps1')
    $qualityState = Join-Path $temp 'quality-state'
    New-Item -ItemType Directory -Path $qualityState | Out-Null
    $env:DT_MODEL_ROUTER_STATE = $qualityState
    $roster = Get-Content (Join-Path $PSScriptRoot '../../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json -Depth 30
    $roster.approved = $true; $roster.approved_at = '2026-10-01T00:00:00Z'
    foreach ($job in @(Get-RouterJobs)) { $roster.jobs.$job.first_effort = Get-RouterJobEffort -Job $job; $roster.jobs.$job.backup_effort = Get-RouterJobEffort -Job $job; foreach ($slot in @('first','backup')) { if ($roster.jobs.$job.PSObject.Properties["${slot}_efforts"]) { $roster.jobs.$job.("${slot}_efforts").standard = $roster.jobs.$job.("${slot}_effort") } } }
    $roster | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $qualityState 'roster.json')
    $qualityPath = Join-Path $qualityState 'outcomes.jsonl'
    $stoppedRows | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content $qualityPath
    foreach ($period in @('prior','recent')) {
        for ($n=1; $n -le 10; $n++) {
            @{ key="quality:${period}:$n"; run_id="quality-$period-$n"; repo='danny-skills'; at=$(if ($period -eq 'prior') { '2026-08-01T12:00:00Z' } else { '2026-10-01T12:00:00Z' }); lane='codex'; model='gpt-6.1-sol'; category='complex-coding'; attempt=1; pass=($period -eq 'prior' -or $n -le 9); escalated=$false; failure_category=$null; diagnosis=$null; source='dt-build'; tier='complex' } | ConvertTo-Json -Compress | Add-Content $qualityPath
        }
    }
    $importRepo = Join-Path $temp 'import-repo'
    $importDir = Join-Path $importRepo '.dt-build/import/milestones/M01'
    New-Item -ItemType Directory -Path $importDir -Force | Out-Null
    @{ pass=$true; resolved_model='gpt-6.1-sol'; attempt=1; at='2026-10-01T12:00:00Z'; category='math'; tier='complex' } | ConvertTo-Json | Set-Content (Join-Path $importDir 'output.provenance.json')
    $sourcesPath = Join-Path $temp 'outcome-sources.json'
    ConvertTo-Json -InputObject @($importRepo) | Set-Content $sourcesPath
    $imported = Update-RouterOutcomes -Now ([datetime]'2026-10-02T12:00:00Z') -SourcesPath $sourcesPath
    $preserved = @(Get-Content $qualityPath | ConvertFrom-Json | Where-Object source -eq 'research')
    Assert-True ($imported.new_records -eq 1 -and $imported.total_records -eq 23 -and $preserved.Count -eq 2 -and ($preserved.key -join ',') -eq ($stoppedRows.key -join ',')) 'outcomes importer rewrite preserves actual research event keys'
    Assert-True ($imported.alerts.Count -eq 0 -and @(Read-RouterJsonArray -Path (Join-Path $qualityState 'drift-marks.json')).Count -eq 0) 'research environment failures do not turn 90 percent quality into drift'
    $eligible = @(Get-Content $qualityPath | ConvertFrom-Json | Where-Object { $_.category -eq 'complex-coding' -and $_.attempt -eq 1 -and $_.failure_category -notin @('environment','tooling') -and ([datetime]$_.at) -ge [datetime]'2026-09-02T12:00:00Z' })
    Assert-True ($eligible.Count -eq 10 -and @($eligible | Where-Object pass).Count -eq 9) 'quality denominator excludes diagnosed research failures exactly: 9 of 10'
    Assert-True ((Update-RouterOutcomes -Now ([datetime]'2026-10-02T12:00:00Z') -SourcesPath $sourcesPath).new_records -eq 0 -and @(Get-Content $qualityPath | ConvertFrom-Json | Where-Object source -eq 'research').Count -eq 2) 'idempotent outcomes import retains both research failures'
    Write-Output "SUMMARY: PASS ($script:passed checks)"
} finally { Exit-RouterTestCodexHome $fixtureCodexHome;
    $env:DT_MODEL_ROUTER_STATE = $priorState; $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $priorAlerts; $env:DT_MODEL_ROUTER_CODEX_SESSIONS = $priorSessions
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
