Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('m02-harness-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$failures = [Collections.Generic.List[string]]::new()
$checks = 0
function Check {
    param([string]$Name, [scriptblock]$Body)
    $script:checks++
    try { & $Body; Write-Output "PASS $Name" } catch { $script:failures.Add("${Name}: $($_.Exception.Message)"); Write-Output "FAIL ${Name}: $($_.Exception.Message)" }
}
function Assert { param([bool]$Condition, [string]$Message) if (-not $Condition) { throw $Message } }
$priorCase = $env:M02_FAKE_CASE
$priorAudit = $env:M02_FAKE_AUDIT
$priorDispatch = $env:M05_FAKE_DISPATCH
$priorScripts = $env:M05_TEST_SCRIPTS
$pathBefore = $env:PATH
try {
    $fake = Join-Path $root 'fake-claude.ps1'
    @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($args -contains '--version') { [Console]::Write('fake-claude 1.0'); exit 0 }
if ($args -contains '--help') { [Console]::Write('--no-session-persistence'); exit 0 }
function ArgValue([string]$Name) { $i = [array]::IndexOf($argsCopy, $Name); return $argsCopy[$i + 1] }
$argsCopy = $args
$promptText = [Console]::In.ReadToEnd()
if ((ArgValue '--model') -ne 'haiku') { throw 'Outer model must be haiku' }
if ($promptText.Contains('The real dispatch guard must deny')) {
    if ([int](ArgValue '--max-turns') -gt 5) { throw 'Unbounded guard turns' }
    & git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Case root is not a git repo' }
    & git rev-parse --verify HEAD *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Case root has no empty commit' }
    $cfg = Get-Content (ArgValue '--settings') -Raw | ConvertFrom-Json -AsHashtable
    $hookPath = [regex]::Match($cfg.hooks.PreToolUse[0].hooks[0].command, '-File "([^"]+)"').Groups[1].Value
    $inputData = if ($promptText.Contains('no Agent tool')) { @{ command = 'claude -p --version' } }
        elseif ($promptText.Contains('subagent_type fork')) { @{ subagent_type = 'fork' } }
        else { @{ subagent_type = 'general-purpose'; model = 'opus' } }
    $tool = if ($inputData.ContainsKey('command')) { 'Bash' } else { 'Agent' }
    $payload = @{ hook_event_name = 'PreToolUse'; tool_name = $tool; tool_input = $inputData }
    $decision = ($payload | ConvertTo-Json -Depth 10 -Compress) | & pwsh -NoProfile -File $hookPath | ConvertFrom-Json
    if ($decision.hookSpecificOutput.permissionDecision -ne 'deny') { throw 'Real guard did not deny' }
    $retry = [regex]::Match($promptText, 'pwsh -NoProfile -File "([^"\\]+/retry-dispatch\.ps1)"')
    if (-not $retry.Success -or $retry.Value.Length -gt 180 -or $promptText.Contains('-EncodedCommand')) { throw 'Short literal retry missing' }
    $retryPath = $retry.Groups[1].Value
    $body = Get-Content $retryPath -Raw
    $dispatchPath = [IO.Path]::GetFullPath((Join-Path $env:M05_TEST_SCRIPTS '../dispatch.ps1'))
    if (-not $body.StartsWith(('& pwsh -NoProfile -File ' + "'" + $dispatchPath.Replace("'","''") + "' ")) -or $body -notmatch '-Category routine-coding -PromptPath ') { throw 'Retry script does not call categorized dispatch' }
    if ((Split-Path $retryPath -Parent) -ne (Split-Path (Get-Location).Path -Parent)) { throw 'Retry script is not outside project in case root' }
    if ($env:M02_FAKE_CASE -ne 'guard-no-retry') {
        $command = if ($env:M02_FAKE_CASE -eq 'guard-wrong-retry-path') { $retry.Value.Replace('/retry-dispatch.ps1', '/other-retry-dispatch.ps1') } else { $retry.Value }
        $payload = @{ hook_event_name = 'PreToolUse'; tool_name = 'PowerShell'; tool_input = @{ command = $command } }
        $allowed = ($payload | ConvertTo-Json -Depth 10 -Compress) | & pwsh -NoProfile -File $hookPath
        if ($allowed) { throw 'Routed retry was denied' }
    }
    if ($env:M02_FAKE_CASE -ne 'guard-not-started') {
        # Substitute only the executable; exercise the built quoting, arguments
        # and redirections in a separate script that cannot call a model.
        $body = $body.Replace($dispatchPath.Replace("'","''"), $env:M05_FAKE_DISPATCH.Replace("'","''"))
        $fakeRetry = Join-Path (Split-Path $retryPath -Parent) 'fake-retry.ps1'
        $body | Set-Content $fakeRetry -Encoding utf8NoBOM
        if ($env:M02_FAKE_CASE -eq 'guard-files-in-project') { 'harness' | Set-Content 'harness.txt' }
        & pwsh -NoProfile -File $fakeRetry
    }
    [Console]::WriteLine('{"type":"assistant","message":{"model":"claude-haiku-test","content":[{"type":"text","text":"OK"}]}}')
    exit 0
}
if ([int](ArgValue '--max-turns') -gt 3) { throw 'Unbounded turns' }
if ($args -notcontains '--no-session-persistence') { throw 'Persistence flag missing' }
$cfg = Get-Content (ArgValue '--settings') -Raw | ConvertFrom-Json -AsHashtable
$isOutput = $promptText.Contains('M02_BYTE_EXACT_OK')
$inputData = @{ prompt = 'RAW_PROMPT_MUST_NOT_SURVIVE'; description = 'raw description'; subagent_type = 'general-purpose' }
$tool = 'Agent'
if ($isOutput) { $tool = 'Bash'; $inputData = @{ command = 'claude -p --version' } }
elseif ($promptText.Contains('without a subagent_type')) { $inputData.Remove('subagent_type') }
elseif ($promptText.Contains('subagent_type fork')) {
    $inputData.subagent_type = 'fork'
    if ($env:M02_FAKE_CASE -eq 'legacy-fork') { $inputData.subagent_type = 'general-purpose'; $inputData.fork = $true }
}
elseif ($promptText.Contains('subagent_type Explore')) { $inputData.subagent_type = 'Explore' }
elseif ($promptText.Contains('model sonnet')) { $inputData.model = 'sonnet' }
elseif ($promptText.Contains('model opus')) { $inputData.model = 'opus' }
elseif ($promptText.Contains('Call Workflow')) { $tool = 'Workflow' }
if ($env:M02_FAKE_CASE -eq 'wrong-form' -and -not $isOutput -and $tool -ne 'Workflow') { $tool = 'Agent'; $inputData = @{ subagent_type = 'wrong' } }
$payload = @{ hook_event_name = 'PreToolUse'; tool_name = $tool; tool_input = $inputData; session_id = 'PRIVATE_SESSION'; cwd = 'D:/private/location'; transcript_path = 'D:/private/transcript.jsonl'; nested = @{ path = '/private/path'; sessionId = 'PRIVATE_SESSION' } }
$command = $cfg.hooks.PreToolUse[0].hooks[0].command
$hookPath = [regex]::Match($command, '-File "([^"]+)"').Groups[1].Value
if ($env:M02_FAKE_CASE -ne 'no-hook' -and -not ($tool -eq 'Workflow' -and $env:M02_FAKE_CASE -in @('workflow-unavailable','wrong-form'))) {
    $decision = ($payload | ConvertTo-Json -Depth 15 -Compress) | & pwsh -NoProfile -File $hookPath | ConvertFrom-Json
    $expected = if ($tool -eq 'Workflow') { 'allow' } else { 'deny' }
    if ($LASTEXITCODE -ne 0 -or $decision.hookSpecificOutput.permissionDecision -ne $expected) { throw "Unexpected hook decision for $tool" }
    if ($tool -eq 'Workflow' -and $env:M02_FAKE_CASE -in @('workflow-inner-agent','workflow-inner-task')) {
        $payload.tool_name = if ($env:M02_FAKE_CASE -eq 'workflow-inner-task') { 'Task' } else { 'Agent' }
        $decision = ($payload | ConvertTo-Json -Depth 15 -Compress) | & pwsh -NoProfile -File $hookPath | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $decision.hookSpecificOutput.permissionDecision -ne 'deny') { throw 'Inner child was not denied' }
    }
}
$off = $cfg.ContainsKey('enabledPlugins')
if ($off -and ($cfg.enabledPlugins.Count -ne 1 -or $cfg.enabledPlugins['message-timestamps@zoharbabin-claude-tools'] -ne $false)) { throw 'Plugin settings modified beyond timestamp plugin' }
[IO.File]::AppendAllText($env:M02_FAKE_AUDIT, ((@{ model = (ArgValue '--model'); tool = $tool; plugin_off = $off; max_turns = (ArgValue '--max-turns') } | ConvertTo-Json -Compress) + "`n"))
$answer = if ($isOutput) { 'M02_BYTE_EXACT_OK' } else { 'OK' }
if ($env:M02_FAKE_CASE -eq 'prefix') { $answer = '[12:34:56] ' + $answer }
if ($env:M02_FAKE_CASE -eq 'malformed') { [Console]::Write('broken-json'); exit 0 }
$usage = @{ 'claude-haiku-test' = @{ outputTokens = 3 } }
if ($env:M02_FAKE_CASE -eq 'no-model') { $usage = @{} }
if ((ArgValue '--output-format') -eq 'stream-json') {
    $model = if ($env:M02_FAKE_CASE -eq 'no-model') { $null } else { 'claude-haiku-test' }
    [Console]::WriteLine((@{ type = 'assistant'; message = @{ model = $model; content = @(@{ type = 'text'; text = 'intermediate' }) } } | ConvertTo-Json -Depth 10 -Compress))
    [Console]::WriteLine((@{ type = 'assistant'; message = @{ model = $model; content = @(@{ type = 'text'; text = $answer }) } } | ConvertTo-Json -Depth 10 -Compress))
    [Console]::WriteLine((@{ type = 'result'; result = 'wrong-display-result'; modelUsage = $usage } | ConvertTo-Json -Depth 10 -Compress))
} else { [Console]::Write((@{ type = 'result'; result = $answer; modelUsage = $usage } | ConvertTo-Json -Depth 10 -Compress)) }
if ($env:M02_FAKE_CASE -eq 'nonzero') { exit 7 }
'@ | Set-Content $fake -Encoding utf8NoBOM
    # A space in this executable path exercises the exact retry quoting.
    $fakeDir = Join-Path $root 'fake dispatch'
    $null = New-Item -ItemType Directory $fakeDir
    $env:M05_FAKE_DISPATCH = Join-Path $fakeDir 'dispatch.ps1'
    $env:M05_TEST_SCRIPTS = $PSScriptRoot
    @'
param([string]$ProjectPath, [string]$Category, [string]$PromptPath, [string]$OutputPath, [string]$SelectionReason, [switch]$AdHoc, [switch]$ReadOnly, [switch]$AllowOutputInProject, [switch]$Live)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
& git -C $ProjectPath rev-parse --verify HEAD *> $null
if ($LASTEXITCODE -ne 0) { throw 'Retry project is not a committed git repo' }
if ($AllowOutputInProject -or $OutputPath.StartsWith($ProjectPath) -or $PromptPath.StartsWith($ProjectPath)) { throw 'Harness input/output appeared inside retry project' }
$projectFiles=@(& git -C $ProjectPath ls-files --cached --others --exclude-standard)
if ($projectFiles.Count -ne 0) { throw ('Harness files appeared inside retry project: ' + ($projectFiles -join ', ')) }
if ((Split-Path $ProjectPath -Leaf) -ne 'project') { throw 'Retry project is not isolated from case root' }
if ($Category -ne 'routine-coding' -or -not (Test-Path $PromptPath) -or $SelectionReason -ne 'M05 guard retry probe') { throw 'Retry arguments corrupted' }
if ($env:M02_FAKE_CASE -ne 'guard-no-output') { 'M05_DISPATCH_OK' | Set-Content $OutputPath }
if ($env:M02_FAKE_CASE -ne 'guard-no-provenance') {
    @{ execution_result = if ($env:M02_FAKE_CASE -eq 'guard-failure') { 'failure' } else { 'success' }; actual_model = 'fake-codex' } | ConvertTo-Json | Set-Content ($OutputPath + '.provenance.json')
}
[Console]::Out.Write(('x' * 900) + ' stdout-end D:/private/location')
[Console]::Error.Write(('y' * 900) + ' stderr-end D:/private/location')
# A successful process exit does not imply semantic success.
exit 0
'@ | Set-Content $env:M05_FAKE_DISPATCH -Encoding utf8NoBOM
    $env:M02_FAKE_AUDIT = Join-Path $root 'audit.jsonl'
    foreach ($scriptName in @('probe-claude-output.ps1','probe-native-hooks.ps1')) {
        Check "refusal $scriptName" {
            $log = Join-Path $root ($scriptName + '.refusal.log')
            & pwsh -NoProfile -File (Join-Path $PSScriptRoot $scriptName) -CliPath $fake -OutDir (Join-Path $root 'refused') *> $log
            Assert ($LASTEXITCODE -ne 0) 'Probe did not refuse without Live'
            Assert (-not (Test-Path (Join-Path $root 'refused'))) 'Refused probe wrote output'
        }
    }
    . (Join-Path $PSScriptRoot 'probe-native-hooks.ps1')
    Check 'output candidates exact, identity and literal deny' {
        $r = Invoke-ClaudeOutputProbe $fake (Join-Path $root 'output')
        Assert (-not $r.probe_error) ($r | ConvertTo-Json -Depth 8 -Compress)
        Assert ($r.candidates.Count -eq 2) 'Expected both candidates'
        Assert (@($r.candidates | Where-Object { -not $_.accepted }).Count -eq 0) 'Candidate not accepted'
        Assert ($r.candidates[0].actual_text -eq 'M02_BYTE_EXACT_OK') 'Not final assistant text'
    }
    foreach ($case in @('prefix','no-model','no-hook','malformed','nonzero')) {
        Check "reject candidate $case without infrastructure failure" {
            $env:M02_FAKE_CASE = $case
            $r = Invoke-ClaudeOutputProbe $fake (Join-Path $root $case)
            Assert (-not $r.probe_error) 'A measured candidate failure became an infrastructure failure'
            Assert (@($r.candidates | Where-Object { $_.accepted }).Count -eq 0) 'Invalid candidate accepted'
            if ($case -eq 'prefix') { Assert ($r.candidates[0].actual_text.StartsWith('[12:34:56] ')) 'Timestamp was stripped' }
        }
    }
    $env:M02_FAKE_CASE = ''
    Check 'all native forms captured with sanitized shape and Codex limitation' {
        $fixtures = Join-Path $root 'fixtures'
        $r = Invoke-NativeHooksProbe $fake (Join-Path $root 'native') $fixtures
        Assert (-not $r.probe_error) ($r | ConvertTo-Json -Depth 8 -Compress)
        Assert ($r.forms.Count -eq 7) 'Missing forms'
        Assert (@($r.forms | Where-Object { $_.label -ne 'fired' }).Count -eq 0) 'Form not captured'
        Assert ($r.codex.label -eq 'measured-only') 'Codex claim too strong'
        Assert (@($r.forms | Where-Object { $_.form -eq 'Workflow' })[0].support -eq 'unsupported') 'Workflow inner enforcement claimed'
        Assert (@($r.forms | Where-Object { $_.form -eq 'Workflow' })[0].reason -match 'no inner Agent/Task') 'Missing Workflow no-inner reason'
        $fork = @($r.forms | Where-Object { $_.form -eq 'fork' })[0]
        Assert ($fork.label -eq 'fired' -and $fork.support -eq 'captured-denied') 'Real fork shape not recognized'
        $forkPayload = @(Get-Content (Join-Path $fixtures 'fork.json') -Raw | ConvertFrom-Json -AsHashtable)[0]
        Assert ($forkPayload.tool_input.subagent_type -eq 'fork' -and -not $forkPayload.tool_input.ContainsKey('fork')) 'Fake fork did not use real shape'
        Assert (@(Get-ChildItem $fixtures -Filter '*.json').Count -eq 7) 'Missing fixture'
        $content = (Get-ChildItem $fixtures | Get-Content -Raw) -join ''
        Assert ($content -notmatch 'RAW_PROMPT|PRIVATE_SESSION|private/location|private/path|raw description') 'Raw data leaked'
        $p = @(Get-Content (Join-Path $fixtures 'general-purpose.json') -Raw | ConvertFrom-Json -AsHashtable)[0]
        Assert ($p.ContainsKey('session_id') -and $p.tool_input.ContainsKey('prompt') -and $p.nested.ContainsKey('sessionId')) 'Shape lost'
    }
    Check 'boolean fork alone is not a captured fork' {
        $env:M02_FAKE_CASE = 'legacy-fork'
        $r = Invoke-NativeHooksProbe $fake (Join-Path $root 'legacy-fork') (Join-Path $root 'legacy-fork-fixtures')
        Assert (-not $r.probe_error) 'Unexpected probe infrastructure error'
        $fork = @($r.forms | Where-Object { $_.form -eq 'fork' })[0]
        Assert ($fork.label -eq 'not-fired' -and $fork.support -eq 'unsupported') 'Boolean fork accepted'
    }
    foreach ($case in @('workflow-inner-agent','workflow-inner-task','workflow-unavailable')) {
        Check "$case observed and labeled" {
            $env:M02_FAKE_CASE = $case
            $fixtures = Join-Path $root ($case + '-fixtures')
            $r = Invoke-NativeHooksProbe $fake (Join-Path $root $case) $fixtures
            Assert (-not $r.probe_error) ($r | ConvertTo-Json -Depth 8 -Compress)
            $workflow = @($r.forms | Where-Object { $_.form -eq 'Workflow' })[0]
            Assert ($workflow.cli_exit_code -eq 0) 'Fake hook decision validation failed'
            if ($case -eq 'workflow-unavailable') {
                Assert ($workflow.label -eq 'not-fired' -and $workflow.support -eq 'unsupported') 'Unavailable Workflow claimed enforced'
                Assert ($workflow.reason -match 'unavailable' -and $null -eq $workflow.fixture) 'Missing unavailable reason or spurious fixture'
            } else {
                Assert ($workflow.label -eq 'fired' -and $workflow.support -eq 'enforced-inner-agent') 'Inner denial not recognized'
                Assert ($null -eq $workflow.reason) 'Enforced Workflow has an unsupported reason'
                $payloads = @(Get-Content (Join-Path $fixtures 'Workflow.json') -Raw | ConvertFrom-Json -AsHashtable)
                Assert ($payloads.Count -eq 2 -and $payloads[0].tool_name -eq 'Workflow' -and $payloads[1].tool_name -in @('Agent','Task')) 'Workflow or inner payload not logged'
            }
        }
    }
    Check 'wrong native forms labeled not-fired unsupported' {
        $env:M02_FAKE_CASE = 'wrong-form'
        $r = Invoke-NativeHooksProbe $fake (Join-Path $root 'unsupported') (Join-Path $root 'unsupported-fixtures')
        Assert (-not $r.probe_error) 'Unexpected probe infrastructure error'
        Assert (@($r.forms | Where-Object { $_.form -ne 'untyped' -and $_.label -ne 'not-fired' }).Count -eq 0) 'Wrong form counted'
    }
    Check 'missing CLI reported as probe infrastructure error' {
        $r = Invoke-ClaudeOutputProbe (Join-Path $root 'absent.exe') (Join-Path $root 'missing')
        Assert ([bool]$r.probe_error) 'Missing executable not reported'
        Assert (Test-Path (Join-Path $root 'missing/result.json')) 'Missing result file'
    }
    foreach ($case in @('guard-success','guard-failure','guard-no-provenance','guard-no-output','guard-not-started','guard-no-retry','guard-wrong-retry-path','guard-files-in-project')) {
        Check "$case requires committed repo, semantic result, output and provenance" {
            $env:M02_FAKE_CASE = $case
            $destination = Join-Path $root $case
            $r = Invoke-DispatchGuardProbe $fake $destination
            Assert (-not $r.probe_error) ($r | ConvertTo-Json -Depth 8 -Compress)
            Assert ($r.forms.Count -eq 3) 'Missing guard forms'
            $saved = Get-Content (Join-Path $destination 'result.json') -Raw | ConvertFrom-Json -AsHashtable
            foreach ($f in $saved.forms) {
                Assert ($f.cli_exit_code -eq 0 -and $f.real_guard_denied) 'Fake did not exercise real deny'
                Assert ($f.retry_observed -eq ($case -notin @('guard-no-retry','guard-wrong-retry-path'))) 'Retry observation did not require exact script command'
                Assert ($null -eq $f.independent_acceptance) 'Execution became independent acceptance'
                if ($case -eq 'guard-success') {
                    Assert ($f.accepted -and $f.retry_provenance_present -and $f.retry_output_present -and $f.retry_execution_result -eq 'success') 'Valid retry rejected (repo or quoting broken)'
                } else {
                    Assert (-not $f.accepted) 'Incomplete or failed retry accepted on exit status alone'
                    if ($case -eq 'guard-not-started') { Assert ($f.retry_reason -eq 'retry-command-did-not-start') 'Missing command-start reason' }
                    elseif ($case -in @('guard-no-retry','guard-wrong-retry-path')) {
                        Assert ($f.retry_output_present -and $f.retry_provenance_present -and $f.retry_execution_result -eq 'success') 'Missing observation case must otherwise succeed'
                    }
                    elseif ($case -eq 'guard-files-in-project') {
                        Assert (-not $f.retry_provenance_present -and $f.retry_stderr_tail -match 'Harness files appeared inside retry project') 'Project contamination was not rejected'
                    }
                    else {
                        Assert ($f.retry_stdout_tail.Length -eq 800 -and $f.retry_stderr_tail.Length -eq 800) 'Retry tails not bounded/preserved'
                        Assert ($f.retry_stdout_tail -match 'stdout-end <path>' -and $f.retry_stderr_tail -match 'stderr-end <path>') 'Retry tails not sanitized'
                    }
                    if ($case -eq 'guard-no-provenance') { Assert ($f.retry_reason -eq 'retry-provenance-missing' -and -not $f.retry_provenance_present) 'Missing provenance reason' }
                }
            }
            Assert ($r.accepted -eq ($case -eq 'guard-success')) 'Overall acceptance wrong'
        }
    }
    Check 'PATH unchanged and no raw prompts persisted' {
        Assert ($env:PATH -ceq $pathBefore) 'PATH changed'
        $stored = (Get-ChildItem $root -Recurse -File | Where-Object { $_.Extension -in @('.json','.jsonl') } | Get-Content -Raw) -join ''
        Assert ($stored -notmatch 'RAW_PROMPT|Use Bash exactly once|Call Agent once|PRIVATE_SESSION') 'Raw prompt/session stored'
    }
} finally {
    $env:M02_FAKE_CASE = $priorCase
    $env:M02_FAKE_AUDIT = $priorAudit
    $env:M05_FAKE_DISPATCH = $priorDispatch
    $env:M05_TEST_SCRIPTS = $priorScripts
    Write-Output "Harness evidence: $root"
}
Write-Output "Checks: $checks; failures: $($failures.Count)"
if ($failures.Count) { exit 1 }
exit 0
