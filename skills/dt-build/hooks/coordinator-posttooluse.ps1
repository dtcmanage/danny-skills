#Requires -Version 7.0
# Claude PostToolUse hook for dt-build coordinator sessions; installed only at adoption (see README.md).
# Surfaces the context line as additional context when the coordinator reaches checkpoint or rotate;
# silent when the state is ok and for every non-coordinator session. Any error is silent.
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'coordinator-pretooluse.ps1')

try {
    $hookInput = Read-HookInput
    if ($null -eq $hookInput) { exit 0 }
    $coordinator = Find-HookCoordinator -HookInput $hookInput
    if ($null -eq $coordinator) { exit 0 }
    $context = Get-HookContext -Coordinator $coordinator -HookInput $hookInput
    if (@('checkpoint', 'rotate') -notcontains $context.state) { exit 0 }
    $runFolder = if ($coordinator.run_folder) { $coordinator.run_folder } else { '<run folder>' }
    $next = if ($context.state -eq 'checkpoint') {
        'Soft limit reached: finish the current decision and write _build-state.md before taking on more.'
    }
    elseif ($context.deferred) {
        'Hard limit reached; rotation waits for the open irreversible step. Finish it, run dt-job irreversible -Action end, then rotate.'
    }
    else {
        "Hard limit reached: write _build-state.md and the coordinator handoff, run pwsh -NoProfile -File `"$($script:HookDtJob)`" request-continuation -RunFolder `"$runFolder`" -Reason context_rotation, release the lease, and end the turn."
    }
    [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PostToolUse'; additionalContext = "$($context.line). $next" } } | ConvertTo-Json -Depth 4 -Compress
    exit 0
}
catch { exit 0 }
