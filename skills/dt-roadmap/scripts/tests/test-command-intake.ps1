# AI-52: verification commands fail at roadmap intake when dt-build would not run them.
# Producer (build-roadmap.ps1) rejects unsupported wrappers; the validator rejects wrappers and
# milestones whose matching procedures name no executable command; the real dt-build acceptance
# gate runs a quoted-path command verbatim in a disposable working tree. Everything lives under one
# temp root (with spaces in its name) that the finally block removes.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$passed = 0; $failed = [Collections.Generic.List[string]]::new()
function Check([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:passed++ } else { $script:failed.Add($Message) }
}
$scripts = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scripts))
$builder = Join-Path $scripts 'build-roadmap.ps1'
$validator = Join-Path $scripts 'roadmap-validator.ps1'
$gate = Join-Path $repoRoot 'skills/dt-build/scripts/verify-milestone-acceptance.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('command intake ' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$savedLogDir = $env:DT_BUILD_LOG_DIR
$env:DT_BUILD_LOG_DIR = Join-Path $root 'gate logs'

. (Join-Path $repoRoot 'scripts/extract-named-artifacts.ps1')
. (Join-Path $scripts 'command-intake.ps1')

# API names alone are prose; generic calls become wrappers only when they hide a runner.
foreach ($identifier in @('run()', 'command()', 'exec()', 'run(value)')) {
    Check (-not (Test-IsUnsupportedWrapperCandidate $identifier)) "harmless API name is ignored: $identifier"
    $snippets = Get-UnsupportedCommandWrappers ("Confirm ``$identifier`` returns a value.")
    Check ($snippets.Count -eq 0) "harmless API name in procedure prose is ignored: $identifier"
}

function Invoke-Builder([string]$Name, [string]$Design) {
    $designPath = Join-Path $root "$Name.md"
    $roadmapPath = Join-Path $root "$Name-roadmap.md"
    Set-Content -LiteralPath $designPath -Value $Design
    $stderrPath = Join-Path $root "$Name.stderr"
    $out = & pwsh -NoProfile -File $builder -DesignPath $designPath -RoadmapPath $roadmapPath -ForceMermaidFallback 2> $stderrPath
    [pscustomobject]@{
        exit = $LASTEXITCODE
        stdout = ($out -join "`n")
        stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
        path = $roadmapPath
        roadmap = if (Test-Path -LiteralPath $roadmapPath) { Get-Content -LiteralPath $roadmapPath -Raw } else { '' }
    }
}
function Invoke-Validator([string]$Path) {
    $out = & pwsh -NoProfile -File $validator -RoadmapPath $Path -Json 2>&1
    $code = $LASTEXITCODE
    $parsed = $null
    try { $parsed = ($out -join "`n") | ConvertFrom-Json } catch { }
    [pscustomobject]@{ exit = $code; errors = if ($parsed) { @($parsed.errors) } else { @($out -join ' ') } }
}
function Invoke-Gate([string]$Roadmap, [string]$Tree, [switch]$RunTests) {
    $gateArgs = @('-NoProfile', '-File', $gate, '-RoadmapPath', $Roadmap, '-MilestoneId', 'M01', '-WorkingTree', $Tree, '-Json')
    if ($RunTests) { $gateArgs += '-RunTests' }
    $out = & pwsh @gateArgs 2> (Join-Path $root 'gate.stderr')
    [pscustomobject]@{ exit = $LASTEXITCODE; result = (($out -join "`n") | ConvertFrom-Json) }
}
function Design([string]$Gates) {
    return "# Design`n## Implementation Sequence`n1. Ingest. Build the reader.`n## Milestone Surfaces`n| milestone-id | write-surface | provides | consumes | design-source |`n| --- | --- | --- | --- | --- |`n| M01 | ingest/** | module:ingest | - | Implementation Sequence 1 |`n## Validation Gates`n$Gates`n"
}
function Errors-Named($v, [string]$Code) { return @($v.errors | Where-Object { $_ -like "${Code}:*" }) }
# Replace M01's acceptance-checks and chk-m01 procedure cells in a producer-built roadmap.
function Write-Mutated([string]$Base, [string]$Name, [string]$Acceptance, [string]$Procedure) {
    $lines = foreach ($line in ($Base -split "`n")) {
        if ($line.StartsWith('| M01 |') -and $line.Split('|').Count -ge 12) {
            $cells = $line.Split('|'); $cells[7] = " $Acceptance "; $cells -join '|'
        } elseif ($line.StartsWith('| chk-m01 |')) {
            $cells = $line.Split('|'); $cells[6] = " $Procedure "; $cells -join '|'
        } else { $line }
    }
    $path = Join-Path $root "$Name-roadmap.md"
    Set-Content -LiteralPath $path -Value ($lines -join "`n") -NoNewline
    return $path
}

try {
    # --- Producer -------------------------------------------------------------------------------
    # The original permanent-653 shape: a Bash(...) tool wrapper next to a named test file. Before
    # AI-52 the wrapper was silently dropped and the path alone satisfied the validator.
    $r = Invoke-Builder 'orig' (Design '- M01: `Bash(cd backend && python -m pytest tests/test_a.py -q)` covers `tests/test_a.py`.')
    Check ($r.exit -eq 2) "Bash(...) plus artifact fails the producer (exit $($r.exit))"
    Check ($r.stderr.Contains('UNSUPPORTED_COMMAND_WRAPPER') -and $r.stderr.Contains('M01: Bash(cd backend && python -m pytest tests/test_a.py -q)')) 'producer error names the milestone and the wrapper verbatim'
    Check (-not (Test-Path -LiteralPath $r.path)) 'producer writes no roadmap on a wrapper'
    Check ($r.stderr -notmatch 'build-roadmap\.ps1:\d+|ScriptStackTrace') 'producer wrapper error carries no stack trace'

    $wrapped = [ordered]@{
        'bash-string' = '`Bash("python3 -m pytest tests/test_a.py")`'
        'lower-bash'  = '`bash(pytest tests/test_a.py)`'
        'shell-call'  = '`Shell(npm test)`'
        'generic-call' = '`Tool(pytest tests/test_a.py)`'
        'cd-preamble' = '`cd backend && python3 -m pytest tests`'
        'source'      = '`source .venv/bin/activate; pytest -q`'
        'cd-unknown'  = '`cd web && dotnet test`'
        'env-prefix'  = '`PYTHONPATH=. pytest tests`'
        'sudo'        = '`sudo make test`'
        'prompt'      = '`$ pytest -q`'
        'inline-bash' = 'Bash(cd backend && pytest tests/test_a.py)'
        'inline-cd'   = 'cd backend && pytest tests/test_a.py'
    }
    foreach ($name in $wrapped.Keys) {
        # Every wrapper sits beside a supported sibling command and artifact that would mask it.
        $r = Invoke-Builder "wrap-$name" (Design ("- M01: {0} then ``python3 -m pytest tests/test_b.py`` and ``tests/test_b.py``." -f $wrapped[$name]))
        Check ($r.exit -eq 2 -and $r.stderr.Contains('UNSUPPORTED_COMMAND_WRAPPER')) "wrapper with valid sibling fails the producer: $name (exit $($r.exit))"
    }

    # Harmless prose identifiers are ignored, not rejected and not lifted.
    $prose = @('`tag_clusters`', '`discovery_active`', '`foo()`', '`parse(rows)`', '`make-believe`', '`the go module`', '`M01 | M02`', 'Run (see below)')
    $r = Invoke-Builder 'prose' (Design ('- M01: run `python3 -m pytest tests/test_a.py`; see ' + ($prose -join ', ') + '.'))
    Check ($r.exit -eq 0) "harmless prose builds (stderr: $($r.stderr))"
    Check ($r.roadmap.Contains('`python3 -m pytest tests/test_a.py`') -and -not $r.roadmap.Contains('`tag_clusters`') -and -not $r.roadmap.Contains('`foo()`')) 'prose stays out of procedure cells'

    # An unrecognized runner is not added to the set: it is not lifted and the milestone is flagged.
    $r = Invoke-Builder 'dotnet' (Design '- M01: `dotnet test` and `tests/test_a.py`.')
    Check ($r.exit -eq 0 -and -not $r.roadmap.Contains('`dotnet test`')) 'unrecognized runner is not lifted'
    Check ($r.roadmap -match '(?s)Producer Warnings.*no executable command.*- M01') 'path-only milestone gets the no-executable-command producer warning'
    $v = Invoke-Validator $r.path
    Check ($v.exit -eq 1 -and @(Errors-Named $v 'VERIFICATION_NO_EXECUTABLE_COMMAND').Count -eq 1 -and @(Errors-Named $v 'VERIFICATION_NAMES_NO_RUNNABLE').Count -eq 0) "path-only roadmap fails only VERIFICATION_NO_EXECUTABLE_COMMAND ($($v.errors -join ' '))"

    # Every currently recognized runner stays executable (python3, bash, sh, ./path, ...).
    foreach ($cmd in @('pytest -q', 'python scripts/a.py', 'python3 tests/test_a.py', 'python3.12 -m pytest', 'pwsh -NoProfile -File t.ps1', 'powershell -File t.ps1', 'node t.js', 'npm test', 'npx vitest run', 'pnpm test', 'bun test', 'bash scripts/check.sh', 'bash -c "pytest -q"', 'sh ./check.sh', 'uv run pytest', 'make test', 'go test ./...', 'cargo test', './scripts/check.sh --fast')) {
        Check ((Test-IsExecutableCommand $cmd) -and -not (Test-IsUnsupportedWrapperCandidate $cmd)) "recognized runner stays executable: $cmd"
    }
    foreach ($cmd in @('dotnet test', 'pythonic_style', 'tag_clusters', 'Bash(pytest -q)')) {
        Check (-not (Test-IsExecutableCommand $cmd)) "not executable (no runner expansion): $cmd"
    }

    # --- Validator ------------------------------------------------------------------------------
    $base = Invoke-Builder 'base' (Design '- M01: `python3 -m pytest tests/test_a.py`')
    Check ($base.exit -eq 0 -and (Invoke-Validator $base.path).exit -eq 0) 'baseline roadmap builds and validates'
    $good = 'Run `python3 -m pytest tests/test_a.py` for M01 and capture PASS/FAIL evidence.'
    $cases = @(
        @{ n = 'orig-bash-artifact'; a = 'Run `Bash(cd backend && python -m pytest tests/test_a.py -q)`; `tests/test_a.py`.'; p = 'Run `Bash(cd backend && python -m pytest tests/test_a.py -q)`; `tests/test_a.py` for M01.'; want = @('VERIFICATION_UNSUPPORTED_COMMAND_WRAPPER', 'VERIFICATION_NO_EXECUTABLE_COMMAND') },
        @{ n = 'wrapper-sibling'; a = $good; p = 'Run `Bash(pytest tests/test_a.py)`; `python3 -m pytest tests/test_a.py` for M01.'; want = @('VERIFICATION_UNSUPPORTED_COMMAND_WRAPPER') },
        @{ n = 'preamble-sibling'; a = $good; p = 'Run `cd backend && pytest -q`; `pytest tests/test_a.py` for M01.'; want = @('VERIFICATION_UNSUPPORTED_COMMAND_WRAPPER') },
        @{ n = 'inline-inner-pytest'; a = $good; p = 'Run Bash(cd backend && pytest tests/test_a.py) for M01.'; want = @('VERIFICATION_UNSUPPORTED_COMMAND_WRAPPER') },
        @{ n = 'acceptance-wrapper'; a = 'Run `Bash(npm test)`.'; p = $good; want = @('VERIFICATION_UNSUPPORTED_COMMAND_WRAPPER') },
        @{ n = 'artifact-only'; a = 'Covers `tests/test_a.py`.'; p = 'Inspect `tests/test_a.py` for M01.'; want = @('VERIFICATION_NO_EXECUTABLE_COMMAND') },
        @{ n = 'acceptance-only-command'; a = $good; p = 'Inspect `tests/test_a.py` for M01.'; want = @('VERIFICATION_NO_EXECUTABLE_COMMAND') },
        @{ n = 'nothing'; a = 'Looks right.'; p = 'Eyeball it for M01.'; want = @('VERIFICATION_NAMES_NO_RUNNABLE', 'VERIFICATION_NO_EXECUTABLE_COMMAND') },
        @{ n = 'prose-ok'; a = $good; p = 'Run `python3 -m pytest tests/test_a.py` for M01; check `tag_clusters` and `parse(rows)`.'; want = @() }
    )
    $named = @('VERIFICATION_UNSUPPORTED_COMMAND_WRAPPER', 'VERIFICATION_NO_EXECUTABLE_COMMAND', 'VERIFICATION_NAMES_NO_RUNNABLE')
    $paths = @{}
    foreach ($c in $cases) {
        $paths[$c.n] = Write-Mutated $base.roadmap $c.n $c.a $c.p
        $v = Invoke-Validator $paths[$c.n]
        $got = @($named | Where-Object { @(Errors-Named $v $_).Count -gt 0 })
        Check ((($got | Sort-Object) -join ',') -eq ((@($c.want) | Sort-Object) -join ',') -and ($v.exit -eq $(if ($c.want.Count) { 1 } else { 0 }))) "validator $($c.n): want [$($c.want -join ',')] got [$($got -join ',')] exit $($v.exit)"
    }
    # The inline case is the masking hazard: the extractor alone lifts the inner pytest.
    $inner = Extract-NamedArtifacts -Text 'Run Bash(cd backend && pytest tests/test_a.py) for M01.'
    Check (@($inner.commands) -contains 'pytest tests/test_a.py') 'extractor alone lifts the inner pytest (why the wrapper check is needed)'

    # --- dt-build gate on the original and commandless fixtures ---------------------------------
    $tree = Join-Path $root 'tree'
    New-Item -ItemType Directory -Path (Join-Path $tree 'tests') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $tree 'tests/test_a.py') -Value 'def test_a(): pass'
    $g = Invoke-Gate $paths['orig-bash-artifact'] $tree
    Check ($g.exit -eq 0 -and $g.result.status -eq 'INSPECT_ONLY' -and @($g.result.commands_named).Count -eq 0) "Bash(...) fixture: inspect is INSPECT_ONLY with no commands ($($g.result.status))"
    foreach ($n in @('orig-bash-artifact', 'artifact-only', 'acceptance-only-command')) {
        $g = Invoke-Gate $paths[$n] $tree -RunTests
        Check ($g.exit -eq 1 -and $g.result.status -eq 'BLOCKED' -and $g.result.test_status -eq 'NO_COMMAND_NAMED' -and @($g.result.command_results).Count -eq 0) "${n}: RunTests blocks NO_COMMAND_NAMED ($($g.result.status)/$($g.result.test_status))"
    }

    # --- Quoted paths with spaces survive verbatim and execute ----------------------------------
    $gateDir = Join-Path $tree 'gate dir'
    New-Item -ItemType Directory -Path $gateDir | Out-Null
    $py = Join-Path $gateDir 'check it.py'
    Set-Content -LiteralPath $py -Value "import sys, pathlib`npathlib.Path(sys.argv[1]).write_text('|'.join(sys.argv[2:]))"
    Set-Content -LiteralPath (Join-Path $gateDir 'check two.sh') -Value "printf '%s' `"`$1`" > `"`$2`""
    $marker1 = Join-Path $root 'py marker.txt'
    $marker2 = 'sh marker.txt'
    $cmd1 = "python3 `"$py`" `"$marker1`" 'two words' plain"
    $cmd2 = "bash 'gate dir/check two.sh' 'from bash' '$marker2'"
    $r = Invoke-Builder 'quoted' (Design ("- M01: run ``{0}`` and ``{1}``." -f $cmd1, $cmd2))
    Check ($r.exit -eq 0) "quoted-path design builds (stderr: $($r.stderr))"
    Check ($r.roadmap.Contains("Run ``$cmd1``; ``$cmd2`` for M01")) 'quoted commands lifted into the procedure verbatim'
    $v = Invoke-Validator $r.path
    Check ($v.exit -eq 0) "quoted-path roadmap validates ($($v.errors -join ' '))"
    $g = Invoke-Gate $r.path $tree
    Check ($g.result.status -eq 'INSPECT_ONLY' -and (@($g.result.commands_named) -join "`n") -ceq ($cmd1 + "`n" + $cmd2)) 'gate names both quoted commands exactly'
    $g = Invoke-Gate $r.path $tree -RunTests
    $results = @($g.result.command_results)
    Check ($g.exit -eq 0 -and $g.result.status -eq 'PASS' -and $g.result.test_status -eq 'PASS') "quoted-path RunTests PASS ($($g.result.status); $($g.result.blockers -join ' '))"
    Check ($results.Count -eq 2 -and $results[0].command -ceq $cmd1 -and $results[1].command -ceq $cmd2 -and @($results | Where-Object { $_.exit_code -ne 0 }).Count -eq 0) 'gate ran both commands verbatim with exit 0'
    Check ((Test-Path -LiteralPath $marker1) -and (Get-Content -LiteralPath $marker1 -Raw) -ceq "two words|plain") 'python3 received the quoted arguments intact'
    $m2 = Join-Path $tree $marker2
    Check ((Test-Path -LiteralPath $m2) -and (Get-Content -LiteralPath $m2 -Raw) -ceq 'from bash') 'bash ran the single-quoted script path from the working tree root'
} finally {
    $env:DT_BUILD_LOG_DIR = $savedLogDir
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Check (-not (Test-Path -LiteralPath $root)) 'disposable root removed'
Write-Output "SUMMARY: $passed passed, $($failed.Count) failed"
if ($failed.Count) { $failed | ForEach-Object { Write-Output "FAIL: $_" }; exit 1 }
