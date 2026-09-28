param([Alias('Models')][string[]]$RouterResearchCliModels, [Alias('ModelsFile')][string]$RouterResearchCliModelsFile, [Alias('All')][switch]$RouterResearchCliAll, [Alias('Context')][string]$RouterResearchCliContext, [Alias('DetachedChild')][switch]$RouterResearchCliDetachedChild, [Alias('LockToken')][string]$RouterResearchCliLockToken, [Alias('Json')][switch]$RouterResearchCliJson, [Alias('Categories')][string[]]$RouterResearchCliCategories, [Alias('CandidateModels')][string[]]$RouterResearchCliCandidateModels, [Alias('Trigger')][ValidateSet('release','confirmation','refresh','manual')][string]$RouterResearchCliTrigger = 'manual', [Alias('Lane')][ValidateSet('codex','claude')][string]$RouterResearchCliLane = 'codex')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')
. (Join-Path $PSScriptRoot 'build-router-table.ps1')
. (Join-Path $PSScriptRoot '../invoke-codex-process.ps1')
. (Join-Path $PSScriptRoot '../wrap-prompt-envelope.ps1')
. (Join-Path $PSScriptRoot 'send-router-alert.ps1')

# Lock protocol: the lock file carries a random owner token plus the owner's PID and process start time. The owner
# refreshes updated_at before and after every research call. A lock is stale when its owner process is gone (or the PID
# now belongs to a different process start) or when its heartbeat is older than 10 minutes plus the longest single
# research call. Only the holder of the token deletes the lock.
$script:RouterResearchCallTimeoutMs = 3600000
$script:RouterLockStaleMinutes = 10 + ($script:RouterResearchCallTimeoutMs / 60000)
if (-not (Get-Variable RouterResearchHandoffSeconds -Scope Script -ErrorAction SilentlyContinue)) { $script:RouterResearchHandoffSeconds = 30 }

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

function Read-RouterResearchModelsFile {
    param([Parameter(Mandatory)][string]$Path)
    try { return @([IO.File]::ReadAllText($Path) | ConvertFrom-Json | ForEach-Object { [string]$_ }) }
    finally { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
}

function Invoke-RouterResearchCall {
    param([string]$Model, [string]$Prompt)
    if ((Get-Variable RouterResearchInvoker -Scope Script -ErrorAction SilentlyContinue) -and $script:RouterResearchInvoker) { return (& $script:RouterResearchInvoker $Model $Prompt) }
    if (-not (Get-Command Resolve-RouterModel -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'resolve-model.ps1') }
    $pick = Resolve-RouterModel -Category deep-research -Lane codex -SkipModelCheck
    $codex = (Get-Command codex -ErrorAction Stop).Source
    $out = Join-Path $env:TEMP ('router-research-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $result = Invoke-CodexProcess -CodexPath $codex -Arguments @('--ask-for-approval','never','exec','--ignore-user-config','-c','web_search="live"','--sandbox','read-only','--cd',$PSScriptRoot,'--model',$pick.model,'--output-last-message',$out,'-') -Prompt $Prompt -WorkingDirectory $PSScriptRoot -TimeoutMs $script:RouterResearchCallTimeoutMs
        if ($result.timed_out -or $result.exit_code -ne 0 -or -not (Test-Path -LiteralPath $out)) { throw 'Research process failed or timed out.' }
        return (Get-Content -LiteralPath $out -Raw)
    } finally { if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force } }
}

function Get-RouterCategoryCallArguments {
    # Research always runs on an explicit router pick; an unpinned call would fall back to a CLI default that may be a frontier model.
    param([string]$Lane, [string]$OutPath)
    if (-not (Get-Command Resolve-RouterModel -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'resolve-model.ps1') }
    $pick = Resolve-RouterModel -Category deep-research -Lane $Lane -SkipModelCheck
    if (-not $pick.model -or ($pick.PSObject.Properties['status'] -and $pick.status -eq 'wait')) { throw "Category research has no available $Lane model: $($pick.reason)" }
    if ($Lane -eq 'codex') { return @('--ask-for-approval','never','exec','--ignore-user-config','-c','web_search="live"','--sandbox','read-only','--cd',$PSScriptRoot,'--model',$pick.model,'--output-last-message',$OutPath,'-') }
    return @('-p','--model',$pick.model,'--allowedTools','WebSearch,WebFetch','--output-format','json')
}

function Invoke-RouterCategoryCall {
    param([string]$Category, [string]$Lane, [string]$Prompt)
    if ((Get-Variable RouterResearchInvoker -Scope Script -ErrorAction SilentlyContinue) -and $script:RouterResearchInvoker) { return (& $script:RouterResearchInvoker $Category $Lane $Prompt) }
    if ($Lane -eq 'codex') {
        $codex = (Get-Command codex -ErrorAction Stop).Source
        $out = Join-Path $env:TEMP ('router-category-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            $result = Invoke-CodexProcess -CodexPath $codex -Arguments (Get-RouterCategoryCallArguments -Lane codex -OutPath $out) -Prompt $Prompt -WorkingDirectory $PSScriptRoot -TimeoutMs $script:RouterResearchCallTimeoutMs
            if ($result.timed_out -or $result.exit_code -ne 0 -or -not (Test-Path -LiteralPath $out)) { throw 'Category research process failed or timed out.' }
            return [IO.File]::ReadAllText($out)
        } finally { Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue }
    }
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Command claude -ErrorAction Stop).Source
    foreach ($arg in @(Get-RouterCategoryCallArguments -Lane claude -OutPath '')) { [void]$psi.ArgumentList.Add($arg) }
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($psi)
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($Prompt); $process.StandardInput.Close()
        if (-not $process.WaitForExit($script:RouterResearchCallTimeoutMs)) { $process.Kill($true); throw 'Category research timed out.' }
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
    if ($null -eq $stored) { return @($RosterModels | Where-Object { $_ -cne $NewModel }) }
    foreach ($model in $RosterModels) {
        if ($model -ceq $NewModel) { continue }
        $shared = @($stored.readings | Where-Object { ("$($_.benchmark)`n$($_.version)`n$($_.harness)" -cin $newKeys) -and @($_.results | Where-Object model -CEQ $model).Count -gt 0 })
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
    param([Parameter(Mandatory)][string[]]$Categories, [Parameter(Mandatory)][string[]]$Models, [ValidateSet('release','confirmation','refresh','manual')][string]$Trigger = 'manual', [ValidateSet('codex','claude')][string]$Lane = 'codex', [string]$Context, [datetime]$Now = (Get-Date))
    $state = Get-RouterStateDir
    $lock = Join-Path $state 'research.lock'
    $entry = Enter-RouterResearchLock -Path $lock -Now $Now
    if (-not $entry.acquired) { throw 'ROUTER_LOCK_BUSY' }
    $readingsDir = Join-Path $state 'readings'
    $passId = [guid]::NewGuid().ToString('N')
    $stage = Join-Path $readingsDir ('.pass-' + $passId)
    try {
        New-Item -ItemType Directory -Path $readingsDir -Force | Out-Null
        Get-ChildItem -LiteralPath $readingsDir -Directory -Filter '.pass-*' | Remove-Item -Recurse -Force
        New-Item -ItemType Directory -Path $stage | Out-Null
        $sources = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/benchmark-sources.json') -Raw | ConvertFrom-Json -Depth 20
        $fixed = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/research-category-prompt.md') -Raw) + "`n`n" + (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/readings-schema.md') -Raw)
        $failed = [Collections.Generic.List[string]]::new()
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
                $raw = Invoke-RouterCategoryCall -Category $category -Lane $Lane -Prompt $prompt
                try {
                    $body = ([string]$raw).Trim()
                    if ($body -match '^```(?:json)?\s*([\s\S]*?)\s*```$') { $body = $Matches[1] }
                    $parsed = $body | ConvertFrom-Json -Depth 40
                    if (-not (Test-RouterReadings -Readings $parsed -Category $category -Models $request.models)) { throw 'Invalid category readings' }
                } catch {
                    $failDir = Join-Path $state 'research-failures'; New-Item -ItemType Directory -Path $failDir -Force | Out-Null
                    $detail = "error: $($_.Exception.Message)`n" + [string]$raw
                    if ($detail.Length -gt 20000) { $detail = $detail.Substring(0,20000) }
                    [IO.File]::WriteAllText((Join-Path $failDir ($category + '@' + (Get-Date).ToString('yyyyMMddTHHmmssfff') + '.txt')),$detail,[Text.UTF8Encoding]::new($false))
                    $failed.Add($category); break
                }
                foreach ($source in $parsed.sources_checked) { $checked.Add([pscustomobject]@{ name=$source.name; comparable_results_found=$source.comparable_results_found; note=$source.note }) }
                foreach ($reading in $parsed.readings) {
                    $combined.Add([pscustomobject]@{ benchmark=$reading.benchmark; version=$reading.version; date=$reading.date; harness=$reading.harness; effort_class=$reading.effort_class; independent=$reading.independent; url=$reading.url; results=@($reading.results | ForEach-Object { [pscustomobject]@{ model=$_.model; score=$_.score; tasks=$_.tasks; margin=$_.margin } }) })
                }
                if ($Trigger -eq 'release' -and $i -eq 0 -and $Models.Count -eq 1) {
                    $temporary = [pscustomobject]@{ category=$category; readings=@($combined.ToArray()) }
                    $rosterModels = @((Read-RouterRoster).roster.jobs.PSObject.Properties | ForEach-Object { @($_.Value.first,$_.Value.backup) } | Where-Object { $_ -and $_ -cne $Models[0] } | Sort-Object -Unique)
                    $keys = @($combined | ForEach-Object { "$($_.benchmark)`n$($_.version)`n$($_.harness)" })
                    $missing = @(Get-RouterNonComparableModels -Category $category -NewModel $Models[0] -RosterModels $rosterModels -NewReadings $temporary)
                    if ($missing.Count -and $keys.Count) { $pending += @{ models=$missing; benchmarks=@($combined | ForEach-Object benchmark | Sort-Object -Unique) } }
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
                        if ($existing.benchmark -ceq $reading.benchmark -and $existing.version -ceq $reading.version -and $existing.harness -ceq $reading.harness -and $existing.effort_class -ceq $reading.effort_class) {
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
            [IO.File]::WriteAllText($target,(ConvertTo-Json -InputObject $saved -Depth 40),[Text.UTF8Encoding]::new($false))
        }
        $record = [pscustomobject]@{ pass_id=$passId; trigger=$Trigger; categories=@($Categories); models=@($Models); started_at=$Now.ToString('o'); completed_at=(Get-Date).ToString('o'); failed_categories=@($failed.ToArray()) }
        [IO.File]::AppendAllText((Join-Path $readingsDir 'passes.jsonl'),((ConvertTo-Json -InputObject $record -Compress -Depth 10) + "`n"),[Text.UTF8Encoding]::new($false))
        return $record
    } finally { if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }; [void](Update-RouterLockOwned -Path $lock -Token $entry.token -Action release) }
}

function Invoke-RouterResearch {
    param([string[]]$Models, [switch]$All, [string]$Context, [switch]$DetachedChild, [string]$LockToken, [datetime]$Now = (Get-Date))
    $state = Get-RouterStateDir
    New-Item -ItemType Directory -Path $state -Force | Out-Null
    $lock = Join-Path $state 'research.lock'
    $lockAlerts = @()
    if ($DetachedChild) {
        $token = $LockToken
        if (-not $token -or -not (Update-RouterLockOwned -Path $lock -Token $token -Action take)) { return [pscustomobject]@{ researched = @(); alerts = @('research-already-running'); table_written = $false } }
    } else {
        $entry = Enter-RouterResearchLock -Path $lock -Now $Now
        $lockAlerts = @($entry.alerts)
        if (-not $entry.acquired) { return [pscustomobject]@{ researched = @(); alerts = @($lockAlerts + 'research-already-running'); table_written = $false } }
        $token = $entry.token
    }
    try {
        $queuePath = Join-Path $state 'pending-research.json'
        $queue = @(Read-RouterJsonArray -Path $queuePath)
        $table = (Read-RouterTable).table
        $ids = if ($All) {
            @($table.categories.PSObject.Properties | ForEach-Object { $_.Value.PSObject.Properties | ForEach-Object { $_.Value.candidates | ForEach-Object model } } | Sort-Object -Unique)
        } elseif ($Models -and $Models.Count) { @($Models | Sort-Object -Unique) } else { @($queue | ForEach-Object id | Sort-Object -Unique) }
        $alerts = [System.Collections.Generic.List[string]]::new()
        foreach ($alert in $lockAlerts) { $alerts.Add($alert) }
        $done = [System.Collections.Generic.List[string]]::new()
        # The research session cannot read local files (Windows Codex runs without a sandbox that permits reads), so
        # the profile schema travels inside the prompt instead of being referenced by path.
        $fixed = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/research-prompt.md') -Raw) + "`n`n" + (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/profile-schema.md') -Raw)
        foreach ($id in $ids) {
            if ([string]$id -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') { $alerts.Add('invalid-research-model-id'); continue }
            $lane = if ($id -like 'claude-*') { 'claude' } else { 'codex' }
            $prompt = $fixed + "`nModel: $id`nLane: $lane"
            if ($Context) { $prompt += "`n" + (New-PromptEnvelope -Label 'RESEARCH CONTEXT' -Content $Context) }
            [void](Update-RouterLockOwned -Path $lock -Token $token -Action heartbeat)
            try {
                $raw = $null
                $raw = Invoke-RouterResearchCall -Model $id -Prompt $prompt
                if (-not $raw) { throw 'empty research response' }
                $text = ([string]$raw).Trim()
                if ($text -match '^```(?:json)?\s*([\s\S]*?)\s*```$') { $text = $Matches[1] }
                $profile = $text | ConvertFrom-Json -Depth 40
                if (-not (Test-RouterProfile $profile) -or $profile.model -cne $id -or $profile.lane -cne $lane) { throw 'invalid research profile' }
                $profile.researched_at = $Now.ToString('o')
                $profilesDir = Join-Path $state 'profiles'
                New-Item -ItemType Directory -Path $profilesDir -Force | Out-Null
                $path = Join-Path $profilesDir ($id + '.json')
                $json = ConvertTo-Json -InputObject $profile -Depth 40
                $historyDir = Join-Path $profilesDir 'history'
                New-Item -ItemType Directory -Path $historyDir -Force | Out-Null
                $historyTime = $Now
                do {
                    $historyPath = Join-Path $historyDir ($id + '@' + $historyTime.ToString('yyyy-MM-ddTHHmmss') + '.json')
                    if (-not (Test-Path -LiteralPath $historyPath)) { break }
                    $historyTime = $historyTime.AddSeconds(1)
                } while ($true)
                $historyStream = [IO.File]::Open($historyPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try {
                    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
                    $historyStream.Write($bytes,0,$bytes.Length)
                } finally { $historyStream.Dispose() }
                $temp = Join-Path $profilesDir ('.' + $id + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
                try { [IO.File]::WriteAllText($temp,$json,[Text.UTF8Encoding]::new($false)); [IO.File]::Move($temp,$path,$true) }
                finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
                $done.Add($id)
            } catch {
                $alerts.Add("research-profile-invalid:$id")
                # Keep the rejected answer so a failed run can be diagnosed without re-spending a research call.
                try {
                    $failDir = Join-Path $state 'research-failures'
                    New-Item -ItemType Directory -Path $failDir -Force | Out-Null
                    $detail = "error: $($_.Exception.Message)`n" + [string]$raw
                    if ($detail.Length -gt 20000) { $detail = $detail.Substring(0, 20000) }
                    [IO.File]::WriteAllText((Join-Path $failDir ($id + '.txt')), $detail, [Text.UTF8Encoding]::new($false))
                } catch { }
            }
            [void](Update-RouterLockOwned -Path $lock -Token $token -Action heartbeat)
        }
        Use-RouterQueueMutex -StateDir $state -Action {
            if (Test-Path -LiteralPath $queuePath) {
                $remaining = @(Read-RouterJsonArray -Path $queuePath | Where-Object { $done -notcontains [string]$_.id })
                $json = ConvertTo-Json -InputObject $remaining -Depth 10
                $temp = Join-Path $state ('.pending-research.' + [guid]::NewGuid().ToString('N') + '.tmp')
                try { [IO.File]::WriteAllText($temp,$json,[Text.UTF8Encoding]::new($false)); [IO.File]::Move($temp,$queuePath,$true) }
                finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
            }
        }
        $profilesDir = Join-Path $state 'profiles'
        $profileIds = if (Test-Path -LiteralPath $profilesDir) { @(Get-ChildItem -LiteralPath $profilesDir -File -Filter '*.json' | ForEach-Object BaseName) } else { @() }
        $fullCoverage = [bool]$All -and $ids.Count -gt 0 -and $done.Count -eq $ids.Count -and @($profileIds | Where-Object { $done -notcontains $_ }).Count -eq 0
        $build = Build-RouterTable -ProfilesDir $profilesDir -OutPath (Join-Path $state 'router-table.json') -Now $Now -FullCoverage:$fullCoverage
        foreach ($alert in $build.alerts) { $alerts.Add([string]$alert) }
        if ($alerts.Count -and -not (Get-Variable RouterResearchSuppressAlerts -Scope Script -ErrorAction SilentlyContinue)) { Send-RouterAlerts -Alerts @($alerts.ToArray()) | Out-Null }
        return [pscustomobject]@{ researched = @($done.ToArray()); alerts = @($alerts.ToArray()); table_written = [bool]$build.written }
    } finally { [void](Update-RouterLockOwned -Path $lock -Token $token -Action release) }
}

function Start-RouterResearchDetached {
    param([string[]]$Models, [datetime]$Now = (Get-Date))
    $state = Get-RouterStateDir
    New-Item -ItemType Directory -Path $state -Force | Out-Null
    $lock = Join-Path $state 'research.lock'
    $entry = Enter-RouterResearchLock -Path $lock -Now $Now -Phase 'launching'
    if (-not $entry.acquired) { return [pscustomobject]@{ launched = $false; alerts = @($entry.alerts) } }
    $modelsFile = $null
    try {
        $shim = 'D:\Claude\_system-tools\run-hidden\run-hidden.vbs'
        $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
        $wscript = (Get-Command wscript.exe -ErrorAction Stop).Source
        $launchArguments = @($shim,$pwsh,(Join-Path $PSScriptRoot 'run-router-research.ps1'),'-DetachedChild','-LockToken',$entry.token)
        if ($Models -and $Models.Count) {
            $modelsFile = Join-Path $env:TEMP ('router-research-models-' + [guid]::NewGuid().ToString('N') + '.json')
            [IO.File]::WriteAllText($modelsFile,(ConvertTo-Json -InputObject @($Models | ForEach-Object { [string]$_ }) -Compress),[Text.UTF8Encoding]::new($false))
            $launchArguments += @('-ModelsFile',$modelsFile)
        }
        if ((Get-Variable RouterResearchLauncher -Scope Script -ErrorAction SilentlyContinue) -and $script:RouterResearchLauncher) { & $script:RouterResearchLauncher $wscript $launchArguments | Out-Null }
        else { Start-Process -FilePath $wscript -ArgumentList @($launchArguments | ForEach-Object { '"' + ([string]$_).Replace('"','""') + '"' }) -WindowStyle Hidden | Out-Null }
        # Wait for the child to take ownership; the parent's live PID and fresh lock keep it unstealable meanwhile.
        $deadline = [datetime]::UtcNow.AddSeconds($script:RouterResearchHandoffSeconds)
        while ($true) {
            $stream = Open-RouterLockExclusive -Path $lock
            $owner = if ($null -ne $stream) { try { Read-RouterLockStream -Stream $stream } finally { $stream.Dispose() } } else { $null }
            if ($null -eq $owner -or -not $owner.PSObject.Properties['token'] -or [string]$owner.token -cne $entry.token -or [string]$owner.phase -cne 'launching') { break }
            if ([datetime]::UtcNow -ge $deadline) {
                [void](Update-RouterLockOwned -Path $lock -Token $entry.token -Action release)
                if ($modelsFile) { Remove-Item -LiteralPath $modelsFile -Force -ErrorAction SilentlyContinue }
                return [pscustomobject]@{ launched = $false; alerts = @($entry.alerts + 'research-launch-timeout') }
            }
            Start-Sleep -Milliseconds 100
        }
        return [pscustomobject]@{ launched = $true; alerts = @($entry.alerts) }
    } catch {
        [void](Update-RouterLockOwned -Path $lock -Token $entry.token -Action release)
        if ($modelsFile) { Remove-Item -LiteralPath $modelsFile -Force -ErrorAction SilentlyContinue }
        throw
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($RouterResearchCliCategories -and $RouterResearchCliCategories.Count) {
        $result = Invoke-RouterCategoryResearch -Categories $RouterResearchCliCategories -Models $RouterResearchCliCandidateModels -Trigger $RouterResearchCliTrigger -Lane $RouterResearchCliLane -Context $RouterResearchCliContext
        if ($RouterResearchCliJson) { $result | ConvertTo-Json -Depth 20 -Compress } else { $result }
        return
    }
    $models = $RouterResearchCliModels
    if ($RouterResearchCliModelsFile) { $models = @(Read-RouterResearchModelsFile -Path $RouterResearchCliModelsFile) }
    $result = Invoke-RouterResearch -Models $models -All:$RouterResearchCliAll -Context $RouterResearchCliContext -DetachedChild:$RouterResearchCliDetachedChild -LockToken $RouterResearchCliLockToken
    if ($RouterResearchCliJson) { $result | ConvertTo-Json -Depth 20 -Compress } else { $result }
}
