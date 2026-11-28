function Test-OperatorFixtureAutomationCaller {
    # Use the production ancestry check in a local scope, before fixtures clear
    # environment tags or replace the registry. This never grants authority.
    . (Join-Path $PSScriptRoot '../dt-job.ps1')
    return (Test-DtJobAutomationCaller)
}
