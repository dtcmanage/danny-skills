param([Alias('Force')][switch]$RouterCheckCliForce, [Alias('TimeoutSeconds')][int]$RouterCheckCliTimeoutSeconds = 30, [Alias('Now')][datetime]$RouterCheckCliNow = (Get-Date), [Alias('Json')][switch]$RouterCheckCliJson)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')
. (Join-Path $PSScriptRoot 'vendor-limits.ps1')

function Get-RouterAnthropicModelIds {
    param([Parameter(Mandatory)][string]$Html)
    $ids = [System.Collections.Generic.List[string]]::new()
    $apiRowFound = $false
    foreach ($table in [regex]::Matches($Html, '<table\b[^>]*>.*?</table>', 'Singleline, IgnoreCase')) {
        foreach ($row in [regex]::Matches($table.Value, '<tr\b[^>]*>.*?</tr>', 'Singleline, IgnoreCase')) {
            $heading = [regex]::Match($row.Value, '<th\b[^>]*>(.*?)</th>', 'Singleline, IgnoreCase')
            if (-not $heading.Success) { continue }
            $label = [System.Net.WebUtility]::HtmlDecode(([regex]::Replace($heading.Groups[1].Value, '<[^>]+>', '')).Trim())
            if ($label -ne 'Claude API ID') { continue }
            $apiRowFound = $true
            foreach ($cell in [regex]::Matches($row.Value, '<td\b[^>]*>(.*?)</td>', 'Singleline, IgnoreCase')) {
                $id = [System.Net.WebUtility]::HtmlDecode(([regex]::Replace($cell.Groups[1].Value, '<[^>]+>', '')).Trim())
                if ($id -cmatch '^claude-[a-z]+-\d+(-\d+)?(-\d{8})?$') { $ids.Add($id) }
            }
        }
    }
    if (-not $apiRowFound -or $ids.Count -eq 0) { throw 'ANTHROPIC_API_ID_TABLE_NOT_FOUND' }
    return @($ids | Sort-Object -Unique)
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


function Update-RouterBenchJudges {
    param([object[]]$Listing)
    $path = Join-Path (Get-RouterStateDir) 'bench/judge-config.json'
    $config = if (Test-Path -LiteralPath $path) { Read-RouterJsonObject $path } else { Get-Content (Join-Path $PSScriptRoot 'bench/bench-config.json') -Raw | ConvertFrom-Json }
    # Only known frontier families qualify; generic catalog additions never become judges.
    foreach ($lane in @('claude','codex')) {
        $pattern = if ($lane -eq 'claude') { '^claude-fable-(\d+)(?:-(\d+))?(?:-\d{8})?$' } else { '^gpt-(\d+)(?:\.(\d+))?-astra$' }
        $effective = @($Listing) + @([pscustomobject]@{lane=$lane;id=$config.judges.$lane})
        $best = @($effective | Where-Object { $_.lane -eq $lane -and $_.id -match $pattern } | Sort-Object @{Expression={ [void]($_.id -match $pattern); [int]$Matches[1] };Descending=$true},@{Expression={ [void]($_.id -match $pattern); if($Matches[2]){[int]$Matches[2]}else{0} };Descending=$true} | Select-Object -First 1)
        if ($best.Count) { $config.judges.$lane = $best[0].id }
    }
    [void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
    Write-RouterJsonAtomic -Path $path -Value $config
}

function Invoke-RouterModelCheck {
    param([switch]$Force, [int]$TimeoutSeconds = 30, [datetime]$Now = (Get-Date), [scriptblock]$BenchInvoker)
    Assert-RouterWindowsOwner -Action 'Vendor release polling'
    $state = Get-RouterStateDir
    $stamp = Join-Path $state 'last-check.json'
    $result = [ordered]@{ skipped = $false; offline = $false; timed_out = $false; checked_at = $null; new_models = @(); missing_models = @(); errors = @(); alerts = @() }
    if (-not $Force) {
        $last = Read-RouterJsonObject -Path $stamp
        if ($null -ne $last) {
            try {
                if (($Now - [datetime]$last.checked_at).TotalHours -ge 0 -and ($Now - [datetime]$last.checked_at).TotalHours -lt 12) {
                    $result.skipped = $true
                    $result.checked_at = $last.checked_at
                    return [pscustomobject]$result
                }
            } catch { }
        }
    }
    $vendorsPath = Join-Path $PSScriptRoot '../../references/model-router/vendors.json'
    if ((Get-Variable -Name RouterModelCheckVendorsPath -Scope Script -ErrorAction SilentlyContinue) -and $script:RouterModelCheckVendorsPath) { $vendorsPath = $script:RouterModelCheckVendorsPath }
    $vendors = @(Get-Content -LiteralPath $vendorsPath -Raw | ConvertFrom-Json)
    foreach ($lane in @($vendors.lane | Sort-Object -Unique)) {
        if ((Test-RouterConnectivity -Vendor $lane).offline) {
            $result.skipped = $true; $result.offline = $true
            return [pscustomobject]$result
        }
    }
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
        $registryExisted = Test-Path -LiteralPath $registryPath
        $registry = @(Read-RouterJsonArray -Path $registryPath)
        if (-not $registryExisted -or $registry.Count -eq 0) {
            if ($registryExisted) { $result.alerts += 'known-models-reset' }
            Write-RouterJsonAtomic -Path $registryPath -Value @($listing.ToArray())
        } else {
            $queued = [System.Collections.Generic.List[object]]::new()
            $current = @{}; foreach ($item in $listing) { $current["$($item.vendor)/$($item.id)"] = $item }
            $old = @{}; foreach ($item in $registry) { $old["$($item.vendor)/$($item.id)"] = $item }
            foreach ($item in $listing) {
                if (-not $old.ContainsKey("$($item.vendor)/$($item.id)")) {
                    $item.status = 'unprofiled'; $registry += $item; $queued.Add($item)
                    $result.new_models += $item.id; $result.alerts += "new-model:$($item.id)"
                }
            }
            foreach ($item in $registry) {
                if (-not $current.ContainsKey("$($item.vendor)/$($item.id)") -and $item.status -ne 'missing') {
                    $item.status = 'missing'; $result.missing_models += $item.id; $result.alerts += "model-missing:$($item.id)"
                }
            }
            if ($queued.Count) {
                if (-not (Get-Command Add-RouterResearchQueueItem -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'run-router-cadence.ps1') }
                foreach ($new in $queued) {
                    $categories = @(Get-RouterCadenceCategories -Model ([string]$new.id))
                    [void](Add-RouterResearchQueueItem -Model $new.id -Trigger release -Categories $categories -DueAt $Now -Reason 'new-model-release')
                    [void](Add-RouterResearchQueueItem -Model $new.id -Trigger confirmation -Categories $categories -DueAt $Now.AddDays(7) -Reason 'day-seven-confirmation')
                }
            }
            Write-RouterJsonAtomic -Path $registryPath -Value @($registry)
        }
        Write-RouterJsonAtomic -Path $stamp -Value @{ checked_at = $result.checked_at }
        Update-RouterBenchJudges -Listing @($listing.ToArray())
        if (@($result.new_models).Count) {
            try {
                . (Join-Path $PSScriptRoot 'build-roster.ps1')
                $snapshot = (Read-RouterRoster).roster
                foreach ($model in $result.new_models) {
                    if (Test-RouterFrontierModel -Model $model) { continue }
                    $categories = @(Get-RouterCadenceCategories -Model $model)
                    foreach ($job in @($categories | ForEach-Object { Get-RouterCategoryJob $_ } | Sort-Object -Unique)) {
                        $entry = $snapshot.jobs.$job
                        $request = [pscustomobject]@{job=$job;candidate=$model;incumbent=$entry.first;effort=$entry.first_effort}
                        $bench = Invoke-RouterTriggeredComparison -Request $request -Trigger new-model -BenchInvoker $BenchInvoker
                        Use-RouterOutcomeMutex -StateDir $state -Action {
                            if ((ConvertTo-Json (Read-RouterRoster).roster.jobs -Compress -Depth 30) -cne (ConvertTo-Json $snapshot.jobs -Compress -Depth 30)) { throw 'BENCH_STALE_ROSTER' }
                            Save-RouterEffortProposal $request $bench
                        } | Out-Null
                        Send-RouterEffortAlerts
                    }
                }
            } catch { $result.alerts += 'bench-trigger-error' }
        }
        return [pscustomobject]$result
    } finally {
        foreach ($job in $jobs) { if ($job.State -notin @('Completed','Failed','Stopped')) { Stop-Job -Job $job }; Remove-Job -Job $job -Force }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Invoke-RouterModelCheck -Force:$RouterCheckCliForce -TimeoutSeconds $RouterCheckCliTimeoutSeconds -Now $RouterCheckCliNow
    if ($RouterCheckCliJson) { $result | ConvertTo-Json -Depth 12 -Compress } else { $result }
}
