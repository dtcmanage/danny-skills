# PowerShell-only timing fixtures. The acceptance helper is replaced by a
# PowerShell stub that starts no Python, pytest, grader or model process.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('pytest-admission-' + [guid]::NewGuid().ToString('N'))
$passed = 0
$children = @()
$stream = [IO.MemoryStream]::new()
function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw "ASSERT_FAIL: $message" }
    $script:passed++
}
function Load-Functions([string]$path, [string[]]$names, [string]$scriptRoot) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
    if ($errors) { throw 'fixture source does not parse' }
    foreach ($name in $names) {
        $node = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
        if (-not $node) { throw "missing fixture function $name" }
        $text = $node.Extent.Text
        if ($scriptRoot) { $text = $text.Replace('$PSScriptRoot', ("'" + $scriptRoot.Replace("'", "''") + "'")) }
        . ([scriptblock]::Create($text.Replace("function $name", "function script:$name")))
    }
}
try {
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    Load-Functions (Join-Path $repo 'skills/dt-build/scripts/verify-milestone-acceptance.ps1') @('Parse-MarkdownTableRows') ''
    $rows = @(Parse-MarkdownTableRows -SectionText "| check-id | procedure | exclusive_reason |`n| --- | --- | --- |`n| direct | pytest fixture | |`n| opted | pytest fixture | documented evidence |")
    Assert-True ($rows.Count -eq 2 -and $rows[0].exclusive_reason -eq '' -and $rows[1].exclusive_reason -eq 'documented evidence') 'optional acceptance reason column preserves blank entries'
    $rows = @(Parse-MarkdownTableRows -SectionText "| check-id | procedure | exclusive_reason |`n| --- | --- | --- |`n| opted | pytest fixture | documented evidence")
    Assert-True ($rows.Count -eq 1 -and $rows[0].exclusive_reason -eq 'documented evidence') 'optional reason survives a Markdown row without a trailing delimiter'
    Load-Functions (Join-Path $repo 'skills/dt-build/scripts/dt-job-runner.ps1') @('Get-DtJobTreeCpuSeconds','Wait-DtJobProcess') ''
    function Get-DtJobSettingSec { param($Name,$Default) return 1 }
    function Write-DtJobAtomic { param($Path,$Content) [IO.File]::WriteAllText($Path,$Content) }
    $script:DtJobHeartbeatSec = 30
    $jobDir = $fixture; $paths = @{ Root = $fixture }; $JobId = 'fixture-admission'
    foreach ($mode in @('admitted','timeout')) {
        $ready = Join-Path $fixture "$mode.ready"
        $childScript = Join-Path $fixture "$mode.ps1"
        $delay = if ($mode -eq 'admitted') { 4 } else { 0 }
        $execution = if ($mode -eq 'admitted') { 1 } else { 10 }
        [IO.File]::WriteAllText($childScript,"Start-Sleep -Seconds $delay; [IO.File]::WriteAllText('$ready','acquired'); Start-Sleep -Seconds $execution")
        $child = Start-Process pwsh -ArgumentList @('-NoProfile','-File',('"'+$childScript+'"')) -WindowStyle Hidden -PassThru
        $children += $child
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $finished = Wait-DtJobProcess -Process $child -TimeoutSec 2 -WorkDir $fixture -Outputs @($stream) -AdmissionReady $ready
        if ($mode -eq 'admitted') {
            Assert-True ($finished -and $clock.Elapsed.TotalSeconds -ge 4) 'runner excludes a wait longer than its execution budget'
        } else {
            Assert-True (-not $finished -and $clock.Elapsed.TotalSeconds -lt 8) 'runner still enforces candidate execution timeout'
        }
        if (-not $child.HasExited) { $child.Kill($true); [void]$child.WaitForExit(5000) }
    }
    $stubRoot = Join-Path $fixture 'skills/dt-build/scripts'
    $stubScripts = Join-Path $fixture 'scripts'
    New-Item -ItemType Directory -Path $stubRoot,$stubScripts -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $stubScripts 'pytest-lock.ps1'), @'
param()
# Deliberately ignore forwarded candidate command; this is a PS-only fixture.
if ($args[0] -ne '-Reason' -or $args[2] -ne '-ReadyFile') { throw 'missing documented admission arguments' }
Start-Sleep -Seconds 4
[IO.File]::WriteAllText([string]$args[3], 'acquired')
Start-Sleep -Milliseconds 200
Write-Output 'PS admission fixture'
exit 0
'@)
    Load-Functions (Join-Path $repo 'skills/dt-build/scripts/verify-milestone-acceptance.ps1') @('Normalize-Command','Remove-TempFileQuietly','Invoke-NamedCommand') $stubRoot
    $reason = "fixture suite: deliberate contention; shared 'marker' required for timing evidence"
    $result = Invoke-NamedCommand -WorkingTree $fixture -Command 'pytest fixture-selection' -TimeoutMs 2000 -ExclusiveReason $reason
    Assert-True ($result.exit_code -eq 0 -and -not $result.timed_out -and $result.duration_ms -ge 4000 -and $result.stdout_tail -match 'PS admission fixture') 'acceptance execution budget excludes PS stub lock admission'
    Assert-True ($result.exclusive_reason -ceq $reason -and $result.effective_command -match '-Reason') 'acceptance records the exact documented reason'
    $direct = "function pytest { 'direct fixture' }; pytest"
    foreach ($emptyReason in @($null, '', '   ')) {
        $result = Invoke-NamedCommand -WorkingTree $fixture -Command $direct -TimeoutMs 2000 -ExclusiveReason $emptyReason
        Assert-True ($result.exit_code -eq 0 -and $result.effective_command -ceq $direct -and $result.stdout_tail -match 'direct fixture') 'pytest acceptance without a nonempty reason runs directly'
    }
    $result = Invoke-NamedCommand -WorkingTree $fixture -Command 'Start-Sleep -Seconds 10' -TimeoutMs 200
    Assert-True ($result.exit_code -eq 124 -and $result.timed_out) 'acceptance still enforces non-pytest execution timeout'
    Write-Output "PASS: PowerShell admission fixtures; SUMMARY: $passed passed"
} finally {
    foreach ($child in $children) { if (-not $child.HasExited) { $child.Kill($true); [void]$child.WaitForExit(5000) }; $child.Dispose() }
    $stream.Dispose()
    $resolved = [IO.Path]::GetFullPath($fixture)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) { throw 'fixture cleanup escaped temp directory' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
