param(
    [Parameter(Mandatory)][string]$ProjectPath,
    [string]$PromptPath = "",
    [string]$OutputPath = "",
    [ValidateSet('complex', 'standard', 'light')][string]$Tier = "standard",
    [string]$Model = "",
    [ValidateRange(1, 2)][int]$Attempt = 1,
    [ValidateRange(1000, 3600000)][int]$TimeoutMs = 600000,
    [switch]$Preflight,
    [string]$ClaudeCliPath = "",
    [switch]$Json
)

# invoke-claude-chunk.ps1
# -----------------------
# Claude-lane twin of invoke-codex-chunk.ps1, for orchestrators that cannot use a
# host-native Agent tool (a Codex-orchestrated dt-build run). When the orchestrator
# IS a Claude Code session, dispatch Claude subagents through the Agent tool with an
# explicit model instead — this wrapper is the cross-model bridge, not the default.
#
# Tier -> model uses CLI aliases, not dated slugs, so the pin self-heals when
# Anthropic rotates model versions:
#   complex  -> opus
#   standard -> sonnet
#   light    -> haiku
# There is no reasoning-effort knob on the claude CLI; effort is a session-level
# setting, so provenance records the alias and resolved CLI version only.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-SkillRepoRoot {
    $scriptDir = Split-Path -Parent $PSCommandPath
    $skillRoot = Split-Path -Parent $scriptDir
    $original = (Resolve-Path -LiteralPath $skillRoot).Path
    $cursor = Get-Item -LiteralPath $original
    while ($null -ne $cursor) {
        $resolved = $null
        try { $resolved = $cursor.ResolveLinkTarget($true) } catch { }
        if ($resolved) {
            $suffix = [System.IO.Path]::GetRelativePath($cursor.FullName, $original)
            $skillRoot = if ($suffix -eq '.') { $resolved.FullName } else { Join-Path $resolved.FullName $suffix }
            break
        }
        $cursor = $cursor.Parent
    }
    return (Split-Path -Parent (Split-Path -Parent $skillRoot))
}

function Get-ReportShapeErrors {
    param([string]$Text, [string]$RunId, [string]$ChunkId, [int]$ExpectedAttempt)
    $errors = New-Object System.Collections.Generic.List[string]
    $required = @(
        @{ label = 'DT_BUILD_REPORT_VERSION'; pattern = '(?m)^DT_BUILD_REPORT_VERSION:\s*2\s*$' },
        @{ label = 'RUN_ID'; pattern = '(?m)^RUN_ID:\s*' + [regex]::Escape($RunId) + '\s*$' },
        @{ label = 'chunk_id'; pattern = '(?m)^chunk_id:\s*' + [regex]::Escape($ChunkId) + '\s*$' },
        @{ label = 'attempt'; pattern = '(?m)^attempt:\s*' + $ExpectedAttempt + '\s*$' },
        @{ label = 'CHANGED_FILES'; pattern = '(?m)^CHANGED_FILES:\s*$' },
        @{ label = 'COMMANDS_AND_RESULTS'; pattern = '(?m)^COMMANDS_AND_RESULTS:\s*$' },
        @{ label = 'UNRESOLVED_BLOCKERS'; pattern = '(?m)^UNRESOLVED_BLOCKERS:\s*$' },
        @{ label = 'DISCOVERED_ENHANCEMENTS'; pattern = '(?m)^DISCOVERED_ENHANCEMENTS:\s*$' }
    )
    foreach ($entry in $required) {
        if ($Text -notmatch $entry.pattern) { $errors.Add("missing or mismatched $($entry.label)") | Out-Null }
    }
    return @($errors)
}

function Get-ClaudeCliPath {
    if (-not [string]::IsNullOrWhiteSpace($ClaudeCliPath)) {
        if (-not (Test-Path -LiteralPath $ClaudeCliPath)) {
            throw "CLAUDE_INVOKE_FAIL: claude CLI override not found: $ClaudeCliPath"
        }
        return (Resolve-Path -LiteralPath $ClaudeCliPath).Path
    }
    $candidates = Get-Command claude.ps1, claude.cmd, claude, claude.exe -ErrorAction SilentlyContinue
    foreach ($cmd in $candidates) {
        if ($cmd -and $cmd.CommandType -in @('Application', 'ExternalScript')) {
            return $cmd.Source
        }
    }
    throw "CLAUDE_INVOKE_FAIL: unable to locate claude CLI executable."
}

if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
    throw "CLAUDE_INVOKE_FAIL: project path not found: $ProjectPath"
}
$projectRoot = (Resolve-Path -LiteralPath $ProjectPath).Path
$gitProbe = & git -C $projectRoot rev-parse --show-toplevel 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "CLAUDE_INVOKE_FAIL: project path is not a git repo: $projectRoot`n$($gitProbe -join "`n")"
}

if (-not $Preflight) {
    if ([string]::IsNullOrWhiteSpace($PromptPath) -or -not (Test-Path -LiteralPath $PromptPath -PathType Leaf)) {
        throw "CLAUDE_INVOKE_FAIL: substantive invocation requires an existing -PromptPath."
    }
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        throw "CLAUDE_INVOKE_FAIL: substantive invocation requires -OutputPath."
    }
    $PromptPath = (Resolve-Path -LiteralPath $PromptPath).Path
    $OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $promptText = Get-Content -Raw -LiteralPath $PromptPath
    $attemptMatch = [regex]::Match($promptText, '(?m)^attempt:\s*(\d+)\s*$')
    if (-not $attemptMatch.Success -or [int]$attemptMatch.Groups[1].Value -ne $Attempt) {
        throw "CLAUDE_INVOKE_FAIL: prompt attempt header must equal -Attempt $Attempt."
    }
    $runMatch = [regex]::Match($promptText, '(?m)^RUN_ID:\s*(.+?)\s*$')
    $chunkMatch = [regex]::Match($promptText, '(?m)^chunk_id:\s*(.+?)\s*$')
    if (-not $runMatch.Success -or -not $chunkMatch.Success) {
        throw "CLAUDE_INVOKE_FAIL: prompt must contain RUN_ID and chunk_id identity headers."
    }
    $promptRunId = $runMatch.Groups[1].Value.Trim()
    $promptChunkId = $chunkMatch.Groups[1].Value.Trim()
}

$repoRoot = Resolve-SkillRepoRoot
. (Join-Path $repoRoot "scripts\security\redact-secrets.ps1")

$resolvedModel = $Model
if ([string]::IsNullOrWhiteSpace($resolvedModel)) {
    $resolvedModel = switch ($Tier) {
        'complex'  { 'opus' }
        'standard' { 'sonnet' }
        'light'    { 'haiku' }
    }
}
$claudeCli = Get-ClaudeCliPath

$temporaryOutput = $false
if ($Preflight -and [string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-build-claude-preflight-{0}.md" -f ([guid]::NewGuid().ToString('N')))
    $temporaryOutput = $true
}
$outputDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$prompt = if ($Preflight) {
    "Reply with the single word OK and nothing else. Do not inspect or modify files."
}
else {
    Get-Content -Raw -LiteralPath $PromptPath
}
$promptSha256 = if ($Preflight) {
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($prompt)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
else {
    (Get-FileHash -LiteralPath $PromptPath -Algorithm SHA256).Hash.ToLowerInvariant()
}
# Preflight needs no tool access; a build chunk needs file writes and test
# commands without interactive prompts, mirroring Codex's workspace-write sandbox.
$permissionMode = if ($Preflight) { 'default' } else { 'bypassPermissions' }
$args = @(
    '-p',
    '--model', $resolvedModel,
    '--permission-mode', $permissionMode,
    '--output-format', 'text'
)

$started = Get-Date
$proc = $null
$streamPath = "$OutputPath.stream.log"
$provenancePath = "$OutputPath.provenance.json"
$provenanceWritten = $false
try {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $cliExtension = [System.IO.Path]::GetExtension($claudeCli).ToLowerInvariant()
    $prefixArgs = @()
    if ($cliExtension -in @('.cmd', '.bat')) {
        $startInfo.FileName = $env:ComSpec
        $quotedCli = '"' + $claudeCli.Replace('"', '""') + '"'
        $quotedArgs = @($args | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' })
        $prefixArgs = @('/d', '/s', '/c', ($quotedCli + ' ' + ($quotedArgs -join ' ')))
        $args = @()
    }
    elseif ($cliExtension -eq '.ps1') {
        $startInfo.FileName = 'pwsh'
        $prefixArgs = @('-NoProfile', '-File', $claudeCli)
    }
    else {
        $startInfo.FileName = $claudeCli
    }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $startInfo.WorkingDirectory = $projectRoot
    foreach ($arg in @($prefixArgs) + @($args)) { [void]$startInfo.ArgumentList.Add($arg) }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $startInfo
    if (-not $proc.Start()) { throw "CLAUDE_INVOKE_FAIL: failed to start claude CLI." }

    # Start both drains before writing stdin so neither native pipe can fill and
    # deadlock the process.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $stdinTask = $proc.StandardInput.WriteAsync($prompt)
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
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exitCode = if ($timedOut) { 124 } else { $proc.ExitCode }
    $durationMs = [int][Math]::Round(((Get-Date) - $started).TotalMilliseconds)

    # claude -p returns the final message on stdout; stderr is the stream log.
    $lastMessage = Invoke-SecretRedaction -Text $stdout
    $streamText = Invoke-SecretRedaction -Text $stderr
    [System.IO.File]::WriteAllText($streamPath, $streamText)
    [System.IO.File]::WriteAllText($OutputPath, $lastMessage)

    $failureReason = ''
    $failureCategory = $null
    $shapeErrors = @()
    if ($timedOut) {
        $failureReason = "CLAUDE_INVOKE_TIMEOUT: claude -p exceeded ${TimeoutMs}ms and its process tree was terminated. Redacted stream: $streamPath"
        $failureCategory = 'tooling'
    }
    elseif ($exitCode -ne 0) {
        $failureReason = "CLAUDE_INVOKE_FAIL: claude -p exited $exitCode. Redacted stream: $streamPath"
        $failureCategory = 'tooling'
    }
    elseif ([string]::IsNullOrWhiteSpace($lastMessage)) {
        $failureReason = "CLAUDE_INVOKE_FAIL: claude -p returned no final message. Redacted stream: $streamPath"
        $failureCategory = 'model-output'
    }
    elseif ($Preflight -and $lastMessage.Trim() -ne 'OK') {
        $failureReason = "CLAUDE_PREFLIGHT_FAIL: expected OK, received '$($lastMessage.Trim())'. Redacted stream: $streamPath"
        $failureCategory = 'model-output'
    }
    elseif (-not $Preflight) {
        $shapeErrors = @(Get-ReportShapeErrors -Text $lastMessage -RunId $promptRunId -ChunkId $promptChunkId -ExpectedAttempt $Attempt)
        if ($shapeErrors.Count -gt 0) {
            $failureReason = "CLAUDE_OUTPUT_INVALID: $($shapeErrors -join '; '). Redacted output: $OutputPath"
            $failureCategory = 'model-output'
        }
    }

    $cliVersion = if ([System.IO.Path]::GetExtension($claudeCli).ToLowerInvariant() -eq '.ps1') {
        (& pwsh -NoProfile -File $claudeCli --version 2>&1) -join ' '
    } else { (& $claudeCli --version 2>&1) -join ' ' }

    $result = [pscustomobject]@{
        pass                = [string]::IsNullOrWhiteSpace($failureReason)
        preflight           = [bool]$Preflight
        lane                = 'claude'
        tier                = $Tier
        requested_model     = $resolvedModel
        resolved_model      = $resolvedModel
        permission_mode     = $permissionMode
        attempt             = $Attempt
        claude_cli_version  = $cliVersion
        duration_ms         = $durationMs
        timeout_ms          = $TimeoutMs
        prompt_sha256       = $promptSha256
        output_sha256       = if (Test-Path -LiteralPath $OutputPath) { (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
        output_path         = if ($temporaryOutput -or -not (Test-Path -LiteralPath $OutputPath)) { $null } else { (Resolve-Path -LiteralPath $OutputPath).Path }
        stream_log_path     = if ($temporaryOutput -or -not (Test-Path -LiteralPath $streamPath)) { $null } else { (Resolve-Path -LiteralPath $streamPath).Path }
        failure_category    = $failureCategory
        termination_reason  = $failureReason
        output_shape_errors = @($shapeErrors)
    }

    if (-not $temporaryOutput) {
        [System.IO.File]::WriteAllText($provenancePath, ($result | ConvertTo-Json -Depth 5))
        $provenanceWritten = $true
        $result | Add-Member -NotePropertyName provenance_path -NotePropertyValue (Resolve-Path -LiteralPath $provenancePath).Path
    }

    if (-not $result.pass) { throw $failureReason }
    if ($Json) { $result | ConvertTo-Json -Depth 5 }
    else { $result }
}
catch {
    if (-not $temporaryOutput -and -not $provenanceWritten) {
        $durationMs = [int][Math]::Round(((Get-Date) - $started).TotalMilliseconds)
        $fallback = [pscustomobject]@{
            pass = $false; preflight = [bool]$Preflight; lane = 'claude'; tier = $Tier
            requested_model = $resolvedModel; resolved_model = $resolvedModel
            attempt = $Attempt; duration_ms = $durationMs; timeout_ms = $TimeoutMs
            prompt_sha256 = $promptSha256
            output_path = $OutputPath; stream_log_path = if (Test-Path -LiteralPath $streamPath) { $streamPath } else { $null }
            failure_category = 'tooling'; termination_reason = (Invoke-SecretRedaction -Text $_.Exception.Message)
        }
        [System.IO.File]::WriteAllText($provenancePath, ($fallback | ConvertTo-Json -Depth 5))
    }
    throw
}
finally {
    if ($proc) { $proc.Dispose() }
    if ($temporaryOutput) {
        Remove-Item -LiteralPath $OutputPath, "$OutputPath.stream.log" -Force -ErrorAction SilentlyContinue
    }
}
