param()
# Keep native flags (-c, -v, -q) in $args; advanced parameter binding would
# consume abbreviations/common parameters belonging to the child command.
$forward = @($args)
$lockWaitSec = 1800
if ($forward.Count -ge 2 -and $forward[0] -in @('-TimeoutSec', '--timeout')) {
    $lockWaitSec = [int]$forward[1]
    $forward = @($forward | Select-Object -Skip 2)
}
if ($forward.Count -eq 0) { throw 'PYTEST_LOCK_USAGE: supply an executable and its arguments.' }
# All callers use the same Python OS lock, including Git Bash and sandbox children.
& python (Join-Path $PSScriptRoot 'pytest-lock.py') --timeout $lockWaitSec -- @forward
exit $LASTEXITCODE
