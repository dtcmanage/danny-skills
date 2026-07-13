[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectPath,

    [string]$Model = 'gpt-5.6-luna',

    [ValidateSet('complex', 'light')]
    [string]$Tier = 'light',

    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max', 'ultra')]
    [string]$ReasoningEffort = 'low',

    [ValidateRange(1000, 300000)]
    [int]$TimeoutMs = 30000,

    [string]$CodexCliPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-CodexCliPath {
    foreach ($name in @('codex.cmd', 'codex.exe', 'codex.ps1')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and $cmd.CommandType -in @('Application', 'ExternalScript')) {
            return $cmd.Source
        }
    }
    throw 'Unable to locate codex CLI executable (codex.cmd/codex.exe/codex.ps1).'
}

if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
    throw "Project path not found: $ProjectPath"
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SkillRoot = Split-Path -Parent $ScriptDir
$original = (Resolve-Path -LiteralPath $SkillRoot).Path
$cursor = Get-Item -LiteralPath $original
while ($null -ne $cursor) {
    $resolved = $null
    try { $resolved = $cursor.ResolveLinkTarget($true) } catch { }
    if ($resolved) {
        $suffix = [System.IO.Path]::GetRelativePath($cursor.FullName, $original)
        $SkillRoot = if ($suffix -eq '.') { $resolved.FullName } else { Join-Path $resolved.FullName $suffix }
        break
    }
    $cursor = $cursor.Parent
}
$RepoRoot = Split-Path -Parent (Split-Path -Parent $SkillRoot)
. (Join-Path $RepoRoot 'scripts\resolve-codex-model.ps1')
. (Join-Path $RepoRoot 'scripts\invoke-codex-process.ps1')

$projectRoot = (Resolve-Path -LiteralPath $ProjectPath).Path
$executionDir = Join-Path $env:TEMP ("dt-review-preflight-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $executionDir -Force | Out-Null

Push-Location $executionDir
try {
    $msg = 'Reply with the single word OK and nothing else'
    $codexCli = if ([string]::IsNullOrWhiteSpace($CodexCliPath)) { Get-CodexCliPath } else { $CodexCliPath }
    $versionResult = Invoke-CodexProcess -CodexPath $codexCli -Arguments @('--version') -Prompt '' -WorkingDirectory $executionDir -TimeoutMs 10000
    $helpResult = Invoke-CodexProcess -CodexPath $codexCli -Arguments @('exec', '--help') -Prompt '' -WorkingDirectory $executionDir -TimeoutMs 10000
    $versionText = ($versionResult.stdout + $versionResult.stderr).Trim()
    $helpText = $helpResult.stdout + $helpResult.stderr
    if ($versionResult.exit_code -ne 0 -or $helpResult.exit_code -ne 0 -or $helpText -notmatch '--output-schema' -or $helpText -notmatch '--ephemeral' -or $helpText -notmatch '--ignore-user-config') {
        throw "Codex CLI lacks required dt-review capabilities (--output-schema, --ephemeral, --ignore-user-config). Detected: $versionText"
    }
    $catalogResult = Invoke-CodexProcess -CodexPath $codexCli -Arguments @('debug', 'models') -Prompt '' -WorkingDirectory $executionDir -TimeoutMs 15000
    if ($catalogResult.exit_code -ne 0 -or $catalogResult.timed_out) {
        throw "Codex model catalog refresh failed; cannot verify current account availability. Detected: $versionText"
    }
    $Model = Resolve-CodexModel -Tier $Tier -PreferredModel $Model -Strict
    [void](Assert-CodexReasoningEffort -Model $Model -Effort $ReasoningEffort -Strict)
    $arguments = @(
        '-a', 'never',
        '-c', 'forced_login_method="chatgpt"',
        '-c', 'project_doc_max_bytes=0',
        'exec',
        '--ignore-user-config',
        '--sandbox', 'read-only',
        '--skip-git-repo-check',
        '--ephemeral',
        '--color', 'never',
        '--model', $Model,
        '-c', ('model_reasoning_effort="{0}"' -f $ReasoningEffort),
        '-'
    )
    $processResult = Invoke-CodexProcess `
        -CodexPath $codexCli `
        -Arguments $arguments `
        -Prompt $msg `
        -WorkingDirectory $executionDir `
        -TimeoutMs $TimeoutMs
    $joined = $processResult.stdout + $processResult.stderr
    if ($processResult.timed_out) {
        throw "Preflight exceeded the enforced $TimeoutMs ms timeout for model '$Model'."
    }
    if ($processResult.exit_code -ne 0) {
        throw "Preflight failed for model '$Model' with exit code $($processResult.exit_code). Raw output:`n$joined"
    }
    if ($joined -notmatch '(?m)^OK\s*$') {
        throw "Preflight failed for model '$Model': expected single-word OK response. Raw output:`n$joined"
    }
    [pscustomobject]@{
        status = 'ok'
        cli = $versionText.Trim()
        model = $Model
        reasoning_effort = $ReasoningEffort
        duration_ms = $processResult.duration_ms
    } | ConvertTo-Json -Compress
}
finally {
    Pop-Location
    Remove-CodexTempDirectory -Path $executionDir -ExpectedLeafPrefix 'dt-review-preflight-'
}
