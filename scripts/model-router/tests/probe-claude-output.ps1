param([switch]$Live, [string]$OutDir, [string]$CliPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared only by the two probes and their offline harness. Dot-sourcing never launches a CLI.
function ConvertTo-ProbeSanitized {
    param($Value, [string]$Key = '')
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $clean = @{}
        foreach ($k in $Value.Keys) { $clean[$k] = ConvertTo-ProbeSanitized $Value[$k] ([string]$k) }
        return $clean
    }
    if ($Value -is [array]) { return ,@($Value | ForEach-Object { ConvertTo-ProbeSanitized $_ $Key }) }
    if ($Value -is [string]) {
        if ($Key -match '(?i)prompt|description|instruction|message|content|session|transcript|cwd|directory|path|token|secret') { return '<redacted>' }
        $s = $Value -replace '(?i)[a-z]:[\\/][^\s"'']+', '<path>'
        $s = $s -replace '(?<![\w:])/(?:[^\s/"'']+/)*[^\s"'']+', '<path>'
        return ($s -replace '(?i)\b[0-9a-f]{8}-[0-9a-f-]{27,}\b', '<id>')
    }
    return $Value
}

function Invoke-ProbeCli {
    param([string]$Cli, [string[]]$Arguments, [string]$InputText = '', [string]$WorkingDirectory)
    $si = [Diagnostics.ProcessStartInfo]::new()
    $si.FileName = $Cli
    $prefix = @()
    if ([IO.Path]::GetExtension($Cli) -eq '.ps1') {
        $si.FileName = (Get-Command pwsh -ErrorAction Stop).Source
        $prefix = @('-NoProfile', '-File', $Cli)
    } elseif ([IO.Path]::GetExtension($Cli) -in @('.cmd', '.bat')) {
        $si.FileName = $env:ComSpec
        $prefix = @('/d', '/s', '/c', ('""' + $Cli + '" ' + (($Arguments | ForEach-Object { '"' + $_.Replace('"','\"') + '"' }) -join ' ') + '"'))
        $Arguments = @()
    }
    foreach ($a in @($prefix) + @($Arguments)) { $null = $si.ArgumentList.Add($a) }
    $si.WorkingDirectory = $WorkingDirectory
    $si.UseShellExecute = $false
    $si.CreateNoWindow = $true
    $si.RedirectStandardInput = $true
    $si.RedirectStandardOutput = $true
    $si.RedirectStandardError = $true
    $si.StandardInputEncoding = $si.StandardOutputEncoding = $si.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    # Inherit PATH and plugin configuration unchanged. No persistent environment edits.
    $p = [Diagnostics.Process]::new()
    $p.StartInfo = $si
    try {
        if (-not $p.Start()) { throw 'Probe CLI could not start.' }
        $stdout = $p.StandardOutput.ReadToEndAsync()
        $stderr = $p.StandardError.ReadToEndAsync()
        $p.StandardInput.Write($InputText)
        $p.StandardInput.Close()
        if (-not $p.WaitForExit(120000)) { $p.Kill($true); throw 'Probe CLI timed out after 120 seconds.' }
        return @{ stdout = $stdout.GetAwaiter().GetResult(); stderr = $stderr.GetAwaiter().GetResult(); exit_code = $p.ExitCode }
    } finally { $p.Dispose() }
}

function New-ProbeSettings {
    param([string]$Root, [string]$Matcher, [switch]$DisableTimestamp, [switch]$AllowWorkflow)
    $null = New-Item -ItemType Directory -Path $Root -Force
    $logPath = Join-Path $Root 'hooks.jsonl'
    $hookPath = Join-Path $Root 'deny.ps1'
    $sanitize = (Get-Command ConvertTo-ProbeSanitized).Definition
    $hook = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function ConvertTo-ProbeSanitized {
__SANITIZE__
}
$payload = [Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable
$clean = ConvertTo-ProbeSanitized $payload
[IO.File]::AppendAllText('__LOG__', (($clean | ConvertTo-Json -Depth 50 -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
if (__ALLOW_WORKFLOW__ -and $payload['tool_name'] -eq 'Workflow') {
    @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'allow' } } | ConvertTo-Json -Compress
    exit 0
}
@{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = 'M02 protocol probe: denied; do not retry or use another tool.' } } | ConvertTo-Json -Compress
'@
    [IO.File]::WriteAllText($hookPath, $hook.Replace('__SANITIZE__', $sanitize).Replace('__LOG__', $logPath.Replace("'", "''")).Replace('__ALLOW_WORKFLOW__', ('$' + $AllowWorkflow.ToString().ToLowerInvariant())))
    $command = 'pwsh -NoProfile -File "' + $hookPath.Replace('\','/') + '"'
    $settings = @{ hooks = @{ PreToolUse = @(@{ matcher = $Matcher; hooks = @(@{ type = 'command'; command = $command; timeout = 10 }) }) } }
    if ($DisableTimestamp) { $settings.enabledPlugins = @{ 'message-timestamps@zoharbabin-claude-tools' = $false } }
    $path = Join-Path $Root 'settings.json'
    $settings | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    return @{ settings = $path; log = $logPath }
}

function Get-ProbePayloads {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in [IO.File]::ReadAllLines($Path)) {
            if ($line) { ConvertTo-ProbeSanitized ($line | ConvertFrom-Json -AsHashtable) }
        }
    }
}

function Read-ProbeOutput {
    param([string]$Text, [switch]$Stream)
    $events = if ($Stream) { @($Text -split '\r?\n' | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable }) } else { @($Text | ConvertFrom-Json -AsHashtable) }
    $models = @()
    $answer = $null
    foreach ($e in $events) {
        if ($e.ContainsKey('modelUsage')) { $models += @($e.modelUsage.Keys) }
        if ($Stream -and $e.type -eq 'assistant' -and $e.ContainsKey('message')) {
            if ($e.message.ContainsKey('model')) { $models += $e.message.model }
            # Last assistant message only; do not trim or strip timestamp prefixes.
            $answer = (@($e.message.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join '')
        } elseif (-not $Stream -and $e.ContainsKey('result')) { $answer = [string]$e.result }
    }
    return @{ text = $answer; models = @($models | Where-Object { $_ } | Select-Object -Unique) }
}

function Get-ProbeCliInfo {
    param([string]$Cli, [string]$Root)
    $version = Invoke-ProbeCli $Cli @('--version') '' $Root
    $help = Invoke-ProbeCli $Cli @('--help') '' $Root
    if ($version.exit_code -ne 0 -or $help.exit_code -ne 0) { throw 'Probe CLI version/help preflight failed.' }
    return @{ version = $version.stdout.Trim(); no_persistence = ($help.stdout -match '--no-session-persistence') }
}

function Invoke-ClaudeOutputProbe {
    param([string]$Cli, [string]$Destination)
    $null = New-Item -ItemType Directory -Path $Destination -Force
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('m02-output-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $tempRoot
    $result = [ordered]@{ probe = 'claude-output'; cli_version = $null; candidates = @(); probe_error = $null }
    try {
        $info = Get-ProbeCliInfo $Cli $tempRoot
        $result.cli_version = $info.version
        foreach ($candidate in @('stream-json', 'settings-plugin-off')) {
            $cfg = New-ProbeSettings (Join-Path $tempRoot $candidate) 'Bash' -DisableTimestamp:($candidate -eq 'settings-plugin-off')
            $format = if ($candidate -eq 'stream-json') { 'stream-json' } else { 'json' }
            $cliArgs = @('-p','--model','haiku','--max-turns','3','--strict-mcp-config','--tools','Bash','--output-format',$format,'--settings',$cfg.settings)
            if ($info.no_persistence) { $cliArgs += '--no-session-persistence' }
            if ($format -eq 'stream-json') { $cliArgs += '--verbose' }
            $expected = 'M02_BYTE_EXACT_OK'
            $prompt = 'Use Bash exactly once to run the literal harmless command: claude -p --version . It will be denied by a test hook. Do not retry or delegate. Then respond with exactly M02_BYTE_EXACT_OK and no other text or whitespace.'
            $run = Invoke-ProbeCli $Cli $cliArgs $prompt $tempRoot
            $parseError = $null
            $parsed = @{ text = $null; models = @() }
            try { $parsed = Read-ProbeOutput $run.stdout -Stream:($format -eq 'stream-json') } catch { $parseError = 'unparseable-output' }
            $payloads = @(Get-ProbePayloads $cfg.log)
            $denied = @($payloads | Where-Object { $_.tool_name -eq 'Bash' -and $_.tool_input.command -match '^\s*claude\s+-p\s+--version\s*$' }).Count -gt 0
            $exact = $null -ne $parsed.text -and [string]::Equals($parsed.text, $expected, [StringComparison]::Ordinal)
            $result.candidates += [ordered]@{
                candidate = $candidate; expected = $expected; actual_text = $parsed.text
                expected_utf8_base64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($expected))
                actual_utf8_base64 = if ($null -ne $parsed.text) { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($parsed.text)) } else { $null }
                byte_exact = $exact; model_identity_available = ($parsed.models.Count -gt 0); models = $parsed.models
                worker_hook_denied_literal = $denied; hooks = $payloads; cli_exit_code = $run.exit_code; parse_error = $parseError
                no_session_persistence = $info.no_persistence
                accepted = ($exact -and $parsed.models.Count -gt 0 -and $denied -and $run.exit_code -eq 0)
            }
        }
    } catch { $result.probe_error = 'probe-infrastructure-failure: ' + $_.Exception.GetType().Name }
    finally {
        $result | ConvertTo-Json -Depth 50 | Set-Content (Join-Path $Destination 'result.json') -Encoding utf8NoBOM
        if (Test-Path $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
    return $result
}

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $Live) { throw 'This probe requires explicit -Live. Offline tests dot-source functions and use a fake CLI.' }
if (-not $OutDir) { throw '-OutDir is required.' }
if (-not $CliPath) { $CliPath = (Get-Command claude -ErrorAction Stop).Source }
$r = Invoke-ClaudeOutputProbe $CliPath ([IO.Path]::GetFullPath($OutDir))
if ($r.probe_error) { exit 1 }
exit 0
