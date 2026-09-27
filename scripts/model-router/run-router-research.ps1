param([Alias('Models')][string[]]$RouterResearchCliModels, [Alias('ModelsFile')][string]$RouterResearchCliModelsFile, [Alias('All')][switch]$RouterResearchCliAll, [Alias('Context')][string]$RouterResearchCliContext, [Alias('DetachedChild')][switch]$RouterResearchCliDetachedChild, [Alias('LockToken')][string]$RouterResearchCliLockToken, [Alias('Json')][switch]$RouterResearchCliJson)
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
        $fixed = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../references/model-router/research-prompt.md') -Raw
        foreach ($id in $ids) {
            if ([string]$id -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') { $alerts.Add('invalid-research-model-id'); continue }
            $lane = if ($id -like 'claude-*') { 'claude' } else { 'codex' }
            $prompt = $fixed + "`nModel: $id`nLane: $lane"
            if ($Context) { $prompt += "`n" + (New-PromptEnvelope -Label 'RESEARCH CONTEXT' -Content $Context) }
            [void](Update-RouterLockOwned -Path $lock -Token $token -Action heartbeat)
            try {
                $raw = Invoke-RouterResearchCall -Model $id -Prompt $prompt
                if (-not $raw) { throw 'empty research response' }
                $profile = [string]$raw | ConvertFrom-Json -Depth 40
                if (-not (Test-RouterProfile $profile) -or $profile.model -cne $id -or $profile.lane -cne $lane) { throw 'invalid research profile' }
                $profile.researched_at = $Now.ToString('yyyy-MM-dd')
                $profilesDir = Join-Path $state 'profiles'
                New-Item -ItemType Directory -Path $profilesDir -Force | Out-Null
                $path = Join-Path $profilesDir ($id + '.json')
                $json = ConvertTo-Json -InputObject $profile -Depth 40
                $temp = Join-Path $profilesDir ('.' + $id + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
                try { [IO.File]::WriteAllText($temp,$json,[Text.UTF8Encoding]::new($false)); [IO.File]::Move($temp,$path,$true) }
                finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
                $done.Add($id)
            } catch { $alerts.Add("research-profile-invalid:$id") }
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
    $models = $RouterResearchCliModels
    if ($RouterResearchCliModelsFile) { $models = @(Read-RouterResearchModelsFile -Path $RouterResearchCliModelsFile) }
    $result = Invoke-RouterResearch -Models $models -All:$RouterResearchCliAll -Context $RouterResearchCliContext -DetachedChild:$RouterResearchCliDetachedChild -LockToken $RouterResearchCliLockToken
    if ($RouterResearchCliJson) { $result | ConvertTo-Json -Depth 20 -Compress } else { $result }
}
