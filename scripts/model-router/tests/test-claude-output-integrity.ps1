Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../claude-cli-result.ps1')
. (Join-Path $PSScriptRoot 'probe-claude-output.ps1')
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$root = Join-Path ([IO.Path]::GetTempPath()) ('m03-integrity-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$invocation = $null
$checks = 0
function Check([bool]$Value, [string]$Name) {
    if (-not $Value) { throw "FAIL: $Name" }
    $script:checks++
}
function Reject([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch {
        Check ($_.Exception.Message -match $Pattern) 'expected rejection'
        return
    }
    throw 'FAIL: unexpectedly accepted invalid output'
}
try {
    $priorPath = $env:PATH
    $invocation = New-ClaudeCliInvocation
    $settingsPath = $invocation.SettingsPath
    $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json -AsHashtable
    Check ($settings.Count -eq 1 -and $settings.enabledPlugins.Count -eq 1 -and $settings.enabledPlugins['message-timestamps@zoharbabin-claude-tools'] -eq $false) 'only the timestamp plugin is overridden; hooks inherit'
    Check ($invocation.Arguments[0] -ceq '--settings' -and $invocation.Arguments[1] -ceq $settingsPath) 'per invocation settings arguments'
    $cli = Join-Path $root 'fake claude.ps1'
    [IO.File]::WriteAllText($cli, @'
$i = [array]::IndexOf($args, '--settings')
if ($i -lt 0) { throw 'missing settings' }
$cfg = Get-Content -LiteralPath $args[$i+1] -Raw | ConvertFrom-Json -AsHashtable
if ($cfg.Count -ne 1 -or $cfg.enabledPlugins.Count -ne 1 -or $cfg.enabledPlugins['message-timestamps@zoharbabin-claude-tools'] -ne $false) { throw 'wrong override' }
$answer = [Console]::In.ReadToEnd()
[Console]::Write((@{result=$answer;is_error=$false;modelUsage=@{'claude-opus-5-5'=@{inputTokens=1;outputTokens=1}}} | ConvertTo-Json -Depth 6 -Compress))
'@)
    $exact = "  Snow 雪 😀`r`nline two`t "
    $run = Invoke-ProbeCli $cli (@('-p','--model','opus','--output-format','json') + $invocation.Arguments) $exact $root
    Check ($run.exit_code -eq 0) 'fake CLI ran'
    $parsed = $invocation.ReadResult($run.stdout, 'opus')
    Check ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($parsed.result)) -ceq [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($exact))) 'UTF8 bytes and whitespace preserved'
    Check ($parsed.resolved_model -ceq 'claude-opus-5-5') 'model identity retained'
    Check ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) 'installed PowerShell supports DateKind'
    foreach ($iso in @('2026-11-05T10:00:00Z', '2026-11-05T10:00:00.1234567-05:00')) {
        $dateEnvelope = @{result=$iso;modelUsage=@{'claude-opus-5-5'=@{outputTokens=1}}} | ConvertTo-Json -Depth 5
        Check ($invocation.ReadResult($dateEnvelope, 'opus').result -ceq $iso) 'ISO date result bytes preserved'
    }
    $prefixed = @{result='[04:15:28] OK';modelUsage=@{'claude-opus-5-5'=@{outputTokens=1}}} | ConvertTo-Json -Depth 5
    Reject { $invocation.ReadResult($prefixed, 'opus') } 'timestamp prefix'
    Reject { $invocation.ReadResult(('[04:15:28] ' + $run.stdout), 'opus') } 'unparseable'
    Reject { $invocation.ReadResult('{"result":"OK"}', 'opus') } 'no modelUsage'
    Reject { $invocation.ReadResult($run.stdout, 'haiku') } 'Requested'

    # Execute the production round parser against a fake CLI response, without
    # running wrapper routing, live sessions, or a model.
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'skills/dt-review/scripts/invoke-claude-round.ps1'), [ref]$tokens, [ref]$errors)
    $fn = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ConvertFrom-ClaudeReviewOutput'}, $true)
    . ([scriptblock]::Create($fn.Extent.Text))
    $round = '{"round":1,"verdict":"PASS","findings":[]}'
    $run = Invoke-ProbeCli $cli (@('-p','--model','opus','--output-format','json') + $invocation.Arguments) $round $root
    Check ($run.exit_code -eq 0) 'fake JSON round CLI ran'
    $review = ConvertFrom-ClaudeReviewOutput ($invocation.ReadResult($run.stdout, 'opus').result)
    Check ($review.round -eq 1 -and $review.verdict -ceq 'PASS' -and $review.findings.Count -eq 0) 'JSON round parses through production parser'
    Reject { ConvertFrom-ClaudeReviewOutput ('[04:15:28] ' + $round) } '.'
    Check ($env:PATH -ceq $priorPath) 'PATH unchanged'
    $invocation.Dispose()
    Check (-not (Test-Path -LiteralPath $settingsPath)) 'success cleanup'
    $failedPath = $null
    $failureThrown = $false
    try {
        $failed = New-ClaudeCliInvocation
        $failedPath = $failed.SettingsPath
        try { $failed.ReadResult($prefixed, 'opus') | Out-Null } finally { $failed.Dispose() }
    } catch { $failureThrown = $true; Check ($_.Exception.Message -match 'timestamp prefix') 'failure propagated' }
    Check $failureThrown 'failure cleanup exercised an exception'
    Check (-not (Test-Path -LiteralPath $failedPath)) 'failure cleanup'
    "PASS: $checks Claude output integrity checks (fake CLI only)"
} finally {
    if ($invocation) { $invocation.Dispose() }
    Remove-Item -LiteralPath $root -Recurse -Force
}
