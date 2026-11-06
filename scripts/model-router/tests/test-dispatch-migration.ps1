[CmdletBinding()]
param()
# Pack-path migration: both greps have dispositions, the superseded repo items
# changed, fixed lanes stayed put, and the staged release material is complete.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Remove-Item Env:DT_JOB_ID, Env:DT_JOB_DIR, Env:DT_BUILD_COORDINATOR_ID -ErrorAction SilentlyContinue

$script:passed = 0
function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
function Read-Repo([string]$Path) { [IO.File]::ReadAllText((Join-Path $repo $Path)) }

$stagedText = Read-Repo 'references/model-router/dispatch-guard-staged-edits.md'
$releaseText = Read-Repo 'references/model-router/dispatch-guard-release.md'

# Every hit of both greps has a disposition row.
$table = [regex]::Match($stagedText, '(?s)<!-- dispositions:start -->(.*?)<!-- dispositions:end -->').Groups[1].Value
$rows = @([regex]::Matches($table, '(?m)^\| `([^`]+)` \| (.+?) \| (.+?) \|\s*$') | ForEach-Object {
    [pscustomobject]@{ path = ($_.Groups[1].Value -replace '^<danny-skills>/', ''); contains = $_.Groups[2].Value; reason = $_.Groups[3].Value }
})
Assert-True ($rows.Count -ge 30) "disposition table parsed ($($rows.Count) rows)"
$native = '\bAgent\b|subagent|sub-agent|\bExplore\b|spawn_agent|Task tool|TaskStop|SendMessage|agent_alias|spawned agent'
$direct = 'codex exec|claude(\.cmd)? +-p\b'
$undisposed = [Collections.Generic.List[string]]::new()
$hitCount = 0
foreach ($pattern in @($native, $direct)) {
    foreach ($hit in @(& git -C $repo grep -nIE --untracked $pattern)) {
        $hitCount++
        $parts = ([string]$hit) -split ':', 3
        $row = $rows | Where-Object { $parts[0] -like $_.path -and ($_.contains -eq '*' -or $parts[2].Contains($_.contains)) } | Select-Object -First 1
        if (-not $row) { $undisposed.Add([string]$hit) }
    }
}
Assert-True ($hitCount -gt 100) "both greps found hits ($hitCount)"
Assert-True ($undisposed.Count -eq 0) "undisposed grep hits:`n$($undisposed -join "`n")"

# A row cannot dispose of a superseded instruction by sitting over its file.
$stale = @{
    'skills/dt-build/SKILL.md' = @('host-native Agent', 'agent_alias', 'TaskStop', 'has the Agent tool', 'Agent-tool dispatch')
    'skills/dt-build/references/adapter-claude.md' = @('agent_alias', 'Agent-tool launched')
    'skills/dt-build/references/subagent-prompts.md' = @('host-native Agent', 'stop each subagent')
    'skills/dt-pipeline/SKILL.md' = @('Spawn a subagent', 'SendMessage', 'While any subagent', 'Edit Agent ')
    'skills/dt-review/SKILL.md' = @('SendMessage', 'spawning session', 'stay responsive')
    'skills/dt-handoff/SKILL.md' = @('named subagents')
    'skills/dt-writing-draft/SKILL.md' = @('a subagent or a Codex', 'resolve-model.ps1 -Category long-form-writing')
    'skills/dt-writing-edit/SKILL.md' = @('a subagent or a Codex', 'resolve-model.ps1 -Category long-form-writing')
    'references/model-router/README.md' = @('inherited by a subagent or a `codex exec` call')
    'skills/dt-build/hooks/README.md' = @('It has no `hooks` key today')
}
foreach ($path in $stale.Keys) {
    $text = Read-Repo $path
    foreach ($needle in $stale[$path]) { Assert-True (-not $text.Contains($needle)) "$path no longer says: $needle" }
}

# The replacement paths are in place.
$pipeline = Read-Repo 'skills/dt-pipeline/SKILL.md'
$step2 = [regex]::Match($pipeline, '(?s)\n2\. \*\*Review\.\*\*.*?(?=\n3\. )').Value
$step3 = [regex]::Match($pipeline, '(?s)\n3\. \*\*Build\.\*\*.*?(?=\n4\. )').Value
Assert-True ($step2.Contains('dt-job.ps1') -and $step2.Contains('-Verb start') -and $step2.Contains('dispatch.ps1') -and $step2.Contains('decision-needed.md')) 'dt-pipeline review launches under dt-job and reads decision-needed.md'
Assert-True ($step3.Contains('Launch a job the same way') -and $step3.Contains('dt-build')) 'dt-pipeline build launches as a job'
$review = Read-Repo 'skills/dt-review/SKILL.md'
$contract = [regex]::Match($review, '(?s)\*\*Worker contract\.\*\*.*?(?=\r?\n\r?\n)').Value
Assert-True ($contract.Contains('USER_DECISION') -and $contract.Contains('`decision-needed.md`') -and $contract.Contains('final message')) 'dt-review worker contract writes the package and returns'
foreach ($path in @('skills/dt-writing-draft/SKILL.md', 'skills/dt-writing-edit/SKILL.md')) {
    Assert-True ((Read-Repo $path).Contains('dispatch.ps1" -ProjectPath <dir> -Category long-form-writing')) "$path dispatches through the command"
}
Assert-True ((Read-Repo 'skills/dt-handoff/SKILL.md').Contains('dispatch.ps1')) 'dt-handoff names the command'
$dispatchFlags = (Read-Repo 'scripts/model-router/dispatch.ps1')
foreach ($flag in @('ProjectPath', 'Category', 'PromptPath', 'OutputPath', 'SelectionReason', 'AdHoc', 'SingleDispatch', 'AllowOutputInProject', 'Live', 'ReadOnly', 'Lane')) {
    Assert-True ($dispatchFlags.Contains('$' + $flag)) "documented dispatch flag exists: $flag"
}

# Fixed lanes stay on their scripts.
Assert-True ($review.Contains('invoke-codex-round.ps1') -or $review.Contains('invoke-claude-round.ps1')) 'dt-review keeps its invokers'
Assert-True ($dispatchFlags.Contains('IMAGE_GENERATION_FIXED_PATH')) 'image generation stays on dt-image-gen'
Assert-True ((Read-Repo 'skills/dt-build/references/adapter-claude.md').Contains('invoke-claude-chunk.ps1')) 'dt-build keeps its wrappers'
Assert-True (-not (Read-Repo 'skills/dt-image-gen/scripts/gen-image.sh').Contains('dispatch.ps1')) 'dt-image-gen does not call the command'

# Staged edits: one per required file, each find unique or already applied.
$edits = @([regex]::Matches($stagedText, '(?ms)^### Edit: ([^\r\n]+)\r?\n\s*~~~~find\r?\n(.*?)\r?\n~~~~\s*~~~~replace\r?\n(.*?)\r?\n~~~~') | ForEach-Object {
    [pscustomobject]@{ path = $_.Groups[1].Value.Trim(); find = $_.Groups[2].Value; replace = $_.Groups[3].Value }
})
Assert-True ($edits.Count -eq ([regex]::Matches($stagedText, '(?m)^### Edit: ')).Count) 'every staged edit parses'
foreach ($required in @('00_Resources/model-routing.md', '00_Resources/read-delegation.md', 'read-guard/read_guard.py', 'D:/Claude/CLAUDE.md', '00_Resources/codex-cli-usage.md')) {
    Assert-True (@($edits | Where-Object { $_.path.EndsWith($required) }).Count -ge 1) "staged edit exists for $required"
}
foreach ($edit in $edits) {
    Assert-True ($edit.replace -notmatch 'dispatch an Agent|agent_alias|Explore agent') "replacement carries no native guidance: $($edit.path)"
    if (-not (Test-Path -LiteralPath $edit.path -PathType Leaf)) {
        Write-Output "SKIP: $($edit.path) is absent on this machine; staged text not compared"
        continue
    }
    $live = [IO.File]::ReadAllText($edit.path) -replace "`r`n", "`n"
    $findCount = ([regex]::Matches($live, [regex]::Escape(($edit.find -replace "`r`n", "`n")))).Count
    $applied = $live.Contains(($edit.replace -replace "`r`n", "`n"))
    Assert-True ($findCount -eq 1 -or $applied) "staged find text is unique or applied ($findCount) in $($edit.path): $($edit.find.Substring(0, [Math]::Min(50, $edit.find.Length)))"
}
$routing = @($edits | Where-Object { $_.path.EndsWith('model-routing.md') } | ForEach-Object { $_.replace }) -join "`n"
Assert-True ($routing.Contains('MCP server') -and $routing.Contains('live conversation') -and $routing.Contains('ROUTER_GUARD_OFF')) 'model-routing states the capability loss and the off-switch'
foreach ($label in @('Enforced, for each form a probe showed firing the hook', 'Enforced, best effort', 'Measured, not prevented', 'Unsupported and unmeasured')) {
    Assert-True ($routing.Contains($label)) "model-routing carries the surface label: $label"
}

# The release document carries the inventory and stays staged.
$inventory = [regex]::Match($releaseText, '(?s)## M06 collateral inventory\r?\n.*?(?=\r?\n## |\z)').Value
Assert-True ($inventory.Length -gt 0 -and $inventory -notmatch '(?i)reserved|pending M06') 'collateral inventory is written'
foreach ($needle in @('code-review/1.0.1/commands/code-review.md', 'skill-creator', 'code-simplifier', 'claude.exe', '/batch', 'MCP', 'live conversation', 'ROUTER_GUARD_OFF', 'remove')) {
    Assert-True ($inventory.Contains($needle)) "collateral inventory names: $needle"
}
Assert-True ($releaseText.Contains('Status: staged, inactive') -and $stagedText.Contains('The guard is not active')) 'release documents say the guard is staged'

# New shared files have owners.
$owners = Read-Repo 'references/shared-component-owners.json' | ConvertFrom-Json
foreach ($path in @('references/model-router/dispatch-guard-staged-edits.md', 'scripts/model-router/tests/probe-fixed-paths.ps1', 'scripts/model-router/tests/test-dispatch-migration.ps1')) {
    Assert-True ($null -ne $owners.PSObject.Properties[$path]) "owners entry exists for $path"
}

# The probe refuses to spend without -Live and writes nothing.
$probe = Join-Path $repo 'scripts/model-router/tests/probe-fixed-paths.ps1'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('dispatch-migration-' + [guid]::NewGuid().ToString('N'))
try {
    $refusalDir = Join-Path $temp 'refused'
    $output = & pwsh -NoProfile -File $probe -OutDir $refusalDir 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -ne 0 -and $output.Contains('requires explicit -Live') -and -not (Test-Path -LiteralPath $refusalDir)) 'probe refuses without -Live and writes nothing'

    # A clean exit with the wrong content fails each case; the real dt-review script satisfies the first.
    . $probe
    $planning = Join-Path $temp 'planning'
    $expected = New-FixedPathReviewFixture -Directory $planning
    $none = Test-FixedPathReviewResult -Directory $planning -ExpectedHash $expected -FinalMessage 'done'
    Assert-True (-not $none.pass) 'review case fails without the script state and decision file'
    $decision = Join-Path $planning 'decision-needed.md'
    [IO.File]::WriteAllText($decision, "Options: A or B`nFinding R1-F01`nState $expected`nRecommendation: A`n")
    $unrun = Test-FixedPathReviewResult -Directory $planning -ExpectedHash $expected -FinalMessage $decision
    Assert-True (-not $unrun.pass -and -not $unrun.checks.script_wrote_state) 'review case fails when the dt-review script never ran'
    & pwsh -NoProfile -File (Join-Path $repo 'skills/dt-review/scripts/parse-verdict.ps1') -FeedbackPath (Join-Path $planning 'review-v1.md') -Round 1 -StatePath (Join-Path $planning 'review-state.json') -Tier light | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'probe fixture is accepted by parse-verdict'
    $ran = Test-FixedPathReviewResult -Directory $planning -ExpectedHash $expected -FinalMessage $decision
    Assert-True ($ran.pass) "review case passes with real script state: $($ran.checks | ConvertTo-Json -Compress)"
    $noDecision = Test-FixedPathReviewResult -Directory $planning -ExpectedHash $expected -FinalMessage 'finished'
    Assert-True (-not $noDecision.pass) 'review case fails when the worker does not return the decision path'
    $sha = 'abcdef0123456789abcdef0123456789abcdef01'
    Assert-True ((Test-FixedPathWebResult -ExpectedShas @($sha) -Answer "sha $sha").pass) 'web case accepts the independently fetched value'
    Assert-True (-not (Test-FixedPathWebResult -ExpectedShas @($sha) -Answer 'I fetched it successfully').pass) 'web case rejects a claim with no value'
    $forbidden = Join-Path $temp 'forbidden.txt'
    Assert-True ((Test-FixedPathReadOnlyResult -ForbiddenPath $forbidden -ReadNonce 'n0nce' -Answer 'n0nce; no write tool').pass) 'read-only case accepts a read with no write'
    Assert-True (-not (Test-FixedPathReadOnlyResult -ForbiddenPath $forbidden -ReadNonce 'n0nce' -Answer 'no write tool').pass) 'read-only case rejects a worker that read nothing'
    [IO.File]::WriteAllText($forbidden, 'x')
    Assert-True (-not (Test-FixedPathReadOnlyResult -ForbiddenPath $forbidden -ReadNonce 'n0nce' -Answer 'n0nce').pass) 'read-only case rejects a written file'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}

Write-Output "PASS: test-dispatch-migration ($script:passed assertions, $hitCount grep hits disposed)"
