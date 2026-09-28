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
    param([Parameter(Mandatory)][ValidateSet('codex','claude')][string]$Vendor, [datetimeoffset]$ResetAtUtc, [string]$Reason)
    $now = [datetimeoffset]::UtcNow
    if (-not $PSBoundParameters.ContainsKey('ResetAtUtc')) { $ResetAtUtc = $now.AddHours(1) }
    $path = Join-Path (Get-RouterStateDir) 'vendor-blocks.json'
    $entries = @(Read-RouterJsonArray -Path $path | Where-Object {
        $_.PSObject.Properties['vendor'] -and $_.PSObject.Properties['reset_at_utc'] -and
        $_.vendor -ne $Vendor -and [datetimeoffset]$_.reset_at_utc -gt $now
    })
    $block = [pscustomobject]@{ vendor=$Vendor; blocked_at_utc=$now.ToString('o'); reset_at_utc=$ResetAtUtc.ToUniversalTime().ToString('o'); reason=$Reason }
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
    $refused = $errorText -match '(?i)(?:usage limit (?:reached|exceeded)|you(?:[''\u2019]ve| have) (?:hit|reached) your (?:usage )?limit|\b\d+-hour limit reached|weekly limit reached|rate limit (?:reached|exceeded)|would exceed the rate limit|(?<![A-Za-z0-9_])rate_limit_(?:exceeded|error)(?![A-Za-z0-9_])|quota exceeded|too many requests|Claude AI usage limit reached)'
    $reset = $null
    if ($refused) {
        $time = [regex]::Match($resetText, '(?im)(?:resets?_at|resets? at|try again at|available again at|Claude AI usage limit reached\|)["'']?\s*[=:]?\s*["'']?([0-9]{10}|[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}(?::[0-9]{2})?(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:?[0-9]{2})?)')
        if ($time.Success) {
            $value = $time.Groups[1].Value.Trim().TrimEnd('.',',',';')
            $parsed = [datetimeoffset]::MinValue
            if ([datetimeoffset]::TryParse($value, [ref]$parsed)) { $reset = $parsed.ToUniversalTime().ToString('o') }
            elseif ($value -match '^\d{10}$') { $reset = [datetimeoffset]::FromUnixTimeSeconds([long]$value).ToString('o') }
        }
        $relative = [regex]::Match($errorText, '(?i)try again in\s+((?:\d+\s+(?:days?|hours?|minutes?)[,\s]*(?:and\s+)?)+)')
        if (-not $reset -and $relative.Success) {
            # Codex leaves out zero parts ("4 days 2 hours", "45 minutes"); sum whatever parts are present.
            $at = [datetimeoffset]::UtcNow
            foreach ($part in [regex]::Matches($relative.Groups[1].Value, '(?i)(\d+)\s+(day|hour|minute)')) {
                $n = [double]$part.Groups[1].Value
                switch ($part.Groups[2].Value.ToLowerInvariant()) { 'day' { $at = $at.AddDays($n) } 'hour' { $at = $at.AddHours($n) } 'minute' { $at = $at.AddMinutes($n) } }
            }
            $reset = $at.ToString('o')
        }
    }
    return [pscustomobject]@{ refused=[bool]$refused; reset_at_utc=$reset }
}

function Get-RouterVendorBlocked {
    param([Parameter(Mandatory)][ValidateSet('codex','claude')][string]$Vendor)
    $now = [datetimeoffset]::UtcNow
    $path = Join-Path (Get-RouterStateDir) 'vendor-blocks.json'
    foreach ($entry in @(Read-RouterJsonArray -Path $path)) {
        if ($entry.PSObject.Properties['vendor'] -and $entry.PSObject.Properties['reset_at_utc'] -and
            $entry.vendor -eq $Vendor -and [datetimeoffset]$entry.reset_at_utc -gt $now) { return $true }
    }
    if ($Vendor -eq 'codex') { $usage = Get-RouterCodexUsage; return ($null -ne $usage -and $usage.used_percent -ge 95) }
    return $false
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $RouterLimitsCliVendor) { throw 'VENDOR_REQUIRED: -Vendor must be codex or claude' }
    if ($RouterLimitsCliRecordBlock) {
        $recordArgs = @{ Vendor=$RouterLimitsCliVendor; Reason=$RouterLimitsCliReason }
        if ($PSBoundParameters.ContainsKey('RouterLimitsCliResetAtUtc')) { $recordArgs.ResetAtUtc = $RouterLimitsCliResetAtUtc }
        $null = Add-RouterVendorBlock @recordArgs
    }
    $usage = if ($RouterLimitsCliVendor -eq 'codex') { Get-RouterCodexUsage } else { $null }
    $block = @(Read-RouterJsonArray -Path (Join-Path (Get-RouterStateDir) 'vendor-blocks.json') | Where-Object { $_.vendor -eq $RouterLimitsCliVendor -and [datetimeoffset]$_.reset_at_utc -gt [datetimeoffset]::UtcNow } | Select-Object -First 1)
    $blocked = ($block.Count -gt 0 -or ($null -ne $usage -and $usage.used_percent -ge 95))
    $result = [pscustomobject]@{ vendor=$RouterLimitsCliVendor; blocked=$blocked; reason=$(if ($block.Count) { $block[0].reason } elseif ($blocked) { 'Codex usage at or above 95%' } else { $null }); used_percent=$(if ($null -ne $usage) { $usage.used_percent } else { $null }) }
    if ($RouterLimitsCliJson) { $result | ConvertTo-Json -Compress -Depth 5 } else { $result }
}
