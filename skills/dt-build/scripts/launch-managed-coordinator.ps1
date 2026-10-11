#Requires -Version 7.0
# Default coordinator launcher for dt-build-watcher.ps1 (override with DT_BUILD_COORDINATOR_LAUNCHER).
# Takes the coordinator lease (launched_by watcher), then starts a hidden, detached headless coordinator
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

$dtJob = Join-Path $PSScriptRoot 'dt-job.ps1'
$runRoot = [System.IO.Path]::GetFullPath($RunFolder)
$skillRoot = Split-Path -Parent $PSScriptRoot
$resolvedSkillRoot = (Get-Item -LiteralPath $skillRoot).ResolveLinkTarget($true)
if ($resolvedSkillRoot) { $skillRoot = $resolvedSkillRoot.FullName }
$resumeGuide = Join-Path $skillRoot 'references/managed-resume.md'
# Use the dedicated resume entry, not a skill invocation that reloads the entire intake skill.
# Only the headless Codex coordinator opts out of eager canonical reads; authority reads remain mandatory.
$prompt = @"
Resume existing managed build $RunId as coordinator $CoordinatorId on $CoordinatorHost.
Run folder: $runRoot
Checkpoint: $BuildStatePath
Read and follow $resumeGuide as your entry contract, plus the canonical context bridge.
For a lean bridge, read the compact coordinator rulebook via scripts/read-coordinator-rulebook.ps1 -CoordinatorHost $CoordinatorHost; canonical policy is deferred until its action is triggered.
Complete required authorization reads, then mark-bootstrap immediately, and continue the checkpoint's next action.
Do not repeat intake or preload implementation/close-out references. Never run dt-job resume or approve.
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
    # The permission flags invoke-codex-chunk.ps1 uses for a substantive chunk: no approval prompts, and on
    # Windows (where Codex removed its sandbox) explicit full access instead of a sandbox that fails closed.
    $permission = if ($env:OS -eq 'Windows_NT') { "-c $(ConvertTo-SingleQuoted 'default_permissions=":danger-full-access"')" } else { '--sandbox workspace-write' }
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
    $lines.Add("& codex --ask-for-approval never exec $permission $hookArgs $(ConvertTo-SingleQuoted $prompt) *>> $(ConvertTo-SingleQuoted $log)")
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
    $lines.Add("& claude -p --strict-mcp-config --mcp-config $(ConvertTo-SingleQuoted $mcpConfig) --settings $(ConvertTo-SingleQuoted $settings) --permission-mode bypassPermissions $(ConvertTo-SingleQuoted $prompt) *>> $(ConvertTo-SingleQuoted $log)")
}
$lines.Add('exit $LASTEXITCODE')
$encoded = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes(($lines -join "`n")))

# The watcher runs this launcher under coordinator.lock and sets DT_BUILD_COORDINATOR_LOCK_HELD, so this
# acquire skips that lock. Take the lease before starting anything: if it is refused, no child exists.
& pwsh -NoProfile -NonInteractive -File $dtJob lease -RunFolder $runRoot -Action acquire -CoordinatorId $CoordinatorId -Host $CoordinatorHost -LaunchedBy watcher -Json | Out-Null
if ($LASTEXITCODE -ne 0) { throw "DT_BUILD_LEASE_FAILED: lease acquire for $CoordinatorId exited $LASTEXITCODE; nothing started" }

$childPid = $null
try {
    $pwsh = [System.Environment]::ProcessPath
    $commandLine = "`"$pwsh`" -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $encoded"
    $startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
    $result = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $commandLine; CurrentDirectory = $workDir; ProcessStartupInformation = $startup }
    if ($result.ReturnValue -ne 0) { throw "DT_BUILD_LAUNCH_FAILED: Win32_Process.Create returned $($result.ReturnValue)" }
    $childPid = [int]$result.ProcessId
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
