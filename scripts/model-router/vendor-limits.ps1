param(
    [Alias('Vendor')][ValidateSet('codex','claude')][string]$RouterLimitsCliVendor,
    [Alias('Json')][switch]$RouterLimitsCliJson,
    [Alias('RecordBlock')][switch]$RouterLimitsCliRecordBlock,
    [Alias('ResetAtUtc')][datetimeoffset]$RouterLimitsCliResetAtUtc,
    [Alias('Reason')][string]$RouterLimitsCliReason
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')
. (Join-Path $PSScriptRoot 'router-credentials.ps1')
if (-not (Get-Variable RouterClaudeCredentialProvider -Scope Script -ErrorAction SilentlyContinue)) {
    $script:RouterClaudeCredentialProvider = { Get-RouterClaudeCredential }
}

# Injectable diagnosis I/O; each call is bounded and tests replace all three seams.
if (-not (Get-Variable RouterDiagnosisHttp -Scope Script -ErrorAction SilentlyContinue)) {
    $script:RouterDiagnosisHttp = { param([string]$Uri) Invoke-RestMethod -Uri $Uri -TimeoutSec 5 }
}
if (-not (Get-Variable RouterDiagnosisDns -Scope Script -ErrorAction SilentlyContinue)) {
    $script:RouterDiagnosisDns = { param([string]$ApiHost) Test-RouterDns -ApiHost $ApiHost }
}
if (-not (Get-Variable RouterDiagnosisClock -Scope Script -ErrorAction SilentlyContinue)) {
    $script:RouterDiagnosisClock = { [datetimeoffset]::UtcNow }
}

if (-not (Get-Variable -Name RouterClaudeUsageFetcher -Scope Script -ErrorAction SilentlyContinue)) {
    $script:RouterClaudeUsageFetcher = {
        param([string]$Token)
        Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Method Get -TimeoutSec 5 -Headers @{
            Authorization="Bearer $Token"; 'anthropic-beta'='oauth-2025-04-20'
        }
    }
}

function Get-RouterClaudeUsage {
    $cached = $null
    try {
        $path = Join-Path (Get-RouterStateDir) 'claude-usage.json'
        $identity = Get-RouterClaudeCredentialIdentity
        $cached = Read-RouterJsonObject -Path $path
        $now = [datetimeoffset]::UtcNow
        if ($null -ne $cached) {
            try {
                if (-not $cached.PSObject.Properties['credential_locator_identity'] -or $cached.credential_locator_identity -cne $identity) {
                    throw 'CLAUDE_CACHE_SOURCE_CHANGED'
                }
                $cached = [pscustomobject]@{
                    used_percent=[double]$cached.used_percent
                    resets_at_utc=([datetimeoffset]$cached.resets_at_utc).ToUniversalTime().ToString('o')
                    observed_at_utc=([datetimeoffset]$cached.observed_at_utc).ToUniversalTime().ToString('o')
                    session_percent=$(if ($cached.PSObject.Properties['session_percent'] -and $null -ne $cached.session_percent) { [double]$cached.session_percent } else { $null })
                    session_resets_at_utc=$(if ($cached.PSObject.Properties['session_resets_at_utc'] -and $null -ne $cached.session_resets_at_utc) { ([datetimeoffset]$cached.session_resets_at_utc).ToUniversalTime().ToString('o') } else { $null })
                    source='oauth-usage'
                    credential_locator_identity=$identity
                }
                if (-not [double]::IsFinite($cached.used_percent)) { throw 'CLAUDE_CACHE_PERCENT' }
                if ([datetimeoffset]$cached.resets_at_utc -le $now) { $cached.used_percent = 0.0 }
                if (($now - [datetimeoffset]$cached.observed_at_utc).TotalMinutes -lt 5) { return $cached }
            } catch { $cached = $null }
        }
        $credential = & $script:RouterClaudeCredentialProvider
        if ($credential.status -ne 'available') {
            # Token expiry cannot undo an observed quota ceiling before its reset.
            # Keep the original observation age; this is not a successful refresh.
            if ($credential.status -eq 'expired' -and $null -ne $cached -and
                $cached.used_percent -ge 95 -and [datetimeoffset]$cached.resets_at_utc -gt $now) {
                return $cached
            }
            return $null
        }
        $response = & $script:RouterClaudeUsageFetcher ([string]$credential.token)
        if ($null -eq $response -or -not $response.PSObject.Properties['seven_day'] -or $null -eq $response.seven_day -or
            -not $response.seven_day.PSObject.Properties['utilization'] -or $null -eq $response.seven_day.utilization -or
            -not $response.seven_day.PSObject.Properties['resets_at']) { throw 'CLAUDE_USAGE_SHAPE' }
        $used = [double]$response.seven_day.utilization
        if (-not [double]::IsFinite($used)) { throw 'CLAUDE_USAGE_PERCENT' }
        $reset = ([datetimeoffset]$response.seven_day.resets_at).ToUniversalTime()
        $session = $null; $sessionReset = $null
        if ($response.PSObject.Properties['five_hour'] -and $null -ne $response.five_hour) {
            if ($response.five_hour.PSObject.Properties['utilization'] -and $null -ne $response.five_hour.utilization) {
                $session = [double]$response.five_hour.utilization
                if (-not [double]::IsFinite($session)) { throw 'CLAUDE_SESSION_PERCENT' }
            }
            if ($response.five_hour.PSObject.Properties['resets_at'] -and $null -ne $response.five_hour.resets_at) {
                $sessionReset = ([datetimeoffset]$response.five_hour.resets_at).ToUniversalTime().ToString('o')
            }
        }
        $reading = [pscustomobject]@{ used_percent=$used; resets_at_utc=$reset.ToString('o'); observed_at_utc=[datetimeoffset]::UtcNow.ToString('o'); session_percent=$session; session_resets_at_utc=$sessionReset; source='oauth-usage'; credential_locator_identity=$identity }
        Write-RouterJsonAtomic -Path $path -Value $reading
        if ($reset -le [datetimeoffset]::UtcNow) { $reading.used_percent = 0.0 }
        return $reading
    } catch {
        try {
            if ($null -ne $cached -and [datetimeoffset]$cached.resets_at_utc -le [datetimeoffset]::UtcNow) { $cached.used_percent = 0.0 }
            return $cached
        } catch { return $null }
    }
}

function Get-RouterCodexUsage {
    param([string]$SessionsRoot)
    if (-not $SessionsRoot) {
        $SessionsRoot = if ($env:DT_MODEL_ROUTER_CODEX_SESSIONS) { $env:DT_MODEL_ROUTER_CODEX_SESSIONS }
            elseif ($env:CODEX_HOME) { Join-Path $env:CODEX_HOME 'sessions' }
            else { Join-Path (Join-Path $HOME '.codex') 'sessions' }
    }
    if (-not (Test-Path -LiteralPath $SessionsRoot -PathType Container)) { return $null }
    $files = [System.Collections.Generic.List[IO.FileInfo]]::new()
    foreach ($year in @(Get-ChildItem -LiteralPath $SessionsRoot -Directory | Sort-Object Name -Descending)) {
        foreach ($month in @(Get-ChildItem -LiteralPath $year.FullName -Directory | Sort-Object Name -Descending)) {
            foreach ($day in @(Get-ChildItem -LiteralPath $month.FullName -Directory | Sort-Object Name -Descending)) {
                foreach ($file in @(Get-ChildItem -LiteralPath $day.FullName -File -Filter '*.jsonl')) { $files.Add($file) }
                if ($files.Count -ge 3) { break }
            }
            if ($files.Count -ge 3) { break }
        }
        if ($files.Count -ge 3) { break }
    }
    foreach ($file in @($files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 3)) {
        $stream = $null; $reader = $null
        try {
            $stream = [IO.FileStream]::new($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
            $reader = [IO.StreamReader]::new($stream)
            $last = $null
            while ($null -ne ($line = $reader.ReadLine())) {
                try { $row = $line | ConvertFrom-Json -Depth 20 -DateKind String } catch { continue }
                if ($null -eq $row -or -not $row.PSObject.Properties['type'] -or $row.type -ne 'event_msg' -or
                    -not $row.PSObject.Properties['payload'] -or $null -eq $row.payload -or
                    -not $row.payload.PSObject.Properties['type'] -or $row.payload.type -ne 'token_count' -or
                    -not $row.PSObject.Properties['timestamp']) { continue }
                if (-not $row.payload.PSObject.Properties['rate_limits'] -or $null -eq $row.payload.rate_limits) { continue }
                $primary = $row.payload.rate_limits.PSObject.Properties['primary']
                if (-not $primary -or $null -eq $primary.Value -or -not $primary.Value.PSObject.Properties['used_percent'] -or -not $primary.Value.PSObject.Properties['resets_at']) { continue }
                try {
                    $reset = [datetimeoffset]::FromUnixTimeSeconds([long]$primary.Value.resets_at)
                    $observed = [datetimeoffset]::Parse([string]$row.timestamp).ToUniversalTime()
                    $used = [double]$primary.Value.used_percent
                } catch { continue }
                $last = [pscustomobject]@{ used_percent=$used; resets_at_utc=$reset.ToString('o'); observed_at_utc=$observed.ToString('o'); source_file=$file.FullName }
            }
            if ($null -ne $last) {
                if ([datetimeoffset]$last.resets_at_utc -le [datetimeoffset]::UtcNow) { $last.used_percent = 0.0 }
                return $last
            }
        } catch [IO.IOException], [UnauthorizedAccessException] { continue }
        finally { if ($null -ne $reader) { $reader.Dispose() } elseif ($null -ne $stream) { $stream.Dispose() } }
    }
    return $null
}

function Add-RouterVendorBlock {
    param([Parameter(Mandatory)][ValidateSet('codex','claude')][string]$Vendor, [datetimeoffset]$ResetAtUtc, [string]$Reason,
        [string]$Component, [AllowNull()][string]$IncidentId)
    $now = [datetimeoffset](& $script:RouterDiagnosisClock)
    $source = if ($PSBoundParameters.ContainsKey('ResetAtUtc')) { 'refusal-reset' } else { 'recheck' }
    if ($source -eq 'recheck') { $ResetAtUtc = $now.AddHours(1) }
    $path = Join-Path (Get-RouterStateDir) 'vendor-blocks.json'
    $entries = @(Read-RouterJsonArray -Path $path | Where-Object {
        $isIncident = $_.PSObject.Properties['reason'] -and $_.reason -eq 'vendor_incident'
        $live = $isIncident -or ($_.PSObject.Properties['reset_at_utc'] -and [datetimeoffset]$_.reset_at_utc -gt $now)
        $replace = $_.vendor -eq $Vendor -and $(if ($Reason -eq 'vendor_incident') {
            $isIncident -and $_.component -ceq $Component
        } else { -not $isIncident })
        $live -and -not $replace
    })
    $block = if ($Reason -eq 'vendor_incident') {
        if (-not $Component) { throw 'INCIDENT_COMPONENT_REQUIRED' }
        [pscustomobject]@{ vendor=$Vendor; blocked_at_utc=$now.ToString('o'); reason='vendor_incident'; component=$Component; incident_id=$IncidentId }
    } else {
        [pscustomobject]@{ vendor=$Vendor; blocked_at_utc=$now.ToString('o'); reset_at_utc=$ResetAtUtc.ToUniversalTime().ToString('o'); reason=$Reason; resume_after_source=$source }
    }
    $entries += $block
    $temp = Join-Path (Split-Path -Parent $path) ('.vendor-blocks-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, (ConvertTo-Json -InputObject @($entries) -Depth 5), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp,$path,$true)
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
    return $block
}

function Test-RouterLimitRefusal {
    param([Parameter(Mandatory)][ValidateSet('codex','claude')][string]$Vendor, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $errorText = $Text
    $resetText = $Text
    if ($Vendor -eq 'codex') {
        $lines = @([regex]::Matches($Text, '(?im)^\s*(?:ERROR:\s*|rate_limit_exceeded\b[^\r\n]*)([^\r\n]*)') | ForEach-Object Value)
        $errorText = if ($lines.Count) { $lines[-1] } else { '' }
        $resetText = $errorText
        if (-not $errorText) {
            try {
                $event = $Text.Trim() | ConvertFrom-Json -ErrorAction Stop
                if ($event.PSObject.Properties['error']) { $errorText = ConvertTo-Json -InputObject $event.error -Compress -Depth 8; $resetText = $Text }
                elseif ($event.PSObject.Properties['type'] -and $event.type -eq 'error' -and $event.PSObject.Properties['message']) { $errorText = [string]$event.message; $resetText = $Text }
            } catch { }
        }
    }
    # Vendor phrasing (Codex CLI prints "You've hit your usage limit"); identifiers such as test_rate_limit_exceeded_x do not count.
    $refused = $errorText -match '(?i)(?:usage limit (?:reached|exceeded)|you(?:[''\u2019]ve| have) (?:hit|reached) your (?:usage )?limit|\b\d+-hour limit reached|weekly limit reached|rate limit (?:reached|exceeded)|would exceed the rate limit|(?<![A-Za-z0-9_])rate_limit_(?:exceeded|error)(?![A-Za-z0-9_])|quota exceeded|too many requests|workspace is out of credits|hit your spend cap|Claude AI usage limit reached)'
    $reset = $null
    if ($refused) {
        $time = [regex]::Match($resetText, '(?im)(?:resets?_at|resets? at|try again at|available again at|Claude AI usage limit reached\|)["'']?\s*[=:]?\s*["'']?([0-9]{10}|[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(?::[0-9]{2})?(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:?[0-9]{2})?)')
        if ($time.Success) {
            $value = $time.Groups[1].Value.Trim().TrimEnd('.',',',';')
            $parsed = [datetimeoffset]::MinValue
            if ([datetimeoffset]::TryParse($value, [ref]$parsed)) { $reset = $parsed.ToUniversalTime().ToString('o') }
            elseif ($value -match '^\d{10}$') { $reset = [datetimeoffset]::FromUnixTimeSeconds([long]$value).ToString('o') }
        }
        if (-not $reset) {
            # Codex CLI wording: "Try again at Oct 2nd, 2026 3:04 PM." or "Try again at 3:04 PM." (local time).
            $english = [regex]::Match($resetText, '(?i)try again at\s+(?:([A-Z][a-z]{2,8})\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\s+)?(\d{1,2}:\d{2}\s*[AP]M)')
            if ($english.Success) {
                $clock = [datetime]::MinValue
                $culture = [Globalization.CultureInfo]::InvariantCulture
                if ($english.Groups[1].Success) {
                    $text = '{0} {1} {2} {3}' -f $english.Groups[1].Value, $english.Groups[2].Value, $english.Groups[3].Value, ($english.Groups[4].Value -replace '\s+', ' ')
                    if ([datetime]::TryParse($text, $culture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$clock)) { $reset = ([datetimeoffset]$clock).ToUniversalTime().ToString('o') }
                } elseif ([datetime]::TryParse(($english.Groups[4].Value -replace '\s+', ' '), $culture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$clock)) {
                    $localNow = ([datetimeoffset](& $script:RouterDiagnosisClock)).LocalDateTime
                    $at = $localNow.Date.Add($clock.TimeOfDay)
                    if ($at -le $localNow) { $at = $at.AddDays(1) }
                    $reset = ([datetimeoffset]$at).ToUniversalTime().ToString('o')
                }
            }
        }
        $relative = [regex]::Match($errorText, '(?i)try again in\s+((?:\d+\s+(?:days?|hours?|minutes?)[,\s]*(?:and\s+)?)+)')
        if (-not $reset -and $relative.Success) {
            # Codex leaves out zero parts ("4 days 2 hours", "45 minutes"); sum whatever parts are present.
            $at = [datetimeoffset](& $script:RouterDiagnosisClock)
            foreach ($part in [regex]::Matches($relative.Groups[1].Value, '(?i)(\d+)\s+(day|hour|minute)')) {
                $n = [double]$part.Groups[1].Value
                switch ($part.Groups[2].Value.ToLowerInvariant()) { 'day' { $at = $at.AddDays($n) } 'hour' { $at = $at.AddHours($n) } 'minute' { $at = $at.AddMinutes($n) } }
            }
            $reset = $at.ToString('o')
        }
    }
    return [pscustomobject]@{ refused=[bool]$refused; reset_at_utc=$reset }
}

function Format-RouterResumeAfterEt {
    param([Parameter(Mandatory)][datetimeoffset]$AtUtc, [Parameter(Mandatory)][string]$Source)
    $et = [TimeZoneInfo]::ConvertTime($AtUtc, [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time'))
    $prefix = if ($Source -eq 'recheck') { 'recheck after' } else { 'resume after' }
    return "$prefix $($et.ToString('ddd yyyy-MM-dd h:mm tt', [Globalization.CultureInfo]::InvariantCulture)) ET"
}

function Get-RouterResumeAfter {
    param([Parameter(Mandatory)][string[]]$Vendors)
    $now = [datetimeoffset]::UtcNow
    $blocks = @(Read-RouterJsonArray -Path (Join-Path (Get-RouterStateDir) 'vendor-blocks.json'))
    $times = foreach ($vendor in @($Vendors | Select-Object -Unique)) {
        $at = $null; $source = $null
        $usage = if ($vendor -eq 'codex') { Get-RouterCodexUsage } else { Get-RouterClaudeUsage }
        if ($null -ne $usage -and $usage.used_percent -ge 95 -and [datetimeoffset]$usage.resets_at_utc -gt $now) {
            $at = [datetimeoffset]$usage.resets_at_utc; $source = 'usage-reset'
        }
        foreach ($block in $blocks) {
            if (-not $block.PSObject.Properties['vendor'] -or -not $block.PSObject.Properties['reset_at_utc'] -or $block.vendor -ne $vendor) { continue }
            $reset = [datetimeoffset]$block.reset_at_utc
            if ($reset -le $now -or ($null -ne $at -and $reset -lt $at)) { continue }
            $at = $reset
            $source = if ($block.PSObject.Properties['resume_after_source']) { $block.resume_after_source }
                elseif ($block.PSObject.Properties['blocked_at_utc'] -and ($reset - [datetimeoffset]$block.blocked_at_utc).TotalSeconds -eq 3600) { 'recheck' }
                else { 'refusal-reset' }
        }
        if ($null -ne $at) { [pscustomobject]@{ at=$at; source=$source } }
    }
    $first = @($times | Sort-Object at | Select-Object -First 1)
    return [pscustomobject]@{
        resume_after_utc=$(if ($first.Count) { $first[0].at.ToUniversalTime().ToString('o') } else { $null })
        resume_after_source=$(if ($first.Count) { $first[0].source } else { $null })
        resume_after_et=$(if ($first.Count) { Format-RouterResumeAfterEt -AtUtc $first[0].at -Source $first[0].source } else { $null })
    }
}

function Get-RouterVendorBlocked {
    param([Parameter(Mandatory)][ValidateSet('codex','claude')][string]$Vendor)
    $now = [datetimeoffset](& $script:RouterDiagnosisClock)
    $path = Join-Path (Get-RouterStateDir) 'vendor-blocks.json'
    foreach ($entry in @(Read-RouterJsonArray -Path $path)) {
        if ($entry.vendor -eq $Vendor -and $entry.PSObject.Properties['reason'] -and $entry.reason -eq 'vendor_incident') { return $true }
        if ($entry.PSObject.Properties['vendor'] -and $entry.PSObject.Properties['reset_at_utc'] -and
            $entry.vendor -eq $Vendor -and [datetimeoffset]$entry.reset_at_utc -gt $now) { return $true }
    }
    if ($Vendor -eq 'codex') { $usage = Get-RouterCodexUsage; return ($null -ne $usage -and $usage.used_percent -ge 95) }
    $usage = Get-RouterClaudeUsage; return ($null -ne $usage -and $usage.used_percent -ge 95)
}

function Test-RouterConnectivity {
    param([Parameter(Mandatory)][ValidateSet('codex','claude')][string]$Vendor)
    $configPath = Join-Path (Get-RouterStateDir) 'vendor-status.json'
    if (-not (Test-Path -LiteralPath $configPath)) { $configPath = Join-Path $PSScriptRoot '../../references/model-router/vendor-status.json' }
    $lane = (Read-RouterJsonObject -Path $configPath).$Vendor
    $http = $false; $dns = $false
    try { $http = $null -ne (& $script:RouterDiagnosisHttp 'http://www.msftconnecttest.com/connecttest.txt') } catch { }
    try { $dns = [bool](& $script:RouterDiagnosisDns ([string]$lane.api_host)) } catch { }
    return [pscustomobject]@{ http=$http; dns=$dns; offline=(-not $http -and -not $dns) }
}

function Resolve-RouterDispatchFailure {
    param([Parameter(Mandatory)][ValidateSet('codex','claude')][string]$Vendor,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ErrorText)
    $checks = [ordered]@{ quota=$false; http=$null; dns=$null; status=$null; cache_hit=$false }
    $result = [pscustomobject]@{ verdict='unexplained'; detail=''; incident_id=$null; checks=$checks }
    $checks.quota = (Test-RouterLimitRefusal -Vendor $Vendor -Text $ErrorText).refused
    if ($checks.quota) { $result.verdict = 'quota'; $result.detail = 'Vendor limit refusal matched'; return $result }
    try {
        $configPath = Join-Path (Get-RouterStateDir) 'vendor-status.json'
        if (-not (Test-Path -LiteralPath $configPath)) { $configPath = Join-Path $PSScriptRoot '../../references/model-router/vendor-status.json' }
        $config = Read-RouterJsonObject -Path $configPath
        $lane = $config.$Vendor
        if (-not $lane.api_host -or -not $lane.components_url -or -not $lane.incidents_url -or -not @($lane.components).Count) { throw 'Incomplete vendor configuration' }
    } catch { $result.detail = "Component lookup configuration failed: $($_.Exception.Message)"; $checks.status = 'lookup_failed'; return $result }
    $connectivity = Test-RouterConnectivity -Vendor $Vendor
    $checks.http = $connectivity.http; $checks.dns = $connectivity.dns
    if (-not $checks.http -and -not $checks.dns) { $result.verdict = 'offline'; $result.detail = 'Connectivity HTTP probe and vendor API DNS lookup both failed'; return $result }
    try {
        $now = [datetimeoffset](& $script:RouterDiagnosisClock)
        $cachePath = Join-Path (Get-RouterStateDir) 'vendor-status-cache.json'
        $cache = @{}
        try {
            if (Test-Path -LiteralPath $cachePath) { $cache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json -AsHashtable -DateKind String }
        } catch { $cache = @{} }
        $reading = $null
        if ($cache.ContainsKey($Vendor)) {
            try {
                $age = ($now - [datetimeoffset]$cache[$Vendor].fetched_at).TotalSeconds
                if ($age -ge 0 -and $age -lt 300 -and $cache[$Vendor].components_url -ceq $lane.components_url -and $cache[$Vendor].incidents_url -ceq $lane.incidents_url) {
                    $reading = $cache[$Vendor]; $checks.cache_hit = $true
                }
            } catch { $reading = $null }
        }
        if ($null -eq $reading) {
            $response = & $script:RouterDiagnosisHttp ([string]$lane.components_url)
            $map = @{}
            foreach ($component in $response.components) {
                if (-not $component.name -or -not $component.id -or -not $component.status) { throw 'Malformed component response' }
                if ($map.ContainsKey([string]$component.name)) { throw "Duplicate component name: $($component.name)" }
                $map[[string]$component.name] = @{ id=[string]$component.id; status=[string]$component.status }
            }
            $reading = @{ fetched_at=$now.ToUniversalTime().ToString('o'); components=$map; components_url=$lane.components_url; incidents_url=$lane.incidents_url }
            $cache[$Vendor] = $reading
            Write-RouterJsonAtomic -Path $cachePath -Value $cache
        }
        # Recovery is component-specific, so quota and other incident siblings survive.
        $blockPath = Join-Path (Get-RouterStateDir) 'vendor-blocks.json'
        $blocks = @(Read-RouterJsonArray -Path $blockPath)
        $remaining = @($blocks | Where-Object {
            -not ($_.vendor -eq $Vendor -and $_.reason -eq 'vendor_incident' -and
                $reading.components.ContainsKey([string]$_.component) -and $reading.components[$_.component].status -ceq 'operational')
        })
        if ($remaining.Count -ne $blocks.Count) { Write-RouterJsonAtomic -Path $blockPath -Value $remaining }
        $missing = @($lane.components | Where-Object { -not $reading.components.ContainsKey([string]$_) })
        if ($missing.Count) { throw "Named component not found: $($missing -join ', ')" }
        $degraded = @($lane.components | Where-Object { $reading.components[$_].status -cne 'operational' })
        if (-not $degraded.Count) { $checks.status = 'operational'; $result.detail = 'Named lane components are operational'; return $result }
        $checks.status = 'non_operational'
        # The incident id is a courtesy detail. OpenAI's Statuspage serves components.json but returns 404 for
        # incidents/unresolved.json (checked 2026-10-01), so a failed incident lookup must not turn a real
        # non-operational component into "unexplained" and page Danny during a vendor outage.
        $incidents = $null
        try { $incidents = & $script:RouterDiagnosisHttp ([string]$lane.incidents_url) } catch { $incidents = $null }
        if ($null -eq $incidents -or -not $incidents.PSObject.Properties['incidents']) { $incidents = [pscustomobject]@{ incidents=@() } }
        foreach ($name in $degraded) {
            $componentId = $reading.components[$name].id
            $matched = @($incidents.incidents | Where-Object { @($_.components | Where-Object { $_.id -ceq $componentId }).Count } | Select-Object -First 1)
            $incidentId = if ($matched.Count) { [string]$matched[0].id } else { $null }
            $null = Add-RouterVendorBlock -Vendor $Vendor -Reason vendor_incident -Component $name -IncidentId $incidentId
            if ($name -ceq $degraded[0]) { $result.incident_id = $incidentId }
        }
        $result.verdict = 'vendor_incident'; $result.detail = "Non-operational lane component: $($degraded -join ', ')"
    } catch { $checks.status = 'lookup_failed'; $result.detail = "Component lookup failed: $($_.Exception.Message)" }
    return $result
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $RouterLimitsCliVendor) { throw 'VENDOR_REQUIRED: -Vendor must be codex or claude' }
    if ($RouterLimitsCliRecordBlock) {
        $recordArgs = @{ Vendor=$RouterLimitsCliVendor; Reason=$RouterLimitsCliReason }
        if ($PSBoundParameters.ContainsKey('RouterLimitsCliResetAtUtc')) { $recordArgs.ResetAtUtc = $RouterLimitsCliResetAtUtc }
        $null = Add-RouterVendorBlock @recordArgs
    }
    $usage = if ($RouterLimitsCliVendor -eq 'codex') { Get-RouterCodexUsage } else { Get-RouterClaudeUsage }
    $block = @(Read-RouterJsonArray -Path (Join-Path (Get-RouterStateDir) 'vendor-blocks.json') | Where-Object { $_.vendor -eq $RouterLimitsCliVendor -and ($_.reason -eq 'vendor_incident' -or [datetimeoffset]$_.reset_at_utc -gt [datetimeoffset]::UtcNow) } | Select-Object -First 1)
    $blocked = ($block.Count -gt 0 -or ($null -ne $usage -and $usage.used_percent -ge 95))
    $result = [pscustomobject]@{ vendor=$RouterLimitsCliVendor; blocked=$blocked; reason=$(if ($block.Count) { $block[0].reason } elseif ($blocked) { if ($RouterLimitsCliVendor -eq 'claude') { 'Claude weekly usage at or above 95%' } else { 'Codex usage at or above 95%' } } else { $null }); used_percent=$(if ($null -ne $usage) { $usage.used_percent } else { $null }); resets_at_utc=$(if ($null -ne $usage) { $usage.resets_at_utc } else { $null }) }
    if ($RouterLimitsCliVendor -eq 'claude') { $result | Add-Member -NotePropertyName session_percent -NotePropertyValue $(if ($null -ne $usage) { $usage.session_percent } else { $null }) }
    if ($RouterLimitsCliJson) { $result | ConvertTo-Json -Compress -Depth 5 } else { $result }
}
