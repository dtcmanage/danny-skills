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
$skillPrefix = if ($CoordinatorHost -eq 'codex') { '$dt-build' } else { '/dt-build' }
$prompt = "$skillPrefix resume $RunId (managed coordinator $CoordinatorId)"
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
if ($CoordinatorHost -eq 'codex') { $lines.Add("& codex exec $(ConvertTo-SingleQuoted $prompt) *>> $(ConvertTo-SingleQuoted $log)") }
else { $lines.Add("& claude -p $(ConvertTo-SingleQuoted $prompt) *>> $(ConvertTo-SingleQuoted $log)") }
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
    # A child the lease does not name would be a second coordinator: stop it, then give the lease back.
    if ($childPid) { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue }
    & pwsh -NoProfile -NonInteractive -File $dtJob lease -RunFolder $runRoot -Action release -CoordinatorId $CoordinatorId -Json *> $null
    throw
}
[pscustomobject][ordered]@{ coordinator_id = $CoordinatorId; host = $CoordinatorHost; pid = $childPid; log = $log } | ConvertTo-Json -Compress
