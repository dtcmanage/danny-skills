Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($key in @('DT_JOB_ID','DT_JOB_DIR','DT_BUILD_COORDINATOR_ID','ROUTER_GUARD_OFF')) { [Environment]::SetEnvironmentVariable($key, $null, 'Process') }
$root = Join-Path ([IO.Path]::GetTempPath()) ('m05-harness-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$failures = [Collections.Generic.List[string]]::new()
$keptCaseFolders = [Collections.Generic.List[string]]::new()
$checks = 0
function Assert { param([bool]$Condition,[string]$Message) if (-not $Condition) { throw $Message } }
function Check {
    param([string]$Name,[scriptblock]$Body)
    $script:checks++
    try { & $Body; Write-Output "PASS $Name" } catch { $script:failures.Add("${Name}: $($_.Exception.Message)"); Write-Output "FAIL ${Name}: $($_.Exception.Message)" }
}
$installer = Join-Path $PSScriptRoot '../guard-settings.ps1'
try {
    Check 'install separate entry, primary path, idempotent and byte-exact rollback' {
        $settings = Join-Path $root 'settings.json'
        $original = [Text.UTF8Encoding]::new($true).GetPreamble() + [Text.Encoding]::UTF8.GetBytes("{`r`n  `"hooks`": {`"PreToolUse`": [{`"matcher`": `"Read|Bash|PowerShell`", `"hooks`": [{`"type`": `"command`", `"command`": `"python read_guard.py`"}]}]}, `"enabledPlugins`": {`"timestamps`": true}`r`n}")
        [IO.File]::WriteAllBytes($settings,$original)
        & pwsh -NoProfile -File $installer -SettingsPath $settings -Action status > (Join-Path $root 'status-before.log')
        Assert ($LASTEXITCODE -eq 0) 'status failed'
        & pwsh -NoProfile -File $installer -SettingsPath $settings -Action install > (Join-Path $root 'install.log')
        Assert ($LASTEXITCODE -eq 0) 'install failed'
        $first = [IO.File]::ReadAllBytes($settings)
        $cfg = Get-Content $settings -Raw | ConvertFrom-Json -AsHashtable
        Assert ($cfg.hooks.PreToolUse.Count -eq 2) 'Existing guard not preserved separately'
        Assert ($cfg.hooks.PreToolUse[0].hooks[0].command -eq 'python read_guard.py') 'Read guard changed'
        Assert ($cfg.enabledPlugins.timestamps -eq $true) 'Plugin changed'
        $script:entry = $cfg.hooks.PreToolUse[1]
        Assert ($entry.hooks[0].command -eq '"C:/Users/Danny/AppData/Local/Python/pythoncore-3.14-64/python.exe" -I "D:/Claude/_Claude-Workspace/Skill Creation/danny-skills/scripts/model-router/dispatch-guard.py"') 'Not post-merge primary path'
        foreach ($tool in @('Agent','Task','Bash','PowerShell')) { Assert ($tool -match $entry.matcher) "Matcher misses $tool" }
        Assert ('Workflow' -notmatch $entry.matcher) 'Workflow matched'
        & pwsh -NoProfile -File $installer -SettingsPath $settings -Action install > (Join-Path $root 'reinstall.log')
        Assert ($LASTEXITCODE -eq 0 -and [Convert]::ToBase64String($first) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($settings))) 'Install not idempotent'
        $status = & pwsh -NoProfile -File $installer -SettingsPath $settings -Action status | ConvertFrom-Json
        Assert ($status.installed -and $status.backup_present) 'Wrong installed status'
        & pwsh -NoProfile -File $installer -SettingsPath $settings -Action rollback > (Join-Path $root 'rollback.log')
        Assert ($LASTEXITCODE -eq 0 -and [Convert]::ToBase64String($original) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($settings))) 'Rollback differs bytewise'
        & pwsh -NoProfile -File $installer -SettingsPath $settings -Action rollback > (Join-Path $root 'rerollback.log')
        Assert ($LASTEXITCODE -eq 0) 'Rollback not idempotent'
    }
    Check 'rollback without backup leaves installed entry and names manual removal' {
        $settings = Join-Path $root 'pasted.json'
        @{ hooks = @{ PreToolUse = @($entry) } } | ConvertTo-Json -Depth 20 | Set-Content $settings
        $before = [IO.File]::ReadAllBytes($settings)
        $message = & pwsh -NoProfile -File $installer -SettingsPath $settings -Action rollback
        Assert ($LASTEXITCODE -eq 1) 'Installed entry rollback must fail without backup'
        Assert ($message -match 'No backup exists.*still installed.*Remove.*hook entry by hand') 'Manual removal explanation missing'
        Assert ([Convert]::ToBase64String($before) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($settings))) 'Pasted settings changed'
    }
    Check 'rollback without backup or entry reports nothing to roll back' {
        $settings = Join-Path $root 'empty.json'
        '{}' | Set-Content $settings
        $message = & pwsh -NoProfile -File $installer -SettingsPath $settings -Action rollback
        Assert ($LASTEXITCODE -eq 0 -and $message -ceq 'nothing to roll back') 'Wrong empty rollback outcome'
    }
    Check 'malformed settings rollback writes nothing' {
        $settings = Join-Path $root 'malformed.json'
        '{broken' | Set-Content $settings
        $before = [IO.File]::ReadAllBytes($settings)
        & pwsh -NoProfile -File $installer -SettingsPath $settings -Action rollback *> (Join-Path $root 'malformed.log')
        Assert ($LASTEXITCODE -ne 0) 'Malformed settings accepted'
        Assert ([Convert]::ToBase64String($before) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($settings))) 'Malformed settings changed'
        Assert (-not (Test-Path ($settings + '.router-guard.backup'))) 'Malformed settings backed up'
    }
    Check 'guard probe refuses without Live' {
        & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'probe-native-hooks.ps1') -Mode guard -OutDir (Join-Path $root 'refused') *> (Join-Path $root 'refused.log')
        Assert ($LASTEXITCODE -ne 0 -and -not (Test-Path (Join-Path $root 'refused'))) 'Live gate missing'
    }
    $fake = Join-Path $root 'fake-claude.ps1'
    @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
foreach ($key in @('DT_JOB_ID','DT_JOB_DIR','DT_BUILD_COORDINATOR_ID')) { [Environment]::SetEnvironmentVariable($key, $null, 'Process') }
if ($args -contains '--version') { 'fake-claude'; exit 0 }
if ($args -contains '--help') { '--no-session-persistence'; exit 0 }
$promptText = [Console]::In.ReadToEnd()
$settings = $args[[array]::IndexOf($args,'--settings') + 1]
$cfg = Get-Content $settings -Raw | ConvertFrom-Json -AsHashtable
$hook = [regex]::Match($cfg.hooks.PreToolUse[0].hooks[0].command, '-File "([^"]+)"').Groups[1].Value
$tool = 'Agent'; $inputData = @{ model = 'opus' }
if ($promptText.Contains('subagent_type fork')) { $inputData = @{ subagent_type = 'fork' } }
if ($promptText.Contains('headless worker')) {
    if ($args -notcontains '--tools' -or $args[[array]::IndexOf($args,'--tools')+1] -match 'Agent') { throw 'Worker has Agent' }
    $tool = 'Bash'; $inputData = @{ command = 'claude -p --version' }
}
$p = @{ hook_event_name = 'PreToolUse'; tool_name = $tool; tool_input = $inputData; cwd = (Get-Location).Path }
if ($env:M05_FAKE_CASE -ne 'no-hook') {
    $d = $p | ConvertTo-Json -Depth 10 -Compress | & pwsh -NoProfile -File $hook | ConvertFrom-Json
    if ($d.hookSpecificOutput.permissionDecision -ne 'deny' -or $d.hookSpecificOutput.permissionDecisionReason -notmatch '^ROUTER_GUARD_DENY:.*dispatch.ps1') { throw 'Real guard did not deny' }
}
if ($env:M05_FAKE_CASE -ne 'no-retry') {
    $command = [regex]::Match($promptText, 'exact command: (.+) \. Do not substitute').Groups[1].Value
    $p.tool_name = 'Bash'; $p.tool_input = @{ command = $command }
    $d = $p | ConvertTo-Json -Depth 10 -Compress | & pwsh -NoProfile -File $hook
    if ($d) { throw 'Dispatch denied' }
    $retry = [regex]::Match($command, '^pwsh -NoProfile -File "([^"\\]+/retry-dispatch\.ps1)"$')
    if (-not $retry.Success) { throw 'Short retry script command missing' }
    $body = Get-Content $retry.Groups[1].Value -Raw
    if ($body -notmatch 'dispatch\.ps1.*-Category routine-coding -PromptPath ') { throw 'Categorized dispatch missing from retry script' }
    $output = [regex]::Match($body, "-OutputPath '([^']+)'").Groups[1].Value
    if ($env:M05_FAKE_CASE -ne 'no-output') { 'M05_DISPATCH_OK' | Set-Content $output }
    if ($env:M05_FAKE_CASE -ne 'no-provenance') {
        @{ execution_result = $(if ($env:M05_FAKE_CASE -eq 'failed-retry') { 'failure' } else { 'success' }); actual_model = $null } | ConvertTo-Json | Set-Content ($output + '.provenance.json')
    }
}
@{ type = 'assistant'; message = @{ model = 'fake-haiku'; content = @(@{ type = 'text'; text = 'OK' }) } } | ConvertTo-Json -Depth 10 -Compress
'@ | Set-Content $fake -Encoding utf8NoBOM
    . (Join-Path $PSScriptRoot 'probe-native-hooks.ps1')
    foreach ($case in @('ok','no-hook','no-retry','no-output','no-provenance','failed-retry')) {
        Check "fake CLI guard deny and retry $case" {
            $env:M05_FAKE_CASE = $case
            $r = Invoke-DispatchGuardProbe $fake (Join-Path $root $case)
            if ($r['kept_case_folder']) { $keptCaseFolders.Add($r['kept_case_folder']) }
            Assert (-not $r.probe_error) ($r | ConvertTo-Json -Depth 60 -Compress)
            Assert ($r.forms.Count -eq 3) 'Missing required forms'
            Assert ($r.accepted -eq ($case -eq 'ok')) 'Invalid probe acceptance'
            Assert ($r.codex -eq 'measured-only' -and $r.Workflow -eq 'unsupported') 'Overstated surfaces'
            foreach ($form in $r.forms) { Assert ($null -eq $form.independent_acceptance) 'Execution confused with independent acceptance' }
        }
    }
} finally {
    [Environment]::SetEnvironmentVariable('M05_FAKE_CASE',$null,'Process')
    # A rejected case keeps its folder as evidence for a real probe; a fake CLI run has no use for it.
    foreach ($folder in $keptCaseFolders) {
        if ([IO.Path]::GetFullPath($folder).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()))) { Remove-Item -LiteralPath $folder -Recurse -Force }
    }
    # Only remove the uniquely created harness root after confirming containment.
    if ([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()))) { Remove-Item -LiteralPath $root -Recurse -Force }
}
Write-Output "Checks: $checks; failures: $($failures.Count)"
if ($failures.Count) { $failures | Write-Output; exit 1 }
