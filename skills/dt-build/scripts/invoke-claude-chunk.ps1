param(
    [Parameter(Mandatory)][string]$ProjectPath,
    [string]$PromptPath = "",
    [string]$OutputPath = "",
    [ValidateSet('complex', 'standard', 'light')][string]$Tier = "standard",
    # Model-router category; when empty, -Tier maps to one (complex -> complex-coding protected,
    # standard -> routine-coding, light -> mechanical).
    [string]$Category = "",
    [switch]$Protected,
    # Retry after a failed attempt: the router moves one step up from this model.
    [string]$EscalateFrom = "",
    [string]$Model = "",
    [string]$SelectionReason = "",
    [ValidateSet('low', 'medium', 'high', 'xhigh')][string]$Effort,
    [ValidateRange(1, 2)][int]$Attempt = 1,
    [ValidateRange(1000, 3600000)][int]$TimeoutMs = 600000,
    [switch]$Preflight,
    [switch]$ReadOnly,
    [string]$ClaudeCliPath = "",
    [switch]$Json
)

# invoke-claude-chunk.ps1
# -----------------------
# Claude-lane wrapper for codex-host orchestrators and for Claude chunks whose
# roster effort differs from the session's effort. A claude-host chunk at matching
# effort may use the host-native Agent tool with an explicit resolved model.
#
# The model comes from the shared model router (scripts/model-router/resolve-model.ps1,
# Claude lane) for the chunk's category; -Tier alone maps to a category the same way
# as the Codex wrapper. -Model is an explicit override only.
# The claude CLI accepts --effort; the caller passes the resolved roster effort
# explicitly and provenance records it alongside the model version.

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
# Outcome rows name the canonical repo (the main checkout's folder), also when building in a linked worktree.
$outcomeRepo = Split-Path -Leaf $projectRoot
$commonGitDir = @(& git -C $projectRoot rev-parse --path-format=absolute --git-common-dir 2>$null)
if ($LASTEXITCODE -eq 0 -and $commonGitDir.Count -and $commonGitDir[0]) { $outcomeRepo = Split-Path -Leaf (Split-Path -Parent ([string]$commonGitDir[0]).Trim()) }
$gitProbe = & git -C $projectRoot rev-parse --show-toplevel 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "CLAUDE_INVOKE_FAIL: project path is not a git repo: $projectRoot`n$($gitProbe -join "`n")"
}

if (-not $Preflight -and -not $Effort) {
    [Console]::Error.WriteLine('CLAUDE_INVOKE_FAIL: substantive invocation requires -Effort.')
    exit 1
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
    if ($SelectionReason -match '[\r\n]') {
        throw "CLAUDE_INVOKE_FAIL: -SelectionReason must be one line."
    }
    $SelectionReason = $SelectionReason.Trim()
    if ([string]::IsNullOrWhiteSpace($SelectionReason)) {
        throw "CLAUDE_INVOKE_FAIL: substantive invocation requires -SelectionReason. Report the selected model and this reason in chat before dispatch."
    }
    if ($SelectionReason.Length -gt 240) {
        throw "CLAUDE_INVOKE_FAIL: -SelectionReason must be 240 characters or fewer."
    }
}

$repoRoot = Resolve-SkillRepoRoot
. (Join-Path $repoRoot "scripts\security\redact-secrets.ps1")
# Child-process test seam: replace diagnosis network/clock and offline sleep together.
$script:RouterDispatchSleep = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
if ($env:DT_BUILD_DISPATCH_SEAMS) {
    [Console]::Error.WriteLine('DT_BUILD_DISPATCH_SEAMS_ACTIVE')
    . $env:DT_BUILD_DISPATCH_SEAMS
}

. (Join-Path $repoRoot "scripts\claude-cli-result.ps1")
. (Join-Path $repoRoot "scripts\resolve-codex-model.ps1")
. (Join-Path $repoRoot "scripts\model-router\resolve-model.ps1")

$isProtected = [bool]$Protected
if ([string]::IsNullOrWhiteSpace($Category)) {
    $mappedCategory = ConvertTo-RouterCategoryFromTier -Tier $Tier
    $Category = $mappedCategory.category
    $isProtected = $isProtected -or $mappedCategory.protected
}
$escalatedFrom = if ([string]::IsNullOrWhiteSpace($EscalateFrom)) { $null } else { $EscalateFrom.Trim() }
try {
    $routerPick = Resolve-RouterModel -Category $Category -Lane claude -Protected:$isProtected -EscalateFrom $escalatedFrom -SendAlerts -ChatToStderr:$Json
}
catch { throw "CLAUDE_INVOKE_FAIL: model router failed: $($_.Exception.Message)" }
if ($routerPick.status -eq 'wait' -and ([string]::IsNullOrWhiteSpace($Model) -or (Get-RouterVendorBlocked -Vendor claude))) {
    $waitReason = "ROUTER_WAIT: $($routerPick.reason)"
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $waitProvenance = [pscustomobject]@{
            pass = $false; preflight = [bool]$Preflight; lane = 'claude'; tier = $Tier; effort = $Effort
            category = $Category; protected = [bool]$routerPick.protected; escalated_from = $escalatedFrom
            router_status = 'wait'; router_reason = $routerPick.reason
            router_table_source = $routerPick.table_source; router_table_date = $routerPick.table_date
            job = $routerPick.job; vendor = $routerPick.vendor
            requested_model = $Model; resolved_model = $null
            selection_reason = if ($Preflight) { $null } else { $SelectionReason }
            failure_category = 'environment'; termination_reason = $waitReason
        }
        $waitPath = [IO.Path]::GetFullPath("$OutputPath.provenance.json")
        New-Item -ItemType Directory -Path (Split-Path -Parent $waitPath) -Force | Out-Null
        [IO.File]::WriteAllText($waitPath, ($waitProvenance | ConvertTo-Json -Depth 5))
    }
    throw $waitReason
}
$isProtected = [bool]$routerPick.protected
if ([string]::IsNullOrWhiteSpace($Model)) {
    $resolvedModel = [string]$routerPick.model
    $routerReason = [string]$routerPick.reason
}
else {
    $resolvedModel = $Model
    $routerReason = "Explicit -Model override; router pick was $($routerPick.model) ($($routerPick.reason))"
}
$selectionLabel = $Category + $(if ($isProtected) { ', protected' } else { '' }) + $(if ($escalatedFrom) { ", escalated from $escalatedFrom" } else { '' })
$disclosureLine = if ($Preflight) { $null } else {
    "MODEL_SELECTION: $promptChunkId -> $resolvedModel ($selectionLabel, effort $Effort): $SelectionReason; router: $routerReason"
}
$claudeCli = Get-ClaudeCliPath
# The exact model version the CLI reports; null until a run is parsed.
$actualModel = $null

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
# Slim session: no MCP servers and only the built-in tools a chunk needs. This
# cuts the cold-start context (measured 2026-09-19: 42K -> 25K tokens) and removes
# the Agent tool, so a chunk cannot spawn nested agents outside the tier policy.
# -ReadOnly (verifier/review chunks) also drops the file-writing tools.
$toolList = if ($Preflight) { 'Read' } elseif ($ReadOnly) { 'Bash,Read,Glob,Grep' } else { 'Bash,Read,Edit,Write,Glob,Grep' }
$args = @(
    '-p',
    '--model', $resolvedModel,
    '--permission-mode', $permissionMode,
    '--output-format', 'json',
    '--strict-mcp-config',
    '--tools', $toolList
)

if ($Effort) { $args = @($args[0..2]) + @('--effort', $Effort) + @($args[3..($args.Count - 1)]) }

$dispatchStarted = [datetimeoffset](& $script:RouterDiagnosisClock)
$dispatchId = [guid]::NewGuid().ToString('N')
$diagnosis = $null
$dispatchDiagnosis = $null
$backupPick = $null
$unexplainedRetried = $false
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

    :dispatch do {
    $diagnosis = $null
    $dispatchDiagnosis = $null
    if ($proc) { $proc.Dispose() }
    # Never accept a retained message from an earlier failed launch.
    Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $startInfo
    if (-not $proc.Start()) { throw "CLAUDE_INVOKE_FAIL: failed to start claude CLI." }

    # Start both drains before writing stdin so neither native pipe can fill and
    # deadlock the process.
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $stdinTask = $proc.StandardInput.WriteAsync($prompt)
    $stdinClosed = $false
    while (-not $proc.HasExited -and (([datetimeoffset](& $script:RouterDiagnosisClock) - $dispatchStarted).TotalMilliseconds -lt $TimeoutMs)) {
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

    # claude -p returns a JSON envelope on stdout (final message + modelUsage naming
    # the exact model version that ran); stderr is the stream log.
    $cliResult = $null
    $cliResultError = $null
    if (-not $timedOut -and $exitCode -eq 0) {
        try { $cliResult = ConvertFrom-ClaudeCliResult -Stdout $stdout -RequestedModel $resolvedModel }
        catch { $cliResultError = $_.Exception.Message }
    }
    if ($cliResult) { $actualModel = $cliResult.resolved_model }
    $lastMessage = Invoke-SecretRedaction -Text $(if ($cliResult) { $cliResult.result } else { '' })
    $lastMessage = [regex]::Replace($lastMessage, '\A(?:\[\d{1,2}:\d{2}(?::\d{2})?\][ \t]*)+', '')
    $streamText = Invoke-SecretRedaction -Text $stderr
    if (-not $cliResult) { $streamText += "`n--- stdout ---`n" + (Invoke-SecretRedaction -Text $stdout) }
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
    elseif ($cliResultError) {
        $failureReason = "CLAUDE_INVOKE_FAIL: $cliResultError Redacted stream: $streamPath"
        $failureCategory = 'tooling'
    }
    elseif ($cliResult.is_error) {
        $failureReason = "CLAUDE_INVOKE_FAIL: claude -p reported is_error. Redacted stream: $streamPath"
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

    $limitBlock = $null
    if (-not $timedOut -and ($exitCode -ne 0 -or $cliResultError -or ($cliResult -and $cliResult.is_error))) {
        $claudeErrorText = $stderr
        try {
            $errorEnvelope = $stdout | ConvertFrom-Json -Depth 40 -ErrorAction Stop
            if ($errorEnvelope.PSObject.Properties['error'] -and $errorEnvelope.error) {
                $claudeErrorText += "`n" + [string]$errorEnvelope.error
            }
            if ($errorEnvelope.PSObject.Properties['is_error'] -and $errorEnvelope.is_error -and
                $errorEnvelope.PSObject.Properties['result'] -and
                (-not $errorEnvelope.PSObject.Properties['subtype'] -or $errorEnvelope.subtype -ne 'error_max_turns')) {
                $claudeErrorText += "`n" + [string]$errorEnvelope.result
            }
        } catch { }
        $refusal = Test-RouterLimitRefusal -Vendor claude -Text $claudeErrorText
        if ($refusal.refused) {
            $blockArgs = @{ Vendor='claude'; Reason='usage-limit refusal from claude -p' }
            if ($refusal.reset_at_utc) { $blockArgs.ResetAtUtc = [datetimeoffset]$refusal.reset_at_utc }
            $limitBlock = Add-RouterVendorBlock @blockArgs
            $failureReason = "ROUTER_LIMIT: claude at its usage limit until $($limitBlock.reset_at_utc)"
            $failureCategory = 'environment'
        }

        elseif ($exitCode -ne 0) {
            $dispatchDiagnosis = Resolve-RouterDispatchFailure -Vendor claude -ErrorText $claudeErrorText
            $diagnosis = $dispatchDiagnosis.verdict
            $failureCategory = 'environment'
            # Only nonterminal events need a wrapper row; terminal events come from provenance.
            $appendEvent = {
                $row = [ordered]@{
                    key = ($dispatchId + ':' + [guid]::NewGuid().ToString('N')); at = ([datetimeoffset](& $script:RouterDiagnosisClock)).ToUniversalTime().ToString('o')
                    run_id = $(if ($Preflight) { 'preflight' } else { $promptRunId }); repo = $outcomeRepo
                    lane = 'claude'; model = $resolvedModel; category = $Category; attempt = $Attempt
                    pass = $false; escalated = $false; failure_category = 'environment'; diagnosis = $diagnosis; source = 'dt-build'; tier = $Tier
                }
                Add-RouterOutcome -Row $row
            }
            switch ($diagnosis) {
                'offline' {
                    $outageStart = [datetimeoffset](& $script:RouterDiagnosisClock)
                    do {
                        $remaining = $TimeoutMs - (([datetimeoffset](& $script:RouterDiagnosisClock)) - $dispatchStarted).TotalMilliseconds
                        if ($remaining -le 0) { break }
                        & $script:RouterDispatchSleep ([int][Math]::Min(60000, $remaining))
                        if ((([datetimeoffset](& $script:RouterDiagnosisClock)) - $dispatchStarted).TotalMilliseconds -ge $TimeoutMs) { break }
                        $dispatchDiagnosis = Resolve-RouterDispatchFailure -Vendor claude -ErrorText ''
                    } while ($dispatchDiagnosis.verdict -eq 'offline')
                    if ($dispatchDiagnosis.verdict -ne 'offline' -and (([datetimeoffset](& $script:RouterDiagnosisClock)) - $dispatchStarted).TotalMilliseconds -lt $TimeoutMs) {
                        if ((([datetimeoffset](& $script:RouterDiagnosisClock)) - $outageStart).TotalMinutes -gt 5) {
                            $etZone = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
                            $key = 'router-offline:' + [TimeZoneInfo]::ConvertTime($outageStart, $etZone).ToString('yyyy-MM-dd HH:mm') + ' ET'
                            $null = Send-RouterAlert -Key $key -Message (Get-RouterAlertMessage -Key $key) -ChatToStderr:$Json
                        }
                        & $appendEvent
                        if ($dispatchDiagnosis.verdict -eq 'vendor_incident') {
                            $diagnosis = 'vendor_incident'
                            $backupPick = Resolve-RouterModel -Category $Category -Lane codex -Protected:$isProtected -SkipModelCheck -SendAlerts -ChatToStderr:$Json
                            $failureReason = 'ROUTER_VENDOR_INCIDENT'
                            break
                        }
                        continue dispatch
                    }
                    $failureReason = 'ROUTER_OFFLINE'
                }
                'vendor_incident' {
                    $backupPick = Resolve-RouterModel -Category $Category -Lane codex -Protected:$isProtected -SkipModelCheck -SendAlerts -ChatToStderr:$Json
                    $failureReason = 'ROUTER_VENDOR_INCIDENT'
                }
                'unexplained' {
                    if (-not $unexplainedRetried) { & $appendEvent; $unexplainedRetried = $true; continue dispatch }
                    $failureReason = 'ROUTER_UNEXPLAINED'
                    $key = 'vendor-error:claude:' + $dispatchId
                    $message = Get-RouterAlertMessage -Key $key -Model $resolvedModel -Category $Category -ErrorText $claudeErrorText -Checks $dispatchDiagnosis.checks -ArtifactPath $provenancePath -PromptText $prompt -InvocationText ($startInfo.ArgumentList -join ' ')
                    $null = Send-RouterAlert -Key $key -Message $message -ChatToStderr:$Json
                }
            }
        }
    }

    break
    } while ($true)
    if ($failureReason -in @('ROUTER_OFFLINE','ROUTER_VENDOR_INCIDENT','ROUTER_UNEXPLAINED')) {
        $failureCategory = 'environment'
    } else {
        $diagnosis = $null
        $dispatchDiagnosis = $null
    }

    $cliVersion = if ([System.IO.Path]::GetExtension($claudeCli).ToLowerInvariant() -eq '.ps1') {
        (& pwsh -NoProfile -File $claudeCli --version 2>&1) -join ' '
    } else { (& $claudeCli --version 2>&1) -join ' ' }

    $result = [pscustomobject]@{
        pass                = [string]::IsNullOrWhiteSpace($failureReason)
        preflight           = [bool]$Preflight
        lane                = 'claude'
        effort              = $Effort
        tier                = $Tier
        category            = $Category
        protected           = $isProtected
        escalated_from      = $escalatedFrom
        router_reason       = $routerReason
        router_table_source = $routerPick.table_source
        router_table_date   = $routerPick.table_date
        job                 = $routerPick.job
        vendor              = $routerPick.vendor
        requested_model     = $resolvedModel
        resolved_model      = $actualModel
        models_used         = @(if ($cliResult) { $cliResult.models_used })
        total_cost_usd      = if ($cliResult) { $cliResult.total_cost_usd } else { $null }
        selection_reason    = if ($Preflight) { $null } else { $SelectionReason }
        disclosure_line     = $disclosureLine
        permission_mode     = $permissionMode
        tools               = $toolList
        mcp_servers         = 'none (--strict-mcp-config)'
        attempt             = $Attempt
        claude_cli_version  = $cliVersion
        duration_ms         = $durationMs
        timeout_ms          = $TimeoutMs
        prompt_sha256       = $promptSha256
        output_sha256       = if (Test-Path -LiteralPath $OutputPath) { (Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
        output_path         = if ($temporaryOutput -or -not (Test-Path -LiteralPath $OutputPath)) { $null } else { (Resolve-Path -LiteralPath $OutputPath).Path }
        stream_log_path     = if ($temporaryOutput -or -not (Test-Path -LiteralPath $streamPath)) { $null } else { (Resolve-Path -LiteralPath $streamPath).Path }
        failure_category    = $failureCategory
        diagnosis              = $diagnosis
        dispatch_diagnosis     = $dispatchDiagnosis
        backup_pick            = $backupPick
        dispatch_id            = $dispatchId
        vendor_block        = $limitBlock
        termination_reason  = $failureReason
        output_shape_errors = @($shapeErrors)
    }

    if (-not $temporaryOutput) {
        [System.IO.File]::WriteAllText($provenancePath, ($result | ConvertTo-Json -Depth 8))
        $provenanceWritten = $true
        $result | Add-Member -NotePropertyName provenance_path -NotePropertyValue (Resolve-Path -LiteralPath $provenancePath).Path
    }

    if (-not $result.pass -and $diagnosis) {
        if ($Json) { $result | ConvertTo-Json -Depth 8 } else { $result }
        exit 1
    }
    if (-not $result.pass) { throw $failureReason }
    if ($Json) { $result | ConvertTo-Json -Depth 5 }
    else { $result }
}
catch {
    if (-not $temporaryOutput -and -not $provenanceWritten) {
        $durationMs = [int][Math]::Round(((Get-Date) - $started).TotalMilliseconds)
        $fallback = [pscustomobject]@{
            pass = $false; preflight = [bool]$Preflight; lane = 'claude'; tier = $Tier; effort = $Effort
            category = $Category; protected = $isProtected; escalated_from = $escalatedFrom
            router_reason = $routerReason; router_table_source = $routerPick.table_source; router_table_date = $routerPick.table_date
            job = $routerPick.job; vendor = $routerPick.vendor
            requested_model = $resolvedModel; resolved_model = $actualModel
            selection_reason = if ($Preflight) { $null } else { $SelectionReason }
            disclosure_line = $disclosureLine
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
