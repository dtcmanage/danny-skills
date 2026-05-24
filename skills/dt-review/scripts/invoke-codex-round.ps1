param(
    [Parameter(Mandatory)]
    [string]$ProjectPath,
    [Parameter(Mandatory)]
    [int]$Round,
    [Parameter(Mandatory)]
    [string]$PromptPath,
    [string]$Model = "gpt-5.3-codex",
    [int]$TimeoutMs = 1800000
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not (Test-Path -LiteralPath $ProjectPath)) {
    throw "Project path not found: $ProjectPath"
}
if (-not (Test-Path -LiteralPath $PromptPath)) {
    throw "Prompt path not found: $PromptPath"
}

function Get-CodexCliPath {
    $candidates = Get-Command codex.cmd, codex.exe, codex.ps1 -ErrorAction SilentlyContinue
    foreach ($cmd in $candidates) {
        if ($cmd -and $cmd.CommandType -in @('Application', 'ExternalScript')) {
            return $cmd.Source
        }
    }
    throw "Unable to locate codex CLI executable (codex.cmd/codex.exe/codex.ps1)."
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SkillRoot = Split-Path -Parent $ScriptDir
$resolved = (Get-Item -LiteralPath $SkillRoot).ResolveLinkTarget($true)
if ($resolved) { $SkillRoot = $resolved.FullName }
$RepoRoot = Split-Path -Parent (Split-Path -Parent $SkillRoot)

. (Join-Path $RepoRoot 'scripts\security\redact-secrets.ps1')
. (Join-Path $RepoRoot 'scripts\wrap-prompt-envelope.ps1')

$designDir = Join-Path $ProjectPath 'design'
New-Item -ItemType Directory -Path $designDir -Force | Out-Null

$reviewPath = Join-Path $designDir ("review-v{0}.md" -f $Round)
$streamPath = Join-Path $designDir ("codex-stream-v{0}.log" -f $Round)

$promptRaw = Get-Content -LiteralPath $PromptPath -Raw
$envelopedPrompt = New-PromptEnvelope -Label ("DT-REVIEW ROUND V{0}" -f $Round) -Content $promptRaw
$tmpPrompt = Join-Path $env:TEMP ("dt-review-prompt-v{0}-{1}.txt" -f $Round, [guid]::NewGuid().ToString('N'))
Set-Content -LiteralPath $tmpPrompt -Value $envelopedPrompt -Encoding utf8

Push-Location $ProjectPath
try {
    $codexCli = Get-CodexCliPath
    $rawLines = & $codexCli exec --sandbox read-only --skip-git-repo-check --model $Model --output-last-message $reviewPath -- "$(Get-Content -LiteralPath $tmpPrompt -Raw)" 2>&1
    $rawText = ($rawLines -join "`n")
    $redacted = Invoke-SecretRedaction -Text $rawText
    Set-Content -LiteralPath $streamPath -Value $redacted -Encoding utf8

    $provJson = & (Join-Path $ScriptDir 'capture-provenance.ps1') -PromptPath $PromptPath -CanonicalPath (Resolve-Path -LiteralPath $ProjectPath).Path
    [pscustomobject]@{
        round = $Round
        feedback_path = $reviewPath
        stream_path = $streamPath
        provenance = ($provJson | ConvertFrom-Json)
    } | ConvertTo-Json -Depth 6 -Compress
}
finally {
    Pop-Location
    if (Test-Path -LiteralPath $tmpPrompt) {
        Remove-Item -LiteralPath $tmpPrompt -Force
    }
}
