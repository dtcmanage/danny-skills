# Explicit ad-hoc read/extract lane. Build and verification lanes never enter here.
Set-StrictMode -Version Latest

function Assert-ReadWorkerLane {
    param([bool]$ReadExtract, [bool]$AdHoc, [bool]$ReadOnly, [bool]$Preflight, [bool]$Scrutiny, [Collections.IDictionary]$Parameters)
    if ($ReadExtract -and (-not $AdHoc -or $ReadOnly -or $Preflight -or $Scrutiny -or $env:DT_JOB_ID -or $env:DT_BUILD_COORDINATOR_ID)) {
        throw 'READ_EXTRACT_LANE_INVALID: use -AdHoc -ReadExtract for a single extract artifact, outside managed builds; do not combine with -ReadOnly/-Scrutiny/-Preflight.'
    }
    if (-not $ReadExtract -and @($Parameters.Keys | Where-Object { $_ -like 'ReadMax*' }).Count) {
        throw 'READ_EXTRACT_REQUIRED: read caps require explicit -ReadExtract.'
    }
}

function New-ReadWorkerMeter {
    param([string]$Prompt)
    @{ tools = 0; turns = 0; input_tokens = 0L; seen_tools = @{}; seen_turns = @{}; inputs = @{};
       # UTF-8 bytes are a conservative admission bound for the supplied prompt, not a tokenizer.
       prompt_bytes = [Text.Encoding]::UTF8.GetByteCount($Prompt); output_edits = 0; last_tool = $null;
       result = $null; actual_model = $null; malformed = $false; turn_complete = $false }
}

function Add-ReadWorkerFrame {
    param([hashtable]$Meter, [string]$Line, [string]$Vendor, [string]$OutputPath, [string]$ProjectPath)
    # Vendor frames have optional fields; missing dictionary values are null.
    Set-StrictMode -Off
    if ([string]::IsNullOrWhiteSpace($Line)) { return }
    try { $frame = ConvertFrom-Json -InputObject $Line -AsHashtable -Depth 100 -ErrorAction Stop }
    catch { $Meter.malformed = $true; return }
    $tools = @()
    if ($Vendor -eq 'claude') {
        if ($frame.type -eq 'assistant' -and $frame.message) {
            $message = $frame.message
            $id = [string]$message.id
            if (-not $id) { $Meter.malformed = $true; return }
            if (-not $Meter.seen_turns.ContainsKey($id)) { $Meter.seen_turns[$id] = $true; $Meter.turns++ }
            if ($message.model) { $Meter.actual_model = $message.model }
            if ($message.usage) {
                $u = $message.usage
                $Meter.inputs[$id] = [long]$u.input_tokens + [long]$u.cache_read_input_tokens + [long]$u.cache_creation_input_tokens
            }
            foreach ($block in @($message.content)) {
                if ($block.type -eq 'tool_use') {
                    $paths = @()
                    if ($block.name -in @('Write','Edit') -and $block.input.file_path) { $paths = @([string]$block.input.file_path) }
                    $tools += @{ id=[string]$block.id; paths=$paths; mutation=($paths.Count -gt 0); completed=$false }
                }
            }
        }
        elseif ($frame.type -eq 'user' -and $frame.message) {
            foreach ($block in @($frame.message.content)) {
                if ($block.type -eq 'tool_result' -and -not $block.is_error -and $Meter.last_tool -and $block.tool_use_id -eq $Meter.last_tool.id) {
                    $tools += @{id=[string]$block.tool_use_id; paths=$Meter.last_tool.paths; mutation=$Meter.last_tool.mutation; completed=$true}
                }
            }
        }
        elseif ($frame.type -eq 'result') { $Meter.result = $frame }
    }
    else {
        if ($frame.type -eq 'thread.started') { $Meter.thread_id = [string]$frame.thread_id }
        if ($frame.type -eq 'turn.started') { $Meter.turns++ }
        if ($frame.type -eq 'turn.completed' -and $frame.usage) {
            $Meter.turn_complete = $true
            $Meter.inputs["turn-$($Meter.turns)"] = [long]$frame.usage.input_tokens
        }
        if ($frame.type -in @('item.started','item.completed') -and $frame.item) {
            $item = $frame.item
            if ($item.type -notin @('reasoning','agent_message','todo_list','error','compaction')) {
                $paths = @()
                if ($item.type -eq 'file_change') { $paths = @($item.changes | ForEach-Object { [string]$_.path }) }
                $tools += @{id=[string]$item.id; paths=$paths; mutation=($item.type -eq 'file_change'); completed=($frame.type -eq 'item.completed' -and $item.status -eq 'completed')}
            }
        }
    }
    foreach ($tool in $tools) {
        if (-not $tool.id) { $Meter.malformed = $true; continue }
        if (-not $Meter.seen_tools.ContainsKey($tool.id)) {
            $Meter.seen_tools[$tool.id] = $false; $Meter.tools++
            if (-not $tool.mutation) { $Meter.output_edits = 0 }
            $Meter.last_tool = $tool
        }
        if ($tool.completed -and -not $Meter.seen_tools[$tool.id]) {
            $Meter.seen_tools[$tool.id] = $true
            $onlyOutput = $tool.mutation -and $tool.paths.Count -gt 0
            foreach ($path in $tool.paths) {
                $full = [IO.Path]::GetFullPath($path, $ProjectPath)
                if (-not [string]::Equals($full, $OutputPath, $(if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }))) { $onlyOutput = $false }
            }
            if ($onlyOutput -and (Test-Path -LiteralPath $OutputPath -PathType Leaf) -and (Get-Item -LiteralPath $OutputPath).Length -gt 0) { $Meter.output_edits++ }
            else { $Meter.output_edits = 0 }
        }
    }
    $Meter.input_tokens = 0L
    foreach ($value in $Meter.inputs.Values) { $Meter.input_tokens += [long]$value }
}

function Invoke-BoundedReadWorker {
    param(
        [ValidateSet('codex','claude')][string]$Vendor, [string]$CliPath, [string]$ProjectPath,
        [string]$OutputPath, [string]$Prompt, [string]$PromptPath, [string]$Model, [string]$Effort,
        [int]$TimeoutMs,
        [ValidateRange(1,128)][int]$ReadMaxToolCalls,
        [ValidateRange(1,64)][int]$ReadMaxTurns,
        [ValidateRange(256,1000000)][int]$ReadMaxInputTokens,
        [ValidateRange(100,540000)][int]$ReadMaxMs,
        [object]$Context, [object]$Resolution, [string]$SelectionReason
    )
    . (Join-Path $PSScriptRoot 'worker-process-tree.ps1')
    # Installed per-skill links must resolve before walking out to repo imports.
    $readSkillRoot = Split-Path -Parent $PSScriptRoot
    $resolvedSkill = (Get-Item -LiteralPath $readSkillRoot).ResolveLinkTarget($true)
    if ($resolvedSkill) { $readSkillRoot = $resolvedSkill.FullName }
    $readRepoRoot = Split-Path -Parent (Split-Path -Parent $readSkillRoot)
    . (Join-Path $readRepoRoot 'scripts/claude-headless-auth.ps1')
    . (Join-Path $readRepoRoot 'scripts/invoke-codex-process.ps1')
    $OutputPath = [IO.Path]::GetFullPath($OutputPath)
    if (Test-Path -LiteralPath $OutputPath -PathType Container) { throw 'READ_EXTRACT_OUTPUT_NOT_FILE' }
    if ($OutputPath -eq [IO.Path]::GetFullPath($PromptPath)) { throw 'READ_EXTRACT_OUTPUT_IS_PROMPT' }
    # Never infer the artifact from prose. The wrapper appends the exact declared path.
    $Prompt += "`nREAD_EXTRACT_OUTPUT_PATH: $OutputPath`nWrite only this extract artifact. Size limits are SOFT targets; finish within roughly 10% over the target. Do not polish to hit an exact count. Cite source paths and page/sheet/slide/line provenance. Finish after writing the extract. No nested workers, build work, retries or diagnosis. If unfinished, mark PARTIAL and state what remains.`n"
    $meter = New-ReadWorkerMeter -Prompt $Prompt
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $started = Get-Date
    $lastUsagePoll = -1000L
    $deadline = [Math]::Min($ReadMaxMs, [Math]::Floor($TimeoutMs * 0.9))
    $reason = $null; $proc = $null; $exitCode = $null; $complete = $false; $launches = 0
    $buffers = @([Text.StringBuilder]::new(), [Text.StringBuilder]::new())
    $tasks = @($null, $null); $closed = @($false, $false)
    # Preserve any prior artifact as evidence, but never count it as this dispatch's output.
    if (Test-Path -LiteralPath $OutputPath) {
        Move-Item -LiteralPath $OutputPath -Destination ($OutputPath + '.before-' + $Context.dispatch_id) -Force
    }
    Remove-Item -LiteralPath ($OutputPath + '.last-message.tmp') -Force -ErrorAction SilentlyContinue
    try {
        if ($meter.prompt_bytes -ge $ReadMaxInputTokens) { $reason = 'input-token-cap: prompt UTF-8 admission bound' }
        else {
            $info = [Diagnostics.ProcessStartInfo]::new()
            $info.FileName = $CliPath
            if ([IO.Path]::GetExtension($CliPath) -eq '.ps1') {
                $info.FileName = 'pwsh'
                foreach ($arg in @(Get-Utf8PowerShellArguments -ScriptPath $CliPath)) { $info.ArgumentList.Add($arg) }
            }
            $info.WorkingDirectory = $ProjectPath
            $info.UseShellExecute = $false; $info.CreateNoWindow = $true
            $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
            $info.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
            $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
            $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
            if ($Vendor -eq 'claude') {
                $null = Set-ClaudeHeadlessAuth -StartInfo $info
                $arguments = @('-p','--model',$Model,'--effort',$Effort,'--permission-mode','bypassPermissions','--output-format','stream-json','--verbose','--strict-mcp-config','--tools','Read,Glob,Grep,Write,Edit,WebSearch,WebFetch')
            } else {
                # Match the existing ad-hoc write-capable wrapper's permission policy;
                # do not silently block network/SSH required by an authorized source.
                $arguments = @('--ask-for-approval','never','exec','--ignore-user-config','--skip-git-repo-check','--model',$Model,'-c',('model_reasoning_effort="'+$Effort+'"'),'-c','default_permissions=":danger-full-access"','--cd',$ProjectPath,'--json','--output-last-message',($OutputPath+'.last-message.tmp'),'-')
            }
            if ([IO.Path]::GetExtension($CliPath).ToLowerInvariant() -in @('.cmd','.bat')) {
                $info.FileName = $env:ComSpec
                $quotedCli = '"' + $CliPath.Replace('"','""') + '"'
                $quotedArgs = @($arguments | ForEach-Object { '"' + ([string]$_).Replace('"','\"') + '"' })
                $arguments = @('/d','/s','/c',($quotedCli+' '+($quotedArgs -join ' ')))
            }
            foreach ($arg in $arguments) { $info.ArgumentList.Add($arg) }
            $null = Initialize-WorkerProcessJob
            $null = Start-RouterFrontierDispatch -Resolution $Resolution -DispatchId $Context.dispatch_id
            $proc = [Diagnostics.Process]::new(); $proc.StartInfo = $info
            if (-not $proc.Start()) { throw 'READ_EXTRACT_START_FAILED' }
            $launches++
            $readers = @($proc.StandardOutput, $proc.StandardError)
            $tasks = @($readers[0].ReadLineAsync(), $readers[1].ReadLineAsync())
            $stdin = $proc.StandardInput.WriteAsync($Prompt); $stdinClosed = $false
            while ($true) {
                for ($i = 0; $i -lt 2; $i++) {
                    # One frame per pipe per iteration keeps metering responsive under a flood.
                    if (-not $closed[$i] -and $tasks[$i].IsCompleted) {
                        $line = $tasks[$i].GetAwaiter().GetResult()
                        if ($null -eq $line) { $closed[$i] = $true }
                        else {
                            [void]$buffers[$i].AppendLine($line)
                            if ($i -eq 0) { Add-ReadWorkerFrame -Meter $meter -Line $line -Vendor $Vendor -OutputPath $OutputPath -ProjectPath $ProjectPath }
                            $tasks[$i] = $readers[$i].ReadLineAsync()
                        }
                    }
                }
                if (-not $stdinClosed -and $stdin.IsCompleted) { [void]$stdin.GetAwaiter().GetResult(); $proc.StandardInput.Close(); $stdinClosed = $true }
                if ($Vendor -eq 'codex' -and $meter.ContainsKey('thread_id') -and $watch.ElapsedMilliseconds - $lastUsagePoll -ge 100) {
                    $lastUsagePoll = $watch.ElapsedMilliseconds
                    $execution = Read-RouterCodexExecutionEvidence -Project $ProjectPath -StartedAt $started -SessionId $meter.thread_id
                    if ($execution.model) { $meter.actual_model = $execution.model }
                    if ($execution.usage) { $meter.input_tokens = [Math]::Max($meter.input_tokens, [long](Get-DispatchValue $execution.usage 'input_tokens')) }
                }
                if ($meter.malformed) { $reason = 'invalid-structured-stream' }
                elseif ($meter.tools -ge $ReadMaxToolCalls) { $reason = 'tool-call-cap' }
                elseif ($meter.turns -ge $ReadMaxTurns) { $reason = 'turn-cap' }
                elseif ($meter.input_tokens -ge $ReadMaxInputTokens) { $reason = 'input-token-cap' }
                elseif ($meter.output_edits -ge 2) { $reason = 'output-only-reedit' }
                elseif ($watch.ElapsedMilliseconds -ge $deadline) { $reason = 'read-deadline' }
                if ($reason) { break }
                if ($proc.HasExited -and $closed[0] -and $closed[1]) { break }
                Start-Sleep -Milliseconds 5
            }
            if ($reason -and -not $proc.HasExited) { $proc.Kill($true); [void]$proc.WaitForExit(1000) }
            if ($proc.HasExited) { $exitCode = $proc.ExitCode }
            $complete = -not $reason -and $exitCode -eq 0 -and -not $meter.malformed
            if ($Vendor -eq 'claude' -and (-not $meter.result -or $meter.result.is_error)) { $complete = $false }
            if ($Vendor -eq 'codex' -and -not $meter.turn_complete) { $complete = $false }
            if (-not $complete -and -not $reason) { $reason = 'worker-failure-or-incomplete-stream' }
        }
    } catch { $reason = 'read-worker-error: ' + (Invoke-SecretRedaction -Text $_.Exception.Message) }
    finally {
        if ($proc) {
            if (-not $proc.HasExited) { try { $proc.Kill($true); [void]$proc.WaitForExit(1000) } catch {} }
            $proc.Dispose()
        }
        $null = Stop-WorkerJobProcesses
        Undo-RouterFrontierReservation -Resolution $Resolution -DispatchId $Context.dispatch_id
    }
    $hasArtifact = (Test-Path -LiteralPath $OutputPath -PathType Leaf) -and -not [string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($OutputPath))
    if (-not $hasArtifact) { $complete = $false; $reason = (@($reason, 'no-output: declared artifact missing or empty') | Where-Object { $_ }) -join '; ' }
    $partial = -not $complete
    $artifact = if ($hasArtifact) { Invoke-SecretRedaction -Text ([IO.File]::ReadAllText($OutputPath)) } else { '' }
    if ($partial) {
        $artifact += "`n`n<!-- READ_EXTRACT_PARTIAL -->`nPARTIAL: $reason`nProvenance: dispatch $($Context.dispatch_id); vendor $Vendor; requested model $Model; source prompt $PromptPath; tools $($meter.tools); turns $($meter.turns); observed input tokens $($meter.input_tokens). Any extracted content above is retained; completeness is unverified.`n"
    }
    [IO.File]::WriteAllText($OutputPath, $artifact)
    [IO.File]::WriteAllText(($OutputPath+'.stream.log'), (Invoke-SecretRedaction -Text ($buffers[0].ToString()+"`n"+$buffers[1].ToString())))
    $final = if ($Vendor -eq 'claude' -and $meter.result) { [string]$meter.result.result } elseif (Test-Path -LiteralPath ($OutputPath+'.last-message.tmp')) { [IO.File]::ReadAllText($OutputPath+'.last-message.tmp') } else { '' }
    [IO.File]::WriteAllText(($OutputPath+'.final.md'), (Invoke-SecretRedaction -Text $final))
    Remove-Item -LiteralPath ($OutputPath+'.last-message.tmp') -Force -ErrorAction SilentlyContinue
    $result = [pscustomobject]@{
        pass=$complete; partial=$partial; read_extract=$true; intentional_finalization=[bool]$reason
        failure_category=$(if ($partial) { 'read-partial' } else { $null }); termination_reason=$reason
        lane=$Vendor; resolved_model=$Model; effort=$Effort; selection_reason=$SelectionReason
        output_path=$OutputPath; output_sha256=(Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant()
        prompt_sha256=(Get-FileHash -LiteralPath $PromptPath -Algorithm SHA256).Hash.ToLowerInvariant()
        dispatched_prompt_sha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Prompt))).ToLowerInvariant()
        stream_log_path=($OutputPath+'.stream.log'); output_final_path=($OutputPath+'.final.md')
        artifact_present=$hasArtifact; backup_pick=$null; diagnosis=$null; dispatch_count=$launches
        read_limits=@{tool_calls=$ReadMaxToolCalls; turns=$ReadMaxTurns; input_tokens=$ReadMaxInputTokens; deadline_ms=$deadline}
        read_observed=@{tool_calls=$meter.tools; turns=$meter.turns; input_tokens=$meter.input_tokens; prompt_admission_bytes=$meter.prompt_bytes}
    }
    Write-RouterDispatchEvidence -Path ($OutputPath+'.provenance.json') -Record $result -Context $Context -ExitCode $(if ($complete) { 0 } else { 2 }) -ActualModel $meter.actual_model -Usage @{input_tokens=$meter.input_tokens}
    return $result
}
