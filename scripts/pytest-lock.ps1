param()
# Keep native flags (-c, -v, -q) in $args; advanced parameter binding would
# consume abbreviations/common parameters belonging to the child command.
$forward = @($args)
$lockWaitSec = 1800
$readyFile = $null
while ($forward.Count -ge 2 -and $forward[0] -in @('-TimeoutSec', '--timeout', '-ReadyFile', '--ready-file')) {
    if ($forward[0] -in @('-TimeoutSec','--timeout')) { $lockWaitSec = [int]$forward[1] }
    else { $readyFile = [string]$forward[1] }
    $forward = @($forward | Select-Object -Skip 2)
}
if ($forward.Count -eq 0) { throw 'PYTEST_LOCK_USAGE: supply an executable and its arguments.' }
# All callers use the same Python OS lock, including Git Bash and sandbox children.
$lockArgs = @('--timeout', [string]$lockWaitSec)
if ($readyFile) { $lockArgs += @('--ready-file', $readyFile) }
& python (Join-Path $PSScriptRoot 'pytest-lock.py') @lockArgs -- @forward
exit $LASTEXITCODE
