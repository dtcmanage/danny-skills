# CLI guard: under the fake-CLI root, nothing outside it starts, on any path to a launch.
# Runs in the real-wrapper fixture. Outside CLIs are harmless sentinels; no live CLI or network calls.
$recoveryState=$env:DT_MODEL_ROUTER_STATE
$guardRoot=$env:DT_ROUTER_TEST_FAKE_CLI_ROOT
$guardPath=$env:PATH
$guardCatalog=[IO.File]::ReadAllText($catalogPath)
$sibling=$null
try {
    Reset-EmptySourcesState 'cli-guard'
    # Product guard: a harmless CLI outside the root models a failed patch.
    # Never point a test at the installed model executables.
    $outside=Join-Path $temp 'outside-cli.ps1'; $marker=Join-Path $temp 'outside-cli-started'
    [IO.File]::WriteAllText($outside,('[IO.File]::WriteAllText('''+$marker+''',''started''); exit 0'))
    $savedRoot=$env:DT_ROUTER_TEST_FAKE_CLI_ROOT
    $env:DT_ROUTER_TEST_FAKE_CLI_ROOT=$fixture.root
    try {
        foreach ($lane in 'claude','codex') {
            $o=$base.Clone(); $o.OutputPath=Join-Path $temp "$lane-guard.md"; $o[$lane+'CliPath']=$outside
            Reject { & (Join-Path $env:M04_REPO_ROOT "skills/dt-build/scripts/invoke-$lane-chunk.ps1") @o | Out-Null } 'ROUTER_TEST_FAKE_CLI_REQUIRED'
            Check (-not (Test-Path $marker)) "CLI guard: $lane external CLI blocked before process start without retry"
            $null=Invoke-LaneDispatch $lane "$lane-inside-root"
            Check ((Read-RouterDispatchEvidence (Join-Path $temp "$lane-inside-root.md.provenance.json")).execution_result -eq 'success') "CLI guard: $lane allowed fake CLI runs"
        }
        # Real-shape usage credentials must never reach either I/O seam.
        & {
            . (Join-Path $env:M04_REPO_ROOT 'scripts/model-router/vendor-limits.ps1')
            $script:usageNetworkCalls=0
            $script:RouterClaudeCredentialProvider={ $script:usageNetworkCalls++; [pscustomobject]@{status='available';token='fake'} }
            $script:RouterClaudeUsageFetcher={ $script:usageNetworkCalls++; throw 'NETWORK_CALL' }
            $quota=Join-Path $fixture.root 'quota-reader.py'
            [IO.File]::WriteAllText($quota, ("from pathlib import Path`nPath(" + ($marker | ConvertTo-Json -Compress) + " ).write_text('started')`n"))
            $env:DT_MODEL_ROUTER_CODEX_LIVE_COMMAND=$quota
            $claudeUsage=Get-RouterClaudeUsage; $codexUsage=Get-RouterCodexLiveUsage
            Check ($null -eq $claudeUsage -and $null -eq $codexUsage -and $null -eq (Get-RouterCodexUsage) -and $null -eq (Get-RouterCachedWeeklyUsage 'claude') -and $script:usageNetworkCalls -eq 0) 'CLI guard: usage readers return unknown without network or CLI calls'
            Check (-not (Test-Path $marker)) 'CLI guard: quota reader starts no CLI under fake root guard'
            Remove-Item Env:DT_MODEL_ROUTER_CODEX_LIVE_COMMAND -ErrorAction SilentlyContinue
        }
        $originalPath=$env:PATH
        try {
            $outsideDir=Join-Path $temp 'outside-bin'; [void][IO.Directory]::CreateDirectory($outsideDir)
            foreach ($lane in 'claude','codex') { Copy-Item $outside (Join-Path $outsideDir ($lane+'.ps1')) }
            $escape=Join-Path $fixture.root 'escape'
            New-Item -ItemType Junction -Path $escape -Target $outsideDir | Out-Null
            try { Reject { Assert-RouterTestCliPath -Path (Join-Path $escape 'claude.ps1') } 'ROUTER_TEST_FAKE_CLI_REQUIRED' } finally { (Get-Item $escape).Delete() }
            $env:PATH=$outsideDir+[IO.Path]::PathSeparator+$originalPath
            # A wrapper shim without its own guard proves dispatch's guard is
            # independently load-bearing. It can only write a harmless marker.
            $shimDir=Join-Path $temp 'unguarded-shims'; [void][IO.Directory]::CreateDirectory($shimDir)
            foreach ($lane in 'claude','codex') {
                $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $env:M04_REPO_ROOT "skills/dt-build/scripts/invoke-$lane-chunk.ps1"),[ref]$null,[ref]$null)
                [IO.File]::WriteAllText((Join-Path $shimDir "invoke-$lane-chunk.ps1"),($ast.ParamBlock.Extent.Text+"`n"+'[IO.File]::WriteAllText('''+$marker+''',''started'')'))
            }
            $defaultInvoker=New-RouterWrapperInvoker -WrapperDirectory $shimDir
            $o=$base.Clone(); $o.Live=$true
            foreach ($lane in 'claude','codex') { $o.Lane=$lane; Reject { Invoke-RouterDispatch $o $defaultInvoker } 'ROUTER_TEST_FAKE_CLI_REQUIRED' }
            Check (-not (Test-Path $marker)) 'CLI guard: public dispatch refuses external CLI without retry'
        } finally { $env:PATH=$originalPath }
        $env:DT_ROUTER_TEST_FAKE_CLI_ROOT=''
        Assert-RouterTestCliPath -Path $outside
        $plain=Invoke-LaneDispatch 'claude' 'guard-unset'
        Check ($plain.execution_result -eq 'success') 'CLI guard: absent fake root preserves normal wrapper behavior'
    } finally { $env:DT_ROUTER_TEST_FAKE_CLI_ROOT=$savedRoot }
    # Prefix-sharing directories remain outside, with harmless fake sentinels.
    $sibling=$fixture.root+'-sibling'; [void][IO.Directory]::CreateDirectory($sibling)
    $sentinel=Join-Path $temp 'guard-cli-started'
    $outsideCli=Join-Path $sibling 'codex.ps1'
    [IO.File]::WriteAllText($outsideCli,('[IO.File]::WriteAllText('''+$sentinel+''',''started''); exit 0'))
    $env:DT_ROUTER_TEST_FAKE_CLI_ROOT=$fixture.root
    $refused=$false
    try { Assert-RouterTestCliPath $outsideCli } catch { $refused=$_.Exception.Message -like 'ROUTER_TEST_FAKE_CLI_REQUIRED*' }
    Check ($refused -and -not (Test-Path $sentinel)) 'CLI guard: separator rejects sibling-folder CLI'
    Reset-RosterOnlyState 'catalog'
    [IO.File]::WriteAllText($catalogPath,'{"models":[{"slug":"gpt-5.6-luna","visibility":"list","priority":1}]}')
    $env:PATH=$sibling+[IO.Path]::PathSeparator+$guardPath
    $env:DT_ROUTER_TEST_FAKE_CLI_ROOT=$fixture.root
    $publicOut=Join-Path $temp 'guard-public-catalog.md'
    $publicLog=Join-Path $temp 'guard-public-catalog.log'
    # All names on PATH resolve to fixture scripts, including the outside sentinel.
    Check ((Get-Command codex).Source -ceq $outsideCli) 'CLI guard: catalog sentinel is first CLI on PATH'
    & pwsh -NoProfile -File (Join-Path $env:M04_REPO_ROOT 'scripts/model-router/dispatch.ps1') -ProjectPath $repo -Category routine-coding -PromptPath $prompt -OutputPath $publicOut -SelectionReason fixture -Lane codex -AdHoc -ReadOnly -Scrutiny -Live *> $publicLog
    $publicExit=$LASTEXITCODE; $publicText=[IO.File]::ReadAllText($publicLog)
    Check ($publicExit -eq 1 -and $publicText -match 'ROUTER_TEST_FAKE_CLI_REQUIRED' -and -not (Test-Path $sentinel)) 'CLI guard: public dispatch propagates catalog guard refusal before any CLI start'
    [IO.File]::WriteAllText($catalogPath,$guardCatalog); $env:PATH=$guardPath; $env:DT_ROUTER_TEST_FAKE_CLI_ROOT=$guardRoot
} finally {
    $env:DT_MODEL_ROUTER_STATE=$recoveryState; $env:DT_ROUTER_TEST_FAKE_CLI_ROOT=$guardRoot; $env:PATH=$guardPath
    [IO.File]::WriteAllText($catalogPath,$guardCatalog)
    if ($sibling -and (Test-Path $sibling) -and [IO.Path]::GetFullPath($sibling).StartsWith([IO.Path]::GetTempPath())) { Remove-Item -LiteralPath $sibling -Recurse -Force }
}
