# Independent parser fixtures: no runtime lease, model calls or shared run state.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../..'))
. (Join-Path $repo 'scripts/extract-named-artifacts.ps1')
$passed = 0; $failed = [Collections.Generic.List[string]]::new()
function Check([bool]$Ok, [string]$Label) { if ($Ok) { $script:passed++; "PASS: $Label" } else { $script:failed.Add($Label) } }
foreach ($prose in @('router pytest `-n 8` returned green', 'Run Bash(cd backend && pytest tests/test_a.py) for M01.', 'pytest tests/test_a.py is mentioned in prose', 'The python scripts/check.py result is green.')) {
    Check (@((Extract-NamedArtifacts $prose).commands).Count -eq 0) "prose cannot invent commands: $prose"
}
$runners = @('pytest -q', 'python scripts/a.py', 'python3 tests/a.py', 'python3.12 -m pytest', 'pwsh -NoProfile -File t.ps1', 'powershell -File t.ps1', 'node t.js', 'npm test', 'npx vitest run', 'pnpm test', 'bun test', 'bash scripts/check.sh', 'sh check.sh', 'uv run pytest', 'make test', 'go test ./...', 'cargo test', './scripts/check.sh --fast', 'python3 "gate dir/check it.py" "two words"', "bash 'gate dir/check two.sh' 'from bash'")
foreach ($cmd in $runners) {
    foreach ($text in @(('Run `' + $cmd + '` for M01.'), ('Test Command: ' + $cmd), ("~~~bash`n$cmd`n~~~"), ('``' + $cmd + '``'))) {
        $r = Extract-NamedArtifacts $text
        Check ($r.commands.Count -eq 1 -and $r.commands[0] -ceq $cmd) "preserve executable input: $text"
    }
}
$r = Extract-NamedArtifacts ('Run `python -m pytest tests/test_a.py` and inspect `replay/report.md`.')
Check ($r.commands.Count -eq 1 -and $r.artifacts -contains 'tests/test_a.py' -and $r.artifacts -contains 'replay/report.md') 'paths retained and nested pytest not run twice'
$r = Extract-NamedArtifacts "``````sh`npytest tests/a.py`nbash scripts/check.sh`n```````nrouter pytest ``-n 8`` green"
Check ($r.commands.Count -eq 2 -and $r.commands[0] -ceq 'pytest tests/a.py' -and $r.commands[1] -ceq 'bash scripts/check.sh') 'multiline fence and adjacent prose stay separated'
$functions = foreach ($path in @('scripts/extract-named-artifacts.ps1','skills/dt-build/scripts/verify-milestone-acceptance.ps1')) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $path),[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) "parses: $path"
    $ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Extract-NamedArtifacts'},$true).Extent.Text
}
# Check emits messages, so select the function text explicitly.
$bodies = @($functions | Where-Object { $_.StartsWith('function Extract-NamedArtifacts {') })
Check ($bodies.Count -eq 2 -and $bodies[0] -ceq $bodies[1]) 'extractor function copies are byte-identical UTF-8'
"SUMMARY: $passed passed, $($failed.Count) failed"
$failed | ForEach-Object { "FAIL: $_" }
if ($failed.Count) { exit 1 }
