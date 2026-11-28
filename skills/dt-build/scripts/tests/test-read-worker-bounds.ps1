param([Parameter(Mandatory)][ValidateSet('codex','claude')][string]$Vendor, [Parameter(Mandatory)][string]$EvidenceRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../../../scripts/model-router/dispatch.ps1')
. (Join-Path $PSScriptRoot '../read-worker-bounds.ps1')
$root = Join-Path $EvidenceRoot $Vendor
[void][IO.Directory]::CreateDirectory($root)
$env:DT_MODEL_ROUTER_STATE = Join-Path $root 'router-state'
[void][IO.Directory]::CreateDirectory($env:DT_MODEL_ROUTER_STATE)
'[]' | Set-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'sources.json')
foreach ($name in @('DT_JOB_ID','DT_JOB_DIR','DT_BUILD_COORDINATOR_ID')) { Remove-Item ('Env:'+$name) -ErrorAction SilentlyContinue }
$env:AI9_LAUNCHES = Join-Path $root 'launches.log'
$env:DT_CLAUDE_TOKEN_FILE = Join-Path $root 'absent-token-fixture'
$env:DT_MODEL_ROUTER_CODEX_SESSIONS = Join-Path $root 'sessions'
[void][IO.Directory]::CreateDirectory($env:DT_MODEL_ROUTER_CODEX_SESSIONS)
[IO.File]::WriteAllText($env:AI9_LAUNCHES, '')
$promptPath = Join-Path $PSScriptRoot 'fixtures/read-extract-prompt.md'
$cli = Join-Path $PSScriptRoot 'fixtures/read-worker-cli.ps1'
$failures = [Collections.Generic.List[string]]::new()
$checks = 0
function Check([bool]$Condition,[string]$Name) { $script:checks++; if (-not $Condition) { $script:failures.Add($Name); "FAIL $Name" } else { "PASS $Name" } }
$cases = @('ordinary','tool-cap','turn-cap','input-cap','live-input-cap','reedit','deadline','no-output','empty','stale','multi-file','read-between','malformed','failure','incomplete','admission')
foreach ($case in $cases) {
    try {
        $env:AI9_CASE = $case
        $output = Join-Path $root ($case+'.md')
        Remove-Item -LiteralPath $output -ErrorAction SilentlyContinue
        if ($case -eq 'stale') { [IO.File]::WriteAllText($output,'STALE ARTIFACT MUST NOT SUCCEED') }
        $context = New-RouterDispatchContext -PromptPath $promptPath -Project $root -Category mechanical -AdHoc -RequestedModel fixture-model
        $options = @{Vendor=$Vendor;CliPath=$cli;ProjectPath=$root;OutputPath=$output;Prompt=[IO.File]::ReadAllText($promptPath);PromptPath=$promptPath;Model='fixture-model';Effort='low';TimeoutMs=5000;ReadMaxToolCalls=24;ReadMaxTurns=16;ReadMaxInputTokens=120000;ReadMaxMs=3500;Context=$context;Resolution=@{};SelectionReason='deterministic fixture'}
        if ($case -eq 'tool-cap') { $options.ReadMaxToolCalls = 2 }
        if ($case -eq 'turn-cap') { $options.ReadMaxTurns = 2 }
        if ($case -eq 'deadline') { $options.ReadMaxMs = 500 }
        if ($case -eq 'admission') { $options.ReadMaxInputTokens = 256 }
        $before = @([IO.File]::ReadAllLines($env:AI9_LAUNCHES)).Count
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $row = Invoke-BoundedReadWorker @options
        $elapsed = $watch.ElapsedMilliseconds
        $after = @([IO.File]::ReadAllLines($env:AI9_LAUNCHES)).Count
        $body = [IO.File]::ReadAllText($output)
        $evidence = Read-RouterDispatchEvidence ($output+'.provenance.json')
        $expected = switch ($case) { 'tool-cap' {'tool-call-cap'} 'turn-cap' {'turn-cap'} 'input-cap' {'input-token-cap'} 'live-input-cap' {'input-token-cap'} 'reedit' {'output-only-reedit'} 'deadline' {'read-deadline'} 'admission' {'input-token-cap'} default {$null} }
        $success = $case -in @('ordinary','multi-file','read-between')
        Check ($row.pass -eq $success -and $row.partial -eq (-not $success)) "$case completion classification ($($row.termination_reason))"
        Check (($after-$before) -eq $(if ($case -eq 'admission') {0} else {1})) "$case one launch, no retries"
        Check ($evidence.output_sha256 -eq (Get-FileHash $output -Algorithm SHA256).Hash.ToLowerInvariant()) "$case retained artifact hash"
        Check ($null -eq $row.backup_pick -and $null -eq $row.diagnosis) "$case no diagnosis or fallback"
        if ($expected) { Check ($row.termination_reason -like "$expected*") "$case stopping reason"; Check ($elapsed -lt 5000) "$case stopped before outer timeout ($elapsed ms)" }
        if ($success) { Check ($body -eq "source.md:3: exact retained fact`n") "$case exact artifact bytes preserved"; Check ([IO.File]::ReadAllText($output+'.final.md') -match 'FINAL STDOUT') "$case final stdout separate" }
        else { Check ($body -match 'READ_EXTRACT_PARTIAL' -and $body -match 'Provenance: dispatch') "$case explicit partial and provenance" }
        if ($case -in @('no-output','empty','stale','admission')) { Check (-not $row.artifact_present -and $row.termination_reason -match 'no-output') "$case honest missing/empty artifact" }
        if ($case -eq 'stale') { Check ($body -notmatch 'STALE ARTIFACT' -and (Test-Path ($output+'.before-'+$context.dispatch_id))) 'stale file preserved separately' }
        if ($case -eq 'reedit') { Check ($body -match 'second retained line') 'reedit content preserved' }
    } catch { $failures.Add("$case exception: $($_.Exception.Message)"); "FAIL $case exception: $_" }
}
# Lane detection is explicit and independent of category or words in a build prompt.
foreach ($invalid in @(@{ReadExtract=$true;AdHoc=$false},@{ReadExtract=$true;AdHoc=$true;ReadOnly=$true},@{ReadExtract=$true;AdHoc=$true;Scrutiny=$true},@{ReadExtract=$false;Parameters=@{ReadMaxTurns=2}})) {
    $guard = @{ReadExtract=$false;AdHoc=$true;ReadOnly=$false;Preflight=$false;Scrutiny=$false;Parameters=@{}}
    foreach ($key in $invalid.Keys) { $guard[$key]=$invalid[$key] }
    $rejected=$false; try { Assert-ReadWorkerLane @guard } catch { $rejected=$true }
    Check $rejected 'invalid lane/cap combination rejected'
}
try { Assert-ReadWorkerLane -ReadExtract $false -AdHoc $false -ReadOnly $false -Preflight $false -Scrutiny $false -Parameters @{}; Check $true 'build lane accepts no read caps' } catch { Check $false 'build lane accepts no read caps' }
$ranges = @{ReadMaxToolCalls=@(0,129);ReadMaxTurns=@(0,65);ReadMaxInputTokens=@(255,1000001);ReadMaxMs=@(99,540001)}
foreach ($range in $ranges.GetEnumerator()) {
    foreach ($value in $range.Value) {
        $bad = $options.Clone(); $bad[$range.Key] = $value
        $rejected = $false; try { Invoke-BoundedReadWorker @bad | Out-Null } catch { $rejected = $_.Exception.Message -match 'validate argument' }
        Check $rejected "out-of-range $($range.Key)=$value rejected before launch"
    }
}
$env:DT_BUILD_COORDINATOR_ID = 'fixture-coordinator'
try {
    $rejected = $false; try { Assert-ReadWorkerLane -ReadExtract $true -AdHoc $true -Parameters @{} } catch { $rejected = $true }
    Check $rejected 'managed coordinator cannot enter small read lane'
    Assert-ReadWorkerLane -ReadExtract $false -AdHoc $false -Parameters @{}
    Check $true 'managed build coordinator keeps ordinary lane'
} finally { Remove-Item Env:DT_BUILD_COORDINATOR_ID }
$bad = $options.Clone(); $bad.OutputPath = $promptPath
$promptHash = (Get-FileHash $promptPath -Algorithm SHA256).Hash
$rejected = $false; try { Invoke-BoundedReadWorker @bad | Out-Null } catch { $rejected = $_.Exception.Message -match 'OUTPUT_IS_PROMPT' }
Check ($rejected -and (Get-FileHash $promptPath -Algorithm SHA256).Hash -eq $promptHash) 'output cannot overwrite source prompt'
$bad = $options.Clone(); $bad.OutputPath = $root
$rejected = $false; try { Invoke-BoundedReadWorker @bad | Out-Null } catch { $rejected = $_.Exception.Message -match 'OUTPUT_NOT_FILE' }
Check $rejected 'output directory rejected without moving it'
$link = Join-Path $root 'linked-skill'
[void][IO.Directory]::CreateSymbolicLink($link, (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path)
. (Join-Path $link 'scripts/read-worker-bounds.ps1')
$env:AI9_CASE = 'ordinary'
$linked = $options.Clone(); $linked.ReadMaxInputTokens = 120000; $linked.OutputPath = Join-Path $root 'linked-ordinary.md'
$linked.Context = New-RouterDispatchContext -PromptPath $promptPath -Project $root -Category mechanical -AdHoc -RequestedModel fixture-model
try {
    $row = Invoke-BoundedReadWorker @linked
    Check $row.pass 'linked skill resolves shared runtime imports'
    Check ([IO.File]::ReadAllText($linked.OutputPath) -eq "source.md:3: exact retained fact`n") 'linked skill retains exact extract'
} catch { $failures.Add("linked skill exception: $($_.Exception.Message)"); "FAIL linked skill exception: $_" }
# Public dispatcher -> actual vendor wrapper -> bounded runner -> fake native stream.
. (Join-Path $PSScriptRoot '../../../../scripts/model-router/tests/fixtures/router-test-codex-home.ps1')
$fixture = Enter-RouterTestCodexHome
try {
    $fakeCli = Join-Path $fixture.root 'read-worker-cli.ps1'
    Copy-Item -LiteralPath $cli -Destination $fakeCli
    $catalogPath = Join-Path $env:CODEX_HOME 'models_cache.json'
    $catalog = Get-Content $catalogPath -Raw | ConvertFrom-Json
    foreach ($entry in $catalog.models) { $entry | Add-Member -NotePropertyName supported_reasoning_levels -NotePropertyValue @(@{effort='low'},@{effort='medium'},@{effort='high'},@{effort='xhigh'}) -Force }
    $catalog | ConvertTo-Json -Depth 20 | Set-Content $catalogPath
    $roster = Get-Content (Join-Path $PSScriptRoot '../../../../references/model-router/default-roster.json') -Raw | ConvertFrom-Json
    $roster.approved = $true; $roster.approved_at = '2026-11-05T00:00:00Z'
    $roster | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'roster.json')
    @{checked_at=(Get-Date).ToString('o')} | ConvertTo-Json | Set-Content (Join-Path $env:DT_MODEL_ROUTER_STATE 'last-check.json')
    function Get-RouterVendorBlocked { param($Vendor,$UsageReadings) $false }
    function Get-RouterClaudeUsage { $null }
    function Get-RouterCodexUsage { $null }
    $project = Join-Path $root 'project'; [void][IO.Directory]::CreateDirectory($project)
    & git -C $project init -q -b main
    & git -C $project -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm fixture
    $real = {
        param($Vendor,$Arguments)
        $adapter = $Arguments.Clone()
        if ($Vendor -eq 'claude') { $adapter.Remove('AllowOutputInProject') }
        $adapter[$Vendor+'CliPath'] = $fakeCli
        & (Join-Path $PSScriptRoot "../invoke-$Vendor-chunk.ps1") @adapter | Out-Null
    }
    foreach ($case in @('ordinary','tool-cap')) {
        try {
            $env:AI9_CASE = $case
            $output = Join-Path $root ("public-$case.md")
            $options = @{ProjectPath=$project;Category='mechanical';PromptPath=$promptPath;OutputPath=$output;SelectionReason='bounded read integration fixture';AdHoc=$true;ReadExtract=$true;Lane=$Vendor;ReadMaxToolCalls=2;TimeoutMs=5000;ReadMaxMs=3500}
            $before = @([IO.File]::ReadAllLines($env:AI9_LAUNCHES)).Count
            $row = Invoke-RouterDispatch -Options $options -WrapperInvoker $real
            Check ($row.pass -eq ($case -eq 'ordinary') -and $row.read_extract) "public $case actual $Vendor wrapper classification ($($row.termination_reason))"
            Check ((@([IO.File]::ReadAllLines($env:AI9_LAUNCHES)).Count-$before) -eq 1) "public $case exactly one vendor launch"
            Check ([IO.File]::ReadAllText($output) -match 'exact retained fact') "public $case artifact preserved"
            if ($case -eq 'tool-cap') { Check ($row.termination_reason -eq 'tool-call-cap' -and $row.failure_category -eq 'read-partial') 'public read cap remains intentional partial' }
        } catch { $failures.Add("public $case exception: $($_.Exception.Message)"); "FAIL public $case exception: $_" }
    }
} finally { Exit-RouterTestCodexHome $fixture }
"Checks: $checks; failures: $($failures.Count)"
if ($failures.Count) { $failures | ForEach-Object { [Console]::Error.WriteLine($_) }; exit 1 }
