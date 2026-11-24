Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scripts = Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts 'check-moved-path-consumers.ps1')
. (Join-Path $scripts 'worker-standing-rules.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('gates-briefs-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root | Out-Null
function Assert($condition, $message) { if (-not $condition) { throw $message } }
try {
    & git -C $root init -b main -q
    & git -C $root config user.email fixture@example.test
    & git -C $root config user.name Fixture
    New-Item -ItemType Directory (Join-Path $root 'web/src/settings') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $root 'web/src/settings/screens.json'), '{}')
    [IO.File]::WriteAllText((Join-Path $root 'windows_screen.rs'), 'read("web/src/settings/screens.json")')
    [IO.File]::WriteAllText((Join-Path $root 'other.py'), 'read("web/src/settings/screens.json")')
    & git -C $root add .
    & git -C $root commit -qm fixture
    $evidence = Join-Path $root '.git/evidence'
    New-Item -ItemType Directory $evidence | Out-Null
    & git -C $root mv web/src/settings/screens.json web/src/settings/new.json
    $hits = @(Test-MovedPathConsumers $root main)
    Assert ($hits.Count -eq 2 -and ($hits -join ' ') -match 'windows_screen.rs:1:') 'rename must catch cross-language consumers'
    $roadmap = Join-Path $root 'roadmap.md'
    [IO.File]::WriteAllText($roadmap, @'
## Milestones
| id | acceptance-checks |
| --- | --- |
| M01 | move settings |
## Verification Manifest
| check-id | milestone-id | procedure |
| --- | --- | --- |
| CHK-M01 | M01 | Run `pwsh -NoProfile -Command exit 0` |
'@)
    $json = & pwsh -NoProfile -File (Join-Path $scripts 'verify-milestone-acceptance.ps1') -RoadmapPath $roadmap -MilestoneId M01 -WorkingTree $root -BaseRef main -RunTests -Json 2> (Join-Path $evidence 'acceptance.err')
    Assert ($LASTEXITCODE -eq 1) 'acceptance must block stale consumers even when named check passes'
    $acceptance = ($json -join "`n") | ConvertFrom-Json
    Assert ($acceptance.status -eq 'BLOCKED' -and ($acceptance.blockers -join ' ').Contains('windows_screen.rs:1:')) 'acceptance carries file/line diagnostics'
    [IO.File]::WriteAllText((Join-Path $root 'windows_screen.rs'), 'read("web/src/settings/new.json")')
    [IO.File]::WriteAllText((Join-Path $root 'other.py'), 'read("web/src/settings/new.json")')
    Assert (@(Test-MovedPathConsumers $root main).Count -eq 0) 'updated consumers should pass'
    & git -C $root rm -q -f web/src/settings/new.json
    Assert (@(Test-MovedPathConsumers $root main).Count -eq 0) 'removed file itself is excluded'
    $badBase = $false
    try { Test-MovedPathConsumers $root missing-ref } catch { $badBase = $_ -match 'MOVED_PATH_BASE_UNRESOLVED' }
    Assert $badBase 'unknown base must fail closed'

    # Whole tokens, history defaults, caller exclusions, untracked consumers and
    # nested WorkingTree calls all use the same repository-wide search.
    & git -C $root checkout -qb feature
    New-Item -ItemType Directory (Join-Path $root 'src'), (Join-Path $root 'docs/history'), (Join-Path $root 'design') -Force | Out-Null
    foreach ($path in @('src/a.js','Makefile','README','setup.py')) { [IO.File]::WriteAllText((Join-Path $root $path), 'old') }
    & git -C $root add .
    & git -C $root commit -qm before-token-milestone
    $tokenBase = & git -C $root rev-parse HEAD
    & git -C $root rm -q src/a.js Makefile README setup.py
    New-Item -ItemType Directory (Join-Path $root 'src') -Force | Out-Null
    foreach ($path in @('CHANGELOG.md','docs/history/migration.md','design/decision.md')) {
        [IO.File]::WriteAllText((Join-Path $root $path), 'src/a.js Makefile README setup.py')
    }
    [IO.File]::WriteAllText((Join-Path $root 'consumer.py'), 'src/a.json xsrc/a.js src/a.js.map sub/src/a.js Makefiles README.md setup.pyc')
    Assert (@(Test-MovedPathConsumers (Join-Path $root 'src') $tokenBase).Count -eq 0) 'prefixes and default historical paths must not block'
    foreach ($mention in @('./src/a.js', 'see src/a.js.', "see src/a.js. next", 'src\a.js', '.\src\a.js', 'src\\a.js')) {
        [IO.File]::WriteAllText((Join-Path $root 'consumer.py'), $mention)
        Assert (@(Test-MovedPathConsumers $root $tokenBase).Count -eq 1) "relative prefix and sentence punctuation must block: $mention"
    }
    [IO.File]::WriteAllText((Join-Path $root 'consumer.py'), '')
    foreach ($name in @('consumer:123:name.py', "consumer`nname.py")) {
        # These names are legal on POSIX; Windows disallows colon and newline.
        if ($IsWindows) { continue }
        $path = Join-Path $root $name
        [IO.File]::WriteAllText($path, 'src/a.js')
        $unusualHits = @(Test-MovedPathConsumers $root $tokenBase)
        Assert ($unusualHits.Count -eq 1 -and $unusualHits[0].Contains("${name}:1:src/a.js")) 'NUL-delimited grep must preserve colon-number and newline filenames'
        Remove-Item -LiteralPath $path
    }
    [IO.File]::WriteAllText((Join-Path $root 'consumer.py'), 'read("src/a.js"); read("Makefile"); read("README"); read("setup.py")')
    $tokenHits = @(Test-MovedPathConsumers (Join-Path $root 'src') $tokenBase)
    Assert ($tokenHits.Count -eq 4) "untracked whole-token consumers outside nested working tree must block: $($tokenHits -join '; ')"
    Assert (@(Test-MovedPathConsumers $root $tokenBase -ExcludePaths @('consumer.py')).Count -eq 0) 'caller exclusion is repo-top relative'
    & git -C $root add .
    & git -C $root commit -qm completed-earlier-milestone
    $nextBase = & git -C $root rev-parse HEAD
    Assert (@(Test-MovedPathConsumers $root $nextBase).Count -eq 0) 'prior milestone deletions must not leak into the next boundary'
    $report = Join-Path $evidence 'builder.md'
    @{start_commit=$nextBase;dispatch_id='fixture'} | ConvertTo-Json | Set-Content "$report.provenance.json"
    $json = & pwsh -NoProfile -File (Join-Path $scripts 'verify-milestone-acceptance.ps1') -RoadmapPath $roadmap -MilestoneId M01 -WorkingTree $root -BuilderReportPath $report -Json
    $acceptance = ($json -join "`n") | ConvertFrom-Json
    Assert ($LASTEXITCODE -eq 0 -and $acceptance.blockers.Count -eq 0) 'default boundary comes from builder start_commit rather than main'
    $json = & pwsh -NoProfile -File (Join-Path $scripts 'verify-milestone-acceptance.ps1') -RoadmapPath $roadmap -MilestoneId M01 -WorkingTree $root -BaseRef missing-ref -RunTests -Json 2> (Join-Path $evidence 'base.err')
    $acceptance = ($json -join "`n") | ConvertFrom-Json
    Assert ($LASTEXITCODE -eq 1 -and $acceptance.status -eq 'BLOCKED' -and ($acceptance.blockers -join ' ').Contains('MOVED_PATH_BASE_UNRESOLVED')) 'check errors must retain JSON blocker evidence'

    # No provenance is a supported artifact-only inspection, even with a report.
    $json = & pwsh -NoProfile -File (Join-Path $scripts 'verify-milestone-acceptance.ps1') -RoadmapPath $roadmap -MilestoneId M01 -WorkingTree $root -BuilderReportPath (Join-Path $evidence 'absent.md') -Json
    $acceptance = ($json -join "`n") | ConvertFrom-Json
    Assert ($LASTEXITCODE -eq 0 -and $acceptance.status -eq 'INSPECT_ONLY' -and $acceptance.blockers.Count -eq 0) 'B missing provenance retains inspect-only behavior'
    $null = & pwsh -NoProfile -File (Join-Path $scripts 'verify-milestone-acceptance.ps1') -RoadmapPath $roadmap -MilestoneId M01 -WorkingTree $root -BuilderReportPath (Join-Path $evidence 'absent.md') -RunTests -Json 2> (Join-Path $evidence 'missing-provenance.err')
    Assert ($LASTEXITCODE -ne 0 -and (Get-Content -Raw (Join-Path $evidence 'missing-provenance.err')).Contains('absent.md.provenance.json')) 'J RunTests with a builder report and no provenance must fail as before'

    # Use isolated router state and real evidence for end-to-end acceptance.
    $priorState = $env:DT_MODEL_ROUTER_STATE
    $env:DT_MODEL_ROUTER_STATE = Join-Path $evidence 'router'
    try {
        . (Join-Path $scripts '../../../scripts/model-router/dispatch-evidence.ps1')
        $context = New-RouterDispatchContext -Project $root -Category routine-coding -LogicalTaskId 'boundary-fixture'
        $fallback = Join-Path $evidence 'fallback.provenance.json'
        foreach ($payload in @(@{start_commit=$null}, @{start_commit=''}, @{})) {
            Write-RouterDispatchEvidence "$report.provenance.json" ([pscustomobject]$payload) $context -ExitCode 0
            $json = & pwsh -NoProfile -File (Join-Path $scripts 'verify-milestone-acceptance.ps1') -RoadmapPath $roadmap -MilestoneId M01 -WorkingTree $root -BuilderReportPath $report -RunTests -Json
            $acceptance = ($json -join "`n") | ConvertFrom-Json
            Assert ($LASTEXITCODE -eq 0 -and $acceptance.status -eq 'PASS') 'A null/empty/legacy boundary must not block'
            Write-RouterDispatchEvidence $fallback ([pscustomobject]@{start_commit='missing-ref'}) $context -ExitCode 0
            $json = & pwsh -NoProfile -File (Join-Path $scripts 'verify-milestone-acceptance.ps1') -RoadmapPath $roadmap -MilestoneId M01 -WorkingTree $root -BuilderReportPath $report -ProvenancePath $fallback -RunTests -Json 2> (Join-Path $evidence 'fallback.err')
            Assert ($LASTEXITCODE -ne 0 -and (Get-Content -Raw (Join-Path $evidence 'fallback.err')).Contains('DISPATCH_ACCEPTANCE_PATH_MISMATCH')) 'J distinct existing evidence paths must fail even with the same dispatch id'
            $json = & pwsh -NoProfile -File (Join-Path $scripts 'verify-milestone-acceptance.ps1') -RoadmapPath $roadmap -MilestoneId M01 -WorkingTree $root -ProvenancePath $fallback -RunTests -Json 2> (Join-Path $evidence 'base-fallback.err')
            $acceptance = ($json -join "`n") | ConvertFrom-Json
            Assert ($LASTEXITCODE -eq 1 -and ($acceptance.blockers -join ' ').Contains('MOVED_PATH_BASE_UNRESOLVED')) 'A explicit provenance is tried after null/empty/missing builder boundary'
        }
        Remove-Item -LiteralPath "$report.provenance.json"
        $null = & pwsh -NoProfile -File (Join-Path $scripts 'verify-milestone-acceptance.ps1') -RoadmapPath $roadmap -MilestoneId M01 -WorkingTree $root -BuilderReportPath $report -ProvenancePath $fallback -RunTests -Json 2> (Join-Path $evidence 'identity-fallback.err')
        Assert ($LASTEXITCODE -ne 0 -and (Get-Content -Raw (Join-Path $evidence 'identity-fallback.err')).Contains('builder.md.provenance.json')) 'J fallback must never supply the missing builder dispatch identity'
        Write-RouterDispatchEvidence "$report.provenance.json" ([pscustomobject]@{start_commit=$null;write_mode=$true}) $context -ExitCode 0
        $json = & pwsh -NoProfile -File (Join-Path $scripts 'verify-milestone-acceptance.ps1') -RoadmapPath $roadmap -MilestoneId M01 -WorkingTree $root -BuilderReportPath $report -RunTests -Json 2> (Join-Path $evidence 'write.err')
        $acceptance = ($json -join "`n") | ConvertFrom-Json
        Assert ($LASTEXITCODE -eq 1 -and ($acceptance.blockers -join ' ').Contains('MOVED_PATH_BASE_REQUIRED')) 'A explicit write mode requires a boundary'

        # A later deletion with stale consumers must not poison M01 revalidation.
        [IO.File]::WriteAllText((Join-Path $root 'later.txt'), 'later file')
        [IO.File]::WriteAllText((Join-Path $root 'later-consumer.txt'), 'later.txt')
        & git -C $root add .
        & git -C $root commit -qm end-M01
        $endM01 = & git -C $root rev-parse HEAD
        Write-RouterDispatchEvidence "$report.provenance.json" ([pscustomobject]@{start_commit=$endM01}) $context -ExitCode 0
        & git -C $root rm -q later.txt
        & git -C $root commit -qm later-milestone
        Assert (@(Test-MovedPathConsumers $root $endM01).Count -gt 0) 'C fixture includes later stale consumers'
        $run = Join-Path $evidence 'run'
        New-Item -ItemType Directory $run | Out-Null
        @{milestone_id='M01';status='PASS';commit_sha=$endM01;tests='fixture passed';dispatch_id=$context.dispatch_id;provenance_path="$report.provenance.json"} | ConvertTo-Json -Compress | Set-Content (Join-Path $run 'acceptance-rows.jsonl')
        & pwsh -NoProfile -File (Join-Path $scripts 'build-acceptance-ledger.ps1') -RoadmapPath $roadmap -WorkingTree $root -RunFolder $run -OutDir (Join-Path $evidence 'ledger') -RunTests *> (Join-Path $evidence 'ledger.log')
        Assert ($LASTEXITCODE -eq 0) 'C ledger revalidation ignores later milestone deletions'
    } finally { $env:DT_MODEL_ROUTER_STATE = $priorState }

    # Extract the real executor without executing acceptance main; a long failure
    # proves the original first line survives both JSON data and stderr redirection.
    $tokens=$null; $errors=$null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $scripts 'verify-milestone-acceptance.ps1'), [ref]$tokens, [ref]$errors)
    $functions = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('Normalize-Command','Remove-TempFileQuietly','Invoke-NamedCommand') }, $false)
    $probe = Join-Path $evidence 'probe.ps1'
    $code = 'Set-StrictMode -Version Latest' + "`n" + ($functions.Extent.Text -join "`n") + @'

$r = Invoke-NamedCommand -WorkingTree $PSScriptRoot -Command 'pwsh -NoProfile -Command ''Write-Output FIRST_LINE; 1..60 | ForEach-Object { Write-Output $_ }; [Console]::Error.WriteLine("FIRST_ERROR"); exit 7''' -TimeoutMs 10000
$r | ConvertTo-Json | Set-Content (Join-Path $PSScriptRoot 'result.json')
exit $r.exit_code
'@
    [IO.File]::WriteAllText($probe, $code)
    & pwsh -NoProfile -File $probe 2> (Join-Path $evidence 'error.log')
    Assert ($LASTEXITCODE -eq 7) 'probe preserves the real child exit 7'
    $r = Get-Content -Raw (Join-Path $evidence 'result.json') | ConvertFrom-Json
    $err = Get-Content -Raw (Join-Path $evidence 'error.log')
    Assert ((Get-Content -Raw $r.stdout_path).Contains('FIRST_LINE') -and (Get-Content -Raw $r.stderr_path).Contains('FIRST_ERROR')) 'persistent logs retain complete output'
    Assert (-not $r.PSObject.Properties['stdout'] -and -not $r.stdout_tail.Contains('FIRST_LINE') -and $r.stdout_tail.Length -le 4000 -and $r.stderr_tail.Length -le 4000) 'JSON carries only bounded tails and paths'
    Assert ($err.Contains('FAILED COMMAND') -and $err.Contains($r.stdout_path) -and $err.Contains($r.stderr_path)) 'piped JSON cannot suppress failure log paths'
    $rule = Get-WorkerEnvironmentRule
    Assert ($rule.Contains('until green') -and $rule.Contains('first repairable failure') -and $rule.Contains('network/SSH') -and $rule.Contains('git symbolic-ref refs/remotes/origin/HEAD')) 'brief carries repair, environment and resolved default-branch rules'
    $readRule = Get-WorkerEnvironmentRule -ReadOnly
    Assert ($readRule.Contains('network/SSH') -and $readRule.Contains('git symbolic-ref') -and $readRule.Contains('Do not edit or repair') -and -not $readRule.Contains('until green')) 'E read-only verification retains environment rules without repairs'
    foreach ($lane in @('claude','codex')) {
        $wrapper = Get-Content -Raw (Join-Path $scripts "invoke-$lane-chunk.ps1")
        Assert ($wrapper.Contains('Get-WorkerEnvironmentRule -ReadOnly:$ReadOnly') -and $wrapper.Contains('if (-not $ReadOnly) { Get-WorkerFixRoundRule')) "E $lane wrapper respects read-only and scrutiny mode"
        $wrapperAst = [Management.Automation.Language.Parser]::ParseInput($wrapper, [ref]$tokens, [ref]$errors)
        $append = $wrapperAst.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Extent.Text.Contains('Standing execution rules:') -and $n.Extent.Text.Contains('$hardwareRule') }, $true)
        foreach ($ReadOnly in @($false, $true)) {
            $promptText = ''; $PromptPath = 'fixture.md'; $promptFolder = $root; $hardwareRule = 'hardware fixture'
            $repairRule = $fixRoundRule = if (-not $ReadOnly) { Get-WorkerFixRoundRule -MaxFixRounds 2 }
            . ([scriptblock]::Create($append.Extent.Text))
            Assert ($promptText -notmatch '(?m)^-\s*$' -and $promptText -notmatch 'hardware fixture\r?\n\r?\n') "K $lane omits empty rules"
            if (-not $ReadOnly) { Assert ($promptText.Contains("- $repairRule`n")) "K $lane repair rule is a bullet" }
        }
    }
    $book = (& pwsh -NoProfile -File (Join-Path $scripts 'read-coordinator-rulebook.ps1') -Section worker-briefs) -join "`n"
    Assert ($book.Contains('git symbolic-ref') -and $book.Contains('blanket offline') -and $book.Contains('until green')) 'resume coordinator receives brief requirements'
    'PASS: gates and briefs'
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
