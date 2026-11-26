# Called before routing's synthetic expiry adjustments. Failures never change guard decisions.
function Save-RouterQuotaObservation {
    param([string]$Vendor, [string]$Source, [object]$Data,
        [string]$ObservedAtUtc = ([datetimeoffset]::UtcNow.ToString('o')),
        [ValidateSet('fresh','cache','backfill')][string]$Provenance = 'fresh')
    if ((Get-RouterPlatform) -ne (Get-RouterOwnerPlatform)) { return }
    try {
        $python = (Get-Command python3, python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        $payload = @{ vendor=$Vendor; source=$Source; data=$Data; observed_at_utc=$ObservedAtUtc
            collected_at_utc=[datetimeoffset]::UtcNow.ToString('o'); provenance=$Provenance
            owner_profile='danny-local-owner' } | ConvertTo-Json -Depth 30 -Compress
        $result = $payload | & $python (Join-Path $PSScriptRoot 'quota_history.py') --state-dir (Get-RouterStatePath) --ingest 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'QUOTA_HISTORY_WRITE_FAILED' }
        $script:RouterQuotaHistoryStatus = [string]($result | ConvertFrom-Json).status
    } catch {
        $script:RouterQuotaHistoryStatus = 'error'
        Write-Warning 'QUOTA_HISTORY_WRITE_FAILED: quota history was not saved; routing is unchanged.'
    }
}
