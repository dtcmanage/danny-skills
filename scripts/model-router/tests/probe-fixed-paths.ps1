[CmdletBinding()]
param([switch]$Live, [string]$OutDir)
# Coordinator-run live probe of the fixed paths: a review coordinator under dt-job,
# an ad hoc Claude worker's WebFetch, and a read-only worker. Each case spends one
# tiny prompt and saves a semantic result that exit status alone cannot satisfy.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FixedPathFileHash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant() }

function New-FixedPathReviewFixture {
    param([Parameter(Mandatory)][string]$Directory)
    $null = New-Item -ItemType Directory -Path $Directory -Force
    $nonce = [guid]::NewGuid().ToString('N')
    $review = [ordered]@{
        headline = "Fixed-path probe $nonce"
        dimension_assessments = [ordered]@{ intent='ok'; completeness='gap'; coherence='ok'; resilience='ok'; economy='ok'; feasibility='ok' }
        prior_finding_checks = @()
        findings = @([ordered]@{
            id='R1-F01'; status='NEW'; title='Probe finding'; dimension='Completeness'; severity='medium'; blocks_design=$true
            root_cause='Probe fixture.'; remediation='None.'; validation_check='None.'
            ambiguous_root_cause=$false; candidate_dimensions=@(); missing_evidence=''; owner_role=''
        })
        engagement_with_prior_reasoning = 'First round.'
        verdict = 'MATERIAL_CHANGES_NEEDED'
        confidence = 'high'
        confidence_reason = 'Probe fixture.'
    }
    $encoding = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText((Join-Path $Directory 'review-v1.json'), ($review | ConvertTo-Json -Depth 8), $encoding)
    [IO.File]::WriteAllText((Join-Path $Directory 'review-v1.md'), "VERDICT: MATERIAL_CHANGES_NEEDED`nConfidence: high -- fixture`n", $encoding)
    [IO.File]::WriteAllText((Join-Path $Directory 'round-meta-v1.json'), (@{ round=1; tier='light' } | ConvertTo-Json), $encoding)
    return Get-FixedPathFileHash (Join-Path $Directory 'review-v1.json')
}

function Test-FixedPathReviewResult {
    param([string]$Directory, [string]$ExpectedHash, [string]$FinalMessage)
    $statePath = Join-Path $Directory 'review-state.json'
    $decisionPath = Join-Path $Directory 'decision-needed.md'
    $stateHash = $null
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $round = @(Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json | Where-Object { $_.round -eq 1 }) | Select-Object -Last 1
        if ($round) { $stateHash = [string]$round.structured_review_sha256 }
    }
    $decision = if (Test-Path -LiteralPath $decisionPath -PathType Leaf) { Get-Content -LiteralPath $decisionPath -Raw } else { '' }
    $checks = [ordered]@{
        script_wrote_state = ($stateHash -ceq $ExpectedHash)
        decision_names_hash = $decision.ToUpperInvariant().Contains($ExpectedHash)
        decision_has_package = ($decision -match '(?i)options' -and $decision -match '(?i)recommendation' -and $decision -match 'R1-F01')
        returned_decision_path = ([string]$FinalMessage).Contains('decision-needed.md')
    }
    return [pscustomobject]@{ pass = -not ($checks.Values -contains $false); checks = $checks }
}

function Test-FixedPathWebResult {
    # Expected values are fetched by the probe itself, before and after the worker runs.
    param([string[]]$ExpectedShas, [string]$Answer)
    $found = @($ExpectedShas | Where-Object { $_ -and ([string]$Answer).Contains($_.Substring(0, 12)) })
    return [pscustomobject]@{ pass = ($found.Count -gt 0); checks = [ordered]@{ web_value_matches_independent_fetch = ($found.Count -gt 0) } }
}

function Test-FixedPathReadOnlyResult {
    param([string]$ForbiddenPath, [string]$ReadNonce, [string]$Answer)
    $checks = [ordered]@{
        forbidden_file_absent = (-not (Test-Path -LiteralPath $ForbiddenPath))
        worker_read_the_nonce = ([string]$Answer).Contains($ReadNonce)
    }
    return [pscustomobject]@{ pass = -not ($checks.Values -contains $false); checks = $checks }
}

function Invoke-FixedPathWorker {
    # Starts one dispatch under dt-job, waits for it, and returns its answer and execution status.
    param([string]$RunFolder, [string]$ProjectPath, [string]$PromptText, [string]$OutputPath, [string]$RepoRoot, [string[]]$Extra = @(), [string]$Category = 'mechanical')
    $promptPath = Join-Path $RunFolder 'prompt.md'
    $null = New-Item -ItemType Directory -Path $RunFolder -Force
    # The wrappers require a git project.
    if (-not (Test-Path -LiteralPath (Join-Path $ProjectPath '.git'))) {
        & git -C $ProjectPath init -q
        & git -C $ProjectPath -c user.email=probe@example.com -c user.name=probe commit --allow-empty -qm fixture
    }
    [IO.File]::WriteAllText($promptPath, $PromptText, [Text.UTF8Encoding]::new($false))
    $dispatch = Join-Path $RepoRoot 'scripts/model-router/dispatch.ps1'
    $call = "pwsh -NoProfile -File '$dispatch' -ProjectPath '$ProjectPath' -Category $Category -PromptPath '$promptPath' -OutputPath '$OutputPath' -SelectionReason 'Fixed-path probe; one tiny prompt.' -Lane claude -AdHoc -SingleDispatch -AllowOutputInProject -Live $($Extra -join ' ')"
    $job = Join-Path $RepoRoot 'skills/dt-build/scripts/dt-job.ps1'
    $started = (& $job -Verb start -RunFolder $RunFolder -AllowTempRunFolder -Kind worker -Category $Category -Command $call -Json) | ConvertFrom-Json
    $waited = (& $job -Verb wait -RunFolder $RunFolder -AllowTempRunFolder -JobId $started.job_id -All -TimeoutSec 540 -Json) | ConvertFrom-Json
    $answer = if (Test-Path -LiteralPath $OutputPath -PathType Leaf) { Get-Content -LiteralPath $OutputPath -Raw } else { '' }
    $provenancePath = $OutputPath + '.provenance.json'
    $execution = $null; $actual = $null
    if (Test-Path -LiteralPath $provenancePath -PathType Leaf) {
        $provenance = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json
        if ($provenance.PSObject.Properties['execution_result']) { $execution = $provenance.execution_result }
        if ($provenance.PSObject.Properties['actual_model']) { $actual = $provenance.actual_model }
    }
    return [pscustomobject]@{ job_id = $started.job_id; wait_result = $waited.result; job_status = @($waited.jobs)[0].status; execution_result = $execution; actual_model = $actual; answer = $answer }
}

function Invoke-FixedPathProbe {
    param([string]$RepoRoot, [string]$Root)
    $results = [ordered]@{}
    $parse = Join-Path $RepoRoot 'skills/dt-review/scripts/parse-verdict.ps1'

    # Case: a dt-pipeline-style review coordinator runs a dt-review script and returns decision-needed.md.
    $planning = Join-Path $Root 'review/planning'
    $expected = New-FixedPathReviewFixture -Directory $planning
    $prompt = @"
You are a dt-pipeline review stage coordinator in a probe. Run exactly this once with your shell tool:
pwsh -NoProfile -File "$parse" -FeedbackPath "$planning/review-v1.md" -Round 1 -StatePath "$planning/review-state.json" -Tier light
Then read structured_review_sha256 from $planning/review-state.json. This is a USER_DECISION: write $planning/decision-needed.md with an Options section (A stop, B extend), the unresolved finding id R1-F01, that sha256 under State, and a Recommendation. End with the path of decision-needed.md as your final message. Do nothing else.
"@
    $worker = Invoke-FixedPathWorker -RunFolder (Join-Path $Root 'review') -ProjectPath $planning -PromptText $prompt -OutputPath (Join-Path $planning 'result.md') -RepoRoot $RepoRoot
    $results.review_coordinator = [ordered]@{ job = $worker; verdict = (Test-FixedPathReviewResult -Directory $planning -ExpectedHash $expected -FinalMessage $worker.answer) }

    # Case: an ad hoc Claude worker uses WebFetch for a value it cannot know from memory.
    $webRoot = Join-Path $Root 'web'
    $null = New-Item -ItemType Directory -Path $webRoot -Force
    $url = 'https://api.github.com/repos/python/cpython/commits/main'
    $before = (Invoke-RestMethod -Uri $url -TimeoutSec 30).sha
    $prompt = "Use WebFetch once on $url and ask for the top-level sha field. Reply with only that sha. Do nothing else."
    $worker = Invoke-FixedPathWorker -RunFolder $webRoot -ProjectPath $webRoot -PromptText $prompt -OutputPath (Join-Path $webRoot 'result.md') -RepoRoot $RepoRoot
    $after = (Invoke-RestMethod -Uri $url -TimeoutSec 30).sha
    $results.adhoc_webfetch = [ordered]@{ job = $worker; verdict = (Test-FixedPathWebResult -ExpectedShas @($before, $after) -Answer $worker.answer) }

    # Case: a read-only worker reads a file but cannot leave a new one.
    $readRoot = Join-Path $Root 'readonly'
    $project = Join-Path $readRoot 'project'
    $null = New-Item -ItemType Directory -Path $project -Force
    $nonce = [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText((Join-Path $project 'nonce.txt'), $nonce, [Text.UTF8Encoding]::new($false))
    & git -C $project init -q
    & git -C $project add nonce.txt
    & git -C $project -c user.email=probe@example.com -c user.name=probe commit -qm fixture
    $forbidden = Join-Path $project 'forbidden.txt'
    $prompt = "Use the Read tool on $project/nonce.txt. Attempt once to create $forbidden with any write tool you have; if you have none, say so. Do not retry and do nothing else. Your final reply must include the exact text of nonce.txt."
    $worker = Invoke-FixedPathWorker -RunFolder $readRoot -ProjectPath $project -PromptText $prompt -OutputPath (Join-Path $project '_dispatch/result.md') -RepoRoot $RepoRoot -Extra @('-ReadOnly')
    $results.read_only = [ordered]@{ job = $worker; verdict = (Test-FixedPathReadOnlyResult -ForbiddenPath $forbidden -ReadNonce $nonce -Answer $worker.answer) }

    return $results
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Live) { throw 'This probe requires explicit -Live. Offline tests dot-source its checks.' }
    if (-not $OutDir) { throw '-OutDir is required.' }
    # Each case must start its own job, not join the coordinator's.
    Remove-Item Env:DT_JOB_ID, Env:DT_JOB_DIR, Env:DT_BUILD_COORDINATOR_ID -ErrorAction SilentlyContinue
    $out = [IO.Path]::GetFullPath($OutDir)
    $root = Join-Path $out 'cases'
    $null = New-Item -ItemType Directory -Path $root -Force
    $repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
    $results = Invoke-FixedPathProbe -RepoRoot $repo -Root $root
    $pass = -not (@($results.Values | ForEach-Object { $_.verdict.pass }) -contains $false)
    $summary = [ordered]@{ recorded_et = (Get-Date).ToString('o'); pass = $pass; independent_acceptance = $null; cases = $results }
    [IO.File]::WriteAllText((Join-Path $out 'fixed-path-results.json'), ($summary | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $summary | ConvertTo-Json -Depth 8
    if (-not $pass) { exit 1 }
}
