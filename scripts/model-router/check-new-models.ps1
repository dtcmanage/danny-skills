param([switch]$Force, [int]$TimeoutSeconds = 30, [datetime]$Now = (Get-Date), [switch]$Json)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')

function Get-RouterAnthropicModelIds {
    param([Parameter(Mandatory)][string]$Html)
    return @([regex]::Matches($Html, '\bclaude-(?=[a-z0-9-]*\d)[a-z0-9]+(?:-[a-z0-9]+)*\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) |
        ForEach-Object { $_.Value.ToLowerInvariant() } | Sort-Object -Unique)
}

function Get-RouterVendorModels {
    param([Parameter(Mandatory)][object]$Vendor, [int]$TimeoutSeconds = 30)
    switch ([string]$Vendor.source) {
        'codex-catalog' {
            . (Join-Path $PSScriptRoot '../resolve-codex-model.ps1')
            $cli = (Get-Command codex -ErrorAction Stop).Source
            $catalog = Update-CodexModelCatalog -CodexCliPath $cli -TimeoutMs ([Math]::Max(1000, [Math]::Min(120000, $TimeoutSeconds * 1000)))
            $ids = foreach ($row in @($catalog.models)) {
                if ($row.PSObject.Properties['slug'] -and $row.PSObject.Properties['visibility'] -and $row.visibility -eq 'list' -and
                    (-not $row.PSObject.Properties['upgrade'] -or $null -eq $row.upgrade) -and [string]$row.slug -match '^gpt-\d+(?:\.\d+)?(?:-|$)' -and
                    [string]$row.slug -notmatch 'spark') { [string]$row.slug }
            }
            return @($ids | Sort-Object -Unique)
        }
        'anthropic-models-page' {
            $response = Invoke-WebRequest -Uri $Vendor.url -TimeoutSec $TimeoutSeconds
            return @(Get-RouterAnthropicModelIds -Html ([string]$response.Content))
        }
        default { throw "UNKNOWN_SOURCE_TYPE: $($Vendor.source)" }
    }
}

function Write-RouterJsonAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Value)
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temp = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = ConvertTo-Json -InputObject $Value -Depth 20
        [IO.File]::WriteAllText($temp, $json, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp, $Path, $true)
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

function Invoke-RouterModelCheck {
    param([switch]$Force, [int]$TimeoutSeconds = 30, [datetime]$Now = (Get-Date))
    $state = Get-RouterStateDir
    $stamp = Join-Path $state 'last-check.json'
    $result = [ordered]@{ skipped = $false; timed_out = $false; checked_at = $null; new_models = @(); missing_models = @(); errors = @(); alerts = @() }
    if (-not $Force -and (Test-Path -LiteralPath $stamp)) {
        try {
            $last = Get-Content -LiteralPath $stamp -Raw | ConvertFrom-Json
            if (($Now - [datetime]$last.checked_at).TotalHours -ge 0 -and ($Now - [datetime]$last.checked_at).TotalHours -lt 12) {
                $result.skipped = $true
                $result.checked_at = $last.checked_at
                return [pscustomobject]$result
            }
        } catch { }
    }
    $vendorsPath = Join-Path $PSScriptRoot '../../references/model-router/vendors.json'
    if ((Get-Variable -Name RouterModelCheckVendorsPath -Scope Script -ErrorAction SilentlyContinue) -and $script:RouterModelCheckVendorsPath) { $vendorsPath = $script:RouterModelCheckVendorsPath }
    $vendors = @(Get-Content -LiteralPath $vendorsPath -Raw | ConvertFrom-Json)
    $jobs = [System.Collections.Generic.List[object]]::new()
    $fetcher = if (Get-Variable -Name RouterModelCheckFetcher -Scope Script -ErrorAction SilentlyContinue) { $script:RouterModelCheckFetcher } else { $null }
    try {
        foreach ($vendor in $vendors) {
            if ($vendor.source -notin @('codex-catalog','anthropic-models-page')) {
                $result.errors += "unknown source type for $($vendor.id): $($vendor.source)"
                $result.alerts += "catalog-check-error:$($vendor.id)"
                continue
            }
            $jobs.Add((Start-ThreadJob -ScriptBlock {
                param($item, $sourceScript, $injectedFetcher, $limit)
                try {
                    if ($null -ne $injectedFetcher) { $ids = @(& $injectedFetcher $item) }
                    else { . $sourceScript; $ids = @(Get-RouterVendorModels -Vendor $item -TimeoutSeconds $limit) }
                    [pscustomobject]@{ vendor = $item; models = @($ids); error = $null }
                } catch { [pscustomobject]@{ vendor = $item; models = @(); error = $_.Exception.Message } }
            } -ArgumentList $vendor, $PSCommandPath, $fetcher, $TimeoutSeconds))
        }
        $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
        foreach ($job in $jobs) {
            $remaining = [Math]::Max(0, [int][Math]::Ceiling(($deadline - [datetime]::UtcNow).TotalSeconds))
            if ($remaining -eq 0 -or -not (Wait-Job -Job $job -Timeout $remaining)) { $result.timed_out = $true; break }
        }
        if ($result.timed_out) {
            $result.alerts += 'catalog-check-timeout'
            return [pscustomobject]$result
        }
        $listing = [System.Collections.Generic.List[object]]::new()
        foreach ($job in $jobs) {
            $out = Receive-Job -Job $job -ErrorAction Stop
            if ($out.error) { $result.errors += "$($out.vendor.id): $($out.error)"; $result.alerts += "catalog-check-error:$($out.vendor.id)" }
            elseif (@($out.models).Count -eq 0) { $result.errors += "$($out.vendor.id): empty model list"; $result.alerts += "catalog-check-error:$($out.vendor.id)" }
            else { foreach ($id in @($out.models | Sort-Object -Unique)) { $listing.Add([pscustomobject]@{ id = [string]$id; vendor = [string]$out.vendor.id; lane = [string]$out.vendor.lane; status = 'known' }) } }
        }
        $result.checked_at = $Now.ToString('o')
        if ($result.errors.Count) { return [pscustomobject]$result }
        $registryPath = Join-Path $state 'known-models.json'
        $queuePath = Join-Path $state 'pending-research.json'
        if (-not (Test-Path -LiteralPath $registryPath)) {
            Write-RouterJsonAtomic -Path $registryPath -Value @($listing.ToArray())
        } else {
            $registry = @(Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json)
            $queue = if (Test-Path -LiteralPath $queuePath) { @(Get-Content -LiteralPath $queuePath -Raw | ConvertFrom-Json) } else { @() }
            $current = @{}; foreach ($item in $listing) { $current["$($item.vendor)/$($item.id)"] = $item }
            $old = @{}; foreach ($item in $registry) { $old["$($item.vendor)/$($item.id)"] = $item }
            foreach ($item in $listing) {
                if (-not $old.ContainsKey("$($item.vendor)/$($item.id)")) {
                    $item.status = 'unprofiled'; $registry += $item; $queue += [pscustomobject]@{ id = $item.id; vendor = $item.vendor; lane = $item.lane; detected_at = $result.checked_at }
                    $result.new_models += $item.id; $result.alerts += "new-model:$($item.id)"
                }
            }
            foreach ($item in $registry) {
                if (-not $current.ContainsKey("$($item.vendor)/$($item.id)") -and $item.status -ne 'missing') {
                    $item.status = 'missing'; $result.missing_models += $item.id; $result.alerts += "model-missing:$($item.id)"
                }
            }
            Write-RouterJsonAtomic -Path $registryPath -Value @($registry)
            if ($result.new_models.Count) { Write-RouterJsonAtomic -Path $queuePath -Value @($queue) }
        }
        Write-RouterJsonAtomic -Path $stamp -Value @{ checked_at = $result.checked_at }
        return [pscustomobject]$result
    } finally {
        foreach ($job in $jobs) { if ($job.State -notin @('Completed','Failed','Stopped')) { Stop-Job -Job $job }; Remove-Job -Job $job -Force }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-RouterModelCheck -Force:$Force -TimeoutSeconds $TimeoutSeconds -Now $Now
    if ($Json) { $result | ConvertTo-Json -Depth 12 -Compress } else { $result }
}
