param([Alias('Context')][string]$RouterResearchCliContext, [Alias('Json')][switch]$RouterResearchCliJson, [Alias('Categories')][string[]]$RouterResearchCliCategories, [Alias('CandidateModels')][string[]]$RouterResearchCliCandidateModels, [Alias('Trigger')][ValidateSet('release','confirmation','followup','refresh','manual')][string]$RouterResearchCliTrigger = 'manual', [Alias('Lane')][ValidateSet('codex','claude')][string]$RouterResearchCliLane = 'codex')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')
. (Join-Path $PSScriptRoot '../invoke-codex-process.ps1')
. (Join-Path $PSScriptRoot '../wrap-prompt-envelope.ps1')
. (Join-Path $PSScriptRoot 'send-router-alert.ps1')
. (Join-Path $PSScriptRoot 'vendor-limits.ps1')

# Lock protocol: the lock file carries a random owner token plus the owner's PID and process start time. The owner
# refreshes updated_at before and after every research call. A lock is stale when its owner process is gone (or the PID
# now belongs to a different process start) or when its heartbeat is older than 10 minutes plus the longest single
# research call. Only the holder of the token deletes the lock.
$script:RouterResearchCallTimeoutMs = 3600000
$script:RouterLockStaleMinutes = 10 + ($script:RouterResearchCallTimeoutMs / 60000)
if (-not (Get-Variable RouterResearchSleep -Scope Script -ErrorAction SilentlyContinue)) { $script:RouterResearchSleep = { param($Milliseconds) Start-Sleep -Milliseconds $Milliseconds } }

function Format-RouterCodexFailure {
    # Keeps the diagnosable part of a failed Codex run; a bare "failed" message left no way to tell a crash from a timeout.
    param([string]$Label, [object]$Result)
    $stderr = [string]$Result.stderr
    if ($stderr.Length -gt 2000) { $stderr = $stderr.Substring($stderr.Length - 2000) }
    return "$Label (exit_code=$($Result.exit_code); timed_out=$($Result.timed_out); duration_ms=$($Result.duration_ms)). stderr tail:`n$stderr"
}

function Get-RouterResearchJsonBody {
    # The reply is one JSON object, possibly fenced. On 2026-10-07 every Claude reply opened with a "[HH:mm:ss] " preface
    # (the local-time note each prompt carries, echoed back) and all nine categories failed to parse, so text before the
    # first brace or after the last is dropped.
    param([string]$Text)
    $body = ([string]$Text).Trim()
    if ($body -match '^```(?:json)?\s*([\s\S]*?)\s*```$') { $body = $Matches[1].Trim() }
    if (-not $body.StartsWith('{')) {
        $start = $body.IndexOf('{'); $end = $body.LastIndexOf('}')
        if ($start -ge 0 -and $end -gt $start) { $body = $body.Substring($start, $end - $start + 1) }
    }
    return $body
}

function Write-RouterResearchFailure {
    param([Parameter(Mandatory)][string]$StateDir, [Parameter(Mandatory)][string]$FileName, [Parameter(Mandatory)][string]$Detail)
    $failDir = Join-Path $StateDir 'research-failures'; New-Item -ItemType Directory -Path $failDir -Force | Out-Null
    if ($Detail.Length -gt 20000) { $Detail = $Detail.Substring(0,20000) }
    [IO.File]::WriteAllText((Join-Path $failDir $FileName),$Detail,[Text.UTF8Encoding]::new($false))
}

function Get-RouterResearchFailures {
    param([string]$Category)
    $state = Get-RouterStateDir
    $dir = Join-Path $state 'research-failures'
    if (-not (Test-Path -LiteralPath $dir)) { return }
    foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -Filter '*.txt')) {
        if ($file.Name -notmatch '^([^@]+)@(\d{8}T\d{9})(?:-|\.txt$)') { continue }
        $name = $Matches[1]; $stamp = $Matches[2]
        if ($Category -and $name -cne $Category) { continue }
        $et = [datetime]::ParseExact($stamp, 'yyyyMMddTHHmmssfff', [Globalization.CultureInfo]::InvariantCulture)
        $at = [TimeZoneInfo]::ConvertTimeToUtc($et, [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time'))
        [pscustomobject]@{ category=$name; at=$at; date_et=$et.ToString('yyyy-MM-dd'); file=$file }
    }
}

function Get-RouterResearchRecoveryTime {
    param([string]$Category)
    $stored = Read-RouterJsonObject -Path (Join-Path (Get-RouterStateDir) "readings/$Category.json")
    if ($stored -and $stored.PSObject.Properties['readings'] -and
        @($stored.readings | Where-Object { @($_.results | Where-Object { $null -ne $_ }).Count }).Count) {
        if ($stored.PSObject.Properties['researched_at']) { return ([datetimeoffset]$stored.researched_at).UtcDateTime }
        # Older saved readings have no commit timestamp; only completed, committed passes establish recovery.
        $path = Join-Path (Get-RouterStateDir) 'readings/passes.jsonl'
        $times = @(if (Test-Path -LiteralPath $path) {
            Get-Content -LiteralPath $path | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json -Depth 20 } | Where-Object {
                $_.PSObject.Properties['completed_at'] -and $_.completed_at -and $Category -cin $_.categories -and
                $_.PSObject.Properties['failed_categories'] -and $Category -cnotin $_.failed_categories -and
                -not ($_.PSObject.Properties['interrupted'] -and $_.interrupted) -and
                -not ($_.PSObject.Properties['deferred'] -and $_.deferred)
            } | ForEach-Object { ([datetimeoffset]$_.completed_at).UtcDateTime } | Sort-Object -Descending
        })
        if ($times.Count) { return $times[0] }
    }
    return [datetime]::MinValue
}

function Get-RouterResearchFailureKey {
    param([string]$Category, [datetimeoffset]$At)
    $recovered = Get-RouterResearchRecoveryTime -Category $Category
    $first = @(Get-RouterResearchFailures -Category $Category | Where-Object { $_.at -gt $recovered } | Sort-Object at | Select-Object -First 1)
    $date = if ($first.Count) { $first[0].date_et } else { [TimeZoneInfo]::ConvertTime($At, [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')).ToString('yyyy-MM-dd') }
    return "research-failure:${Category}:$date"
}

function Open-RouterLockExclusive {
    param([string]$Path)
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        try { return [IO.FileStream]::new($Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Delete) }
        catch [IO.FileNotFoundException] { return $null }
        catch [IO.IOException], [UnauthorizedAccessException] { if (-not (Test-Path -LiteralPath $Path)) { return $null }; Start-Sleep -Milliseconds 50 }
    }
    throw 'ROUTER_LOCK_BUSY'
}

function Read-RouterLockStream {
    param([IO.FileStream]$Stream)
    try {
        $reader = [IO.StreamReader]::new($Stream,[Text.UTF8Encoding]::new($false),$true,1024,$true)
        try { $raw = $reader.ReadToEnd() } finally { $reader.Dispose() }
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

function Write-RouterLockStream {
    param([IO.FileStream]$Stream, [object]$Owner)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Owner | ConvertTo-Json -Compress))
    $Stream.SetLength(0); $Stream.Position = 0
    $Stream.Write($bytes,0,$bytes.Length); $Stream.Flush()
}

function Test-RouterLockOwnerStale {
    param([object]$Owner, [datetime]$Now = (Get-Date))
    try {
        foreach ($key in @('token','pid','process_start','updated_at')) { if ($null -eq $Owner -or -not $Owner.PSObject.Properties[$key]) { return $true } }
        if (($Now - [datetime]$Owner.updated_at).TotalMinutes -gt $script:RouterLockStaleMinutes) { return $true }
        $process = Get-Process -Id ([int]$Owner.pid) -ErrorAction SilentlyContinue
        return ($null -eq $process -or $process.StartTime.ToUniversalTime().Ticks -ne ([datetime]$Owner.process_start).ToUniversalTime().Ticks)
    } catch { return $true }
}

function New-RouterLockOwner {
    param([string]$Token, [string]$Phase, [datetime]$Now = (Get-Date))
    return [pscustomobject]@{ token = $Token; pid = $PID; process_start = (Get-Process -Id $PID).StartTime.ToString('o'); phase = $Phase; created_at = $Now.ToString('o'); updated_at = $Now.ToString('o') }
}

function Update-RouterLockOwned {
    param([string]$Path, [string]$Token, [ValidateSet('heartbeat','take','release')][string]$Action, [datetime]$Now = (Get-Date))
    $stream = Open-RouterLockExclusive -Path $Path
    if ($null -eq $stream) { return $false }
    try {
        $owner = Read-RouterLockStream -Stream $stream
        if ($null -eq $owner -or -not $owner.PSObject.Properties['token'] -or [string]$owner.token -cne $Token -or -not $Token) { return $false }
        if ($Action -eq 'release') { [IO.File]::Delete($Path); return $true }
        if ($Action -eq 'take') {
            $taken = New-RouterLockOwner -Token $Token -Phase 'running' -Now $Now
            if ($owner.PSObject.Properties['created_at']) { $taken.created_at = [string]$owner.created_at }
            $owner = $taken
        } else { $owner.updated_at = $Now.ToString('o') }
        Write-RouterLockStream -Stream $stream -Owner $owner
        return $true
    } finally { $stream.Dispose() }
}

function Remove-RouterLockIfStale {
    param([string]$Path, [datetime]$Now = (Get-Date))
    $stream = Open-RouterLockExclusive -Path $Path
    if ($null -eq $stream) { return 'missing' }
    try {
        if (-not (Test-RouterLockOwnerStale -Owner (Read-RouterLockStream -Stream $stream) -Now $Now)) { return 'live' }
        [IO.File]::Delete($Path)
        return 'removed'
    } finally { $stream.Dispose() }
}

function Enter-RouterResearchLock {
    param([string]$Path, [datetime]$Now = (Get-Date), [string]$Phase = 'running')
    $alerts = [System.Collections.Generic.List[string]]::new()
    $token = [guid]::NewGuid().ToString('N')
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            $stream = [IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::Delete)
            try { Write-RouterLockStream -Stream $stream -Owner (New-RouterLockOwner -Token $token -Phase $Phase -Now $Now) } finally { $stream.Dispose() }
            return [pscustomobject]@{ acquired = $true; token = $token; alerts = @($alerts.ToArray()) }
        } catch [IO.IOException], [UnauthorizedAccessException] {
            $state = Remove-RouterLockIfStale -Path $Path -Now $Now
            if ($state -eq 'live') { return [pscustomobject]@{ acquired = $false; token = $null; alerts = @($alerts.ToArray()) } }
            if ($state -eq 'removed') { $alerts.Add('research-stale-lock-cleared') }
        }
    }
    return [pscustomobject]@{ acquired = $false; token = $null; alerts = @($alerts.ToArray()) }
}

function Get-RouterCategoryCallArguments {
    # Research always runs on an explicit router pick; an unpinned call would fall back to a CLI default that may be a frontier model.
    param([string]$Lane, [string]$OutPath)
    if (-not (Get-Command Resolve-RouterModel -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'resolve-model.ps1') }
    $pick = Resolve-RouterModel -Category deep-research -Lane $Lane -SkipModelCheck
    $script:RouterResearchCurrentModel = $pick.model
    if (-not $pick.model -or ($pick.PSObject.Properties['status'] -and $pick.status -eq 'wait')) {
        $error = [InvalidOperationException]::new("Category research has no available $Lane model: $($pick.reason)")
        $error.Data['router_status'] = 'wait'
        throw $error
    }
    if ($Lane -eq 'codex') { return @('--ask-for-approval','never','exec','--ignore-user-config','-c','web_search="live"','--sandbox','read-only','--cd',$PSScriptRoot,'--model',$pick.model,'--output-last-message',$OutPath,'-') }
    return @('-p','--model',$pick.model,'--allowedTools','WebSearch,WebFetch','--output-format','json')
}

function Invoke-RouterCategoryCall {
    param([string]$Category, [string]$Lane, [string]$Prompt, [int]$TimeoutMs = $script:RouterResearchCallTimeoutMs)
    if ((Get-Variable RouterResearchInvoker -Scope Script -ErrorAction SilentlyContinue) -and $script:RouterResearchInvoker) { return (& $script:RouterResearchInvoker $Category $Lane $Prompt) }
    if ($Lane -eq 'codex') {
        $codex = (Get-Command codex -ErrorAction Stop).Source
        $out = Join-Path $env:TEMP ('router-category-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            $result = Invoke-CodexProcess -CodexPath $codex -Arguments (Get-RouterCategoryCallArguments -Lane codex -OutPath $out) -Prompt $Prompt -WorkingDirectory $PSScriptRoot -TimeoutMs $TimeoutMs
            if ($result.timed_out -or $result.exit_code -ne 0 -or -not (Test-Path -LiteralPath $out)) { throw (Format-RouterCodexFailure -Label 'Category research process failed or timed out' -Result $result) }
            return [IO.File]::ReadAllText($out)
        } finally { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
    }
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $cli = (Get-Command claude -ErrorAction Stop).Source
    if ([IO.Path]::GetExtension($cli) -eq '.ps1') {
        $psi.FileName = (Get-Command pwsh -ErrorAction Stop).Source
        foreach ($arg in @(Get-Utf8PowerShellArguments -ScriptPath $cli)) { [void]$psi.ArgumentList.Add($arg) }
    } else { $psi.FileName = $cli }
    foreach ($arg in @(Get-RouterCategoryCallArguments -Lane claude -OutPath '')) { [void]$psi.ArgumentList.Add($arg) }
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $utf8 = [Text.UTF8Encoding]::new($false)
    $psi.StandardInputEncoding = $utf8; $psi.StandardOutputEncoding = $utf8; $psi.StandardErrorEncoding = $utf8
    $process = [Diagnostics.Process]::Start($psi)
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($Prompt); $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutMs)) { $process.Kill($true); throw 'Category research timed out.' }
        if ($process.ExitCode -ne 0) { throw ('Category research failed: ' + $errors.Result) }
        $response = $output.Result | ConvertFrom-Json -Depth 40
        if ($response.PSObject.Properties['result']) { return [string]$response.result }
        return [string]$output.Result
    } finally { $process.Dispose() }
}

function Get-RouterNonComparableModels {
    param([Parameter(Mandatory)][string]$Category, [Parameter(Mandatory)][string]$NewModel, [Parameter(Mandatory)][string[]]$RosterModels, [object]$NewReadings)
    $stored = Read-RouterJsonObject -Path (Join-Path (Join-Path (Get-RouterStateDir) 'readings') ($Category + '.json'))
    if ($null -eq $NewReadings) { $NewReadings = $stored }
    if ($null -eq $NewReadings) { return @() }
    $newKeys = @($NewReadings.readings | Where-Object { @($_.results | Where-Object model -CEQ $NewModel).Count -gt 0 } | ForEach-Object { "$($_.benchmark)`n$($_.version)`n$($_.harness)" })
    if (-not $newKeys.Count) { return @() }
    foreach ($model in $RosterModels) {
        if ($model -ceq $NewModel) { continue }
        $shared = @(@($stored, $NewReadings) | Where-Object { $_ } | ForEach-Object { $_.readings } | Where-Object { ("$($_.benchmark)`n$($_.version)`n$($_.harness)" -cin $newKeys) -and @($_.results | Where-Object model -CEQ $model).Count -gt 0 })
        if ($shared.Count -eq 0) { $model }
    }
}

function Get-RouterStaleReadingModels {
    param([int]$Months = 6, [datetime]$Now = (Get-Date))
    $roster = (Read-RouterRoster).roster
    $models = @($roster.jobs.PSObject.Properties | ForEach-Object { @($_.Value.first,$_.Value.backup) } | Where-Object { $_ } | Sort-Object -Unique)
    $dir = Join-Path (Get-RouterStateDir) 'readings'
    foreach ($model in $models) {
        $dates = @()
        if (Test-Path -LiteralPath $dir) {
            foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -Filter '*.json')) {
                $stored = Read-RouterJsonObject -Path $file.FullName
                if ($stored) { $dates += @($stored.readings | Where-Object { @($_.results | Where-Object model -CEQ $model).Count -gt 0 } | ForEach-Object { [datetime]$_.date }) }
            }
        }
        if ($dates.Count -eq 0 -or (@($dates | Sort-Object -Descending)[0] -lt $Now.AddMonths(-$Months))) { $model }
    }
}

function Invoke-RouterCategoryResearch {
    param([Parameter(Mandatory)][string[]]$Categories, [Parameter(Mandatory)][string[]]$Models, [string]$NewModel, [ValidateSet('release','confirmation','followup','refresh','manual')][string]$Trigger = 'manual', [ValidateSet('codex','claude')][string]$Lane = 'codex', [string]$Context, [datetime]$Now = (Get-Date))
    Assert-RouterWindowsOwner -Action 'Roster research'
    $state = Get-RouterStateDir
    $lock = Join-Path $state 'research.lock'
    $entry = Enter-RouterResearchLock -Path $lock -Now $Now
    if (-not $entry.acquired) { throw 'ROUTER_LOCK_BUSY' }
    $readingsDir = Join-Path $state 'readings'
    $passId = [guid]::NewGuid().ToString('N')
    $stage = Join-Path $readingsDir ('.pass-' + $passId)
    $failed = [Collections.Generic.List[string]]::new()
    $notes = [Collections.Generic.List[string]]::new()
    $record = [pscustomobject]@{ pass_id=$passId; trigger=$Trigger; categories=@($Categories); models=@($Models); started_at=$Now.ToString('o'); completed_at=$null; failed_categories=@(); notes=@(); attempts=@{}; transient_failures=@{}; research_failure_keys=@{}; interrupted=$false; deferred=$false; diagnosis=$null }
    foreach ($category in $Categories) {
        $record.attempts[$category] = [Collections.Generic.List[object]]::new()
        $record.transient_failures[$category] = [Collections.Generic.List[string]]::new()
    }
    try {
        New-Item -ItemType Directory -Path $readingsDir -Force | Out-Null
        Get-ChildItem -LiteralPath $readingsDir -Directory -Filter '.pass-*' | Remove-Item -Recurse -Force
        New-Item -ItemType Directory -Path $stage | Out-Null
        $sources = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/benchmark-sources.json') -Raw | ConvertFrom-Json -Depth 20
        $fixed = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/research-category-prompt.md') -Raw) + "`n`n" + (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/readings-schema.md') -Raw)
        foreach ($category in $Categories) {
            if (-not $sources.PSObject.Properties[$category] -or $category -cnotmatch '^[a-z-]+$') { throw "Unknown research category: $category" }
            $pending = @(@{ models = @($Models); benchmarks = @() })
            $combined = [Collections.Generic.List[object]]::new()
            $checked = [Collections.Generic.List[object]]::new()
            for ($i = 0; $i -lt $pending.Count; $i++) {
                $request = $pending[$i]
                $prompt = $fixed + "`nCategory: $category`nCandidate models: " + ($request.models -join ', ') + "`nSources: " + (ConvertTo-Json -InputObject @($sources.$category) -Depth 10 -Compress)
                if ($request.benchmarks.Count) { $prompt += "`nFollow-up benchmarks only: " + ($request.benchmarks -join ', ') }
                if ($Context) { $prompt += "`n" + (New-PromptEnvelope -Label 'RESEARCH CONTEXT' -Content $Context) }
                [void](Update-RouterLockOwned -Path $lock -Token $entry.token -Action heartbeat)
                $raw = ''
                $returned = $false
                $callStarted = [datetimeoffset](& $script:RouterDiagnosisClock)
                $unexplainedRetried = $false
                $unavailableLanes = @()
                try {
                    while ($true) {
                        $remaining = $script:RouterResearchCallTimeoutMs - (([datetimeoffset](& $script:RouterDiagnosisClock)) - $callStarted).TotalMilliseconds
                        if ($remaining -le 0) {
                            $failed.Add($category); $record.deferred = $true
                            if (-not $record.diagnosis) { $record.diagnosis = 'quota' }
                            return $record
                        }
                        $attempt = [pscustomobject]@{ attempt=($record.attempts[$category].Count + 1); lane=$Lane; succeeded=$false }
                        $record.attempts[$category].Add($attempt)
                        $script:RouterResearchCurrentModel = ''
                        try {
                            $raw = Invoke-RouterCategoryCall -Category $category -Lane $Lane -Prompt $prompt -TimeoutMs ([int]$remaining)
                            $record.diagnosis = $null
                            break
                        } catch {
                            $failure = $_
                            $failedModel = $script:RouterResearchCurrentModel
                            $errorText = $failure.Exception.Message
                            $at = [datetimeoffset](& $script:RouterDiagnosisClock)
                            $et = [TimeZoneInfo]::ConvertTime($at, [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time'))
                            if (-not $record.research_failure_keys.ContainsKey($category)) { $record.research_failure_keys[$category] = Get-RouterResearchFailureKey -Category $category -At $at }
                            $record.transient_failures[$category].Add(($errorText -split '\r?\n')[0])
                            $failurePath = Join-Path $state ('research-failures/' + $category + '@' + $et.ToString('yyyyMMddTHHmmssfff') + "-$passId-attempt$($attempt.attempt).txt")
                            Write-RouterResearchFailure -StateDir $state -FileName ([IO.Path]::GetFileName($failurePath)) -Detail "attempt $($attempt.attempt): call threw`nalert_key: $($record.research_failure_keys[$category])`nerror: $errorText"
                            $dispatch = Resolve-RouterDispatchFailure -Vendor $Lane -ErrorText $errorText
                            $diagnosis = $dispatch.verdict
                            $refusal = Test-RouterLimitRefusal -Vendor $Lane -Text $errorText
                            if ($refusal.refused -or $failure.Exception.Data['router_status'] -eq 'wait' -or ($dispatch.PSObject.Properties['status'] -and $dispatch.status -eq 'wait')) { $diagnosis = 'quota' }
                            # Persist the diagnosed call before connectivity probes or failover can change its provenance.
                            $outcome = [ordered]@{
                                key="research:${passId}:${category}:$($attempt.attempt)"; run_id=$passId; pass_id=$passId
                                repo='danny-skills'; at=$at.ToUniversalTime().ToString('o'); lane=$attempt.lane; model=$failedModel
                                category=$category; attempt=$attempt.attempt; pass=$false; escalated=$false
                                failure_category='environment'; diagnosis=$diagnosis; source='research'; tier='research'; failure_file=$failurePath
                            }
                            Add-RouterOutcome -StateDir $state -Row $outcome
                            if ($diagnosis -eq 'offline') {
                                $outageStart = $at
                                do {
                                    $remaining = $script:RouterResearchCallTimeoutMs - (([datetimeoffset](& $script:RouterDiagnosisClock)) - $callStarted).TotalMilliseconds
                                    if ($remaining -le 0) { break }
                                    $null = & $script:RouterResearchSleep ([int][Math]::Min(60000, $remaining))
                                    [void](Update-RouterLockOwned -Path $lock -Token $entry.token -Action heartbeat)
                                    if ((([datetimeoffset](& $script:RouterDiagnosisClock)) - $callStarted).TotalMilliseconds -ge $script:RouterResearchCallTimeoutMs) { break }
                                    $dispatch = Resolve-RouterDispatchFailure -Vendor $Lane -ErrorText ''
                                } while ($dispatch.verdict -eq 'offline')
                                if ($dispatch.verdict -ne 'offline' -and (([datetimeoffset](& $script:RouterDiagnosisClock)) - $callStarted).TotalMilliseconds -lt $script:RouterResearchCallTimeoutMs) {
                                    if ((([datetimeoffset](& $script:RouterDiagnosisClock)) - $outageStart).TotalMinutes -gt 5) {
                                        $key = 'router-offline:' + [TimeZoneInfo]::ConvertTime($outageStart, [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')).ToString('yyyy-MM-dd HH:mm') + ' ET'
                                        $null = Send-RouterAlert -Key $key -Message (Get-RouterAlertMessage -Key $key)
                                    }
                                    if ($dispatch.verdict -ne 'vendor_incident' -and $dispatch.verdict -ne 'quota') { continue }
                                    $diagnosis = $dispatch.verdict
                                }
                            }
                            if ($diagnosis -in @('quota','vendor_incident')) {
                                $unavailableLanes += $Lane
                                $record.diagnosis = $diagnosis
                                if ($diagnosis -eq 'quota') {
                                    if ($refusal.refused) {
                                        $blockArgs = @{ Vendor=$Lane }
                                        if ($refusal.reset_at_utc) { $blockArgs.ResetAtUtc = [datetimeoffset]$refusal.reset_at_utc }
                                        $null = Add-RouterVendorBlock @blockArgs
                                    }
                                }
                                $other = if ($Lane -eq 'codex') { 'claude' } else { 'codex' }
                                if ($other -notin $unavailableLanes -and -not (Get-RouterVendorBlocked -Vendor $other)) { $Lane = $other; continue }
                                $failed.Add($category); $record.deferred = $true; $record.diagnosis = $diagnosis
                                return $record
                            }
                            if ($diagnosis -eq 'unexplained' -and -not $unexplainedRetried -and
                                (([datetimeoffset](& $script:RouterDiagnosisClock)) - $callStarted).TotalMilliseconds -lt $script:RouterResearchCallTimeoutMs) { $unexplainedRetried = $true; continue }
                            $record.interrupted = $true; $record.diagnosis = $diagnosis
                            if ($diagnosis -eq 'unexplained') {
                                $key = "vendor-error:${Lane}:$passId"
                                $message = Get-RouterAlertMessage -Key $key -Model $script:RouterResearchCurrentModel -Category $category -ErrorText $errorText -Checks $dispatch.checks -ArtifactPath $failurePath -PromptText $prompt
                                $null = Send-RouterAlert -Key $key -Message $message
                            }
                            throw $failure
                        }
                    }
                    $returned = $true
                    $parsed = (Get-RouterResearchJsonBody -Text ([string]$raw)) | ConvertFrom-Json -Depth 40
                    if (-not (Test-RouterReadings -Readings $parsed -Category $category -Models $request.models)) { throw 'Invalid category readings' }
                    $attempt.succeeded = $true
                } catch {
                    # Diagnosed stops interrupt the entire pass; invalid replies only fail this category.
                    if (-not $returned) { $failed.Add($category); throw }
                    $errorText = $_.Exception.Message
                    $record.transient_failures[$category].Add(($errorText -split '\r?\n')[0])
                    $et = [TimeZoneInfo]::ConvertTime(([datetimeoffset](& $script:RouterDiagnosisClock)), [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time'))
                    if (-not $record.research_failure_keys.ContainsKey($category)) { $record.research_failure_keys[$category] = Get-RouterResearchFailureKey -Category $category -At ([datetimeoffset](& $script:RouterDiagnosisClock)) }
                    Write-RouterResearchFailure -StateDir $state -FileName ($category + '@' + $et.ToString('yyyyMMddTHHmmssfff') + "-$passId.txt") -Detail ("alert_key: $($record.research_failure_keys[$category])`nerror: $errorText`n" + [string]$raw)
                    if ($i -gt 0) { $notes.Add("$category follow-up failed: $($_.Exception.Message)") }
                    else { $failed.Add($category) }
                    break
                }
                foreach ($source in $parsed.sources_checked) { $checked.Add([pscustomobject]@{ name=$source.name; comparable_results_found=$source.comparable_results_found; note=$source.note }) }
                foreach ($reading in $parsed.readings) {
                    $combined.Add([pscustomobject]@{ benchmark=$reading.benchmark; version=$reading.version; date=$reading.date; harness=$reading.harness; effort_class=$reading.effort_class; independent=$reading.independent; url=$reading.url; results=@($reading.results | ForEach-Object { [pscustomobject]@{ model=$_.model; score=$_.score; tasks=$_.tasks; margin=$_.margin } }) })
                }
                if ($Trigger -eq 'release' -and $i -eq 0 -and $NewModel) {
                    $temporary = [pscustomobject]@{ category=$category; readings=@($combined.ToArray()) }
                    $roster = (Read-RouterRoster).roster
                    $job = Get-RouterCategoryJob -Category $category
                    $rosterModels = @(@($roster.jobs.$job.first, $roster.jobs.$job.backup) | Where-Object { $_ -and $_ -cne $NewModel } | Sort-Object -Unique)
                    $keys = @($combined | ForEach-Object { "$($_.benchmark)`n$($_.version)`n$($_.harness)" })
                    $missing = @(Get-RouterNonComparableModels -Category $category -NewModel $NewModel -RosterModels $rosterModels -NewReadings $temporary)
                    if ($missing.Count -and $keys.Count) { $pending += @{ models=@($NewModel) + $missing; benchmarks=@($combined | ForEach-Object benchmark | Sort-Object -Unique) } }
                }
            }
            if ($failed -contains $category) { continue }
            $payload = [pscustomobject]@{ category=$category; sources_checked=@($checked.ToArray()); readings=@($combined.ToArray()) }
            [IO.File]::WriteAllText((Join-Path $stage ($category + '.json')),(ConvertTo-Json -InputObject $payload -Depth 40),[Text.UTF8Encoding]::new($false))
        }
        foreach ($category in $Categories) {
            $staged = Join-Path $stage ($category + '.json')
            if (-not (Test-Path -LiteralPath $staged)) { continue }
            $incoming = Get-Content -LiteralPath $staged -Raw | ConvertFrom-Json -Depth 40
            $target = Join-Path $readingsDir ($category + '.json')
            $previous = Read-RouterJsonObject -Path $target
            $all = [Collections.Generic.List[object]]::new()
            if ($previous) { foreach ($reading in $previous.readings) { $all.Add($reading) } }
            foreach ($reading in $incoming.readings) {
                foreach ($result in $reading.results) {
                    $found = $false
                    foreach ($existing in $all) {
                        if ($existing.benchmark -ceq $reading.benchmark -and $existing.version -ceq $reading.version -and $existing.harness -ceq $reading.harness -and $existing.effort_class -ceq $reading.effort_class -and [bool]$existing.independent -eq [bool]$reading.independent) {
                            $prior = @($existing.results | Where-Object model -CEQ $result.model)
                            if ($prior.Count) {
                                if ([datetime]$reading.date -gt [datetime]$existing.date) { $existing.results = @($existing.results | Where-Object model -CNE $result.model) + $result; $existing.date = $reading.date }
                            } else { $existing.results = @($existing.results) + $result }
                            $found = $true; break
                        }
                    }
                    if (-not $found) { $all.Add([pscustomobject]@{ benchmark=$reading.benchmark; version=$reading.version; date=$reading.date; harness=$reading.harness; effort_class=$reading.effort_class; independent=$reading.independent; url=$reading.url; results=@($result) }) }
                }
            }
            $saved = [pscustomobject]@{ category=$category; sources_checked=@($incoming.sources_checked); readings=@($all.ToArray()) }
            if (@($incoming.readings | Where-Object { @($_.results).Count }).Count) {
                $saved | Add-Member -NotePropertyName researched_at -NotePropertyValue ([datetimeoffset](& $script:RouterDiagnosisClock)).ToString('o')
            } elseif ($previous -and $previous.PSObject.Properties['researched_at']) {
                $saved | Add-Member -NotePropertyName researched_at -NotePropertyValue $previous.researched_at
            }
            [IO.File]::WriteAllText($target,(ConvertTo-Json -InputObject $saved -Depth 40),[Text.UTF8Encoding]::new($false))
        }
        return $record
    } catch {
        $record.interrupted = $true
        if (-not $record.diagnosis) { $record.diagnosis = 'unexplained' }
        throw
    } finally {
        try {
            $record.completed_at = ([datetimeoffset](& $script:RouterDiagnosisClock)).ToString('o')
            $record.failed_categories = @($failed.ToArray()); $record.notes = @($notes.ToArray())
            New-Item -ItemType Directory -Path $readingsDir -Force | Out-Null
            [IO.File]::AppendAllText((Join-Path $readingsDir 'passes.jsonl'),((ConvertTo-Json -InputObject $record -Compress -Depth 10) + "`n"),[Text.UTF8Encoding]::new($false))
        } finally {
            if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
            [void](Update-RouterLockOwned -Path $lock -Token $entry.token -Action release)
        }
    }
}

function Invoke-RouterResearch {
    param([Parameter(Mandatory)][string[]]$Categories, [Parameter(Mandatory)][string[]]$Models, [string]$NewModel, [ValidateSet('release','confirmation','followup','refresh','manual')][string]$Trigger = 'manual', [ValidateSet('codex','claude')][string]$Lane = 'codex', [string]$Context, [datetime]$Now = (Get-Date))
    return Invoke-RouterCategoryResearch @PSBoundParameters
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-RouterResearch -Categories $RouterResearchCliCategories -Models $RouterResearchCliCandidateModels -Trigger $RouterResearchCliTrigger -Lane $RouterResearchCliLane -Context $RouterResearchCliContext
    if ($RouterResearchCliJson) { $result | ConvertTo-Json -Depth 20 -Compress } else { $result }
}
