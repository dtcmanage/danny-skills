param([switch]$Live, [ValidateSet('capture','guard')][string]$Mode = 'capture', [string]$OutDir, [string]$FixtureDir, [string]$CliPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'probe-claude-output.ps1') -OutDir $OutDir -CliPath $CliPath -Live:$Live

function Invoke-NativeHooksProbe {
    param([string]$Cli, [string]$Destination, [string]$Fixtures)
    $null = New-Item -ItemType Directory -Path $Destination, $Fixtures -Force
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('m02-native-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $tempRoot
    $result = [ordered]@{
        probe = 'native-hooks'; mode = 'capture'; cli_version = $null; forms = @(); probe_error = $null
        codex = @{ label = 'measured-only'; reason = 'No verified temporary-CODEX_HOME hook trust/configuration protocol is available to this Claude probe. No Codex process started and no global files changed.' }
    }
    # The alias in tool input is data for a denied call; every outer session is haiku.
    $forms = [ordered]@{
        'general-purpose' = 'Call Agent once with subagent_type general-purpose.'
        'untyped' = 'Call Agent once without a subagent_type field.'
        'fork' = 'Call Agent once with subagent_type fork (a fork of this conversation).'
        'Explore' = 'Call Agent once with subagent_type Explore.'
        'sonnet' = 'Call Agent once with subagent_type general-purpose and model sonnet.'
        'frontier-alias' = 'Call Agent once with subagent_type general-purpose and model opus.'
        'Workflow' = 'Call Workflow once describing a workflow containing exactly one general-purpose agent.'
    }
    try {
        $info = Get-ProbeCliInfo $Cli $tempRoot
        $result.cli_version = $info.version
        foreach ($name in $forms.Keys) {
            # Leave tool discovery native: naming an unavailable Workflow tool in
            # --tools can reject the entire invocation before Agent can be measured.
            # Workflow must reach its inner call; every other tool stays denied,
            # including Agent/Task and shell fallbacks.
            $cfg = New-ProbeSettings (Join-Path $tempRoot $name) '.*' -AllowWorkflow:($name -eq 'Workflow')
            $cliArgs = @('-p','--model','haiku','--max-turns','2','--strict-mcp-config','--output-format','json','--settings',$cfg.settings)
            if ($info.no_persistence) { $cliArgs += '--no-session-persistence' }
            $instructions = if ($name -eq 'Workflow') {
                ' Workflow is allowed for this protocol test; its inner Agent/Task call must be denied by the hook before the child runs. If Workflow is unavailable, report that and stop. Do not call Agent/Task directly, retry, substitute another form, or use Bash. After the inner denial return OK.'
            } else {
                ' This is a protocol test: a deny hook must block the call before any child runs. Do not retry, substitute another form, or use Bash. After denial return OK.'
            }
            $prompt = $forms[$name] + ' Use a tiny prompt saying return OK.' + $instructions
            $run = Invoke-ProbeCli $Cli $cliArgs $prompt $tempRoot
            $payloads = @(Get-ProbePayloads $cfg.log)
            $matching = @($payloads | Where-Object {
                $p = $_
                if ($p.tool_name -notin @('Agent','Task','Workflow')) { return $false }
                $inputData = $p.tool_input
                switch ($name) {
                    'general-purpose' { return $p.tool_name -in @('Agent','Task') -and $inputData['subagent_type'] -eq 'general-purpose' }
                    'untyped' { return $p.tool_name -in @('Agent','Task') -and -not $inputData.ContainsKey('subagent_type') }
                    'fork' { return $p.tool_name -in @('Agent','Task') -and $inputData['subagent_type'] -eq 'fork' }
                    'Explore' { return $p.tool_name -in @('Agent','Task') -and $inputData['subagent_type'] -eq 'Explore' }
                    'sonnet' { return $p.tool_name -in @('Agent','Task') -and $inputData['model'] -eq 'sonnet' }
                    'frontier-alias' { return $p.tool_name -in @('Agent','Task') -and $inputData['model'] -eq 'opus' }
                    'Workflow' { return $p.tool_name -in @('Workflow','Agent','Task') }
                }
            })
            $fired = $matching.Count -gt 0
            $innerDenied = $name -eq 'Workflow' -and @($matching | Where-Object { $_.tool_name -in @('Agent','Task') }).Count -gt 0
            $fixture = $null
            if ($payloads.Count -gt 0) {
                $fixture = $name + '.json'
                ConvertTo-Json -InputObject $payloads -Depth 50 | Set-Content (Join-Path $Fixtures $fixture) -Encoding utf8NoBOM
            }
            $result.forms += @{
                form = $name; label = if ($fired) { 'fired' } else { 'not-fired' }
                support = if ($innerDenied) { 'enforced-inner-agent' } elseif ($fired -and $name -ne 'Workflow') { 'captured-denied' } else { 'unsupported' }
                reason = if ($name -eq 'Workflow' -and -not $innerDenied) {
                    if ($fired) { 'Workflow was allowed and logged, but no inner Agent/Task payload reached the deny hook; inner enforcement is unsupported.' }
                    else { 'Workflow did not reach the hook; the tool may be unavailable in this session, its schema invalid, or the model may have refused. No inner Agent/Task denial was observed; enforcement is unsupported.' }
                } elseif (-not $fired) { 'Requested form did not reach the hook; unavailable tool, invalid schema, or model refusal cannot establish enforcement.' } else { $null }
                fixture = $fixture; cli_exit_code = $run.exit_code; no_session_persistence = $info.no_persistence
            }
        }
    } catch { $result.probe_error = 'probe-infrastructure-failure: ' + $_.Exception.GetType().Name + ': ' + (ConvertTo-ProbeSanitized $_.Exception.Message) + ' line ' + $_.InvocationInfo.ScriptLineNumber }
    finally {
        $result | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $Destination 'result.json') -Encoding utf8NoBOM
        if (Test-Path $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
    return $result
}

function Invoke-DispatchGuardProbe {
    param([string]$Cli, [string]$Destination)
    $null = New-Item -ItemType Directory -Path $Destination -Force
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('m05-' + [guid]::NewGuid().ToString('N').Substring(0,12))
    $null = New-Item -ItemType Directory -Path $tempRoot
    $guard = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../dispatch-guard.py'))
    $dispatch = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../dispatch.ps1'))
    $result = [ordered]@{ probe = 'dispatch-guard'; mode = 'guard'; cli_version = $null; forms = @(); probe_error = $null; accepted = $false; codex = 'measured-only'; Workflow = 'unsupported' }
    try {
        $info = Get-ProbeCliInfo $Cli $tempRoot
        $result.cli_version = $info.version
        foreach ($form in @('opus','fork','worker-shell')) {
            $caseRoot = Join-Path $tempRoot $form
            $null = New-Item -ItemType Directory -Path $caseRoot
            $retryScript = Join-Path $caseRoot 'retry-dispatch.ps1'
            $retry = 'pwsh -NoProfile -File "' + $retryScript.Replace('\','/') + '"'
            $project = Join-Path $caseRoot 'project'
            $null = New-Item -ItemType Directory -Path $project
            # The Codex lane requires both a repository and an existing HEAD.
            & git -C $project init --quiet
            if ($LASTEXITCODE -ne 0) { throw 'guard-case-git-init-failed' }
            & git -C $project -c user.name=GuardProbe -c user.email=guard-probe@example.invalid -c core.hooksPath=NUL -c commit.gpgsign=false commit --quiet --allow-empty -m 'Guard probe baseline'
            if ($LASTEXITCODE -ne 0) { throw 'guard-case-git-commit-failed' }
            $log = Join-Path $caseRoot 'guard.jsonl'
            $hook = Join-Path $caseRoot 'guard-hook.ps1'
            $sanitize = (Get-Command ConvertTo-ProbeSanitized).Definition
            $hookText = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function ConvertTo-ProbeSanitized {
__SANITIZE__
}
$raw = [Console]::In.ReadToEnd()
$p = $raw | ConvertFrom-Json -AsHashtable
$answer = $raw | & python '__GUARD__'
$d = if ($answer) { $answer | ConvertFrom-Json -AsHashtable } else { $null }
$denied = $null -ne $d -and $d.hookSpecificOutput.permissionDecision -eq 'deny' -and $d.hookSpecificOutput.permissionDecisionReason.StartsWith('ROUTER_GUARD_DENY:')
$commandText = if ($p.tool_name -in @('Bash','PowerShell')) { [string]$p.tool_input.command } else { '' }
$retry = $commandText -ceq '__RETRY__'
$record = @{ payload = (ConvertTo-ProbeSanitized $p); real_guard_deny = $denied; dispatch_retry = $retry; reason = if ($denied) { 'ROUTER_GUARD_DENY: category routine-coding; dispatch.ps1' } else { $null } }
[IO.File]::AppendAllText('__LOG__', (($record | ConvertTo-Json -Depth 50 -Compress) + "`n"))
if ($answer) { [Console]::Write($answer) }
'@
            $hookText.Replace('__SANITIZE__',$sanitize).Replace('__GUARD__',$guard.Replace("'","''")).Replace('__LOG__',$log.Replace("'","''")).Replace('__RETRY__',$retry.Replace("'","''")) | Set-Content $hook -Encoding utf8NoBOM
            $settings = Join-Path $caseRoot 'settings.json'
            @{ hooks = @{ PreToolUse = @(@{ matcher = '^(Agent|Task|Bash|PowerShell)$'; hooks = @(@{ type = 'command'; command = ('pwsh -NoProfile -File "' + $hook + '"'); timeout = 10 }) }) } } | ConvertTo-Json -Depth 15 | Set-Content $settings -Encoding utf8NoBOM
            $task = Join-Path $caseRoot 'task-prompt.md'
            $output = Join-Path $caseRoot 'task-output.md'
            'Return exactly M05_DISPATCH_OK. Do not use tools.' | Set-Content $task -Encoding utf8NoBOM
            $retryStdout = Join-Path $caseRoot 'retry.stdout.txt'
            $retryStderr = Join-Path $caseRoot 'retry.stderr.txt'
            # Keep the shell-tool command short. The script holds quoting and
            # redirections outside the git project, alongside the other harness files.
            $quote = { param([string]$Value) "'" + $Value.Replace("'", "''") + "'" }
            $retryBody = '& pwsh -NoProfile -File ' + (& $quote $dispatch) + ' -ProjectPath ' + (& $quote $project) + ' -Category routine-coding -PromptPath ' + (& $quote $task) + ' -OutputPath ' + (& $quote $output) + ' -SelectionReason ''M05 guard retry probe'' -AdHoc -ReadOnly -Live 1> ' + (& $quote $retryStdout) + ' 2> ' + (& $quote $retryStderr)
            $retryBody | Set-Content $retryScript -Encoding utf8NoBOM
            $scriptText = (Get-Content $retryScript -Raw).TrimEnd("`r", "`n")
            $dispatchPrefix = '& pwsh -NoProfile -File ' + (& $quote $dispatch) + ' -ProjectPath ' + (& $quote $project) + ' -Category routine-coding -PromptPath ' + (& $quote $task)
            if (-not $scriptText.StartsWith($dispatchPrefix, [StringComparison]::Ordinal) -or $scriptText -cne $retryBody) {
                throw 'guard-retry-script-invalid: expected dispatch.ps1 -Category routine-coding with the complete retry arguments'
            }
            $request = switch ($form) {
                'opus' { 'Call Agent once with subagent_type general-purpose and model opus, prompt return OK.' }
                'fork' { 'Call Agent once with subagent_type fork, prompt return OK.' }
                'worker-shell' { 'You are a headless worker with no Agent tool. Use Bash once for the literal shell launch: claude -p --version' }
            }
            $prompt = $request + ' The real dispatch guard must deny this attempt. After that denial use the shell tool to retry exactly once via this exact command: ' + $retry + ' . Do not substitute another native launch. Then return OK.'
            $cliArgs = @('-p','--model','haiku','--max-turns','5','--strict-mcp-config','--output-format','stream-json','--verbose','--settings',$settings)
            if ($form -eq 'worker-shell') { $cliArgs += @('--tools','Bash,PowerShell') }
            if ($info.no_persistence) { $cliArgs += '--no-session-persistence' }
            $run = Invoke-ProbeCli $Cli $cliArgs $prompt $project
            $records = if (Test-Path $log) { @(Get-Content $log | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable }) } else { @() }
            $denied = $false; $retried = $false
            foreach ($record in $records) {
                if ($record.dispatch_retry -and $denied -and -not $record.real_guard_deny) { $retried = $true }
                if (-not $record.real_guard_deny) { continue }
                $p = $record.payload
                $matches = switch ($form) {
                    'opus' { $p.tool_name -in @('Agent','Task') -and $p.tool_input['model'] -eq 'opus' }
                    'fork' { $p.tool_name -in @('Agent','Task') -and $p.tool_input['subagent_type'] -eq 'fork' }
                    'worker-shell' { $p.tool_name -in @('Bash','PowerShell') -and $p.tool_input['command'] -eq 'claude -p --version' }
                }
                if ($matches) { $denied = $true }
            }
            $parsed = Read-ProbeOutput $run.stdout -Stream
            $execution = $null; $actualModel = $null
            $provenancePresent = Test-Path ($output + '.provenance.json')
            $retryReason = $null
            if ($provenancePresent) {
                $provenance = Get-Content ($output + '.provenance.json') -Raw | ConvertFrom-Json -AsHashtable
                $execution = $provenance['execution_result']; $actualModel = $provenance['actual_model']
            } else {
                $retryReason = if (-not $retried) { 'retry-not-observed' }
                    elseif (-not (Test-Path $retryStdout) -and -not (Test-Path $retryStderr)) { 'retry-command-did-not-start' }
                    else { 'retry-provenance-missing' }
            }
            $accepted = $denied -and $retried -and $provenancePresent -and (Test-Path $output) -and $execution -eq 'success' -and $run.exit_code -eq 0
            $tails = @{}
            foreach ($stream in @('stdout','stderr')) {
                $file = if ($stream -eq 'stdout') { $retryStdout } else { $retryStderr }
                $tail = ''
                if (-not $accepted -and (Test-Path $file)) {
                    $text = ConvertTo-ProbeSanitized (Get-Content $file -Raw)
                    if ($null -ne $text) { $tail = $text.Substring([Math]::Max(0, $text.Length - 800)) }
                }
                $tails[$stream] = $tail
            }
            $result.forms += @{ form = $form; real_guard_denied = $denied; retry_observed = $retried; retry_output_present = (Test-Path $output); retry_provenance_present = $provenancePresent; retry_reason = $retryReason; retry_stdout_tail = $tails.stdout; retry_stderr_tail = $tails.stderr; retry_execution_result = $execution; retry_actual_model = $actualModel; cli_exit_code = $run.exit_code; models = $parsed.models; independent_acceptance = $null; records = $records; accepted = $accepted }
        }
        $result.accepted = @($result.forms | Where-Object { -not $_.accepted }).Count -eq 0
    } catch { $result.probe_error = 'probe-infrastructure-failure: ' + $_.Exception.GetType().Name + ': ' + (ConvertTo-ProbeSanitized $_.Exception.Message) }
    finally {
        # A miss keeps its case folders: the guard log and transcript are the only proof of why.
        if (-not $result.accepted) { $result.kept_case_folder = $tempRoot }
        $result | ConvertTo-Json -Depth 60 | Set-Content (Join-Path $Destination 'result.json') -Encoding utf8NoBOM
        if ($result.accepted -and (Test-Path $tempRoot)) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
    return $result
}

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $Live) { throw 'This probe requires explicit -Live. Offline tests dot-source functions and use a fake CLI.' }
if (-not $OutDir -or ($Mode -eq 'capture' -and -not $FixtureDir)) { throw '-OutDir is required; capture also requires -FixtureDir.' }
if (-not $CliPath) { $CliPath = (Get-Command claude -ErrorAction Stop).Source }
$r = if ($Mode -eq 'guard') { Invoke-DispatchGuardProbe $CliPath ([IO.Path]::GetFullPath($OutDir)) } else { Invoke-NativeHooksProbe $CliPath ([IO.Path]::GetFullPath($OutDir)) ([IO.Path]::GetFullPath($FixtureDir)) }
if ($r.probe_error -or ($Mode -eq 'guard' -and -not $r.accepted)) { exit 1 }
exit 0
