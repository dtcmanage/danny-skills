param(
    [string]$Category,
    [string]$ProblemPath,
    [string[]]$AttemptPaths,
    [ValidateSet('codex','claude')][string]$AttemptVendor,
    [string]$StateDir,
    [scriptblock]$ScrutinyInvoker
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'resolve-model.ps1')
. (Join-Path $PSScriptRoot '../wrap-prompt-envelope.ps1')
. (Join-Path $PSScriptRoot '../security/redact-secrets.ps1')

function Limit-FrontierPromptText {
    param([string]$Text)
    $marker = "`n[TRUNCATED]"
    if ($Text.Length -gt 20000) { return $Text.Substring(0,20000 - $marker.Length) + $marker }
    return $Text
}

function Request-RouterFrontier {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$ProblemPath,
        [string[]]$AttemptPaths,
        [Parameter(Mandatory)][ValidateSet('codex','claude')][string]$AttemptVendor,
        [Parameter(Mandatory)][string]$StateDir,
        [scriptblock]$ScrutinyInvoker
    )
    $AttemptPaths = @($AttemptPaths | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $AttemptPaths -or $AttemptPaths.Count -eq 0) { throw 'FRONTIER_ATTEMPTS_REQUIRED' }
    $job = Get-RouterCategoryJob $Category
    if ($job -notin @('coder','deep-thinker')) { throw 'FRONTIER_REQUIRES_TIERED_JOB' }
    $frontierProblemText = Invoke-SecretRedaction -Text ([IO.File]::ReadAllText((Convert-Path -LiteralPath $ProblemPath)))
    $frontierAttemptRows = foreach ($path in $AttemptPaths) {
        $full = Convert-Path -LiteralPath $path
        [pscustomobject]@{path=$full;sha256=(Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant();content=(Limit-FrontierPromptText (Invoke-SecretRedaction -Text ([IO.File]::ReadAllText($full))))}
    }
    $prior = $env:DT_MODEL_ROUTER_STATE
    $env:DT_MODEL_ROUTER_STATE = [IO.Path]::GetFullPath($StateDir)
    try {
        $id = [guid]::NewGuid().ToString('N')
        $lane = if ($AttemptVendor -eq 'codex') { 'claude' } else { 'codex' }
        $pick = Resolve-RouterModel -Category analysis -Difficulty hard -DifficultyReason 'Scrutinize failed hard-tier attempts' -Lane $lane
        if ($pick.status -ne 'ok' -or $pick.effort -cne 'high') { throw 'FRONTIER_SCRUTINY_UNAVAILABLE' }
        $prompt = "RUN_ID: frontier-$id`nchunk_id: scrutiny`nattempt: 1`nReview this problem and the failed hard-tier attempts (including their failed checks), or two disagreeing hard-tier answers. Make one read-only scrutiny call; do not edit files. Return only strict JSON with string fields verdict, failed_attempt (which attempt failed and how), why_effort_insufficient, guidance. verdict must be needs_frontier, retry_with_guidance, or decompose. Recommend needs_frontier only when you can cite a failed attempt and explain why more effort cannot fix it.`n" + (New-PromptEnvelope -Label 'FRONTIER SCRUTINY DATA' -Content (ConvertTo-Json -InputObject @{problem=(Limit-FrontierPromptText $frontierProblemText);attempts=@($frontierAttemptRows)} -Depth 10))
        $call = [pscustomobject]@{prompt=$prompt;model=$pick.model;effort='high';lane=$lane;category='analysis';difficulty='hard';read_only=$true}
        if ($ScrutinyInvoker) { $raw = & $ScrutinyInvoker $call }
        else {
            $scratch = Join-Path ([IO.Path]::GetTempPath()) "router-scrutiny-$id"
            [void][IO.Directory]::CreateDirectory($scratch)
            try {
                $promptFile = Join-Path $scratch 'prompt.txt'; $answerFile = Join-Path $scratch 'answer.json'
                [IO.File]::WriteAllText($promptFile,$prompt,[Text.UTF8Encoding]::new($false))
                $wrapper = Join-Path $PSScriptRoot "../../skills/dt-build/scripts/invoke-$lane-chunk.ps1"
                $wrapperResult = & $wrapper -ProjectPath (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path -PromptPath $promptFile -OutputPath $answerFile -Model $pick.model -Effort high -Category analysis -Difficulty hard -DifficultyReason 'Scrutinize failed hard-tier attempts' -SelectionReason 'Other-vendor scrutiny before a frontier request' -ReadOnly -Scrutiny -Json
                $dispatch = $wrapperResult | ConvertFrom-Json
                if (-not $dispatch.pass) { throw 'FRONTIER_SCRUTINY_FAILED' }
                $raw = [IO.File]::ReadAllText($answerFile)
            } finally {
                $scratchFull = [IO.Path]::GetFullPath($scratch)
                $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
                if (-not $scratchFull.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($scratchFull) -cne "router-scrutiny-$id") { throw 'FRONTIER_SCRATCH_PATH_INVALID' }
                if (Test-Path -LiteralPath $scratchFull) { Remove-Item -LiteralPath $scratchFull -Recurse -Force }
            }
        }
        $verdict = [pscustomobject]@{verdict='retry_with_guidance';failed_attempt='';why_effort_insufficient='';guidance='Scrutiny did not return valid, cited JSON; retry with guidance.'}
        try {
            $parsed = ConvertFrom-Json -InputObject ([string]$raw) -Depth 10
            if ($parsed -isnot [pscustomobject]) { throw 'Invalid scrutiny object' }
            foreach ($field in @('verdict','failed_attempt','why_effort_insufficient','guidance')) {
                if (-not $parsed.PSObject.Properties[$field] -or $parsed.$field -isnot [string]) { throw 'Invalid scrutiny field' }
            }
            if ($parsed.verdict -cnotin @('needs_frontier','retry_with_guidance','decompose')) { throw 'Invalid scrutiny verdict' }
            $safeFields = [ordered]@{}
            foreach ($field in @('verdict','failed_attempt','why_effort_insufficient','guidance')) {
                $safe = Invoke-SecretRedaction -Text $parsed.$field
                $safeFields[$field] = $safe.Substring(0,[Math]::Min(600,$safe.Length))
            }
            $verdict=[pscustomobject]$safeFields
            if ($verdict.verdict -ceq 'needs_frontier' -and ([string]::IsNullOrWhiteSpace($verdict.failed_attempt) -or [string]::IsNullOrWhiteSpace($verdict.why_effort_insufficient))) { $verdict.verdict='retry_with_guidance' }
        } catch { }
        if ($verdict.verdict -cne 'needs_frontier') { return [pscustomobject]@{verdict=$verdict.verdict;guidance=$verdict.guidance;request_id=$null;waits=$false} }
        $roster = Read-RouterRoster
        $vendor = $roster.roster.jobs.$job.first_vendor
        $map = Get-Content (Join-Path $PSScriptRoot '../../references/model-router/ladders.json') -Raw | ConvertFrom-Json
        $models = @($map.lanes.$vendor.ladder | Where-Object frontier)
        if ($models.Count -ne 1) { throw 'FRONTIER_MODEL_UNAVAILABLE' }
        $summary = $frontierProblemText.Substring(0,[Math]::Min(600,$frontierProblemText.Length))
        $quota = 'One piece at high effort; frontier usage draws on the selected vendor quota. Exact use is unknown until dispatch.'
        $request = [pscustomobject]@{id=$id;created_at=[datetimeoffset]::UtcNow.ToString('o');category=$Category;problem_summary=$summary;attempts=@($frontierAttemptRows | Select-Object path,sha256);scrutiny_verdict=$verdict;proposed_model=$models[0].model;proposed_effort='high';expected_quota_note=$quota;status='pending'}
        $path = Get-RouterFrontierRequestPath $id
        Write-RouterJsonAtomic $path $request
        $alertSummary = $summary.Substring(0,[Math]::Min(260,$summary.Length))
        $failure = $verdict.failed_attempt.Substring(0,[Math]::Min(140,$verdict.failed_attempt.Length))
        $insufficient = $verdict.why_effort_insufficient.Substring(0,[Math]::Min(140,$verdict.why_effort_insufficient.Length))
        $stateCommand = $env:DT_MODEL_ROUTER_STATE.Replace("'","''")
        $approveCommand = "pwsh -NoProfile -File scripts/model-router/approve-roster.ps1 -ApproveFrontier -RequestId '$id' -Model '$($request.proposed_model)'"
        $declineCommand = "pwsh -NoProfile -File scripts/model-router/approve-roster.ps1 -DeclineFrontier -RequestId '$id'"
        $message = "A hard-tier piece needs your frontier decision. The piece waits.`nProblem: $alertSummary`nAttempts: $($frontierAttemptRows.Count); details: $path`nScrutiny: needs_frontier. Failed: $failure`nWhy high is insufficient: $insufficient`nProposed: $($request.proposed_model), high effort.`n$quota`ncd '$((Resolve-Path (Join-Path $PSScriptRoot '../..')).Path.Replace("'","''"))'`n`$env:DT_MODEL_ROUTER_STATE = '$stateCommand'`n$approveCommand`n$declineCommand"
        $alert = Send-RouterAlert -Key "frontier-request:$id" -Message $message -ChatToStderr
        $resultMessage = if ($alert.sent) { 'The piece waits for the named model approval.' } else { "ALERT_FAILED: request remains pending.`ncd '$((Resolve-Path (Join-Path $PSScriptRoot '../..')).Path.Replace("'","''"))'`n`$env:DT_MODEL_ROUTER_STATE = '$stateCommand'`n$approveCommand`n$declineCommand" }
        return [pscustomobject]@{verdict='needs_frontier';request_id=$id;waits=$true;alert_sent=[bool]$alert.sent;message=$resultMessage}
    } finally { $env:DT_MODEL_ROUTER_STATE=$prior }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Request-RouterFrontier @PSBoundParameters
    $result
    if ($result.PSObject.Properties['alert_sent'] -and -not $result.alert_sent) { exit 1 }
}
