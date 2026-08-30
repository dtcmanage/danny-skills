[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectPath,

    [ValidateRange(1, 99)]
    [int]$Round = 0,

    [string]$PromptPath = '',

    # CLI alias, not a dated slug, so the pin self-heals when Anthropic rotates
    # versions. Default by tier: complex -> opus, light -> sonnet. Override with a
    # different alias only with a recorded reason (for example a top-tier alias the
    # installed CLI supports).
    [string]$Model = '',

    [ValidateSet('complex', 'light')]
    [string]$Tier = 'light',

    [ValidateRange(1000, 3600000)]
    [int]$TimeoutMs = 600000,

    # Required whenever -Model overrides the tier default alias.
    [string]$ModelReason = '',

    [string]$ClaudeCliPath = '',

    [switch]$Preflight
)

# invoke-claude-round.ps1
# -----------------------
# Claude-lane twin of invoke-codex-round.ps1 for the cross-family reviewer rule:
# a Codex-authored draft is critiqued by a Claude reviewer, not by its own family.
# Same canonical-prompt receipt chain, semantic validation, redaction, and round
# metadata as the Codex lane. The claude CLI has no --output-schema, so the wrapper
# appends the review output schema to the stdin payload and validates the returned
# JSON with the same semantic validator that governs the Codex lane. There is no
# reasoning-effort knob on the claude CLI; capability parity comes from the model
# alias (opus for complex reviews).

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Atomic([string]$Path, [string]$Content) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmp = Join-Path $dir ((Split-Path -Leaf $Path) + '.tmp.' + $PID)
    [System.IO.File]::WriteAllText($tmp, $Content, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Get-ClaudeCliPath {
    if (-not [string]::IsNullOrWhiteSpace($ClaudeCliPath)) {
        if (-not (Test-Path -LiteralPath $ClaudeCliPath)) {
            throw "claude CLI override not found: $ClaudeCliPath"
        }
        return (Resolve-Path -LiteralPath $ClaudeCliPath).Path
    }
    $candidates = Get-Command claude.ps1, claude.cmd, claude, claude.exe -ErrorAction SilentlyContinue
    foreach ($cmd in $candidates) {
        if ($cmd -and $cmd.CommandType -in @('Application', 'ExternalScript')) {
            return $cmd.Source
        }
    }
    throw 'Unable to locate claude CLI executable (claude.ps1/claude.cmd/claude/claude.exe).'
}

function Invoke-ClaudeProcess {
    param(
        [Parameter(Mandatory)] [string]$CliPath,
        [Parameter(Mandatory)] [string[]]$Arguments,
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Prompt,
        [Parameter(Mandatory)] [string]$WorkingDirectory,
        [Parameter(Mandatory)] [ValidateRange(1000, 3600000)] [int]$TimeoutMs
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $cliExtension = [System.IO.Path]::GetExtension($CliPath).ToLowerInvariant()
    $prefixArgs = @()
    $mainArgs = @($Arguments)
    if ($cliExtension -in @('.cmd', '.bat')) {
        $startInfo.FileName = $env:ComSpec
        $quotedCli = '"' + $CliPath.Replace('"', '""') + '"'
        $quotedArgs = @($mainArgs | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' })
        $prefixArgs = @('/d', '/s', '/c', ($quotedCli + ' ' + ($quotedArgs -join ' ')))
        $mainArgs = @()
    }
    elseif ($cliExtension -eq '.ps1') {
        $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
        $prefixArgs = @('-NoProfile', '-File', $CliPath)
    }
    else {
        $startInfo.FileName = $CliPath
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $startInfo.StandardInputEncoding = $utf8
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    foreach ($arg in @($prefixArgs) + @($mainArgs)) { [void]$startInfo.ArgumentList.Add([string]$arg) }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $startInfo
    $started = [DateTimeOffset]::UtcNow
    try {
        if (-not $proc.Start()) { throw "Failed to start claude CLI: $($startInfo.FileName)" }
        # Start both drains before writing stdin so neither native pipe can fill and
        # deadlock the process.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $stdinTask = $proc.StandardInput.WriteAsync($Prompt)
        $stdinClosed = $false
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $proc.HasExited -and $clock.ElapsedMilliseconds -lt $TimeoutMs) {
            if (-not $stdinClosed -and $stdinTask.IsCompleted) {
                [void]$stdinTask.GetAwaiter().GetResult()
                $proc.StandardInput.Close()
                $stdinClosed = $true
            }
            Start-Sleep -Milliseconds 20
        }
        $timedOut = -not $proc.HasExited
        if ($timedOut) {
            try { $proc.Kill($true) } catch { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
            [void]$proc.WaitForExit(5000)
        }
        else {
            $proc.WaitForExit()
        }
        [pscustomobject]@{
            exit_code = if ($timedOut) { 124 } else { $proc.ExitCode }
            timed_out = $timedOut
            duration_ms = [int]([DateTimeOffset]::UtcNow - $started).TotalMilliseconds
            stdout = $stdoutTask.GetAwaiter().GetResult()
            stderr = $stderrTask.GetAwaiter().GetResult()
        }
    }
    finally {
        if ($proc -and -not $proc.HasExited) {
            try { $proc.Kill($true) } catch { }
        }
        $proc.Dispose()
    }
}

function ConvertFrom-ClaudeReviewOutput([string]$Text) {
    $trimmed = $Text.Trim()
    # Strip a single fenced wrapper if the model added one despite instructions.
    $fenceMatch = [regex]::Match($trimmed, '(?s)^```(?:json)?\s*(.+?)\s*```$')
    if ($fenceMatch.Success) { $trimmed = $fenceMatch.Groups[1].Value }
    return ($trimmed | ConvertFrom-Json)
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

$tierDefaultModel = if ($Tier -eq 'complex') { 'opus' } else { 'sonnet' }
$RequestedModel = if ([string]::IsNullOrWhiteSpace($Model)) { $tierDefaultModel } else { $Model }
if ($RequestedModel -cne $tierDefaultModel -and [string]::IsNullOrWhiteSpace($ModelReason)) {
    throw "Model '$RequestedModel' deviates from the $Tier-tier default '$tierDefaultModel'. Record the reason with -ModelReason."
}

$claudeCli = Get-ClaudeCliPath
$executionDir = Join-Path $env:TEMP ("dt-review-claude-exec-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $executionDir -Force | Out-Null

if ($Preflight) {
    try {
        $preflightArgs = @('-p', '--model', $RequestedModel, '--permission-mode', 'default', '--output-format', 'text')
        $result = Invoke-ClaudeProcess -CliPath $claudeCli -Arguments $preflightArgs `
            -Prompt 'Reply with the single word OK and nothing else. Do not inspect or modify files.' `
            -WorkingDirectory $executionDir -TimeoutMs $TimeoutMs
        if ($result.timed_out) { throw "Claude preflight exceeded ${TimeoutMs}ms." }
        if ($result.exit_code -ne 0) { throw "Claude preflight exited $($result.exit_code): $($result.stderr.Trim())" }
        if ($result.stdout.Trim() -ne 'OK') { throw "Claude preflight expected OK, received '$($result.stdout.Trim())'." }
        [pscustomobject]@{
            status = 'ok'
            preflight = $true
            lane = 'claude'
            tier = $Tier
            model = $RequestedModel
            duration_ms = $result.duration_ms
        } | ConvertTo-Json -Compress
        return
    }
    finally {
        Remove-Item -LiteralPath $executionDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($Round -lt 1) { throw 'Round is required for a substantive review invocation.' }
if ([string]::IsNullOrWhiteSpace($PromptPath) -or -not (Test-Path -LiteralPath $PromptPath -PathType Leaf)) {
    throw "Prompt path not found: $PromptPath"
}

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
. (Join-Path $ScriptDir 'validate-review-semantics.ps1')
. (Join-Path $ScriptDir 'invocation-receipt.ps1')
. (Join-Path $ScriptDir 'render-review-markdown.ps1')

$schemaPath = Join-Path $SkillRoot 'references\review-output-schema.json'
if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
    throw "Review output schema not found: $schemaPath"
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
$draftSha256 = [string]$inputReceipt.draft_sha256

$reviewPath = Join-Path $scratchDir ("review-v{0}.md" -f $Round)
$reviewJsonPath = Join-Path $scratchDir ("review-v{0}.json" -f $Round)
$streamPath = Join-Path $scratchDir ("claude-stream-v{0}.log" -f $Round)
$metadataPath = Join-Path $scratchDir ("round-meta-v{0}.json" -f $Round)

$promptRaw = Get-Content -LiteralPath $PromptPath -Raw
$redactedPrompt = Invoke-SecretRedaction -Text $promptRaw
if ($redactedPrompt -cne $promptRaw) {
    throw 'SECURITY_SECRET_PATTERN: the assembled review prompt contains a credential-shaped value. Remove or replace it before invoking the Claude reviewer.'
}

# The claude CLI has no --output-schema; append the schema to the stdin payload.
# The canonical prompt file is untouched, so the receipt chain still binds it; the
# deterministic suffix is recorded by hash in round metadata.
$schemaRaw = Get-Content -LiteralPath $schemaPath -Raw
$stdinSuffix = @"


=== REQUIRED OUTPUT SCHEMA (JSON Schema 2020-12) ===
$schemaRaw
=== END REQUIRED OUTPUT SCHEMA ===

Return ONLY one JSON object that conforms exactly to the schema above. No prose before or after it, no code fences.
"@
$stdinPayload = $promptRaw + $stdinSuffix
$suffixSha256 = [System.BitConverter]::ToString(
    [System.Security.Cryptography.SHA256]::HashData(
        [System.Text.UTF8Encoding]::new($false).GetBytes($stdinSuffix))).Replace('-', '').ToUpperInvariant()

try {
    $cliVersion = ((Invoke-ClaudeProcess -CliPath $claudeCli -Arguments @('--version') -Prompt '' `
        -WorkingDirectory $executionDir -TimeoutMs 30000).stdout).Trim()
    Assert-DtReviewInvocationReceipt -Receipt $inputReceipt -Round $Round -Tier $Tier
    $arguments = @(
        '-p',
        '--model', $RequestedModel,
        '--permission-mode', 'default',
        '--output-format', 'text'
    )
    $processResult = Invoke-ClaudeProcess `
        -CliPath $claudeCli `
        -Arguments $arguments `
        -Prompt $stdinPayload `
        -WorkingDirectory $executionDir `
        -TimeoutMs $TimeoutMs
    Assert-DtReviewInvocationReceipt -Receipt $inputReceipt -Round $Round -Tier $Tier
    Write-Atomic -Path $streamPath -Content (Invoke-SecretRedaction -Text $processResult.stderr)

    if ($processResult.timed_out) {
        throw "Claude round $Round exceeded the enforced $TimeoutMs ms timeout. Redacted stream: $streamPath"
    }
    if ($processResult.exit_code -ne 0) {
        throw "Claude round $Round failed with exit code $($processResult.exit_code). Redacted stream: $streamPath"
    }
    if ([string]::IsNullOrWhiteSpace($processResult.stdout)) {
        throw "Claude round $Round returned no final message. Redacted stream: $streamPath"
    }

    try {
        $review = ConvertFrom-ClaudeReviewOutput -Text $processResult.stdout
        $reviewRaw = ConvertTo-Json -InputObject $review -Depth 10
    }
    catch {
        throw "Claude round $Round returned invalid structured JSON: $($_.Exception.Message). Redacted stream: $streamPath"
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
    [void](Assert-DtReviewSemantics -Review $review -Round $Round -PriorEntries $priorEntries)
    $findings = @($review.findings)
    Assert-DtReviewInvocationReceipt -Receipt $inputReceipt -Round $Round -Tier $Tier

    $safeJson = Invoke-SecretRedaction -Text $reviewRaw
    $safeMarkdown = Invoke-SecretRedaction -Text (Convert-ReviewToMarkdown -Review $review)
    Write-Atomic -Path $reviewJsonPath -Content ($safeJson.TrimEnd() + "`n")
    Write-Atomic -Path $reviewPath -Content $safeMarkdown

    $provJson = & (Join-Path $ScriptDir 'capture-provenance.ps1') `
        -PromptPath $PromptPath `
        -CanonicalPath $projectRoot

    $draftSha256AfterReview = (Get-FileHash -LiteralPath $draftPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($draftSha256AfterReview -cne $draftSha256) {
        throw "Round $Round draft changed while the reviewer was running. Refusing to issue a review receipt for a moving input."
    }
    $metadata = [ordered]@{
        round = $Round
        tier = $Tier
        requested_model = $RequestedModel
        resolved_model = $RequestedModel
        reasoning_effort = 'cli-session-default'
        model_reason = $ModelReason
        lane = 'claude'
        cli_version = $cliVersion
        duration_ms = $processResult.duration_ms
        token_usage = $null
        prompt_bytes = [System.Text.Encoding]::UTF8.GetByteCount($promptRaw)
        stdin_suffix_sha256 = $suffixSha256
        prompt_path = [string]$inputReceipt.prompt_path
        prompt_sha256 = [string]$inputReceipt.prompt_sha256
        state_path = [string]$inputReceipt.state_path
        state_sha256 = [string]$inputReceipt.state_sha256
        authorization_path = if ($inputReceipt.authorization_required) { [string]$inputReceipt.authorization_path } else { $null }
        authorization_sha256 = if ($inputReceipt.authorization_required) { [string]$inputReceipt.authorization_sha256 } else { $null }
        review_bytes = [System.Text.Encoding]::UTF8.GetByteCount($safeJson)
        draft_path = $draftPath
        draft_sha256 = $draftSha256
        provenance = ($provJson | ConvertFrom-Json)
    }
    Write-Atomic -Path $metadataPath -Content (($metadata | ConvertTo-Json -Depth 6) + "`n")

    [pscustomobject]@{
        status = 'ok'
        round = $Round
        lane = 'claude'
        model = $RequestedModel
        duration_ms = $processResult.duration_ms
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
    Remove-Item -LiteralPath $executionDir -Recurse -Force -ErrorAction SilentlyContinue
}
