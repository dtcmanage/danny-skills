#Requires -Version 7.0
# Default coordinator launcher for dt-build-watcher.ps1 (override with DT_BUILD_COORDINATOR_LAUNCHER).
# Takes the coordinator lease (launched_by watcher, state starting until the coordinator marks bootstrap), then starts a hidden, detached headless coordinator
# (`claude -p` or `codex exec`) for one managed run, records the child pid in the lease, and returns at once.
# A refused lease starts nothing; a failed start releases the lease. A replacement launcher keeps that order.
param(
    # $Host is an automatic variable, so the host binds through an alias.
    [Parameter(Mandatory)]
    [Alias('Host')]
    [ValidateSet('claude', 'codex')]
    [string]$CoordinatorHost,

    [Parameter(Mandatory)]
    [string]$RunId,

    [Parameter(Mandatory)]
    [string]$RunFolder,

    [Parameter(Mandatory)]
    [string]$BuildStatePath,

    [Parameter(Mandatory)]
    [string]$CoordinatorId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'powershell-startup.ps1')
Disable-DtPowerShellStartupProfile
. (Join-Path $PSScriptRoot 'toolbox-path.ps1')
Enable-DtBuildToolboxPath

$dtJob = Join-Path $PSScriptRoot 'dt-job.ps1'
$runRoot = [System.IO.Path]::GetFullPath($RunFolder)
$skillRoot = Split-Path -Parent $PSScriptRoot
$resolvedSkillRoot = (Get-Item -LiteralPath $skillRoot).ResolveLinkTarget($true)
if ($resolvedSkillRoot) { $skillRoot = $resolvedSkillRoot.FullName }
# Use the dedicated resume entry, not a skill invocation that reloads the entire intake skill.
# Only the headless Codex coordinator opts out of eager canonical reads; authority reads remain mandatory.
$prompt = @"
Resume existing managed build $RunId as coordinator $CoordinatorId on $CoordinatorHost.
Run folder: $runRoot
Checkpoint: $BuildStatePath
Your single bootstrap entry read is: pwsh -NoProfile -File "$PSScriptRoot/read-coordinator-rulebook.ps1" -CoordinatorHost $CoordinatorHost
Run that command alone. Next run: pwsh -NoProfile -File "$PSScriptRoot/read-coordinator-state.ps1" -RunFolder "$runRoot" -RunId "$RunId" -BuildStatePath "$BuildStatePath" -CoordinatorId "$CoordinatorId"
Read its complete output, including all mandatory authorization originals (all parts if requested). Do not cat build-state, roadmap, design or canonical policy docs during bootstrap unless the authority contract explicitly requires that original.
Follow the canonical context bridge$(if ($CoordinatorHost -eq 'claude') { ' (for this Claude coordinator: the build coordinator instructions in your system prompt, generated at launch from the live CLAUDE.md chain; do not reread those CLAUDE.md files)' }). Canonical policy deferred by a lean bridge still loads when its action is triggered.
Complete required authorization reads, then mark-bootstrap immediately with: pwsh -NoProfile -File "$dtJob" -Verb mark-bootstrap -RunFolder "$runRoot" -CoordinatorId "$CoordinatorId" -Host $CoordinatorHost -Json
Only after the marker load on-demand sections for the checkpoint's next action. The bootstrap order is system instructions, entry, state digest, mark-bootstrap. Target at most 20,000 coordinator-added input tokens.
Do not repeat intake or preload implementation/close-out references. Never run dt-job resume, approve, delegate or hold.
That rule binds you only: the launching session runs resume, approve and relaunch, so never ask Danny to type a command; raise only genuine decisions with dt-job await-danny.
AI-5: Keep disposable source exports, copies and test scratch under ~/.cache/<run>/, never synced planning/workstation folders. Retain logs/reports in the owning workstation _audits or run evidence. Clean only scratch created by this invocation; carry this rule into every chunk brief.
At a stop, use await-danny -WaitMinutes 7.5 -CallStartedUtc <UTC captured before pwsh launch> -Json with tool timeout 600000. A live director can approve while this call blocks and renews your lease: on decision=approved read its receipt and continue in this SAME coordinator. Otherwise checkpoint and end; never re-wait the boundary. Never self-approve.
"@
$log = Join-Path $runRoot "coordinator-$CoordinatorId.log"
$workDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($BuildStatePath))

function ConvertTo-SingleQuoted {
    param([string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

# Win32_Process.Create gives the child a fresh environment, so the wrapper sets what the coordinator needs.
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("`$env:DT_BUILD_COORDINATOR_ID = $(ConvertTo-SingleQuoted $CoordinatorId)")
foreach ($name in @('DT_BUILD_STATE_DIR', 'CLAUDE_CONFIG_DIR', 'CODEX_HOME')) {
    $value = [System.Environment]::GetEnvironmentVariable($name)
    if ($value) { $lines.Add("`$env:$name = $(ConvertTo-SingleQuoted $value)") }
}
$lines.Add("Set-Location -LiteralPath $(ConvertTo-SingleQuoted $workDir)")
if ($CoordinatorHost -eq 'codex') {
    $lines.Add("`$env:DT_BUILD_LEAN_BOOTSTRAP = '1'")
    # The permission flags invoke-codex-chunk.ps1 uses for a substantive chunk: no approval prompts and
    # explicit full access on every platform (Windows has no Codex sandbox; POSIX workspace-write keeps
    # .git read-only, so a sandboxed coordinator could not commit).
    $permission = "-c $(ConvertTo-SingleQuoted 'default_permissions=":danger-full-access"')"
    # The same context hooks a Claude coordinator gets, as session flags for this coordinator only: after
    # each step the coordinator sees its context state, so it hands off at a safe point instead of being
    # killed mid-work, and past the hard limit only the handoff steps run. Codex runs them once trusted.
    $hooksDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\hooks')).Replace('\', '/')
    $hookOverrides = @(foreach ($pair in @(@('PreToolUse', 'coordinator-pretooluse.ps1'), @('PostToolUse', 'coordinator-posttooluse.ps1'))) {
        "hooks.$($pair[0])=[{matcher=`"*`",hooks=[{type=`"command`",command='pwsh -NoProfile -NonInteractive -File `"$hooksDir/$($pair[1])`"'}]}]"
    })
    # In-process: pwsh -File would flatten the string[] into one argument. The helper never throws.
    $trust = & (Join-Path $PSScriptRoot 'ensure-codex-hook-trust.ps1') -HookOverrides $hookOverrides
    [System.IO.File]::AppendAllText($log, "hook trust: $($trust -join ' ')`n", [System.Text.UTF8Encoding]::new($false))
    $hookArgs = ($hookOverrides | ForEach-Object { "-c $(ConvertTo-SingleQuoted $_)" }) -join ' '
    # Sol's full 872k window (828k usable), compacting only at 800k: past the 760k window cap in context-guard.
    $windowArgs = "-c model_context_window=872000 -c model_auto_compact_token_limit=800000"
    $lines.Add("& codex --ask-for-approval never exec $permission $hookArgs $windowArgs $(ConvertTo-SingleQuoted $prompt) *>> $(ConvertTo-SingleQuoted $log)")
}
else {
    $lines.Add('Remove-Item Env:DT_BUILD_LEAN_BOOTSTRAP -ErrorAction SilentlyContinue')
    # Minimal tool set: no MCP servers, and the coordinator hooks from a run-folder copy of the snippet
    # with the real hooks path. Danny runs bypass deliberately; the hooks still deny at the call.
    $mcpConfig = Join-Path $runRoot 'coordinator-mcp.json'
    $settings = Join-Path $runRoot 'coordinator-settings.json'
    $hooksDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\hooks')).Replace('\', '/')
    $snippet = [System.IO.File]::ReadAllText((Join-Path $hooksDir 'settings-snippet.json'))
    [System.IO.File]::WriteAllText($mcpConfig, '{ "mcpServers": {} }', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($settings, $snippet.Replace('__DT_BUILD_HOOKS_DIR__', $hooksDir), [System.Text.UTF8Encoding]::new($false))
    # Lean start (measured 2026-11-24: 58k -> 18k host tokens before the coordinator's own reads). Claude
    # Code's CLAUDE.md loading is off and the coordinator gets the build coordinator instructions instead,
    # regenerated from the live CLAUDE.md chain at every launch so they never drift. Skills are off and the
    # tool list comes from the run folder's coordinator-tools.txt (one comma- or line-separated list; the
    # director edits it, and the next coordinator launch picks it up). Hooks still run, so the context
    # guard is unaffected. DT_BUILD_FULL_CONTEXT=1 restores Claude Code's normal loading for a run.
    # '--' ends the options: --tools takes several values and would otherwise swallow the prompt.
    $leanArgs = ''
    if ($env:DT_BUILD_FULL_CONTEXT -ne '1') {
        # One file per run, overwritten at each launch: generation is deterministic, so unchanged rules give
        # identical bytes; the log records a short hash so a mid-run rule change is visible.
        $rulesPath = Join-Path $runRoot 'coordinator-instructions.md'
        $built = & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'build-orchestrator-rules.ps1') -WorkDir $workDir -OutPath $rulesPath 2>&1
        if ($LASTEXITCODE -eq 0) {
            $toolsFile = Join-Path $runRoot 'coordinator-tools.txt'
            if (-not (Test-Path -LiteralPath $toolsFile)) {
                [System.IO.File]::WriteAllText($toolsFile, "Bash,Read,Edit,Write`n", [System.Text.UTF8Encoding]::new($false))
            }
            $tools = (([System.IO.File]::ReadAllText($toolsFile) -split '[,\s]+') | Where-Object { $_ }) -join ','
            if (-not $tools) { $tools = 'Bash,Read,Edit,Write' }
            $lines.Add("`$env:CLAUDE_CODE_DISABLE_CLAUDE_MDS = '1'")
            $leanArgs = "--append-system-prompt-file $(ConvertTo-SingleQuoted $rulesPath) --disable-slash-commands --tools $(ConvertTo-SingleQuoted $tools) "
            $rulesHash = (Get-FileHash -LiteralPath $rulesPath -Algorithm SHA256).Hash.Substring(0, 12).ToLowerInvariant()
            [System.IO.File]::AppendAllText($log, "lean start: instructions $rulesPath (sha256 $rulesHash); tools $tools`n", [System.Text.UTF8Encoding]::new($false))
        }
        else {
            [System.IO.File]::AppendAllText($log, "lean start skipped (normal CLAUDE.md loading): $($built -join ' ')`n", [System.Text.UTF8Encoding]::new($false))
        }
    }
    $lines.Add("& claude -p --strict-mcp-config --mcp-config $(ConvertTo-SingleQuoted $mcpConfig) --settings $(ConvertTo-SingleQuoted $settings) --permission-mode bypassPermissions $leanArgs-- $(ConvertTo-SingleQuoted $prompt) *>> $(ConvertTo-SingleQuoted $log)")
}
$lines.Add('$coordinatorExit = $LASTEXITCODE')
$lines.Add("`$capacityText = [IO.File]::ReadAllText($(ConvertTo-SingleQuoted $log))")
$lines.Add("`$failureCategory = if (`$coordinatorExit -ne 0 -and `$capacityText -match '(?i)Selected model is at capacity|(?:model|server) is (?:currently )?(?:at capacity|overloaded)|overloaded_error|insufficient model capacity') { 'capacity' } else { `$null }")
$lines.Add("[IO.File]::WriteAllText($(ConvertTo-SingleQuoted (Join-Path $runRoot "coordinator-$CoordinatorId.exit.json")), (([ordered]@{ coordinator_id = $(ConvertTo-SingleQuoted $CoordinatorId); exit_code = `$coordinatorExit; failure_category = `$failureCategory } | ConvertTo-Json -Compress)))")
$lines.Add('exit $coordinatorExit')
$encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes(($lines -join "`n")))

# The watcher runs this launcher under coordinator.lock and sets DT_BUILD_COORDINATOR_LOCK_HELD, so this
# acquire skips that lock. Take the lease before starting anything: if it is refused, no child exists.
& pwsh -NoProfile -NonInteractive -File $dtJob lease -RunFolder $runRoot -Action acquire -CoordinatorId $CoordinatorId -Host $CoordinatorHost -LaunchedBy watcher -Json | Out-Null
if ($LASTEXITCODE -ne 0) { throw "DT_BUILD_LEASE_FAILED: lease acquire for $CoordinatorId exited $LASTEXITCODE; nothing started" }

$childPid = $null
try {
    $pwsh = [System.Environment]::ProcessPath
    if ($IsWindows) {
        $commandLine = "`"$pwsh`" -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $encoded"
        $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
        $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $workDir; ProcessStartupInformation = $startup }
        if ($result.ReturnValue -ne 0) { throw "DT_BUILD_LAUNCH_FAILED: Win32_Process.Create returned $($result.ReturnValue)" }
        $childPid = [int]$result.ProcessId
    }
    else {
        # Linux/Mac: mirror dt-job's non-Windows launch. Under a systemd timer the watcher unit needs
        # KillMode=process so the coordinator outlives the watcher run.
        # The wrapper itself carries the coordinator tag from exec (the encoded script's own assignment is not
        # visible in /proc/<pid>/environ), so the watcher can find it and everything under it after a kill
        # re-parents the children. dt-job strips the tag from jobs, which survive rotation.
        # Its own streams are redirected too: an inherited stdout pipe would hold the watcher, which captures
        # this launcher's output, inside its tick (and coordinator.lock) for the coordinator's whole life
        # (2026-11-23 on CT202: a launcher returned only when its coordinator exited). The coordinator's
        # own output already goes to its log through the wrapper's *>>.
        $process = Start-Process -FilePath $pwsh -WorkingDirectory $workDir -PassThru -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) -Environment @{ DT_BUILD_COORDINATOR_ID = $CoordinatorId } `
            -RedirectStandardOutput '/dev/null' -RedirectStandardError (Join-Path $runRoot "coordinator-$CoordinatorId.wrapper-stderr.log")
        $childPid = [int]$process.Id
    }
    & pwsh -NoProfile -NonInteractive -File $dtJob lease -RunFolder $runRoot -Action renew -CoordinatorId $CoordinatorId -Pid $childPid -Json | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "DT_BUILD_LEASE_FAILED: recording pid $childPid for $CoordinatorId exited $LASTEXITCODE" }
}
catch {
    # A child the lease does not name would be a second coordinator: stop it and the claude/codex process
    # under it, then give the lease back.
    if ($childPid) { try { [System.Diagnostics.Process]::GetProcessById($childPid).Kill($true) } catch { } }
    & pwsh -NoProfile -NonInteractive -File $dtJob lease -RunFolder $runRoot -Action release -CoordinatorId $CoordinatorId -Json *> $null
    throw
}
[pscustomobject][ordered]@{ coordinator_id = $CoordinatorId; host = $CoordinatorHost; pid = $childPid; log = $log } | ConvertTo-Json -Compress
