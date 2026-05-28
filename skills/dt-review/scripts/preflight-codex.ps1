param(
    [Parameter(Mandatory)]
    [string]$ProjectPath,
    [string]$Model = "gpt-5.3-codex",
    [ValidateSet('complex', 'light')]
    [string]$Tier = "light",
    [ValidateSet('minimal', 'low', 'medium', 'high')]
    [string]$ReasoningEffort = "medium",
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

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SkillRoot = Split-Path -Parent $ScriptDir
$resolved = (Get-Item -LiteralPath $SkillRoot).ResolveLinkTarget($true)
if ($resolved) { $SkillRoot = $resolved.FullName }
$RepoRoot = Split-Path -Parent (Split-Path -Parent $SkillRoot)
. (Join-Path $RepoRoot 'scripts\resolve-codex-model.ps1')

# Self-heal the pin against Codex's live per-account model cache before spending the
# 30s preflight budget on a model that is no longer selectable.
$Model = Resolve-CodexModel -Tier $Tier -PreferredModel $Model

Push-Location $ProjectPath
try {
    $msg = "Reply with the single word OK and nothing else"
    $codexCli = Get-CodexCliPath
    $effortArgs = @('-c', ('model_reasoning_effort="{0}"' -f $ReasoningEffort))
    # Prompt over stdin (see invoke-codex-round.ps1); -ReasoningEffort overrides the global
    # model_reasoning_effort=high so the sanity check is not a full deep-reasoning pass.
    $result = $msg | & $codexCli exec --sandbox read-only --skip-git-repo-check --model $Model @effortArgs 2>&1
    $joined = ($result -join "`n")
    if ($joined -notmatch '(?m)^OK\s*$') {
        throw "Pre-flight failed for model '$Model': expected single-word OK response. Raw output:`n$joined"
    }
    Write-Warning "Preflight OK on model: $Model"
    Write-Output "OK"
}
finally {
    Pop-Location
}
