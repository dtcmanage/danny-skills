param(
    [Parameter(Mandatory)]
    [string]$ProjectPath,
    [Parameter(Mandatory)]
    [int]$Round,
    [Parameter(Mandatory)]
    [string]$PromptPath,
    [string]$Model = "gpt-5.3-codex",
    [ValidateSet('minimal', 'low', 'medium', 'high')]
    [string]$ReasoningEffort,
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
$scratchDir = Join-Path $ProjectPath 'design\_review'
New-Item -ItemType Directory -Path $designDir -Force | Out-Null
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null

$reviewPath = Join-Path $scratchDir ("review-v{0}.md" -f $Round)
$streamPath = Join-Path $scratchDir ("codex-stream-v{0}.log" -f $Round)

$promptRaw = Get-Content -LiteralPath $PromptPath -Raw
$envelopedPrompt = New-PromptEnvelope -Label ("DT-REVIEW ROUND V{0}" -f $Round) -Content $promptRaw
$tmpPrompt = Join-Path $env:TEMP ("dt-review-prompt-v{0}-{1}.txt" -f $Round, [guid]::NewGuid().ToString('N'))
Set-Content -LiteralPath $tmpPrompt -Value $envelopedPrompt -Encoding utf8

Push-Location $ProjectPath
try {
    $codexCli = Get-CodexCliPath
    $effortArgs = @()
    if ($ReasoningEffort) { $effortArgs = @('-c', ('model_reasoning_effort="{0}"' -f $ReasoningEffort)) }
    # Feed the prompt to codex over stdin, never as an argv. A round prompt is ~30KB+ and a
    # positional prompt overruns the OS command-line length limit ("Argument list too long"),
    # so codex never receives it and review-v<N>.md is never written. codex exec reads the
    # prompt from stdin when no positional PROMPT arg is given.
    $rawLines = Get-Content -LiteralPath $tmpPrompt -Raw | & $codexCli exec --sandbox read-only --skip-git-repo-check --model $Model @effortArgs --output-last-message $reviewPath 2>&1
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
