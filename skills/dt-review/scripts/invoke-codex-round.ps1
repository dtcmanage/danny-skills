[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectPath,

    [Parameter(Mandatory)]
    [ValidateRange(1, 99)]
    [int]$Round,

    [Parameter(Mandatory)]
    [string]$PromptPath,

    [string]$Model = 'gpt-5.6-terra',

    [ValidateSet('complex', 'light')]
    [string]$Tier = 'light',

    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max', 'ultra')]
    [string]$ReasoningEffort = 'medium',

    [ValidateRange(1000, 3600000)]
    [int]$TimeoutMs = 300000,

    # Required whenever the effort deviates from the tier default (complex=high, light=medium):
    # a one-line recorded reason, persisted in round metadata.
    [string]$EffortReason = '',

    [string]$CodexCliPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-CodexCliPath {
    # Prefer the npm shim on Danny's host: it tracks the current CLI release,
    # while a separate WinGet codex.exe may lag behind.
    foreach ($name in @('codex.cmd', 'codex.exe', 'codex.ps1')) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd -and $cmd.CommandType -in @('Application', 'ExternalScript')) {
            return $cmd.Source
        }
    }
    throw 'Unable to locate codex CLI executable (codex.cmd/codex.exe/codex.ps1).'
}

function Write-Atomic([string]$Path, [string]$Content) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = Join-Path $dir ((Split-Path -Leaf $Path) + '.tmp.' + $PID)
    [System.IO.File]::WriteAllText($tmp, $Content, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

. (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'render-review-markdown.ps1')


if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
    throw "Project path not found: $ProjectPath"
}
if (-not (Test-Path -LiteralPath $PromptPath -PathType Leaf)) {
    throw "Prompt path not found: $PromptPath"
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

. (Join-Path $ScriptDir 'round-transition.ps1')
$transition = Get-DtReviewRoundTransition `
    -ProjectPath $ProjectPath `
    -Round $Round `
    -Tier $Tier `
    -EvaluatorPath (Join-Path $ScriptDir 'evaluate-termination.ps1')
$authorizationPath = Join-Path (Join-Path (Resolve-Path -LiteralPath $ProjectPath).Path 'design\_review') 'round-authorizations.json'
Assert-DtReviewRoundAuthorization -Transition $transition -AuthorizationPath $authorizationPath
if ([string]$transition.mode -eq 'SAME_ROUND_RERUN') {
    throw "Round $Round already exists in review state. Reviewer replay is refused; recovery may only reparse the identical existing structured artifact."
}

. (Join-Path $RepoRoot 'scripts\security\redact-secrets.ps1')
. (Join-Path $RepoRoot 'scripts\resolve-codex-model.ps1')
. (Join-Path $RepoRoot 'scripts\invoke-codex-process.ps1')
. (Join-Path $ScriptDir 'validate-review-semantics.ps1')
. (Join-Path $ScriptDir 'invocation-receipt.ps1')

$schemaPath = Join-Path $SkillRoot 'references\review-output-schema.json'
if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
    throw "Review output schema not found: $schemaPath"
}

$RequestedModel = $Model
$Model = Resolve-CodexModel -Tier $Tier -PreferredModel $Model -Strict
[void](Assert-CodexReasoningEffort -Model $Model -Effort $ReasoningEffort -Strict)
# Complex rounds 1-2 are the full critique at high effort; rounds 3+ are verification rounds and
# run at medium. A high-effort critic re-reading the whole draft every round manufactured findings
# inside machinery it had itself requested (audit 2026-09-06).
$tierDefaultEffort = if ($Tier -eq 'complex' -and $Round -le 2) { 'high' } else { 'medium' }
if ($ReasoningEffort -cne $tierDefaultEffort -and [string]::IsNullOrWhiteSpace($EffortReason)) {
    throw "Effort '$ReasoningEffort' deviates from the $Tier-tier default '$tierDefaultEffort'. Record the reason with -EffortReason."
}
$projectRoot = (Resolve-Path -LiteralPath $ProjectPath).Path
$scratchDir = Join-Path $projectRoot 'design\_review'
New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
$inputReceipt = Get-DtReviewInvocationReceipt `
    -ProjectPath $projectRoot `
    -Round $Round `
    -Tier $Tier `
    -PromptPath $PromptPath `
    -AssemblerPath (Join-Path $ScriptDir 'assemble-review-prompt.ps1')
$PromptPath = [string]$inputReceipt.prompt_path
$draftPath = [string]$inputReceipt.draft_path
$draftResolvedPath = $draftPath
$draftSha256 = [string]$inputReceipt.draft_sha256

$reviewPath = Join-Path $scratchDir ("review-v{0}.md" -f $Round)
$reviewJsonPath = Join-Path $scratchDir ("review-v{0}.json" -f $Round)
$streamPath = Join-Path $scratchDir ("codex-stream-v{0}.log" -f $Round)
$metadataPath = Join-Path $scratchDir ("round-meta-v{0}.json" -f $Round)
$tmpJson = Join-Path $scratchDir ("review-v{0}.tmp.{1}.json" -f $Round, [guid]::NewGuid().ToString('N'))
$executionDir = Join-Path $env:TEMP ("dt-review-exec-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $executionDir -Force | Out-Null

$promptRaw = Get-Content -LiteralPath $PromptPath -Raw
$redactedPrompt = Invoke-SecretRedaction -Text $promptRaw
if ($redactedPrompt -cne $promptRaw) {
    throw 'SECURITY_SECRET_PATTERN: the assembled review prompt contains a credential-shaped value. Remove or replace it before invoking Codex.'
}

Push-Location $executionDir
try {
    $codexCli = if ([string]::IsNullOrWhiteSpace($CodexCliPath)) { Get-CodexCliPath } else { $CodexCliPath }
    $cliVersionResult = Invoke-CodexProcess -CodexPath $codexCli -Arguments @('--version') -Prompt '' -WorkingDirectory $executionDir -TimeoutMs 10000
    $cliVersion = ($cliVersionResult.stdout + $cliVersionResult.stderr).Trim()
    Assert-DtReviewInvocationReceipt -Receipt $inputReceipt -Round $Round -Tier $Tier
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
        '--output-schema', $schemaPath,
        '--output-last-message', $tmpJson,
        '-'
    )
    $processResult = Invoke-CodexProcess `
        -CodexPath $codexCli `
        -Arguments $arguments `
        -Prompt $promptRaw `
        -WorkingDirectory $executionDir `
        -TimeoutMs $TimeoutMs
    Assert-DtReviewInvocationReceipt -Receipt $inputReceipt -Round $Round -Tier $Tier
    $rawText = ($processResult.stdout + $processResult.stderr)
    Write-Atomic -Path $streamPath -Content (Invoke-SecretRedaction -Text $rawText)

    if ($processResult.timed_out) {
        throw "Codex round $Round exceeded the enforced $TimeoutMs ms timeout. Redacted stream: $streamPath"
    }
    if ($processResult.exit_code -ne 0) {
        throw "Codex round $Round failed with exit code $($processResult.exit_code). Redacted stream: $streamPath"
    }
    if (-not (Test-Path -LiteralPath $tmpJson -PathType Leaf) -or (Get-Item -LiteralPath $tmpJson).Length -eq 0) {
        throw "Codex round $Round exited without a structured review. Redacted stream: $streamPath"
    }

    try {
        $reviewRaw = Get-Content -LiteralPath $tmpJson -Raw
        $review = $reviewRaw | ConvertFrom-Json
    }
    catch {
        throw "Codex round $Round returned invalid structured JSON: $($_.Exception.Message). Redacted stream: $streamPath"
    }

    $statePath = Join-Path $scratchDir 'verdicts.json'
    $priorEntries = @()
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try {
            $priorEntries = @(Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json)
        }
        catch {
            throw "Review state is not valid JSON: $statePath. $($_.Exception.Message)"
        }
    }
    Assert-DtReviewSemanticHistory -Entries $priorEntries
    # Blocking policy runs before validation so the persisted artifact carries normalized values.
    $blockingDowngrades = @(Set-DtReviewBlockingPolicy -Review $review -Round $Round)
    if ($blockingDowngrades.Count -gt 0) { $reviewRaw = ConvertTo-Json -InputObject $review -Depth 10 }
    [void](Assert-DtReviewSemantics -Review $review -Round $Round -PriorEntries $priorEntries)
    $findings = @($review.findings)
    Assert-DtReviewInvocationReceipt -Receipt $inputReceipt -Round $Round -Tier $Tier

    $safeJson = Invoke-SecretRedaction -Text $reviewRaw
    $safeMarkdown = Invoke-SecretRedaction -Text (Convert-ReviewToMarkdown -Review $review)
    if ($blockingDowngrades.Count -gt 0) {
        $safeMarkdown = $safeMarkdown.TrimEnd() + "`n`n## Blocking policy`n" +
            (($blockingDowngrades | ForEach-Object { "- $($_.id) ($($_.severity)): blocks_design set to false. $($_.reason)" }) -join "`n") + "`n"
    }
    Write-Atomic -Path $reviewJsonPath -Content ($safeJson.TrimEnd() + "`n")
    Write-Atomic -Path $reviewPath -Content $safeMarkdown

    $provJson = & (Join-Path $ScriptDir 'capture-provenance.ps1') `
        -PromptPath $PromptPath `
        -CanonicalPath $projectRoot

    $tokenMatch = [regex]::Matches($rawText, '(?is)tokens used\s*:?\s*([\d,]+)') | Select-Object -Last 1
    $tokenUsage = if ($tokenMatch) { [int64](($tokenMatch.Groups[1].Value) -replace ',', '') } else { $null }
    $draftSha256AfterReview = (Get-FileHash -LiteralPath $draftPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($draftSha256AfterReview -cne $draftSha256) {
        throw "Round $Round draft changed while the reviewer was running. Refusing to issue a review receipt for a moving input."
    }
    $metadata = [ordered]@{
        round = $Round
        tier = $Tier
        requested_model = $RequestedModel
        resolved_model = $Model
        reasoning_effort = $ReasoningEffort
        effort_reason = $EffortReason
        blocking_downgrades = @($blockingDowngrades)
        lane = 'codex'
        cli_version = $cliVersion
        duration_ms = $processResult.duration_ms
        token_usage = $tokenUsage
        prompt_bytes = [System.Text.Encoding]::UTF8.GetByteCount($promptRaw)
        prompt_path = [string]$inputReceipt.prompt_path
        prompt_sha256 = [string]$inputReceipt.prompt_sha256
        state_path = [string]$inputReceipt.state_path
        state_sha256 = [string]$inputReceipt.state_sha256
        authorization_path = if ($inputReceipt.authorization_required) { [string]$inputReceipt.authorization_path } else { $null }
        authorization_sha256 = if ($inputReceipt.authorization_required) { [string]$inputReceipt.authorization_sha256 } else { $null }
        review_bytes = [System.Text.Encoding]::UTF8.GetByteCount($safeJson)
        draft_path = $draftResolvedPath
        draft_sha256 = $draftSha256
        provenance = ($provJson | ConvertFrom-Json)
    }
    Write-Atomic -Path $metadataPath -Content (($metadata | ConvertTo-Json -Depth 6) + "`n")

    [pscustomobject]@{
        status = 'ok'
        round = $Round
        model = $Model
        reasoning_effort = $ReasoningEffort
        duration_ms = $processResult.duration_ms
        token_usage = $tokenUsage
        verdict = [string]$review.verdict
        findings = $findings.Count
        feedback_path = (Resolve-Path -LiteralPath $reviewPath).Path
        structured_review_path = (Resolve-Path -LiteralPath $reviewJsonPath).Path
        stream_path = (Resolve-Path -LiteralPath $streamPath).Path
        metadata_path = (Resolve-Path -LiteralPath $metadataPath).Path
        provenance = ($provJson | ConvertFrom-Json)
    } | ConvertTo-Json -Depth 6 -Compress
}
finally {
    Pop-Location
    if (Test-Path -LiteralPath $tmpJson) {
        Remove-Item -LiteralPath $tmpJson -Force
    }
    Remove-CodexTempDirectory -Path $executionDir -ExpectedLeafPrefix 'dt-review-exec-'
}
