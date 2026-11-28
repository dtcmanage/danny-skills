Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../../../scripts/lib/runtime-test-admission.ps1')
Enter-RuntimeTestSuite
$scripts = Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts 'dt-job.ps1')
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'dt-job-runner.ps1'), [ref]$tokens, [ref]$parseErrors)
$function = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Wait-DtJobProcess'}, $true)
. ([scriptblock]::Create($function.Extent.Text))
function Get-DtJobTreeMemoryGB { return $null }
function Get-DtJobTreeCpuSeconds { return 0 }
$root = Join-Path ([IO.Path]::GetTempPath()) ('heartbeat-test-' + [guid]::NewGuid().ToString('N'))
$env:DT_JOB_HEARTBEAT_SEC = '1'; $env:DT_JOB_STALL_SEC = '8'
try {
    foreach ($case in @('worktree','logs','run-state','reader-worktree','sibling-log')) {
        $JobId = $case
        $paths = @{Root="$root/$case/run"}
        $jobDir = "$($paths.Root)/jobs/j-0001"
        $tree = "$root/$case/tree"
        New-Item -ItemType Directory "$jobDir/logs", $tree -Force | Out-Null
        $target = switch ($case) { worktree { "$tree/code.py" } logs { "$jobDir/logs/test.log" } reader-worktree { "$tree/unowned.py" } sibling-log { "$($paths.Root)/jobs/j-9999/logs/test.log" } default { "$($paths.Root)/unrelated.json" } }
        New-Item -ItemType Directory (Split-Path -Parent $target) -Force | Out-Null
        $payload = '1..8 | ForEach-Object { Start-Sleep 1; [IO.File]::AppendAllText(' + "'" + $target.Replace("'","''") + "', 'changed') }"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payload))
        $child = Start-Process pwsh -ArgumentList @('-NoProfile','-EncodedCommand',$encoded) -PassThru
        $out = [IO.File]::Open("$jobDir/stdout.log",'Create','ReadWrite','ReadWrite')
        $err = [IO.File]::Open("$jobDir/stderr.log",'Create','ReadWrite','ReadWrite')
        try {
            $done = Wait-DtJobProcess -Process $child -TimeoutSec 0 -WorkDir $tree -Outputs @($out,$err) -Writes ($case -eq 'worktree')
            $beat = Get-Content "$jobDir/heartbeat.json" -Raw | ConvertFrom-Json -DateKind String
            $idle = ([DateTime]::UtcNow - [DateTime]::Parse($beat.last_activity_utc).ToUniversalTime()).TotalSeconds
            $progressExpected = $case -in @('worktree','logs')
            if (-not $done -or ($progressExpected -and ($beat.file_changes -lt 2 -or $idle -gt 4 -or $idle -lt 0)) -or (-not $progressExpected -and ($beat.file_changes -ne 0 -or $idle -lt 6))) { throw "heartbeat attribution failed: $case changes=$($beat.file_changes) idle=$idle" }
            "PASS: heartbeat attribution $case changes=$($beat.file_changes) idle=$([Math]::Round($idle,1))"
        } finally {
            if (-not $child.HasExited) { $child.Kill($true); $child.WaitForExit() }
            $child.Dispose(); $out.Dispose(); $err.Dispose()
        }
    }
    if (-not $IsWindows) {
        . (Join-Path $scripts 'toolbox-path.ps1')
        $env:PATH = '/usr/bin:/bin'
        Enable-DtBuildToolboxPath
        $python = (Get-Command python3 -CommandType Application | Select-Object -First 1).Source
        & $python -c 'import pytest,sys; print(sys.executable)'
        if ($LASTEXITCODE -ne 0 -or $python -notlike '*/workspace-python/bin/python3') { throw 'toolbox python not selected' }
        'PASS: headless PATH selects shared toolbox with pytest'
        # Exercise the real runner too: its persisted spec restores this
        # system-only PATH after the runner itself has already bootstrapped.
        $env:PATH = '/usr/bin:/bin'
        $env:DT_BUILD_STATE_DIR = "$root/registry"
        $env:DT_BUILD_HEADLESS = '1'
        $rf = "$root/toolbox-run"
        New-Item -ItemType Directory $rf | Out-Null
        $raw = & pwsh -NoProfile -File (Join-Path $scripts 'dt-job.ps1') start -RunFolder $rf -Command 'python3 -c "import pytest,sys; print(sys.executable)"' -AllowTempRunFolder -Json
        if ($LASTEXITCODE) { throw 'toolbox job did not start' }
        $ownedJob = $raw -join "`n" | ConvertFrom-Json
        try {
            $waitRaw = & pwsh -NoProfile -File (Join-Path $scripts 'dt-job.ps1') wait -RunFolder $rf -JobId $ownedJob.job_id -TimeoutSec 120 -AllowTempRunFolder -Json
            if ($LASTEXITCODE) { throw 'toolbox job wait failed' }
            $waitResult = $waitRaw -join "`n" | ConvertFrom-Json
            $completed = @($waitResult.jobs | Where-Object job_id -eq $ownedJob.job_id)
            if ($completed.Count -ne 1 -or $completed[0].status -ne 'succeeded' -or $completed[0].exit_code -ne 0) { throw 'toolbox job did not succeed' }
            # wait exposes the persisted output_path as an evidence path string;
            # observe/status uses a different evidence object.
            $stdout = Join-Path $rf "jobs/$($ownedJob.job_id)/stdout.log"
            if ($waitResult.result -ne 'finished' -or $completed[0].evidence -isnot [string] -or $completed[0].evidence -cne $stdout) { throw 'toolbox wait did not identify the owned stdout log' }
            $output = Get-Content -LiteralPath $stdout -Raw
            if ($output -notmatch '/workspace-python/bin/python3') { throw "real runner missed toolbox: $output" }
            'PASS: real runner repairs persisted system-only PATH and imports pytest'
        } finally {
            & pwsh -NoProfile -File (Join-Path $scripts 'dt-job.ps1') cancel -RunFolder $rf -JobId $ownedJob.job_id -AllowTempRunFolder -Json | Out-Null
        }
    }
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
