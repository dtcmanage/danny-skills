param(
    [Parameter(Mandatory)][string]$ProjectPath,
    [string]$PromptPath = "",
    [string]$OutputPath = "",
    [ValidateSet('complex', 'standard', 'light')][string]$Tier = "standard",
    [string]$Model = "",
    [string]$SelectionReason = "",
    [ValidateSet('low', 'medium', 'high', 'xhigh', 'max', 'ultra')][string]$ReasoningEffort = "medium",
    [ValidateRange(1, 2)][int]$Attempt = 1,
    [ValidateRange(1000, 3600000)][int]$TimeoutMs = 600000,
    [switch]$Preflight,
    [string]$CodexCliPath = "",
    [switch]$Json
)

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

function Get-CodexCliPath {
    if (-not [string]::IsNullOrWhiteSpace($CodexCliPath)) {
        if (-not (Test-Path -LiteralPath $CodexCliPath)) {
            throw "CODEX_INVOKE_FAIL: codex CLI override not found: $CodexCliPath"
        }
        return (Resolve-Path -LiteralPath $CodexCliPath).Path
    }

    # Prefer the npm shim because it is the actively updated CLI on this host;
    # a separately installed native codex.exe may lag several releases.
    $candidates = Get-Command codex.ps1, codex.cmd, codex, codex.exe -ErrorAction SilentlyContinue
    foreach ($cmd in $candidates) {
        if ($cmd -and $cmd.CommandType -in @('Application', 'ExternalScript')) {
            return $cmd.Source
        }
    }
    throw "CODEX_INVOKE_FAIL: unable to locate codex CLI executable."
}

if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
    throw "CODEX_INVOKE_FAIL: project path not found: $ProjectPath"
}
$projectRoot = (Resolve-Path -LiteralPath $ProjectPath).Path
$gitProbe = & git -C $projectRoot rev-parse --show-toplevel 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "CODEX_INVOKE_FAIL: project path is not a git repo: $projectRoot`n$($gitProbe -join "`n")"
}

if (-not $Preflight) {
    if ([string]::IsNullOrWhiteSpace($PromptPath) -or -not (Test-Path -LiteralPath $PromptPath -PathType Leaf)) {
        throw "CODEX_INVOKE_FAIL: substantive invocation requires an existing -PromptPath."
    }
    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        throw "CODEX_INVOKE_FAIL: substantive invocation requires -OutputPath."
    }
    $PromptPath = (Resolve-Path -LiteralPath $PromptPath).Path
    $OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $promptText = Get-Content -Raw -LiteralPath $PromptPath
    $attemptMatch = [regex]::Match($promptText, '(?m)^attempt:\s*(\d+)\s*$')
    if (-not $attemptMatch.Success -or [int]$attemptMatch.Groups[1].Value -ne $Attempt) {
        throw "CODEX_INVOKE_FAIL: prompt attempt header must equal -Attempt $Attempt."
    }
    $runMatch = [regex]::Match($promptText, '(?m)^RUN_ID:\s*(.+?)\s*$')
    $chunkMatch = [regex]::Match($promptText, '(?m)^chunk_id:\s*(.+?)\s*$')
    if (-not $runMatch.Success -or -not $chunkMatch.Success) {
        throw "CODEX_INVOKE_FAIL: prompt must contain RUN_ID and chunk_id identity headers."
    }
    $promptRunId = $runMatch.Groups[1].Value.Trim()
    $promptChunkId = $chunkMatch.Groups[1].Value.Trim()
    if ($SelectionReason -match '[\r\n]') {
        throw "CODEX_INVOKE_FAIL: -SelectionReason must be one line."
    }
    $SelectionReason = $SelectionReason.Trim()
    if ([string]::IsNullOrWhiteSpace($SelectionReason)) {
        throw "CODEX_INVOKE_FAIL: substantive invocation requires -SelectionReason. Report the selected model and this reason in chat before dispatch."
    }
    if ($SelectionReason.Length -gt 240) {
        throw "CODEX_INVOKE_FAIL: -SelectionReason must be 240 characters or fewer."
    }
}

$repoRoot = Resolve-SkillRepoRoot
. (Join-Path $repoRoot "scripts\resolve-codex-model.ps1")
. (Join-Path $repoRoot "scripts\security\redact-secrets.ps1")

$preferred = $Model
if ([string]::IsNullOrWhiteSpace($preferred)) {
    $preferred = switch ($Tier) {
        'complex'  { 'gpt-5.6-sol' }
        'standard' { 'gpt-5.6-terra' }
        'light'    { 'gpt-5.6-luna' }
    }
}
$resolvedModel = Resolve-CodexModel -Tier $Tier -PreferredModel $preferred -Strict
[void](Assert-CodexReasoningEffort -Model $resolvedModel -Effort $ReasoningEffort -Strict)
$disclosureLine = if ($Preflight) { $null } else {
    "MODEL_SELECTION: $promptChunkId -> $resolvedModel ($Tier, effort $ReasoningEffort): $SelectionReason"
}
$codexCli = Get-CodexCliPath

$temporaryOutput = $false
if ($Preflight -and [string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path ([System.IO.Path]::GetTempPath()) ("dt-build-codex-preflight-{0}.md" -f ([guid]::NewGuid().ToString('N')))
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
$sandbox = if ($Preflight) { 'read-only' } else { 'workspace-write' }
# Codex removed its Windows sandbox (features experimental_windows_sandbox /
# elevated_windows_sandbox report "removed"), so under --ignore-user-config a
# workspace-write request fails closed to read-only and blocks every command
# before process launch. On Windows, substantive chunks therefore run
# unsandboxed via explicit default_permissions; containment is the scoped
# worktree plus the orchestrator's independent verification. Preflight and
# non-Windows hosts keep the real sandbox. Verified 2026-08-30, codex-cli 0.151.0.
$windowsUnsandboxed = (-not $Preflight) -and ($env:OS -eq 'Windows_NT')
if ($windowsUnsandboxed) { $sandbox = 'danger-full-access (windows: codex sandbox removed upstream)' }
$sandboxArgs = if ($windowsUnsandboxed) {
    @('-c', 'default_permissions=":danger-full-access"')
} else {
    @('--sandbox', $sandbox)
}
$args = @(
    '--ask-for-approval', 'never',
    'exec',
    '--ignore-user-config'
) + $sandboxArgs + @(
    '--cd', $projectRoot,
    '--model', $resolvedModel,
    '-c', ('model_reasoning_effort="{0}"' -f $ReasoningEffort),
    '--output-last-message', $OutputPath,
    '-'
)

$started = Get-Date
$proc = $null
$completedSuccessfully = $false
$streamPath = "$OutputPath.stream.log"
$provenancePath = "$OutputPath.provenance.json"
$provenanceWritten = $false
try {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $cliExtension = [System.IO.Path]::GetExtension($codexCli).ToLowerInvariant()
    $prefixArgs = @()
    if ($cliExtension -in @('.cmd', '.bat')) {
        $startInfo.FileName = $env:ComSpec
        $quotedCli = '"' + $codexCli.Replace('"', '""') + '"'
        $quotedArgs = @($args | ForEach-Object { '"' + ([string]$_).Replace('"', '\"') + '"' })
        $prefixArgs = @('/d', '/s', '/c', ($quotedCli + ' ' + ($quotedArgs -join ' ')))
        $args = @()
    }
    elseif ($cliExtension -eq '.ps1') {
        $startInfo.FileName = 'pwsh'
        $prefixArgs = @('-NoProfile', '-File', $codexCli)
    }
    else {
        $startInfo.FileName = $codexCli
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
    if (-not $proc.Start()) { throw "CODEX_INVOKE_FAIL: failed to start codex CLI." }

    # Start both drains before writing stdin so neither native pipe can fill and
    # deadlock the process. The same pattern protects high-volume verifier runs.
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
    $streamText = Invoke-SecretRedaction -Text (($stdout, $stderr) -join "`n")

    [System.IO.File]::WriteAllText($streamPath, $streamText)

    $lastMessage = if (Test-Path -LiteralPath $OutputPath) {
        Get-Content -Raw -LiteralPath $OutputPath
    }
    else { "" }

    # The retained final message is evidence too: redact it before hashing or
    # writing provenance, not only the process stream.
    if (-not [string]::IsNullOrEmpty($lastMessage)) {
        $lastMessage = Invoke-SecretRedaction -Text $lastMessage
        [System.IO.File]::WriteAllText($OutputPath, $lastMessage)
    }

    $failureReason = ''
    $failureCategory = $null
    $shapeErrors = @()
    if ($timedOut) {
        $failureReason = "CODEX_INVOKE_TIMEOUT: codex exec exceeded ${TimeoutMs}ms and its process tree was terminated. Redacted stream: $streamPath"
        $failureCategory = 'tooling'
    }
    elseif ($exitCode -ne 0) {
        $failureReason = "CODEX_INVOKE_FAIL: codex exec exited $exitCode. Redacted stream: $streamPath"
        $failureCategory = 'tooling'
    }
    elseif ([string]::IsNullOrWhiteSpace($lastMessage)) {
        $failureReason = "CODEX_INVOKE_FAIL: codex exec returned no final message. Redacted stream: $streamPath"
        $failureCategory = 'model-output'
    }
    elseif ($Preflight -and $lastMessage.Trim() -ne 'OK') {
        $failureReason = "CODEX_PREFLIGHT_FAIL: expected OK, received '$($lastMessage.Trim())'. Redacted stream: $streamPath"
        $failureCategory = 'model-output'
    }
    elseif (-not $Preflight) {
        $shapeErrors = @(Get-ReportShapeErrors -Text $lastMessage -RunId $promptRunId -ChunkId $promptChunkId -ExpectedAttempt $Attempt)
        if ($shapeErrors.Count -gt 0) {
            $failureReason = "CODEX_OUTPUT_INVALID: $($shapeErrors -join '; '). Redacted output: $OutputPath"
            $failureCategory = 'model-output'
        }
    }

    $cliVersion = if ([System.IO.Path]::GetExtension($codexCli).ToLowerInvariant() -eq '.ps1') {
        (& pwsh -NoProfile -File $codexCli --version 2>&1) -join ' '
    } else { (& $codexCli --version 2>&1) -join ' ' }
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $cachePath = Join-Path $codexHome 'models_cache.json'
    $cacheFetchedAt = $null
    if (Test-Path -LiteralPath $cachePath) {
        try { $cacheFetchedAt = (Get-Content -Raw -LiteralPath $cachePath | ConvertFrom-Json).fetched_at } catch { }
    }
    $authSurface = 'unknown'
    $authPath = Join-Path $codexHome 'auth.json'
    if (Test-Path -LiteralPath $authPath) {
        try {
            $auth = Get-Content -Raw -LiteralPath $authPath | ConvertFrom-Json
            if ($auth.PSObject.Properties.Name -contains 'auth_mode') { $authSurface = [string]$auth.auth_mode }
        } catch { }
    }
    $forcedLoginMethod = $null
    $configPath = Join-Path $codexHome 'config.toml'
    if (Test-Path -LiteralPath $configPath) {
        $authMatch = [regex]::Match((Get-Content -Raw -LiteralPath $configPath), '(?m)^forced_login_method\s*=\s*"([^"]+)"')
        if ($authMatch.Success) { $forcedLoginMethod = $authMatch.Groups[1].Value }
    }

    $result = [pscustomobject]@{
        pass                   = [string]::IsNullOrWhiteSpace($failureReason)
        preflight              = [bool]$Preflight
        tier                   = $Tier
        requested_model        = $preferred
        resolved_model         = $resolvedModel
        selection_reason       = if ($Preflight) { $null } else { $SelectionReason }
        disclosure_line        = $disclosureLine
        reasoning_effort       = $ReasoningEffort
        attempt                = $Attempt
        sandbox                = $sandbox
        # Approval policy and sandbox mode are separate controls: the global
        # --ask-for-approval never pin makes non-interactive behavior part of
        # the wrapper contract instead of an inherited default.
        approval_mode          = 'never'
        codex_cli_version      = $cliVersion
        auth_surface           = $authSurface
        forced_login_method    = $forcedLoginMethod
        model_cache_fetched_at = $cacheFetchedAt
        duration_ms            = $durationMs
        timeout_ms             = $TimeoutMs
        prompt_sha256          = $promptSha256
        output_sha256          = if (Test-Path -LiteralPath $OutputPath) { (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
        output_path            = if ($temporaryOutput -or -not (Test-Path -LiteralPath $OutputPath)) { $null } else { (Resolve-Path -LiteralPath $OutputPath).Path }
        stream_log_path        = if ($temporaryOutput -or -not (Test-Path -LiteralPath $streamPath)) { $null } else { (Resolve-Path -LiteralPath $streamPath).Path }
        failure_category       = $failureCategory
        termination_reason     = $failureReason
        output_shape_errors    = @($shapeErrors)
    }

    if (-not $temporaryOutput) {
        [System.IO.File]::WriteAllText($provenancePath, ($result | ConvertTo-Json -Depth 5))
        $provenanceWritten = $true
        $result | Add-Member -NotePropertyName provenance_path -NotePropertyValue (Resolve-Path -LiteralPath $provenancePath).Path
    }

    if (-not $result.pass) { throw $failureReason }
    if ($Json) { $result | ConvertTo-Json -Depth 5 }
    else { $result }
    $completedSuccessfully = $true
}
catch {
    if (-not $temporaryOutput -and -not $provenanceWritten) {
        $durationMs = [int][Math]::Round(((Get-Date) - $started).TotalMilliseconds)
        $fallback = [pscustomobject]@{
            pass = $false; preflight = [bool]$Preflight; tier = $Tier
            requested_model = $preferred; resolved_model = $resolvedModel
            selection_reason = if ($Preflight) { $null } else { $SelectionReason }
            disclosure_line = $disclosureLine
            reasoning_effort = $ReasoningEffort; attempt = $Attempt; sandbox = $sandbox
            approval_mode = 'never'
            duration_ms = $durationMs; timeout_ms = $TimeoutMs; prompt_sha256 = $promptSha256
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
