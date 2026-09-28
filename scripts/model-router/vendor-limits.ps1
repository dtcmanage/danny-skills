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
