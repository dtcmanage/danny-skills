[CmdletBinding()]
param(
    [string]$BaseRef = 'auto',
    [switch]$Full,
    [ValidateRange(1, 6)][int]$ThrottleLimit = 6,
    [switch]$List,
    [string]$LogDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

function Get-GateSteps {
    # One catalog owns execution and selection. Always-run steps are the cheap policy gate.
    @(
        @{ Name='dt-job'; Skill='dt-build'; Command='& ./skills/dt-build/scripts/tests/test-dt-job.ps1'; Slots=2 }
        @{ Name='context-guard'; Skill='dt-build'; Command='& ./skills/dt-build/scripts/tests/test-context-guard.ps1' }
        @{ Name='build-regressions'; Skill='dt-build'; Command='& ./skills/dt-build/scripts/test-dt-build-regressions.ps1'; Slots=3 }
        @{ Name='versioning-tests'; Skill=''; Command='& ./scripts/test-versioning-policy.ps1' }
        @{ Name='review'; Skill='dt-review'; Command='& ./skills/dt-review/tests/run-tests.ps1' }
        @{ Name='host-adapters'; Skill='dt-build'; Command='& ./skills/dt-build/scripts/tests/test-host-adapters.ps1' }
        @{ Name='review-final-draft'; Skill='dt-review'; Command='& ./skills/dt-review/tests/run-final-draft-tests.ps1' }
        @{ Name='roadmap-hardware'; Skill='dt-roadmap'; Command='& ./skills/dt-roadmap/scripts/tests/test-hardware-roadmap.ps1' }
        @{ Name='roadmap-coverage'; Skill='dt-roadmap'; Command='& ./skills/dt-roadmap/scripts/tests/test-design-coverage.ps1' }
        @{ Name='roadmap-sources'; Skill='dt-roadmap'; Command='& ./skills/dt-roadmap/scripts/tests/test-milestone-sources.ps1' }
        @{ Name='merge-feature'; Skill='git-merge-feature'; Command='& ./skills/git-merge-feature/scripts/tests/test-merge-feature.ps1' }
        @{ Name='ship-live-jobs'; Skill='dt-ship'; Command='& ./skills/dt-ship/tests/test-ship-live-jobs.ps1' }
        @{ Name='release-triage'; Skill=''; Command='& ./scripts/tests/test-release-triage.ps1' }
        @{ Name='preflight'; Skill='*'; Command='& ./scripts/test-preflight.ps1 -Scope gate' }
        @{ Name='preflight-tests'; Skill='*'; Command='& ./scripts/tests/test-test-preflight.ps1' }
        @{ Name='gate-runner-tests'; Skill='*'; Command='& ./scripts/tests/test-run-gate.ps1' }
        @{ Name='eastern-time'; Skill='*'; Command='& $env:DANNY_SKILLS_TEST_PYTHON -m unittest scripts/tests/test_eastern_time.py; exit $LASTEXITCODE' }
        @{ Name='versioning-policy'; Skill='*'; Command='& ./scripts/verify-versioning-policy.ps1 -BaseRef auto' }
        @{ Name='plugin-validation'; Skill='*'; Command='& ./tools/build-plugin.ps1 -BaseRef auto -ValidateOnly' }
    )
}

function Test-GateReleaseMetadataOnly {
    param([string]$Path, [string]$BaseRef = 'auto')
    # Compare parsed JSON against the merge base, including staged and working edits.
    # Only the known release fields can be ignored; malformed/new/deleted manifests fail closed.
    if ($Path -notin @('.claude-plugin/plugin.json','.claude-plugin/marketplace.json')) { return $false }
    if ($BaseRef -eq 'auto') { $BaseRef = 'main' }
    try {
        $base = & git -C $repo merge-base HEAD $BaseRef 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        $beforeText = & git -C $repo show "${base}:$Path" 2>$null
        if ($LASTEXITCODE -ne 0) { return $false }
        $before = ($beforeText -join "`n") | ConvertFrom-Json -AsHashtable
        $after = Get-Content -LiteralPath (Join-Path $repo $Path) -Raw | ConvertFrom-Json -AsHashtable
        foreach ($document in @($before,$after)) {
            if ($document -isnot [Collections.IDictionary]) { return $false }
            if ($Path -eq '.claude-plugin/plugin.json') { $document.Remove('version') | Out-Null }
            if ($document.Contains('metadata') -and $document.metadata -is [Collections.IDictionary]) {
                $document.metadata.Remove('version') | Out-Null
                $document.metadata.Remove('changelog') | Out-Null
            }
            if ($Path -eq '.claude-plugin/marketplace.json' -and $document.Contains('plugins')) {
                foreach ($plugin in $document.plugins) { $plugin.Remove('version') | Out-Null }
            }
        }
        # Sort object keys recursively, preserving array order and JSON value types.
        function ConvertTo-GateCanonicalJson($Value) {
            if ($Value -is [Collections.IDictionary]) {
                $items = foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) {
                    (ConvertTo-Json -InputObject ([string]$key) -Compress) + ':' + (ConvertTo-GateCanonicalJson $Value[$key])
                }
                return '{' + ($items -join ',') + '}'
            }
            if ($Value -is [array]) { return '[' + ((@($Value | ForEach-Object { ConvertTo-GateCanonicalJson $_ })) -join ',') + ']' }
            return ConvertTo-Json -InputObject $Value -Depth 100 -Compress
        }
        return (ConvertTo-GateCanonicalJson $before) -ceq (ConvertTo-GateCanonicalJson $after)
    }
    catch { return $false }
}

function Select-GateSteps {
    param([string[]]$ChangedPaths, [switch]$Full, [string]$BaseRef = 'auto')
    $all = @(Get-GateSteps)
    $skills = @{}
    foreach ($path in $ChangedPaths) {
        if ($path -match '^skills/([^/]+)/' -and (Test-Path -LiteralPath (Join-Path $repo "skills/$($Matches[1])/SKILL.md"))) { $skills[$Matches[1]] = $true }
        elseif ($path -like '.claude-plugin/*' -and (Test-GateReleaseMetadataOnly -Path $path -BaseRef $BaseRef)) { continue }
        else { $Full = $true } # Shared and unknown paths both require the full gate.
    }
    @($all | Where-Object { $Full -or $_.Skill -eq '*' -or $skills.ContainsKey($_.Skill) })
}

function Get-GateChangedPaths {
    param([string]$BaseRef)
    if ($BaseRef -eq 'auto') { $BaseRef = 'main' }
    $base = & git -C $repo merge-base HEAD $BaseRef
    if ($LASTEXITCODE -ne 0) { throw "Cannot resolve merge base: $BaseRef" }
    $paths = @(& git -C $repo diff --name-only --no-renames $base --)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate changed paths' }
    $paths += @(& git -C $repo ls-files --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate untracked paths' }
    return @($paths | Where-Object { $_ } | Sort-Object -Unique)
}

if ($MyInvocation.InvocationName -eq '.') { return }
Push-Location $repo
try {
    $paths = @(Get-GateChangedPaths -BaseRef $BaseRef)
    # Clean main has no feature merge base delta; use the full release gate there.
    $branch = & git branch --show-current
    $steps = @(Select-GateSteps -ChangedPaths $paths -BaseRef $BaseRef -Full:($Full -or $branch -eq 'main'))
    Write-Output "Gate selection: $($steps.Name -join ', ') (concurrency $ThrottleLimit)"
    if ($List) { exit 0 }
    $wall = [Diagnostics.Stopwatch]::StartNew()
    . (Join-Path $PSScriptRoot 'lib/resolve-test-python.ps1')
    $python = Resolve-TestPython
    if (-not $python.Path) { throw 'Test Python unavailable' }
    $env:DANNY_SKILLS_TEST_PYTHON = $python.Path
    if (-not $LogDirectory) { $LogDirectory = Join-Path $repo ('.dt-build/gates/' + [guid]::NewGuid().ToString('N')) }
    $LogDirectory = [IO.Path]::GetFullPath($LogDirectory)
    New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
    Write-Output "Gate logs: $LogDirectory"
    $pending = [Collections.Generic.Queue[object]]::new()
    foreach ($step in $steps) { $pending.Enqueue($step) }
    $running = [Collections.Generic.List[object]]::new()
    $results = [Collections.Generic.List[object]]::new()
    try {
        while ($pending.Count -or $running.Count) {
            while ($pending.Count -and $running.Count -lt $ThrottleLimit) {
                $occupied = 0
                foreach ($job in $running) { $occupied += $job.Slots }
                $next = $pending.Peek()
                $slots = if ($next.ContainsKey('Slots')) { [Math]::Min([int]$next.Slots,$ThrottleLimit) } else { 1 }
                if ($occupied + $slots -gt $ThrottleLimit) { break }
                $step = $pending.Dequeue()
                if ($step.ContainsKey('Slots') -and $step.Slots -gt $ThrottleLimit) { $step.Command += ' -Serial'; $slots = 1 }
                $out = Join-Path $LogDirectory ($step.Name + '.log')
                $err = Join-Path $LogDirectory ($step.Name + '.stderr.log')
                $code = "`$ErrorActionPreference = 'Stop'; try { $($step.Command) } catch { Write-Error `$_ -ErrorAction Continue; exit 1 }"
                $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
                $timer = [Diagnostics.Stopwatch]::StartNew()
                $process = Start-Process -FilePath (Join-Path $PSHOME 'pwsh') -ArgumentList @('-NoProfile','-NonInteractive','-EncodedCommand',$encoded) -WorkingDirectory $repo -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
                $running.Add(@{ Name=$step.Name; Process=$process; Timer=$timer; Log=$out; ErrorLog=$err; Slots=$slots })
            }
            foreach ($job in @($running.ToArray())) {
                if (-not $job.Process.HasExited) { continue }
                $job.Process.WaitForExit()
                $job.Timer.Stop()
                $result = [pscustomobject]@{ name=$job.Name; seconds=[Math]::Round($job.Timer.Elapsed.TotalSeconds,3); exit_code=$job.Process.ExitCode; log=$job.Log; error_log=$job.ErrorLog }
                $results.Add($result)
                Write-Output ('{0}: {1} ({2:N2}s)' -f $result.name, $(if ($result.exit_code -eq 0) {'PASS'} else {'FAIL'}), $result.seconds)
                $job.Process.Dispose()
                $null = $running.Remove($job)
            }
            if ($running.Count) { Start-Sleep -Milliseconds 50 }
        }
    }
    finally {
        foreach ($job in $running) {
            if (-not $job.Process.HasExited) { $job.Process.Kill($true); $job.Process.WaitForExit() }
            $job.Process.Dispose()
        }
    }
    $wall.Stop()
    $ordered = @($results | Sort-Object seconds -Descending)
    $summary = [ordered]@{ finished_et=[TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow,'America/New_York').ToString('yyyy-MM-dd HH:mm:ss') + ' ET'; seconds=[Math]::Round($wall.Elapsed.TotalSeconds,3); steps=$ordered }
    $summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $LogDirectory 'timings.json')
    Write-Output "Gate wall time: $($summary.seconds)s; slowest: $($ordered[0].name) $($ordered[0].seconds)s"
    $failures = @($results | Where-Object exit_code -ne 0)
    foreach ($failure in $failures) {
        Write-Output "FAILED: $($failure.name) (exit $($failure.exit_code)); full output: $($failure.log); stderr: $($failure.error_log)"
        foreach ($log in @($failure.log, $failure.error_log)) {
            Write-Output "--- $log ---"
            Get-Content -LiteralPath $log -Tail 40 | Write-Output
        }
    }
    if ($failures.Count) { exit 1 }
    exit 0
}
finally { Pop-Location }
