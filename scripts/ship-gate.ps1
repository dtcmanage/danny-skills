# The .ship.json caller owns the explicit machine pytest lock around this gate.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$checks = @(
    @('scripts/verify-versioning-policy.ps1','-BaseRef','auto'),
    @('scripts/test-versioning-policy.ps1'),
    @('skills/dt-review/tests/run-tests.ps1'),
    @('skills/dt-review/tests/run-final-draft-tests.ps1'),
    @('skills/dt-build/scripts/tests/test-host-adapters.ps1'),
    @('skills/dt-build/scripts/tests/test-context-guard.ps1'),
    @('skills/dt-build/scripts/tests/test-dt-job.ps1'),
    @('skills/dt-build/scripts/test-dt-build-regressions.ps1'),
    @('tools/build-plugin.ps1','-BaseRef','auto','-ValidateOnly')
)
foreach ($check in $checks) {
    & pwsh -NoProfile -File @check
    if ($LASTEXITCODE -ne 0) { exit 1 }
}
exit 0
