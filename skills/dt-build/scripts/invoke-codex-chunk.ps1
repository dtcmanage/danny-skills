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
    [ValidateRange(1000, 2147483647)][int]$TimeoutMs = 600000,
    # Vendor capacity is transient: retry the identical invocation after 5/10/20 minutes.
    # Milliseconds permit fast fixtures; an empty array disables capacity retries.
    [AllowEmptyCollection()][ValidateRange(0, 2147483647)][int[]]$CapacityBackoffMs = @(300000, 600000, 1200000),
    [switch]$Preflight,
    [switch]$ReadOnly,
    [switch]$Scrutiny,
    [switch]$AdHoc,
    [switch]$AllowOutputInProject,
    [switch]$ValidateOnly,
    [ValidateRange(1, 2147483647)][int]$MaxFixRounds = 2,
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
if ($AdHoc -and -not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = [IO.Path]::GetFullPath($OutputPath)
    $projectPrefix = [IO.Path]::GetFullPath($projectRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $AllowOutputInProject -and ($OutputPath.Equals($projectPrefix.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase) -or $OutputPath.StartsWith($projectPrefix, [StringComparison]::OrdinalIgnoreCase))) {
        throw 'CODEX_OUTPUT_IN_PROJECT: -AdHoc -OutputPath must be outside -ProjectPath; pass -AllowOutputInProject to opt in.'
    }
}
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

$runPinVendor = $env:DT_BUILD_RUN_PIN_VENDOR
$runPinModel = $env:DT_BUILD_RUN_PIN_MODEL
$runPinActive = -not [string]::IsNullOrWhiteSpace($runPinVendor)
$selectionSuffix = ''
if (-not $Preflight -and $SelectionReason -match '[\r\n]') { throw 'CODEX_INVOKE_FAIL: -SelectionReason must be one line.' }
if ($runPinActive) {
    $pinFailure = if ($runPinVendor -ine 'codex') {
        'CODEX_INVOKE_FAIL: RUN_PIN_VENDOR: run is pinned to ' + $runPinVendor + ' (' + $runPinModel + '); codex wrapper refused.'
    } elseif (-not [string]::IsNullOrWhiteSpace($Model) -and $Model -cne $runPinModel) {
        'CODEX_INVOKE_FAIL: RUN_PIN_MODEL: run is pinned to ' + $runPinModel + '; explicit model ' + $Model + ' refused.'
    } elseif ([string]::IsNullOrWhiteSpace($runPinModel)) {
        'CODEX_INVOKE_FAIL: RUN_PIN_MODEL: run pin model is missing.'
    } else { $null }
    if ($pinFailure) {
        if (-not $ValidateOnly -and -not [string]::IsNullOrWhiteSpace($OutputPath)) {
            $pinProvenance = [ordered]@{
                pass = $false; preflight = [bool]$Preflight; lane = 'codex'; vendor = 'codex'; tier = $Tier; effort = $Effort
                category = $Category; requested_model = $Model; resolved_model = $null
                router_reason = 'run pin'; selection_reason = $SelectionReason
                output_path = $OutputPath; failure_category = 'environment'; termination_reason = $pinFailure
                dispatched_at_utc = [datetimeoffset]::UtcNow.ToString('o')
            }
            $pinPath = [IO.Path]::GetFullPath("$OutputPath.provenance.json")
            New-Item -ItemType Directory -Path (Split-Path -Parent $pinPath) -Force | Out-Null
            [IO.File]::WriteAllText($pinPath, ($pinProvenance | ConvertTo-Json -Depth 5))
        }
        throw $pinFailure
    }
    $Model = $runPinModel
    $selectionSuffix = if ([string]::IsNullOrWhiteSpace($SelectionReason)) { '' } else { '; run pin ' + $runPinModel }
    $SelectionReason = if ([string]::IsNullOrWhiteSpace($SelectionReason)) { 'run pin' } else { $SelectionReason.Trim() + $selectionSuffix }
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
    . (Join-Path $PSScriptRoot 'worker-standing-rules.ps1')
    $fixRoundRule = Get-WorkerFixRoundRule -MaxFixRounds $MaxFixRounds
    if ($AdHoc) { $promptText += "`nStanding execution rules:`n- $fixRoundRule`n" }
    elseif ($PSBoundParameters.ContainsKey('MaxFixRounds')) {
        $rulePattern = '(?m)^- Run the full named test selection[^\r\n]*'
        if ($promptText -match $rulePattern) { $promptText = [regex]::Replace($promptText, $rulePattern, { param($match) '- ' + $fixRoundRule }) }
        else { $promptText += "`nStanding execution rules:`n- $fixRoundRule`n" }
    }
    # Pasted sources, evidence packets and histories have pushed review prompts past Codex's
    # 1,048,576-character cap. Refuse well below it, before anything is dispatched.
    $maxPromptChars = 400000
    $limitText = [System.Environment]::GetEnvironmentVariable('DT_BUILD_PROMPT_MAX_CHARS')
    $parsedLimit = 0
    if ($limitText -and [int]::TryParse($limitText, [ref]$parsedLimit) -and $parsedLimit -gt 0) { $maxPromptChars = $parsedLimit }
    if ($promptText.Length -gt $maxPromptChars) {
        throw "CODEX_INVOKE_FAIL: PROMPT_TOO_LARGE: the prompt is $($promptText.Length) characters, over the $maxPromptChars limit. Pass file paths with sha256 pins and let the worker read and hash them itself; never paste sources, evidence packets or histories."
    }
    # An ad-hoc call (one-off delegated work outside a dt-build run) keeps routing, the usage ledger,
    # error classification and stall reporting, but its prompt and report carry no dt-build envelope.
    if ($AdHoc) {
        $promptRunId = 'adhoc'
        $promptChunkId = 'adhoc-' + [System.IO.Path]::GetFileNameWithoutExtension($PromptPath)
    }
    else {
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
    }
    if ($SelectionReason -match '[\r\n]') {
        throw "CODEX_INVOKE_FAIL: -SelectionReason must be one line."
    }
    $SelectionReason = $SelectionReason.Trim()
    if ([string]::IsNullOrWhiteSpace($SelectionReason)) {
        throw "CODEX_INVOKE_FAIL: substantive invocation requires -SelectionReason. Report the selected model and this reason in chat before dispatch."
    }
    if ($SelectionReason.Length -gt 240) {
        throw "CODEX_INVOKE_FAIL: SELECTION_REASON_TOO_LONG: effective length $($SelectionReason.Length), suffix length $($selectionSuffix.Length), cap 240."
    }
}

function Get-ReadOnlyTreeSnapshot {
    # The project's state as comparable entries: git HEAD, status, tracked diff and untracked file contents, or for
    # a non-git folder every file's path, size and write time. Paths under -IgnoreDir (the wrapper's own
    # output folder) and any .dt-build folder are left out.
    param([Parameter(Mandatory)][string]$Root, [string]$IgnoreDir)
    $ignore = if ($IgnoreDir) { [System.IO.Path]::GetFullPath($IgnoreDir).TrimEnd('\', '/') } else { $null }
    # An output folder that contains the whole project would hide every change: ignore it only inside.
    if ($ignore -and ([System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + '\').StartsWith($ignore + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $ignore = $null }
    $skip = { param([string]$full) ($full -match '[\\/]\.dt-build([\\/]|$)') -or ($ignore -and $full.StartsWith($ignore, [System.StringComparison]::OrdinalIgnoreCase)) }
    # A fixed first entry keeps an empty folder's snapshot non-empty for Compare-Object.
    $parts = [System.Collections.Generic.List[string]]::new(); $parts.Add("root:$Root")
    $top = (& git -C $Root rev-parse --show-toplevel 2>$null | Select-Object -First 1)
    if ($LASTEXITCODE -eq 0 -and $top) {
        $head = [string](& git -C $Root rev-parse --verify -q HEAD 2>$null | Select-Object -First 1)
        $parts.Add("head:$head")
        foreach ($line in @(& git -C $Root -c core.quotepath=false status --porcelain=v1 --untracked-files=all 2>$null)) {
            if ($line.Length -lt 4) { continue }
            $rel = $line.Substring(3)
            $full = [System.IO.Path]::GetFullPath((Join-Path $top $rel))
            if (& $skip $full) { continue }
            $parts.Add($line)
            if ($line.StartsWith('??') -and (Test-Path -LiteralPath $full -PathType Leaf)) { $parts.Add((Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash) }
        }
        if ($head) { $parts.Add('diff:' + ((& git -C $Root diff HEAD --no-ext-diff --binary 2>$null) -join "`n")) }
    }
    else {
        foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue | Sort-Object FullName)) {
            if (& $skip $f.FullName) { continue }
            $parts.Add("$($f.FullName)|$($f.Length)|$($f.LastWriteTimeUtc.Ticks)")
        }
    }
    return @($parts)
}

function Get-ReadOnlyTreeChanges {
    # The snapshot entries that differ between two snapshots, at most five, for the violation message.
    param([string[]]$Before, [string[]]$After)
    $changed = @(Compare-Object -ReferenceObject @($Before) -DifferenceObject @($After) -CaseSensitive | ForEach-Object { [string]$_.InputObject })
    return @($changed | Select-Object -First 5)
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
try { $modelCatalog = if ($ValidateOnly) { Get-CodexModelCatalog } else { Update-CodexModelCatalog -CodexCliPath $codexCli } }
catch { throw "CODEX_INVOKE_FAIL: $($_.Exception.Message)" }
$modelLadder = @(Get-CodexModelLadder -Catalog $modelCatalog)
$workstation = if ($projectRoot -match '[/\\]_Claude-Workspace[/\\]([^/\\]+)') { $Matches[1] } else { Split-Path -Leaf (Split-Path -Parent $projectRoot) }
$isProtected = [bool]$Protected
if ([string]::IsNullOrWhiteSpace($Category)) {
    $mappedCategory = ConvertTo-RouterCategoryFromTier -Tier $Tier
    $Category = $mappedCategory.category
    $isProtected = $isProtected -or $mappedCategory.protected
}
# A builder or reviewer chunk routinely runs past 10 minutes; killing it there throws its work away.
# Under dt-job (DT_JOB_ID set) a substantive call has no time limit: the runner records its activity and
# the coordinator's 10-minute check-ins decide what a stall means. Called directly without an explicit
# -TimeoutMs, coder work gets 45 minutes and deep-thinker work 30.
if ($env:DT_JOB_ID -and -not $Preflight) { $TimeoutMs = [int]::MaxValue }
elseif (-not $PSBoundParameters.ContainsKey('TimeoutMs')) {
    $timeoutJob = try { Get-RouterCategoryJob -Category $Category } catch { $null }
    $TimeoutMs = switch ($timeoutJob) { 'coder' { 2700000 } 'deep-thinker' { 1800000 } default { 600000 } }
}
try {
    $Difficulty = $Difficulty.ToLowerInvariant()
    if ($RetryAtHardFrom) { $Difficulty = 'hard' }
    Test-RouterDifficulty -Difficulty $Difficulty -DifficultyReason $DifficultyReason
    $routingDifficultyArgs = @{}
    if ($PSBoundParameters.ContainsKey('Difficulty') -or $PSBoundParameters.ContainsKey('DifficultyReason') -or $RetryAtHardFrom) { $routingDifficultyArgs = @{Difficulty=$Difficulty;DifficultyReason=$DifficultyReason} }
    $resolvedDifficulty = if ((Get-RouterCategoryJob -Category $Category) -in @('coder','deep-thinker') -or ($isProtected -and $Category -eq 'mechanical')) { $Difficulty } else { $null }
    $escalatedFrom = if ([string]::IsNullOrWhiteSpace($EscalateFrom)) { $null } else { $EscalateFrom.Trim() }

    $routerPick = Resolve-RouterModel -Category $Category -Lane codex -Protected:$isProtected @routingDifficultyArgs -EscalateFrom $escalatedFrom -RetryAtHardFrom $RetryAtHardFrom -Catalog $modelCatalog -SendAlerts:(-not $Scrutiny -and -not $ValidateOnly) -ChatToStderr:$Json
}
catch { throw "CODEX_INVOKE_FAIL: model router failed: $($_.Exception.Message)" }
if ($routerPick.status -eq 'wait' -and ([string]::IsNullOrWhiteSpace($Model) -or (Get-RouterVendorBlocked -Vendor codex))) {
    $waitReason = "ROUTER_WAIT: $($routerPick.reason)"
    if (-not $ValidateOnly -and -not [string]::IsNullOrWhiteSpace($OutputPath)) {
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
if ($ValidateOnly) {
    if ($Json) { [pscustomobject]@{ pass = $true; validate_only = $true; resolved_model = $resolvedModel; selection_reason = $SelectionReason; suffix_length = $selectionSuffix.Length } | ConvertTo-Json }
    else { 'VALIDATION_OK: no dispatch or reservation; model checks used the cached catalog.' }
    exit 0
}
if ($runPinActive) { $routerReason = 'run pin' }
$selectionLabel = $Category + $(if ($isProtected) { ', protected' } else { '' }) + $(if ($escalatedFrom) { ", escalated from $escalatedFrom" } else { '' })
$disclosureLine = if ($Preflight) { $null } else {
    "MODEL_SELECTION: $promptChunkId -> $resolvedModel ($selectionLabel, effort $Effort): $SelectionReason; router: $routerReason"
}
. (Join-Path $PSScriptRoot 'model-selection.ps1')
Publish-DtJobModelSelection -Line $disclosureLine -Model $resolvedModel -Vendor 'codex' -Effort $Effort


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
    $promptText
}
$promptSha256 = if ($Preflight) {
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($prompt)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
else {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($prompt))).ToLowerInvariant()
}
$sandbox = if ($Preflight -or $ReadOnly) { 'read-only' } else { 'workspace-write' }
# Keep the existing Windows builder route separate from reviewers. Reviewers
# use a real read-only sandbox; the tree check is only a defensive backstop.
$windowsUnsandboxed = (-not $Preflight) -and (-not $ReadOnly) -and ($env:OS -eq 'Windows_NT')
$verifyReadOnly = $ReadOnly -and -not $Preflight
if ($windowsUnsandboxed) { $sandbox = 'danger-full-access (windows: codex sandbox removed upstream)' }
$sandboxArgs = if ($windowsUnsandboxed) {
    @('-c', 'default_permissions=":danger-full-access"')
} elseif ($Preflight -or $ReadOnly) {
    @(Get-CodexReadOnlySandboxArguments)
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
$dispatchAttempts = [System.Collections.Generic.List[object]]::new()
$capacityBackoffs = [System.Collections.Generic.List[object]]::new()
$started = Get-Date
$proc = $null
$completedSuccessfully = $false
$streamPath = "$OutputPath.stream.log"
$provenancePath = "$OutputPath.provenance.json"
$provenanceWritten = $false
$untrackedBefore = @()
$untrackedCreated = @()
function Get-ProjectUntrackedPaths {
    # NUL delimiters preserve spaces, quotes, Unicode and embedded newlines in paths.
    $statusText = (@(& git -C $projectRoot status --porcelain --untracked-files=all -z) -join "`n")
    if ($LASTEXITCODE -ne 0) { throw 'CODEX_UNTRACKED_STATUS_FAILED: could not inspect project untracked paths.' }
    return @($statusText.Split([char]0) | Where-Object { $_.StartsWith('?? ') } | ForEach-Object { $_.Substring(3) })
}
function Update-AdHocUntrackedPaths {
    if ($AdHoc) {
        $script:untrackedCreated = @(Get-ProjectUntrackedPaths | Where-Object { $_ -cnotin $untrackedBefore })
        if ($script:untrackedCreated.Count) { [Console]::Error.WriteLine('WARNING: ad-hoc worker created untracked paths: ' + ($script:untrackedCreated -join ', ')) }
    }
}
if ($AdHoc) { $untrackedBefore = @(Get-ProjectUntrackedPaths) }
try {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    # Coordinator-only bootstrap must never propagate to workers, including direct wrapper calls.
    $startInfo.Environment.Remove('DT_BUILD_LEAN_BOOTSTRAP') | Out-Null
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

    $readOnlyBefore = if ($verifyReadOnly) { Get-ReadOnlyTreeSnapshot -Root $projectRoot -IgnoreDir (Split-Path -Parent $OutputPath) } else { $null }
    :dispatch do {
    $attemptStarted = [datetimeoffset](& $script:RouterDiagnosisClock)
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

    if ($dispatchAttempts.Count -eq 0) { [System.IO.File]::WriteAllText($streamPath, $streamText) }
    else { [System.IO.File]::AppendAllText($streamPath, "`n--- dispatch attempt $($dispatchAttempts.Count + 1) ---`n" + $streamText) }
    $attemptRecord = [pscustomobject]@{
        dispatch_attempt = $dispatchAttempts.Count + 1
        started_at_utc = $attemptStarted.ToUniversalTime().ToString('o')
        duration_ms = [long](([datetimeoffset](& $script:RouterDiagnosisClock)) - $attemptStarted).TotalMilliseconds
        exit_code = $exitCode; timed_out = $timedOut
        model = $resolvedModel; effort = $Effort; failure_category = $null; failure_detail = $null
    }
    $dispatchAttempts.Add($attemptRecord)

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
    $failureDetail = $null
    $blockedReportDetail = Get-CodexBlockedReportDetail -Text $lastMessage
    $shapeErrors = @()
    $reportVersionWarning = $null
    if ($timedOut) {
        $failureReason = "CODEX_INVOKE_TIMEOUT: codex exec exceeded ${TimeoutMs}ms and its process tree was terminated. Redacted stream: $streamPath"
        $failureCategory = 'tooling'
    }
    elseif ($blockedReportDetail) {
        $failureDetail = $blockedReportDetail
        $failureReason = "CODEX_REVIEW_BLOCKED: ${failureDetail}. The reviewer could not inspect required inputs. Redacted output: $OutputPath"
        $failureCategory = 'environment'
    }
    elseif ($exitCode -ne 0) {
        $failureReason = "CODEX_INVOKE_FAIL: codex exec exited $exitCode. Redacted stream: $streamPath"
        $failureCategory = 'tooling'
    }

    elseif ($verifyReadOnly -and @(Get-ReadOnlyTreeChanges -Before $readOnlyBefore -After (Get-ReadOnlyTreeSnapshot -Root $projectRoot -IgnoreDir (Split-Path -Parent $OutputPath))).Count -gt 0) {
        $readOnlyChanged = @(Get-ReadOnlyTreeChanges -Before $readOnlyBefore -After (Get-ReadOnlyTreeSnapshot -Root $projectRoot -IgnoreDir (Split-Path -Parent $OutputPath)))
        $failureReason = "CODEX_READONLY_VIOLATION: the read-only worker changed files under ${projectRoot}: $($readOnlyChanged -join '; '). Its report is rejected. Redacted stream: $streamPath"
        $failureCategory = 'model-output'
    }
    elseif ([string]::IsNullOrWhiteSpace($lastMessage)) {
        $failureReason = "CODEX_INVOKE_FAIL: codex exec returned no final message. Redacted stream: $streamPath"
        $failureCategory = 'model-output'
    }
    elseif ($Preflight -and $lastMessage.Trim() -ne 'OK') {
        $failureReason = "CODEX_PREFLIGHT_FAIL: expected OK, received '$($lastMessage.Trim())'. Redacted stream: $streamPath"
        $failureCategory = 'model-output'
    }
    elseif (-not $Preflight -and -not $Scrutiny -and -not $AdHoc) {
        $shape = Get-ReportShapeResult -Text $lastMessage -RunId $promptRunId -ChunkId $promptChunkId -ExpectedAttempt $Attempt
        $shapeErrors = @($shape.errors)
        $reportVersionWarning = $shape.warning
        if ($shapeErrors.Count -gt 0) {
            $failureReason = "CODEX_OUTPUT_INVALID: $($shapeErrors -join '; '). Redacted output: $OutputPath"
            $failureCategory = 'model-output'
        }
    }

    $limitBlock = $null
    if (-not $timedOut -and $exitCode -ne 0 -and -not $blockedReportDetail) {
        # Without --json, codex exec writes progress and errors to stderr and only the final agent
        # message to stdout, so stdout is model text and never a source of error events.
        $codexErrorText = $stderr
        $refusal = Test-RouterLimitRefusal -Vendor codex -Text $codexErrorText
        $tooLarge = Test-RouterInputTooLarge -Vendor codex -Text $codexErrorText
        $capacitySignal = Get-CodexCapacitySignal -ErrorText $codexErrorText
        if ($tooLarge.too_large) {
            # The caller's prompt is over Codex's input cap: no vendor diagnosis, no retry, and the alert names the sizes.
            $failureReason = "CODEX_INPUT_TOO_LARGE: prompt is $($tooLarge.actual_chars) characters; Codex accepts at most $($tooLarge.max_chars). Split the prompt. Redacted stream: $streamPath"
            $failureCategory = 'tooling'
            $key = 'input-too-large:codex:' + $dispatchId + ':' + $tooLarge.actual_chars + ':' + $tooLarge.max_chars
            $message = Get-RouterAlertMessage -Key $key -Model $resolvedModel -Category $Category -ArtifactPath $provenancePath
            $null = Send-RouterAlert -Key $key -Message $message -ChatToStderr:$Json
        }
        elseif ($refusal.refused) {
            $blockArgs = @{ Vendor='codex'; Reason='usage-limit refusal from codex exec' }
            if ($refusal.reset_at_utc) { $blockArgs.ResetAtUtc = [datetimeoffset]$refusal.reset_at_utc }
            $limitBlock = Add-RouterVendorBlock @blockArgs
            $quotaUsage = Get-RouterCodexUsage
            $quotaPercent = Format-RouterUsageText -Usage $quotaUsage
            if (-not $quotaPercent) { $quotaPercent = 'unknown% used / unknown% left' }
            $failureReason = "ROUTER_LIMIT: codex at its usage limit ($quotaPercent); $(Format-RouterResumeAfterEt -AtUtc ([datetimeoffset]$limitBlock.reset_at_utc) -Source $limitBlock.resume_after_source)"
            $failureCategory = 'environment'
            $failureDetail = 'quota'
        }
        elseif ($capacitySignal) {
            $failureCategory = 'capacity'
            $failureDetail = Invoke-SecretRedaction -Text $capacitySignal
            $attemptRecord.failure_category = 'capacity'
            $attemptRecord.failure_detail = $failureDetail
            # A refusal can follow substantial work. Discard its partial final message;
            # each retry starts a fresh exec with the same prompt, argv and output path.
            Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
            if ($capacityBackoffs.Count -lt $CapacityBackoffMs.Count) {
                $waitMs = $CapacityBackoffMs[$capacityBackoffs.Count]
                $waitStarted = [datetimeoffset](& $script:RouterDiagnosisClock)
                $etZone = [TimeZoneInfo]::FindSystemTimeZoneById('Eastern Standard Time')
                $waitEt = [TimeZoneInfo]::ConvertTime($waitStarted, $etZone).ToString('yyyy-MM-dd HH:mm:ss.fff') + ' ET'
                $resumeEt = [TimeZoneInfo]::ConvertTime($waitStarted.AddMilliseconds($waitMs), $etZone).ToString('yyyy-MM-dd HH:mm:ss.fff') + ' ET'
                $waitMessage = "CODEX_CAPACITY_WAIT: $failureDetail; wait ${waitMs}ms from $waitEt until $resumeEt; retry $($capacityBackoffs.Count + 1)/$($CapacityBackoffMs.Count), same model $resolvedModel and effort $Effort."
                $capacityBackoffs.Add([pscustomobject]@{ after_dispatch_attempt = $dispatchAttempts.Count; wait_ms = $waitMs; wait_started_et = $waitEt; resume_after_et = $resumeEt; failure_detail = $failureDetail; message = $waitMessage })
                [Console]::Error.WriteLine($waitMessage)
                [System.IO.File]::AppendAllText($streamPath, "`n$waitMessage`n")
                # Persist before sleeping so an interrupted wait still has capacity evidence.
                if (-not $temporaryOutput) {
                    $waiting = [ordered]@{
                        pass = $false; lane = 'codex'; vendor = 'codex'; tier = $Tier; category = $Category
                        attempt = $Attempt; resolved_model = $resolvedModel; effort = $Effort
                        failure_category = 'capacity'; failure_detail = $failureDetail; diagnosis = $null
                        output_path = $null; stream_log_path = $streamPath; termination_reason = $waitMessage
                        dispatched_at_utc = $started.ToUniversalTime().ToString('o')
                        dispatch_attempts = @($dispatchAttempts.ToArray()); capacity_backoffs = @($capacityBackoffs.ToArray())
                    }
                    [IO.File]::WriteAllText($provenancePath, ($waiting | ConvertTo-Json -Depth 8))
                }
                & $script:RouterDispatchSleep $waitMs
                # Capacity wait and earlier work must not consume the fresh attempt's timeout.
                $dispatchStarted = [datetimeoffset](& $script:RouterDiagnosisClock)
                continue dispatch
            }
            $totalWaitMs = [long]0
            foreach ($backoff in $capacityBackoffs) { $totalWaitMs += $backoff.wait_ms }
            $failureReason = "CODEX_CAPACITY_EXHAUSTED: $failureDetail; vendor capacity unavailable after $($dispatchAttempts.Count) dispatch attempts and ${totalWaitMs}ms of bounded backoff. Same model $resolvedModel and effort $Effort retained. Redacted stream: $streamPath"
        }
        else {
            $dispatchDiagnosis = Resolve-RouterDispatchFailure -Vendor codex -ErrorText $codexErrorText
            $diagnosis = $dispatchDiagnosis.verdict
            $failureCategory = 'environment'
            $attemptRecord.failure_category = $failureCategory
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

    $attemptRecord.failure_category = $failureCategory
    $attemptRecord.failure_detail = $failureDetail
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

    Update-AdHocUntrackedPaths
    $result = [pscustomobject]@{
        untracked_created      = @($untrackedCreated)
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
        windows_sandbox        = if (($Preflight -or $ReadOnly) -and $env:OS -eq 'Windows_NT') { 'mxc' } else { $null }
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
        failure_detail         = $failureDetail
        dispatch_attempts      = @($dispatchAttempts.ToArray())
        capacity_backoffs      = @($capacityBackoffs.ToArray())
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
        Update-AdHocUntrackedPaths
        $durationMs = [int][Math]::Round(((Get-Date) - $started).TotalMilliseconds)
        $fallback = [pscustomobject]@{
            untracked_created = @($untrackedCreated)
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
            dispatch_attempts = @($dispatchAttempts.ToArray()); capacity_backoffs = @($capacityBackoffs.ToArray())
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
