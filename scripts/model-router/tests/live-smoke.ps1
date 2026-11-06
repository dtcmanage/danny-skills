param([switch]$Live, [string]$OutDir)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# One tiny no-tools prompt per vendor through each repaired path: the bench transport
# (smoke-transport.ps1) and the dispatcher (dispatch.ps1). A dry report is regenerated
# into the audit folder. All router state is a copy under -OutDir, so no live roster,
# ledger or alert log can change, and every alert request is refused. Parameters are not
# marked mandatory because `pwsh -File` would prompt for them instead of failing.
# Dot-sourcing launches nothing: the harness calls Invoke-RouterLiveSmoke with fake runners.

$script:RouterLiveSmokeCategory = 'mechanical'
# ConvertFrom-Json turns an unprotected value of this shape into a DateTime.
$script:RouterLiveSmokeExpected = '2026-11-05T05:01:00Z'
$script:RouterLiveSmokeAcceptance = 'execution only; independent coordinator acceptance required'

function Get-RouterLiveSmokeEasternTime {
    $zone = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
    return [TimeZoneInfo]::ConvertTime([datetimeoffset]::UtcNow, $zone).ToString('yyyy-MM-dd h:mm:ss tt') + ' ET'
}

function Get-RouterLiveSmokeHash {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Copy-RouterLiveSmokeState {
    # Everything guards and reports read, without benchmark runs, archives or old reports.
    param([string]$Source, [string]$Destination)
    [void][IO.Directory]::CreateDirectory($Destination)
    $skipped = [Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return @{ copied = 0; skipped = @() } }
    $root = [IO.Path]::GetFullPath($Source).TrimEnd('\', '/')
    $copied = 0
    foreach ($file in (Get-ChildItem -LiteralPath $root -File -Recurse -Force)) {
        $relative = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
        if ($relative -match '^(_archive|canary|cost-reports|bench/runs|bench/review|bench/triggered)/') { continue }
        if ($file.Length -gt 20MB -or $relative -like 'roster.before-*') { continue }
        $target = Join-Path $Destination $relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        # A file another session holds is reported. The roster check below stays fatal.
        try { [IO.File]::Copy($file.FullName, $target, $true); $copied++ } catch { $skipped.Add($relative) }
    }
    if ((Test-Path -LiteralPath (Join-Path $root 'roster.json')) -and -not (Test-Path -LiteralPath (Join-Path $Destination 'roster.json'))) {
        throw 'LIVE_SMOKE_STATE_COPY_FAILED: roster.json could not be copied.'
    }
    return @{ copied = $copied; skipped = @($skipped) }
}

function New-RouterLiveSmokeProject {
    # An empty git project keeps repo instructions out of the prompt.
    $path = Join-Path ([IO.Path]::GetTempPath()) ('router-live-smoke-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($path)
    & git -C $path init -q
    if ($LASTEXITCODE -ne 0) { throw 'LIVE_SMOKE_PROJECT_FAILED: git init.' }
    & git -C $path -c user.email=live-smoke@example.invalid -c user.name=live-smoke commit --allow-empty -qm 'live smoke project'
    if ($LASTEXITCODE -ne 0) { throw 'LIVE_SMOKE_PROJECT_FAILED: git commit.' }
    return $path
}

function Get-RouterLiveSmokeDispatchArguments {
    # -Scrutiny gives the Claude lane an empty tool list and keeps resolver alerts off.
    # -Lane and -SingleDispatch forbid a cross-vendor fallback. -Live is added only by the entry.
    param([string]$Vendor, [string]$ProjectPath, [string]$PromptPath, [string]$OutputPath)
    return @('-ProjectPath', $ProjectPath, '-Category', $script:RouterLiveSmokeCategory, '-PromptPath', $PromptPath,
        '-OutputPath', $OutputPath, '-SelectionReason', 'bounded live smoke', '-Lane', $Vendor,
        '-AdHoc', '-ReadOnly', '-Scrutiny', '-SingleDispatch', '-TimeoutMs', '300000', '-Json')
}

function Read-RouterLiveSmokeTransport {
    # The saved report decides. The process exit is recorded and can only make it worse.
    param([string]$Directory, [object]$ExitCode)
    $path = Join-Path $Directory 'smoke-transport.json'
    $record = [ordered]@{ status = 'missing'; ok = $false; process_exit = $ExitCode; report = $path; model = $null; effort = $null; failure_category = $null; detail = $null; reason = $null; events = @() }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $record.detail = 'no saved transport result'; return $record }
    try { $saved = [IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable -DateKind String }
    catch { $record.status = 'unreadable'; $record.detail = 'saved transport result is not valid JSON'; return $record }
    foreach ($name in @('status', 'model', 'effort', 'failure_category', 'detail', 'reason')) {
        if ($saved -is [Collections.IDictionary] -and $saved.Contains($name)) { $record[$name] = $saved[$name] }
    }
    if ($saved -is [Collections.IDictionary] -and $saved.Contains('events')) {
        $record.events = @($saved.events | ForEach-Object { @{ method = $_.method; observation = $_.observation } })
    }
    $record.ok = ($record.status -ceq 'ok' -and $ExitCode -eq 0)
    if ($record.status -ceq 'ok' -and $ExitCode -ne 0) { $record.detail = 'saved status ok but the process exited nonzero' }
    return $record
}

function Read-RouterLiveSmokeDispatch {
    param([string]$Vendor, [string]$OutputPath, [object]$ExitCode, $Frontier)
    $evidencePath = $OutputPath + '.provenance.json'
    $record = [ordered]@{ status = 'missing'; ok = $false; process_exit = $ExitCode; evidence = $evidencePath; expected_text = $script:RouterLiveSmokeExpected; actual_text = $null; byte_exact = $false; execution_result = $null; lane = $null; requested_model = $null; actual_model = $null; failure_category = $null; termination_reason = $null; independent_acceptance = $null }
    if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
        # Compare the bytes on disk. A reader that strips a BOM or a prefix would hide a change.
        $bytes = [IO.File]::ReadAllBytes($OutputPath)
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        $record.actual_text = if ($text.Length -gt 200) { $text.Substring(0, 200) } else { $text }
        $record.byte_exact = [string]::Equals($text, $script:RouterLiveSmokeExpected, [StringComparison]::Ordinal) -and $bytes.Length -eq [Text.Encoding]::UTF8.GetByteCount($script:RouterLiveSmokeExpected)
    }
    if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) { return $record }
    try { $row = [IO.File]::ReadAllText($evidencePath) | ConvertFrom-Json -AsHashtable -DateKind String }
    catch { $record.status = 'unreadable'; return $record }
    foreach ($name in @('execution_result', 'lane', 'requested_model', 'actual_model', 'failure_category', 'termination_reason', 'independent_acceptance')) {
        if ($row -is [Collections.IDictionary] -and $row.Contains($name)) { $record[$name] = $row[$name] }
    }
    # Unknown telemetry stays unknown and never reads as a pass.
    $record.status = if ($record.execution_result -ceq 'success') {
        if (-not $record.actual_model) { 'unknown_model' }
        elseif (Test-RouterFrontierModel -Model $record.actual_model -Frontier $Frontier) { 'frontier_refused' }
        elseif ($record.lane -cne $Vendor) { 'wrong_lane' }
        elseif (-not $record.byte_exact) { 'answer_changed' }
        elseif ($ExitCode -ne 0) { 'nonzero_exit' }
        else { 'ok' }
    } elseif ($record.execution_result) { 'failed' } else { 'unknown' }
    $record.ok = $record.status -ceq 'ok'
    return $record
}

function Invoke-RouterLiveSmokeReport {
    # cost-report.ps1 always exits 0, so the regenerated file and the dry line are the evidence.
    # The copied state holds no old reports, so a present file was written by this run.
    param([string]$StateDir, [string]$LogPath)
    & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot '../cost-report.ps1') -StateDir $StateDir -Dry *> $LogPath
    return $LASTEXITCODE
}

function Read-RouterLiveSmokeReport {
    param([string]$StateDir, [string]$LogPath)
    $latest = Join-Path $StateDir 'cost-reports/latest.md'
    $log = if (Test-Path -LiteralPath $LogPath -PathType Leaf) { [IO.File]::ReadAllText($LogPath) } else { '' }
    $written = Test-Path -LiteralPath $latest -PathType Leaf
    $dry = $log -match 'dry report; nothing sent'
    $sourceFailed = $log -match 'DT_MODEL_ROUTER_COST_REPORT: skipped'
    $ok = $written -and $dry -and -not $sourceFailed
    return [ordered]@{ status = $(if ($ok) { 'ok' } else { 'failed' }); ok = $ok; path = $latest; log = $LogPath; dry = $dry }
}

function Write-RouterLiveSmokeResult {
    param([string]$Path, [object]$Result)
    [IO.File]::WriteAllText($Path, ($Result | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
}

function Write-RouterLiveSmokeTieNote {
    param([string]$Path, [string]$ResultPath, [object]$Result)
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('# Tie follow-up after the live smoke')
    $lines.Add('')
    $lines.Add("Both vendors passed the bounded live smoke at $($Result.finished_et).")
    $lines.Add('')
    $lines.Add('**This note approves nothing.** Old tie approvals stay invalid until fresh evidence exists and Danny approves it.')
    $lines.Add('')
    foreach ($vendor in @('codex', 'claude')) {
        $item = $Result.vendors[$vendor]
        $lines.Add("- ${vendor}: transport model $($item.transport.model), dispatch model $($item.dispatch.actual_model).")
    }
    $lines.Add('')
    $lines.Add('The smoke started no benchmark comparison, made no frontier call, and wrote no roster. Passing shows that the two paths executed. It says nothing about model quality.')
    $lines.Add('')
    $lines.Add('Next step, only with quota checks and existing approval rules: run a fresh comparison through the repaired transport to produce new tie proposals for Danny to review.')
    $lines.Add('')
    $lines.Add("Evidence: ``$ResultPath``")
    [IO.File]::WriteAllText($Path, (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
}

function Invoke-RouterLiveSmoke {
    # Returns the exit code. Runner seams exist so the harness never reaches the -Live entry.
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$SourceState,
        [Parameter(Mandatory)][scriptblock]$TransportRunner,
        [Parameter(Mandatory)][scriptblock]$DispatchRunner,
        [scriptblock]$QuotaGuard = { param($Vendor) Resolve-RouterModel -Category $script:RouterLiveSmokeCategory -Lane $Vendor },
        [scriptblock]$ReportRunner = { param($StateDir, $LogPath) Invoke-RouterLiveSmokeReport -StateDir $StateDir -LogPath $LogPath }
    )
    $root = [IO.Path]::GetFullPath($Destination)
    [void][IO.Directory]::CreateDirectory($root)
    $resultPath = Join-Path $root 'live-smoke-result.json'
    $notePath = Join-Path $root 'tie-follow-up.md'
    # A rerun must never leave an earlier pass readable as its own.
    if (Test-Path -LiteralPath $notePath -PathType Leaf) { Remove-Item -LiteralPath $notePath -Force }
    $attempt = Join-Path $root ('attempts/' + [datetimeoffset]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($attempt)
    $result = [ordered]@{
        status = 'started'; ok = $false; started_et = (Get-RouterLiveSmokeEasternTime); finished_et = $null
        acceptance = $script:RouterLiveSmokeAcceptance; attempt = $attempt; error = $null
        vendors = [ordered]@{}; report = $null; tie_follow_up = $null
        notifications = [ordered]@{ mode = 'off'; suppressed_requests = 0 }
        live_roster_unchanged = $null; state_copy = $null
    }
    Write-RouterLiveSmokeResult -Path $resultPath -Result $result

    $sourceRoster = Join-Path $SourceState 'roster.json'
    $rosterBefore = Get-RouterLiveSmokeHash -Path $sourceRoster
    $stateCopy = Join-Path $attempt 'state'
    $alertLog = Join-Path $attempt 'suppressed-alert-requests.log'
    $alertStub = Join-Path $attempt 'refuse-alerts.ps1'
    [IO.File]::WriteAllText($alertStub, "param(`$Request)`n[IO.File]::AppendAllText('$($alertLog.Replace("'", "''"))', ([string]`$Request.kind + `"``n`"))`nthrow 'Notifications are off during the live smoke.'`n", [Text.UTF8Encoding]::new($false))
    $saved = @{ state = $env:DT_MODEL_ROUTER_STATE; alert = $env:DT_MODEL_ROUTER_ALERT_TRANSPORT }
    $project = $null
    try {
        $result.state_copy = Copy-RouterLiveSmokeState -Source $SourceState -Destination $stateCopy
        # Process scope only: children inherit these and nothing persists.
        $env:DT_MODEL_ROUTER_STATE = $stateCopy
        $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $alertStub
        $project = New-RouterLiveSmokeProject
        $promptPath = Join-Path $attempt 'prompt.txt'
        [IO.File]::WriteAllText($promptPath, "Reply with exactly $script:RouterLiveSmokeExpected and nothing else. Use no tools.", [Text.UTF8Encoding]::new($false))
        $frontier = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../../references/model-router/frontier-models.json') -Raw | ConvertFrom-Json

        foreach ($vendor in @('codex', 'claude')) {
            $vendorDir = Join-Path $attempt $vendor
            [void][IO.Directory]::CreateDirectory($vendorDir)
            $item = [ordered]@{ status = 'failed'; ok = $false; quota = $null; transport = @{ status = 'not_run'; ok = $false; events = @() }; dispatch = @{ status = 'not_run'; ok = $false } }
            $result.vendors[$vendor] = $item
            $pick = & $QuotaGuard $vendor
            $item.quota = @{ status = [string]$pick.status; reason = [string]$pick.reason; model = [string]$pick.model }
            if ($pick.status -ne 'ok') {
                $item.status = 'quota_blocked'
                Write-RouterLiveSmokeResult -Path $resultPath -Result $result
                continue
            }
            $transportDir = Join-Path $vendorDir 'transport'
            [void][IO.Directory]::CreateDirectory($transportDir)
            $transportExit = & $TransportRunner $vendor $transportDir (Join-Path $vendorDir 'transport.log')
            $item.transport = Read-RouterLiveSmokeTransport -Directory $transportDir -ExitCode $transportExit
            Write-RouterLiveSmokeResult -Path $resultPath -Result $result

            $outputPath = Join-Path $vendorDir 'dispatch-answer.txt'
            $arguments = Get-RouterLiveSmokeDispatchArguments -Vendor $vendor -ProjectPath $project -PromptPath $promptPath -OutputPath $outputPath
            $dispatchExit = & $DispatchRunner $vendor $arguments (Join-Path $vendorDir 'dispatch.log')
            $item.dispatch = Read-RouterLiveSmokeDispatch -Vendor $vendor -OutputPath $outputPath -ExitCode $dispatchExit -Frontier $frontier
            $item.ok = $item.transport.ok -and $item.dispatch.ok
            $item.status = if ($item.ok) { 'ok' } else { 'failed' }
            Write-RouterLiveSmokeResult -Path $resultPath -Result $result
        }

        $reportLog = Join-Path $attempt 'report.log'
        $null = & $ReportRunner $stateCopy $reportLog
        $result.report = Read-RouterLiveSmokeReport -StateDir $stateCopy -LogPath $reportLog
    } catch {
        $result.error = Invoke-SecretRedaction -Text $_.Exception.Message
    } finally {
        $env:DT_MODEL_ROUTER_STATE = $saved.state
        $env:DT_MODEL_ROUTER_ALERT_TRANSPORT = $saved.alert
        if ($project -and (Test-Path -LiteralPath $project)) { Remove-Item -LiteralPath $project -Recurse -Force -ErrorAction SilentlyContinue }
    }

    if (Test-Path -LiteralPath $alertLog -PathType Leaf) { $result.notifications.suppressed_requests = @([IO.File]::ReadAllLines($alertLog)).Count }
    $result.live_roster_unchanged = ($rosterBefore -ceq (Get-RouterLiveSmokeHash -Path $sourceRoster))
    $vendorsOk = @('codex', 'claude' | Where-Object { $result.vendors.Contains($_) -and $result.vendors[$_].ok }).Count -eq 2
    $reportOk = $null -ne $result.report -and $result.report.ok
    $result.ok = $vendorsOk -and $reportOk -and $result.live_roster_unchanged -and -not $result.error
    $result.status = if ($result.ok) { 'ok' } else { 'failed' }
    $result.finished_et = Get-RouterLiveSmokeEasternTime
    if ($result.ok) {
        Write-RouterLiveSmokeTieNote -Path $notePath -ResultPath $resultPath -Result $result
        $result.tie_follow_up = $notePath
    }
    Write-RouterLiveSmokeResult -Path $resultPath -Result $result
    return $(if ($result.ok) { 0 } else { 1 })
}

$routerLiveSmokeDotSourced = $MyInvocation.InvocationName -eq '.'
if (-not $routerLiveSmokeDotSourced) {
    if ([string]::IsNullOrWhiteSpace($OutDir)) { throw 'LIVE_SMOKE_OUTDIR_REQUIRED: -OutDir is required.' }
    if (-not $Live) { throw 'LIVE_SMOKE_LIVE_REQUIRED: this smoke spends real model calls and requires explicit -Live.' }
}
. (Join-Path $PSScriptRoot '../resolve-model.ps1')
. (Join-Path $PSScriptRoot '../dispatch-evidence.ps1')
if ($routerLiveSmokeDotSourced) { return }

$liveExit = Invoke-RouterLiveSmoke -Destination $OutDir -SourceState (Get-RouterStatePath) -TransportRunner {
    param($Vendor, $Directory, $LogPath)
    & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot '../bench/smoke-transport.ps1') -Vendor $Vendor -OutDir $Directory -Live *> $LogPath
    $LASTEXITCODE
} -DispatchRunner {
    param($Vendor, $Arguments, $LogPath)
    & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot '../dispatch.ps1') @Arguments -Live *> $LogPath
    $LASTEXITCODE
}
Write-Output (Join-Path ([IO.Path]::GetFullPath($OutDir)) 'live-smoke-result.json')
exit $liveExit
