#Requires -Version 7.0
# Fixtures only: fake worker CLIs that leave a grandchild behind. Each case runs in its own pwsh, because
# joining the job object is permanent for the joining process.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:passed = 0
function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "ASSERT_FAIL: $Message" }
    $script:passed++; Write-Output "PASS: $Message"
}
$scripts = Split-Path -Parent $PSScriptRoot
$root = Join-Path ([IO.Path]::GetTempPath()) ('worker-tree-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)

# A fake CLI: prints a line, optionally starts a grandchild that sleeps (holding the inherited output
# pipes, or detached from them), records the grandchild's pid, and exits at once.
$fake = Join-Path $root 'fake-cli.ps1'
[IO.File]::WriteAllText($fake, @'
param([string]$Mode, [string]$PidFile)
Write-Output 'worker final message'
if ($Mode -ne 'clean') {
    $info = [Diagnostics.ProcessStartInfo]::new('pwsh')
    foreach ($a in @('-NoProfile', '-Command', 'Start-Sleep -Seconds 300')) { $info.ArgumentList.Add($a) }
    $info.UseShellExecute = $false
    # Shell-execute inherits no handles, so this grandchild holds none of the worker's pipes.
    if ($Mode -eq 'detached') { $info.UseShellExecute = $true; $info.WindowStyle = 'Hidden' }
    $child = [Diagnostics.Process]::Start($info)
    [IO.File]::WriteAllText($PidFile, [string]$child.Id)
}
exit 0
'@, $utf8)

# The harness mirrors the wrappers: join the job, start the CLI with redirected pipes, wait for exit,
# then complete the dispatch with a short grace.
$harness = Join-Path $root 'harness.ps1'
[IO.File]::WriteAllText($harness, @'
param([string]$Helper, [string]$Fake, [string]$Mode, [string]$PidFile)
. $Helper
$null = Initialize-WorkerProcessJob
$info = [Diagnostics.ProcessStartInfo]::new('pwsh')
foreach ($a in @('-NoProfile', '-File', $Fake, '-Mode', $Mode, '-PidFile', $PidFile)) { $info.ArgumentList.Add($a) }
$info.UseShellExecute = $false; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true; $info.RedirectStandardInput = $true
$proc = [Diagnostics.Process]::Start($info)
$out = $proc.StandardOutput.ReadToEndAsync(); $err = $proc.StandardError.ReadToEndAsync()
$proc.StandardInput.Close()
while (-not $proc.HasExited) { Start-Sleep -Milliseconds 50 }
$watch = [Diagnostics.Stopwatch]::StartNew()
$done = Complete-WorkerDispatch -OutputTasks @($out, $err) -GraceMs 3000
[ordered]@{ exit_code = $proc.ExitCode; seconds = [Math]::Round($watch.Elapsed.TotalSeconds, 1); stdout = $done.stdout; drained = $done.streams_drained; custody = $done.custody; stopped = @($done.orphans_stopped | ForEach-Object pid) } | ConvertTo-Json -Compress
'@, $utf8)

function Invoke-Case([string]$Mode) {
    $pidFile = Join-Path $root "$Mode.pid"
    $raw = & pwsh -NoProfile -File $harness -Helper (Join-Path $scripts 'worker-process-tree.ps1') -Fake $fake -Mode $Mode -PidFile $pidFile 2>&1
    $result = ($raw | Select-Object -Last 1) | ConvertFrom-Json
    $grandchild = if (Test-Path $pidFile) { [int](Get-Content -Raw $pidFile) } else { 0 }
    $alive = $grandchild -and [bool](Get-Process -Id $grandchild -ErrorAction SilentlyContinue)
    return [pscustomobject]@{ result = $result; grandchild = $grandchild; alive = $alive; raw = ($raw -join ' ') }
}

try {
    if (-not $IsWindows) { Write-Output 'SKIP: job-object custody is Windows-only'; Write-Output 'SUMMARY: 0 passed'; return }
    $clean = Invoke-Case 'clean'
    Assert-True ($clean.result.custody -eq 'job_object') "the wrapper joins a job object ($($clean.raw))"
    Assert-True ($clean.result.drained -and $clean.result.stdout -match 'worker final message' -and @($clean.result.stopped).Count -eq 0) 'a worker that leaves nothing behind drains fully and stops nothing'
    Assert-True ($clean.result.seconds -lt 3) "a clean dispatch completes without waiting out the grace ($($clean.result.seconds)s)"

    $held = Invoke-Case 'held'
    Assert-True ($held.grandchild -gt 0 -and $held.result.stopped -contains $held.grandchild) "an orphan holding the output pipes is stopped ($($held.raw))"
    Assert-True ($held.result.drained -and $held.result.stdout -match 'worker final message') 'the worker output is kept after the orphan is stopped'
    Assert-True ($held.result.seconds -lt 20) "the drain is bounded, not waited out ($($held.result.seconds)s)"
    Assert-True (-not $held.alive) 'the orphan is gone afterwards'

    $detached = Invoke-Case 'detached'
    Assert-True ($detached.grandchild -gt 0 -and $detached.result.stopped -contains $detached.grandchild -and -not $detached.alive) "an orphan detached from the pipes is swept too ($($detached.raw))"
    Assert-True ($detached.result.seconds -lt 3) "sweeping a detached orphan costs no grace wait ($($detached.result.seconds)s)"

    # Both wrappers use the helper and record custody in provenance.
    foreach ($wrapper in @('invoke-codex-chunk.ps1', 'invoke-claude-chunk.ps1')) {
        $text = Get-Content -Raw (Join-Path $scripts $wrapper)
        Assert-True ($text.Contains("worker-process-tree.ps1") -and $text.Contains('Initialize-WorkerProcessJob') -and $text.Contains('Complete-WorkerDispatch') -and $text.Contains('orphans_stopped') -and -not ($text -match '\$stdoutTask\.GetAwaiter\(\)\.GetResult\(\)')) "$wrapper drains through the bounded helper and records orphans"
    }
    Write-Output "SUMMARY: $script:passed passed"
}
finally {
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Filter '*.pid' -ErrorAction SilentlyContinue)) {
        try { Stop-Process -Id ([int](Get-Content -Raw $file.FullName)) -Force -ErrorAction SilentlyContinue } catch { }
    }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
