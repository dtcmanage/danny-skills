param([Alias('Models')][string[]]$RouterResearchCliModels, [Alias('All')][switch]$RouterResearchCliAll, [Alias('Context')][string]$RouterResearchCliContext, [Alias('DetachedChild')][switch]$RouterResearchCliDetachedChild, [Alias('Json')][switch]$RouterResearchCliJson)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')
. (Join-Path $PSScriptRoot 'build-router-table.ps1')
. (Join-Path $PSScriptRoot '../invoke-codex-process.ps1')
. (Join-Path $PSScriptRoot '../wrap-prompt-envelope.ps1')
. (Join-Path $PSScriptRoot 'send-router-alert.ps1')

function Get-RouterLockOwner {
    param([datetime]$Now = (Get-Date))
    return [pscustomobject]@{ pid = $PID; process_start = (Get-Process -Id $PID).StartTime.ToString('o'); created_at = $Now.ToString('o') }
}

function Test-RouterLockStale {
    param([string]$Path, [datetime]$Now = (Get-Date))
    try {
        $owner = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if (-not $owner.PSObject.Properties['pid'] -or -not $owner.PSObject.Properties['process_start'] -or -not $owner.PSObject.Properties['created_at']) { return $true }
        if (($Now - [datetime]$owner.created_at).TotalHours -ge 2) { return $true }
        $process = Get-Process -Id ([int]$owner.pid) -ErrorAction SilentlyContinue
        return ($null -eq $process -or $process.StartTime.ToUniversalTime().Ticks -ne ([datetime]$owner.process_start).ToUniversalTime().Ticks)
    } catch { return $true }
}

function Enter-RouterResearchLock {
    param([string]$Path, [datetime]$Now = (Get-Date))
    $alerts = [System.Collections.Generic.List[string]]::new()
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        try {
            $stream = [IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try {
                $bytes = [Text.UTF8Encoding]::new($false).GetBytes((Get-RouterLockOwner -Now $Now | ConvertTo-Json -Compress))
                $stream.Write($bytes,0,$bytes.Length)
            } finally { $stream.Dispose() }
            return [pscustomobject]@{ acquired = $true; alerts = @($alerts.ToArray()) }
        } catch [IO.IOException] {
            if (-not (Test-Path -LiteralPath $Path)) { continue }
            if (-not (Test-RouterLockStale -Path $Path -Now $Now)) { return [pscustomobject]@{ acquired = $false; alerts = @($alerts.ToArray()) } }
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
            $alerts.Add('research-stale-lock-cleared')
        }
    }
    return [pscustomobject]@{ acquired = $false; alerts = @($alerts.ToArray()) }
}

function Invoke-RouterResearchCall {
    param([string]$Model, [string]$Prompt)
    if ((Get-Variable RouterResearchInvoker -Scope Script -ErrorAction SilentlyContinue) -and $script:RouterResearchInvoker) { return (& $script:RouterResearchInvoker $Model $Prompt) }
    if (-not (Get-Command Resolve-RouterModel -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'resolve-model.ps1') }
    $pick = Resolve-RouterModel -Category deep-research -Lane codex -SkipModelCheck
    $codex = (Get-Command codex -ErrorAction Stop).Source
    $out = Join-Path $env:TEMP ('router-research-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $result = Invoke-CodexProcess -CodexPath $codex -Arguments @('--ask-for-approval','never','exec','--ignore-user-config','-c','web_search="live"','--sandbox','read-only','--cd',$PSScriptRoot,'--model',$pick.model,'--output-last-message',$out,'-') -Prompt $Prompt -WorkingDirectory $PSScriptRoot -TimeoutMs 3600000
        if ($result.timed_out -or $result.exit_code -ne 0 -or -not (Test-Path -LiteralPath $out)) { throw 'Research process failed or timed out.' }
        return (Get-Content -LiteralPath $out -Raw)
    } finally { if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force } }
}

function Invoke-RouterResearch {
    param([string[]]$Models, [switch]$All, [string]$Context, [switch]$DetachedChild, [datetime]$Now = (Get-Date))
    $state = Get-RouterStateDir
    New-Item -ItemType Directory -Path $state -Force | Out-Null
    $lock = Join-Path $state 'research.lock'
    $owned = $false
    $lockAlerts = @()
    if (-not $DetachedChild) {
        $entry = Enter-RouterResearchLock -Path $lock -Now $Now
        $lockAlerts = @($entry.alerts)
        if (-not $entry.acquired) { return [pscustomobject]@{ researched = @(); alerts = @($lockAlerts + 'research-already-running'); table_written = $false } }
        $owned = $true
    } else { Get-RouterLockOwner -Now $Now | ConvertTo-Json -Compress | Set-Content -LiteralPath $lock }
    try {
        $queuePath = Join-Path $state 'pending-research.json'
        $queue = @(if (Test-Path -LiteralPath $queuePath) { Get-Content -LiteralPath $queuePath -Raw | ConvertFrom-Json })
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
        }
        if (Test-Path -LiteralPath $queuePath) {
            $latest = @(Get-Content -LiteralPath $queuePath -Raw | ConvertFrom-Json)
            $remaining = @($latest | Where-Object { $done -notcontains [string]$_.id })
            $json = ConvertTo-Json -InputObject $remaining -Depth 10
            $temp = Join-Path $state ('.pending-research.' + [guid]::NewGuid().ToString('N') + '.tmp')
            try { [IO.File]::WriteAllText($temp,$json,[Text.UTF8Encoding]::new($false)); [IO.File]::Move($temp,$queuePath,$true) }
            finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
        }
        $build = Build-RouterTable -ProfilesDir (Join-Path $state 'profiles') -OutPath (Join-Path $state 'router-table.json') -Now $Now
        foreach ($alert in $build.alerts) { $alerts.Add([string]$alert) }
        if ($alerts.Count -and -not (Get-Variable RouterResearchSuppressAlerts -Scope Script -ErrorAction SilentlyContinue)) { Send-RouterAlerts -Alerts @($alerts.ToArray()) | Out-Null }
        return [pscustomobject]@{ researched = @($done.ToArray()); alerts = @($alerts.ToArray()); table_written = [bool]$build.written }
    } finally { if ($owned -or $DetachedChild) { Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue } }
}

function Start-RouterResearchDetached {
    param([string[]]$Models, [datetime]$Now = (Get-Date))
    $state = Get-RouterStateDir
    New-Item -ItemType Directory -Path $state -Force | Out-Null
    $lock = Join-Path $state 'research.lock'
    $entry = Enter-RouterResearchLock -Path $lock -Now $Now
    if (-not $entry.acquired) { return [pscustomobject]@{ launched = $false; alerts = @($entry.alerts) } }
    try {
        $shim = 'D:\Claude\_system-tools\run-hidden\run-hidden.vbs'
        $pwsh = (Get-Command pwsh -ErrorAction Stop).Source
        $wscript = (Get-Command wscript.exe -ErrorAction Stop).Source
        $launchArguments = @($shim,$pwsh,(Join-Path $PSScriptRoot 'run-router-research.ps1'),'-DetachedChild')
        if ($Models -and $Models.Count) { $launchArguments += '-Models'; $launchArguments += @($Models) }
        if ((Get-Variable RouterResearchLauncher -Scope Script -ErrorAction SilentlyContinue) -and $script:RouterResearchLauncher) { & $script:RouterResearchLauncher $wscript $launchArguments | Out-Null }
        else { Start-Process -FilePath $wscript -ArgumentList @($launchArguments | ForEach-Object { '"' + ([string]$_).Replace('"','""') + '"' }) -WindowStyle Hidden | Out-Null }
        return [pscustomobject]@{ launched = $true; alerts = @($entry.alerts) }
    } catch { Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue; throw }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-RouterResearch -Models $RouterResearchCliModels -All:$RouterResearchCliAll -Context $RouterResearchCliContext -DetachedChild:$RouterResearchCliDetachedChild
    if ($RouterResearchCliJson) { $result | ConvertTo-Json -Depth 20 -Compress } else { $result }
}
