param(
    [Parameter(Mandatory)]
    [string]$ProjectPath,
    [string]$Model = "gpt-5.3-codex",
    [ValidateSet('minimal', 'low', 'medium', 'high')]
    [string]$ReasoningEffort = "low",
    [int]$TimeoutMs = 30000
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-CodexCliPath {
    $candidates = Get-Command codex.cmd, codex.exe, codex.ps1 -ErrorAction SilentlyContinue
    foreach ($cmd in $candidates) {
        if ($cmd -and $cmd.CommandType -in @('Application', 'ExternalScript')) {
            return $cmd.Source
        }
    }
    throw "Unable to locate codex CLI executable (codex.cmd/codex.exe/codex.ps1)."
}

if (-not (Test-Path -LiteralPath $ProjectPath)) {
    throw "Project path not found: $ProjectPath"
}

Push-Location $ProjectPath
try {
    $msg = "Reply with the single word OK and nothing else"
    $codexCli = Get-CodexCliPath
    $effortArgs = @('-c', ('model_reasoning_effort="{0}"' -f $ReasoningEffort))
    # Prompt over stdin (see invoke-codex-round.ps1) and low reasoning effort so the
    # sanity check returns inside the 30s budget instead of burning a deep-reasoning pass.
    $result = $msg | & $codexCli exec --sandbox read-only --skip-git-repo-check --model $Model @effortArgs 2>&1
    $joined = ($result -join "`n")
    if ($joined -notmatch '(?m)^OK\s*$') {
        throw "Pre-flight failed: expected single-word OK response. Raw output:`n$joined"
    }
    Write-Output "OK"
}
finally {
    Pop-Location
}
