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
    [ValidateSet('standard','hard')][string]$Difficulty = 'standard',
    [string]$DifficultyReason = "",
    [string]$RetryAtHardFrom = "",
    [string]$Model = "",
    [string]$SelectionReason = "",
    [ValidateSet('low', 'medium', 'high', 'xhigh')][string]$Effort,
    [ValidateRange(1, 2)][int]$Attempt = 1,
    [ValidateRange(1000, 3600000)][int]$TimeoutMs = 600000,
    [switch]$Preflight,
    [switch]$ReadOnly,
    [switch]$Scrutiny,
    [string]$CodexCliPath = "",
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($Scrutiny -and -not $ReadOnly) { throw 'SCRUTINY_REQUIRES_READ_ONLY' }

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

# Report shape (v3, with v2 accepted and flagged) is shared with the other wrapper.
. (Join-Path $PSScriptRoot 'report-contract.ps1')

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
# Outcome rows name the canonical repo (the main checkout's folder), also when building in a linked worktree.
$outcomeRepo = Split-Path -Leaf $projectRoot
$commonGitDir = @(& git -C $projectRoot rev-parse --path-format=absolute --git-common-dir 2>$null)
if ($LASTEXITCODE -eq 0 -and $commonGitDir.Count -and $commonGitDir[0]) { $outcomeRepo = Split-Path -Leaf (Split-Path -Parent ([string]$commonGitDir[0]).Trim()) }
$gitProbe = & git -C $projectRoot rev-parse --show-toplevel 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "CODEX_INVOKE_FAIL: project path is not a git repo: $projectRoot`n$($gitProbe -join "`n")"
}

if (-not $Preflight -and -not $Effort) {
    [Console]::Error.WriteLine('CODEX_INVOKE_FAIL: substantive invocation requires -Effort.')
    exit 1
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
. (Join-Path $repoRoot "scripts\model-router\resolve-model.ps1")
. (Join-Path $repoRoot "scripts\security\redact-secrets.ps1")
. (Join-Path $repoRoot "scripts\invoke-codex-process.ps1")
# Child-process test seam: replace diagnosis network/clock and offline sleep together.
$script:RouterDispatchSleep = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds }
if ($env:DT_BUILD_DISPATCH_SEAMS) {
    [Console]::Error.WriteLine('DT_BUILD_DISPATCH_SEAMS_ACTIVE')
    . $env:DT_BUILD_DISPATCH_SEAMS
}


$codexCli = Get-CodexCliPath
# No model names live here: refresh the live account catalog and let the shared model
# router pick for the chunk's category. -Model is an explicit override only.
try { $modelCatalog = Update-CodexModelCatalog -CodexCliPath $codexCli }
catch { throw "CODEX_INVOKE_FAIL: $($_.Exception.Message)" }
$modelLadder = @(Get-CodexModelLadder -Catalog $modelCatalog)
$workstation = if ($projectRoot -match '[/\\]_Claude-Workspace[/\\]([^/\\]+)') { $Matches[1] } else { Split-Path -Leaf (Split-Path -Parent $projectRoot) }
$isProtected = [bool]$Protected
if ([string]::IsNullOrWhiteSpace($Category)) {
    $mappedCategory = ConvertTo-RouterCategoryFromTier -Tier $Tier
    $Category = $mappedCategory.category
    $isProtected = $isProtected -or $mappedCategory.protected
}
try {
    $Difficulty = $Difficulty.ToLowerInvariant()
    if ($RetryAtHardFrom) { $Difficulty = 'hard' }
    Test-RouterDifficulty -Difficulty $Difficulty -DifficultyReason $DifficultyReason
    $routingDifficultyArgs = @{}
    if ($PSBoundParameters.ContainsKey('Difficulty') -or $PSBoundParameters.ContainsKey('DifficultyReason') -or $RetryAtHardFrom) { $routingDifficultyArgs = @{Difficulty=$Difficulty;DifficultyReason=$DifficultyReason} }
    $resolvedDifficulty = if ((Get-RouterCategoryJob -Category $Category) -in @('coder','deep-thinker') -or ($isProtected -and $Category -eq 'mechanical')) { $Difficulty } else { $null }
    $escalatedFrom = if ([string]::IsNullOrWhiteSpace($EscalateFrom)) { $null } else { $EscalateFrom.Trim() }

    $routerPick = Resolve-RouterModel -Category $Category -Lane codex -Protected:$isProtected @routingDifficultyArgs -EscalateFrom $escalatedFrom -RetryAtHardFrom $RetryAtHardFrom -Catalog $modelCatalog -SendAlerts:(-not $Scrutiny) -ChatToStderr:$Json
}
catch { throw "CODEX_INVOKE_FAIL: model router failed: $($_.Exception.Message)" }
if ($routerPick.status -eq 'wait' -and ([string]::IsNullOrWhiteSpace($Model) -or (Get-RouterVendorBlocked -Vendor codex))) {
    $waitReason = "ROUTER_WAIT: $($routerPick.reason)"
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $waitProvenance = [pscustomobject]@{
            pass = $false; preflight = [bool]$Preflight; tier = $Tier; effort = $Effort; reasoning_effort = $Effort
            workstation = $workstation; dispatched_at_utc = [datetimeoffset]::UtcNow.ToString('o'); difficulty = $resolvedDifficulty; difficulty_reason = $(if ($resolvedDifficulty) { $DifficultyReason } else { $null }); retry_at_hard_from = $RetryAtHardFrom
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
$preferred = if ([string]::IsNullOrWhiteSpace($Model)) { $null } else { $Model }
if ($preferred) {
    $resolvedModel = Resolve-CodexModel -Category $Category -Protected:$isProtected -PreferredModel $preferred -Catalog $modelCatalog -Strict
    $routerReason = "Explicit -Model override; router pick was $($routerPick.model) ($($routerPick.reason))"
}
else {
    $resolvedModel = [string]$routerPick.model
    if (-not (Test-RouterCodexSelectable -ParsedCatalog $modelCatalog -Model $resolvedModel)) {
        throw "CODEX_INVOKE_FAIL: router pick '$resolvedModel' for category '$Category' is not selectable on this account ($($routerPick.reason))."
    }
    $routerReason = [string]$routerPick.reason
}
if ($Effort) { [void](Assert-CodexReasoningEffort -Model $resolvedModel -Effort $Effort -Catalog $modelCatalog -Strict) }
$selectionLabel = $Category + $(if ($isProtected) { ', protected' } else { '' }) + $(if ($escalatedFrom) { ", escalated from $escalatedFrom" } else { '' })
$disclosureLine = if ($Preflight) { $null } else {
    "MODEL_SELECTION: $promptChunkId -> $resolvedModel ($selectionLabel, effort $Effort): $SelectionReason; router: $routerReason"
}

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
$sandbox = if ($Preflight -or $ReadOnly) { 'read-only' } else { 'workspace-write' }
# Codex removed its Windows sandbox (features experimental_windows_sandbox /
# elevated_windows_sandbox report "removed"), so under --ignore-user-config a
# workspace-write request fails closed to read-only and blocks every command
# before process launch. On Windows, substantive chunks therefore run
# unsandboxed via explicit default_permissions; containment is the scoped
# worktree plus the orchestrator's independent verification. Preflight and
# non-Windows hosts keep the real sandbox. Verified 2026-08-30, codex-cli 0.151.0.
$windowsUnsandboxed = (-not $Preflight -and -not $ReadOnly) -and ($env:OS -eq 'Windows_NT')
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
    '--output-last-message', $OutputPath,
    '-'
)

if ($Effort) { $args = @($args[0..($args.Count - 2)]) + @('-c', ('model_reasoning_effort="{0}"' -f $Effort), '-') }

$dispatchStarted = [datetimeoffset](& $script:RouterDiagnosisClock)
$dispatchId = [guid]::NewGuid().ToString('N')
$diagnosis = $null
$dispatchDiagnosis = $null
$backupPick = $null
$unexplainedRetried = $false
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
        $prefixArgs = @(Get-Utf8PowerShellArguments -ScriptPath $codexCli)
    }
    else {
        $startInfo.FileName = $codexCli
    }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $utf8 = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardInputEncoding = $utf8
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
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
    if (-not $proc.Start()) { throw "CODEX_INVOKE_FAIL: failed to start codex CLI." }

    # Start both drains before writing stdin so neither native pipe can fill and
    # deadlock the process. The same pattern protects high-volume verifier runs.
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
    $reportVersionWarning = $null
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
    elseif (-not $Preflight -and -not $Scrutiny) {
        $shape = Get-ReportShapeResult -Text $lastMessage -RunId $promptRunId -ChunkId $promptChunkId -ExpectedAttempt $Attempt
        $shapeErrors = @($shape.errors)
        $reportVersionWarning = $shape.warning
        if ($shapeErrors.Count -gt 0) {
            $failureReason = "CODEX_OUTPUT_INVALID: $($shapeErrors -join '; '). Redacted output: $OutputPath"
            $failureCategory = 'model-output'
        }
    }

    $limitBlock = $null
    if (-not $timedOut -and $exitCode -ne 0) {
        # Without --json, codex exec writes progress and errors to stderr and only the final agent
        # message to stdout, so stdout is model text and never a source of error events.
        $codexErrorText = $stderr
        $refusal = Test-RouterLimitRefusal -Vendor codex -Text $codexErrorText
        if ($refusal.refused) {
            $blockArgs = @{ Vendor='codex'; Reason='usage-limit refusal from codex exec' }
            if ($refusal.reset_at_utc) { $blockArgs.ResetAtUtc = [datetimeoffset]$refusal.reset_at_utc }
            $limitBlock = Add-RouterVendorBlock @blockArgs
            $failureReason = "ROUTER_LIMIT: codex at its usage limit until $($limitBlock.reset_at_utc)"
            $failureCategory = 'environment'
        }

        else {
            $dispatchDiagnosis = Resolve-RouterDispatchFailure -Vendor codex -ErrorText $codexErrorText
            $diagnosis = $dispatchDiagnosis.verdict
            $failureCategory = 'environment'
            # Only nonterminal events need a wrapper row; terminal events come from provenance.
            $appendEvent = {
                $row = [ordered]@{
                    key = ($dispatchId + ':' + [guid]::NewGuid().ToString('N')); at = ([datetimeoffset](& $script:RouterDiagnosisClock)).ToUniversalTime().ToString('o')
                    run_id = $(if ($Preflight) { 'preflight' } else { $promptRunId }); repo = $outcomeRepo
                    lane = 'codex'; model = $resolvedModel; category = $Category; attempt = $Attempt
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
                        $dispatchDiagnosis = Resolve-RouterDispatchFailure -Vendor codex -ErrorText ''
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
                            $backupPick = Resolve-RouterModel -Category $Category -Lane claude -Protected:$isProtected @routingDifficultyArgs -SkipModelCheck -SendAlerts -ChatToStderr:$Json
                            $failureReason = 'ROUTER_VENDOR_INCIDENT'
                            break
                        }
                        continue dispatch
                    }
                    $failureReason = 'ROUTER_OFFLINE'
                }
                'vendor_incident' {
                    $backupPick = Resolve-RouterModel -Category $Category -Lane claude -Protected:$isProtected @routingDifficultyArgs -SkipModelCheck -SendAlerts -ChatToStderr:$Json
                    $failureReason = 'ROUTER_VENDOR_INCIDENT'
                }
                'unexplained' {
                    if (-not $unexplainedRetried) { & $appendEvent; $unexplainedRetried = $true; continue dispatch }
                    $failureReason = 'ROUTER_UNEXPLAINED'
                    $key = 'vendor-error:codex:' + $dispatchId
                    $message = Get-RouterAlertMessage -Key $key -Model $resolvedModel -Category $Category -ErrorText $codexErrorText -Checks $dispatchDiagnosis.checks -ArtifactPath $provenancePath -PromptText $prompt -InvocationText ($startInfo.ArgumentList -join ' ')
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

    $cliVersion = if ([System.IO.Path]::GetExtension($codexCli).ToLowerInvariant() -eq '.ps1') {
        ($null | & pwsh -NoProfile -File $codexCli --version 2>&1) -join ' '
    } else { ($null | & $codexCli --version 2>&1) -join ' ' }
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
        workstation = $workstation
        dispatched_at_utc = $started.ToUniversalTime().ToString('o')
        difficulty             = $resolvedDifficulty
        difficulty_reason      = $(if ($resolvedDifficulty) { $DifficultyReason } else { $null })
        retry_at_hard_from     = $RetryAtHardFrom
        category               = $Category
        protected              = $isProtected
        escalated_from         = $escalatedFrom
        router_reason          = $routerReason
        router_table_source    = $routerPick.table_source
        router_table_date      = $routerPick.table_date
        job                    = $routerPick.job
        vendor                 = $routerPick.vendor
        requested_model        = $preferred
        resolved_model         = $resolvedModel
        model_ladder           = $modelLadder
        selection_reason       = if ($Preflight) { $null } else { $SelectionReason }
        disclosure_line        = $disclosureLine
        effort                 = $Effort
        reasoning_effort       = $Effort
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
        diagnosis              = $diagnosis
        dispatch_diagnosis     = $dispatchDiagnosis
        backup_pick            = $backupPick
        dispatch_id            = $dispatchId
        vendor_block           = $limitBlock
        termination_reason     = $failureReason
        output_shape_errors    = @($shapeErrors)
        report_version_warning = $reportVersionWarning
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
    $completedSuccessfully = $true
}
catch {
    if (-not $temporaryOutput -and -not $provenanceWritten) {
        $durationMs = [int][Math]::Round(((Get-Date) - $started).TotalMilliseconds)
        $fallback = [pscustomobject]@{
            pass = $false; preflight = [bool]$Preflight; tier = $Tier; effort = $Effort; reasoning_effort = $Effort
            workstation = $workstation; dispatched_at_utc = [datetimeoffset]::UtcNow.ToString('o'); difficulty = $resolvedDifficulty; difficulty_reason = $(if ($resolvedDifficulty) { $DifficultyReason } else { $null }); retry_at_hard_from = $RetryAtHardFrom
            category = $Category; protected = $isProtected; escalated_from = $escalatedFrom
            router_reason = $routerReason; router_table_source = $routerPick.table_source; router_table_date = $routerPick.table_date
            job = $routerPick.job; vendor = $routerPick.vendor
            requested_model = $preferred; resolved_model = $resolvedModel
            selection_reason = if ($Preflight) { $null } else { $SelectionReason }
            disclosure_line = $disclosureLine
            attempt = $Attempt; sandbox = $sandbox
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
