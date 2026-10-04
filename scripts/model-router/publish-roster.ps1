Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'router-common.ps1')

function Publish-RouterRoster {
    Assert-RouterWindowsOwner -Action 'Roster publication'
    Use-RouterRosterMutex -Body {
    $source = Join-Path (Get-RouterStatePath) 'roster.json'
    $destination = Join-Path (Get-RouterSharedDir) 'roster.json'
    # A missing/invalid authority must not leave a stale approved snapshot available.
    if (-not (Test-Path -LiteralPath $source)) {
        if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force }
        return
    }
    try {
        $roster = Get-Content -LiteralPath $source -Raw | ConvertFrom-Json -Depth 20
        $errors = @(Test-RouterRoster -Roster $roster)
        if ($errors.Count) { throw "ROSTER_PUBLISH_INVALID: $($errors -join '; ')" }
        # Only routing fields travel. Runtime caches, proposal metadata and credentials do not.
        $snapshot = [ordered]@{}
        foreach ($field in @('schema_version','generated_at','approved','approved_at','category_jobs')) { $snapshot[$field] = $roster.$field }
        $snapshot.jobs = [ordered]@{}
        foreach ($job in @(Get-RouterJobs)) {
            $entry = [ordered]@{}
            foreach ($field in @('first','first_vendor','backup','backup_vendor','first_effort','backup_effort')) { $entry[$field] = $roster.jobs.$job.$field }
            if ($roster.jobs.$job.PSObject.Properties['tie_evidence']) { $entry.tie_evidence = $roster.jobs.$job.tie_evidence }
            $snapshot.jobs[$job] = $entry
        }
        Write-RouterJsonAtomic -Path $destination -Value $snapshot
    } catch {
        if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force }
        throw
    }
    }
}

if ($MyInvocation.InvocationName -ne '.') { Publish-RouterRoster }
