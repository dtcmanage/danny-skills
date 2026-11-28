# A baseline is an immutable export of the repository's default branch, never a
# caller-supplied success receipt. Keep source copies outside synced workspaces.
function New-AcceptanceBaseline {
    param([string]$WorkingTree)
    $ref = (& git -C $WorkingTree symbolic-ref refs/remotes/origin/HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) {
        $ref = $null
        foreach ($candidate in @('main','master')) {
            & git -C $WorkingTree show-ref --verify --quiet "refs/heads/$candidate" 2>$null
            if ($LASTEXITCODE -eq 0) { $ref = "refs/heads/$candidate"; break }
        }
    }
    if (-not $ref) { return [pscustomobject]@{ available=$false; reason='default branch unavailable'; path=$null; commit=$null } }
    $commit = & git -C $WorkingTree rev-parse "$ref^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'BASELINE_REF_UNRESOLVED' }
    $root = Join-Path ([Environment]::GetFolderPath('UserProfile')) ('.cache/build-acceptance-gates/baseline-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($root) | Out-Null
    try {
        $archive = Join-Path $root 'source.tar'
        & git -C $WorkingTree archive --format=tar "--output=$archive" $commit
        if ($LASTEXITCODE -ne 0) { throw 'BASELINE_EXPORT_FAILED' }
        $source = Join-Path $root 'source'
        [IO.Directory]::CreateDirectory($source) | Out-Null
        & tar -xf $archive -C $source
        if ($LASTEXITCODE -ne 0) { throw 'BASELINE_EXTRACT_FAILED' }
        return [pscustomobject]@{ available=$true; reason=$null; ref=[string]$ref; commit=[string]$commit; path=$source; scratch=$root }
    } catch { Remove-Item -LiteralPath $root -Recurse -Force; throw }
}

function Get-AcceptanceFailureFingerprint {
    param($Result, [string]$WorkingTree)
    # Compare COMPLETE streams, not tails, failure counts or just exit codes.
    # Normalize only transport formatting and the two source-root identities.
    $streams = foreach ($name in @('stdout_path','stderr_path')) {
        $content = [IO.File]::ReadAllText($Result.$name)
        $content.Replace([IO.Path]::GetFullPath($WorkingTree), '<source>').Replace("`r`n", "`n") -replace '\x1b\[[0-9;]*[A-Za-z]', ''
    }
    $payload = ConvertTo-Json -Compress -InputObject @($Result.exit_code, @($streams))
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($payload))).ToLowerInvariant()
}

function Test-AcceptanceBaselineFailure {
    param($Current, $Baseline, [string]$WorkingTree, [string]$BaselineTree)
    # Timeouts/infrastructure interruptions can never establish a baseline floor.
    try {
        if ((Test-AcceptanceInfrastructureFailure $Current) -or (Test-AcceptanceInfrastructureFailure $Baseline) -or
            $Current.exit_code -eq 0 -or $Baseline.exit_code -eq 0 -or $Current.exit_code -ne $Baseline.exit_code) { return $false }
        return (Get-AcceptanceFailureFingerprint $Current $WorkingTree) -ceq (Get-AcceptanceFailureFingerprint $Baseline $BaselineTree)
    } catch { return $false }
}

function Test-AcceptanceInfrastructureFailure {
    param($Result)
    # Inspect full streams, including loader failures that exit 1 rather than 127.
    # Missing/unreadable evidence is infrastructure, never a known test failure.
    if ($Result.timed_out -isnot [bool] -or $Result.timed_out -or $Result.exit_code -in @(124,126,127,137,139,143)) { return $true }
    foreach ($name in @('stdout_path','stderr_path')) {
        $content = [IO.File]::ReadAllText($Result.$name) -replace '\x1b\[[0-9;]*[A-Za-z]', ''
        if ($content -match '(?i)No module named|ModuleNotFoundError|ImportError:|command not found|not recognized as|CommandNotFoundException|Permission denied|cannot execute|bad interpreter|error while loading shared libraries|cannot open shared object file|ERR_MODULE_NOT_FOUND|Cannot find module|Could not load (?:file or assembly|type)|PYTEST_LOCK_WAIT_TIMEOUT|ERROR at setup|ERROR collecting|errors? during collection|no tests (?:ran|collected)|ERROR:\s*usage:|infrastructure (?:failure|error)') { return $true }
    }
    return $false
}

function Test-AcceptanceCommandPass {
    param($Result)
    if ($Result.exit_code -eq 0) { return (-not $Result.PSObject.Properties['timed_out'] -or ($Result.timed_out -is [bool] -and -not $Result.timed_out)) }
    try {
        $b = $Result.baseline
        if (-not ($b.available -is [bool] -and $b.available -and $b.identical_failure -is [bool] -and $b.identical_failure -and
            $b.commit -cmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$' -and
            $b.current_fingerprint -cmatch '^[0-9a-f]{64}$' -and
            $b.current_fingerprint -ceq $b.baseline_fingerprint -and
            $Result.timed_out -is [bool] -and -not $Result.timed_out -and $b.result.timed_out -is [bool] -and -not $b.result.timed_out -and
            $Result.exit_code -eq $b.result.exit_code -and -not [string]::IsNullOrWhiteSpace($b.note))) { return $false }
        if (-not [IO.Path]::IsPathRooted($b.current_source_root) -or -not [IO.Path]::IsPathRooted($b.baseline_source_root)) { return $false }
        if (-not (Test-AcceptanceBaselineFailure $Result $b.result $b.current_source_root $b.baseline_source_root)) { return $false }
        return ((Get-AcceptanceFailureFingerprint $Result $b.current_source_root) -ceq $b.current_fingerprint -and
            (Get-AcceptanceFailureFingerprint $b.result $b.baseline_source_root) -ceq $b.baseline_fingerprint)
    } catch { return $false }
}
