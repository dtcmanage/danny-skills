param([switch]$Live, [ValidateSet('capture')][string]$Mode = 'capture', [string]$OutDir, [string]$FixtureDir, [string]$CliPath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'probe-claude-output.ps1') -OutDir $OutDir -CliPath $CliPath -Live:$Live

function Invoke-NativeHooksProbe {
    param([string]$Cli, [string]$Destination, [string]$Fixtures)
    $null = New-Item -ItemType Directory -Path $Destination, $Fixtures -Force
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('m02-native-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $tempRoot
    $result = [ordered]@{
        probe = 'native-hooks'; mode = 'capture'; cli_version = $null; forms = @(); probe_error = $null
        codex = @{ label = 'measured-only'; reason = 'No verified temporary-CODEX_HOME hook trust/configuration protocol is available to this Claude probe. No Codex process started and no global files changed.' }
    }
    # The alias in tool input is data for a denied call; every outer session is haiku.
    $forms = [ordered]@{
        'general-purpose' = 'Call Agent once with subagent_type general-purpose.'
        'untyped' = 'Call Agent once without a subagent_type field.'
        'fork' = 'Call Agent once with subagent_type fork (a fork of this conversation).'
        'Explore' = 'Call Agent once with subagent_type Explore.'
        'sonnet' = 'Call Agent once with subagent_type general-purpose and model sonnet.'
        'frontier-alias' = 'Call Agent once with subagent_type general-purpose and model opus.'
        'Workflow' = 'Call Workflow once describing a workflow containing exactly one general-purpose agent.'
    }
    try {
        $info = Get-ProbeCliInfo $Cli $tempRoot
        $result.cli_version = $info.version
        foreach ($name in $forms.Keys) {
            # Leave tool discovery native: naming an unavailable Workflow tool in
            # --tools can reject the entire invocation before Agent can be measured.
            # Workflow must reach its inner call; every other tool stays denied,
            # including Agent/Task and shell fallbacks.
            $cfg = New-ProbeSettings (Join-Path $tempRoot $name) '.*' -AllowWorkflow:($name -eq 'Workflow')
            $cliArgs = @('-p','--model','haiku','--max-turns','2','--strict-mcp-config','--output-format','json','--settings',$cfg.settings)
            if ($info.no_persistence) { $cliArgs += '--no-session-persistence' }
            $instructions = if ($name -eq 'Workflow') {
                ' Workflow is allowed for this protocol test; its inner Agent/Task call must be denied by the hook before the child runs. If Workflow is unavailable, report that and stop. Do not call Agent/Task directly, retry, substitute another form, or use Bash. After the inner denial return OK.'
            } else {
                ' This is a protocol test: a deny hook must block the call before any child runs. Do not retry, substitute another form, or use Bash. After denial return OK.'
            }
            $prompt = $forms[$name] + ' Use a tiny prompt saying return OK.' + $instructions
            $run = Invoke-ProbeCli $Cli $cliArgs $prompt $tempRoot
            $payloads = @(Get-ProbePayloads $cfg.log)
            $matching = @($payloads | Where-Object {
                $p = $_
                if ($p.tool_name -notin @('Agent','Task','Workflow')) { return $false }
                $inputData = $p.tool_input
                switch ($name) {
                    'general-purpose' { return $p.tool_name -in @('Agent','Task') -and $inputData['subagent_type'] -eq 'general-purpose' }
                    'untyped' { return $p.tool_name -in @('Agent','Task') -and -not $inputData.ContainsKey('subagent_type') }
                    'fork' { return $p.tool_name -in @('Agent','Task') -and $inputData['subagent_type'] -eq 'fork' }
                    'Explore' { return $p.tool_name -in @('Agent','Task') -and $inputData['subagent_type'] -eq 'Explore' }
                    'sonnet' { return $p.tool_name -in @('Agent','Task') -and $inputData['model'] -eq 'sonnet' }
                    'frontier-alias' { return $p.tool_name -in @('Agent','Task') -and $inputData['model'] -eq 'opus' }
                    'Workflow' { return $p.tool_name -in @('Workflow','Agent','Task') }
                }
            })
            $fired = $matching.Count -gt 0
            $innerDenied = $name -eq 'Workflow' -and @($matching | Where-Object { $_.tool_name -in @('Agent','Task') }).Count -gt 0
            $fixture = $null
            if ($payloads.Count -gt 0) {
                $fixture = $name + '.json'
                ConvertTo-Json -InputObject $payloads -Depth 50 | Set-Content (Join-Path $Fixtures $fixture) -Encoding utf8NoBOM
            }
            $result.forms += @{
                form = $name; label = if ($fired) { 'fired' } else { 'not-fired' }
                support = if ($innerDenied) { 'enforced-inner-agent' } elseif ($fired -and $name -ne 'Workflow') { 'captured-denied' } else { 'unsupported' }
                reason = if ($name -eq 'Workflow' -and -not $innerDenied) {
                    if ($fired) { 'Workflow was allowed and logged, but no inner Agent/Task payload reached the deny hook; inner enforcement is unsupported.' }
                    else { 'Workflow did not reach the hook; the tool may be unavailable in this session, its schema invalid, or the model may have refused. No inner Agent/Task denial was observed; enforcement is unsupported.' }
                } elseif (-not $fired) { 'Requested form did not reach the hook; unavailable tool, invalid schema, or model refusal cannot establish enforcement.' } else { $null }
                fixture = $fixture; cli_exit_code = $run.exit_code; no_session_persistence = $info.no_persistence
            }
        }
    } catch { $result.probe_error = 'probe-infrastructure-failure: ' + $_.Exception.GetType().Name + ': ' + (ConvertTo-ProbeSanitized $_.Exception.Message) + ' line ' + $_.InvocationInfo.ScriptLineNumber }
    finally {
        $result | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $Destination 'result.json') -Encoding utf8NoBOM
        if (Test-Path $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
    return $result
}

if ($MyInvocation.InvocationName -eq '.') { return }
if (-not $Live) { throw 'This probe requires explicit -Live. Offline tests dot-source functions and use a fake CLI.' }
if (-not $OutDir -or -not $FixtureDir) { throw '-OutDir and -FixtureDir are required.' }
if (-not $CliPath) { $CliPath = (Get-Command claude -ErrorAction Stop).Source }
$r = Invoke-NativeHooksProbe $CliPath ([IO.Path]::GetFullPath($OutDir)) ([IO.Path]::GetFullPath($FixtureDir))
if ($r.probe_error) { exit 1 }
exit 0
